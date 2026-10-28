#!/usr/bin/env bash
# =====================================================================
# Source this inside an AzureCLI@2 task (addSpnToEnvironment: true) to
# let Terraform sign in as the service connection's identity with
# workload identity federation (OIDC) - no client secret anywhere.
#   source scripts/cd/terraform-env.sh
# =====================================================================
export ARM_CLIENT_ID="$servicePrincipalId"
export ARM_TENANT_ID="$tenantId"
export ARM_OIDC_TOKEN="$idToken"
export ARM_USE_OIDC=true
ARM_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
export ARM_SUBSCRIPTION_ID
export TF_IN_AUTOMATION=true
export TF_INPUT=false
