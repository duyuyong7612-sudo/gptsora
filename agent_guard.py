# GPTsora / gpt-solara-backend — default-deny route guard (security patch, 2026-09-29)
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
"""
默认拒绝（白名单）路由守卫。HTTP 与 WebSocket 都生效。

放行条件（满足其一即可）：
  1. 路径在公开白名单内（聊天、语音、会话、账号、计费、静态页等）
  2. 请求头 X-Agent-Token 与环境变量 AGENT_API_TOKEN 一致（常量时间比较）
  3. 来自 127.0.0.1 / ::1，且没有 Origin 头、没有任何代理转发头（本机脚本）
     —— 可用 ADU_AGENT_TRUST_LOOPBACK=0 关闭
其余一律 403（WebSocket 以 1008 关闭）。

不在白名单、因此需要 token 的典型路径：
  /agent/*  /api/*（除 /api/chat、/api/adu/chat、/api/realtime/* 外，含 /api/adu/codex、
  /api/adu/automation、/api/adu/self、/api/brain）
  /computer-agent/*  /control*  /controller/*  /tasks*  /home/*
  /screen/*  /ws/screen/*  /ws/control/*  /debug/*  /qwen_omni_local/*
  以及以后新增、未显式加入白名单的任何路由。

注意：白名单里的语音/聊天入口本身不再带电脑控制能力——server_session.py 里的
computer / openclaw_* / adu_agent_* / adu_mac_send 工具默认关闭，需要部署者设置
ADU_ALLOW_COMPUTER_TOOLS=1 才会启用。

需要临时放行更多公开路径时，设置环境变量（逗号分隔）：
  ADU_PUBLIC_EXACT=/foo,/bar
  ADU_PUBLIC_PREFIXES=/baz/,/qux/
"""
from __future__ import annotations

import hmac
import json
import os
import re

PUBLIC_EXACT = {
    "/", "/health", "/favicon.ico",
    "/chat", "/api/chat", "/api/adu/chat",
    "/conversations", "/session", "/web_search",
    "/tts", "/tts_prepare", "/tts_stream.mp3",
    "/adu_voice", "/rt/intent", "/solara/photo",
    "/tools/search_memory",
    "/chatagi-adu", "/realtime-native-poc",
}

PUBLIC_PREFIXES = (
    "/chat/", "/conversations/", "/conversation/", "/memory/",
    "/tts/", "/adu_voice/", "/realtime/", "/rtc/",
    "/api/realtime/", "/livekit/",
    "/ws/realtime/", "/ws/v2/",
    "/video/", "/vision/", "/file/", "/upload/", "/media/",
    "/v1/", "/v2/", "/auth/", "/billing/",
    "/chatagi-adu/", "/studio/", "/static/",
)

_LOOPBACK = {"127.0.0.1", "::1"}
_FORWARD_HEADERS = ("x-forwarded-for", "x-real-ip", "forwarded", "x-forwarded-host",
                    "cf-connecting-ip", "true-client-ip")


def _env_list(name: str) -> list:
    return [s.strip() for s in (os.getenv(name) or "").split(",") if s.strip()]


def _normalize(path: str) -> str:
    path = re.sub(r"/{2,}", "/", path or "/")
    if len(path) > 1:
        path = path.rstrip("/") or "/"
    return path


def is_public(path: str) -> bool:
    raw = path or "/"
    # 含 ".." / "." 段、反斜杠、空字节的路径一律不算公开（防路径穿越绕过前缀白名单）
    if "\\" in raw or "\x00" in raw or any(seg in ("..", ".") for seg in raw.split("/")):
        return False
    p = _normalize(raw)
    if p in PUBLIC_EXACT or p in _env_list("ADU_PUBLIC_EXACT"):
        return True
    probe = p + "/"
    for prefix in PUBLIC_PREFIXES + tuple(_env_list("ADU_PUBLIC_PREFIXES")):
        if probe.startswith(prefix if prefix.endswith("/") else prefix + "/"):
            return True
    return False


class AgentGuardMiddleware:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope.get("type") not in ("http", "websocket"):
            return await self.app(scope, receive, send)
        if is_public(scope.get("path", "")):
            return await self.app(scope, receive, send)

        headers = {k.decode("latin-1").lower(): v.decode("latin-1") for k, v in scope.get("headers") or []}

        expected = (os.getenv("AGENT_API_TOKEN") or "").strip()
        given = (headers.get("x-agent-token") or "").strip()
        if expected and given and hmac.compare_digest(given.encode(), expected.encode()):
            return await self.app(scope, receive, send)

        trust_loopback = os.getenv("ADU_AGENT_TRUST_LOOPBACK", "1").strip().lower() not in ("0", "false", "no")
        client = (scope.get("client") or ("", 0))[0]
        if (trust_loopback and client in _LOOPBACK and "origin" not in headers
                and not any(h in headers for h in _FORWARD_HEADERS)):
            return await self.app(scope, receive, send)

        if scope["type"] == "websocket":
            await send({"type": "websocket.close", "code": 1008})
            return
        body = json.dumps({"ok": False, "error": "forbidden",
                           "detail": "This route requires X-Agent-Token."}).encode()
        await send({"type": "http.response.start", "status": 403,
                    "headers": [(b"content-type", b"application/json"),
                                (b"content-length", str(len(body)).encode())]})
        await send({"type": "http.response.body", "body": body})


# 兼容旧名称
AgentGuard = AgentGuardMiddleware
