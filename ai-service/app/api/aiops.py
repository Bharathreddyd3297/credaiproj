"""AIOps endpoints used by the admin portal's Monitoring page.

GET  /api/ai/overview   health picture of this environment (no AI involved)
POST /api/ai/insight    plain-English briefing: Azure OpenAI or rule-based
"""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Depends, Request

from app.services.aiops_service import AIOpsService

router = APIRouter()


def get_aiops_service(request: Request) -> AIOpsService:
    return request.app.state.aiops_service


@router.get("/overview")
async def overview(service: AIOpsService = Depends(get_aiops_service)) -> dict[str, Any]:
    return await service.overview()


@router.post("/insight")
async def insight(service: AIOpsService = Depends(get_aiops_service)) -> dict[str, Any]:
    return await service.insight()
