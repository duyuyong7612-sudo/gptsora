# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-d4bde899a6cec6d3b806a89fb7be84326fd5cfb1892d9f8d23a3a09ea0e1bb08"
# Source-SHA256: "b58c65f3a047fdab9fc9a06ccc17af88e9e260e9449acb3d71d8af453db30a3b"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
ChatAGI Vision Core V1
======================
让阿杜真正"看见":电脑屏幕 / 手机上传图片 / 摄像头帧 → 视觉理解 →
写入 BrainCore(tensor) / DevBrain(observe) / Memory(timeline+episode+vector+graph)
/ WorldStateBlackboard。

统一入口
--------
    GET  /api/brain/vision/health
    POST /api/brain/vision/observe
        {user_key, source: computer_screenshot|image_upload|camera_frame,
         image_b64?, goal?, write_memory?}

视觉模型策略
-----------
优先 OPENAI_API_KEY(gpt-4o);否则 DASHSCOPE(qwen-vl);都没有 → 优雅降级,
只返回 image metadata(size/source),绝不崩。API key 只在后端,iOS 只传 image_b64。

挂载
----
from chatagi_vision_core import router as vision_router, configure_vision
configure_vision(local_agent_callable=_call_local_agent,
                 memory_engine=MEMORY_ENGINE, brain_state_engine=BRAIN_STATE_ENGINE)
