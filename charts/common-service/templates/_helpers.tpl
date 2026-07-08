{{- define "common-service.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "common-service.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "common-service.labels" -}}
app.kubernetes.io/name: {{ include "common-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "common-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "common-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- /* Name of the ESO-projected dockerconfigjson pull secret (defaults to <release>-registry). */ -}}
{{- define "common-service.registrySecretName" -}}
{{- .Values.registry.secretName | default (printf "%s-registry" (include "common-service.fullname" .)) -}}
{{- end -}}

{{- /* imagePullSecrets for the Deployment: explicit .Values.imagePullSecrets plus the
       registry pull secret when registry.enabled. */ -}}
{{- define "common-service.imagePullSecrets" -}}
{{- $secrets := .Values.imagePullSecrets | default list -}}
{{- if .Values.registry.enabled -}}
{{- $secrets = append $secrets (dict "name" (include "common-service.registrySecretName" .)) -}}
{{- end -}}
{{- if $secrets -}}
{{- toYaml $secrets -}}
{{- end -}}
{{- end -}}

{{- define "common-service.otelResourceAttributes" -}}
{{- /* k8s.namespace.name resolves at runtime via the Downward API POD_NAMESPACE env
       (defined earlier in the container), not at render time - under the Kustomize+Helm
       hybrid .Release.Namespace is "default", so templating it would be wrong. */ -}}
{{- $attrs := "service.namespace=tradebot,k8s.namespace.name=$(POD_NAMESPACE)" -}}
{{- range $k, $v := .Values.observability.resourceAttributes -}}
{{- $attrs = printf "%s,%s=%s" $attrs $k $v -}}
{{- end -}}
{{- $attrs -}}
{{- end -}}
