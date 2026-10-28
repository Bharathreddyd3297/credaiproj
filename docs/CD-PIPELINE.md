# CREDPAY - CD Pipeline (Azure DevOps)

`pipelines/credpay-cd.yml` creates the Azure infrastructure with Terraform, installs the
cluster platform (ingress, certificates, observability) and deploys the images that CI
built - to **dev, then qa, then prod**. It starts automatically when **credpay-ci**
succeeds on `main`.

```
credpay-ci (images in ACR) ──► credpay-cd
   Infra     state storage (created once) → terraform plan
             → terraform apply only if the plan has changes
   Platform  Traefik + cert-manager
             Prometheus / Alertmanager / Grafana            (always)
             alerts to Slack, Dynatrace Operator            (when their Key Vault secrets exist)
   DEV       Key Vault → Kubernetes Secrets → helm upgrade charts/credpay → smoke tests
             publishes the image list ("images" artifact)
   QA        [approval] → the SAME images → helm upgrade → smoke tests
   PROD      [approval] → the SAME images + monitoring, AIOps, Dynatrace → smoke tests
```

| Path | Purpose |
| --- | --- |
| `pipelines/credpay-cd.yml` | The pipeline: stages, chart/tool versions, domain, certificate issuer |
| `pipelines/templates/deploy-env.yml` | One environment's deployment (used for dev, qa, prod) |
| `charts/credpay` | The application as a Helm chart, `values-<env>.yaml` per environment ([k8s/README](../k8s/README.md)) |
| `terraform/` | AKS, PostgreSQL (databases per environment), Key Vault, Log Analytics, ingress IP ([README](../terraform/README.md)) |
| `k8s/platform` | Cluster add-ons: Traefik, cert-manager, issuers, monitoring, Dynatrace |
| `scripts/cd/` | The pipeline steps as plain scripts (readable, runnable by hand) |

---

## Build once, promote

The **dev** stage decides the image of every service - the image the triggering CI run
pushed, otherwise the newest image in ACR (CI only pushes images that passed every gate) -
and publishes that list as the artifact **`images`**. **qa** and **prod** download it and
deploy exactly those tags, so prod never gets an image that was not tested in dev and qa,
even when CI pushes something newer in between.

```bash
helm history credpay -n credpay-prod      # which release (and images) is live
helm rollback credpay <revision> -n credpay-prod
```

`helm upgrade --atomic` rolls a failed release back automatically.

## Environments and approvals

| Environment | Namespace | Values | Gets |
| --- | --- | --- | --- |
| dev | `credpay-dev` | `values-dev.yaml` | every merge to main, automatically |
| qa | `credpay-qa` | `values-qa.yaml` | after dev's smoke tests (+ approval, if configured) |
| prod | `credpay-prod` | `values-prod.yaml` | after qa (+ approval): 2+ replicas, autoscaling (HPA), disruption budgets, monitoring, AIOps |

Approvals live in Azure DevOps, not in YAML: **Pipelines → Environments → credpay-prod →
⋯ → Approvals and checks → Approvals** (add yourself; optionally *Business hours*). Do the
same for `credpay-qa` if you want a person to start qa. The stage then waits, and the run
shows *Waiting for approval*.

All three namespaces share one AKS cluster and one PostgreSQL server (databases
`credpay_<env>`, `keycloak_<env>`), and each has its own Keycloak - so each has its own
users. The cluster autoscaler adds nodes when the three environments, monitoring and
Dynatrace need them: the system pool runs 2 → up to 5 nodes (`Standard_D2alds_v6`, 4 GiB),
then the user pool 0 → up to 4 (`Standard_D2s_v6`, 8 GiB). Two VM families, because each
family has its own vCPU quota (10 by default) in the subscription.

## "Skip if the infrastructure already exists"

Terraform decides, not the pipeline: `terraform plan -detailed-exitcode` compares
the code with what exists in Azure.

| Plan exit code | Meaning | Pipeline |
| --- | --- | --- |
| 0 | Azure already matches the code | apply step **skipped** |
| 2 | Something is missing or different (first run, a changed `.tf` file, drift) | apply runs |
| 1 | Error | stage fails |

The plan (`tfplan.txt`) and the outputs are published as the `terraform-<attempt>` artifact.

## URLs