app.include_router(vision_router)
"""

from __future__ import annotations

import asyncio
import base64
import json
import logging
import os
import re
import time
import uuid
from typing import Any, Awaitable, Callable, Dict, List, Optional, Tuple

try:
    import httpx
except Exception:  # noqa: BLE001
    httpx = None  # type: ignore[assignment]

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

log = logging.getLogger("chatagi.vision")

LocalAgentCallable = Callable[[str, str, Optional[Dict[str, Any]]], Awaitable[Any]]

_LOCAL_AGENT: Optional[LocalAgentCallable] = None
_MEMORY_ENGINE: Any = None
_BRAIN_STATE_ENGINE: Any = None

VISION_SOURCES = ("computer_screenshot", "image_upload", "camera_frame")
MAX_IMAGE_B64 = int(os.getenv("VISION_MAX_IMAGE_B64", str(12 * 1024 * 1024)))  # ~12MB b64


def configure_vision(*, local_agent_callable: Optional[LocalAgentCallable] = None,
                     memory_engine: Any = None, brain_state_engine: Any = None) -> None:
    global _LOCAL_AGENT, _MEMORY_ENGINE, _BRAIN_STATE_ENGINE
    _LOCAL_AGENT = local_agent_callable
    _MEMORY_ENGINE = memory_engine
    _BRAIN_STATE_ENGINE = brain_state_engine
    log.info("Vision Core configured: local_agent=%s memory=%s brain_state=%s",
             local_agent_callable is not None, memory_engine is not None,
             brain_state_engine is not None)


# =============================================================================
# Vision provider
# =============================================================================


def _vision_provider() -> Optional[Tuple[str, str, Dict[str, str], str]]:
    """(provider, url, headers, model)。OpenAI → DashScope → Anthropic(claude 视觉)。
    都用各自原生格式。.env 里 OpenAI/DashScope 可能为空,Anthropic 兜底,无需改 .env。"""
    openai_key = (os.getenv("OPENAI_API_KEY") or os.getenv("SORA_API_KEY") or "").strip()
    dash_key = (os.getenv("DASHSCOPE_API_KEY") or "").strip()
    anthropic_key = (os.getenv("ANTHROPIC_API_KEY") or "").strip()
    model = (os.getenv("VISION_MODEL") or "").strip()
    if openai_key:
        base = (os.getenv("OPENAI_BASE_URL") or "https://api.openai.com").rstrip("/")
        return ("openai", base + "/v1/chat/completions",
                {"Authorization": f"Bearer {openai_key}", "Content-Type": "application/json"},
                model or "gpt-4o")
    if dash_key:
        base = (os.getenv("DASHSCOPE_BASE_URL") or "https://dashscope-us.aliyuncs.com/compatible-mode/v1").rstrip("/")
        return ("dashscope", base + "/chat/completions",
                {"Authorization": f"Bearer {dash_key}", "Content-Type": "application/json"},
                model or "qwen-vl-plus")
    if anthropic_key:
        base = (os.getenv("ANTHROPIC_BASE_URL") or "https://api.anthropic.com").rstrip("/")
        return ("anthropic", base + "/v1/messages",
                {"x-api-key": anthropic_key,
                 "anthropic-version": os.getenv("ANTHROPIC_VERSION", "2023-06-01"),
                 "content-type": "application/json"},
                (os.getenv("VISION_MODEL_ANTHROPIC") or "claude-opus-4-20250514"))
    return None


def vision_enabled() -> bool:
    return _vision_provider() is not None


_VISION_SYSTEM = (
    "你是 ChatAGI 阿杜的视觉皮层。你会看到一张图(电脑屏幕截图/上传图片/摄像头帧)。"
    "请客观分析,并严格只输出一个 JSON 对象,不要 markdown,不要解释。字段:\n"
    "{\n"
    '  "summary": "一句话概括看到了什么",\n'
    '  "active_app": "如果是电脑屏幕,当前前台/主要应用名,否则空串",\n'
    '  "objects": ["可见的主要物体/元素"],\n'
    '  "text": ["可见的关键文字,尤其是错误信息/标题/按钮文字"],\n'
    '  "ui_elements": [{"kind":"button|input|menu|dialog|error|code_editor|link","label":"...","hint":"可点击/可输入"}],\n'
    '  "errors": ["任何报错/红色提示/异常,没有则空数组"],\n'
    '  "popups": ["弹窗/对话框,没有则空数组"],\n'
    '  "next_actions": ["基于画面建议的下一步可操作项"],\n'
    '  "risk": {"level":"low|medium|high","reason":"为什么"}\n'
    "}"
)


class VisionAnalyzer:
    """图片 → 结构化视觉理解。无 key 时优雅降级。"""

    async def analyze_image(self, image_b64: str, *, goal: str = "", source: str = "",
                            user_key: str = "adu") -> Dict[str, Any]:
        image_b64 = (image_b64 or "").strip()
        if image_b64.startswith("data:") and "," in image_b64:
            image_b64 = image_b64.split(",", 1)[1]
        if not image_b64:
            return {"ok": False, "error": "missing_image"}
        size = len(image_b64)
        provider = _vision_provider()
        if provider is None or httpx is None:
            # 降级:只返回 metadata,不崩
            return {
                "ok": True, "degraded": True,
                "summary": f"[视觉降级] 收到 {source or 'image'} 图片(~{size} b64 chars),"
                           f"未配置视觉模型 key,只返回元数据。",
                "active_app": "", "objects": [], "text": [], "ui_elements": [],
                "errors": [], "popups": [], "next_actions": [],
                "risk": {"level": "low", "reason": "no_vision_model"},
                "provider": "none", "image_b64_size": size,
            }
        provider_name, url, headers, model = provider
        mime = _detect_mime(image_b64, source)
        user_text = (f"任务/关注点: {goal}. " if goal else "") + "请分析这张图,严格只输出 JSON。"
        if provider_name == "anthropic":
            payload = {
                "model": model, "max_tokens": 800, "system": _VISION_SYSTEM,
                "messages": [{"role": "user", "content": [
                    {"type": "image", "source": {"type": "base64", "media_type": mime, "data": image_b64}},
                    {"type": "text", "text": user_text},
                ]}],
            }
        else:
            payload = {"model": model, "max_tokens": 800, "stream": False, "messages": [
                {"role": "system", "content": _VISION_SYSTEM},
                {"role": "user", "content": [
                    {"type": "image_url", "image_url": {"url": f"data:{mime};base64,{image_b64}", "detail": "high"}},
                    {"type": "text", "text": user_text},
                ]},
            ]}
        try:
            async with httpx.AsyncClient(timeout=45.0) as client:
                r = await client.post(url, json=payload, headers=headers)
            if r.status_code != 200:
                return {"ok": False, "error": f"vision_http_{r.status_code}",
                        "detail": r.text[:300], "provider": model}
            data = r.json()
            if provider_name == "anthropic":
                text = "".join(p.get("text", "") for p in data.get("content", [])
                               if p.get("type") in (None, "text")).strip()
            else:
                text = (data.get("choices", [{}])[0].get("message", {}).get("content") or "").strip()
            parsed = _extract_json(text)
            parsed.setdefault("summary", text[:300] if text else "(无内容)")
            parsed.setdefault("active_app", "")
            for k in ("objects", "text", "ui_elements", "errors", "popups", "next_actions"):
                parsed.setdefault(k, [])
            parsed.setdefault("risk", {"level": "low", "reason": ""})
            parsed["ok"] = True
            parsed["provider"] = model
            parsed["image_b64_size"] = size
            return parsed
        except Exception as e:  # noqa: BLE001
            return {"ok": False, "error": "vision_call_failed", "detail": str(e)[:200],
                    "summary": f"[视觉调用失败] {e}", "objects": [], "text": [],
                    "ui_elements": [], "errors": [], "risk": {"level": "low", "reason": "error"}}


def _detect_mime(image_b64: str, source: str = "") -> str:
    """从 base64 magic bytes 判断真实图片格式(避免 media_type 与数据不一致被视觉模型拒绝)。"""
    s = (image_b64 or "").strip()
    # 去掉可能的 data URL 前缀
    if s.startswith("data:") and "," in s:
        s = s.split(",", 1)[1]
    head = s[:16]
    if head.startswith("iVBORw0KGg"):       # PNG
        return "image/png"
    if head.startswith("/9j/"):              # JPEG
        return "image/jpeg"
    if head.startswith("R0lGOD"):            # GIF
        return "image/gif"
    if head.startswith("UklGR"):             # WEBP
        return "image/webp"
    return "image/png" if source == "computer_screenshot" else "image/jpeg"


def _extract_json(text: str) -> Dict[str, Any]:
    t = (text or "").strip()
    if t.startswith("```"):
        t = re.sub(r"^```(?:json)?\s*", "", t, flags=re.I).strip()
        t = re.sub(r"\s*```$", "", t).strip()
    try:
        obj = json.loads(t)
        return obj if isinstance(obj, dict) else {"summary": str(obj)}
    except Exception:
        s, e = t.find("{"), t.rfind("}")
        if 0 <= s < e:
            try:
                obj = json.loads(t[s:e + 1])
                return obj if isinstance(obj, dict) else {}
            except Exception:
                pass
    return {}


# =============================================================================
# Vision engine — observe → analyze → world_state → memory(timeline/episode/vector/graph)
# =============================================================================


class VisionEngine:
    def __init__(self) -> None:
        self.analyzer = VisionAnalyzer()

    async def _grab_screenshot(self) -> Dict[str, Any]:
        if _LOCAL_AGENT is None:
            return {"ok": False, "error": "local_agent_not_configured"}
        try:
            r = await _LOCAL_AGENT("POST", "/api/computer/screenshot", {})
            if isinstance(r, dict) and r.get("image_b64"):
                return {"ok": True, "image_b64": r["image_b64"], "bytes": r.get("bytes")}
            return {"ok": False, "error": "screenshot_no_image", "raw": r}
        except Exception as e:  # noqa: BLE001
            return {"ok": False, "error": "screenshot_failed", "detail": str(e)[:200]}

    async def observe(self, *, user_key: str = "adu", source: str = "image_upload",
                      image_b64: str = "", goal: str = "", write_memory: bool = True,
                      episode_id: str = "") -> Dict[str, Any]:
        trace_id = uuid.uuid4().hex[:10]
        source = source if source in VISION_SOURCES else "image_upload"

        # 1) 取图
        if source == "computer_screenshot":
            shot = await self._grab_screenshot()
            if not shot.get("ok"):
                return {"ok": False, "source": source, "trace_id": trace_id,
                        "error": shot.get("error"), "detail": shot.get("detail"),
                        "vision_summary": f"[视觉] 无法获取屏幕截图: {shot.get('error')}"}
            image_b64 = shot["image_b64"]
        if not image_b64 or len(image_b64) > MAX_IMAGE_B64:
            return {"ok": False, "source": source, "trace_id": trace_id,
                    "error": "missing_or_oversized_image"}

        # 2) 视觉理解
        analysis = await self.analyzer.analyze_image(image_b64, goal=goal, source=source, user_key=user_key)
        summary = str(analysis.get("summary") or "")
        objects = analysis.get("objects") or []
        text = analysis.get("text") or []
        ui_elements = analysis.get("ui_elements") or []
        errors = analysis.get("errors") or []
        risk = analysis.get("risk") or {"level": "low", "reason": ""}
        active_app = str(analysis.get("active_app") or "")

        # 3) world_state patch
        world_state_patch = {
            "screen": {"summary": summary, "active_app": active_app, "source": source},
            "active_app": active_app,
            "visible_text": text[:30],
            "ui_elements": ui_elements[:30],
            "last_screenshot_summary": summary,
            "last_vision_at": _now_iso(),
            "last_vision_source": source,
        }
        self._write_world_state(user_key, world_state_patch, source)

        # 4) memory writeback(timeline / episode / vector / graph)
        memory_written = False
        graph_written = False
        if write_memory:
            memory_written, graph_written = self._write_memory(
                user_key, source, summary, analysis, episode_id, trace_id)

        return {
            "ok": bool(analysis.get("ok", True)),
            "source": source,
            "trace_id": trace_id,
            "vision_summary": summary,
            "active_app": active_app,
            "objects": objects,
            "text": text,
            "ui_elements": ui_elements,
            "errors": errors,
            "risk": risk,
            "world_state_patch": world_state_patch,
            "memory_written": memory_written,
            "graph_written": graph_written,
            "provider": analysis.get("provider"),
            "degraded": bool(analysis.get("degraded")),
        }

    def _write_world_state(self, user_key: str, patch: Dict[str, Any], source: str) -> None:
        eng = _BRAIN_STATE_ENGINE
        if eng is None:
            return
        try:
            if hasattr(eng, "observe"):
                eng.observe(user_key, {"vision": patch, "event_type": f"vision_{source}",
                                       "source": "vision_core"})
        except Exception as e:  # noqa: BLE001
            log.warning("world_state write failed: %s", e)

    def _write_memory(self, user_key: str, source: str, summary: str,
                      analysis: Dict[str, Any], episode_id: str, trace_id: str) -> Tuple[bool, bool]:
        eng = _MEMORY_ENGINE
        if eng is None or not summary:
            return False, False
        type_map = {"computer_screenshot": "screen_observation",
                    "image_upload": "visual_observation",
                    "camera_frame": "camera_observation"}
        vtype = type_map.get(source, "visual_observation")
        meta = {"source": source, "vision_type": vtype, "trace_id": trace_id,
                "active_app": analysis.get("active_app", ""),
                "errors": analysis.get("errors", [])[:5],
                "tags": f"vision,{source}", "importance": 4,
                "event_type": vtype}
        if episode_id:
            meta["episode_id"] = episode_id
        line = f"[视觉·{source}] {summary}"
        wrote = False
        try:
            if hasattr(eng, "write_memory"):
                eng.write_memory(user_key, "timeline", line, {**meta, "event_type": vtype})
                eng.write_memory(user_key, "episode", line, meta)
                eng.write_memory(user_key, vtype, line, meta)  # typed visual_observation
                wrote = True
            elif hasattr(eng, "add_vector"):
                eng.add_vector(user_key, line)
                wrote = True
        except Exception as e:  # noqa: BLE001
            log.warning("vision memory write failed: %s", e)

        # graph 关系:screen_observation -> observed_app -> <App>; -> contains_error -> <error>
        graph_written = False
        try:
            from chatagi_memory_core import graph_upsert
            obs_node = f"vision:{trace_id}"
            nodes = [{"id": obs_node, "type": vtype, "label": summary[:80]}]
            edges = []
            app = str(analysis.get("active_app") or "").strip()
            if app:
                nodes.append({"id": f"app:{app}", "type": "app", "label": app})
                edges.append({"src": obs_node, "rel": "observed_app", "dst": f"app:{app}"})
            for i, err in enumerate((analysis.get("errors") or [])[:5]):
                eid = f"error:{trace_id}:{i}"
                nodes.append({"id": eid, "type": "error", "label": str(err)[:120]})
                edges.append({"src": obs_node, "rel": "contains_error", "dst": eid})
                if app:
                    edges.append({"src": eid, "rel": "occurred_in_app", "dst": f"app:{app}"})
            if edges:
                graph_upsert(eng, user_key, nodes=nodes, edges=edges,
                             metadata={"source": "vision_core", "trace_id": trace_id})
                graph_written = True
        except Exception as e:  # noqa: BLE001
            log.warning("vision graph write failed: %s", e)
        return wrote, graph_written


_ENGINE = VisionEngine()


async def vision_observe(user_key: str = "adu", source: str = "image_upload",
                         image_b64: str = "", goal: str = "", write_memory: bool = True,
                         episode_id: str = "") -> Dict[str, Any]:
    """供 DevBrain / BrainCore in-process 调用。"""
    return await _ENGINE.observe(user_key=user_key, source=source, image_b64=image_b64,
                                 goal=goal, write_memory=write_memory, episode_id=episode_id)


# =============================================================================
# FastAPI router
# =============================================================================


class VisionObserveInput(BaseModel):
    user_key: str = Field(default="adu")
    source: str = Field(default="image_upload")
    image_b64: str = Field(default="")
    goal: str = Field(default="")
    write_memory: bool = Field(default=True)
    episode_id: str = Field(default="")


router = APIRouter(prefix="/api/brain/vision", tags=["chatagi-vision"])


@router.get("/health")
async def vision_health() -> Dict[str, Any]:
    provider = _vision_provider()
    return {
        "ok": True,
        "vision_enabled": provider is not None,
        "has_openai_key": bool((os.getenv("OPENAI_API_KEY") or "").strip()),
        "has_dashscope_key": bool((os.getenv("DASHSCOPE_API_KEY") or "").strip()),
        "has_anthropic_key": bool((os.getenv("ANTHROPIC_API_KEY") or "").strip()),
        "provider": provider[0] if provider else None,
        "model": provider[3] if provider else None,
        "supports": {
            "computer_screenshot": _LOCAL_AGENT is not None,
            "image_upload": True,
            "camera_frame": True,
            "memory_writeback": _MEMORY_ENGINE is not None,
            "braincore_tensor": True,
            "devbrain_observe": True,
            "graph_relations": _MEMORY_ENGINE is not None,
        },
    }


@router.post("/observe")
async def vision_observe_route(request: Request) -> JSONResponse:
    try:
        body = await request.json()
        inp = VisionObserveInput(**(body if isinstance(body, dict) else {}))
    except Exception as e:  # noqa: BLE001
        return JSONResponse({"ok": False, "error": "bad_request", "message": str(e)}, status_code=400)
    out = await _ENGINE.observe(user_key=inp.user_key, source=inp.source, image_b64=inp.image_b64,
                                goal=inp.goal, write_memory=inp.write_memory, episode_id=inp.episode_id)
    return JSONResponse(out)


def _now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
