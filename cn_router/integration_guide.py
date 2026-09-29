# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-cbb9a8c4c069eb9eefc215a0b4b17a78870241d53e8d14158412b5081b4ebba9"
# Source-SHA256: "c815d975d8c95b275d48e28b1448fdf2123432f4ff131a55382af46585391bf5"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
ChatAGI-Adu 全中国模型路由 - 集成指南
======================================
展示如何接入 server_session.py + 统一多厂商调用
"""

import asyncio
import httpx
import os
import logging

logger = logging.getLogger("adu_cn_integration")


# ============================================================
# 1. 多厂商统一调用函数
# ============================================================

# 从环境变量读取各厂商API Key
DEEPSEEK_KEY = os.getenv("DEEPSEEK_API_KEY", "")
ALIYUN_KEY = os.getenv("DASHSCOPE_API_KEY", "")    # 阿里云百炼
MOONSHOT_KEY = os.getenv("MOONSHOT_API_KEY", "")    # Kimi
MINIMAX_KEY = os.getenv("MINIMAX_API_KEY", "")
ZHIPU_KEY = os.getenv("ZHIPU_API_KEY", "")         # 智谱
DOUBAO_KEY = os.getenv("ARK_API_KEY", "")           # 火山引擎/豆包
TENCENT_KEY = os.getenv("TENCENT_SECRET_KEY", "")   # 腾讯混元


async def call_cn_model(
    provider: str,
    model_id: str,
    api_base: str,
    messages: list,
    max_tokens: int = 4096,
) -> str:
    """
    统一的中国模型调用函数

    所有中国厂商基本都兼容 OpenAI 格式（除了腾讯混元需要特殊处理）。
    这大大简化了多厂商对接。
    """

    # 大多数中国模型API都兼容OpenAI格式
    openai_compatible = ["deepseek", "aliyun", "moonshot", "minimax", "zhipu", "doubao"]

    if provider in openai_compatible:
        return await _call_openai_compatible(provider, model_id, api_base, messages, max_tokens)
    elif provider == "tencent":
        return await _call_tencent(model_id, messages, max_tokens)
    else:
        raise ValueError(f"Unknown provider: {provider}")


async def _call_openai_compatible(
    provider: str,
    model_id: str,
    api_base: str,
    messages: list,
    max_tokens: int,
) -> str:
    """OpenAI兼容格式调用（大多数中国厂商都支持）"""

    # 获取对应的API Key
    key_map = {
        "deepseek": DEEPSEEK_KEY,
        "aliyun": ALIYUN_KEY,
        "moonshot": MOONSHOT_KEY,
        "minimax": MINIMAX_KEY,
        "zhipu": ZHIPU_KEY,
        "doubao": DOUBAO_KEY,
    }
    api_key = key_map.get(provider, "")

    # 构建请求URL
    # 大多数厂商的endpoint格式: {api_base}/chat/completions
    url = f"{api_base}/chat/completions"

    # 阿里云百炼的格式略有不同
    if provider == "aliyun":
        url = f"{api_base}/chat/completions"

    async with httpx.AsyncClient() as client:
        try:
            resp = await client.post(
                url,
                headers={
                    "Authorization": f"Bearer {api_key}",
                    "Content-Type": "application/json",
                },
                json={
                    "model": model_id,
                    "messages": messages,
                    "max_tokens": max_tokens,
                    "stream": False,
                },
                timeout=60.0,
            )
            resp.raise_for_status()
            data = resp.json()
            return data["choices"][0]["message"]["content"]

        except httpx.HTTPStatusError as e:
            logger.error(f"[{provider}] HTTP {e.response.status_code}: {e.response.text[:200]}")
            raise
        except Exception as e:
            logger.error(f"[{provider}] Call failed: {e}")
            raise


async def _call_tencent(model_id: str, messages: list, max_tokens: int) -> str:
    """
    腾讯混元调用（需要特殊的签名认证）

    注意：腾讯混元-Lite 完全免费，但认证方式与其他厂商不同。
    推荐使用 tencentcloud-sdk-python 包。

    pip install tencentcloud-sdk-python --break-system-packages
    """
    try:
        from tencentcloud.common import credential
        from tencentcloud.hunyuan.v20230901 import hunyuan_client, models

        cred = credential.Credential(
            os.getenv("TENCENT_SECRET_ID", ""),
            os.getenv("TENCENT_SECRET_KEY", ""),
        )
        client = hunyuan_client.HunyuanClient(cred, "")

        req = models.ChatCompletionsRequest()
        req.Model = model_id
        req.Messages = []
        for msg in messages:
            m = models.Message()
            m.Role = msg["role"]
            m.Content = msg["content"]
            req.Messages.append(m)

        resp = client.ChatCompletions(req)
        return resp.Choices[0].Message.Content

    except ImportError:
        logger.warning("tencentcloud SDK not installed, skipping Tencent")
        raise
    except Exception as e:
        logger.error(f"[tencent] Call failed: {e}")
        raise


# ============================================================
# 2. 集成到 server_session.py
# ============================================================

from cn_smart_router import ChinaSmartRouter


# 初始化（app启动时执行一次）
cn_router = ChinaSmartRouter(
    router_mode="ollama",       # 本地Qwen做路由，零成本
    ollama_model="qwen2.5:0.5b",
)


async def handle_message(
    session_id: str,
    user_input: str,
    user_tier: str = "free",
    has_image: bool = False,
):
    """
    主消息处理函数 - 替换你现有的 handle_message

    对用户完全透明：
    - 用户不知道后面切换了哪个模型
    - 上下文始终连贯
    - 质量不好自动升级
    """

    # 你现有的记忆检索（保持不变）
    memory_context = ""  # await your_vector_memory.search(user_input)
    user_profile = ""    # await your_episodic_memory.get_profile(session_id)

    system_prompt = """你是阿杜(Adu)，一个智能AI助手。
