# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-9335ff3a8e95745da75001313ad71c43ed47d16da3338432b7c50370cae308ad"
# Source-SHA256: "1c5eaf4bf3464fe9acb100575f5bd10cbaa8c822faee7dfb0413e6611db09951"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
ChatAGI Computer Body Gateway V2
================================
把"电脑"端口化成 ChatAGI 阿杜的身体。统一入口:

    GET  /api/brain/computer/body/ports
    POST /api/brain/computer/body/{port}/{action}

设计参考(工程思路,不盲目引重依赖)
----------------------------------
- OpenAI/Claude Computer Use:模型出 action,本地受控代码执行(本网关就是执行层)。
- Self-Operating Computer:screenshot→鼠标键盘动作循环(ScreenPort/Mouse/Keyboard)。
- Open Computer Use:完整电脑控制平台的端口分组思想(9 个 Port)。
- Taskhomie/computer-agent:本地桌面 agent(local-agent :4317 当身体)。
- browser-use:浏览器自动化(BrowserPort 先做轻量 open_url/screenshot,后续接 Playwright)。
- OpenComputer:任务 verifier / 轨迹验证(VerifyPort)。
- HIDAgent:后续硬件 HID 键鼠(本网关已为 mouse/keyboard 预留 port,可换后端)。

能力分层
--------
- GUI 端口(screen/mouse/keyboard/app/browser)→ 代理到 local-agent :4317
  (真正碰 GUI/osascript 的事在本机 local-agent 里做)。
- 后端端口(file/shell/code/verify)→ 在后端进程里执行(同一台 Mac/localhost),
  复用已有的安全实现(codex/claude executor、py_compile、allowlist),
  不把 shell/codex 重复塞进对外的 local-agent。

安全(默认拒绝危险)
------------------
- token:沿用 local-agent 的 Bearer(GUI 代理时带上)。
- localhost/LAN only:local-agent 绑 127.0.0.1;本网关不另开公网端口。
- shell allowlist + dangerous blocklist。
- file write 自动备份;敏感文件(.env/key/token/凭证)默认 blocked。
- max payload size、trace log、emergency stop flag(ENV 或运行时置位)。
- 不暴露任意 shell;非白名单 → blocked。

Mount
-----
from chatagi_computer_body import router as body_router, configure_computer_body
configure_computer_body(local_agent_callable=_call_local_agent)
app.include_router(body_router)
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import shutil
import subprocess
import time
import uuid
from typing import Any, Awaitable, Callable, Dict, List, Optional, Tuple

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

log = logging.getLogger("chatagi.computer_body")

LocalAgentCallable = Callable[[str, str, Optional[Dict[str, Any]]], Awaitable[Any]]
_LOCAL_AGENT: Optional[LocalAgentCallable] = None

# =============================================================================
# Config / guards
# =============================================================================

BACKEND_DIR = "~/Desktop/backend"
GPTSORA_DIR = "~/Desktop/GPTsora"
DESKTOP_DIR = "~/Desktop"

# 文件操作允许的根目录(沙箱)。写/改只能落在这里面。
FILE_SANDBOX_ROOTS = [BACKEND_DIR, GPTSORA_DIR, "/tmp"]

MAX_PAYLOAD_BYTES = int(os.getenv("BODY_MAX_PAYLOAD_BYTES", str(2 * 1024 * 1024)))  # 2MB
MAX_FILE_READ_BYTES = int(os.getenv("BODY_MAX_FILE_READ_BYTES", str(512 * 1024)))   # 512KB
SHELL_TIMEOUT = int(os.getenv("BODY_SHELL_TIMEOUT", "30"))

# 运行时紧急停止开关(置 True 后所有动作直接拒绝)。
_EMERGENCY_STOP = (os.getenv("BODY_EMERGENCY_STOP", "0").strip().lower() in ("1", "true", "yes"))

# shell 白名单(前缀匹配,只读/编译/诊断类)。
SHELL_ALLOWLIST = (
    "pwd", "ls", "find", "grep", "rg", "cat", "head", "tail", "wc", "file", "stat",
    "sed -n", "python3 -m py_compile", "python -m py_compile",
    "curl", "git diff", "git status", "git log", "git rev-parse",
    "lsof", "which", "echo", "xcodebuild -version", "xcrun --find", "swiftc --version",
)

