# =====================================================================
# Key Vault - credentials the CD pipeline needs to configure the apps
# =====================================================================
# Access is controlled with Azure RBAC (no access policies). The admins
# (pipeline identity + listed people) get "Key Vault Secrets Officer".
# The pipeline reads the secrets with the AzureKeyVault@2 task and turns
# them into Kubernetes Secrets. (Later phase: Key Vault CSI driver with
# Workload Identity, so the secrets never pass through the pipeline.)
# =====================================================================

# Accepted risk (2026-10-23, review by 2027-01-31): no network rules, for
# the same reason as the AKS API server (Microsoft-hosted agents). Every
# request still needs Entra ID login + the Key Vault Secrets Officer role.
#trivy:ignore:AZU-0013:exp:2027-01-31
resource "azurerm_key_vault" "this" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  tenant_id           = var.tenant_id
  sku_name            = "standard"

  rbac_authorization_enabled = true
  soft_delete_retention_days = 7
  purge_protection_enabled   = false # dev: allow destroy + recreate with the same name

  tags = var.tags
}

resource "azurerm_role_assignment" "secrets_officer" {
  for_each = var.admin_object_ids

  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = each.value
}

# New role assignments take a minute or two to reach Key Vault; writing
# secrets straight away fails with 403 Forbidden.
resource "time_sleep" "rbac_propagation" {
  depends_on      = [azurerm_role_assignment.secrets_officer]
  create_duration = "90s"
}

resource "azurerm_key_vault_secret" "this" {
  # Only the names are used as keys; the values stay sensitive
  for_each = toset(nonsensitive(keys(var.secrets)))

  name         = each.value
  value        = var.secrets[each.value]
  key_vault_id = azurerm_key_vault.this.id

  depends_on = [time_sleep.rbac_propagation]
}
