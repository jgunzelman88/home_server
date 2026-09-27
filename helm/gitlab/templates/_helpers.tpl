{{- define "gitlab.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "gitlab.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "gitlab.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "gitlab.labels" -}}
helm.sh/chart: {{ include "gitlab.chart" . }}
app.kubernetes.io/name: {{ include "gitlab.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* Per-component selector labels: include "gitlab.selectorLabels" (dict "ctx" . "component" "gitlab") */}}
{{- define "gitlab.selectorLabels" -}}
app.kubernetes.io/name: {{ include "gitlab.name" .ctx }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{- define "gitlab.postgres.fullname" -}}{{ include "gitlab.fullname" . }}-postgres{{- end }}
{{- define "gitlab.redis.fullname" -}}{{ include "gitlab.fullname" . }}-redis{{- end }}
{{- define "gitlab.secretName" -}}{{ include "gitlab.fullname" . }}-secrets{{- end }}

{{- define "gitlab.externalUrl" -}}
{{- printf "https://%s%s" .Values.gitlab.host (.Values.gitlab.path | trimSuffix "/") }}
{{- end }}

{{/*
Return a password that is stable across upgrades:
  explicit value from values.yaml > value already in the Secret > new random.
Usage: include "gitlab.stablePassword" (dict "ctx" . "key" "postgres-password" "value" .Values.postgresql.auth.password)
*/}}
{{- define "gitlab.stablePassword" -}}
{{- $existing := lookup "v1" "Secret" .ctx.Release.Namespace (include "gitlab.secretName" .ctx) -}}
{{- if .value -}}
{{- .value -}}
{{- else if and $existing $existing.data (hasKey $existing.data .key) -}}
{{- index $existing.data .key | b64dec -}}
{{- else -}}
{{- randAlphaNum 32 -}}
{{- end -}}
{{- end }}

{{- define "gitlab.oidcIssuer" -}}
{{- printf "%s/realms/%s" (.Values.gitlab.oidc.keycloakBaseUrl | trimSuffix "/") .Values.gitlab.oidc.realm }}
{{- end }}

{{/* Hostname part of keycloakBaseUrl, for the hostAlias */}}
{{- define "gitlab.oidcHost" -}}
{{- (urlParse .Values.gitlab.oidc.keycloakBaseUrl).hostname }}
{{- end }}
