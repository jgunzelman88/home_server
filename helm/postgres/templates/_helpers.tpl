{{/*
Expand the name of the chart.
*/}}
{{- define "postgres.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "postgres.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- printf "%s" $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Chart label.
*/}}
{{- define "postgres.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "postgres.labels" -}}
helm.sh/chart: {{ include "postgres.chart" . }}
app.kubernetes.io/name: {{ include "postgres.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
------------------------------------------------------------------
PostgreSQL component
------------------------------------------------------------------
*/}}
{{- define "postgres.pg.fullname" -}}
{{ include "postgres.fullname" . }}
{{- end }}

{{- define "postgres.pg.selectorLabels" -}}
app.kubernetes.io/name: {{ include "postgres.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: postgresql
{{- end }}

{{/*
------------------------------------------------------------------
pgAdmin component
------------------------------------------------------------------
*/}}
{{- define "postgres.pgadmin.fullname" -}}
{{ include "postgres.fullname" . }}-pgadmin
{{- end }}

{{- define "postgres.pgadmin.selectorLabels" -}}
app.kubernetes.io/name: {{ include "postgres.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: pgadmin
{{- end }}

{{/*
OIDC discovery URL: use the explicit override if set, otherwise build it
from keycloakBaseUrl + realm.
*/}}
{{- define "postgres.pgadmin.oidcMetadataUrl" -}}
{{- if .Values.pgadmin.oidc.serverMetadataUrl -}}
{{ .Values.pgadmin.oidc.serverMetadataUrl }}
{{- else -}}
{{ printf "%s/realms/%s/.well-known/openid-configuration" (.Values.pgadmin.oidc.keycloakBaseUrl | trimSuffix "/") .Values.pgadmin.oidc.realm }}
{{- end -}}
{{- end }}
