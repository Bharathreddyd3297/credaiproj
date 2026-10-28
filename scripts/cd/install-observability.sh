#!/usr/bin/env bash
# =====================================================================
# Cluster-wide observability, installed by the CD pipeline's Platform
# stage (after aks-login.sh). Every step is an idempotent helm upgrade:
#
#   1. kube-prometheus-stack  Prometheus, Alertmanager, Grafana   (always)
#      + Alertmanager -> Slack receiver                           (SLACK_ENABLED=true)
#   2. Dynatrace Operator     OneAgent + ActiveGate (DynaKube)    (DYNATRACE_ENABLED=true)
#
# Environment variables:
#   DOMAIN TLS_ISSUER          Grafana at https://grafana.<DOMAIN>
#   GRAFANA_ADMIN_PASSWORD     from Key Vault (grafana-admin-password)
#   KPS_VERSION DYNATRACE_CHART_VERSION   pinned chart versions
#   + the variables of read-optional-secrets.sh (SLACK_*, DYNATRACE_*)
# =====================================================================
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
platform="$repo_root/k8s/platform"
work="$(mktemp -d)"
section() { echo; echo "===== $* ====="; }

ensure_ns() { kubectl create namespace "$1" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; }
secret() { # <namespace> <name> <key=value>...
  local ns="$1" name="$2"; shift 2
  local args=()
  for kv in "$@"; do args+=(--from-literal="$kv"); done
  kubectl create secret generic "$name" -n "$ns" "${args[@]}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "  secret $ns/$name"
}

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo update >/dev/null

# ---- Secrets first (Alertmanager mounts alertmanager-slack) ----------
section "Secrets"
ensure_ns monitoring
secret monitoring grafana-admin username=admin "password=${GRAFANA_ADMIN_PASSWORD:?GRAFANA_ADMIN_PASSWORD is required}"
if [ "${SLACK_ENABLED:-false}" = true ]; then
  secret monitoring alertmanager-slack "webhook_url=$SLACK_WEBHOOK_URL"
fi

# ---- 1. Prometheus, Alertmanager, Grafana -----------------------------
section "kube-prometheus-stack $KPS_VERSION"
"$repo_root/scripts/cd/monitoring-values.sh" "$work/monitoring-generated.yaml"
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --version "$KPS_VERSION" -n monitoring \
  -f "$platform/monitoring/kube-prometheus-stack-values.yaml" \
  -f "$work/monitoring-generated.yaml" \
  --wait --timeout 15m
kubectl get pods -n monitoring

# ---- 2. Dynatrace -----------------------------------------------------
if [ "${DYNATRACE_ENABLED:-false}" = true ]; then
  section "Dynatrace Operator $DYNATRACE_CHART_VERSION"
  helm upgrade --install dynatrace-operator oci://public.ecr.aws/dynatrace/dynatrace-operator \
    --version "$DYNATRACE_CHART_VERSION" -n dynatrace --create-namespace \
    --set installCRD=true --atomic --wait --timeout 10m
  secret dynatrace dynakube "apiToken=$DYNATRACE_API_TOKEN" "dataIngestToken=$DYNATRACE_INGEST_TOKEN"
  sed "s#ENVIRONMENT_URL#${DYNATRACE_URL%/}#" "$platform/dynatrace/dynakube.yaml" | kubectl apply -f -
  kubectl get dynakube -n dynatrace
else
  section "Dynatrace: not configured (Key Vault dynatrace-url / -api-token / -data-ingest-token) - skipped"
fi

rm -rf "$work"
