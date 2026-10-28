"""Prometheus client.

Talks directly to the existing Prometheus server's HTTP API
(http://prometheus.monitoring.svc.cluster.local:9090) - the
kube-prometheus-stack installed by the CD pipeline (docs/OBSERVABILITY.md).
This client is intentionally a thin, dependency-light HTTP wrapper
(httpx) rather than a heavier third-party PromQL library - Prometheus's
own HTTP API is simple enough that no extra abstraction is needed, and
this avoids taking on a dependency whose own maintenance/versioning is
outside our control.

Isolation: this module knows nothing about Kubernetes, Azure, or the
LLM - it only knows how to ask Prometheus a PromQL question and hand
back a normalized answer.
"""

from __future__ import annotations

import httpx

from app.config.settings import Settings
from app.utils.logging import get_logger
from app.utils.normalizer import normalize_prometheus_result

logger = get_logger(__name__)


class PrometheusClientError(Exception):
    """Raised when Prometheus cannot be reached or returns an error."""


class PrometheusClient:
    def __init__(self, settings: Settings):
        self._base_url = settings.prometheus_url.rstrip("/")
        self._timeout = settings.prometheus_timeout_seconds

    async def query(self, promql: str, metric_name: str | None = None) -> list[dict]:
        """Runs an instant PromQL query and returns normalized facts.

        `metric_name` is a short human-readable description (e.g. "Node
        CPU utilization %") embedded into each fact's label - see
        normalize_prometheus_result for why this matters.
        """
        url = f"{self._base_url}/api/v1/query"
        try:
            async with httpx.AsyncClient(timeout=self._timeout) as client:
                response = await client.get(url, params={"query": promql})
                response.raise_for_status()
        except httpx.HTTPError as exc:
            logger.warning("Prometheus query failed: %s (%s)", promql, exc)
            raise PrometheusClientError(f"Prometheus query failed: {exc}") from exc

        payload = response.json()
        if payload.get("status") != "success":
            raise PrometheusClientError(f"Prometheus returned non-success status: {payload}")

        return normalize_prometheus_result(payload, promql, metric_name)

    async def query_scalar(self, promql: str) -> float | None:
        """Convenience helper for queries expected to return exactly one value."""
        facts = await self.query(promql)
        if not facts:
            return None
        try:
            return float(facts[0]["value"])
        except (TypeError, ValueError):
            return None

    async def is_healthy(self) -> bool:
        try:
            async with httpx.AsyncClient(timeout=self._timeout) as client:
                response = await client.get(f"{self._base_url}/-/healthy")
                return response.status_code == 200
        except httpx.HTTPError:
            return False


# --- Well-known queries this service relies on, kept in one place so
# they're easy to audit. ---

class PromQL:
    """Named PromQL queries for one CREDPAY environment (= one namespace).

    Keeps the raw query strings out of the services layer. Every query is
    scoped to the environment's namespace; the HTTP metrics come from the
    ServiceMonitors in charts/credpay (Spring Boot: http_server_requests_*,
    FastAPI: http_requests_total / http_request_duration_seconds_*)."""

    def __init__(self, namespace: str):
        ns = f'namespace="{namespace}"'
        self.UNHEALTHY_PODS = f'kube_pod_status_phase{{{ns}, phase!="Running", phase!="Succeeded"}} == 1'
        self.POD_RESTARTS_TOTAL = f"sum(kube_pod_container_status_restarts_total{{{ns}}})"
        self.DEPLOYMENT_AVAILABILITY = (
            f"kube_deployment_status_replicas_available{{{ns}}} "
            f"/ kube_deployment_spec_replicas{{{ns}}} * 100"
        )
        # Node-level queries are cluster-wide on purpose
        self.NODE_CPU_PERCENT = (
            '100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)'
        )
        self.NODE_MEMORY_AVAILABLE_PERCENT = (
            "avg by (instance) (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes * 100)"
        )
        self.HIGHEST_CPU_DEPLOYMENT = (
            "topk(1, sum(rate(container_cpu_usage_seconds_total"
            f'{{{ns}, container!="", image!=""}}[5m])) by (pod)) * 1000'
        )
        # Capacity planning: usage vs configured requests, per pod, plus HPA ceiling
        self.ALL_PODS_CPU_USAGE_MILLICORES = (
            "sum(rate(container_cpu_usage_seconds_total"
            f'{{{ns}, container!="", image!=""}}[5m])) by (pod) * 1000'
        )
        self.ALL_PODS_MEMORY_USAGE_MIB = (
            f'sum(container_memory_working_set_bytes{{{ns}, container!="", image!=""}}) '
            "by (pod) / 1024 / 1024"
        )
        self.POD_CPU_REQUESTS_MILLICORES = (
            f'sum(kube_pod_container_resource_requests{{{ns}, resource="cpu"}}) by (pod) * 1000'
        )
        self.POD_MEMORY_REQUESTS_MIB = (
            f'sum(kube_pod_container_resource_requests{{{ns}, resource="memory"}}) '
            "by (pod) / 1024 / 1024"
        )
        self.HPA_CURRENT_REPLICAS = (
            f"sum(kube_horizontalpodautoscaler_status_current_replicas{{{ns}}}) "
            "by (horizontalpodautoscaler)"
        )
        self.HPA_MAX_REPLICAS = (
            f"sum(kube_horizontalpodautoscaler_spec_max_replicas{{{ns}}}) "
            "by (horizontalpodautoscaler)"
        )
        # FastAPI groups status codes as 2xx/4xx/5xx
        self.PAYMENT_ERROR_RATE = (
            f'sum(rate(http_requests_total{{{ns}, status="5xx"}}[5m])) by (handler)'
        )
        self.PAYMENT_SUCCESS_RATE = (
            f'sum(rate(http_requests_total{{{ns}, status="2xx"}}[1h])) '
            f"/ sum(rate(http_requests_total{{{ns}}}[1h])) * 100"
        )
        self.USER_SERVICE_P95_LATENCY = (
            "histogram_quantile(0.95, sum(rate(http_server_requests_seconds_bucket"
            f"{{{ns}}}[5m])) by (le, uri))"
        )
        self.TOTAL_REQUEST_RATE = (
            f"sum(rate(http_server_requests_seconds_count{{{ns}}}[1h])) "
            f"+ sum(rate(http_requests_total{{{ns}}}[1h]))"
        )
        # --- AIOps overview (recording rules from charts/credpay monitoring) ---
        self.SERVICES_UP = f'min by (job) (up{{{ns}}})'
        # User traffic only: health checks and metrics scrapes left out
        spring = 'uri!~"/actuator.*|/health.*|/metrics"'
        fast = 'handler!~"/health.*|/metrics"'
        self.REQUEST_RATE_BY_SERVICE = (
            f"sum by (service) (rate(http_server_requests_seconds_count{{{ns}, {spring}}}[5m])) "
            f"or sum by (service) (rate(http_requests_total{{{ns}, {fast}}}[5m]))"
        )
        self.ERROR_RATIO_BY_SERVICE = f"credpay:http_error_ratio:rate5m{{{ns}}}"
        self.P95_LATENCY_BY_SERVICE = f"credpay:http_latency_p95:rate5m{{{ns}}}"
        self.RESTARTS_LAST_HOUR = (
            f"sum by (pod) (increase(kube_pod_container_status_restarts_total{{{ns}}}[1h])) > 0"
        )
