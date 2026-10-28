#!/bin/sh
# =====================================================================
# Runs at container start (nginx image: /docker-entrypoint.d/*.sh).
# Writes /tmp/runtime/config.js from environment variables, so the SAME
# image runs in dev, qa and prod - only the environment variables differ.
#
#   CREDPAY_USER_API_URL     user-service base URL ('' = same origin)
#   CREDPAY_PAYMENT_API_URL  payment-service base URL ('' = same origin)
#   CREDPAY_OIDC_AUTHORITY   Keycloak realm URL, e.g. https://example.com/auth/realms/credpay
#   CREDPAY_OIDC_CLIENT_ID   Keycloak client id
#   CREDPAY_AI_API_URL       ai-service base URL ('' = same origin, /api/ai)
#   CREDPAY_AIOPS_ENABLED    "true" shows the live Monitoring page
#   CREDPAY_GRAFANA_URL / CREDPAY_DYNATRACE_URL
#                            links on the Monitoring page (optional)
#
# A variable that is not set is left out, and the app falls back to its
# built-in default (src/config.js). /tmp is used so the container can run
# with a read-only root filesystem (mount an emptyDir at /tmp on Kubernetes).
# =====================================================================
set -eu

out_dir=/tmp/runtime
mkdir -p "$out_dir"

entry() {
  # $1 = JSON key, $2 = variable name; only emitted when the variable is set
  eval "is_set=\${$2+set}"
  if [ "$is_set" = "set" ]; then
    eval "value=\${$2}"
    case "$value" in
      *'"'* | *'\'* | *'<'*) echo "runtime-config: $2 contains an invalid character" >&2; exit 1 ;;
    esac
    printf '  "%s": "%s",\n' "$1" "$value"
  fi
}

{
  echo "window.__CREDPAY_CONFIG__ = {"
  entry userApiUrl CREDPAY_USER_API_URL
  entry paymentApiUrl CREDPAY_PAYMENT_API_URL
  entry oidcAuthority CREDPAY_OIDC_AUTHORITY
  entry oidcClientId CREDPAY_OIDC_CLIENT_ID
  entry aiApiUrl CREDPAY_AI_API_URL
  entry aiopsEnabled CREDPAY_AIOPS_ENABLED
  entry grafanaUrl CREDPAY_GRAFANA_URL
  entry dynatraceUrl CREDPAY_DYNATRACE_URL
  echo "};"
} > "$out_dir/config.js"

echo "runtime-config: wrote $out_dir/config.js"
