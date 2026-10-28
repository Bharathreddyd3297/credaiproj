# CredPay on Kubernetes

The application is packaged as a **Helm chart** ([`charts/credpay`](../charts/credpay)) and
deployed by `pipelines/credpay-cd.yml` to three namespaces of one AKS cluster:
`credpay-dev` → `credpay-qa` → `credpay-prod` (see [docs/CD-PIPELINE.md](../docs/CD-PIPELINE.md)).
This folder holds the **cluster-wide platform** the chart relies on.

```
charts/credpay/                 the application (one chart, every environment)
  values.yaml                     defaults
  values-dev.yaml / -qa / -prod   per environment (replicas, autoscaling, monitoring, AIOps)
  templates/                      keycloak, user-service, payment-service, portals,
                                  ai-service, ingress, HPAs/PDBs, ServiceMonitors,
                                  PrometheusRules, Grafana dashboard
  dashboards/                     Grafana dashboards (JSON)

k8s/platform/                   installed once per cluster (Platform stage)
  traefik-values.yaml             ingress controller (Helm)
  cert-manager-values.yaml        certificates (Helm)
  cluster-issuers.yaml            letsencrypt-prod / letsencrypt-staging / selfsigned
  monitoring/                     kube-prometheus-stack: Prometheus, Alertmanager, Grafana
  dynatrace/                      DynaKube (OneAgent + ActiveGate)                 - optional

```

## Traffic

```
browser --https--> Traefik (static public IP)
   <env>.<domain>         /api/payment -> payment-service
                          /api         -> user-service
                          /            -> customer-portal
   admin.<env>.<domain>   /api/ai      -> ai-service        (prod: AIOps)
                          same APIs,  / -> admin-portal
   auth.<env>.<domain>    /            -> keycloak
   grafana.<domain>       /            -> Grafana            (monitoring namespace)
```

The portals call the APIs on their own host (`/api/...`), so there is no CORS.
The services validate Keycloak tokens: the issuer is the public URL
(`https://auth.<env>.<domain>/realms/credpay`), the signing keys are fetched
inside the cluster (`http://keycloak:8080/...`).

## Configuration

| What | Where |
| --- | --- |
| Hosts, public URLs, database names, token audience | chart → ConfigMap `credpay-config` (from `environment` + `domain`) |
| Replicas, autoscaling, monitoring, AIOps | `charts/credpay/values-<env>.yaml` |
| Image tags | set by the pipeline: `--set <component>.image=<registry>/credpay/<service>:<tag>` |
| DB host/user/password, Keycloak admin | Secrets `credpay-db`, `keycloak-admin`, created by the pipeline from Key Vault |
| Azure OpenAI / Dynatrace settings for AIOps | Secret `credpay-aiops` (prod, optional), from Key Vault |

## Security settings (every pod)

The namespaces enforce the **restricted** Pod Security Standard. Every container
runs as non-root with a read-only root filesystem (a writable `emptyDir` only
where the app needs one, e.g. `/tmp`), no privilege escalation, all Linux
capabilities dropped, the default seccomp profile and CPU/memory requests and
limits. Only ai-service mounts a service-account token: read-only access to pods,
deployments and events of its own namespace.

## By hand

```bash
az aks get-credentials -g rg-credpay -n aks-credpay && kubelogin convert-kubeconfig -l azurecli
helm list -A                                           # every release in the cluster
helm history credpay -n credpay-prod                   # releases of one environment
helm get values credpay -n credpay-prod                # what the pipeline set
helm rollback credpay <revision> -n credpay-prod       # go back to a previous release
kubectl get pods,ingress,certificate,hpa -n credpay-prod
kubectl logs deploy/keycloak -n credpay-dev

# Render the chart locally (no cluster needed)
helm template credpay charts/credpay -f charts/credpay/values-prod.yaml \
  --set domain=example.com \
  --set keycloak.image=r/keycloak:1 --set userService.image=r/user-service:1 \
  --set paymentService.image=r/payment-service:1 --set customerPortal.image=r/customer-portal:1 \
  --set adminPortal.image=r/admin-portal:1 --set aiops.image=r/ai-service:1
```
