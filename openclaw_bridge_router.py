# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-8a3344883625213c274ac918d1a93dd173426e25ec5aded51eca04ebb2429ef5"
# Source-SHA256: "ef277f2c08492e6bac94b1e6e50722b0040da5a01331846a98e7a8251bf8d6e3"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
openclaw_bridge_router.py
==========================
OpenClaw ← server_session.py 反向桥接。

方向反转:
    之前: server_session.py → OpenClaw → Anthropic
    现在: OpenClaw → server_session.py → Anthropic

OpenClaw 配置 chatagi/adu provider 指向本端点;每次 OpenClaw 要推理,
就发 OpenAI 格式请求过来,本端点:
  1. 注入 ChatAGI-阿杜的 system prompt (人设/记忆/路由规则)
  2. 转调 Claude Opus 4.7 (第一版只接 Claude,后续可扩展路由)
  3. 按 OpenAI 格式返回

挂载方式 (在 server_session.py 最后部分 include):
    from openclaw_bridge_router import (
        openclaw_bridge_router,
        attach_anthropic_caller,
        attach_brain_builder,
    )

    # 注入现有的 Anthropic 调用函数
    attach_anthropic_caller(_anthropic_messages_create_nonstream)

    # (可选) 注入自定义 brain builder 替换默认人设
    # attach_brain_builder(my_brain_builder_fn)

    app.include_router(openclaw_bridge_router)

环境变量:
    OPENCLAW_BRIDGE_TOKEN         内部鉴权 token (OpenClaw 配置的 apiKey；必须显式设置，未配置时拒绝请求)
    OPENCLAW_BRIDGE_MODEL         下游 Claude 模型 (默认 claude-opus-4-7)
    OPENCLAW_BRIDGE_MAX_TOKENS    单次最大 tokens (默认 4096)
    OPENCLAW_BRIDGE_LOG_BODY      "1" 时打印完整 messages (调试用)
"""

from __future__ import annotations

import os
import json
import time
import uuid
import logging
from typing import Any, Callable, Dict, List, Optional

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel

log = logging.getLogger("openclaw_bridge")

# ─── 配置 ─────────────────────────────────────────────

BRIDGE_TOKEN = os.getenv("OPENCLAW_BRIDGE_TOKEN", "").strip()
BRIDGE_MODEL = os.getenv("OPENCLAW_BRIDGE_MODEL", "claude-opus-4-7").strip()
BRIDGE_MAX_TOKENS = int(os.getenv("OPENCLAW_BRIDGE_MAX_TOKENS", "4096"))
BRIDGE_LOG_BODY = os.getenv("OPENCLAW_BRIDGE_LOG_BODY", "0") == "1"

# ─── 依赖注入 (主后端启动时注入) ─────────────────────

_anthropic_caller: Optional[Callable[..., Dict[str, Any]]] = None
_brain_builder: Optional[Callable[[List[Dict[str, Any]], Dict[str, Any]], str]] = None


def attach_anthropic_caller(fn: Callable[..., Dict[str, Any]]) -> None:
    """
    注入主后端的 Anthropic 调用函数。
    期望签名: fn(model=str, inp=list, max_tokens=int, temperature=float|None) -> dict
    """
    global _anthropic_caller
    _anthropic_caller = fn
    log.info("[bridge] anthropic caller attached: %s", fn.__name__)


def attach_brain_builder(fn: Callable[[List[Dict[str, Any]], Dict[str, Any]], str]) -> None:
    """
    注入自定义"大脑"拼装函数。
    期望签名: fn(messages: list, meta: dict) -> system_prompt: str
    """
    global _brain_builder
    _brain_builder = fn
    log.info("[bridge] brain builder attached: %s", fn.__name__)


# ─── 默认大脑 (阿杜人设,可被 attach_brain_builder 替换) ─

DEFAULT_ADU_BRAIN = """你是阿杜 (Adu),当前用户的生产力助手,ChatAGI 项目的执行层 agent。

身份:
- 由 Claude Opus 4.7 驱动,运行在 ChatAGI 后端,通过 OpenClaw 拿到本地工具能力
- 主用户: 当前已授权的用户；不预设其姓名、所在地或个人经历

语言规则:
- 用户用什么语言,你就用什么语言回复。不默认中文。
- 技术术语保留英文

执行规则:
- 收到任务直接执行,不要先问"你是谁"或"上次在做什么"
- 不追问历史记忆,每次 API 请求当作独立任务处理
- 破坏性操作 (rm/delete/drop) 必须先列方案等确认
- 非破坏性操作 (read/list/grep/ls) 直接做
- 使用 OpenClaw 提供的工具时直接调用,不要说"我将使用..."这类填充语

回复风格:
- 直接给答案,不加"好的"/"当然"/"我很乐意"等客套
- 列方案时用简洁的 bullet 或表格
- 代码变动优先用工具写入文件,不要把全量代码内联粘到回复里

