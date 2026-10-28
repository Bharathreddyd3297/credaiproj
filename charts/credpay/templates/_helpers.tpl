{{/* ===================================================================
     Shared helpers
     =================================================================== */}}

{{/* Labels on every object. The selector labels (app.kubernetes.io/name)
     are kept exactly as in the earlier kustomize manifests, so an
     existing environment can be taken over by Helm without recreating
     its Deployments (selectors are immutable). */}}
{{- define "credpay.labels" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/part-of: credpay
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
app.kubernetes.io/version: {{ .root.Chart.AppVersion | quote }}
helm.sh/chart: {{ printf "%s-%s" .root.Chart.Name .root.Chart.Version }}
credpay.io/environment: {{ .root.Values.environment }}
{{- end }}

{{- define "credpay.selectorLabels" -}}
app.kubernetes.io/name: {{ .name }}
{{- end }}

{{/* Host names of this environment */}}
{{- define "credpay.customerHost" -}}
{{- default (printf "%s.%s" .Values.environment .Values.domain) .Values.hosts.customer -}}
{{- end }}
{{- define "credpay.adminHost" -}}
{{- default (printf "admin.%s.%s" .Values.environment .Values.domain) .Values.hosts.admin -}}
{{- end }}
{{- define "credpay.authHost" -}}
{{- default (printf "auth.%s.%s" .Values.environment .Values.domain) .Values.hosts.auth -}}
{{- end }}
{{- define "credpay.issuerUri" -}}
{{- printf "https://%s/realms/credpay" (include "credpay.authHost" .) -}}
{{- end }}

{{/* Database names (one PostgreSQL server, databases per environment) */}}
{{- define "credpay.appDbName" -}}
{{- default (printf "credpay_%s" .Values.environment) .Values.database.appName -}}
{{- end }}
{{- define "credpay.keycloakDbName" -}}
{{- default (printf "keycloak_%s" .Values.environment) .Values.database.keycloakName -}}
{{- end }}

{{/* Image reference - fails the render when the pipeline did not set it */}}
{{- define "credpay.image" -}}
{{- required (printf "%s.image is required (full reference, e.g. creddemoacr.azurecr.io/credpay/<service>:<tag>)" .key) .image -}}
{{- end }}

{{/* Restart pods when the shared configuration changes */}}
{{- define "credpay.configChecksum" -}}
checksum/config: {{ include (print .Template.BasePath "/configmap.yaml") . | sha256sum }}
{{- end }}

{{/* Prometheus scrape annotations for Dynatrace (metrics.dynatrace.com/*) */}}
{{- define "credpay.dynatraceScrape" -}}
{{- if and .root.Values.monitoring.enabled .root.Values.monitoring.dynatraceMetrics }}
metrics.dynatrace.com/scrape: "true"
metrics.dynatrace.com/port: {{ .port | quote }}
metrics.dynatrace.com/path: {{ .path | quote }}
{{- end }}
{{- end }}

