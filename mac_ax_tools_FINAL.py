# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-024776cfd46aec521df8fe176172a4103432cee31df3dccf6ddd520f207760f5"
# Source-SHA256: "5d6652dba4e7217099b9eb873d6c98cae5282ad1d830c6e1061c26bf16273a79"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
mac_ax_tools_FINAL.py
======================
Patch to add macOS Accessibility tools to adu_computer_tools.py.

Design principles for stability:
- All AppleScript content uses pure English (no Chinese / Unicode pitfalls)
- All AppleScript built using string concatenation, NEVER Python f-strings
  inside multi-line scripts (avoids brace/quote escaping nightmares)
- All variable names are English and avoid AppleScript reserved words:
    children → kids
    description → (skipped, use AXHelp via attribute lookup if needed)
    item → entry
    document → doc
- Function names prefixed with `aduWalk` / `aduFind` to avoid command collisions
- Each script tested mentally (and via dry-run) before being committed

Usage:
    cd ~/Desktop/backend
    cat mac_ax_tools_FINAL.py >> adu_computer_tools.py
    pkill -9 -f server_session.py
    python3 server_session.py
"""

# ════════════════════════════════════════════════════════════════════════
# macOS Accessibility (AX) Tools v2 — STABLE
# ════════════════════════════════════════════════════════════════════════


def _esc_for_as(s: str) -> str:
    """Escape a string to be safely embedded inside an AppleScript double-quoted string."""
    if s is None:
        return ""
    return s.replace("\\", "\\\\").replace('"', '\\"')


async def _run_osascript(script: str, timeout: int = 15) -> Dict[str, Any]:
    """Run an AppleScript via osascript stdin. Returns {ok, output, error}."""
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
            return {"ok": False, "error": "osascript timeout (>" + str(timeout) + "s)"}

        out = (stdout or b"").decode("utf-8", errors="replace").strip()
        err = (stderr or b"").decode("utf-8", errors="replace").strip()

        if proc.returncode != 0:
            return {
                "ok": False,
                "error": err or ("osascript exit " + str(proc.returncode)),
                "exit_code": proc.returncode,
            }

        return {"ok": True, "output": out, "exit_code": 0}
    except FileNotFoundError:
        return {"ok": False, "error": "osascript not found (not on macOS?)"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


# ── Tool 1: list_apps ────────────────────────────────────────────────────

async def tool_mac_list_apps() -> Dict[str, Any]:
    """List currently running visible GUI apps."""
    script = (
        'tell application "System Events"\n'
        '    set procList to name of every application process whose visible is true\n'
        '    set AppleScript\'s text item delimiters to linefeed\n'
        '    return procList as text\n'
        'end tell\n'
    )
    res = await _run_osascript(script, timeout=10)
    if not res["ok"]:
        return res
    apps = [a.strip() for a in (res["output"] or "").split("\n") if a.strip()]
    return {"ok": True, "apps": apps, "count": len(apps)}


# ── Tool 2: activate_app ────────────────────────────────────────────────

async def tool_mac_activate_app(app: str) -> Dict[str, Any]:
    """Bring an app to the foreground. Falls back to launching if not running."""
    if not app or not app.strip():
        return {"ok": False, "error": "app name is empty"}

    app_name = _esc_for_as(app.strip())

    script = (
        'tell application "System Events"\n'
        '    try\n'
        '        set targetProc to first application process whose name is "' + app_name + '"\n'
        '        set frontmost of targetProc to true\n'
        '        return "activated"\n'
        '    on error\n'
        '        try\n'
        '            tell application "' + app_name + '" to activate\n'
        '            return "launched"\n'
        '        end try\n'
        '    end try\n'
        'end tell\n'
    )

    res = await _run_osascript(script, timeout=10)
    if not res["ok"]:
        return res
    return {"ok": True, "app": app, "action": res["output"] or "ok"}


# ── Tool 3: get_ui_elements ─────────────────────────────────────────────

async def tool_mac_get_ui_elements(
    app: str,
    max_depth: int = 3,
    max_elements: int = 50,
) -> Dict[str, Any]:
    """Walk the AX tree of the app's frontmost window and return UI elements."""
    if not app or not app.strip():
        return {"ok": False, "error": "app name is empty"}

    app_name = _esc_for_as(app.strip())
    md = min(max(1, int(max_depth or 3)), 6)
    mn = min(max(5, int(max_elements or 50)), 200)

    script = (
        'on aduWalk(elem, depthLeft, theList, maxN)\n'
        '    if (count of theList) >= maxN then return theList\n'
        '    set rRole to ""\n'
        '    set rName to ""\n'
        '    try\n'
        '        set rRole to (role of elem) as text\n'
        '    end try\n'
        '    try\n'
        '        set rName to (name of elem) as text\n'
        '    end try\n'
        '    set end of theList to (rRole & "|" & rName)\n'
        '    if depthLeft > 0 then\n'
        '        try\n'
        '            set kids to UI elements of elem\n'
        '            repeat with k in kids\n'
        '                if (count of theList) >= maxN then return theList\n'
        '                set theList to my aduWalk(k, depthLeft - 1, theList, maxN)\n'
        '            end repeat\n'
        '        end try\n'
        '    end if\n'
        '    return theList\n'
        'end aduWalk\n'
        '\n'
        'tell application "System Events"\n'
        '    set targetProc to first application process whose name is "' + app_name + '"\n'
        '    set targetWindow to first window of targetProc\n'
        '    set theList to {}\n'
        '    set theList to my aduWalk(targetWindow, ' + str(md) + ', theList, ' + str(mn) + ')\n'
        '    set AppleScript\'s text item delimiters to linefeed\n'
        '    return theList as text\n'
        'end tell\n'
    )

    res = await _run_osascript(script, timeout=20)
    if not res["ok"]:
        return res

    elements = []
    for line in (res["output"] or "").split("\n"):
        line = line.strip()
        if not line or "|" not in line:
            continue
        parts = line.split("|", 1)
        elements.append({
            "role": parts[0] if len(parts) > 0 else "",
            "name": parts[1] if len(parts) > 1 else "",
        })

    return {
        "ok": True,
        "app": app,
        "elements": elements,
        "count": len(elements),
    }


