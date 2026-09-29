# ================================
# brain_state_engine.py
# ChatAGI-阿杜 BrainState Engine / 大脑状态引擎
#
# 目标：把 APP 后端从“接口集合”升级成“状态张量驱动的思维主体”。
# - 用 JSON + 权重向量实现第一版工程化 BrainState Tensor
# - 负责：意图识别、模型路由、工具选择、风险判断、执行反馈、状态持久化
# - 不强绑定任何大模型/云服务；server_session.py 负责把工具函数注册/调用进来
# ================================

# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-74ececc02eabb20690792a52702280797363db7223bb849b7e73e42e3866d1ea"
# Source-SHA256: "e537a5eb9d5c4ca2d50441541bbacd4379b43534ecf4d92395ce13e4b4b16134"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
from __future__ import annotations

import json
import math
import re
import sqlite3
import time
import uuid
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


INTENT_DIMS = [
    "chat",
    "coding",
    "math_reasoning",
    "computer_control",
    "web_search",
    "memory_recall",
    "memory_write",
    "vision",
    "long_context",
    "planning",
    "voice",
    "realtime_data",
]

MODEL_NEED_DIMS = [
    "coding",
    "math_reasoning",
    "chinese",
    "vision",
    "long_context",
    "tool_use",
    "agentic_task",
    "low_cost",
    "low_latency",
    "privacy",
    "final_check",
]

TOOL_DIMS = [
    "local_agent",
    "computer_screenshot",
    "computer_mouse",
    "computer_keyboard",
    "web_search",
    "web_page_reader",
    "memory_search",
    "memory_write",
    "model_router",
    "file_read",
    "file_write",
    "voice_io",
]

RISK_DIMS = [
    "read_only",
    "mouse_click",
    "keyboard_input",
    "file_write",
    "shell_exec",
    "send_message",
    "send_email",
    "delete_file",
    "payment",
    "external_publish",
]

DEFAULT_MODEL_CAPABILITIES: Dict[str, Dict[str, float]] = {
    # 中国/开源专家池：先作为路由表，后续可由 benchmark 自动更新
    "deepseek": {
        "coding": 0.88,
        "math_reasoning": 0.88,
        "chinese": 0.88,
        "vision": 0.05,
        "long_context": 0.62,
        "tool_use": 0.72,
        "agentic_task": 0.72,
        "low_cost": 0.92,
        "low_latency": 0.72,
        "privacy": 0.55,
        "final_check": 0.74,
    },
    "qwen": {
        "coding": 0.80,
        "math_reasoning": 0.78,
        "chinese": 0.93,
        "vision": 0.82,
        "long_context": 0.78,
        "tool_use": 0.80,
        "agentic_task": 0.75,
        "low_cost": 0.84,
        "low_latency": 0.76,
        "privacy": 0.55,
        "final_check": 0.72,
    },
    "glm": {
        "coding": 0.84,
        "math_reasoning": 0.76,
        "chinese": 0.86,
        "vision": 0.35,
        "long_context": 0.84,
        "tool_use": 0.84,
        "agentic_task": 0.88,
        "low_cost": 0.76,
        "low_latency": 0.68,
        "privacy": 0.58,
        "final_check": 0.75,
    },
    "kimi": {
        "coding": 0.70,
        "math_reasoning": 0.66,
        "chinese": 0.88,
        "vision": 0.28,
        "long_context": 0.92,
        "tool_use": 0.68,
        "agentic_task": 0.62,
        "low_cost": 0.78,
        "low_latency": 0.70,
        "privacy": 0.50,
        "final_check": 0.70,
    },
    "openai": {
        "coding": 0.90,
        "math_reasoning": 0.88,
        "chinese": 0.84,
        "vision": 0.92,
        "long_context": 0.86,
        "tool_use": 0.92,
        "agentic_task": 0.88,
        "low_cost": 0.45,
        "low_latency": 0.74,
        "privacy": 0.45,
        "final_check": 0.90,
    },
    "claude": {
        "coding": 0.92,
        "math_reasoning": 0.86,
        "chinese": 0.80,
        "vision": 0.80,
        "long_context": 0.90,
        "tool_use": 0.88,
        "agentic_task": 0.90,
        "low_cost": 0.42,
        "low_latency": 0.68,
        "privacy": 0.45,
        "final_check": 0.92,
    },
    "local_small": {
        "coding": 0.35,
        "math_reasoning": 0.30,
        "chinese": 0.62,
        "vision": 0.10,
        "long_context": 0.28,
        "tool_use": 0.55,
        "agentic_task": 0.45,
        "low_cost": 1.00,
        "low_latency": 0.92,
        "privacy": 0.95,
        "final_check": 0.35,
    },
}


