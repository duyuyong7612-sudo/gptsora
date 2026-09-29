# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-15437bf043bef4ef41abf7344e339843d2066b650abae077f6092a5a3ad2c73f"
# Source-SHA256: "60f8c3fd1732e031a4c15482fcfcd2b5d36c60d7d53362ba5a427ec21bc5985a"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
ChatRouter - 双轨路由决策层
============================
判断用户消息应该走直连 AI API（快、便宜）还是 OpenClaw Agent（有工具能力）。

用法:
    route = classify_task("帮我读一下项目代码")
    # → TaskRoute(type=AGENT, tools=["file"])
"""

import re
from dataclasses import dataclass, field
from enum import Enum
from typing import Optional


class RouteType(str, Enum):
    DIRECT = "direct"   # 直连 AI API (GPT/Claude)
    AGENT = "agent"     # 走 OpenClaw Agent


@dataclass
class TaskRoute:
    type: RouteType
    tools: list[str] = field(default_factory=list)
    reason: str = ""


# ─── 关键词规则 ──────────────────────────────────────

# (类别, 关键词列表, 需要的工具)
AGENT_RULES: list[tuple[str, list[str], list[str]]] = [
    # 文件操作
    ("file_ops", [
        "读取文件", "写入文件", "创建文件", "修改文件", "删除文件",
        "read file", "write file", "create file", "edit file",
        "打开项目", "看一下代码", "看看代码", "读代码", "项目结构",
        "目录结构", "文件列表", "file tree", "ls ", "cat ",
        "看一下这个文件", "读一下", "打开这个",
    ], ["file"]),

    # 代码执行
    ("exec", [
        "运行", "执行", "编译", "构建",
        "run ", "execute", "build", "compile",
        "npm install", "npm run", "pip install", "pip ",
        "python ", "node ", "swift ", "xcodebuild",
        "部署", "deploy", "安装依赖", "install",
        "git clone", "git pull", "git push", "git commit",
        "make", "cargo ", "go run", "go build",
        "测试", "test", "跑一下",
    ], ["exec"]),

    # 浏览器
    ("browser", [
        "打开网页", "浏览器", "截图", "网页截图",
        "抓取", "爬取", "提取网页",
        "browse", "screenshot", "scrape", "fetch url",
        "打开 http", "打开 https", "访问网站",
        "看看这个网站", "分析这个网页",
    ], ["browser"]),

    # 项目级任务
    ("project", [
        "项目分析", "代码审查", "代码review", "code review",
        "重构", "refactor", "优化代码",
        "生成模块", "生成组件", "写一个完整的",
        "整个项目", "工程结构", "架构分析",
        "Xcode项目", "SwiftUI", "React项目",
        "分析一下这个项目", "帮我改这个项目",
    ], ["file", "exec"]),

    # 文件交付/下载
    ("file_delivery", [
        "下载", "导出", "打包", "zip",
        "给我文件", "生成文件", "保存为文件",
        "download", "export", "生成报告",
        "写成文档", "生成pdf", "生成docx",
        "给我一个可下载的",
    ], ["file"]),

    # 定时任务
    ("cron", [
        "定时", "每天", "每小时", "每周",
        "cron", "schedule", "定期",
        "提醒我", "自动执行",
    ], ["cron"]),

    # 系统操作
    ("system", [
        "终端", "命令行", "terminal", "shell",
        "系统信息", "磁盘空间", "内存",
        "进程", "端口", "process",
        "环境变量", "env",
    ], ["exec"]),
]

# URL 模式匹配
URL_PATTERN = re.compile(r"https?://\S+", re.IGNORECASE)

# 代码块模式（用户贴了代码让你"运行"）
CODE_BLOCK_WITH_RUN = re.compile(
    r"```[\s\S]+```[\s\S]*(运行|执行|run|跑一下|试试)", re.IGNORECASE
)


def classify_task(
    message: str,
    has_file_context: bool = False,
    force_agent: bool = False,
) -> TaskRoute:
    """
    分析用户消息，决定路由。

    Args:
        message: 用户消息文本
        has_file_context: 是否有文件上下文（用户上传了文件等）
        force_agent: 强制走 Agent（比如用户在 Project 模式下）

    Returns:
        TaskRoute(type, tools, reason)
    """
    if force_agent:
        return TaskRoute(
            type=RouteType.AGENT,
            tools=["file", "exec"],
            reason="force_agent mode",
        )

    msg = message.strip()
    msg_lower = msg.lower()
    matched_tools = set()
    matched_reason = ""

    # 1. 关键词匹配
    for category, keywords, tools in AGENT_RULES:
        for kw in keywords:
            if kw.lower() in msg_lower:
                matched_tools.update(tools)
                if not matched_reason:
                    matched_reason = f"keyword: {kw} ({category})"
                break

    # 2. URL + 浏览器意图
    if URL_PATTERN.search(msg) and any(
        w in msg_lower for w in ["打开", "访问", "抓取", "分析", "看看", "browse", "open"]
    ):
        matched_tools.add("browser")
        if not matched_reason:
            matched_reason = "url + browser intent"

    # 3. 文件上下文 + 操作意图
    if has_file_context and any(
        w in msg_lower
        for w in ["分析", "修改", "优化", "重构", "改", "fix", "debug", "analyze"]
    ):
        matched_tools.add("file")
        if not matched_reason:
            matched_reason = "file context + action intent"

    # 4. 代码块 + 运行意图
    if CODE_BLOCK_WITH_RUN.search(msg):
        matched_tools.add("exec")
        if not matched_reason:
            matched_reason = "code block + run intent"

    # 判定
    if matched_tools:
        return TaskRoute(
            type=RouteType.AGENT,
            tools=sorted(matched_tools),
            reason=matched_reason,
        )

    return TaskRoute(
        type=RouteType.DIRECT,
        reason="no agent triggers detected",
    )


# ─── 便捷判断 ────────────────────────────────────────

def needs_agent(message: str, **kwargs) -> bool:
    """快速判断是否需要 Agent"""
    return classify_task(message, **kwargs).type == RouteType.AGENT
