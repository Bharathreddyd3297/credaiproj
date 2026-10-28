"""AIOps: one picture of an environment's health, and a summary of it.

overview()  gathers, in parallel and each optional:
              Prometheus    - services up, request rate, error ratio, p95 latency, restarts
              Kubernetes    - deployments and their available replicas
              Alertmanager  - alerts firing now (the ones posted to Slack)
              Dynatrace     - open problems found by Davis AI
            and derives one status: healthy | degraded | down.

insight()   turns the overview into a short operator briefing:
              Azure OpenAI when configured (generatedBy "azure-openai"),
              otherwise deterministic rules (generatedBy "rules") - so the
              admin portal is useful before any AI key is added.
"""

from __future__ import annotations

import asyncio
import json
from datetime import datetime, timezone
from typing import Any

from app.clients.alertmanager_client import AlertmanagerClient, AlertmanagerClientError
from app.clients.dynatrace_client import DynatraceClient, DynatraceClientError
from app.clients.openai_client import AzureOpenAIClient, OpenAIClientError
from app.config.settings import Settings
from app.services.telemetry_collector import TelemetryCollector
from app.utils.logging import get_logger

logger = get_logger(__name__)

# The CREDPAY workloads, in the order the portal shows them
SERVICES = ["keycloak", "user-service", "payment-service", "customer-portal", "admin-portal", "ai-service"]
ERROR_RATIO_THRESHOLD = 0.05   # same thresholds as the PrometheusRules in charts/credpay
LATENCY_P95_THRESHOLD = 1.0    # seconds


def _to_float(value: Any) -> float | None:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return None if number != number else number  # NaN (no traffic) -> None


