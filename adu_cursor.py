#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-8f92f2964cc65f09bc8b35990af66aafd32b517c0aab904e45c82f7e29b6b470"
# Source-SHA256: "653dce729568ad30b4105180ac323cdfbc09e08b457652e5da8726ea1209caaf"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
adu_cursor.py — QPG v3.0 (Claude-Driven Grid)

Claude 主动驱动的视觉点击服务。

核心设计(按 Yuyong 手画设计图):
  - 整个屏幕铺 1000 格(40×25)固定 ID 网格
  - Claude 看满屏图 → 主动决定:直接点 or 要求放大哪一片
  - Claude 要求放大时,给他看 7×7 区域的放大图(原 ID 继续用)
  - 最多 2 轮:满屏 + 放大
  - 系统预先算好 1000 个 ID 的精确坐标,Claude 只返回 ID,系统鼠标执行

5 条宪法原则(保持):
  1. 坐标预先算好,O(1) 查表
  2. Claude 只输出 ID(整数)
  3. 鼠标固定 HOME
  4. N 个并行竞速
  5. 由 Claude 决定是否继续(不是盲目递归)

CLI:
    python3 adu_cursor.py --cli "WeChat icon in Dock"
    python3 adu_cursor.py --cli "WeChat" --click
"""

import io
import os
import sys
import time
import json
import math
import base64
import asyncio
import re as _re
import traceback
import datetime as _dt
import pathlib as _pl
import subprocess
from dataclasses import dataclass, field
from typing import List, Tuple, Optional, Dict, Any

from fastapi import FastAPI
from pydantic import BaseModel, Field
from PIL import Image, ImageDraw, ImageFont

try:
    import mss
except Exception:
    mss = None

try:
    import pyautogui
    pyautogui.FAILSAFE = False
    pyautogui.PAUSE = 0
except Exception:
    pyautogui = None


# =========================
# 配置
# =========================

HOST = os.getenv("ADU_CURSOR_HOST", "127.0.0.1")
PORT = int(os.getenv("ADU_CURSOR_PORT", "8787"))
MODEL_NAME = os.getenv("ADU_CURSOR_MODEL", "claude-opus-4-7")

DEFAULT_CLICK_SETTLE = 0.35
VLM_RETRY = 3
VLM_RETRY_SLEEP = 0.35

SCREENSHOT_DIR = _pl.Path(
    os.getenv("ADU_CURSOR_DEBUG_DIR",
              os.path.join(os.path.expanduser("~"), ".adu_cursor", "debug"))
)
SCREENSHOT_DIR.mkdir(parents=True, exist_ok=True)

MEMORY_DIR = _pl.Path(os.path.expanduser("~/.adu_cursor"))
MEMORY_DIR.mkdir(exist_ok=True, parents=True)
_MEMORY_FILE = MEMORY_DIR / "route_server_memory.json"
_OP_LOG = MEMORY_DIR / "route_server_operations.jsonl"

ENABLE_SYSTEM_OPEN = (os.getenv("ADU_CURSOR_SYSTEM_OPEN", "1").strip().lower()
                      in ("1", "true", "yes", "on"))


# =========================
# 基础工具
# =========================

def now_ts() -> str:
    return time.strftime("%Y%m%d_%H%M%S")


def get_screen_size() -> Tuple[int, int]:
    if pyautogui:
        s = pyautogui.size()
        return int(s.width), int(s.height)
    if mss:
        with mss.mss() as sct:
            mon = sct.monitors[0]
            return int(mon["width"]), int(mon["height"])
    raise RuntimeError("pyautogui/mss 都不可用")


def get_cursor_pos() -> Tuple[int, int]:
    if not pyautogui:
        raise RuntimeError("pyautogui 不可用")
    x, y = pyautogui.position()
    return int(x), int(y)


def move_cursor_to(x: float, y: float, duration: float = 0.15):
    if not pyautogui:
        raise RuntimeError("pyautogui 不可用")
    pyautogui.moveTo(int(round(x)), int(round(y)), duration=duration)


def click_mouse(button: str = "left", clicks: int = 1, interval: float = 0.12):
    if not pyautogui:
        raise RuntimeError("pyautogui 不可用")
    pyautogui.click(button=button, clicks=clicks, interval=interval)


def capture_screen_pil() -> Image.Image:
    try:
        from Quartz import CGMainDisplayID, CGDisplayCreateImage
        from Cocoa import NSBitmapImageRep
        cg = CGDisplayCreateImage(CGMainDisplayID())
        if cg is not None:
            rep = NSBitmapImageRep.alloc().initWithCGImage_(cg)
            png = rep.representationUsingType_properties_(4, None)
            img = Image.open(io.BytesIO(bytes(png)))
            if img.mode != "RGB":
                img = img.convert("RGB")
            return img
    except Exception:
        pass

    if mss:
        try:
            with mss.mss() as sct:
                mon = sct.monitors[0]
                shot = sct.grab(mon)
                return Image.frombytes("RGB", shot.size, shot.rgb)
        except Exception:
            pass

    if pyautogui:
        img = pyautogui.screenshot()
        if img.mode != "RGB":
            img = img.convert("RGB")
        return img

    raise RuntimeError("无法截图")


_CAPTURE_SCALE_CACHE: Optional[float] = None


def _scale() -> float:
    global _CAPTURE_SCALE_CACHE
    if _CAPTURE_SCALE_CACHE is not None:
        return _CAPTURE_SCALE_CACHE
    try:
        img = capture_screen_pil()
        lw, _ = get_screen_size()
        if lw > 0:
            _CAPTURE_SCALE_CACHE = img.size[0] / float(lw)
        else:
            _CAPTURE_SCALE_CACHE = 1.0
    except Exception:
        _CAPTURE_SCALE_CACHE = 1.0
    return _CAPTURE_SCALE_CACHE


def save_image(img: Image.Image, name: str) -> str:
    path = SCREENSHOT_DIR / name
    to_save = img if img.mode == "RGB" else img.convert("RGB")
    to_save.save(str(path), "JPEG", quality=90)
    return str(path)


def pil_to_jpeg_bytes(img: Image.Image, max_dim: int = 2400, quality: int = 88) -> bytes:
    out = img.copy()
    if max(out.size) > max_dim:
        out.thumbnail((max_dim, max_dim))
    if out.mode != "RGB":
        out = out.convert("RGB")
    buf = io.BytesIO()
    out.save(buf, format="JPEG", quality=quality, optimize=True)
    return buf.getvalue()


def try_load_font(size: int = 24):
    for p in [
        "/System/Library/Fonts/Helvetica.ttc",
        "/System/Library/Fonts/HelveticaNeue.ttc",
        "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
        "/System/Library/Fonts/SFNS.ttf",
    ]:
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except Exception:
                continue
    return ImageFont.load_default()


# =========================
# 系统 open -a
# =========================

APP_ALIASES = {
    "wechat": "WeChat", "微信": "WeChat",
    "safari": "Safari", "finder": "Finder", "xcode": "Xcode",
    "chrome": "Google Chrome", "google chrome": "Google Chrome",
    "terminal": "Terminal", "iterm": "iTerm", "iterm2": "iTerm",
    "vscode": "Visual Studio Code", "visual studio code": "Visual Studio Code",
    "music": "Music", "mail": "Mail", "calendar": "Calendar",
    "notes": "Notes", "备忘录": "Notes", "日历": "Calendar", "邮件": "Mail",
    "spotify": "Spotify", "slack": "Slack", "zoom": "zoom.us",
    "messages": "Messages", "photos": "Photos", "照片": "Photos",
    "preview": "Preview", "预览": "Preview",
    "settings": "System Settings", "系统设置": "System Settings",
    "activity monitor": "Activity Monitor", "活动监视器": "Activity Monitor",
}


def _get_active_app_name() -> str:
    try:
        r = subprocess.run(
            ["osascript", "-e",
             'tell application "System Events" to get name of first application process whose frontmost is true'],
            check=False, capture_output=True, text=True, timeout=3,
        )
        return (r.stdout or "").strip()
    except Exception:
        return ""


def _extract_app_name(target: str) -> str:
    s = (target or "").strip()
    ls = s.lower()
    for k, v in APP_ALIASES.items():
        if k in ls:
            return v
    if s:
        return s.split()[0]
    return ""


def try_system_open(target: str) -> Dict[str, Any]:
    app = _extract_app_name(target)
    if not app:
        return {"ok": False, "method": "", "app_tried": "", "active_app": _get_active_app_name()}
    try:
        r = subprocess.run(["open", "-a", app], check=False, capture_output=True, text=True, timeout=5)
        if r.returncode == 0:
            time.sleep(0.7)
            active = _get_active_app_name()
            if active.lower() == app.lower():
                return {"ok": True, "method": "open -a", "app_tried": app, "active_app": active}
    except Exception:
        pass
    try:
        subprocess.run(
            ["osascript", "-e", f'tell application "{app}" to activate'],
            check=False, capture_output=True, text=True, timeout=5,
        )
        time.sleep(0.5)
        active = _get_active_app_name()
        if active.lower() == app.lower():
            return {"ok": True, "method": "applescript_activate", "app_tried": app, "active_app": active}
    except Exception:
        pass
    return {"ok": False, "method": "", "app_tried": app, "active_app": _get_active_app_name()}


# =========================
# Claude VLM
# =========================

_ANTHROPIC_CLIENT = None
_ANTHROPIC_ASYNC_CLIENT = None


def _get_claude_client():
    global _ANTHROPIC_CLIENT
    if _ANTHROPIC_CLIENT is not None:
        return _ANTHROPIC_CLIENT
    try:
        from anthropic import Anthropic
    except ImportError:
        raise RuntimeError("缺少 anthropic 包")
    if not os.environ.get("ANTHROPIC_API_KEY"):
        raise RuntimeError("未设置 ANTHROPIC_API_KEY")
    _ANTHROPIC_CLIENT = Anthropic()
    return _ANTHROPIC_CLIENT


def _get_claude_client_async():
    global _ANTHROPIC_ASYNC_CLIENT
    if _ANTHROPIC_ASYNC_CLIENT is not None:
        return _ANTHROPIC_ASYNC_CLIENT
    try:
        from anthropic import AsyncAnthropic
    except ImportError:
        raise RuntimeError("缺少 anthropic 包")
    if not os.environ.get("ANTHROPIC_API_KEY"):
        raise RuntimeError("未设置 ANTHROPIC_API_KEY")
    _ANTHROPIC_ASYNC_CLIENT = AsyncAnthropic()
    return _ANTHROPIC_ASYNC_CLIENT


def _extract_json_from_text(text: str) -> Dict[str, Any]:
    t = (text or "").strip()
    fence = "```"
    if t.startswith(fence):
        t = t[len(fence):]
        if t.lower().startswith("json"):
            t = t[4:]
        t = t.strip()
        if fence in t:
            t = t.split(fence, 1)[0].strip()
    if not t.startswith("{"):
        s, e = t.find("{"), t.rfind("}")
        if s >= 0 and e > s:
            t = t[s:e + 1]
    return json.loads(t)


def _safe_int(value, lo: int = 1, hi: int = 1000) -> int:
    """健壮地从 Claude 返回值提取整数(处理 'Point 847' / '847.' / 847.0)"""
    if isinstance(value, (int, float)):
        try:
            n = int(value)
            return n if lo <= n <= hi else 0
        except Exception:
            return 0
    if isinstance(value, str):
        m = _re.search(r"\d+", value)
        if m:
            try:
                n = int(m.group())
                return n if lo <= n <= hi else 0
            except Exception:
                return 0
    return 0


async def _call_claude_vision_async(system_prompt: str, user_text: str,
                                    jpeg_bytes: bytes, max_tokens: int = 280) -> str:
    client = _get_claude_client_async()
    b64 = base64.standard_b64encode(jpeg_bytes).decode()
    content = [
        {"type": "text", "text": user_text},
        {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": b64}},
        {"type": "text", "text": "Respond with JSON only."},
    ]
    last_err = None
    for attempt in range(VLM_RETRY):
        try:
            resp = await client.messages.create(
                model=MODEL_NAME, max_tokens=max_tokens,
                system=system_prompt,
                messages=[{"role": "user", "content": content}],
            )
            text = "".join(b.text for b in resp.content if hasattr(b, "text") and b.text).strip()
            if not text:
                raise ValueError("empty")
            return text
        except Exception as e:
            last_err = e
            if attempt < VLM_RETRY - 1:
                await asyncio.sleep(VLM_RETRY_SLEEP)
    raise RuntimeError(f"Claude vision 失败: {last_err}")


# =========================
# 点击验证
# =========================

CLICK_VERIFY_PROMPT = """BEFORE/AFTER screenshots of a click.

