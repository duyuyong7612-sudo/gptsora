# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-ca16463ae421ab7810f89c860b934aa827490eaa5c691ecd508cb99ed1557061"
# Source-SHA256: "1bc7e6131f0ef8a52c0faa911bb7b2445c8240f9837e8d3f0b75751cc7ba12dd"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
ChatAGI BrainCore v3.2 Embodied Projection
======================
A production-oriented brain core for Adu / ChatAGI.

Design target
-------------
This module is meant to be mounted inside the existing FastAPI backend. It does
NOT execute tools on the cloud machine. All computer actions are routed through
an injected local-agent callable or through LOCAL_AGENT_BASE_URL.

Core loop
---------
perceive/recall -> tensor blackboard -> tensor route -> plan -> risk gate -> local-agent body
-> observe -> tensor critique -> tensor arbitrate -> async memory/state write -> trace
+ embodied projection loop: body/world observation -> belief tensor -> imagined rollouts
-> target-state/skill control -> feedback error -> blackboard.

Dependencies
------------
pip install httpx fastapi pydantic numpy

Environment variables
---------------------
OPENAI_API_KEY / ANTHROPIC_API_KEY / DEEPSEEK_API_KEY / DASHSCOPE_API_KEY
LOCAL_AGENT_BASE_URL       default http://127.0.0.1:18789
LOCAL_AGENT_TOKEN          optional bearer token
BRAIN_RACE_TIMEOUT         default 25
BRAIN_CRITIC_TIMEOUT       default 18
BRAIN_MAX_REDOS            default 1
BRAIN_TENSOR_EMBED_DIM     default 64

Integration in server_session.py
--------------------------------
from chatagi_brain_core_v3_2_embodied_projection import router as brain_core_router, configure_brain_core

