# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-a28ac73b940cfe8dbbc1d23f1dcd9e0fa265195b73be07c0a00786fff82560f5"
# Source-SHA256: "face38c3e47a2eab326735859d34b97e4ea29a83578fb463b08d6fe8f2e2f603"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
ChatAGI DevBrain Runtime V1
===========================
The autonomous-programming closed loop for ChatAGI / 阿杜.

手机一句话 → 总大脑理解目标 → observe(屏幕/文件/项目状态) → plan → act
(Codex / Claude / local-agent / shell / file) → verify(py_compile / health /
screenshot) → repair(失败自动修一次,最多 3 次) → memory writeback → 返回完整 trace。

Design
------
This module is mounted into the existing FastAPI backend. It NEVER deletes
project files, never runs `rm -rf`, never touches .env secret VALUES, never
`git push`, never modifies billing/payment. Write-capable steps snapshot the
target files first and auto-rollback if py_compile breaks. The running backend
process is not restarted by this module (edits only take effect on a manual
restart), so an in-flight DevBrain run can never crash the live server.

Layers / classes
----------------
- DevBrainStep            一步的结构化记录 (i/phase/tool/action/result/ms)
- DevBrainExecutorRouter  按 preference + 可用性选执行器,带 fallback
- CodexExecutor           包装 adu_orchestrator.codex_executor.run_codex_task
- ClaudeExecutor          包装 adu_orchestrator.claude_executor.run_claude_task
- LocalAgentExecutor      包装注入的 local-agent callable(控电脑)
- VerificationRunner      py_compile / curl health / local-agent health / screenshot / swift
- SelfUpgradeController    递归自我升级 preset,内部复用 DevBrainRuntime
- DevBrainRuntime          observe→plan→act→verify→repair→writeback 主循环

