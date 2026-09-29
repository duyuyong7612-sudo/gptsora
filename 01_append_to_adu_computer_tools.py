# ════════════════════════════════════════════════════════════════════════
# ✅ macOS Accessibility (AX) 工具组 — v1
# ════════════════════════════════════════════════════════════════════════
#
# 灵感来源:macos-control-mcp (https://github.com/syedazharmbnr1/macos-control-mcp)
# 实现方式:全部基于系统自带的 osascript + AppleScript,无需 npm/pyobjc 依赖
#
# 复用现有机制:
# - tool_exec() 处理 subprocess + 超时 + 安全检测
# - dispatch_tool() 统一入口,/agent/tool 路由自动支持
# - TOOL_DEFINITIONS 一加,GPT/Claude/Realtime 立即可调
# - [ADU_ACTION:...] 标记 + agent_intent_router 自动支持
#
# 6 个工具:
# - mac_list_apps         : 列出所有运行中的 GUI app
# - mac_activate_app      : 激活 app(切到前台)
# - mac_get_ui_elements   : 读取 app 当前窗口的所有 UI 元素
# - mac_click_element     : 按名字点击 UI 元素(按钮/菜单等)
# - mac_type_text         : 在当前焦点处输入文字
# - mac_press_key         : 按键(enter/tab/cmd-w 等)
#
# 安全要求:
# - macOS 系统设置 → 隐私与安全 → 辅助功能,需要给 Terminal/Python 授权
# - 第一次运行时 macOS 会弹窗请求权限,允许后所有工具就能用
# ════════════════════════════════════════════════════════════════════════

# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-e43726b889529fad9a9feec0b929c434fb6994c379bafd560fbe23d3cb13b872"
# Source-SHA256: "bea419fcd37a1e04c904e54cda5a1d8fa58ad839096b24a096c90feb0e2a9f97"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
import json as _json_ax


def _escape_for_applescript(s: str) -> str:
    """
    把 Python 字符串转义成 AppleScript 字符串字面量内安全的形式。
    AppleScript 字符串用双引号包裹,内部要转义反斜杠和双引号。
    """
    if s is None:
        return ""
    return s.replace("\\", "\\\\").replace('"', '\\"')