configure_brain_core(
    memory_engine=MEMORY_ENGINE,
    brain_state_engine=BRAIN_STATE_ENGINE,
    local_agent_callable=_call_local_agent,  # async def(method, path, body=None)
)
app.include_router(brain_core_router)
"""

from __future__ import annotations

import asyncio
import copy
import hashlib
import json
import logging
import math
import os
import re
import time
import uuid
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Awaitable, Callable, Dict, Iterable, List, Mapping, Optional, Tuple

import httpx

try:
    import numpy as np
except Exception:  # noqa: BLE001
    np = None  # type: ignore[assignment]

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

log = logging.getLogger("chatagi.brain_core")


# =============================================================================
# 0. Model registry: heterogeneity is a first-class safety property
# =============================================================================


class Provider(str, Enum):
    OPENAI = "openai"
    ANTHROPIC = "anthropic"
    DEEPSEEK = "deepseek"
    DASHSCOPE = "dashscope"


@dataclass(frozen=True)
class ModelSpec:
    provider: Provider
    model_id: str
    family: str
    role: str = ""


DEFAULT_REGISTRY: Dict[str, ModelSpec] = {
    # Keep ids overridable by env. Defaults mirror Adu's current mixed-provider stack.
    "planner": ModelSpec(Provider.DEEPSEEK, os.getenv("BRAIN_MODEL_PLANNER", "deepseek-chat"), "deepseek", "planner"),
    "general": ModelSpec(Provider.DASHSCOPE, os.getenv("BRAIN_MODEL_GENERAL", "qwen-max"), "qwen", "general"),
    "web": ModelSpec(Provider.OPENAI, os.getenv("BRAIN_MODEL_WEB", "gpt-4o"), "openai", "web"),
    "critic_a": ModelSpec(Provider.ANTHROPIC, os.getenv("BRAIN_MODEL_CRITIC_A", "claude-opus-4-20250514"), "anthropic", "critic"),
    "critic_b": ModelSpec(Provider.OPENAI, os.getenv("BRAIN_MODEL_CRITIC_B", "gpt-4o"), "openai", "critic"),
    "arbiter": ModelSpec(Provider.ANTHROPIC, os.getenv("BRAIN_MODEL_ARBITER", "claude-opus-4-20250514"), "anthropic", "arbiter"),
    "scorer": ModelSpec(Provider.DEEPSEEK, os.getenv("BRAIN_MODEL_SCORER", "deepseek-chat"), "deepseek", "scorer"),
}


class LLMError(RuntimeError):
    pass


class JsonContractError(RuntimeError):
    pass


class LLMClient:
    def __init__(self, registry: Optional[Dict[str, ModelSpec]] = None):
        self.registry = registry or dict(DEFAULT_REGISTRY)

    def has_provider_key(self, provider: Provider) -> bool:
        env = {
            Provider.OPENAI: "OPENAI_API_KEY",
            Provider.ANTHROPIC: "ANTHROPIC_API_KEY",
            Provider.DEEPSEEK: "DEEPSEEK_API_KEY",
            Provider.DASHSCOPE: "DASHSCOPE_API_KEY",
        }[provider]
        return bool(os.getenv(env))

    def available_role(self, preferred: str, fallback: Iterable[str] = ("general", "planner", "web")) -> str:
        candidates = [preferred, *fallback]
        for role in candidates:
            spec = self.registry.get(role)
            if spec and self.has_provider_key(spec.provider):
                return role
        raise LLMError("No configured model provider API key is available.")

    async def call(
        self,
        role_key: str,
        system: str,
        prompt: str,
        *,
        max_tokens: int = 2048,
        timeout: float = 60.0,
        retries: int = 1,
    ) -> str:
        role_key = self.available_role(role_key)
        spec = self.registry[role_key]
        last_err: Optional[BaseException] = None
        for attempt in range(retries + 1):
            try:
                return await self._dispatch(spec, system, prompt, max_tokens=max_tokens, timeout=timeout)
            except Exception as e:  # noqa: BLE001
                last_err = e
                if attempt >= retries:
                    break
                await asyncio.sleep(min(2.0, 0.35 * (2**attempt)))
        raise LLMError(f"{role_key} failed after retries: {last_err}")

    async def call_json(
        self,
        role_key: str,
        system: str,
        prompt: str,
        *,
        schema_hint: str,
        max_tokens: int = 2048,
        timeout: float = 60.0,
        retries: int = 1,
    ) -> Dict[str, Any]:
        sys2 = (
            system
            + "\n\n只输出一个 JSON 对象，不要 markdown，不要解释。"
            + "\nJSON 结构要求："
            + schema_hint
        )
        text = await self.call(role_key, sys2, prompt, max_tokens=max_tokens, timeout=timeout, retries=retries)
        return _extract_json_object(text)

    async def _dispatch(self, spec: ModelSpec, system: str, prompt: str, *, max_tokens: int, timeout: float) -> str:
        async with httpx.AsyncClient(timeout=timeout) as client:
            if spec.provider == Provider.ANTHROPIC:
                key = os.environ["ANTHROPIC_API_KEY"]
                r = await client.post(
                    os.getenv("ANTHROPIC_BASE_URL", "https://api.anthropic.com") + "/v1/messages",
                    headers={
                        "x-api-key": key,
                        "anthropic-version": os.getenv("ANTHROPIC_VERSION", "2023-06-01"),
                        "content-type": "application/json",
                    },
                    json={
                        "model": spec.model_id,
                        "system": system,
                        "max_tokens": max_tokens,
                        "messages": [{"role": "user", "content": prompt}],
                    },
                )
                r.raise_for_status()
                data = r.json()
                return "".join(part.get("text", "") for part in data.get("content", []) if part.get("type") in (None, "text"))

            if spec.provider == Provider.OPENAI:
                key = os.environ["OPENAI_API_KEY"]
                base = os.getenv("OPENAI_BASE_URL", "https://api.openai.com")
                r = await client.post(
                    base.rstrip("/") + "/v1/chat/completions",
                    headers={"authorization": f"Bearer {key}", "content-type": "application/json"},
                    json={
                        "model": spec.model_id,
                        "max_tokens": max_tokens,
                        "messages": [
                            {"role": "system", "content": system},
                            {"role": "user", "content": prompt},
                        ],
                    },
                )
                r.raise_for_status()
                return r.json()["choices"][0]["message"]["content"] or ""

            if spec.provider == Provider.DEEPSEEK:
                key = os.environ["DEEPSEEK_API_KEY"]
                base = os.getenv("DEEPSEEK_BASE_URL", "https://api.deepseek.com")
                r = await client.post(
                    base.rstrip("/") + "/chat/completions",
                    headers={"authorization": f"Bearer {key}", "content-type": "application/json"},
                    json={
                        "model": spec.model_id,
                        "max_tokens": max_tokens,
                        "messages": [
                            {"role": "system", "content": system},
                            {"role": "user", "content": prompt},
                        ],
                    },
                )
                r.raise_for_status()
                return r.json()["choices"][0]["message"]["content"] or ""

            if spec.provider == Provider.DASHSCOPE:
                key = os.environ["DASHSCOPE_API_KEY"]
                base = os.getenv("DASHSCOPE_BASE_URL", "https://dashscope.aliyuncs.com/compatible-mode")
                r = await client.post(
                    base.rstrip("/") + "/v1/chat/completions",
                    headers={"authorization": f"Bearer {key}", "content-type": "application/json"},
                    json={
                        "model": spec.model_id,
                        "max_tokens": max_tokens,
                        "messages": [
                            {"role": "system", "content": system},
                            {"role": "user", "content": prompt},
                        ],
                    },
                )
                r.raise_for_status()
                return r.json()["choices"][0]["message"]["content"] or ""

        raise LLMError(f"unknown provider: {spec.provider}")


# =============================================================================
# 1. Data contracts
# =============================================================================


class BrainInput(BaseModel):
    text: str = Field(..., description="User task / signal.")
    user_key: str = Field(default="default")
    conversation_id: str = Field(default="")
    context: Dict[str, Any] = Field(default_factory=dict)
    allow_tools: bool = True
    allow_web: bool = False
    dry_run: bool = False
    confirmation_token: str = ""
    max_tokens: int = 2048
    # ✅ 视觉输入(可选):有图或视觉意图时,handle 会先调 Vision Core 看图。
    image_b64: str = Field(default="")
    vision_source: str = Field(default="")   # computer_screenshot|image_upload|camera_frame
    visual_goal: str = Field(default="")


class BrainOutput(BaseModel):
    ok: bool
    trace_id: str
    result: str
    answer: str
    confidence: float = 0.0
    requires_confirmation: bool = False
    instruction: Optional[Dict[str, Any]] = None
    tool_result: Optional[Dict[str, Any]] = None
    state: Dict[str, Any] = Field(default_factory=dict)
    trace: List[Dict[str, Any]] = Field(default_factory=list)
    tensor: Dict[str, Any] = Field(default_factory=dict)


class Risk(str, Enum):
    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"
    BLOCKED = "blocked"


@dataclass
class Decision:
    role_key: str
    risk: Risk
    need_tool: bool
    need_web: bool
    need_critic: bool
    requires_confirmation: bool
    intent: Dict[str, Any] = field(default_factory=dict)
    route_reason: str = ""


@dataclass
class Draft:
    answer: str
    confidence: float
    plan: Dict[str, Any] = field(default_factory=dict)
    instruction: Optional[Dict[str, Any]] = None
    tool_result: Optional[Dict[str, Any]] = None


@dataclass
class Critique:
    critic: str
    family: str
    objection: str
    severity: float


@dataclass
class Verdict:
    result: str  # accept / revise / confirm / fail
    answer: str
    confidence: float
    reason: str
    requires_confirmation: bool = False


@dataclass
class Trace:
    trace_id: str
    t0: float = field(default_factory=time.perf_counter)
    events: List[Dict[str, Any]] = field(default_factory=list)

    def mark(self, stage: str, **info: Any) -> None:
        self.events.append({"stage": stage, "ms": round((time.perf_counter() - self.t0) * 1000, 1), **info})


# =============================================================================
# 1.5. Tensor math substrate
# =============================================================================


class TensorMath:
    """Small tensor algebra layer used everywhere in the brain loop.

    The code prefers numpy when available, but every method returns JSON-safe
    Python floats/lists so the blackboard, traces and API responses stay simple.
    """

    @staticmethod
    def vec(values: Any, dim: Optional[int] = None, fill: float = 0.0) -> List[float]:
        if values is None:
            out: List[float] = []
        elif isinstance(values, dict):
            out = [_floatish(v, 0.0) for v in values.values()]
        elif isinstance(values, (list, tuple)):
            out = [_floatish(v, 0.0) for v in values]
        else:
            out = [_floatish(values, 0.0)]
        if dim is not None:
            if len(out) < dim:
                out.extend([fill] * (dim - len(out)))
            if len(out) > dim:
                out = out[:dim]
        return [float(x) for x in out]

    @staticmethod
    def zeros(dim: int) -> List[float]:
        return [0.0] * max(0, int(dim))

    @staticmethod
    def clamp01(v: float) -> float:
        return max(0.0, min(1.0, float(v)))

    @staticmethod
    def l2_normalize(v: Any, eps: float = 1e-9) -> List[float]:
        arr = TensorMath.vec(v)
        if not arr:
            return []
        if np is not None:
            a = np.asarray(arr, dtype=float)
            n = float(np.linalg.norm(a))
            if n <= eps:
                return [0.0 for _ in arr]
            return [float(x) for x in (a / n).tolist()]
        n = math.sqrt(sum(x * x for x in arr))
        if n <= eps:
            return [0.0 for _ in arr]
        return [float(x / n) for x in arr]

    @staticmethod
    def sum_normalize(v: Any, eps: float = 1e-9) -> List[float]:
        arr = [max(0.0, float(x)) for x in TensorMath.vec(v)]
        s = sum(arr)
        if s <= eps:
            return [1.0 / len(arr) for _ in arr] if arr else []
        return [float(x / s) for x in arr]

    @staticmethod
    def softmax(v: Any, temperature: float = 1.0) -> List[float]:
        arr = TensorMath.vec(v)
        if not arr:
            return []
        t = max(1e-6, float(temperature))
        if np is not None:
            a = np.asarray(arr, dtype=float) / t
            a = a - float(np.max(a))
            e = np.exp(a)
            s = float(np.sum(e)) or 1.0
            return [float(x) for x in (e / s).tolist()]
        m = max(arr)
        e = [math.exp((x - m) / t) for x in arr]
        s = sum(e) or 1.0
        return [float(x / s) for x in e]

    @staticmethod
    def dot(a: Any, b: Any) -> float:
        av = TensorMath.vec(a)
        bv = TensorMath.vec(b, dim=len(av))
        if np is not None:
            return float(np.dot(np.asarray(av, dtype=float), np.asarray(bv, dtype=float)))
        return float(sum(x * y for x, y in zip(av, bv)))

    @staticmethod
    def cosine(a: Any, b: Any, eps: float = 1e-9) -> float:
        av = TensorMath.vec(a)
        bv = TensorMath.vec(b, dim=len(av))
        if not av or not bv:
            return 0.0
        if np is not None:
            aa = np.asarray(av, dtype=float)
            bb = np.asarray(bv, dtype=float)
            denom = float(np.linalg.norm(aa) * np.linalg.norm(bb))
            return 0.0 if denom <= eps else float(np.dot(aa, bb) / denom)
        na = math.sqrt(sum(x * x for x in av))
        nb = math.sqrt(sum(x * x for x in bv))
        return 0.0 if na * nb <= eps else float(sum(x * y for x, y in zip(av, bv)) / (na * nb))

    @staticmethod
    def entropy(prob: Any, eps: float = 1e-12) -> float:
        p = TensorMath.sum_normalize(prob)
        if not p:
            return 0.0
        h = -sum(x * math.log(max(x, eps)) for x in p)
        return float(h / math.log(len(p))) if len(p) > 1 else 0.0

    @staticmethod
    def weighted_sum(items: List[Any], weights: Any) -> List[float]:
        if not items:
            return []
        w = TensorMath.sum_normalize(weights)
        dim = len(TensorMath.vec(items[0]))
        acc = TensorMath.zeros(dim)
        for item, weight in zip(items, w):
            vec = TensorMath.vec(item, dim=dim)
            for i, x in enumerate(vec):
                acc[i] += float(weight) * float(x)
        return acc

    @staticmethod
    def map_to_vector(mapping: Mapping[str, Any], dims: List[str], default: float = 0.0) -> List[float]:
        return [TensorMath.clamp01(_floatish(mapping.get(d), default)) for d in dims]

    @staticmethod
    def vector_to_map(vector: Any, dims: List[str]) -> Dict[str, float]:
        vec = TensorMath.vec(vector, dim=len(dims))
        return {d: round(TensorMath.clamp01(vec[i]), 6) for i, d in enumerate(dims)}

    @staticmethod
    def concat(*vectors: Any) -> List[float]:
        out: List[float] = []
        for v in vectors:
            out.extend(TensorMath.vec(v))
        return out


class TensorEncoder:
    """Deterministic tensor encoder for state, memory, routing and risk.

    This is deliberately provider-free: it gives the brain a stable mathematical
    substrate even before external embedding models are connected. Later you can
    replace `text_embedding` with your vector DB embedding while preserving the
    same tensor contract.
    """

    INTENT_DIMS = ["chat", "plan", "tool", "web", "memory", "code", "file", "schedule", "creative", "safety"]
    RISK_DIMS = ["low", "medium", "high", "blocked"]
    TOOL_DIMS = ["none", "local_agent", "memory", "web", "file", "terminal", "browser", "communication"]
    MODEL_DIMS = ["general", "planner", "web", "critic", "arbiter"]
    AFFECT_DIMS = ["urgency", "uncertainty", "novelty", "user_control", "irreversibility"]
    ATTENTION_DIMS = ["task", "memory", "tool", "web", "risk", "user_context", "critic"]

    PLAN_TERMS = ("规划", "计划", "步骤", "方案", "架构", "设计", "实现", "代码", "backend", "后端", "重构", "build", "plan")
    TOOL_TERMS = ("打开", "点击", "输入", "按下", "截图", "鼠标", "运行", "编译", "文件", "桌面", "终端", "open", "click", "type", "screenshot", "press")
    WEB_TERMS = ("最新", "今天", "现在", "新闻", "价格", "天气", "股价", "搜索", "查一下", "联网", "latest", "today", "current", "price")
    MEMORY_TERMS = ("记住", "回忆", "记忆", "长期", "偏好", "习惯", "remember", "recall")
    CODE_TERMS = ("代码", "函数", "class", "def ", "import ", "api", "backend", "前端", "后端", "bug", "patch")
    FILE_TERMS = ("文件", "目录", "上传", "下载", "pdf", "docx", "xlsx", "slides", "file")
    SCHEDULE_TERMS = ("日程", "会议", "明天", "今天", "周", "calendar", "schedule", "meeting")
    CREATIVE_TERMS = ("写", "创作", "画", "设计", "故事", "海报", "图片", "generate", "draw")
    SAFETY_TERMS = ("删除", "支付", "转账", "生产", "数据库", "危险", "隐私", "法律", "医疗", "rm ", "drop ", "deploy", "上线")
    BLOCK_TERMS = ("rm -rf", "drop database", "format", "wipe", "转账", "支付", "购买", "delete production", "删除生产")

    def __init__(self, embed_dim: Optional[int] = None):
        self.embed_dim = int(embed_dim or os.getenv("BRAIN_TENSOR_EMBED_DIM", "64"))

    def encode_state(
        self,
        *,
        text: str,
        context: Optional[Dict[str, Any]] = None,
        engine_state: Optional[Dict[str, Any]] = None,
        memories: Optional[List[Dict[str, Any]]] = None,
        recent_events: Optional[List[Dict[str, Any]]] = None,
    ) -> Dict[str, Any]:
        context = context if isinstance(context, dict) else {}
        engine_state = engine_state if isinstance(engine_state, dict) else {}
        memories = memories if isinstance(memories, list) else []
        recent_events = recent_events if isinstance(recent_events, list) else []

        task_emb = self.text_embedding(text)
        memory_emb = self.memory_embedding(memories)
        event_emb = self.text_embedding("\n".join(str(e.get("summary") or e.get("event_type") or "") for e in recent_events[-8:]))
        context_emb = self.text_embedding(json.dumps(context, ensure_ascii=False, default=str)[:2000])

        intent = self.encode_intent(text, context, engine_state)
        risk = self.encode_risk(text, context, engine_state)
        tool = self.encode_tool(text, intent, context)
        model = self.encode_model_need(intent, risk, tool)
        affect = self.encode_affect(text, context, engine_state, risk)

        alignment = {
            "task_memory_cosine": round(TensorMath.cosine(task_emb, memory_emb), 6),
            "task_context_cosine": round(TensorMath.cosine(task_emb, context_emb), 6),
            "task_event_cosine": round(TensorMath.cosine(task_emb, event_emb), 6),
        }
        risk_mass = TensorMath.dot(TensorMath.map_to_vector(risk, self.RISK_DIMS), [0.0, 0.35, 0.75, 1.0])
        uncertainty = affect.get("uncertainty", 0.0)
        attention_raw = [
            0.65 + intent.get("plan", 0.0),
            0.25 + max(0.0, alignment["task_memory_cosine"]),
            0.15 + intent.get("tool", 0.0),
            0.10 + intent.get("web", 0.0),
            0.10 + risk_mass,
            0.10 + max(0.0, alignment["task_context_cosine"]),
            0.10 + max(model.get("critic", 0.0), uncertainty),
        ]
        attention_vec = TensorMath.softmax(attention_raw, temperature=0.65)
        attention = TensorMath.vector_to_map(attention_vec, self.ATTENTION_DIMS)

        state_vec = TensorMath.l2_normalize(
            TensorMath.concat(
                TensorMath.map_to_vector(intent, self.INTENT_DIMS),
                TensorMath.map_to_vector(risk, self.RISK_DIMS),
                TensorMath.map_to_vector(tool, self.TOOL_DIMS),
                TensorMath.map_to_vector(model, self.MODEL_DIMS),
                TensorMath.map_to_vector(affect, self.AFFECT_DIMS),
                attention_vec,
                task_emb,
                memory_emb,
            )
        )
        return {
            "version": "chatagi.tensor_frame.v1",
            "created_at": _now_iso(),
            "dims": {
                "intent": self.INTENT_DIMS,
                "risk": self.RISK_DIMS,
                "tool": self.TOOL_DIMS,
                "model": self.MODEL_DIMS,
                "affect": self.AFFECT_DIMS,
                "attention": self.ATTENTION_DIMS,
                "embedding": self.embed_dim,
                "state": len(state_vec),
            },
            "vectors": {
                "intent": TensorMath.map_to_vector(intent, self.INTENT_DIMS),
                "risk": TensorMath.map_to_vector(risk, self.RISK_DIMS),
                "tool": TensorMath.map_to_vector(tool, self.TOOL_DIMS),
                "model": TensorMath.map_to_vector(model, self.MODEL_DIMS),
                "affect": TensorMath.map_to_vector(affect, self.AFFECT_DIMS),
                "attention": attention_vec,
                "task_embedding": task_emb,
                "memory_embedding": memory_emb,
                "context_embedding": context_emb,
                "event_embedding": event_emb,
                "state": state_vec,
            },
            "maps": {
                "intent": intent,
                "risk": risk,
                "tool": tool,
                "model": model,
                "affect": affect,
                "attention": attention,
            },
            "alignment": alignment,
            "scalars": {
                "risk_mass": round(TensorMath.clamp01(risk_mass), 6),
                "intent_entropy": round(TensorMath.entropy(TensorMath.map_to_vector(intent, self.INTENT_DIMS)), 6),
                "model_entropy": round(TensorMath.entropy(TensorMath.map_to_vector(model, self.MODEL_DIMS)), 6),
                "attention_entropy": round(TensorMath.entropy(attention_vec), 6),
                "state_energy": round(TensorMath.dot(state_vec, state_vec), 6),
                "novelty": round(TensorMath.clamp01(1.0 - max(0.0, alignment["task_memory_cosine"])), 6),
                "uncertainty": round(TensorMath.clamp01(uncertainty), 6),
            },
        }

    def encode_patch(self, patch: Dict[str, Any], *, compact: bool = False) -> Dict[str, Any]:
        s = json.dumps(patch if isinstance(patch, dict) else {}, ensure_ascii=False, default=str)
        emb = self.text_embedding(s[:4000])
        numeric: List[float] = []
        self._collect_numbers(patch, numeric)
        numeric_energy = math.sqrt(sum(x * x for x in numeric[:512])) if numeric else 0.0
        digest = {
            "version": "patch_tensor.v1",
            "text_embedding": emb[:12] if compact else emb,
            "size": len(s),
            "numeric_count": len(numeric),
            "numeric_energy": round(float(min(numeric_energy, 999999.0)), 6),
            "type_vector": self._type_vector(patch),
        }
        return digest

    def text_embedding(self, text: str) -> List[float]:
        text = str(text or "")
        dim = self.embed_dim
        vec = [0.0] * dim
        tokens = self._tokens(text)
        if not tokens:
            return vec
        grams = list(tokens)
        grams.extend(tokens[i] + "_" + tokens[i + 1] for i in range(max(0, len(tokens) - 1)))
        grams.extend(tokens[i] + "_" + tokens[i + 1] + "_" + tokens[i + 2] for i in range(max(0, len(tokens) - 2)))
        for gram in grams[:2048]:
            h = hashlib.blake2b(gram.encode("utf-8", errors="ignore"), digest_size=8).digest()
            n = int.from_bytes(h, "little", signed=False)
            idx = n % dim
            sign = 1.0 if ((n >> 8) & 1) == 0 else -1.0
            vec[idx] += sign * (1.0 + min(len(gram), 12) / 24.0)
        return TensorMath.l2_normalize(vec)

    def memory_embedding(self, memories: List[Dict[str, Any]]) -> List[float]:
        if not memories:
            return [0.0] * self.embed_dim
        vectors = []
        weights = []
        for i, m in enumerate(memories[:12]):
            text = m.get("text") or m.get("content") or m.get("memory") or m.get("summary") or str(m)
            vectors.append(self.text_embedding(str(text)))
            score = _floatish(m.get("score") or m.get("similarity") or m.get("weight"), 1.0 / (i + 1)) if isinstance(m, dict) else 1.0 / (i + 1)
            weights.append(max(0.02, score))
        return TensorMath.l2_normalize(TensorMath.weighted_sum(vectors, weights))

    def encode_intent(self, text: str, context: Dict[str, Any], engine_state: Dict[str, Any]) -> Dict[str, float]:
        low = str(text or "").lower()
        scores = {
            "chat": 0.28,
            "plan": self._hit_score(low, self.PLAN_TERMS, 0.18, 0.16),
            "tool": self._hit_score(low, self.TOOL_TERMS, 0.10, 0.18),
            "web": self._hit_score(low, self.WEB_TERMS, 0.08, 0.20),
            "memory": self._hit_score(low, self.MEMORY_TERMS, 0.12, 0.16),
            "code": self._hit_score(low, self.CODE_TERMS, 0.10, 0.16),
            "file": self._hit_score(low, self.FILE_TERMS, 0.08, 0.18),
            "schedule": self._hit_score(low, self.SCHEDULE_TERMS, 0.06, 0.16),
            "creative": self._hit_score(low, self.CREATIVE_TERMS, 0.08, 0.15),
            "safety": self._hit_score(low, self.SAFETY_TERMS, 0.05, 0.18),
        }
        if context.get("allow_web") is True or context.get("force_web") is True:
            scores["web"] = max(scores["web"], 0.85)
        if context.get("active_file") or context.get("files"):
            scores["file"] = max(scores["file"], 0.68)
        if isinstance(engine_state.get("intent_vector"), dict):
            scores = self._blend_maps(scores, engine_state["intent_vector"], alpha=0.72)
        if max(scores.get("plan", 0), scores.get("tool", 0), scores.get("web", 0), scores.get("code", 0)) < 0.25:
            scores["chat"] = max(scores["chat"], 0.62)
        return {k: round(TensorMath.clamp01(v), 6) for k, v in scores.items()}

    def encode_risk(self, text: str, context: Dict[str, Any], engine_state: Dict[str, Any]) -> Dict[str, float]:
        low = str(text or "").lower()
        safety = self._hit_score(low, self.SAFETY_TERMS, 0.05, 0.18)
        blocked = self._hit_score(low, self.BLOCK_TERMS, 0.0, 0.35)
        planning_only = any(w in low for w in ("计划", "规划", "方案", "设计", "steps", "plan"))
        destructive_like = any(w in low for w in ("生产数据库", "drop", "rm -rf", "wipe", "format", "转账", "支付", "购买"))
        deploy_like = any(w in low for w in ("生产", "database", "数据库", "deploy", "上线", "commit", "push"))
        high = max(safety, 0.88 if destructive_like else (0.62 if deploy_like and not planning_only else 0.0))
        medium = max(0.15, 0.52 if deploy_like else (0.45 if any(w in low for w in ("运行", "终端", "文件", "修改")) else 0.0))
        if context.get("risk_level") in ("high", "blocked"):
            high = max(high, 0.8)
        if context.get("requires_confirmation") is True:
            high = max(high, 0.75)
        if isinstance(engine_state.get("risk_vector"), dict):
            blended = self._blend_maps({"low": 0.0, "medium": medium, "high": high, "blocked": blocked}, engine_state["risk_vector"], alpha=0.7)
            medium, high, blocked = blended.get("medium", medium), blended.get("high", high), blended.get("blocked", blocked)
        blocked = TensorMath.clamp01(blocked)
        high = TensorMath.clamp01(max(high, blocked * 0.9))
        medium = TensorMath.clamp01(max(medium, high * 0.45))
        low_score = TensorMath.clamp01(1.0 - max(high, blocked, medium * 0.55))
        return {"low": round(low_score, 6), "medium": round(medium, 6), "high": round(high, 6), "blocked": round(blocked, 6)}

    def encode_tool(self, text: str, intent: Dict[str, float], context: Dict[str, Any]) -> Dict[str, float]:
        low = str(text or "").lower()
        local_agent = max(intent.get("tool", 0.0), self._hit_score(low, self.TOOL_TERMS, 0.05, 0.20))
        terminal = 0.85 if any(w in low for w in ("终端", "terminal", "shell", "运行", "编译")) else 0.05
        communication = 0.75 if any(w in low for w in ("发邮件", "email", "gmail", "微信", "message")) else 0.05
        browser = 0.75 if any(w in low for w in ("浏览器", "browser", "打开网页", "网页")) else 0.05
        file_score = max(intent.get("file", 0.0), 0.7 if context.get("files") else 0.05)
        scores = {
            "none": 0.2,
            "local_agent": local_agent,
            "memory": intent.get("memory", 0.0),
            "web": intent.get("web", 0.0),
            "file": file_score,
            "terminal": terminal,
            "browser": browser,
            "communication": communication,
        }
        scores["none"] = TensorMath.clamp01(1.0 - max(scores[k] for k in scores if k != "none"))
        return {k: round(TensorMath.clamp01(v), 6) for k, v in scores.items()}

    def encode_model_need(self, intent: Dict[str, float], risk: Dict[str, float], tool: Dict[str, float]) -> Dict[str, float]:
        risk_mass = TensorMath.dot(TensorMath.map_to_vector(risk, self.RISK_DIMS), [0.0, 0.35, 0.75, 1.0])
        raw = {
            "general": 0.45 + intent.get("chat", 0.0) * 0.6,
            "planner": 0.25 + max(intent.get("plan", 0.0), intent.get("code", 0.0), tool.get("terminal", 0.0)) * 0.95,
            "web": 0.10 + intent.get("web", 0.0) * 1.2 + tool.get("web", 0.0) * 0.4,
            "critic": 0.12 + max(risk_mass, tool.get("local_agent", 0.0) * 0.65, intent.get("safety", 0.0)),
            "arbiter": 0.06 + risk_mass * 0.9,
        }
        probs = TensorMath.softmax([raw[d] for d in self.MODEL_DIMS], temperature=0.72)
        return TensorMath.vector_to_map(probs, self.MODEL_DIMS)

    def encode_affect(self, text: str, context: Dict[str, Any], engine_state: Dict[str, Any], risk: Dict[str, float]) -> Dict[str, float]:
        low = str(text or "").lower()
        urgency = 0.75 if any(w in low for w in ("马上", "立刻", "现在", "紧急", "urgent", "asap")) else 0.18
        uncertainty = 0.65 if any(w in low for w in ("可能", "不确定", "是不是", "吗", "?", "？", "maybe")) else 0.22
        user_control = 0.82 if any(w in low for w in ("确认", "让我", "先问", "不要", "别")) else 0.35
        irreversibility = max(risk.get("high", 0.0), risk.get("blocked", 0.0), 0.2 if any(w in low for w in ("保存", "提交", "发送")) else 0.0)
        novelty = 0.55 if context else 0.32
        if isinstance(engine_state.get("affect_vector"), dict):
            blended = self._blend_maps(
                {"urgency": urgency, "uncertainty": uncertainty, "novelty": novelty, "user_control": user_control, "irreversibility": irreversibility},
                engine_state["affect_vector"],
                alpha=0.72,
            )
            urgency, uncertainty, novelty, user_control, irreversibility = [blended[k] for k in self.AFFECT_DIMS]
        return {
            "urgency": round(TensorMath.clamp01(urgency), 6),
            "uncertainty": round(TensorMath.clamp01(uncertainty), 6),
            "novelty": round(TensorMath.clamp01(novelty), 6),
            "user_control": round(TensorMath.clamp01(user_control), 6),
            "irreversibility": round(TensorMath.clamp01(irreversibility), 6),
        }

    def _tokens(self, text: str) -> List[str]:
        # English-ish tokens plus individual CJK chars gives deterministic sparse-hash embeddings.
        return re.findall(r"[a-zA-Z0-9_./:-]+|[\u4e00-\u9fff]", str(text or "").lower())

    def _hit_score(self, low_text: str, terms: Iterable[str], base: float, inc: float) -> float:
        score = base
        for term in terms:
            if term.lower() in low_text:
                score += inc
        return TensorMath.clamp01(score)

    def _blend_maps(self, a: Dict[str, float], b: Mapping[str, Any], *, alpha: float) -> Dict[str, float]:
        out = dict(a)
        for k, v in b.items():
            if k in out:
                out[k] = TensorMath.clamp01(alpha * out[k] + (1.0 - alpha) * _floatish(v, out[k]))
        return out

    def _collect_numbers(self, obj: Any, out: List[float]) -> None:
        if isinstance(obj, (int, float)):
            out.append(float(obj))
        elif isinstance(obj, dict):
            for v in obj.values():
                self._collect_numbers(v, out)
        elif isinstance(obj, (list, tuple)):
            for v in obj:
                self._collect_numbers(v, out)

    def _type_vector(self, obj: Any) -> Dict[str, float]:
        counts = {"dict": 0, "list": 0, "str": 0, "number": 0, "bool": 0, "none": 0}

        def walk(x: Any) -> None:
            if isinstance(x, dict):
                counts["dict"] += 1
                for v in x.values():
                    walk(v)
            elif isinstance(x, (list, tuple)):
                counts["list"] += 1
                for v in x:
                    walk(v)
            elif isinstance(x, str):
                counts["str"] += 1
            elif isinstance(x, bool):
                counts["bool"] += 1
            elif x is None:
                counts["none"] += 1
            elif isinstance(x, (int, float)):
                counts["number"] += 1

        walk(obj)
        total = sum(counts.values()) or 1
        return {k: round(v / total, 6) for k, v in counts.items()}


_GLOBAL_TENSOR_ENCODER = TensorEncoder()


def _floatish(v: Any, default: float = 0.0) -> float:
    try:
        return float(v)
    except Exception:
        return float(default)


def _tensor_frame(state: Dict[str, Any]) -> Dict[str, Any]:
    tf = state.get("tensor_frame") if isinstance(state, dict) else None
    return tf if isinstance(tf, dict) else {}


def _tensor_map_from_state(state: Dict[str, Any], name: str) -> Dict[str, float]:
    tf = _tensor_frame(state)
    maps = tf.get("maps") if isinstance(tf.get("maps"), dict) else {}
    m = maps.get(name) if isinstance(maps, dict) else None
    return {str(k): _floatish(v, 0.0) for k, v in m.items()} if isinstance(m, dict) else {}


def _tensor_scalar(state: Dict[str, Any], name: str, default: float = 0.0) -> float:
    tf = _tensor_frame(state)
    scalars = tf.get("scalars") if isinstance(tf.get("scalars"), dict) else {}
    return _floatish(scalars.get(name), default) if isinstance(scalars, dict) else default


def _tensor_for_prompt(tf: Dict[str, Any], *, include_embeddings: bool = False) -> Dict[str, Any]:
    if not isinstance(tf, dict):
        return {}
    out = {
        "version": tf.get("version"),
        "dims": tf.get("dims"),
        "maps": tf.get("maps"),
        "alignment": tf.get("alignment"),
        "scalars": tf.get("scalars"),
    }
    if include_embeddings:
        out["vectors"] = tf.get("vectors")
    else:
        vectors = tf.get("vectors") if isinstance(tf.get("vectors"), dict) else {}
        out["vector_previews"] = {
            k: (v[:8] if isinstance(v, list) else v)
            for k, v in vectors.items()
            if k in ("intent", "risk", "tool", "model", "affect", "attention", "state")
        }
    return out


def _state_without_tensor(state: Dict[str, Any]) -> Dict[str, Any]:
    if not isinstance(state, dict):
        return {}
    out = copy.deepcopy(state)
    for key in ("tensor_frame", "state_tensor", "blackboard"):
        out.pop(key, None)
    return out


def _tensor_objection_severity(objection: str, state: Dict[str, Any], draft: Optional[Draft] = None, decision: Optional[Decision] = None) -> float:
    risk = _GLOBAL_TENSOR_ENCODER.encode_risk(objection, {}, {})
    risk_mass = TensorMath.dot(TensorMath.map_to_vector(risk, TensorEncoder.RISK_DIMS), [0.0, 0.35, 0.75, 1.0])
    state_risk = _tensor_scalar(state, "risk_mass", 0.0)
    uncertainty = _tensor_scalar(state, "uncertainty", 0.0)
    task_vec = (_tensor_frame(state).get("vectors") or {}).get("task_embedding", []) if isinstance(_tensor_frame(state).get("vectors"), dict) else []
    obj_vec = _GLOBAL_TENSOR_ENCODER.text_embedding(objection)
    task_alignment = max(0.0, TensorMath.cosine(task_vec, obj_vec))
    conf_gap = 0.0 if draft is None else max(0.0, 0.72 - float(draft.confidence))
    raw = TensorMath.dot([risk_mass, state_risk, uncertainty, task_alignment, conf_gap], [0.36, 0.22, 0.12, 0.18, 0.12])
    if decision is not None and decision.need_tool:
        raw += 0.08
    return TensorMath.clamp01(raw)


def _tensor_confidence(state: Dict[str, Any], draft: Draft, critiques: List[Critique], tool_result: Optional[Dict[str, Any]]) -> float:
    base = float(draft.confidence)
    risk_penalty = 0.28 * _tensor_scalar(state, "risk_mass", 0.0)
    uncertainty_penalty = 0.10 * _tensor_scalar(state, "uncertainty", 0.0)
    critique_penalty = 0.0 if not critiques else 0.24 * max(c.severity for c in critiques)
    tool_bonus = 0.0
    if isinstance(tool_result, dict):
        tool_bonus = 0.12 if tool_result.get("ok") else -0.18
    tensor_gain = 0.06 * (1.0 - _tensor_scalar(state, "model_entropy", 0.5))
    return round(TensorMath.clamp01(base - risk_penalty - uncertainty_penalty - critique_penalty + tool_bonus + tensor_gain), 6)


# =============================================================================
# 2. Memory, state and local-agent ports
# =============================================================================


MemorySearchFn = Callable[[str, str, int, float], Any]
MemoryAddFn = Callable[[str, str], Any]
LocalAgentCallable = Callable[[str, str, Optional[Dict[str, Any]]], Awaitable[Any]]


class MemoryPort:
    def __init__(self, memory_engine: Any = None, search_fn: Optional[MemorySearchFn] = None, add_fn: Optional[MemoryAddFn] = None):
        self.memory_engine = memory_engine
        self.search_fn = search_fn
        self.add_fn = add_fn
        self._bg_tasks: set[asyncio.Task] = set()

    async def recall(self, user_key: str, query: str, *, k: int = 6, min_score: float = 0.18) -> List[Dict[str, Any]]:
        query = (query or "").strip()
        if not query:
            return []
        try:
            if self.memory_engine is not None and hasattr(self.memory_engine, "hybrid_recall"):
                obj = await asyncio.to_thread(
                    self.memory_engine.hybrid_recall,
                    user_key,
                    query,
                    max(6, int(k or 6)),
                    ["facts", "vector", "timeline", "episodes", "procedural", "working", "graph"],
                )
                if isinstance(obj, dict):
                    flat: List[Dict[str, Any]] = []
                    for bucket in ("facts", "procedural", "graph", "episodic", "timeline", "vector", "working"):
                        for item in obj.get(bucket) or []:
                            if not isinstance(item, dict):
                                continue
                            text = item.get("content") or item.get("summary") or item.get("text") or item.get("title") or ""
                            if not str(text).strip():
                                continue
                            flat.append({**item, "memory_type": bucket, "text": str(text)})
                    return flat[: max(1, int(k or 6)) * 4]
            if self.memory_engine is not None and hasattr(self.memory_engine, "search_vectors"):
                return await asyncio.to_thread(self.memory_engine.search_vectors, user_key, query, k, min_score)
            if self.search_fn is not None:
                out = self.search_fn(user_key, query, k, min_score)
                if asyncio.iscoroutine(out):
                    out = await out
                return list(out or [])
        except Exception as e:  # noqa: BLE001
            log.warning("memory recall failed: %s", e)
        return []

    def remember_async(self, user_key: str, text: str, *, meta: Optional[Dict[str, Any]] = None) -> None:
        text = (text or "").strip()
        if not text or len(text) < 8 or "```" in text:
            return
        payload = text if not meta else f"{text}\nMETA:{json.dumps(meta, ensure_ascii=False, default=str)}"
        task = asyncio.create_task(self._remember(user_key, payload))
        self._bg_tasks.add(task)
        task.add_done_callback(self._bg_tasks.discard)

    async def _remember(self, user_key: str, text: str) -> None:
        try:
            if self.memory_engine is not None and hasattr(self.memory_engine, "write_memory"):
                await asyncio.to_thread(self.memory_engine.write_memory, user_key, "raw", text, {"source": "brain_core"})
                return
            if self.memory_engine is not None and hasattr(self.memory_engine, "add_vector"):
                await asyncio.to_thread(self.memory_engine.add_vector, user_key, text)
                return
            if self.add_fn is not None:
                out = self.add_fn(user_key, text)
                if asyncio.iscoroutine(out):
                    await out
        except Exception as e:  # noqa: BLE001
            log.warning("memory write ignored: %s", e)

    def remember_structured_async(self, user_key: str, mtype: str, text: str, *, meta: Optional[Dict[str, Any]] = None) -> None:
        text = (text or "").strip()
        if not text or self.memory_engine is None or not hasattr(self.memory_engine, "write_memory"):
            return
        task = asyncio.create_task(self._remember_structured(user_key, mtype, text, meta or {}))
        self._bg_tasks.add(task)
        task.add_done_callback(self._bg_tasks.discard)

    async def _remember_structured(self, user_key: str, mtype: str, text: str, meta: Dict[str, Any]) -> None:
        try:
            await asyncio.to_thread(self.memory_engine.write_memory, user_key, mtype, text, meta)
        except Exception as e:  # noqa: BLE001
            log.warning("structured memory write ignored: %s", e)


class WorldStateBlackboard:
    """Per-user world-state blackboard.

    This is the glue layer between perception, memory, planning, tool execution,
    critique and arbitration. It keeps a durable-ish snapshot plus an append-only
    recent event stream. The real BrainStateEngine can still be injected; this
    blackboard wraps it so the core always has a consistent state contract.
    """

    def __init__(self, *, max_events: Optional[int] = None, tensor_encoder: Optional[TensorEncoder] = None):
        self.max_events = int(max_events or os.getenv("BRAIN_BLACKBOARD_MAX_EVENTS", "200"))
        self.tensor_encoder = tensor_encoder or _GLOBAL_TENSOR_ENCODER
        self._states: Dict[str, Dict[str, Any]] = {}
        self._events: Dict[str, List[Dict[str, Any]]] = {}
        self._locks: Dict[str, asyncio.Lock] = {}

    def _lock_for(self, user_key: str) -> asyncio.Lock:
        lock = self._locks.get(user_key)
        if lock is None:
            lock = asyncio.Lock()
            self._locks[user_key] = lock
        return lock

    async def snapshot(
        self,
        user_key: str,
        *,
        text: str = "",
        context: Optional[Dict[str, Any]] = None,
        engine_state: Optional[Dict[str, Any]] = None,
        actor: str = "perception",
        event_type: str = "state_snapshot",
        trace_id: str = "",
    ) -> Dict[str, Any]:
        context = context if isinstance(context, dict) else {}
        engine_state = engine_state if isinstance(engine_state, dict) else {}
        async with self._lock_for(user_key):
            previous = copy.deepcopy(self._states.get(user_key, {}))
            recent_events = copy.deepcopy(self._events.get(user_key, [])[-8:])
            tensor_frame = self.tensor_encoder.encode_state(
                text=text,
                context=context,
                engine_state=engine_state,
                memories=[],
                recent_events=recent_events,
            )
            maps = tensor_frame.get("maps", {}) if isinstance(tensor_frame.get("maps"), dict) else {}
            vectors = tensor_frame.get("vectors", {}) if isinstance(tensor_frame.get("vectors"), dict) else {}
            derived = {
                "user_key": user_key,
                "current_task": text,
                "focus": {
                    "task": text,
                    "context_keys": sorted(context.keys()),
                    "updated_at": _now_iso(),
                },
                # Backward-compatible vector maps for existing backend code.
                "intent_vector": maps.get("intent", {}),
                "risk_vector": maps.get("risk", {}),
                "tool_vector": maps.get("tool", {}),
                "model_need_vector": maps.get("model", {}),
                # New tensor-first state contract.
                "tensor_frame": tensor_frame,
                "state_tensor": vectors.get("state", []),
                "last_flash_at": _now_iso(),
            }
            merged = _deep_merge(previous, engine_state)
            merged = _deep_merge(merged, derived)
            event = self._event(actor, event_type, {"current_task": text, "tensor_frame": _tensor_for_prompt(tensor_frame)}, "state perceived as tensor", trace_id)
            self._append_event_locked(user_key, event)
            merged["blackboard"] = self._blackboard_meta_locked(user_key)
            self._states[user_key] = merged
            return copy.deepcopy(merged)

    async def patch(
        self,
        user_key: str,
        patch: Dict[str, Any],
        *,
        actor: str = "brain_core",
        event_type: str = "patch",
        summary: str = "",
        trace_id: str = "",
    ) -> Dict[str, Any]:
        patch = patch if isinstance(patch, dict) else {}
        async with self._lock_for(user_key):
            current = copy.deepcopy(self._states.get(user_key, {"user_key": user_key}))
            patch_tensor = self.tensor_encoder.encode_patch(patch)
            current = _deep_merge(current, patch)
            current["last_patch_tensor"] = patch_tensor
            journal = current.setdefault("tensor_journal", [])
            if isinstance(journal, list):
                journal.append({
                    "ts": _now_iso(),
                    "actor": actor,
                    "event_type": event_type,
                    "summary": summary or event_type,
                    "patch_tensor": {**patch_tensor, "text_embedding": patch_tensor.get("text_embedding", [])[:12]},
                })
                if len(journal) > 64:
                    del journal[: len(journal) - 64]
            current["last_blackboard_update_at"] = _now_iso()
            event = self._event(actor, event_type, patch, summary or event_type, trace_id)
            self._append_event_locked(user_key, event)
            current["blackboard"] = self._blackboard_meta_locked(user_key)
            self._states[user_key] = current
            return copy.deepcopy(current)

    async def read(self, user_key: str) -> Dict[str, Any]:
        async with self._lock_for(user_key):
            state = copy.deepcopy(self._states.get(user_key, {"user_key": user_key}))
            state["blackboard"] = self._blackboard_meta_locked(user_key)
            return state

    async def events(self, user_key: str, *, limit: int = 20) -> List[Dict[str, Any]]:
        async with self._lock_for(user_key):
            return copy.deepcopy(self._events.get(user_key, [])[-limit:])

    def _event(self, actor: str, event_type: str, patch: Dict[str, Any], summary: str, trace_id: str) -> Dict[str, Any]:
        return {
            "t": time.time(),
            "ts": _now_iso(),
            "actor": actor,
            "event_type": event_type,
            "summary": summary,
            "trace_id": trace_id,
            "patch_keys": sorted(patch.keys()),
            "patch": _compact_for_event(patch),
            "tensor_digest": self.tensor_encoder.encode_patch(patch, compact=True),
        }

    def _append_event_locked(self, user_key: str, event: Dict[str, Any]) -> None:
        events = self._events.setdefault(user_key, [])
        events.append(event)
        if len(events) > self.max_events:
            del events[: len(events) - self.max_events]

    def _blackboard_meta_locked(self, user_key: str) -> Dict[str, Any]:
        events = self._events.get(user_key, [])
        return {
            "event_count": len(events),
            "recent_events": copy.deepcopy(events[-8:]),
            "updated_at": _now_iso(),
        }


class BrainStatePort:
    def __init__(self, brain_state_engine: Any = None, blackboard: Optional[WorldStateBlackboard] = None):
        self.engine = brain_state_engine
        self.blackboard = blackboard or WorldStateBlackboard()

    async def think_state(self, user_key: str, text: str, context: Dict[str, Any]) -> Dict[str, Any]:
        engine_state = await self._engine_think(user_key, text, context)
        return await self.blackboard.snapshot(
            user_key,
            text=text,
            context=context,
            engine_state=engine_state,
            actor="perception",
            event_type="state_snapshot",
        )

    async def write_state(
        self,
        user_key: str,
        patch: Dict[str, Any],
        *,
        actor: str = "brain_core",
        event_type: str = "patch",
        summary: str = "",
        trace_id: str = "",
        persist_engine: bool = True,
    ) -> Dict[str, Any]:
        updated = await self.blackboard.patch(
            user_key,
            patch,
            actor=actor,
            event_type=event_type,
            summary=summary,
            trace_id=trace_id,
        )
        # If the real engine exposes a persistence hook, use it best-effort.
        # Pure tensor refresh patches can skip external persistence to avoid bloat.
        if persist_engine and self.engine is not None:
            for name in ("save_state", "write_state", "patch_state"):
                fn = getattr(self.engine, name, None)
                if callable(fn):
                    try:
                        await asyncio.to_thread(fn, user_key, patch)
                    except Exception as e:  # noqa: BLE001
                        log.warning("BrainStateEngine.%s write ignored: %s", name, e)
                    break
        return updated

    async def read_state(self, user_key: str) -> Dict[str, Any]:
        return await self.blackboard.read(user_key)

    async def _engine_think(self, user_key: str, text: str, context: Dict[str, Any]) -> Dict[str, Any]:
        if self.engine is None:
            return {}
        # Adu's BrainStateEngine has historically exposed different method names.
        for name in ("think", "update", "build_state", "process", "infer"):
            fn = getattr(self.engine, name, None)
            if not callable(fn):
                continue
            try:
                out = await asyncio.to_thread(fn, text, context)
                if isinstance(out, dict):
                    return out
            except TypeError:
                try:
                    out = await asyncio.to_thread(fn, user_key, text, context)
                    if isinstance(out, dict):
                        return out
                except Exception as e:  # noqa: BLE001
                    log.warning("BrainStateEngine.%s failed: %s", name, e)
            except Exception as e:  # noqa: BLE001
                log.warning("BrainStateEngine.%s failed: %s", name, e)
        return {}


class LocalAgentPort:
    """All computer/tool work goes to the user's local agent. Never local OS."""

    def __init__(self, callable_: Optional[LocalAgentCallable] = None):
        self.callable = callable_
        self.base_url = os.getenv("LOCAL_AGENT_BASE_URL") or os.getenv("OPENCLAW_URL") or "http://127.0.0.1:18789"
        self.token = os.getenv("LOCAL_AGENT_TOKEN") or os.getenv("OPENCLAW_TOKEN") or ""
        self.timeout = float(os.getenv("LOCAL_AGENT_TIMEOUT_SEC", "30"))

    async def call(self, method: str, path: str, body: Optional[Dict[str, Any]] = None) -> Any:
        method = method.upper().strip()
        body = body if isinstance(body, dict) else None
        if self.callable is not None:
            return await self.callable(method, path, body)
        headers = {"content-type": "application/json"}
        if self.token:
            headers["authorization"] = f"Bearer {self.token}"
        try:
            async with httpx.AsyncClient(timeout=self.timeout) as client:
                r = await client.request(method, self.base_url.rstrip("/") + path, headers=headers, json=body)
                r.raise_for_status()
                ctype = r.headers.get("content-type", "")
                return r.json() if "json" in ctype else {"text": r.text}
        except httpx.ConnectError:
            return {"ok": False, "error": "local_agent_unreachable", "message": "用户 Mac 上的 local-agent 未连接。"}
        except httpx.TimeoutException:
            return {"ok": False, "error": "local_agent_timeout"}
        except Exception as e:  # noqa: BLE001
            return {"ok": False, "error": "local_agent_error", "message": str(e)}

    async def body_action(self, port: str, action: str, payload: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        """通过 ChatAGI Computer Body Gateway 调端口动作(in-process)。
        embodied skill 可映射:observe→screen.screenshot, open_app→app.open_app,
        computer_action→对应 port, verify→verify port, code_task→code port。
        Body Gateway 不可用时回退到 execute_action(GUI 类)。"""
        try:
            from chatagi_computer_body import body_dispatch
            return await body_dispatch(port, action, payload or {})
        except Exception:
            return await self.execute_action(action, payload or {})

    @staticmethod
    def skill_to_body(skill: str) -> Optional[Tuple[str, str]]:
        """embodied skill → (port, action)。"""
        s = (skill or "").strip().lower()
        m = {
            "observe": ("screen", "screenshot"),
            "screenshot": ("screen", "screenshot"),
            "look_at": ("screen", "active_window"),
            "open_app": ("app", "open_app"),
            "click": ("mouse", "click"),
            "type_text": ("keyboard", "type"),
            "computer_action": ("screen", "screenshot"),
            # 网页技能 → BrowserPort(DOM 级,而非坐标)
            "open_url": ("browser", "open_url"),
            "browse": ("browser", "open_url"),
            "extract_text": ("browser", "extract_text"),
            "read_page": ("browser", "extract_text"),
            "get_dom": ("browser", "get_dom"),
            "click_text": ("browser", "click_text"),
            "type_into": ("browser", "type_into"),
        }
        return m.get(s)

    async def execute_action(self, action: str, payload: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        action = (action or "").strip().lower()
        payload = payload if isinstance(payload, dict) else {}
        if action in ("screenshot", "screen_shot"):
            return _ok_action("screenshot", await self.call("POST", "/api/computer/screenshot", payload))
        if action in ("mouse", "mouse_position", "position"):
            return _ok_action("mouse_position", await self.call("GET", "/api/computer/mouse"))
        if action in ("move", "move_mouse", "mouse_move"):
            return _ok_action("move", await self.call("POST", "/api/computer/move", payload))
        if action in ("click", "double_click", "right_click"):
            # local-agent :4317 /api/computer/click 只认 count/clicks 与 button,
            # 不认 "double" 标志位。这里发 count=2 才能真正双击(DevBrain 自查修复)。
            if action == "double_click":
                payload = {**payload, "count": 2}
            if action == "right_click":
                payload = {**payload, "button": "right"}
            return _ok_action(action, await self.call("POST", "/api/computer/click", payload))
        if action in ("type", "type_text", "input_text"):
            return _ok_action("type_text", await self.call("POST", "/api/computer/type", payload))
        if action in ("press", "press_keys", "hotkey"):
            return _ok_action("press_keys", await self.call("POST", "/api/computer/press", payload))
        if action in ("open_app", "open_application", "launch_app", "launch"):
            app = str(payload.get("app") or payload.get("name") or payload.get("query") or "").strip()
            if not app:
                return {"ok": False, "error": "missing_app"}
            steps = []
            steps.append(await self.execute_action("press_keys", {"keys": ["cmd", "space"]}))
            await asyncio.sleep(0.25)
            steps.append(await self.execute_action("type_text", {"text": app}))
            await asyncio.sleep(0.2)
            steps.append(await self.execute_action("press_keys", {"keys": ["enter"]}))
            return {"ok": True, "action": "open_app", "app": app, "steps": steps}
        if action in ("agent_action", "computer_action"):
            return _ok_action("agent_action", await self.call("POST", "/api/computer/action", payload))
        return {"ok": False, "error": "unsupported_action", "action": action}


# =============================================================================
# 3. Router, risk gate, planner, critics, arbiter
# =============================================================================


class BrainRouter:
    WEB_WORDS = ("最新", "今天", "现在", "新闻", "价格", "天气", "股价", "搜索", "查一下", "联网", "latest", "today", "current")
    TOOL_WORDS = ("打开", "点击", "输入", "按下", "截图", "鼠标", "运行", "编译", "文件", "桌面", "终端", "open", "click", "type", "screenshot")
    PLAN_WORDS = ("规划", "计划", "步骤", "方案", "架构", "设计", "实现", "代码", "backend", "后端", "重构")

    def decide(self, text: str, state: Dict[str, Any], allow_web: bool, allow_tools: bool) -> Decision:
        low = text.lower()
        intent = _tensor_map_from_state(state, "intent") or (state.get("intent_vector") if isinstance(state.get("intent_vector"), dict) else {})
        tool = _tensor_map_from_state(state, "tool") or (state.get("tool_vector") if isinstance(state.get("tool_vector"), dict) else {})
        model = _tensor_map_from_state(state, "model") or (state.get("model_need_vector") if isinstance(state.get("model_need_vector"), dict) else {})
        risk_map = _tensor_map_from_state(state, "risk") or (state.get("risk_vector") if isinstance(state.get("risk_vector"), dict) else {})
        affect = _tensor_map_from_state(state, "affect")

        need_web = bool(
            allow_web
            or intent.get("web", 0.0) >= 0.48
            or tool.get("web", 0.0) >= 0.48
            or any(w in text or w in low for w in self.WEB_WORDS)
        )
        need_tool = bool(
            allow_tools
            and (
                intent.get("tool", 0.0) >= 0.48
                or tool.get("local_agent", 0.0) >= 0.48
                or tool.get("terminal", 0.0) >= 0.55
                or any(w in text or w in low for w in self.TOOL_WORDS)
            )
        )

        role_scores = {"general": 0.34, "planner": 0.20, "web": 0.05, "critic": 0.0, "arbiter": 0.0}
        for k, v in model.items():
            if k in role_scores:
                role_scores[k] = max(role_scores[k], _floatish(v, 0.0))
        if not need_web:
            role_scores["web"] *= 0.25
        if intent.get("plan", 0.0) >= 0.48 or intent.get("code", 0.0) >= 0.45:
            role_scores["planner"] += 0.18
        role = max(("general", "planner", "web"), key=lambda r: role_scores.get(r, 0.0))

        risk = _risk_from_state_or_text(state, text)
        requires_confirmation = risk in (Risk.HIGH, Risk.BLOCKED)
        risk_mass = _tensor_scalar(state, "risk_mass", 0.0)
        need_critic = bool(
            need_tool
            or need_web
            or risk != Risk.LOW
            or risk_mass >= 0.32
            or model.get("critic", 0.0) >= 0.30
            or affect.get("uncertainty", 0.0) >= 0.55
        )
        return Decision(
            role_key=role,
            risk=risk,
            need_tool=need_tool,
            need_web=need_web,
            need_critic=need_critic,
            requires_confirmation=requires_confirmation,
            intent={
                "intent": intent,
                "tool": tool,
                "risk": risk_map,
                "model": model,
                "affect": affect,
                "scalars": (_tensor_frame(state).get("scalars") if isinstance(_tensor_frame(state).get("scalars"), dict) else {}),
            },
            route_reason="tensor-router",
        )


class RiskGate:
    CONFIRM_TOKEN = "I_CONFIRM_RISK"
    BLOCKED_ACTIONS = {"delete", "rm", "drop", "wipe", "format", "transfer_money", "pay", "purchase"}
    HIGH_RISK_WORDS = ("删除", "支付", "转账", "生产", "数据库", "drop ", "rm ", "wipe", "format", "commit", "push", "deploy", "上线")

    def evaluate(self, text: str, action: str = "", payload: Optional[Dict[str, Any]] = None, state: Optional[Dict[str, Any]] = None) -> Tuple[Risk, bool, str]:
        low = f"{text} {action} {json.dumps(payload or {}, ensure_ascii=False)}".lower()
        risk_vec = _GLOBAL_TENSOR_ENCODER.encode_risk(low, {}, {})
        if state:
            state_risk = _tensor_map_from_state(state, "risk")
            risk_vec = {
                "low": min(risk_vec.get("low", 1.0), state_risk.get("low", risk_vec.get("low", 1.0))),
                "medium": max(risk_vec.get("medium", 0.0), state_risk.get("medium", 0.0)),
                "high": max(risk_vec.get("high", 0.0), state_risk.get("high", 0.0)),
                "blocked": max(risk_vec.get("blocked", 0.0), state_risk.get("blocked", 0.0)),
            }
        risk_mass = TensorMath.dot(TensorMath.map_to_vector(risk_vec, TensorEncoder.RISK_DIMS), [0.0, 0.35, 0.75, 1.0])
        if action.lower() in self.BLOCKED_ACTIONS or risk_vec.get("blocked", 0.0) >= 0.65:
            return Risk.BLOCKED, True, f"tensor risk blocked={risk_vec.get('blocked', 0.0):.2f}"
        if any(w in low for w in self.HIGH_RISK_WORDS) or risk_vec.get("high", 0.0) >= 0.65 or risk_mass >= 0.58:
            return Risk.HIGH, True, f"tensor risk high={risk_vec.get('high', 0.0):.2f} mass={risk_mass:.2f}"
        if risk_vec.get("medium", 0.0) >= 0.58 or risk_mass >= 0.34:
            return Risk.MEDIUM, False, f"tensor risk medium={risk_vec.get('medium', 0.0):.2f} mass={risk_mass:.2f}"
        return Risk.LOW, False, f"tensor risk low mass={risk_mass:.2f}"

    def allow(self, risk: Risk, confirmation_token: str, dry_run: bool) -> Tuple[bool, bool, str]:
        if risk == Risk.BLOCKED:
            return False, True, "blocked action; requires manual redesign"
        if risk == Risk.HIGH and not dry_run and confirmation_token != self.CONFIRM_TOKEN:
            return False, True, "high-risk action requires explicit confirmation token"
        return True, False, "allowed"


class Planner:
    SCHEMA = """
{
  "answer": "给用户的直接回答或行动计划",
  "confidence": 0.0,
  "needs_tool": false,
  "tool_action": "screenshot|mouse_position|move|click|double_click|type_text|press_keys|open_app|agent_action|null",
  "tool_payload": {},
  "memory_to_write": "值得长期记住的一句话；没有则空字符串",
  "final_after_tool": false
}
""".strip()

    def __init__(self, llm: LLMClient):
        self.llm = llm

    async def draft(self, brain_input: BrainInput, state: Dict[str, Any], memories: List[Dict[str, Any]], decision: Decision) -> Draft:
        sys = (
            "你是 ChatAGI 阿杜的左脑规划器。你必须基于状态、记忆和用户任务，"
            "输出可执行、可回滚、最小风险的 JSON 计划。电脑动作只允许通过 local-agent 工具执行。"
        )
        prompt = json.dumps(
            {
                "task": brain_input.text,
                "context": brain_input.context,
                "state": _state_without_tensor(state),
                "tensor_frame": _tensor_for_prompt(_tensor_frame(state)),
                "memories": memories[:8],
                "memory_tensor": {
                    "recalled": len(memories),
                    "task_memory_cosine": (_tensor_frame(state).get("alignment") or {}).get("task_memory_cosine"),
                },
                "decision": {
                    "role": decision.role_key,
                    "risk": decision.risk.value,
                    "need_tool": decision.need_tool,
                    "need_web": decision.need_web,
                    "requires_confirmation": decision.requires_confirmation,
                },
                "allowed_tool_actions": [
                    "screenshot",
                    "mouse_position",
                    "move",
                    "click",
                    "double_click",
                    "type_text",
                    "press_keys",
                    "open_app",
                    "agent_action",
                ],
            },
            ensure_ascii=False,
            default=str,
        )
        try:
            obj = await self.llm.call_json(
                decision.role_key,
                sys,
                prompt,
                schema_hint=self.SCHEMA,
                max_tokens=brain_input.max_tokens,
                timeout=float(os.getenv("BRAIN_RACE_TIMEOUT", "25")),
                retries=1,
            )
            return Draft(
                answer=str(obj.get("answer") or "").strip(),
                confidence=_float01(obj.get("confidence"), 0.62),
                plan=obj,
            )
        except Exception as e:  # noqa: BLE001
            log.warning("planner failed, using safe fallback: %s", e)
            return Draft(
                answer="我先给出安全的高层方案：先读取当前状态和相关记忆，再生成可执行计划；涉及电脑动作时先 dry-run，确认后再通过 local-agent 执行。",
                confidence=0.42,
                plan={"needs_tool": False, "memory_to_write": ""},
            )

    async def finalize(self, brain_input: BrainInput, state: Dict[str, Any], draft: Draft, decision: Decision) -> Draft:
        if not draft.tool_result:
            return draft
        sys = "你是 ChatAGI 阿杜的结果整合器。结合工具执行结果，给出简洁准确的最终回答。"
        prompt = json.dumps(
            {
                "task": brain_input.text,
                "state": _state_without_tensor(state),
                "tensor_frame": _tensor_for_prompt(_tensor_frame(state)),
                "draft": draft.answer,
                "plan": draft.plan,
                "instruction": draft.instruction,
                "tool_result": draft.tool_result,
            },
            ensure_ascii=False,
            default=str,
        )
        try:
            answer = await self.llm.call(decision.role_key, sys, prompt, max_tokens=brain_input.max_tokens, timeout=30, retries=1)
            draft.answer = answer.strip() or draft.answer
            if draft.tool_result.get("ok"):
                draft.confidence = max(draft.confidence, 0.74)
            else:
                draft.confidence = min(draft.confidence, 0.45)
        except Exception as e:  # noqa: BLE001
            log.warning("finalize failed: %s", e)
        return draft


class CriticPool:
    def __init__(self, llm: LLMClient):
        self.llm = llm
        self.timeout = float(os.getenv("BRAIN_CRITIC_TIMEOUT", "18"))
        self.severity_gate = float(os.getenv("BRAIN_SEVERITY_GATE", "0.62"))

    async def critique(self, brain_input: BrainInput, state: Dict[str, Any], draft: Draft, decision: Decision) -> List[Critique]:
        roles = ["critic_a", "critic_b"]
        sys = (
            "你是异源质证者，只负责挑错，不许附和。检查事实错误、执行风险、遗漏前提、"
            "工具误用、记忆污染和是否需要用户确认。输出你的反对意见。"
        )
        prompt = json.dumps(
            {
                "task": brain_input.text,
                "state": _state_without_tensor(state),
                "tensor_frame": _tensor_for_prompt(_tensor_frame(state)),
                "decision": decision.__dict__,
                "draft": draft.answer,
                "plan": draft.plan,
                "instruction": draft.instruction,
                "tool_result": draft.tool_result,
            },
            ensure_ascii=False,
            default=str,
        )

        async def one(role: str) -> Critique:
            spec = self.llm.registry.get(role)
            family = spec.family if spec else role
            out = await self.llm.call(role, sys, prompt, max_tokens=1024, timeout=self.timeout, retries=0)
            sev = await self._score(brain_input.text, draft.answer, out, state=state, draft=draft, decision=decision)
            return Critique(role, family, out.strip(), sev)

        tasks = [asyncio.create_task(one(r)) for r in roles]
        critiques: List[Critique] = []
        deadline = time.perf_counter() + self.timeout
        try:
            for fut in asyncio.as_completed(tasks, timeout=self.timeout):
                try:
                    c = await fut
                    critiques.append(c)
                    # QPG style: a strong first objection is enough to stop and arbitrate.
                    if c.severity >= self.severity_gate:
                        break
                    if time.perf_counter() >= deadline:
                        break
                except Exception as e:  # noqa: BLE001
                    log.warning("critic failed: %s", e)
        finally:
            for t in tasks:
                if not t.done():
                    t.cancel()
        return critiques

    async def _score(
        self,
        task: str,
        answer: str,
        objection: str,
        *,
        state: Optional[Dict[str, Any]] = None,
        draft: Optional[Draft] = None,
        decision: Optional[Decision] = None,
    ) -> float:
        sys = "你给反对意见的实质性打分，只输出 0~1 一个小数。1=严重，0=无意义。"
        prompt = f"任务:{task}\n方案:{answer}\n反对:{objection}\n分数:"
        tensor_score = _tensor_objection_severity(objection, state or {}, draft, decision)
        try:
            raw = await self.llm.call("scorer", sys, prompt, max_tokens=8, timeout=10, retries=0)
            m = re.search(r"0(?:\.\d+)?|1(?:\.0+)?", raw)
            llm_score = _float01(m.group(0) if m else raw, 0.5)
            return round(TensorMath.clamp01(0.72 * llm_score + 0.28 * tensor_score), 6)
        except Exception:
            return round(tensor_score, 6)



class Arbiter:
    def __init__(self, llm: LLMClient):
        self.llm = llm
        self.severity_gate = float(os.getenv("BRAIN_SEVERITY_GATE", "0.62"))

    async def judge(self, brain_input: BrainInput, state: Dict[str, Any], draft: Draft, critiques: List[Critique], decision: Decision) -> Verdict:
        risk_mass = _tensor_scalar(state, "risk_mass", 0.0)
        dynamic_gate = max(0.45, self.severity_gate - 0.14 * risk_mass)
        strong = [c for c in critiques if c.severity >= dynamic_gate]
        tensor_conf = _tensor_confidence(state, draft, critiques, draft.tool_result)
        if draft.instruction and decision.requires_confirmation and not brain_input.dry_run:
            return Verdict(
                result="confirm",
                answer="这个动作的风险张量超过执行阈值。我已经生成 dry-run 指令，但需要你明确确认后才执行。",
                confidence=min(tensor_conf, 0.55),
                reason=f"tensor risk gate requires confirmation; risk_mass={risk_mass:.2f}",
                requires_confirmation=True,
            )
        if not strong:
            return Verdict("accept", draft.answer, tensor_conf, f"tensor arbiter accepted; gate={dynamic_gate:.2f}", False)
        sys = "你是裁决者。你必须综合主答、状态张量和强反对意见，输出最终可执行答案；必要时要求确认。"
        prompt = json.dumps(
            {
                "task": brain_input.text,
                "state": _state_without_tensor(state),
                "tensor_frame": _tensor_for_prompt(_tensor_frame(state)),
                "draft": draft.answer,
                "confidence": draft.confidence,
                "tensor_confidence": tensor_conf,
                "dynamic_severity_gate": dynamic_gate,
                "critiques": [c.__dict__ for c in strong],
                "instruction": draft.instruction,
                "tool_result": draft.tool_result,
            },
            ensure_ascii=False,
            default=str,
        )
        try:
            answer = await self.llm.call("arbiter", sys, prompt, max_tokens=brain_input.max_tokens, timeout=30, retries=1)
            return Verdict("revise", answer.strip(), min(max(tensor_conf, 0.50), 0.82), f"{len(strong)} strong objections after tensor gate", False)
        except Exception as e:  # noqa: BLE001
            log.warning("arbiter failed: %s", e)
            return Verdict("revise", draft.answer, min(tensor_conf, 0.55), "arbiter fallback after tensor critique", False)



# =============================================================================
# 4. Brain core main loop
# =============================================================================


class BrainCore:
    def __init__(
        self,
        *,
        llm: Optional[LLMClient] = None,
        memory: Optional[MemoryPort] = None,
        state: Optional[BrainStatePort] = None,
        local_agent: Optional[LocalAgentPort] = None,
    ):
        self.llm = llm or LLMClient()
        self.memory = memory or MemoryPort()
        self.state = state or BrainStatePort()
        self.local_agent = local_agent or LocalAgentPort()
        self.router = BrainRouter()
        self.risk_gate = RiskGate()
        self.planner = Planner(self.llm)
        self.critics = CriticPool(self.llm)
        self.arbiter = Arbiter(self.llm)

    VISION_INTENT_WORDS = ("看图", "看屏幕", "屏幕", "电脑屏幕", "看一下屏幕", "观察", "截图",
                           "摄像头", "外面世界", "外部世界", "视觉", "看见", "看到", "屏幕上",
                           "这张图", "图片里", "screenshot", "camera", "vision", "看看电脑",
                           "看看屏幕", "看下屏幕")

    async def _maybe_vision(self, brain_input: BrainInput) -> Optional[Dict[str, Any]]:
        """有 image_b64 或视觉意图 → 调 Vision Core。否则 None。绝不抛。"""
        low = (brain_input.text or "").lower()
        has_image = bool((brain_input.image_b64 or "").strip())
        has_intent = any(w in brain_input.text or w in low for w in self.VISION_INTENT_WORDS)
        if not has_image and not has_intent:
            return None
        source = (brain_input.vision_source or "").strip()
        if not source:
            source = "image_upload" if has_image else "computer_screenshot"
        goal = brain_input.visual_goal or brain_input.text
        try:
            from chatagi_vision_core import vision_observe
            return await vision_observe(user_key=brain_input.user_key or "adu", source=source,
                                        image_b64=brain_input.image_b64 or "", goal=goal,
                                        write_memory=True)
        except Exception as e:  # noqa: BLE001
            log.warning("BrainCore vision step failed: %s", e)
            return {"ok": False, "vision_summary": f"[vision 不可用] {e}", "degraded": True,
                    "source": source, "risk": {"level": "low"}}

    async def handle(self, brain_input: BrainInput) -> BrainOutput:
        trace = Trace(trace_id=uuid.uuid4().hex[:8])
        try:
            trace.mark("start", user_key=brain_input.user_key)
            state_task = asyncio.create_task(self.state.think_state(brain_input.user_key, brain_input.text, brain_input.context))
            mem_task = asyncio.create_task(self.memory.recall(brain_input.user_key, brain_input.text, k=6))
            state, memories = await asyncio.gather(state_task, mem_task)
            # Fuse recalled memory back into the state tensor before routing.
            tensor_frame = _GLOBAL_TENSOR_ENCODER.encode_state(
                text=brain_input.text,
                context=brain_input.context,
                engine_state=_state_without_tensor(state),
                memories=memories,
                recent_events=(state.get("blackboard", {}) or {}).get("recent_events", []),
            )
            state = await self.state.write_state(
                brain_input.user_key,
                {
                    "memory_recall_count": len(memories),
                    "tensor_frame": tensor_frame,
                    "state_tensor": (tensor_frame.get("vectors") or {}).get("state", []),
                    "intent_vector": (tensor_frame.get("maps") or {}).get("intent", {}),
                    "risk_vector": (tensor_frame.get("maps") or {}).get("risk", {}),
                    "tool_vector": (tensor_frame.get("maps") or {}).get("tool", {}),
                    "model_need_vector": (tensor_frame.get("maps") or {}).get("model", {}),
                },
                actor="memory_tensor",
                event_type="tensor_fusion",
                summary="state tensor fused with memory recall",
                trace_id=trace.trace_id,
                persist_engine=False,
            )
            trace.mark(
                "recall_state",
                memories=len(memories),
                risk_mass=round(_tensor_scalar(state, "risk_mass", 0.0), 3),
                novelty=round(_tensor_scalar(state, "novelty", 0.0), 3),
                tensor_dim=len(state.get("state_tensor") or []),
            )

            # ✅ 视觉预处理:有图 or 视觉意图 → 先"看",把 vision_summary 注入状态/张量。
            vision = await self._maybe_vision(brain_input)
            if vision is not None:
                vsum = str(vision.get("vision_summary") or "")
                vrisk = (vision.get("risk") or {}).get("level", "low")
                vt = _GLOBAL_TENSOR_ENCODER.text_embedding(vsum)
                tf = _tensor_frame(state)
                if isinstance(tf.get("vectors"), dict):
                    tf["vectors"]["vision_tensor"] = vt
                if isinstance(tf.get("scalars"), dict):
                    tf["scalars"]["vision_present"] = 1.0
                    tf["scalars"]["vision_risk"] = {"low": 0.1, "medium": 0.5, "high": 0.85}.get(vrisk, 0.1)
                state = await self.state.write_state(
                    brain_input.user_key,
                    {"last_vision": {
                        "source": vision.get("source"),
                        "summary": vsum,
                        "active_app": vision.get("active_app"),
                        "objects": (vision.get("objects") or [])[:12],
                        "ui_elements": (vision.get("ui_elements") or [])[:12],
                        "errors": (vision.get("errors") or [])[:6],
                        "risk": vision.get("risk"),
                    },
                     "tensor_frame": tf},
                    actor="vision", event_type="vision_observe",
                    summary=f"vision: {vsum[:80]}", trace_id=trace.trace_id, persist_engine=False)
                trace.mark("vision", source=vision.get("source"), risk=vrisk,
                           summary=vsum[:80], degraded=bool(vision.get("degraded")))

            decision = self.router.decide(brain_input.text, state, brain_input.allow_web, brain_input.allow_tools)
            trace.mark(
                "route",
                role=decision.role_key,
                risk=decision.risk.value,
                tool=decision.need_tool,
                web=decision.need_web,
                critic=decision.need_critic,
                route_reason=decision.route_reason,
                model_entropy=round(_tensor_scalar(state, "model_entropy", 0.0), 3),
            )

            draft = await self.planner.draft(brain_input, state, memories, decision)
            state = await self.state.write_state(
                brain_input.user_key,
                {"last_plan_tensor": _GLOBAL_TENSOR_ENCODER.encode_patch(draft.plan), "left_brain_plan": draft.plan},
                actor="planner",
                event_type="plan_tensor",
                summary="planner output encoded as tensor",
                trace_id=trace.trace_id,
                persist_engine=False,
            )
            trace.mark("draft", confidence=round(draft.confidence, 2), needs_tool=bool(draft.plan.get("needs_tool")))

            # Tool phase. The planner may request a tool even if heuristic router missed it.
            if brain_input.allow_tools and bool(draft.plan.get("needs_tool")):
                action = str(draft.plan.get("tool_action") or "").strip()
                payload = draft.plan.get("tool_payload") if isinstance(draft.plan.get("tool_payload"), dict) else {}
                risk2, needs_conf, reason = self.risk_gate.evaluate(brain_input.text, action, payload, state)
                if _risk_rank(risk2) > _risk_rank(decision.risk):
                    decision.risk = risk2
                allowed, requires_confirmation, gate_reason = self.risk_gate.allow(risk2, brain_input.confirmation_token, brain_input.dry_run)
                instruction = {
                    "type": "computer_action",
                    "target": "computer",
                    "tool": "local_agent",
                    "goal": brain_input.text,
                    "action": action,
                    "payload": payload,
                    "risk_level": risk2.value,
                    "requires_confirmation": bool(requires_confirmation),
                    "gate_reason": gate_reason,
                }
                draft.instruction = instruction
                trace.mark("risk_gate", action=action, risk=risk2.value, allowed=allowed, confirmation=requires_confirmation)
                if brain_input.dry_run or not allowed:
                    draft.tool_result = {"ok": allowed, "dry_run": True, "requires_confirmation": requires_confirmation, "reason": gate_reason}
                else:
                    draft.tool_result = await self.local_agent.execute_action(action, payload)
                    trace.mark("tool", action=action, ok=bool(draft.tool_result.get("ok")))
                state = await self.state.write_state(
                    brain_input.user_key,
                    {
                        "last_right_brain_instruction": draft.instruction,
                        "last_tool_result": draft.tool_result,
                        "last_observation_tensor": _GLOBAL_TENSOR_ENCODER.encode_patch({"instruction": draft.instruction, "tool_result": draft.tool_result}),
                    },
                    actor="right_brain",
                    event_type="tool_observation",
                    summary=f"tool {action} observed",
                    trace_id=trace.trace_id,
                    persist_engine=False,
                )
                draft = await self.planner.finalize(brain_input, state, draft, decision)
                trace.mark("finalize", confidence=round(draft.confidence, 2))

            critiques: List[Critique] = []
            if decision.need_critic or draft.confidence < 0.7 or draft.tool_result is not None:
                critiques = await self.critics.critique(brain_input, state, draft, decision)
                state = await self.state.write_state(
                    brain_input.user_key,
                    {
                        "last_critique_tensor": _GLOBAL_TENSOR_ENCODER.encode_patch({"critiques": [c.__dict__ for c in critiques]}),
                        "last_critiques": [c.__dict__ for c in critiques],
                    },
                    actor="critic_pool",
                    event_type="critique_tensor",
                    summary="heterogeneous critiques encoded as tensor",
                    trace_id=trace.trace_id,
                    persist_engine=False,
                )
                trace.mark("critique", n=len(critiques), severities=[round(c.severity, 2) for c in critiques])

            verdict = await self.arbiter.judge(brain_input, state, draft, critiques, decision)
            trace.mark("judge", result=verdict.result, confidence=round(verdict.confidence, 2))

            # Async memory/state write-back. It must never block the response.
            memory_line = self._build_memory_line(brain_input, verdict, draft)
            memory_meta = {
                "trace_id": trace.trace_id,
                "result": verdict.result,
                "status": verdict.result,
                "goal": brain_input.text,
                "source": "brain_core",
                "steps": trace.events,
                "importance": 4 if verdict.result in ("accept", "revise") else 3,
            }
            self.memory.remember_async(brain_input.user_key, memory_line, meta=memory_meta)
            self.memory.remember_structured_async(brain_input.user_key, "timeline", f"BrainCore task {verdict.result}: {brain_input.text[:180]}", meta=memory_meta)
            self.memory.remember_structured_async(brain_input.user_key, "episode", memory_line, meta=memory_meta)
            if verdict.result in ("fail", "revise") or (draft.tool_result and not draft.tool_result.get("ok", True)):
                self.memory.remember_structured_async(
                    brain_input.user_key,
                    "procedural",
                    f"BrainCore lesson: task={brain_input.text[:160]}; result={verdict.result}; reason={verdict.reason[:180]}",
                    meta={**memory_meta, "tags": "braincore,error,lesson"},
                )
            asyncio.create_task(
                self.state.write_state(
                    brain_input.user_key,
                    {
                        "last_task": brain_input.text,
                        "last_result": verdict.result,
                        "last_answer": verdict.answer[:500],
                        "last_trace_id": trace.trace_id,
                        "last_right_brain_instruction": draft.instruction,
                        "last_tool_result": draft.tool_result,
                    },
                    actor="brain_core",
                    event_type="turn_result",
                    summary=f"{brain_input.text[:80]} -> {verdict.result}",
                    trace_id=trace.trace_id,
                )
            )

            return BrainOutput(
                ok=True,
                trace_id=trace.trace_id,
                result=verdict.result,
                answer=verdict.answer,
                confidence=verdict.confidence,
                requires_confirmation=verdict.requires_confirmation,
                instruction=draft.instruction,
                tool_result=draft.tool_result,
                state=state,
                trace=trace.events,
                tensor=_tensor_for_prompt(_tensor_frame(state)),
            )
        except Exception as e:  # noqa: BLE001
            trace.mark("fail", error=str(e))
            log.exception("BrainCore failed")
            return BrainOutput(
                ok=False,
                trace_id=trace.trace_id,
                result="fail",
                answer=f"大脑链路失败：{e}",
                confidence=0.0,
                state={},
                trace=trace.events,
                tensor={},
            )

    @staticmethod
    def _build_memory_line(brain_input: BrainInput, verdict: Verdict, draft: Draft) -> str:
        mem = str(draft.plan.get("memory_to_write") or "").strip() if isinstance(draft.plan, dict) else ""
        if mem:
            return mem
        return f"用户任务：{brain_input.text[:220]}；大脑结果：{verdict.result}；回答摘要：{verdict.answer[:260]}"


# =============================================================================
# 5. FastAPI router and runtime configuration
# =============================================================================


_CORE: BrainCore = BrainCore()
router = APIRouter(prefix="/api/brain/core", tags=["chatagi-brain-core"])


def configure_brain_core(
    *,
    memory_engine: Any = None,
    memory_search_fn: Optional[MemorySearchFn] = None,
    memory_add_fn: Optional[MemoryAddFn] = None,
    brain_state_engine: Any = None,
    local_agent_callable: Optional[LocalAgentCallable] = None,
    llm_registry: Optional[Dict[str, ModelSpec]] = None,
) -> BrainCore:
    """Attach existing server_session.py runtime objects to BrainCore."""
    global _CORE
    _CORE = BrainCore(
        llm=LLMClient(llm_registry),
        memory=MemoryPort(memory_engine, memory_search_fn, memory_add_fn),
        state=BrainStatePort(brain_state_engine),
        local_agent=LocalAgentPort(local_agent_callable),
    )
    return _CORE


@router.get("/health")
async def brain_core_health() -> Dict[str, Any]:
    llm = _CORE.llm
    providers = {p.value: llm.has_provider_key(p) for p in Provider}
    return {
        "ok": True,
        "brain": "ChatAGI BrainCore v3.2 Embodied Projection",
        "tensor_math": {
            "enabled": True,
            "backend": "numpy" if np is not None else "python",
            "embedding_dim": _GLOBAL_TENSOR_ENCODER.embed_dim,
            "intent_dims": TensorEncoder.INTENT_DIMS,
            "risk_dims": TensorEncoder.RISK_DIMS,
        },
        "embodied_projection": {
            "enabled": True,
            "mode": "target_state_skill_control",
            "body_parts": EmbodiedBodyEncoder.BODY_PARTS if "EmbodiedBodyEncoder" in globals() else [],
            "world_version": "embodied.world_tensor.v1",
        },
        "providers": providers,
        "local_agent_base_url": _CORE.local_agent.base_url,
        "has_local_agent_callable": bool(_CORE.local_agent.callable is not None),
        "has_memory_engine": bool(_CORE.memory.memory_engine is not None),
        "has_brain_state_engine": bool(_CORE.state.engine is not None),
    }


@router.get("/tensor/{user_key}")
async def brain_core_tensor_state(user_key: str) -> Dict[str, Any]:
    state = await _CORE.state.read_state(user_key)
    return {
        "ok": True,
        "user_key": user_key,
        "tensor": _tensor_for_prompt(_tensor_frame(state), include_embeddings=True),
        "blackboard": state.get("blackboard", {}),
        "last_patch_tensor": state.get("last_patch_tensor", {}),
        "tensor_journal": state.get("tensor_journal", [])[-16:] if isinstance(state.get("tensor_journal"), list) else [],
    }


@router.post("/think")
async def brain_core_think(request: Request) -> JSONResponse:
    try:
        body = await request.json()
        brain_input = BrainInput(**(body if isinstance(body, dict) else {}))
    except Exception as e:  # noqa: BLE001
        raise HTTPException(status_code=400, detail={"ok": False, "error": "bad_request", "message": str(e)})
    out = await _CORE.handle(brain_input)
    return JSONResponse(out.model_dump())


@router.post("/dry-run")
async def brain_core_dry_run(request: Request) -> JSONResponse:
    try:
        body = await request.json()
        if not isinstance(body, dict):
            body = {}
        body["dry_run"] = True
        brain_input = BrainInput(**body)
    except Exception as e:  # noqa: BLE001
        raise HTTPException(status_code=400, detail={"ok": False, "error": "bad_request", "message": str(e)})
    out = await _CORE.handle(brain_input)
    return JSONResponse(out.model_dump())


# =============================================================================
# 6. Utility functions
# =============================================================================



def _deep_merge(base: Dict[str, Any], patch: Dict[str, Any]) -> Dict[str, Any]:
    """Recursive dict merge used by the blackboard. Lists/scalars replace."""
    out = copy.deepcopy(base if isinstance(base, dict) else {})
    for key, value in (patch or {}).items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = _deep_merge(out[key], value)
        else:
            out[key] = copy.deepcopy(value)
    return out


def _compact_for_event(patch: Dict[str, Any], *, max_chars: int = 1400) -> Dict[str, Any]:
    """Keep blackboard events useful without letting huge tool payloads bloat state."""
    try:
        obj = copy.deepcopy(patch)
        s = json.dumps(obj, ensure_ascii=False, default=str)
        if len(s) <= max_chars:
            return obj
        return {"_truncated": True, "preview": s[:max_chars]}
    except Exception:
        return {"_unserializable": str(type(patch))}


def _risk_rank(risk: Risk) -> int:
    return {Risk.LOW: 0, Risk.MEDIUM: 1, Risk.HIGH: 2, Risk.BLOCKED: 3}.get(risk, 0)

def _now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _ok_action(action: str, result: Any) -> Dict[str, Any]:
    if isinstance(result, dict) and result.get("ok") is False:
        return {"ok": False, "action": action, "result": result}
    return {"ok": True, "action": action, "result": result}


def _float01(v: Any, default: float = 0.5) -> float:
    try:
        x = float(str(v).strip())
    except Exception:
        x = default
    return max(0.0, min(1.0, x))


def _extract_json_object(text: str) -> Dict[str, Any]:
    text = (text or "").strip()
    if not text:
        raise JsonContractError("empty JSON output")
    if text.startswith("```"):
        text = re.sub(r"^```(?:json)?\s*", "", text, flags=re.I).strip()
        text = re.sub(r"\s*```$", "", text).strip()
    try:
        obj = json.loads(text)
    except Exception:
        start = text.find("{")
        end = text.rfind("}")
        if start < 0 or end <= start:
            raise JsonContractError(f"no JSON object found: {text[:200]}")
        obj = json.loads(text[start : end + 1])
    if not isinstance(obj, dict):
        raise JsonContractError("JSON root is not an object")
    return obj


def _risk_from_state_or_text(state: Dict[str, Any], text: str) -> Risk:
    rv = _tensor_map_from_state(state, "risk")
    if not rv:
        rv = state.get("risk_vector") if isinstance(state.get("risk_vector"), dict) else {}
    try:
        risk_mass = TensorMath.dot(TensorMath.map_to_vector(rv, TensorEncoder.RISK_DIMS), [0.0, 0.35, 0.75, 1.0])
        if float(rv.get("blocked", 0.0)) >= 0.65 or risk_mass >= 0.82:
            return Risk.BLOCKED
        if float(rv.get("high", 0.0)) >= 0.65 or risk_mass >= 0.58:
            return Risk.HIGH
        if float(rv.get("medium", 0.0)) >= 0.60 or risk_mass >= 0.34:
            return Risk.MEDIUM
    except Exception:
        pass
    low = text.lower()
    if any(w in low or w in text for w in RiskGate.HIGH_RISK_WORDS):
        return Risk.HIGH
    return Risk.LOW


# =============================================================================
# 7. Embodied Projection Control v3.2
# =============================================================================

class EmbodiedObservationInput(BaseModel):
    """A single body/world observation frame.

    The payload is intentionally schema-flexible. A Mac, iPhone, browser, robot,
    car, drone or simulator can all report state through the same contract. The
    encoder turns whatever is present into stable tensors; missing fields become
    low-confidence zeros rather than errors.
    """

    user_key: str = Field(default="default")
    text: str = Field(default="")
    context: Dict[str, Any] = Field(default_factory=dict)
    body: Dict[str, Any] = Field(default_factory=dict)
    world: Dict[str, Any] = Field(default_factory=dict)
    sensors: Dict[str, Any] = Field(default_factory=dict)
    goal: Dict[str, Any] = Field(default_factory=dict)
    source: str = Field(default="external_observation")


class EmbodiedTickInput(EmbodiedObservationInput):
    """Run one embodied projection-control tick.

    The brain never emits raw motor torque. It chooses a target state / skill / 
    constraint bundle. The body runtime translates that into trajectories and
    low-level servo commands.
    """

    candidate_skills: List[str] = Field(default_factory=list)
    horizon_ms: int = Field(default=2500)
    allow_execute: bool = False
    dry_run: bool = True
    confirmation_token: str = ""


@dataclass
class EmbodiedFrame:
    frame_id: str
    timestamp: float
    user_key: str
    text: str
    body: Dict[str, Any]
    world: Dict[str, Any]
    sensors: Dict[str, Any]
    goal: Dict[str, Any]
    tensor: Dict[str, Any]
    summary: Dict[str, Any]


class EmbodiedBodyEncoder:
    """Encode live body state into a stable tensor.

    Body does not mean only a humanoid robot. In ChatAGI's architecture the Mac,
    iPhone, browser and robot are all bodies. A real robot can fill every joint;
    a computer body may only fill screen/mouse/app state. The tensor keeps both
    compatible.
    """

    BODY_PARTS = [
        "head", "torso", "left_arm", "right_arm", "left_hand", "right_hand",
        "base", "screen", "audio", "network", "power", "safety",
    ]
    PART_DIM = 12
    BODY_SCALAR_DIMS = [
        "presence", "stability", "mobility", "manipulation", "perception",
        "power", "thermal", "contact", "human_safe", "emergency", "latency", "confidence",
    ]

    def encode(self, raw: Optional[Dict[str, Any]], sensors: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        raw = raw if isinstance(raw, dict) else {}
        sensors = sensors if isinstance(sensors, dict) else {}
        part_vectors: Dict[str, List[float]] = {}
        for part in self.BODY_PARTS:
            part_vectors[part] = self._encode_part(part, _pick_dict(raw, part), sensors)

        safety_raw = _pick_dict(raw, "safety") or _pick_dict(sensors, "safety")
        power_raw = _pick_dict(raw, "power") or _pick_dict(raw, "battery") or _pick_dict(sensors, "power")
        base_raw = _pick_dict(raw, "base") or _pick_dict(raw, "pose") or raw

        emergency = _boolish(safety_raw.get("emergency_stop") or safety_raw.get("estop") or safety_raw.get("blocked"))
        collision = _float01(safety_raw.get("collision_risk"), 0.0)
        human_distance = _floatish(safety_raw.get("nearest_human_m") or safety_raw.get("human_distance_m"), 9.9)
        battery = _float01(power_raw.get("battery") or power_raw.get("battery_level") or power_raw.get("soc"), 1.0)
        temp = _bounded(_floatish(power_raw.get("temperature_c") or power_raw.get("temp_c"), 35.0), 20.0, 95.0)
        latency = _bounded(_floatish(sensors.get("latency_ms") or raw.get("latency_ms"), 0.0), 0.0, 1500.0)
        stable = 1.0 - max(
            _float01(base_raw.get("tilt") or base_raw.get("tilt_risk"), 0.0),
            _float01(safety_raw.get("fall_risk"), 0.0),
        )
        contact = max(
            _float01(_pick_dict(raw, "left_hand").get("contact"), 0.0),
            _float01(_pick_dict(raw, "right_hand").get("contact"), 0.0),
            _float01(raw.get("contact"), 0.0),
        )
        manipulation = max(
            _present(_pick_dict(raw, "left_arm")), _present(_pick_dict(raw, "right_arm")),
            _present(_pick_dict(raw, "left_hand")), _present(_pick_dict(raw, "right_hand")),
        )
        perception = max(_present(_pick_dict(raw, "head")), _present(_pick_dict(raw, "screen")), _present(sensors))
        mobility = max(_present(_pick_dict(raw, "base")), _float01(base_raw.get("mobility"), 0.0))
        human_safe = 0.0 if emergency else max(0.0, min(1.0, min(1.0, human_distance / 1.2) * (1.0 - collision)))
        scalars = {
            "presence": _present(raw),
            "stability": TensorMath.clamp01(stable),
            "mobility": TensorMath.clamp01(mobility),
            "manipulation": TensorMath.clamp01(manipulation),
            "perception": TensorMath.clamp01(perception),
            "power": TensorMath.clamp01(battery),
            "thermal": 1.0 - temp,
            "contact": TensorMath.clamp01(contact),
            "human_safe": TensorMath.clamp01(human_safe),
            "emergency": 1.0 if emergency else 0.0,
            "latency": 1.0 - latency,
            "confidence": _float01(raw.get("confidence") or sensors.get("confidence"), 0.72 if raw else 0.18),
        }
        vector = TensorMath.l2_normalize(TensorMath.concat(
            *[part_vectors[p] for p in self.BODY_PARTS],
            TensorMath.map_to_vector(scalars, self.BODY_SCALAR_DIMS),
        ))
        return {
            "version": "embodied.body_tensor.v1",
            "parts": part_vectors,
            "scalars": scalars,
            "vector": vector,
            "summary": {
                "battery": round(battery, 3),
                "stable": bool(stable >= 0.62),
                "emergency_stop": bool(emergency),
                "collision_risk": round(collision, 3),
                "nearest_human_m": None if human_distance >= 9.8 else round(human_distance, 3),
                "has_manipulator": bool(manipulation >= 0.35),
                "has_mobility": bool(mobility >= 0.35),
                "has_perception": bool(perception >= 0.35),
            },
        }

    def _encode_part(self, name: str, part: Dict[str, Any], sensors: Dict[str, Any]) -> List[float]:
        part = part if isinstance(part, dict) else {}
        pose = part.get("pose") if isinstance(part.get("pose"), dict) else part
        joints = part.get("joints") if isinstance(part.get("joints"), (list, tuple)) else []
        velocities = part.get("velocities") if isinstance(part.get("velocities"), (list, tuple)) else []
        values = [
            _present(part),
            _bounded(_floatish(pose.get("x"), 0.0), -10.0, 10.0),
            _bounded(_floatish(pose.get("y"), 0.0), -10.0, 10.0),
            _bounded(_floatish(pose.get("z"), 0.0), -3.0, 3.0),
            _angle_norm(_floatish(pose.get("yaw") or pose.get("theta"), 0.0)),
            _angle_norm(_floatish(pose.get("pitch"), 0.0)),
            _angle_norm(_floatish(pose.get("roll"), 0.0)),
            _bounded(_floatish(part.get("speed") or part.get("velocity"), 0.0), 0.0, 3.0),
            _float01(part.get("load") or part.get("effort"), 0.0),
            _float01(part.get("contact") or part.get("touch"), 0.0),
            _float01(part.get("confidence"), 0.7 if part else 0.0),
            _float01(part.get("temperature") or part.get("temperature_c"), 0.35),
        ]
        if joints:
            values[7] = max(values[7], _bounded(sum(abs(_floatish(x, 0.0)) for x in joints[:8]) / max(1, len(joints[:8])), 0.0, 3.14))
        if velocities:
            values[8] = max(values[8], _bounded(sum(abs(_floatish(x, 0.0)) for x in velocities[:8]) / max(1, len(velocities[:8])), 0.0, 2.5))
        return TensorMath.vec(values, dim=self.PART_DIM)


class EmbodiedWorldEncoder:
    """Encode physical / UI world state into scene and affordance tensors."""

    WORLD_SCALAR_DIMS = [
        "presence", "object_count", "human_count", "hazard_count", "target_visible",
        "target_reachable", "target_graspable", "free_space", "dynamic_motion",
        "scene_confidence", "uncertainty", "affordance_density",
    ]

    def encode(self, raw: Optional[Dict[str, Any]], goal: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        raw = raw if isinstance(raw, dict) else {}
        goal = goal if isinstance(goal, dict) else {}
        objects = _listish(raw.get("objects") or _pick_dict(raw, "scene").get("objects"))
        humans = _listish(raw.get("humans") or raw.get("people") or raw.get("persons"))
        hazards = _listish(raw.get("hazards") or raw.get("risks"))
        relations = _listish(raw.get("relations"))
        target_id = str(goal.get("target_id") or goal.get("object_id") or raw.get("target_id") or "").strip()
        target = self._find_target(objects, target_id, goal)
        target_visible = _present(target)
        target_graspable = _float01(target.get("graspable"), 0.0) if target else 0.0
        target_reachable = _float01(target.get("reachable"), 0.0) if target else 0.0
        if target and "distance_m" in target:
            target_reachable = max(target_reachable, 1.0 - _bounded(_floatish(target.get("distance_m"), 2.0), 0.0, 2.0))
        dynamic_motion = max([_float01(o.get("moving") or o.get("dynamic"), 0.0) for o in objects] + [0.0])
        free_space = _float01(raw.get("free_space") or raw.get("free_space_ratio"), 0.5)
        affordance_count = sum(1 for o in objects if any(_boolish(o.get(k)) for k in ("graspable", "clickable", "openable", "reachable", "navigable")))
        scalars = {
            "presence": _present(raw),
            "object_count": _bounded(len(objects), 0.0, 24.0),
            "human_count": _bounded(len(humans), 0.0, 8.0),
            "hazard_count": _bounded(len(hazards), 0.0, 12.0),
            "target_visible": target_visible,
            "target_reachable": target_reachable,
            "target_graspable": target_graspable,
            "free_space": free_space,
            "dynamic_motion": dynamic_motion,
            "scene_confidence": _float01(raw.get("confidence"), 0.70 if raw else 0.12),
            "uncertainty": 1.0 - _float01(raw.get("confidence"), 0.70 if raw else 0.12),
            "affordance_density": _bounded(affordance_count, 0.0, max(1.0, float(len(objects) or 1))),
        }
        scene_text = json.dumps({"goal": goal, "target": target, "objects": objects[:12], "humans": humans[:4], "hazards": hazards[:8], "relations": relations[:20]}, ensure_ascii=False, default=str)
        vector = TensorMath.l2_normalize(TensorMath.concat(
            TensorMath.map_to_vector(scalars, self.WORLD_SCALAR_DIMS),
            _GLOBAL_TENSOR_ENCODER.text_embedding(scene_text[:4000]),
        ))
        return {
            "version": "embodied.world_tensor.v1",
            "scalars": scalars,
            "vector": vector,
            "target": target,
            "summary": {
                "objects": len(objects),
                "humans": len(humans),
                "hazards": len(hazards),
                "target_id": target.get("id") if target else target_id or None,
                "target_type": target.get("type") if target else None,
                "target_visible": bool(target_visible),
                "target_reachable": bool(target_reachable >= 0.55),
                "target_graspable": bool(target_graspable >= 0.55),
                "free_space": round(free_space, 3),
                "uncertainty": round(scalars["uncertainty"], 3),
            },
        }

    def _find_target(self, objects: List[Dict[str, Any]], target_id: str, goal: Dict[str, Any]) -> Dict[str, Any]:
        target_type = str(goal.get("target_type") or goal.get("type") or "").lower().strip()
        target_name = str(goal.get("target") or goal.get("name") or "").lower().strip()
        for obj in objects:
            if not isinstance(obj, dict):
                continue
            oid = str(obj.get("id") or obj.get("object_id") or "").strip()
            if target_id and oid == target_id:
                return obj
        for obj in objects:
            if not isinstance(obj, dict):
                continue
            blob = f"{obj.get('type','')} {obj.get('name','')} {obj.get('label','')}".lower()
            if target_type and target_type in blob:
                return obj
            if target_name and target_name in blob:
                return obj
        return {}


class EmbodiedTensorEncoder:
    """Fuse body, world, goal and feedback into a projection-control tensor."""

    CONTROL_DIMS = ["observe", "ask_user", "stop", "move", "look", "reach", "grasp", "manipulate", "computer", "wait"]

    def __init__(self):
        self.body_encoder = EmbodiedBodyEncoder()
        self.world_encoder = EmbodiedWorldEncoder()

    def encode_frame(
        self,
        *,
        user_key: str,
        text: str,
        body: Dict[str, Any],
        world: Dict[str, Any],
        sensors: Dict[str, Any],
        goal: Dict[str, Any],
        previous: Optional[Dict[str, Any]] = None,
    ) -> EmbodiedFrame:
        previous = previous if isinstance(previous, dict) else {}
        body_t = self.body_encoder.encode(body, sensors)
        world_t = self.world_encoder.encode(world, goal)
        goal_text = json.dumps({"text": text, "goal": goal}, ensure_ascii=False, default=str)
        goal_vec = _GLOBAL_TENSOR_ENCODER.text_embedding(goal_text[:2000])
        body_vec = body_t.get("vector", [])
        world_vec = world_t.get("vector", [])
        previous_prediction = _dig(previous, ["embodied", "last_prediction", "predicted_tensor"], [])
        belief_vec = TensorMath.l2_normalize(TensorMath.weighted_sum(
            [body_vec, world_vec, goal_vec],
            [0.40, 0.42, 0.18],
        ))
        error_vec = []
        prediction_error = 0.0
        if previous_prediction:
            dim = min(len(previous_prediction), len(belief_vec))
            if dim:
                error_vec = [float(belief_vec[i]) - float(previous_prediction[i]) for i in range(dim)]
                prediction_error = min(1.0, math.sqrt(sum(x * x for x in error_vec)))
        risk = self._risk_from_body_world(body_t, world_t, prediction_error)
        control_prior = self._control_prior(body_t, world_t, goal, text, risk)
        tensor = {
            "version": "embodied.projection_frame.v1",
            "vectors": {
                "body": body_vec,
                "world": world_vec,
                "goal": goal_vec,
                "belief": belief_vec,
                "prediction_error": error_vec,
                "control_prior": TensorMath.map_to_vector(control_prior, self.CONTROL_DIMS),
            },
            "maps": {
                "body": body_t.get("scalars", {}),
                "world": world_t.get("scalars", {}),
                "control_prior": control_prior,
                "risk": risk,
            },
            "scalars": {
                "belief_energy": round(sum(abs(float(x)) for x in belief_vec) / max(1, len(belief_vec)), 6),
                "prediction_error_norm": round(prediction_error, 6),
                "body_confidence": body_t.get("scalars", {}).get("confidence", 0.0),
                "world_uncertainty": world_t.get("scalars", {}).get("uncertainty", 1.0),
                "embodied_risk_mass": round(TensorMath.dot(TensorMath.map_to_vector(risk, ["low", "medium", "high", "blocked"]), [0.0, 0.35, 0.75, 1.0]), 6),
            },
            "body_tensor": body_t,
            "world_tensor": world_t,
        }
        summary = {
            "body": body_t.get("summary", {}),
            "world": world_t.get("summary", {}),
            "risk": risk,
            "control_prior": control_prior,
            "prediction_error_norm": tensor["scalars"]["prediction_error_norm"],
        }
        return EmbodiedFrame(
            frame_id=uuid.uuid4().hex[:10],
            timestamp=time.time(),
            user_key=user_key,
            text=text,
            body=body,
            world=world,
            sensors=sensors,
            goal=goal,
            tensor=tensor,
            summary=summary,
        )

    def _risk_from_body_world(self, body_t: Dict[str, Any], world_t: Dict[str, Any], prediction_error: float) -> Dict[str, float]:
        b = body_t.get("scalars", {}) if isinstance(body_t.get("scalars"), dict) else {}
        w = world_t.get("scalars", {}) if isinstance(world_t.get("scalars"), dict) else {}
        emergency = _float01(b.get("emergency"), 0.0)
        low_power = 1.0 - _float01(b.get("power"), 1.0)
        unsafe_human = 1.0 - _float01(b.get("human_safe"), 1.0)
        hazards = _float01(w.get("hazard_count"), 0.0)
        uncertainty = _float01(w.get("uncertainty"), 0.5)
        high = max(0.0, min(1.0, max(unsafe_human * 0.85, hazards * 0.7, prediction_error * 0.9, low_power * 0.45)))
        blocked = max(emergency, 1.0 if low_power > 0.92 else 0.0)
        medium = max(uncertainty * 0.55, high * 0.55)
        low = max(0.0, 1.0 - max(high, medium, blocked))
        return {"low": round(low, 6), "medium": round(medium, 6), "high": round(high, 6), "blocked": round(blocked, 6)}

    def _control_prior(self, body_t: Dict[str, Any], world_t: Dict[str, Any], goal: Dict[str, Any], text: str, risk: Dict[str, float]) -> Dict[str, float]:
        body_s = body_t.get("scalars", {}) if isinstance(body_t.get("scalars"), dict) else {}
        world_s = world_t.get("scalars", {}) if isinstance(world_t.get("scalars"), dict) else {}
        low_text = text.lower()
        blocked = _float01(risk.get("blocked"), 0.0)
        high = _float01(risk.get("high"), 0.0)
        target_reachable = _float01(world_s.get("target_reachable"), 0.0)
        target_graspable = _float01(world_s.get("target_graspable"), 0.0)
        needs_computer = any(w in low_text for w in ("click", "type", "open", "screenshot", "点击", "输入", "打开", "截图")) or str(goal.get("modality") or "").lower() in ("computer", "mac", "browser")
        return {
            "observe": max(_float01(world_s.get("uncertainty"), 0.0), 0.25),
            "ask_user": max(0.1, high * 0.75, _float01(world_s.get("uncertainty"), 0.0) * 0.45),
            "stop": max(blocked, high * 0.55),
            "move": max(0.0, min(1.0, _float01(body_s.get("mobility"), 0.0) * (1.0 - target_reachable))),
            "look": max(0.15, _float01(body_s.get("perception"), 0.0) * (1.0 - _float01(world_s.get("target_visible"), 0.0))),
            "reach": max(0.0, min(1.0, _float01(body_s.get("manipulation"), 0.0) * target_reachable)),
            "grasp": max(0.0, min(1.0, _float01(body_s.get("manipulation"), 0.0) * target_reachable * target_graspable)),
            "manipulate": max(0.0, min(1.0, _float01(body_s.get("manipulation"), 0.0) * target_reachable)),
            "computer": 0.88 if needs_computer else 0.05,
            "wait": max(0.08, high * 0.35),
        }


class ProjectionWorldModel:
    """Lightweight model-predictive controller over discrete skills.

    This does not pretend to be a physics simulator. It is a safety-oriented
    rollout scorer that lets the LLM/orchestrator choose target-state skills,
    while the body runtime owns trajectories, force, balance and servo control.
    """

    DEFAULT_SKILLS = ["observe", "ask_user", "stop", "move_base", "look_at", "reach", "grasp", "release", "manipulate", "computer_action", "wait"]

    def imagine(self, frame: EmbodiedFrame, candidate_skills: Optional[List[str]] = None, horizon_ms: int = 2500) -> Dict[str, Any]:
        skills = [s.strip() for s in (candidate_skills or []) if str(s).strip()] or list(self.DEFAULT_SKILLS)
        rollouts = [self._rollout(frame, skill, horizon_ms) for skill in skills]
        rollouts.sort(key=lambda r: r.get("score", 0.0), reverse=True)
        return {
            "version": "embodied.rollouts.v1",
            "horizon_ms": max(200, int(horizon_ms or 2500)),
            "rollouts": rollouts,
            "best": rollouts[0] if rollouts else {},
        }

    def _rollout(self, frame: EmbodiedFrame, skill: str, horizon_ms: int) -> Dict[str, Any]:
        t = frame.tensor
        maps = t.get("maps", {}) if isinstance(t.get("maps"), dict) else {}
        body = maps.get("body", {}) if isinstance(maps.get("body"), dict) else {}
        world = maps.get("world", {}) if isinstance(maps.get("world"), dict) else {}
        risk = maps.get("risk", {}) if isinstance(maps.get("risk"), dict) else {}
        prior = maps.get("control_prior", {}) if isinstance(maps.get("control_prior"), dict) else {}
        s = skill.lower().strip()
        base_prior = self._prior_for_skill(s, prior)
        risk_mass = TensorMath.dot(TensorMath.map_to_vector(risk, ["low", "medium", "high", "blocked"]), [0.0, 0.35, 0.75, 1.0])
        energy = self._energy_for_skill(s)
        uncertainty = _float01(world.get("uncertainty"), 0.5)
        feasibility = self._feasibility(s, body, world, risk)
        progress = self._progress(s, world, frame.goal, frame.text)
        safety_bonus = 0.18 if s in ("stop", "wait", "ask_user", "observe") and risk_mass >= 0.45 else 0.0
        score = (0.42 * progress) + (0.32 * feasibility) + (0.20 * base_prior) + safety_bonus - (0.30 * risk_mass) - (0.12 * energy) - (0.08 * uncertainty)
        predicted_tensor = TensorMath.l2_normalize(TensorMath.weighted_sum(
            [t.get("vectors", {}).get("belief", []), t.get("vectors", {}).get("goal", []), t.get("vectors", {}).get("control_prior", [])],
            [0.68, 0.22 * max(progress, 0.05), 0.10],
        ))
        return {
            "skill": skill,
            "score": round(float(score), 6),
            "progress": round(progress, 6),
            "feasibility": round(feasibility, 6),
            "risk_mass": round(risk_mass, 6),
            "energy": round(energy, 6),
            "expected_effect": self._expected_effect(s, world),
            "predicted_tensor": predicted_tensor,
        }

    def _prior_for_skill(self, skill: str, prior: Dict[str, Any]) -> float:
        aliases = {
            "move_base": "move", "look_at": "look", "reach_arm": "reach", "grasp_object": "grasp",
            "type_text": "computer", "click": "computer", "open_app": "computer", "screenshot": "computer",
        }
        return _float01(prior.get(skill) or prior.get(aliases.get(skill, skill)), 0.08)

    def _energy_for_skill(self, skill: str) -> float:
        if skill in ("stop", "wait", "ask_user", "observe"):
            return 0.04
        if skill in ("look_at", "screenshot"):
            return 0.12
        if skill in ("click", "type_text", "open_app", "computer_action"):
            return 0.18
        if skill in ("reach", "grasp", "release", "manipulate"):
            return 0.42
        if skill in ("move_base", "navigate"):
            return 0.58
        return 0.30

    def _feasibility(self, skill: str, body: Dict[str, Any], world: Dict[str, Any], risk: Dict[str, Any]) -> float:
        if _float01(risk.get("blocked"), 0.0) >= 0.5:
            return 1.0 if skill in ("stop", "wait", "ask_user") else 0.0
        if skill in ("stop", "wait", "ask_user", "observe"):
            return 1.0
        if skill in ("move_base", "navigate"):
            return min(_float01(body.get("mobility"), 0.0), _float01(world.get("free_space"), 0.5))
        if skill in ("reach", "reach_arm"):
            return min(_float01(body.get("manipulation"), 0.0), _float01(world.get("target_reachable"), 0.0))
        if skill in ("grasp", "grasp_object"):
            return min(_float01(body.get("manipulation"), 0.0), _float01(world.get("target_reachable"), 0.0), _float01(world.get("target_graspable"), 0.0))
        if skill in ("look_at",):
            return _float01(body.get("perception"), 0.0)
        if skill in ("click", "type_text", "open_app", "screenshot", "computer_action"):
            return max(_float01(body.get("perception"), 0.0), _present(body))
        return 0.45

    def _progress(self, skill: str, world: Dict[str, Any], goal: Dict[str, Any], text: str) -> float:
        low = text.lower()
        verb = str(goal.get("verb") or goal.get("intent") or "").lower()
        if skill == "observe":
            return max(0.20, _float01(world.get("uncertainty"), 0.4))
        if skill == "ask_user":
            return 0.50 if _float01(world.get("uncertainty"), 0.0) >= 0.55 else 0.12
        if skill == "stop":
            return 0.28
        if skill in ("move_base", "navigate"):
            return max(0.15, 1.0 - _float01(world.get("target_reachable"), 0.0))
        if skill in ("look_at",):
            return max(0.16, 1.0 - _float01(world.get("target_visible"), 0.0))
        if skill in ("reach", "reach_arm"):
            return max(0.20, _float01(world.get("target_reachable"), 0.0))
        if skill in ("grasp", "grasp_object"):
            grasp_intent = any(w in low for w in ("拿", "抓", "pick", "grasp", "取", "杯", "拿起")) or verb in ("grasp", "pick", "pickup")
            return (0.92 if grasp_intent else 0.35) * _float01(world.get("target_graspable"), 0.0)
        if skill in ("click", "type_text", "open_app", "screenshot", "computer_action"):
            return 0.80 if any(w in low for w in ("click", "type", "open", "screenshot", "点击", "输入", "打开", "截图")) or str(goal.get("modality") or "").lower() in ("computer", "mac", "browser") else 0.20
        return 0.30

    def _expected_effect(self, skill: str, world: Dict[str, Any]) -> Dict[str, Any]:
        if skill == "observe":
            return {"uncertainty_delta": -0.25, "belief_update": True}
        if skill == "ask_user":
            return {"uncertainty_delta": -0.35, "requires_user_input": True}
        if skill == "stop":
            return {"velocity_target": 0, "risk_delta": -0.45}
        if skill == "move_base":
            return {"target_reachable_delta": +0.30, "body_pose_change": True}
        if skill == "look_at":
            return {"target_visible_delta": +0.35, "attention_shift": "target"}
        if skill in ("reach", "reach_arm"):
            return {"hand_to_target_distance_delta": -0.35}
        if skill in ("grasp", "grasp_object"):
            return {"object_relation": "grasped_if_contact_stable"}
        return {"skill_effect": skill}


class ProjectionController:
    """Choose target-state control from imagined rollouts."""

    HARD_RISK_GATE = float(os.getenv("EMBODIED_HARD_RISK_GATE", "0.78"))
    CONFIRM_RISK_GATE = float(os.getenv("EMBODIED_CONFIRM_RISK_GATE", "0.58"))

    def choose(self, frame: EmbodiedFrame, rollouts: Dict[str, Any], *, confirmation_token: str = "") -> Dict[str, Any]:
        best = rollouts.get("best") if isinstance(rollouts.get("best"), dict) else {}
        risk_mass = _dig(frame.tensor, ["scalars", "embodied_risk_mass"], 0.0)
        emergency = _dig(frame.tensor, ["maps", "body", "emergency"], 0.0)
        needs_confirmation = bool(risk_mass >= self.CONFIRM_RISK_GATE and confirmation_token != RiskGate.CONFIRM_TOKEN)
        blocked = bool(emergency >= 0.5 or risk_mass >= self.HARD_RISK_GATE)
        if blocked:
            skill = "stop"
            target_state = {"body.velocity": 0, "safety.mode": "pause_and_replan"}
            needs_confirmation = True
        else:
            skill = str(best.get("skill") or "observe")
            target_state = self._target_state_for_skill(skill, frame)
        control = {
            "version": "embodied.control_directive.v1",
            "mode": "projection_control",
            "skill": skill,
            "target_state": target_state,
            "constraints": {
                "no_raw_motor_commands": True,
                "collision_free": True,
                "human_safe": True,
                "max_force": "body_runtime_safe_default",
                "stop_on_prediction_error_gt": float(os.getenv("EMBODIED_ERROR_STOP_GATE", "0.42")),
                "horizon_ms": rollouts.get("horizon_ms"),
            },
            "requires_confirmation": bool(needs_confirmation),
            "blocked": bool(blocked),
            "reason": "hard safety gate" if blocked else "best projected rollout",
            "selected_rollout": best,
        }
        return control

    def _target_state_for_skill(self, skill: str, frame: EmbodiedFrame) -> Dict[str, Any]:
        target = _dig(frame.tensor, ["world_tensor", "target"], {}) or _dig(frame.tensor, ["world_tensor", "summary"], {})
        if skill == "observe":
            return {"belief.uncertainty": "decrease", "attention": "refresh_scene"}
        if skill == "ask_user":
            return {"dialogue": "ask_clarifying_or_confirmation", "body": "hold_safe"}
        if skill == "stop":
            return {"body.velocity": 0, "actuators": "safe_pause"}
        if skill == "move_base":
            return {"base.relation_to_target": "safe_reachable_pose", "target": target}
        if skill == "look_at":
            return {"head.attention_target": target, "camera": "center_target"}
        if skill in ("reach", "reach_arm"):
            return {"hand.relation_to_target": "near_pregrasp_pose", "target": target}
        if skill in ("grasp", "grasp_object"):
            return {"hand.relation_to_target": "grasp", "object": target, "lift": "only_after_stable_contact"}
        if skill in ("click", "type_text", "open_app", "screenshot", "computer_action"):
            return {"computer.skill": skill, "goal": frame.goal or frame.text}
        return {"skill": skill, "goal": frame.goal or frame.text}


class EmbodiedProjectionEngine:
    """Runtime glue: observation -> tensor belief -> imagined futures -> control directive."""

    def __init__(self, state: BrainStatePort, local_agent: LocalAgentPort):
        self.state = state
        self.local_agent = local_agent
        self.encoder = EmbodiedTensorEncoder()
        self.world_model = ProjectionWorldModel()
        self.controller = ProjectionController()

    async def observe(self, inp: EmbodiedObservationInput) -> Dict[str, Any]:
        previous = await self.state.read_state(inp.user_key)
        frame = self.encoder.encode_frame(
            user_key=inp.user_key,
            text=inp.text,
            body=inp.body,
            world=inp.world,
            sensors=inp.sensors,
            goal=inp.goal,
            previous=previous,
        )
        patch = {
            "embodied": {
                "last_frame_id": frame.frame_id,
                "last_observed_at": _now_iso(),
                "body": frame.body,
                "world": frame.world,
                "sensors": frame.sensors,
                "goal": frame.goal,
                "frame_summary": frame.summary,
                "frame_tensor": _compact_embodied_tensor(frame.tensor),
            },
            "body_state_tensor": frame.tensor.get("vectors", {}).get("body", []),
            "world_state_tensor": frame.tensor.get("vectors", {}).get("world", []),
            "belief_state_tensor": frame.tensor.get("vectors", {}).get("belief", []),
            "prediction_error_tensor": frame.tensor.get("vectors", {}).get("prediction_error", []),
            "embodied_risk_vector": frame.tensor.get("maps", {}).get("risk", {}),
        }
        state = await self.state.write_state(
            inp.user_key,
            patch,
            actor="embodied_perception",
            event_type="embodied_observation",
            summary=f"embodied frame {frame.frame_id} observed",
            trace_id=frame.frame_id,
            persist_engine=False,
        )
        return {"ok": True, "frame": self._frame_for_api(frame), "state": state.get("embodied", {})}

    async def tick(self, inp: EmbodiedTickInput) -> Dict[str, Any]:
        previous = await self.state.read_state(inp.user_key)
        frame = self.encoder.encode_frame(
            user_key=inp.user_key,
            text=inp.text,
            body=inp.body,
            world=inp.world,
            sensors=inp.sensors,
            goal=inp.goal,
            previous=previous,
        )
        rollouts = self.world_model.imagine(frame, inp.candidate_skills, inp.horizon_ms)
        control = self.controller.choose(frame, rollouts, confirmation_token=inp.confirmation_token)
        tool_result: Optional[Dict[str, Any]] = None
        execution_allowed = bool(inp.allow_execute and not inp.dry_run and not control.get("blocked") and not control.get("requires_confirmation"))
        if execution_allowed:
            tool_result = await self._execute_control(control, inp)
        else:
            tool_result = {
                "ok": False if control.get("blocked") else True,
                "dry_run": bool(inp.dry_run or not inp.allow_execute),
                "requires_confirmation": bool(control.get("requires_confirmation")),
                "blocked": bool(control.get("blocked")),
                "reason": control.get("reason"),
            }
        patch = {
            "embodied": {
                "last_frame_id": frame.frame_id,
                "last_tick_at": _now_iso(),
                "frame_summary": frame.summary,
                "frame_tensor": _compact_embodied_tensor(frame.tensor),
                "last_rollouts": _compact_rollouts(rollouts),
                "last_control": control,
                "last_execution": tool_result,
                "last_prediction": {
                    "skill": control.get("skill"),
                    "predicted_tensor": (control.get("selected_rollout") or {}).get("predicted_tensor", []),
                },
            },
            "body_state_tensor": frame.tensor.get("vectors", {}).get("body", []),
            "world_state_tensor": frame.tensor.get("vectors", {}).get("world", []),
            "belief_state_tensor": frame.tensor.get("vectors", {}).get("belief", []),
            "imagined_state_tensor": (control.get("selected_rollout") or {}).get("predicted_tensor", []),
            "control_tensor": frame.tensor.get("vectors", {}).get("control_prior", []),
            "prediction_error_tensor": frame.tensor.get("vectors", {}).get("prediction_error", []),
            "embodied_risk_vector": frame.tensor.get("maps", {}).get("risk", {}),
        }
        state = await self.state.write_state(
            inp.user_key,
            patch,
            actor="projection_controller",
            event_type="embodied_projection_tick",
            summary=f"selected skill={control.get('skill')}",
            trace_id=frame.frame_id,
            persist_engine=False,
        )
        return {
            "ok": True,
            "frame_id": frame.frame_id,
            "frame_summary": frame.summary,
            "rollouts": _compact_rollouts(rollouts),
            "control": control,
            "tool_result": tool_result,
            "state": state.get("embodied", {}),
        }

    async def _execute_control(self, control: Dict[str, Any], inp: EmbodiedTickInput) -> Dict[str, Any]:
        skill = str(control.get("skill") or "observe").strip()
        payload = {
            "skill": skill,
            "target_state": control.get("target_state", {}),
            "constraints": control.get("constraints", {}),
            "goal": inp.goal or {"text": inp.text},
            "source": "chatagi_embodied_projection_v3_2",
        }
        # First try a generic body/robot skill endpoint. If the current local-agent
        # is still a Mac body, fall back to its existing /api/computer/action path.
        result = await self.local_agent.call("POST", "/api/body/skill", payload)
        if isinstance(result, dict) and result.get("ok") is not False and not result.get("error"):
            return _ok_action("body_skill", result)
        result2 = await self.local_agent.call("POST", "/api/robot/skill", payload)
        if isinstance(result2, dict) and result2.get("ok") is not False and not result2.get("error"):
            return _ok_action("robot_skill", result2)
        # Computer-body compatibility.
        computer_action = _skill_to_computer_action(skill, inp)
        if computer_action:
            return await self.local_agent.execute_action(computer_action[0], computer_action[1])
        return _ok_action("agent_action", await self.local_agent.call("POST", "/api/computer/action", payload))

    def _frame_for_api(self, frame: EmbodiedFrame) -> Dict[str, Any]:
        return {
            "frame_id": frame.frame_id,
            "timestamp": frame.timestamp,
            "summary": frame.summary,
            "tensor": _compact_embodied_tensor(frame.tensor),
        }


_EMBODIED: Optional[EmbodiedProjectionEngine] = None
_EMBODIED_CORE_IDS: Tuple[int, int] = (0, 0)


def _get_embodied() -> EmbodiedProjectionEngine:
    global _EMBODIED, _EMBODIED_CORE_IDS
    ids = (id(_CORE.state), id(_CORE.local_agent))
    if _EMBODIED is None or _EMBODIED_CORE_IDS != ids:
        _EMBODIED = EmbodiedProjectionEngine(_CORE.state, _CORE.local_agent)
        _EMBODIED_CORE_IDS = ids
    return _EMBODIED


@router.get("/embodied/health")
async def embodied_health() -> Dict[str, Any]:
    return {
        "ok": True,
        "module": "ChatAGI Embodied Projection Control v3.2",
        "contract": "body/world observation -> belief tensor -> imagined rollouts -> target-state skill control",
        "body_parts": EmbodiedBodyEncoder.BODY_PARTS,
        "control_dims": EmbodiedTensorEncoder.CONTROL_DIMS,
        "no_raw_motor_commands": True,
        "local_agent_base_url": _CORE.local_agent.base_url,
    }


@router.post("/embodied/observe")
async def embodied_observe(request: Request) -> JSONResponse:
    try:
        body = await request.json()
        inp = EmbodiedObservationInput(**(body if isinstance(body, dict) else {}))
    except Exception as e:  # noqa: BLE001
        raise HTTPException(status_code=400, detail={"ok": False, "error": "bad_request", "message": str(e)})
    out = await _get_embodied().observe(inp)
    return JSONResponse(out)


@router.post("/embodied/tick")
async def embodied_tick(request: Request) -> JSONResponse:
    try:
        body = await request.json()
        inp = EmbodiedTickInput(**(body if isinstance(body, dict) else {}))
    except Exception as e:  # noqa: BLE001
        raise HTTPException(status_code=400, detail={"ok": False, "error": "bad_request", "message": str(e)})
    out = await _get_embodied().tick(inp)
    return JSONResponse(out)


@router.get("/embodied/state/{user_key}")
async def embodied_state(user_key: str) -> Dict[str, Any]:
    state = await _CORE.state.read_state(user_key)
    return {
        "ok": True,
        "user_key": user_key,
        "embodied": state.get("embodied", {}),
        "body_state_tensor": state.get("body_state_tensor", [])[:24],
        "world_state_tensor": state.get("world_state_tensor", [])[:24],
        "belief_state_tensor": state.get("belief_state_tensor", [])[:24],
        "imagined_state_tensor": state.get("imagined_state_tensor", [])[:24],
        "control_tensor": state.get("control_tensor", []),
        "prediction_error_tensor": state.get("prediction_error_tensor", [])[:24],
        "blackboard": state.get("blackboard", {}),
    }


def _compact_embodied_tensor(tensor: Dict[str, Any]) -> Dict[str, Any]:
    t = copy.deepcopy(tensor if isinstance(tensor, dict) else {})
    vectors = t.get("vectors") if isinstance(t.get("vectors"), dict) else {}
    for key, value in list(vectors.items()):
        if isinstance(value, list) and len(value) > 32:
            vectors[key] = value[:32]
            vectors[key + "_truncated"] = True
    bt = t.get("body_tensor") if isinstance(t.get("body_tensor"), dict) else {}
    if isinstance(bt.get("parts"), dict):
        bt["parts"] = {k: v[:6] if isinstance(v, list) else v for k, v in bt["parts"].items()}
    return t


def _compact_rollouts(rollouts: Dict[str, Any]) -> Dict[str, Any]:
    r = copy.deepcopy(rollouts if isinstance(rollouts, dict) else {})
    if isinstance(r.get("rollouts"), list):
        compact = []
        for item in r["rollouts"][:8]:
            if isinstance(item, dict):
                item = dict(item)
                pred = item.get("predicted_tensor")
                if isinstance(pred, list) and len(pred) > 24:
                    item["predicted_tensor"] = pred[:24]
                    item["predicted_tensor_truncated"] = True
                compact.append(item)
        r["rollouts"] = compact
    best = r.get("best")
    if isinstance(best, dict) and isinstance(best.get("predicted_tensor"), list) and len(best.get("predicted_tensor")) > 24:
        r["best"] = {**best, "predicted_tensor": best["predicted_tensor"][:24], "predicted_tensor_truncated": True}
    return r


def _pick_dict(obj: Any, key: str) -> Dict[str, Any]:
    if not isinstance(obj, dict):
        return {}
    v = obj.get(key)
    if isinstance(v, dict):
        return v
    # Accept snake/camel/space variants.
    alts = {key.replace("_", ""), key.replace("_", "-")}
    for k, vv in obj.items():
        if str(k).lower().replace("_", "").replace("-", "") in alts and isinstance(vv, dict):
            return vv
    return {}


def _listish(value: Any) -> List[Dict[str, Any]]:
    if isinstance(value, list):
        return [x for x in value if isinstance(x, dict)]
    if isinstance(value, dict):
        return [value]
    return []


def _present(value: Any) -> float:
    if value is None:
        return 0.0
    if isinstance(value, dict):
        return 1.0 if value else 0.0
    if isinstance(value, (list, tuple, set)):
        return 1.0 if value else 0.0
    if isinstance(value, str):
        return 1.0 if value.strip() else 0.0
    return 1.0


def _boolish(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    if isinstance(value, str):
        return value.strip().lower() in ("1", "true", "yes", "y", "on", "ok", "blocked", "emergency")
    return bool(value)


def _bounded(value: float, lo: float, hi: float) -> float:
    try:
        v = float(value)
        lo = float(lo)
        hi = float(hi)
    except Exception:
        return 0.0
    if hi <= lo:
        return 0.0
    return max(0.0, min(1.0, (v - lo) / (hi - lo)))


def _angle_norm(value: float) -> float:
    try:
        v = float(value)
    except Exception:
        return 0.5
    # Accept either radians or degrees.
    if abs(v) > math.pi * 2:
        v = math.radians(v)
    return (math.sin(v) + 1.0) / 2.0


def _dig(obj: Any, path: List[str], default: Any = None) -> Any:
    cur = obj
    for key in path:
        if not isinstance(cur, dict):
            return default
        cur = cur.get(key)
    return default if cur is None else cur


def _skill_to_computer_action(skill: str, inp: EmbodiedTickInput) -> Optional[Tuple[str, Dict[str, Any]]]:
    s = skill.lower().strip()
    goal = inp.goal if isinstance(inp.goal, dict) else {}
    # This helper is only reached in the computer-body fallback, so the body is
    # already a Mac/browser. There the observation primitive is a screenshot,
    # regardless of whether goal.modality was explicitly set.
    if s in ("screenshot", "observe"):
        return ("screenshot", {})
    if s == "click":
        return ("click", goal.get("payload") if isinstance(goal.get("payload"), dict) else {})
    if s == "type_text":
        text = str(goal.get("text") or goal.get("value") or inp.text or "")
        return ("type_text", {"text": text})
    if s == "open_app":
        app = str(goal.get("app") or goal.get("name") or goal.get("target") or "").strip()
        return ("open_app", {"app": app}) if app else None
    if s == "computer_action":
        payload = goal.get("payload") if isinstance(goal.get("payload"), dict) else {"message": inp.text, "goal": goal}
        return ("agent_action", payload)
    return None


if __name__ == "__main__":
    # Syntax / smoke test without requiring API keys.
    async def _demo() -> None:
        core = BrainCore(llm=LLMClient({}))
        # This will fail gracefully if no model keys are present.
        out = await core.handle(BrainInput(text="帮我规划三步上线计划", dry_run=True))
        print(json.dumps(out.model_dump(), ensure_ascii=False, indent=2))

    asyncio.run(_demo())