你友好、专业、乐于助人。请用用户的语言回复。
不要透露你是哪个具体模型，你就是阿杜。"""

    result = await cn_router.process(
        session_id=session_id,
        user_input=user_input,
        user_tier=user_tier,
        has_image=has_image,
        system_prompt=system_prompt,
        memory_context=memory_context,
        user_profile=user_profile,
        call_llm_func=call_cn_model,
    )

    # 日志（你可以存到数据库做分析）
    logger.info(
        f"[{session_id}] "
        f"{result['intent']}/{result['complexity']} → "
        f"{result['model_display']} "
        f"{'(升级)' if result['was_escalated'] else ''} "
        f"cost≈¥{result['estimated_cost_yuan']:.6f}"
    )

    return result


# ============================================================
# 3. FastAPI 路由
# ============================================================

"""
@app.post("/chat")
async def chat(request: ChatRequest):
    result = await handle_message(
        session_id=request.session_id,
        user_input=request.message,
        user_tier=get_user_tier(request.user_id),  # 从Stripe获取
        has_image=bool(request.images),
    )
    return {
        "reply": result["response"],
        "model": result["model_display"],   # 可选：展示用了哪个模型
        "stats": result["stats"],           # 可选：会话统计
    }
"""


# ============================================================
# 4. 部署清单
# ============================================================

"""
═══════════════════════════════════════════════
  ChatAGI-Adu 全中国模型路由 - 部署清单
═══════════════════════════════════════════════

【第一步：注册各平台API Key】

平台             注册地址                              免费额度
─────────────────────────────────────────────────────────────
DeepSeek        https://platform.deepseek.com        需充值，但极便宜
阿里云百炼       https://bailian.console.aliyun.com   100万tokens/模型 免费
火山引擎方舟     https://console.volcengine.com/ark    200万tokens 免费
腾讯混元         https://cloud.tencent.com/product/hunyuan  混元-Lite完全免费
月之暗面Kimi     https://platform.moonshot.cn          需充值
MiniMax         https://platform.minimaxi.com         新用户免费额度
智谱            https://open.bigmodel.cn              100万tokens 免费
硅基流动         https://siliconflow.cn                多模型聚合，有免费额度

─────────────────────────────────────────────────────────────

💡 建议起步顺序：
1. 先开 阿里云百炼 + DeepSeek（覆盖80%场景）
2. 再加 腾讯混元-Lite（免费闲聊层）
3. 最后按需加 Kimi/GLM-5/MiniMax


【第二步：本地路由模型部署】

方案A - Ollama（推荐，最简单）：
  curl -fsSL https://ollama.ai/install.sh | sh
  ollama pull qwen2.5:0.5b
  # 测试：ollama run qwen2.5:0.5b "你好"
  # 占用 ~300MB 内存，CPU即可运行

方案B - 云服务器无GPU（用Qwen-Flash兜底）：
  router_mode="api_fallback"
  # 阿里云Qwen-Flash 限时免费，零成本


【第三步：环境变量】

export DEEPSEEK_API_KEY="sk-..."
export DASHSCOPE_API_KEY="sk-..."       # 阿里云百炼
export MOONSHOT_API_KEY="sk-..."        # Kimi
export MINIMAX_API_KEY="..."
export ZHIPU_API_KEY="..."
export ARK_API_KEY="..."                # 火山引擎/豆包
export TENCENT_SECRET_ID="..."
export TENCENT_SECRET_KEY="..."


【第四步：Render 部署注意】

- Render 免费tier 无GPU → 路由层用 api_fallback 模式
- Render 有512MB内存限制 → 不要本地加载大模型
- 推荐：路由用 Qwen-Flash（免费API），推理用 DeepSeek V3
- 后续升级 Render Starter → 可以跑 Ollama + Qwen2.5:0.5b


═══════════════════════════════════════════════
  成本估算（日均1000条消息）
═══════════════════════════════════════════════

分布           消息量   模型              单次成本(¥)    日成本(¥)
────────────────────────────────────────────────────────────
简单(60%)      600     混元Lite/Qwen Flash  ¥0           ¥0
中等(30%)      300     DeepSeek V3          ¥0.00032     ¥0.096
复杂(10%)      100     Qwen Max/DeepSeek R1 ¥0.0028      ¥0.28
路由成本        1000    Qwen Flash(免费)      ¥0           ¥0
────────────────────────────────────────────────────────────
日总成本                                                  ≈ ¥0.38
月总成本                                                  ≈ ¥11.4

对比全部用美国模型（Claude Sonnet）：
  1000条 × ¥0.05/条 = ¥50/天 = ¥1500/月

💰 节省：99.2%
═══════════════════════════════════════════════
"""
