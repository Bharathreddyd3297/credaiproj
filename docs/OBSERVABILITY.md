# CREDPAY - Observability, Alerting and AIOps

Production (`credpay-prod`) is watched four ways. Each one works on its own, and the
three that need an outside account (Slack, Dynatrace, Azure OpenAI) switch on when their
secrets are added to Key Vault - nothing to change in code or pipelines.

```
                    ┌──────────────────────── AKS cluster ─────────────────────────┐
 credpay-prod pods  │  metrics ──► Prometheus ──► Grafana dashboards                │
 (Keycloak, user-,  │                 │  rules                                       │
  payment-, ai-     │                 ▼                                              │
  service, portals) │            Alertmanager ──────────────────► Slack webhook ────┼──► #credpay-alerts
                    │  traces/code ► Dynatrace OneAgent ─────────────► Dynatrace ────┼──► Davis AI problems
                    │                                                                │
                    │  ai-service ◄── Prometheus, Alertmanager, Kubernetes,          │
                    │       │          Dynatrace problems                            │
                    │       └─► Azure OpenAI (briefing) ──► admin portal: Monitoring │
                    └────────────────────────────────────────────────────────────────┘
```

| Tool | Always on? | Where to look |
| --- | --- | --- |
| **Prometheus + Grafana** | yes | `https://grafana.<domain>` → folder *CREDPAY* → *Service Overview* |
| **Alertmanager** | yes (alerts also on the admin portal) | admin portal → Monitoring; Grafana → Alerting |
| **Slack** | when the `slack-webhook-url` secret exists | your alerts channel (e.g. `#credpay-alerts`) |
| **Dynatrace** | when `dynatrace-*` secrets exist | your Dynatrace environment; problems also on the admin portal |
| **AIOps (ai-service)** | yes in prod; AI-written with `azure-openai-*` secrets | `https://admin.prod.<domain>` → Monitoring |

