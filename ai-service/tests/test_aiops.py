"""AIOps API: access rules, overview, rule-based insight and the clients
(no Prometheus, Kubernetes, Dynatrace or Azure OpenAI needed)."""

import asyncio
import json

import httpx
import pytest
from fastapi.testclient import TestClient

from app.api.auth import token_claims
from app.clients.alertmanager_client import AlertmanagerClient
from app.clients.dynatrace_client import DynatraceClient
from app.clients.openai_client import AzureOpenAIClient
from app.clients.prometheus_client import PromQL
from app.config.settings import Settings
from app.main import app
from app.services.aiops_service import AIOpsService
from app.prompt_builder.builder import UseCase
from app.services.chat_service import ChatService
from app.services.intent_classifier import classify
from app.services.telemetry_collector import TelemetryCollector


@pytest.fixture
def client():
    with TestClient(app) as test_client:
        yield test_client
    app.dependency_overrides.clear()


def signed_in_as(*roles):
    app.dependency_overrides[token_claims] = lambda: {"sub": "test", "realm_access": {"roles": list(roles)}}


# ---- Access ------------------------------------------------------------
def test_probes_need_no_token(client):
    assert client.get("/api/ai/live").status_code == 200
    assert client.get("/api/ai/health").status_code == 200


@pytest.mark.parametrize("method,path", [("get", "/api/ai/overview"), ("post", "/api/ai/insight"), ("post", "/api/ai/chat")])
def test_api_requires_a_token(client, method, path):
    response = getattr(client, method)(path)
    assert response.status_code == 401
    assert response.headers["www-authenticate"] == "Bearer"


def test_rejects_a_forged_token(client):
    assert client.get("/api/ai/overview", headers={"Authorization": "Bearer not.a.jwt"}).status_code == 401


def test_customers_are_refused(client):
    signed_in_as("USER")
    assert client.get("/api/ai/overview").status_code == 403


def test_admins_get_an_overview(client, monkeypatch):
    async def fake_overview(self):
        return {"status": "healthy"}

    monkeypatch.setattr(AIOpsService, "overview", fake_overview)
    signed_in_as("ADMIN")
    response = client.get("/api/ai/overview")
    assert response.status_code == 200
    assert response.json() == {"status": "healthy"}


# ---- Overview + rule-based insight --------------------------------------
def fact(labels, value):
    return {"source": "prometheus", "label": "", "value": value, "labels": labels}


class FakePrometheus:
    def __init__(self, results):
        self.results = results

    async def query(self, promql, metric_name=None):
        return self.results.get(promql, [])


class FakeKubernetes:
    is_configured = True


class FakeCollector:
    def __init__(self, settings, results, deployments):
        self.promql = PromQL(settings.kubernetes_namespace)
        self.prometheus = FakePrometheus(results(self.promql))
        self.kubernetes = FakeKubernetes()
        self._deployments = deployments

    def _safe_k8s_deployments(self, namespace):
        return self._deployments


class FakeAlertmanager:
    def __init__(self, alerts):
        self.alerts = alerts

    async def active_alerts(self, namespace):
        return self.alerts


class FakeDynatrace:
    is_configured = False


class FakeOpenAI:
    is_configured = False


def make_service(results, deployments, alerts):
    settings = Settings(KUBERNETES_NAMESPACE="credpay-prod", environment="prod")
    collector = FakeCollector(settings, results, deployments)
    return AIOpsService(settings, collector, FakeAlertmanager(alerts), FakeDynatrace(), FakeOpenAI())


def deployment(name, available, desired):
    return {"name": name, "namespace": "credpay-prod", "available_replicas": available, "desired_replicas": desired, "ready": available >= desired}


def test_healthy_environment():
    service = make_service(
        lambda q: {
            q.SERVICES_UP: [fact({"job": "user-service"}, "1"), fact({"job": "payment-service"}, "1")],
            q.ERROR_RATIO_BY_SERVICE: [fact({"service": "payment-service"}, "0")],
        },
        [deployment("user-service", 2, 2), deployment("payment-service", 2, 2)],
        [],
    )
    insight = asyncio.run(service.insight())
    assert insight["overview"]["status"] == "healthy"
    assert insight["generatedBy"] == "rules"
    assert "Nothing to do" in insight["summary"]


