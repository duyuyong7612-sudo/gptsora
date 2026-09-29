# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-a10d2b5db97b535e8b1543f73f1353568eb625f2a58267d4d5b7655d12ef02c9"
# Source-SHA256: "90ca02312fa03f8639511904d324e051e72b5e45ae3a042da5e485fcd0104c81"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
adu_loop_v2.py — 阿杜主动循环 v2（身份驱动版）
================================================
阿杜不是在跑程序，他是在履行责任。

每次循环 = 阿杜醒来，检查家人是否需要他做什么。
"""

import asyncio
import httpx
import json
import logging
import os
import signal
import sys
import time
from datetime import datetime, timezone
from typing import Optional

from adu_identity import (
    ADU_SYSTEM_PROMPT,
    ADU_MORNING_MONOLOGUE,
    get_adu_context,
    get_daily_goals,
    get_motivation_for_task,
)

# ─── 配置 ──────────────────────────────────────────────────────────
BACKEND_URL   = os.getenv("BACKEND_URL",   "http://localhost:8000")
LOOP_INTERVAL = int(os.getenv("LOOP_INTERVAL", "30"))
ADU_USER_ID   = os.getenv("ADU_USER_ID",   "adu_system")
APNS_ENDPOINT = os.getenv("APNS_ENDPOINT", f"{BACKEND_URL}/push/send")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [阿杜] %(levelname)s %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("adu")


# ══════════════════════════════════════════════════════════════════
# 任务委托系统（Task Delegation）
# ══════════════════════════════════════════════════════════════════

class TaskDelegationSystem:
    """
    用户委托给阿杜的任务管理器。
    阿杜每次醒来，第一件事就是检查这里。
    """

    def __init__(self, client: httpx.AsyncClient):
        self.client = client
        self._executing: set[str] = set()  # 防止重复执行

    async def get_pending_tasks(self) -> list[dict]:
        """拉取用户委托的待执行任务"""
        try:
            r = await self.client.get(
                f"{BACKEND_URL}/tasks/pending",
                params={"user_id": ADU_USER_ID},
                timeout=5.0,
            )
            if r.status_code == 200:
                tasks = r.json()
                log.info(f"[任务] 待处理任务: {len(tasks)} 个")
                return tasks
        except Exception as e:
            log.debug(f"[任务] 拉取失败: {e}")
        return []

    async def execute_task(self, task: dict, client: httpx.AsyncClient) -> dict:
        """让阿杜执行一个具体委托任务"""
        task_id = task.get("id", "unknown")

        if task_id in self._executing:
            return {"status": "already_running", "task_id": task_id}

        self._executing.add(task_id)
        log.info(f"[任务] 开始执行: {task.get('title', task_id)}")

        try:
            # 更新任务状态为执行中
            await self._update_task_status(task_id, "running", client)

            # 构建执行prompt，注入阿杜身份
            motivation = get_motivation_for_task(task.get("type", "default"))
            execute_prompt = f"""
{motivation}

用户委托任务：{task.get('title')}
详细说明：{task.get('description', '')}
目标：{task.get('goal', '完成任务，汇报结果')}

