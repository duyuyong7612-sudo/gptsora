# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-972acdcfdc427072421e1cbff098a55e0e51f48f55f959ac792cef7bb41b7ad6"
# Source-SHA256: "ea8922abfe6a3c28163c88cffa199ef32188cd5905789b1df112bc2bc0257c4f"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
ChatAGI-Adu 智能路由系统 v2
============================
基于实际 .env 配置的多厂商路由

你的后端现有 Key：
- OPENAI_API_KEY        → GPT-4o, GPT-4o-mini, GPT-5.4
- ANTHROPIC_API_KEY     → Claude Sonnet 4.6
- DEEPSEEK_API_KEY      → DeepSeek V3, DeepSeek R1（直连，最快）
- SILICONFLOW_API_KEY   → 硅基流动聚合（Qwen, GLM-5, Kimi K2.5, MiniMax M2.5 等）
- GOOGLE_API_KEY        → Gemini

核心策略：
- 简单任务 → DeepSeek V3（极便宜）
- 中等任务 → DeepSeek V3 或硅基流动调 Qwen
- 复杂任务 → 硅基流动调顶级中国模型 或 现有美国模型
- 路由本身 → DeepSeek V3 做判断（成本约 ¥0.00003/次）
"""

import asyncio
import time
import json
import os
import logging
import httpx
from enum import Enum
from dataclasses import dataclass, field
from typing import Optional, Dict, List, Any, Callable

logger = logging.getLogger("adu_router")


# ============================================================
# 1. 意图与复杂度
# ============================================================

class Intent(str, Enum):
    CASUAL_CHAT = "casual_chat"
    SIMPLE_QA = "simple_qa"
    CODE = "code"
    DEEP_REASONING = "deep_reasoning"
    CREATIVE = "creative"
    IMAGE = "image"
    TOOL_USE = "tool_use"
    LONG_DOCUMENT = "long_document"
    MATH = "math"


class Complexity(str, Enum):
    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"


@dataclass
class RoutingDecision:
    intent: Intent
    complexity: Complexity
    selected_model: str
    provider: str
    reason: str
    confidence: float = 0.0
    estimated_cost_yuan: float = 0.0


# ============================================================
# 2. 模型注册表（基于你实际的 .env 配置）
# ============================================================

@dataclass
class ModelConfig:
    model_id: str               # API 调用时的 model 名
    provider: str               # deepseek / siliconflow / openai / anthropic / google
    display_name: str
    cost_input_per_million: float   # ¥/百万tokens
    cost_output_per_million: float
    max_context: int
    strengths: List[str]
    tier: str                   # economy / standard / premium / ultra
    supports_vision: bool = False
    supports_tools: bool = False


class ModelRegistry:
    def __init__(self):
        self.models: Dict[str, ModelConfig] = {}
        self._register_all()

    def _register_all(self):
        """注册所有可用模型"""

        # ========== 经济层 (¥0 ~ ¥1/百万tokens) ==========

        self.register(ModelConfig(
            model_id="deepseek-chat",
            provider="deepseek",
            display_name="DeepSeek V3",
            cost_input_per_million=0.2,
            cost_output_per_million=0.8,
            max_context=64000,
            strengths=["casual_chat", "simple_qa", "code", "creative", "math", "deep_reasoning"],
            tier="economy",
            supports_tools=True,
        ))

        self.register(ModelConfig(
            model_id="Qwen/Qwen2.5-7B-Instruct",
            provider="siliconflow",
            display_name="Qwen2.5-7B (免费)",
            cost_input_per_million=0,
            cost_output_per_million=0,
            max_context=32000,
            strengths=["casual_chat", "simple_qa"],
            tier="economy",
        ))

        self.register(ModelConfig(
            model_id="gpt-4o-mini",
            provider="openai",
            display_name="GPT-4o Mini",
            cost_input_per_million=1.05,   # $0.15 × 7
            cost_output_per_million=4.2,   # $0.6 × 7
            max_context=128000,
            strengths=["casual_chat", "simple_qa", "creative", "tool_use"],
            tier="economy",
            supports_vision=True,
            supports_tools=True,
        ))

        # ========== 标准层 (¥1 ~ ¥10/百万tokens) ==========

        self.register(ModelConfig(
            model_id="Pro/deepseek-ai/DeepSeek-V3",
            provider="siliconflow",
            display_name="DeepSeek V3 (硅基)",
            cost_input_per_million=1.0,
            cost_output_per_million=4.0,
            max_context=64000,
            strengths=["code", "deep_reasoning", "math", "creative"],
            tier="standard",
            supports_tools=True,
        ))

        self.register(ModelConfig(
            model_id="Pro/Qwen/Qwen2.5-72B-Instruct",
            provider="siliconflow",
            display_name="Qwen2.5-72B (硅基)",
            cost_input_per_million=4.0,
            cost_output_per_million=8.0,
            max_context=128000,
            strengths=["code", "creative", "simple_qa", "long_document"],
            tier="standard",
            supports_tools=True,
        ))

        # ========== 顶级层 (¥10+/百万tokens) ==========

        self.register(ModelConfig(
            model_id="deepseek-reasoner",
            provider="deepseek",
            display_name="DeepSeek R1",
            cost_input_per_million=1.0,
            cost_output_per_million=16.0,
            max_context=64000,
            strengths=["deep_reasoning", "math", "code"],
            tier="premium",
        ))

        self.register(ModelConfig(
            model_id="Pro/MiniMaxAI/MiniMax-M2.5",
            provider="siliconflow",
            display_name="MiniMax M2.5 (硅基)",
            cost_input_per_million=2.1,
            cost_output_per_million=7.7,
            max_context=200000,
            strengths=["creative", "long_document", "code", "deep_reasoning"],
            tier="premium",
            supports_vision=True,
            supports_tools=True,
        ))

        self.register(ModelConfig(
            model_id="Pro/zai-org/GLM-5",
            provider="siliconflow",
            display_name="GLM-5 (硅基)",
            cost_input_per_million=2.1,
            cost_output_per_million=17.85,
            max_context=200000,
            strengths=["deep_reasoning", "code", "tool_use", "long_document"],
            tier="premium",
            supports_vision=True,
            supports_tools=True,
        ))

        self.register(ModelConfig(
            model_id="Pro/moonshotai/Kimi-K2.5",
            provider="siliconflow",
            display_name="Kimi K2.5 (硅基)",
            cost_input_per_million=2.0,
            cost_output_per_million=8.0,
            max_context=256000,
            strengths=["long_document", "deep_reasoning", "creative", "code"],
            tier="premium",
            supports_vision=True,
            supports_tools=True,
        ))

        # ========== 美国模型（保留作为高端备选）==========

        self.register(ModelConfig(
            model_id="gpt-4o",
            provider="openai",
            display_name="GPT-4o",
            cost_input_per_million=17.5,
            cost_output_per_million=70.0,
            max_context=128000,
            strengths=["code", "deep_reasoning", "image", "tool_use"],
            tier="ultra",
            supports_vision=True,
            supports_tools=True,
        ))

        self.register(ModelConfig(
            model_id="claude-sonnet-4-6",
            provider="anthropic",
            display_name="Claude Sonnet 4.6",
            cost_input_per_million=21.0,
            cost_output_per_million=105.0,
            max_context=200000,
            strengths=["code", "creative", "deep_reasoning", "long_document"],
            tier="ultra",
            supports_vision=True,
            supports_tools=True,
        ))

        self.register(ModelConfig(
            model_id="gemini-2.5-flash",
            provider="google",
            display_name="Gemini 2.5 Flash",
            cost_input_per_million=0.7,
            cost_output_per_million=2.8,
            max_context=1000000,
            strengths=["long_document", "code", "deep_reasoning", "image"],
            tier="standard",
            supports_vision=True,
            supports_tools=True,
        ))

    def register(self, config: ModelConfig):
        self.models[config.model_id] = config

    def get(self, model_id: str) -> Optional[ModelConfig]:
        return self.models.get(model_id)

    def get_upgrade(self, current_id: str, intent: Intent) -> Optional[str]:
        current = self.models.get(current_id)
        if not current:
            return None
        tier_order = ["economy", "standard", "premium", "ultra"]
        current_idx = tier_order.index(current.tier) if current.tier in tier_order else 0
        for tier in tier_order[current_idx + 1:]:
            candidates = [
                m for m in self.models.values()
                if m.tier == tier and intent.value in m.strengths
            ]
            if candidates:
                candidates.sort(key=lambda m: m.cost_output_per_million)
                return candidates[0].model_id
        return None


# ============================================================
# 3. 路由策略表
# ============================================================

ROUTING_TABLE: Dict[tuple, List[str]] = {
    # === 闲聊 → DeepSeek（极便宜）===
    (Intent.CASUAL_CHAT, Complexity.LOW):    ["deepseek-chat", "Qwen/Qwen2.5-7B-Instruct"],
    (Intent.CASUAL_CHAT, Complexity.MEDIUM): ["deepseek-chat", "gpt-4o-mini"],

    # === 简单问答 ===
    (Intent.SIMPLE_QA, Complexity.LOW):      ["deepseek-chat", "Qwen/Qwen2.5-7B-Instruct"],
    (Intent.SIMPLE_QA, Complexity.MEDIUM):   ["deepseek-chat", "gemini-2.5-flash"],

    # === 代码 → DeepSeek为主，复杂的用中国顶级 ===
    (Intent.CODE, Complexity.LOW):           ["deepseek-chat"],
    (Intent.CODE, Complexity.MEDIUM):        ["deepseek-chat", "gemini-2.5-flash", "Pro/Qwen/Qwen2.5-72B-Instruct"],
    (Intent.CODE, Complexity.HIGH):          ["Pro/zai-org/GLM-5", "deepseek-reasoner", "claude-sonnet-4-6"],

    # === 深度推理 ===
    (Intent.DEEP_REASONING, Complexity.LOW):    ["deepseek-chat", "gemini-2.5-flash"],
    (Intent.DEEP_REASONING, Complexity.MEDIUM): ["deepseek-chat", "Pro/MiniMaxAI/MiniMax-M2.5"],
    (Intent.DEEP_REASONING, Complexity.HIGH):   ["deepseek-reasoner", "Pro/zai-org/GLM-5", "Pro/moonshotai/Kimi-K2.5"],

    # === 数学 → DeepSeek R1 最强 ===
    (Intent.MATH, Complexity.LOW):    ["deepseek-chat"],
    (Intent.MATH, Complexity.MEDIUM): ["deepseek-reasoner", "gemini-2.5-flash"],
    (Intent.MATH, Complexity.HIGH):   ["deepseek-reasoner"],

    # === 创意写作 ===
    (Intent.CREATIVE, Complexity.LOW):    ["deepseek-chat", "gpt-4o-mini"],
    (Intent.CREATIVE, Complexity.MEDIUM): ["deepseek-chat", "Pro/MiniMaxAI/MiniMax-M2.5"],
    (Intent.CREATIVE, Complexity.HIGH):   ["Pro/MiniMaxAI/MiniMax-M2.5", "Pro/moonshotai/Kimi-K2.5"],

    # === 图片理解 → 需要 vision ===
    (Intent.IMAGE, Complexity.LOW):    ["gpt-4o-mini", "gemini-2.5-flash"],
    (Intent.IMAGE, Complexity.MEDIUM): ["gemini-2.5-flash", "gpt-4o"],
    (Intent.IMAGE, Complexity.HIGH):   ["gpt-4o", "Pro/moonshotai/Kimi-K2.5"],

    # === 工具使用 ===
    (Intent.TOOL_USE, Complexity.LOW):    ["deepseek-chat", "gpt-4o-mini"],
    (Intent.TOOL_USE, Complexity.MEDIUM): ["deepseek-chat", "Pro/zai-org/GLM-5"],
    (Intent.TOOL_USE, Complexity.HIGH):   ["Pro/zai-org/GLM-5", "gpt-4o"],

    # === 长文档 → Kimi K2.5 256K / Gemini 1M ===
    (Intent.LONG_DOCUMENT, Complexity.LOW):    ["deepseek-chat", "gemini-2.5-flash"],
    (Intent.LONG_DOCUMENT, Complexity.MEDIUM): ["Pro/moonshotai/Kimi-K2.5", "gemini-2.5-flash"],
    (Intent.LONG_DOCUMENT, Complexity.HIGH):   ["Pro/moonshotai/Kimi-K2.5", "Pro/MiniMaxAI/MiniMax-M2.5"],
}


# ============================================================
# 4. 路由分类器（用 DeepSeek V3 做路由，成本约 ¥0.00003/次）
# ============================================================

ROUTER_PROMPT = """你是消息分类器。分析用户消息，只返回JSON，不要其他文字。
{"intent":"casual_chat|simple_qa|code|deep_reasoning|creative|image|tool_use|long_document|math","complexity":"low|medium|high","confidence":0.0-1.0}

