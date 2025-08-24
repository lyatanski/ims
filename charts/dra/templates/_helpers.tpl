{{/*
Expand the name of the chart.
*/}}
{{- define "dra.name" -}}
{{- if contains .Chart.Name .Release.Name }}
{{- printf "%s" .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "dra.labels" -}}
{{ include "dra.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "dra.selectorLabels" -}}
app.kubernetes.io/name: {{ include "dra.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

