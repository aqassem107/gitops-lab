# gitops-lab

Lab: 3 Kubernetes clusters (dev / staging / prod) managed by ArgoCD (running on staging).

| Env | Cluster API | Exposure | Sync |
|---|---|---|---|
| dev | https://192.168.200.11:6443 | NGINX Ingress (`frontend.dev.local`) | auto |
| staging | in-cluster | LoadBalancer via MetalLB | auto |
| prod | https://192.168.200.31:6443 | Istio Gateway (`frontend.prod.local`), mTLS STRICT | manual |

## Layout

```
charts/microservice/            Helm chart عام (Deployment, Service, HPA)
apps/frontend/values-<env>.yaml Helm values لكل بيئة
apps/frontend/overlays/<env>/   Kustomize: routing وسياسات خاصة بالبيئة
argocd/applicationset.yaml      بيولّد Application لكل بيئة
```

Each Application uses 3 sources: the Helm chart, the values ref, and the Kustomize overlay.

## Bootstrap

```bash
# من الـ Ubuntu بتاعك (kubeconfig فيه context اسمه staging)
kubectl --context staging apply -f argocd/applicationset.yaml
argocd app list
```

- dev و staging بيتعملهم sync تلقائي.
- prod: افتح `frontend-prod` في الـ UI واضغط **Sync** (أو `argocd app sync frontend-prod`).

## Test

أضف في `/etc/hosts` على الـ Ubuntu:

```
192.168.200.120 frontend.dev.local
192.168.200.140 frontend.prod.local
```

```bash
curl http://frontend.dev.local
curl http://frontend.prod.local
kubectl --context staging -n frontend get svc frontend   # EXTERNAL-IP من range الـ staging
```

الـ image المستخدمة: `ghcr.io/stefanprodan/podinfo` (service صغيرة بتعرض JSON).
