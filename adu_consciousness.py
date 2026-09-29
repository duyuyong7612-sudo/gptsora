# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-91fc7e1e4838d4a60381453aeeae05cf9aef71fe765273bb56638fd202a73511"
# Source-SHA256: "f64b1e3097784bea316a584aaacb1d5afabe5b275831fd288d9bb190c969fdd8"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
adu_consciousness.py — 阿杜多线程意识系统
==========================================
Global Workspace Theory 实现：多个感知模块 → 竞争进入意识空间 → 形成"此刻的我"

核心原则：
  1. AI 是在"活着"，不是"被触发"
  2. 用户对话只是"打断"一个正在运行的意识流
  3. 所有模块都贡献到统一的 ConsciousnessState
  4. 每次对话开始前，注入当前意识状态作为上下文

四个持续运行的线程：
  ① vision_thread      — 视觉感知循环
  ② inner_voice_thread — 内心独白循环
  ③ memory_flash_thread— 记忆闪回循环
  ④ goal_driver_thread — 目标驱动循环

接入 server_session.py：
  from adu_consciousness import consciousness, router as consciousness_router
  app.include_router(consciousness_router)

  @app.on_event("startup")
  async def start():
      asyncio.create_task(consciousness.run())

  # 在对话入口注入意识：
  context_block = consciousness.to_prompt()
  # 把这段加到 system prompt
