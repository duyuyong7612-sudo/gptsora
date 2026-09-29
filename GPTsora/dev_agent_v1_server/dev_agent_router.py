# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-3b30d33290108bc8c86e2d27e4bd052cf2d1a6d28c875c6f104050858af1f377"
# Source-SHA256: "36dbea225136b9efe0e01e5909a7106125ee7e05bc7269c0e309e54b91fa31e9"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
Dev Agent V1 · 后端转发层
==============================================================

部署到 backend 仓库（与 server_session.py 同目录）：

    1. 复制本文件
    2. 在 server_session.py 顶部加：
           from dev_agent_router import router as dev_agent_router
           app.include_router(dev_agent_router)
    3. 可选环境变量：
           LOCAL_AGENT_BASE     默认 http://127.0.0.1:4317
           DEV_AGENT_TIMEOUT_S  单次请求秒数上限，默认 90

依赖：httpx（如未装：pip install httpx）

接口：
    GET  /api/brain/dev_agent/health
    POST /api/brain/dev_agent/ask   { prompt, project_root?, timeout_ms? }

把请求透传给本机 local-agent，自己不解析业务结果。
"""

from __future__ import annotations

import os
import httpx
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

router = APIRouter(prefix="/api/brain/dev_agent", tags=["dev_agent"])

LOCAL_AGENT_BASE = os.getenv("LOCAL_AGENT_BASE", "http://127.0.0.1:4317").rstrip("/")
DEV_AGENT_TIMEOUT_S = float(os.getenv("DEV_AGENT_TIMEOUT_S", "90"))


class AskRequest(BaseModel):
    prompt: str = Field(..., min_length=1, max_length=8000)
    project_root: str | None = None
    timeout_ms: int = 60_000


@router.get("/health")
async def health() -> dict:
    out: dict = {
        "ok": True,
        "local_agent_online": False,
        "claude_code_installed": False,
        "claude_code_version": None,
        "allowed_roots": [],
    }
    try:
        async with httpx.AsyncClient(timeout=4.0) as c:
            r = await c.get(f"{LOCAL_AGENT_BASE}/dev_agent/health")
            if r.status_code == 200:
                data = r.json()
                out["local_agent_online"] = True
                out["claude_code_installed"] = bool(data.get("claude_code_installed"))
                out["claude_code_version"] = data.get("claude_code_version")
                out["allowed_roots"] = data.get("allowed_roots", [])
    except Exception:
        # local-agent 不可达不视为后端故障；前端会看到 local_agent_online=false
        pass
    return out


@router.post("/ask")
async def ask(req: AskRequest) -> dict:
    body = req.model_dump(exclude_none=True)
    body["read_only"] = True  # V1 硬约束
    timeout_ms = max(5_000, min(body.get("timeout_ms", 60_000),
                                int(DEV_AGENT_TIMEOUT_S * 1000)))
    body["timeout_ms"] = timeout_ms

    try:
        async with httpx.AsyncClient(timeout=DEV_AGENT_TIMEOUT_S + 5) as c:
            r = await c.post(f"{LOCAL_AGENT_BASE}/dev_agent/ask", json=body)
    except httpx.RequestError as e:
        raise HTTPException(status_code=502, detail=f"local-agent 不可达: {e}")

    if r.status_code != 200:
        raise HTTPException(status_code=r.status_code, detail=r.text)
    return r.json()
