# CREDPAY

A credit-card bill-payment platform built the way enterprises build software: separate
customer and admin web apps, a dedicated identity server (Keycloak), secured Java and Python
services, versioned database migrations and automated tests - on your laptop, and on Azure
Kubernetes Service with a DevSecOps pipeline, Prometheus/Grafana, Slack alerting, Dynatrace
and an AIOps assistant.

| | |
| --- | --- |
| **Run it on your laptop** | [docs/LOCAL-SETUP-GUIDE.md](docs/LOCAL-SETUP-GUIDE.md) |
| **Deploy everything in your own Azure account (students)** | [docs/STUDENT-AZURE-SETUP.md](docs/STUDENT-AZURE-SETUP.md) |
| **How it is designed** | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| **CI pipeline (Azure DevOps)** | [docs/CI-PIPELINE.md](docs/CI-PIPELINE.md) |
| **CD pipeline: AKS, dev → qa → prod** | [docs/CD-PIPELINE.md](docs/CD-PIPELINE.md) |
| **Monitoring, alerting (Slack), Dynatrace, AIOps** | [docs/OBSERVABILITY.md](docs/OBSERVABILITY.md) |

## Quick start (Windows)

```powershell
git config --global core.longpaths true
git clone https://dev.azure.com/bharathreddy3297/Flipkart-Capestone/_git/credwithaiops C:\code\credwithaiops
cd C:\code\credwithaiops

# once, in PowerShell "Run as administrator" - then restart and start Docker Desktop
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\setup\install-prereqs.ps1

# once, in a normal PowerShell window
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
.\scripts\setup\check-prereqs.ps1

# every time
.\scripts\start-all.ps1     # Customer Portal http://localhost:5173 · Admin Portal http://localhost:5174
.\scripts\stop-all.ps1
```

Demo accounts: `customer@credpay.local` / `Customer@123` and `admin@credpay.local` / `Admin@123`.
