variable "name_prefix" {
  description = "Naming prefix."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group name."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "node_min_count" {
  description = "Autoscaler minimum node count."
  type        = number
}

variable "node_max_count" {
  description = "Autoscaler maximum node count."
  type        = number
}

variable "vm_size" {
  description = "Node VM size."
  type        = string
}

variable "user_vm_size" {
  description = "VM size of the autoscaling user node pool."
  type        = string
}

variable "user_node_max_count" {
  description = "Autoscaler maximum node count of the user pool (minimum 0)."
  type        = number
}

variable "vnet_subnet_id" {
  description = "Subnet ID for AKS nodes/pods."
  type        = string
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID for Container Insights."
  type        = string
}

variable "acr_id" {
  description = "Container registry the nodes pull images from."
  type        = string
}

variable "admin_object_ids" {
  description = "Entra ID object IDs that get cluster-admin (Azure RBAC)."
  type        = set(string)
}

variable "tags" {
  description = "Tags to apply."
  type        = map(string)
  default     = {}
}
