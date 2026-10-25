{{/* App name that groups the versions: the Service selects pods by label app=<appName>.
          Defaults to the release name. In the canary, v2 uses appName=transactions
          so the same Service reaches both versions. */}}
{{- define "microservice.appName" -}}
{{- default .Release.Name .Values.appName -}}
{{- end }}

{{- define "microservice.labels" -}}
app.kubernetes.io/name: {{ .Release.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "microservice.selectorLabels" -}}
app.kubernetes.io/name: {{ .Release.Name }}
{{- end }}
