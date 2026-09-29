# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-d8a99ffcf04ef474f692e4e2c3576d5436783184ac19b93bca6120b2d0a49b30"
# Source-SHA256: "f685edad96326fa7f4db85453a93850251bf25fe4fbce37b0e5e8cd555cf9638"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
ChatAGI 阿杜 · Computer Work Mode · policy & helpers
=====================================================
把"电脑工作代理"能力沉淀成后端策略层，供 server_session.py 的
/api/brain/adu/act 调用。本模块只负责：

  - 系统提示词常量            ADU_COMPUTER_WORK_SYSTEM_PROMPT
  - 触发判定                  is_computer_work_request / parse_dry_run_click
  - 风险升级                  escalate_risk
  - 弹窗按钮分类              classify_popup_button
  - open_app 多方法回退+验证  resolve_and_open_app
  - 统一返回结构辅助          make_attempt / confirm_text_for

设计约束：
  - 纯 stdlib，无第三方依赖；
  - 导入失败不得拖垮后端启动（调用方必须 try/except）；
  - 不在此执行高风险动作；高风险只做"标记 + need_confirm"。
"""
from __future__ import annotations

import os
import re
import subprocess
import time
from typing import Any, Dict, List, Optional, Tuple


# ============================================================
# 1) 系统提示词：阿杜电脑工作代理的职责定义
# ============================================================
ADU_COMPUTER_WORK_SYSTEM_PROMPT = """你是 ChatAGI 阿杜的电脑工作代理（Computer Work Mode）。

【核心原则】
- 用户给你的是「目标」，不是单个命令。
- 你的职责是「完成用户目标」，而不是「尝试一个动作」。
- 必须按固定链路工作：
  Understand → Observe → Plan → Act → Verify → Retry → Complete
- 只有 Verify 通过后，才能说「已完成」（completed=true）。
- 任何一步失败，必须自动切换方法重试，不能一次失败就停止。
- 如果所有方法都失败，必须如实报告：尝试过哪些方法、各自为什么失败、
  还需要用户提供什么。绝不假装成功。

【七步链路】
1. Understand：理解用户真正的目标，而不是字面动作。
2. Observe：先观察电脑环境——screenshot / vision / active_window /
   mouse_position，必要时查进程、App 状态、文件状态。
3. Plan：生成可验证的小步骤，挑最稳的方法，预估风险，确定是否需用户确认。
4. Act：一次只执行一个小步骤，不要一口气执行一长串不可控动作。
5. Verify：每一步后都要验证——开 App 后看 active_window/进程；点击后看 UI
   是否变化；输入后看文本是否出现；改工程后跑 compile/test；处理弹窗后
   截图确认弹窗已消失。
6. Retry：失败时自动换方法。例如 open_app：
   open -a 英文名 → open -a 中文名 → /Applications → mdfind → osascript
   → Spotlight 兜底。修工程时不可无限 patch。
7. Complete：只有验证成功后才返回 completed=true。

【安全分级】
- risk_level=0（截图/视觉/前台窗口/鼠标位置/只读检查）：可自动执行。
- risk_level=1（移动/点击/输入/粘贴/Esc-Tab-方向-回车/开 App）：确认上下文
  安全后可执行。
- risk_level=2（Cmd+S/Q/W、删除/覆盖、sudo、git push、发布、提交、发送、
  付款、允许钥匙串、改真实项目核心文件）：必须 need_confirm=true，禁止自动执行。

【弹窗规则】
- 遇到弹窗先截图识别按钮。
- 可自动点：取消 / Cancel / OK / 好 / 关闭 / Close / 不保存 / Don't Save / 稍后。
- 必须先问用户：保存 / Save / 删除 / Delete / 覆盖 / Replace / 发送 / Send /
  付款 / Pay / 购买 / Buy / 允许 / Allow / 提交 / Submit / 发布 / Publish。
