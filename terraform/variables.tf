# =====================================================================
# CredPay - Input variables (defaults are the values the pipeline uses)
# =====================================================================

# Azure region
variable "location" {
  type    = string
  default = "canadacentral"
}

# Added to every resource name, e.g. rg-credpay, aks-credpay
variable "name_prefix" {
  type    = string
  default = "credpay"
}

# Application environments that share this cluster and database server.
# Each one gets its own namespace (credpay-<env>) and databases
# (credpay_<env>, keycloak_<env>). The CD pipeline deploys dev -> qa -> prod.
variable "environments" {
  type    = list(string)
  default = ["dev", "qa", "prod"]
}

# People (Entra ID object IDs) who get cluster-admin on AKS and can
# manage Key Vault secrets, in addition to the identity running
# Terraform. Find yours: az ad signed-in-user show --query id -o tsv
variable "admin_object_ids" {
  type    = list(string)
  default = []
}

# ----- Networking -----

variable "vnet_address_space" {
  type    = string
  default = "10.0.0.0/16"
}

variable "aks_subnet_prefix" {
  type    = string
  default = "10.0.0.0/20"
}

# Reserved for PostgreSQL private access in a later phase
variable "postgres_subnet_prefix" {
  type    = string
  default = "10.0.16.0/24"
}

# ----- AKS -----

variable "vm_size" {
  type    = string
  default = "Standard_D2alds_v6" # 2 vCPU, 4 GiB
}

variable "node_min_count" {
  type    = number
  default = 2
}

# System pool: 2 nodes at rest, up to 5 when busy. 5 x 2 vCPU is also the
# subscription's default quota for this VM family (10 vCPUs) - more nodes
# of this size are refused by Azure.
variable "node_max_count" {
  type    = number
  default = 5
}

# User pool: extra room when the system pool is full (three environments,
# monitoring and the Dynatrace agents need more than 5 x 4 GiB). Another
# VM family, so it has its own vCPU quota; 0 nodes (no cost) when idle.
variable "user_vm_size" {
  type    = string
  default = "Standard_D2s_v6" # 2 vCPU, 8 GiB
}

variable "user_node_max_count" {
  type    = number
  default = 4
}

# ----- Container registry (created outside Terraform, shared with CI) -----

variable "acr_name" {
  type    = string
  default = "creddemoacr"
}

variable "acr_resource_group_name" {
  type    = string
  default = "CredInfra-RG"
}

# ----- PostgreSQL -----

variable "postgres_version" {
  type    = string
  default = "17" # same major version as infra/docker-compose.yml
}

variable "postgres_admin_username" {
  type    = string
  default = "credpayadmin"
}

# ----- Monitoring -----

variable "log_retention_days" {
  type    = number
  default = 30
}

# ----- Key Vault -----

# Globally unique, 3-24 characters
variable "key_vault_name" {
  type    = string
  default = "kv-credpay-3297"
}
