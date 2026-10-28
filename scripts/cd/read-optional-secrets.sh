#!/usr/bin/env bash
# =====================================================================
# Read the OPTIONAL integration settings from Key Vault and expose them
# as pipeline variables. A missing secret simply leaves that feature off,
# so the pipeline works before any account (OpenAI, Dynatrace, Slack)
# is connected. Add them later with:
#   az keyvault secret set --vault-name <kv> --name <name> --value <value>
#
#   scripts/cd/read-optional-secrets.sh <key vault name>
#
# Key Vault secret            -> pipeline variable (secret = masked in logs)
#   azure-openai-endpoint        OPENAI_ENDPOINT
#   azure-openai-key             OPENAI_KEY            (secret)
#   azure-openai-deployment      OPENAI_DEPLOYMENT
#   dynatrace-url                DYNATRACE_URL         e.g. https://abc12345.live.dynatrace.com
#   dynatrace-api-token          DYNATRACE_API_TOKEN   (secret)
#   dynatrace-data-ingest-token  DYNATRACE_INGEST_TOKEN (secret)
#   dynatrace-problems-token     DYNATRACE_PROBLEMS_TOKEN (secret, optional) read-only token
#                                                      (problems.read) for the admin portal
#   slack-webhook-url            SLACK_WEBHOOK_URL     (secret) Slack Incoming Webhook for alerts
# Also sets DYNATRACE_ENABLED / SLACK_ENABLED / OPENAI_ENABLED = true|false.
# =====================================================================
set -euo pipefail
kv="${1:?usage: read-optional-secrets.sh <key vault name>}"

read_secret() { # <secret name> <variable> <secret: true|false>
  local value
  value="$(az keyvault secret show --vault-name "$kv" --name "$1" --query value -o tsv 2>/dev/null || true)"
  echo "##vso[task.setvariable variable=$2;issecret=$3]$value"
  # for this step's own summary below
  printf -v "$2" '%s' "$value"
}

read_secret azure-openai-endpoint       OPENAI_ENDPOINT        false
read_secret azure-openai-key            OPENAI_KEY             true
read_secret azure-openai-deployment     OPENAI_DEPLOYMENT      false
read_secret dynatrace-url               DYNATRACE_URL          false
read_secret dynatrace-api-token         DYNATRACE_API_TOKEN    true
read_secret dynatrace-data-ingest-token DYNATRACE_INGEST_TOKEN true
read_secret dynatrace-problems-token    DYNATRACE_PROBLEMS_TOKEN true
read_secret slack-webhook-url           SLACK_WEBHOOK_URL      true

flag() { # <variable> <true|false>
  echo "##vso[task.setvariable variable=$1]$2"
  printf '  %-18s %s\n' "$1" "$2"
}
echo "Optional integrations (Key Vault $kv):"
flag OPENAI_ENABLED    "$([ -n "$OPENAI_ENDPOINT" ] && [ -n "$OPENAI_KEY" ] && [ -n "$OPENAI_DEPLOYMENT" ] && echo true || echo false)"
flag DYNATRACE_ENABLED "$([ -n "$DYNATRACE_URL" ] && [ -n "$DYNATRACE_API_TOKEN" ] && [ -n "$DYNATRACE_INGEST_TOKEN" ] && echo true || echo false)"
flag SLACK_ENABLED     "$([ -n "$SLACK_WEBHOOK_URL" ] && echo true || echo false)"
