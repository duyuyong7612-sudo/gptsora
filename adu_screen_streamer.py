#!/usr/bin/env python3
# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-f793a0f38b31c92579ddbc68525737688500902a446e8a52a806e562333a72c6"
# Source-SHA256: "4e096e321b15a83e3beddb6e0d4dd208d922fdfb8b4f6a04ccf26250ddbfb3d6"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
adu_screen_streamer.py — Mac 屏幕推流
======================================
Mac 端运行，把屏幕实时推给后端，后端转给手机 App 显示。

架构：
  Mac 屏幕
    ↓ screencapture（系统原生）
  JPEG 压缩
    ↓ WebSocket
  后端 /ws/screen/push/{user_key}
    ↓ 广播
  手机 App /ws/screen/subscribe/{user_key}
    ↓
  MJPEG 显示

同时提供本地 MJPEG HTTP 服务：
  http://localhost:7788/stream  → 直接在浏览器/App 看实时画面

运行方式：
  python3 adu_screen_streamer.py

环境变量：
  BACKEND_WS_URL  = ws://127.0.0.1:8000   （后端地址）
  ADU_USER_KEY    = <your-user-key>             （必须设置）
  STREAM_FPS      = 3                           （帧率，默认3fps）
  STREAM_QUALITY  = 60                          （JPEG质量，0-100）
  STREAM_SCALE    = 0.5                         （缩放比例，0.5=半分辨率）
  MJPEG_PORT      = 7788                        （本地MJPEG端口）
