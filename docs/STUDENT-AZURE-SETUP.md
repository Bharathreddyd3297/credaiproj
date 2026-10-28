# CREDPAY - Deploy Everything in Your Own Azure Account

This guide takes you from an empty Azure subscription to the complete CREDPAY platform:
CI/CD in Azure DevOps, AKS with dev → qa → prod, SonarQube, Slack alerts, Dynatrace and the
AI assistant (Azure OpenAI). Do the parts **in order** - each one needs the one before it.

| Part | What you do | Time |
| --- | --- | --- |
| [1](#part-1---prepare-your-tools) | Install the command-line tools | 15 min |
| [2](#part-2---get-the-code-into-your-azure-devops-project) | Get the code into your Azure DevOps project | 10 min |
| [3](#part-3---make-the-names-unique) | Make the global names unique (one suffix) | 10 min |
| [4](#part-4---create-the-container-registry-acr) | Create the container registry (ACR) | 5 min |
| [5](#part-5---create-the-sonarqube-server) | Create the SonarQube server | 20 min |
| [6](#part-6---create-the-service-connections) | Create the three service connections | 15 min |
| [7](#part-7---create-the-pipelines-and-run-ci) | Create the pipelines and run CI | 30 min |
| [8](#part-8---run-cd-azure-infrastructure-and-dev--qa--prod) | Run CD: infrastructure and dev → qa → prod | 40 min |
| [9](#part-9---add-the-integrations-slack-dynatrace-azure-openai) | Add Slack, Dynatrace and Azure OpenAI | 45 min |
| [10](#part-10---test-everything) | Test everything | 20 min |
| [11](#part-11---save-money-destroy-and-rebuild) | Destroy after class, rebuild next time | 5 min |

> **Cost:** the full platform (7 small VMs, PostgreSQL, SonarQube VM) costs roughly
> US$15-25 per day. **Destroy it at the end of every class** (Part 11).

Throughout this guide, replace:

| Placeholder | Meaning | Example |
| --- | --- | --- |
| `<suffix>` | your initials + 2 digits, lowercase letters/digits only, max 6 characters | `rk07` |
| `<org>` | your Azure DevOps organization | `ravi-kumar` |
| `<project>` | your Azure DevOps project | `credpay` |

---

## Part 1 - Prepare your tools

Install on your laptop (Windows: use **PowerShell**; all commands also work in Git Bash):

| Tool | Install | Check |
| --- | --- | --- |
| Azure CLI | `winget install Microsoft.AzureCLI` | `az version` |
| Git | `winget install Git.Git` | `git --version` |
| kubectl + kubelogin | `az aks install-cli` (after Azure CLI) | `kubectl version --client`, `kubelogin --version` |
| Helm (optional, to look around) | `winget install Helm.Helm` | `helm version` |

Close and reopen PowerShell after installing, then sign in:

```powershell
az login                                   # opens the browser
az account show --query "{name:name, id:id}" -o table
```

If you have more than one subscription: `az account set --subscription "<name or id>"`.

Write down **your Entra ID object ID** - you need it in Part 3:

```powershell
az ad signed-in-user show --query id -o tsv
```

---

## Part 2 - Get the code into your Azure DevOps project

1. Open `https://dev.azure.com/<org>` → **+ New project** → name `<project>`,
   visibility *Private* → **Create**.
2. **Repos** → **Files** → the repository is empty → **Import a repository**:
   * Clone URL: the URL your instructor gives you
   * Tick **Requires authentication** and enter the user name / personal access token
     your instructor gives you (only if the instructor's repo is private)
   * **Import**
3. Clone your copy to your laptop:

   ```powershell
   git config --global core.longpaths true
   git clone https://dev.azure.com/<org>/<project>/_git/<project> C:\code\credpay
   cd C:\code\credpay
   ```

   (Repos → Files → **Clone** shows the exact URL; *Generate Git Credentials* gives you a
   password if Git asks for one.)

4. Install the **SonarQube** extension once for your organization:
   **Organization settings** (bottom left) → **Extensions** → **Browse marketplace** →
   search **SonarQube Server** (publisher *SonarSource*) → **Get it free** → choose your
   organization → **Install**.

---

## Part 3 - Make the names unique

Some Azure names are **global** - nobody else in the world can use the same one. Your
instructor's names are already taken, so add your `<suffix>`. Open the folder in VS Code
and change exactly these lines:

| # | File | Change | To (example with `rk07`) |
| --- | --- | --- | --- |
| 1 | `pipelines/templates/variables.yml` | `acrName: creddemoacr` | `acrName: credacrrk07` |
| 2 | `pipelines/templates/variables.yml` | `acrLoginServer: creddemoacr.azurecr.io` | `acrLoginServer: credacrrk07.azurecr.io` |
| 3 | `terraform/variables.tf` | variable `acr_name` → `default = "creddemoacr"` | `default = "credacrrk07"` |
| 4 | `terraform/variables.tf` | variable `key_vault_name` → `default = "kv-credpay-3297"` | `default = "kv-credpay-rk07"` |
| 5 | `terraform/backend.tf` | `storage_account_name = "credpaytfstate3297"` | `storage_account_name = "credpaytfstaterk07"` |
| 6 | `scripts/cd/bootstrap-tfstate.sh` | `account="credpaytfstate3297"` | `account="credpaytfstaterk07"` (same as #5) |
| 7 | `terraform/modules/postgres/main.tf` | `name = "psql-${var.name_prefix}"` | `name = "psql-${var.name_prefix}-rk07"` |
| 8 | `pipelines/credpay-cd.yml` | `adminObjectIds` → `value: '["4a93…"]'` | `value: '["<your object ID from Part 1>"]'` |

Rules: ACR and storage account names - **lowercase letters and digits only**, 5-24
characters. Key Vault - 3-24 characters, letters, digits and `-`.

Line 8 matters: it makes **you** an administrator of your cluster and Key Vault. With the
instructor's ID there, Terraform fails (that ID does not exist in your Azure tenant).

Keep the service connection names `sc-new`, `cred-acr1` and `sqsc1` - you will create
connections with exactly these names in Part 6, so nothing else needs to change.

Optional (cosmetic): the alert runbook links in `charts/credpay/templates/monitoring.yaml`
point to the instructor's repo - replace `bharathreddy3297/Flipkart-Capestone/_git/credwithaiops`
with `<org>/<project>/_git/<project>`.

Commit and push:

```powershell
git add -A
git commit -m "Use my own Azure names"
git push
```

---

## Part 4 - Create the container registry (ACR)

The registry stores the Docker images CI builds. It is created by hand (not by
Terraform) because it must survive when you destroy the cluster.

```powershell
az group create --name CredInfra-RG --location canadacentral
az acr create --resource-group CredInfra-RG --name credacrrk07 --sku Basic
```

Use **your** ACR name from Part 3. Check: Azure portal → *Container registries* →
`credacrrk07` → *Overview* shows the login server `credacrrk07.azurecr.io`.

---

## Part 5 - Create the SonarQube server

SonarQube checks code quality and test coverage. CI waits for its **quality gate** and
stops when it is red. It runs as a Docker container on a small Linux VM.

### 5.1 Create the VM

```powershell
az group create --name rg-sonarqube --location canadacentral
az vm create --resource-group rg-sonarqube --name vm-sonarqube `
  --image Ubuntu2404 --size Standard_B2ms `
  --admin-username azureuser --generate-ssh-keys `
  --public-ip-sku Standard
az vm open-port --resource-group rg-sonarqube --name vm-sonarqube --port 9000 --priority 1010
```

The output shows `"publicIpAddress": "x.x.x.x"` - write it down (`<sonar-ip>`). The
Standard public IP is static, so it stays the same when you stop and start the VM.

### 5.2 Install SonarQube

```powershell
ssh azureuser@<sonar-ip>
```

On the VM:

```bash
sudo apt-get update && sudo apt-get install -y docker.io
sudo systemctl enable --now docker

# SonarQube's search engine (Elasticsearch) needs this kernel setting
echo 'vm.max_map_count=524288' | sudo tee /etc/sysctl.d/99-sonarqube.conf
sudo sysctl --system

sudo docker run -d --name sonarqube --restart unless-stopped -p 9000:9000 \
  -v sonarqube_data:/opt/sonarqube/data \
  -v sonarqube_extensions:/opt/sonarqube/extensions \
  -v sonarqube_logs:/opt/sonarqube/logs \
  sonarqube:community

sudo docker logs -f sonarqube      # wait for "SonarQube is operational", then Ctrl+C
exit
```

### 5.3 First login and token

1. Browser: `http://<sonar-ip>:9000` → log in `admin` / `admin` → set a **strong** new
   password (the server is on the internet).
2. Top right **A** (avatar) → **My Account** → **Security** → *Generate Tokens*:
   name `azure-devops`, type **Global Analysis Token**, expires in 90 days → **Generate**.
3. Copy the token (`sqa_…`) - it is shown only once. You need it in Part 6.

The five SonarQube projects (`credpay-user-service`, `credpay-payment-service`,
`credpay-ai-service`, `credpay-customer-portal`, `credpay-admin-portal`) are created
automatically by the first CI run.

> To save money, stop the VM when you do not need it:
> `az vm deallocate -g rg-sonarqube -n vm-sonarqube` and later `az vm start …`.
> SonarQube must be running whenever CI runs.

---

## Part 6 - Create the service connections

Azure DevOps → your project → **Project settings** (bottom left) → **Service
connections** → **New service connection**. Create these three, with **exactly these names**:

### 6.1 `sc-new` - Azure Resource Manager (Terraform, AKS, Key Vault)

1. Type **Azure Resource Manager** → *Next*.
2. Identity type **App registration (automatic)**, credential **Workload identity
   federation** (no secret to store or expire).
3. Scope level **Subscription** → choose your subscription → leave *Resource group* empty.
4. Service connection name **`sc-new`** → tick **Grant access permission to all
   pipelines** → **Save**.

The connection gets *Contributor* on the subscription. Terraform also creates **role
assignments** (AKS may pull from ACR, you become cluster admin), which needs more:

5. Open the new connection → **Manage App registration** (or *Manage service principal*)
   → copy its **Display name**.
6. Azure portal → **Subscriptions** → your subscription → **Access control (IAM)** →
   **+ Add** → *Add role assignment*:
   * *Privileged administrator roles* tab → **Owner** → *Next*
   * *Members* → **+ Select members** → paste the display name → select → *Next*
   * *Conditions* → **Allow user to assign all roles except privileged administrator
     roles Owner, UAA, RBAC (Recommended)** → **Review + assign**

### 6.2 `cred-acr1` - Docker Registry (push images)

1. Type **Docker Registry** → *Next*.
2. Registry type **Azure Container Registry**, authentication **Workload Identity
   federation** (or *Service Principal*) → your subscription → registry `credacrrk07`.
3. Name **`cred-acr1`** → tick **Grant access permission to all pipelines** → **Save**.

### 6.3 `sqsc1` - SonarQube Server

1. Type **SonarQube Server** → *Next*.
2. Server URL `http://<sonar-ip>:9000`, Token = the `sqa_…` token from Part 5.3.
3. Name **`sqsc1`** → tick **Grant access permission to all pipelines** → **Save**.

---

## Part 7 - Create the pipelines and run CI

All three pipelines are YAML files in the repo. The **names matter**: the CD pipeline is
triggered by the pipeline named `credpay-ci`.

| Name | YAML file | Runs |
| --- | --- | --- |
| `credpay-ci` | `/pipelines/credpay-ci.yml` | every push to `main`: tests, SonarQube, build, Trivy scan, push to ACR |
| `credpay-cd` | `/pipelines/credpay-cd.yml` | after every successful CI run: Terraform, platform, dev → qa → prod |
| `credpay-pr` | `/pipelines/credpay-pr.yml` | every pull request: the same checks, nothing pushed |

For each one: **Pipelines** → **New pipeline** → **Azure Repos Git** → your repository →
**Existing Azure Pipelines YAML file** → branch `main`, path from the table → *Continue* →
open the **Run** drop-down → **Save** (do not run yet). Then **⋯** (top right) →
**Rename/move** → the name from the table → *Save*.

### 7.1 Run CI

Pipelines → `credpay-ci` → **Run pipeline** → *Run*. A manual run builds all six images
(about 15-25 minutes).

* If a run shows *This pipeline needs permission to access a resource* → **View** →
  **Permit** (once per resource).
* Watch the stages: *Prepare* (gitleaks secret scan, Trivy filesystem scan, change
  detection), then one job per service: **unit tests → SonarQube gate → docker build →
  Trivy image scan → push**.

Check:

* The run is green; the **Tests** tab shows the unit tests and the Trivy results.
* `http://<sonar-ip>:9000` → **Projects** shows five projects with a *Passed* gate.
* Azure portal → `credacrrk07` → **Repositories**: `credpay/user-service`,
  `credpay/payment-service`, `credpay/ai-service`, `credpay/customer-portal`,
  `credpay/admin-portal`, `credpay/keycloak`, each with a tag `1.0.<number>`.

### 7.2 Protect `main` (recommended)

Repos → **Branches** → `main` → **⋯** → **Branch policies**:

* *Require a minimum number of reviewers*: **1** (allow requestors to approve their own
  changes if you work alone)
* *Build validation* → **+** → pipeline `credpay-pr`, *Required*
* *Limit merge types*: only **Squash merge**

From now on every change goes through a pull request.

---

## Part 8 - Run CD: Azure infrastructure and dev → qa → prod

The CD pipeline starts automatically when CI succeeds. If the CI run in Part 7 finished
before `credpay-cd` existed, start it yourself: Pipelines → `credpay-cd` → **Run pipeline**
→ *Run* (leave *Destroy* unticked).

### 8.1 What happens (about 30-40 minutes the first time)

| Stage | What it does |
| --- | --- |
| **Infrastructure (Terraform)** | creates the state storage, then `rg-credpay`: network, AKS (system + user node pools), PostgreSQL, Key Vault with generated passwords, static ingress IP |
| **Ingress, certificates and observability** | Traefik ingress, cert-manager (Let's Encrypt), Prometheus + Alertmanager + Grafana; Slack and Dynatrace when their secrets exist |
| **Deploy dev** | Key Vault → Kubernetes Secrets → `helm upgrade` → smoke tests |
| **Deploy qa** | the **same** images as dev |
| **Deploy prod** | the same images, 2+ replicas, autoscaling, monitoring and AIOps |

The first run creates the environments `credpay-dev`, `credpay-qa` and `credpay-prod`;
if it stops with *needs permission*, click **View** → **Permit**.

### 8.2 Add approvals for qa and prod

Pipelines → **Environments** → `credpay-qa` → **⋯** → **Approvals and checks** → **+** →
**Approvals** → add yourself → **Create**. Do the same for `credpay-prod`. From the next
run, qa and prod wait for your **Approve** (the run shows *Waiting*).

### 8.3 Your URLs

At the end of each *Deploy* stage, the log of the step *Deploy (helm) and smoke test*
prints the URLs, for example (your IP is different):

| | URL |
| --- | --- |
| Customer portal | `https://dev.20-48-1-2.sslip.io` (and `qa.`, `prod.`) |
| Admin portal | `https://admin.dev.20-48-1-2.sslip.io` |
| Keycloak admin console | `https://auth.dev.20-48-1-2.sslip.io/admin` |
| Grafana | `https://grafana.20-48-1-2.sslip.io` |

Logins:

| | User | Password |
| --- | --- | --- |
| Customer portal | `customer@credpay.local` | `Customer@123` |
| Admin portal | `admin@credpay.local` | `Admin@123` |
| Grafana | `admin` | Key Vault secret `grafana-admin-password` |
| Keycloak console | Key Vault `keycloak-admin-username` | Key Vault `keycloak-admin-password` |

Read a Key Vault secret: Azure portal → **Key vaults** → `kv-credpay-rk07` → **Secrets** →
the secret → current version → **Show secret value**.

### 8.4 Connect kubectl to your cluster

The cluster accepts only Entra ID logins (no local accounts):

```powershell
az aks get-credentials --resource-group rg-credpay --name aks-credpay --overwrite-existing
kubelogin convert-kubeconfig -l azurecli
kubectl get nodes
kubectl get pods -n credpay-dev
kubectl get pods -n credpay-prod
```

---

## Part 9 - Add the integrations (Slack, Dynatrace, Azure OpenAI)

Each integration is switched on by adding **secrets to your Key Vault** - no code change.
After adding them, run `credpay-cd` again (Run pipeline). The step *Read optional
integrations* prints which ones it found.

**How to add a secret** (Key Vault exists after Part 8): Azure portal → **Key vaults** →
`kv-credpay-rk07` → **Secrets** → **+ Generate/Import** → *Name* and *Secret value* →
**Create**. (You can, because your object ID is in `adminObjectIds`.)

> Secrets go **only** into Key Vault - never into Git, a pipeline file or a chat.

### 9.1 Slack - alerts in a channel (10 minutes)

1. Create a free workspace at [slack.com](https://slack.com) (or use your own) and a
   channel `#credpay-alerts`.
2. [api.slack.com/apps](https://api.slack.com/apps) → **Create New App** → **From
   scratch** → name `CREDPAY Alerts`, pick your workspace → *Create App*.
3. Left menu **Incoming Webhooks** → switch **On** → **Add New Webhook to Workspace**
   (bottom) → choose `#credpay-alerts` → **Allow**.
4. Copy the **Webhook URL** (`https://hooks.slack.com/services/T…/B…/…`).
5. Key Vault secret:

   | Name | Value |
   | --- | --- |
   | `slack-webhook-url` | the webhook URL |

### 9.2 Dynatrace - full-stack monitoring of prod (20 minutes)

1. Start a free trial at [dynatrace.com/trial](https://www.dynatrace.com/trial/) and open
   your environment. The browser address shows your **environment URL**, e.g.
   `https://abc12345.apps.dynatrace.com` - the API URL is the same ID with `live`:
   **`https://abc12345.live.dynatrace.com`**.
2. **Operator token and data ingest token** - the Kubernetes wizard creates both with the
   right scopes: Dynatrace → search **Kubernetes** → **Add cluster** → name `credpay` →
   *Generate token* for the **Dynatrace Operator token** and for the **Data ingest token**
   → copy both (`dt0c01.…`). (Ignore the wizard's install commands - the pipeline
   installs Dynatrace for you.)
3. **Problems token** (read-only, used by the admin portal): Dynatrace → search **Access
   tokens** → **Generate new token** → name `credpay-problems` → scope **Read problems**
   (`problems.read`) → *Generate* → copy.
4. Key Vault secrets:

   | Name | Value |
   | --- | --- |
   | `dynatrace-url` | `https://abc12345.live.dynatrace.com` (no `/` at the end, no `/api`) |
   | `dynatrace-api-token` | the operator token |
   | `dynatrace-data-ingest-token` | the data ingest token |
   | `dynatrace-problems-token` | the problems token |

After the next CD run: Dynatrace → **Kubernetes** shows the cluster `credpay` within a few
minutes, and prod's services appear under **Services**. Dynatrace adds one agent pod per
node, so the cluster may add a node (normal).

### 9.3 Azure OpenAI - AI briefing and the "Ask CredAI" chat (15 minutes)

1. Azure portal → **Create a resource** → search **Azure OpenAI** → *Create*:
   resource group `CredInfra-RG`, region e.g. *East US 2* or *Sweden Central* (where your
   model is available), name `credpayai-rk07`, pricing tier *Standard S0* → *Review +
   create* → *Create*.
2. Open the resource → **Go to Azure AI Foundry portal** → **Deployments** → **Deploy
   model** → **Deploy base model** → choose **`gpt-5-mini`** (cheap and fast; any GPT-5
   family model works - the app needs a *reasoning* model) → deployment name
   `gpt-5-mini` → *Deploy*.
3. Back in the Azure portal → the resource → **Keys and Endpoint** → copy **KEY 1** and
   the **Endpoint** (`https://credpayai-rk07.openai.azure.com/`).
4. Key Vault secrets:

   | Name | Value |
   | --- | --- |
   | `azure-openai-endpoint` | the endpoint **plus `openai/v1`**: `https://credpayai-rk07.openai.azure.com/openai/v1` |
   | `azure-openai-key` | KEY 1 |
   | `azure-openai-deployment` | the deployment name, `gpt-5-mini` |

### 9.4 Apply them

Pipelines → `credpay-cd` → **Run pipeline** → approve qa and prod. In the log, *Read
optional integrations* should show Slack, Dynatrace and Azure OpenAI as configured, and the
prod deploy step prints *AIOps: Azure OpenAI configured, Dynatrace configured*.

---

## Part 10 - Test everything

Do the checks in this order and tick them off:

**Application (dev, qa and prod)**

- [ ] Customer portal → **Sign In** → the CredPay Keycloak login page → log in as the customer.
- [ ] **Add card** → **Pay bill** (use a different amount in each environment) → **History** shows it.
- [ ] Admin portal (private/incognito window) → log in as admin → **Transactions** shows your payment.
- [ ] The payment from dev does **not** appear in qa's admin portal - each environment has its own database.

**Monitoring (prod)**

- [ ] Admin portal (prod) → **Monitoring**: status *Healthy*; the source chips show
      prometheus, alertmanager, kubernetes, dynatrace and azure_openai as *ok*.
- [ ] **Generate briefing** → a short text *Generated by Azure OpenAI*.
- [ ] Grafana → Dashboards → **CREDPAY** → *Service Overview*, Environment `credpay-prod`:
      make a payment and watch the request graph move.

**AI assistant (prod)**

- [ ] Admin portal → **Ask CredAI** → click *Is prod healthy right now?* → an answer within a few seconds.
- [ ] Ask a follow-up, e.g. *Which pods use the most CPU and memory?*, then *Is that within their requests?*

**Alerting (Slack)**

- [ ] Send a test alert (Git Bash, with kubectl connected - Part 8.4):

  ```bash
  kubectl port-forward -n monitoring svc/monitoring-alertmanager 9093:9093 &
  curl -H "Content-Type: application/json" -d '[{"labels":{"alertname":"CredpayHighLatency","severity":"warning","team":"credpay","environment":"prod","namespace":"credpay-prod","service":"user-service"},"annotations":{"summary":"user-service is slow in prod (DEMO)"}}]' http://localhost:9093/api/v2/alerts
  ```

- [ ] Within a minute: a **FIRING** message in `#credpay-alerts`, and the Monitoring page
      shows *Degraded* with the alert. After about 5 minutes a **RESOLVED** message follows.

**Dynatrace**

- [ ] Dynatrace → **Kubernetes** → cluster `credpay` is connected; **Services** lists the
      prod services; make a payment and open its trace.

**Pipeline gates**

- [ ] Make a small change on a branch, open a **pull request**: `credpay-pr` must pass
      before you can merge. After the merge, CI → CD runs and waits for your qa/prod approval.

---

## Part 11 - Save money: destroy and rebuild

**At the end of every class:**

1. Copy your Key Vault secrets (Slack, Dynatrace, Azure OpenAI) into a password manager
   or a private note - **they are deleted together with the Key Vault**.
2. Pipelines → `credpay-cd` → **Run pipeline** → tick **Destroy all Azure
   infrastructure** → *Run*. About 15 minutes; it removes `rg-credpay` (AKS, PostgreSQL,
   Key Vault, IP). It keeps the ACR, the Terraform state and SonarQube.
3. Stop SonarQube: `az vm deallocate -g rg-sonarqube -n vm-sonarqube`.

**Next class:**

1. `az vm start -g rg-sonarqube -n vm-sonarqube`
2. Pipelines → `credpay-cd` → **Run pipeline** (normal run, 30-40 minutes).
3. When the Infrastructure stage is done, add your Key Vault secrets again (Part 9), then
   run `credpay-cd` once more.

The ingress IP and therefore your URLs may change after a destroy.

---

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| *This pipeline needs permission to access a resource* | Open the run → **View** → **Permit** |
| *A task is missing … SonarQubePrepare@7* | Install the SonarQube Server extension (Part 2, step 4) |
| SonarQube step times out or *connection refused* | VM stopped, container not running (`sudo docker ps` on the VM), or port 9000 not open (Part 5.1) |
| SonarQube *Not authorized* | Wrong or expired token: create a new one (Part 5.3) and edit the `sqsc1` connection |
| *Quality gate failed* | Open the project in SonarQube → *New code* tab → fix the issues (or add tests if *Coverage* is the failing condition) and push again |
| Push to ACR *unauthorized* | `cred-acr1` points to the wrong registry, or `acrLoginServer` in `variables.yml` does not match |
| Terraform: *name … is already taken* / *StorageAccountAlreadyTaken* / *already exists* | A global name is not unique - check Part 3 (#3-#7) |
| Terraform: *AuthorizationFailed … roleAssignments/write* | `sc-new` is missing the **Owner** role (Part 6.1, steps 5-6) |
| Terraform: *PrincipalNotFound* | `adminObjectIds` still has the instructor's ID (Part 3, #8) |
| Terraform: *Registry … not found* | The ACR name or its resource group (`CredInfra-RG`) differs from `terraform/variables.tf` |
| Terraform: *Error acquiring the state lock* | Another CD run is active, or a cancelled run left a lock: when no run is active, `az storage blob lease break --account-name credpaytfstaterk07 -c tfstate -b credpay.tfstate` |
| Pods *Pending*, *Insufficient cpu/memory* | The cluster is adding a node - wait a few minutes. *in backoff after failed scale-up* = vCPU quota: `az vm list-usage -l canadacentral -o table`, request more under Subscriptions → Usage + quotas |
| Browser warns about the certificate | Let's Encrypt limits for the shared sslip.io domain - wait and run CD again, or set `tlsIssuer: selfsigned` in `credpay-cd.yml` |
| Key Vault: *You are unauthorized to view these contents* | Your object ID is not in `adminObjectIds`, or you are signed in to the portal with another account |
| Monitoring page: *dynatrace: unavailable* | The problems token is missing or lacks `problems.read` - create it (Part 9.2, step 3) |
| Briefing says *rules* / chat says it needs Azure OpenAI | The three `azure-openai-*` secrets are missing, or the endpoint does not end in `/openai/v1` - fix and run CD again |
| *DeploymentNotFound* in the ai-service log | `azure-openai-deployment` must be the **deployment** name from AI Foundry, not the resource name |

More detail: [CI-PIPELINE.md](CI-PIPELINE.md) · [CD-PIPELINE.md](CD-PIPELINE.md) ·
[OBSERVABILITY.md](OBSERVABILITY.md) · [ARCHITECTURE.md](ARCHITECTURE.md)