async def _run_applescript(
    script: str,
    timeout: int = 15,
) -> Dict[str, Any]:
    """
    执行 AppleScript,返回标准化结果。
    所有 mac_* 工具的底层封装。
    """
    if not script.strip():
        return {"ok": False, "error": "AppleScript 为空"}

    # 用 -e 单行模式;脚本中 \n 在 osascript 看来是一条语句结尾
    # 多行脚本通过多个 -e 拼接更稳;这里用 process_with_input 模式兼容
    timeout = min(max(1, timeout), 60)

    try:
        proc = await asyncio.create_subprocess_exec(
            "osascript",
            "-",  # 从 stdin 读取脚本
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            stdout, stderr = await asyncio.wait_for(
                proc.communicate(input=script.encode("utf-8")),
                timeout=timeout,
            )
        except asyncio.TimeoutError:
            try:
                proc.kill()
            except Exception:
                pass
            return {"ok": False, "error": f"AppleScript 超时(>{timeout}s)"}

        out = (stdout or b"").decode("utf-8", errors="replace").strip()
        err = (stderr or b"").decode("utf-8", errors="replace").strip()

        if proc.returncode != 0:
            # 常见错误:无辅助功能权限 / app 未运行 / 元素不存在
            return {
                "ok": False,
                "error": err or f"osascript 返回 {proc.returncode}",
                "exit_code": proc.returncode,
            }

        return {"ok": True, "output": out, "exit_code": 0}
    except FileNotFoundError:
        return {"ok": False, "error": "osascript 未找到(非 macOS 系统)"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


# ── 工具实现 ────────────────────────────────────────────────────────────────

async def tool_mac_list_apps() -> Dict[str, Any]:
    """
    列出当前运行中的所有 GUI 应用(进程名)。
    返回:{ok, apps:[str,...], count}
    """
    script = '''
    tell application "System Events"
        set procList to name of every application process whose visible is true
        set AppleScript's text item delimiters to "\\n"
        return procList as text
    end tell
    '''
    res = await _run_applescript(script, timeout=10)
    if not res["ok"]:
        return res
    apps = [a.strip() for a in (res["output"] or "").split("\n") if a.strip()]
    return {"ok": True, "apps": apps, "count": len(apps)}


async def tool_mac_activate_app(app: str) -> Dict[str, Any]:
    """
    激活(切到前台)指定 app。
    app: 进程名(如 'Safari'、'WeChat'、'Finder')或 bundle id 也行。
    """
    if not app or not app.strip():
        return {"ok": False, "error": "app 名为空"}

    app_esc = _escape_for_applescript(app.strip())
    script = f'''
    tell application "System Events"
        try
            set targetProc to first application process whose name is "{app_esc}"
            set frontmost of targetProc to true
            return "activated"
        on error errMsg
            -- 进程不在,尝试用 application 启动
            try
                tell application "{app_esc}" to activate
                return "launched"
            on error
                error "无法激活或启动 app: " & errMsg
            end try
        end try
    end tell
    '''
    res = await _run_applescript(script, timeout=10)
    if not res["ok"]:
        return res
    return {"ok": True, "app": app, "action": res["output"]}


async def tool_mac_get_ui_elements(
    app: str,
    max_depth: int = 3,
    max_elements: int = 50,
) -> Dict[str, Any]:
    """
    读取指定 app 当前最前窗口的 UI 元素列表(按钮/输入框/菜单等)。
    用于让 AI 知道有哪些可点的东西。

    返回:{ok, elements:[{role, name, description}, ...], count}

    注意:递归过深会非常慢,默认 depth=3 / max_elements=50 已够大多数场景。
    """
    if not app or not app.strip():
        return {"ok": False, "error": "app 名为空"}

    app_esc = _escape_for_applescript(app.strip())
    max_depth = min(max(1, int(max_depth or 3)), 6)
    max_elements = min(max(5, int(max_elements or 50)), 200)

    # AppleScript 直接拿所有 UI element 信息,序列化为简易格式
    # 格式:role|name|description (一行一个元素)
    script = f'''
    on collectElements(elem, depthLeft, accList, maxN)
        if (count of accList) >= maxN then return accList
        try
            set elemRole to (role of elem) as text
        on error
            set elemRole to "unknown"
        end try
        try
            set elemName to (name of elem) as text
        on error
            set elemName to "(no name)"
        end try
        try
            set elemDesc to (description of elem) as text
        on error
            set elemDesc to ""
        end try
        set end of accList to (elemRole & "|" & elemName & "|" & elemDesc)
        if depthLeft > 0 then
            try
                set children to UI elements of elem
                repeat with child in children
                    if (count of accList) >= maxN then return accList
                    set accList to my collectElements(child, depthLeft - 1, accList, maxN)
                end repeat
            end try
        end if
        return accList
    end collectElements

    tell application "System Events"
        try
            set targetProc to first application process whose name is "{app_esc}"
        on error
            error "app 进程不存在: {app_esc}(请先用 mac_activate_app 激活)"
        end try
        try
            set targetWindow to first window of targetProc
        on error
            error "{app_esc} 没有可见窗口"
        end try
        set elemList to {{}}
        set elemList to my collectElements(targetWindow, {max_depth}, elemList, {max_elements})
        set AppleScript's text item delimiters to "\\n"
        return elemList as text
    end tell
    '''

    res = await _run_applescript(script, timeout=20)
    if not res["ok"]:
        return res

    elements = []
    for line in (res["output"] or "").split("\n"):
        line = line.strip()
        if not line or "|" not in line:
            continue
        parts = line.split("|", 2)
        elements.append({
            "role": parts[0] if len(parts) > 0 else "",
            "name": parts[1] if len(parts) > 1 else "",
            "description": parts[2] if len(parts) > 2 else "",
        })

    return {
        "ok": True,
        "app": app,
        "elements": elements,
        "count": len(elements),
        "max_depth": max_depth,
    }


async def tool_mac_click_element(
    app: str,
    element_name: str,
    role: Optional[str] = None,
) -> Dict[str, Any]:
    """
    在指定 app 中按名字点击一个 UI 元素。
    - app: app 名(如 'Safari')
    - element_name: 元素的 name(如 '发送'、'登录')
    - role: 可选,限定 role 类型(如 'button'、'menu item')

    工作原理:递归遍历 AX 树找到第一个 name 匹配的元素,执行 click。
    """
    if not app.strip() or not element_name.strip():
        return {"ok": False, "error": "app 和 element_name 不能为空"}

    app_esc = _escape_for_applescript(app.strip())
    name_esc = _escape_for_applescript(element_name.strip())
    role_filter = ""
    if role and role.strip():
        role_esc = _escape_for_applescript(role.strip())
        role_filter = f' and (elemRole is "{role_esc}")'

    script = f'''
    on findAndClick(elem, targetName, depthLeft)
        try
            set elemName to (name of elem) as text
        on error
            set elemName to ""
        end try
        try
            set elemRole to (role of elem) as text
        on error
            set elemRole to ""
        end try
        if (elemName is targetName){role_filter} then
            try
                click elem
                return true
            on error
                -- 有些元素需要用 perform 'AXPress'
                try
                    perform action "AXPress" of elem
                    return true
                end try
            end try
        end if
        if depthLeft > 0 then
            try
                set children to UI elements of elem
                repeat with child in children
                    if my findAndClick(child, targetName, depthLeft - 1) then return true
                end repeat
            end try
        end if
        return false
    end findAndClick

    tell application "System Events"
        try
            set targetProc to first application process whose name is "{app_esc}"
        on error
            error "app 进程不存在: {app_esc}"
        end try
        try
            set targetWindow to first window of targetProc
        on error
            error "{app_esc} 没有可见窗口"
        end try
        set found to my findAndClick(targetWindow, "{name_esc}", 6)
        if found then
            return "clicked"
        else
            error "未找到元素: {name_esc}"
        end if
    end tell
    '''

    res = await _run_applescript(script, timeout=15)
    if not res["ok"]:
        return res
    return {"ok": True, "app": app, "element": element_name, "result": res["output"]}


async def tool_mac_type_text(
    text: str,
    app: Optional[str] = None,
) -> Dict[str, Any]:
    """
    在当前焦点处(或指定 app)输入文字。
    - text: 要输入的文字
    - app: 可选,如果指定则先激活该 app

    用 keystroke 模拟真实键盘输入,中文/emoji 也支持。
    """
    if text is None:
        return {"ok": False, "error": "text 为 None"}

    text_esc = _escape_for_applescript(text)

    activate_block = ""
    if app and app.strip():
        app_esc = _escape_for_applescript(app.strip())
        activate_block = f'''
        try
            set targetProc to first application process whose name is "{app_esc}"
            set frontmost of targetProc to true
            delay 0.3
        on error
            error "无法激活 app: {app_esc}"
        end try
        '''

    script = f'''
    tell application "System Events"
        {activate_block}
        keystroke "{text_esc}"
        return "typed"
    end tell
    '''

    res = await _run_applescript(script, timeout=15)
    if not res["ok"]:
        return res
    return {"ok": True, "text_length": len(text), "result": res["output"]}


async def tool_mac_press_key(
    key: str,
    modifiers: Optional[List[str]] = None,
    app: Optional[str] = None,
) -> Dict[str, Any]:
    """
    按一个键(可选组合修饰键)。
    - key: 按键名(常见有 'return', 'tab', 'space', 'escape', 'delete',
            或单字符如 'a', 's';方向键 'left arrow' 'right arrow' 等)
    - modifiers: 修饰键列表,如 ['command'], ['command', 'shift']
                可选值:command / control / option / shift
    - app: 可选,先激活的 app

    例子:
    - mac_press_key('return')         → 按回车
    - mac_press_key('s', ['command']) → cmd+s 保存
    - mac_press_key('tab', ['command']) → cmd+tab 切换 app
    """
    if not key or not key.strip():
        return {"ok": False, "error": "key 为空"}

    key_str = key.strip()

    # 常见特殊键映射(用 key code 比 key 名更稳定)
    SPECIAL_KEYS = {
        "return": "return",
        "enter": "return",
        "tab": "tab",
        "space": "space",
        "escape": "escape",
        "esc": "escape",
        "delete": "delete",
        "backspace": "delete",
        "left": "left arrow",
        "right": "right arrow",
        "up": "up arrow",
        "down": "down arrow",
        "left arrow": "left arrow",
        "right arrow": "right arrow",
        "up arrow": "up arrow",
        "down arrow": "down arrow",
    }

    key_lower = key_str.lower()
    is_special = key_lower in SPECIAL_KEYS

    if is_special:
        key_action = f"key code {{}}"  # 占位,稍后用 special name
        special_name = SPECIAL_KEYS[key_lower]
        # 用 'key code' 太麻烦,改用 keystroke + special key
        if special_name == "return":
            press_line = 'keystroke return'
        elif special_name == "tab":
            press_line = 'keystroke tab'
        elif special_name == "space":
            press_line = 'keystroke space'
        elif special_name == "delete":
            press_line = 'key code 51'  # backspace
        elif special_name == "escape":
            press_line = 'key code 53'
        elif special_name == "left arrow":
            press_line = 'key code 123'
        elif special_name == "right arrow":
            press_line = 'key code 124'
        elif special_name == "down arrow":
            press_line = 'key code 125'
        elif special_name == "up arrow":
            press_line = 'key code 126'
        else:
            press_line = f'keystroke "{_escape_for_applescript(key_str)}"'
    else:
        press_line = f'keystroke "{_escape_for_applescript(key_str)}"'

    # 修饰键
    mod_clause = ""
    if modifiers:
        valid_mods = []
        for m in modifiers:
            ml = (m or "").strip().lower()
            if ml in ("command", "cmd"):
                valid_mods.append("command down")
            elif ml in ("control", "ctrl"):
                valid_mods.append("control down")
            elif ml in ("option", "opt", "alt"):
                valid_mods.append("option down")
            elif ml == "shift":
                valid_mods.append("shift down")
        if valid_mods:
            mod_clause = " using {" + ", ".join(valid_mods) + "}"

    activate_block = ""
    if app and app.strip():
        app_esc = _escape_for_applescript(app.strip())
        activate_block = f'''
        try
            set targetProc to first application process whose name is "{app_esc}"
            set frontmost of targetProc to true
            delay 0.3
        end try
        '''

    script = f'''
    tell application "System Events"
        {activate_block}
        {press_line}{mod_clause}
        return "pressed"
    end tell
    '''

    res = await _run_applescript(script, timeout=10)
    if not res["ok"]:
        return res
    return {
        "ok": True,
        "key": key_str,
        "modifiers": modifiers or [],
        "result": res["output"],
    }


# ── 注册到 TOOL_REGISTRY ───────────────────────────────────────────────────

TOOL_REGISTRY.update({
    "mac_list_apps":       tool_mac_list_apps,
    "mac_activate_app":    tool_mac_activate_app,
    "mac_get_ui_elements": tool_mac_get_ui_elements,
    "mac_click_element":   tool_mac_click_element,
    "mac_type_text":       tool_mac_type_text,
    "mac_press_key":       tool_mac_press_key,
})


# ── 注册到 TOOL_DEFINITIONS(供 LLM function-call 看见)─────────────────────

TOOL_DEFINITIONS.extend([
    {
        "type": "function",
        "function": {
            "name": "mac_list_apps",
            "description": "列出当前运行中的所有 macOS GUI 应用(进程名)。在操作 app 前调用看看有哪些可用。",
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "mac_activate_app",
            "description": "激活(切到前台)指定 macOS app。例如想点微信里的按钮前,先 activate WeChat。",
            "parameters": {
                "type": "object",
                "properties": {
                    "app": {"type": "string", "description": "app 进程名,如 'Safari'、'WeChat'、'Finder'、'Xcode'"},
                },
                "required": ["app"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "mac_get_ui_elements",
            "description": "读取一个 macOS app 当前最前窗口的所有 UI 元素(按钮、输入框、菜单等)。用于在点击/输入前看看有什么可操作的。",
            "parameters": {
                "type": "object",
                "properties": {
                    "app":          {"type": "string", "description": "app 进程名"},
                    "max_depth":    {"type": "integer", "description": "递归深度 1-6,默认 3", "default": 3},
                    "max_elements": {"type": "integer", "description": "最多返回元素数 5-200,默认 50", "default": 50},
                },
                "required": ["app"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "mac_click_element",
            "description": "在指定 macOS app 中按名字点击一个 UI 元素(按钮/菜单/链接等)。先用 mac_get_ui_elements 看有什么,再用这个点。",
            "parameters": {
                "type": "object",
                "properties": {
                    "app":          {"type": "string", "description": "app 进程名"},
                    "element_name": {"type": "string", "description": "要点击的元素 name,如 '发送'、'登录'、'OK'"},
                    "role":         {"type": "string", "description": "可选,限定元素 role 如 'button'、'menu item'"},
                },
                "required": ["app", "element_name"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "mac_type_text",
            "description": "在当前焦点处(或指定 app)输入一段文字(模拟键盘)。中文也支持。",
            "parameters": {
                "type": "object",
                "properties": {
                    "text": {"type": "string", "description": "要输入的文字"},
                    "app":  {"type": "string", "description": "可选,先激活的 app"},
                },
                "required": ["text"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "mac_press_key",
            "description": "按一个键(可选修饰键组合)。例如按回车、cmd+s 保存、cmd+tab 切换 app 等。",
            "parameters": {
                "type": "object",
                "properties": {
                    "key":       {"type": "string", "description": "按键名,如 'return'、'tab'、'escape'、'a'、'left arrow'"},
                    "modifiers": {"type": "array", "items": {"type": "string"}, "description": "修饰键列表,可选 'command'、'control'、'option'、'shift'"},
                    "app":       {"type": "string", "description": "可选,先激活的 app"},
                },
                "required": ["key"],
            },
        },
    },
])
