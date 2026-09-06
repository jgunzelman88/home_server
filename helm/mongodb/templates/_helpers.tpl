{{/*
Expand the name of the chart.
*/}}
{{- define "mongodb.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "mongodb.fullname" -}}
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
{{- define "mongodb.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "mongodb.labels" -}}
helm.sh/chart: {{ include "mongodb.chart" . }}
app.kubernetes.io/name: {{ include "mongodb.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
------------------------------------------------------------------
MongoDB component
------------------------------------------------------------------
*/}}
{{- define "mongodb.mongo.fullname" -}}
{{ include "mongodb.fullname" . }}
{{- end }}

{{- define "mongodb.mongo.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mongodb.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: mongodb
{{- end }}

{{/*
------------------------------------------------------------------
Compass (mongo-express + oauth2-proxy) component
------------------------------------------------------------------
*/}}
{{- define "mongodb.compass.fullname" -}}
{{ include "mongodb.fullname" . }}-compass
{{- end }}

{{- define "mongodb.compass.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mongodb.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: compass
{{- end }}

{{/*
Keycloak issuer URL: {keycloakBaseUrl}/realms/{realm} - oauth2-proxy appends
its own /.well-known/openid-configuration when discovering.
*/}}
{{- define "mongodb.compass.oidcIssuerUrl" -}}
{{ printf "%s/realms/%s" (.Values.compass.oidc.keycloakBaseUrl | trimSuffix "/") .Values.compass.oidc.realm }}
{{- end }}

{{/*
Hostname portion of keycloakBaseUrl (for the hostAliases entry) - strips the
scheme and any path/port so e.g. "https://bwing/keycloak" becomes "bwing".
*/}}
{{- define "mongodb.compass.oidcHost" -}}
{{- $noScheme := .Values.compass.oidc.keycloakBaseUrl | trimPrefix "https://" | trimPrefix "http://" -}}
{{- $hostAndPath := splitList "/" $noScheme -}}
{{- $hostPort := first $hostAndPath -}}
{{- $hostOnly := splitList ":" $hostPort -}}
{{- first $hostOnly -}}
{{- end }}