# 危险动作黑名单(命中即 blocked,优先级高于白名单)。
DANGEROUS_PATTERNS = [
    (r"\brm\s+-", "递归/强制删除"),
    (r"\brmdir\b|\bunlink\b", "删除"),
    (r"\bsudo\b", "sudo 提权"),
    (r"\bchmod\s+777\b|\bchmod\s+-R\b", "危险权限变更"),
    (r"\bmkfs(?:\.|\s)|diskutil\s+erase|format\s+disk|格式化", "格式化磁盘"),
    (r"drop\s+database|delete\s+database|truncate\s+table|删库|删除数据库", "删除数据库"),
    (r"\bgit\s+push\b", "git push"),
    (r"\bscp\b|\bsftp\b|\brsync\b.*::", "外传/上传"),
    (r"\bpayment\b|付款|支付|转账|wire\s+transfer", "支付/转账"),
    (r"\bcurl\b[^|;&]*\b-T\b|\bcurl\b[^|;&]*--upload", "curl 上传"),
    (r":\(\)\s*\{\s*:\|\:&\s*\}", "fork bomb"),
    (r">\s*/dev/sd|dd\s+if=", "裸盘写入"),
]

# 敏感文件(默认 blocked 读取,除非 allow_sensitive=true)。
SENSITIVE_PATTERNS = [
    r"\.env(\.|$)", r"\bid_rsa\b", r"\bid_ed25519\b", r"\.pem$", r"\.key$",
    r"secret", r"credential", r"password", r"token", r"keychain",
    r"\.ssh/", r"\.aws/", r"\.config/.*token",
]


def configure_computer_body(*, local_agent_callable: Optional[LocalAgentCallable] = None) -> None:
    global _LOCAL_AGENT
    _LOCAL_AGENT = local_agent_callable
    log.info("Computer Body Gateway configured: local_agent=%s", local_agent_callable is not None)


def set_emergency_stop(on: bool) -> None:
    global _EMERGENCY_STOP
    _EMERGENCY_STOP = bool(on)
    log.warning("Computer Body emergency_stop = %s", _EMERGENCY_STOP)


# =============================================================================
# Port / action manifest
# =============================================================================

PORTS: Dict[str, Dict[str, Any]] = {
    "screen": {
        "where": "local-agent",
        "actions": {
            "screenshot": ("POST", "/api/computer/screenshot"),
            "displays": ("GET", "/api/computer/displays"),
            "windows": ("GET", "/api/computer/windows"),
            "active_window": ("GET", "/api/computer/active_window"),
        },
        "risk": "low",
    },
    "mouse": {
        "where": "local-agent",
        "actions": {
            "position": ("GET", "/api/computer/mouse"),
            "move": ("POST", "/api/computer/move"),
            "click": ("POST", "/api/computer/click"),
            "double_click": ("POST", "/api/computer/click"),
            "drag": ("POST", "/api/computer/drag"),
            "scroll": ("POST", "/api/computer/scroll"),
        },
        "risk": "low",
    },
    "keyboard": {
        "where": "local-agent",
        "actions": {
            "type": ("POST", "/api/computer/type"),
            "press": ("POST", "/api/computer/press"),
            "hotkey": ("POST", "/api/computer/press"),
            "paste": ("POST", "/api/computer/paste"),
        },
        "risk": "low",
    },
    "app": {
        "where": "local-agent",
        "actions": {
            "open_app": ("POST", "/api/computer/open_app"),
            "focus_app": ("POST", "/api/computer/focus_app"),
            "apps": ("GET", "/api/computer/apps"),
            "frontmost_app": ("GET", "/api/computer/frontmost_app"),
        },
        "risk": "low",
    },
    "browser": {
        "where": "local-agent",
        "actions": {
            "open_url": ("POST", "/api/computer/browser/open_url"),
            "extract_text": ("POST", "/api/computer/browser/extract_text"),
            "get_dom": ("POST", "/api/computer/browser/get_dom"),
            "click_text": ("POST", "/api/computer/browser/click_text"),
            "type_into": ("POST", "/api/computer/browser/type_into"),
            "screenshot": ("POST", "/api/computer/browser/screenshot"),
            "wait_for": ("POST", "/api/computer/browser/wait_for"),
            "status": ("GET", "/api/computer/browser/status"),
            "close": ("POST", "/api/computer/browser/close"),
        },
        "risk": "medium",
    },
    "file": {"where": "backend", "actions": {
        "list": None, "read": None, "write": None, "copy": None,
        "move": None, "rename": None, "search": None,
    }, "risk": "medium"},
    "shell": {"where": "backend", "actions": {"run": None}, "risk": "high"},
    "code": {"where": "backend", "actions": {"codex": None, "claude": None}, "risk": "high"},
    "verify": {"where": "backend", "actions": {
        "py_compile": None, "curl": None, "xcodebuild": None,
        "file_exists": None, "route_exists": None,
    }, "risk": "low"},
}


