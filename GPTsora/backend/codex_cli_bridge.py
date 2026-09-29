# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-d3102b72ad2d59d4c273fe2c23754b4278ec74f985f88aa0db3531e64bb99c01"
# Source-SHA256: "6bba66470edacdcfaa7a1cfce99f21260a6f64d9e1a8473e14d07a3e88d533f8"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""Bridge Adu voice tasks to the Codex CLI non-interactive runner.

This is the "voice -> code CLI" lane: Adu owns wake word, realtime speech,
turn-taking, and spoken feedback; Codex owns repository/file/code workflow work.
Computer-use remains on the Hermes CUA lane because that stack has the desktop
perception and safety state machine.
"""

from __future__ import annotations

import asyncio
import os
import shutil
import subprocess
import tempfile
import time
import uuid
from pathlib import Path
from typing import Any


CODEX_BIN = os.environ.get("ADU_CODEX_BIN", "codex")
CODEX_MODEL = os.environ.get("ADU_CODEX_MODEL", "").strip()
CODEX_WORKDIR = Path(
    os.environ.get("ADU_CODEX_WORKDIR", "~/Desktop/阿杜电脑控制系统")
).expanduser()
CODEX_EXTRA_DIRS = [
    s.strip() for s in os.environ.get(
        "ADU_CODEX_EXTRA_DIRS",
        "~/Desktop/hermes-agent",
    ).split(",") if s.strip()
]
CODEX_TIMEOUT_S = int(os.environ.get("ADU_CODEX_TIMEOUT_S", "900"))
CODEX_MAX_RESPONSE_CHARS = int(os.environ.get("ADU_CODEX_MAX_RESPONSE_CHARS", "6000"))


def _codex_path() -> str:
    return shutil.which(CODEX_BIN) or CODEX_BIN


def status() -> dict[str, Any]:
    path = _codex_path()
    ok = bool(shutil.which(CODEX_BIN) or Path(path).exists())
    data: dict[str, Any] = {
        "ok": ok,
        "backend": "codex_cli",
        "bin": path,
        "model": CODEX_MODEL or "default",
        "workdir": str(CODEX_WORKDIR),
        "extra_dirs": CODEX_EXTRA_DIRS,
        "timeout_s": CODEX_TIMEOUT_S,
    }
    if not ok:
        data["error"] = f"Codex CLI not found: {CODEX_BIN}"
    return data


def _run_codex_sync(prompt: str, *, context: str = "") -> dict[str, Any]:
    task = str(prompt or "").strip()
    if not task:
        return {"ok": False, "response": "", "error": "empty prompt", "backend": "codex_cli"}
    st = status()
    if not st.get("ok"):
        return {"ok": False, "response": "", "error": st.get("error"), "backend": "codex_cli"}

    CODEX_WORKDIR.mkdir(parents=True, exist_ok=True)
    session_id = f"adu_codex_{int(time.time() * 1000)}_{uuid.uuid4().hex[:6]}"
    fd, last_path = tempfile.mkstemp(prefix=f"{session_id}_", suffix=".txt")
    os.close(fd)
    full_prompt = task if not context else f"{context.strip()}\n\n【用户任务】{task}"
    command = [
        st["bin"],
        "exec",
        "--skip-git-repo-check",
        "--sandbox",
        os.environ.get("ADU_CODEX_SANDBOX", "workspace-write"),
        "--ask-for-approval",
        os.environ.get("ADU_CODEX_APPROVAL", "never"),
        "-C",
        str(CODEX_WORKDIR),
        "-o",
        last_path,
    ]
    for extra in CODEX_EXTRA_DIRS:
        p = Path(extra).expanduser()
        if p.exists():
            command.extend(["--add-dir", str(p)])
    if CODEX_MODEL:
        command.extend(["--model", CODEX_MODEL])
    command.append(full_prompt)

    try:
        proc = subprocess.run(
            command,
            cwd=str(CODEX_WORKDIR),
            text=True,
            capture_output=True,
            timeout=CODEX_TIMEOUT_S,
            check=False,
        )
        try:
            response = Path(last_path).read_text(encoding="utf-8", errors="ignore").strip()
        except OSError:
            response = ""
        if not response:
            response = (proc.stdout or proc.stderr or "").strip()
        if len(response) > CODEX_MAX_RESPONSE_CHARS:
            response = response[:CODEX_MAX_RESPONSE_CHARS] + "..."
        return {
            "ok": proc.returncode == 0,
            "response": response,
            "session_id": session_id,
            "backend": "codex_cli",
            "model": CODEX_MODEL or "default",
            "provider": "codex-cli",
            "returncode": proc.returncode,
            "stdout": (proc.stdout or "")[-4000:],
            "stderr": (proc.stderr or "")[-4000:],
            "output_path": last_path,
        }
    except subprocess.TimeoutExpired as exc:
        return {
            "ok": False,
            "response": "Codex 执行超时了，任务还没完成。",
            "error": f"timeout after {CODEX_TIMEOUT_S}s",
            "session_id": session_id,
            "backend": "codex_cli",
            "model": CODEX_MODEL or "default",
            "provider": "codex-cli",
            "stdout": (exc.stdout or "")[-4000:] if isinstance(exc.stdout, str) else "",
            "stderr": (exc.stderr or "")[-4000:] if isinstance(exc.stderr, str) else "",
            "output_path": last_path,
        }


async def ask(prompt: str, *, context: str = "") -> dict[str, Any]:
    return await asyncio.to_thread(_run_codex_sync, prompt, context=context)