# ── Tool 4: click_element ───────────────────────────────────────────────

async def tool_mac_click_element(
    app: str,
    element_name: str,
    role: Optional[str] = None,
) -> Dict[str, Any]:
    """Click a UI element by its name in the given app's frontmost window."""
    if not app or not app.strip() or not element_name or not element_name.strip():
        return {"ok": False, "error": "app and element_name required"}

    app_name = _esc_for_as(app.strip())
    target_name = _esc_for_as(element_name.strip())
    role_check = ""
    if role and role.strip():
        role_esc = _esc_for_as(role.strip())
        role_check = ' and (rRole is "' + role_esc + '")'

    script = (
        'on aduFind(elem, targetName, depthLeft)\n'
        '    set rName to ""\n'
        '    set rRole to ""\n'
        '    try\n'
        '        set rName to (name of elem) as text\n'
        '    end try\n'
        '    try\n'
        '        set rRole to (role of elem) as text\n'
        '    end try\n'
        '    if (rName is targetName)' + role_check + ' then\n'
        '        try\n'
        '            click elem\n'
        '            return true\n'
        '        on error\n'
        '            try\n'
        '                perform action "AXPress" of elem\n'
        '                return true\n'
        '            end try\n'
        '        end try\n'
        '    end if\n'
        '    if depthLeft > 0 then\n'
        '        try\n'
        '            set kids to UI elements of elem\n'
        '            repeat with k in kids\n'
        '                if my aduFind(k, targetName, depthLeft - 1) then return true\n'
        '            end repeat\n'
        '        end try\n'
        '    end if\n'
        '    return false\n'
        'end aduFind\n'
        '\n'
        'tell application "System Events"\n'
        '    set targetProc to first application process whose name is "' + app_name + '"\n'
        '    set targetWindow to first window of targetProc\n'
        '    set found to my aduFind(targetWindow, "' + target_name + '", 6)\n'
        '    if found then\n'
        '        return "clicked"\n'
        '    else\n'
        '        return "not_found"\n'
        '    end if\n'
        'end tell\n'
    )

    res = await _run_osascript(script, timeout=15)
    if not res["ok"]:
        return res

    output = (res["output"] or "").strip()
    if output == "clicked":
        return {"ok": True, "app": app, "element": element_name, "result": "clicked"}
    return {"ok": False, "app": app, "element": element_name, "error": "element_not_found"}


# ── Tool 5: type_text ───────────────────────────────────────────────────

