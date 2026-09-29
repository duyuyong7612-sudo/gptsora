# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-e7b7f3852d417b9085c380782068174dd956f300dedec73d35a0b70288dc7d8d"
# Source-SHA256: "b2d49cbf4abdc4c8765321aabb7269aa701186cd588202f0230d10624ffb16a9"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
ChatAGI-Adu 智能路由 - 集成示例
================================
展示如何将 SmartRouter 接入你现有的 server_session.py

这个文件不是直接运行的，是给你看怎么集成的参考代码。
"""

import asyncio
import httpx
import logging

from semantic_router import SmartRouter

logger = logging.getLogger("adu_integration")


# ============================================================
# 1. 统一的 LLM 调用函数
#    你现有的 server_session.py 里应该已经有类似的，
#    把它封装成这个签名即可：async (model_id, messages, **kwargs) -> str
# ============================================================

async def call_llm(model_id: str, messages: list, max_tokens: int = 4096) -> str:
    """
    统一LLM调用接口 - 根据model_id路由到不同provider

    你需要根据你 server_session.py 中的实际实现来调整。
    关键是保持签名一致：接收 model_id + messages，返回 str。
    """

    # --- OpenAI / GPT 系列 ---
    if model_id.startswith("gpt-"):
        async with httpx.AsyncClient() as client:
            resp = await client.post(
                "https://api.openai.com/v1/chat/completions",
                headers={
                    "Authorization": f"Bearer {OPENAI_API_KEY}",
                    "Content-Type": "application/json",
                },
                json={
                    "model": model_id,
                    "messages": messages,
                    "max_tokens": max_tokens,
                    "user": "chatagi_adu",  # 你之前提到要加的 user 字段
                },
                timeout=60.0,
            )
            data = resp.json()
            return data["choices"][0]["message"]["content"]

    # --- Anthropic / Claude 系列 ---
    elif model_id.startswith("claude-"):
        # 提取system message
        system_msg = ""
        user_messages = []
        for msg in messages:
            if msg["role"] == "system":
                system_msg = msg["content"]
            else:
                user_messages.append(msg)

        async with httpx.AsyncClient() as client:
            resp = await client.post(
                "https://api.anthropic.com/v1/messages",
                headers={
                    "x-api-key": ANTHROPIC_API_KEY,
                    "anthropic-version": "2023-06-01",
                    "Content-Type": "application/json",
                },
                json={
                    "model": model_id,
                    "system": system_msg,
                    "messages": user_messages,
                    "max_tokens": max_tokens,
                },
                timeout=60.0,
            )
            data = resp.json()
            return data["content"][0]["text"]

    # --- DeepSeek ---
    elif model_id.startswith("deepseek"):
        async with httpx.AsyncClient() as client:
            resp = await client.post(
                "https://api.deepseek.com/chat/completions",
                headers={
                    "Authorization": f"Bearer {DEEPSEEK_API_KEY}",
                    "Content-Type": "application/json",
                },
                json={
                    "model": model_id,
                    "messages": messages,
                    "max_tokens": max_tokens,
                },
                timeout=60.0,
            )
            data = resp.json()
            return data["choices"][0]["message"]["content"]

    else:
        raise ValueError(f"Unknown model: {model_id}")


# ============================================================
# 2. 在 server_session.py 中集成 SmartRouter
# ============================================================

# 初始化（在 app 启动时执行一次）
smart_router = SmartRouter(
    mode="api",              # 起步用API模式，后续切换到 "local"
    router_model="gpt-4o-mini",  # 路由判断用最便宜的模型
)


async def handle_message_with_router(
    session_id: str,
    user_input: str,
    user_tier: str = "free",
    has_image: bool = False,
):
    """
    替换你现有的 handle_message 函数

    主要改动：
    1. 不再硬编码用哪个模型
    2. SmartRouter 自动选择最优模型
    3. 质量不过关自动升级
    4. 上下文跨模型同步
    """

    # --- 你现有的记忆检索逻辑（保持不变）---
    # memory_context = await your_vector_memory.search(user_input, top_k=5)
    # user_profile = await your_episodic_memory.get_profile(session_id)
    memory_context = ""   # placeholder
    user_profile = ""     # placeholder

    # --- 你现有的 system prompt（保持不变）---
    system_prompt = """你是阿杜(Adu)，一个智能AI助手，由ChatAGI团队开发。
