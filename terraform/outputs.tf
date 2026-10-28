# =====================================================================
# CredPay - Root outputs (read by the CD pipeline: terraform output -json)
# =====================================================================

output "resource_group_name" {
  description = "Resource group holding the CredPay resources."
  value       = module.resource_group.name
}

output "aks_cluster_name" {
  description = "AKS cluster name."
  value       = module.aks.cluster_name
}

output "ingress_public_ip" {
  description = "Static public IP of the ingress controller (point DNS records here)."
  value       = module.aks.ingress_public_ip
}

output "ingress_public_ip_name" {
  description = "Name of that IP resource (the ingress controller's Service refers to it)."
  value       = module.aks.ingress_public_ip_name
}

output "aks_node_resource_group" {
  description = "Auto-managed node resource group (MC_...), also holds the ingress IP."
  value       = module.aks.node_resource_group
}

output "acr_login_server" {
  description = "Registry the cluster pulls images from."
  value       = data.azurerm_container_registry.acr.login_server
}

output "key_vault_name" {
  description = "Key Vault with the database and Keycloak admin credentials."
  value       = module.keyvault.name
}

output "postgres_fqdn" {
  description = "PostgreSQL server FQDN."
  value       = module.postgres.fqdn
}

output "postgres_databases" {
  description = "Databases created on the server."
  value       = module.postgres.database_names
}

output "get_credentials_command" {
  description = "Connect kubectl to the cluster (Entra ID login via kubelogin)."
  value       = "az aks get-credentials --resource-group ${module.resource_group.name} --name ${module.aks.cluster_name} --overwrite-existing && kubelogin convert-kubeconfig -l azurecli"
}
