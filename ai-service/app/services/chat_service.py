"""Chat service - the orchestrator behind POST /api/ai/chat (the admin
portal's "Ask CredAI" page).

For a free-text question it: (1) classifies intent, (2) gathers the
live overview the Monitoring page shows (services, alerts, Dynatrace
problems) plus the facts that fit the intent, (3) asks the Prompt
Builder for one prompt including the conversation so far, and (4) asks
the LLM Connector for the answer.
"""

from __future__ import annotations

import asyncio

from app.clients.openai_client import AzureOpenAIClient
from app.models.schemas import ChatMessage, ChatResponse, ChatSource
from app.prompt_builder.builder import PromptBuilder, UseCase
from app.services.aiops_service import AIOpsService
from app.services.intent_classifier import classify
from app.services.telemetry_collector import TelemetryCollector


class ChatService:
    def __init__(
        self,
        collector: TelemetryCollector,
        aiops: AIOpsService,
        prompt_builder: PromptBuilder,
        llm: AzureOpenAIClient,
    ):
        self._collector = collector
        self._aiops = aiops
        self._prompt_builder = prompt_builder
        self._llm = llm

    @property
    def is_available(self) -> bool:
        return self._llm.is_configured

    async def ask(self, message: str, history: list[ChatMessage]) -> ChatResponse:
        use_case = classify(message)
        if use_case == UseCase.GENERAL_CHAT:
            # A follow-up ("is that within their requests?") keeps the topic
            # of the administrator's previous question
            previous = next((turn.content for turn in reversed(history) if turn.role == "user"), "")
            use_case = classify(previous)
        overview, facts = await asyncio.gather(self._aiops.overview(), self._gather_facts(use_case, message))

        prompt = self._prompt_builder.build_chat(
            overview,
            facts,
            question=message,
            history=[{"role": turn.role, "content": turn.content} for turn in history],
        )
        # The OpenAI SDK call blocks: keep the event loop free for other requests
        reply = await asyncio.to_thread(self._llm.generate, prompt, max_output_tokens=1500)

        # One entry per source: the overview's sources that answered, then any extra ones
        sources = {name: ChatSource(name=name, summary=state) for name, state in overview["sources"].items() if state == "ok"}
        for source in self._summarize_sources(facts):
            sources.setdefault(source.name, source)
        return ChatResponse(reply=reply, sources=list(sources.values()), use_case=use_case.value)

    async def _gather_facts(self, use_case: UseCase, message: str) -> list[dict]:
        if use_case == UseCase.CLUSTER_HEALTH:
            return await self._collector.collect_cluster_facts()
        if use_case == UseCase.BUSINESS_HEALTH:
            return await self._collector.collect_business_facts()
        if use_case == UseCase.CAPACITY:
            return await self._collector.collect_capacity_facts()
        if use_case == UseCase.DEPLOYMENT_ANALYSIS:
            return await self._collector.collect_deployment_facts()
        if use_case == UseCase.DAILY_OPS:
            return await self._collector.collect_daily_ops_facts()
        if use_case == UseCase.ROOT_CAUSE:
            return await self._collector.collect_root_cause_facts(message)

        # GENERAL_CHAT - no specific use case matched; the overview plus a
        # cluster snapshot (pods, events, nodes) covers most questions.
        return await self._collector.collect_cluster_facts()

    @staticmethod
    def _summarize_sources(facts: list[dict]) -> list[ChatSource]:
        counts: dict[str, int] = {}
        for fact in facts:
            source = fact.get("source", "unknown")
            counts[source] = counts.get(source, 0) + 1
        return [ChatSource(name=source, summary=f"{count} fact(s)") for source, count in counts.items()]
