#!/usr/bin/env bash
# =====================================================================
# Install pinned versions of terraform, kustomize and helm into
# ~/.local/bin (Linux agent). Versions come from the pipeline variables
# TERRAFORM_VERSION, KUSTOMIZE_VERSION, HELM_VERSION.
# =====================================================================
set -euo pipefail
bin="$HOME/.local/bin"
mkdir -p "$bin"
tmp="$(mktemp -d)"

curl -fsSL -o "$tmp/terraform.zip" \
  "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip"
unzip -oq "$tmp/terraform.zip" terraform -d "$bin"

curl -fsSL "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}/kustomize_${KUSTOMIZE_VERSION}_linux_amd64.tar.gz" \
  | tar -xz -C "$bin" kustomize

curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
  | tar -xz -C "$tmp" linux-amd64/helm
mv "$tmp/linux-amd64/helm" "$bin/helm"

rm -rf "$tmp"
echo "##vso[task.prependpath]$bin"
# sed, not head: head exits early and terraform dies of SIGPIPE (exit 141)
"$bin/terraform" version | sed -n 1p
"$bin/kustomize" version
"$bin/helm" version --short
