#!/usr/bin/env bash
# =====================================================================
# Point kubectl at the AKS cluster as the pipeline identity.
#   scripts/cd/aks-login.sh <resource group> <cluster name>
# The cluster only accepts Entra ID logins (local accounts are off), so
# kubelogin turns the az CLI sign-in into a Kubernetes token.
# =====================================================================
set -euo pipefail
rg="${1:?resource group}"
cluster="${2:?cluster name}"

if ! command -v kubelogin >/dev/null; then
  echo "Installing kubectl + kubelogin"
  mkdir -p "$HOME/.local/bin"
  az aks install-cli --install-location "$HOME/.local/bin/kubectl" \
    --kubelogin-install-location "$HOME/.local/bin/kubelogin" -o none
  echo "##vso[task.prependpath]$HOME/.local/bin"
  export PATH="$HOME/.local/bin:$PATH"
fi

az aks get-credentials --resource-group "$rg" --name "$cluster" --overwrite-existing -o none
kubelogin convert-kubeconfig -l azurecli
kubectl version
kubectl get nodes -o wide
