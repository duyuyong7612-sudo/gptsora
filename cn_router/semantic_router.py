# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-5c432236b23657a2795f9e21ddd484da79a5211d2f6fc987b09ece2b6618076c"
# Source-SHA256: "4fb611106da269fc86be69359b9ddb881b8bc4de26c8b578985bd39597f4cc71"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
ChatAGI-Adu 智能路由模块 (Semantic Router)
==========================================
混合架构：前置轻量路由 + 后置质量守卫 + 自动升级

部署方式：
- 方案A（推荐起步）：用最便宜的API模型做路由判断，零本地依赖
- 方案B（进阶）：本地跑 Qwen2.5-0.5B 或 sentence-transformers，零API成本

集成到 server_session.py 的 handle_message 流程中即可。
"""

import asyncio
import time
import json
import logging
from enum import Enum
from dataclasses import dataclass, field
from typing import Optional, Dict, List, Any

logger = logging.getLogger("adu_router")


# ============================================================
# 1. 意图与复杂度定义
# ============================================================

class Intent(str, Enum):
    CASUAL_CHAT = "casual_chat"          # 闲聊、打招呼
    SIMPLE_QA = "simple_qa"              # 简单问答（天气、翻译、常识）
    CODE = "code"                        # 写代码、debug、技术问题
    DEEP_REASONING = "deep_reasoning"    # 深度分析、数学推理、复杂逻辑
    CREATIVE = "creative"               # 创意写作、文案、故事
    IMAGE_UNDERSTANDING = "image"        # 图片理解（多模态）
    TOOL_USE = "tool_use"               # 需要调用工具（搜索、计算等）
    LONG_DOCUMENT = "long_document"      # 长文档摘要、分析


class Complexity(str, Enum):
    LOW = "low"        # 一句话能答
    MEDIUM = "medium"  # 需要思考但不太难
    HIGH = "high"      # 需要深度推理或专业知识


@dataclass
class RoutingDecision:
    """路由决策结果"""
    intent: Intent
    complexity: Complexity
    selected_model: str
    reason: str
    confidence: float = 0.0
    timestamp: float = field(default_factory=time.time)


# ============================================================
# 2. 模型注册表
# ============================================================

@dataclass
class ModelConfig:
    """模型配置"""
    model_id: str           # API调用时的model名
    provider: str           # openai / anthropic / deepseek
    display_name: str       # 展示名
    cost_per_1k_input: float   # 每1k tokens输入成本（美元）
    cost_per_1k_output: float  # 每1k tokens输出成本（美元）
    max_context: int        # 最大上下文窗口
    strengths: List[str]    # 擅长的意图类别
    tier_required: str      # 需要的用户等级: free / creator / pro / enterprise
    supports_vision: bool = False
    supports_tools: bool = False
    avg_latency_ms: int = 1000  # 平均延迟


class ModelRegistry:
    """
    模型注册表 - 管理所有可用模型及其能力
    根据你的 Stripe 分层: Free → Creator($9.99) → Pro($19.99) → Ultra($39.99)
    """

    def __init__(self):
        self.models: Dict[str, ModelConfig] = {}
        self._register_defaults()

    def _register_defaults(self):
        """注册默认模型配置 - 根据你的实际后端调整"""

        # === 经济层：处理简单任务 ===
        self.register(ModelConfig(
            model_id="gpt-4o-mini",
            provider="openai",
            display_name="GPT-4o Mini",
            cost_per_1k_input=0.00015,
            cost_per_1k_output=0.0006,
            max_context=128000,
            strengths=["casual_chat", "simple_qa", "creative"],
            tier_required="free",
            supports_vision=True,
            supports_tools=True,
            avg_latency_ms=600,
        ))

        self.register(ModelConfig(
            model_id="deepseek-chat",
            provider="deepseek",
            display_name="DeepSeek V3",
            cost_per_1k_input=0.00014,
            cost_per_1k_output=0.00028,
            max_context=64000,
            strengths=["casual_chat", "simple_qa", "code", "deep_reasoning"],
            tier_required="free",
            supports_vision=False,
            supports_tools=True,
            avg_latency_ms=800,
        ))

        # === 中间层：处理中等复杂度任务 ===
        self.register(ModelConfig(
            model_id="claude-sonnet-4-20250514",
            provider="anthropic",
            display_name="Claude Sonnet 4",
            cost_per_1k_input=0.003,
            cost_per_1k_output=0.015,
            max_context=200000,
            strengths=["code", "creative", "deep_reasoning", "long_document"],
            tier_required="creator",
            supports_vision=True,
            supports_tools=True,
            avg_latency_ms=1200,
        ))

        self.register(ModelConfig(
            model_id="gpt-4o",
            provider="openai",
            display_name="GPT-4o",
            cost_per_1k_input=0.0025,
            cost_per_1k_output=0.01,
            max_context=128000,
            strengths=["code", "deep_reasoning", "image", "tool_use"],
            tier_required="creator",
            supports_vision=True,
            supports_tools=True,
            avg_latency_ms=1000,
        ))

        # === 顶级层：处理最复杂任务 ===
        self.register(ModelConfig(
            model_id="claude-opus-4-20250514",
            provider="anthropic",
            display_name="Claude Opus 4",
            cost_per_1k_input=0.015,
            cost_per_1k_output=0.075,
            max_context=200000,
            strengths=["deep_reasoning", "code", "creative", "long_document"],
            tier_required="pro",
            supports_vision=True,
            supports_tools=True,
            avg_latency_ms=2000,
        ))

    def register(self, config: ModelConfig):
        self.models[config.model_id] = config

    def get(self, model_id: str) -> Optional[ModelConfig]:
        return self.models.get(model_id)

    def get_upgrade_model(self, current_model_id: str, intent: Intent) -> Optional[str]:
        """获取升级模型 - 当前模型搞不定时升级到更强的"""
        current = self.models.get(current_model_id)
        if not current:
            return None

        # 按成本从低到高排序，找到比当前贵的、且擅长该意图的模型
        candidates = [
            m for m in self.models.values()
            if m.cost_per_1k_input > current.cost_per_1k_input
            and intent.value in m.strengths
        ]
        candidates.sort(key=lambda m: m.cost_per_1k_input)
        return candidates[0].model_id if candidates else None


# ============================================================
# 3. 语义路由器（核心）
# ============================================================

# --- 3A: API路由方案（推荐起步，零本地依赖）---

ROUTER_SYSTEM_PROMPT = """你是一个消息分类器。分析用户消息，返回JSON格式的分类结果。