def ports_manifest() -> Dict[str, Any]:
    return {
        "ok": True,
        "module": "ChatAGI Computer Body Gateway V2",
        "emergency_stop": _EMERGENCY_STOP,
        "local_agent_connected": _LOCAL_AGENT is not None,
        "file_sandbox_roots": FILE_SANDBOX_ROOTS,
        "shell_allowlist": list(SHELL_ALLOWLIST),
        "ports": {
            name: {"where": p["where"], "risk": p["risk"], "actions": sorted(p["actions"].keys())}
            for name, p in PORTS.items()
        },
        "entry": "POST /api/brain/computer/body/{port}/{action}",
    }


# =============================================================================
# Security helpers
# =============================================================================


def _is_dangerous(text: str) -> Optional[str]:
    low = str(text or "").lower()
    for pat, reason in DANGEROUS_PATTERNS:
        try:
            if re.search(pat, low):
                return reason
        except re.error:
            continue
    return None


def _is_sensitive_path(path: str) -> bool:
    low = str(path or "").lower()
    for pat in SENSITIVE_PATTERNS:
        try:
            if re.search(pat, low):
                return True
        except re.error:
            continue
    return False


def _shell_allowed(cmd: str) -> bool:
    c = (cmd or "").strip()
    return any(c == p or c.startswith(p + " ") or c.startswith(p) for p in SHELL_ALLOWLIST)


# 浏览器敏感字段 / 付款动作 → need_confirm,绝不自动输入密码/验证码/卡号,绝不自动付款。
_BROWSER_SENSITIVE_FIELDS = (
    "password", "passwd", "pwd", "otp", "verification", "verify code", "验证码",
    "card number", "card_number", "cardnumber", "cvv", "cvc", "ssn", "社会安全",
    "token", "secret", "api key", "api_key", "密码", "口令", "私钥",
)
_BROWSER_PAYMENT_TERMS = (
    "purchase", "buy now", "buy", "pay now", "pay", "checkout", "place order",
    "submit payment", "transfer", "确认付款", "立即购买", "立即支付", "提交订单",
    "下单", "付款", "支付", "转账",
)


