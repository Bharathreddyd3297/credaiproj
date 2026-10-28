# =====================================================================
# PostgreSQL Flexible Server shared by all environments
#  - one database per app and environment (credpay_dev, keycloak_dev, ...)
#  - public access with TLS required; firewall allows Azure services only
# =====================================================================

# ----- Generated admin password (never hardcoded) -----
resource "random_password" "admin" {
  length           = 24
  special          = true
  override_special = "!#%&*()-_=+[]{}<>:?"
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
}

# ----- The server -----
resource "azurerm_postgresql_flexible_server" "this" {
  name                = "psql-${var.name_prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  version             = var.postgres_version

  # Public access (TLS + firewall). Private VNet access is a later phase.
  public_network_access_enabled = true

  administrator_login    = var.admin_username
  administrator_password = random_password.admin.result

  sku_name              = "B_Standard_B2s" # burstable, 2 vCPU, 4 GiB
  storage_mb            = 32768
  backup_retention_days = 7

  tags = var.tags

  lifecycle {
    ignore_changes = [zone] # Azure may relocate the primary zone; don't churn.
  }
}

# ----- Databases -----
resource "azurerm_postgresql_flexible_server_database" "this" {
  for_each = toset(var.database_names)

  name      = each.value
  server_id = azurerm_postgresql_flexible_server.this.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# ----- Enforce TLS for all client connections -----
resource "azurerm_postgresql_flexible_server_configuration" "require_ssl" {
  name      = "require_secure_transport"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "ON"
}

# ----- Firewall: allow connections from Azure services (incl. AKS egress) -----
# The special 0.0.0.0 rule means "any Azure-internal address" - simple for
# a dev/test setup. Production: private access in the postgres subnet.
resource "azurerm_postgresql_flexible_server_firewall_rule" "allow_azure" {
  name             = "AllowAzureServices"
  server_id        = azurerm_postgresql_flexible_server.this.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}