Return JSON:
{
  "success": true|false,
  "confidence": 0.0-1.0,
  "reason": "short",
  "active_app": "app name"
}

success=true only if AFTER shows meaningful change. JSON only."""


def verify_after_click(before_jpeg: bytes, after_jpeg: bytes,
                       target: Optional[str] = None) -> Dict[str, Any]:
    try:
        client = _get_claude_client()
        b1 = base64.standard_b64encode(before_jpeg).decode()
        b2 = base64.standard_b64encode(after_jpeg).decode()
        content = [
            {"type": "text", "text": f"TARGET: {target or ''}\nACTION: click"},
            {"type": "text", "text": "BEFORE:"},
            {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": b1}},
            {"type": "text", "text": "AFTER:"},
            {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": b2}},
            {"type": "text", "text": "JSON only."},
        ]
        for _ in range(VLM_RETRY):
            try:
                resp = client.messages.create(
                    model=MODEL_NAME, max_tokens=220,
                    system=CLICK_VERIFY_PROMPT,
                    messages=[{"role": "user", "content": content}],
                )
                text = "".join(b.text for b in resp.content if hasattr(b, "text") and b.text).strip()
                raw = _extract_json_from_text(text)
                return {
                    "success": bool(raw.get("success", False)),
                    "confidence": float(raw.get("confidence") or 0.0),
                    "reason": str(raw.get("reason") or "").strip(),
                    "active_app": str(raw.get("active_app") or "").strip(),
                    "method": "claude_vlm",
                }
            except Exception:
                time.sleep(VLM_RETRY_SLEEP)
        raise RuntimeError("vlm failed")
    except Exception as e:
        # 像素差兜底
        try:
            before = Image.open(io.BytesIO(before_jpeg)).convert("RGB")
            after = Image.open(io.BytesIO(after_jpeg)).convert("RGB")
            if before.size != after.size:
                after = after.resize(before.size)
            diff = 0
            step = max(1, min(before.size) // 60)
            bp, ap = before.load(), after.load()
            cnt = 0
            for y in range(0, before.size[1], step):
                for x in range(0, before.size[0], step):
                    br, bg, bb = bp[x, y]
                    ar, ag, ab = ap[x, y]
                    diff += abs(br - ar) + abs(bg - ag) + abs(bb - ab)
                    cnt += 1
            score = diff / max(1, cnt * 765)
            return {
                "success": score > 0.015,
                "confidence": min(1.0, score * 8),
                "reason": f"pixel_diff (claude err: {e})",
                "method": "pixel_diff",
                "active_app": "",
            }
        except Exception as e2:
            return {"success": False, "confidence": 0.0,
                    "reason": f"all_failed: {e} / {e2}",
                    "method": "none", "active_app": ""}


# =========================
# 记忆
# =========================

def load_memory() -> dict:
    if not _MEMORY_FILE.exists():
        return {}
    try:
        return json.loads(_MEMORY_FILE.read_text())
    except Exception:
        return {}


def save_memory(m: dict):
    _MEMORY_FILE.write_text(json.dumps(m, indent=2, ensure_ascii=False))


def _canonical_key(target: str) -> str:
    s = (target or "").strip().lower()
    for k in APP_ALIASES:
        if k in s:
            return k
    return s


def remember_click_success(target: str, x: int, y: int):
    if not target:
        return
    sw, sh = get_screen_size()
    if sw <= 0:
        return
    m = load_memory()
    key = _canonical_key(target)
    priors = m.get("_qpg_priors", {})
    arr = priors.get(key, [])
    entry = {
        "norm_x": round(x / sw, 6),
        "norm_y": round(y / sh, 6),
        "screen_w": sw, "screen_h": sh,
        "last_success": _dt.datetime.now().isoformat(timespec="seconds"),
        "count": 1,
    }
    merged = False
    for old in arr:
        if (abs(old.get("norm_x", 0) - entry["norm_x"]) < 0.03 and
                abs(old.get("norm_y", 0) - entry["norm_y"]) < 0.03):
            old.update(entry)
            old["count"] = int(old.get("count", 0)) + 1
            merged = True
            break
    if not merged:
        arr.append(entry)
    arr = sorted(arr, key=lambda x: int(x.get("count", 0)), reverse=True)[:8]
    priors[key] = arr
    m["_qpg_priors"] = priors
    save_memory(m)


def log_op(payload: dict):
    line = dict(payload)
    line["time"] = _dt.datetime.now().isoformat(timespec="seconds")
    with _OP_LOG.open("a") as f:
        f.write(json.dumps(line, ensure_ascii=False) + "\n")


# =========================================================================
# =========================================================================
# QPG v3.0 — 满屏 1000 格,Claude 主动驱动 zoom
# =========================================================================
# =========================================================================

QPG_GRID_COLS = 40
QPG_GRID_ROWS = 25
QPG_TOTAL_IDS = QPG_GRID_COLS * QPG_GRID_ROWS  # 1000

QPG_ZOOM_HALF = 3  # zoom 时取 ±3 格,即 7×7=49 格

QPG_PARALLEL_N = 3
QPG_CONFIDENCE_THRESHOLD = 0.75
QPG_RACE_TIMEOUT = 15.0

QPG_OVERVIEW_IMG_MAX_WIDTH = 2400  # 满屏图发送上限
QPG_ZOOM_IMG_WIDTH = 1600          # zoom 图宽度


# ── 坐标表:每台电脑启动时算一次 ──────────────────────────

_QPG_COORDS: Dict[int, Tuple[int, int]] = {}  # id -> (logical x, logical y)


def qpg_build_coordinate_table() -> Dict[int, Tuple[int, int]]:
    """屏幕 → 1000 个格子,每个 ID 对应格子中心的逻辑坐标"""
    global _QPG_COORDS
    sw, sh = get_screen_size()
    cw = sw / QPG_GRID_COLS
    ch = sh / QPG_GRID_ROWS
    _QPG_COORDS.clear()
    for r in range(QPG_GRID_ROWS):
        for c in range(QPG_GRID_COLS):
            idx = r * QPG_GRID_COLS + c + 1  # 1-1000
            cx = int(round((c + 0.5) * cw))
            cy = int(round((r + 0.5) * ch))
            _QPG_COORDS[idx] = (cx, cy)
    return _QPG_COORDS


def qpg_id_to_coord(idx: int) -> Tuple[int, int]:
    if not _QPG_COORDS:
        qpg_build_coordinate_table()
    return _QPG_COORDS.get(idx, (0, 0))


def qpg_id_to_rc(idx: int) -> Tuple[int, int]:
    """ID -> (row, col),0-based"""
    idx0 = idx - 1
    return idx0 // QPG_GRID_COLS, idx0 % QPG_GRID_COLS


def qpg_rc_to_id(r: int, c: int) -> int:
    return r * QPG_GRID_COLS + c + 1


# ── HOME ────────────────────────────────────────────────

def qpg_get_home() -> Dict[str, int]:
    sw, sh = get_screen_size()
    env_x = os.getenv("QPG_HOME_X", "").strip()
    env_y = os.getenv("QPG_HOME_Y", "").strip()
    try:
        if env_x and env_y:
            return {"x": max(2, min(sw - 2, int(env_x))),
                    "y": max(2, min(sh - 2, int(env_y)))}
    except Exception:
        pass
    return {"x": sw // 2, "y": sh // 2}


def qpg_move_to_home(duration: float = 0.08):
    home = qpg_get_home()
    move_cursor_to(home["x"], home["y"], duration=duration)
    time.sleep(0.02)
    return home


# ── 渲染:满屏网格 ───────────────────────────────────────

def qpg_render_overview(screen_img: Image.Image) -> Image.Image:
    """
    在全屏截图上画 40×25=1000 个格子。
    编号小字放在每个格子左上角,不挡内容。
    每 5 行/5 列加粗网格线(方便 Claude 定位)。
    """
    out = screen_img.copy()
    if out.mode != "RGB":
        out = out.convert("RGB")
    draw = ImageDraw.Draw(out)

    w, h = out.size  # 物理像素
    cw = w / QPG_GRID_COLS
    ch = h / QPG_GRID_ROWS

    # 细网格线(半透明效果:细线浅色)
    for c in range(1, QPG_GRID_COLS):
        x = int(c * cw)
        color = (255, 200, 50) if c % 5 == 0 else (120, 255, 120)
        width = 2 if c % 5 == 0 else 1
        draw.line([(x, 0), (x, h)], fill=color, width=width)
    for r in range(1, QPG_GRID_ROWS):
        y = int(r * ch)
        color = (255, 200, 50) if r % 5 == 0 else (120, 255, 120)
        width = 2 if r % 5 == 0 else 1
        draw.line([(0, y), (w, y)], fill=color, width=width)

    # 编号 - 小字,不挡图标
    font_size = max(12, int(min(cw, ch) / 4))
    font = try_load_font(font_size)

    for r in range(QPG_GRID_ROWS):
        for c in range(QPG_GRID_COLS):
            idx = qpg_rc_to_id(r, c)
            # 位置:格子左上角小标签
            lx = int(c * cw + 2)
            ly = int(r * ch + 1)

            num_str = str(idx)
            tb = draw.textbbox((0, 0), num_str, font=font)
            tw = tb[2] - tb[0]
            th = tb[3] - tb[1]

            # 黄底黑字
            draw.rectangle(
                [lx, ly, lx + tw + 4, ly + th + 2],
                fill=(255, 235, 50),
            )
            draw.text((lx + 2, ly), num_str, fill=(0, 0, 0), font=font)

    return out


# ── 渲染:zoom 到一个中心 ID 周围 ─────────────────────────

def qpg_render_zoom(screen_img: Image.Image, center_id: int,
                    half: int = QPG_ZOOM_HALF) -> Tuple[Image.Image, List[int]]:
    """
    围绕 center_id 取 ±half 格,裁出那片区域,放大,画格子 + 编号。
    返回 (放大图, 该区域所有 ID 列表)
    """
    if not (1 <= center_id <= QPG_TOTAL_IDS):
        center_id = QPG_TOTAL_IDS // 2

    cr, cc = qpg_id_to_rc(center_id)
    r0 = max(0, cr - half)
    r1 = min(QPG_GRID_ROWS - 1, cr + half)
    c0 = max(0, cc - half)
    c1 = min(QPG_GRID_COLS - 1, cc + half)

    sw, sh = get_screen_size()
    cw = sw / QPG_GRID_COLS
    ch = sh / QPG_GRID_ROWS

    # 逻辑坐标的裁图区域
    log_x = c0 * cw
    log_y = r0 * ch
    log_w = (c1 - c0 + 1) * cw
    log_h = (r1 - r0 + 1) * ch

    sc = _scale()
    # 物理坐标
    phys_x = int(round(log_x * sc))
    phys_y = int(round(log_y * sc))
    phys_w = int(round(log_w * sc))
    phys_h = int(round(log_h * sc))

    crop = screen_img.crop((phys_x, phys_y, phys_x + phys_w, phys_y + phys_h))
    if crop.mode != "RGB":
        crop = crop.convert("RGB")

    # 放大到 zoom 图宽度
    orig_w, orig_h = crop.size
    if orig_w < QPG_ZOOM_IMG_WIDTH:
        zoom = QPG_ZOOM_IMG_WIDTH / orig_w
        new_w = QPG_ZOOM_IMG_WIDTH
        new_h = int(orig_h * zoom)
        zoomed = crop.resize((new_w, new_h), Image.LANCZOS)
    else:
        zoomed = crop
        zoom = 1.0

    zw, zh = zoomed.size
    draw = ImageDraw.Draw(zoomed)

    # 计算每个格子在放大图上的尺寸
    n_cols = c1 - c0 + 1
    n_rows = r1 - r0 + 1
    gw = zw / n_cols
    gh = zh / n_rows

    font_size = max(18, int(min(gw, gh) / 4))
    font = try_load_font(font_size)

    # 画格子线
    for i in range(1, n_cols):
        x = int(i * gw)
        draw.line([(x, 0), (x, zh)], fill=(0, 255, 120), width=2)
    for i in range(1, n_rows):
        y = int(i * gh)
        draw.line([(0, y), (zw, y)], fill=(0, 255, 120), width=2)

    # 画编号(这些 ID 用 overview 里的原 ID,不是新编号)
    ids_in_zoom = []
    for r in range(r0, r1 + 1):
        for c in range(c0, c1 + 1):
            idx = qpg_rc_to_id(r, c)
            ids_in_zoom.append(idx)
            # 在放大图里的局部坐标
            local_r = r - r0
            local_c = c - c0
            lx = int(local_c * gw + 4)
            ly = int(local_r * gh + 2)
            num_str = str(idx)
            tb = draw.textbbox((0, 0), num_str, font=font)
            tw = tb[2] - tb[0]
            th = tb[3] - tb[1]
            draw.rectangle(
                [lx, ly, lx + tw + 6, ly + th + 4],
                fill=(255, 235, 50),
                outline=(0, 0, 0), width=1,
            )
            draw.text((lx + 3, ly + 1), num_str, fill=(0, 0, 0), font=font)

    # 高亮中心 ID:红圈
    if center_id in ids_in_zoom:
        lr = cr - r0
        lc = cc - c0
        cx = int((lc + 0.5) * gw)
        cy = int((lr + 0.5) * gh)
        rr = int(min(gw, gh) * 0.35)
        draw.ellipse(
            (cx - rr, cy - rr, cx + rr, cy + rr),
            outline=(255, 60, 60), width=3,
        )

    return zoomed, ids_in_zoom


# ── Prompt ──────────────────────────────────────────────

QPG_OVERVIEW_PROMPT = """You see a full screenshot of the user's entire screen with a grid overlay.

