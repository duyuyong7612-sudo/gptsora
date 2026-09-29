# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-6f60621c90401c6b3c6dbb3531c193e71d7db4edfdefccceeb15c0de3d02eaa7"
# Source-SHA256: "e026544a6120c1bd6afb4eb7a7ef6bf7061dc86de59251551550d453066eab93"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
adu_push.py — 阿杜推送模块
============================
任务完成 → 推送到用户手机
加入 server_session.py 或单独运行

依赖：
    pip install httpx apns2
    # 或者用 httpx 直接发 HTTP/2 到 APNS
"""

import json
import os
import sqlite3
import time
import httpx
import asyncio
import logging
from datetime import datetime, timezone

log = logging.getLogger("adu_push")

DB_PATH = os.getenv("TASK_DB_PATH", "./adu_tasks.db")

# APNS 配置
APNS_KEY_ID      = os.getenv("APNS_KEY_ID", "")        # Apple Key ID
APNS_TEAM_ID     = os.getenv("APNS_TEAM_ID", "")       # Apple Team ID  
APNS_BUNDLE_ID   = os.getenv("APNS_BUNDLE_ID", "com.yourapp.chatagi")
APNS_KEY_PATH    = os.getenv("APNS_KEY_PATH", "./AuthKey.p8")
APNS_PRODUCTION  = os.getenv("APNS_PRODUCTION", "0") == "1"

APNS_HOST = "api.push.apple.com" if APNS_PRODUCTION else "api.sandbox.push.apple.com"

# ══════════════════════════════════════════════════════════════════
# Token 存储
# ══════════════════════════════════════════════════════════════════

def init_push_db():
    conn = sqlite3.connect(DB_PATH)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS push_tokens (
            user_id      TEXT PRIMARY KEY,
            device_token TEXT NOT NULL,
            platform     TEXT DEFAULT 'ios',
            updated_at   TEXT
        )
    """)
    conn.commit()
    conn.close()

init_push_db()

def save_token(user_id: str, device_token: str, platform: str = "ios"):
    conn = sqlite3.connect(DB_PATH)
    conn.execute("""
        INSERT OR REPLACE INTO push_tokens (user_id, device_token, platform, updated_at)
        VALUES (?, ?, ?, ?)
    """, (user_id, device_token, platform, datetime.now(timezone.utc).isoformat()))
    conn.commit()
    conn.close()
    log.info(f"[Push] Token已保存: {user_id} → {device_token[:8]}...")

def get_token(user_id: str) -> str | None:
    conn = sqlite3.connect(DB_PATH)
    cur = conn.execute("SELECT device_token FROM push_tokens WHERE user_id = ?", (user_id,))
    row = cur.fetchone()
    conn.close()
    return row[0] if row else None

# ══════════════════════════════════════════════════════════════════
# JWT 生成（APNS Token-Based Auth）
# ══════════════════════════════════════════════════════════════════

_jwt_cache: dict = {}  # {"token": ..., "issued_at": ...}

def _get_apns_jwt() -> str:
    """生成或复用 APNS JWT（有效期1小时，提前5分钟刷新）"""
    now = time.time()
    cached = _jwt_cache.get("token")
    issued = _jwt_cache.get("issued_at", 0)

    if cached and (now - issued) < 3300:  # 55分钟内复用
        return cached

    try:
        import jwt as pyjwt  # pip install PyJWT
        with open(APNS_KEY_PATH, "r") as f:
            key = f.read()

        token = pyjwt.encode(
            {"iss": APNS_TEAM_ID, "iat": int(now)},
            key,
            algorithm="ES256",
            headers={"kid": APNS_KEY_ID},
        )
        _jwt_cache["token"] = token
        _jwt_cache["issued_at"] = now
        return token
    except Exception as e:
        log.error(f"[Push] JWT生成失败: {e}")
        return ""

# ══════════════════════════════════════════════════════════════════
# 发送推送
# ══════════════════════════════════════════════════════════════════

async def send_push(device_token: str, title: str, body: str,
                    data: dict = None, badge: int = 1) -> bool:
    """
    发送 APNS 推送通知

    如果 APNS 配置不完整，降级为本地日志（开发模式）
    """
    if not all([APNS_KEY_ID, APNS_TEAM_ID, APNS_KEY_PATH]):
        # 开发模式：打印日志
        log.info(f"[Push:DEV] → {title}: {body}")
        return True

    jwt_token = _get_apns_jwt()
    if not jwt_token:
        return False

    payload = {
        "aps": {
            "alert": {"title": title, "body": body},
            "sound": "default",
            "badge": badge,
        }
    }
    if data:
        payload.update(data)

    url = f"https://{APNS_HOST}/3/device/{device_token}"
    headers = {
        "authorization": f"bearer {jwt_token}",
        "apns-topic": APNS_BUNDLE_ID,
        "apns-push-type": "alert",
        "apns-priority": "10",
    }

    try:
        async with httpx.AsyncClient(http2=True) as client:
            r = await client.post(url, json=payload, headers=headers, timeout=10.0)
            if r.status_code == 200:
                log.info(f"[Push] ✅ 发送成功: {title}")
                return True
            else:
                log.warning(f"[Push] ❌ APNS错误 {r.status_code}: {r.text}")
                return False
    except Exception as e:
        log.error(f"[Push] 发送异常: {e}")
        return False

async def push_to_user(user_id: str, title: str, body: str,
                       data: dict = None, urgent: bool = False) -> bool:
    """根据 user_id 查token并推送"""
    token = get_token(user_id)
    if not token:
        log.debug(f"[Push] 用户 {user_id} 没有注册token，跳过推送")
        # 开发阶段：没有token也打印出来
        log.info(f"[Push:NO_TOKEN] {title}: {body}")
        return False
    return await send_push(token, title, body, data)

# ══════════════════════════════════════════════════════════════════
# FastAPI 路由（加入 server_session.py）
# ══════════════════════════════════════════════════════════════════

from fastapi import APIRouter
from pydantic import BaseModel
from typing import Optional

push_router = APIRouter(prefix="", tags=["push"])

class PushRegisterBody(BaseModel):
    user_id: str
    device_token: str
    platform: str = "ios"

class PushSendBody(BaseModel):
    user_id: str
    notification: dict          # {"title": ..., "body": ...}
    data: Optional[dict] = None
    priority: str = "normal"

@push_router.post("/push/register")
async def register_push_token(body: PushRegisterBody):
    """iOS App启动时注册推送Token"""
    save_token(body.user_id, body.device_token, body.platform)
    return {"status": "ok", "message": "阿杜记住你的手机了"}

@push_router.post("/push/send")
async def send_push_notification(body: PushSendBody):
    """adu_loop 任务完成时调用"""
    title = body.notification.get("title", "阿杜")
    msg   = body.notification.get("body", "")

    success = await push_to_user(body.user_id, title, msg, body.data)
    return {"status": "sent" if success else "no_token", "title": title}

@push_router.get("/push/test/{user_id}")
async def test_push(user_id: str):
    """测试推送是否工作"""
    success = await push_to_user(
        user_id,
        title="阿杜测试推送",
        body="如果你看到这条消息，推送链路已经通了 ✅",
    )
    return {"status": "ok" if success else "failed"}
