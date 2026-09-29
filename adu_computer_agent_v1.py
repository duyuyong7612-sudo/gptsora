# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-be1e0a4faa4a4a75effe3d2d99657508bd9f8e91591bc8a51cdf95a8b8492873"
# Source-SHA256: "f6aec6a7230a3efe8048f78b4fe30a64db94d00dfd04f74e368bc09adf361351"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""ChatAGI 阿杜 · Computer Agent v1.

带确认的半自动电脑执行器。**不是**完整 autonomous loop。
所有路径都过 allow_paths,所有动作都过 ComputerRiskPolicy,文件操作默认 dry-run。

提供给 server_session.py 用的对外接口:
    HIGH_RISK_TEXT_KEYWORDS, HIGH_RISK_HOTKEYS    — 与 brain/computer/action 共用
    ComputerRiskPolicy                              — 统一风险判定(分级 + 原因)
    ALLOW_PATHS, PROTECTED_NAMES                   — 文件操作安全边界
    list_dir / file_op_preview / file_op_execute   — 文件操作三件套
    plan_steps_from_goal / AGENT_ALLOWED_ACTIONS   — agent v1 计划器
    TOOL_WHITELIST                                  — /api/adu/tools/call 白名单
"""
from __future__ import annotations

import re
import shutil
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


# ════════════════════════════════════════════════════════════════════
# 1) 高风险关键词 / 热键 —— 单一源,brain/computer/action + agent + 文件
#    操作 + tools/call 全部共用。
# ════════════════════════════════════════════════════════════════════

HIGH_RISK_TEXT_KEYWORDS: List[Tuple[str, str]] = [
    # ───── 消息 / 通讯(实际联系人副作用)─────
    (r"发\s*微信", "发微信需要二次确认"),
    (r"发\s*消息", "发消息需要二次确认"),
    (r"发送给", "发送给联系人需要二次确认"),
    (r"\bsend\s+(?:message|msg|sms)\b", "send message needs confirmation"),
    # ───── 金融 ─────
    (r"付款", "付款需要二次确认"),
    (r"支付", "支付需要二次确认"),
    (r"转账", "转账需要二次确认"),
    (r"结账", "结账需要二次确认"),
    (r"购买", "购买需要二次确认"),
    (r"下单", "下单需要二次确认"),
    (r"\bcheckout\b", "checkout needs confirmation"),
    (r"\bpay\s", "pay action needs confirmation"),
    (r"\btransfer\s+money\b", "transfer money needs confirmation"),
    # ───── 文件破坏 ─────
    (r"删除", "删除需要二次确认"),
    (r"\bdelete\b", "delete needs confirmation"),
    (r"\brm\s+-r[fF]?\s", "递归删除命令需要二次确认"),
    # ───── 系统权限 ─────
    (r"\bsudo\s", "sudo 命令需要二次确认"),
    (r"\bchmod\s+-R\s+777\b", "chmod -R 777 需要二次确认"),
    (r"\bchown\s+-R\b", "chown -R 需要二次确认"),
    # ───── 发布 / 推送 ─────
    (r"\bgit\s+push\b", "git push 需要二次确认"),
    (r"\bnpm\s+publish\b", "npm publish 需要二次确认"),
    (r"\bpypi\b.*\bupload\b", "pypi upload 需要二次确认"),
    (r"\bdeploy\b", "deploy 需要二次确认"),
    (r"发布", "发布需要二次确认"),
    (r"上架", "上架需要二次确认"),
    (r"提交审核", "提交审核需要二次确认"),
    # ───── 包安装(写盘 / 升级)─────
    (r"\bpip\s+install\b", "pip install 需要二次确认"),
    (r"\bbrew\s+install\b", "brew install 需要二次确认"),
    (r"\bnpm\s+i(?:nstall)?\s+-g\b", "npm install -g 需要二次确认"),
    # ───── 凭证 / 密钥 ─────
    (r"\.env\b.*(?:修改|覆盖|改写|删除|edit)", "改 .env 需要二次确认"),
    (r"(?:修改|覆盖|改写|删除|edit).*\.env\b", "改 .env 需要二次确认"),
    (r"\bapi[ _-]?key\b", "API Key 相关操作需要二次确认"),
    (r"\bpassword\b", "password 相关操作需要二次确认"),
    (r"\bpasswd\b", "passwd 相关操作需要二次确认"),
    (r"\bsecret\b", "secret 相关操作需要二次确认"),
    (r"\btoken\b", "token 相关操作需要二次确认"),
    (r"\bkeychain\b", "钥匙串需要二次确认"),
    (r"钥匙串", "钥匙串需要二次确认"),
    # ───── 保存(可能触发对话框 / 覆盖)─────
    (r"\bcmd\s*[+＋]\s*s\b", "Cmd+S 需要二次确认"),
    (r"\bcommand\s*[+＋]\s*s\b", "Command+S 需要二次确认"),
    (r"按\s*(?:cmd|command)\s*[+＋]?\s*s\b", "按 Cmd+S 需要二次确认"),
    (r"\bsave\s+file\b", "save file 需要二次确认"),
    # ───── 磁盘 ─────
    (r"\bdiskutil\s+erase\b", "磁盘擦除需要二次确认"),
    (r"\bmkfs(?:\.|\s)", "格式化文件系统需要二次确认"),
    (r"格式化磁盘|清空磁盘|擦除磁盘", "磁盘擦除需要二次确认"),
]

HIGH_RISK_HOTKEYS: List[set] = [
    {"cmd", "s"},     {"command", "s"},
    {"cmd", "q"},     {"command", "q"},
    {"cmd", "w"},     {"command", "w"},
    {"cmd", "delete"},{"command", "delete"},
    {"cmd", "shift", "delete"}, {"command", "shift", "delete"},
]


# ════════════════════════════════════════════════════════════════════
# 2) ComputerRiskPolicy —— 统一风险判定
# ════════════════════════════════════════════════════════════════════

class ComputerRiskPolicy:
    """所有 computer action / agent run / file op / tools call 都过这里。

    Levels:
        0 = safe        (无副作用 / 只读)
        1 = normal      (低风险 / 受 allow_paths 约束的写)
        2 = high        (副作用大 / 不可逆 / 影响联系人 / 涉及钱)
    """

    SAFE = 0
    NORMAL = 1
    HIGH = 2

    @classmethod
    def classify_text(cls, text: str) -> Optional[Tuple[int, str]]:
        """文本(goal / NL command / 工具参数 text)层风险。命中返回 (2, reason)。"""
        if not isinstance(text, str) or not text.strip():
            return None
        low = text.lower()
        for pat, reason in HIGH_RISK_TEXT_KEYWORDS:
            try:
                if re.search(pat, low) or re.search(pat, text):
                    return (cls.HIGH, reason)
            except re.error:
                continue
        return None

    @classmethod
    def classify_action(cls, action: str, payload: Optional[Dict[str, Any]]) -> Optional[Tuple[int, str]]:
        """动作 + payload 层风险(主要拦高风险热键)。"""
        a = (action or "").strip().lower()
        payload = payload if isinstance(payload, dict) else {}
        if a in ("press_keys", "press", "hotkey", "shortcut"):
            raw = payload.get("keys") or payload.get("key") or payload.get("combo") or []
            if isinstance(raw, str):
                raw = re.split(r"[+\s,，、]+", raw)
            keyset = {str(k).strip().lower() for k in raw if k}
            for combo in HIGH_RISK_HOTKEYS:
                if combo and combo.issubset(keyset):
                    return (cls.HIGH, f"高风险热键 {'+'.join(sorted(combo))}")
        return None

    @classmethod
    def classify(cls, *,
                 text: Optional[str] = None,
                 action: Optional[str] = None,
                 payload: Optional[Dict[str, Any]] = None) -> Optional[Tuple[int, str]]:
        """一站式分类。text 优先;再看 action+payload。"""
        if text:
            r = cls.classify_text(text)
            if r:
                return r
        if action:
            r = cls.classify_action(action, payload or {})
            if r:
                return r
        return None


# ════════════════════════════════════════════════════════════════════
# 3) 文件操作安全边界
# ════════════════════════════════════════════════════════════════════

_ALLOW_PATHS_RAW = [
    "~/Desktop/GPTsora",
    "~/Desktop/backend",
    "~/Desktop/little-beijing-edge-box",
    "~/Desktop/chatagi-sandboxes",
]
ALLOW_PATHS: List[Path] = [Path(p).expanduser().resolve() for p in _ALLOW_PATHS_RAW]

# 即使在 allow_paths 内,这些名字也禁止操作
PROTECTED_NAMES = {
    ".env", ".env.local", ".env.production",
    "id_rsa", "id_ed25519", "id_dsa",
    ".ssh", ".aws", ".gnupg", ".keychain",
    "secrets.json", "credentials.json",
}

# 即使在 allow_paths 内,这些子路径片段禁止操作
PROTECTED_PATH_SEGMENTS = (".git/config", ".git/hooks", ".git/refs",
                           "node_modules/")

# 这些根目录永远不能直接当源 / 目标(避免批量 / 错点)
HARD_FORBIDDEN_PATHS: List[Path] = [
    Path("/"),
    Path.home(),
    Path.home() / "Desktop",
    Path.home() / "Downloads",
    Path.home() / "Documents",
    Path.home() / "Library",
    Path("/Users"),
    Path("/Applications"),
    Path("/System"),
    Path("/private"),
    Path("/tmp"),
]


def _canonical(p: str) -> Path:
    return Path(str(p)).expanduser().resolve()


def _is_within(child: Path, parent: Path) -> bool:
    try:
        child.relative_to(parent)
        return True
    except ValueError:
        return False


def _inside_any_allow(p: Path) -> bool:
    for ap in ALLOW_PATHS:
        if p == ap or _is_within(p, ap):
            return True
    return False


def _is_protected(p: Path) -> bool:
    if p in HARD_FORBIDDEN_PATHS:
        return True
    if p.name in PROTECTED_NAMES:
        return True
    s = str(p)
    for seg in PROTECTED_PATH_SEGMENTS:
        if seg in s:
            return True
    # 不允许操作 allow_path 根本身(避免移动整个项目)
    for ap in ALLOW_PATHS:
        if p == ap:
            return True
    return False


def check_file_path_safe(p: str, role: str = "path") -> Tuple[bool, str]:
    if not isinstance(p, str) or not p.strip():
        return False, f"missing_{role}"
    try:
        canon = _canonical(p)
    except Exception as e:
        return False, f"invalid_{role}_path: {type(e).__name__}: {e}"
    if not _inside_any_allow(canon):
        return False, (f"{role}_outside_allow_paths: {canon} not under "
                       f"{[str(x) for x in ALLOW_PATHS]}")
    if _is_protected(canon):
        return False, f"{role}_is_protected: {canon}"
    return True, ""


def list_dir(root: str, max_entries: int = 500) -> Dict[str, Any]:
    """列出 allow_paths 内一个目录。"""
    ok, why = check_file_path_safe(root, "root")
    if not ok:
        return {"ok": False, "error": why}
    canon = _canonical(root)
    if not canon.exists():
        return {"ok": False, "error": f"not_found: {canon}"}
    if not canon.is_dir():
        return {"ok": False, "error": f"not_a_dir: {canon}"}

    entries: List[Dict[str, Any]] = []
    truncated = False
    try:
        for child in canon.iterdir():
            if len(entries) >= max_entries:
                truncated = True
                break
            try:
                st = child.stat()
            except OSError:
                continue
            entries.append({
                "name": child.name,
                "is_dir": child.is_dir(),
                "size": st.st_size,
                "mtime": st.st_mtime,
                "protected": _is_protected(child),
            })
    except PermissionError as e:
        return {"ok": False, "error": f"permission_denied: {e}"}

    return {
        "ok": True,
        "root": str(canon),
        "count": len(entries),
        "truncated": truncated,
        "entries": sorted(entries, key=lambda e: (not e["is_dir"], e["name"].lower())),
    }


def file_op_preview(op: str, source: str, target: Optional[str] = None) -> Dict[str, Any]:
    """rename / copy / move 的 dry-run 预览。绝不写盘。"""
    s_ok, s_why = check_file_path_safe(source, "source")
    if not s_ok:
        return {"ok": False, "needs_user_confirmation": True,
                "error": s_why, "preview": ""}
    s = _canonical(source)
    if not s.exists():
        return {"ok": False, "needs_user_confirmation": True,
                "error": f"source_not_found: {s}", "preview": ""}

    if op not in ("rename", "copy", "move"):
        return {"ok": False, "error": f"unsupported_op: {op}",
                "supported": ["rename", "copy", "move"]}

    t_ok, t_why = check_file_path_safe(target or "", "target")
    if not t_ok:
        return {"ok": False, "needs_user_confirmation": True,
                "error": t_why, "preview": ""}
    t = _canonical(target)

    if op == "rename" and t.parent != s.parent:
        return {"ok": False, "needs_user_confirmation": True,
                "error": "rename_must_be_same_dir",
                "preview": (f"rename 的 source/target 必须在同一目录。"
                            f"got source.parent={s.parent} vs target.parent={t.parent}。"
                            f"想要跨目录请用 move。")}

    if t.exists():
        return {"ok": False, "needs_user_confirmation": True,
                "error": "target_exists",
                "preview": f"target 已存在,拒绝覆盖:{t}"}

    if op == "rename":
        preview = f"Will rename {s.name} → {t.name} in {s.parent}"
    elif op == "copy":
        kind = "directory tree" if s.is_dir() else "file"
        preview = f"Will copy {kind} {s} → {t}"
    else:  # move
        preview = f"Will move {s} → {t}"

    return {
        "ok": False,                       # ok=false 表示"未执行";加 confirm=true 才执行
        "needs_user_confirmation": True,
        "op": op,
        "source": str(s),
        "target": str(t),
        "preview": preview,
        "hint": "再发一次同样请求并加 confirm=true 才会执行。",
    }


def file_op_execute(op: str, source: str, target: Optional[str] = None) -> Dict[str, Any]:
    """真执行 rename / copy / move(调用方已收过 confirm)。"""
    # Re-validate via preview path so we keep one source of truth
    pre = file_op_preview(op, source, target)
    if pre.get("error"):
        return pre  # safety fail — bail
    s = _canonical(source)
    t = _canonical(target)
    try:
        if op == "rename":
            s.rename(t)
        elif op == "copy":
            if s.is_dir():
                shutil.copytree(str(s), str(t))
            else:
                shutil.copy2(str(s), str(t))
        elif op == "move":
            shutil.move(str(s), str(t))
        else:
            return {"ok": False, "error": f"unsupported_op: {op}"}
    except Exception as e:
        return {"ok": False, "error": f"{op}_failed: {type(e).__name__}: {e}",
                "source": str(s), "target": str(t)}
    return {
        "ok": True,
        "executed": True,
        "op": op,
        "source": str(s),
        "target": str(t),
        "message": f"{op} done: {s} → {t}",
    }


# ════════════════════════════════════════════════════════════════════
# 4) Agent v1 —— 启发式 planner(无 LLM,可被 LLM 替换)
# ════════════════════════════════════════════════════════════════════

# 半自动执行器允许的动作白名单。任何不在白名单的动作 → 必须 needs_user_confirmation。
AGENT_ALLOWED_ACTIONS = {
    "screenshot",
    "open_app",
    "type_text", "type",
    "press_keys", "press",
    "click", "left_click", "right_click", "double_click",
    "move_mouse", "mouse_move", "move",
    "active_window",
}


_SPLIT_PAT = re.compile(r"[,，;；。]|然后|接着|再来|再去|再|之后|后(?=做|按|点|输|搜|打|开|启)")


def plan_steps_from_goal(goal: str, max_steps: int = 8) -> List[Dict[str, Any]]:
    """把 goal 按 ',' / '，' / '然后' / '接着' / '再' / '之后' 等切成短句,
    每句做一次最小动作解析。绝不 LLM。"""
    text = (goal or "").strip()
    if not text:
        return []
    parts = [p.strip() for p in _SPLIT_PAT.split(text) if p.strip()]
    steps: List[Dict[str, Any]] = []
    cap = max(1, min(int(max_steps or 8), 20))
    for i, part in enumerate(parts[:cap], start=1):
        # ① 文本层风险(发微信 / 付款 / 删除 / git push…)
        rc = ComputerRiskPolicy.classify_text(part)
        if rc:
            steps.append({
                "index": i, "raw": part,
                "action": None, "args": {},
                "ok": False,
                "needs_user_confirmation": True,
                "risk_level": rc[0],
                "reason": rc[1],
            })
            continue
        # ② 启发式 NL → action
        spec = _heuristic_part_to_action(part)
        if spec is None:
            steps.append({
                "index": i, "raw": part,
                "action": None, "args": {},
                "ok": False,
                "reason": "未识别此步骤,需要更明确的指令(例:'打开 Safari' / '输入 hello' / '按回车')",
            })
            continue
        # ③ 解析后再过动作层风险(高风险热键)
        ar = ComputerRiskPolicy.classify_action(spec["action"], spec.get("payload"))
        if ar:
            steps.append({
                "index": i, "raw": part,
                "action": spec["action"], "args": spec.get("payload") or {},
                "ok": False,
                "needs_user_confirmation": True,
                "risk_level": ar[0],
                "reason": ar[1],
            })
            continue
        # ④ 白名单
        a = (spec["action"] or "").lower()
        if a not in AGENT_ALLOWED_ACTIONS:
            steps.append({
                "index": i, "raw": part,
                "action": spec["action"], "args": spec.get("payload") or {},
                "ok": False,
                "needs_user_confirmation": True,
                "reason": f"动作 {spec['action']!r} 不在 agent 白名单",
            })
            continue
        steps.append({
            "index": i, "raw": part,
            "action": spec["action"],
            "args": spec.get("payload") or {},
            "ok": True,
        })
    return steps


def _heuristic_part_to_action(text: str) -> Optional[Dict[str, Any]]:
    """一句 → 一动作的最小启发式。是 server_session._computer_action_from_goal 的子集
    +一些常用搜索 / 输入别名,避免拉整套依赖。"""
    t = text.strip()
    if not t:
        return None
    low = t.lower()

    # screenshot
    if any(k in t for k in ("截图", "截屏", "看屏幕", "看一下屏幕", "看看屏幕")) or "screenshot" in low:
        return {"action": "screenshot", "payload": {}}

    # active window
    if any(k in t for k in ("前台应用", "当前应用", "当前窗口", "前台窗口")) \
            or "active window" in low or "frontmost" in low:
        return {"action": "active_window", "payload": {}}

    # open_app(放在 type/搜索 之前,避免 "打开 X 搜索 Y" 误判)
    if ("打开" in t or "启动" in t or "open " in low or "launch " in low) \
            and not any(k in t for k in ("文件", "网页", "网站", "链接")):
        rest = _extract_app_name(t)
        if rest:
            display = rest
            ql = rest.lower()
            if ql in ("微信", "wechat"):
                return {"action": "open_app", "payload": {"app": "WeChat", "display": "微信"}}
            if ql in ("safari", "苹果浏览器"):
                return {"action": "open_app", "payload": {"app": "Safari", "display": "Safari"}}
            if ql in ("chrome", "谷歌浏览器", "谷歌"):
                return {"action": "open_app", "payload": {"app": "Google Chrome", "display": "Chrome"}}
            return {"action": "open_app", "payload": {"app": rest, "display": display}}

    # type / 搜索 / paste
    m = re.search(r"(?:输入|打字|键入|搜索|search\s+for|search)\s*[:：]?\s*(.+)$", t, re.I)
    if m:
        val = m.group(1).strip().strip('"\'""')
        if val:
            return {"action": "type_text", "payload": {"text": val}}

    # 单键 press
    if "回车" in t or re.search(r"\benter\b", low):
        return {"action": "press_keys", "payload": {"keys": ["enter"]}}
    if "esc" in low or "escape" in low or "退出键" in t:
        return {"action": "press_keys", "payload": {"keys": ["escape"]}}
    if re.search(r"\btab\b", low) or "制表键" in t:
        return {"action": "press_keys", "payload": {"keys": ["tab"]}}
    if "空格" in t or re.search(r"\bspace\b", low):
        return {"action": "press_keys", "payload": {"keys": ["space"]}}

    # 组合键 "按 cmd+space" / "按 Command S"
    m = re.search(
        r"按\s*((?:cmd|ctrl|alt|shift|command|control|option|meta)"
        r"(?:\s*[+＋\s,，、]\s*[A-Za-z0-9一-龥]+){1,3})",
        t, re.I,
    )
    if m:
        raw = m.group(1)
        keys = [p.strip().lower() for p in re.split(r"[+＋\s,，、]+", raw) if p.strip()]
        if len(keys) >= 2:
            return {"action": "press_keys", "payload": {"keys": keys}}

    # click 变种(带 / 不带坐标)
    xy = re.search(r"(\d{1,5})\s*[,，、]\s*(\d{1,5})", t)
    if "双击" in t or "double click" in low:
        pl: Dict[str, Any] = {"button": "left"}
        if xy:
            try: pl["x"], pl["y"] = int(xy.group(1)), int(xy.group(2))
            except ValueError: pass
        return {"action": "double_click", "payload": pl}
    if any(k in t for k in ("右键", "右击", "点右键")):
        pl = {"button": "right"}
        if xy:
            try: pl["x"], pl["y"] = int(xy.group(1)), int(xy.group(2))
            except ValueError: pass
        return {"action": "click", "payload": pl}
    if any(k in t for k in ("点击", "点一下", "左键", "单击")) or "click" in low:
        pl = {"button": "left"}
        if xy:
            try: pl["x"], pl["y"] = int(xy.group(1)), int(xy.group(2))
            except ValueError: pass
        return {"action": "click", "payload": pl}

    # 鼠标移动 (X, Y)
    m = re.search(
        r"(?:鼠标)?\s*(?:移动到|移到|移动至)\s*[(\[（【]?\s*(\d+)\s*[,，、\s]+\s*(\d+)\s*[)\]）】]?",
        t,
    )
    if m:
        try:
            return {"action": "mouse_move",
                    "payload": {"x": int(m.group(1)), "y": int(m.group(2))}}
        except ValueError:
            pass

    return None


def _extract_app_name(t: str) -> Optional[str]:
    for marker in ("帮我打开", "给我打开", "打开", "启动", "open ", "launch "):
        idx_t = t.find(marker)
        idx_l = t.lower().find(marker.lower())
        idx = idx_t if idx_t >= 0 else idx_l
        if idx >= 0:
            rest = t[idx + len(marker):].strip().strip(":：,，。.!！?？")
            # 去掉尾部修饰: "打开 Safari 浏览器" → "Safari"
            rest = re.sub(r"\s*(?:浏览器|App|应用|程序)$", "", rest).strip()
            if rest:
                return rest
    return None


# ════════════════════════════════════════════════════════════════════
# 5) 工具白名单 —— /api/adu/tools/call 只允许这些
# ════════════════════════════════════════════════════════════════════

TOOL_WHITELIST: List[str] = [
    # 只读 / 观察
    "computer.health",
    "computer.config",
    "computer.screenshot",
    "computer.mouse_position",
    "computer.active_window",
    # 输入类 (低风险)
    "computer.mouse_move",
    "computer.click",
    "computer.right_click",
    "computer.double_click",
    "computer.type_text",
    "computer.paste_text",
    "computer.press_keys",
    "computer.open_app",
    # 综合 / NL
    "computer.action",
    # 文件 v1 (allow_paths 内,有预览)
    "computer.file_list",
    "computer.file_copy",
    "computer.file_move",
    "computer.file_rename",
    # 高级
    "computer.agent_plan",
    "computer.agent_run",
    "computer.vision_click",
]