红线:
- 不泄露 API key、token 等敏感信息
- 删除操作用 trash 而不是 rm
- 外部动作 (email/tweet/public post) 必须确认"""


def _build_system_prompt(
    messages: List[Dict[str, Any]],
    meta: Dict[str, Any],
) -> str:
    """拼装最终的 system prompt。可通过 attach_brain_builder 替换。"""
    if _brain_builder is not None:
        try:
            return _brain_builder(messages, meta)
        except Exception as e:
            log.warning("[bridge] custom brain_builder raised, falling back: %s", e)

    # 默认:用 DEFAULT_ADU_BRAIN + 附加 OpenClaw 工具提示
    tools_hint = ""
    if meta.get("has_tools"):
        tools_hint = ("\n\n你当前有 OpenClaw 本地工具可用 (file/shell/browser 等),"
                      "模型层会自动处理工具调用,你只需要在需要时 tool_call,不需要自己执行。")
    return DEFAULT_ADU_BRAIN + tools_hint


# ─── 格式转换: OpenAI <-> Claude ────────────────────

def _openai_messages_to_claude_inp(
    messages: List[Dict[str, Any]],
) -> List[Dict[str, Any]]:
    """
    把 OpenAI chat.completions 格式的 messages 转成主后端
    _anthropic_messages_create_nonstream() 期望的 `inp` 格式。

    主后端的 `inp` 是 OpenAI Responses API 风格:
        [{"role":"system", "content":[{"type":"input_text", "text":"..."}]},
         {"role":"user",   "content":[{"type":"input_text", "text":"..."}]}]

    内部 _responses_input_to_anthropic() 会处理成 Claude 的格式。
    """
    inp: List[Dict[str, Any]] = []
    for m in messages:
        role = m.get("role") or "user"
        content = m.get("content")
        if isinstance(content, str):
            parts = [{"type": "input_text", "text": content}]
        elif isinstance(content, list):
            parts = []
            for c in content:
                if isinstance(c, dict):
                    if c.get("type") == "text":
                        parts.append({"type": "input_text", "text": c.get("text", "")})
                    elif c.get("type") == "image_url":
                        # OpenAI 图像格式 → 留着 input_text 占位,图像暂不透传 (第一版)
                        parts.append({"type": "input_text",
                                      "text": "[image omitted in bridge v1]"})
                    else:
                        # 其他 content block 类型,尽量提文本
                        t = c.get("text")
                        if t:
                            parts.append({"type": "input_text", "text": str(t)})
                elif isinstance(c, str):
                    parts.append({"type": "input_text", "text": c})
        else:
            parts = [{"type": "input_text", "text": str(content or "")}]

        # Claude 不支持 role=tool, 吃掉 tool results 转成 user 消息
        if role == "tool":
            role = "user"
            tool_call_id = m.get("tool_call_id", "")
            parts = [{"type": "input_text",
                      "text": f"[tool result for {tool_call_id}]\n" + (
                          parts[0].get("text", "") if parts else ""
                      )}]

        inp.append({"role": role, "content": parts})
    return inp


def _extract_text_from_claude_resp(resp_like: Dict[str, Any]) -> str:
    """
    从主后端返回的 Responses-like dict 里抽出文本。
    格式: {"output":[{"type":"message","content":[{"type":"output_text","text":"..."}]}]}
    """
    try:
        for item in resp_like.get("output") or []:
            if item.get("type") == "message":
                for c in item.get("content") or []:
                    if c.get("type") == "output_text":
                        return c.get("text") or ""
    except Exception:
        pass
    return ""


def _to_openai_chat_completion(
    text: str,
    *,
    model: str,
    finish_reason: str = "stop",
) -> Dict[str, Any]:
    """包成标准 OpenAI chat.completions 响应格式给 OpenClaw。"""
    return {
        "id": f"chatcmpl-{uuid.uuid4().hex[:24]}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": model,
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": text},
                "finish_reason": finish_reason,
            }
        ],
        "usage": {
            # 精确 token 数主后端目前没统计,先占位
            "prompt_tokens": 0,
            "completion_tokens": 0,
            "total_tokens": 0,
        },
    }


# ─── 鉴权 ─────────────────────────────────────────────

def _check_auth(request: Request) -> Optional[JSONResponse]:
    if not BRIDGE_TOKEN:
        return JSONResponse(
            {"error": {"message": "bridge authentication is not configured", "type": "unavailable"}},
            status_code=503,
        )
    auth = request.headers.get("authorization") or ""
    if not auth.lower().startswith("bearer "):
        return JSONResponse(
            {"error": {"message": "missing bearer token", "type": "unauthorized"}},
            status_code=401,
        )
    parts = auth.split(None, 1)
    token = parts[1].strip() if len(parts) == 2 else ""
    if token != BRIDGE_TOKEN:
        return JSONResponse(
            {"error": {"message": "invalid token", "type": "unauthorized"}},
            status_code=401,
        )
    return None


# ─── 路由 ─────────────────────────────────────────────

openclaw_bridge_router = APIRouter(tags=["openclaw-bridge"])


@openclaw_bridge_router.get("/v1/models")
async def list_models(request: Request):
    """OpenClaw 启动/热重载时会 probe 这个路径验证 provider 可用。"""
    err = _check_auth(request)
    if err:
        return err
    return {
        "object": "list",
        "data": [
            {
                "id": "adu",
                "object": "model",
                "created": int(time.time()),
                "owned_by": "chatagi",
            }
        ],
    }


@openclaw_bridge_router.post("/v1/chat/completions")
async def chat_completions(request: Request):
    """
    OpenAI 兼容端点。OpenClaw 把这里当成一个 provider 调用。
    """
    auth_err = _check_auth(request)
    if auth_err:
        return auth_err

    if _anthropic_caller is None:
        return JSONResponse(
            {
                "error": {
                    "message": "bridge not wired: call attach_anthropic_caller() at startup",
                    "type": "configuration_error",
                }
            },
            status_code=503,
        )

    try:
        body = await request.json()
    except Exception as e:
        return JSONResponse(
            {"error": {"message": f"invalid json: {e}", "type": "bad_request"}},
            status_code=400,
        )

    messages = body.get("messages") or []
    if not isinstance(messages, list) or not messages:
        return JSONResponse(
            {"error": {"message": "messages required", "type": "bad_request"}},
            status_code=400,
        )

    requested_model = (body.get("model") or "adu").strip()
    max_tokens = int(body.get("max_tokens") or BRIDGE_MAX_TOKENS)
    temperature = body.get("temperature")
    tools = body.get("tools") or []
    stream = bool(body.get("stream"))

    if BRIDGE_LOG_BODY:
        log.info("[bridge] req model=%s stream=%s n_msgs=%d n_tools=%d",
                 requested_model, stream, len(messages), len(tools))
        log.info("[bridge] messages=%s", json.dumps(messages, ensure_ascii=False)[:2000])

    # 1. 注入阿杜大脑作为 system message
    #    如果 OpenClaw 自己也传了 system (从 workspace 来),追加在后面
    meta = {"has_tools": bool(tools), "n_tools": len(tools)}
    adu_system = _build_system_prompt(messages, meta)

    existing_systems = [m for m in messages if m.get("role") == "system"]
    non_systems = [m for m in messages if m.get("role") != "system"]

    injected_messages: List[Dict[str, Any]] = [
        {"role": "system", "content": adu_system}
    ]
    # 保留 OpenClaw 自己传的 system (但在阿杜大脑之后,优先级低)
    for sys_msg in existing_systems:
        c = sys_msg.get("content")
        if isinstance(c, str) and c.strip():
            injected_messages.append({"role": "system", "content": c})
    injected_messages.extend(non_systems)

    # 2. 转成主后端期望的 inp 格式
    try:
        inp = _openai_messages_to_claude_inp(injected_messages)
    except Exception as e:
        log.exception("[bridge] message conversion failed")
        return JSONResponse(
            {"error": {"message": f"message conversion: {e}",
                       "type": "internal_error"}},
            status_code=500,
        )

    # 3. 调下游 Claude
    downstream_model = BRIDGE_MODEL
    t0 = time.time()
    try:
        resp_like = _anthropic_caller(
            model=downstream_model,
            inp=inp,
            max_tokens=max_tokens,
            temperature=float(temperature) if temperature is not None else None,
        )
    except Exception as e:
        log.exception("[bridge] downstream anthropic call failed")
        return JSONResponse(
            {"error": {"message": f"downstream: {e}", "type": "upstream_error"}},
            status_code=502,
        )

    elapsed = round(time.time() - t0, 3)
    text = _extract_text_from_claude_resp(resp_like)
    finish_reason = (
        "length"
        if (resp_like.get("status") == "incomplete"
            or (resp_like.get("incomplete_details") or {}).get("reason") == "max_output_tokens")
        else "stop"
    )

    log.info("[bridge] ok model=%s len=%d elapsed=%ss finish=%s",
             downstream_model, len(text), elapsed, finish_reason)

    # 4. OpenAI 兼容响应
    result = _to_openai_chat_completion(text, model=requested_model, finish_reason=finish_reason)

    # 第一版不支持真流式;如果 OpenClaw 要 stream,我们用 fake-stream
    # (一次性把整段文本当成单个 delta 发出去,OpenClaw 仍能 parse)
    if stream:
        from fastapi.responses import StreamingResponse

        def _fake_stream():
            chunk_id = result["id"]
            created = result["created"]
            first = {
                "id": chunk_id, "object": "chat.completion.chunk",
                "created": created, "model": requested_model,
                "choices": [{"index": 0,
                             "delta": {"role": "assistant", "content": text},
                             "finish_reason": None}],
            }
            yield f"data: {json.dumps(first, ensure_ascii=False)}\n\n"
            final = {
                "id": chunk_id, "object": "chat.completion.chunk",
                "created": created, "model": requested_model,
                "choices": [{"index": 0, "delta": {}, "finish_reason": finish_reason}],
            }
            yield f"data: {json.dumps(final, ensure_ascii=False)}\n\n"
            yield "data: [DONE]\n\n"

        return StreamingResponse(_fake_stream(), media_type="text/event-stream")

    return result
