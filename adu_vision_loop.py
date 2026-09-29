# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-52e687f1268245fd84ca4a457595c656f5454fd7521dae0d1f8246722ae7b180"
# Source-SHA256: "62c1aad5fe1747a3f141d2954551ff838e8a294d5732470645dff24a9daf1935"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
adu_vision_loop.py — 助手视觉主动监控
=======================================
给助手装眼睛：持续订阅屏幕帧流，看到变化自动分析，触发下一步行动。

架构：
  adu_screen_streamer.py（推帧）
      ↓ MJPEG /snapshot
  VisionLoop（取帧 + 变化检测）
      ↓ 有变化时
  GPT-4o Vision（看图分析）
      ↓ 分析结果
  adu_control_plane（触发行动 or 汇报）

运行方式：
  python3 adu_vision_loop.py

或接入后端：
  from adu_vision_loop import vision_loop
  asyncio.create_task(vision_loop.start())
"""

import asyncio
import base64
import hashlib
import io
import json
import logging
import os
import time
from dataclasses import dataclass, field
from typing import Callable, Dict, List, Optional, Tuple

import httpx

logger = logging.getLogger("adu_vision")

# ── 配置 ──────────────────────────────────────
OPENAI_KEY      = os.getenv("OPENAI_API_KEY", "")
SNAPSHOT_URL    = os.getenv("SNAPSHOT_URL", "http://localhost:7788/snapshot")
BACKEND_URL     = os.getenv("BACKEND_URL", "http://localhost:8000")
USER_ID         = os.getenv("ADU_USER_ID", "adu_system")

POLL_INTERVAL   = float(os.getenv("VISION_POLL_SEC",    "2"))    # 取帧间隔（秒）
CHANGE_THRESHOLD = float(os.getenv("VISION_CHANGE_THR", "0.08")) # 变化阈值（0-1）
ANALYZE_COOLDOWN = float(os.getenv("VISION_COOLDOWN",   "5"))    # 分析冷却（秒）
MAX_HISTORY     = int(os.getenv("VISION_HISTORY",       "5"))    # 保留历史帧数


# ══════════════════════════════════════════════
# 1. 帧差检测
#    比较两帧的差异，判断屏幕是否有变化
# ══════════════════════════════════════════════

def frame_hash(jpeg_bytes: bytes) -> str:
    """快速感知哈希：把图片缩小后取 MD5"""
    try:
        from PIL import Image  # type: ignore
        img = Image.open(io.BytesIO(jpeg_bytes)).convert("L").resize((32, 18))
        return hashlib.md5(img.tobytes()).hexdigest()
    except Exception:
        # 没有 PIL，直接用文件哈希
        return hashlib.md5(jpeg_bytes[:4096]).hexdigest()

def frame_diff(bytes_a: bytes, bytes_b: bytes) -> float:
    """
    计算两帧差异度（0.0=完全相同，1.0=完全不同）
    用像素级差值估算
    """
    try:
        from PIL import Image, ImageChops  # type: ignore
        img_a = Image.open(io.BytesIO(bytes_a)).convert("L").resize((64, 36))
        img_b = Image.open(io.BytesIO(bytes_b)).convert("L").resize((64, 36))
        diff  = ImageChops.difference(img_a, img_b)
        pixels = list(diff.getdata())
        return sum(pixels) / (len(pixels) * 255)
    except Exception:
        # PIL 不可用，用哈希比较（只能判断有无变化，不能量化）
        h_a = hashlib.md5(bytes_a[:8192]).hexdigest()
        h_b = hashlib.md5(bytes_b[:8192]).hexdigest()
        return 0.0 if h_a == h_b else 0.5


# ══════════════════════════════════════════════
# 2. 视觉分析器
#    把帧发给 GPT-4o，让它描述屏幕内容
# ══════════════════════════════════════════════

VISION_SYSTEM = """你是阿杜的眼睛，负责观察 Mac 屏幕并汇报。

分析屏幕截图，输出 JSON：
{
  "screen_state": "简短描述屏幕当前状态（1句话）",
  "active_app": "当前前台应用名",
  "task_status": "success|failed|in_progress|idle|unknown",
  "needs_action": true/false,
  "suggested_action": "如果需要行动，建议做什么（否则null）",
  "confidence": 0.0-1.0,
  "details": "更多细节（可选）"
}

