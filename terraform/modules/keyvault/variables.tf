variable "name" {
  type        = string
  description = "Key Vault name (globally unique, 3-24 characters)."
}

variable "resource_group_name" {
  type        = string
  description = "Resource group name."
}

variable "location" {
  type        = string
  description = "Azure region."
}

variable "tenant_id" {
  type        = string
  description = "Entra ID tenant of the vault."
}

variable "admin_object_ids" {
  type        = set(string)
  description = "Entra ID object IDs that may manage the secrets."
}

variable "secrets" {
  type        = map(string)
  description = "Secret name -> value."
  sensitive   = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