def test_failing_service_is_reported_with_next_steps():
    alert = {
        "name": "CredpayHighErrorRate", "severity": "critical", "service": "payment-service",
        "summary": "payment-service: more than 5% of requests fail in prod", "description": "", "runbook": "", "startsAt": None,
    }
    service = make_service(
        lambda q: {
            q.SERVICES_UP: [fact({"job": "payment-service"}, "1")],
            q.ERROR_RATIO_BY_SERVICE: [fact({"service": "payment-service"}, "0.25")],
            q.P95_LATENCY_BY_SERVICE: [fact({"service": "payment-service"}, "NaN")],
        },
        [deployment("payment-service", 1, 2)],
        [alert],
    )
    insight = asyncio.run(service.insight())
    overview = insight["overview"]
    assert overview["status"] == "degraded"
    payment = overview["services"][0]
    assert payment["errorRatio"] == 0.25 and payment["latencyP95Seconds"] is None  # NaN = no traffic
    assert "High error rate: payment-service (25% errors)" in insight["summary"]
    assert "Missing replicas: payment-service" in insight["summary"]
    assert "kubectl logs -n credpay-prod deploy/payment-service" in insight["summary"]


def test_down_service_makes_the_environment_down():
    service = make_service(lambda q: {q.SERVICES_UP: [fact({"job": "keycloak"}, "0")]}, [], [])
    overview = asyncio.run(service.overview())
    assert overview["status"] == "down"
    assert overview["services"] == [
        {"name": "keycloak", "up": False, "replicas": None, "requestsPerSecond": None, "errorRatio": None, "latencyP95Seconds": None}
    ]


def test_queries_are_scoped_to_the_environment():
    promql = PromQL("credpay-qa")
    assert 'namespace="credpay-qa"' in promql.SERVICES_UP
    assert 'namespace="credpay-qa"' in promql.PAYMENT_ERROR_RATE
    assert "kubernetes-pods" not in promql.TOTAL_REQUEST_RATE


# ---- Clients against mocked HTTP ---------------------------------------------
def test_alertmanager_client_filters_and_sorts():
    seen = {}

    def handler(request: httpx.Request):
        seen["filter"] = request.url.params["filter"]
        return httpx.Response(200, json=[
            {"labels": {"alertname": "CredpayHighLatency", "severity": "warning", "service": "user-service"},
             "annotations": {"summary": "slow"}, "startsAt": "2026-10-25T10:00:00Z"},
            {"labels": {"alertname": "CredpayServiceDown", "severity": "critical", "job": "keycloak"},
             "annotations": {"summary": "down", "runbook_url": "https://runbook"}, "startsAt": "2026-10-25T10:01:00Z"},
            # info-level housekeeping alerts are not problems
            {"labels": {"alertname": "InfoInhibitor", "severity": "none"}, "annotations": {}},
            {"labels": {"alertname": "CPUThrottlingHigh", "severity": "info"}, "annotations": {}},
        ])

    settings = Settings(ALERTMANAGER_URL="http://am:9093")
    alerts = asyncio.run(AlertmanagerClient(settings, httpx.MockTransport(handler)).active_alerts("credpay-prod"))
    assert seen["filter"] == 'namespace="credpay-prod"'
    assert [a["name"] for a in alerts] == ["CredpayServiceDown", "CredpayHighLatency"]
    assert alerts[0]["service"] == "keycloak" and alerts[0]["runbook"] == "https://runbook"


def test_dynatrace_client_reads_open_problems():
    def handler(request: httpx.Request):
        assert request.headers["authorization"] == "Api-Token dt0c01.test"
        assert request.url.params["problemSelector"] == 'status("open")'
        return httpx.Response(200, json={"problems": [{
            "problemId": "-123_456V2", "displayId": "P-2610", "title": "Response time degradation",
            "severityLevel": "PERFORMANCE", "impactLevel": "SERVICES", "status": "OPEN",
            "rootCauseEntity": {"name": "payment-service"}, "affectedEntities": [{"name": "payment-service"}],
            "startTime": 1761386400000,
        }]})

    settings = Settings(DYNATRACE_URL="https://abc123.live.dynatrace.com/", DYNATRACE_API_TOKEN="dt0c01.test")
    problems = asyncio.run(DynatraceClient(settings, httpx.MockTransport(handler)).open_problems())
    assert problems[0]["id"] == "P-2610"
    assert problems[0]["rootCause"] == "payment-service"
    assert problems[0]["link"] == "https://abc123.live.dynatrace.com/#problems/problemdetails;pid=-123_456V2"


def test_dynatrace_is_skipped_when_not_configured():
    assert asyncio.run(DynatraceClient(Settings(DYNATRACE_URL="", DYNATRACE_API_TOKEN="")).open_problems()) == []


