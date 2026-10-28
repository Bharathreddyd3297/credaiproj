# =====================================================================
# CredPay - Provider configuration
# =====================================================================
# No credentials in code. The subscription and identity come from the
# environment:
#   Pipeline: ARM_SUBSCRIPTION_ID, ARM_TENANT_ID, ARM_CLIENT_ID,
#             ARM_USE_OIDC=true, ARM_OIDC_TOKEN (workload identity
#             federation of the sc-new service connection - no secret)
#   Laptop:   az login
#             export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
# =====================================================================
provider "azurerm" {
  features {
    resource_group {
      # AKS creates a ContainerInsights solution in rg-credpay by itself
      # (monitoring add-on), outside Terraform. rg-credpay holds only
      # CredPay resources, so destroy may delete the group with it.
      prevent_deletion_if_contains_resources = false
    }
    key_vault {
      # Destroy really deletes the vault, so the same name can be
      # created again on the next apply (otherwise it stays soft-deleted)
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }
  }
}

provider "random" {}
