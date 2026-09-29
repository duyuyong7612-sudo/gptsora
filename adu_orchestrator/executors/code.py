# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-05be70002b91bdfc57fdc3cad372fb8d6fe708d3595713380bf6d7f74480cacb"
# Source-SHA256: "3a843a39a67dbd9a1f87b336e484a9ebf0d17cf5b93d26df91cbbbcd79290122"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""code_executor — wraps the local adu_code_agent for project work.

Engine priority (per spec):
  1) local adu_code_agent  ← wired for search / list / read
  2) Codex CLI             ← wired through adu_orchestrator.codex_executor
  3) Claude Code           ← stub (see _claude_code_stub)

V1 routes a few common natural-language intents to adu_code_agent
primitives (search / list / read). Free-form code tasks are delegated to
the existing Codex executor safety wrapper.
"""
from __future__ import annotations

import re
from typing import Any, Dict, Optional

try:
    from adu_code_agent import fs_tools as _aca_fs
    LOCAL_OK = True
    LOCAL_ERR: Optional[str] = None
except Exception as _err:  # pragma: no cover
    LOCAL_OK = False
    LOCAL_ERR = f"{type(_err).__name__}: {_err}"
    _aca_fs = None  # type: ignore

try:
    from adu_orchestrator import codex_executor as _codex_exec
    CODEX_OK = True
    CODEX_ERR: Optional[str] = None
except Exception as _err:  # pragma: no cover
    CODEX_OK = False
    CODEX_ERR = f"{type(_err).__name__}: {_err}"
    _codex_exec = None  # type: ignore


# Adapter stubs ----------------------------------------------------------

def _codex_cli_adapter(task: str, project_dir: Optional[str]) -> Dict[str, Any]:
    if not CODEX_OK:
        return {
            "plan": [f"codex CLI would handle: {task!r}"],
            "actions": [],
            "result": f"Codex CLI adapter unavailable: {CODEX_ERR}",
            "needs_user_confirmation": True,
            "engine": "codex_cli",
        }
    if not (project_dir or "").strip():
        return {
            "plan": [f"codex CLI would handle: {task!r}"],
            "actions": [],
            "result": "project_dir is required for free-form Codex code tasks",
            "needs_user_confirmation": True,
            "engine": "codex_cli",
        }

    result = _codex_exec.run_codex_task(task=task, project_dir=project_dir)  # type: ignore[union-attr]
    ok = bool(result.get("ok"))
    return {
        "plan": [
            f"codex CLI task: {task!r}",
            f"project_dir: {project_dir}",
        ],
        "actions": [{
            "tool": "adu_orchestrator.codex_executor.run_codex_task",
            "ok": ok,
            "error": result.get("error"),
            "exit_code": result.get("exit_code"),
            "duration": result.get("duration"),
        }],
        "result": result.get("message") or ("Codex task completed" if ok else "Codex task failed"),
        "needs_user_confirmation": bool(result.get("needs_user_confirmation", not ok)),
        "engine": "codex_cli",
        "raw": result,
    }


def _claude_code_stub(task: str, project_dir: Optional[str]) -> Dict[str, Any]:
    return {
        "plan": [f"claude code would handle: {task!r}"],
        "actions": [],
        "result": "Claude Code adapter not wired in V1. See orchestrator README.",
        "needs_user_confirmation": True,
        "engine": "claude_code_stub",
    }


# Intent parsing ---------------------------------------------------------

_SEARCH_PAT = re.compile(
    r'(?:search|查找|搜索|grep|找一下|找)\s+(?P<q>"[^"]+"|\'[^\']+\'|\S+)'
    r'(?:\s+(?:in|在)\s+(?P<scope>\S+))?',
    re.I,
)
_LIST_PAT = re.compile(r'(?:list|ls|列出|看一下目录)\s+(?P<scope>\S+)', re.I)
_READ_PAT = re.compile(
    r'(?:read|读)\s+(?P<path>\S+?)(?::(?P<s>\d+)?(?:-(?P<e>\d+))?)?\b',
    re.I,
)


def _strip_quotes(s: str) -> str:
    s = s.strip()
    if len(s) >= 2 and s[0] in "\"'" and s[-1] == s[0]:
        return s[1:-1]
    return s


def _local_handle(task: str, project_dir: Optional[str]) -> Optional[Dict[str, Any]]:
    """Try to satisfy the task with adu_code_agent. Return None if nothing matches."""
    t = (task or "").strip()
    if not t:
        return None
    root = (project_dir or "").strip()

    m = _SEARCH_PAT.search(t)
    if m:
        query = _strip_quotes(m.group("q"))
        scope = (m.group("scope") or "").strip() or root
        if not scope:
            return {
                "plan": [f"search {query!r} (no scope)"],
                "actions": [],
                "result": "search intent matched but no project_dir / scope was provided",
                "needs_user_confirmation": True,
                "engine": "adu_code_agent",
            }
        result = _aca_fs.search_text(scope, query)
        return {
            "plan": [f"adu_code_agent.search_text({scope!r}, {query!r})"],
            "actions": [{
                "tool": "adu_code_agent.search_text",
                "scope": scope, "query": query,
                "ok": result.get("ok"),
                "match_count": result.get("match_count"),
            }],
            "result": (
                f"{result.get('match_count', 0)} match(es) for {query!r} in {scope}"
                if result.get("ok") else f"search failed: {result.get('error')}"
            ),
            "needs_user_confirmation": False,
            "engine": "adu_code_agent",
            "raw": result,
        }

    m = _LIST_PAT.search(t)
    if m:
        scope = m.group("scope")
        if scope in (".", "./"):
            scope = root or "."
        result = _aca_fs.list_files(scope)
        return {
            "plan": [f"adu_code_agent.list_files({scope!r})"],
            "actions": [{
                "tool": "adu_code_agent.list_files",
                "scope": scope,
                "ok": result.get("ok"),
                "count": result.get("count"),
            }],
            "result": (
                f"{result.get('count', 0)} file(s) under {scope}"
                if result.get("ok") else f"list failed: {result.get('error')}"
            ),
            "needs_user_confirmation": False,
            "engine": "adu_code_agent",
            "raw": result,
        }

    m = _READ_PAT.search(t)
    if m:
        path = m.group("path")
        start = int(m.group("s")) if m.group("s") else 1
        end = int(m.group("e")) if m.group("e") else None
        result = _aca_fs.read_file(path, start_line=start, end_line=end)
        return {
            "plan": [f"adu_code_agent.read_file({path!r}, {start}, {end})"],
            "actions": [{
                "tool": "adu_code_agent.read_file",
                "path": path, "ok": result.get("ok"),
            }],
            "result": (
                f"read {path} lines {result.get('start_line')}–{result.get('end_line')}"
                if result.get("ok") else f"read failed: {result.get('error')}"
            ),
            "needs_user_confirmation": False,
            "engine": "adu_code_agent",
            "raw": result,
        }

    return None


def run(task: str,
        project_dir: Optional[str] = None,
        safety_level: str = "normal") -> Dict[str, Any]:
    if not LOCAL_OK:
        return {
            "plan": [],
            "actions": [],
            "result": f"adu_code_agent unavailable — {LOCAL_ERR}",
            "needs_user_confirmation": True,
            "engine": "none",
        }
    out = _local_handle(task, project_dir)
    if out is not None:
        return out
    # Free-form code task → delegate to the central Codex safety wrapper.
    return _codex_cli_adapter(task, project_dir)
