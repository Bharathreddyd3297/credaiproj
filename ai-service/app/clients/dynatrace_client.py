"""Dynatrace client: open problems detected by Davis AI.

Uses the Problems API v2 with an API token (scope problems.read):
  GET {DYNATRACE_URL}/api/v2/problems?problemSelector=status("open")
Optional - when DYNATRACE_URL / DYNATRACE_API_TOKEN are not set the
service simply leaves Dynatrace out.
"""

from __future__ import annotations

from typing import Any

import httpx

from app.config.settings import Settings
from app.utils.logging import get_logger

logger = get_logger(__name__)


class DynatraceClientError(Exception):
    """Dynatrace could not be reached or rejected the request."""


class DynatraceClient:
    def __init__(self, settings: Settings, transport: httpx.AsyncBaseTransport | None = None):
        self._base_url = settings.dynatrace_url.rstrip("/")
        self._token = settings.dynatrace_api_token
        self._timeout = settings.prometheus_timeout_seconds
        self._transport = transport

    @property
    def is_configured(self) -> bool:
        return bool(self._base_url and self._token)

    def problem_link(self, problem_id: str) -> str:
        return f"{self._base_url}/#problems/problemdetails;pid={problem_id}"

    async def open_problems(self, max_results: int = 10) -> list[dict[str, Any]]:
        """Open problems of the last 24 hours, newest first."""
        if not self.is_configured:
            return []
        params = {
            "problemSelector": 'status("open")',
            "from": "now-24h",
            "pageSize": str(max_results),
            "fields": "+evidenceDetails",
        }
        headers = {"Authorization": f"Api-Token {self._token}", "Accept": "application/json"}
        try:
            async with httpx.AsyncClient(timeout=self._timeout, transport=self._transport) as client:
                response = await client.get(f"{self._base_url}/api/v2/problems", params=params, headers=headers)
                response.raise_for_status()
                raw = response.json()
        except (httpx.HTTPError, ValueError) as exc:
            logger.warning("Dynatrace problems query failed: %s", exc)
            raise DynatraceClientError(str(exc)) from exc

        problems = []
        for problem in raw.get("problems", []):
            root_cause = problem.get("rootCauseEntity") or {}
            problems.append(
                {
                    "id": problem.get("displayId") or problem.get("problemId"),
                    "title": problem.get("title", ""),
                    "severity": problem.get("severityLevel", ""),
                    "impact": problem.get("impactLevel", ""),
                    "status": problem.get("status", ""),
                    "rootCause": root_cause.get("name"),
                    "affected": [e.get("name") for e in problem.get("affectedEntities", []) if e.get("name")],
                    "startTime": problem.get("startTime"),
                    "link": self.problem_link(problem.get("problemId", "")),
                }
            )
        return problems