def test_prompt_contains_only_the_facts():
    prompt = AIOpsService._prompt({"environment": "prod", "namespace": "credpay-prod", "status": "healthy",
                                   "services": [], "alerts": [], "problems": [], "restartingPods": []})
    facts = json.loads(prompt.split("Facts (JSON):\n", 1)[1])
    assert facts["status"] == "healthy"
    assert facts["namespace"] == "credpay-prod"  # so suggested kubectl commands use the right namespace


# ---- Chat ("Ask CredAI" page) ---------------------------------------------
OVERVIEW = {"environment": "prod", "namespace": "credpay-prod", "status": "degraded", "services": [],
            "alerts": [{"name": "CredpayHighErrorRate", "severity": "warning", "summary": "payment-service 7% errors"}],
            "problems": [], "restartingPods": [], "sources": {"prometheus": "ok", "dynatrace": "not_configured"},
            "generatedAt": "2026-10-27T10:00:00+00:00"}


def test_chat_needs_azure_openai(client, monkeypatch):
    monkeypatch.setattr(ChatService, "is_available", property(lambda self: False))
    signed_in_as("ADMIN")
    response = client.post("/api/ai/chat", json={"message": "Is prod healthy?"})
    assert response.status_code == 503
    assert "Azure OpenAI" in response.json()["detail"]


def test_chat_answers_from_the_live_overview(client, monkeypatch):
    prompts = []

    async def fake_overview(self):
        return OVERVIEW

    async def fake_cluster_facts(self):
        return [{"source": "kubernetes", "label": "pod payment-service-abc phase", "value": "Running"}]

    def fake_generate(self, prompt, *, max_output_tokens=3500):
        prompts.append(prompt)
        return "One alert is firing: CredpayHighErrorRate."

    monkeypatch.setattr(ChatService, "is_available", property(lambda self: True))
    monkeypatch.setattr(AIOpsService, "overview", fake_overview)
    monkeypatch.setattr(TelemetryCollector, "collect_cluster_facts", fake_cluster_facts)
    monkeypatch.setattr(AzureOpenAIClient, "generate", fake_generate)
    signed_in_as("ADMIN")

    response = client.post("/api/ai/chat", json={
        "message": "Which alert is firing?",
        "history": [{"role": "user", "content": "Hi"}, {"role": "assistant", "content": "Hello, ask me about prod."}],
    })
    assert response.status_code == 200
    assert response.json()["reply"] == "One alert is firing: CredpayHighErrorRate."
    assert {s["name"] for s in response.json()["sources"]} == {"prometheus", "kubernetes"}

    prompt = prompts[0]
    assert "namespace credpay-prod" in prompt
    assert "CredpayHighErrorRate" in prompt                  # the live overview
    assert "pod payment-service-abc phase = Running" in prompt  # the question's facts
    assert "CredAI: Hello, ask me about prod." in prompt      # the conversation so far
    assert prompt.endswith("Administrator: Which alert is firing?\nCredAI:")


def test_chat_rejects_an_empty_question(client):
    signed_in_as("ADMIN")
    assert client.post("/api/ai/chat", json={"message": ""}).status_code == 422


@pytest.mark.parametrize("question,use_case", [
    ("Which pods use the most CPU and memory?", UseCase.CAPACITY),
    ("Is the HPA close to its maximum?", UseCase.CAPACITY),
    ("Why could payments be slow?", UseCase.ROOT_CAUSE),
    ("How many payment requests failed?", UseCase.BUSINESS_HEALTH),
    ("Is prod healthy right now?", UseCase.GENERAL_CHAT),
])
def test_questions_pick_the_right_facts(question, use_case):
    assert classify(question) == use_case


def test_a_follow_up_keeps_the_topic_and_sources_are_listed_once(client, monkeypatch):
    collected = []

    async def fake_overview(self):
        return OVERVIEW

    async def fake_capacity_facts(self):
        collected.append("capacity")
        return [{"source": "prometheus", "label": "Pod CPU usage", "value": "12"}]

    monkeypatch.setattr(ChatService, "is_available", property(lambda self: True))
    monkeypatch.setattr(AIOpsService, "overview", fake_overview)
    monkeypatch.setattr(TelemetryCollector, "collect_capacity_facts", fake_capacity_facts)
    monkeypatch.setattr(AzureOpenAIClient, "generate", lambda self, prompt, **kw: "Yes.")
    signed_in_as("ADMIN")

    response = client.post("/api/ai/chat", json={
        "message": "Is that within their requests?",
        "history": [{"role": "user", "content": "Which pods use the most CPU?"}, {"role": "assistant", "content": "..."}],
    })
    assert response.json()["use_case"] == "capacity_recommendations"
    assert collected == ["capacity"]
    assert [s["name"] for s in response.json()["sources"]] == ["prometheus"]
