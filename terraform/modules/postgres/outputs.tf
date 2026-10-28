output "server_id" {
  description = "PostgreSQL Flexible Server resource ID."
  value       = azurerm_postgresql_flexible_server.this.id
}

output "server_name" {
  description = "PostgreSQL Flexible Server name."
  value       = azurerm_postgresql_flexible_server.this.name
}

output "fqdn" {
  description = "Public FQDN of the server."
  value       = azurerm_postgresql_flexible_server.this.fqdn
}

output "database_names" {
  description = "Databases created on the server."
  value       = sort([for db in azurerm_postgresql_flexible_server_database.this : db.name])
}

output "admin_username" {
  description = "Administrator username."
  value       = azurerm_postgresql_flexible_server.this.administrator_login
}

output "admin_password" {
  description = "Generated administrator password."
  value       = random_password.admin.result
  sensitive   = true
}