Contents: [Prometheus and Grafana](#prometheus-and-grafana) ·
[Alerts and runbooks](#alerts-and-runbooks) · [Slack](#slack) ·
[Dynatrace](#dynatrace) · [AIOps](#aiops) · [What to add to Key Vault](#what-to-add-to-key-vault) ·
[Demo for class](#demo-for-class)

---

## Prometheus and Grafana

Installed once per cluster by the CD pipeline's Platform stage:
`kube-prometheus-stack` 92.13.1 in namespace `monitoring`
([values](../k8s/platform/monitoring/kube-prometheus-stack-values.yaml)).

**What is scraped** - the CREDPAY chart creates a `ServiceMonitor` per service in every
environment with `monitoring.enabled` (prod):

| Service | Endpoint | Key metrics |
| --- | --- | --- |
| user-service | `/actuator/prometheus` | `http_server_requests_seconds_*` (status, uri), JVM |
| payment-service | `/metrics` | `http_requests_total` (handler, status `2xx/4xx/5xx`), `http_request_duration_seconds_*` |
| ai-service | `/metrics` | same as payment-service |
| keycloak | `:9000/metrics` | `http_server_requests_seconds_*`, JVM |

Every series carries `environment` and `service` labels. Health checks and metrics scrapes
are left out of the traffic figures (they are not user traffic).

**Grafana**: `https://grafana.<domain>`, user `admin`, password in Key Vault
`grafana-admin-password`. The dashboard *CREDPAY - Service Overview* comes from the chart
([`charts/credpay/dashboards`](../charts/credpay/dashboards)) - edit the JSON there, not in
Grafana (changes made in the UI are lost on the next deployment). The *Kubernetes / …*
dashboards of the stack show nodes, pods and workloads.

> A counter that appears for the first time is not counted by `increase()`/`rate()` until
> it changes again (Prometheus has no earlier value to compare with). With steady traffic
> this does not matter; in a quick demo, make a few requests, wait 30 seconds, make a few
> more.

Recording rules (used by the dashboard, the alerts and ai-service):

| Rule | Meaning |
| --- | --- |
| `credpay:http_error_ratio:rate5m` | share of requests answered 5xx, per service (0 when there is traffic but no errors) |
| `credpay:http_latency_p95:rate5m` | 95th percentile response time in seconds, per service |

---

## Alerts and runbooks

Defined in [`charts/credpay/templates/monitoring.yaml`](../charts/credpay/templates/monitoring.yaml)
(`PrometheusRule credpay-alerts`). Labels: `severity` (critical | warning), `team=credpay`,
`environment`. Alertmanager groups them by alert, namespace and service, and - when
Slack is configured - posts every one (and its resolution) to Slack. A critical alert
mutes the warnings of the same service.

### CredpayServiceDown
*critical* - Prometheus cannot scrape user-service, payment-service or keycloak for 2 minutes.
```bash
kubectl get pods -n credpay-prod -l app.kubernetes.io/name=<service>
kubectl describe pod <pod> -n credpay-prod      # events: OOMKilled? image pull? probe failures?
kubectl logs <pod> -n credpay-prod --previous   # the crashed container's last log
```
Common causes: database unreachable (check the `credpay-db` secret and PostgreSQL), Keycloak
not ready (the services need its keys), out of memory.

### CredpayDeploymentUnavailable
*warning* - a deployment has fewer ready replicas than desired for 10 minutes.
`kubectl describe deploy/<name> -n credpay-prod` and the pod events: `Pending` → not enough
room (the autoscaler adds a node), `ImagePullBackOff` → image tag, `CrashLoopBackOff` → see
CredpayPodCrashLooping.

### CredpayPodCrashLooping
*critical* - a container restarted more than 3 times in 15 minutes.
`kubectl logs <pod> -n credpay-prod --previous` shows why it died. Roll back if it started
with a release: `helm rollback credpay <previous revision> -n credpay-prod`.

### CredpayHighErrorRate
*critical* - more than 5% of a service's requests return 5xx for 5 minutes.
Look for the error in the logs (`kubectl logs deploy/<service> -n credpay-prod | grep -i error`)
and in Dynatrace (the problem shows the failing request and its root cause). If it started with a deployment,
roll back.

### CredpayHighLatency
*warning* - the 95th percentile response time is above 1 second for 10 minutes.
Check CPU/memory on the dashboard (throttled? at its limit?), the HPA
(`kubectl get hpa -n credpay-prod`), and the database. Dynatrace shows the slow calls.

### CredpayPaymentErrors
*critical* - more than 3 payment requests (`POST /api/payment/pay`) failed with a server error
in 10 minutes. Customers cannot pay. Check payment-service logs and the database first.

### CredpayContainerMemoryHigh
*warning* - a container uses more than 90% of its memory limit for 15 minutes; it may be
OOM-killed soon. Raise the limit in `charts/credpay/values-prod.yaml` (`resources`) or find
the leak (Dynatrace memory analysis).

---

## Slack

Alertmanager posts every CREDPAY alert - and its resolution - to one Slack channel through
an **Incoming Webhook**. Nothing is installed for it: it is a receiver in Alertmanager's
configuration ([`scripts/cd/monitoring-values.sh`](../scripts/cd/monitoring-values.sh)).

**Set-up (once, about 5 minutes)**

1. In your Slack workspace (the free plan is fine) create a channel, e.g. `#credpay-alerts`.
2. [api.slack.com/apps](https://api.slack.com/apps) → **Create New App** → *From scratch*,
   name *CREDPAY Alerts*, pick the workspace.
3. **Incoming Webhooks** → switch on → **Add New Webhook to Workspace** → choose the
   channel → *Allow*. Copy the URL (`https://hooks.slack.com/services/T…/B…/…`).
4. Add it to Key Vault as `slack-webhook-url` (below) and run credpay-cd.

The webhook URL is a secret - anyone who has it can post to the channel. It is stored in
the Kubernetes Secret `alertmanager-slack` (namespace `monitoring`), mounted into
Alertmanager and read with `api_url_file`, so it never appears in a values file or log.

**A message** shows *FIRING* or *RESOLVED*, the alert name and namespace, then per alert
its severity, summary, description and a link to its runbook below; the title links to
the Grafana dashboard. The colour is red for critical, orange for warning and green once
resolved. While an alert keeps firing it is repeated every 4 hours.

---

## Dynatrace

Dynatrace Operator 1.11.1 (namespace `dynatrace`) with the DynaKube in
[`k8s/platform/dynatrace/dynakube.yaml`](../k8s/platform/dynatrace/dynakube.yaml):
**cloud-native full stack** - a OneAgent on every node and code modules injected into the
pods of `credpay-prod` only (dev and qa are untouched), plus an ActiveGate for Kubernetes
API monitoring. Davis AI then detects problems and their root cause; ai-service shows the
open problems on the admin portal.

**Create the tokens** (Dynatrace trial is fine):

1. Dynatrace → *Kubernetes* → *Add cluster* (or Settings → Access tokens). The Kubernetes
   wizard generates the two tokens with the right scopes:
   * **Operator token** (`dynatrace-api-token`) - read/write settings, entities, installer
     download, ActiveGate token management, data export.
   * **Data ingest token** (`dynatrace-data-ingest-token`) - `metrics.ingest`,
     `logs.ingest`, `openTelemetryTrace.ingest`.
   * **Problems token** (`dynatrace-problems-token`, recommended) - Access Tokens →
     *Generate new token*, only the scope **Read problems** (`problems.read`). ai-service
     uses it to show open problems on the admin portal - least privilege: it never gets
     the operator's write access. Without it, ai-service falls back to the operator token
     (which then also needs `problems.read`; a token's scopes cannot be changed later).
2. Your environment URL, e.g. `https://abc12345.live.dynatrace.com` (`dynatrace-url`, no
   trailing `/api`).
3. Add the three secrets to Key Vault (below) and run credpay-cd. The Platform stage
   installs the operator and the DynaKube; prod pods are restarted by the next deployment
   and get the code modules.

Check: `kubectl get dynakube -n dynatrace` (phase *Running*), and the cluster appears in
Dynatrace → Kubernetes within a few minutes.

> **Pod Security:** the CREDPAY namespaces enforce the *restricted* Pod Security Standard.
> If Dynatrace's injection is blocked there (pods fail to start with a
> *violates PodSecurity "restricted"* event after enabling Dynatrace), set
> `pod-security.kubernetes.io/enforce=baseline` on `credpay-prod` in
> `scripts/cd/deploy-app.sh` - the CREDPAY containers themselves stay non-root and
> read-only either way. This was validated against the operator's schema and webhook, but
> not yet against a live Dynatrace tenant.

The DynaKube also lets Dynatrace ingest the services' Prometheus metrics: the pipeline
sets `monitoring.dynatraceMetrics=true`, which adds `metrics.dynatrace.com/*` annotations to
the prod pods.

---

## AIOps

**ai-service** (Python/FastAPI, in `credpay-prod`) builds one picture of the environment
and explains it. It is admin-only: every call needs a Keycloak token with the `ADMIN`
role, and it reads Kubernetes with a read-only role limited to its own namespace.

| Endpoint | What |
| --- | --- |
| `GET /api/ai/overview` | status (healthy / degraded / down), per-service up, pods, requests/s, error ratio, p95, firing alerts, Dynatrace problems, recently restarted pods, which sources answered |
| `POST /api/ai/insight` | a short briefing: the main problem, likely cause, impact and next steps - written by **Azure OpenAI** when configured, otherwise by **deterministic rules** (so it works without an AI account) |
| `POST /api/ai/chat` | the **Ask CredAI** chat: a question plus the conversation so far → an answer from Azure OpenAI (503 without it) |
| `GET /api/ai/health`, `/api/ai/live`, `/metrics` | probes and metrics (no token) |

The admin portal's **Monitoring** page (prod) shows the overview, refreshes every 30
seconds, has a *Generate briefing* button and links to Grafana and Dynatrace.
dev and qa show a short note instead (`aiops.enabled: false`).

**Ask CredAI** (admin portal, prod) is a chat: type a question (*Are any alerts firing?*,
*Which pods use the most CPU?*, *Why could payments be slow?*) and follow-up questions.
For every question ai-service collects the same overview as the Monitoring page plus the
facts that fit the question (keywords pick them, `app/services/intent_classifier.py`):
pods and events, CPU/memory usage vs requests, HPAs, HTTP success and error rates. The
model answers only from those facts and says when they do not contain the answer. The
conversation lives in the browser tab (*New chat* clears it); the last 10 messages are
sent with each question.

**Azure OpenAI**: create an Azure OpenAI (or Azure AI Foundry) resource, deploy a chat
**reasoning** model of the GPT-5 family (e.g. `gpt-5-mini`, `gpt-5.5`; the request sets a
reasoning effort, which older models such as gpt-4o reject), and note:

| Key Vault secret | Value |
| --- | --- |
| `azure-openai-endpoint` | the **v1** endpoint ending in `/openai/v1`, e.g. `https://<resource>.openai.azure.com/openai/v1` (a Foundry `…/openai/v1/responses` URL also works) |
| `azure-openai-key` | Keys and Endpoint → Key 1 |
| `azure-openai-deployment` | the deployment name |

The briefing and the chat send the model only operational facts (service health, alerts,
problems, pod and HTTP metrics) and the admin's question - no customer data and no logs.

---

## What to add to Key Vault

Terraform creates the vault and the passwords it generates (`postgres-*`, `keycloak-admin-*`,
`grafana-admin-password`). Add the integrations by hand - each group is optional:

```bash
kv=$(az keyvault list -g rg-credpay --query "[0].name" -o tsv)

# AIOps briefings (Azure OpenAI)
az keyvault secret set --vault-name $kv --name azure-openai-endpoint   --value "https://<resource>.openai.azure.com/openai/v1"
az keyvault secret set --vault-name $kv --name azure-openai-key        --value "<key>"
az keyvault secret set --vault-name $kv --name azure-openai-deployment --value "<deployment name>"

# Dynatrace
az keyvault secret set --vault-name $kv --name dynatrace-url               --value "https://<env-id>.live.dynatrace.com"
az keyvault secret set --vault-name $kv --name dynatrace-api-token         --value "dt0c01...."
az keyvault secret set --vault-name $kv --name dynatrace-data-ingest-token --value "dt0c01...."
az keyvault secret set --vault-name $kv --name dynatrace-problems-token    --value "dt0c01...."   # problems.read only

# Slack (alerts)
az keyvault secret set --vault-name $kv --name slack-webhook-url --value "https://hooks.slack.com/services/..."
```

Then run **credpay-cd** (Run pipeline). The *Read optional integrations* steps print
which ones are configured. To switch one off again, delete its secrets
(`az keyvault secret delete …`) and run the pipeline.

> Typing secrets into a shared terminal leaves them in its history - use the Azure portal
> (Key Vault → Secrets → Generate/Import) if others can see your shell.

---

## Demo for class

1. **Dashboard** - open Grafana → CREDPAY → Service Overview (Environment: credpay-prod),
   then use the customer portal: requests, latency and payments move.
2. **An alert end to end** - fire a test alert into Alertmanager:

   ```bash
   kubectl port-forward -n monitoring svc/monitoring-alertmanager 9093:9093 &
   curl -H "Content-Type: application/json" -d '[{"labels":{"alertname":"CredpayHighLatency","severity":"warning","team":"credpay","environment":"prod","namespace":"credpay-prod","service":"user-service"},"annotations":{"summary":"user-service is slow in prod (DEMO)"}}]' \
     http://localhost:9093/api/v2/alerts
   ```

   Within a minute it is on the admin portal's Monitoring page (status *Degraded*) and in
   the Slack channel. It resolves itself after 5 minutes (a *RESOLVED* message follows).
3. **A real failure** - `kubectl scale deploy/payment-service -n credpay-prod --replicas=0`
   (the HPA's minimum puts it back) or set a wrong `DB_HOST`; watch the readiness
   failures, *CredpayDeploymentUnavailable* after 10 minutes, Dynatrace's problem, and the
   AIOps briefing. Undo with `helm rollback credpay <revision> -n credpay-prod`.
4. **Brute force** - try 10+ wrong passwords on the customer portal: Keycloak locks the
   account after 5 (Keycloak → Events shows the `LOGIN_ERROR`s).
