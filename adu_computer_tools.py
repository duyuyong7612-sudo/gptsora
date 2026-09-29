# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-ec54904f763af03773325536125bf579e7d5c4690615acf737fd8f6fe4eb1279"
# Source-SHA256: "36424e738755667bbd9f2174c8c42806f6be13391e7cb7f8c0a125774147d1d4"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
adu_computer_tools.py
======================
统一的电脑控制工具协议 v1

提供五个核心工具：exec / read_file / write_file / search_code / list_dir
全部走本地 subprocess，不依赖 OpenClaw bridge。

安全策略（默认）：
- 文件操作只允许在 ALLOWED_ROOTS 白名单内
- 禁止危险命令（rm -rf / sudo / chmod 777 / mkfs 等）
- 危险命令先拦截，返回原因，不执行
- 可通过 confirm=True 显式覆盖（由前端确认后传入）
"""

import asyncio
import os
import re
import subprocess
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

# ── 安全策略 ──────────────────────────────────────────────────────────────────

HOME = os.path.expanduser("~")

# 默认允许的根目录（文件操作只在这些目录内有效）
ALLOWED_ROOTS: List[str] = [
    os.path.join(HOME, "Desktop", "GPTsora"),
    os.path.join(HOME, "Desktop", "backend"),
    os.path.join(HOME, ".openclaw", "workspace"),
    "/tmp",
]

# 危险命令模式（正则，匹配到则拦截）
DANGEROUS_PATTERNS: List[Tuple[str, str]] = [
    (r'\brm\s+-rf?\b',           "rm -rf 可能删除大量文件"),
    (r'\bsudo\b',                "sudo 需要权限提升"),
    (r'\bmkfs\b',                "mkfs 会格式化磁盘"),
    (r'\bdd\s+if=',              "dd if= 可能破坏磁盘"),
    (r'>\s*/dev/(disk|sd|hd)',   "写入磁盘设备文件"),
    (r'\bchmod\s+777\b',         "chmod 777 过度开放权限"),
    (r'\bchown\s+-R\b',          "递归修改文件所有者"),
    (r'\bcurl\s+.*\|\s*sh\b',   "管道执行远程脚本"),
    (r'\bwget\s+.*\|\s*sh\b',   "管道执行远程脚本"),
    (r'eval\s+\$\(',             "eval 执行动态命令"),
    (r'\bnohup\b.*&',            "后台常驻进程"),
    (r'\bkillall\b',             "killall 可能终止关键进程"),
    (r'\bpkill\s+-9\b',         "强制 kill 进程"),
    (r'\blaunchctl\b',           "launchctl 修改系统服务"),
    (r'\bcrontab\b',             "crontab 修改定时任务"),
]

# 允许覆盖的命令白名单（即使触发危险检测，如果在白名单里也放行）
SAFE_OVERRIDES: List[str] = [
    "pkill -9 -f adu_loop",  # 停止已知循环进程
]


def _is_path_allowed(path: str) -> Tuple[bool, str]:
    """检查路径是否在允许的根目录内"""
    abs_path = os.path.realpath(os.path.expanduser(path))
    for root in ALLOWED_ROOTS:
        abs_root = os.path.realpath(root)
        try:
            Path(abs_path).relative_to(abs_root)
            return True, ""
        except ValueError:
            continue
    return False, f"路径 '{path}' 不在允许的工作区内（{', '.join(ALLOWED_ROOTS)}）"


def _check_command_safety(cmd: str) -> Tuple[bool, str]:
    """检查命令是否安全，返回 (is_safe, reason)"""
    # 白名单优先
    for safe in SAFE_OVERRIDES:
        if safe in cmd:
            return True, ""

    for pattern, reason in DANGEROUS_PATTERNS:
        if re.search(pattern, cmd, re.IGNORECASE):
            return False, reason

    return True, ""


# ── 工具实现 ───────────────────────────────────────────────────────────────────

async def tool_exec(
    command: str,
    timeout: int = 30,
    confirm: bool = False,
    workdir: Optional[str] = None,
) -> Dict[str, Any]:
    """
    执行终端命令。
    - 默认拦截危险命令，需要前端 confirm=True 才执行
    - timeout 最大 120s
    """
    if not command.strip():
        return {"ok": False, "error": "命令为空", "blocked": False}

    is_safe, reason = _check_command_safety(command)
    if not is_safe and not confirm:
        return {
            "ok": False,
            "blocked": True,
            "reason": reason,
            "command": command,
            "requires_confirm": True,
        }

    cwd = None
    if workdir:
        cwd = os.path.expanduser(workdir)

    timeout = min(timeout, 120)
    try:
        proc = await asyncio.create_subprocess_shell(
            command,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            cwd=cwd,
            env={**os.environ, "TERM": "xterm-256color"},
        )
        try:
            stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=timeout)
        except asyncio.TimeoutError:
            proc.kill()
            return {"ok": False, "error": f"命令超时（>{timeout}s）", "command": command, "blocked": False}

        output = stdout.decode("utf-8", errors="replace") if stdout else ""
        return {
            "ok": True,
            "output": output,
            "exit_code": proc.returncode,
            "command": command,
            "blocked": False,
        }
    except Exception as e:
        return {"ok": False, "error": str(e), "command": command, "blocked": False}


async def tool_read_file(
    path: str,
    start_line: Optional[int] = None,
    end_line: Optional[int] = None,
    max_chars: int = 50_000,
) -> Dict[str, Any]:
    """
    读取文件内容。
    - 只允许读取白名单目录内的文件
    - 支持行范围读取
    """
    allowed, err = _is_path_allowed(path)
    if not allowed:
        return {"ok": False, "error": err, "blocked": True}

    abs_path = os.path.expanduser(path)
    if not os.path.isfile(abs_path):
        return {"ok": False, "error": f"文件不存在：{path}"}

    try:
        with open(abs_path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()

        total = len(lines)

        if start_line is not None or end_line is not None:
            s = max(0, (start_line or 1) - 1)
            e = min(total, end_line or total)
            selected = lines[s:e]
        else:
            selected = lines

        content = "".join(selected)
        truncated = False
        if len(content) > max_chars:
            content = content[:max_chars]
            truncated = True

        return {
            "ok": True,
            "content": content,
            "path": path,
            "total_lines": total,
            "shown_lines": len(selected),
            "truncated": truncated,
        }
    except Exception as e:
        return {"ok": False, "error": str(e)}


async def tool_write_file(
    path: str,
    content: str,
    mode: str = "overwrite",  # overwrite | append | insert
    insert_line: Optional[int] = None,
    confirm: bool = False,
) -> Dict[str, Any]:
    """
    写入文件。
    - 只允许写入白名单目录内的文件
    - overwrite: 完全替换
    - append: 追加到末尾
    - insert: 在指定行插入
    - 写入前自动备份（.bak）
    """
    allowed, err = _is_path_allowed(path)
    if not allowed:
        return {"ok": False, "error": err, "blocked": True}

    abs_path = os.path.expanduser(path)

    # 如果文件已存在且是 overwrite，需要 confirm
    if mode == "overwrite" and os.path.isfile(abs_path) and not confirm:
        return {
            "ok": False,
            "blocked": True,
            "reason": f"文件 '{path}' 已存在，覆盖写入需要确认",
            "requires_confirm": True,
        }

    try:
        # 备份
        if os.path.isfile(abs_path):
            bak = abs_path + ".bak"
            with open(abs_path, "r", encoding="utf-8", errors="replace") as f:
                bak_content = f.read()
            with open(bak, "w", encoding="utf-8") as f:
                f.write(bak_content)

        # 写入
        os.makedirs(os.path.dirname(abs_path) or ".", exist_ok=True)

        if mode == "append":
            with open(abs_path, "a", encoding="utf-8") as f:
                f.write(content)
        elif mode == "insert" and insert_line is not None:
            if os.path.isfile(abs_path):
                with open(abs_path, "r", encoding="utf-8") as f:
                    lines = f.readlines()
            else:
                lines = []
            lines.insert(max(0, insert_line - 1), content + "\n")
            with open(abs_path, "w", encoding="utf-8") as f:
                f.writelines(lines)
        else:  # overwrite
            with open(abs_path, "w", encoding="utf-8") as f:
                f.write(content)

        return {
            "ok": True,
            "path": path,
            "mode": mode,
            "bytes_written": len(content.encode("utf-8")),
        }
    except Exception as e:
        return {"ok": False, "error": str(e)}


async def tool_search_code(
    keyword: str,
    path: str = "~/Desktop/GPTsora",
    file_pattern: str = "*.swift",
    max_results: int = 30,
    context_lines: int = 2,
) -> Dict[str, Any]:
    """
    在代码文件中搜索关键词（grep）。
    - 只允许搜索白名单目录
    - 返回匹配行及上下文
    """
    allowed, err = _is_path_allowed(path)
    if not allowed:
        return {"ok": False, "error": err, "blocked": True}

    abs_path = os.path.expanduser(path)
    cmd = (
        f'grep -rn --include="{file_pattern}" '
        f'-B{context_lines} -A{context_lines} '
        f'"{keyword}" "{abs_path}" 2>/dev/null | head -n {max_results * (context_lines * 2 + 3)}'
    )

    result = await tool_exec(cmd, timeout=15)
    if not result["ok"]:
        return result

    output = result["output"] or ""
    # 统计匹配数
    match_count = output.count(f"\n") // max(1, context_lines * 2 + 2)

    return {
        "ok": True,
        "keyword": keyword,
        "path": path,
        "file_pattern": file_pattern,
        "output": output,
        "approx_matches": match_count,
    }


async def tool_list_dir(
    path: str = "~/Desktop/GPTsora",
    depth: int = 2,
    extensions: Optional[List[str]] = None,
    include_hidden: bool = False,
) -> Dict[str, Any]:
    """
    列出目录下的文件。
    - 只允许列出白名单目录
    - 支持按扩展名过滤
    """
    allowed, err = _is_path_allowed(path)
    if not allowed:
        return {"ok": False, "error": err, "blocked": True}

    abs_path = os.path.expanduser(path)
    if not os.path.isdir(abs_path):
        return {"ok": False, "error": f"目录不存在：{path}"}

    depth = min(depth, 5)
    ext_filter = ""
    if extensions:
        parts = " -o ".join([f'-name "*{e}"' for e in extensions])
        ext_filter = f" \\( {parts} \\)"

    hidden_filter = "" if include_hidden else ' -not -name ".*"'
    cmd = (
        f'find "{abs_path}" -maxdepth {depth}{ext_filter}{hidden_filter} '
        f'-not -path "*/Pods/*" -not -path "*/.git/*" '
        f'-not -path "*/node_modules/*" -not -path "*/DerivedData/*" '
        f'-not -path "*/.venv*" -not -path "*/__pycache__/*" '
        f'| sort | head -200'
    )

    result = await tool_exec(cmd, timeout=15)
    if not result["ok"]:
        return result

    files = [f for f in (result["output"] or "").split("\n") if f.strip()]
    return {
        "ok": True,
        "path": path,
        "files": files,
        "count": len(files),
    }


# ── 工具路由（统一入口）────────────────────────────────────────────────────────

TOOL_REGISTRY = {
    "exec":        tool_exec,
    "read_file":   tool_read_file,
    "write_file":  tool_write_file,
    "search_code": tool_search_code,
    "list_dir":    tool_list_dir,
}

async def dispatch_tool(
    tool_name: str,
    params: Dict[str, Any],
) -> Dict[str, Any]:
    """统一工具调用入口"""
    fn = TOOL_REGISTRY.get(tool_name)
    if fn is None:
        return {"ok": False, "error": f"未知工具：{tool_name}"}
    try:
        return await fn(**params)
    except TypeError as e:
        return {"ok": False, "error": f"参数错误：{e}"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


# ── OpenAI Function-call 工具定义（供 LLM 调用）─────────────────────────────

TOOL_DEFINITIONS = [
    {
        "type": "function",
        "function": {
            "name": "exec",
            "description": "在用户电脑上执行终端命令（shell）。危险命令会被拦截并要求确认。",
            "parameters": {
                "type": "object",
                "properties": {
                    "command":  {"type": "string", "description": "要执行的 shell 命令"},
                    "timeout":  {"type": "integer", "description": "超时秒数，默认30，最大120", "default": 30},
                    "confirm":  {"type": "boolean", "description": "是否已经用户确认（危险命令需要）", "default": False},
                    "workdir":  {"type": "string", "description": "工作目录，可选"},
                },
                "required": ["command"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "read_file",
            "description": "读取用户电脑上的文件内容。只允许读取项目目录内的文件。",
            "parameters": {
                "type": "object",
                "properties": {
                    "path":       {"type": "string", "description": "文件路径（绝对路径或~开头）"},
                    "start_line": {"type": "integer", "description": "起始行号（1-indexed），可选"},
                    "end_line":   {"type": "integer", "description": "结束行号，可选"},
                },
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "write_file",
            "description": "写入文件。覆盖已有文件需要用户确认。自动创建备份。",
            "parameters": {
                "type": "object",
                "properties": {
                    "path":        {"type": "string", "description": "文件路径"},
                    "content":     {"type": "string", "description": "文件内容"},
                    "mode":        {"type": "string", "enum": ["overwrite", "append", "insert"], "default": "overwrite"},
                    "insert_line": {"type": "integer", "description": "插入行号（mode=insert时）"},
                    "confirm":     {"type": "boolean", "description": "是否已确认覆盖", "default": False},
                },
                "required": ["path", "content"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "search_code",
            "description": "在代码文件中搜索关键词（类似 grep -rn）。",
            "parameters": {
                "type": "object",
                "properties": {
                    "keyword":      {"type": "string", "description": "搜索关键词"},
                    "path":         {"type": "string", "description": "搜索目录", "default": "~/Desktop/GPTsora"},
                    "file_pattern": {"type": "string", "description": "文件名通配符", "default": "*.swift"},
                    "max_results":  {"type": "integer", "description": "最大结果数", "default": 30},
                },
                "required": ["keyword"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "list_dir",
            "description": "列出目录下的文件和文件夹。",
            "parameters": {
                "type": "object",
                "properties": {
                    "path":       {"type": "string", "description": "目录路径", "default": "~/Desktop/GPTsora"},
                    "depth":      {"type": "integer", "description": "递归深度 1-5", "default": 2},
                    "extensions": {"type": "array",  "items": {"type": "string"}, "description": "文件扩展名过滤，如 [\".swift\", \".py\"]"},
                },
                "required": [],
            },
        },
    },
]


# ── 安全配置 API（供前端查询/修改）────────────────────────────────────────────

def get_security_config() -> Dict[str, Any]:
    return {
        "allowed_roots": ALLOWED_ROOTS,
        "dangerous_patterns": [p for p, _ in DANGEROUS_PATTERNS],
        "tool_names": list(TOOL_REGISTRY.keys()),
    }


def add_allowed_root(path: str) -> None:
    abs_path = os.path.realpath(os.path.expanduser(path))
    if abs_path not in ALLOWED_ROOTS:
        ALLOWED_ROOTS.append(abs_path)


def remove_allowed_root(path: str) -> None:
    abs_path = os.path.realpath(os.path.expanduser(path))
    if abs_path in ALLOWED_ROOTS:
        ALLOWED_ROOTS.remove(abs_path)