"""


# ============================================================
# 2) 进入 Computer Work Mode 的触发判定
# ============================================================
_CW_TRIGGER_KEYWORDS = [
    # 看屏幕 / 观察
    "看屏幕", "看一下屏幕", "看下屏幕", "看看屏幕", "截图", "截屏",
    "当前前台", "前台窗口", "前台应用", "当前窗口", "当前应用",
    "鼠标在哪", "鼠标位置", "鼠标现在",
    # 打开 App / 文件
    "打开微信", "打开电脑微信", "打开浏览器", "打开应用", "打开文件",
    "打开网页", "打开网站", "启动", "运行程序",
    # 鼠标键盘
    "点击", "点一下", "移动鼠标", "鼠标移到", "右键", "双击", "拖拽", "拖动",
    "输入", "打字", "键入", "粘贴", "按键", "热键", "快捷键",
    # 弹窗
    "关闭弹窗", "点确认", "点取消", "处理弹窗",
    # 工程
    "修复编译错误", "修编译", "跑测试", "改代码", "修工程", "修 bug", "修bug",
    "自动修", "编译错误",
    # 文件 / 通用
    "上传", "下载", "查文件", "操作电脑", "操作本地",
    "帮我在电脑上", "你来操作电脑", "你帮我操作", "在我电脑上",
]
_CW_TRIGGER_LOW = [
    "screenshot", "active window", "frontmost", "mouse position",
    "open app", "click", "double click", "right click", "drag",
    "paste", "hotkey", "press key",
]


def is_computer_work_request(text: str) -> bool:
    """文本是否表达「操控/观察电脑」意图。供调用方决定是否进入 computer_work。"""
    t = (text or "").strip()
    if not t:
        return False
    low = t.lower()
    if any(k in t for k in _CW_TRIGGER_KEYWORDS):
        return True
    if any(k in low for k in _CW_TRIGGER_LOW):
        return True
    if low.startswith("open ") or low.startswith("launch "):
        return True
    return False


_DRY_RUN_MARKERS = [
    "不要执行", "不执行", "不要点击", "不要真的", "别点", "别真的",
    "判断", "评估", "先别", "先不要", "只判断", "只评估", "能不能点", "可不可以点",
]


def parse_dry_run_click(text: str) -> Optional[Dict[str, Any]]:
    """识别「判断 X,Y 能不能点，不要执行」这类只评估不执行的点击请求。
    命中返回 {"action":"click","payload":{x,y,button},"dry_run":True}。"""
    t = (text or "").strip()
    if not t:
        return None
    low = t.lower()
    is_dry = any(m in t for m in _DRY_RUN_MARKERS) or "dry run" in low or "dry-run" in low
    if not is_dry:
        return None
    talks_click = any(k in t for k in ("点", "点击", "单击", "左键")) or "click" in low
    if not talks_click:
        return None
    payload: Dict[str, Any] = {"button": "left"}
    m = re.search(r"(\d{1,5})\s*[,，、\s]+\s*(\d{1,5})", t)
    if m:
        try:
            payload["x"], payload["y"] = int(m.group(1)), int(m.group(2))
        except ValueError:
            pass
    return {"action": "click", "payload": payload, "dry_run": True}


# ============================================================
# 3) 风险升级：risk_level=2 高风险动作
# ============================================================
# 文本里出现这些词 → 强制 risk_level=2 + need_confirm
RISK2_TEXT_KEYWORDS = [
    "sudo", "git push", "rm -rf", "格式化", "清空磁盘",
    "发布", "上架", "提交审核", "付款", "支付", "转账", "购买",
    "允许钥匙串", "钥匙串", "keychain",
]
# 这些热键组合 → risk_level=2
RISK2_HOTKEYS: List[set] = [
    {"cmd", "s"}, {"command", "s"},
    {"cmd", "q"}, {"command", "q"},
    {"cmd", "w"}, {"command", "w"},
    {"cmd", "delete"}, {"command", "delete"},
    {"cmd", "shift", "delete"}, {"command", "shift", "delete"},
]


def escalate_risk(action: str, payload: Dict[str, Any], text: str,
                  base_risk: int) -> Tuple[int, str]:
    """在基础 risk 上做升级判定。返回 (risk_level, reason)。
    risk 只升不降；reason 非空表示触发了 need_confirm。"""
    a = (action or "").strip().lower()
    payload = payload if isinstance(payload, dict) else {}
    risk = int(base_risk or 0)

    if a in ("press_keys", "press", "hotkey", "shortcut"):
        keys = payload.get("keys") or payload.get("key") or payload.get("combo") or []
        if isinstance(keys, str):
            keys = re.split(r"[+\s,，、]+", keys)
        keyset = {str(k).strip().lower() for k in keys if str(k).strip()}
        for combo in RISK2_HOTKEYS:
            if combo and combo.issubset(keyset):
                return (2, f"高风险热键 {'+'.join(sorted(combo))} 必须二次确认。")

    low = (text or "").lower()
    for kw in RISK2_TEXT_KEYWORDS:
        if kw in (text or "") or kw in low:
            return (max(risk, 2), f"涉及高风险操作「{kw}」，必须二次确认。")

    return (risk, "")


# ============================================================
# 4) 弹窗按钮分类
# ============================================================
# 注意：AUTO 先判，确保「不保存 / Don't Save」不会被「保存 / Save」误吞。
POPUP_AUTO_OK = [
    "不保存", "don't save", "dont save", "do not save",
    "取消", "cancel", "好的", "好", "ok", "关闭", "close",
    "稍后", "later", "知道了", "got it", "以后再说",
]
POPUP_ASK_USER = [
    "保存", "save", "删除", "delete", "覆盖", "replace", "overwrite",
    "发送", "send", "付款", "pay", "购买", "buy", "允许", "allow",
    "提交", "submit", "发布", "publish",
]


def classify_popup_button(label: str) -> str:
    """返回 'auto'（可自动点）| 'ask'（必须问用户）| 'unknown'。"""
    s = (label or "").strip().lower()
    if not s:
        return "unknown"
    for k in POPUP_AUTO_OK:
        if k in s:
            return "auto"
    for k in POPUP_ASK_USER:
        if k in s:
            return "ask"
    return "unknown"


# ============================================================
# 5) open_app：多方法回退 + 验证
# ============================================================
# (匹配关键词, 英文名, 中文名, 进程名候选)
APP_ALIASES: List[Tuple[List[str], str, str, List[str]]] = [
    (["微信", "wechat"], "WeChat", "微信", ["WeChat"]),
    (["chrome", "谷歌浏览器", "谷歌"], "Google Chrome", "Google Chrome", ["Google Chrome"]),
    (["safari", "苹果浏览器"], "Safari", "Safari", ["Safari"]),
    (["xcode"], "Xcode", "Xcode", ["Xcode"]),
    (["终端", "terminal", "命令行"], "Terminal", "终端", ["Terminal"]),
    (["备忘录", "notes"], "Notes", "备忘录", ["Notes"]),
    (["访达", "finder"], "Finder", "访达", ["Finder"]),
    (["系统设置", "系统偏好", "system settings"], "System Settings", "系统设置", ["System Settings"]),
    (["邮件", "mail"], "Mail", "邮件", ["Mail"]),
    (["日历", "calendar"], "Calendar", "日历", ["Calendar"]),
    (["音乐", "music"], "Music", "音乐", ["Music"]),
    (["照片", "photos"], "Photos", "照片", ["Photos"]),
    (["qq"], "QQ", "QQ", ["QQ"]),
    (["textedit", "文本编辑"], "TextEdit", "文本编辑", ["TextEdit"]),
]


def _candidates_for(query: str, display: str) -> Tuple[List[str], List[str]]:
    """返回 (open候选名列表, 进程名候选列表)。"""
    q = (query or "").strip()
    d = (display or "").strip()
    ql = q.lower()
    open_names: List[str] = []
    proc_names: List[str] = []
    for keys, en, zh, procs in APP_ALIASES:
        if q == en or q == zh or any(k in ql or k in q for k in keys):
            open_names = [en, zh]
            proc_names = list(procs)
            break
    for n in (q, d):
        if n and n not in open_names:
            open_names.append(n)
    if not proc_names and q:
        proc_names = [q]
    open_names = [n for i, n in enumerate(open_names) if n and n not in open_names[:i]]
    return open_names, proc_names


def _run(cmd: List[str], timeout: float = 8.0) -> Tuple[int, str, str]:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout or "").strip(), (p.stderr or "").strip()
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"
    except Exception as e:
        return 1, "", f"{type(e).__name__}: {e}"


def frontmost_app() -> Optional[str]:
    """当前前台 App 名（osascript）。"""
    rc, out, _ = _run([
        "osascript", "-e",
        'tell application "System Events" to get name of first process whose frontmost is true',
    ], timeout=5.0)
    return out.strip() if rc == 0 and out.strip() else None


def app_process_running(proc_names: List[str]) -> Optional[str]:
    """检查进程是否在跑；返回命中的进程名或 None。"""
    for name in proc_names:
        if not name:
            continue
        rc, out, _ = _run(["pgrep", "-x", name], timeout=4.0)
        if rc == 0 and out.strip():
            return name
    return None


def find_app_in_applications(name: str) -> Optional[str]:
    """在 /Applications、~/Applications、/System/Applications 找 <name>.app。"""
    for base in ("/Applications", os.path.expanduser("~/Applications"),
                 "/System/Applications"):
        cand = os.path.join(base, f"{name}.app")
        if os.path.isdir(cand):
            return cand
    return None


def mdfind_app(name: str) -> Optional[str]:
    """用 Spotlight 索引（mdfind）定位应用 bundle 路径。"""
    rc, out, _ = _run([
        "mdfind",
        f'kMDItemContentType == "com.apple.application-bundle" '
        f'&& kMDItemDisplayName == "{name}*"cd',
    ], timeout=6.0)
    if rc == 0 and out:
        for line in out.splitlines():
            line = line.strip()
            if line.endswith(".app"):
                return line
    return None


def make_attempt(step: int, method: str, ok: bool,
                 verified_by: str = "", reason: str = "") -> Dict[str, Any]:
    """统一 attempt 结构。"""
    return {
        "step": int(step),
        "method": str(method),
        "ok": bool(ok),
        "verified_by": verified_by or "",
        "reason": reason or "",
    }


def _verify_app(open_names: List[str], proc_names: List[str]) -> Tuple[bool, str, str]:
    """打开后验证。返回 (verified, verified_by, detail)。"""
    targets = {n.strip().lower() for n in open_names if n}
    deadline = time.time() + 3.0
    while time.time() < deadline:
        fm = frontmost_app()
        if fm and fm.strip().lower() in targets:
            return True, "active_window", f"前台已是 {fm}"
        time.sleep(0.4)
    hit = app_process_running(proc_names)
    if hit:
        fm = frontmost_app() or "?"
        return True, "process", f"进程 {hit} 在运行（当前前台 {fm}）"
    return False, "", "前台未切换且进程未检测到"


def resolve_and_open_app(query: str, display: str = "") -> Dict[str, Any]:
    """open_app 完整链路：多方法回退 + 每步验证。
    同步函数，调用方应用 asyncio.to_thread 包裹。
    返回 {ok, completed, opened_by, attempts, spotlight_needed, final_text}。
    """
    open_names, proc_names = _candidates_for(query, display)
    disp = (display or query or "").strip()
    attempts: List[Dict[str, Any]] = []
    state = {"step": 0}

    def _verify(method: str) -> Optional[Dict[str, Any]]:
        verified, vby, detail = _verify_app(open_names, proc_names)
        state["step"] += 1
        attempts.append(make_attempt(state["step"], f"verify after {method}",
                                     verified, vby, detail))
        if verified:
            return {
                "ok": True, "completed": True, "opened_by": method,
                "attempts": attempts, "spotlight_needed": False,
                "final_text": f"已打开{disp}并验证成功（{detail}）。",
            }
        return None

    def _launch(method: str, cmd: List[str]) -> Optional[Dict[str, Any]]:
        rc, _out, err = _run(cmd, timeout=8.0)
        state["step"] += 1
        ok = (rc == 0)
        attempts.append(make_attempt(state["step"], method, ok, "",
                                     "" if ok else (err or f"exit={rc}")))
        if not ok:
            return None
        time.sleep(0.6)
        return _verify(method)

    # 方法 1/2：open -a 英文名 / 中文名（含用户原词）
    for nm in open_names:
        done = _launch(f'open -a "{nm}"', ["open", "-a", nm])
        if done:
            return done

    # 方法 3：/Applications 等路径直开
    for nm in open_names:
        path = find_app_in_applications(nm)
        if path:
            done = _launch(f"open {path}", ["open", path])
            if done:
                return done

    # 方法 4：mdfind 定位 bundle
    for nm in open_names:
        path = mdfind_app(nm)
        if path:
            done = _launch(f"mdfind→open {path}", ["open", path])
            if done:
                return done

    # 方法 5：osascript activate
    for nm in open_names:
        done = _launch(f'osascript activate "{nm}"',
                       ["osascript", "-e", f'tell application "{nm}" to activate'])
        if done:
            return done

    # 子进程方法全部失败 → 交回调用方做 Spotlight 键盘兜底
    return {
        "ok": False, "completed": False, "opened_by": None,
        "attempts": attempts, "spotlight_needed": True,
        "final_text": (f"已尝试 open -a / 路径 / mdfind / osascript 共 "
                       f"{len(attempts)} 步，均未能确认打开{disp}。"),
    }


# ============================================================
# 6) 统一返回结构辅助
# ============================================================
def confirm_text_for(action: str, risk_level: int, reason: str = "") -> str:
    """生成给前端展示的确认文案。"""
    txt = f"动作「{action}」需要你确认（risk_level={risk_level}）。"
    if reason:
        txt += reason
    return txt + "回复确认后我才会执行。"


# ============================================================
# 7) 任务级分类：把一个完整目标归到某个 task executor
# ============================================================
def classify_task(goal: str) -> Optional[str]:
    """把完整目标归类到任务级执行器。返回：
    open_app | observe | mouse_position | dry_run_click | textedit_input | None。
    None = 不属于这 5 个固定任务，交回原单动作流程（含工程修复 / 普通聊天）。"""
    t = (goal or "").strip()
    if not t:
        return None
    low = t.lower()

    # 1) dry-run 点击判断 —— 最高优先，绝不能进入真实 click
    if parse_dry_run_click(t) is not None:
        return "dry_run_click"

    # 1.5) 高风险热键 / 退出·关闭类意图 → 不归任务执行器，交回原单动作流程，
    #      由 escalate_risk + safety 闸门做 need_confirm。
    #      （避免 "退出当前应用" 里的 "当前应用" 被下方 observe 关键词误吞）
    if ("按" in t and re.search(r"cmd|command|ctrl|control|⌘|⌃|⌥|⇧|option|shift", low)) \
            or re.search(r"(?:cmd|command|ctrl|control)\s*[+＋]", low) \
            or (any(k in t for k in ("退出", "关掉", "关闭")) and
                any(k in t for k in ("应用", "程序", "窗口", "app"))):
        return None

    # 2) TextEdit 输入任务（多步：打开 + 准备输入区 [+ 输入]）
    if ("textedit" in low or "文本编辑" in t) and any(
        k in t for k in ("打开", "启动", "输入", "准备", "文字", "文本")
    ) or low.startswith("open textedit"):
        return "textedit_input"

    # 3) 鼠标位置
    if (("鼠标" in t) and any(k in t for k in ("在哪", "位置", "现在", "哪里"))) \
            or "mouse position" in low:
        return "mouse_position"

    # 4) 打开 App（排除打开文件 / 网页）
    if (any(k in t for k in ("打开", "启动", "运行"))
            or low.startswith("open ") or low.startswith("launch ")) \
            and not any(k in t for k in ("文件", "网页", "网站", "链接", "url")):
        return "open_app"

    # 5) 看屏幕 / 观察
    if any(k in t for k in (
        "看屏幕", "看一下屏幕", "看下屏幕", "看看屏幕", "屏幕看看", "截图", "截屏",
        "当前前台", "前台是什么", "前台窗口", "前台应用", "当前窗口", "当前应用",
        "屏幕上有什么", "你看到什么", "你看见什么",
    )) or "screenshot" in low:
        return "observe"

    return None


def textedit_text_to_type(goal: str) -> Optional[str]:
    """从 TextEdit 任务目标里抽取要输入的文字；抽不到返回 None（只准备输入区、不输入）。"""
    t = (goal or "").strip()
    if not t:
        return None
    m = re.search(r'["“『「](.+?)["”』」]', t)
    if m and m.group(1).strip():
        return m.group(1).strip()
    m = re.search(r'(?:输入|打字|键入)(?:文字|文本|内容)?[:：]\s*(\S.+)$', t)
    if m and m.group(1).strip():
        return m.group(1).strip()
    if any(k in t for k in ("测试文字", "测试文本", "测试内容")):
        return "这是 ChatAGI 阿杜的安全输入测试。"
    return None