class AIOpsService:
    def __init__(
        self,
        settings: Settings,
        collector: TelemetryCollector,
        alertmanager: AlertmanagerClient,
        dynatrace: DynatraceClient,
        openai_client: AzureOpenAIClient,
    ):
        self.settings = settings
        self.collector = collector
        self.alertmanager = alertmanager
        self.dynatrace = dynatrace
        self.openai = openai_client

    # ------------------------------------------------------------------
    async def overview(self) -> dict[str, Any]:
        ns = self.settings.kubernetes_namespace
        promql = self.collector.promql
        sources: dict[str, str] = {}

        async def prom(query: str) -> list[dict[str, Any]] | None:
            try:
                return await self.collector.prometheus.query(query)
            except Exception as exc:  # noqa: BLE001 - every source is optional
                logger.warning("overview: prometheus query failed: %s", exc)
                return None

        async def alerts() -> list[dict[str, Any]] | None:
            try:
                return await self.alertmanager.active_alerts(ns)
            except AlertmanagerClientError:
                return None

        async def problems() -> list[dict[str, Any]] | None:
            if not self.dynatrace.is_configured:
                return []
            try:
                return await self.dynatrace.open_problems()
            except DynatraceClientError:
                return None

        up, rate, errors, latency, restarts, firing, dt_problems = await asyncio.gather(
            prom(promql.SERVICES_UP),
            prom(promql.REQUEST_RATE_BY_SERVICE),
            prom(promql.ERROR_RATIO_BY_SERVICE),
            prom(promql.P95_LATENCY_BY_SERVICE),
            prom(promql.RESTARTS_LAST_HOUR),
            alerts(),
            problems(),
        )
        deployments = await asyncio.to_thread(self.collector._safe_k8s_deployments, ns)

        sources["prometheus"] = "ok" if up is not None else "unavailable"
        sources["alertmanager"] = "ok" if firing is not None else "unavailable"
        sources["kubernetes"] = "ok" if deployments else (
            "not_configured" if not self.collector.kubernetes.is_configured else "unavailable"
        )
        sources["dynatrace"] = (
            "not_configured" if not self.dynatrace.is_configured else ("ok" if dt_problems is not None else "unavailable")
        )
        sources["azure_openai"] = "ok" if self.openai.is_configured else "not_configured"

        def by_label(facts: list[dict[str, Any]] | None, label: str) -> dict[str, float | None]:
            return {f["labels"].get(label, ""): _to_float(f["value"]) for f in (facts or []) if f.get("labels")}

        up_by_job = by_label(up, "job")
        rate_by_service = by_label(rate, "service")
        errors_by_service = by_label(errors, "service")
        latency_by_service = by_label(latency, "service")
        deployment_by_name = {d["name"]: d for d in deployments}

        services = []
        for name in SERVICES:
            deployment = deployment_by_name.get(name)
            if deployment is None and name not in up_by_job:
                continue  # not deployed in this environment (e.g. ai-service in dev)
            services.append(
                {
                    "name": name,
                    "up": None if name not in up_by_job else up_by_job[name] == 1,
                    "replicas": None if deployment is None else {
                        "available": deployment["available_replicas"],
                        "desired": deployment["desired_replicas"],
                    },
                    "requestsPerSecond": rate_by_service.get(name),
                    "errorRatio": errors_by_service.get(name),
                    "latencyP95Seconds": latency_by_service.get(name),
                }
            )

        restarting = [
            {"pod": f["labels"].get("pod"), "restarts": _to_float(f["value"])} for f in (restarts or []) if f.get("labels")
        ]

        return {
            "environment": self.settings.environment,
            "namespace": ns,
            "status": self._status(services, firing or [], dt_problems or []),
            "services": services,
            "alerts": firing or [],
            "problems": dt_problems or [],
            "restartingPods": restarting,
            "sources": sources,
            "generatedAt": datetime.now(timezone.utc).isoformat(),
        }

    @staticmethod
    def _status(services: list[dict], alerts: list[dict], problems: list[dict]) -> str:
        if any(s["up"] is False for s in services) or any(a["severity"] == "critical" for a in alerts):
            return "down" if any(s["up"] is False for s in services) else "degraded"
        if alerts or problems or any(
            s["replicas"] and s["replicas"]["available"] < s["replicas"]["desired"] for s in services
        ):
            return "degraded"
        return "healthy"

    # ------------------------------------------------------------------
    async def insight(self) -> dict[str, Any]:
        overview = await self.overview()
        if self.openai.is_configured:
            try:
                text = await asyncio.to_thread(self.openai.generate, self._prompt(overview), max_output_tokens=900)
                return {"summary": text, "generatedBy": "azure-openai", "overview": overview}
            except OpenAIClientError as exc:
                logger.warning("insight: Azure OpenAI failed, falling back to rules: %s", exc)
        return {"summary": self.rule_based_summary(overview), "generatedBy": "rules", "overview": overview}

    @staticmethod
    def _prompt(overview: dict[str, Any]) -> str:
        facts = json.dumps(
            {k: overview[k] for k in ("environment", "namespace", "status", "services", "alerts", "problems", "restartingPods")},
            indent=1,
            default=str,
        )
        return (
            "You are the on-call SRE assistant for CREDPAY, a credit-card bill payment platform "
            "(Keycloak login, Java user-service, Python payment-service, two React portals) on Kubernetes.\n"
            "Using ONLY the facts below, write a briefing for an administrator in plain English:\n"
            "1. One sentence: overall health.\n"
            "2. The most important problem, its likely cause and the user impact (if any).\n"
            "3. Up to three concrete next steps (kubectl commands for the namespace in the facts, "
            "or what to check in Grafana/Dynatrace).\n"
            "Say clearly when there is nothing to do. Do not invent numbers or services. Max 150 words.\n\n"
            f"Facts (JSON):\n{facts}"
        )

    @staticmethod
    def rule_based_summary(overview: dict[str, Any]) -> str:
        env = overview["environment"]
        services = overview["services"]
        alerts = overview["alerts"]
        problems = overview["problems"]
        lines: list[str] = []

        down = [s["name"] for s in services if s["up"] is False]
        short = [
            s["name"] for s in services if s["replicas"] and s["replicas"]["available"] < s["replicas"]["desired"]
        ]
        failing = [
            f"{s['name']} ({s['errorRatio']:.0%} errors)"
            for s in services
            if s["errorRatio"] is not None and s["errorRatio"] > ERROR_RATIO_THRESHOLD
        ]
        slow = [
            f"{s['name']} (p95 {s['latencyP95Seconds']:.2f}s)"
            for s in services
            if s["latencyP95Seconds"] is not None and s["latencyP95Seconds"] > LATENCY_P95_THRESHOLD
        ]

        if overview["status"] == "healthy":
            lines.append(f"{env}: all services are up and no alerts are firing. Nothing to do.")
        else:
            lines.append(f"{env} is {overview['status'].upper()}.")
        if down:
            lines.append(f"Down: {', '.join(down)}.")
        if short:
            lines.append(f"Missing replicas: {', '.join(short)}.")
        if failing:
            lines.append(f"High error rate: {', '.join(failing)}.")
        if slow:
            lines.append(f"Slow: {', '.join(slow)}.")
        if alerts:
            top = alerts[0]
            lines.append(f"{len(alerts)} alert(s) firing; most severe: {top['name']} ({top['severity']}) - {top['summary']}")
        if problems:
            top = problems[0]
            root = f", root cause {top['rootCause']}" if top.get("rootCause") else ""
            lines.append(f"Dynatrace: {len(problems)} open problem(s); latest: {top['title']}{root}.")
        if overview["restartingPods"]:
            pods = ", ".join(p["pod"] for p in overview["restartingPods"][:3])
            lines.append(f"Restarted in the last hour: {pods}.")

        ns = overview["namespace"]
        steps: list[str] = []
        for name in down + [s.split(" ")[0] for s in failing]:
            steps.append(f"kubectl logs -n {ns} deploy/{name} --tail=100")
        for name in short:
            steps.append(f"kubectl describe deploy/{name} -n {ns}  (look at the pod events)")
        if alerts and alerts[0].get("runbook"):
            steps.append(f"Runbook: {alerts[0]['runbook']}")
        if steps:
            lines.append("Next steps: " + "; ".join(dict.fromkeys(steps[:3])))

        unavailable = [k for k, v in overview["sources"].items() if v == "unavailable"]
        if unavailable:
            lines.append(f"(Could not reach: {', '.join(unavailable)} - the picture may be incomplete.)")
        return "\n".join(lines)
