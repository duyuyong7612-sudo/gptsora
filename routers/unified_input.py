# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-c6102e71ac63cc221571942e651ae8c7810e88481d86e1dd2727668141c07e0d"
# Source-SHA256: "7bc3cd03cf56347baf3dfb18299351942109ed2e2ae96c303167d62180085dcb"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
routers/unified_input.py

统一输入通道 (Unified Input Channel)
=====================================
POST /api/adu/unified/input —— 所有输入源的单一入口：
    text | recorded_audio | realtime_voice | image | video |
    computer_button | coding_button | robot_button

设计原则
--------
1. 普通文本/语音转写后/图片视频摘要 → 转发到既有聊天逻辑 (/chat/prepare)。
2. 电脑控制 → 只走唯一的 ComputerGateway -> LOCAL_COMPUTER_API_URL ->
   local_computer_agent:4317。任何电脑动作都不允许绕过这个 gateway。
3. 自动化编程 → 转发到既有 Codex/Claude executor (/api/adu/automation/run)。
   若编程任务需要看屏幕/点击/输入，也必须经由 ComputerGateway，而不是直连。
4. robot_button 只是 surface=robot / intent_hint=robot，永不直接控制电脑
   （即使带了 requires_computer 也会被忽略，强制走普通 chat/intent）。

