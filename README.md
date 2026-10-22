# gitops-lab

A production-like GitOps lab: **three separate Kubernetes clusters** (dev, staging, prod) managed by a single
**ArgoCD** instance, running a 4-service FastAPI fintech app, with an external **Patroni HA PostgreSQL** cluster.

Everything the clusters run is described in this repository. ArgoCD watches it and applies it; nobody runs
`kubectl apply` against the apps by hand.

The application source code lives in a separate repository, `fintech-app`. This repo only holds the manifests.

## Architecture

```
                        GitHub: gitops-lab (this repo)
                                   |
                                   | ArgoCD pulls and compares
                                   v
   +--------------------------- staging cluster ---------------------------+
   |  ArgoCD (hub)  --->  manages dev, staging (in-cluster) and prod        |
   +-----------------------------------------------------------------------+
        |                              |                              |
        v                              v                              v
   dev cluster                   staging cluster                 prod cluster
   ingress-nginx                 LoadBalancer (MetalLB)          Istio (mTLS STRICT,
   auto sync                     auto sync                       zero-trust policies)
                                                                 manual sync, canary
        \                              |                              /
         +-----------------------------+-----------------------------+
                                       |
                        PostgreSQL HA (3 VMs, outside Kubernetes)
                        VIP 192.168.200.50 :5000 -> current primary
                        etcd + Patroni + HAProxy + keepalived
```

| Environment | API server | Pod / Service CIDR | MetalLB pool | Exposure | Sync |
|---|---|---|---|---|---|
| dev | https://192.168.200.11:6443 | 10.110.0.0/16, 10.111.0.0/16 | .120-.129 | ingress-nginx, `fintech.dev.local` (.120) | automatic |
| staging | in-cluster (ArgoCD lives here) | 10.120.0.0/16, 10.121.0.0/16 | .130-.139 | LoadBalancer Service (.132) | automatic |
| prod | https://192.168.200.31:6443 | 10.130.0.0/16, 10.131.0.0/16 | .140-.149 | Istio Gateway, `fintech.prod.local` (.140) | manual |

ArgoCD itself is reachable at `https://192.168.200.130` (staging).

## The application

Four FastAPI services (Python 3.12), built from the `fintech-app` repository:

```
client -> api-gateway -> accounts
                      -> transactions -> accounts
                                      -> notifications
```

- `accounts` and `transactions` keep their state in PostgreSQL (`DATABASE_URL` comes from a Kubernetes Secret).
- Money is always integer cents, never floats.
- `transactions` supports an idempotency key, and `accounts` uses `SELECT ... FOR UPDATE`, so several replicas are safe.

## Repository layout

```
charts/microservice/            One generic Helm chart used by every service
apps/fintech/common.yaml        Values shared by all services and environments
apps/fintech/envs/<env>.yaml    Values per environment (replicas, resources)
apps/fintech/services/<svc>.yaml  Values per service (image, tag, env vars)
apps/fintech/overlays/<env>/    Kustomize: routing and security that differ per environment
                                  dev: Ingress | staging: LoadBalancer Service
                                  prod: Gateway, VirtualService, DestinationRules,
                                        PeerAuthentication, AuthorizationPolicies, canary routing
argocd/fintech-services.yaml    ApplicationSet: 4 services x 3 environments = 12 Applications
argocd/fintech-platform.yaml    ApplicationSet: one Kustomize Application per environment
argocd/fintech-canary-prod.yaml Application for the transactions v2 canary (prod only)
apps/frontend, argocd/applicationset.yaml
                                An earlier small sample app (podinfo). Optional, not needed for the fintech lab.
```

Values are layered, the last one wins: `common.yaml` -> `envs/<env>.yaml` -> `services/<svc>.yaml`.
Each Application uses ArgoCD multi-source: the Helm chart from this repo plus a second source of the same repo
with `ref: values`, so the values files are read as `$values/apps/fintech/...`.

## Prerequisites

- Three Kubernetes clusters with a CNI, MetalLB, ingress-nginx on dev and Istio on prod.
- ArgoCD installed on staging, with `dev` and `prod` registered (`argocd cluster add`).
- Container images pushed to a registry (Docker Hub in this lab) and **public**, or an `imagePullSecret`.
- A kubeconfig with contexts named `dev`, `staging` and `prod`.

## Bootstrap

1. Replace the `DOCKERHUB_USER` placeholder with your registry user in the service values:

   ```bash
   sed -i 's/DOCKERHUB_USER/<your-dockerhub-user>/g' apps/fintech/services/*.yaml
   ```

2. Check the `repoURL` and the cluster `server` fields in `argocd/*.yaml` match your GitHub repo and your IPs.

3. Commit and push, then apply the ApplicationSets once, on the hub (staging):

   ```bash
   kubectl --context staging apply -f argocd/fintech-services.yaml
   kubectl --context staging apply -f argocd/fintech-platform.yaml
   argocd app list
   ```

   dev and staging sync automatically. For prod, sync manually:

   ```bash
   argocd app sync argocd/fintech-api-gateway-prod   # one Application per service, or use the UI
   argocd app sync argocd/fintech-platform-prod
   ```

   Use `argocd app list` to see the exact Application names that were generated.

4. Create the database Secrets in each cluster (they are **never** stored in Git):

   ```bash
   kubectl --context <env> -n fintech create secret generic db-accounts \
     --from-literal=url='postgresql+psycopg://<user>:<password>@192.168.200.50:5000/accounts_<env>'
   kubectl --context <env> -n fintech create secret generic db-transactions \
     --from-literal=url='postgresql+psycopg://<user>:<password>@192.168.200.50:5000/transactions_<env>'
   ```

   Until these Secrets exist the services fall back to SQLite inside the pod (data is lost on restart),
   so `replicaCount` is pinned to 1 in `services/accounts.yaml` and `services/transactions.yaml`.
   After the Secrets exist, remove that pin so the environment files decide the replica count.

## Testing

Add to `/etc/hosts` on the machine you test from:

```
192.168.200.120 fintech.dev.local
192.168.200.140 fintech.prod.local
```

From the `fintech-app` repository:

```bash
BASE=http://fintech.dev.local  python smoke_test.py
BASE=http://192.168.200.132    python smoke_test.py      # staging
BASE=http://fintech.prod.local python smoke_test.py
```

All three must finish with `ALL PASSED`.

## Prod security (Istio)

- `PeerAuthentication` mTLS `STRICT` for the `fintech` namespace.
- A default-deny `AuthorizationPolicy`, then explicit allows by ServiceAccount identity:
  ingress gateway -> api-gateway -> accounts and transactions; transactions -> accounts and notifications.
- A `DestinationRule` with outlier detection (circuit breaking) per service.

## Canary release (prod only)

`transactions-v2` is a second Helm release that joins the same Service. A `DestinationRule` defines subsets
`v1` and `v2` by the `version` pod label and a `VirtualService` splits traffic by weight.

```bash
# edit the weights in apps/fintech/overlays/prod/transactions-canary.yaml, then:
git add apps/fintech/overlays/prod/transactions-canary.yaml
git commit -m "canary: transactions 50/50"
git push
argocd app sync argocd/fintech-platform-prod
BASE=http://fintech.prod.local N=200 python canary_test.py
```

Typical stages: 90/10, then 50/50, then 100/0 to roll back (or 0/100 to promote).

## Security notes

- Never commit passwords, tokens, kubeconfigs or the database credentials file.
- Push to GitHub with a personal access token or an SSH key.
- Use an access token, not your password, for `docker login`.
