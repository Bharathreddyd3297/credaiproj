#!/usr/bin/env bash
# =====================================================================
# Deploy CredPay to one environment (namespace credpay-<env>) with the
# Helm chart charts/credpay, then smoke test it. Called by
# pipelines/credpay-cd.yml (templates/deploy-env.yml) after aks-login.sh.
#
#   scripts/cd/deploy-app.sh <env>          # env = dev | qa | prod
#
# Environment variables:
#   DOMAIN        e.g. 20-48-1-2.sslip.io (hosts: <env>.DOMAIN, admin.<env>.DOMAIN, auth.<env>.DOMAIN)
#   TLS_ISSUER    letsencrypt-prod | letsencrypt-staging | selfsigned
#   IMAGES_FILE   service=image lines (scripts/cd/resolve-images.sh)
#   OUT_DIR       where to write the rendered manifests and test results
#   DB_HOST DB_USERNAME DB_PASSWORD             (from Key Vault)
#   KC_ADMIN_USERNAME KC_ADMIN_PASSWORD         (from Key Vault)
# Optional (prod; empty = feature off):
#   OPENAI_ENDPOINT OPENAI_KEY OPENAI_DEPLOYMENT  Azure OpenAI for the AIOps briefing
#   DYNATRACE_URL DYNATRACE_PROBLEMS_TOKEN        Dynatrace problems in the AIOps overview
#                                                 (read-only token; falls back to DYNATRACE_API_TOKEN)
#   DYNATRACE_ENABLED=true   the Dynatrace Operator runs: annotate pods for metric ingest
#   GRAFANA_URL DYNATRACE_URL                     links on the admin portal's Monitoring page
#   HELM_EXTRA_ARGS   extra helm arguments, for local testing (e.g. a database without TLS:
#                     --set-string database.keycloakUrlProperties=)
# =====================================================================
set -euo pipefail

env_name="${1:?usage: deploy-app.sh <env>}"
ns="credpay-$env_name"
release=credpay
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
chart="$repo_root/charts/credpay"
values_env="$chart/values-$env_name.yaml"
mkdir -p "$OUT_DIR"

section() { echo; echo "===== $* ====="; }

[ -f "$values_env" ] || { echo "##vso[task.logissue type=error]Missing $values_env"; exit 1; }

# Hosts (same rule as the chart's _helpers.tpl)
CUSTOMER_HOST="$env_name.$DOMAIN"
ADMIN_HOST="admin.$env_name.$DOMAIN"
AUTH_HOST="auth.$env_name.$DOMAIN"
OIDC_ISSUER_URI="https://$AUTH_HOST/realms/credpay"

# ---- 1. Helm arguments: images, domain, optional features -------------
section "Helm values for $env_name"
helm_args=(
  -f "$values_env"
  --set-string "domain=$DOMAIN"
  --set-string "tls.issuer=$TLS_ISSUER"
)