判断标准：
- 看到错误弹窗/警告 → needs_action=true, task_status=failed
- 看到进度条/加载中 → task_status=in_progress
- 看到成功提示/完成状态 → task_status=success
- 屏幕无明显变化/空闲 → task_status=idle
- 看到需要用户输入的对话框 → needs_action=true

只输出JSON，不要解释。"""

class VisionAnalyzer:

    def __init__(self):
        self._last_analysis_time: float = 0
        self._last_result: Optional[Dict] = None

    async def analyze(self, frame: bytes, context: str = "") -> Optional[Dict]:
        """
        把帧发给 GPT-4o 分析
        context: 当前正在执行的任务描述
        """
        if not OPENAI_KEY:
            logger.warning("[Vision] 没有 OPENAI_API_KEY，跳过视觉分析")
            return None

        b64 = base64.b64encode(frame).decode()
        prompt = f"分析这个Mac屏幕截图。"
        if context:
            prompt += f"\n当前任务背景：{context}"

        try:
            async with httpx.AsyncClient(timeout=15) as client:
                resp = await client.post(
                    "https://api.openai.com/v1/chat/completions",
                    headers={"Authorization": f"Bearer {OPENAI_KEY}"},
                    json={
                        "model": "gpt-4o",
                        "messages": [{
                            "role": "user",
                            "content": [
                                {"type": "text",      "text": prompt},
                                {"type": "image_url", "image_url": {
                                    "url":    f"data:image/jpeg;base64,{b64}",
                                    "detail": "low",   # 省 token
                                }},
                            ]
                        }],
                        "response_format": {"type": "json_object"},
                        "max_tokens": 200,
                    }
                )
            raw = resp.json()["choices"][0]["message"]["content"]
            result = json.loads(raw)
            self._last_result = result
            self._last_analysis_time = time.time()
            return result

        except Exception as e:
            logger.error(f"[Vision] 分析失败: {e}")
            return None

    async def quick_verify(self, frame: bytes, task_desc: str) -> Tuple[bool, str]:
        """
        快速验证任务是否完成（比 analyze 更轻量）
        返回 (success, reason)
        """
        result = await self.analyze(frame, context=f"验证任务是否完成：{task_desc}")
        if not result:
            return False, "视觉分析失败"

        status = result.get("task_status", "unknown")
        screen = result.get("screen_state", "")

        if status == "success":
            return True, f"✅ 视觉确认成功: {screen}"
        elif status == "failed":
            return False, f"❌ 视觉发现失败: {screen}"
        elif status == "in_progress":
            return False, f"⏳ 仍在进行中: {screen}"
        else:
            return False, f"❓ 状态不明: {screen}"


# ══════════════════════════════════════════════
# 3. 视觉主动监控循环
# ══════════════════════════════════════════════

@dataclass
class VisionEvent:
    """视觉事件"""
    event_type:       str    # change_detected / task_done / error_found / needs_input
    screen_state:     str
    task_status:      str
    needs_action:     bool
    suggested_action: Optional[str]
    frame_diff:       float
    timestamp:        float = field(default_factory=time.time)
    frame_b64:        Optional[str] = None  # 可选：附带截图


class VisionLoop:
    """
    助手的眼睛：持续监控屏幕，检测变化，分析状态，触发行动
    """

    def __init__(self):
        self.analyzer       = VisionAnalyzer()
        self.running        = False

        # 帧历史
        self._frame_history: List[bytes]  = []
        self._last_frame:    Optional[bytes] = None
        self._last_hash:     str = ""

        # 分析状态
        self._last_analyze_time: float = 0
        self._current_task:      str   = ""  # 当前监控的任务

        # 事件回调
        self._on_event_callbacks: List[Callable] = []
        self._on_action_callbacks: List[Callable] = []

        # 统计
        self.stats = {
            "frames_captured": 0,
            "changes_detected": 0,
            "analyses_done": 0,
            "actions_triggered": 0,
        }

    # ── 回调注册 ────────────────────────────────

    def on_event(self, callback: Callable):
        """注册视觉事件回调"""
        self._on_event_callbacks.append(callback)

    def on_action_needed(self, callback: Callable):
        """注册需要行动时的回调"""
        self._on_action_callbacks.append(callback)

    def set_task_context(self, task: str):
        """设置当前正在执行的任务（给视觉分析提供上下文）"""
        self._current_task = task
        logger.info(f"[Vision] 监控任务: {task}")

    # ── 帧获取 ──────────────────────────────────

    async def _fetch_frame(self) -> Optional[bytes]:
        """从推流服务取一帧"""
        try:
            async with httpx.AsyncClient(timeout=3) as client:
                resp = await client.get(SNAPSHOT_URL)
                if resp.status_code == 200:
                    return resp.content
        except Exception:
            pass
        return None

    # ── 变化检测 ────────────────────────────────

    def _detect_change(self, new_frame: bytes) -> Tuple[bool, float]:
        """检测屏幕是否有显著变化"""
        if not self._last_frame:
            return True, 1.0

        new_hash = frame_hash(new_frame)
        if new_hash == self._last_hash:
            return False, 0.0

        diff = frame_diff(self._last_frame, new_frame)
        changed = diff > CHANGE_THRESHOLD
        return changed, diff

    # ── 主循环 ──────────────────────────────────

    async def start(self):
        """启动视觉监控循环"""
        self.running = True
        logger.info(f"[Vision] 👁 视觉监控启动 (间隔{POLL_INTERVAL}s, 阈值{CHANGE_THRESHOLD})")

        while self.running:
            try:
                await self._tick()
            except Exception as e:
                logger.error(f"[Vision] 循环异常: {e}")
            await asyncio.sleep(POLL_INTERVAL)

    async def _tick(self):
        """单次监控周期"""
        # 1. 取帧
        frame = await self._fetch_frame()
        if not frame:
            return

        self.stats["frames_captured"] += 1

        # 2. 变化检测
        changed, diff = self._detect_change(frame)

        # 更新帧历史
        self._last_frame = frame
        self._last_hash  = frame_hash(frame)
        self._frame_history.append(frame)
        if len(self._frame_history) > MAX_HISTORY:
            self._frame_history.pop(0)

        if not changed:
            return

        self.stats["changes_detected"] += 1
        logger.info(f"[Vision] 🔍 检测到变化 diff={diff:.3f}")

        # 3. 冷却检查（避免频繁调用 GPT-4o）
        now = time.time()
        if now - self._last_analyze_time < ANALYZE_COOLDOWN:
            logger.debug("[Vision] 冷却中，跳过分析")
            return

        # 4. GPT-4o 分析
        self._last_analyze_time = now
        result = await self.analyzer.analyze(frame, context=self._current_task)
        if not result:
            return

        self.stats["analyses_done"] += 1

        # 5. 生成视觉事件
        event = VisionEvent(
            event_type    = self._classify_event(result),
            screen_state  = result.get("screen_state", ""),
            task_status   = result.get("task_status", "unknown"),
            needs_action  = result.get("needs_action", False),
            suggested_action = result.get("suggested_action"),
            frame_diff    = diff,
            frame_b64     = base64.b64encode(frame).decode() if result.get("needs_action") else None,
        )

        logger.info(f"[Vision] 📺 {event.screen_state} | 状态={event.task_status} | 需要行动={event.needs_action}")

        # 6. 触发回调
        for cb in self._on_event_callbacks:
            try:
                await cb(event)
            except Exception as e:
                logger.error(f"[Vision] 事件回调失败: {e}")

        # 7. 如果需要行动，推给控制平面
        if event.needs_action and event.suggested_action:
            self.stats["actions_triggered"] += 1
            logger.info(f"[Vision] 🎯 触发行动: {event.suggested_action}")
            await self._trigger_action(event)

    def _classify_event(self, result: Dict) -> str:
        status = result.get("task_status", "")
        needs  = result.get("needs_action", False)
        if status == "failed":
            return "error_found"
        if status == "success":
            return "task_done"
        if needs:
            return "needs_input"
        if status == "in_progress":
            return "change_detected"
        return "change_detected"

    async def _trigger_action(self, event: VisionEvent):
        """把视觉发现的行动需求推给控制平面"""
        try:
            async with httpx.AsyncClient(timeout=30) as client:
                await client.post(
                    f"{BACKEND_URL}/control/dispatch",
                    json={
                        "goal":   event.suggested_action,
                        "source": "vision_loop",
                    }
                )
        except Exception as e:
            logger.error(f"[Vision] 触发行动失败: {e}")

        for cb in self._on_action_callbacks:
            try:
                await cb(event)
            except Exception as e:
                logger.error(f"[Vision] 行动回调失败: {e}")

    # ── 外部接口 ────────────────────────────────

    def stop(self):
        self.running = False
        logger.info("[Vision] 👁 视觉监控停止")

    async def capture_and_analyze(self, task: str = "") -> Optional[Dict]:
        """立即截图并分析（供外部调用）"""
        frame = await self._fetch_frame()
        if not frame:
            return {"error": "无法获取屏幕截图，请确认推流服务在运行"}
        return await self.analyzer.analyze(frame, context=task)

    async def verify_task(self, task_desc: str) -> Tuple[bool, str]:
        """验证任务是否完成（供控制平面调用）"""
        frame = await self._fetch_frame()
        if not frame:
            return False, "无法获取截图"
        return await self.analyzer.quick_verify(frame, task_desc)

    def get_stats(self) -> Dict:
        return {
            **self.stats,
            "running":       self.running,
            "current_task":  self._current_task,
            "last_analysis": self._last_analyze_time,
        }


# ══════════════════════════════════════════════
# 4. FastAPI 路由
# ══════════════════════════════════════════════

try:
    from fastapi import APIRouter, Request
    from fastapi.responses import JSONResponse

    router = APIRouter(prefix="/vision", tags=["vision-loop"])

    @router.post("/analyze")
    async def vision_analyze(request: Request):
        """立即截图并分析"""
        body = await request.json()
        task = body.get("task", "")
        result = await vision_loop.capture_and_analyze(task)
        return {"ok": True, "result": result}

    @router.post("/verify")
    async def vision_verify(request: Request):
        """验证任务是否完成"""
        body = await request.json()
        task = body.get("task", "")
        success, reason = await vision_loop.verify_task(task)
        return {"ok": True, "success": success, "reason": reason}

    @router.post("/watch")
    async def vision_watch(request: Request):
        """设置当前监控任务"""
        body = await request.json()
        task = body.get("task", "")
        vision_loop.set_task_context(task)
        return {"ok": True, "watching": task}

    @router.get("/stats")
    async def vision_stats():
        return {"ok": True, "stats": vision_loop.get_stats()}

    @router.post("/start")
    async def vision_start():
        if not vision_loop.running:
            asyncio.create_task(vision_loop.start())
        return {"ok": True, "running": True}

    @router.post("/stop")
    async def vision_stop():
        vision_loop.stop()
        return {"ok": True, "running": False}

except ImportError:
    router = None


# ══════════════════════════════════════════════
# 单例
# ══════════════════════════════════════════════

vision_loop = VisionLoop()


# ══════════════════════════════════════════════
# server_session.py 接入
# ══════════════════════════════════════════════
"""
【接入步骤】

