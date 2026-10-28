# =====================================================================
# Azure Kubernetes Service
#  - System-assigned identity, Azure CNI + Azure network policy
#  - Entra ID login with Azure RBAC; local (certificate) accounts off
#  - OIDC issuer + Workload Identity (for later: Key Vault CSI driver)
#  - Autoscaling node pool, Container Insights
#  - Static public IP for the ingress controller
#  - Pull access to the container registry
# =====================================================================

data "azurerm_client_config" "current" {}

# Accepted risk (2026-10-23, review by 2027-01-31): the API server is
# reachable from any IP. Microsoft-hosted pipeline agents have changing
# IPs, so an allow-list needs a self-hosted agent or a private cluster
# (later phase). Access still requires Entra ID login + an Azure role.
#trivy:ignore:AZU-0041:exp:2027-01-31
resource "azurerm_kubernetes_cluster" "this" {
  name                = "aks-${var.name_prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = var.name_prefix

  # Separate, auto-managed RG for cluster infra (VMSS, disks, LBs, IPs).
  node_resource_group = "rg-${var.name_prefix}-aks-nodes"

  # Keep the cluster patched automatically on the stable channel.
  automatic_upgrade_channel = "stable"
  node_os_upgrade_channel   = "NodeImage"

  # Everyone signs in with Entra ID; access is granted with Azure roles
  # (see azurerm_role_assignment.cluster_admin below).
  local_account_disabled = true
  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
    tenant_id          = data.azurerm_client_config.current.tenant_id
  }

  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  default_node_pool {
    name                 = "system"
    vm_size              = var.vm_size
    auto_scaling_enabled = true
    min_count            = var.node_min_count
    max_count            = var.node_max_count
    vnet_subnet_id       = var.vnet_subnet_id
    os_sku               = "Ubuntu"
    max_pods             = 60
    type                 = "VirtualMachineScaleSets"

    upgrade_settings {
      max_surge = "33%"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin    = "azure"
    network_policy    = "azure"
    load_balancer_sku = "standard"
    # Internal IP ranges used by Kubernetes services (kept separate from
    # the VNet so they never overlap).
    service_cidr   = "10.240.0.0/16"
    dns_service_ip = "10.240.0.10"
  }

  # Container Insights -> Log Analytics.
  oms_agent {
    log_analytics_workspace_id = var.log_analytics_workspace_id
  }

  tags = var.tags

  lifecycle {
    # The autoscaler owns the node count at runtime - don't fight it.
    ignore_changes = [default_node_pool[0].node_count]
  }
}

# ----- User node pool: extra room, scaled from 0 by the autoscaler -----
resource "azurerm_kubernetes_cluster_node_pool" "user" {
  name                  = "user"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  mode                  = "User"
  vm_size               = var.user_vm_size
  auto_scaling_enabled  = true
  min_count             = 0
  max_count             = var.user_node_max_count
  vnet_subnet_id        = var.vnet_subnet_id
  os_sku                = "Ubuntu"
  max_pods              = 60

  upgrade_settings {
    max_surge = "33%"
  }

  tags = var.tags

  lifecycle {
    ignore_changes = [node_count]
  }
}

# ----- Nodes may pull images from the container registry -----
resource "azurerm_role_assignment" "acr_pull" {
  scope                            = var.acr_id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
  skip_service_principal_aad_check = true
}

# ----- Cluster admins (pipeline identity + listed people) -----
resource "azurerm_role_assignment" "cluster_admin" {
  for_each = var.admin_object_ids

  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = each.value
}

# ----- Static public IP for the ingress controller -----
# Lives in the node resource group, where AKS may attach it to its load
# balancer. Static: it survives reinstalling the ingress controller, so
# DNS records (GoDaddy later) keep pointing at the right address.
resource "azurerm_public_ip" "ingress" {
  name                = "pip-${var.name_prefix}-ingress"
  resource_group_name = azurerm_kubernetes_cluster.this.node_resource_group
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}
