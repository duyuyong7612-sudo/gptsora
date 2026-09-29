# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-f2d781d035fec876d0e4d09ddb42e8cc89fc6766775d77df9eff4615f96428b1"
# Source-SHA256: "87df16a8e81bc5d1014ba551adf15ce3c83d41a04ac47893ae2cb6acf96d398e"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
本机最小测试服务：把 server_session-104.py 里的 /api/brain/adu/act 抽出来本机跑。
- 复制了真实的 _computer_action_from_goal 解析逻辑（保真）
- _brain_computer_execute_action 用 stub 假装成功（不调 local-agent）
- 监听 127.0.0.1:8765
"""

from __future__ import annotations

import re
from typing import Any, Dict, Optional

from fastapi import FastAPI, HTTPException, Request

try:
    from .adu_planner_router import router as adu_planner_router
except ImportError:
    from adu_planner_router import router as adu_planner_router

app = FastAPI(title="adu_act local test")
app.include_router(adu_planner_router)


async def _request_json_or_empty(request: Request) -> Dict[str, Any]:
    try:
        data = await request.json()
        if isinstance(data, dict):
            return data
        return {}
    except Exception:
        return {}


# ---- 与 server_session-104.py 的 _computer_action_from_goal 完全对齐 ----
def _extract_app_to_open_from_goal(text: str) -> Optional[Dict[str, Any]]:
    # 测试场景里不打开应用：返回 None，让后续基础动作分支接管。
    return None


def _computer_action_from_goal(goal: str) -> Optional[Dict[str, Any]]:
    text = (goal or "").strip()
    if not text:
        return None
    low = text.lower()

    app_spec = _extract_app_to_open_from_goal(text)
    if app_spec:
        return {"action": "open_app", "payload": {"app": app_spec["query"], "display": app_spec["display"]}}

    if any(k in text for k in ["截图", "截屏", "看屏幕", "看看屏幕", "屏幕看看"]) or "screenshot" in low:
        return {"action": "screenshot", "payload": {}}
    if ("鼠标" in text and "位置" in text) or "mouse position" in low:
        return {"action": "mouse_position", "payload": {}}
    if any(k in text for k in ["聚焦搜索", "spotlight", "全局搜索"]) or ("command" in low and "space" in low) or ("cmd" in low and "space" in low):
        return {"action": "press_keys", "payload": {"keys": ["cmd", "space"]}}
    if any(k in text for k in ["按回车", "敲回车", "回车", "enter"]):
        return {"action": "press_keys", "payload": {"keys": ["enter"]}}
    if any(k in text for k in ["按esc", "按 Esc", "esc", "escape", "退出键"]):
        return {"action": "press_keys", "payload": {"keys": ["escape"]}}
    if any(k in text for k in ["按空格", "空格键"]):
        return {"action": "press_keys", "payload": {"keys": ["space"]}}

    m = re.search(r"(?:输入|打字|键入)[:：\s]*(.+)$", text, re.I)
    if not m:
        m = re.search(r"\btype\s+(.+)$", text, re.I)
    if m:
        val = (m.group(1) or "").strip().strip('"“”')
        if val:
            return {"action": "type_text", "payload": {"text": val}}

    if any(k in text for k in ["右键", "点右键", "右击"]):
        return {"action": "click", "payload": {"button": "right"}}
    if any(k in text for k in ["双击", "double click"]):
        return {"action": "double_click", "payload": {"button": "left"}}
    if any(k in text for k in ["点击", "点一下", "左键", "单击"]) or "click" in low:
        return {"action": "click", "payload": {"button": "left"}}
    return None


# ---- stub：假装执行成功，不调 local-agent ----
async def _brain_computer_execute_action(action: str, payload: Dict[str, Any]) -> Dict[str, Any]:
    if action == "screenshot":
        return {"ok": True, "action": "screenshot",
                "message": "截图已完成。",
                "result": {"_stub": True, "image_b64": "iVBORw0KGgo...(stub)"}}
    if action == "mouse_position":
        return {"ok": True, "action": "mouse_position",
                "message": "鼠标位置已读取。",
                "result": {"x": 512, "y": 384, "_stub": True}}
    if action in ("press_keys", "press"):
        keys = payload.get("keys") or []
        return {"ok": True, "action": "press_keys",
                "message": f"已按键：{'+'.join(keys)}",
                "result": {"_stub": True}, "keys": keys}
    return {"ok": True, "action": action, "message": f"已执行 {action}", "result": {"_stub": True}}


# ---- 以下与 server_session-104.py 里 /api/brain/adu/act 同一份代码 ----
_ADU_ACT_SOURCES = {"text_chat", "audio_transcript", "realtime_voice", "realtime_av", "debug_panel"}

_ADU_ACT_RISK = {
    "screenshot": 0,
    "mouse_position": 0,
    "wait": 0,
    "open_app": 1,
    "type_text": 1,
    "press_keys": 1,
    "click": 1,
    "double_click": 1,
    "right_click": 1,
    "left_click": 1,
    "move": 1,
}

_ADU_ACT_AUTO_RISK_THRESHOLD = 1


def _adu_act_risk(action: str) -> int:
    return _ADU_ACT_RISK.get((action or "").strip().lower(), 2)


def _adu_act_final_text(action: str, result: Any) -> str:
    if isinstance(result, dict):
        msg = result.get("message")
        if isinstance(msg, str) and msg.strip():
            return msg.strip()
        inner = result.get("result")
        if action == "mouse_position" and isinstance(inner, dict):
            x = inner.get("x")
            y = inner.get("y")
            if x is not None and y is not None:
                return f"鼠标位置：x={x}, y={y}"
    return "电脑动作已执行。"


@app.post("/api/brain/adu/act")
async def api_brain_adu_act(request: Request):
    body = await _request_json_or_empty(request)

    source = str(body.get("source") or "").strip().lower()
    text = str(body.get("text") or body.get("goal") or "").strip()
    client_id = str(body.get("client_id") or "").strip()
    conversation_id = str(body.get("conversation_id") or "").strip()
    mode = str(body.get("mode") or "").strip()
    allow_execute_raw = body.get("allow_execute")
    allow_execute = True if allow_execute_raw is None else bool(allow_execute_raw)

    if source not in _ADU_ACT_SOURCES:
        raise HTTPException(status_code=400, detail={
            "ok": False,
            "error": "bad_source",
            "hint": f"source 必须是 {sorted(_ADU_ACT_SOURCES)} 之一",
        })
    if not text:
        raise HTTPException(status_code=400, detail={"ok": False, "error": "missing text"})

    spec = _computer_action_from_goal(text)
    if spec is None:
        return {"ok": False, "route": "chat", "source": source, "goal": text}

    action = spec["action"]
    payload = spec.get("payload") or {}
    if not isinstance(payload, dict):
        payload = {}
    risk_level = _adu_act_risk(action)

    if not allow_execute:
        need_confirm = True
    else:
        need_confirm = risk_level > _ADU_ACT_AUTO_RISK_THRESHOLD

    base: Dict[str, Any] = {
        "ok": True,
        "route": "computer",
        "source": source,
        "goal": text,
        "client_id": client_id,
        "conversation_id": conversation_id,
        "mode": mode,
        "need_confirm": need_confirm,
        "risk_level": risk_level,
        "action": action,
        "payload": payload,
        "result": None,
        "final_text": None,
    }

    if need_confirm:
        base["final_text"] = "已识别为电脑任务，等待确认。"
        return base

    try:
        result = await _brain_computer_execute_action(action, payload)
    except HTTPException as e:
        detail = e.detail if isinstance(e.detail, dict) else {"error": str(e.detail)}
        base["ok"] = False
        base["result"] = detail if isinstance(detail, dict) else {"error": str(detail)}
        err_text = ""
        if isinstance(detail, dict):
            err_text = str(detail.get("error") or detail.get("hint") or "")
        base["final_text"] = err_text or "电脑动作执行失败"
        return base
    except Exception as e:
        base["ok"] = False
        base["result"] = {"error": str(e)}
        base["final_text"] = f"电脑动作执行异常：{e}"
        return base

    base["result"] = result if isinstance(result, dict) else {"value": result}
    base["final_text"] = _adu_act_final_text(action, result)
    return base


@app.get("/")
def root():
    return {"ok": True, "service": "adu_act local test", "endpoint": "/api/brain/adu/act"}
