{{- define "kb-mongosync.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "kb-mongosync.fullname" -}}
{{- printf "%s" (include "kb-mongosync.name" .) -}}
{{- end -}}

{{- define "kb-mongosync.labels" -}}
app.kubernetes.io/name: {{ include "kb-mongosync.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end -}}