def _browser_guard(action: str, payload: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """浏览器危险动作守门。命中 → 返回 need_confirm 结果(不执行);安全 → None。"""
    a = (action or "").lower()
    blob = " ".join([
        str(payload.get("text") or ""), str(payload.get("selector") or ""),
        str(payload.get("value") or ""), str(payload.get("name") or ""),
    ]).lower()
    # type_into 到敏感字段 → 拒绝
    if a == "type_into":
        if any(s in blob for s in _BROWSER_SENSITIVE_FIELDS):
            return {"ok": False, "needs_user_confirmation": True, "blocked": True,
                    "error": "sensitive_input_blocked",
                    "message": "不自动输入密码/验证码/卡号等敏感字段,需人工确认。"}
    # click_text 命中付款/提交订单 → 需确认
    if a == "click_text":
        if any(t in blob for t in _BROWSER_PAYMENT_TERMS):
            return {"ok": False, "needs_user_confirmation": True, "blocked": True,
                    "error": "payment_action_blocked",
                    "message": "不自动提交付款/订单,需人工确认。"}
    return None


def _in_sandbox(path: str) -> bool:
    try:
        rp = os.path.realpath(os.path.abspath(os.path.expanduser(path)))
    except Exception:
        return False
    # 用 realpath 对比根目录(macOS 上 /tmp 是 /private/tmp 的软链,必须两边都解析)。
    for root in FILE_SANDBOX_ROOTS:
        try:
            rr = os.path.realpath(os.path.abspath(os.path.expanduser(root)))
        except Exception:
            continue
        if rp == rr or rp.startswith(rr.rstrip("/") + "/"):
            return True
    return False


def _backup_file(path: str) -> Optional[str]:
    try:
        if os.path.exists(path) and os.path.isfile(path):
            bak = f"{path}.body_bak.{uuid.uuid4().hex[:8]}"
            shutil.copy2(path, bak)
            return bak
    except Exception as e:  # noqa: BLE001
        log.warning("file backup failed for %s: %s", path, e)
    return None


def _result(ok: bool, port: str, action: str, payload: Dict[str, Any], data: Any,
            *, risk: str, allowed: bool, blocked: bool, reason: str, started: float) -> Dict[str, Any]:
    return {
        "ok": bool(ok),
        "port": port,
        "action": action,
        "risk_level": risk,
        "allowed": allowed,
        "blocked": blocked,
        "reason": reason,
        "result": data,
        "ms": round((time.perf_counter() - started) * 1000, 1),
    }


# =============================================================================
# Backend-side port implementations (file / shell / code / verify)
# =============================================================================


def _file_action(action: str, payload: Dict[str, Any]) -> Dict[str, Any]:
    allow_sensitive = bool(payload.get("allow_sensitive"))
    path = str(payload.get("path") or "")

    if action == "list":
        target = path or BACKEND_DIR
        if not _in_sandbox(target):
            return {"ok": False, "error": "path_outside_sandbox", "path": target}
        try:
            entries = sorted(os.listdir(target))[:500]
            return {"ok": True, "path": target, "entries": entries, "count": len(entries)}
        except Exception as e:  # noqa: BLE001
            return {"ok": False, "error": str(e), "path": target}

    if action == "read":
        if not _in_sandbox(path):
            return {"ok": False, "error": "path_outside_sandbox", "path": path}
        if _is_sensitive_path(path) and not allow_sensitive:
            return {"ok": False, "blocked": True, "error": "sensitive_file_blocked",
                    "message": "敏感文件默认禁止读取,需 allow_sensitive=true 且本地确认。", "path": path}
        try:
            with open(path, "rb") as fh:
                data = fh.read(MAX_FILE_READ_BYTES + 1)
            truncated = len(data) > MAX_FILE_READ_BYTES
            text = data[:MAX_FILE_READ_BYTES].decode("utf-8", errors="replace")
            return {"ok": True, "path": path, "content": text, "truncated": truncated,
                    "bytes": min(len(data), MAX_FILE_READ_BYTES)}
        except Exception as e:  # noqa: BLE001
            return {"ok": False, "error": str(e), "path": path}

    if action == "write":
        content = payload.get("content")
        if not isinstance(content, str):
            return {"ok": False, "error": "missing_content"}
        if not _in_sandbox(path):
            return {"ok": False, "error": "path_outside_sandbox", "path": path}
        if _is_sensitive_path(path) and not allow_sensitive:
            return {"ok": False, "blocked": True, "error": "sensitive_file_blocked", "path": path}
        if len(content.encode("utf-8")) > MAX_PAYLOAD_BYTES:
            return {"ok": False, "error": "payload_too_large"}
        bak = _backup_file(path)  # 写入前自动备份
        try:
            os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(content)
            return {"ok": True, "path": path, "backup": bak, "bytes": len(content.encode("utf-8"))}
        except Exception as e:  # noqa: BLE001
            return {"ok": False, "error": str(e), "path": path, "backup": bak}

    if action in ("copy", "move", "rename"):
        src = str(payload.get("src") or payload.get("from") or path)
        dst = str(payload.get("dst") or payload.get("to") or "")
        if not _in_sandbox(src) or not _in_sandbox(dst):
            return {"ok": False, "error": "path_outside_sandbox", "src": src, "dst": dst}
        if (_is_sensitive_path(src) or _is_sensitive_path(dst)) and not allow_sensitive:
            return {"ok": False, "blocked": True, "error": "sensitive_file_blocked"}
        bak = _backup_file(dst) if os.path.exists(dst) else None
        try:
            if action == "copy":
                shutil.copy2(src, dst)
            else:  # move / rename
                shutil.move(src, dst)
            return {"ok": True, "action": action, "src": src, "dst": dst, "backup": bak}
        except Exception as e:  # noqa: BLE001
            return {"ok": False, "error": str(e), "src": src, "dst": dst}

    if action == "search":
        root = str(payload.get("path") or BACKEND_DIR)
        query = str(payload.get("query") or payload.get("q") or "")
        if not _in_sandbox(root) or not query:
            return {"ok": False, "error": "bad_request"}
        try:
            proc = subprocess.run(
                ["grep", "-rIl", "--include=*.*", query, root],
                capture_output=True, text=True, timeout=20)
            hits = [ln for ln in (proc.stdout or "").splitlines() if ln.strip()][:200]
            return {"ok": True, "query": query, "root": root, "hits": hits, "count": len(hits)}
        except Exception as e:  # noqa: BLE001
            return {"ok": False, "error": str(e)}

    return {"ok": False, "error": "unsupported_file_action", "action": action}


def _shell_action(payload: Dict[str, Any]) -> Tuple[Dict[str, Any], str, bool, bool]:
    cmd = str(payload.get("cmd") or payload.get("command") or "").strip()
    if not cmd:
        return {"ok": False, "error": "missing_cmd"}, "high", False, False
    danger = _is_dangerous(cmd)
    if danger:
        return ({"ok": False, "blocked": True, "error": "dangerous_blocked", "reason": danger, "cmd": cmd},
                "blocked", False, True)
    if not _shell_allowed(cmd):
        return ({"ok": False, "needs_user_confirmation": True, "error": "not_in_allowlist",
                 "message": "命令不在白名单内,需人工确认。", "cmd": cmd,
                 "allowlist": list(SHELL_ALLOWLIST)}, "high", False, False)
    try:
        proc = subprocess.run(cmd, shell=True, capture_output=True, text=True,
                              timeout=SHELL_TIMEOUT, cwd=BACKEND_DIR)
        return ({"ok": proc.returncode == 0, "cmd": cmd, "exit_code": proc.returncode,
                 "stdout": (proc.stdout or "")[-8000:], "stderr": (proc.stderr or "")[-2000:]},
                "low", True, False)
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "shell_timeout", "cmd": cmd}, "low", True, False
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": str(e), "cmd": cmd}, "low", True, False