# Is "<block>: enabled: true" set in this environment's values file?
values_enabled() {
  awk -v block="$1" '
    $0 ~ "^" block ":" { inside = 1; next }
    inside && /^[^ #]/  { inside = 0 }
    inside && /^  enabled:[[:space:]]*true/ { found = 1 }
    END { exit !found }' "$values_env"
}
aiops_enabled="$(values_enabled aiops && echo true || echo false)"
declare -A chart_key=(
  [keycloak]=keycloak [user-service]=userService [payment-service]=paymentService
  [customer-portal]=customerPortal [admin-portal]=adminPortal [ai-service]=aiops
)
while IFS='=' read -r service image; do
  [ -n "$service" ] || continue
  [ "$service" = ai-service ] && [ "$aiops_enabled" != true ] && continue
  helm_args+=(--set-string "${chart_key[$service]}.image=$image")
  printf '  %-16s %s\n' "$service" "$image"
done < "$IMAGES_FILE"

# ai-service only reads problems: give it the read-only token when there is one
dt_problems_token="${DYNATRACE_PROBLEMS_TOKEN:-${DYNATRACE_API_TOKEN:-}}"

if [ "$aiops_enabled" = true ]; then
  [ "${DYNATRACE_ENABLED:-}" = true ] && helm_args+=(--set monitoring.dynatraceMetrics=true)
  [ -n "${GRAFANA_URL:-}" ] && helm_args+=(--set-string "aiops.links.grafana=$GRAFANA_URL")
  [ -n "${DYNATRACE_URL:-}" ] && helm_args+=(--set-string "aiops.links.dynatrace=$DYNATRACE_URL")
  # Pods read the Secret credpay-aiops only when they start: a hash of its
  # settings in the pod template restarts ai-service when one changes
  aiops_hash="$(printf '%s\n' "${OPENAI_ENDPOINT:-}" "${OPENAI_KEY:-}" "${OPENAI_DEPLOYMENT:-}" \
    "${DYNATRACE_URL:-}" "$dt_problems_token" | sha256sum | cut -c1-16)"
  helm_args+=(--set-string "aiops.settingsChecksum=$aiops_hash")
fi
if [ -n "${HELM_EXTRA_ARGS:-}" ]; then
  read -r -a extra <<<"$HELM_EXTRA_ARGS"
  helm_args+=("${extra[@]}")
fi
echo "AIOps: $aiops_enabled  Dynatrace metrics: ${DYNATRACE_ENABLED:-false}"

helm template "$release" "$chart" -n "$ns" "${helm_args[@]}" > "$OUT_DIR/rendered-$env_name.yaml"
echo "Rendered manifests: rendered-$env_name.yaml"

# ---- 2. Namespace + Secrets (values from Key Vault) -------------------
section "Namespace and secrets"
kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
# Reject pods that don't meet the "restricted" Pod Security Standard
kubectl label namespace "$ns" --overwrite \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=restricted \
  app.kubernetes.io/part-of=credpay

kubectl create secret generic credpay-db -n "$ns" \
  --from-literal=DB_HOST="$DB_HOST" \
  --from-literal=DB_USERNAME="$DB_USERNAME" \
  --from-literal=DB_PASSWORD="$DB_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic keycloak-admin -n "$ns" \
  --from-literal=username="$KC_ADMIN_USERNAME" \
  --from-literal=password="$KC_ADMIN_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

if [ "$aiops_enabled" = true ]; then
  # Optional settings of the AIOps service; empty values switch a feature off
  kubectl create secret generic credpay-aiops -n "$ns" \
    --from-literal=OPENAI_ENDPOINT="${OPENAI_ENDPOINT:-}" \
    --from-literal=OPENAI_KEY="${OPENAI_KEY:-}" \
    --from-literal=OPENAI_DEPLOYMENT="${OPENAI_DEPLOYMENT:-}" \
    --from-literal=DYNATRACE_URL="${DYNATRACE_URL:-}" \
    --from-literal=DYNATRACE_API_TOKEN="$dt_problems_token" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "AIOps: Azure OpenAI $([ -n "${OPENAI_KEY:-}" ] && echo configured || echo 'not configured (rule-based briefings)'), Dynatrace $([ -n "${DYNATRACE_PROBLEMS_TOKEN:-}" ] && echo 'configured (read-only token)' || { [ -n "$dt_problems_token" ] && echo 'configured (operator token)'; } || echo 'not configured')"
fi

# ---- 3. One-time takeover of an environment deployed with kustomize ----
# Helm only manages objects that carry its ownership labels. Objects
# created earlier by `kubectl apply` (the kustomize overlays) get them, so
# Helm updates them in place instead of failing or recreating them.
section "Adopt existing objects (only needed once)"
adopted=0
for obj in deployment/keycloak deployment/user-service deployment/payment-service \
           deployment/customer-portal deployment/admin-portal \
           service/keycloak service/user-service service/payment-service \
           service/customer-portal service/admin-portal ingress/credpay; do
  if kubectl get "$obj" -n "$ns" >/dev/null 2>&1 && \
     [ "$(kubectl get "$obj" -n "$ns" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}')" != Helm ]; then
    kubectl label "$obj" -n "$ns" --overwrite app.kubernetes.io/managed-by=Helm >/dev/null
    kubectl annotate "$obj" -n "$ns" --overwrite \
      meta.helm.sh/release-name="$release" meta.helm.sh/release-namespace="$ns" >/dev/null
    echo "  adopted $obj"
    adopted=$((adopted + 1))
  fi
done
echo "Adopted $adopted object(s)"

# ---- 4. Install / upgrade (rolled back automatically if it fails) ------
section "helm upgrade --install $release ($ns)"
helm upgrade --install "$release" "$chart" -n "$ns" "${helm_args[@]}" \
  --atomic --wait --timeout 15m --history-max 10
helm history "$release" -n "$ns" --max 5

# kustomize's hashed ConfigMaps (credpay-config-<hash>) are no longer used
kubectl get configmap -n "$ns" -o name | grep -E '^configmap/credpay-config-[a-z0-9]{6,}$' \
  | xargs -r kubectl delete -n "$ns" || true

kubectl get pods,svc,ingress,hpa -n "$ns" -o wide

# ---- 5. TLS certificate -----------------------------------------------
section "TLS certificate ($TLS_ISSUER)"
curl_tls=()
if kubectl wait --for=condition=Ready "certificate/credpay-tls" -n "$ns" --timeout=5m; then
  echo "Certificate ready"
else
  kubectl describe certificate credpay-tls -n "$ns" || true
  kubectl get certificaterequests,orders,challenges -n "$ns" || true
  echo "##vso[task.logissue type=warning]Certificate for $CUSTOMER_HOST not issued by $TLS_ISSUER yet - smoke tests skip certificate checks. Let's Encrypt limits sslip.io to 50 certificates a week for everyone; set tlsIssuer=selfsigned or use your own domain."
  curl_tls=(-k)
fi
if [ "$TLS_ISSUER" != "letsencrypt-prod" ]; then
  curl_tls=(-k) # staging and self-signed certificates are not trusted
fi

# ---- 6. Smoke tests ---------------------------------------------------
section "Smoke tests"
results="$OUT_DIR/smoke-tests-$env_name.txt"
: > "$results"
failed=0

# check <name> <expected HTTP code(s), e.g. 200 or 301|308> <url> [text the body must contain]
check() {
  local name="$1" expected="$2" url="$3" contains="${4:-}" code body
  for attempt in 1 2 3 4 5 6; do
    body="$(curl -s "${curl_tls[@]}" --max-time 15 -o - -w '\n%{http_code}' "$url" || true)"
    code="${body##*$'\n'}"
    body="${body%$'\n'*}"
    if [[ "$code" =~ ^($expected)$ ]] && { [ -z "$contains" ] || grep -qF "$contains" <<<"$body"; }; then
      printf 'PASS  %-45s %s -> %s\n' "$name" "$url" "$code" | tee -a "$results"
      return
    fi
    sleep 10
  done
  printf 'FAIL  %-45s %s -> %s (expected %s%s)\n' "$name" "$url" "$code" "$expected" \
    "${contains:+ containing \"$contains\"}" | tee -a "$results"
  failed=1
}

check "HTTP redirects to HTTPS"                   "301|308" "http://$CUSTOMER_HOST/"
check "Customer portal is served"                 200 "https://$CUSTOMER_HOST/healthz"
check "Customer portal points at Keycloak"        200 "https://$CUSTOMER_HOST/config.js" "$OIDC_ISSUER_URI"
check "Admin portal is served"                    200 "https://$ADMIN_HOST/healthz"
check "Admin portal calls APIs on its own host"   200 "https://$ADMIN_HOST/config.js" '"userApiUrl": ""'
check "Keycloak issuer is the public URL"         200 "https://$AUTH_HOST/realms/credpay/.well-known/openid-configuration" "\"issuer\":\"$OIDC_ISSUER_URI\""
check "payment-service reachable via ingress"     200 "https://$CUSTOMER_HOST/api/payment/health"
check "user-service rejects calls without login"  401 "https://$CUSTOMER_HOST/api/cards"
check "admin API rejects calls without login"     401 "https://$ADMIN_HOST/api/admin/users/summary"
check "admin payments API (payment-service)"      401 "https://$ADMIN_HOST/api/admin/payments/summary"
if [ "$aiops_enabled" = true ]; then
  check "AIOps API rejects calls without login"   401 "https://$ADMIN_HOST/api/ai/overview"
fi

section "Result"
cat "$results"
cat <<URLS

Customer portal  https://$CUSTOMER_HOST
Admin portal     https://$ADMIN_HOST
Keycloak         https://$AUTH_HOST/admin   (admin user + password: Key Vault keycloak-admin-*)
URLS
exit "$failed"
