{{- define "mfe.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mfe.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "mfe.labels" -}}
app.kubernetes.io/name: {{ include "mfe.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "mfe.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mfe.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "mfe.registrySecretName" -}}
{{- .Values.registry.secretName | default (printf "%s-registry" (include "mfe.fullname" .)) -}}
{{- end -}}

{{- define "mfe.imagePullSecrets" -}}
{{- $secrets := .Values.imagePullSecrets | default list -}}
{{- if .Values.registry.enabled -}}
{{- $secrets = append $secrets (dict "name" (include "mfe.registrySecretName" .)) -}}
{{- end -}}
{{- if $secrets -}}
{{- toYaml $secrets -}}
{{- end -}}
{{- end -}}