def _code_action(action: str, payload: Dict[str, Any]) -> Dict[str, Any]:
    prompt = str(payload.get("prompt") or payload.get("task") or "")
    workspace = str(payload.get("workspace") or BACKEND_DIR)
    timeout = int(payload.get("timeout") or 180)
    if not prompt:
        return {"ok": False, "error": "missing_prompt"}
    if action == "codex":
        try:
            from adu_orchestrator.codex_executor import run_codex_task
            return run_codex_task(prompt, workspace, timeout)
        except Exception as e:  # noqa: BLE001
            return {"ok": False, "error": "codex_unavailable", "message": str(e)}
    if action == "claude":
        try:
            from adu_orchestrator.claude_executor import run_claude_task
            return run_claude_task(prompt, workspace, timeout)
        except Exception as e:  # noqa: BLE001
            return {"ok": False, "error": "claude_unavailable", "message": str(e)}
    return {"ok": False, "error": "unsupported_code_action", "action": action}


def _verify_action(action: str, payload: Dict[str, Any]) -> Dict[str, Any]:
    if action == "py_compile":
        files = payload.get("files") or ([payload.get("file")] if payload.get("file") else [])
        results, all_ok = [], True
        for f in files:
            path = f if os.path.isabs(str(f)) else os.path.join(BACKEND_DIR, str(f))
            if not os.path.exists(path):
                results.append({"file": f, "ok": False, "error": "missing"}); all_ok = False; continue
            try:
                proc = subprocess.run(["python3", "-m", "py_compile", path],
                                      capture_output=True, text=True, timeout=60)
                ok = proc.returncode == 0
                all_ok = all_ok and ok
                results.append({"file": f, "ok": ok, "stderr": (proc.stderr or "")[-600:] if not ok else ""})
            except Exception as e:  # noqa: BLE001
                all_ok = False; results.append({"file": f, "ok": False, "error": str(e)})
        return {"ok": all_ok, "files": results}

    if action == "curl":
        url = str(payload.get("url") or "")
        if not url or _is_dangerous(url):
            return {"ok": False, "error": "bad_url"}
        try:
            proc = subprocess.run(["curl", "-s", "-m", "8", "-o", "/dev/null",
                                   "-w", "%{http_code}", url], capture_output=True, text=True, timeout=12)
            code = (proc.stdout or "").strip()
            return {"ok": code.isdigit() and int(code) < 400, "url": url, "status_code": code}
        except Exception as e:  # noqa: BLE001
            return {"ok": False, "error": str(e), "url": url}

    if action == "file_exists":
        path = str(payload.get("path") or "")
        return {"ok": os.path.exists(path), "path": path, "exists": os.path.exists(path),
                "is_file": os.path.isfile(path), "is_dir": os.path.isdir(path)}

    if action == "route_exists":
        route = str(payload.get("route") or "")
        try:
            proc = subprocess.run(["grep", "-rn", route, os.path.join(BACKEND_DIR, "server_session.py")],
                                  capture_output=True, text=True, timeout=15)
            found = bool((proc.stdout or "").strip())
            return {"ok": found, "route": route, "found": found,
                    "sample": (proc.stdout or "").splitlines()[:3]}
        except Exception as e:  # noqa: BLE001
            return {"ok": False, "error": str(e), "route": route}

    if action == "xcodebuild":
        xcode = shutil.which("xcodebuild")
        if not xcode:
            return {"ok": True, "skipped": True, "reason": "xcodebuild 不可用"}
        return {"ok": True, "skipped": True, "xcodebuild": xcode,
                "reason": "V2 只做可用性检查,完整 build 由用户在 Xcode 跑"}

    return {"ok": False, "error": "unsupported_verify_action", "action": action}