Until a real domain is attached, the hosts are built from the ingress IP with
[sslip.io](https://sslip.io) (`20-48-1-2.sslip.io` resolves to `20.48.1.2`):

| | URL (`<env>` = dev, qa, prod) |
| --- | --- |
| Customer portal | `https://<env>.<ip-with-dashes>.sslip.io` |
| Admin portal | `https://admin.<env>.<ip-with-dashes>.sslip.io` (prod: Monitoring page with AIOps) |
| Keycloak | `https://auth.<env>.<ip-with-dashes>.sslip.io` (admin console: `/admin`) |
| Grafana | `https://grafana.<ip-with-dashes>.sslip.io` (user `admin`, password: Key Vault `grafana-admin-password`) |

The exact URLs are printed at the end of each *Deploy (helm) and smoke test* step. The
ingress IP is static (Terraform output `ingress_public_ip`), so it survives
redeployments.

**HTTPS is required**: the portals' login (PKCE) uses browser crypto APIs that
only exist on HTTPS pages, and Keycloak refuses plain HTTP on public addresses.

### Certificates (pipeline variable `tlsIssuer`)

| Value | Result |
| --- | --- |
| `letsencrypt-prod` (default) | Trusted certificate. Let's Encrypt allows 50 certificates a week per domain, and **sslip.io is shared by everyone** - if issuance fails, the run shows a warning and continues. |
| `letsencrypt-staging` | Same flow, untrusted test certificate - for checking the setup. |
| `selfsigned` | No Let's Encrypt; browsers show a warning to click through (once for the portal, once for `auth.`). |

### Moving to your own domain (GoDaddy)

1. GoDaddy DNS: one wildcard `A` record `*` (or records `dev`, `admin.dev`, `auth.dev`,
   the same for `qa` and `prod`, and `grafana`) pointing to the ingress IP.
2. `pipelines/credpay-cd.yml`: set `baseDomain` to your domain.
3. Run the pipeline. New certificates are issued for the new hosts. Keycloak's
   realm keeps its old redirect URLs (it is imported only once): update the two
   clients in the admin console, or delete the realm and restart Keycloak.

## Secrets

Terraform generates the PostgreSQL, Keycloak admin and Grafana admin passwords and stores
them in Key Vault. The pipeline reads them and creates Kubernetes Secrets (`credpay-db`,
`keycloak-admin`, `grafana-admin`). Nothing secret is in Git, in the pipeline YAML or in
Helm values. Keycloak admin login: Key Vault `keycloak-admin-username` /
`keycloak-admin-password`.

**Optional integrations** are switched on by adding their secrets to the same Key Vault -
no code or pipeline change (`scripts/cd/read-optional-secrets.sh`; details in
[OBSERVABILITY.md](OBSERVABILITY.md#what-to-add-to-key-vault)):

| Key Vault secrets | Switches on |
| --- | --- |
| `azure-openai-endpoint`, `azure-openai-key`, `azure-openai-deployment` | AI-written briefings in the admin portal (prod) |
| `dynatrace-url`, `dynatrace-api-token`, `dynatrace-data-ingest-token` (+ `dynatrace-problems-token`) | Dynatrace Operator + OneAgent, Dynatrace problems in the admin portal |
| `slack-webhook-url` | all CREDPAY alerts (and resolutions) to a Slack channel |

## One-time setup in Azure DevOps

1. Service connection **sc-new** (Azure Resource Manager, workload identity
   federation) with **Owner** on the subscription: Terraform creates role
   assignments (AKS pulls from ACR, cluster admin, Key Vault access).
2. Pipelines → New pipeline → Azure Repos Git → `credwithaiops` → Existing YAML
   file → `/pipelines/credpay-cd.yml` → Save, rename it **credpay-cd**.
3. The CI pipeline must be named **credpay-ci** (the CD trigger refers to it).
4. Pipelines → Environments: **credpay-dev**, **credpay-qa**, **credpay-prod** are created
   on the first run; add the approvals (above).

## Destroy (save money between classes)

Run `credpay-cd` manually and tick **Destroy all Azure infrastructure**. It
removes the ingress controller first (to release the static IP), then runs
`terraform destroy`. The state storage account and the ACR are kept. The next
normal run creates everything again (about 20-30 minutes).

Key Vault secrets you added by hand (OpenAI, Dynatrace, Slack) are deleted with the
vault - add them again before the next run, or keep a copy in a password manager.

### If a destroy fails

* **AKS delete fails with `OperationNotAllowed ... Rolling Upgrade in progress`**:
  Azure sometimes starts a platform "VM Agent Rolling Upgrade" on the node VM
  scale set, and deleting is blocked until it ends. Check
  `az vmss rolling-upgrade get-latest -g rg-credpay-aks-nodes -n <vmss>` and run
  the destroy again once it shows `Completed`.
* **The job was abandoned** (hosted agents in private projects stop after 60
  minutes) and the next run waits on *"Error acquiring the state lock"*: make
  sure no other credpay-cd run is active, then release the lock:
  `az storage blob lease break --account-name credpaytfstate3297 -c tfstate -b credpay.tfstate`.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| *Error: … rendered manifests contain a resource that already exists* | An object without Helm's labels: `deploy-app.sh` adopts the known ones; for another object, delete it or label it (`app.kubernetes.io/managed-by=Helm`, annotations `meta.helm.sh/release-name=credpay`, `meta.helm.sh/release-namespace=<ns>`) |
| `helm upgrade` fails with *timed out waiting for the condition* and rolls back | A pod did not get ready: `kubectl get pods -n credpay-<env>`, `kubectl describe pod …`, `kubectl logs …`. The previous release keeps running. |
| QA: *Artifact images not found* | The dev stage of the same run failed or was skipped - qa only promotes what dev deployed |
| Pods `Pending` (*Insufficient memory*) | The autoscaler is adding a node (a few minutes): the system pool grows to 5 nodes, then the **user** pool (`Standard_D2s_v6`, 0-4 nodes) |
| Pod events say *didn't trigger scale-up: in backoff after failed scale-up* | Azure refused a new VM - usually the subscription's **vCPU quota** for that VM family (10 by default). Check: `az vm list-usage -l canadacentral -o table` (look for *Family vCPUs* at its limit); request more under Subscriptions → Usage + quotas, or use another VM family (`vm_size` / `user_vm_size` in `terraform/variables.tf`) |
| Grafana certificate not issued | Same Let's Encrypt limits as the portals - see *Certificates* |
| Platform: *Dynatrace … invalid token* | Check the token scopes in [OBSERVABILITY.md](OBSERVABILITY.md#dynatrace) |