规则：
- 打招呼闲聊→casual_chat+low
- 事实问答翻译→simple_qa+low
- 写代码debug技术→code+medium/high
- 数学计算证明→math+medium/high
- 深度分析推理→deep_reasoning+high
- 写作文案故事→creative+medium
- 图片相关→image+medium
- 需要搜索工具→tool_use+medium
- 长文档分析→long_document+medium/high"""


class Router:
    """用 DeepSeek V3 做路由判断"""

    def __init__(self):
        self.api_key = os.getenv("DEEPSEEK_API_KEY", "")
        self.base_url = "https://api.deepseek.com/v1"

    async def classify(self, user_input: str) -> dict:
        """调 DeepSeek V3 分类，成本约 ¥0.00003/次"""
        try:
            async with httpx.AsyncClient() as client:
                resp = await client.post(
                    f"{self.base_url}/chat/completions",
                    headers={
                        "Authorization": f"Bearer {self.api_key}",
                        "Content-Type": "application/json",
                    },
                    json={
                        "model": "deepseek-chat",
                        "messages": [
                            {"role": "system", "content": ROUTER_PROMPT},
                            {"role": "user", "content": user_input[:300]},
                        ],
                        "max_tokens": 100,
                        "temperature": 0.1,
                    },
                    timeout=5.0,
                )
                raw = resp.json()["choices"][0]["message"]["content"].strip()
                raw = raw.strip("```json").strip("```").strip()
                return json.loads(raw)
        except Exception as e:
            logger.warning(f"Router classify failed: {e}")
            return self._fallback_rules(user_input)

    def _fallback_rules(self, text: str) -> dict:
        """规则兜底"""
        t = text.lower()
        if any(k in t for k in ["你好", "hi", "hello", "嗨", "在吗"]):
            return {"intent": "casual_chat", "complexity": "low", "confidence": 0.9}
        if any(k in t for k in ["代码", "code", "bug", "python", "react", "swift", "api", "函数"]):
            return {"intent": "code", "complexity": "medium" if len(text) < 200 else "high", "confidence": 0.8}
        if any(k in t for k in ["数学", "计算", "方程", "证明", "math"]):
            return {"intent": "math", "complexity": "high", "confidence": 0.85}
        if any(k in t for k in ["分析", "推理", "为什么", "对比", "analyze"]):
            return {"intent": "deep_reasoning", "complexity": "high", "confidence": 0.8}
        if any(k in t for k in ["写", "故事", "文案", "诗", "创作"]):
            return {"intent": "creative", "complexity": "medium", "confidence": 0.8}
        if any(k in t for k in ["总结", "摘要", "文档", "文章", "summarize"]):
            return {"intent": "long_document", "complexity": "medium", "confidence": 0.8}
        if any(k in t for k in ["搜索", "查找", "最新", "search"]):
            return {"intent": "tool_use", "complexity": "medium", "confidence": 0.75}
        return {"intent": "simple_qa", "complexity": "medium", "confidence": 0.5}


# ============================================================
# 5. 统一模型调用（支持所有厂商）
# ============================================================

class ModelCaller:
    """
    统一调用所有厂商的模型
    - DeepSeek: 直连（最快最便宜）
    - SiliconFlow: 聚合调中国模型（OpenAI兼容格式）
    - OpenAI: 直连
    - Anthropic: 直连（不同格式）
    - Google: Gemini API
    """

    def __init__(self):
        self.keys = {
            "deepseek": os.getenv("DEEPSEEK_API_KEY", ""),
            "siliconflow": os.getenv("SILICONFLOW_API_KEY", ""),
            "openai": os.getenv("OPENAI_API_KEY", ""),
            "anthropic": os.getenv("ANTHROPIC_API_KEY", ""),
            "google": os.getenv("GOOGLE_API_KEY", ""),
        }
        self.endpoints = {
            "deepseek": "https://api.deepseek.com/v1/chat/completions",
            "siliconflow": "https://api.siliconflow.cn/v1/chat/completions",
            "openai": "https://api.openai.com/v1/chat/completions",
            "anthropic": "https://api.anthropic.com/v1/messages",
            "google": "https://generativelanguage.googleapis.com/v1beta",
        }

    async def call(self, provider: str, model_id: str, messages: list,
                   max_tokens: int = 4096) -> str:
        """统一调用入口"""
        if provider == "anthropic":
            return await self._call_anthropic(model_id, messages, max_tokens)
        elif provider == "google":
            return await self._call_google(model_id, messages, max_tokens)
        else:
            # DeepSeek, SiliconFlow, OpenAI 都兼容 OpenAI 格式
            return await self._call_openai_compatible(provider, model_id, messages, max_tokens)

    async def _call_openai_compatible(self, provider: str, model_id: str,
                                       messages: list, max_tokens: int) -> str:
        """OpenAI 兼容格式（DeepSeek / SiliconFlow / OpenAI）"""
        url = self.endpoints[provider]
        key = self.keys[provider]

        async with httpx.AsyncClient() as client:
            resp = await client.post(
                url,
                headers={
                    "Authorization": f"Bearer {key}",
                    "Content-Type": "application/json",
                },
                json={
                    "model": model_id,
                    "messages": messages,
                    "max_tokens": max_tokens,
                    "stream": False,
                },
                timeout=120.0,
            )
            resp.raise_for_status()
            data = resp.json()
            return data["choices"][0]["message"]["content"]

    async def _call_anthropic(self, model_id: str, messages: list,
                               max_tokens: int) -> str:
        """Anthropic Claude 格式"""
        key = self.keys["anthropic"]
        system_msg = ""
        user_messages = []
        for msg in messages:
            if msg["role"] == "system":
                system_msg = msg["content"]
            else:
                user_messages.append(msg)

        async with httpx.AsyncClient() as client:
            resp = await client.post(
                self.endpoints["anthropic"],
                headers={
                    "x-api-key": key,
                    "anthropic-version": "2023-06-01",
                    "Content-Type": "application/json",
                },
                json={
                    "model": model_id,
                    "system": system_msg,
                    "messages": user_messages,
                    "max_tokens": max_tokens,
                },
                timeout=120.0,
            )
            resp.raise_for_status()
            data = resp.json()
            return data["content"][0]["text"]

    async def _call_google(self, model_id: str, messages: list,
                            max_tokens: int) -> str:
        """Google Gemini 格式"""
        key = self.keys["google"]
        # 转换 messages 格式
        contents = []
        system_instruction = None
        for msg in messages:
            if msg["role"] == "system":
                system_instruction = msg["content"]
            else:
                role = "user" if msg["role"] == "user" else "model"
                contents.append({
                    "role": role,
                    "parts": [{"text": msg["content"]}]
                })

        url = f"{self.endpoints['google']}/models/{model_id}:generateContent?key={key}"

        body = {
            "contents": contents,
            "generationConfig": {"maxOutputTokens": max_tokens},
        }
        if system_instruction:
            body["systemInstruction"] = {
                "parts": [{"text": system_instruction}]
            }

        async with httpx.AsyncClient() as client:
            resp = await client.post(url, json=body, timeout=120.0)
            resp.raise_for_status()
            data = resp.json()
            return data["candidates"][0]["content"]["parts"][0]["text"]


# ============================================================
# 6. 质量守卫
# ============================================================

class QualityGuard:
    SIGNALS = [
        "我不确定", "我不太清楚", "超出我的能力", "我无法",
        "我的知识有限", "i'm not sure", "i cannot", "beyond my capability",
    ]

    def check(self, response: str, intent: Intent, complexity: Complexity) -> dict:
        issues = []
        if complexity in (Complexity.MEDIUM, Complexity.HIGH) and len(response.strip()) < 50:
            issues.append("too_short")
        if sum(1 for s in self.SIGNALS if s in response.lower()) >= 2:
            issues.append("uncertain")
        if intent == Intent.CODE and "```" not in response and complexity != Complexity.LOW:
            issues.append("no_code")
        return {"pass": len(issues) == 0, "should_escalate": len(issues) > 0, "reasons": issues}


# ============================================================
# 7. 上下文管理
# ============================================================

class ContextManager:
    def __init__(self, max_turns: int = 12):
        self.max_turns = max_turns
        self._sessions: Dict[str, List[dict]] = {}
        self._logs: Dict[str, List[dict]] = {}

    def add_turn(self, sid: str, role: str, content: str, model: str = ""):
        if sid not in self._sessions:
            self._sessions[sid] = []
        self._sessions[sid].append({"role": role, "content": content, "model": model, "ts": time.time()})
        if len(self._sessions[sid]) > self.max_turns * 2:
            self._sessions[sid] = self._sessions[sid][-self.max_turns * 2:]

    def build_messages(self, sid: str, system_prompt: str, memory: str = "", profile: str = "") -> list:
        full_sys = system_prompt
        if profile:
            full_sys += f"\n\n## 用户画像\n{profile}"
        if memory:
            full_sys += f"\n\n## 相关记忆\n{memory}"
        messages = [{"role": "system", "content": full_sys}]
        for turn in self._sessions.get(sid, []):
            messages.append({"role": turn["role"], "content": turn["content"]})
        return messages

    def log_decision(self, sid: str, decision: RoutingDecision):
        if sid not in self._logs:
            self._logs[sid] = []
        self._logs[sid].append({
            "intent": decision.intent.value, "model": decision.selected_model,
            "provider": decision.provider, "cost": decision.estimated_cost_yuan, "ts": time.time(),
        })

    def get_stats(self, sid: str) -> dict:
        logs = self._logs.get(sid, [])
        usage = {}
        cost = 0.0
        for l in logs:
            usage[l["model"]] = usage.get(l["model"], 0) + 1
            cost += l.get("cost", 0)
        return {"total_turns": len(self._sessions.get(sid, [])) // 2,
                "model_usage": usage, "total_cost_yuan": round(cost, 4)}


# ============================================================
# 8. 主控制器 - SmartRouter
# ============================================================

class SmartRouter:
    """
    智能路由主控制器

    集成到 server_session.py：
        from cn_router.cn_smart_router import SmartRouter
        smart_router = SmartRouter()

        # 在 handle_message 中：
        result = await smart_router.process(
            session_id=session_id,
            user_input=user_input,
            user_tier=user_tier,
        )
        response = result["response"]
    """

    def __init__(self):
        self.registry = ModelRegistry()
        self.router = Router()
        self.caller = ModelCaller()
        self.guard = QualityGuard()
        self.context = ContextManager()

    async def process(
        self,
        session_id: str,
        user_input: str,
        user_tier: str = "free",
        has_image: bool = False,
        system_prompt: str = "",
        memory_context: str = "",
        user_profile: str = "",
    ) -> dict:
        """
        完整流程：路由分类 → 选模型 → 调用 → 质量检查 → (升级) → 返回
        """

        # 1. 分类
        if has_image:
            classification = {"intent": "image", "complexity": "medium", "confidence": 0.99}
        else:
            classification = await self.router.classify(user_input)

        intent = Intent(classification["intent"])
        complexity = Complexity(classification["complexity"])

        # 2. 选模型
        model_id = self._select(intent, complexity, user_tier, has_image)
        config = self.registry.get(model_id)

        est_cost = (500 * config.cost_input_per_million + 300 * config.cost_output_per_million) / 1_000_000

        decision = RoutingDecision(
            intent=intent, complexity=complexity,
            selected_model=model_id, provider=config.provider,
            reason=classification.get("reason", ""),
            confidence=classification.get("confidence", 0),
            estimated_cost_yuan=est_cost,
        )

        logger.info(
            f"[Route] {intent.value}/{complexity.value} → "
            f"{config.display_name} ({config.provider}) cost≈¥{est_cost:.6f}"
        )

        # 3. 上下文
        self.context.add_turn(session_id, "user", user_input)
        self.context.log_decision(session_id, decision)
        messages = self.context.build_messages(session_id, system_prompt, memory_context, user_profile)

        # 4. 调用
        try:
            response = await self.caller.call(config.provider, model_id, messages)
        except Exception as e:
            logger.error(f"[Call] {config.display_name} failed: {e}, trying fallback")
            # 失败则 fallback 到 DeepSeek
            response = await self.caller.call("deepseek", "deepseek-chat", messages)
            config = self.registry.get("deepseek-chat")

        # 5. 质量检查
        quality = self.guard.check(response, intent, complexity)
        was_escalated = False
        original_model = model_id

        if not quality["pass"]:
            upgrade_id = self.registry.get_upgrade(model_id, intent)
            if upgrade_id:
                upgrade_config = self.registry.get(upgrade_id)
                logger.info(f"[Escalate] {config.display_name} → {upgrade_config.display_name}")
                try:
                    response = await self.caller.call(upgrade_config.provider, upgrade_id, messages)
                    model_id = upgrade_id
                    config = upgrade_config
                    was_escalated = True
                except Exception as e:
                    logger.error(f"[Escalate] Failed: {e}, keeping original response")

        # 6. 记录
        self.context.add_turn(session_id, "assistant", response, model_id)

        return {
            "response": response,
            "model_used": model_id,
            "model_display": config.display_name,
            "provider": config.provider,
            "original_model": original_model,
            "was_escalated": was_escalated,
            "intent": intent.value,
            "complexity": complexity.value,
            "confidence": decision.confidence,
            "estimated_cost_yuan": est_cost,
            "quality": quality,
            "stats": self.context.get_stats(session_id),
        }

    def _select(self, intent: Intent, complexity: Complexity,
                user_tier: str, requires_vision: bool = False) -> str:
        """根据策略表 + 用户等级选模型"""
        tier_access = {
            "free": ["economy"],
            "creator": ["economy", "standard"],
            "pro": ["economy", "standard", "premium"],
            "ultra": ["economy", "standard", "premium", "ultra"],
        }
        allowed = tier_access.get(user_tier, ["economy"])
        candidates = ROUTING_TABLE.get((intent, complexity), ["deepseek-chat"])

        for mid in candidates:
            cfg = self.registry.get(mid)
            if not cfg:
                continue
            if cfg.tier not in allowed:
                continue
            if requires_vision and not cfg.supports_vision:
                continue
            # 检查对应的 API Key 是否存在
            key = self.caller.keys.get(cfg.provider, "")
            if not key:
                continue
            return mid

        return "deepseek-chat"