你友好、专业、乐于助人。请用用户的语言回复。"""

    # --- 调用智能路由 ---
    result = await smart_router.process(
        session_id=session_id,
        user_input=user_input,
        user_tier=user_tier,
        has_image=has_image,
        system_prompt=system_prompt,
        memory_context=memory_context,
        user_profile=user_profile,
        call_llm_func=call_llm,
    )

    # --- 日志 & 计费 ---
    logger.info(
        f"[Session {session_id}] "
        f"intent={result['intent']} "
        f"model={result['model_used']} "
        f"escalated={result['was_escalated']}"
    )

    # --- 异步写入记忆（你现有的非阻塞写入逻辑）---
    # asyncio.create_task(your_memory_system.update(
    #     session_id, user_input, result["response"], result["model_used"]
    # ))

    return result


# ============================================================
# 3. FastAPI 路由示例
# ============================================================

"""
# 在你的 FastAPI app 中：

@app.post("/chat")
async def chat_endpoint(request: ChatRequest):
    result = await handle_message_with_router(
        session_id=request.session_id,
        user_input=request.message,
        user_tier=request.user_tier,  # 从Stripe/JWT获取
        has_image=bool(request.images),
    )

    return {
        "reply": result["response"],
        "model": result["model_used"],          # 可选：告诉前端用了哪个模型
        "intent": result["intent"],              # 可选：用于前端展示/调试
        "escalated": result["was_escalated"],    # 可选：是否升级过
    }
"""


# ============================================================
# 4. 本地模式部署指南（进阶）
# ============================================================

"""
当你想从 API 路由模式切换到本地模型路由（省掉路由环节的API费用）：

1. 安装依赖：
   pip install sentence-transformers torch --break-system-packages

2. 修改初始化：
   smart_router = SmartRouter(mode="local")

3. 首次启动会下载 all-MiniLM-L6-v2（~80MB），之后走缓存。

4. Render 免费 tier 注意事项：
   - 内存限制 512MB，加载模型后剩余约 300MB
   - 如果内存不够，考虑升级到 Starter Plan 或只用 API 模式

5. 更进阶：本地跑 Qwen2.5-0.5B 做路由
   - 需要 ~1GB 内存
   - 精度更高，可以输出更细粒度的分类
   - 需要 Render Starter Plan 以上
"""


# ============================================================
# 5. 成本估算
# ============================================================

"""
假设每天 1000 条消息，路由分布：

简单任务 60% (600条) → DeepSeek V3
  输入: 600 × 500 tokens × $0.00014/1k = $0.042
  输出: 600 × 300 tokens × $0.00028/1k = $0.050

中等任务 30% (300条) → Claude Sonnet
  输入: 300 × 800 tokens × $0.003/1k = $0.720
  输出: 300 × 600 tokens × $0.015/1k = $2.700

复杂任务 10% (100条) → Claude Opus / GPT-4o
  输入: 100 × 1000 tokens × $0.015/1k = $1.500
  输出: 100 × 800 tokens × $0.075/1k = $6.000

路由成本（API模式）：
  1000 × 200 tokens × $0.00015/1k = $0.030

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
日总成本: ~$11.04
vs 全部用 Claude Opus: ~$90/天
节省: 约 88%
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

本地路由模式可再省 $0.03/天（基本可忽略）。
主要省钱在于把 60% 简单任务用 DeepSeek 处理。
"""
