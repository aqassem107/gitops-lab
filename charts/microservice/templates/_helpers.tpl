{{/* اسم الـ app اللي بيجمّع النسخ: الـ Service بتختار pods بـ label app=<appName>.
     الافتراضي = اسم الـ release. في الـ canary نسخة v2 بتاخد appName=transactions
     عشان نفس الـ Service توصّل للنسختين. */}}
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
