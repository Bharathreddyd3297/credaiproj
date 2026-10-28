"""Combines every route module into one APIRouter, mounted at /api/ai
in app/main.py.

The health probes are open (Kubernetes calls them without a token);
everything else needs a Keycloak access token with the ADMIN role."""

from fastapi import APIRouter, Depends

from app.api import aiops, chat, health, summary, telemetry
from app.api.auth import require_admin

api_router = APIRouter(prefix="/api/ai", tags=["CredAI"])
api_router.include_router(health.router)

protected = APIRouter(dependencies=[Depends(require_admin)])
protected.include_router(aiops.router)
protected.include_router(chat.router)
protected.include_router(telemetry.router)
protected.include_router(summary.router)
api_router.include_router(protected)
