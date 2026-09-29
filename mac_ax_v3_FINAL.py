# ════════════════════════════════════════════════════════════════════════
# macOS Accessibility (AX) Tools v3 — FINAL
# 用 `entire contents` 一次拿到所有后代,无需递归,完全避开保留字
# ════════════════════════════════════════════════════════════════════════


# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-1dce263d89e2062cf6ea9041a8797eff8f3bce2af91b6b771ff1a3512da5955b"
# Source-SHA256: "7d45de0869f27dedcbed0bfa082aef41d794a595db3a3dfc3702af1248dc71b5"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
def _esc_for_as(s):
    """Escape string for AppleScript double-quoted literal."""
    if s is None:
        return ""
    return s.replace("\\", "\\\\").replace('"', '\\"')


async def _run_osascript(script: str, timeout: int = 15) -> Dict[str, Any]:
    """Run AppleScript via osascript stdin."""
    if not script.strip():
        return {"ok": False, "error": "empty script"}

    timeout = min(max(1, int(timeout)), 60)

    try:
        proc = await asyncio.create_subprocess_exec(
            "osascript", "-",
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
            return {"ok": False, "error": "osascript timeout"}

        out = (stdout or b"").decode("utf-8", errors="replace").strip()
        err = (stderr or b"").decode("utf-8", errors="replace").strip()

        if proc.returncode != 0:
            return {
                "ok": False,
                "error": err or "osascript error",
                "exit_code": proc.returncode,
            }
        return {"ok": True, "output": out, "exit_code": 0}
    except FileNotFoundError:
        return {"ok": False, "error": "osascript not found"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


# ── Tool 1: list_apps ────────────────────────────────────────────────────

async def tool_mac_list_apps() -> Dict[str, Any]:
    """List currently running visible GUI apps."""
    parts = [
        'tell application "System Events"',
        '    set procList to name of every application process whose visible is true',
        "    set AppleScript's text item delimiters to linefeed",
        '    return procList as text',
        'end tell',
    ]
    script = "\n".join(parts) + "\n"
    res = await _run_osascript(script, timeout=10)
    if not res["ok"]:
        return res
    apps = [a.strip() for a in (res["output"] or "").split("\n") if a.strip()]
    return {"ok": True, "apps": apps, "count": len(apps)}


# ── Tool 2: activate_app ────────────────────────────────────────────────

async def tool_mac_activate_app(app: str) -> Dict[str, Any]:
    """Bring an app to foreground. Falls back to launching."""
    if not app or not app.strip():
        return {"ok": False, "error": "app name is empty"}

    app_name = _esc_for_as(app.strip())
    parts = [
        'tell application "System Events"',
        '    try',
        '        set targetProc to first application process whose name is "' + app_name + '"',
        '        set frontmost of targetProc to true',
        '        return "activated"',
        '    on error',
        '        try',
        '            tell application "' + app_name + '" to activate',
        '            return "launched"',
        '        end try',
        '    end try',
        'end tell',
    ]
    script = "\n".join(parts) + "\n"
    res = await _run_osascript(script, timeout=10)
    if not res["ok"]:
        return res
    return {"ok": True, "app": app, "action": res["output"] or "ok"}


# ── Tool 3: get_ui_elements (用 entire contents,无递归) ────────────────

async def tool_mac_get_ui_elements(
    app: str,
    max_depth: int = 3,
    max_elements: int = 50,
) -> Dict[str, Any]:
    """Walk all descendants of the app's frontmost window using entire contents."""
    if not app or not app.strip():
        return {"ok": False, "error": "app name is empty"}

    app_name = _esc_for_as(app.strip())
    mn = min(max(5, int(max_elements or 50)), 500)

    parts = [
        'tell application "System Events"',
        '    set targetProc to first application process whose name is "' + app_name + '"',
        '    set targetWindow to first window of targetProc',
        '    set allElems to entire contents of targetWindow',
        '    set theList to {}',
        '    set maxN to ' + str(mn),
        '    repeat with anItem in allElems',
        '        if (count of theList) is greater than or equal to maxN then exit repeat',
        '        set rRole to ""',
        '        set rName to ""',
        '        try',
        '            set rRole to (role of anItem) as text',
        '        end try',
        '        try',
        '            set rName to (name of anItem) as text',
        '        end try',
        '        set end of theList to (rRole & "|" & rName)',
        '    end repeat',
        "    set AppleScript's text item delimiters to linefeed",
        '    return theList as text',
        'end tell',
    ]
    script = "\n".join(parts) + "\n"

    res = await _run_osascript(script, timeout=20)
    if not res["ok"]:
        return res

    elements = []
    for line in (res["output"] or "").split("\n"):
        line = line.strip()
        if not line or "|" not in line:
            continue
        bits = line.split("|", 1)
        elements.append({
            "role": bits[0] if len(bits) > 0 else "",
            "name": bits[1] if len(bits) > 1 else "",
        })

    return {
        "ok": True,
        "app": app,
        "elements": elements,
        "count": len(elements),
    }


# ── Tool 4: click_element (用 entire contents,无递归) ──────────────────

async def tool_mac_click_element(
    app: str,
    element_name: str,
    role: Optional[str] = None,
) -> Dict[str, Any]:
    """Click an element by name (and optional role) inside the app's frontmost window."""
    if not app or not app.strip() or not element_name or not element_name.strip():
        return {"ok": False, "error": "app and element_name required"}

    app_name = _esc_for_as(app.strip())
    target_name = _esc_for_as(element_name.strip())
    role_check = ""
    if role and role.strip():
        role_esc = _esc_for_as(role.strip())
        role_check = ' and (rRole is "' + role_esc + '")'

    parts = [
        'tell application "System Events"',
        '    set targetProc to first application process whose name is "' + app_name + '"',
        '    set targetWindow to first window of targetProc',
        '    set allElems to entire contents of targetWindow',
        '    set foundFlag to false',
        '    repeat with anItem in allElems',
        '        set rName to ""',
        '        set rRole to ""',
        '        try',
        '            set rName to (name of anItem) as text',
        '        end try',
        '        try',
        '            set rRole to (role of anItem) as text',
        '        end try',
        '        if (rName is "' + target_name + '")' + role_check + ' then',
        '            try',
        '                click anItem',
        '                set foundFlag to true',
        '                exit repeat',
        '            on error',
        '                try',
        '                    perform action "AXPress" of anItem',
        '                    set foundFlag to true',
        '                    exit repeat',
        '                end try',
        '            end try',
        '        end if',
        '    end repeat',
        '    if foundFlag then',
        '        return "clicked"',
        '    else',
        '        return "not_found"',
        '    end if',
        'end tell',
    ]
    script = "\n".join(parts) + "\n"

    res = await _run_osascript(script, timeout=15)
    if not res["ok"]:
        return res

    output = (res["output"] or "").strip()
    if output == "clicked":
        return {"ok": True, "app": app, "element": element_name, "result": "clicked"}
    return {"ok": False, "app": app, "element": element_name, "error": "element_not_found"}


# ── Tool 5: type_text ───────────────────────────────────────────────────

async def tool_mac_type_text(text: str, app: Optional[str] = None) -> Dict[str, Any]:
    """Type text at current focus (or after activating the given app)."""
    if text is None:
        return {"ok": False, "error": "text is None"}

    text_esc = _esc_for_as(text)

    activate_lines = []
    if app and app.strip():
        app_name = _esc_for_as(app.strip())
        activate_lines = [
            '    try',
            '        set targetProc to first application process whose name is "' + app_name + '"',
            '        set frontmost of targetProc to true',
            '        delay 0.3',
            '    end try',
        ]

    parts = (
        ['tell application "System Events"']
        + activate_lines
        + [
            '    keystroke "' + text_esc + '"',
            '    return "typed"',
            'end tell',
        ]
    )
    script = "\n".join(parts) + "\n"

    res = await _run_osascript(script, timeout=15)
    if not res["ok"]:
        return res
    return {"ok": True, "text_length": len(text), "result": res["output"] or "ok"}


# ── Tool 6: press_key ───────────────────────────────────────────────────

async def tool_mac_press_key(
    key: str,
    modifiers: Optional[List[str]] = None,
    app: Optional[str] = None,
) -> Dict[str, Any]:
    """Press a key (with optional modifiers)."""
    if not key or not key.strip():
        return {"ok": False, "error": "key is empty"}

    key_str = key.strip().lower()

    KEY_CODES = {
        "return": 36, "enter": 36,
        "tab": 48,
        "space": 49,
        "delete": 51, "backspace": 51,
        "escape": 53, "esc": 53,
        "left arrow": 123, "left": 123,
        "right arrow": 124, "right": 124,
        "down arrow": 125, "down": 125,
        "up arrow": 126, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118,
        "f5": 96, "f6": 97, "f7": 98, "f8": 100,
    }

    if key_str in KEY_CODES:
        press_line = "key code " + str(KEY_CODES[key_str])
    else:
        key_esc = _esc_for_as(key.strip())
        press_line = 'keystroke "' + key_esc + '"'

    mod_clause = ""
    if modifiers:
        valid = []
        for m in modifiers:
            ml = (m or "").strip().lower()
            if ml in ("command", "cmd"):
                valid.append("command down")
            elif ml in ("control", "ctrl"):
                valid.append("control down")
            elif ml in ("option", "opt", "alt"):
                valid.append("option down")
            elif ml == "shift":
                valid.append("shift down")
        if valid:
            mod_clause = " using {" + ", ".join(valid) + "}"

    activate_lines = []
    if app and app.strip():
        app_name = _esc_for_as(app.strip())
        activate_lines = [
            '    try',
            '        set targetProc to first application process whose name is "' + app_name + '"',
            '        set frontmost of targetProc to true',
            '        delay 0.3',
            '    end try',
        ]

    parts = (
        ['tell application "System Events"']
        + activate_lines
        + [
            '    ' + press_line + mod_clause,
            '    return "pressed"',
            'end tell',
        ]
    )
    script = "\n".join(parts) + "\n"

    res = await _run_osascript(script, timeout=10)
    if not res["ok"]:
        return res
    return {
        "ok": True,
        "key": key_str,
        "modifiers": modifiers or [],
        "result": res["output"] or "ok",
    }


# ── Register tools ──────────────────────────────────────────────────────

TOOL_REGISTRY.update({
    "mac_list_apps":       tool_mac_list_apps,
    "mac_activate_app":    tool_mac_activate_app,
    "mac_get_ui_elements": tool_mac_get_ui_elements,
    "mac_click_element":   tool_mac_click_element,
    "mac_type_text":       tool_mac_type_text,
    "mac_press_key":       tool_mac_press_key,
})


# ── LLM tool definitions ────────────────────────────────────────────────

TOOL_DEFINITIONS.extend([
    {
        "type": "function",
        "function": {
            "name": "mac_list_apps",
            "description": "List currently running visible macOS GUI apps.",
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "mac_activate_app",
            "description": "Bring a macOS app to foreground.",
            "parameters": {
                "type": "object",
                "properties": {
                    "app": {"type": "string", "description": "App process name (e.g. Safari, WeChat, Finder)"},
                },
                "required": ["app"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "mac_get_ui_elements",
            "description": "Get all UI elements (buttons, fields, menus) of a macOS app's frontmost window.",
            "parameters": {
                "type": "object",
                "properties": {
                    "app":          {"type": "string"},
                    "max_elements": {"type": "integer", "default": 50},
                },
                "required": ["app"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "mac_click_element",
            "description": "Click a UI element by name in a macOS app.",
            "parameters": {
                "type": "object",
                "properties": {
                    "app":          {"type": "string"},
                    "element_name": {"type": "string"},
                    "role":         {"type": "string", "description": "Optional role filter (e.g. AXButton)"},
                },
                "required": ["app", "element_name"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "mac_type_text",
            "description": "Type text (Unicode supported, e.g. Chinese).",
            "parameters": {
                "type": "object",
                "properties": {
                    "text": {"type": "string"},
                    "app":  {"type": "string", "description": "Optional app to activate"},
                },
                "required": ["text"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "mac_press_key",
            "description": "Press a key with optional modifiers (return, tab, escape, cmd+s, etc).",
            "parameters": {
                "type": "object",
                "properties": {
                    "key":       {"type": "string"},
                    "modifiers": {"type": "array", "items": {"type": "string"}},
                    "app":       {"type": "string"},
                },
                "required": ["key"],
            },
        },
    },
])