# =============================================================================
# Gateway dispatch
# =============================================================================


async def body_dispatch(port: str, action: str, payload: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    started = time.perf_counter()
    port = (port or "").strip().lower()
    action = (action or "").strip().lower()
    payload = payload if isinstance(payload, dict) else {}

    if _EMERGENCY_STOP:
        return _result(False, port, action, payload, {"emergency_stop": True}, risk="blocked",
                       allowed=False, blocked=True, reason="emergency_stop_active", started=started)

    spec = PORTS.get(port)
    if not spec or action not in spec["actions"]:
        return _result(False, port, action, payload, {"error": "unknown_port_or_action"},
                       risk="unknown", allowed=False, blocked=False,
                       reason="unknown_port_or_action", started=started)

    # payload 大小限制
    try:
        if len(json.dumps(payload, default=str).encode("utf-8")) > MAX_PAYLOAD_BYTES:
            return _result(False, port, action, {}, {"error": "payload_too_large"},
                           risk=spec["risk"], allowed=False, blocked=True,
                           reason="payload_too_large", started=started)
    except Exception:
        pass

    where = spec["where"]
    risk = spec["risk"]

    # ---- GUI ports → 代理到 local-agent ----
    if where == "local-agent":
        if _LOCAL_AGENT is None:
            return _result(False, port, action, payload, {"error": "local_agent_not_configured"},
                           risk=risk, allowed=False, blocked=False,
                           reason="local_agent_not_configured", started=started)
        # 浏览器安全守门:敏感字段/付款 → need_confirm,不代理
        if port == "browser":
            guard = _browser_guard(action, payload)
            if guard is not None:
                return _result(False, port, action, payload, guard, risk="blocked",
                               allowed=False, blocked=True, reason=guard.get("error", "browser_guard"),
                               started=started)
        method, path = spec["actions"][action]
        body = dict(payload)
        if action == "double_click":
            body.setdefault("count", 2)
        if action == "hotkey" and "keys" not in body and body.get("combo"):
            body["keys"] = re.split(r"[+\s,]+", str(body["combo"]))
        try:
            data = await _LOCAL_AGENT(method, path, body if method == "POST" else None)
        except Exception as e:  # noqa: BLE001
            data = {"ok": False, "error": "local_agent_error", "message": str(e)}
        ok = not (isinstance(data, dict) and data.get("ok") is False)
        return _result(ok, port, action, payload, data, risk=risk, allowed=True,
                       blocked=False, reason="proxied_to_local_agent", started=started)

    # ---- backend ports ----
    if port == "file":
        data = await asyncio.to_thread(_file_action, action, payload)
        blocked = bool(isinstance(data, dict) and data.get("blocked"))
        return _result(not (isinstance(data, dict) and data.get("ok") is False), port, action,
                       payload, data, risk=risk, allowed=not blocked, blocked=blocked,
                       reason="sensitive_blocked" if blocked else "backend_file", started=started)

    if port == "shell":
        data, rk, allowed, blocked = await asyncio.to_thread(_shell_action, payload)
        return _result(bool(data.get("ok")), port, action, payload, data, risk=rk,
                       allowed=allowed, blocked=blocked,
                       reason=("dangerous_blocked" if blocked else
                               ("needs_confirmation" if data.get("needs_user_confirmation") else "shell_allowlist")),
                       started=started)

    if port == "code":
        data = await asyncio.to_thread(_code_action, action, payload)
        return _result(bool(isinstance(data, dict) and (data.get("ok") or data.get("exit_code") == 0)),
                       port, action, payload, _trim_code(data), risk=risk, allowed=True,
                       blocked=False, reason="backend_code_executor", started=started)

    if port == "verify":
        data = await asyncio.to_thread(_verify_action, action, payload)
        return _result(bool(isinstance(data, dict) and data.get("ok")), port, action, payload,
                       data, risk=risk, allowed=True, blocked=False, reason="backend_verify",
                       started=started)

    return _result(False, port, action, payload, {"error": "unhandled_port"}, risk=risk,
                   allowed=False, blocked=False, reason="unhandled_port", started=started)


def _trim_code(data: Any) -> Any:
    if isinstance(data, dict):
        out = dict(data)
        for k in ("stdout", "stderr"):
            v = out.get(k)
            if isinstance(v, str) and len(v) > 6000:
                out[k] = v[:6000] + f"…(+{len(v)-6000})"
        return out
    return data


# =============================================================================
# FastAPI router
# =============================================================================

router = APIRouter(prefix="/api/brain/computer/body", tags=["chatagi-computer-body"])


@router.get("/ports")
async def body_ports() -> Dict[str, Any]:
    return ports_manifest()


@router.get("/health")
async def body_health() -> Dict[str, Any]:
    la_ok = False
    if _LOCAL_AGENT is not None:
        try:
            h = await _LOCAL_AGENT("GET", "/health", None)
            la_ok = bool(isinstance(h, dict) and h.get("ok"))
        except Exception:
            la_ok = False
    return {"ok": True, "module": "ChatAGI Computer Body Gateway V2",
            "local_agent_health": la_ok, "emergency_stop": _EMERGENCY_STOP,
            "ports": sorted(PORTS.keys())}


@router.post("/emergency_stop")
async def body_emergency_stop(request: Request) -> Dict[str, Any]:
    body = await _safe_json(request)
    set_emergency_stop(bool(body.get("on", True)))
    return {"ok": True, "emergency_stop": _EMERGENCY_STOP}


@router.post("/{port}/{action}")
async def body_action(port: str, action: str, request: Request) -> JSONResponse:
    payload = await _safe_json(request)
    out = await body_dispatch(port, action, payload)
    status = 200 if out.get("ok") or out.get("blocked") or out.get("allowed") is False else 200
    return JSONResponse(out, status_code=status)


async def _safe_json(request: Request) -> Dict[str, Any]:
    try:
        data = await request.json()
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}
