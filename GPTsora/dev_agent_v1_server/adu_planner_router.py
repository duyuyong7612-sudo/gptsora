# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-dc5c716c13d0cf6551a74bf6ac1f61fc9e6b08373a55e1b98d49f2640c9ff437"
# Source-SHA256: "af8faa60f90908df3c7ecefabe345f6ad9d479821fe8835909a575727eda70a2"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
ChatAGI Adu semantic task planner.

Mount this router from the main FastAPI app:

    from dev_agent_v1_server.adu_planner_router import router as adu_planner_router
    app.include_router(adu_planner_router)

The planner only classifies and prepares prompts. It never executes Codex,
computer actions, deployments, commits, shell commands, or code changes.
"""

from __future__ import annotations

import asyncio
import json
import os
import urllib.error
import urllib.request
from typing import Any, Dict, List, Literal, Optional

from fastapi import APIRouter
from pydantic import BaseModel, Field


router = APIRouter(prefix="/api/adu/planner", tags=["adu_planner"])

Intent = Literal[
    "computer_action",
    "codex_task",
    "claude_task",
    "chat_answer",
    "self_upgrade_task",
    "continue_previous_task",
    "confirm_pending_task",
    "cancel_pending_task",
    "edit_pending_task",
    "ask_clarification",
]


class RecentMessage(BaseModel):
    role: str = Field(default="")
    content: str = Field(default="")


class PendingCodexTask(BaseModel):
    exists: bool = False
    project: Optional[str] = None
    prompt: Optional[str] = None
    summary: Optional[str] = None
    risk_level: Optional[str] = None
    created_at: Optional[str] = None


class PlannerRequest(BaseModel):
    text: str = Field(default="")
    surface: str = Field(default="home_chat")
    recent_messages: List[RecentMessage] = Field(default_factory=list)
    pending_codex_task: Optional[PendingCodexTask] = None
    selected_project: Optional[str] = None
    screen_state: Dict[str, Any] = Field(default_factory=dict)


class PlannerResponse(BaseModel):
    ok: bool = True
    intent: Intent
    confidence: float = 0.0
    surface: str = "home_chat"
    project: Optional[str] = None
    executor: str = "none"
    title: str = ""
    summary: str = ""
    computer_goal: str = ""
    codex_prompt: str = ""
    claude_prompt: str = ""
    chat_answer: str = ""
    risk_level: str = "low"
    needs_user_confirmation: bool = False
    blocked_terms: List[str] = Field(default_factory=list)
    next_action: str = "none"
    message: str = ""


SYSTEM_PROMPT = """
你是 ChatAGI 阿杜的任务规划器。
你的任务不是直接完成用户请求，而是判断用户当前输入应该交给哪个执行器。

你必须结合：
- 用户输入的真实语义
- 最近对话上下文
- 是否存在 pending Codex task
- 当前页面 surface
- 当前 selected_project
- 用户是否在确认、继续、取消、修改上一轮任务
- 当前系统状态 screen_state

必须返回严格 JSON。
不要输出 markdown。
不要输出解释性长文。
不要编造执行结果。
planner 只规划，不执行。

判断规则：
1. 如果用户说“继续、继续给 codex、接着做、就按这个、确认运行”，必须先看 pending_codex_task。
   - 如果存在 pending task：返回 continue_previous_task 或 confirm_pending_task。
   - 如果不存在 pending task：返回 ask_clarification。
2. 只有用户表达明确工程目标时，才返回 codex_task。
3. 普通解释、原因分析、概念说明，返回 chat_answer。
4. 明确电脑动作，返回 computer_action。
5. 自我升级、自我检查、递归自我改进类表达，返回 self_upgrade_task。
6. 不要因为文本里出现 “codex” 这个词就直接判断为 codex_task。
7. 高风险或不明确任务，needs_user_confirmation=true。
8. 如果用户输入太短或上下文不足，返回 ask_clarification。

安全边界：
- 不直接执行 Codex。
- 不改代码。
- 不执行系统命令。
- 不做发布。
- 不做版本提交。
- 不读取敏感配置。
- 不返回任何密钥。