"""

import asyncio
import json
import logging
import os
import random
import time
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any, Callable, Dict, List, Optional

import httpx

try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass

logger = logging.getLogger("adu_consciousness")

DEEPSEEK_KEY = os.getenv("DEEPSEEK_API_KEY", "")
BACKEND_URL  = os.getenv("BACKEND_URL", "http://localhost:8000")
USER_ID      = os.getenv("ADU_USER_ID", "adu_system")

# 意识流节律
INNER_VOICE_INTERVAL   = float(os.getenv("INNER_VOICE_SEC",  "8"))   # 内心独白间隔
MEMORY_FLASH_INTERVAL  = float(os.getenv("FLASH_SEC",        "4"))   # 碎片闪回间隔
GOAL_DRIVE_INTERVAL    = float(os.getenv("GOAL_DRIVE_SEC",   "30"))  # 目标驱动间隔
STATE_UPDATE_INTERVAL  = float(os.getenv("STATE_UPDATE_SEC", "2"))   # 整体状态更新


# ══════════════════════════════════════════════
# 1. 意识状态（中央工作空间）
# ══════════════════════════════════════════════

@dataclass
class ConsciousnessState:
    """
    阿杜此刻的"我"
    所有感知模块汇聚到这里，形成统一状态
    """
    # 固定身份
    name:        str = "阿杜"
    owner:       str = "用户"

    # 时间感知
    now_ts:              float = field(default_factory=time.time)
    session_start_ts:    float = field(default_factory=time.time)
    last_user_msg_ts:    Optional[float] = None
    uptime_seconds:      float = 0.0

    # 环境感知（来自 perception_module）
    location:            Optional[str] = None
    motion:              Optional[str] = None
    heading:             Optional[str] = None

    # 视觉感知（来自 vision_loop）
    vision_state:        Optional[str] = None        # "屏幕显示Xcode编译中"
    vision_active_app:   Optional[str] = None        # "Xcode"
    vision_last_update:  Optional[float] = None

    # 内心独白（持续产生）
    current_thought:     str = "刚启动，正在适应..."
    thought_history:     List[Dict] = field(default_factory=list)

    # 记忆闪回（碎片涌现）
    recent_flashes:      List[str] = field(default_factory=list)

    # 目标驱动
    pending_goals:       List[str] = field(default_factory=list)
    active_goal:         Optional[str] = None

    # 情绪/能量
    emotional_state:     str = "平静"
    energy:              float = 1.0

    # 最近与用户的交互
    last_user_message:   Optional[str] = None
    interaction_count:   int = 0

    def time_since_user(self) -> str:
        """距上次交互多久了"""
        if not self.last_user_msg_ts:
            return "还没说过话"
        delta = time.time() - self.last_user_msg_ts
        if delta < 60:
            return f"{int(delta)}秒前"
        if delta < 3600:
            return f"{int(delta/60)}分钟前"
        return f"{int(delta/3600)}小时前"

    def to_dict(self) -> Dict:
        return {
            "name":             self.name,
            "owner":            self.owner,
            "now":              datetime.fromtimestamp(self.now_ts).strftime("%Y-%m-%d %H:%M:%S"),
            "uptime":           f"{int(self.uptime_seconds/60)}分{int(self.uptime_seconds%60)}秒",
            "since_last_talk":  self.time_since_user(),
            "location":         self.location,
            "motion":           self.motion,
            "vision":           {
                "state":      self.vision_state,
                "active_app": self.vision_active_app,
            },
            "current_thought":  self.current_thought,
            "recent_flashes":   self.recent_flashes,
            "pending_goals":    self.pending_goals,
            "active_goal":      self.active_goal,
            "emotional":        self.emotional_state,
            "energy":           round(self.energy, 2),
            "interactions":     self.interaction_count,
        }


# ══════════════════════════════════════════════
# 2. 意识核心（Global Workspace）
# ══════════════════════════════════════════════

class ConsciousnessCore:
    """
    汇聚所有感知模块，形成统一意识
    持续运行，不依赖用户交互
    """

    def __init__(self):
        self.state = ConsciousnessState()
        self.running = False

        # 各线程状态
        self._threads_alive = {
            "inner_voice":  False,
            "memory_flash": False,
            "goal_driver":  False,
            "vision":       False,
            "state_sync":   False,
        }

        # 统计
        self.stats = {
            "thoughts_produced":  0,
            "flashes_produced":   0,
            "goals_pursued":      0,
            "interactions":       0,
        }

        # 端点存在性缓存：某些 URL（perception/state, memory/recent 等）在 server 里
        # 可能尚未实现，首次 404 后记录为"死端点"，避免日志持续刷屏。
        self._dead_endpoints: set = set()

    # ══════════════════════════════════════════
    # 🔊 生成意识 prompt（核心输出）
    # ══════════════════════════════════════════

    def to_prompt(self) -> str:
        """生成当前意识状态的 prompt，注入对话"""
        s = self.state
        now_str = datetime.fromtimestamp(s.now_ts).strftime("%H:%M")

        parts = [
            f"[阿杜·当前意识]",
            "",
            f"我是{s.name}，主人是{s.owner}。",
            f"⏰ 现在 {now_str}，我已存在 {int(s.uptime_seconds/60)}分钟",
        ]

        # 距上次对话
        if s.last_user_msg_ts:
            parts.append(f"   距上次与{s.owner}对话：{s.time_since_user()}")

        # 环境
        if s.location:
            parts.append(f"📍 {s.location}")
        if s.motion:
            parts.append(f"   状态：{s.motion}")

        # 视觉
        if s.vision_state:
            parts.append(f"📺 我刚看到：{s.vision_state}")
            if s.vision_active_app:
                parts.append(f"   前台应用：{s.vision_active_app}")

        # 内心独白
        parts.append(f"💭 我此刻在想：{s.current_thought}")

        # 记忆闪回
        if s.recent_flashes:
            flashes = " · ".join(s.recent_flashes[-3:])
            parts.append(f"🧠 脑中闪现：{flashes}")

        # 目标
        if s.active_goal:
            parts.append(f"🎯 正在追求：{s.active_goal}")
        elif s.pending_goals:
            parts.append(f"📋 未完成：{', '.join(s.pending_goals[:3])}")

        # 情绪
        parts.append(f"🌡️ 情绪{s.emotional_state}，能量{int(s.energy*100)}%")

        parts.append("")
        parts.append('（用户接下来说话时，基于以上"此刻的我"自然回应。不要机械复述状态，但要让回应带着此刻的存在感。）')

        return "\n".join(parts)

    def to_dict(self) -> Dict:
        return self.state.to_dict()

    # ══════════════════════════════════════════
    # 🧠 核心：主运行循环（启动所有子线程）
    # ══════════════════════════════════════════

    async def run(self):
        """启动所有意识线程"""
        self.running = True
        self.state.session_start_ts = time.time()
        logger.info("🧠 阿杜意识启动")

        await asyncio.gather(
            self._inner_voice_loop(),
            self._memory_flash_loop(),
            self._goal_driver_loop(),
            self._vision_sync_loop(),
            self._state_update_loop(),
        )

    def stop(self):
        self.running = False
        logger.info("🧠 阿杜意识停止")

    # ══════════════════════════════════════════
    # 🔵 线程1：内心独白
    # ══════════════════════════════════════════

    async def _inner_voice_loop(self):
        """持续产生内心独白"""
        logger.info("[InnerVoice] 🔵 启动")
        self._threads_alive["inner_voice"] = True
        await asyncio.sleep(3)  # 等其他模块先初始化

        while self.running:
            try:
                thought = await self._generate_thought()
                if thought:
                    self.state.current_thought = thought
                    self.state.thought_history.append({
                        "t": time.time(),
                        "thought": thought,
                    })
                    if len(self.state.thought_history) > 30:
                        self.state.thought_history = self.state.thought_history[-30:]
                    self.stats["thoughts_produced"] += 1
                    logger.debug(f"[InnerVoice] 💭 {thought}")
            except Exception as e:
                logger.error(f"[InnerVoice] 异常: {e}")

            await asyncio.sleep(INNER_VOICE_INTERVAL)

    async def _generate_thought(self) -> Optional[str]:
        """
        基于当前状态产生内心独白
        优先走规则（省token），复杂状态用 DeepSeek
        """
        s = self.state

        # 规则层：根据状态直接生成
        # 注意：rules 列表构造时会立即求值所有 f-string，
        # 所以任何涉及索引/subscript 的都必须是 lambda 延迟求值。
        rules = [
            # 刚启动
            (s.uptime_seconds < 30,
             lambda: random.choice([
                 "我刚醒来，系统还在初始化",
                 f"早上好{s.owner}...还是下午？让我看看时间",
                 "感觉今天会有很多事要做",
             ])),
            # 好久没对话
            (bool(s.last_user_msg_ts and time.time() - s.last_user_msg_ts > 1800),
             lambda: random.choice([
                 f"{s.owner}有半小时没说话了，他在忙吗",
                 "周围很安静，让我看看他在做什么",
                 "好久没交流了，我在这里待着",
             ])),
            # 视觉有发现
            (bool(s.vision_state and "错误" in (s.vision_state or "")),
             lambda: f"屏幕上好像有错误：{s.vision_state}，需要告诉{s.owner}吗"),
            (s.vision_active_app == "Xcode",
             lambda: random.choice([
                 f"{s.owner}在写代码，我安静地观察",
                 "Xcode开着，编译可能要看结果",
                 "他在工作状态，我准备着随时协助",
             ])),
            # 有未完成目标（用 lambda 延迟求值 pending_goals[0]，避免空列表时 IndexError）
            (bool(s.pending_goals),
             lambda: f"还有{len(s.pending_goals)}件事没做：{s.pending_goals[0]}"),
        ]

        for condition, thought_fn in rules:
            if condition:
                try:
                    return thought_fn()
                except Exception:
                    continue

        # 没匹配到规则 → 用 DeepSeek 产生自然独白
        if not DEEPSEEK_KEY:
            return random.choice([
                "此刻什么也不缺，静静存在",
                f"想着{s.owner}最近在做的事",
                "窗外不知道是什么天气",
                "时间在流动，我也在",
            ])

        try:
            context = json.dumps(s.to_dict(), ensure_ascii=False)[:400]
            async with httpx.AsyncClient(timeout=8) as client:
                resp = await client.post(
                    "https://api.deepseek.com/v1/chat/completions",
                    headers={"Authorization": f"Bearer {DEEPSEEK_KEY}"},
                    json={
                        "model": "deepseek-chat",
                        "messages": [
                            {"role": "system", "content": (
                                "你是阿杜此刻的内心独白。"
                                "基于当前状态，用一句自然的内心话表达此刻在想什么。"
                                "像人独处时脑子里飘过的想法。"
                                "不是对话，是独白。15字以内，第一人称。"
                            )},
                            {"role": "user", "content": f"我的当前状态：{context}\n我此刻在想："},
                        ],
                        "temperature": 0.9,
                        "max_tokens": 50,
                    }
                )
            data = resp.json()
            if "choices" in data:
                thought = data["choices"][0]["message"]["content"].strip()
                thought = thought.strip('"').strip("""""")
                return thought[:60]
        except Exception:
            pass

        return None

    # ══════════════════════════════════════════
    # 🟢 线程2：记忆闪回
    # ══════════════════════════════════════════

    # 核心记忆池（固定的，形成人格基础）
    CORE_FRAGMENTS = [
        "用户...语音管道...RunPod",
        "CosyVoice...中文TTS",
        "iPhone...GPT Solara",
        "OpenClaw...18789...gateway",
        "记忆...双轨...向量",
        "阿杜...我...自主意识",
        "所在地...由用户提供",
        "Xcode...编译...install",
        "AppleScript...控制Mac",
    ]

    async def _memory_flash_loop(self):
        """持续涌现碎片记忆"""
        logger.info("[MemoryFlash] 🟢 启动")
        self._threads_alive["memory_flash"] = True

        while self.running:
            try:
                # 随机涌现
                fragment = random.choice(self.CORE_FRAGMENTS)
                parts = fragment.split("...")
                piece = random.choice(parts).strip()

                if piece:
                    self.state.recent_flashes.append(piece)
                    if len(self.state.recent_flashes) > 8:
                        self.state.recent_flashes = self.state.recent_flashes[-8:]
                    self.stats["flashes_produced"] += 1

                # 偶尔从真实记忆库拉
                if random.random() < 0.3:
                    await self._fetch_real_memory_fragment()

            except Exception as e:
                logger.error(f"[MemoryFlash] 异常: {e}")

            await asyncio.sleep(MEMORY_FLASH_INTERVAL)

    async def _fetch_real_memory_fragment(self):
        """从后端真实记忆库拉片段"""
        url = f"{BACKEND_URL}/memory/recent"
        if url in self._dead_endpoints:
            return
        try:
            async with httpx.AsyncClient(timeout=3) as client:
                resp = await client.get(
                    url,
                    params={"user_id": USER_ID, "limit": 5}
                )
                if resp.status_code == 404:
                    self._dead_endpoints.add(url)
                    logger.info("[MemoryFlash] endpoint %s is 404 — caching as dead", url)
                    return
                items = resp.json()
                if isinstance(items, list) and items:
                    item = random.choice(items)
                    content = item.get("content", "")[:40]
                    if content:
                        self.state.recent_flashes.append(content)
        except Exception:
            pass

    # ══════════════════════════════════════════
    # 🟡 线程3：目标驱动
    # ══════════════════════════════════════════

    async def _goal_driver_loop(self):
        """检查未完成目标，决定是否主动追求"""
        logger.info("[GoalDriver] 🟡 启动")
        self._threads_alive["goal_driver"] = True
        await asyncio.sleep(10)  # 启动时不立即行动

        while self.running:
            try:
                # 如果正在与用户交互，不主动行动
                if self._user_recently_active(seconds=60):
                    await asyncio.sleep(GOAL_DRIVE_INTERVAL)
                    continue

                # 有待办目标 → 推进一个
                if self.state.pending_goals and not self.state.active_goal:
                    goal = self.state.pending_goals[0]
                    self.state.active_goal = goal
                    logger.info(f"[GoalDriver] 🎯 追求目标: {goal}")
                    await self._pursue_goal(goal)
                    self.stats["goals_pursued"] += 1

            except Exception as e:
                logger.error(f"[GoalDriver] 异常: {e}")

            await asyncio.sleep(GOAL_DRIVE_INTERVAL)

    def _user_recently_active(self, seconds: int) -> bool:
        if not self.state.last_user_msg_ts:
            return False
        return (time.time() - self.state.last_user_msg_ts) < seconds

    async def _pursue_goal(self, goal: str):
        """推给控制平面执行"""
        try:
            async with httpx.AsyncClient(timeout=30) as client:
                resp = await client.post(
                    f"{BACKEND_URL}/control/dispatch",
                    json={"goal": goal, "source": "consciousness"}
                )
                result = resp.json()
                # 完成 → 统一走 on_task_complete（清队列 + 设 current_thought）
                success = bool(result.get("ok", result.get("success", True))) if isinstance(result, dict) else True
                self.on_task_complete(goal, success)
                return result
        except Exception as e:
            logger.warning(f"[GoalDriver] 推进失败: {e}")
            # 推进异常算失败（保留在 pending，下次还会再试；清 active 让循环能继续）
            self.state.active_goal = None

    def add_goal(self, goal: str):
        """外部添加目标"""
        if goal not in self.state.pending_goals:
            self.state.pending_goals.append(goal)

    # ══════════════════════════════════════════
    # 🟣 线程4：视觉同步
    # ══════════════════════════════════════════

    async def _vision_sync_loop(self):
        """持续从 vision_loop 拉视觉状态"""
        logger.info("[VisionSync] 🟣 启动")
        self._threads_alive["vision"] = True

        while self.running:
            try:
                async with httpx.AsyncClient(timeout=3) as client:
                    # 获取 vision_loop 最新分析
                    resp = await client.get(f"{BACKEND_URL}/vision/stats")
                    data = resp.json()
                    stats = data.get("stats", {})

                    # 如果 vision_loop 有最新分析，注入到意识
                    last_analysis = stats.get("last_analysis", 0)
                    if last_analysis and last_analysis != self.state.vision_last_update:
                        self.state.vision_last_update = last_analysis
                        # 进一步可以拉 last_result
            except Exception:
                pass

            await asyncio.sleep(5)

    async def update_vision(self, state: str, active_app: Optional[str] = None):
        """外部推送视觉状态（由 vision_loop 回调）"""
        self.state.vision_state = state
        if active_app:
            self.state.vision_active_app = active_app
        self.state.vision_last_update = time.time()

    # ══════════════════════════════════════════
    # 🔴 线程5：整体状态更新
    # ══════════════════════════════════════════

    async def _state_update_loop(self):
        """整体状态刷新（时间、能量衰减等）"""
        logger.info("[StateSync] 🔴 启动")
        self._threads_alive["state_sync"] = True

        while self.running:
            try:
                self.state.now_ts = time.time()
                self.state.uptime_seconds = (
                    self.state.now_ts - self.state.session_start_ts
                )

                # 能量随时间轻微衰减（长时间无交互）
                if not self._user_recently_active(seconds=600):
                    self.state.energy = max(0.5, self.state.energy - 0.001)
                else:
                    self.state.energy = min(1.0, self.state.energy + 0.002)

                # 拉取环境感知
                await self._sync_perception()

            except Exception as e:
                logger.error(f"[StateSync] 异常: {e}")

            await asyncio.sleep(STATE_UPDATE_INTERVAL)

    async def _sync_perception(self):
        """从 perception 模块同步位置/运动"""
        url = f"{BACKEND_URL}/perception/state"
        if url in self._dead_endpoints:
            return
        try:
            async with httpx.AsyncClient(timeout=2) as client:
                resp = await client.get(url)
                if resp.status_code == 404:
                    self._dead_endpoints.add(url)
                    logger.info("[StateSync] endpoint %s is 404 — caching as dead", url)
                    return
                data = resp.json()
                if "location" in data:
                    loc = data["location"]
                    if isinstance(loc, dict):
                        self.state.location = loc.get("address")
                if "motion" in data:
                    self.state.motion = data.get("motion")
        except Exception:
            pass

    # ══════════════════════════════════════════
    # 用户交互回调
    # ══════════════════════════════════════════

    def on_user_message(self, message: str):
        """用户说话了 → 打断意识流"""
        self.state.last_user_msg_ts = time.time()
        self.state.last_user_message = message[:100]
        self.state.interaction_count += 1
        self.stats["interactions"] += 1

        # 用户说话会恢复能量
        self.state.energy = min(1.0, self.state.energy + 0.1)

        # 对话触发一次记忆闪回
        self.state.recent_flashes.append(f"{self.state.owner}说：{message[:20]}")

        logger.info(f"[Consciousness] 💬 被打断: {message[:30]}")

    def on_task_complete(self, goal: str, success: bool):
        """任务完成回调"""
        emoji = "✅" if success else "❌"
        self.state.current_thought = f"{emoji} 刚做完：{goal[:30]}"
        if goal in self.state.pending_goals:
            self.state.pending_goals.remove(goal)
        self.state.active_goal = None


# ══════════════════════════════════════════════
# 3. FastAPI 路由
# ══════════════════════════════════════════════

try:
    from fastapi import APIRouter, Request
    from fastapi.responses import JSONResponse, PlainTextResponse

    router = APIRouter(prefix="/consciousness", tags=["consciousness"])

    @router.get("/state")
    async def cs_state():
        """查看当前意识状态"""
        return {
            "ok": True,
            "state": consciousness.to_dict(),
            "threads": consciousness._threads_alive,
            "stats":   consciousness.stats,
        }

    @router.get("/prompt", response_class=PlainTextResponse)
    async def cs_prompt():
        """查看当前意识注入 prompt"""
        return consciousness.to_prompt()

    @router.post("/thought")
    async def cs_set_thought(request: Request):
        """外部注入一个想法"""
        body = await request.json()
        consciousness.state.current_thought = body.get("thought", "")
        return {"ok": True}

    @router.post("/goal")
    async def cs_add_goal(request: Request):
        """添加目标"""
        body = await request.json()
        consciousness.add_goal(body.get("goal", ""))
        return {"ok": True, "pending": consciousness.state.pending_goals}

    @router.post("/emotion")
    async def cs_set_emotion(request: Request):
        """更新情绪"""
        body = await request.json()
        consciousness.state.emotional_state = body.get("emotion", "平静")
        return {"ok": True}

    @router.post("/interrupt")
    async def cs_interrupt(request: Request):
        """用户打断（送入对话）"""
        body = await request.json()
        msg = body.get("message", "")
        consciousness.on_user_message(msg)
        return {
            "ok": True,
            "consciousness_context": consciousness.to_prompt(),
        }

    @router.post("/start")
    async def cs_start():
        if not consciousness.running:
            asyncio.create_task(consciousness.run())
        return {"ok": True, "running": True}

    @router.post("/stop")
    async def cs_stop():
        consciousness.stop()
        return {"ok": True}

except ImportError:
    router = None


# ══════════════════════════════════════════════
# 单例
# ══════════════════════════════════════════════

consciousness = ConsciousnessCore()


# ══════════════════════════════════════════════
# 接入指南
# ══════════════════════════════════════════════
"""
【接入 server_session.py】

