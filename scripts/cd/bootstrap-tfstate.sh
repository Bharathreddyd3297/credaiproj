#!/usr/bin/env bash
# =====================================================================
# Create the Terraform state storage if it does not exist yet.
# Terraform cannot create the storage its own state lives in, so this
# runs before `terraform init`. Safe to run every time: existing
# resources are left as they are. Names must match terraform/backend.tf.
# Needs: az CLI signed in (AzureCLI@2 task).
# =====================================================================
set -euo pipefail

rg="rg-credpay-tfstate"
account="credpaytfstate3297"
container="tfstate"
location="${LOCATION:-canadacentral}"

if [ "$(az group exists --name "$rg")" = "true" ]; then
  echo "Resource group $rg exists"
else
  echo "Creating resource group $rg"
  az group create --name "$rg" --location "$location" --tags project=credpay purpose=terraform-state -o none
fi

if az storage account show --name "$account" --resource-group "$rg" -o none 2>/dev/null; then
  echo "Storage account $account exists"
else
  echo "Creating storage account $account"
  az storage account create --name "$account" --resource-group "$rg" --location "$location" \
    --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 \
    --allow-blob-public-access false --https-only true -o none
  # Keep old state versions: a bad apply can be rolled back
  az storage account blob-service-properties update --account-name "$account" --resource-group "$rg" \
    --enable-versioning true --enable-delete-retention true --delete-retention-days 14 -o none
fi

key=$(az storage account keys list --account-name "$account" --resource-group "$rg" --query "[0].value" -o tsv)
if [ "$(az storage container exists --name "$container" --account-name "$account" --account-key "$key" --query exists -o tsv)" = "true" ]; then
  echo "Container $container exists"
else
  echo "Creating container $container"
  az storage container create --name "$container" --account-name "$account" --account-key "$key" -o none
fi