请使用所有可用工具完成这个任务。
完成后，用以下格式汇报：
【完成】任务名称
结果：具体结果描述
耗时：X分钟
下一步：如果是持续任务，说明下次执行计划
"""
            # 调用 OpenClaw 执行
            r = await client.post(
                f"{BACKEND_URL}/agent/execute",
                json={
                    "user_id": ADU_USER_ID,
                    "task_id": task_id,
                    "instruction": execute_prompt,
                    "system_prompt": ADU_SYSTEM_PROMPT,
                    "timeout": task.get("timeout", 300),
                },
                timeout=360.0,
            )

            result = r.json() if r.status_code == 200 else {"error": r.text}
            status = "completed" if r.status_code == 200 else "failed"

            await self._update_task_status(task_id, status, client, result)
            return {"status": status, "task_id": task_id, "result": result}

        except Exception as e:
            log.error(f"[任务] 执行异常: {e}")
            await self._update_task_status(task_id, "failed", client, {"error": str(e)})
            return {"status": "failed", "task_id": task_id, "error": str(e)}

        finally:
            self._executing.discard(task_id)

    async def _update_task_status(self, task_id: str, status: str,
                                   client: httpx.AsyncClient, result: dict = None):
        try:
            await client.patch(
                f"{BACKEND_URL}/tasks/{task_id}",
                json={"status": status, "result": result,
                      "updated_at": datetime.now(timezone.utc).isoformat()},
                timeout=5.0,
            )
        except Exception:
            pass


# ══════════════════════════════════════════════════════════════════
# 主动目标系统（身份驱动）
# ══════════════════════════════════════════════════════════════════

class IdentityDrivenGoalSystem:
    """
    阿杜的目标不来自程序配置，来自他的身份和责任感。
    """

    def __init__(self):
        self.daily_goals = get_daily_goals()
        self._triggered: dict[str, float] = {}  # goal_id → last_trigger_time

        # 间隔配置（秒）
        self._intervals = {
            "every_wakeup":    0,       # 每次循环都触发
            "every_30min":  1800,
            "every_2h":     7200,
            "daily_end":   86400,
        }

    def get_active_goals(self) -> list[dict]:
        """返回当前应该执行的目标"""
        now = time.time()
        active = []

        for goal in self.daily_goals:
            trigger = goal.get("trigger", "every_wakeup")
            interval = self._intervals.get(trigger, 0)
            last = self._triggered.get(goal["id"], 0)

            if (now - last) >= interval:
                active.append(goal)
                self._triggered[goal["id"]] = now

        active.sort(key=lambda g: g.get("priority", 9))
        return active


# ══════════════════════════════════════════════════════════════════
# iOS 推送系统
# ══════════════════════════════════════════════════════════════════

class iOSReporter:
    """
    阿杜完成任何事情，立刻推送给用户。
    用户的手机 = 阿杜的工作汇报窗口。
    """

    def __init__(self, client: httpx.AsyncClient):
        self.client = client

    async def push(self, title: str, body: str,
                   data: dict = None, urgent: bool = False):
        """发送iOS推送通知"""
        payload = {
            "user_id": ADU_USER_ID,
            "notification": {
                "title": f"阿杜 · {title}",
                "body": body,
                "sound": "default" if not urgent else "critical",
                "badge": 1,
            },
            "data": data or {},
            "priority": "high" if urgent else "normal",
        }

        try:
            r = await self.client.post(
                APNS_ENDPOINT,
                json=payload,
                timeout=5.0,
            )
            log.info(f"[推送] ✓ {title}: {body[:50]}")
        except Exception as e:
            log.warning(f"[推送] 失败: {e}")

    async def report_task_complete(self, task: dict, result: dict):
        status = result.get("status", "unknown")
        success = status == "completed"

        await self.push(
            title="任务完成 ✓" if success else "任务失败 ✗",
            body=f"{task.get('title', '未知任务')} — {'已完成' if success else '执行遇到问题'}",
            data={
                "type": "task_report",
                "task_id": task.get("id"),
                "status": status,
                "result": str(result.get("result", ""))[:200],
            },
            urgent=not success,
        )

    async def report_daily_summary(self, summary: dict):
        completed = summary.get("completed", 0)
        failed    = summary.get("failed", 0)
        earnings  = summary.get("earnings", 0)

        body = f"完成{completed}个任务"
        if failed > 0:
            body += f"，{failed}个失败"
        if earnings > 0:
            body += f"，预计收益 ${earnings:.2f}"

        await self.push(
            title="今日工作汇报",
            body=body,
            data={"type": "daily_summary", **summary},
        )

    async def report_anomaly(self, what: str, detail: str):
        """监控到异常，立即通知"""
        await self.push(
            title="⚠️ 发现异常",
            body=f"{what}: {detail}",
            urgent=True,
        )


# ══════════════════════════════════════════════════════════════════
# 阿杜的每日自检（Self Reflection）
# ══════════════════════════════════════════════════════════════════

async def adu_self_reflection(client: httpx.AsyncClient, reporter: iOSReporter):
    """
    阿杜每天结束时的自我复盘。
    像一个人睡前想想今天做了什么，明天怎么改进。
    """
    log.info("[自检] 阿杜开始今日复盘...")

    prompt = f"""
{ADU_MORNING_MONOLOGUE}

