{{/*
Expand the name of the chart.
*/}}
{{- define "bookorbit.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "bookorbit.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart label value.
*/}}
{{- define "bookorbit.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "bookorbit.labels" -}}
helm.sh/chart: {{ include "bookorbit.chart" . }}
{{ include "bookorbit.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "bookorbit.selectorLabels" -}}
app.kubernetes.io/name: {{ include "bookorbit.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Postgres selector labels.
*/}}
{{- define "bookorbit.postgresSelectorLabels" -}}
app.kubernetes.io/name: {{ include "bookorbit.name" . }}-postgres
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Name of the Secret holding credentials.
*/}}
{{- define "bookorbit.secretName" -}}
{{- if .Values.credentials.existingSecret }}
{{- .Values.credentials.existingSecret }}
{{- else }}
{{- include "bookorbit.fullname" . }}
{{- end }}
{{- end }}

{{/*
PostgreSQL hostname. Internal service when bundled, external host otherwise.
*/}}
{{- define "bookorbit.postgresHost" -}}
{{- if .Values.postgres.enabled }}
{{- printf "%s-postgres" (include "bookorbit.fullname" .) }}
{{- else }}
{{- required "postgres.host is required when postgres.enabled=false" .Values.postgres.host }}
{{- end }}
{{- end }}

{{/*
PVC name helpers.
*/}}
{{- define "bookorbit.pvcBooks" -}}
{{- if .Values.persistence.books.existingClaim }}
{{- .Values.persistence.books.existingClaim }}
{{- else }}
{{- printf "%s-books" (include "bookorbit.fullname" .) }}
{{- end }}
{{- end }}

{{- define "bookorbit.pvcData" -}}
{{- if .Values.persistence.data.existingClaim }}
{{- .Values.persistence.data.existingClaim }}
{{- else }}
{{- printf "%s-data" (include "bookorbit.fullname" .) }}
{{- end }}
{{- end }}

{{- define "bookorbit.pvcPostgres" -}}
{{- if .Values.postgres.persistence.existingClaim }}
{{- .Values.postgres.persistence.existingClaim }}
{{- else }}
{{- printf "%s-postgres" (include "bookorbit.fullname" .) }}
{{- end }}
{{- end }}