旧 endpoint（/chat/prepare、/chat/events、/api/brain/computer/*、
/api/adu/orchestrator/*、/api/adu/codex/*、/api/adu/automation/*）不删除，
它们降级为 adapter：仍可被内部转发调用，但新前端只调 /api/adu/unified/input。
"""
from __future__ import annotations

import os
from typing import Any, Dict, List, Optional

try:  # 网络客户端（项目已依赖 httpx）
    import httpx  # type: ignore
except Exception:  # pragma: no cover
    httpx = None  # type: ignore

try:
    from fastapi import APIRouter  # type: ignore
    from fastapi.responses import JSONResponse  # type: ignore
    from pydantic import BaseModel, Field  # type: ignore
except Exception:  # pragma: no cover - 允许在无 FastAPI 环境下被 py_compile
    APIRouter = None  # type: ignore
    JSONResponse = None  # type: ignore
    BaseModel = object  # type: ignore

    def Field(default=None, **_kw):  # type: ignore
        return default


# ─────────────────────────────────────────────────────────────
# ComputerGateway —— 唯一允许触达本机电脑的封装
#   内部只调用 LOCAL_COMPUTER_API_URL（默认 local_computer_agent:4317）。
# ─────────────────────────────────────────────────────────────
def _computer_root() -> str:
    """解析本机电脑代理根地址。统一回退到 4317，并容忍带 /api/computer 后缀的配置。"""
    raw = (
        os.getenv("LOCAL_COMPUTER_API_URL")
        or os.getenv("LOCAL_AGENT_BASE_URL")
        or os.getenv("AI_BRAIN_LOCAL_AGENT_BASE_URL")
        or os.getenv("COMPUTER_AGENT_BASE_URL")
        or "http://127.0.0.1:4317"
    ).strip().rstrip("/")
    if raw.endswith("/api/computer"):
        raw = raw[: -len("/api/computer")]
    return raw


def _computer_token() -> str:
    return (
        os.getenv("LOCAL_COMPUTER_API_TOKEN")
        or os.getenv("LOCAL_AGENT_TOKEN")
        or os.getenv("AI_BRAIN_LOCAL_AGENT_TOKEN")
        or os.getenv("COMPUTER_AGENT_TOKEN")
        or ""
    ).strip()


class ComputerGateway:
    """所有电脑动作的唯一出口。内部只 HTTP 调用 local_computer_agent:4317。"""

    SUPPORTED = {
        "health",
        "screenshot",
        "click",
        "type",
        "paste",
        "press",
        "mouse_move",
        "active_window",
        "mouse_position",
    }

    def __init__(
        self,
        root: Optional[str] = None,
        token: Optional[str] = None,
        timeout: float = 30.0,
    ) -> None:
        self._root = (root or _computer_root()).rstrip("/")
        self._token = token if token is not None else _computer_token()
        self._timeout = timeout

    @property
    def base_url(self) -> str:
        return self._root

    def _headers(self) -> Dict[str, str]:
        h = {"Content-Type": "application/json"}
        if self._token:
            h["Authorization"] = f"Bearer {self._token}"
        return h

    async def _request(
        self, method: str, path: str, body: Optional[Dict[str, Any]] = None
    ) -> Dict[str, Any]:
        if httpx is None:
            return {"ok": False, "error": "httpx_not_available"}
        url = f"{self._root}{path}"
        try:
            async with httpx.AsyncClient(timeout=self._timeout) as client:
                if method.upper() == "GET":
                    r = await client.get(url, headers=self._headers())
                else:
                    r = await client.request(
                        method.upper(), url, headers=self._headers(), json=body or {}
                    )
            ctype = (r.headers.get("content-type") or "").lower()
            if "application/json" in ctype:
                data: Any = r.json()
            else:
                data = {"status_code": r.status_code, "body": (r.text or "")[:2000]}
            return {
                "ok": r.status_code < 400,
                "status_code": r.status_code,
                "via": url,
                "data": data,
            }
        except Exception as e:  # 4317 未启动/不可达时优雅返回，不抛异常
            return {
                "ok": False,
                "error": "local_agent_unreachable",
                "via": url,
                "detail": str(e),
            }

    # ── 显式动作（与 local_agent_4317.py 的 /api/computer/* 一一对应）──
    async def health(self) -> Dict[str, Any]:
        return await self._request("GET", "/health")

    async def screenshot(self, payload: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        return await self._request("POST", "/api/computer/screenshot", payload or {})

    async def click(self, payload: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        return await self._request("POST", "/api/computer/click", payload or {})

    async def type(self, payload: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        return await self._request("POST", "/api/computer/type", payload or {})

    async def paste(self, payload: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        return await self._request("POST", "/api/computer/paste", payload or {})

    async def press(self, payload: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        return await self._request("POST", "/api/computer/press", payload or {})

    async def mouse_move(self, payload: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        return await self._request("POST", "/api/computer/move", payload or {})

    async def active_window(self) -> Dict[str, Any]:
        return await self._request("GET", "/api/computer/active_window")

    async def mouse_position(self) -> Dict[str, Any]:
        return await self._request("GET", "/api/computer/mouse")

    async def dispatch(
        self, action: str, payload: Optional[Dict[str, Any]] = None
    ) -> Dict[str, Any]:
        act = (action or "").strip().lower()
        mapping = {
            "health": self.health,
            "screenshot": self.screenshot,
            "click": self.click,
            "type": self.type,
            "type_text": self.type,
            "paste": self.paste,
            "press": self.press,
            "press_keys": self.press,
            "mouse_move": self.mouse_move,
            "move": self.mouse_move,
            "active_window": self.active_window,
            "mouse_position": self.mouse_position,
            "mouse": self.mouse_position,
        }
        fn = mapping.get(act)
        if fn is None:
            return {
                "ok": False,
                "error": "unsupported_computer_action",
                "action": act,
                "supported": sorted(self.SUPPORTED),
            }
        if act in ("health", "active_window", "mouse_position", "mouse"):
            return await fn()
        return await fn(payload or {})


def get_computer_gateway() -> ComputerGateway:
    """每次新建，以便测试/部署时实时读取环境变量。"""
    return ComputerGateway()


# 文本→动作 的轻量关键词（仅用于电脑控制页的只读快捷动作 / 编程意图提示）
_COMPUTER_SCREENSHOT_HINTS = (
    "screenshot", "截屏", "截图", "看屏", "看看屏幕",
    "刷新画面", "刷新电脑", "刷新屏幕", "电脑画面", "屏幕画面", "刷新电脑画面",
)
_CODING_HINTS = (
    "检查工程", "工程目录", "项目目录", "跑工程", "改代码", "修代码", "重构",
    "代码", "编译", "build", "repo", "仓库", "bug", "codex", "claude",
    "函数", "server_session", ".py", ".swift",
)


# ─────────────────────────────────────────────────────────────
# 内部自转发（把旧 endpoint 当作 adapter 调用）
# ─────────────────────────────────────────────────────────────
def _self_base() -> str:
    return (
        os.getenv("UNIFIED_SELF_BASE_URL")
        or os.getenv("SELF_BASE_URL")
        or f"http://127.0.0.1:{os.getenv('PORT', '8000')}"
    ).strip().rstrip("/")


async def _forward_self(
    method: str,
    path: str,
    body: Optional[Dict[str, Any]] = None,
    headers: Optional[Dict[str, str]] = None,
) -> Dict[str, Any]:
    if httpx is None:
        return {"ok": False, "error": "httpx_not_available"}
    url = f"{_self_base()}{path}"
    try:
        async with httpx.AsyncClient(timeout=180.0) as client:
            r = await client.request(
                method.upper(), url, json=body or {}, headers=headers or {}
            )
        ctype = (r.headers.get("content-type") or "").lower()
        if "application/json" in ctype:
            data: Any = r.json()
        else:
            data = {"status_code": r.status_code, "body": (r.text or "")[:2000]}
        if isinstance(data, dict):
            data.setdefault("_adapter_status", r.status_code)
            return data
        return {"ok": r.status_code < 400, "status_code": r.status_code, "data": data}
    except Exception as e:
        return {"ok": False, "error": "self_forward_failed", "via": url, "detail": str(e)}


# ─────────────────────────────────────────────────────────────
# Router
# ─────────────────────────────────────────────────────────────
if APIRouter is not None:
    router = APIRouter(prefix="/api/adu/unified", tags=["adu-unified"])

    class UnifiedInput(BaseModel):  # type: ignore[misc]
        source: str = Field(
            ...,
            description=(
                "text | recorded_audio | realtime_voice | image | video | "
                "computer_button | coding_button | robot_button"
            ),
        )
        surface: Optional[str] = Field(default="home")  # home|computer|coding|robot|voice|media
        text: Optional[str] = Field(default="")
        media_refs: Optional[List[Any]] = Field(default=None)
        session_id: Optional[str] = Field(default=None)
        user_id: Optional[str] = Field(default=None)
        intent_hint: Optional[str] = Field(
            default=None, description="chat|computer_control|coding|robot|search|file"
        )
        requires_computer: Optional[bool] = Field(default=False)
        requires_code_agent: Optional[bool] = Field(default=False)
        requires_realtime: Optional[bool] = Field(default=False)
        # 透传字段（电脑动作 / 编程任务用）
        action: Optional[str] = Field(default=None)
        payload: Optional[Dict[str, Any]] = Field(default=None)
        project_id: Optional[str] = Field(default=None)
        project_dir: Optional[str] = Field(default=None)
        model: Optional[str] = Field(default=None)
        engine: Optional[str] = Field(default=None)

    def _resolve_route(inp: "UnifiedInput") -> str:
        src = (inp.source or "").strip().lower()
        hint = (inp.intent_hint or "").strip().lower()

        # 守卫：机器人按钮永不直接控制电脑
        if src == "robot_button":
            return "chat"

        if inp.requires_computer or hint == "computer_control" or src == "computer_button":
            return "computer"
        if inp.requires_code_agent or hint == "coding" or src == "coding_button":
            return "coding"
        if src in ("image", "video"):
            return "media"
        if src in ("recorded_audio", "realtime_voice"):
            return "voice"
        return "chat"

    async def _handle_computer(inp: "UnifiedInput") -> Any:
        # 守卫：电脑控制路由【绝不】启动 Codex/Claude executor。
        #       这里只会调用 ComputerGateway -> local_agent:4317。
        gw = get_computer_gateway()
        action = (inp.action or "").strip().lower()
        payload = inp.payload or {}
        t = (inp.text or "").lower()

        # 进入电脑控制页 / 显式截图 → 统一当作 screenshot
        if action in ("open_computer_control", "open", "screenshot"):
            action = "screenshot"

        # 仅文本时，做极小的只读动作识别；需要坐标/文本参数的动作必须显式 action+payload
        if not action:
            if any(k in t for k in _COMPUTER_SCREENSHOT_HINTS):
                action = "screenshot"
            elif "active_window" in t or "当前窗口" in t or "前台窗口" in t:
                action = "active_window"
            elif "鼠标位置" in t or ("mouse" in t and "position" in t):
                action = "mouse_position"

        # 仍无具体电脑动作：若文本像编程任务，只“建议”切到自动化编程（不执行 Codex）
        if not action:
            if inp.text and any(k in t for k in _CODING_HINTS):
                return {
                    "ok": True,
                    "type": "coding_task",
                    "route": "computer",
                    "source": inp.source,
                    "surface": inp.surface,
                    "executed": False,       # ✅ 仅建议，未运行 Codex/Claude
                    "suggestion": True,
                    "intent": "coding",
                    "text": inp.text,
                    "message": (
                        "检测到编程意图。已建议切换到自动化编程"
                        "（需在编程卡片里点 Run 才执行，不会自动跑 Codex）。"
                    ),
                    "gateway": gw.base_url,
                }
            return JSONResponse(
                {
                    "ok": False,
                    "type": "error",
                    "route": "computer",
                    "source": inp.source,
                    "error": "need_action",
                    "message": (
                        "未识别为具体电脑动作。请提供 action 或更明确的电脑指令"
                        "（电脑动作只走 ComputerGateway -> local_agent:4317）。"
                    ),
                    "supported_actions": sorted(ComputerGateway.SUPPORTED),
                    "gateway": gw.base_url,
                },
                status_code=400,
            )

        gw_result = await gw.dispatch(action, payload)
        # 解包：把本机 agent 的真实 JSON 提到顶层 result（截图的 image_b64 直接可取）
        inner = gw_result.get("data") if isinstance(gw_result, dict) else None
        unwrapped = inner if isinstance(inner, dict) else gw_result
        rtype = "computer_screenshot" if action == "screenshot" else "computer_action"
        return {
            "ok": bool(gw_result.get("ok")) if isinstance(gw_result, dict) else False,
            "type": rtype,
            "route": "computer",
            "source": inp.source,
            "surface": inp.surface,
            "action": action,
            "gateway": gw.base_url,
            "result": unwrapped,       # screenshot: {"image_b64": ...}
            "raw_gateway": gw_result,  # 调试用：含 status_code / via
        }

    async def _handle_coding(inp: "UnifiedInput") -> Any:
        body: Dict[str, Any] = {"task": inp.text or "", "timeout": 900}
        if inp.project_id:
            body["project_id"] = inp.project_id
        if inp.project_dir:
            body["project_dir"] = inp.project_dir
        if inp.engine:
            body["engine"] = inp.engine
        if inp.model:
            body["model"] = inp.model
        res = await _forward_self("POST", "/api/adu/automation/run", body)
        ok = res.get("ok", True) if isinstance(res, dict) else True
        return {
            "ok": bool(ok),
            "type": "coding_task",
            "route": "coding",
            "source": inp.source,
            "surface": inp.surface,
            "executed": True,
            "adapter": "/api/adu/automation/run",
            "note": "编程任务如需操作电脑，必须经后端 ComputerGateway -> local_agent:4317。",
            "result": res,
        }

    async def _handle_chat(inp: "UnifiedInput", route_label: str = "chat") -> Any:
        text = inp.text or ""
        body: Dict[str, Any] = {"messages": [{"role": "user", "content": text}]}
        if inp.session_id:
            body["conversation_id"] = inp.session_id
        if inp.model:
            body["model"] = inp.model
        if inp.media_refs:
            body["attachments"] = inp.media_refs
        if inp.user_id:
            body["user_id"] = inp.user_id
        headers: Dict[str, str] = {}
        if inp.user_id:
            headers["x-user-id"] = str(inp.user_id)
        res = await _forward_self("POST", "/chat/prepare", body, headers=headers)
        ok = res.get("ok", True) if isinstance(res, dict) else True
        return {
            "ok": bool(ok),
            "type": "chat",
            "route": route_label,
            "source": inp.source,
            "surface": inp.surface,
            "adapter": "/chat/prepare",
            "result": res,
        }

    async def _handle_media(inp: "UnifiedInput") -> Any:
        # 图片/视频：media_refs 已由客户端上传形成；这里并入聊天上下文（attachments）。
        return await _handle_chat(inp, route_label="media")

    async def _handle_voice(inp: "UnifiedInput") -> Any:
        # 录音/实时语音：STT 在客户端或 realtime 通道完成；带文本则按 chat 处理。
        if (inp.text or "").strip():
            return await _handle_chat(inp, route_label="voice")
        return {
            "ok": True,
            "type": "chat",
            "route": "voice",
            "source": inp.source,
            "surface": inp.surface,
            "message": (
                "录音/实时语音请先在客户端或 realtime 通道完成转写；"
                "转成文本后再次提交到 /api/adu/unified/input。"
            ),
            "requires_realtime": bool(inp.requires_realtime),
        }

    @router.get("/health")
    async def unified_health() -> Dict[str, Any]:
        gw = get_computer_gateway()
        return {
            "ok": True,
            "service": "unified_input",
            "endpoint": "/api/adu/unified/input",
            "computer_gateway": gw.base_url,
            "self_base": _self_base(),
            "supported_computer_actions": sorted(ComputerGateway.SUPPORTED),
        }

    @router.post("/input")
    async def unified_input(inp: "UnifiedInput") -> Any:
        route = _resolve_route(inp)
        if route == "computer":
            return await _handle_computer(inp)
        if route == "coding":
            return await _handle_coding(inp)
        if route == "media":
            return await _handle_media(inp)
        if route == "voice":
            return await _handle_voice(inp)
        return await _handle_chat(inp)

else:  # pragma: no cover
    router = None  # type: ignore
