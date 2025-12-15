{{/*
Expand the name of the chart.
*/}}
{{- define "rtpengine.name" -}}
{{- if contains .Chart.Name .Release.Name }}
{{- printf "%s" .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "rtpengine.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "rtpengine.labels" -}}
helm.sh/chart: {{ include "rtpengine.chart" . }}
{{ include "rtpengine.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "rtpengine.selectorLabels" -}}
app.kubernetes.io/name: {{ include "rtpengine.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

