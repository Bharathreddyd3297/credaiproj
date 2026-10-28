"""Alertmanager client: the alerts that are firing right now.

Reads Alertmanager's v2 API (kube-prometheus-stack, in-cluster, no auth)
and keeps only active, not silenced/inhibited critical or warning alerts
of one namespace. Info-level alerts (severity "info"/"none", e.g. the
stack's own InfoInhibitor) are housekeeping, not problems.
"""

from __future__ import annotations

from typing import Any

import httpx

from app.config.settings import Settings
from app.utils.logging import get_logger

logger = get_logger(__name__)


class AlertmanagerClientError(Exception):
    """Alertmanager could not be reached or answered with an error."""


class AlertmanagerClient:
    def __init__(self, settings: Settings, transport: httpx.AsyncBaseTransport | None = None):
        self._base_url = settings.alertmanager_url.rstrip("/")
        self._timeout = settings.prometheus_timeout_seconds
        self._transport = transport

    async def active_alerts(self, namespace: str) -> list[dict[str, Any]]:
        """Firing alerts for one namespace, most severe first."""
        params = {"active": "true", "silenced": "false", "inhibited": "false", "filter": f'namespace="{namespace}"'}
        try:
            async with httpx.AsyncClient(timeout=self._timeout, transport=self._transport) as client:
                response = await client.get(f"{self._base_url}/api/v2/alerts", params=params)
                response.raise_for_status()
                raw = response.json()
        except (httpx.HTTPError, ValueError) as exc:
            logger.warning("Alertmanager query failed: %s", exc)
            raise AlertmanagerClientError(str(exc)) from exc

        alerts = []
        for alert in raw:
            labels = alert.get("labels", {})
            if labels.get("severity") not in ("critical", "warning"):
                continue
            annotations = alert.get("annotations", {})
            alerts.append(
                {
                    "name": labels.get("alertname", "unknown"),
                    "severity": labels.get("severity", "none"),
                    "service": labels.get("service") or labels.get("job") or labels.get("deployment") or labels.get("pod"),
                    "summary": annotations.get("summary", ""),
                    "description": annotations.get("description", ""),
                    "runbook": annotations.get("runbook_url", ""),
                    "startsAt": alert.get("startsAt"),
                }
            )
        rank = {"critical": 0, "warning": 1}
        return sorted(alerts, key=lambda a: (rank[a["severity"]], a["name"]))
