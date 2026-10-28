# Name added to the resources
variable "name_prefix" {
  type = string
}

# Resource group name
variable "resource_group_name" {
  type = string
}

# Azure region
variable "location" {
  type = string
}

# PostgreSQL admin username
variable "admin_username" {
  type = string
}

# Databases to create, e.g. ["credpay_dev", "keycloak_dev"]
variable "database_names" {
  type = list(string)
}

# PostgreSQL major version
variable "postgres_version" {
  type = string
}

# Tags to apply
variable "tags" {
  type    = map(string)
  default = {}
}