只返回一个 JSON object，字段必须包含：
ok,intent,confidence,surface,project,executor,title,summary,computer_goal,codex_prompt,
claude_prompt,chat_answer,risk_level,needs_user_confirmation,blocked_terms,next_action,message
""".strip()


def _pending(req: PlannerRequest) -> PendingCodexTask:
    return req.pending_codex_task or PendingCodexTask()


def _response(**kwargs: Any) -> PlannerResponse:
    base: Dict[str, Any] = {
        "ok": True,
        "intent": "ask_clarification",
        "confidence": 0.0,
        "surface": "home_chat",
        "project": None,
        "executor": "none",
        "title": "",
        "summary": "",
        "computer_goal": "",
        "codex_prompt": "",
        "claude_prompt": "",
        "chat_answer": "",
        "risk_level": "low",
        "needs_user_confirmation": False,
        "blocked_terms": [],
        "next_action": "none",
        "message": "",
    }
    base.update(kwargs)
    return PlannerResponse(**base)


def _project_for(text: str, selected: Optional[str]) -> str:
    selected = (selected or "").strip()
    if selected:
        return selected
    low = text.lower()
    if "little beijing" in low or "小北京" in text:
        return "LittleBeijing"
    if ("后端" in text or "backend" in low or "server_session" in low or "api" in low) and not any(
        k in text for k in ["不要改后端", "不改后端", "别改后端", "无需改后端"]
    ):
        return "Backend"
    return "GPTsora"


def _codex_prompt(text: str, project: str) -> str:
    backend_limit = "用户明确要求不要改后端；只处理 iOS 前端相关代码。" if any(
        k in text for k in ["不要改后端", "不改后端", "别改后端", "无需改后端"]
    ) else "只改本任务必要范围。"
    return (
        f"请在 {project} 项目中处理下面任务。\n\n"
        f"用户原始需求:\n{text}\n\n"
        "执行要求:\n"
        f"1. {backend_limit}\n"
        "2. 不改 local-agent、不改 Codex executor/run 逻辑、不改 Little Beijing、不改 billing。\n"
        "3. 不部署、不提交版本、不读取或输出密钥配置。\n"
        "4. 先阅读相关代码，再做最小实现；完成后运行可行的语法/编译验证。\n"
    )


def _self_upgrade_prompt(text: str) -> str:
    return (
        "请只读检查 ChatAGI 阿杜系统还能升级的地方，先输出计划，不自动执行。\n\n"
        f"用户原始需求:\n{text}\n\n"
        "要求:\n"
        "1. 分析前端、后端、agent、Codex runner 的边界和风险。\n"
        "2. 给出最小可行升级计划。\n"
        "3. 标记需要用户确认的步骤。\n"
        "4. 禁止读取或泄露 .env/API key，禁止部署、提交版本、删除数据。\n"
    )


def _fallback_plan(req: PlannerRequest, reason: str = "") -> PlannerResponse:
    text = (req.text or "").strip()
    low = text.lower()
    compact = "".join(text.split())
    pending = _pending(req)
    surface = req.surface or "home_chat"

    if not text or len(text) <= 1:
        return _response(
            intent="ask_clarification",
            confidence=0.55,
            surface=surface,
            needs_user_confirmation=True,
            next_action="ask_clarification",
            message="请再说明你想让我做什么。",
            summary=reason,
        )

    if compact in {"继续", "接着做", "继续给codex", "确认运行", "确认执行", "就按这个"} or any(
        k in text for k in ["继续给 codex", "继续给codex", "接着做", "确认运行", "就按这个"]
    ):
        if pending.exists:
            intent: Intent = "confirm_pending_task" if any(k in text for k in ["确认", "运行", "就按这个"]) else "continue_previous_task"
            return _response(
                intent=intent,
                confidence=0.9,
                surface=surface,
                project=pending.project or req.selected_project,
                executor="codex",
                title="继续待确认 Codex 任务",
                summary=pending.summary or pending.prompt or "",
                codex_prompt=pending.prompt or "",
                risk_level=pending.risk_level or "medium",
                needs_user_confirmation=True,
                next_action="show_codex_confirmation",
                message="已找到待继续的 Codex 任务，请确认后再运行。",
            )
        return _response(
            intent="ask_clarification",
            confidence=0.88,
            surface=surface,
            needs_user_confirmation=True,
            next_action="ask_clarification",
            message="当前没有待继续或待执行的 Codex 任务，请说明要处理的新任务。",
        )

    if any(k in text for k in ["取消", "别运行", "不要运行", "不用了", "算了"]):
        if pending.exists:
            return _response(
                intent="cancel_pending_task",
                confidence=0.86,
                surface=surface,
                project=pending.project or req.selected_project,
                executor="none",
                title="取消待执行任务",
                summary=pending.summary or "",
                next_action="none",
                message="已取消待执行的 Codex 任务。",
            )
        return _response(
            intent="ask_clarification",
            confidence=0.7,
            surface=surface,
            next_action="ask_clarification",
            message="当前没有待取消的 Codex 任务。",
        )

    if any(k in text for k in ["自我升级", "自己升级", "递归", "自我改进", "检查系统哪里还能升级", "哪里还能升级"]):
        prompt = _self_upgrade_prompt(text)
        return _response(
            intent="self_upgrade_task",
            confidence=0.9,
            surface=surface,
            project="GPTsora",
            executor="self_upgrade",
            title="自我升级检查计划",
            summary="用户要求阿杜检查系统可升级点，应先生成计划并等待确认。",
            codex_prompt=prompt,
            risk_level="high",
            needs_user_confirmation=True,
            next_action="show_codex_confirmation",
            message="我可以先整理自我升级检查计划，需要你确认后再交给 Codex。",
        )

    if any(k in text for k in ["什么意思", "为什么", "解释", "原因", "含义", "是什么"]) or text.endswith(("?", "？")):
        answer = "这是一个普通解释问题，不应执行电脑动作或 Codex。"
        if "not_simple_computer_action" in low:
            answer = "not_simple_computer_action 通常表示输入没有被识别为可直接执行的简单电脑动作，因此系统会停在解释或规划层，避免误触发电脑控制。"
        return _response(
            intent="chat_answer",
            confidence=0.86,
            surface=surface,
            executor="chat",
            title="解释问题",
            summary=text,
            chat_answer=answer,
            next_action="answer_chat",
            message=answer,
        )

    if compact.startswith(("打开", "点击", "输入", "按", "切换到", "关闭")) and not any(k in text for k in ["修复", "代码", "页面", "编译"]):
        return _response(
            intent="computer_action",
            confidence=0.88,
            surface=surface,
            executor="computer",
            title="电脑动作",
            summary=text,
            computer_goal=text,
            next_action="execute_computer_action",
            message="已识别为电脑动作。",
        )

    has_engineering_goal = any(k in text for k in ["修复", "新增", "实现", "接入", "编译", "构建", "代码", "页面", "接口"])
    if has_engineering_goal:
        project = _project_for(text, req.selected_project)
        return _response(
            intent="codex_task",
            confidence=0.84,
            surface=surface,
            project=project,
            executor="codex",
            title="自动化编程任务",
            summary=text,
            codex_prompt=_codex_prompt(text, project),
            risk_level="medium",
            needs_user_confirmation=True,
            next_action="show_codex_confirmation",
            message="已整理为 Codex 任务，请确认后再运行。",
        )

    return _response(
        intent="ask_clarification",
        confidence=0.52,
        surface=surface,
        needs_user_confirmation=True,
        next_action="ask_clarification",
        message="我还不确定要执行电脑动作、交给 Codex，还是只回答问题。请再补充一句目标。",
    )


def _extract_json_object(raw: str) -> Dict[str, Any]:
    text = (raw or "").strip()
    if text.startswith("```"):
        text = text.strip("`")
        if text.lower().startswith("json"):
            text = text[4:].strip()
    start = text.find("{")
    end = text.rfind("}")
    if start >= 0 and end >= start:
        text = text[start : end + 1]
    obj = json.loads(text)
    if not isinstance(obj, dict):
        raise ValueError("planner model did not return a JSON object")
    return obj


def _call_openai_json(req: PlannerRequest) -> Dict[str, Any]:
    key = os.getenv("OPENAI_API_KEY") or os.getenv("SORA_API_KEY")
    if not key:
        raise RuntimeError("missing model api key")

    model = os.getenv("ADU_PLANNER_MODEL") or os.getenv("OPENAI_CHAT_MODEL") or "gpt-4o-mini"
    payload = {
        "model": model,
        "temperature": 0.1,
        "response_format": {"type": "json_object"},
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": json.dumps(req.model_dump(), ensure_ascii=False)},
        ],
    }
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    http_req = urllib.request.Request(
        "https://api.openai.com/v1/chat/completions",
        data=data,
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(http_req, timeout=20) as resp:
        body = json.loads(resp.read().decode("utf-8"))
    content = body["choices"][0]["message"]["content"]
    return _extract_json_object(content)


def _coerce_model_plan(req: PlannerRequest, obj: Dict[str, Any]) -> PlannerResponse:
    fallback = _fallback_plan(req)
    merged = fallback.model_dump()
    for key, value in obj.items():
        if key in merged and value is not None:
            merged[key] = value
    merged["ok"] = True
    merged["surface"] = merged.get("surface") or req.surface
    return PlannerResponse(**merged)


@router.post("/route", response_model=PlannerResponse)
async def route(req: PlannerRequest) -> PlannerResponse:
    text = (req.text or "").strip()
    req.text = text
    if not text:
        return _fallback_plan(req)

    try:
        obj = await asyncio.to_thread(_call_openai_json, req)
        return _coerce_model_plan(req, obj)
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, RuntimeError, ValueError, KeyError, json.JSONDecodeError):
        return _fallback_plan(req, reason="model_unavailable_fallback")

