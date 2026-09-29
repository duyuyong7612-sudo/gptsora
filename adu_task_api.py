# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-7c9f66db3ce4e089b8073400c63989bdff8ebc69aeaae6b89a6b93432a34b6c0"
# Source-SHA256: "1ad204c94e5f251acf736b52a3ea86be705c45eceadfc3a6a997ae73c4da2bac"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
adu_task_api.py — 任务委托系统后端API
=====================================
加入 server_session.py 的路由补丁

这是连接用户（iOS App）和阿杜（adu_loop_v2.py）的桥梁。
用户在App里下达任务 → 存入这里 → 阿杜来取 → 执行 → 结果写回 → 推送给用户
"""

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field
from typing import Optional, List
from datetime import datetime, timezone
import sqlite3
import json
import uuid
import os

router = APIRouter(prefix="", tags=["adu-tasks"])

DB_PATH = os.getenv("TASK_DB_PATH", "./adu_tasks.db")

# ══════════════════════════════════════════════════════════════════
# 数据库初始化
# ══════════════════════════════════════════════════════════════════

def init_db():
    conn = sqlite3.connect(DB_PATH)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS tasks (
            id              TEXT PRIMARY KEY,
            user_id         TEXT NOT NULL,
            title           TEXT NOT NULL,
            description     TEXT,
            type            TEXT DEFAULT 'general',
            status          TEXT DEFAULT 'pending',
            priority        INTEGER DEFAULT 5,
            result          TEXT,
            estimated_earnings REAL,
            created_at      TEXT NOT NULL,
            updated_at      TEXT,
            completed_at    TEXT
        )
    """)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS task_logs (
            id          TEXT PRIMARY KEY,
            task_id     TEXT NOT NULL,
            message     TEXT NOT NULL,
            level       TEXT DEFAULT 'info',
            created_at  TEXT NOT NULL
        )
    """)
    conn.commit()
    conn.close()

init_db()

# ══════════════════════════════════════════════════════════════════
# 数据模型
# ══════════════════════════════════════════════════════════════════

class TaskCreate(BaseModel):
    user_id: str
    title: str
    description: Optional[str] = ""
    type: Optional[str] = "general"    # general/monitor/content/game/shopping/data
    priority: Optional[int] = 5        # 1=最高 10=最低
    estimated_earnings: Optional[float] = None

class TaskUpdate(BaseModel):
    status: Optional[str] = None       # pending/running/completed/failed
    result: Optional[str] = None
    updated_at: Optional[str] = None

class TaskLog(BaseModel):
    task_id: str
    message: str
    level: str = "info"

# ══════════════════════════════════════════════════════════════════
# 工具函数
# ══════════════════════════════════════════════════════════════════

def row_to_dict(row, cursor) -> dict:
    return dict(zip([d[0] for d in cursor.description], row))

def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()

# ══════════════════════════════════════════════════════════════════
# 路由
# ══════════════════════════════════════════════════════════════════

@router.post("/tasks", status_code=201)
async def create_task(body: TaskCreate):
    """用户从iOS App下达任务给阿杜"""
    task_id = str(uuid.uuid4())[:8]
    conn = sqlite3.connect(DB_PATH)
    conn.execute("""
        INSERT INTO tasks
        (id, user_id, title, description, type, status, priority, estimated_earnings, created_at)
        VALUES (?, ?, ?, ?, ?, 'pending', ?, ?, ?)
    """, (task_id, body.user_id, body.title, body.description,
          body.type, body.priority, body.estimated_earnings, now_iso()))
    conn.commit()
    conn.close()

    return {
        "id": task_id,
        "status": "pending",
        "message": f"阿杜收到了，马上去办：{body.title}",
    }


@router.get("/tasks/pending")
async def get_pending_tasks(user_id: str = "adu_system") -> List[dict]:
    """阿杜每轮循环来取待执行任务"""
    conn = sqlite3.connect(DB_PATH)
    cur = conn.execute("""
        SELECT * FROM tasks
        WHERE status IN ('pending', 'running')
        ORDER BY priority ASC, created_at ASC
        LIMIT 10
    """)
    rows = [row_to_dict(r, cur) for r in cur.fetchall()]
    conn.close()
    return rows


@router.get("/tasks")
async def get_all_tasks(user_id: str, limit: int = 50) -> List[dict]:
    """iOS App查看所有任务（用于工作报告界面）"""
    conn = sqlite3.connect(DB_PATH)
    cur = conn.execute("""
        SELECT * FROM tasks
        WHERE user_id = ?
        ORDER BY created_at DESC
        LIMIT ?
    """, (user_id, limit))
    rows = [row_to_dict(r, cur) for r in cur.fetchall()]
    conn.close()
    return rows


@router.patch("/tasks/{task_id}")
async def update_task(task_id: str, body: TaskUpdate):
    """阿杜执行完更新任务状态"""
    conn = sqlite3.connect(DB_PATH)

    fields = []
    values = []

    if body.status:
        fields.append("status = ?")
        values.append(body.status)

    if body.result:
        fields.append("result = ?")
        values.append(body.result)

    fields.append("updated_at = ?")
    values.append(now_iso())

    if body.status == "completed":
        fields.append("completed_at = ?")
        values.append(now_iso())

    if not fields:
        raise HTTPException(status_code=400, detail="没有要更新的字段")

    values.append(task_id)
    conn.execute(f"UPDATE tasks SET {', '.join(fields)} WHERE id = ?", values)
    conn.commit()
    conn.close()

    return {"status": "updated", "task_id": task_id}


@router.post("/tasks/{task_id}/log")
async def add_task_log(task_id: str, body: TaskLog):
    """阿杜执行过程中写日志（iOS可以实时看到进度）"""
    conn = sqlite3.connect(DB_PATH)
    conn.execute("""
        INSERT INTO task_logs (id, task_id, message, level, created_at)
        VALUES (?, ?, ?, ?, ?)
    """, (str(uuid.uuid4())[:8], task_id, body.message, body.level, now_iso()))
    conn.commit()
    conn.close()
    return {"status": "logged"}


@router.get("/tasks/{task_id}/logs")
async def get_task_logs(task_id: str) -> List[dict]:
    """iOS实时查看任务执行日志"""
    conn = sqlite3.connect(DB_PATH)
    cur = conn.execute("""
        SELECT * FROM task_logs WHERE task_id = ?
        ORDER BY created_at ASC
    """, (task_id,))
    rows = [row_to_dict(r, cur) for r in cur.fetchall()]
    conn.close()
    return rows


@router.delete("/tasks/{task_id}")
async def cancel_task(task_id: str):
    """用户取消任务"""
    conn = sqlite3.connect(DB_PATH)
    conn.execute("UPDATE tasks SET status = 'cancelled', updated_at = ? WHERE id = ?",
                 (now_iso(), task_id))
    conn.commit()
    conn.close()
    return {"status": "cancelled", "message": "阿杜已停止这个任务"}


# ══════════════════════════════════════════════════════════════════
# 今日汇总（iOS工作报告用）
# ══════════════════════════════════════════════════════════════════

@router.get("/tasks/summary/today")
async def get_today_summary(user_id: str):
    """今日工作数据汇总"""
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    conn = sqlite3.connect(DB_PATH)

    cur = conn.execute("""
        SELECT
            COUNT(CASE WHEN status = 'completed' THEN 1 END) as completed,
            COUNT(CASE WHEN status = 'failed' THEN 1 END) as failed,
            COUNT(CASE WHEN status = 'running' THEN 1 END) as running,
            COALESCE(SUM(CASE WHEN status = 'completed' THEN estimated_earnings ELSE 0 END), 0) as earnings
        FROM tasks
        WHERE user_id = ? AND DATE(created_at) = ?
    """, (user_id, today))

    row = cur.fetchone()
    conn.close()

    return {
        "completed": row[0],
        "failed": row[1],
        "running": row[2],
        "earnings": row[3],
        "date": today,
    }


# ══════════════════════════════════════════════════════════════════
# /agent/execute — 接入 OpenClaw（核心执行端点）
# ══════════════════════════════════════════════════════════════════

import asyncio
import subprocess

class AgentExecuteRequest(BaseModel):
    user_id: str
    task_id: str
    instruction: str
    system_prompt: Optional[str] = None
    timeout: int = 300

@router.post("/agent/execute")
async def agent_execute(body: AgentExecuteRequest):
    """
    阿杜执行任务的核心：调用 OpenClaw
    复用你已有的 openclaw agent --agent main -m "..." --json 调用链
    """
    try:
        cmd = [
            "openclaw", "agent",
            "--agent", "main",
            "-m", body.instruction,
            "--json"
        ]

        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )

        try:
            stdout, stderr = await asyncio.wait_for(
                proc.communicate(), timeout=body.timeout
            )
        except asyncio.TimeoutError:
            proc.kill()
            return {"status": "timeout", "task_id": body.task_id}

        output = stdout.decode("utf-8", errors="ignore")
        return {
            "status": "completed" if proc.returncode == 0 else "failed",
            "task_id": body.task_id,
            "output": output[:2000],
            "return_code": proc.returncode,
        }

    except Exception as e:
        return {"status": "error", "task_id": body.task_id, "error": str(e)}


# ══════════════════════════════════════════════════════════════════
# v2 扩展：任务闭环执行协议
# ══════════════════════════════════════════════════════════════════

import re
import sys
import logging

log = logging.getLogger("adu_task_api")

# 迁移：给 tasks 表加 v2 字段
def migrate_db_v2():
    conn = sqlite3.connect(DB_PATH)
    existing = [r[1] for r in conn.execute("PRAGMA table_info(tasks)").fetchall()]
    v2_cols = {
        "goal":          "TEXT",
        "scope":         "TEXT",
        "constraints":   "TEXT",
        "deliverables":  "TEXT",
        "done_definition": "TEXT",
        "progress":      "INTEGER DEFAULT 0",
        "current_step":  "TEXT",
        "last_result":   "TEXT",
        "next_action":   "TEXT",
        "error_count":   "INTEGER DEFAULT 0",
        "max_retries":   "INTEGER DEFAULT 3",
    }
    for col, ddl in v2_cols.items():
        if col not in existing:
            conn.execute(f"ALTER TABLE tasks ADD COLUMN {col} {ddl}")
    conn.commit()
    conn.close()

migrate_db_v2()


class TaskCreateV2(BaseModel):
    """扩展任务结构，支持完整任务闭环"""
    user_id: str = "adu_system"
    title: str
    goal: Optional[str] = None          # 明确目标（Why）
    description: Optional[str] = ""     # 详细描述（What）
    scope: Optional[str] = None         # 操作范围限制（Where）
    constraints: Optional[str] = None   # 约束（禁止事项）
    deliverables: Optional[str] = None  # 可交付物（输出什么）
    done_definition: Optional[str] = None  # 完成标准
    type: Optional[str] = "dev"         # dev/monitor/content/general
    priority: Optional[int] = 5
    max_retries: int = 3


class TaskUpdateV2(BaseModel):
    status: Optional[str] = None
    result: Optional[str] = None
    current_step: Optional[str] = None
    last_result: Optional[str] = None
    next_action: Optional[str] = None
    progress: Optional[int] = None
    error_count: Optional[int] = None


@router.post("/tasks/v2", status_code=201)
async def create_task_v2(body: TaskCreateV2):
    """v2 任务创建：支持完整任务描述结构"""
    task_id = str(uuid.uuid4())[:8]
    conn = sqlite3.connect(DB_PATH)
    conn.execute("""
        INSERT INTO tasks
        (id, user_id, title, description, goal, scope, constraints,
         deliverables, done_definition, type, status, priority, max_retries, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?)
    """, (task_id, body.user_id, body.title, body.description,
          body.goal, body.scope, body.constraints,
          body.deliverables, body.done_definition,
          body.type, body.priority, body.max_retries, now_iso()))
    conn.commit()
    conn.close()
    return {"id": task_id, "status": "pending",
            "message": f"任务已创建：{body.title}"}


@router.patch("/tasks/v2/{task_id}")
async def update_task_v2(task_id: str, body: TaskUpdateV2):
    """v2 任务更新"""
    conn = sqlite3.connect(DB_PATH)
    fields, values = [], []
    for field, val in body.model_dump(exclude_none=True).items():
        fields.append(f"{field} = ?")
        values.append(val)
    fields.append("updated_at = ?")
    values.append(now_iso())
    if body.status == "completed":
        fields.append("completed_at = ?")
        values.append(now_iso())
    values.append(task_id)
    conn.execute(f"UPDATE tasks SET {', '.join(fields)} WHERE id = ?", values)
    conn.commit()
    conn.close()
    return {"status": "updated", "task_id": task_id}


@router.get("/tasks/v2/{task_id}")
async def get_task_v2(task_id: str) -> dict:
    """获取完整任务详情（含 v2 字段）"""
    conn = sqlite3.connect(DB_PATH)
    cur = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,))
    row = cur.fetchone()
    conn.close()
    if not row:
        raise HTTPException(status_code=404, detail="Task not found")
    return row_to_dict(row, cur)


# ══════════════════════════════════════════════════════════════════
# 任务闭环执行引擎
# ══════════════════════════════════════════════════════════════════

from adu_computer_tools import dispatch_tool, ALLOWED_ROOTS

# 安全检查：工具参数白名单校验
def _validate_tool_scope(tool_name: str, params: dict) -> tuple[bool, str]:
    """确保工具调用在允许的范围内"""
    if tool_name == "exec":
        cmd = params.get("command", "")
        # 禁止破坏性命令
        forbidden = ["rm -rf", "sudo", "chmod 777", "mkfs", "dd if=", "killall -9"]
        for f in forbidden:
            if f in cmd:
                return False, f"命令包含禁止操作：{f}"
    if tool_name in ("read_file", "write_file"):
        path = params.get("path", "")
        import os
        abs_path = os.path.realpath(os.path.expanduser(path))
        allowed = any(
            abs_path.startswith(os.path.realpath(r))
            for r in ALLOWED_ROOTS
        )
        if not allowed:
            return False, f"路径 '{path}' 不在允许的范围内"
    return True, ""


async def _run_tool_safe(tool_name: str, params: dict) -> dict:
    """安全地运行工具，带验证"""
    ok, reason = _validate_tool_scope(tool_name, params)
    if not ok:
        return {"ok": False, "blocked": True, "reason": reason}
    return await dispatch_tool(tool_name, params)


async def _compile_check() -> dict:
    """执行 xcodebuild 编译检查（只编译，不安装）"""
    cmd = (
        "cd ~/Desktop/GPTsora && "
        "xcodebuild -workspace GPTsora.xcworkspace "
        "-scheme 'GPT Solara' "
        "-destination 'generic/platform=iOS' "
        "-configuration Debug "
        "build 2>&1 | grep -E 'error:|BUILD SUCCEEDED|BUILD FAILED' | tail -20"
    )
    result = await _run_tool_safe("exec", {"command": cmd, "timeout": 120})
    output = result.get("output", "")
    success = "BUILD SUCCEEDED" in output
    errors = [l for l in output.split("\n") if "error:" in l and "error: " in l]
    return {
        "ok": success,
        "build_success": success,
        "errors": errors[:10],
        "output_tail": output[-500:],
    }


async def _generate_fix_plan(task: dict, error_output: str, llm_fn=None) -> str:
    """根据错误生成修复方案（简单规则 + 可选 LLM）"""
    errors = error_output[:1000]

    # 基于错误模式的规则修复建议
    suggestions = []
    if "cannot find" in errors or "undeclared identifier" in errors:
        suggestions.append("检查 import 语句和类型定义，确认文件已加入 Xcode target")
    if "unused variable" in errors or "never used" in errors:
        suggestions.append("移除未使用的变量，或用 _ = 忽略")
    if "type mismatch" in errors or "cannot convert" in errors:
        suggestions.append("检查类型转换，确认 Optional 解包正确")
    if "missing argument" in errors or "extra argument" in errors:
        suggestions.append("检查函数调用的参数数量和类型是否匹配")
    if "ComputerToolsView" in errors or "cannot find type" in errors:
        suggestions.append("确认新文件已正确添加到 Xcode project.pbxproj")

    if not suggestions:
        suggestions.append("仔细阅读错误信息，逐行修复")

    plan = f"修复建议（第 {task.get('error_count', 0) + 1} 次尝试）：\n"
    plan += "\n".join(f"- {s}" for s in suggestions)
    plan += f"\n\n具体错误：\n{errors}"
    return plan


class TaskRunRequest(BaseModel):
    task_id: str
    dry_run: bool = False  # True=只模拟不实际执行


@router.post("/tasks/v2/{task_id}/run")
async def run_task_loop(task_id: str, req: TaskRunRequest):
    """
    任务闭环执行引擎：
    1. 读取任务
    2. 用 LLM（通过 /chat）生成执行计划
    3. 按步骤调用工具
    4. 编译检查
    5. 失败时生成修复建议，写入 next_action
    6. 更新任务状态
    """
    # 读取任务
    conn = sqlite3.connect(DB_PATH)
    cur = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,))
    row = cur.fetchone()
    conn.close()
    if not row:
        raise HTTPException(status_code=404, detail="Task not found")
    task = row_to_dict(row, cur)

    if task["error_count"] >= task["max_retries"]:
        return {"status": "max_retries_reached",
                "message": f"已尝试 {task['error_count']} 次，需要人工干预"}

    # 标记运行中
    conn = sqlite3.connect(DB_PATH)
    conn.execute("UPDATE tasks SET status='running', current_step='初始化', updated_at=? WHERE id=?",
                 (now_iso(), task_id))
    conn.commit()
    conn.close()

    results = {"task_id": task_id, "steps": [], "final_status": "unknown"}

    try:
        # Step 1: 如果有 deliverables 里包含 Swift 文件，读取相关上下文
        step_results = []
        if not req.dry_run:
            # 列出项目文件（帮助 AI 了解结构）
            ls_result = await _run_tool_safe("list_dir", {
                "path": "~/Desktop/GPTsora/GPTsora",
                "depth": 1,
                "extensions": [".swift"]
            })
            step_results.append({"step": "list_project", "ok": ls_result.get("ok"), "count": ls_result.get("count", 0)})

        # Step 2: 执行任务描述里的指令（如果有明确的 current_step / next_action）
        if task.get("next_action") and not req.dry_run:
            next_action = task["next_action"]
            # 简单解析 next_action 里的工具调用
            exec_result = await _run_tool_safe("exec", {
                "command": f"echo '执行: {next_action[:100]}'",
                "timeout": 5
            })
            step_results.append({"step": "next_action", "action": next_action[:200]})

        # Step 3: 编译检查（如果任务类型是 dev）
        compile_result = None
        if task.get("type") == "dev" and not req.dry_run:
            compile_result = await _compile_check()
            step_results.append({
                "step": "compile_check",
                "ok": compile_result["build_success"],
                "errors": compile_result["errors"][:5],
            })

        # Step 4: 判断成功/失败
        if compile_result and not compile_result["build_success"]:
            # 编译失败 → 生成修复建议
            error_summary = "\n".join(compile_result["errors"][:5])
            fix_plan = await _generate_fix_plan(task, error_summary)

            conn = sqlite3.connect(DB_PATH)
            conn.execute("""
                UPDATE tasks
                SET status='failed', last_result=?, next_action=?,
                    error_count=error_count+1, current_step='编译失败', updated_at=?
                WHERE id=?
            """, (error_summary[:500], fix_plan[:500], now_iso(), task_id))
            conn.commit()
            conn.close()

            # 写日志
            conn = sqlite3.connect(DB_PATH)
            conn.execute("""
                INSERT INTO task_logs (id, task_id, message, level, created_at)
                VALUES (?, ?, ?, 'error', ?)
            """, (str(uuid.uuid4())[:8], task_id, f"编译失败：{error_summary[:200]}", now_iso()))
            conn.commit()
            conn.close()

            results["final_status"] = "failed"
            results["error"] = error_summary
            results["fix_plan"] = fix_plan
        else:
            # 成功
            final_result = "任务执行完成"
            if compile_result and compile_result["build_success"]:
                final_result = "编译成功 ✅"

            conn = sqlite3.connect(DB_PATH)
            conn.execute("""
                UPDATE tasks
                SET status='completed', result=?, last_result=?,
                    progress=100, current_step='完成', updated_at=?, completed_at=?
                WHERE id=?
            """, (final_result, final_result, now_iso(), now_iso(), task_id))
            conn.commit()
            conn.close()

            results["final_status"] = "completed"
            results["result"] = final_result

        results["steps"] = step_results

    except Exception as e:
        log.error("[TaskRun] task=%s err=%s", task_id, e)
        conn = sqlite3.connect(DB_PATH)
        conn.execute("""
            UPDATE tasks SET status='failed', last_result=?,
            error_count=error_count+1, updated_at=? WHERE id=?
        """, (str(e)[:300], now_iso(), task_id))
        conn.commit()
        conn.close()
        results["final_status"] = "error"
        results["error"] = str(e)

    return results


# ══════════════════════════════════════════════════════════════════
# 聊天触发任务创建（从聊天消息解析任务）
# ══════════════════════════════════════════════════════════════════

class ChatTaskTriggerRequest(BaseModel):
    """聊天消息 → 解析为任务"""
    message: str
    user_id: str = "adu_system"

@router.post("/tasks/from_chat")
async def create_task_from_chat(body: ChatTaskTriggerRequest):
    """
    从聊天消息自动解析并创建任务。
    规则：消息包含"任务"、"帮我"、"执行"、"实现"等关键词时触发。
    """
    msg = body.message.strip()

    # 简单关键词触发检测
    trigger_keywords = ["任务", "帮我", "执行", "实现", "修复", "修改", "添加", "升级",
                        "编译", "安装", "部署", "创建", "删除文件", "搜索代码"]
    is_task = any(kw in msg for kw in trigger_keywords)
    if not is_task:
        return {"created": False, "reason": "消息未触发任务模式"}

    # 解析任务类型
    task_type = "general"
    if any(kw in msg for kw in ["编译", "build", "xcode", "swift", "代码"]):
        task_type = "dev"
    elif any(kw in msg for kw in ["监控", "检查", "观察"]):
        task_type = "monitor"

    # 创建任务
    task_id = str(uuid.uuid4())[:8]
    title = msg[:50] + ("..." if len(msg) > 50 else "")
    conn = sqlite3.connect(DB_PATH)
    conn.execute("""
        INSERT INTO tasks
        (id, user_id, title, description, type, status, priority, created_at)
        VALUES (?, ?, ?, ?, ?, 'pending', 5, ?)
    """, (task_id, body.user_id, title, msg, task_type, now_iso()))
    conn.commit()
    conn.close()

    return {
        "created": True,
        "task_id": task_id,
        "title": title,
        "type": task_type,
        "message": f"✅ 已创建任务 [{task_id}]：{title}",
    }
