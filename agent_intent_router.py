# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-33510b7b6674d47daaab652c10dcc5c4c7856de65181c083752d08e6ae4a491a"
# Source-SHA256: "641e3726e2a6d1ca9dac0fc587e768830b8655a4141faa98bacded1811d6c5e0"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
agent_intent_router.py  v2.1
============================
可执行动作协议(五类基础工具 + 安全层)

工具类型:
  exec        — 终端命令执行
  read_file   — 文件读取(支持行范围,失败时自动 fuzzy 搜索候选)
  write_file  — 文件写入(限工作区)
  search_code — 代码搜索
  list_files  — 目录列出(新增,支持 glob 模式)

安全层:
  A. 危险命令黑名单 → 自动拒绝
  B. 工作区白名单   → 文件操作限 SAFE_ROOTS
  C. 高危命令确认   → 写操作/删除需 confirm=true
  D. 超时限制       → exec 最大 180s

动作协议(嵌入 AI 回复):
  [ADU_ACTION:exec|命令]
  [ADU_ACTION:list_files|路径]
  [ADU_ACTION:list_files|路径|通配符]        # 例: *.swift
  [ADU_ACTION:read_file|路径|起始行|结束行]
  [ADU_ACTION:write_file|路径|内容]
  [ADU_ACTION:search_code|关键词|路径]
  [ADU_ACTION:agent_task|任务描述]

v2.1 变更:
  + 新增 list_files 工具(填补"先探索后读取"的空缺,避免 LLM 猜文件名)
  + read_file 文件不存在时自动在 SAFE_ROOTS fuzzy 搜索相似名,回给候选
  + AGENT_TOOLS_PROMPT 增加"读文件前先探索"的工作模式引导
"""

import re
import json
import logging
import os
import asyncio
import subprocess
import shlex
import fnmatch
import difflib
from pathlib import Path
from typing import Optional, Dict, Any, Tuple, List

logger = logging.getLogger("agent_intent")

# ══════════════════════════════════════════════════════════════════
# 安全配置
# ══════════════════════════════════════════════════════════════════

# 工作区白名单（文件读写只允许这些路径下）
SAFE_ROOTS: List[str] = [
    os.path.expanduser("~/Desktop/GPTsora"),
    os.path.expanduser("~/Desktop/backend"),
    os.path.expanduser("~/Desktop/chatterbox"),
    os.path.expanduser("~/Desktop/frontend"),
    os.path.expanduser("~/.openclaw/workspace"),
    "/tmp",
]

# 危险命令黑名单（包含任意一条即拒绝）
DANGEROUS_PATTERNS: List[str] = [
    "rm -rf /",
    "rm -rf ~",
    "sudo rm",
    "mkfs",
    "> /dev/",
    "dd if=/dev/zero",
    "dd if=/dev/urandom",
    "chmod -R 777 /",
    "chown -R",
    ":(){:|:&};:",  # fork bomb
    "sudo shutdown",
    "sudo reboot",
    "sudo halt",
    "launchctl unload /System",
    "defaults delete",
    "killall Finder",
    "killall SystemUIServer",
]

# 需要 confirm=true 才执行的高危操作
CONFIRM_REQUIRED_PATTERNS: List[str] = [
    "rm ",
    "rmdir",
    "git push",
    "git reset --hard",
    "git clean -fd",
    "DROP TABLE",
    "DELETE FROM",
    "truncate",
    "pkill",
    "kill -9",
]


def _is_dangerous(cmd: str) -> Tuple[bool, str]:
    """检查是否为危险命令，返回 (是否危险, 原因)"""
    cmd_lower = cmd.lower()
    for pat in DANGEROUS_PATTERNS:
        if pat.lower() in cmd_lower:
            return True, f"命令包含危险模式: '{pat}'"
    return False, ""


def _needs_confirm(cmd: str) -> Tuple[bool, str]:
    """检查是否需要用户确认"""
    cmd_lower = cmd.lower()
    for pat in CONFIRM_REQUIRED_PATTERNS:
        if pat.lower() in cmd_lower:
            return True, f"命令包含高危操作: '{pat}'，需要显式确认"
    return False, ""


def _is_path_safe(path: str) -> Tuple[bool, str]:
    """检查文件路径是否在安全工作区内"""
    resolved = str(Path(os.path.expanduser(path)).resolve())
    for root in SAFE_ROOTS:
        if resolved.startswith(root):
            return True, ""
    return False, f"路径 '{path}' 超出允许的工作区范围。允许路径: {', '.join(SAFE_ROOTS)}"


def _expand_path(p: str) -> str:
    if p.startswith("~/") or p == "~":
        return os.path.expanduser(p)
    return p


# ══════════════════════════════════════════════════════════════════
# AI System Prompt
# ══════════════════════════════════════════════════════════════════

AGENT_TOOLS_PROMPT = """
## 你的额外能力（静默使用，不要改变你的对话风格）

