# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-06c91907aeae93b6c85400fecade771afa6d7b6fca7b167443121c119a5d8199"
# Source-SHA256: "76f14a498dc9eb066d20450a7256b78093b9e810e835811e8219d5a0497f3fd3"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
local-agent · :4317  (V1.5 action layer)
========================================
- screencapture：截图（原生，无依赖）
- pyautogui：鼠标位置 / 移动 / 单击 / 双击 / 右键 / 拖拽
- osascript：键盘输入（Unicode 安全）/ 组合键 / 粘贴（pbcopy + cmd+v）/ 前台窗口
- 共享后端 venv（fastapi、uvicorn、pyautogui 已装）

启动：
    cd ~/Desktop/backend
    python3 local_agent_4317.py

Token：Authorization: Bearer local-dev-token（与 .env 的 LOCAL_AGENT_TOKEN 对齐）
若 token 设为空则跳过校验（开发态）。
"""

from __future__ import annotations

import asyncio
import base64
import hmac
import json
import os
import shutil
import subprocess
import tempfile
import time
import uuid
from typing import Any, Dict, List, Optional

from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import JSONResponse
import uvicorn

# pyautogui：可选依赖。鼠标/拖拽走它；失败时降级到 osascript+screencapture 能做的事。
try:
    import pyautogui  # type: ignore
    pyautogui.FAILSAFE = False  # 关闭"鼠标到角落自杀"逃生机制
    pyautogui.PAUSE = 0.02
    _PYAUTOGUI_OK = True
    _PYAUTOGUI_ERR: Optional[str] = None
except Exception as _pyag_err:  # pragma: no cover
    pyautogui = None  # type: ignore
    _PYAUTOGUI_OK = False
    _PYAUTOGUI_ERR = f"{type(_pyag_err).__name__}: {_pyag_err}"

# 不再有默认令牌：没设置 LOCAL_AGENT_TOKEN 时拒绝所有请求（原来默认值可猜、空值还会全部放行）
EXPECTED_TOKEN = (os.getenv("LOCAL_AGENT_TOKEN") or "").strip()
LISTEN_HOST = os.getenv("LOCAL_AGENT_HOST", "127.0.0.1")
LISTEN_PORT = int(os.getenv("LOCAL_AGENT_PORT", "4317"))

app = FastAPI(title="local-agent 4317 (V1.5)")


def _check_auth(authorization: Optional[str]) -> None:
    if not EXPECTED_TOKEN:
        raise HTTPException(status_code=503, detail="LOCAL_AGENT_TOKEN is not set; local agent refuses all requests")
    if not authorization:
        raise HTTPException(status_code=401, detail="missing Authorization")
    parts = authorization.split(None, 1)
    if len(parts) != 2 or parts[0].lower() != "bearer":
        raise HTTPException(status_code=401, detail="bad Authorization scheme")
    if not hmac.compare_digest(parts[1].strip().encode("utf-8"), EXPECTED_TOKEN.encode("utf-8")):
        raise HTTPException(status_code=403, detail="invalid token")


async def _json_body(request: Request) -> Dict[str, Any]:
    try:
        data = await request.json()
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


# ---- macOS helpers ----

def _run(cmd: List[str], input_text: Optional[str] = None, timeout: float = 10.0) -> Dict[str, Any]:
    try:
        out = subprocess.run(
            cmd,
            input=input_text,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return {
            "ok": out.returncode == 0,
            "returncode": out.returncode,
            "stdout": (out.stdout or "").strip(),
            "stderr": (out.stderr or "").strip(),
        }
    except subprocess.TimeoutExpired:
        return {"ok": False, "returncode": -1, "stdout": "", "stderr": f"timeout {timeout}s"}
    except FileNotFoundError as e:
        return {"ok": False, "returncode": -1, "stdout": "", "stderr": str(e)}


# 按键名 → AppleScript 表达。System Events 用 "key code" 或 "keystroke"。
_KEYSTROKE_NAMED = {
    "enter": "return",
    "return": "return",
    "escape": "escape",
    "esc": "escape",
    "tab": "tab",
    "space": "space",
    "delete": "delete",
    "backspace": "delete",
}
# 修饰键 → AppleScript "using ... down"
_MODIFIER = {
    "cmd": "command down",
    "command": "command down",
    "ctrl": "control down",
    "control": "control down",
    "alt": "option down",
    "opt": "option down",
    "option": "option down",
    "shift": "shift down",
}
# key code 表（用于部分需要 key code 的键）
# 注：backend 的 _computer_key_alias 把 "enter" 当 canonical 名;若 _KEY_CODE 里没有 "enter",
#     就会走 keystroke "return" 分支,把字面字符串 r-e-t-u-r-n 输入到当前焦点（BUG）。
#     "enter" 和 "return" 都必须指向 key code 36。
_KEY_CODE = {
    "return": 36,
    "enter": 36,
    "escape": 53,
    "esc": 53,
    "tab": 48,
    "space": 49,
    "delete": 51,
    "backspace": 51,
}


def _osa_keys(keys: List[str]) -> Dict[str, Any]:
    if not keys:
        return {"ok": False, "stderr": "missing keys"}

    norm = [k.strip().lower() for k in keys if k and k.strip()]
    mods = [k for k in norm if k in _MODIFIER]
    targets = [k for k in norm if k not in _MODIFIER]

    if len(targets) > 1:
        return {"ok": False, "stderr": f"only one main key supported, got {targets}"}

    if not targets:
        return {"ok": False, "stderr": "no target key"}

    target = targets[0]
    using = ", ".join(_MODIFIER[m] for m in mods)

    if target in _KEY_CODE:
        code = _KEY_CODE[target]
        if using:
            script = f'tell application "System Events" to key code {code} using {{{using}}}'
        else:
            script = f'tell application "System Events" to key code {code}'
    else:
        # 单字符 / 命名键走 keystroke
        ks = _KEYSTROKE_NAMED.get(target, target)
        if ks in {"return", "tab", "space"}:
            # keystroke 也支持这些名字，作为 escape 字符串
            pass
        ks_literal = ks.replace('"', '\\"')
        if using:
            script = f'tell application "System Events" to keystroke "{ks_literal}" using {{{using}}}'
        else:
            script = f'tell application "System Events" to keystroke "{ks_literal}"'

    return _run(["osascript", "-e", script])


# ---- routes ----

@app.get("/health")
async def health(authorization: Optional[str] = Header(default=None)):
    _check_auth(authorization)
    return {
        "ok": True,
        "agent": "local-agent 4317 (min)",
        "host": LISTEN_HOST,
        "port": LISTEN_PORT,
        "auth_required": bool(EXPECTED_TOKEN),
        "pyautogui_ok": _PYAUTOGUI_OK,
        "pyautogui_error": _PYAUTOGUI_ERR,
    }


@app.post("/api/computer/screenshot")
async def computer_screenshot(request: Request, authorization: Optional[str] = Header(default=None)):
    _check_auth(authorization)
    tmp = os.path.join(tempfile.gettempdir(), f"adu_shot_{uuid.uuid4().hex}.png")
    r = _run(["screencapture", "-x", tmp], timeout=8.0)
    if not r["ok"] or not os.path.exists(tmp):
        raise HTTPException(status_code=500, detail={"ok": False, "error": "screencapture failed", "stderr": r.get("stderr", "")})
    try:
        with open(tmp, "rb") as f:
            data = f.read()
    finally:
        try:
            os.remove(tmp)
        except Exception:
            pass
    b64 = base64.b64encode(data).decode("ascii")
    return {"ok": True, "image_b64": b64, "bytes": len(data), "format": "png"}


@app.get("/api/computer/mouse")
async def computer_mouse(authorization: Optional[str] = Header(default=None)):
    _check_auth(authorization)
    if not _PYAUTOGUI_OK:
        return {"ok": False, "error": "pyautogui unavailable", "detail": _PYAUTOGUI_ERR}
    try:
        pos = pyautogui.position()
        return {"ok": True, "x": int(pos.x), "y": int(pos.y), "backend": "pyautogui"}
    except Exception as e:
        return {"ok": False, "error": f"{type(e).__name__}: {e}"}


@app.post("/api/computer/move")
async def computer_move(request: Request, authorization: Optional[str] = Header(default=None)):
    _check_auth(authorization)
    if not _PYAUTOGUI_OK:
        return {"ok": False, "error": "pyautogui unavailable", "detail": _PYAUTOGUI_ERR}
    body = await _json_body(request)
    try:
        x = int(body.get("x") or 0)
        y = int(body.get("y") or 0)
        duration = float(body.get("duration") or 0.1)
    except (TypeError, ValueError) as e:
        raise HTTPException(status_code=400, detail={"ok": False, "error": f"bad coords: {e}"})
    try:
        pyautogui.moveTo(x, y, duration=duration)
        return {"ok": True, "x": x, "y": y, "duration": duration, "backend": "pyautogui"}
    except Exception as e:
        return {"ok": False, "error": f"{type(e).__name__}: {e}"}


@app.post("/api/computer/click")
async def computer_click(request: Request, authorization: Optional[str] = Header(default=None)):
    _check_auth(authorization)
    if not _PYAUTOGUI_OK:
        return {"ok": False, "error": "pyautogui unavailable", "detail": _PYAUTOGUI_ERR}
    body = await _json_body(request)
    x = body.get("x")
    y = body.get("y")
    button_raw = (body.get("button") or "left").lower()
    button = "right" if button_raw in ("right", "secondary") else (
        "middle" if button_raw == "middle" else "left"
    )
    try:
        count_raw = body.get("count") or body.get("clicks") or 1
        count = max(1, min(int(count_raw), 5))
    except (TypeError, ValueError):
        count = 1
    try:
        if x is not None and y is not None:
            pyautogui.click(x=int(x), y=int(y), button=button, clicks=count)
        else:
            pyautogui.click(button=button, clicks=count)
        return {"ok": True, "x": x, "y": y, "button": button, "count": count, "backend": "pyautogui"}
    except Exception as e:
        return {"ok": False, "error": f"{type(e).__name__}: {e}"}


@app.post("/api/computer/drag")
async def computer_drag(request: Request, authorization: Optional[str] = Header(default=None)):
    """从 (x1,y1) 拖到 (x2,y2)。请求体支持两种形态：
    1) {"x1":..,"y1":..,"x2":..,"y2":..,"duration":0.3}
    2) {"from":{"x":..,"y":..}, "to":{"x":..,"y":..}, "duration":0.3}
    """
    _check_auth(authorization)
    if not _PYAUTOGUI_OK:
        return {"ok": False, "error": "pyautogui unavailable", "detail": _PYAUTOGUI_ERR}
    body = await _json_body(request)
    src = body.get("from") if isinstance(body.get("from"), dict) else {}
    dst = body.get("to") if isinstance(body.get("to"), dict) else {}
    try:
        x1 = int(body.get("x1") if body.get("x1") is not None else src.get("x"))
        y1 = int(body.get("y1") if body.get("y1") is not None else src.get("y"))
        x2 = int(body.get("x2") if body.get("x2") is not None else dst.get("x"))
        y2 = int(body.get("y2") if body.get("y2") is not None else dst.get("y"))
    except (TypeError, ValueError) as e:
        raise HTTPException(status_code=400, detail={"ok": False, "error": f"drag requires x1,y1,x2,y2: {e}"})
    try:
        duration = float(body.get("duration") or 0.3)
    except (TypeError, ValueError):
        duration = 0.3
    button_raw = (body.get("button") or "left").lower()
    button = "right" if button_raw == "right" else "left"
    try:
        pyautogui.moveTo(x1, y1)
        pyautogui.dragTo(x2, y2, duration=duration, button=button)
        return {"ok": True, "from": [x1, y1], "to": [x2, y2], "duration": duration, "button": button}
    except Exception as e:
        return {"ok": False, "error": f"{type(e).__name__}: {e}"}


@app.post("/api/computer/paste")
async def computer_paste(request: Request, authorization: Optional[str] = Header(default=None)):
    """把文本放入剪贴板，再按 Cmd+V 粘贴。"""
    _check_auth(authorization)
    body = await _json_body(request)
    text = str(body.get("text") or "")
    if not text:
        raise HTTPException(status_code=400, detail={"ok": False, "error": "missing text"})
    # 1) pbcopy 写入剪贴板
    try:
        cp = subprocess.run(
            ["pbcopy"],
            input=text,
            text=True,
            timeout=5,
            capture_output=True,
        )
        if cp.returncode != 0:
            return {"ok": False, "error": "pbcopy failed", "stderr": (cp.stderr or "").strip()}
    except Exception as e:
        return {"ok": False, "error": f"pbcopy exception: {type(e).__name__}: {e}"}
    # 2) Cmd+V 粘贴
    r = _run(["osascript", "-e", 'tell application "System Events" to keystroke "v" using {command down}'])
    if not r["ok"]:
        return {"ok": False, "error": "paste keystroke failed", "stderr": r.get("stderr", "")}
    return {"ok": True, "pasted_chars": len(text), "preview": text[:80]}


@app.get("/api/computer/active_window")
async def computer_active_window(authorization: Optional[str] = Header(default=None)):
    """返回前台 app 名 + 首个窗口标题（只读，risk_level=0）。"""
    _check_auth(authorization)
    script = (
        'tell application "System Events"\n'
        '    set frontApp to first application process whose frontmost is true\n'
        '    set appName to name of frontApp\n'
        '    set winTitle to ""\n'
        '    try\n'
        '        set winTitle to name of front window of frontApp\n'
        '    end try\n'
        '    return appName & "||" & winTitle\n'
        'end tell'
    )
    r = _run(["osascript", "-e", script])
    if not r["ok"]:
        return {"ok": False, "error": "osascript failed", "stderr": r.get("stderr", "")}
    parts = r["stdout"].split("||", 1)
    return {
        "ok": True,
        "app": parts[0].strip() if parts else "",
        "window_title": parts[1].strip() if len(parts) > 1 else "",
    }


@app.post("/api/computer/type")
async def computer_type(request: Request, authorization: Optional[str] = Header(default=None)):
    _check_auth(authorization)
    body = await _json_body(request)
    text = str(body.get("text") or "")
    if not text:
        raise HTTPException(status_code=400, detail={"ok": False, "error": "missing text"})
    # 转义双引号
    safe = text.replace('\\', '\\\\').replace('"', '\\"')
    script = f'tell application "System Events" to keystroke "{safe}"'
    r = _run(["osascript", "-e", script])
    return {"ok": r["ok"], "typed": text, "stderr": r.get("stderr", "")}


@app.post("/api/computer/press")
async def computer_press(request: Request, authorization: Optional[str] = Header(default=None)):
    _check_auth(authorization)
    body = await _json_body(request)
    keys_raw = body.get("keys") or body.get("key")
    if isinstance(keys_raw, str):
        keys = [keys_raw]
    elif isinstance(keys_raw, list):
        keys = [str(k) for k in keys_raw]
    else:
        raise HTTPException(status_code=400, detail={"ok": False, "error": "missing keys"})
    r = _osa_keys(keys)
    if not r["ok"]:
        raise HTTPException(status_code=500, detail={"ok": False, "error": "press failed", "keys": keys, "stderr": r.get("stderr", "")})
    return {"ok": True, "keys": keys}


# ---- Dev Agent V1 (read-only Claude Code) ----
# ═══════════════════════════════════════════════════════════════════
# ✅ Computer Body Gateway V2 — OS GUI ports (screen/mouse/app/browser)
#    被后端 /api/brain/computer/body/{port}/{action} 代理。只读为主,无 shell 暴露。
# ═══════════════════════════════════════════════════════════════════

def _osa(script: str, timeout: float = 8.0) -> Dict[str, Any]:
    return _run(["osascript", "-e", script], timeout=timeout)


@app.get("/api/computer/displays")
async def computer_displays(authorization: Optional[str] = Header(default=None)):
    """屏幕分辨率/数量(只读)。"""
    _check_auth(authorization)
    r = _osa('tell application "Finder" to get bounds of window of desktop')
    bounds = r.get("stdout", "") if r.get("ok") else ""
    sp = _run(["system_profiler", "SPDisplaysDataType"], timeout=10)
    count = sp.get("stdout", "").count("Resolution:") if sp.get("ok") else (1 if bounds else 0)
    return {"ok": True, "desktop_bounds": bounds, "display_count": max(1, count)}


@app.get("/api/computer/windows")
async def computer_windows(authorization: Optional[str] = Header(default=None)):
    """前台 app 的窗口标题列表(只读)。"""
    _check_auth(authorization)
    script = (
        'tell application "System Events"\n'
        '  set frontApp to first application process whose frontmost is true\n'
        '  set appName to name of frontApp\n'
        '  set titles to {}\n'
        '  try\n'
        '    repeat with w in windows of frontApp\n'
        '      set end of titles to name of w\n'
        '    end repeat\n'
        '  end try\n'
        '  set AppleScript\'s text item delimiters to "||"\n'
        '  return appName & ">>" & (titles as string)\n'
        'end tell'
    )
    r = _osa(script)
    if not r.get("ok"):
        return {"ok": False, "error": "osascript failed", "stderr": r.get("stderr", "")}
    app_part, _, titles = r["stdout"].partition(">>")
    win_titles = [t for t in titles.split("||") if t.strip()]
    return {"ok": True, "app": app_part.strip(), "windows": win_titles, "count": len(win_titles)}


@app.get("/api/computer/apps")
async def computer_apps(authorization: Optional[str] = Header(default=None)):
    """当前运行中的可见 app 列表(只读)。"""
    _check_auth(authorization)
    script = (
        'tell application "System Events" to get name of (every process whose background only is false)'
    )
    r = _osa(script)
    if not r.get("ok"):
        return {"ok": False, "error": "osascript failed", "stderr": r.get("stderr", "")}
    apps = [a.strip() for a in r["stdout"].split(",") if a.strip()]
    return {"ok": True, "apps": apps, "count": len(apps)}


@app.get("/api/computer/frontmost_app")
async def computer_frontmost_app(authorization: Optional[str] = Header(default=None)):
    """最前台 app 名(只读)。"""
    _check_auth(authorization)
    r = _osa('tell application "System Events" to get name of first application process whose frontmost is true')
    if not r.get("ok"):
        return {"ok": False, "error": "osascript failed", "stderr": r.get("stderr", "")}
    return {"ok": True, "frontmost_app": r["stdout"].strip()}


@app.post("/api/computer/open_app")
async def computer_open_app(request: Request, authorization: Optional[str] = Header(default=None)):
    """打开 App。{app}。用 `open -a`,失败回退 Spotlight 不在这里做(后端兜底)。"""
    _check_auth(authorization)
    body = await _json_body(request)
    app = str(body.get("app") or body.get("name") or "").strip()
    if not app:
        raise HTTPException(status_code=400, detail={"ok": False, "error": "missing app"})
    r = _run(["open", "-a", app], timeout=12)
    return {"ok": r["ok"], "app": app, "stderr": r.get("stderr", "")}


@app.post("/api/computer/focus_app")
async def computer_focus_app(request: Request, authorization: Optional[str] = Header(default=None)):
    """把某 App 调到前台。{app}。"""
    _check_auth(authorization)
    body = await _json_body(request)
    app = str(body.get("app") or body.get("name") or "").strip()
    if not app:
        raise HTTPException(status_code=400, detail={"ok": False, "error": "missing app"})
    safe = app.replace('"', '\\"')
    r = _osa(f'tell application "{safe}" to activate')
    return {"ok": r["ok"], "app": app, "stderr": r.get("stderr", "")}


@app.post("/api/computer/scroll")
async def computer_scroll(request: Request, authorization: Optional[str] = Header(default=None)):
    """滚动。{dx?, dy?}。用 System Events scroll(整数行)。"""
    _check_auth(authorization)
    body = await _json_body(request)
    try:
        dy = int(body.get("dy") if body.get("dy") is not None else body.get("amount") or -3)
        dx = int(body.get("dx") or 0)
    except Exception:
        dx, dy = 0, -3
    # AppleScript 没有原生 scroll;用 key code(下=125/上=126)近似,或 cliclick 若有。
    cliclick = shutil.which("cliclick")
    if cliclick:
        direction = "+" if dy < 0 else "-"
        r = _run([cliclick, f"w:{abs(dy)}"], timeout=6)
        return {"ok": r["ok"], "scrolled": {"dx": dx, "dy": dy}, "via": "cliclick"}
    # 回退:用方向键近似滚动
    code = 125 if dy < 0 else 126
    reps = min(abs(dy), 20)
    script = 'tell application "System Events"\n' + \
             "\n".join([f'  key code {code}' for _ in range(reps)]) + \
             '\nend tell'
    r = _osa(script)
    return {"ok": r["ok"], "scrolled": {"dx": dx, "dy": dy}, "via": "key_code_fallback"}


# ═══════════════════════════════════════════════════════════════════
# ✅ BrowserPort V2 — DOM 级浏览器控制(Playwright 持久会话)
#    阿杜真正控制网页:open_url / extract_text / get_dom / click_text /
#    type_into / screenshot / wait_for。Playwright 不可用则优雅降级。
# ═══════════════════════════════════════════════════════════════════

_PLAYWRIGHT_OK = False
try:
    from playwright.async_api import async_playwright as _async_playwright  # noqa: F401
    _PLAYWRIGHT_OK = True
except Exception:
    _PLAYWRIGHT_OK = False

BROWSER_HEADLESS = (os.getenv("BROWSER_HEADLESS", "1").strip().lower() not in ("0", "false", "no"))


class _BrowserSession:
    """单例持久浏览器会话(async)。同一个 page 上跨请求操作,才能 DOM 级控制。"""

    def __init__(self) -> None:
        self._pw = None
        self._browser = None
        self._page = None
        self._lock = asyncio.Lock()

    async def _ensure(self) -> None:
        if self._page is not None:
            return
        self._pw = await _async_playwright().start()
        self._browser = await self._pw.chromium.launch(headless=BROWSER_HEADLESS)
        self._page = await self._browser.new_page()

    async def open_url(self, url: str, new_tab: bool = False) -> Dict[str, Any]:
        await self._ensure()
        if new_tab and self._browser is not None:
            self._page = await self._browser.new_page()
        await self._page.goto(url, timeout=20000, wait_until="domcontentloaded")
        return {"ok": True, "url": self._page.url, "title": await self._page.title()}

    async def extract_text(self) -> Dict[str, Any]:
        await self._ensure()
        text = await self._page.inner_text("body")
        return {"ok": True, "url": self._page.url, "title": await self._page.title(),
                "text": text[:20000], "truncated": len(text) > 20000}

    async def get_dom(self, max_nodes: int = 150) -> Dict[str, Any]:
        await self._ensure()
        js = """(maxNodes) => {
          const sel = 'a,button,input,textarea,select,[role],h1,h2,h3,label,[onclick]';
          const out = [];
          const nodes = document.querySelectorAll(sel);
          function cssPath(el){
            if(!el) return '';
            if(el.id) return '#'+el.id;
            const parts=[]; let e=el;
            while(e && e.nodeType===1 && parts.length<5){
              let s=e.tagName.toLowerCase();
              if(e.name) s+=`[name="${e.name}"]`;
              parts.unshift(s); e=e.parentElement;
            }
            return parts.join('>');
          }
          for(const el of nodes){
            if(out.length>=maxNodes) break;
            const r=el.getBoundingClientRect();
            const visible = !!(r.width||r.height) && getComputedStyle(el).visibility!=='hidden' && getComputedStyle(el).display!=='none';
            const txt=(el.innerText||el.value||el.placeholder||'').trim().slice(0,120);
            if(!visible && !txt) continue;
            out.push({
              tag: el.tagName.toLowerCase(),
              text: txt,
              role: el.getAttribute('role')||'',
              href: el.getAttribute('href')||'',
              name: el.getAttribute('name')||'',
              type: el.getAttribute('type')||'',
              selector: cssPath(el),
              visible: visible
            });
          }
          return out;
        }"""
        nodes = await self._page.evaluate(js, max_nodes)
        return {"ok": True, "url": self._page.url, "count": len(nodes), "dom": nodes}

    async def click_text(self, text: str) -> Dict[str, Any]:
        await self._ensure()
        try:
            loc = self._page.get_by_text(text, exact=False).first
            await loc.click(timeout=6000)
            return {"ok": True, "clicked": text, "url": self._page.url}
        except Exception as e:
            # 退回 role=按钮/链接 名称匹配
            try:
                await self._page.get_by_role("button", name=text).first.click(timeout=4000)
                return {"ok": True, "clicked": text, "via": "role_button", "url": self._page.url}
            except Exception:
                return {"ok": False, "error": "text_not_found", "text": text, "detail": str(e)[:160]}

    async def type_into(self, selector: str, text: str) -> Dict[str, Any]:
        await self._ensure()
        try:
            await self._page.fill(selector, text, timeout=6000)
            return {"ok": True, "selector": selector, "typed_len": len(text), "url": self._page.url}
        except Exception as e:
            return {"ok": False, "error": "fill_failed", "selector": selector, "detail": str(e)[:160]}

    async def screenshot(self) -> Dict[str, Any]:
        await self._ensure()
        png = await self._page.screenshot(full_page=False)
        return {"ok": True, "url": self._page.url, "format": "png", "bytes": len(png),
                "image_b64": base64.b64encode(png).decode("ascii")}

    async def wait_for(self, text: str, timeout: float = 5.0) -> Dict[str, Any]:
        await self._ensure()
        try:
            await self._page.get_by_text(text, exact=False).first.wait_for(timeout=int(timeout * 1000))
            return {"ok": True, "found": True, "text": text}
        except Exception:
            return {"ok": False, "found": False, "text": text, "error": "timeout"}

    async def close(self) -> Dict[str, Any]:
        try:
            if self._browser is not None:
                await self._browser.close()
            if self._pw is not None:
                await self._pw.stop()
        except Exception:
            pass
        self._pw = self._browser = self._page = None
        return {"ok": True, "closed": True}


_BROWSER = _BrowserSession()


def _browser_unavailable() -> Dict[str, Any]:
    return {"ok": False, "error": "browser_dom_unsupported",
            "fallback": "screen_click_required",
            "message": "Playwright 未安装/不可用。pip install playwright && python3 -m playwright install chromium"}


@app.post("/api/computer/browser/open_url")
async def computer_browser_open_url(request: Request, authorization: Optional[str] = Header(default=None)):
    _check_auth(authorization)
    body = await _json_body(request)
    url = str(body.get("url") or "").strip()
    if not (url.startswith("http://") or url.startswith("https://")):
        raise HTTPException(status_code=400, detail={"ok": False, "error": "bad_url"})
    if not _PLAYWRIGHT_OK:
        # 降级:用系统默认浏览器打开(无 DOM 控制)
        r = _run(["open", url], timeout=10)
        return {"ok": r["ok"], "url": url, "dom": False, "note": "playwright 不可用,系统浏览器打开,无 DOM 控制"}
    return await _BROWSER.open_url(url, bool(body.get("new_tab")))


@app.post("/api/computer/browser/extract_text")
async def computer_browser_extract_text(request: Request, authorization: Optional[str] = Header(default=None)):
    _check_auth(authorization)
    if not _PLAYWRIGHT_OK:
        return _browser_unavailable()
    return await _BROWSER.extract_text()


@app.post("/api/computer/browser/get_dom")
async def computer_browser_get_dom(request: Request, authorization: Optional[str] = Header(default=None)):
    _check_auth(authorization)
    body = await _json_body(request)
    if not _PLAYWRIGHT_OK:
        return _browser_unavailable()
    return await _BROWSER.get_dom(int(body.get("max_nodes") or 150))


@app.post("/api/computer/browser/click_text")
async def computer_browser_click_text(request: Request, authorization: Optional[str] = Header(default=None)):
    _check_auth(authorization)
    body = await _json_body(request)
    if not _PLAYWRIGHT_OK:
        return _browser_unavailable()
    text = str(body.get("text") or "").strip()
    if not text:
        return {"ok": False, "error": "missing_text"}
    return await _BROWSER.click_text(text)


@app.post("/api/computer/browser/type_into")
async def computer_browser_type_into(request: Request, authorization: Optional[str] = Header(default=None)):
    _check_auth(authorization)
    body = await _json_body(request)
    if not _PLAYWRIGHT_OK:
        return _browser_unavailable()
    selector = str(body.get("selector") or "").strip()
    text = str(body.get("text") or "")
    if not selector:
        return {"ok": False, "error": "missing_selector"}
    return await _BROWSER.type_into(selector, text)


@app.post("/api/computer/browser/screenshot")
async def computer_browser_screenshot(request: Request, authorization: Optional[str] = Header(default=None)):
    _check_auth(authorization)
    if not _PLAYWRIGHT_OK:
        return await computer_screenshot(request, authorization)  # 降级:整屏截图
    return await _BROWSER.screenshot()


@app.post("/api/computer/browser/wait_for")
async def computer_browser_wait_for(request: Request, authorization: Optional[str] = Header(default=None)):
    _check_auth(authorization)
    body = await _json_body(request)
    if not _PLAYWRIGHT_OK:
        return _browser_unavailable()
    return await _BROWSER.wait_for(str(body.get("text") or ""), float(body.get("timeout") or 5))


@app.post("/api/computer/browser/close")
async def computer_browser_close(authorization: Optional[str] = Header(default=None)):
    _check_auth(authorization)
    if not _PLAYWRIGHT_OK:
        return {"ok": True, "closed": True, "note": "no playwright session"}
    return await _BROWSER.close()


@app.get("/api/computer/browser/status")
async def computer_browser_status(authorization: Optional[str] = Header(default=None)):
    _check_auth(authorization)
    return {"ok": True, "playwright": _PLAYWRIGHT_OK, "headless": BROWSER_HEADLESS,
            "session_open": _BROWSER._page is not None if _PLAYWRIGHT_OK else False}


# 接 ChatAGI Dev Agent V1 只读版：手机 App → backend → local-agent → claude CLI → 分析 GPTsora 项目。
# 只允许 project=GPTsora，目录固定 ~/Desktop/GPTsora。
# 调用方式：claude -p "<prompt>" --permission-mode plan --max-turns 3 (cwd = project_dir)

DEV_AGENT_CLAUDE_BIN = os.getenv("DEV_AGENT_CLAUDE_BIN") or "~/.local/bin/claude"
DEV_AGENT_PROJECT_DIR = os.getenv("DEV_AGENT_PROJECT_DIR") or "~/Desktop/GPTsora"
DEV_AGENT_TIMEOUT_SEC = float(os.getenv("DEV_AGENT_TIMEOUT_SEC") or "90")
DEV_AGENT_MAX_TURNS = os.getenv("DEV_AGENT_MAX_TURNS") or "3"
DEV_AGENT_SAFETY_PREFIX = (
    "只读分析。不要修改文件。不要读取密钥、.env、SSH、证书、系统隐私目录。\n\n"
)


@app.get("/dev_agent/health")
async def dev_agent_health(authorization: Optional[str] = Header(default=None)):
    _check_auth(authorization)
    v = _run([DEV_AGENT_CLAUDE_BIN, "--version"], timeout=4.0)
    return {
        "ok": True,
        "claude_installed": bool(v["ok"]),
        "claude_version": v["stdout"] if v["ok"] else None,
        "claude_bin": DEV_AGENT_CLAUDE_BIN,
        "project_dir": DEV_AGENT_PROJECT_DIR,
        "project_exists": os.path.isdir(DEV_AGENT_PROJECT_DIR),
        "timeout_sec": DEV_AGENT_TIMEOUT_SEC,
        "max_turns": DEV_AGENT_MAX_TURNS,
    }


@app.post("/dev_agent/ask")
async def dev_agent_ask(request: Request, authorization: Optional[str] = Header(default=None)):
    _check_auth(authorization)
    body = await _json_body(request)
    project = str(body.get("project") or "").strip()
    prompt = str(body.get("prompt") or "").strip()

    if project != "GPTsora":
        raise HTTPException(status_code=400, detail={
            "ok": False,
            "error": f"project must be 'GPTsora', got '{project}'",
        })
    if not prompt:
        raise HTTPException(status_code=400, detail={"ok": False, "error": "missing prompt"})
    if not os.path.isdir(DEV_AGENT_PROJECT_DIR):
        return {
            "ok": False, "project": "GPTsora", "mode": "readonly",
            "output": "", "elapsed_ms": 0,
            "error": f"project_dir missing: {DEV_AGENT_PROJECT_DIR}",
        }

    full_prompt = DEV_AGENT_SAFETY_PREFIX + prompt
    started = time.time()

    try:
        proc = await asyncio.create_subprocess_exec(
            DEV_AGENT_CLAUDE_BIN, "-p", full_prompt,
            "--permission-mode", "plan",
            "--max-turns", str(DEV_AGENT_MAX_TURNS),
            cwd=DEV_AGENT_PROJECT_DIR,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
    except FileNotFoundError:
        return {
            "ok": False, "project": "GPTsora", "mode": "readonly",
            "output": "", "elapsed_ms": int((time.time() - started) * 1000),
            "error": f"claude binary not found: {DEV_AGENT_CLAUDE_BIN}",
        }
    except Exception as e:
        return {
            "ok": False, "project": "GPTsora", "mode": "readonly",
            "output": "", "elapsed_ms": int((time.time() - started) * 1000),
            "error": f"spawn failed: {type(e).__name__}: {e}",
        }

    try:
        stdout_b, stderr_b = await asyncio.wait_for(
            proc.communicate(), timeout=DEV_AGENT_TIMEOUT_SEC
        )
    except asyncio.TimeoutError:
        try:
            proc.kill()
            await proc.wait()
        except Exception:
            pass
        return {
            "ok": False, "project": "GPTsora", "mode": "readonly",
            "output": "", "elapsed_ms": int((time.time() - started) * 1000),
            "error": f"timeout after {DEV_AGENT_TIMEOUT_SEC}s",
        }

    elapsed_ms = int((time.time() - started) * 1000)
    stdout = (stdout_b or b"").decode("utf-8", errors="replace").strip()
    stderr = (stderr_b or b"").decode("utf-8", errors="replace").strip()

    if proc.returncode != 0:
        return {
            "ok": False, "project": "GPTsora", "mode": "readonly",
            "output": stdout, "elapsed_ms": elapsed_ms,
            "error": f"claude exit={proc.returncode}: {stderr[:500]}",
        }

    return {
        "ok": True, "project": "GPTsora", "mode": "readonly",
        "output": stdout, "elapsed_ms": elapsed_ms,
        "error": None,
    }


# ---- entry ----

if __name__ == "__main__":
    uvicorn.run(app, host=LISTEN_HOST, port=LISTEN_PORT, log_level="warning")
