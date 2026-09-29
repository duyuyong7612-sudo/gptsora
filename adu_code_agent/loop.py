# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-2414198f930c64e0934b840c625ac48dfed0bf0225db150006fdc520d02599a6"
# Source-SHA256: "fd69570e48b71f93511a6f1a608ed8fbf061d80ebab89934b2b7cb39b2316510"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""AgentLoop — lightweight orchestration scaffold.

V1 is a STRUCTURED EXECUTOR, not an LLM planner. The caller supplies a
sequence of action dicts; the loop runs them, records attempts, and
produces a summary. This is the foundation a future LLM-driven planner
will sit on top of.

Supported action types:
  - {"type": "list",       "root": ..., "include": [], "exclude": [], "max_depth": 8}
  - {"type": "read",       "path": ..., "start": 1, "end": ..., "max_lines": 400}
  - {"type": "search",     "root": ..., "query": ..., "include": [], "exclude": [], ...}
  - {"type": "write",      "path": ..., "content": ..., "allow_write": false}
  - {"type": "patch",      "path": ..., "search": ..., "replace": ..., "allow_write": false}
  - {"type": "run",        "cmd": ..., "cwd": ..., "timeout": 60}
  - {"type": "check_port", "port": 3000}
  - {"type": "kill",       "pid": ..., "port": ..., "allow_kill": false, "signal": "TERM"}
"""
from __future__ import annotations

import time
from typing import Any, Dict, List, Optional

from . import fs_tools, shell_tools


_ACTION_TYPES = {
    "list", "read", "search", "write", "patch",
    "run", "check_port", "kill",
}


class AgentLoop:
    def __init__(self,
                 goal: str,
                 allow_write: bool = False,
                 allow_kill: bool = False,
                 max_iterations: int = 5):
        self.goal = goal
        self.allow_write = bool(allow_write)
        self.allow_kill = bool(allow_kill)
        self.max_iterations = max(1, min(int(max_iterations or 5), 50))
        self.attempts: List[Dict[str, Any]] = []
        self.started_at = time.time()

    @staticmethod
    def _summarize_result(action: Dict[str, Any], result: Dict[str, Any]) -> str:
        a = action.get("type")
        if a == "list":
            return f"{result.get('count','?')} files"
        if a == "read":
            try:
                n = int(result.get("end_line", 0)) - int(result.get("start_line", 0)) + 1
            except Exception:
                n = "?"
            return f"{n} lines from {result.get('start_line','?')}"
        if a == "search":
            return f"{result.get('match_count','?')} matches across {result.get('files_scanned','?')} files"
        if a in ("write", "patch"):
            diff_lines = len((result.get("diff") or "").splitlines())
            return f"applied={result.get('applied')} diff_lines={diff_lines}"
        if a == "run":
            return f"exit={result.get('exit_code','?')} duration={result.get('duration_sec','?')}s"
        if a == "check_port":
            return f"listening={result.get('listening')} procs={len(result.get('processes') or [])}"
        if a == "kill":
            return f"signal={result.get('signal','?')} applied={result.get('applied', False)}"
        return ""

    def _record(self, step: int, action: Dict[str, Any], result: Dict[str, Any]) -> None:
        self.attempts.append({
            "step": step,
            "action": action.get("type"),
            "ok": bool(result.get("ok")),
            "applied": bool(result.get("applied", False)),
            "error": result.get("error"),
            "summary": self._summarize_result(action, result),
        })

    def step(self, action: Dict[str, Any]) -> Dict[str, Any]:
        a = (action or {}).get("type")
        if a not in _ACTION_TYPES:
            return {"ok": False, "error": f"unknown_action: {a!r}"}
        try:
            if a == "list":
                return fs_tools.list_files(
                    action["root"],
                    include_patterns=action.get("include"),
                    exclude_patterns=action.get("exclude"),
                    max_depth=action.get("max_depth", 8),
                )
            if a == "read":
                return fs_tools.read_file(
                    action["path"],
                    start_line=action.get("start", 1),
                    end_line=action.get("end"),
                    max_lines=action.get("max_lines", 400),
                )
            if a == "search":
                return fs_tools.search_text(
                    action["root"], action["query"],
                    include_patterns=action.get("include"),
                    exclude_patterns=action.get("exclude"),
                    case_sensitive=action.get("case_sensitive", False),
                    max_results=action.get("max_results", 500),
                    context_lines=action.get("context", 0),
                    explicitly_allow_secrets=action.get("explicitly_allow_secrets", False),
                )
            if a == "write":
                allow = action.get("allow_write", self.allow_write)
                return fs_tools.write_file(
                    action["path"], action.get("content", ""),
                    allow_write=allow,
                )
            if a == "patch":
                allow = action.get("allow_write", self.allow_write)
                return fs_tools.patch_file(
                    action["path"],
                    search=action.get("search"),
                    replace=action.get("replace"),
                    patch=action.get("patch"),
                    allow_write=allow,
                )
            if a == "run":
                return shell_tools.run_command(
                    action["cmd"], cwd=action.get("cwd"),
                    timeout_seconds=action.get("timeout", 60),
                    env_extra=action.get("env"),
                )
            if a == "check_port":
                return shell_tools.check_port(action["port"])
            if a == "kill":
                return shell_tools.kill_process(
                    pid=action.get("pid"), port=action.get("port"),
                    allow_kill=action.get("allow_kill", self.allow_kill),
                    signal_name=action.get("signal", "TERM"),
                )
        except KeyError as ke:
            return {"ok": False, "error": f"missing_arg: {ke}"}
        return {"ok": False, "error": "unreachable"}

    def run_script(self, actions: List[Dict[str, Any]]) -> Dict[str, Any]:
        """Run a scripted sequence of actions. Records attempts; returns summary."""
        # Hard cap on script length so a runaway script can't grind forever.
        cap = max(1, int(self.max_iterations) * 4)
        results: List[Dict[str, Any]] = []
        for i, act in enumerate(actions[:cap], start=1):
            res = self.step(act)
            self._record(i, act, res)
            results.append({"step": i, "action": act.get("type"), "result": res})
            if (not res.get("ok")) and act.get("stop_on_error", False):
                break
        return self.summarize(results=results)

    def summarize(self, results: Optional[List[Dict[str, Any]]] = None) -> Dict[str, Any]:
        elapsed = round(time.time() - self.started_at, 3)
        completed = bool(self.attempts) and all(a.get("ok") for a in self.attempts)
        return {
            "ok": True,
            "goal": self.goal,
            "elapsed_sec": elapsed,
            "completed": completed,
            "step_count": len(self.attempts),
            "attempts": self.attempts,
            "details": results or [],
            "allow_write": self.allow_write,
            "allow_kill": self.allow_kill,
        }