你可以操控用户的电脑。这只是你的一个附加能力，不是你的身份。
你依然是一个通用 AI 助手，有记忆、有个性、懂用户的项目。

### 重要：保持自然对话
- 不要说"我现在帮你执行命令"这种机械话
- 像一个懂编程的朋友一样说话，顺便帮忙干活
- 读完代码后给出你的理解和分析
- 执行完操作后用自然语言总结结果

### ⚠️ 关键工作原则：不要凭记忆猜文件名

如果用户让你读某个文件/模块但没给精确路径：
1. **先** `list_files` 列目录看清楚有哪些文件
2. **再** `read_file` 读你确定存在的文件
3. 不要凭印象/记忆构造文件名（比如 `ComputerControlPanel.swift`）再去读——你会猜错

只有当用户给出**你在同一轮对话里见过的**路径，或者明显是常见文件（`package.json`, `README.md` 等），才可以直接 read_file。

### 可用动作（A/B 两类）

#### A. 五类基础工具（直接执行，秒级返回）
[ADU_ACTION:exec|命令]                         — 执行终端命令
[ADU_ACTION:list_files|路径]                   — 列出目录(默认 1 层)
[ADU_ACTION:list_files|路径|通配符]            — 按 glob 过滤(例: *.swift)
[ADU_ACTION:read_file|路径]                    — 读取文件完整内容
[ADU_ACTION:read_file|路径|起始行|结束行]       — 读取指定行范围
[ADU_ACTION:write_file|路径|内容]              — 写入文件（限项目工作区）
[ADU_ACTION:search_code|关键词|路径]           — 按关键词搜索代码内容

#### B. 复杂任务（智能体全权处理，支持多步操作）
[ADU_ACTION:agent_task|任务描述]

复杂任务例子：
- [ADU_ACTION:agent_task|编译 GPTsora 项目并安装到已连接的 iPhone 上]
- [ADU_ACTION:agent_task|查看 Git 状态，如果有改动帮我 commit 并 push]
- [ADU_ACTION:agent_task|打开浏览器访问 github.com 并截图]
- [ADU_ACTION:agent_task|发微信给信玉说我回来了]
- [ADU_ACTION:agent_task|检查系统健康状态，包括磁盘、内存、CPU]

### 工具选择速查表
| 场景                            | 用哪个                              |
|--------------------------------|-------------------------------------|
| 不知道文件叫什么，想看目录      | list_files                          |
| 知道确切路径，要读内容          | read_file                           |
| 知道关键词，要在代码里搜        | search_code                         |
| 要跑一条 shell 命令             | exec                                |
| 多步复杂任务（编译/git/浏览器）| agent_task                          |

