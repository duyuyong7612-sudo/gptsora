# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-f0496cb2d6252eb13f273832ce5bd780325864b99ca9091e42e8e5ef0def5fe0"
# Source-SHA256: "6fef556c0c2fbbc32ce0068891405349f56bffca4d3cb9edca68a450047e1324"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""browser_executor — V1 stub for browser-use / agent-browser.

Returns a plan-only response. See orchestrator README for wiring.
"""
from __future__ import annotations

from typing import Any, Dict, Optional


def run(task: str,
        project_dir: Optional[str] = None,
        safety_level: str = "normal") -> Dict[str, Any]:
    return {
        "plan": [
            f"task: {task!r}",
            "browser executor not yet wired",
            "candidates: browser-use, agent-browser, Playwright + LLM",
        ],
        "actions": [],
        "result": (
            "browser executor is a V1 stub. See orchestrator README for the "
            "~6-line wiring to browser-use or agent-browser."
        ),
        "needs_user_confirmation": True,
        "engine": "browser_stub",
    }
