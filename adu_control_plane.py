# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-ba63013a29eb737123b1d1d13f79a6150ec24557d0d6a671eccb7b04f9ee6d64"
# Source-SHA256: "13115e6c456d44c6212769b7129af2d7dfb07b58167fefc00f2d7ee7d94c0c09"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
adu_control_plane.py — Adu 控制平面
=====================================
App 控制 OpenClaw 的协议层

架构位置：
  右脑（意图）→ 控制平面（协议/风险/确认）→ OpenClaw（执行）

三层职责：
  1. 任务协议   — 结构化任务包，不是自由文本
  2. 风险闸门   — low/medium/high 三档，自动/确认/只出方案
  3. 执行监督   — 观察结果，决定是否继续/回滚/上报

接入方式：
  from adu_control_plane import control_plane
  result = await control_plane.dispatch(goal="查看git状态", source="voice")
"""

import asyncio
import json
import logging
import os
import time
import uuid
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Callable, Dict, List, Optional, Tuple

import httpx

logger = logging.getLogger("adu_control_plane")

DEEPSEEK_KEY = os.getenv("DEEPSEEK_API_KEY", "")
BACKEND_URL  = os.getenv("BACKEND_URL", "http://localhost:8000")


# ══════════════════════════════════════════════
# 1. 协议数据结构
# ══════════════════════════════════════════════

class RiskLevel(str, Enum):
    LOW    = "low"     # 自动执行（读取/查看/git status）
    MEDIUM = "medium"  # 需要确认（发消息/写文件/git commit）
    HIGH   = "high"    # 只出方案不执行（删除/系统改动/批量操作）

class ExecutionMode(str, Enum):
    EXECUTE      = "execute"    # 直接执行
    CONFIRM      = "confirm"    # 先确认再执行
    PLAN_ONLY    = "plan_only"  # 只出方案

@dataclass
class AduTask:
    """Adu → OpenClaw 任务包（控制协议）"""
    goal:                 str
    task_id:              str = field(default_factory=lambda: uuid.uuid4().hex[:8])
    source:               str = "user"          # voice / right_brain / auto_brain / api
    risk_level:           RiskLevel = RiskLevel.LOW
    execution_mode:       ExecutionMode = ExecutionMode.EXECUTE
    tool_profile:         List[str] = field(default_factory=list)  # 允许的工具
    requires_confirmation: bool = False
    max_steps:            int = 5
    timeout:              int = 60
    context:              Dict[str, Any] = field(default_factory=dict)
    created_at:           float = field(default_factory=time.time)

    def to_dict(self) -> Dict:
        return {
            "task_id":              self.task_id,
            "goal":                 self.goal,
            "source":               self.source,
            "risk_level":           self.risk_level.value,
            "execution_mode":       self.execution_mode.value,
            "tool_profile":         self.tool_profile,
            "requires_confirmation": self.requires_confirmation,
            "max_steps":            self.max_steps,
            "timeout":              self.timeout,
            "context":              self.context,
        }

@dataclass
class AduTaskResult:
    """OpenClaw → Adu 执行结果"""
    task_id:       str
    goal:          str
    success:       bool
    observation:   str           # 执行观察到的内容
    tool_calls:    List[str]     # 实际调用了哪些工具
    need_approval: bool = False  # 是否需要人工审批
    risk_triggered: bool = False
    elapsed:       float = 0.0
    raw:           Dict = field(default_factory=dict)

    def to_summary(self) -> str:
        icon = "✅" if self.success else "❌"
        risk = "⚠️ 风险触发" if self.risk_triggered else ""
        approval = "🔒 需要确认" if self.need_approval else ""
        flags = " ".join(filter(None, [risk, approval]))
        return f"{icon} {self.goal} ({self.elapsed:.1f}s) {flags}\n{self.observation[:200]}"


# ══════════════════════════════════════════════
# 2. 风险评估器
#    分析任务，自动评定风险等级
# ══════════════════════════════════════════════

# 工具白名单（按风险分组）
TOOL_PROFILES = {
    RiskLevel.LOW: [
        "exec_readonly",   # 只读命令
        "read",            # 文件读取
        "filetree",        # 文件树
        "git_status",      # git查看
        "git_log",         # git日志
        "screenshot",      # 截图
        "system_info",     # 系统信息
    ],
    RiskLevel.MEDIUM: [
        "exec",            # 终端执行
        "write",           # 文件写入
        "git_commit",      # git提交
        "send_message",    # 发消息
        "open_app",        # 打开App
        "build",           # 编译
        "install",         # 安装
    ],
    RiskLevel.HIGH: [
        "exec_destructive", # 危险命令
        "delete",           # 删除
        "system_modify",    # 系统修改
        "batch_operation",  # 批量操作
    ],
}

# 关键词 → 风险等级
RISK_KEYWORDS = {
    RiskLevel.HIGH: [
        "删除", "rm -rf", "格式化", "drop", "truncate",
        "清空", "覆盖所有", "批量删", "重置系统",
        "sudo", "chmod 777", "修改权限",
    ],
    RiskLevel.MEDIUM: [
        "发微信", "发消息", "imessage", "发邮件",
        "写入", "修改", "替换", "编辑",
        "git commit", "git push", "提交代码",
        "安装", "编译", "build",
    ],
    RiskLevel.LOW: [
        "查看", "读取", "列出", "git status", "git log",
        "截图", "系统状态", "磁盘", "内存",
        "文件树", "搜索代码",
    ],
}

class RiskAssessor:
    """风险评估器：分析任务，返回风险等级 + 工具白名单"""

    def assess(self, goal: str) -> Tuple[RiskLevel, List[str], ExecutionMode]:
        """
        返回 (risk_level, allowed_tools, execution_mode)
        """
        g = goal.lower()

        # 先查高风险关键词
        for kw in RISK_KEYWORDS[RiskLevel.HIGH]:
            if kw.lower() in g:
                logger.warning(f"[Risk] 高风险关键词命中: '{kw}' in '{goal}'")
                return (
                    RiskLevel.HIGH,
                    TOOL_PROFILES[RiskLevel.HIGH],
                    ExecutionMode.PLAN_ONLY,  # 高风险只出方案
                )

        # 中风险
        for kw in RISK_KEYWORDS[RiskLevel.MEDIUM]:
            if kw.lower() in g:
                return (
                    RiskLevel.MEDIUM,
                    TOOL_PROFILES[RiskLevel.LOW] + TOOL_PROFILES[RiskLevel.MEDIUM],
                    ExecutionMode.CONFIRM,  # 中风险需要确认
                )

        # 低风险（默认）
        return (
            RiskLevel.LOW,
            TOOL_PROFILES[RiskLevel.LOW],
            ExecutionMode.EXECUTE,  # 低风险直接执行
        )

    def needs_confirmation(self, risk: RiskLevel) -> bool:
        return risk in (RiskLevel.MEDIUM, RiskLevel.HIGH)


# ══════════════════════════════════════════════
# 3. NL2Shell（自然语言 → shell命令）
#    规则优先，DeepSeek兜底
# ══════════════════════════════════════════════

class NL2Shell:
    """把自然语言目标翻译成具体的 shell 命令"""

    PROJ = "~/Desktop/GPTsora"

    # 规则表：关键词 → 命令
    RULES = [
        (["git状态", "git status", "git.*状态", "查看.*git"],
         "git -C ~/Desktop/GPTsora status"),
        (["git日志", "git log", "提交记录", "历史.*提交"],
         "git -C ~/Desktop/GPTsora log --oneline -10"),
        (["git diff", "代码改动", "改了什么"],
         "git -C ~/Desktop/GPTsora diff --stat"),
        (["桌面.*文件", "桌面上.*文件", "列出.*桌面"],
         "ls -la ~/Desktop"),
        (["项目文件", "gptsora.*文件", "项目.*列表"],
         "ls -la ~/Desktop/GPTsora"),
        (["系统状态", "openclaw.*状态", "gateway"],
         "curl -s http://localhost:18789/health || echo 'OpenClaw offline'"),
        (["磁盘", "硬盘空间", "存储空间"],
         "df -h ~"),
        (["内存", "ram", "内存使用"],
         "vm_stat | head -8"),
        (["python.*进程", "后端.*进程", "运行中.*进程"],
         "ps aux | grep python3 | grep -v grep"),
        (["ip地址", "网络", "局域网"],
         "ifconfig | grep 'inet ' | grep -v 127"),
    ]

    def translate_rule(self, goal: str) -> Optional[str]:
        """规则层翻译（0延迟）"""
        import re
        g = goal.lower()
        for keywords, cmd in self.RULES:
            for kw in keywords:
                if re.search(kw.lower(), g):
                    return cmd
        return None

    async def translate(self, goal: str) -> str:
        """完整翻译：规则优先，DeepSeek兜底"""
        # 1. 规则层
        rule_result = self.translate_rule(goal)
        if rule_result:
            logger.info(f"[NL2Shell] 规则命中: {goal} → {rule_result}")
            return rule_result

        # 2. DeepSeek
        if not DEEPSEEK_KEY:
            return f'echo "请配置 DEEPSEEK_API_KEY 以支持自然语言命令"'

        try:
            async with httpx.AsyncClient(timeout=8) as client:
                resp = await client.post(
                    "https://api.deepseek.com/v1/chat/completions",
                    headers={"Authorization": f"Bearer {DEEPSEEK_KEY}"},
                    json={
                        "model": "deepseek-chat",
                        "messages": [
                            {"role": "system", "content": (
                                "你是NL2Shell翻译器。把中文自然语言转为Mac bash命令。"
                                "只输出命令本身，不要解释。"
                                f"项目路径: ~/Desktop/GPTsora"
                            )},
                            {"role": "user", "content": goal},
                        ],
                        "temperature": 0.0,
                        "max_tokens": 100,
                    },
                )
            cmd = resp.json()["choices"][0]["message"]["content"].strip().strip("`")
            logger.info(f"[NL2Shell] DeepSeek: {goal} → {cmd}")
            return cmd
        except Exception as e:
            logger.error(f"[NL2Shell] 翻译失败: {e}")
            return f'echo "指令翻译失败: {goal}"'


# ══════════════════════════════════════════════
# 4. OpenClaw 执行器
#    按协议下发任务给 OpenClaw
# ══════════════════════════════════════════════

class OpenClawExecutor:
    """按控制协议执行 OpenClaw 任务"""

    def __init__(self, nl2shell: NL2Shell):
        self.nl2shell = nl2shell

    async def _call(self, endpoint: str, payload: Dict, timeout: int = 60) -> Dict:
        try:
            async with httpx.AsyncClient(timeout=timeout) as client:
                resp = await client.post(
                    f"{BACKEND_URL}/agent/{endpoint}",
                    json=payload
                )
                return resp.json()
        except Exception as e:
            return {"ok": False, "error": str(e)}

    async def execute_task(self, task: AduTask) -> AduTaskResult:
        """按任务包执行，返回结构化结果"""
        t0     = time.time()
        goal   = task.goal
        tools  = task.tool_profile
        i      = goal.lower()

        tool_calls = []

        # ── 根据工具白名单和目标选择执行方式 ──

        if any(k in i for k in ["编译", "build", "xcode"]) and "build" in tools:
            endpoint = "build"
            payload  = {"path": "~/Desktop/GPTsora", "scheme": "GPT Solara"}
            timeout  = 300

        elif any(k in i for k in ["安装", "install", "装到手机"]) and "install" in tools:
            endpoint = "install"
            payload  = {"path": "~/Desktop/GPTsora", "scheme": "GPT Solara"}
            timeout  = 300

        elif any(k in i for k in ["文件树", "项目结构"]):
            endpoint = "filetree"
            payload  = {"path": "~/Desktop/GPTsora", "depth": 2}
            timeout  = 30

        else:
            # 自然语言 → shell命令
            shell_cmd = await self.nl2shell.translate(goal)
            endpoint  = "exec"
            payload   = {"command": shell_cmd, "timeout": task.timeout}
            timeout   = task.timeout + 10
            tool_calls.append(f"exec: {shell_cmd}")

        result = await self._call(endpoint, payload, timeout=timeout)

        success     = result.get("ok", False) or result.get("success", False)
        observation = result.get("output", result.get("error", str(result)))[:500]

        if endpoint != "exec":
            tool_calls.append(f"{endpoint}: {json.dumps(payload, ensure_ascii=False)[:80]}")

        return AduTaskResult(
            task_id    = task.task_id,
            goal       = goal,
            success    = success,
            observation= observation,
            tool_calls = tool_calls,
            elapsed    = round(time.time() - t0, 2),
            raw        = result,
        )


# ══════════════════════════════════════════════
# 5. 确认回调系统
#    中/高风险任务等待用户确认
# ══════════════════════════════════════════════

class ConfirmationGate:
    """等待用户确认的闸门"""

    def __init__(self):
        self._pending: Dict[str, asyncio.Future] = {}

    def create_pending(self, task_id: str) -> asyncio.Future:
        loop = asyncio.get_event_loop()
        fut = loop.create_future()
        self._pending[task_id] = fut
        return fut

    def approve(self, task_id: str) -> bool:
        if task_id in self._pending:
            fut = self._pending.pop(task_id)
            if not fut.done():
                fut.set_result(True)
                return True
        return False

    def reject(self, task_id: str) -> bool:
        if task_id in self._pending:
            fut = self._pending.pop(task_id)
            if not fut.done():
                fut.set_result(False)
                return True
        return False

    def list_pending(self) -> List[str]:
        return list(self._pending.keys())


# ══════════════════════════════════════════════
# 6. 控制平面主类
# ══════════════════════════════════════════════

class AduControlPlane:
    """
    Adu 控制平面 — App 控制 OpenClaw 的协议层

    完整流程：
      goal → 风险评估 → 构建任务包 → 确认闸门（如需）→ 执行 → 返回结果
    """

    def __init__(self):
        self.risk_assessor  = RiskAssessor()
        self.nl2shell       = NL2Shell()
        self.executor       = OpenClawExecutor(self.nl2shell)
        self.confirm_gate   = ConfirmationGate()

        # 确认回调（UI 层注册，用于推送确认请求给用户）
        self._confirm_callback: Optional[Callable] = None
        # 结果回调（用于 SSE 推送）
        self._result_callback:  Optional[Callable] = None

        # 执行历史
        self.history: List[AduTaskResult] = []

    def on_confirm_needed(self, callback: Callable):
        """注册确认请求回调（如推送给手机 App 显示确认弹窗）"""
        self._confirm_callback = callback

    def on_result(self, callback: Callable):
        """注册结果回调（如 SSE 推送给前端）"""
        self._result_callback = callback

    async def dispatch(
        self,
        goal:   str,
        source: str = "user",
        force_risk: Optional[RiskLevel] = None,
        force_mode: Optional[ExecutionMode] = None,
    ) -> AduTaskResult:
        """
        主入口：接收目标，评估风险，执行，返回结果

        Args:
            goal:       自然语言目标
            source:     来源（voice/right_brain/auto_brain/api）
            force_risk: 强制指定风险等级（覆盖自动评估）
            force_mode: 强制指定执行模式
        """
        logger.info(f"[ControlPlane] 📋 任务: [{source}] {goal}")

        # 1. 风险评估
        risk, tools, mode = self.risk_assessor.assess(goal)
        if force_risk:
            risk = force_risk
        if force_mode:
            mode = force_mode

        logger.info(f"[ControlPlane] 风险={risk.value} 模式={mode.value} 工具={tools[:3]}")

        # 2. 构建任务包
        task = AduTask(
            goal                 = goal,
            source               = source,
            risk_level           = risk,
            execution_mode       = mode,
            tool_profile         = tools,
            requires_confirmation= self.risk_assessor.needs_confirmation(risk),
            timeout              = 60 if risk == RiskLevel.LOW else 120,
        )

        # 3. 高风险 → 只出方案，不执行
        if mode == ExecutionMode.PLAN_ONLY:
            plan = await self._generate_plan(goal)
            result = AduTaskResult(
                task_id      = task.task_id,
                goal         = goal,
                success      = True,
                observation  = f"⚠️ 高风险任务，仅提供方案（未执行）:\n{plan}",
                tool_calls   = [],
                need_approval= True,
                risk_triggered= True,
                elapsed      = 0.0,
            )
            await self._notify_result(result)
            return result

        # 4. 中风险 → 等待确认
        if mode == ExecutionMode.CONFIRM:
            logger.info(f"[ControlPlane] 🔒 等待确认: {goal}")

            # 通知用户确认
            if self._confirm_callback:
                await self._confirm_callback(task)

            # 等待确认（最多60秒）
            fut = self.confirm_gate.create_pending(task.task_id)
            try:
                approved = await asyncio.wait_for(fut, timeout=60)
            except asyncio.TimeoutError:
                approved = False
                logger.info(f"[ControlPlane] ⏰ 确认超时，取消执行")

            if not approved:
                result = AduTaskResult(
                    task_id    = task.task_id,
                    goal       = goal,
                    success    = False,
                    observation= "用户取消或超时未确认",
                    tool_calls = [],
                    elapsed    = 0.0,
                )
                await self._notify_result(result)
                return result

            logger.info(f"[ControlPlane] ✅ 用户已确认，开始执行")

        # 5. 执行
        result = await self.executor.execute_task(task)

        # 6. 记录历史
        self.history.append(result)
        if len(self.history) > 100:
            self.history = self.history[-100:]

        # 7. 通知结果
        await self._notify_result(result)

        logger.info(f"[ControlPlane] {result.to_summary()[:100]}")
        return result

    async def _generate_plan(self, goal: str) -> str:
        """高风险任务只生成方案不执行"""
        if not DEEPSEEK_KEY:
            return f"建议手动执行: {goal}"
        try:
            async with httpx.AsyncClient(timeout=10) as client:
                resp = await client.post(
                    "https://api.deepseek.com/v1/chat/completions",
                    headers={"Authorization": f"Bearer {DEEPSEEK_KEY}"},
                    json={
                        "model": "deepseek-chat",
                        "messages": [{
                            "role": "user",
                            "content": f"给出安全执行以下任务的步骤方案（不要直接执行）:\n{goal}"
                        }],
                        "temperature": 0.3,
                        "max_tokens": 300,
                    },
                )
            return resp.json()["choices"][0]["message"]["content"].strip()
        except Exception:
            return f"建议手动评估后执行: {goal}"

    async def _notify_result(self, result: AduTaskResult):
        if self._result_callback:
            try:
                await self._result_callback(result)
            except Exception as e:
                logger.error(f"[ControlPlane] 结果回调失败: {e}")

    # ── 确认接口（供 API 调用）──────────────────

    def approve(self, task_id: str) -> bool:
        return self.confirm_gate.approve(task_id)

    def reject(self, task_id: str) -> bool:
        return self.confirm_gate.reject(task_id)

    def pending_tasks(self) -> List[str]:
        return self.confirm_gate.list_pending()

    def recent_history(self, n: int = 10) -> List[Dict]:
        return [
            {
                "task_id":    r.task_id,
                "goal":       r.goal,
                "success":    r.success,
                "elapsed":    r.elapsed,
                "risk":       "high" if r.risk_triggered else "normal",
                "observation": r.observation[:100],
            }
            for r in self.history[-n:]
        ]


# ══════════════════════════════════════════════
# 7. FastAPI 路由
# ══════════════════════════════════════════════

try:
    from fastapi import APIRouter, Request
    from fastapi.responses import JSONResponse

    router = APIRouter(prefix="/control", tags=["control-plane"])

    @router.post("/dispatch")
    async def cp_dispatch(request: Request):
        """
        主入口：下发任务给 OpenClaw
        POST /control/dispatch
        {"goal": "查看git状态", "source": "voice"}
        """
        body   = await request.json()
        goal   = body.get("goal", "")
        source = body.get("source", "api")
        if not goal:
            return JSONResponse({"ok": False, "error": "missing goal"}, status_code=400)

        result = await control_plane.dispatch(goal, source=source)
        return {
            "ok":           True,
            "task_id":      result.task_id,
            "success":      result.success,
            "observation":  result.observation,
            "tool_calls":   result.tool_calls,
            "need_approval": result.need_approval,
            "risk_triggered": result.risk_triggered,
            "elapsed":      result.elapsed,
            "summary":      result.to_summary(),
        }

    @router.post("/approve/{task_id}")
    async def cp_approve(task_id: str):
        """用户确认执行中风险任务"""
        ok = control_plane.approve(task_id)
        return {"ok": ok, "task_id": task_id, "action": "approved"}

    @router.post("/reject/{task_id}")
    async def cp_reject(task_id: str):
        """用户拒绝执行"""
        ok = control_plane.reject(task_id)
        return {"ok": ok, "task_id": task_id, "action": "rejected"}

    @router.get("/pending")
    async def cp_pending():
        """查看待确认任务"""
        return {"pending": control_plane.pending_tasks()}

    @router.get("/history")
    async def cp_history(n: int = 10):
        """查看执行历史"""
        return {"history": control_plane.recent_history(n)}

    @router.post("/risk_check")
    async def cp_risk_check(request: Request):
        """预先评估风险等级（不执行）"""
        body = await request.json()
        goal = body.get("goal", "")
        risk, tools, mode = control_plane.risk_assessor.assess(goal)
        return {
            "goal":       goal,
            "risk_level": risk.value,
            "mode":       mode.value,
            "tools":      tools,
            "needs_confirmation": control_plane.risk_assessor.needs_confirmation(risk),
        }

except ImportError:
    router = None


# ══════════════════════════════════════════════
# 单例
# ══════════════════════════════════════════════

control_plane = AduControlPlane()


# ══════════════════════════════════════════════
# server_session.py 接入说明
# ══════════════════════════════════════════════
"""
【接入步骤】