async def tool_mac_type_text(text: str, app: Optional[str] = None) -> Dict[str, Any]:
    """Type text at the current focus (or in the given app after activating it)."""
    if text is None:
        return {"ok": False, "error": "text is None"}

    text_esc = _esc_for_as(text)

    activate = ""
    if app and app.strip():
        app_name = _esc_for_as(app.strip())
        activate = (
            '    try\n'
            '        set targetProc to first application process whose name is "' + app_name + '"\n'
            '        set frontmost of targetProc to true\n'
            '        delay 0.3\n'
            '    end try\n'
        )

    script = (
        'tell application "System Events"\n'
        + activate +
        '    keystroke "' + text_esc + '"\n'
        '    return "typed"\n'
        'end tell\n'
    )

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
    """
    Press a key with optional modifiers.
    Examples:
      key='return'                   → enter
      key='s', modifiers=['command'] → cmd+s
      key='tab', modifiers=['command'] → cmd+tab
    """
    if not key or not key.strip():
        return {"ok": False, "error": "key is empty"}

    key_str = key.strip().lower()

    # Special keys → key code numbers (most reliable)
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

    # Build the press line
    if key_str in KEY_CODES:
        press_line = "key code " + str(KEY_CODES[key_str])
    else:
        # Single characters: use keystroke
        key_esc = _esc_for_as(key.strip())
        press_line = 'keystroke "' + key_esc + '"'

    # Modifiers
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

    activate = ""
    if app and app.strip():
        app_name = _esc_for_as(app.strip())
        activate = (
            '    try\n'
            '        set targetProc to first application process whose name is "' + app_name + '"\n'
            '        set frontmost of targetProc to true\n'
            '        delay 0.3\n'
            '    end try\n'
        )

    script = (
        'tell application "System Events"\n'
        + activate +
        '    ' + press_line + mod_clause + '\n'
        '    return "pressed"\n'
        'end tell\n'
    )

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


# ── Tool definitions for LLM function calls ─────────────────────────────

TOOL_DEFINITIONS.extend([
    {
        "type": "function",
        "function": {
            "name": "mac_list_apps",
            "description": "List currently running visible macOS GUI apps. Call this before operating an app to see what's available.",
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "mac_activate_app",
            "description": "Bring a macOS app to the foreground. For example, before clicking a button in WeChat, activate WeChat first.",
            "parameters": {
                "type": "object",
                "properties": {
                    "app": {"type": "string", "description": "App process name (e.g. Safari, WeChat, Finder, Xcode)"},
                },
                "required": ["app"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "mac_get_ui_elements",
            "description": "Walk the AX tree of a macOS app's frontmost window and return UI elements (buttons, fields, menus). Call before clicking/typing to know what's available.",
            "parameters": {
                "type": "object",
                "properties": {
                    "app":          {"type": "string", "description": "App process name"},
                    "max_depth":    {"type": "integer", "description": "Recursion depth 1-6, default 3", "default": 3},
                    "max_elements": {"type": "integer", "description": "Max elements 5-200, default 50", "default": 50},
                },
                "required": ["app"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "mac_click_element",
            "description": "Click a UI element by name in a macOS app. Use mac_get_ui_elements first to see what's available.",
            "parameters": {
                "type": "object",
                "properties": {
                    "app":          {"type": "string", "description": "App process name"},
                    "element_name": {"type": "string", "description": "Element name to click (e.g. 'Send', 'Login', 'OK')"},
                    "role":         {"type": "string", "description": "Optional role filter (e.g. 'AXButton', 'AXMenuItem')"},
                },
                "required": ["app", "element_name"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "mac_type_text",
            "description": "Type text at the current keyboard focus (or in the given app after activating it). Supports Unicode (Chinese, etc).",
            "parameters": {
                "type": "object",
                "properties": {
                    "text": {"type": "string", "description": "Text to type"},
                    "app":  {"type": "string", "description": "Optional: app to activate first"},
                },
                "required": ["text"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "mac_press_key",
            "description": "Press a key (with optional modifiers). Examples: return, tab, escape, cmd+s, cmd+tab.",
            "parameters": {
                "type": "object",
                "properties": {
                    "key":       {"type": "string", "description": "Key name (return, tab, escape, a, left arrow, etc)"},
                    "modifiers": {"type": "array", "items": {"type": "string"}, "description": "Optional: command, control, option, shift"},
                    "app":       {"type": "string", "description": "Optional: app to activate first"},
                },
                "required": ["key"],
            },
        },
    },
])