"""

import asyncio
import base64
import io
import json
import logging
import os
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import List, Optional, Set

import websockets

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [Streamer] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("streamer")

# ── 配置 ──────────────────────────────────────
BACKEND_WS_URL = os.getenv("BACKEND_WS_URL", "ws://127.0.0.1:8000")
USER_KEY       = os.getenv("ADU_USER_KEY", "").strip()
FPS            = float(os.getenv("STREAM_FPS",     "3"))
QUALITY        = int(os.getenv("STREAM_QUALITY",   "60"))   # JPEG 质量
SCALE          = float(os.getenv("STREAM_SCALE",   "0.5"))  # 缩放
MJPEG_PORT     = int(os.getenv("MJPEG_PORT",       "7788"))
INTERVAL       = 1.0 / FPS   # 截图间隔（秒）


# ══════════════════════════════════════════════
# 1. 截图引擎
#    screencapture → JPEG bytes
# ══════════════════════════════════════════════

class ScreenCapture:

    def __init__(self, scale: float = 0.5, quality: int = 60):
        self.scale   = scale
        self.quality = quality
        self._tmp    = tempfile.NamedTemporaryFile(suffix=".jpg", delete=False)
        self._path   = self._tmp.name
        self._tmp.close()
        log.info(f"截图引擎初始化: scale={scale} quality={quality}")

    def capture(self) -> Optional[bytes]:
        """截取当前屏幕，返回 JPEG bytes"""
        try:
            # screencapture -x 静默截图（不发出声音）
            result = subprocess.run(
                ["screencapture", "-x", "-t", "jpg", self._path],
                timeout=2,
                capture_output=True,
            )
            if result.returncode != 0:
                return None

            with open(self._path, "rb") as f:
                raw = f.read()

            # 缩放 + 压缩
            if self.scale < 1.0 or self.quality < 95:
                raw = self._compress(raw)

            return raw

        except Exception as e:
            log.error(f"截图失败: {e}")
            return None

    def _compress(self, jpeg_bytes: bytes) -> bytes:
        """缩放 + 重新压缩"""
        try:
            from PIL import Image  # type: ignore
            img = Image.open(io.BytesIO(jpeg_bytes))

            if self.scale < 1.0:
                w = int(img.width * self.scale)
                h = int(img.height * self.scale)
                img = img.resize((w, h), Image.LANCZOS)

            buf = io.BytesIO()
            img.save(buf, format="JPEG", quality=self.quality, optimize=True)
            return buf.getvalue()
        except ImportError:
            # 没有 PIL，直接返回原始截图
            return jpeg_bytes
        except Exception:
            return jpeg_bytes

    def cleanup(self):
        try:
            os.unlink(self._path)
        except Exception:
            pass


# ══════════════════════════════════════════════
# 2. 帧缓冲
#    最新一帧供 MJPEG 服务和 WebSocket 使用
# ══════════════════════════════════════════════

class FrameBuffer:

    def __init__(self):
        self._frame:     Optional[bytes] = None
        self._timestamp: float = 0.0
        self._lock       = threading.Lock()
        self._listeners: Set[asyncio.Queue] = set()

    def update(self, frame: bytes):
        with self._lock:
            self._frame     = frame
            self._timestamp = time.time()

    def get(self) -> Optional[bytes]:
        with self._lock:
            return self._frame

    @property
    def timestamp(self) -> float:
        return self._timestamp


# ══════════════════════════════════════════════
# 3. MJPEG HTTP 服务
#    http://localhost:7788/stream
#    手机 App 和浏览器直接打开看实时画面
# ══════════════════════════════════════════════

_frame_buffer: Optional[FrameBuffer] = None

class MJPEGHandler(BaseHTTPRequestHandler):

    def log_message(self, format, *args):
        pass  # 静默 HTTP 日志

    def do_GET(self):
        if self.path == "/stream":
            self._stream()
        elif self.path == "/snapshot":
            self._snapshot()
        elif self.path == "/health":
            self._health()
        else:
            self.send_response(404)
            self.end_headers()

    def _stream(self):
        """MJPEG 流"""
        self.send_response(200)
        self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()

        last_ts = 0.0
        while True:
            try:
                frame = _frame_buffer.get() if _frame_buffer else None
                if frame and _frame_buffer.timestamp > last_ts:
                    last_ts = _frame_buffer.timestamp
                    self.wfile.write(b"--frame\r\n")
                    self.wfile.write(b"Content-Type: image/jpeg\r\n\r\n")
                    self.wfile.write(frame)
                    self.wfile.write(b"\r\n")
                    self.wfile.flush()
                else:
                    time.sleep(0.05)
            except (BrokenPipeError, ConnectionResetError):
                break
            except Exception:
                break

    def _snapshot(self):
        """单张截图"""
        frame = _frame_buffer.get() if _frame_buffer else None
        if not frame:
            self.send_response(503)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "image/jpeg")
        self.send_header("Content-Length", str(len(frame)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(frame)

    def _health(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        ts = _frame_buffer.timestamp if _frame_buffer else 0
        age = round(time.time() - ts, 2) if ts else -1
        self.wfile.write(json.dumps({
            "ok": True,
            "fps": FPS,
            "quality": QUALITY,
            "scale": SCALE,
            "last_frame_age_sec": age,
        }).encode())


def start_mjpeg_server(port: int, buf: FrameBuffer):
    """在独立线程启动 MJPEG HTTP 服务"""
    global _frame_buffer
    _frame_buffer = buf

    # 屏幕 MJPEG 流默认只给本机；要给局域网看须显式设 ADU_SCREEN_STREAM_HOST
    server = HTTPServer((os.getenv("ADU_SCREEN_STREAM_HOST", "127.0.0.1"), port), MJPEGHandler)
    log.info(f"📺 MJPEG 服务启动: http://localhost:{port}/stream")
    log.info(f"📸 快照接口: http://localhost:{port}/snapshot")

    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()
    return server


# ══════════════════════════════════════════════
# 4. WebSocket 推流
#    把帧推给后端，后端转发给手机 App
# ══════════════════════════════════════════════

async def ws_push_loop(buf: FrameBuffer):
    """WebSocket 推流主循环，自动重连"""
    ws_url = f"{BACKEND_WS_URL}/ws/screen/push/{USER_KEY}"
    log.info(f"🔗 WebSocket 推流: {ws_url}")

    reconnect_delay = 2.0

    while True:
        try:
            async with websockets.connect(
                ws_url,
                ping_interval=20,
                ping_timeout=10,
                max_size=10 * 1024 * 1024,  # 10MB
            ) as ws:
                log.info("✅ WebSocket 已连接后端")
                reconnect_delay = 2.0
                last_sent_ts = 0.0

                while True:
                    frame = buf.get()
                    if frame and buf.timestamp > last_sent_ts:
                        last_sent_ts = buf.timestamp

                        # 打包为 JSON（带 base64 图片）
                        payload = json.dumps({
                            "type":      "frame",
                            "data":      base64.b64encode(frame).decode(),
                            "timestamp": buf.timestamp,
                            "format":    "jpeg",
                        })
                        await ws.send(payload)

                    await asyncio.sleep(INTERVAL)

        except websockets.exceptions.ConnectionClosed:
            log.warning(f"WebSocket 断开，{reconnect_delay}s 后重连...")
        except OSError as e:
            log.warning(f"连接失败: {e}，{reconnect_delay}s 后重试...")
        except Exception as e:
            log.error(f"推流异常: {e}")

        await asyncio.sleep(reconnect_delay)
        reconnect_delay = min(reconnect_delay * 1.5, 30.0)


# ══════════════════════════════════════════════
# 5. 截图主循环
# ══════════════════════════════════════════════

async def capture_loop(capture: ScreenCapture, buf: FrameBuffer):
    """截图主循环：定时截图，更新帧缓冲"""
    log.info(f"📷 截图循环启动: {FPS}fps 间隔{INTERVAL:.2f}s")
    frame_count = 0
    last_log    = time.time()

    while True:
        t0    = time.time()
        frame = capture.capture()

        if frame:
            buf.update(frame)
            frame_count += 1

            # 每10秒打印一次统计
            now = time.time()
            if now - last_log >= 10:
                actual_fps = frame_count / (now - last_log)
                size_kb    = len(frame) / 1024
                log.info(f"📊 {actual_fps:.1f}fps  帧大小: {size_kb:.0f}KB")
                frame_count = 0
                last_log    = now

        # 精确控制帧率
        elapsed = time.time() - t0
        sleep   = max(0, INTERVAL - elapsed)
        await asyncio.sleep(sleep)


# ══════════════════════════════════════════════
# 6. 主入口
# ══════════════════════════════════════════════

async def main():
    if not USER_KEY:
        raise RuntimeError("Set ADU_USER_KEY before starting screen capture.")
    log.info("=" * 50)
    log.info("阿杜屏幕推流服务启动")
    log.info(f"  后端: {BACKEND_WS_URL}")
    log.info(f"  用户: {USER_KEY[:16]}...")
    log.info(f"  帧率: {FPS}fps  质量: {QUALITY}  缩放: {SCALE}")
    log.info("=" * 50)

    buf     = FrameBuffer()
    capture = ScreenCapture(scale=SCALE, quality=QUALITY)

    # 启动 MJPEG 本地服务
    start_mjpeg_server(MJPEG_PORT, buf)

    # 并行运行截图 + WebSocket 推流
    try:
        await asyncio.gather(
            capture_loop(capture, buf),
            ws_push_loop(buf),
        )
    finally:
        capture.cleanup()


if __name__ == "__main__":
    import signal

    def _stop(sig, frame):
        log.info("收到停止信号，退出...")
        raise SystemExit(0)

    signal.signal(signal.SIGINT,  _stop)
    signal.signal(signal.SIGTERM, _stop)

    try:
        asyncio.run(main())
    except SystemExit:
        log.info("推流服务已停止")