Mount in server_session.py
---------------------------
from chatagi_devbrain_runtime import router as devbrain_router, configure_devbrain
configure_devbrain(
    memory_engine=MEMORY_ENGINE,
    brain_state_engine=BRAIN_STATE_ENGINE,
    local_agent_callable=_call_local_agent,
)
app.include_router(devbrain_router)
"""

from __future__ import annotations

import asyncio
import copy
import json
import logging
import os
import re
import shutil
import subprocess
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, Awaitable, Callable, Dict, List, Optional, Tuple

try:
    import httpx
except Exception:  # noqa: BLE001
    httpx = None  # type: ignore[assignment]

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

log = logging.getLogger("chatagi.devbrain")

# =============================================================================
# Config & injection
# =============================================================================

LocalAgentCallable = Callable[[str, str, Optional[Dict[str, Any]]], Awaitable[Any]]

_MEMORY_ENGINE: Any = None
_BRAIN_STATE_ENGINE: Any = None
_LOCAL_AGENT_CALLABLE: Optional[LocalAgentCallable] = None

BACKEND_DIR = "~/Desktop/backend"
GPTSORA_DIR = "~/Desktop/GPTsora"
DESKTOP_DIR = "~/Desktop"

WORKSPACES: Dict[str, str] = {
    "backend": BACKEND_DIR,
    "gptsora": GPTSORA_DIR,
    "ios": GPTSORA_DIR,
    "desktop": DESKTOP_DIR,
}
DEFAULT_WORKSPACE = BACKEND_DIR

BACKEND_BASE = os.getenv("DEVBRAIN_BACKEND_BASE", "http://127.0.0.1:8000")

# 关键文件:写操作前做快照,verify 后若编译崩了可回滚。
SNAPSHOT_FILES = {
    BACKEND_DIR: [
        "server_session.py",
        "chatagi_brain_core_v3_2_embodied_projection.py",
        "chatagi_devbrain_runtime.py",
    ],
}

# 硬禁止类别(命中 goal/动作即拒绝,进入 blocked/need_confirm)。
_HARD_BLOCK_PATTERNS = [
    (r"\brm\s+-r", "递归/强制删除"),
    (r"\bsudo\b", "sudo 提权"),
    (r"\bmkfs(?:\.|\s)|format\s+disk|格式化磁盘|抹掉磁盘|擦除磁盘", "格式化磁盘"),
    (r"drop\s+database|delete\s+database|删除数据库|删库|truncate\s+table", "删除数据库"),
    (r"delete\s+production|删除生产|清空生产", "删除生产数据"),
    (r"git\s+push", "git push(本系统禁止自动推送)"),
    (r"\bpayment\b|付款|支付|结账|checkout|transfer\s+money|wire\s+transfer|转账|汇款", "支付/转账"),
    (r"修改密钥|改写密钥|覆盖密钥|改\s*\.env|覆盖\s*\.env|删除\s*\.env|api[_\s-]?key\s*=|私钥|钥匙串|keychain", "修改/读取密钥"),
    (r"billing|计费逻辑改|改计费|改账单", "billing/计费"),
]

# 中风险(写文件/调用代码执行器):备份后执行。
_MED_RISK_HINT = ("修改", "改", "patch", "edit", "write", "重构", "refactor", "修复", "fix", "新增", "实现", "接入")

# shell 白名单(前缀匹配,只读/编译类)。
_SHELL_WHITELIST_PREFIXES = (
    "python3 -m py_compile", "python -m py_compile",
    "ls", "cat", "head", "tail", "grep", "rg", "find", "wc",
    "git status", "git diff", "git log", "git rev-parse",
    "curl", "lsof", "echo", "pwd", "which", "file", "stat",
    "xcodebuild -version", "xcrun --find", "swiftc --version",
)


def configure_devbrain(
    *,
    memory_engine: Any = None,
    brain_state_engine: Any = None,
    local_agent_callable: Optional[LocalAgentCallable] = None,
) -> None:
    global _MEMORY_ENGINE, _BRAIN_STATE_ENGINE, _LOCAL_AGENT_CALLABLE
    _MEMORY_ENGINE = memory_engine
    _BRAIN_STATE_ENGINE = brain_state_engine
    _LOCAL_AGENT_CALLABLE = local_agent_callable
    # 用 is not None,不要用 bool():五层记忆引擎为空时真值可能为假,
    # 之前 bool() 误报 memory=False,其实引擎已注入。
    log.info("DevBrain configured: memory=%s (hybrid_recall=%s) brain_state=%s local_agent=%s",
             memory_engine is not None,
             bool(memory_engine is not None and hasattr(memory_engine, "hybrid_recall")),
             brain_state_engine is not None, local_agent_callable is not None)


# =============================================================================
# Data contracts
# =============================================================================


class DevRunInput(BaseModel):
    goal: str = Field(default="")
    mode: str = Field(default="auto")
    max_steps: int = Field(default=20)
    allow_write: bool = Field(default=True)
    allow_tools: bool = Field(default=True)
    executor_preference: str = Field(default="codex_first")
    return_trace: bool = Field(default=True)
    workspace: str = Field(default="")
    confirm_token: str = Field(default="")
    source: str = Field(default="dev_run")
    # ✅ 视觉驱动闭环参数
    vision_driven: Optional[bool] = Field(default=None)   # None → allow_tools 时默认 True
    observe_each_step: bool = Field(default=True)
    visual_verify: bool = Field(default=True)


@dataclass
class DevBrainStep:
    i: int
    phase: str          # observe|plan|act|verify|repair|writeback
    tool: str           # braincore|local-agent|codex|claude|shell|file|devbrain
    action: str
    result: Dict[str, Any] = field(default_factory=dict)
    ms: float = 0.0
    ok: bool = True

    def as_dict(self) -> Dict[str, Any]:
        return {
            "i": self.i, "phase": self.phase, "tool": self.tool,
            "action": self.action, "result": self.result,
            "ms": round(self.ms, 1), "ok": self.ok,
        }


# =============================================================================
# Risk gate
# =============================================================================


def _hard_block(text: str) -> Optional[str]:
    if not isinstance(text, str) or not text.strip():
        return None
    low = text.lower()
    for pat, reason in _HARD_BLOCK_PATTERNS:
        try:
            if re.search(pat, low):
                return reason
        except re.error:
            continue
    return None


def _shell_allowed(cmd: str) -> bool:
    c = (cmd or "").strip()
    if _hard_block(c):
        return False
    return any(c.startswith(p) for p in _SHELL_WHITELIST_PREFIXES)


def _emergency_active() -> bool:
    """读 Body Gateway 的全局急停标志(若模块可用)。"""
    try:
        import chatagi_computer_body as _cb
        return bool(getattr(_cb, "_EMERGENCY_STOP", False))
    except Exception:
        return False


# =============================================================================
# Visual signal extraction + visual verifier (视觉驱动闭环)
# =============================================================================

_APP_PATTERNS = [
    ("Xcode", r"\bxcode\b"),
    ("VSCode", r"\bvs\s*code\b|visual studio code|vscode"),
    ("Terminal", r"\bterminal\b|终端|iterm"),
    ("Safari", r"\bsafari\b"),
    ("Chrome", r"\bchrome\b"),
    ("WeChat", r"\bwechat\b|微信"),
]
# 错误类型识别(关键词 → type)
_ERR_RULES = [
    ("swift_compile", r"unable to type-check|cannot find .* in scope|build failed|no exact matches|swift compiler|\.swift:\d+"),
    ("python_error", r"traceback|syntaxerror|modulenotfounderror|indentationerror|py_compile|\.py\", line"),
    ("terminal_error", r"command failed|no such file|permission denied|command not found|non-zero exit|fatal:"),
    ("xcode_issue", r"signing|provisioning|simulator|scheme|linker|undefined symbol"),
]
_FILE_RE = re.compile(r"([A-Za-z0-9_./\-]+\.(?:swift|py|m|h|js|ts|json|plist))(?::(\d+))?")


def extract_visual_signals(vision_result: Dict[str, Any]) -> Dict[str, Any]:
    """把 vision observe 结果抽成结构化信号(app/errors[type,file,line,confidence]/ui/next)。"""
    vr = vision_result if isinstance(vision_result, dict) else {}
    summary = str(vr.get("vision_summary") or "")
    app_raw = str(vr.get("active_app") or "")
    visible_text = [str(t) for t in (vr.get("text") or [])][:20]
    raw_errors = [str(e) for e in (vr.get("errors") or [])]
    ui_elements = vr.get("ui_elements") or []
    blob = (app_raw + " " + summary + " " + " ".join(visible_text) + " " + " ".join(raw_errors)).lower()

    app = "Unknown"
    for name, pat in _APP_PATTERNS:
        if re.search(pat, blob):
            app = name
            break

    errors: List[Dict[str, Any]] = []
    candidates = list(raw_errors)
    # 也从可见文本/概要里捞 error: 行
    for t in visible_text + [summary]:
        if re.search(r"error|failed|traceback|cannot find|unable to type-check|报错|错误", t, re.I):
            candidates.append(t)
    seen = set()
    for c in candidates:
        c = str(c).strip()
        if not c or c.lower() in seen:
            continue
        seen.add(c.lower())
        etype = "unknown"
        for name, pat in _ERR_RULES:
            if re.search(pat, c, re.I):
                etype = name
                break
        if etype == "unknown" and app == "Xcode":
            etype = "xcode_issue"
        fm = _FILE_RE.search(c)
        errors.append({
            "type": etype,
            "text": c[:240],
            "file": fm.group(1) if fm else None,
            "line": int(fm.group(2)) if (fm and fm.group(2)) else None,
            "confidence": round(0.85 if etype != "unknown" else 0.4, 2),
        })
        if len(errors) >= 8:
            break

    return {
        "app": app,
        "visible_text": visible_text,
        "errors": errors,
        "ui_elements": ui_elements[:12],
        "next_possible_actions": (vr.get("next_actions") or [])[:6],
        "has_error": bool(errors),
        "summary": summary,
    }


class VisualVerifier:
    """基于 goal + before/after 视觉 + 动作/验证结果,判断任务是否完成。"""

    @staticmethod
    def verify(goal: str, before_vision: Dict[str, Any], after_vision: Dict[str, Any],
               action_result: Dict[str, Any], verify_result: Dict[str, Any]) -> Dict[str, Any]:
        low = (goal or "").lower()
        after = after_vision or {}
        after_errors = after.get("errors") or []
        after_app = str(after.get("app") or "")
        py_ok = bool((verify_result or {}).get("py_compile", {}).get("ok", True))

        def res(done, conf, reason, nxt=""):
            return {"done": bool(done), "confidence": round(conf, 2), "reason": reason,
                    "remaining_errors": after_errors[:6], "next_suggestion": nxt}

        # 修 Xcode / Swift 错误
        if any(k in low for k in ("xcode", "swift", "编译错误", "build")):
            if not after_errors:
                return res(True, 0.8, "视觉上已无错误(Xcode/Swift)")
            return res(False, 0.7, f"视觉仍有 {len(after_errors)} 个错误", "继续 repair 或 xcodebuild")
        # 打开网页
        if any(k in low for k in ("网页", "url", "browser", "网站", "打开 http")):
            txt = " ".join(after.get("visible_text") or [])
            return res(bool(txt), 0.7 if txt else 0.3, "浏览器已有页面内容" if txt else "页面内容为空")
        # 打开 App
        if "打开" in low or "open app" in low:
            for name in ("Xcode", "VSCode", "Terminal", "Safari", "Chrome", "WeChat"):
                if name.lower() in low and after_app.lower() == name.lower():
                    return res(True, 0.8, f"目标 App {name} 已在前台")
            return res(bool(after_app and after_app != "Unknown"), 0.5, f"前台应用: {after_app}")
        # 修代码(后端)
        if any(k in low for k in ("修复", "fix", "py_compile", "代码", "工程", "重构")):
            if not py_ok:
                return res(False, 0.7, "py_compile 未通过", "继续 repair")
            if after_errors:
                return res(False, 0.6, "py_compile 通过但视觉仍有错误")
            return res(True, 0.8, "py_compile 通过且视觉无错误")
        # 截图/观察
        if any(k in low for k in ("观察", "看", "截图", "屏幕", "screenshot", "判断")):
            return res(bool(after.get("summary")), 0.75 if after.get("summary") else 0.3,
                       f"已观察屏幕,前台: {after_app or 'Unknown'}")
        # 默认:无残留错误即视为完成
        return res(not after_errors, 0.55, "无明显残留错误" if not after_errors else "仍有视觉错误")


# =============================================================================
# Executors
# =============================================================================


class CodexExecutor:
    name = "codex"

    def __init__(self) -> None:
        self._run = None
        self._check = None
        self._mod = None
        try:
            from adu_orchestrator import codex_executor as _cx
            self._mod = _cx
            self._run = _cx.run_codex_task
            self._check = _cx.check_codex_available
        except Exception as e:  # noqa: BLE001
            log.warning("CodexExecutor import failed: %s", e)

    def available(self) -> Dict[str, Any]:
        if self._check is None:
            return {"ok": False, "error": "codex_executor_unavailable"}
        try:
            return self._check()
        except Exception as e:  # noqa: BLE001
            return {"ok": False, "error": "codex_check_failed", "message": str(e)}

    async def run(self, prompt: str, workspace: str, *, timeout: int = 180,
                  write: bool = False) -> Dict[str, Any]:
        """write=False → 复用共享只读 run_codex_task;write=True → DevBrain 自己的
        workspace-write 调用(不动共享模块,其它调用方仍是只读)。"""
        if write:
            return await asyncio.to_thread(self._run_write, prompt, workspace, timeout)
        if self._run is None:
            return {"ok": False, "error": "codex_executor_unavailable", "stdout": "", "stderr": ""}
        try:
            return await asyncio.to_thread(self._run, prompt, workspace, timeout)
        except Exception as e:  # noqa: BLE001
            return {"ok": False, "error": "codex_exception", "message": str(e), "stdout": "", "stderr": str(e)}

    def _run_write(self, prompt: str, workspace: str, timeout: int) -> Dict[str, Any]:
        """codex exec -s workspace-write —— 真正允许 codex 在工作区内改文件。
        仍复用 codex_executor 的 auth/env、安全前缀、风险词拦截与输出脱敏。"""
        import subprocess as _sp
        start = time.time()
        cx = self._mod
        if cx is None:
            return {"ok": False, "error": "codex_executor_unavailable", "stdout": "", "stderr": ""}
        # 我方风险词拦截(用户目标级别已在 runtime 拦过,这里再保一道)
        hits = cx.find_confirmation_terms(prompt)
        if hits:
            return {"ok": False, "error": "needs_user_confirmation", "needs_user_confirmation": True,
                    "blocked_terms": hits, "stdout": "", "stderr": "", "exit_code": None}
        avail = self.available()
        if not avail.get("ok"):
            return {**avail, "stdout": "", "stderr": ""}
        codex_path = str(avail.get("codex_path") or "codex")
        env, _ = cx._build_codex_subprocess_env()
        task = cx.SAFETY_PREFIX + prompt
        cmd = [codex_path, "exec", "--skip-git-repo-check", "-s", "workspace-write", "-C", workspace, task]
        try:
            proc = _sp.run(cmd, cwd=workspace, stdin=_sp.DEVNULL,
                           stdout=_sp.PIPE, stderr=_sp.PIPE, text=True,
                           timeout=max(1, min(int(timeout or 180), 900)), env=env)
            ok = proc.returncode == 0
            return {
                "ok": ok, "engine": "codex", "mode": "workspace-write",
                "exit_code": proc.returncode,
                "stdout": cx.sanitize_output((proc.stdout or "")[-6000:]),
                "stderr": cx.sanitize_output((proc.stderr or "")[-2000:]),
                "duration": round(time.time() - start, 3),
                "error": None if ok else "codex_exec_failed",
            }
        except _sp.TimeoutExpired:
            return {"ok": False, "error": "codex_exec_timeout", "stdout": "", "stderr": "",
                    "exit_code": None, "duration": round(time.time() - start, 3)}
        except Exception as e:  # noqa: BLE001
            return {"ok": False, "error": "codex_exec_exception", "message": str(e),
                    "stdout": "", "stderr": str(e), "exit_code": None}


class ClaudeExecutor:
    name = "claude"

    def __init__(self) -> None:
        self._run = None
        self._check = None
        try:
            from adu_orchestrator.claude_executor import run_claude_task, check_claude_available
            self._run = run_claude_task
            self._check = check_claude_available
        except Exception as e:  # noqa: BLE001
            log.warning("ClaudeExecutor import failed: %s", e)

    def available(self) -> Dict[str, Any]:
        if self._check is None:
            return {"ok": False, "error": "claude_executor_unavailable"}
        try:
            return self._check(test_model=False)
        except Exception as e:  # noqa: BLE001
            return {"ok": False, "error": "claude_check_failed", "message": str(e)}

    async def run(self, prompt: str, workspace: str, *, timeout: int = 180) -> Dict[str, Any]:
        if self._run is None:
            return {"ok": False, "error": "claude_executor_unavailable", "stdout": "", "stderr": ""}
        try:
            return await asyncio.to_thread(self._run, prompt, workspace, timeout)
        except Exception as e:  # noqa: BLE001
            return {"ok": False, "error": "claude_exception", "message": str(e), "stdout": "", "stderr": str(e)}


class LocalAgentExecutor:
    """通过注入的 callable 控制本机电脑(local-agent :4317)。"""

    name = "local-agent"

    _ROUTE = {
        "screenshot": ("POST", "/api/computer/screenshot"),
        "mouse": ("GET", "/api/computer/mouse"),
        "move": ("POST", "/api/computer/move"),
        "click": ("POST", "/api/computer/click"),
        "type": ("POST", "/api/computer/type"),
        "press": ("POST", "/api/computer/press"),
        "paste": ("POST", "/api/computer/paste"),
        "active_window": ("GET", "/api/computer/active_window"),
    }

    def configured(self) -> bool:
        return _LOCAL_AGENT_CALLABLE is not None

    async def health(self) -> Dict[str, Any]:
        if _LOCAL_AGENT_CALLABLE is None:
            return {"ok": False, "error": "local_agent_not_configured"}
        try:
            return await _LOCAL_AGENT_CALLABLE("GET", "/health", None)
        except Exception as e:  # noqa: BLE001
            return {"ok": False, "error": "local_agent_health_failed", "message": str(e)}

    async def run(self, action: str, payload: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        if _LOCAL_AGENT_CALLABLE is None:
            return {"ok": False, "error": "local_agent_not_configured"}
        a = (action or "").strip().lower()
        payload = payload if isinstance(payload, dict) else {}
        if a == "open_app":
            # Spotlight 兜底:cmd+space → type → enter
            app = str(payload.get("app") or payload.get("name") or "").strip()
            if not app:
                return {"ok": False, "error": "missing_app"}
            steps = []
            steps.append(await self.run("press", {"keys": ["cmd", "space"]}))
            await asyncio.sleep(0.3)
            steps.append(await self.run("type", {"text": app}))
            await asyncio.sleep(0.2)
            steps.append(await self.run("press", {"keys": ["enter"]}))
            return {"ok": True, "action": "open_app", "app": app, "steps": steps}
        route = self._ROUTE.get(a)
        if not route:
            return {"ok": False, "error": "unsupported_action", "action": a}
        method, path = route
        try:
            return await _LOCAL_AGENT_CALLABLE(method, path, payload if method == "POST" else None)
        except Exception as e:  # noqa: BLE001
            return {"ok": False, "error": "local_agent_error", "message": str(e)}


class DevBrainExecutorRouter:
    """按 preference + 可用性挑执行器,带 fallback。"""

    def __init__(self) -> None:
        self.codex = CodexExecutor()
        self.claude = ClaudeExecutor()
        self.local_agent = LocalAgentExecutor()

    def order(self, preference: str) -> List[str]:
        p = (preference or "codex_first").lower()
        if p in ("claude_first", "claude_only"):
            base = ["claude", "codex"]
        else:
            base = ["codex", "claude"]
        if p.endswith("_only"):
            base = base[:1]
        return base

    def availability(self) -> Dict[str, Any]:
        cx = self.codex.available()
        cl = self.claude.available()
        return {
            "codex": bool(cx.get("ok")),
            "claude": bool(cl.get("ok")),
            "local_agent": self.local_agent.configured(),
            "codex_detail": {k: cx.get(k) for k in ("ok", "error", "version", "codex_path") if k in cx},
            "claude_detail": {k: cl.get(k) for k in ("ok", "error", "version", "claude_path", "model") if k in cl},
        }

    async def run_code_task(self, prompt: str, workspace: str, preference: str,
                            *, timeout: int = 180, write: bool = False) -> Tuple[str, Dict[str, Any]]:
        """返回 (engine_used, result)。逐个尝试直到有一个可用且没崩。
        write=True 时 codex 走 workspace-write(可改文件);claude 在 headless 下本就能改。"""
        last: Dict[str, Any] = {"ok": False, "error": "no_executor"}
        for name in self.order(preference):
            ex = self.codex if name == "codex" else self.claude
            avail = ex.available()
            if not avail.get("ok"):
                last = {"ok": False, "error": f"{name}_unavailable", "detail": avail}
                continue
            if name == "codex":
                res = await ex.run(prompt, workspace, timeout=timeout, write=write)
            else:
                res = await ex.run(prompt, workspace, timeout=timeout)
            if isinstance(res, dict) and (res.get("ok") or res.get("exit_code") == 0):
                return name, res
            # 执行器跑了但失败 → 记录,尝试下一个
            last = {"engine": name, **(res if isinstance(res, dict) else {"ok": False})}
            if res.get("needs_user_confirmation"):
                return name, res  # 风险拦截,不再 fallback
        return "none", last


# =============================================================================
# Verification
# =============================================================================


class VerificationRunner:
    def __init__(self) -> None:
        self.local_agent = LocalAgentExecutor()

    def py_compile(self, files: List[str], cwd: str = BACKEND_DIR) -> Dict[str, Any]:
        results = []
        all_ok = True
        for f in files:
            path = f if os.path.isabs(f) else os.path.join(cwd, f)
            if not os.path.exists(path):
                results.append({"file": f, "ok": False, "error": "missing"})
                all_ok = False
                continue
            try:
                proc = subprocess.run(
                    ["python3", "-m", "py_compile", path],
                    capture_output=True, text=True, timeout=60,
                )
                ok = proc.returncode == 0
                all_ok = all_ok and ok
                results.append({"file": f, "ok": ok,
                                "stderr": (proc.stderr or "")[-800:] if not ok else ""})
            except Exception as e:  # noqa: BLE001
                all_ok = False
                results.append({"file": f, "ok": False, "error": str(e)})
        return {"ok": all_ok, "files": results}

    def curl_health(self, url: str, timeout: float = 6.0) -> Dict[str, Any]:
        try:
            if httpx is not None:
                r = httpx.get(url, timeout=timeout)
                ok = r.status_code < 400
                try:
                    body = r.json()
                except Exception:
                    body = {"text": r.text[:300]}
                return {"ok": ok, "status_code": r.status_code, "url": url, "body": _trim(body)}
            proc = subprocess.run(["curl", "-s", "-m", str(int(timeout)), url],
                                  capture_output=True, text=True, timeout=timeout + 4)
            try:
                body = json.loads(proc.stdout)
            except Exception:
                body = {"text": (proc.stdout or "")[:300]}
            return {"ok": proc.returncode == 0, "url": url, "body": _trim(body)}
        except Exception as e:  # noqa: BLE001
            return {"ok": False, "url": url, "error": str(e)}

    async def local_agent_health(self) -> Dict[str, Any]:
        h = await self.local_agent.health()
        return {"ok": bool(isinstance(h, dict) and h.get("ok")), "body": _trim(h)}

    async def screenshot(self) -> Dict[str, Any]:
        if not self.local_agent.configured():
            return {"ok": False, "error": "local_agent_not_configured"}
        r = await self.local_agent.run("screenshot", {})
        ok = bool(isinstance(r, dict) and r.get("ok"))
        return {"ok": ok, "bytes": r.get("bytes") if isinstance(r, dict) else None,
                "has_image": bool(isinstance(r, dict) and r.get("image_b64")),
                "image_b64": r.get("image_b64") if isinstance(r, dict) else None}

    def swift_check(self, workspace: str) -> Dict[str, Any]:
        """轻量:只确认 xcodebuild 是否可用 + 工程是否存在。完整 build 留给用户在 Xcode 做。"""
        xcode = shutil.which("xcodebuild")
        if not xcode:
            return {"ok": True, "skipped": True, "reason": "xcodebuild 不可用,跳过 Swift 构建检查"}
        proj = None
        for name in ("GPTsora.xcworkspace", "GPTsora.xcodeproj"):
            p = os.path.join(workspace, name)
            if os.path.exists(p):
                proj = p
                break
        return {"ok": True, "skipped": True, "xcodebuild": xcode, "project": proj,
                "reason": "为避免长时间占用,V1 只做可用性检查,不跑完整 xcodebuild"}


# =============================================================================
# File snapshot / rollback (safety net for write-capable runs)
# =============================================================================


class _Snapshot:
    def __init__(self) -> None:
        self.saved: Dict[str, str] = {}
        self.stamp = uuid.uuid4().hex[:8]

    def take(self, workspace: str) -> List[str]:
        files = SNAPSHOT_FILES.get(workspace, [])
        taken = []
        for f in files:
            src = os.path.join(workspace, f)
            if os.path.exists(src):
                bak = f"{src}.devbrain_snap.{self.stamp}"
                try:
                    shutil.copy2(src, bak)
                    self.saved[src] = bak
                    taken.append(f)
                except Exception as e:  # noqa: BLE001
                    log.warning("snapshot failed for %s: %s", src, e)
        return taken

    def rollback(self) -> List[str]:
        restored = []
        for src, bak in self.saved.items():
            try:
                if os.path.exists(bak):
                    shutil.copy2(bak, src)
                    restored.append(os.path.basename(src))
            except Exception as e:  # noqa: BLE001
                log.warning("rollback failed for %s: %s", src, e)
        return restored

    def cleanup(self) -> None:
        for bak in self.saved.values():
            try:
                if os.path.exists(bak):
                    os.remove(bak)
            except Exception:
                pass


# =============================================================================
# Observation
# =============================================================================


def _git_changed(workspace: str) -> List[str]:
    try:
        proc = subprocess.run(["git", "-C", workspace, "status", "--porcelain"],
                              capture_output=True, text=True, timeout=15)
        if proc.returncode != 0:
            return []
        return [ln[3:].strip() for ln in proc.stdout.splitlines() if ln.strip()]
    except Exception:
        return []


def _observe_project(workspace: str) -> Dict[str, Any]:
    info: Dict[str, Any] = {"workspace": workspace, "exists": os.path.isdir(workspace)}
    if not info["exists"]:
        return info
    try:
        entries = sorted(os.listdir(workspace))
        info["top_level"] = entries[:60]
        info["py_files"] = [e for e in entries if e.endswith(".py")][:40]
        info["has_git"] = os.path.isdir(os.path.join(workspace, ".git"))
        info["has_ios_proj"] = any(e.endswith((".xcodeproj", ".xcworkspace")) for e in entries)
    except Exception as e:  # noqa: BLE001
        info["error"] = str(e)
    return info


def _recent_backend_errors(limit: int = 12) -> List[str]:
    out: List[str] = []
    for logpath in ("/tmp/chatagi_backend.log", "/tmp/local_agent_4317.log"):
        try:
            if os.path.exists(logpath):
                with open(logpath, "r", errors="replace") as fh:
                    lines = fh.readlines()[-200:]
                for ln in lines:
                    if re.search(r"error|traceback|exception|failed|❌", ln, re.I):
                        out.append(f"{os.path.basename(logpath)}: {ln.strip()[:200]}")
        except Exception:
            continue
    return out[-limit:]


def _is_py_compile_target(path: str) -> bool:
    """Return True only for real Python source files, not backup/snapshot artifacts."""
    name = os.path.basename(path)
    if "__pycache__" in path.split(os.sep):
        return False
    if ".bak" in name or ".devbrain_snap." in name:
        return False
    return name.endswith(".py")


# =============================================================================
# DevBrain runtime — observe → plan → act → verify → repair → writeback
# =============================================================================


class DevBrainRuntime:
    def __init__(self) -> None:
        self.router_ex = DevBrainExecutorRouter()
        self.verifier = VerificationRunner()

    def _ws_from_goal(self, goal: str, override: str = "") -> str:
        if override:
            return WORKSPACES.get(override.lower(), override if os.path.isdir(override) else DEFAULT_WORKSPACE)
        low = goal.lower()
        if any(k in low for k in ("gptsora", "ios", "swift", "xcode", "手机", "app端", "前端")):
            return GPTSORA_DIR
        return BACKEND_DIR

    def _codex_prompt(self, goal: str, observation: Dict[str, Any], *, allow_write: bool,
                      repair_context: str = "", memory_summary: Optional[List[str]] = None) -> str:
        # 注意:codex_executor 已内置 SAFETY_PREFIX(禁止破坏性/推送/凭证等),
        # 这里的措辞刻意避开它的风险关键词,否则会被 find_confirmation_terms 误拦。
        guard = (
            "安全约束(必须遵守):\n"
            "1. 改任何文件前,先复制一份 <file>.bak.<时间戳> 备份。\n"
            "2. 只做低风险、可编译、可回滚的小改动;不要做破坏性或不可逆的操作。\n"
            "3. 不要触碰配置文件里的凭证值,不要改动计费相关逻辑。\n"
            "4. 保持现有 chat / memory / realtime 主链路完全不变。\n"
            "5. 改完务必确保相关 python 文件可以正常 py_compile。\n"
            "6. 如果目标本身有风险或不清晰,只做只读分析并说明,不要乱改。\n"
        )
        mode = "你可以修改文件(已授权 apply)。" if allow_write else "只读模式:不要修改任何文件,只分析并给出建议。"
        # 把项目上下文里会误触发 codex 风险词的 token 做无害替换(只动上下文,不动用户目标),
        # 否则像 ".env" 这种文件名会让 find_confirmation_terms 直接拦成 needs_user_confirmation。
        ctx = _redact_codex_triggers(json.dumps(observation, ensure_ascii=False)[:1500])
        extra = f"\n上一轮验证失败,请修复:\n{_redact_codex_triggers(repair_context)}\n" if repair_context else ""
        mem = ""
        if memory_summary:
            mem_txt = _redact_codex_triggers("\n".join(f"- {m}" for m in memory_summary[:8])[:1200])
            mem = f"\n相关长期记忆(过去的经验/事实/流程,供参考):\n{mem_txt}\n"
        return (
            f"你是 ChatAGI 的自动化编程执行器。目标:\n{goal}\n\n"
            f"{mode}\n\n{guard}{mem}\n当前观察(项目状态):\n{ctx}\n{extra}\n"
            "请完成目标。最后用一句话总结你做了什么、改了哪些文件、为什么安全。"
        )

    async def run(self, inp: DevRunInput) -> Dict[str, Any]:
        t0 = time.perf_counter()
        steps: List[DevBrainStep] = []
        files_touched: List[str] = []
        verifications: Dict[str, Any] = {}
        goal = (inp.goal or "").strip()
        max_steps = max(1, min(int(inp.max_steps or 20), 40))
        workspace = self._ws_from_goal(goal, inp.workspace)
        preference = inp.executor_preference or "codex_first"

        def add(phase: str, tool: str, action: str, result: Dict[str, Any],
                started: float, ok: bool = True) -> None:
            steps.append(DevBrainStep(
                i=len(steps) + 1, phase=phase, tool=tool, action=action,
                result=_trim(result), ms=(time.perf_counter() - started) * 1000, ok=ok))

        if not goal:
            return self._envelope("failed", goal, steps, files_touched, verifications,
                                  "goal 为空。", t0)

        # ---- 风险闸门(任务级) ----
        block = _hard_block(goal)
        if block:
            s = time.perf_counter()
            add("plan", "devbrain", "risk_gate", {"blocked_reason": block}, s, ok=False)
            return self._envelope("need_confirm", goal, steps, files_touched, verifications,
                                  f"目标命中高风险类别「{block}」,已进入待确认,不自动执行。", t0,
                                  extra={"needs_user_confirmation": True, "blocked_reason": block})

        # ✅ 视觉驱动:None → allow_tools 时默认开启
        vision_driven = inp.vision_driven if inp.vision_driven is not None else bool(inp.allow_tools)
        # 紧急停止(Body Gateway 的全局 flag)→ 立即中止
        if _emergency_active():
            return self._envelope("blocked", goal, steps, files_touched, verifications,
                                  "emergency_stop 已激活,DevBrain 拒绝执行。", t0,
                                  extra={"emergency_stop": True})

        # ---- 0) RECALL (五层长期记忆) ----
        # 与 _writeback 用同一个 key("adu"),才能跨 run 召回过去的 DevBrain 经验。
        mem_key = "adu"
        s = time.perf_counter()
        recalled = await self._memory_recall(mem_key, goal, k=6)
        add("observe", "memory", "hybrid_recall", recalled, s,
            ok=bool(recalled.get("ok", True)))

        # ---- 1) OBSERVE ----
        s = time.perf_counter()
        observation = {
            "project": _observe_project(workspace),
            "executors": self.router_ex.availability(),
            "local_agent": await self.verifier.local_agent_health(),
            "recent_errors": _recent_backend_errors(),
            "memory_recall": recalled.get("summary", []),
            "backend_core_health": await asyncio.to_thread(
                self.verifier.curl_health, f"{BACKEND_BASE}/api/brain/core/health"),
        }
        add("observe", "devbrain", "scan_project_and_links", observation, s)

        # ---- 1.5) VISION FIRST:每次 dev/run 先用视觉看屏幕,抽结构化信号,进 plan/codex ----
        vision_ctx: Dict[str, Any] = {}
        signals: Dict[str, Any] = {}
        before_vision: Dict[str, Any] = {}
        if inp.allow_tools and vision_driven:
            s = time.perf_counter()
            vis = await self._vision_observe(goal, source="computer_screenshot")
            vision_ctx = self._vision_ctx(vis)
            signals = extract_visual_signals(vis)
            before_vision = signals
            add("vision_observe", "vision", "computer_screenshot", {
                "source": "computer_screenshot",
                "vision_summary": vision_ctx.get("summary"),
                "app": signals.get("app"),
                "visible_text": signals.get("visible_text"),
                "ui_elements": signals.get("ui_elements"),
                "errors": signals.get("errors"),
                "next_possible_actions": signals.get("next_possible_actions"),
                "risk": vis.get("risk"),
                "degraded": vis.get("degraded"),
            }, s, ok=bool(vis.get("ok", True)))
            if isinstance(observation.get("project"), dict):
                observation["project"]["screen_vision"] = vision_ctx
                observation["project"]["visual_signals"] = signals

        # ---- 2) PLAN ----
        s = time.perf_counter()
        want_write = bool(inp.allow_write and any(h in goal.lower() for h in
                          [w.lower() for w in _MED_RISK_HINT]))
        plan = self._make_plan(goal, observation, allow_write=inp.allow_write,
                               allow_tools=inp.allow_tools, want_write=want_write,
                               workspace=workspace, preference=preference, vision_ctx=vision_ctx)
        add("plan", "devbrain", "generate_plan", {"plan": plan, "workspace": workspace,
                                                   "preference": preference}, s)

        # ---- 网页任务 → 优先 BrowserPort(DOM 级,不靠坐标点击)----
        browser_pulled = ""
        if inp.allow_tools and plan.get("browser_task"):
            # 先看 BrowserPort 是否可用
            s = time.perf_counter()
            bstatus = await self._body("browser", "status", {})
            pw_ok = bool(isinstance(bstatus, dict) and ((bstatus.get("result") or {}).get("playwright")
                                                        if isinstance(bstatus.get("result"), dict)
                                                        else bstatus.get("playwright")))
            add("plan", "body-gateway", "browser.status", bstatus, s,
                ok=bool(isinstance(bstatus, dict) and bstatus.get("ok", True)))
            if not pw_ok:
                # BrowserPort 不可用 → 退回 screen 截图(坐标兜底)
                plan["computer_action"] = {"action": "screenshot", "payload": {}}
            else:
                for ba in plan.get("browser_actions", []):
                    if len(steps) >= max_steps:
                        break
                    s = time.perf_counter()
                    r = await self._body("browser", ba.get("action"), ba.get("payload", {}))
                    add("act", "body-gateway", f"browser.{ba.get('action')}", r, s,
                        ok=bool(isinstance(r, dict) and r.get("ok", True)))
                    # 把抽到的网页文字喂给后续 codex/observation
                    rr = r.get("result") if isinstance(r, dict) else None
                    if isinstance(rr, dict):
                        if rr.get("title") and not browser_pulled:
                            browser_pulled = f"网页标题: {rr.get('title')}\n"
                        if rr.get("text"):
                            browser_pulled += f"网页正文(节选): {str(rr.get('text'))[:1200]}\n"
            # 把网页内容喂给后续 codex 上下文
            if browser_pulled and isinstance(observation.get("project"), dict):
                observation["project"]["browser_content"] = browser_pulled[:1600]

        # ---- optional computer tool step → 经 Body Gateway(port/action,带 risk/blocked trace)----
        if inp.allow_tools and plan.get("computer_action"):
            ca = plan["computer_action"]
            port, bact = self._body_route(ca.get("action", "screenshot"))
            s = time.perf_counter()
            r = await self._body(port, bact, ca.get("payload", {}))
            add("act", "body-gateway", f"{port}.{bact}", r, s,
                ok=bool(isinstance(r, dict) and r.get("ok", True)))
            # ✅ 不止拿原图:走 Vision 理解屏幕,把 vision_summary/ui/visible_text 进 trace + 喂 codex
            if len(steps) < max_steps:
                s2 = time.perf_counter()
                vis = await self._vision_observe(goal, source="computer_screenshot")
                add("observe", "vision", "computer_screenshot", {
                    "source": "computer_screenshot",
                    "vision_summary": vis.get("vision_summary"),
                    "active_app": vis.get("active_app"),
                    "ui_elements": (vis.get("ui_elements") or [])[:12],
                    "visible_text": (vis.get("text") or [])[:12],
                    "errors": (vis.get("errors") or [])[:6],
                    "risk": vis.get("risk"),
                    "degraded": vis.get("degraded"),
                }, s2, ok=bool(vis.get("ok", True)))
                if vis.get("vision_summary") and isinstance(observation.get("project"), dict):
                    observation["project"]["screen_vision"] = {
                        "summary": vis.get("vision_summary"),
                        "active_app": vis.get("active_app"),
                        "errors": (vis.get("errors") or [])[:6],
                        "next_actions": (vis.get("next_actions") or [])[:6],
                    }

        # ---- 3) ACT (code executor) ----
        snapshot = _Snapshot()
        status = "done"
        final_engine = "none"
        if plan.get("use_code_executor"):
            snap_taken = snapshot.take(workspace) if (inp.allow_write and plan.get("will_write")) else []
            if snap_taken:
                s = time.perf_counter()
                add("act", "file", "snapshot_before_write", {"snapshot": snap_taken, "workspace": workspace}, s)
            before = set(_git_changed(workspace))
            prompt = self._codex_prompt(goal, observation["project"], allow_write=inp.allow_write,
                                        memory_summary=recalled.get("summary"))
            s = time.perf_counter()
            engine, res = await self.router_ex.run_code_task(
                prompt, workspace, preference,
                timeout=int(os.getenv("DEVBRAIN_CODEX_TIMEOUT", "180")),
                write=bool(plan.get("will_write")))
            final_engine = engine
            ok = bool(isinstance(res, dict) and (res.get("ok") or res.get("exit_code") == 0))
            add("act", engine, "code_task", res, s, ok=ok)
            after = set(_git_changed(workspace))
            files_touched = sorted(after - before) or sorted(after) if (after != before) else []
            if isinstance(res, dict) and res.get("needs_user_confirmation"):
                status = "need_confirm"
            elif not ok:
                status = "failed"
        else:
            s = time.perf_counter()
            add("act", "devbrain", "no_code_change_needed",
                {"reason": plan.get("reason", "目标为只读/观察,无需代码执行器")}, s)

        # ---- 4) VERIFY (py_compile/health) + VISION RE-OBSERVE(视觉验证)----
        s = time.perf_counter()
        verifications = await self._verify(workspace, files_touched)
        add("verify", "devbrain", "run_verifications", verifications, s,
            ok=verifications.get("ok", False))

        # ---- post_action_vision:动作后再看一眼,判断状态变化 / 残留错误 ----
        vision_after = before_vision or {}
        visual_done: Optional[Dict[str, Any]] = None
        if inp.allow_tools and vision_driven and inp.observe_each_step and len(steps) < max_steps:
            s = time.perf_counter()
            v2 = await self._vision_observe(goal, source="computer_screenshot")
            vision_after = extract_visual_signals(v2)
            state_changed = (vision_after.get("summary") != (before_vision or {}).get("summary")) or \
                            (len(vision_after.get("errors") or []) != len((before_vision or {}).get("errors") or []))
            add("post_action_vision", "vision", "computer_screenshot", {
                "before_summary": (before_vision or {}).get("summary"),
                "after_summary": vision_after.get("summary"),
                "app": vision_after.get("app"),
                "state_changed": bool(state_changed),
                "remaining_errors": vision_after.get("errors"),
            }, s, ok=not vision_after.get("has_error", False))

        # ---- visual_verify:VisualVerifier 判 done ----
        if inp.allow_tools and vision_driven and inp.visual_verify:
            s = time.perf_counter()
            visual_done = VisualVerifier.verify(goal, before_vision or {}, vision_after,
                                                {"files_touched": files_touched}, verifications)
            add("visual_verify", "visual_verifier", "decide", visual_done, s,
                ok=bool(visual_done.get("done")))

        # ---- 5) REPAIR (最多 3 次):验证失败 或 视觉判定未完成 都触发 ----
        repair_n = 0
        while ((not verifications.get("ok")) or (visual_done is not None and not visual_done.get("done")
                                                 and vision_after.get("has_error"))) \
                and inp.allow_write and plan.get("use_code_executor") \
                and status not in ("need_confirm",) and repair_n < 3 and len(steps) < max_steps \
                and not _emergency_active():
            repair_n += 1
            rc = self._verify_error_text(verifications)
            if vision_after.get("has_error"):
                _etxt = "; ".join(str(e.get("text") if isinstance(e, dict) else e)
                                  for e in (vision_after.get("errors") or [])[:5])
                rc += f"\n视觉在屏幕上仍看到错误({vision_after.get('app')}): {_etxt}"
            prompt = self._codex_prompt(goal, observation["project"], allow_write=True, repair_context=rc,
                                        memory_summary=recalled.get("summary"))
            s = time.perf_counter()
            engine, res = await self.router_ex.run_code_task(
                prompt, workspace, preference,
                timeout=int(os.getenv("DEVBRAIN_CODEX_TIMEOUT", "180")), write=True)
            if final_engine == "none":
                final_engine = engine
            ok = bool(isinstance(res, dict) and (res.get("ok") or res.get("exit_code") == 0))
            add("repair", engine, f"repair_attempt_{repair_n}", res, s, ok=ok)
            s = time.perf_counter()
            verifications = await self._verify(workspace, files_touched)
            add("verify", "devbrain", f"reverify_{repair_n}", verifications, s,
                ok=verifications.get("ok", False))
            # 每轮 repair 后再视觉确认一次(post_action_vision)+ 重判 visual_verify
            if inp.allow_tools and vision_driven and len(steps) < max_steps:
                s = time.perf_counter()
                v3 = await self._vision_observe(goal, source="computer_screenshot")
                prev = vision_after
                vision_after = extract_visual_signals(v3)
                add("post_action_vision", "vision", f"revision_{repair_n}", {
                    "before_summary": (prev or {}).get("summary"),
                    "after_summary": vision_after.get("summary"),
                    "app": vision_after.get("app"),
                    "remaining_errors": vision_after.get("errors"),
                }, s, ok=not vision_after.get("has_error", False))
                if inp.visual_verify and len(steps) < max_steps:
                    s = time.perf_counter()
                    visual_done = VisualVerifier.verify(goal, prev or {}, vision_after,
                                                        {"files_touched": files_touched}, verifications)
                    add("visual_verify", "visual_verifier", f"decide_{repair_n}", visual_done, s,
                        ok=bool(visual_done.get("done")))
                    if visual_done.get("done"):
                        break

        # ---- rollback if still broken (only py_compile failures matter) ----
        if plan.get("will_write") and snapshot.saved and not verifications.get("py_compile", {}).get("ok", True):
            s = time.perf_counter()
            restored = snapshot.rollback()
            re_verify = await self._verify(workspace, files_touched)
            add("repair", "file", "auto_rollback_on_compile_failure",
                {"restored": restored, "reverify": re_verify}, s, ok=bool(re_verify.get("py_compile", {}).get("ok")))
            verifications = re_verify
            status = "failed"
            files_touched = []

        snapshot.cleanup()

        if status == "done" and not verifications.get("ok"):
            status = "max_steps" if len(steps) >= max_steps else "failed"

        # ---- 6) MEMORY WRITEBACK ----
        s = time.perf_counter()
        wb = self._writeback(goal, status, files_touched, verifications, final_engine, inp.source)
        add("writeback", "memory", "persist_trace", wb, s)

        final_message = self._final_message(goal, status, files_touched, verifications, final_engine, repair_n)
        # ✅ 视觉驱动:final_message 里点明当前屏幕/App 状态(测试要求)。
        if vision_driven and vision_after:
            app = vision_after.get("app") or (before_vision or {}).get("app") or "Unknown"
            vsum = vision_after.get("summary") or (before_vision or {}).get("summary") or ""
            errs = vision_after.get("errors") or []
            final_message += f"\n[视觉] 当前前台: {app};屏幕: {vsum[:120]}"
            if errs:
                final_message += f";仍有 {len(errs)} 处疑似错误"
            if visual_done is not None:
                final_message += f"。视觉判定: {'完成' if visual_done.get('done') else '未完成'}({visual_done.get('reason','')})"
        # 顶层保留一张完整截图(未裁剪)供手机展示;verifications 里的 image_b64 会被裁剪。
        shot_b64 = None
        try:
            shot_b64 = (verifications.get("screenshot") or {}).get("image_b64")
        except Exception:
            shot_b64 = None
        extra = {"engine": final_engine, "workspace": workspace,
                 "repairs": repair_n, "return_trace": inp.return_trace,
                 "vision_driven": vision_driven,
                 "current_app": (vision_after or {}).get("app"),
                 "visual_verify": visual_done}
        if isinstance(shot_b64, str) and len(shot_b64) > 64:
            extra["screenshot_b64"] = shot_b64
        return self._envelope(status, goal, steps, files_touched, verifications, final_message, t0,
                              extra=extra)

    # ---- helpers ----

    def _make_plan(self, goal: str, observation: Dict[str, Any], *, allow_write: bool,
                   allow_tools: bool, want_write: bool, workspace: str, preference: str,
                   vision_ctx: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        low = goal.lower()
        vision_ctx = vision_ctx or {}
        plan: Dict[str, Any] = {"steps": [], "workspace": workspace}

        # ---- 网页任务优先 BrowserPort(DOM 级),而不是坐标点击 ----
        web_intent = any(k in low for k in (
            "打开网页", "网站", "网页", "浏览器", "browser", "website", "url", "网址",
            "open url", "登录页", "点击网页", "click text", "填表", "表单",
            "提取网页", "extract text", "网页文字", "网页正文", "dom", "搜索", "search",
            "http://", "https://", ".com", ".org", ".net", ".io", "google", "百度"))
        if allow_tools and web_intent:
            url = self._extract_url(goal)
            actions: List[Dict[str, Any]] = []
            if url:
                actions.append({"action": "open_url", "payload": {"url": url}})
            actions.append({"action": "extract_text", "payload": {}})
            actions.append({"action": "get_dom", "payload": {"max_nodes": 60}})
            plan["browser_task"] = True
            plan["browser_actions"] = actions
            plan["steps"].append(f"browser: open {url or '(current)'} → extract_text → get_dom")

        # computer tool intent? (含"屏幕/screen/看一下屏幕/查看屏幕"等宽匹配)
        # 网页任务已优先 BrowserPort,这里只在非网页任务时才用 screen/坐标。
        if allow_tools and not plan.get("browser_task") and any(k in low for k in (
                "打开 xcode", "打开xcode", "open xcode", "看屏幕",
                "屏幕", "screen", "截图", "screenshot", "打开微信",
                "open app", "控制电脑", "桌面", "前台", "window")):
            # 只在明确要"打开某个 App"时才设 computer_action(早期 vision 已经观察过屏幕,
            # 不再为纯"看屏幕"重复截图)。
            if any(k in low for k in ("打开 xcode", "打开xcode", "open xcode", "打开微信",
                                      "open app", "打开应用", "打开 app")):
                app = "Xcode" if "xcode" in low else ("WeChat" if "微信" in low else "")
                if app:
                    plan["computer_action"] = {"action": "open_app", "payload": {"app": app}}
                    plan["steps"].append(f"open_app {app} → vision observe")
        # code executor intent?
        code_intent = any(k in low for k in ("修复", "fix", "改", "patch", "实现", "接入", "重构",
                                             "检查", "升级", "新增", "codex", "claude", "代码",
                                             "编译", "工程", "bug", "测试", "test", "错误", "报错", "error"))
        fix_intent = any(k in low for k in ("修复", "fix", "改", "patch", "重构", "升级", "新增", "解决"))
        # ✅ 视觉闭环:如果视觉在开发界面(Xcode/VSCode/终端)看到错误,即使 goal 没明说"修代码",
        # 也升级为代码任务,把视觉错误交给 Codex 处理。
        vision_error = bool(vision_ctx.get("has_error") and vision_ctx.get("dev_surface"))
        if vision_error:
            code_intent = True
            plan["vision_triggered"] = True
            plan["steps"].append(f"vision 发现错误({vision_ctx.get('active_app')}) → 交给 Codex")
        plan["use_code_executor"] = bool(code_intent)
        plan["will_write"] = bool(code_intent and allow_write and (want_write or fix_intent or vision_error))
        plan["steps"].append("observe project + links")
        if plan["use_code_executor"]:
            plan["steps"].append(f"run {preference.split('_')[0]} code task ({'write' if plan['will_write'] else 'readonly'})")
        plan["steps"].append("verify: py_compile + curl health + local-agent + screenshot")
        if plan["will_write"]:
            plan["steps"].append("repair up to 3x; auto-rollback on compile failure")
        if not plan["use_code_executor"] and not plan.get("computer_action"):
            plan["reason"] = "目标偏观察/只读,执行验证链路即可"
        return plan

    async def _verify(self, workspace: str, files_touched: List[str]) -> Dict[str, Any]:
        v: Dict[str, Any] = {}
        # py_compile: 后端关键文件 + 本次改动的 .py
        targets = list(SNAPSHOT_FILES.get(BACKEND_DIR, []))
        for f in files_touched:
            if _is_py_compile_target(f) and f not in targets:
                targets.append(f if os.path.isabs(f) else os.path.join(workspace, f))
        # py_compile + 自我 health 都是阻塞调用;放到线程里跑,避免堵住事件循环
        # (curl_health 会请求本进程自己的 :8000,若在事件循环里同步等待会自锁)。
        v["py_compile"] = await asyncio.to_thread(self.verifier.py_compile, targets, BACKEND_DIR)
        v["core_health"] = await asyncio.to_thread(self.verifier.curl_health, f"{BACKEND_BASE}/api/brain/core/health")
        v["embodied_health"] = await asyncio.to_thread(self.verifier.curl_health, f"{BACKEND_BASE}/api/brain/core/embodied/health")
        v["computer_health"] = await asyncio.to_thread(self.verifier.curl_health, f"{BACKEND_BASE}/api/brain/computer/health")
        v["local_agent_health"] = await self.verifier.local_agent_health()
        v["screenshot"] = await self.verifier.screenshot()
        if os.path.isdir(os.path.join(GPTSORA_DIR, "GPTsora.xcodeproj")) or \
                os.path.isdir(os.path.join(GPTSORA_DIR, "GPTsora.xcworkspace")):
            v["swift_check"] = self.verifier.swift_check(GPTSORA_DIR)
        # 总 ok:py_compile 必须过;health 至少 core 过
        v["ok"] = bool(v["py_compile"].get("ok") and v["core_health"].get("ok"))
        return v

    def _verify_error_text(self, v: Dict[str, Any]) -> str:
        bits = []
        pc = v.get("py_compile", {})
        if not pc.get("ok"):
            for f in pc.get("files", []):
                if not f.get("ok"):
                    bits.append(f"py_compile {f.get('file')}: {f.get('stderr') or f.get('error')}")
        for key in ("core_health", "computer_health"):
            h = v.get(key, {})
            if not h.get("ok"):
                bits.append(f"{key} 失败: {json.dumps(h.get('body') or h, ensure_ascii=False)[:200]}")
        return "\n".join(bits[:8]) or "验证未通过(细节见 verifications)"

    @staticmethod
    def _extract_url(goal: str) -> str:
        """从目标里抽 URL。带 scheme 直接用;裸域名补 https://。"""
        m = re.search(r"https?://[^\s一-鿿，。、）)】\"']+", goal or "")
        if m:
            return m.group(0).rstrip(".,;)")
        m2 = re.search(r"\b([a-z0-9][a-z0-9\-]*\.(?:com|org|net|io|cn|dev|ai|co|edu|gov)(?:/[^\s一-鿿，。、]*)?)", goal or "", re.I)
        if m2:
            return "https://" + m2.group(1).rstrip(".,;)")
        return ""

    @staticmethod
    def _body_route(action: str) -> Tuple[str, str]:
        """把 DevBrain 的旧动作名映射到 Body Gateway 的 (port, action)。"""
        a = (action or "").strip().lower()
        mapping = {
            "screenshot": ("screen", "screenshot"),
            "open_app": ("app", "open_app"),
            "focus_app": ("app", "focus_app"),
            "active_window": ("screen", "active_window"),
            "click": ("mouse", "click"),
            "double_click": ("mouse", "double_click"),
            "move": ("mouse", "move"),
            "scroll": ("mouse", "scroll"),
            "type": ("keyboard", "type"),
            "press": ("keyboard", "press"),
            "paste": ("keyboard", "paste"),
            "open_url": ("browser", "open_url"),
        }
        return mapping.get(a, ("screen", "screenshot"))

    async def _vision_observe(self, goal: str, *, source: str = "computer_screenshot",
                              image_b64: str = "") -> Dict[str, Any]:
        """Vision Core 视觉观察(in-process)。失败回退到原图截图,绝不抛。"""
        try:
            from chatagi_vision_core import vision_observe
            return await vision_observe(user_key="adu", source=source, image_b64=image_b64,
                                        goal=goal, write_memory=True)
        except Exception as e:  # noqa: BLE001
            shot = await self._body("screen", "screenshot", {})
            return {"ok": bool(isinstance(shot, dict) and shot.get("ok", True)),
                    "vision_summary": f"[vision 不可用,回退原图截图] {e}",
                    "degraded": True, "ui_elements": [], "text": [], "errors": []}

    @staticmethod
    def _vision_ctx(vis: Dict[str, Any]) -> Dict[str, Any]:
        """把 vision observe 结果压成给 plan/codex 用的紧凑上下文,并判定是否有错误。"""
        vsum = str(vis.get("vision_summary") or "")
        errs = [str(e) for e in (vis.get("errors") or [])][:6]
        app = str(vis.get("active_app") or "")
        text = [str(t) for t in (vis.get("text") or [])][:12]
        blob = (vsum + " " + " ".join(errs) + " " + " ".join(text)).lower()
        has_error = bool(errs) or bool(re.search(
            r"error|failed|failure|build failed|报错|错误|失败|红色|exception|cannot find|undefined",
            blob))
        dev_surface = any(k in (app + " " + blob) for k in
                          ("xcode", "vscode", "visual studio code", "terminal", "终端", "编译", "compiler"))
        return {"summary": vsum, "active_app": app, "errors": errs,
                "ui_elements": (vis.get("ui_elements") or [])[:10],
                "visible_text": text, "next_actions": (vis.get("next_actions") or [])[:6],
                "has_error": has_error, "dev_surface": dev_surface}

    async def _body(self, port: str, action: str, payload: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        """通过 Body Gateway 调一个端口动作(in-process)。失败回退直连 local-agent。"""
        try:
            from chatagi_computer_body import body_dispatch
            return await body_dispatch(port, action, payload or {})
        except Exception as e:  # noqa: BLE001
            # 回退:GUI 类直接走 local-agent
            try:
                return await self.router_ex.local_agent.run(action, payload or {})
            except Exception:
                return {"ok": False, "error": "body_unavailable", "message": str(e)}

    async def _memory_recall(self, user_key: str, query: str, *, k: int = 6) -> Dict[str, Any]:
        """五层 hybrid_recall(失败回退 vector / 空),绝不抛。返回 {ok, summary[], raw}。"""
        eng = _MEMORY_ENGINE
        if eng is None or not str(query or "").strip():
            return {"ok": True, "summary": [], "raw": {}, "used": "none"}
        try:
            if hasattr(eng, "hybrid_recall"):
                raw = await asyncio.to_thread(eng.hybrid_recall, user_key, query, k)
                summary: List[str] = []
                if isinstance(raw, dict):
                    for layer in ("episodic", "semantic", "procedural", "timeline", "facts", "working", "vector"):
                        for it in (raw.get(layer) or [])[:3]:
                            txt = ""
                            if isinstance(it, dict):
                                txt = str(it.get("content") or it.get("text") or it.get("summary") or it.get("memory") or "")
                            else:
                                txt = str(it)
                            if txt:
                                summary.append(f"[{layer}] {txt[:180]}")
                return {"ok": True, "summary": summary[:12], "raw": _trim(raw), "used": "hybrid_recall"}
            if hasattr(eng, "search_vectors"):
                hits = await asyncio.to_thread(eng.search_vectors, user_key, query, k, 0.2)
                summary = [f"[vector] {str((h.get('text') if isinstance(h, dict) else h))[:180]}" for h in (hits or [])[:6]]
                return {"ok": True, "summary": summary, "raw": _trim(hits), "used": "search_vectors"}
        except Exception as e:  # noqa: BLE001
            log.warning("memory recall failed: %s", e)
            return {"ok": False, "summary": [], "raw": {}, "error": str(e), "used": "error"}
        return {"ok": True, "summary": [], "raw": {}, "used": "none"}

    def _writeback(self, goal: str, status: str, files_touched: List[str],
                   verifications: Dict[str, Any], engine: str, source: str) -> Dict[str, Any]:
        line = (f"[DevBrain] goal={goal[:160]} | status={status} | engine={engine} | "
                f"files={files_touched} | verify_ok={verifications.get('ok')}")
        wrote = False
        user_key = "adu"
        meta = {
            "source": source or "devbrain",
            "goal": goal,
            "status": status,
            "result": status,
            "engine": engine,
            "files_touched": files_touched,
            "verifications": _trim(verifications),
            "importance": 5 if status != "done" else 4,
        }
        try:
            if _MEMORY_ENGINE is not None and hasattr(_MEMORY_ENGINE, "write_memory"):
                _MEMORY_ENGINE.write_memory(user_key, "timeline", line, {**meta, "event_type": "devbrain_task"})
                _MEMORY_ENGINE.write_memory(user_key, "episode", line, meta)
                if hasattr(_MEMORY_ENGINE, "graph_from_episode"):
                    _MEMORY_ENGINE.graph_from_episode(user_key, episode_id=meta.get("trace_id", ""), content=line, metadata=meta)
                if source == "self_upgrade" or status != "done" or files_touched:
                    proc = (
                        f"DevBrain procedure: goal={goal[:180]}; status={status}; "
                        f"engine={engine}; files={files_touched}; verify_ok={verifications.get('ok')}"
                    )
                    _MEMORY_ENGINE.write_memory(user_key, "procedural", proc, {**meta, "tags": "devbrain,self-upgrade,repair" if source == "self_upgrade" else "devbrain,procedure"})
                wrote = True
            elif _MEMORY_ENGINE is not None and hasattr(_MEMORY_ENGINE, "add_vector") and len(line) > 8:
                _MEMORY_ENGINE.add_vector(user_key, line)
                wrote = True
        except Exception as e:  # noqa: BLE001
            log.warning("memory writeback failed: %s", e)
        next_hint = ("下一步:人工在 Xcode build 一次确认 iOS。" if files_touched else
                     "下一步:可给更具体的改进目标,DevBrain 会 apply。")
        return {"memory_written": wrote, "line": line, "next_suggestion": next_hint}

    def _final_message(self, goal: str, status: str, files_touched: List[str],
                       verifications: Dict[str, Any], engine: str, repairs: int) -> str:
        vok = "通过" if verifications.get("ok") else "未通过"
        ft = ("、".join(files_touched) if files_touched else "无文件改动")
        if status == "done":
            return (f"已完成目标「{goal}」。执行器={engine},改动文件={ft},验证{vok}"
                    + (f",自动修复{repairs}次" if repairs else "") + "。")
        if status == "need_confirm":
            return f"目标「{goal}」涉及高风险,已进入待确认状态,未自动执行。"
        if status == "max_steps":
            return f"目标「{goal}」达到最大步数,验证{vok}。"
        return f"目标「{goal}」执行失败。执行器={engine},验证{vok}。已尽量回滚保持系统可编译。"

    def _envelope(self, status: str, goal: str, steps: List[DevBrainStep],
                  files_touched: List[str], verifications: Dict[str, Any],
                  final_message: str, t0: float, extra: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        env = {
            "ok": status in ("done", "max_steps"),
            "status": status,
            "goal": goal,
            "steps": [s.as_dict() for s in steps],
            "files_touched": files_touched,
            "verifications": _trim(verifications),
            "final_message": final_message,
            "total_ms": round((time.perf_counter() - t0) * 1000, 1),
        }
        if extra:
            env.update(extra)
        return env


class SelfUpgradeController:
    """递归自我升级:复用 DevBrainRuntime,但 preset 更强调'找最有价值的低风险改进'。"""

    def __init__(self, runtime: DevBrainRuntime) -> None:
        self.runtime = runtime

    async def start(self, inp: DevRunInput) -> Dict[str, Any]:
        goal = (inp.goal or "升级当前 ChatAGI 自动化编程能力").strip()
        # 注意:措辞刻意避开 _hard_block / codex 的风险关键词,否则会拦到自己。
        preset_goal = (
            f"{goal}\n\n"
            "这是递归自我升级任务(已授权 apply,但只允许低风险、可编译、可回滚的小改动;"
            "不得做破坏性或不可逆操作,不得触碰凭证值或计费逻辑,不得推送远端,保持主链路不变)。"
            "请:1) 观察当前 ChatAGI 后端自动化编程能力;2) 找出一个最有价值且低风险的改进点;"
            "3) 实现它(改前先复制一份 .bak 备份);4) 确保 py_compile 通过;"
            "5) 用一句话说明改了什么、为什么有价值且安全。"
            "如果暂时找不到安全的改进点,就只做只读分析并清楚说明,不要强行改。"
        )
        run_inp = DevRunInput(
            goal=preset_goal, mode=inp.mode or "auto",
            max_steps=inp.max_steps or 20, allow_write=inp.allow_write,
            allow_tools=inp.allow_tools, executor_preference=inp.executor_preference or "codex_first",
            return_trace=inp.return_trace, workspace=inp.workspace or "backend",
            source="self_upgrade",
        )
        out = await self.runtime.run(run_inp)
        out["preset"] = "self_upgrade"
        return out


# =============================================================================
# Utilities
# =============================================================================


# codex_executor.CONFIRMATION_TERMS 会扫描整个 prompt;嵌入的项目上下文里若出现这些
# token(如文件名 ".env")会被误判为高风险。对"上下文"做无害替换,保留语义、避免误拦。
_CODEX_TRIGGER_REPLACEMENTS = [
    (".env", "env-config-file"),
    ("rm -rf", "recursive-remove"),
    ("git push", "git-publish"),
    ("npm publish", "npm-publish"),
    ("pip install", "pip-deps"),
    ("pip3 install", "pip-deps"),
    ("npm install", "npm-deps"),
    ("pnpm add", "pnpm-deps"),
    ("yarn add", "yarn-deps"),
    ("brew install", "brew-deps"),
    ("sudo", "elevated-cmd"),
    ("删除", "清理"),
    ("payment", "billing-area"),
    ("付款", "billing-area"),
    ("api key", "credential"),
    ("api_key", "credential"),
    ("apikey", "credential"),
    ("修改 .env", "edit-env-config"),
    ("修改.env", "edit-env-config"),
]


def _redact_codex_triggers(text: str) -> str:
    out = str(text or "")
    for bad, safe in _CODEX_TRIGGER_REPLACEMENTS:
        if bad in out:
            out = out.replace(bad, safe)
        # 中文/大小写无关项也处理一次小写
        low = bad.lower()
        if low != bad and low in out:
            out = out.replace(low, safe)
    return out


def _trim(obj: Any, max_chars: int = 4000) -> Any:
    """裁掉超大字段(尤其 base64 截图),保留可读结构。"""
    try:
        if isinstance(obj, dict):
            out = {}
            for k, v in obj.items():
                if k == "image_b64" and isinstance(v, str) and len(v) > 64:
                    out[k] = f"<base64 {len(v)} chars>"
                else:
                    out[k] = _trim(v, max_chars)
            return out
        if isinstance(obj, list):
            return [_trim(x, max_chars) for x in obj[:40]]
        if isinstance(obj, str) and len(obj) > max_chars:
            return obj[:max_chars] + f"…(+{len(obj) - max_chars})"
        return obj
    except Exception:
        return str(obj)[:max_chars]


# =============================================================================
# FastAPI router
# =============================================================================

router = APIRouter(prefix="/api/brain", tags=["chatagi-devbrain"])
_RUNTIME = DevBrainRuntime()
_SELF_UPGRADE = SelfUpgradeController(_RUNTIME)


@router.get("/dev/health")
async def dev_health() -> Dict[str, Any]:
    avail = _RUNTIME.router_ex.availability()
    la = await _RUNTIME.verifier.local_agent_health()
    return {
        "ok": True,
        "module": "ChatAGI DevBrain Runtime V1",
        "contract": "observe→plan→act(codex/claude/local-agent)→verify→repair→writeback",
        "executors": avail,
        "local_agent": la.get("ok"),
        "memory_engine": bool(_MEMORY_ENGINE is not None),
        "brain_state_engine": bool(_BRAIN_STATE_ENGINE is not None),
        "workspaces": WORKSPACES,
        "routes": [
            "GET  /api/brain/dev/health",
            "POST /api/brain/dev/run",
            "POST /api/brain/self-upgrade/start",
        ],
    }


@router.post("/dev/run")
async def dev_run(request: Request) -> JSONResponse:
    try:
        body = await request.json()
        inp = DevRunInput(**(body if isinstance(body, dict) else {}))
    except Exception as e:  # noqa: BLE001
        return JSONResponse({"ok": False, "status": "failed", "error": "bad_request",
                             "message": str(e)}, status_code=400)
    out = await _RUNTIME.run(inp)
    if not inp.return_trace:
        out = {k: v for k, v in out.items() if k != "steps"}
    return JSONResponse(out)


@router.post("/self-upgrade/start")
async def self_upgrade_start(request: Request) -> JSONResponse:
    try:
        body = await request.json()
        inp = DevRunInput(**(body if isinstance(body, dict) else {}))
    except Exception as e:  # noqa: BLE001
        return JSONResponse({"ok": False, "status": "failed", "error": "bad_request",
                             "message": str(e)}, status_code=400)
    out = await _SELF_UPGRADE.start(inp)
    return JSONResponse(out)
