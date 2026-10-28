#!/usr/bin/env bash
# =====================================================================
# Decide which image tag to deploy for every service and write them as
# "service=registry/repo:tag" lines to $1.
#
#   1. the image the triggering CI run pushed (artifact image-<service>)
#   2. otherwise the newest tag in ACR - CI only pushes images that
#      passed every gate, so the newest tag is the last good build
#
#   scripts/cd/resolve-images.sh <out file> <artifacts dir> <acr name>
# =====================================================================
set -euo pipefail
out="${1:?out file}"
artifacts="${2:?artifacts dir}"
acr="${3:?acr name}"
login_server="$(az acr show --name "$acr" --query loginServer -o tsv)"

: > "$out"
# ai-service is optional: only environments with aiops enabled (prod) use it
for service in keycloak user-service payment-service customer-portal admin-portal ai-service; do
  file="$artifacts/image-$service/$service.txt"
  if [ -f "$file" ]; then
    image="$(cat "$file")"
    source="this CI run"
  else
    # Not --top 1: it returns nothing for some repositories
    tag="$(az acr repository show-tags --name "$acr" --repository "credpay/$service" \
             --orderby time_desc -o tsv 2>/dev/null | head -n 1 || true)"
    if [ -z "$tag" ] && [ "$service" = ai-service ]; then
      echo "##vso[task.logissue type=warning]No ai-service image in $acr yet - environments with AIOps need a CI run that builds it"
      continue
    fi
    if [ -z "$tag" ]; then
      echo "##vso[task.logissue type=error]No image for $service: not in this CI run and none in $acr"
      exit 1
    fi
    image="$login_server/credpay/$service:$tag"
    source="newest in ACR"
  fi
  echo "$service=$image" >> "$out"
  printf '  %-16s %-70s (%s)\n' "$service" "$image" "$source"
done