1. from adu_control_plane import control_plane, router as cp_router
2. app.include_router(cp_router)

3. 在语音消息处理里替换原来的 voice_bridge.handle：
   # 原来：
   result = await voice_bridge.handle(user_text)
   # 改为：
   result = await control_plane.dispatch(user_text, source="voice")

4. 注册确认回调（推送给手机 App）：
   async def ask_user_confirm(task):
       # 通过 SSE/WebSocket 推送确认请求给手机
       await push_to_client(user_id, {
           "type": "confirm_request",
           "task_id": task.task_id,
           "goal": task.goal,
           "risk": task.risk_level.value,
       })
   control_plane.on_confirm_needed(ask_user_confirm)

【完整风险分层】
low    → 查看/读取/git状态  → 自动执行（<1s）
medium → 发消息/写文件/编译 → 等用户确认（手机弹窗）
high   → 删除/系统改动      → 只出方案，不执行

【测试命令】
# 低风险（自动执行）
curl -X POST http://localhost:8000/control/dispatch \\
  -H "Content-Type: application/json" \\
  -d '{"goal": "查看 GPTsora 的 git 状态", "source": "voice"}'

# 预先评估风险
curl -X POST http://localhost:8000/control/risk_check \\
  -H "Content-Type: application/json" \\
  -d '{"goal": "发微信给张三说明天见"}'
"""

if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [ControlPlane] %(message)s",
        datefmt="%H:%M:%S",
    )

    async def test():
        tests = [
            ("查看 GPTsora 的 git 状态", "voice"),
            ("发微信给张三说明天见",      "voice"),
            ("删除 Desktop 所有文件",    "voice"),
            ("查看磁盘空间",             "auto_brain"),
        ]
        for goal, source in tests:
            print(f"\n{'='*50}")
            risk, tools, mode = control_plane.risk_assessor.assess(goal)
            print(f"🎯 {goal}")
            print(f"   风险: {risk.value} | 模式: {mode.value}")

    asyncio.run(test())