The grid is 40 columns × 25 rows = 1000 cells, each cell has a unique ID number (1 to 1000).
Cell IDs increase left-to-right, top-to-bottom. ID 1 is top-left, ID 1000 is bottom-right.

Your job: find where the TARGET is, and decide what to do.

Return strict JSON, choose ONE of two actions:

Option A — If you can see the target clearly enough to click right now:
{
  "action": "click",
  "target_id": <integer 1-1000>,
  "confidence": 0.0-1.0,
  "reason": "what's at that cell"
}

Option B — If the target is visible but you want a closer look before committing:
{
  "action": "zoom",
  "center_id": <integer 1-1000>,
  "confidence": 0.0-1.0,
  "reason": "why you want to zoom here"
}

Rules:
- Pick "click" when you are sure of the exact cell. Pick "zoom" if you need to see details.
- For small/dense icons (like Dock apps), prefer "zoom" first.
- JSON only.
"""


QPG_ZOOM_PROMPT = """You see a zoomed-in view of part of the user's screen.

The grid cells are the SAME cells (and same ID numbers) as the full screen — you are now seeing a small region at higher resolution. The center cell is highlighted with a RED circle.

Your job: pick the EXACT cell ID where the target's clickable center is.

Return strict JSON:
{
  "action": "click",
  "target_id": <integer, must be one of the visible IDs>,
  "confidence": 0.0-1.0,
  "reason": "what's at that cell"
}

