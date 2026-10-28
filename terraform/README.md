# CredPay - Terraform (Azure infrastructure)

Applied by the CD pipeline (`pipelines/credpay-cd.yml`, stage *Infra*): `terraform
plan` runs on every deployment and `apply` runs only when the plan has changes.
See [docs/CD-PIPELINE.md](../docs/CD-PIPELINE.md).

## What it creates

| Resource | Name | Notes |
| --- | --- | --- |
| Resource group | `rg-credpay` | |
| Virtual network | `vnet-credpay` | subnets `snet-aks` (10.0.0.0/20), `snet-postgres` (reserved) |
| Log Analytics | `log-credpay` | Container Insights for AKS |
| PostgreSQL Flexible Server 17 | `psql-credpay` | databases `credpay_<env>`, `keycloak_<env>` per environment; TLS required |
| AKS | `aks-credpay` | system pool 2-5 × Standard_D2alds_v6, user pool 0-4 × Standard_D2s_v6 (autoscaling), Entra ID login + Azure RBAC, no local accounts |
| Public IP | `pip-credpay-ingress` | static, in the node resource group; used by the Traefik ingress |
| Role assignments | | AKS nodes → `AcrPull` on `creddemoacr`; admins → AKS cluster admin, Key Vault Secrets Officer |
| Key Vault | `kv-credpay-3297` | `postgres-host/-username/-password`, `keycloak-admin-username/-password`, `grafana-admin-password` |

Not created here (shared, made by hand): the container registry `creddemoacr`
and the Terraform state storage (`rg-credpay-tfstate` / `credpaytfstate3297`,
created by `scripts/cd/bootstrap-tfstate.sh`).

Admins = the identity running Terraform (the pipeline's service connection) plus
`admin_object_ids` (the pipeline passes the instructor's object ID).

## Layout

```
terraform/
  backend.tf     remote state (Azure Storage)
  provider.tf    azurerm - credentials from ARM_* environment variables / az login
  versions.tf    Terraform >= 1.9, azurerm 4.x, random, time
  .terraform.lock.hcl   exact provider versions (committed)
  variables.tf   every input, with the defaults the pipeline uses
  main.tf        composes the modules
  outputs.tf     read by the pipeline (terraform output -json)
  modules/       resource-group, networking, monitoring, postgres, aks, keyvault
```

## Run it from a laptop

```bash
az login
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
cd terraform
terraform init
terraform plan          # what would change
```

Prefer the pipeline for `apply`, so that only one place changes the
infrastructure. To add yourself as an admin, put your object ID
(`az ad signed-in-user show --query id -o tsv`) in `terraform.tfvars` (see
`terraform.tfvars.example`; the real file is git-ignored).

## Accepted findings (Trivy)

Two checks are suppressed in the code with an expiry date (`#trivy:ignore`):
AKS API server and Key Vault accept connections from any IP (`AZU-0041`,
`AZU-0013`). Microsoft-hosted pipeline agents have changing IPs; closing this
needs a self-hosted agent or private endpoints (later phase). Access still
requires Entra ID login and an Azure role.