1. from adu_vision_loop import vision_loop, router as vision_router
2. app.include_router(vision_router)

3. 启动时开启视觉监控：
   @app.on_event("startup")
   async def start_vision():
       asyncio.create_task(vision_loop.start())

4. 控制平面执行完任务后自动视觉验证：
   # 在 adu_control_plane.py 的 dispatch() 末尾加：
   success, reason = await vision_loop.verify_task(goal)
   result.observation += f"\n视觉验证: {reason}"

5. 注册事件回调（推送给手机）：
   async def on_vision_event(event):
       await push_to_client(user_id, {
           "type": "vision_event",
           "screen_state": event.screen_state,
           "needs_action": event.needs_action,
           "suggested": event.suggested_action,
       })
   vision_loop.on_event(on_vision_event)

【测试命令】
# 立即截图分析
curl -X POST http://localhost:8000/vision/analyze \\
  -H "Content-Type: application/json" \\
  -d '{"task": "检查编译是否成功"}'

# 验证任务
curl -X POST http://localhost:8000/vision/verify \\
  -H "Content-Type: application/json" \\
  -d '{"task": "微信消息是否发送成功"}'

# 启动持续监控
curl -X POST http://localhost:8000/vision/start

# 查看统计
curl http://localhost:8000/vision/stats
"""

if __name__ == "__main__":
    import signal
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [Vision] %(message)s",
        datefmt="%H:%M:%S",
    )

    async def on_event(event: VisionEvent):
        print(f"\n🎬 视觉事件: {event.event_type}")
        print(f"   屏幕: {event.screen_state}")
        print(f"   状态: {event.task_status}")
        if event.needs_action:
            print(f"   ⚡ 建议行动: {event.suggested_action}")

    vision_loop.on_event(on_event)

    def _stop(sig, frame):
        vision_loop.stop()

    signal.signal(signal.SIGINT,  _stop)
    signal.signal(signal.SIGTERM, _stop)

    logger.info("视觉监控启动（确保 adu_screen_streamer.py 在运行）")
    asyncio.run(vision_loop.start())
