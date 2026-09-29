# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-107aa9a0513dbe03f2dd50cbd5e20dc74afcdcf8241efb97eee6837db3290041"
# Source-SHA256: "83b2cb6c8f0d96dfeeec6888097bb406e8f6cb20c14a239aa2acd9afbf82a3b6"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""Shell tools: run_command, check_port, kill_process.

run_command  — blocklist + timeout + secret-masked output.
check_port   — read-only port-listener lookup via `lsof`.
kill_process — dry-run by default; same-user check required.
"""
from __future__ import annotations

import os
import signal
import subprocess
import time
from typing import Any, Dict, List, Optional

from . import config, safety


def run_command(cmd: str,
                cwd: Optional[str] = None,
                timeout_seconds: float = config.DEFAULT_CMD_TIMEOUT,
                env_extra: Optional[Dict[str, str]] = None) -> Dict[str, Any]:
    """Run a shell command (via /bin/sh -c) with timeout + blocklist.
    Output is secret-masked."""
    if not isinstance(cmd, str) or not cmd.strip():
        return {"ok": False, "error": "empty_command"}

    bad, why = safety.is_dangerous_command(cmd)
    if bad:
        return {"ok": False, "blocked": True, "error": why, "command": cmd}

    try:
        timeout = float(timeout_seconds or config.DEFAULT_CMD_TIMEOUT)
    except (TypeError, ValueError):
        timeout = config.DEFAULT_CMD_TIMEOUT
    timeout = max(1.0, min(timeout, config.MAX_CMD_TIMEOUT))

    workdir = None
    if cwd:
        wd = safety.canonical(cwd)
        ok, why = safety.check_read_allowed(wd)
        if not ok:
            return {"ok": False, "error": f"cwd_denied: {why}"}
        if not wd.is_dir():
            return {"ok": False, "error": f"cwd_not_a_dir: {wd}"}
        workdir = str(wd)

    env = os.environ.copy()
    if env_extra:
        for k, v in env_extra.items():
            env[str(k)] = str(v)

    t0 = time.time()
    try:
        proc = subprocess.run(
            cmd, shell=True, cwd=workdir, env=env,
            capture_output=True, text=True, timeout=timeout,
        )
        duration = time.time() - t0
        stdout = proc.stdout or ""
        stderr = proc.stderr or ""
        if len(stdout) > config.MAX_OUTPUT_BYTES:
            stdout = stdout[:config.MAX_OUTPUT_BYTES] + "\n…[stdout truncated]"
        if len(stderr) > config.MAX_OUTPUT_BYTES:
            stderr = stderr[:config.MAX_OUTPUT_BYTES] + "\n…[stderr truncated]"
        return {
            "ok": True,
            "command": cmd,
            "cwd": workdir,
            "exit_code": proc.returncode,
            "duration_sec": round(duration, 3),
            "stdout": safety.mask_secrets(stdout),
            "stderr": safety.mask_secrets(stderr),
        }
    except subprocess.TimeoutExpired as e:
        so = e.stdout or ""
        se = e.stderr or ""
        if isinstance(so, bytes):
            so = so.decode("utf-8", errors="replace")
        if isinstance(se, bytes):
            se = se.decode("utf-8", errors="replace")
        return {
            "ok": False, "error": "timeout",
            "timeout_seconds": timeout,
            "duration_sec": round(time.time() - t0, 3),
            "command": cmd,
            "stdout": safety.mask_secrets(so),
            "stderr": safety.mask_secrets(se),
        }
    except Exception as ex:
        return {"ok": False,
                "error": f"run_failed: {type(ex).__name__}: {ex}",
                "command": cmd}


def check_port(port: int) -> Dict[str, Any]:
    """Look up the process listening on a TCP port (read-only)."""
    try:
        port = int(port)
    except (TypeError, ValueError):
        return {"ok": False, "error": "invalid_port"}
    if not (1 <= port <= 65535):
        return {"ok": False, "error": "port_out_of_range"}

    cmd = f"lsof -nP -iTCP:{port} -sTCP:LISTEN -Fpcn"
    try:
        proc = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=8)
    except Exception as e:
        return {"ok": False, "error": f"lsof_failed: {e}"}

    listeners: List[Dict[str, Any]] = []
    cur: Dict[str, Any] = {}
    for line in (proc.stdout or "").splitlines():
        if not line:
            continue
        tag, val = line[0], line[1:]
        if tag == "p":
            if cur:
                listeners.append(cur)
            cur = {"pid": int(val) if val.isdigit() else val}
        elif tag == "c":
            cur["command"] = val
        elif tag == "n":
            cur["address"] = val
    if cur:
        listeners.append(cur)

    return {"ok": True, "port": port,
            "listening": bool(listeners), "processes": listeners}


def _proc_info(pid: int) -> Dict[str, Any]:
    try:
        proc = subprocess.run(
            ["ps", "-p", str(pid), "-o", "pid=,user=,command="],
            capture_output=True, text=True, timeout=4,
        )
        line = (proc.stdout or "").strip()
        if not line:
            return {}
        parts = line.split(None, 2)
        return {
            "pid": int(parts[0]),
            "user": parts[1] if len(parts) > 1 else "",
            "command": parts[2] if len(parts) > 2 else "",
        }
    except Exception:
        return {}


def kill_process(pid: Optional[int] = None,
                 port: Optional[int] = None,
                 allow_kill: bool = False,
                 signal_name: str = "TERM") -> Dict[str, Any]:
    """Send a signal to a process. Default = dry-run (returns target info only).
    Will refuse processes owned by a different user."""
    if pid is None and port is None:
        return {"ok": False, "error": "missing_pid_or_port"}

    target_pids: List[int] = []
    if pid is not None:
        try:
            target_pids.append(int(pid))
        except (TypeError, ValueError):
            return {"ok": False, "error": "invalid_pid"}
    if port is not None:
        info = check_port(port)
        if not info.get("ok"):
            return info
        for p in info.get("processes", []):
            if isinstance(p.get("pid"), int):
                target_pids.append(p["pid"])

    if not target_pids:
        return {"ok": False, "error": "no_target_processes_found"}

    me = os.environ.get("USER") or ""
    candidates: List[Dict[str, Any]] = []
    for tpid in target_pids:
        info = _proc_info(tpid)
        same_user = (info.get("user") == me) if me else False
        candidates.append({**info, "pid": tpid, "same_user": same_user})

    if not allow_kill:
        return {
            "ok": True, "dry_run": True,
            "would_signal": signal_name,
            "candidates": candidates,
            "hint": "set allow_kill=true to actually send the signal",
        }

    sigmap = {"TERM": signal.SIGTERM, "KILL": signal.SIGKILL,
              "INT": signal.SIGINT, "HUP": signal.SIGHUP}
    sig = sigmap.get(signal_name.upper(), signal.SIGTERM)

    results: List[Dict[str, Any]] = []
    for c in candidates:
        if not c.get("same_user"):
            results.append({"pid": c["pid"], "ok": False, "error": "not_same_user"})
            continue
        try:
            os.kill(c["pid"], sig)
            results.append({"pid": c["pid"], "ok": True, "signal": signal_name})
        except ProcessLookupError:
            results.append({"pid": c["pid"], "ok": False, "error": "no_such_process"})
        except PermissionError:
            results.append({"pid": c["pid"], "ok": False, "error": "permission_denied"})
        except Exception as e:
            results.append({"pid": c["pid"], "ok": False, "error": str(e)})

    return {"ok": True, "applied": True, "signal": signal_name, "results": results}
