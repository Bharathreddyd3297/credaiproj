# =====================================================================
# CredPay - Root module: all Azure infrastructure for the app
# =====================================================================
# One AKS cluster and one PostgreSQL server are shared by the
# environments in var.environments (namespace and databases per env).
# The CD pipeline runs `terraform plan` on every deployment and only
# applies when something changed - see pipelines/credpay-cd.yml.
# =====================================================================

locals {
  tags = {
    project    = "credpay"
    managed_by = "terraform"
  }

  # The identity running Terraform (pipeline service principal or the
  # signed-in user) plus the listed people
  admin_object_ids = toset(concat([data.azurerm_client_config.current.object_id], var.admin_object_ids))
}

data "azurerm_client_config" "current" {}

# Created outside Terraform (CI pushes images to it)
data "azurerm_container_registry" "acr" {
  name                = var.acr_name
  resource_group_name = var.acr_resource_group_name
}

# ---------------------------------------------------------------------
# 1. Resource group
# ---------------------------------------------------------------------
module "resource_group" {
  source = "./modules/resource-group"

  name     = "rg-${var.name_prefix}"
  location = var.location
  tags     = local.tags
}

# ---------------------------------------------------------------------
# 2. Networking (VNet + subnets)
# ---------------------------------------------------------------------
module "networking" {
  source = "./modules/networking"

  name_prefix            = var.name_prefix
  resource_group_name    = module.resource_group.name
  location               = module.resource_group.location
  vnet_address_space     = var.vnet_address_space
  aks_subnet_prefix      = var.aks_subnet_prefix
  postgres_subnet_prefix = var.postgres_subnet_prefix
  tags                   = local.tags
}

# ---------------------------------------------------------------------
# 3. Monitoring (Log Analytics for Container Insights)
# ---------------------------------------------------------------------
module "monitoring" {
  source = "./modules/monitoring"

  name_prefix         = var.name_prefix
  resource_group_name = module.resource_group.name
  location            = module.resource_group.location
  retention_days      = var.log_retention_days
  tags                = local.tags
}

# ---------------------------------------------------------------------
# 4. PostgreSQL Flexible Server: credpay_<env> + keycloak_<env> databases
# ---------------------------------------------------------------------
module "postgres" {
  source = "./modules/postgres"

  name_prefix         = var.name_prefix
  resource_group_name = module.resource_group.name
  location            = module.resource_group.location
  admin_username      = var.postgres_admin_username
  postgres_version    = var.postgres_version
  database_names      = flatten([for env in var.environments : ["credpay_${env}", "keycloak_${env}"]])
  tags                = local.tags
}

# ---------------------------------------------------------------------
# 5. AKS + static public IP for the ingress controller + ACR pull
# ---------------------------------------------------------------------
module "aks" {
  source = "./modules/aks"

  name_prefix                = var.name_prefix
  resource_group_name        = module.resource_group.name
  location                   = module.resource_group.location
  vm_size                    = var.vm_size
  node_min_count             = var.node_min_count
  node_max_count             = var.node_max_count
  user_vm_size               = var.user_vm_size
  user_node_max_count        = var.user_node_max_count
  vnet_subnet_id             = module.networking.subnet_ids["aks"]
  log_analytics_workspace_id = module.monitoring.workspace_id
  acr_id                     = data.azurerm_container_registry.acr.id
  admin_object_ids           = local.admin_object_ids
  tags                       = local.tags
}

# ---------------------------------------------------------------------
# 6. Key Vault: database + Keycloak admin credentials for the pipeline
# ---------------------------------------------------------------------
resource "random_password" "keycloak_admin" {
  length      = 24
  special     = false # letters and digits only: no quoting problems in scripts
  min_lower   = 2
  min_upper   = 2
  min_numeric = 2
}

# Grafana's admin login (user "admin"), https://grafana.<domain>
resource "random_password" "grafana_admin" {
  length      = 24
  special     = false
  min_lower   = 2
  min_upper   = 2
  min_numeric = 2
}

module "keyvault" {
  source = "./modules/keyvault"

  name                = var.key_vault_name
  resource_group_name = module.resource_group.name
  location            = module.resource_group.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  admin_object_ids    = local.admin_object_ids
  tags                = local.tags

  secrets = {
    "postgres-host"           = module.postgres.fqdn
    "postgres-username"       = module.postgres.admin_username
    "postgres-password"       = module.postgres.admin_password
    "keycloak-admin-username" = "credpay-admin"
    "keycloak-admin-password" = random_password.keycloak_admin.result
    "grafana-admin-password"  = random_password.grafana_admin.result
  }
  # Optional integrations are added by hand, not by Terraform (their
  # values come from outside Azure) - docs/OBSERVABILITY.md:
  #   azure-openai-endpoint/-key/-deployment, dynatrace-url/-api-token/
  #   -data-ingest-token, slack-webhook-url
}