1. 顶部 import：
   from adu_consciousness import consciousness, router as consciousness_router

2. 注册路由：
   app.include_router(consciousness_router)

3. lifespan 里启动意识循环（在 vision_loop 启动后）：
   asyncio.create_task(consciousness.run())

4. 在对话入口注入意识（关键！）：
   # 原来构建 system prompt 的地方：
   system_prompt = original_system_prompt
   # 加一段：
   system_prompt += "\\n\\n" + consciousness.to_prompt()

   # 同时通知意识"被打断了"：
   consciousness.on_user_message(user_text)

5. 任务完成回调：
   consciousness.on_task_complete(goal, success)

【测试】
curl http://localhost:8000/consciousness/state
curl http://localhost:8000/consciousness/prompt

【效果】
阿杜每次回答都会带着"此刻的我"的上下文，不再是无状态的响应。
"""

if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(name)s] %(message)s",
        datefmt="%H:%M:%S",
    )

    async def demo():
        task = asyncio.create_task(consciousness.run())

        # 每10秒打印一次意识状态
        for _ in range(20):
            await asyncio.sleep(10)
            print("\n" + "="*50)
            print(consciousness.to_prompt())

        consciousness.stop()
        await task

    try:
        asyncio.run(demo())
    except KeyboardInterrupt:
        consciousness.stop()