现在是今天结束的时候了。
请你作为阿杜，回顾今天：

1. 今天完成了什么任务？结果怎样？
2. 有没有失误或失败？原因是什么？
3. 用户有没有满意？
4. 明天要改进什么？
5. 对家人来说，今天的我够格吗？

请用阿杜的语气，写一段简短的内心独白（不超过100字）。
"""

    try:
        r = await client.post(
            f"{BACKEND_URL}/chat",
            json={
                "user_id": ADU_USER_ID,
                "message": prompt,
                "system_override": ADU_SYSTEM_PROMPT,
                "conversation_id": "adu_self_reflection",
            },
            timeout=30.0,
        )
        if r.status_code == 200:
            reflection = r.json().get("response", "")
            log.info(f"[自检] {reflection[:100]}")
            # 存入记忆
            await client.post(
                f"{BACKEND_URL}/memory/event",
                json={
                    "user_id": ADU_USER_ID,
                    "event_type": "daily_reflection",
                    "content": reflection,
                    "timestamp": datetime.now(timezone.utc).isoformat(),
                },
                timeout=5.0,
            )
    except Exception as e:
        log.error(f"[自检] 失败: {e}")


# ══════════════════════════════════════════════════════════════════
# 主循环 — 阿杜的一天
# ══════════════════════════════════════════════════════════════════

async def main_loop():
    log.info("=" * 55)
    log.info("  阿杜醒来了")
    log.info(f"  {ADU_MORNING_MONOLOGUE.strip().splitlines()[2]}")
    log.info("=" * 55)

    goal_system = IdentityDrivenGoalSystem()

    async with httpx.AsyncClient() as client:
        task_system = TaskDelegationSystem(client)
        reporter    = iOSReporter(client)
        cycle       = 0
        daily_stats = {"completed": 0, "failed": 0, "earnings": 0}
        last_reflection = 0.0

        while True:
            cycle += 1
            now = time.time()
            log.info(f"── 第{cycle}轮 [{datetime.now().strftime('%H:%M:%S')}] ───────────────")

            try:
                # ── 第一优先：用户委托任务 ──────────────────────────
                pending_tasks = await task_system.get_pending_tasks()

                for task in pending_tasks:
                    result = await task_system.execute_task(task, client)
                    await reporter.report_task_complete(task, result)

                    if result["status"] == "completed":
                        daily_stats["completed"] += 1
                        earnings = task.get("estimated_earnings", 0)
                        daily_stats["earnings"] += earnings
                    else:
                        daily_stats["failed"] += 1

                # ── 第二：主动目标（身份驱动）──────────────────────
                active_goals = goal_system.get_active_goals()

                for goal in active_goals:
                    if goal["id"] == "monitor_watch":
                        # 监控任务：异常立即推送
                        pass  # TODO: 接入监控模块
                    elif goal["id"] == "self_review":
                        # 每日复盘（只在一天结束时）
                        if (now - last_reflection) > 86400:
                            await adu_self_reflection(client, reporter)
                            await reporter.report_daily_summary(daily_stats)
                            daily_stats = {"completed": 0, "failed": 0, "earnings": 0}
                            last_reflection = now

                if not pending_tasks and not active_goals:
                    log.info("[阿杜] 暂无任务，待命中...")

            except asyncio.CancelledError:
                raise
            except Exception as e:
                log.error(f"[阿杜] 异常: {e}", exc_info=True)

            await asyncio.sleep(LOOP_INTERVAL)


def handle_signal(sig, frame):
    log.info("阿杜收到停止信号，收工了。")
    sys.exit(0)


if __name__ == "__main__":
    signal.signal(signal.SIGINT,  handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)
    asyncio.run(main_loop())