分类维度：
1. intent（意图）：casual_chat | simple_qa | code | deep_reasoning | creative | image | tool_use | long_document
2. complexity（复杂度）：low | medium | high
3. confidence（置信度）：0.0-1.0
4. reason（理由）：一句话解释

分类规则：
- 打招呼、闲聊、简单对话 → casual_chat + low
- 事实性问答、翻译、天气 → simple_qa + low
- 写代码、debug、技术问题 → code + medium/high
- 数学证明、逻辑推理、深度分析 → deep_reasoning + high
- 写作、文案、故事 → creative + medium
- 涉及图片理解 → image + medium
- 需要搜索、计算等工具 → tool_use + medium
- 长文档分析、摘要 → long_document + medium/high

只返回JSON，不要任何其他文字。"""

ROUTER_EXAMPLE = """示例：
用户: "帮我写一个Python爬虫"
{"intent": "code", "complexity": "medium", "confidence": 0.95, "reason": "编程任务，中等复杂度"}

用户: "你好"
{"intent": "casual_chat", "complexity": "low", "confidence": 0.99, "reason": "简单打招呼"}

用户: "证明哥德巴赫猜想的弱形式"
{"intent": "deep_reasoning", "complexity": "high", "confidence": 0.92, "reason": "数学证明，需要深度推理"}"""


class SemanticRouter:
    """
    语义路由器 - 分析用户输入，决定发给哪个模型

    支持两种模式：
    - api模式：用最便宜的LLM做路由判断（推荐起步）
    - local模式：本地embedding相似度匹配（进阶，需要安装sentence-transformers）
    """

    def __init__(
        self,
        model_registry: ModelRegistry,
        mode: str = "api",  # "api" 或 "local"
        router_model: str = "gpt-4o-mini",  # 路由用的模型
    ):
        self.registry = model_registry
        self.mode = mode
        self.router_model = router_model

        # 路由策略表：(intent, complexity) → 优先模型列表
        # 从便宜到贵排列，按用户tier筛选后取第一个
        self.routing_table: Dict[tuple, List[str]] = {
            # 简单任务 → 最便宜的模型
            (Intent.CASUAL_CHAT, Complexity.LOW):    ["deepseek-chat", "gpt-4o-mini"],
            (Intent.CASUAL_CHAT, Complexity.MEDIUM): ["deepseek-chat", "gpt-4o-mini"],
            (Intent.SIMPLE_QA, Complexity.LOW):      ["deepseek-chat", "gpt-4o-mini"],
            (Intent.SIMPLE_QA, Complexity.MEDIUM):   ["gpt-4o-mini", "deepseek-chat"],

            # 代码任务 → 中等模型，复杂的用顶级
            (Intent.CODE, Complexity.LOW):           ["deepseek-chat", "gpt-4o-mini"],
            (Intent.CODE, Complexity.MEDIUM):        ["claude-sonnet-4-20250514", "gpt-4o"],
            (Intent.CODE, Complexity.HIGH):          ["claude-opus-4-20250514", "claude-sonnet-4-20250514"],

            # 深度推理 → 直接上强模型
            (Intent.DEEP_REASONING, Complexity.LOW):    ["deepseek-chat", "gpt-4o"],
            (Intent.DEEP_REASONING, Complexity.MEDIUM): ["gpt-4o", "claude-sonnet-4-20250514"],
            (Intent.DEEP_REASONING, Complexity.HIGH):   ["claude-opus-4-20250514", "gpt-4o"],

            # 创意写作
            (Intent.CREATIVE, Complexity.LOW):    ["gpt-4o-mini", "deepseek-chat"],
            (Intent.CREATIVE, Complexity.MEDIUM): ["claude-sonnet-4-20250514", "gpt-4o"],
            (Intent.CREATIVE, Complexity.HIGH):   ["claude-opus-4-20250514", "claude-sonnet-4-20250514"],

            # 图片理解 → 必须支持vision
            (Intent.IMAGE_UNDERSTANDING, Complexity.LOW):    ["gpt-4o-mini"],
            (Intent.IMAGE_UNDERSTANDING, Complexity.MEDIUM): ["gpt-4o", "claude-sonnet-4-20250514"],
            (Intent.IMAGE_UNDERSTANDING, Complexity.HIGH):   ["claude-opus-4-20250514", "gpt-4o"],

            # 工具使用
            (Intent.TOOL_USE, Complexity.LOW):    ["gpt-4o-mini"],
            (Intent.TOOL_USE, Complexity.MEDIUM): ["gpt-4o", "claude-sonnet-4-20250514"],
            (Intent.TOOL_USE, Complexity.HIGH):   ["gpt-4o", "claude-opus-4-20250514"],

            # 长文档
            (Intent.LONG_DOCUMENT, Complexity.LOW):    ["gpt-4o-mini", "deepseek-chat"],
            (Intent.LONG_DOCUMENT, Complexity.MEDIUM): ["claude-sonnet-4-20250514", "gpt-4o"],
            (Intent.LONG_DOCUMENT, Complexity.HIGH):   ["claude-opus-4-20250514", "claude-sonnet-4-20250514"],
        }

        # 本地模式的embedding模型（懒加载）
        self._local_model = None
        self._intent_anchors = None

    # ----- API 路由模式 -----

    async def classify_via_api(self, user_input: str, call_llm_func) -> dict:
        """
        用最便宜的LLM做意图分类
        call_llm_func: 你现有的LLM调用函数，签名 async (model, messages) -> str
        """
        messages = [
            {"role": "system", "content": ROUTER_SYSTEM_PROMPT + "\n\n" + ROUTER_EXAMPLE},
            {"role": "user", "content": user_input[:500]},  # 截断，路由不需要全文
        ]

        try:
            raw = await call_llm_func(self.router_model, messages, max_tokens=200)
            # 清理可能的markdown包裹
            raw = raw.strip().strip("```json").strip("```").strip()
            result = json.loads(raw)
            return result
        except (json.JSONDecodeError, Exception) as e:
            logger.warning(f"Router classification failed: {e}, falling back to defaults")
            return {
                "intent": "simple_qa",
                "complexity": "medium",
                "confidence": 0.5,
                "reason": "classification_failed_fallback"
            }

    # ----- 本地 Embedding 路由模式 -----

    def _load_local_model(self):
        """懒加载本地embedding模型（仅local模式需要）"""
        if self._local_model is not None:
            return

        try:
            from sentence_transformers import SentenceTransformer
            import numpy as np

            # ~80MB，Render免费tier能跑
            self._local_model = SentenceTransformer('all-MiniLM-L6-v2')
            self._np = np

            # 预计算意图锚点向量
            intent_examples = {
                Intent.CASUAL_CHAT: [
                    "你好", "hi", "今天天气不错", "在吗", "hello",
                    "嗨", "晚上好", "闲聊一下"
                ],
                Intent.SIMPLE_QA: [
                    "什么是光合作用", "美国总统是谁", "翻译这句话",
                    "北京到上海多远", "1+1等于几"
                ],
                Intent.CODE: [
                    "帮我写一个Python函数", "这段代码有bug", "怎么用React",
                    "debug this error", "写一个API接口", "SwiftUI布局问题"
                ],
                Intent.DEEP_REASONING: [
                    "分析这个商业模式的可行性", "证明这个数学定理",
                    "对比两种架构的优劣", "为什么会出现这种现象",
                    "帮我做深入分析"
                ],
                Intent.CREATIVE: [
                    "帮我写一首诗", "写个故事", "写一段文案",
                    "帮我想个slogan", "创意写作"
                ],
                Intent.TOOL_USE: [
                    "帮我搜索最新新闻", "查一下股价", "今天天气怎么样",
                    "帮我算一下", "搜索一下"
                ],
                Intent.LONG_DOCUMENT: [
                    "总结这篇文章", "帮我分析这个文档", "这份报告说了什么",
                    "帮我提取关键信息", "概括主要内容"
                ],
            }

            self._intent_anchors = {}
            for intent, examples in intent_examples.items():
                embeddings = self._local_model.encode(examples)
                # 用所有示例的平均向量作为锚点
                self._intent_anchors[intent] = np.mean(embeddings, axis=0)

            logger.info("Local embedding model loaded successfully")

        except ImportError:
            logger.error("sentence-transformers not installed. Run: pip install sentence-transformers")
            raise

    def classify_local(self, user_input: str) -> dict:
        """本地embedding相似度分类"""
        self._load_local_model()
        np = self._np

        query_embedding = self._local_model.encode([user_input[:500]])[0]

        best_intent = Intent.SIMPLE_QA
        best_score = -1.0

        for intent, anchor in self._intent_anchors.items():
            # 余弦相似度
            score = float(np.dot(query_embedding, anchor) / (
                np.linalg.norm(query_embedding) * np.linalg.norm(anchor)
            ))
            if score > best_score:
                best_score = score
                best_intent = intent

        # 根据输入长度和关键词粗判复杂度
        complexity = self._estimate_complexity(user_input)

        return {
            "intent": best_intent.value,
            "complexity": complexity.value,
            "confidence": round(best_score, 3),
            "reason": f"embedding_similarity_{best_score:.3f}"
        }

    def _estimate_complexity(self, text: str) -> Complexity:
        """基于规则粗判复杂度"""
        length = len(text)

        high_keywords = ["分析", "对比", "证明", "为什么", "深入", "详细", "完整",
                        "analyze", "compare", "prove", "explain in detail", "comprehensive"]
        low_keywords = ["你好", "hi", "hello", "是什么", "多少", "谁是",
                       "what is", "who is", "how many"]

        text_lower = text.lower()

        if any(kw in text_lower for kw in high_keywords) or length > 500:
            return Complexity.HIGH
        elif any(kw in text_lower for kw in low_keywords) or length < 30:
            return Complexity.LOW
        else:
            return Complexity.MEDIUM

    # ----- 统一路由入口 -----

    async def route(
        self,
        user_input: str,
        user_tier: str = "free",
        has_image: bool = False,
        call_llm_func=None,
    ) -> RoutingDecision:
        """
        主路由方法 - 分析输入并选择最佳模型

        参数：
            user_input: 用户消息文本
            user_tier: 用户等级 (free/creator/pro/enterprise)
            has_image: 是否包含图片
            call_llm_func: LLM调用函数（仅api模式需要）
        """
        # 图片输入强制走vision模型
        if has_image:
            classification = {
                "intent": "image",
                "complexity": "medium",
                "confidence": 0.99,
                "reason": "image_input_detected"
            }
        elif self.mode == "api" and call_llm_func:
            classification = await self.classify_via_api(user_input, call_llm_func)
        elif self.mode == "local":
            classification = self.classify_local(user_input)
        else:
            # fallback
            classification = {
                "intent": "simple_qa",
                "complexity": "medium",
                "confidence": 0.5,
                "reason": "no_router_available"
            }

        intent = Intent(classification["intent"])
        complexity = Complexity(classification["complexity"])

        # 根据路由表选择模型
        selected_model = self._select_model(intent, complexity, user_tier, has_image)

        return RoutingDecision(
            intent=intent,
            complexity=complexity,
            selected_model=selected_model,
            reason=classification.get("reason", ""),
            confidence=classification.get("confidence", 0.0),
        )

    def _select_model(
        self,
        intent: Intent,
        complexity: Complexity,
        user_tier: str,
        requires_vision: bool = False,
    ) -> str:
        """根据意图+复杂度+用户等级选择模型"""
        tier_order = ["free", "creator", "pro", "enterprise"]
        user_tier_idx = tier_order.index(user_tier) if user_tier in tier_order else 0

        candidates = self.routing_table.get(
            (intent, complexity),
            ["gpt-4o-mini"]  # 默认fallback
        )

        for model_id in candidates:
            config = self.registry.get(model_id)
            if not config:
                continue

            # 检查用户等级是否够
            model_tier_idx = tier_order.index(config.tier_required)
            if model_tier_idx > user_tier_idx:
                continue

            # 如果需要vision，检查模型是否支持
            if requires_vision and not config.supports_vision:
                continue

            return model_id

        # 所有候选都不满足，返回免费层默认
        return "gpt-4o-mini"


# ============================================================
# 4. 质量守卫（后置检查 + 自动升级）
# ============================================================

class QualityGuard:
    """
    质量守卫 - 检查模型回答质量，必要时触发升级

    这就是方案2的思想融入：不是让模型自己判断"我行不行"，
    而是通过客观指标检测回答质量。
    """

    def __init__(self, model_registry: ModelRegistry):
        self.registry = model_registry

        # 低质量回答的信号词
        self.uncertainty_signals_zh = [
            "我不确定", "我不太清楚", "可能不太准确", "超出我的能力",
            "我无法", "这个问题比较复杂", "建议咨询专业人士",
            "我的知识有限", "不在我的训练数据中",
        ]
        self.uncertainty_signals_en = [
            "i'm not sure", "i don't know", "beyond my capability",
            "i cannot", "i'm unable to", "outside my training",
            "you should consult", "i may be wrong",
        ]

        # 需要升级的最大重试次数
        self.max_escalations = 1

    def check_quality(
        self,
        response_text: str,
        intent: Intent,
        complexity: Complexity,
    ) -> dict:
        """
        检查回答质量

        返回：
        {
            "pass": True/False,
            "should_escalate": True/False,
            "reason": "..."
        }
        """
        issues = []

        # 检查1：回答是否过短（对于复杂问题）
        if complexity in (Complexity.MEDIUM, Complexity.HIGH):
            if len(response_text.strip()) < 50:
                issues.append("response_too_short")

        # 检查2：是否含有不确定信号
        response_lower = response_text.lower()
        uncertainty_count = sum(
            1 for signal in (self.uncertainty_signals_zh + self.uncertainty_signals_en)
            if signal in response_lower
        )
        if uncertainty_count >= 2:
            issues.append(f"high_uncertainty_count_{uncertainty_count}")

        # 检查3：代码任务但回答中没有代码块
        if intent == Intent.CODE and "```" not in response_text and complexity != Complexity.LOW:
            issues.append("code_task_no_code_block")

        # 检查4：是否答非所问（简单启发式：回答中完全不包含输入的关键词）
        # 这个可以后续用embedding相似度替代

        should_escalate = len(issues) > 0
        return {
            "pass": not should_escalate,
            "should_escalate": should_escalate,
            "reasons": issues,
        }


# ============================================================
# 5. 上下文管理器（跨模型统一上下文）
# ============================================================

class ContextManager:
    """
    统一上下文管理器 - 确保不同模型看到一致的对话历史

    与你现有的双轨记忆系统（向量+情景）对接。
    """

    def __init__(self, max_recent_turns: int = 10):
        self.max_recent_turns = max_recent_turns
        # session_id → 对话历史
        self._sessions: Dict[str, List[dict]] = {}
        # session_id → 路由决策日志
        self._routing_logs: Dict[str, List[RoutingDecision]] = {}

    def add_turn(self, session_id: str, role: str, content: str, model_used: str = ""):
        """添加一轮对话"""
        if session_id not in self._sessions:
            self._sessions[session_id] = []

        self._sessions[session_id].append({
            "role": role,
            "content": content,
            "model": model_used,
            "timestamp": time.time(),
        })

        # 保持窗口大小
        if len(self._sessions[session_id]) > self.max_recent_turns * 2:
            self._sessions[session_id] = self._sessions[session_id][-self.max_recent_turns * 2:]

    def log_routing(self, session_id: str, decision: RoutingDecision):
        """记录路由决策（用于后续分析优化）"""
        if session_id not in self._routing_logs:
            self._routing_logs[session_id] = []
        self._routing_logs[session_id].append(decision)

    def build_messages(
        self,
        session_id: str,
        system_prompt: str,
        memory_context: str = "",
        user_profile: str = "",
    ) -> List[dict]:
        """
        构建发给模型的完整messages数组

        参数：
            session_prompt: 基础system prompt
            memory_context: 从向量记忆检索的相关上下文
            user_profile: 用户画像摘要
        """
        # 组装system prompt
        full_system = system_prompt

        if user_profile:
            full_system += f"\n\n## 用户画像\n{user_profile}"

        if memory_context:
            full_system += f"\n\n## 相关历史记忆\n{memory_context}"

        messages = [{"role": "system", "content": full_system}]

        # 添加对话历史（去掉model字段，只保留role和content）
        history = self._sessions.get(session_id, [])
        for turn in history:
            messages.append({
                "role": turn["role"],
                "content": turn["content"],
            })

        return messages

    def get_session_stats(self, session_id: str) -> dict:
        """获取会话统计（用于监控面板）"""
        logs = self._routing_logs.get(session_id, [])
        history = self._sessions.get(session_id, [])

        model_usage = {}
        for log in logs:
            model_usage[log.selected_model] = model_usage.get(log.selected_model, 0) + 1

        return {
            "total_turns": len(history) // 2,
            "model_usage": model_usage,
            "routing_decisions": len(logs),
        }


# ============================================================
# 6. 主控制器 - 把所有组件串起来
# ============================================================

class SmartRouter:
    """
    智能路由主控制器

    用法：
        router = SmartRouter(mode="api")

        # 在你的 handle_message 中：
        result = await router.process(
            session_id="user_123_session_456",
            user_input="帮我写一个React组件",
            user_tier="pro",
            system_prompt="你是Adu，一个AI助手...",
            call_llm_func=your_existing_llm_call_function,
        )
        # result.response = 模型回答
        # result.model_used = 实际用了哪个模型
        # result.was_escalated = 是否经过升级
    """

    def __init__(self, mode: str = "api", router_model: str = "gpt-4o-mini"):
        self.registry = ModelRegistry()
        self.router = SemanticRouter(self.registry, mode=mode, router_model=router_model)
        self.guard = QualityGuard(self.registry)
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
        call_llm_func=None,
    ) -> dict:
        """
        完整处理流程：路由 → 调用 → 质量检查 → (可能升级) → 返回

        call_llm_func 签名: async (model_id: str, messages: list, **kwargs) -> str
        """
        # 1. 路由决策
        decision = await self.router.route(
            user_input=user_input,
            user_tier=user_tier,
            has_image=has_image,
            call_llm_func=call_llm_func,
        )
        self.context.log_routing(session_id, decision)

        logger.info(
            f"[Router] intent={decision.intent.value} "
            f"complexity={decision.complexity.value} "
            f"model={decision.selected_model} "
            f"confidence={decision.confidence}"
        )

        # 2. 记录用户输入到上下文
        self.context.add_turn(session_id, "user", user_input)

        # 3. 构建messages
        messages = self.context.build_messages(
            session_id=session_id,
            system_prompt=system_prompt,
            memory_context=memory_context,
            user_profile=user_profile,
        )

        # 4. 调用选中的模型
        response_text = await call_llm_func(decision.selected_model, messages)

        # 5. 质量检查
        quality = self.guard.check_quality(
            response_text=response_text,
            intent=decision.intent,
            complexity=decision.complexity,
        )

        was_escalated = False
        original_model = decision.selected_model

        # 6. 如果质量不过关，尝试升级
        if not quality["pass"]:
            upgrade_model = self.registry.get_upgrade_model(
                decision.selected_model, decision.intent
            )
            if upgrade_model:
                logger.info(
                    f"[Guard] Escalating from {decision.selected_model} → {upgrade_model} "
                    f"reasons: {quality['reasons']}"
                )
                response_text = await call_llm_func(upgrade_model, messages)
                decision.selected_model = upgrade_model
                was_escalated = True

        # 7. 记录助手回答到上下文
        self.context.add_turn(
            session_id, "assistant", response_text,
            model_used=decision.selected_model
        )

        return {
            "response": response_text,
            "model_used": decision.selected_model,
            "original_model": original_model,
            "was_escalated": was_escalated,
            "intent": decision.intent.value,
            "complexity": decision.complexity.value,
            "confidence": decision.confidence,
            "quality_check": quality,
            "session_stats": self.context.get_session_stats(session_id),
        }
