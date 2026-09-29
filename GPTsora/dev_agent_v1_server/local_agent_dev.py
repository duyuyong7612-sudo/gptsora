# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-1f2d3013fcebc84924a54be55b057b1b3dc003d9cac644d419877a3e06935b2b"
# Source-SHA256: "b6bdff7b38103cdd688455d181a5e662f262cd107868b1b75598f728529ed982"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
Dev Agent V1 · local-agent 端点
==============================================================

部署到 Mac 本机的 local-agent 进程（监听 :4317，与 /click /screenshot 同进程）：

    1. 复制本文件到 local-agent 仓库
    2. 在主 app 里加：
           from local_agent_dev import router as dev_router
           app.include_router(dev_router)
    3. 可选环境变量：
           DEV_AGENT_ALLOWED_ROOTS   逗号分隔，默认 ~/Desktop/GPTsora
           DEV_AGENT_CLAUDE_BIN      默认 claude （需在 PATH 内）

依赖：fastapi、pydantic
前置：Mac 上已 `npm install -g @anthropic-ai/claude-code`，
      并已 `claude` 一次完成登录（OAuth 或 API key）。

接口：
    GET  /dev_agent/health
    POST /dev_agent/ask   { prompt, project_root?, timeout_ms?, read_only=true }

安全：
    - project_root 必须在 ALLOWED_ROOTS 之下；
    - --permission-mode plan 双保险禁写；
    - --allowed-tools 白名单 + --disallowed-tools 黑名单；
    - 单次硬超时 ≤120s，子进程到期 SIGKILL。
"""

from __future__ import annotations

import asyncio
import json
import os
import subprocess
from pathlib import Path

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

router = APIRouter(prefix="/dev_agent", tags=["dev_agent"])

CLAUDE_BIN = os.getenv("DEV_AGENT_CLAUDE_BIN", "claude")

_DEFAULT_ROOTS = [str(Path.home() / "Desktop" / "GPTsora")]
ALLOWED_ROOTS = [
    str(Path(p).expanduser().resolve())
    for p in os.getenv("DEV_AGENT_ALLOWED_ROOTS", ",".join(_DEFAULT_ROOTS)).split(",")
    if p.strip()
]

ALLOWED_TOOLS = (
    "Read,Grep,Glob,"
    "Bash(ls:*),Bash(cat:*),Bash(wc:*),Bash(find:*),"
    "Bash(git log:*),Bash(git status),Bash(git diff:*)"
)
DISALLOWED_TOOLS = (
    "Edit,Write,NotebookEdit,WebFetch,WebSearch,"
    "Bash(rm:*),Bash(mv:*),Bash(cp:*),Bash(chmod:*),Bash(chown:*),"
    "Bash(curl:*),Bash(wget:*),Bash(sudo:*),Bash(open:*),Bash(kill:*)"
)


class AskRequest(BaseModel):
    prompt: str = Field(..., min_length=1, max_length=8000)
    project_root: str | None = None
    timeout_ms: int = 60_000
    read_only: bool = True


def _resolve_root(req_root: str | None) -> str:
    if not ALLOWED_ROOTS:
        raise HTTPException(status_code=500, detail="ALLOWED_ROOTS 为空")
    candidate = (str(Path(req_root).expanduser().resolve())
                 if req_root else ALLOWED_ROOTS[0])
    for allowed in ALLOWED_ROOTS:
        if candidate == allowed or candidate.startswith(allowed + os.sep):
            return candidate
    raise HTTPException(status_code=400,
                        detail=f"project_root 不在 allowed_roots 内: {candidate}")


def _claude_version() -> tuple[bool, str | None]:
    try:
        out = subprocess.run([CLAUDE_BIN, "--version"],
                             capture_output=True, text=True, timeout=4)
        if out.returncode == 0:
            return True, out.stdout.strip()
    except Exception:
        pass
    return False, None


@router.get("/health")
async def health() -> dict:
    installed, version = _claude_version()
    return {
        "ok": True,
        "claude_code_installed": installed,
        "claude_code_version": version,
        "claude_code_path": CLAUDE_BIN,
        "allowed_roots": ALLOWED_ROOTS,
    }


@router.post("/ask")
async def ask(req: AskRequest) -> dict:
    if not req.read_only:
        raise HTTPException(status_code=400, detail="V1 仅支持只读")

    cwd = _resolve_root(req.project_root)
    installed, _ = _claude_version()
    if not installed:
        raise HTTPException(status_code=500,
                            detail=f"Claude Code CLI 不可用: {CLAUDE_BIN}")

    timeout_s = max(5.0, min(req.timeout_ms / 1000, 120.0))

    cmd = [
        CLAUDE_BIN,
        "-p", req.prompt,
        "--output-format", "json",
        "--permission-mode", "plan",
        "--allowed-tools", ALLOWED_TOOLS,
        "--disallowed-tools", DISALLOWED_TOOLS,
        "--max-turns", "8",
    ]

    loop = asyncio.get_event_loop()
    started = loop.time()
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            cwd=cwd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
    except FileNotFoundError:
        raise HTTPException(status_code=500,
                            detail=f"Claude Code 未找到: {CLAUDE_BIN}")

    try:
        stdout_b, stderr_b = await asyncio.wait_for(
            proc.communicate(), timeout=timeout_s
        )
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        raise HTTPException(status_code=504,
                            detail=f"Claude Code 超时 ({timeout_s:.0f}s)")

    duration_ms = int((loop.time() - started) * 1000)
    stdout = stdout_b.decode("utf-8", errors="replace")
    stderr = stderr_b.decode("utf-8", errors="replace")

    text = ""
    tool_calls: list[str] = []
    parse_err: str | None = None
    try:
        last = stdout.strip().splitlines()[-1] if stdout.strip() else ""
        obj = json.loads(last)
        text = (obj.get("result")
                or obj.get("text")
                or obj.get("content")
                or "")
        uses = obj.get("tool_uses") or obj.get("tools") or []
        if isinstance(uses, list):
            tool_calls = [
                str(u.get("name") if isinstance(u, dict) else u)
                for u in uses
                if u is not None
            ]
    except Exception as e:
        parse_err = f"parse: {e}"
        text = stdout.strip()

    ok = (proc.returncode == 0) and bool(text)
    err = None
    if proc.returncode != 0:
        err = (stderr.strip() or f"exit={proc.returncode}")
    elif parse_err and not text:
        err = parse_err

    return {
        "ok": ok,
        "text": text,
        "tool_calls": tool_calls,
        "duration_ms": duration_ms,
        "exit_code": proc.returncode,
        "error": err,
    }