Rules:
- target_id must be one of the cells visible in this zoomed view
- Pick the single cell most precisely at the center of the clickable target
- JSON only.
"""


# ── 并行竞速(看图 → 选 action + ID) ─────────────────────

async def qpg_race_decide(system_prompt: str,
                          user_text: str,
                          jpeg: bytes,
                          n_parallel: int,
                          valid_ids: Optional[List[int]] = None) -> Dict[str, Any]:
    """
    并行 N 个 Claude,每个返回 {action, target_id/center_id, confidence, reason}
    首个 confidence >= threshold 的赢。
    """
    async def one_call(tag: int) -> Dict[str, Any]:
        t0 = time.time()
        text = await _call_claude_vision_async(system_prompt, user_text, jpeg, max_tokens=220)
        raw = _extract_json_from_text(text)
        elapsed = time.time() - t0

        action = str(raw.get("action") or "").strip().lower()
        if action not in ("click", "zoom"):
            action = "click"

        # 提取 ID(click -> target_id, zoom -> center_id)
        key = "target_id" if action == "click" else "center_id"
        raw_id = raw.get(key)
        idx = _safe_int(raw_id, 1, QPG_TOTAL_IDS)

        # 如果是 zoom 后的 race,还要验证 ID 在可见区域内
        if valid_ids and idx and idx not in valid_ids:
            # 尝试 fallback:从 reason 里再提一次
            reason_text = str(raw.get("reason") or "")
            m = _re.search(r"\d+", reason_text)
            if m:
                idx2 = _safe_int(m.group(), 1, QPG_TOTAL_IDS)
                if idx2 in valid_ids:
                    idx = idx2

        return {
            "tag": tag,
            "elapsed": elapsed,
            "action": action,
            "id": idx,
            "confidence": float(raw.get("confidence") or 0.0),
            "reason": str(raw.get("reason") or ""),
        }

    tasks = [asyncio.create_task(one_call(i + 1)) for i in range(n_parallel)]
    winner = None
    all_results = []

    try:
        while tasks:
            done, pending = await asyncio.wait(
                tasks, return_when=asyncio.FIRST_COMPLETED,
                timeout=QPG_RACE_TIMEOUT,
            )
            if not done:
                for t in pending:
                    t.cancel()
                break
            for t in done:
                try:
                    result = t.result()
                    all_results.append(result)
                    if (result.get("id") and
                            result.get("confidence", 0.0) >= QPG_CONFIDENCE_THRESHOLD):
                        winner = result
                        break
                except Exception as e:
                    all_results.append({"tag": -1, "error": str(e)})
            if winner:
                for t in pending:
                    t.cancel()
                break
            tasks = list(pending)
    finally:
        for t in tasks:
            if not t.done():
                t.cancel()

    if not winner and all_results:
        valid = [r for r in all_results if r.get("id")]
        if valid:
            valid.sort(key=lambda x: x.get("confidence", 0.0), reverse=True)
            winner = valid[0]
            winner["fallback_best_of_n"] = True

    return {
        "ok": winner is not None,
        "winner": winner,
        "all_results": all_results,
        "n_parallel": n_parallel,
    }


# ── 主流程 ──────────────────────────────────────────────

async def navigate_qpg(target: str,
                       do_click: bool = True,
                       save_debug: bool = True,
                       use_system_open: bool = True,
                       n_parallel: int = QPG_PARALLEL_N,
                       max_zoom_rounds: int = 1) -> Dict[str, Any]:
    """
    v3.0 主入口:
      1. (可选) 系统 open -a
      2. HOME
      3. 满屏网格 → Claude(并行竞速)→ click 或 zoom
      4. 如果 zoom:放大那片 → Claude(并行)→ click
      5. 执行点击 + 验证
    """
    t0 = time.time()
    logs: List[Dict[str, Any]] = []

    sw, sh = get_screen_size()
    home = qpg_get_home()
    qpg_build_coordinate_table()
    logs.append({
        "stage": "init",
        "data": {
            "screen": {"w": sw, "h": sh},
            "home": home,
            "grid": f"{QPG_GRID_COLS}x{QPG_GRID_ROWS}={QPG_TOTAL_IDS}",
        },
    })

    # 1. 系统兜底
    if use_system_open and ENABLE_SYSTEM_OPEN:
        sys_res = try_system_open(target)
        logs.append({"stage": "system_open", "data": sys_res})
        if sys_res.get("ok"):
            duration = round(time.time() - t0, 2)
            log_op({
                "target": target, "mode": "qpg_system_open",
                "success": True, "duration_s": duration,
                "active_app": sys_res.get("active_app"),
            })
            return {
                "ok": True, "mode": "qpg_system_open",
                "target": target,
                "method": sys_res.get("method"),
                "active_app": sys_res.get("active_app"),
                "duration_s": duration,
                "logs": logs,
            }

    # 2. HOME
    qpg_move_to_home(duration=0.08)

    # 3. 满屏网格
    screen_img = capture_screen_pil()
    overview = qpg_render_overview(screen_img)
    if save_debug:
        save_image(overview, f"{now_ts()}_qpg_overview.jpg")

    overview_jpeg = pil_to_jpeg_bytes(overview, max_dim=QPG_OVERVIEW_IMG_MAX_WIDTH, quality=88)

    user_text = (
        f"TARGET: {target}\n"
        f"Screen is {sw}x{sh} pixels. Find the target and decide: click now or zoom first."
    )

    overview_race = await qpg_race_decide(
        system_prompt=QPG_OVERVIEW_PROMPT,
        user_text=user_text,
        jpeg=overview_jpeg,
        n_parallel=n_parallel,
        valid_ids=None,
    )
    logs.append({"stage": "overview_race", "data": overview_race})

    if not overview_race.get("ok"):
        duration = round(time.time() - t0, 2)
        log_op({"target": target, "mode": "qpg",
                "success": False, "reason": "overview_race_failed",
                "duration_s": duration})
        return {
            "ok": False, "mode": "qpg", "target": target,
            "reason": "overview_race_failed",
            "duration_s": duration,
            "logs": logs,
        }

    winner = overview_race["winner"]
    final_id: Optional[int] = None
    zoom_rounds = 0

    if winner.get("action") == "click":
        # Claude 说满屏就够了
        final_id = winner.get("id")
    else:
        # Claude 要求 zoom
        current_center = winner.get("id")
        for zoom_idx in range(max_zoom_rounds):
            if not current_center:
                break

            zoom_img, ids_in_zoom = qpg_render_zoom(screen_img, current_center)
            if save_debug:
                save_image(zoom_img, f"{now_ts()}_qpg_zoom_{zoom_idx+1}_c{current_center}.jpg")

            zoom_jpeg = pil_to_jpeg_bytes(zoom_img, max_dim=1800, quality=90)
            zoom_user = (
                f"TARGET: {target}\n"
                f"The red circle is on cell #{current_center}. "
                f"Pick the exact cell where the clickable target is."
            )

            zoom_race = await qpg_race_decide(
                system_prompt=QPG_ZOOM_PROMPT,
                user_text=zoom_user,
                jpeg=zoom_jpeg,
                n_parallel=n_parallel,
                valid_ids=ids_in_zoom,
            )
            logs.append({
                "stage": f"zoom_{zoom_idx+1}_race",
                "data": {
                    "center_id": current_center,
                    "ids_in_zoom": ids_in_zoom[:5] + ["..."] if len(ids_in_zoom) > 5 else ids_in_zoom,
                    "race": zoom_race,
                },
            })

            zoom_rounds += 1

            if not zoom_race.get("ok"):
                break

            zw = zoom_race["winner"]
            final_id = zw.get("id")
            # 目前只做 1 轮 zoom,直接用
            break

    if not final_id or not (1 <= final_id <= QPG_TOTAL_IDS):
        duration = round(time.time() - t0, 2)
        log_op({"target": target, "mode": "qpg",
                "success": False, "reason": "no_final_id",
                "duration_s": duration})
        return {
            "ok": False, "mode": "qpg", "target": target,
            "reason": "no_final_id",
            "duration_s": duration,
            "logs": logs,
        }

    final_x, final_y = qpg_id_to_coord(final_id)
    logs.append({
        "stage": "final_decision",
        "data": {
            "id": final_id,
            "x": final_x, "y": final_y,
            "zoom_rounds": zoom_rounds,
        },
    })

    # 4. 点击
    qpg_move_to_home(duration=0.05)
    move_cursor_to(final_x, final_y, duration=0.12)
    time.sleep(0.04)

    click_report = None
    success = True
    if do_click:
        before = capture_screen_pil()
        before_jpeg = pil_to_jpeg_bytes(before, max_dim=1024, quality=82)
        click_mouse(button="left", clicks=1, interval=0.1)
        time.sleep(DEFAULT_CLICK_SETTLE)
        after = capture_screen_pil()
        after_jpeg = pil_to_jpeg_bytes(after, max_dim=1024, quality=82)
        verify = verify_after_click(before_jpeg, after_jpeg, target=target)
        click_report = {"clicked": True, "verify": verify}
        success = bool(verify.get("success", False))

    if success:
        try:
            remember_click_success(target, final_x, final_y)
        except Exception:
            pass

    duration = round(time.time() - t0, 2)
    log_op({
        "target": target, "mode": "qpg",
        "success": success,
        "final_id": final_id,
        "final_point": {"x": final_x, "y": final_y},
        "zoom_rounds": zoom_rounds,
        "duration_s": duration,
    })

    return {
        "ok": success,
        "mode": "qpg",
        "target": target,
        "final_id": final_id,
        "final_point": {"x": final_x, "y": final_y},
        "zoom_rounds": zoom_rounds,
        "home": home,
        "click": click_report,
        "duration_s": duration,
        "n_parallel": n_parallel,
        "logs": logs,
    }


# =========================
# FastAPI
# =========================

app = FastAPI(title="Adu Cursor QPG Server", version="6.0.0-qpg-driven")


class QPGClickRequest(BaseModel):
    target: str
    do_click: bool = True
    save_debug: bool = True
    use_system_open: bool = True
    max_zoom_rounds: int = Field(default=1, ge=0, le=2)
    n_parallel: int = Field(default=QPG_PARALLEL_N, ge=1, le=10)


@app.get("/health")
def health():
    try:
        sw, sh = get_screen_size()
    except Exception as e:
        return {"ok": False, "error": str(e)}
    try:
        full = capture_screen_pil()
        phys_w, phys_h = full.size
        sc = _scale()
    except Exception:
        phys_w, phys_h, sc = 0, 0, 0
    return {
        "ok": True,
        "service": "adu_cursor_qpg_driven",
        "version": "6.0.0-qpg-driven",
        "model": MODEL_NAME,
        "api_key_set": bool(os.environ.get("ANTHROPIC_API_KEY")),
        "screen_logical": {"w": sw, "h": sh},
        "screen_physical": {"w": phys_w, "h": phys_h},
        "retina_scale": round(sc, 2),
        "pyautogui": pyautogui is not None,
        "qpg_grid": f"{QPG_GRID_COLS}x{QPG_GRID_ROWS}={QPG_TOTAL_IDS}",
        "qpg_zoom_half": QPG_ZOOM_HALF,
        "qpg_parallel_n": QPG_PARALLEL_N,
        "debug_dir": str(SCREENSHOT_DIR),
        "time": now_ts(),
    }


@app.post("/qpg_click")
async def api_qpg_click(req: QPGClickRequest):
    try:
        return await navigate_qpg(
            target=req.target,
            do_click=req.do_click,
            save_debug=req.save_debug,
            use_system_open=req.use_system_open,
            n_parallel=req.n_parallel,
            max_zoom_rounds=req.max_zoom_rounds,
        )
    except Exception as e:
        return {"ok": False, "error": str(e), "traceback": traceback.format_exc()}


# =========================
# CLI
# =========================

def _run_cli(args: List[str]):
    do_click = False
    no_system = False
    targets = []
    for a in args:
        if a == "--click":
            do_click = True
        elif a == "--no-system":
            no_system = True
        else:
            targets.append(a)

    target = " ".join(targets).strip() or "WeChat icon in Dock"

    print(f"\n═══ QPG v3.0 CLI (Claude-Driven) ═══")
    print(f"  target:       {target}")
    print(f"  click:        {do_click}")
    print(f"  system_open:  {not no_system}")
    print(f"  grid:         {QPG_GRID_COLS}x{QPG_GRID_ROWS}={QPG_TOTAL_IDS}")
    print(f"  parallel_n:   {QPG_PARALLEL_N}")
    print(f"═══════════════════════════════════════")
    print("\n3 秒后开始…")
    for k in range(3, 0, -1):
        print(f"  {k}…")
        time.sleep(1)

    result = asyncio.run(navigate_qpg(
        target=target,
        do_click=do_click,
        save_debug=True,
        use_system_open=not no_system,
        n_parallel=QPG_PARALLEL_N,
        max_zoom_rounds=1,
    ))

    print("\n═══ 结果 ═══")
    print(f"  ok: {result.get('ok')}")
    print(f"  mode: {result.get('mode')}")
    print(f"  耗时: {result.get('duration_s')}s")
    if result.get("method"):
        print(f"  method: {result.get('method')}  app: {result.get('active_app')}")
    else:
        print(f"  final_id: {result.get('final_id')}")
        p = result.get("final_point") or {}
        print(f"  final_point: ({p.get('x')}, {p.get('y')})")
        print(f"  zoom_rounds: {result.get('zoom_rounds')}")
        if result.get("click"):
            v = result["click"].get("verify") or {}
            print(f"  click verify: {v.get('success')}  app={v.get('active_app')}")

    print(f"\n  debug: {SCREENSHOT_DIR}")
    return 0 if result.get("ok") else 2


# =========================
# 启动
# =========================

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] in ("--cli", "-c"):
        sys.exit(_run_cli(sys.argv[2:]))

    import uvicorn

    api_set = "SET ✓" if os.environ.get("ANTHROPIC_API_KEY") else "NOT SET ✗"
    print(f"""
╔═══════════════════════════════════════════════════╗
║   Adu Cursor QPG Server v6.0 (Claude-Driven)      ║
╠═══════════════════════════════════════════════════╣
║   host:         {HOST:<35}║
║   port:         {PORT:<35}║
║   model:        {MODEL_NAME:<35}║
║   api:          {api_set:<35}║
║   grid:         {QPG_GRID_COLS}x{QPG_GRID_ROWS}={QPG_TOTAL_IDS}{'':<24}║
║   zoom_half:    ±{QPG_ZOOM_HALF}格 = 7x7 = 49 cells{'':<14}║
║   parallel_n:   {QPG_PARALLEL_N:<35}║
╚═══════════════════════════════════════════════════╝

Endpoints:
  GET  /health
  POST /qpg_click       Claude 主动驱动的点击

CLI:
  python3 {os.path.basename(__file__)} --cli "WeChat"
  python3 {os.path.basename(__file__)} --cli "WeChat" --click

启动中...
""")
    uvicorn.run(app, host=HOST, port=PORT)