### 安全规则（必须遵守）
1. 文件写入只在项目工作区内（GPTsora/backend/chatterbox/frontend）
2. 删除文件/git push/kill 进程等操作请先告知用户再执行
3. 不执行系统破坏性命令（rm -rf /、sudo rm、格式化等）
4. 动作标记自然嵌入回复，不单独列出来
5. 不需要操作电脑时正常聊天，不输出任何动作标记
"""

# ══════════════════════════════════════════════════════════════════
# 动作解析
# ══════════════════════════════════════════════════════════════════

ACTION_PATTERN = re.compile(r'\[ADU_ACTION:([^\]]+)\]')


def extract_actions(text: str) -> Tuple[str, List[Dict[str, Any]]]:
    """从 AI 回复中提取动作标记，返回（清理后文本，动作列表）"""
    actions = []
    clean_lines = []

    for line in text.split('\n'):
        match = ACTION_PATTERN.search(line)
        if match:
            raw = match.group(1)
            parts = raw.split('|')
            action_type = parts[0].strip() if parts else ''
            params = [p.strip() for p in parts[1:]]
            actions.append({
                'type': action_type,
                'params': params,
                'raw': match.group(0),
            })
            cleaned = line.replace(match.group(0), '').strip()
            if cleaned:
                clean_lines.append(cleaned)
        else:
            clean_lines.append(line)

    return '\n'.join(clean_lines).strip(), actions


# ══════════════════════════════════════════════════════════════════
# 四类基础工具执行（含安全层）
# ══════════════════════════════════════════════════════════════════

async def _tool_exec(cmd: str, confirm: bool = False, timeout: int = 60) -> Dict[str, Any]:
    """
    工具1: 终端命令执行
    - 危险命令直接拒绝
    - 高危操作需 confirm=True
    - 超时保护
    """
    # 安全检查
    is_danger, danger_reason = _is_dangerous(cmd)
    if is_danger:
        return {
            "ok": False,
            "blocked": True,
            "reason": f"⛔ 安全拦截: {danger_reason}",
            "output": "",
        }

    needs_conf, conf_reason = _needs_confirm(cmd)
    if needs_conf and not confirm:
        return {
            "ok": False,
            "needs_confirm": True,
            "reason": f"⚠️ {conf_reason}。如确认执行，请回复【确认】后重试。",
            "output": "",
            "cmd": cmd,
        }

    # 长时命令加大超时
    if any(k in cmd for k in ['xcodebuild', 'pod install', 'npm install', 'pip install', 'cargo build']):
        timeout = max(timeout, 180)

    try:
        proc = await asyncio.create_subprocess_shell(
            cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            env={**os.environ, "TERM": "xterm-256color"},
        )
        try:
            stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=timeout)
        except asyncio.TimeoutError:
            proc.kill()
            return {"ok": False, "output": f"⏰ 命令超时（{timeout}s）: {cmd[:80]}"}

        output = stdout.decode("utf-8", errors="replace") if stdout else ""
        return {
            "ok": True,
            "output": output,
            "exit_code": proc.returncode,
            "cmd": cmd,
        }
    except Exception as e:
        return {"ok": False, "output": f"执行失败: {e}"}


# ── fuzzy 文件名搜索辅助(供 read_file 失败时自动建议候选) ──

# 目录扫描时跳过的目录(用于 fuzzy 搜索和 list_files)
_SKIP_DIRS = {
    '.git', '.svn', '.hg',
    'node_modules', '.pnpm', '.yarn',
    '.venv', 'venv', '__pycache__', '.mypy_cache', '.ruff_cache',
    'Pods', 'DerivedData', 'build', 'dist', '.build',
    '.next', '.nuxt', '.cache',
    '.idea', '.vscode',
}


def _fuzzy_find_file(basename_query: str, max_results: int = 5,
                     max_scanned: int = 20000) -> List[str]:
    """
    在 SAFE_ROOTS 里 fuzzy 搜索和 basename_query 最相似的文件名,返回绝对路径列表。

    策略:
    1. 先做一轮全量扫描收集所有文件 basename(跳过 _SKIP_DIRS)
    2. 用 difflib.get_close_matches 做相似度排序
    3. 最多扫描 max_scanned 个文件(防止 home 目录扫炸),超限直接返回已有结果
    """
    if not basename_query:
        return []

    target_base = os.path.basename(basename_query).lower()
    if not target_base:
        return []

    all_files: List[Tuple[str, str]] = []  # (lower_basename, fullpath)
    scanned = 0

    for root in SAFE_ROOTS:
        if not os.path.isdir(root):
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            # in-place 修剪,跳过不感兴趣的目录
            dirnames[:] = [d for d in dirnames if d not in _SKIP_DIRS and not d.startswith('.')]
            for fn in filenames:
                scanned += 1
                if scanned > max_scanned:
                    break
                all_files.append((fn.lower(), os.path.join(dirpath, fn)))
            if scanned > max_scanned:
                break
        if scanned > max_scanned:
            break

    if not all_files:
        return []

    # 用 difflib 做相似度匹配
    lower_names = [name for name, _ in all_files]
    matches = difflib.get_close_matches(target_base, lower_names, n=max_results, cutoff=0.5)

    # 把命中的 lower name 映射回第一个匹配的完整路径
    result_paths: List[str] = []
    seen = set()
    for m in matches:
        for name, path in all_files:
            if name == m and path not in seen:
                result_paths.append(path)
                seen.add(path)
                break

    # 兜底: 如果相似度搜不到,尝试子串匹配
    if not result_paths:
        stem = os.path.splitext(target_base)[0]
        if len(stem) >= 3:
            for name, path in all_files:
                if stem in name:
                    result_paths.append(path)
                    if len(result_paths) >= max_results:
                        break

    return result_paths


# ══════════════════════════════════════════════════════════════════
# 新增工具: list_files (目录列出,支持 glob)
# ══════════════════════════════════════════════════════════════════

async def _tool_list_files(path: str, pattern: str = "",
                           max_entries: int = 200) -> Dict[str, Any]:
    """
    工具5: 目录列出
    - 路径安全检查(工作区限制)
    - 可选 glob pattern 过滤(如 *.swift)
    - 跳过 _SKIP_DIRS 里的噪音目录
    - 只列一层(不递归),避免爆炸
    - 最多返回 max_entries 项
    """
    expanded = _expand_path(path)
    safe, reason = _is_path_safe(expanded)
    if not safe:
        return {"ok": False, "output": f"⛔ {reason}"}

    if not os.path.exists(expanded):
        # 目录不存在时,提示相似目录
        candidates = _fuzzy_find_file(path, max_results=3)
        hint = ""
        if candidates:
            hint = "\n\n相似路径:\n" + "\n".join(f"  - {c}" for c in candidates)
        return {"ok": False, "output": f"❌ 路径不存在: {path}{hint}"}

    if not os.path.isdir(expanded):
        return {"ok": False, "output": f"❌ 不是目录(可能是文件): {path}"}

    try:
        entries = os.listdir(expanded)
    except PermissionError as e:
        return {"ok": False, "output": f"❌ 无权限访问: {path} ({e})"}

    # 分离目录和文件,分别排序
    dirs: List[str] = []
    files: List[str] = []
    for name in entries:
        # 跳过噪音目录
        if name in _SKIP_DIRS:
            continue
        full = os.path.join(expanded, name)
        if os.path.isdir(full):
            dirs.append(name)
        else:
            if pattern and not fnmatch.fnmatch(name, pattern):
                continue
            files.append(name)

    dirs.sort()
    files.sort()

    total = len(dirs) + len(files)
    truncated = False
    if total > max_entries:
        # 按比例截断
        files = files[:max(0, max_entries - len(dirs))]
        truncated = True

    lines = []
    header_parts = [f"📂 {expanded}"]
    if pattern:
        header_parts.append(f"(过滤: {pattern})")
    header_parts.append(f"[{len(dirs)} 目录, {len(files)} 文件]")
    if truncated:
        header_parts.append("⚠️ 已截断")
    lines.append(" ".join(header_parts))
    lines.append("")

    for d in dirs:
        lines.append(f"  📁 {d}/")
    for f in files:
        full = os.path.join(expanded, f)
        try:
            size = os.path.getsize(full)
            if size < 1024:
                size_str = f"{size}B"
            elif size < 1024 * 1024:
                size_str = f"{size/1024:.1f}K"
            else:
                size_str = f"{size/1024/1024:.1f}M"
            lines.append(f"  📄 {f}  ({size_str})")
        except OSError:
            lines.append(f"  📄 {f}")

    if truncated:
        lines.append(f"\n... [共 {total} 项, 已截断至 {max_entries}] ...")

    return {
        "ok": True,
        "output": "\n".join(lines),
        "path": expanded,
        "dir_count": len(dirs),
        "file_count": len(files),
    }


async def _tool_read_file(path: str, start_line: Optional[int] = None, end_line: Optional[int] = None) -> Dict[str, Any]:
    """
    工具2: 文件读取
    - 路径安全检查（工作区限制）
    - 支持行范围
    - 大文件自动截断（最多500行）
    - 文件不存在时自动 fuzzy 搜索候选(v2.1)
    """
    expanded = _expand_path(path)
    safe, reason = _is_path_safe(expanded)
    if not safe:
        return {"ok": False, "output": f"⛔ {reason}"}

    if not os.path.exists(expanded):
        # fuzzy 搜索相似文件名,帮阿杜自愈
        candidates = _fuzzy_find_file(path, max_results=5)
        if candidates:
            hint_lines = ["\n\n🔎 未找到该文件,但工作区里有相似的:"]
            for c in candidates:
                hint_lines.append(f"  - {c}")
            hint_lines.append("\n提示: 如需读其中一个,直接用上面的完整路径再调 read_file。")
            return {
                "ok": False,
                "output": f"❌ 文件不存在: {path}" + "\n".join(hint_lines),
                "candidates": candidates,
            }
        return {"ok": False, "output": f"❌ 文件不存在: {path}"}

    try:
        with open(expanded, 'r', encoding='utf-8', errors='replace') as f:
            lines = f.readlines()

        total = len(lines)
        file_name = os.path.basename(expanded)

        if start_line is not None and end_line is not None:
            # 行范围读取（1-based）
            sl = max(1, start_line) - 1
            el = min(total, end_line)
            content = ''.join(lines[sl:el])
            header = f"📄 {file_name} (第{start_line}-{end_line}行 / 共{total}行)\n\n"
        else:
            # 全文读取，超过500行截断
            MAX_LINES = 500
            if total > MAX_LINES:
                content = ''.join(lines[:MAX_LINES])
                header = f"📄 {file_name} (共{total}行，显示前{MAX_LINES}行)\n\n"
                content += f"\n\n... [文件过长，已截断。如需后续内容请用行范围读取: read_file|{path}|{MAX_LINES+1}|{min(total, MAX_LINES*2)}] ..."
            else:
                content = ''.join(lines)
                header = f"📄 {file_name} (共{total}行)\n\n"

        return {"ok": True, "output": header + content, "path": expanded, "total_lines": total}
    except Exception as e:
        return {"ok": False, "output": f"读取失败: {e}"}


async def _tool_write_file(path: str, content: str, confirm: bool = False) -> Dict[str, Any]:
    """
    工具3: 文件写入
    - 路径安全检查（严格工作区限制）
    - 自动备份（写入前 git commit）
    - 始终需要确认（高危操作）
    """
    expanded = _expand_path(path)
    safe, reason = _is_path_safe(expanded)
    if not safe:
        return {"ok": False, "output": f"⛔ {reason}"}

    if not confirm:
        file_exists = os.path.exists(expanded)
        action = "覆盖" if file_exists else "新建"
        return {
            "ok": False,
            "needs_confirm": True,
            "reason": f"⚠️ 即将{action}文件: {path} ({len(content)} 字符)。如确认，请回复【确认】后重试。",
            "output": "",
            "path": path,
        }

    try:
        # 自动创建目录
        os.makedirs(os.path.dirname(expanded), exist_ok=True)

        # 写入前 git 备份
        git_dir = next((r for r in SAFE_ROOTS if expanded.startswith(r) and os.path.exists(os.path.join(r, '.git'))), None)
        if git_dir:
            try:
                subprocess.run(
                    ['git', '-C', git_dir, 'add', '-A'],
                    capture_output=True, timeout=5
                )
                subprocess.run(
                    ['git', '-C', git_dir, 'commit', '-m', f'[ADU-BACKUP] before write {os.path.basename(expanded)}', '--allow-empty'],
                    capture_output=True, timeout=5
                )
            except Exception:
                pass

        with open(expanded, 'w', encoding='utf-8') as f:
            f.write(content)

        return {
            "ok": True,
            "output": f"✅ 已写入: {path} ({len(content)} 字符，{content.count(chr(10))+1} 行)",
            "path": expanded,
        }
    except Exception as e:
        return {"ok": False, "output": f"写入失败: {e}"}


async def _tool_search_code(keyword: str, search_path: str = "~/Desktop/GPTsora",
                             file_ext: str = "") -> Dict[str, Any]:
    """
    工具4: 代码搜索
    - grep -rn 带行号
    - 支持指定文件类型
    - 最多返回50条结果
    """
    expanded = _expand_path(search_path)
    safe, reason = _is_path_safe(expanded)
    if not safe:
        return {"ok": False, "output": f"⛔ {reason}"}

    if not keyword.strip():
        return {"ok": False, "output": "搜索关键词不能为空"}

    # 构建 grep 命令
    include = f'--include="*{file_ext}"' if file_ext else \
              '--include="*.swift" --include="*.py" --include="*.js" --include="*.ts" --include="*.json"'
    safe_kw = shlex.quote(keyword)
    cmd = (
        f'grep -rn {include} {safe_kw} "{expanded}" '
        f'--exclude-dir=".git" --exclude-dir="Pods" --exclude-dir="node_modules" '
        f'--exclude-dir=".venv" --exclude-dir="DerivedData" '
        f'2>/dev/null | head -50'
    )

    try:
        proc = await asyncio.create_subprocess_shell(
            cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=15)
        output = stdout.decode("utf-8", errors="replace") if stdout else ""

        if not output.strip():
            return {"ok": True, "output": f"🔍 未找到 '{keyword}' 的匹配结果（路径: {search_path}）"}

        lines = output.strip().split('\n')
        header = f"🔍 搜索 '{keyword}' 找到 {len(lines)} 处匹配:\n\n"
        return {"ok": True, "output": header + output}
    except asyncio.TimeoutError:
        return {"ok": False, "output": "搜索超时（15s）"}
    except Exception as e:
        return {"ok": False, "output": f"搜索失败: {e}"}


# ══════════════════════════════════════════════════════════════════
# 动作分发 (Action Router)
# ══════════════════════════════════════════════════════════════════

async def execute_actions(
    actions: List[Dict[str, Any]],
    bridge,
    confirm: bool = False,
) -> List[Dict[str, Any]]:
    """分发并执行动作列表"""
    results = []

    for action in actions:
        t = action['type']
        p = action['params']
        result: Dict[str, Any] = {'type': t, 'ok': False, 'output': ''}

        try:
            # ── exec: 终端命令 ──
            if t == 'exec' and len(p) >= 1:
                cmd = p[0]
                timeout = int(p[1]) if len(p) > 1 and p[1].isdigit() else 60
                result = await _tool_exec(cmd, confirm=confirm, timeout=timeout)
                result['type'] = 'exec'

            # ── read_file: 文件读取 ──
            elif t == 'read_file' and len(p) >= 1:
                start = int(p[1]) if len(p) > 1 and p[1].isdigit() else None
                end   = int(p[2]) if len(p) > 2 and p[2].isdigit() else None
                result = await _tool_read_file(p[0], start, end)
                result['type'] = 'read_file'

            # ── list_files: 目录列出 ──
            elif t == 'list_files' and len(p) >= 1:
                pattern = p[1] if len(p) > 1 else ""
                result = await _tool_list_files(p[0], pattern=pattern)
                result['type'] = 'list_files'

            # ── write_file: 文件写入 ──
            elif t == 'write_file' and len(p) >= 2:
                content = '|'.join(p[1:])  # 内容中可能包含 |
                result = await _tool_write_file(p[0], content, confirm=confirm)
                result['type'] = 'write_file'

            # ── search_code: 代码搜索 ──
            elif t == 'search_code' and len(p) >= 1:
                search_path = p[1] if len(p) > 1 else '~/Desktop/GPTsora'
                file_ext    = p[2] if len(p) > 2 else ''
                result = await _tool_search_code(p[0], search_path, file_ext)
                result['type'] = 'search_code'

            # ── agent_task: 复杂任务 → OpenClaw AI ──
            elif t == 'agent_task' and len(p) >= 1:
                task_desc = '|'.join(p)
                result = await _execute_agent_task(bridge, task_desc)

            # ── 旧协议兼容 ──
            elif t in ('git', 'build', 'msg_send', 'browser_open', 'device_control',
                       'schedule_create', 'msg_platforms', 'device_list', 'schedule_list',
                       'skill_list', 'skill_invoke', 'system_info'):
                task = _legacy_action_to_task(t, p)
                result = await _execute_agent_task(bridge, task)

            else:
                result = {'type': t, 'ok': False, 'output': f'未知动作类型: {t}'}

        except Exception as e:
            result = {'type': t, 'ok': False, 'output': f'执行异常: {e}'}
            logger.error("[Intent] Action %s failed: %s", t, e, exc_info=True)

        results.append(result)
        logger.info("[Intent] %s → %s%s", t,
                    'OK' if result.get('ok') else 'FAIL',
                    f" (blocked)" if result.get('blocked') else f" (needs_confirm)" if result.get('needs_confirm') else "")

    return results


# ══════════════════════════════════════════════════════════════════
# /agent/tools HTTP 端点（供 iOS 直接调用，不走 AI 回复解析）
# ══════════════════════════════════════════════════════════════════

async def handle_agent_tools_request(body: dict) -> dict:
    """
    POST /agent/tools
    Body: {
      "tool": "exec" | "read_file" | "write_file" | "search_code",
      "params": {...},    # 工具参数
      "confirm": false,   # 高危操作确认标志
    }
    Returns: { "ok": bool, "output": str, ... }
    """
    tool = (body.get("tool") or "").strip()
    params = body.get("params") or {}
    confirm = bool(body.get("confirm", False))

    if not tool:
        return {"ok": False, "output": "缺少 tool 参数"}

    if tool == "exec":
        cmd = params.get("command", "")
        timeout = int(params.get("timeout", 60))
        if not cmd:
            return {"ok": False, "output": "缺少 command 参数"}
        return await _tool_exec(cmd, confirm=confirm, timeout=timeout)

    elif tool == "read_file":
        path = params.get("path", "")
        start = params.get("start_line")
        end = params.get("end_line")
        if not path:
            return {"ok": False, "output": "缺少 path 参数"}
        return await _tool_read_file(path,
                                     int(start) if start else None,
                                     int(end) if end else None)

    elif tool == "list_files":
        path = params.get("path", "")
        pattern = params.get("pattern", "")
        if not path:
            return {"ok": False, "output": "缺少 path 参数"}
        return await _tool_list_files(path, pattern=pattern)

    elif tool == "write_file":
        path = params.get("path", "")
        content = params.get("content", "")
        if not path:
            return {"ok": False, "output": "缺少 path 参数"}
        return await _tool_write_file(path, content, confirm=confirm)

    elif tool == "search_code":
        keyword = params.get("keyword", "")
        search_path = params.get("path", "~/Desktop/GPTsora")
        file_ext = params.get("ext", "")
        if not keyword:
            return {"ok": False, "output": "缺少 keyword 参数"}
        return await _tool_search_code(keyword, search_path, file_ext)

    else:
        return {"ok": False, "output": f"未知工具: {tool}。支持: exec, read_file, write_file, search_code, list_files"}


# ══════════════════════════════════════════════════════════════════
# OpenClaw AI 任务（agent_task B 类）
# ══════════════════════════════════════════════════════════════════

async def _execute_agent_task(bridge, task_description: str) -> Dict[str, Any]:
    logger.info("[AgentTask] → %s", task_description[:100])

    try:
        safe_msg = shlex.quote(task_description)
        cmd = f'openclaw agent --agent main -m {safe_msg} --json --timeout 300'

        proc = await asyncio.create_subprocess_shell(
            cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=360)
        raw = stdout.decode('utf-8', errors='replace').strip()
        if not raw and stderr:
            raw = stderr.decode('utf-8', errors='replace').strip()

        try:
            data = json.loads(raw)
            payloads = data.get('result', {}).get('payloads', [])
            texts = [p.get('text', '') for p in payloads if p.get('text')]
            output = '\n\n'.join(texts) if texts else raw
            return {'type': 'agent_task', 'ok': data.get('status') == 'ok', 'output': output, 'task': task_description}
        except json.JSONDecodeError:
            return {'type': 'agent_task', 'ok': bool(raw), 'output': raw or '无输出', 'task': task_description}

    except asyncio.TimeoutError:
        return {'type': 'agent_task', 'ok': False,
                'output': '⏰ 任务超过6分钟，请到 OpenClaw 控制台查看进度。', 'task': task_description}
    except Exception as e:
        logger.error("[AgentTask] Failed: %s", e)
        # fallback: 直接本地执行
        simple = _task_to_simple_command(task_description)
        if simple:
            r = await _tool_exec(simple, timeout=120)
            if r.get('ok'):
                r['task'] = task_description
                return r
        return {'type': 'agent_task', 'ok': False, 'output': f'执行失败: {e}', 'task': task_description}


def _task_to_simple_command(task: str) -> Optional[str]:
    t = task.lower()
    if '系统' in t and ('健康' in t or '状态' in t):
        return 'uname -a && uptime && df -h / && vm_stat | head -5'
    if 'git' in t and 'status' in t:
        return 'cd ~/Desktop/GPTsora && git status'
    if 'git' in t and 'log' in t:
        return 'cd ~/Desktop/GPTsora && git log --oneline -10'
    if '磁盘' in t or 'disk' in t:
        return 'df -h ~'
    if '内存' in t or 'memory' in t:
        return 'vm_stat | head -8'
    return None


def _legacy_action_to_task(t: str, p: list) -> str:
    if t == 'git':
        return f"git {p[0] if p else 'status'}" + (f" commit: {p[2]}" if len(p) > 2 else "")
    elif t == 'build':
        return f"编译 {p[0] if p else '~/Desktop/GPTsora'} 并安装到手机"
    elif t == 'msg_send' and len(p) >= 3:
        return f"通过 {p[0]} 发消息给 {p[1]}: {p[2]}"
    elif t == 'browser_open' and p:
        return f"打开浏览器访问 {p[0]}"
    elif t == 'system_info':
        return "检查系统健康状态（磁盘/内存/CPU）"
    return t


# ══════════════════════════════════════════════════════════════════
# 结果格式化
# ══════════════════════════════════════════════════════════════════

def format_action_results(results: List[Dict[str, Any]]) -> str:
    if not results:
        return ''
    parts = ['\n\n---\n📡 **执行结果：**\n']
    for r in results:
        # 需要确认
        if r.get('needs_confirm'):
            parts.append(f'⚠️ **需要确认**\n> {r.get("reason", "请确认后重试")}')
            parts.append('')
            continue
        # 被拦截
        if r.get('blocked'):
            parts.append(f'⛔ **安全拦截**\n> {r.get("reason", "危险操作已被阻止")}')
            parts.append('')
            continue

        icon = '✅' if r.get('ok') else '❌'
        label = {
            'exec': '⌨️ 终端命令',
            'read_file': '📄 文件读取',
            'write_file': '✏️ 文件写入',
            'search_code': '🔍 代码搜索',
            'list_files': '📂 目录列出',
            'agent_task': '🦾 智能体任务',
        }.get(r.get('type', ''), r.get('type', '工具'))

        output = (r.get('output') or '').strip()
        parts.append(f'{icon} **{label}**')
        if output:
            if '\n' in output or len(output) > 100:
                # 超长输出截断
                if len(output) > 3000:
                    output = output[:3000] + f'\n... [输出过长，已截断 {len(output)} 字符]'
                parts.append(f'```\n{output}\n```')
            else:
                parts.append(f'> {output}')
        parts.append('')

    return '\n'.join(parts)


# ══════════════════════════════════════════════════════════════════
# 入口函数
# ══════════════════════════════════════════════════════════════════

def inject_agent_system_prompt(messages: list, bridge_connected: bool = False) -> list:
    if not bridge_connected:
        return messages
    new_messages = list(messages)
    for i, msg in enumerate(new_messages):
        if msg.get('role') in ('system', 'developer'):
            new_messages[i] = {**msg, 'content': msg['content'] + '\n\n' + AGENT_TOOLS_PROMPT}
            return new_messages
    new_messages.insert(0, {'role': 'system', 'content': '你是 ChatAGI-阿杜，一个全能 AI 助手。\n\n' + AGENT_TOOLS_PROMPT})
    return new_messages


async def process_agent_actions(
    ai_text: str, bridge, confirm: bool = False
) -> Tuple[str, str]:
    clean_text, actions = extract_actions(ai_text)
    if not actions:
        return ai_text, ''
    results = await execute_actions(actions, bridge, confirm=confirm)
    return clean_text, format_action_results(results)


def process_agent_actions_sync(
    ai_text: str, bridge, confirm: bool = False
) -> Tuple[str, str]:
    clean_text, actions = extract_actions(ai_text)
    if not actions:
        return ai_text, ''
    logger.info("[Intent] Found %d actions (sync)", len(actions))
    try:
        loop = asyncio.get_event_loop()
        if loop.is_running():
            future = asyncio.run_coroutine_threadsafe(
                execute_actions(actions, bridge, confirm=confirm), loop
            )
            results = future.result(timeout=360)
        else:
            results = loop.run_until_complete(execute_actions(actions, bridge, confirm=confirm))
    except RuntimeError:
        results = asyncio.run(execute_actions(actions, bridge, confirm=confirm))
    except Exception as e:
        logger.error("[Intent] sync failed: %s", e)
        return clean_text, f'\n\n> ⚠️ 执行失败: {e}'
    return clean_text, format_action_results(results)