def _now() -> float:
    return time.time()


def _short(text: Any, n: int = 500) -> str:
    s = str(text or "")
    return s if len(s) <= n else s[:n] + "…"


def _zero(keys: List[str]) -> Dict[str, float]:
    return {k: 0.0 for k in keys}


def _clip01(v: float) -> float:
    try:
        return max(0.0, min(1.0, float(v)))
    except Exception:
        return 0.0


def _dot(a: Dict[str, float], b: Dict[str, float]) -> float:
    return sum(float(a.get(k, 0.0)) * float(b.get(k, 0.0)) for k in set(a) | set(b))


def _norm(a: Dict[str, float]) -> float:
    return math.sqrt(sum(float(v) * float(v) for v in a.values())) or 1.0


def _cosine(a: Dict[str, float], b: Dict[str, float]) -> float:
    return _dot(a, b) / (_norm(a) * _norm(b))


class BrainStateEngine:
    """工程版 BrainState Tensor。

    第一版用 JSON + 权重向量实现，后续可把 intent/memory/screen/model capability
    换成真正 embedding/tensor 计算。
    """

    def __init__(self, db_path: Optional[str] = None) -> None:
        self.db_path = str(db_path or (Path(__file__).parent / "data" / "brain_state.sqlite3"))
        Path(self.db_path).parent.mkdir(parents=True, exist_ok=True)
        self._init_db()
        self.model_capabilities = dict(DEFAULT_MODEL_CAPABILITIES)

    def _conn(self) -> sqlite3.Connection:
        con = sqlite3.connect(self.db_path, check_same_thread=False)
        con.row_factory = sqlite3.Row
        con.execute("PRAGMA journal_mode=WAL;")
        con.execute("PRAGMA synchronous=NORMAL;")
        return con

    def _init_db(self) -> None:
        with self._conn() as con:
            con.execute(
                """
                CREATE TABLE IF NOT EXISTS brain_states (
                    user_key TEXT PRIMARY KEY,
                    state_json TEXT NOT NULL,
                    updated_at REAL NOT NULL
                )
                """
            )
            con.execute(
                """
                CREATE TABLE IF NOT EXISTS brain_events (
                    id TEXT PRIMARY KEY,
                    user_key TEXT NOT NULL,
                    event_type TEXT NOT NULL,
                    event_json TEXT NOT NULL,
                    created_at REAL NOT NULL
                )
                """
            )
            con.execute("CREATE INDEX IF NOT EXISTS idx_brain_events_user_time ON brain_events(user_key, created_at DESC)")

    def default_state(self, user_key: str = "default") -> Dict[str, Any]:
        return {
            "version": "brain_state_tensor_v1",
            "user_key": user_key,
            "created_at": _now(),
            "updated_at": _now(),
            "persona_layer": {
                "name": "阿杜",
                "identity": "杜聿永的数字分身 / portable personal AI brain",
                "mission": "挣钱养家、长期记忆、实时感知、控制电脑、可迁移到不同身体",
            },
            "long_term_goals": [
                "构建可移植个人 AI 大脑",
                "手机作为入口，电脑作为第一个身体",
                "长期记忆、实时感知、多模型路由、local-agent 执行闭环",
                "进入 AI 技术圈，参加 AI Tinkerers/黑客松并展示技术",
                "未来迁移到浏览器、手机本机、机器人身体或其他实体载体",
            ],
            "intent_vector": _zero(INTENT_DIMS),
            "model_need_vector": _zero(MODEL_NEED_DIMS),
            "tool_vector": _zero(TOOL_DIMS),
            "risk_vector": _zero(RISK_DIMS),
            "current_task": {
                "task_id": "",
                "name": "",
                "stage": "idle",
                "confidence": 0.0,
                "last_user_input": "",
            },
            "device_state": {
                "phone_active": True,
                "computer_reachable": None,
                "local_agent_healthy": None,
                "screen_state": "unknown",
            },
            "voice_state": {
                "mode": "text_or_voice",
                "last_transcript": "",
                "semantic_interrupt": False,
            },
            "memory_context": [],
            "realtime_context": {
                "need_freshness": False,
                "last_query": "",
                "sources": [],
            },
            "available_tools": {
                "local_agent": False,
                "web_search": False,
                "memory_search": True,
                "memory_write": True,
                "model_router": True,
            },
            "model_capabilities": self.model_capabilities,
            "model_route": {
                "selected_model_family": "",
                "score": 0.0,
                "reason": "",
                "fallbacks": [],
            },
            "risk_level": "low",
            "requires_confirmation": False,
            "last_action_result": {},
            "next_action": {
                "type": "none",
                "target": "none",
                "tool": "none",
                "params": {},
                "confidence": 0.0,
                "requires_confirmation": False,
            },
            "event_count": 0,
        }

    def get_state(self, user_key: str = "default") -> Dict[str, Any]:
        user_key = user_key or "default"
        with self._conn() as con:
            row = con.execute("SELECT state_json FROM brain_states WHERE user_key=?", (user_key,)).fetchone()
        if row:
            try:
                state = json.loads(row["state_json"])
                if isinstance(state, dict):
                    return state
            except Exception:
                pass
        state = self.default_state(user_key)
        self.save_state(user_key, state)
        return state

    def save_state(self, user_key: str, state: Dict[str, Any]) -> Dict[str, Any]:
        state["user_key"] = user_key
        state["updated_at"] = _now()
        with self._conn() as con:
            con.execute(
                "INSERT INTO brain_states(user_key,state_json,updated_at) VALUES(?,?,?) "
                "ON CONFLICT(user_key) DO UPDATE SET state_json=excluded.state_json, updated_at=excluded.updated_at",
                (user_key, json.dumps(state, ensure_ascii=False), float(state["updated_at"])),
            )
        return state

    def reset(self, user_key: str = "default") -> Dict[str, Any]:
        state = self.default_state(user_key)
        self.save_state(user_key, state)
        self.record_event(user_key, "reset", {"ok": True})
        return state

    def record_event(self, user_key: str, event_type: str, event: Dict[str, Any]) -> None:
        try:
            with self._conn() as con:
                con.execute(
                    "INSERT INTO brain_events(id,user_key,event_type,event_json,created_at) VALUES(?,?,?,?,?)",
                    (uuid.uuid4().hex, user_key, event_type, json.dumps(event, ensure_ascii=False), _now()),
                )
        except Exception:
            pass

    def infer_intent_vector(self, text: str, context: Optional[Dict[str, Any]] = None) -> Dict[str, float]:
        t = (text or "").strip()
        lo = t.lower()
        v = _zero(INTENT_DIMS)
        v["chat"] = 0.35

        def hit(words: List[str]) -> bool:
            return any(w.lower() in lo for w in words) or any(w in t for w in words)

        if hit(["代码", "修复", "bug", "swift", "python", "server.js", "index.html", "xcode", "github", "compile", "报错", "接口"]):
            v["coding"] = 0.88
            v["planning"] = max(v["planning"], 0.45)
        if hit(["数学", "证明", "公式", "方程", "推理", "算法", "矩阵", "张量", "概率", "几何"]):
            v["math_reasoning"] = 0.82
        if hit(["打开", "点击", "鼠标", "键盘", "输入", "回车", "电脑", "浏览器", "截图", "按", "press", "click", "type"]):
            v["computer_control"] = 0.84
        if hit(["最新", "发布", "现在", "实时", "联网", "搜索", "查一下", "价格", "新闻", "活动", "报名", "名额", "官网"]):
            v["web_search"] = 0.82
            v["realtime_data"] = 0.78
        if hit(["记住", "保存到记忆", "加入记忆", "长期记忆", "以后", "从现在", "别忘"]):
            v["memory_write"] = 0.88
        if hit(["之前", "上次", "历史", "记得", "我们做过", "项目进展", "明天继续"]):
            v["memory_recall"] = 0.78
        if hit(["看图", "图片", "屏幕", "画面", "截图", "视觉", "摄像头"]):
            v["vision"] = 0.72
        if hit(["总结", "长文", "文档", "PDF", "全部内容", "报告", "长上下文"]):
            v["long_context"] = 0.70
        if hit(["计划", "路线", "架构", "怎么做", "下一步", "方案", "产品", "发布", "参加"]):
            v["planning"] = max(v["planning"], 0.72)
        if hit(["语音", "说话", "播报", "通话", "听"]):
            v["voice"] = 0.68

        if context:
            if context.get("has_attachments"):
                v["vision"] = max(v["vision"], 0.45)
            if context.get("allow_web"):
                v["web_search"] = max(v["web_search"], 0.45)
            if context.get("computer_reachable"):
                v["computer_control"] = max(v["computer_control"], 0.30)

        # normalize soft floor: highest non-chat suppresses generic chat
        mx = max([v[k] for k in v if k != "chat"] or [0.0])
        if mx > 0.6:
            v["chat"] = 0.15
        return {k: round(_clip01(val), 3) for k, val in v.items()}

    def model_need_from_intent(self, intent: Dict[str, float]) -> Dict[str, float]:
        n = _zero(MODEL_NEED_DIMS)
        n["chinese"] = 0.70
        n["low_cost"] = 0.55
        n["low_latency"] = 0.45
        n["privacy"] = 0.35
        n["coding"] = max(n["coding"], intent.get("coding", 0.0))
        n["math_reasoning"] = max(n["math_reasoning"], intent.get("math_reasoning", 0.0))
        n["vision"] = max(n["vision"], intent.get("vision", 0.0))
        n["long_context"] = max(n["long_context"], intent.get("long_context", 0.0), intent.get("memory_recall", 0.0) * 0.7)
        n["tool_use"] = max(n["tool_use"], intent.get("computer_control", 0.0), intent.get("web_search", 0.0) * 0.7)
        n["agentic_task"] = max(n["agentic_task"], intent.get("planning", 0.0), intent.get("computer_control", 0.0) * 0.8)
        if intent.get("realtime_data", 0.0) > 0.6:
            n["tool_use"] = max(n["tool_use"], 0.78)
        if intent.get("coding", 0.0) > 0.75 or intent.get("math_reasoning", 0.0) > 0.75:
            n["final_check"] = 0.62
        return {k: round(_clip01(v), 3) for k, v in n.items()}

    def choose_model(self, need: Dict[str, float]) -> Dict[str, Any]:
        scores: List[Tuple[str, float]] = []
        for name, cap in self.model_capabilities.items():
            # cosine keeps scores stable even when vectors have different magnitudes
            score = _cosine(need, cap)
            scores.append((name, round(score, 4)))
        scores.sort(key=lambda x: x[1], reverse=True)
        best = scores[0] if scores else ("openai", 0.0)
        return {
            "selected_model_family": best[0],
            "score": best[1],
            "reason": "task_need_vector matched model_capability_vector",
            "fallbacks": [{"model_family": n, "score": s} for n, s in scores[1:4]],
            "all_scores": [{"model_family": n, "score": s} for n, s in scores],
        }

    def infer_tool_vector(self, intent: Dict[str, float], available_tools: Optional[Dict[str, Any]] = None) -> Dict[str, float]:
        tv = _zero(TOOL_DIMS)
        tv["model_router"] = 0.75
        tv["memory_search"] = max(intent.get("memory_recall", 0.0), intent.get("planning", 0.0) * 0.35)
        tv["memory_write"] = intent.get("memory_write", 0.0)
        tv["web_search"] = max(intent.get("web_search", 0.0), intent.get("realtime_data", 0.0))
        if intent.get("computer_control", 0.0) > 0.3:
            tv["local_agent"] = intent.get("computer_control", 0.0)
            tv["computer_screenshot"] = max(intent.get("vision", 0.0), 0.55)
            tv["computer_mouse"] = intent.get("computer_control", 0.0) * 0.75
            tv["computer_keyboard"] = intent.get("computer_control", 0.0) * 0.80
        if intent.get("coding", 0.0) > 0.6:
            tv["file_read"] = 0.55
            tv["file_write"] = 0.45
        if available_tools:
            for k, ok in available_tools.items():
                if k in tv and not ok:
                    tv[k] = min(tv[k], 0.10)
        return {k: round(_clip01(v), 3) for k, v in tv.items()}

    def infer_risk_vector(self, text: str, intent: Dict[str, float]) -> Dict[str, float]:
        lo = (text or "").lower()
        rv = _zero(RISK_DIMS)
        rv["read_only"] = 0.1
        if intent.get("computer_control", 0.0) > 0.5:
            rv["mouse_click"] = 0.35
            rv["keyboard_input"] = 0.42
        if any(w in lo for w in ["写入", "保存", "覆盖", "替换", "修改文件", "write", "save", "overwrite"]):
            rv["file_write"] = 0.60
        if any(w in lo for w in ["终端", "shell", "sudo", "rm -rf", "删除", "delete", "清空", "格式化", "reboot", "shutdown"]):
            rv["shell_exec"] = 0.80
        if any(w in lo for w in ["发邮件", "发送", "转发", "send email", "gmail"]):
            rv["send_email"] = 0.82
        if any(w in lo for w in ["付款", "支付", "购买", "订阅", "checkout", "payment"]):
            rv["payment"] = 0.95
        if any(w in lo for w in ["发布", "上线", "推送到", "post", "tweet", "公开"]):
            rv["external_publish"] = 0.74
        if any(w in lo for w in ["删除文件", "删掉", "rm ", "trash"]):
            rv["delete_file"] = 0.95
        return {k: round(_clip01(v), 3) for k, v in rv.items()}

    def risk_level(self, rv: Dict[str, float]) -> Tuple[str, bool]:
        high = max(rv.values() or [0.0])
        if high >= 0.85:
            return "high", True
        if high >= 0.60:
            return "medium", True
        return "low", False

    def _parse_simple_computer_action(self, text: str) -> Optional[Dict[str, Any]]:
        t = (text or "").strip()
        lo = t.lower()
        if not t:
            return None
        if "截图" in t or "screenshot" in lo:
            return {"action": "screenshot", "payload": {}}
        if "鼠标位置" in t or "mouse position" in lo:
            return {"action": "mouse_position", "payload": {}}
        if "回车" in t or "enter" in lo:
            return {"action": "press_keys", "payload": {"keys": ["enter"]}}
        if "esc" in lo or "退出键" in t or "escape" in lo:
            return {"action": "press_keys", "payload": {"keys": ["escape"]}}
        if "空格" in t or "space" in lo:
            return {"action": "press_keys", "payload": {"keys": ["space"]}}
        m = re.search(r"(?:输入|打字|type)[:：\s]+(.+)$", t, re.I)
        if m:
            return {"action": "type_text", "payload": {"text": m.group(1).strip()}}
        m2 = re.search(r"(?:打开|启动|open)\s*([A-Za-z0-9_\-\.\u4e00-\u9fff ]{1,40})", t, re.I)
        if m2:
            name = m2.group(1).strip().strip("。.!！")
            if name and name not in ("文件", "网页"):
                return {"action": "open_app", "payload": {"app": name, "display": name}}
        return None

    def build_next_action(self, text: str, intent: Dict[str, float], tool_vector: Dict[str, float], risk_level: str, requires_confirmation: bool, route: Dict[str, Any]) -> Dict[str, Any]:
        if requires_confirmation and risk_level == "high":
            return {
                "type": "ask_confirmation",
                "target": "user",
                "tool": "safety_gate",
                "params": {"reason": "high_risk_action_detected", "text": _short(text, 300)},
                "confidence": 0.95,
                "requires_confirmation": True,
            }

        if intent.get("computer_control", 0.0) >= 0.70:
            spec = self._parse_simple_computer_action(text)
            if spec:
                return {
                    "type": "tool_call",
                    "target": "computer",
                    "tool": "local_agent",
                    "params": spec,
                    "confidence": round(intent.get("computer_control", 0.0), 3),
                    "requires_confirmation": requires_confirmation,
                }
            return {
                "type": "plan_computer_task",
                "target": "computer",
                "tool": "model_router_then_local_agent",
                "params": {"goal": text, "selected_model_family": route.get("selected_model_family")},
                "confidence": round(intent.get("computer_control", 0.0), 3),
                "requires_confirmation": requires_confirmation,
            }

        if intent.get("web_search", 0.0) >= 0.70 or intent.get("realtime_data", 0.0) >= 0.70:
            return {
                "type": "tool_call",
                "target": "outside_world",
                "tool": "web_search",
                "params": {"query": text, "k": 6},
                "confidence": round(max(intent.get("web_search", 0.0), intent.get("realtime_data", 0.0)), 3),
                "requires_confirmation": False,
            }

        if intent.get("memory_write", 0.0) >= 0.75:
            return {
                "type": "tool_call",
                "target": "memory",
                "tool": "memory_write",
                "params": {"text": text, "importance": 4, "tags": "user_explicit"},
                "confidence": round(intent.get("memory_write", 0.0), 3),
                "requires_confirmation": False,
            }

        if intent.get("memory_recall", 0.0) >= 0.70:
            return {
                "type": "tool_call",
                "target": "memory",
                "tool": "memory_search",
                "params": {"query": text, "k": 6},
                "confidence": round(intent.get("memory_recall", 0.0), 3),
                "requires_confirmation": False,
            }

        return {
            "type": "call_model",
            "target": "model_pool",
            "tool": "model_router",
            "params": {"selected_model_family": route.get("selected_model_family"), "user_input": text},
            "confidence": round(route.get("score", 0.0), 3),
            "requires_confirmation": False,
        }

    def think(self, user_key: str, user_input: str, context: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        user_key = user_key or "default"
        context = context or {}
        state = self.get_state(user_key)
        text = (user_input or "").strip()
        intent = self.infer_intent_vector(text, context)
        model_need = self.model_need_from_intent(intent)
        route = self.choose_model(model_need)

        available_tools = dict(state.get("available_tools") or {})
        for k, v in (context.get("available_tools") or {}).items():
            available_tools[k] = bool(v)
        tool_vector = self.infer_tool_vector(intent, available_tools)
        risk_vector = self.infer_risk_vector(text, intent)
        risk_level, requires_confirmation = self.risk_level(risk_vector)
        next_action = self.build_next_action(text, intent, tool_vector, risk_level, requires_confirmation, route)

        # Update BrainState Tensor
        state["intent_vector"] = intent
        state["model_need_vector"] = model_need
        state["tool_vector"] = tool_vector
        state["risk_vector"] = risk_vector
        state["model_route"] = route
        state["risk_level"] = risk_level
        state["requires_confirmation"] = requires_confirmation
        state["next_action"] = next_action
        state["available_tools"] = available_tools
        state["current_task"] = {
            "task_id": state.get("current_task", {}).get("task_id") or uuid.uuid4().hex,
            "name": self._task_name_from_intent(intent, text),
            "stage": "thinking",
            "confidence": round(max(intent.values() or [0.0]), 3),
            "last_user_input": text,
        }
        state["realtime_context"]["need_freshness"] = bool(intent.get("realtime_data", 0.0) >= 0.6)
        if intent.get("web_search", 0.0) >= 0.6:
            state["realtime_context"]["last_query"] = text
        state["event_count"] = int(state.get("event_count") or 0) + 1
        self.save_state(user_key, state)
        self.record_event(user_key, "think", {"input": _short(text, 500), "intent": intent, "route": route, "next_action": next_action})

        return {
            "ok": True,
            "brain_state_version": state["version"],
            "user_key": user_key,
            "intent_vector": intent,
            "model_need_vector": model_need,
            "tool_vector": tool_vector,
            "risk_vector": risk_vector,
            "risk_level": risk_level,
            "requires_confirmation": requires_confirmation,
            "model_route": route,
            "next_action": next_action,
            "state_summary": self.summarize_state(state),
            "state": state,
        }

    def _task_name_from_intent(self, intent: Dict[str, float], text: str) -> str:
        pairs = sorted(intent.items(), key=lambda x: x[1], reverse=True)
        top = pairs[0][0] if pairs else "chat"
        return f"{top}: {_short(text, 50)}"

    def observe(self, user_key: str, observation: Dict[str, Any]) -> Dict[str, Any]:
        state = self.get_state(user_key)
        obs = observation or {}
        if isinstance(obs.get("device_state"), dict):
            state.setdefault("device_state", {}).update(obs["device_state"])
        if isinstance(obs.get("voice_state"), dict):
            state.setdefault("voice_state", {}).update(obs["voice_state"])
        if isinstance(obs.get("realtime_context"), dict):
            state.setdefault("realtime_context", {}).update(obs["realtime_context"])
        if isinstance(obs.get("available_tools"), dict):
            state.setdefault("available_tools", {}).update({k: bool(v) for k, v in obs["available_tools"].items()})
        if obs.get("memory_context"):
            state["memory_context"] = obs.get("memory_context")
        self.save_state(user_key, state)
        self.record_event(user_key, "observe", obs)
        return {"ok": True, "state": state, "state_summary": self.summarize_state(state)}

    def remember_action_result(self, user_key: str, action: Dict[str, Any], result: Dict[str, Any]) -> Dict[str, Any]:
        state = self.get_state(user_key)
        state["last_action_result"] = {
            "action": action,
            "result": result,
            "created_at": _now(),
        }
        state["current_task"]["stage"] = "acted" if result.get("ok", True) else "failed"
        state["event_count"] = int(state.get("event_count") or 0) + 1
        self.save_state(user_key, state)
        self.record_event(user_key, "action_result", {"action": action, "result": result})
        return state

    def summarize_state(self, state: Dict[str, Any]) -> Dict[str, Any]:
        def top(vec: Dict[str, float], n: int = 3) -> List[Dict[str, Any]]:
            return [
                {"name": k, "score": v}
                for k, v in sorted((vec or {}).items(), key=lambda x: x[1], reverse=True)[:n]
                if float(v) > 0.0
            ]

        return {
            "task": state.get("current_task"),
            "top_intents": top(state.get("intent_vector") or {}),
            "selected_model_family": (state.get("model_route") or {}).get("selected_model_family"),
            "risk_level": state.get("risk_level"),
            "next_action": state.get("next_action"),
            "device_state": state.get("device_state"),
        }

    def tensor_view(self, user_key: str) -> Dict[str, Any]:
        state = self.get_state(user_key)
        return {
            "ok": True,
            "user_key": user_key,
            "tensors": {
                "intent_vector": state.get("intent_vector"),
                "model_need_vector": state.get("model_need_vector"),
                "tool_vector": state.get("tool_vector"),
                "risk_vector": state.get("risk_vector"),
                "model_capability_matrix": state.get("model_capabilities"),
            },
            "model_route": state.get("model_route"),
            "next_action": state.get("next_action"),
        }
