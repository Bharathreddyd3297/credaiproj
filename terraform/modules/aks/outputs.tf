output "cluster_name" {
  description = "AKS cluster name."
  value       = azurerm_kubernetes_cluster.this.name
}

output "cluster_id" {
  description = "AKS cluster resource ID."
  value       = azurerm_kubernetes_cluster.this.id
}

output "oidc_issuer_url" {
  description = "OIDC issuer URL for workload identity federation."
  value       = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "node_resource_group" {
  description = "Auto-managed node resource group."
  value       = azurerm_kubernetes_cluster.this.node_resource_group
}

output "ingress_public_ip" {
  description = "Static public IP for the ingress controller."
  value       = azurerm_public_ip.ingress.ip_address
}

output "ingress_public_ip_name" {
  description = "Name of the ingress public IP resource."
  value       = azurerm_public_ip.ingress.name
}
