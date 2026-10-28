# =====================================================================
# Remote state in Azure Storage
# =====================================================================
# Terraform cannot create the storage that holds its own state, so the
# CD pipeline creates it first (scripts/cd/bootstrap-tfstate.sh - safe
# to run every time). Same names there and here.
# =====================================================================
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-credpay-tfstate"
    storage_account_name = "credpaytfstate3297"
    container_name       = "tfstate"
    key                  = "credpay.tfstate"
  }
}
