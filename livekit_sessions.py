# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-c5e79d0467de7f340e92711f75fd1616379ae9055a834c1ceee2571973263e42"
# Source-SHA256: "5f8725e1ed03895d7a1beecedc54d8cadb6ec6c25ea0064d79ccdfa7ea7a0c82"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""LiveKit session/token helpers for Adu commercial front/back split.

Only the backend reads LIVEKIT_API_SECRET. The desktop/web frontend receives a
short-lived LiveKit JWT and never stores the API secret.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import time
from typing import Any


def _b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def _clean_name(value: str, fallback: str) -> str:
    value = (value or "").strip()
    if not value:
        return fallback
    value = re.sub(r"[^a-zA-Z0-9_.:-]+", "-", value)
    return value[:96] or fallback


def _truthy_env(name: str, default: str = "0") -> bool:
    return os.environ.get(name, default).strip().lower() not in ("0", "false", "off", "no", "")


def _agent_name() -> str:
    return os.environ.get("LIVEKIT_AGENT_NAME", "adu-three-stage-agent").strip() or "adu-three-stage-agent"


def livekit_status() -> dict[str, Any]:
    url = os.environ.get("LIVEKIT_URL", "").strip()
    key = os.environ.get("LIVEKIT_API_KEY", "").strip()
    secret = os.environ.get("LIVEKIT_API_SECRET", "").strip()
    return {
        "configured": bool(url and key and secret),
        "url": url,
        "api_key_hint": (key[:4] + "..." + key[-4:]) if len(key) > 8 else ("set" if key else ""),
        "secret_set": bool(secret),
        "token_ttl_s": int(os.environ.get("LIVEKIT_TOKEN_TTL_S", "600") or 600),
        "agent_name": _agent_name(),
        "auto_dispatch": _truthy_env("LIVEKIT_AUTO_DISPATCH_AGENT", "1"),
    }


def _sign_jwt(payload: dict[str, Any], api_secret: str) -> str:
    header = {"alg": "HS256", "typ": "JWT"}
    head = _b64url(json.dumps(header, separators=(",", ":")).encode("utf-8"))
    body = _b64url(json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8"))
    signing_input = f"{head}.{body}".encode("ascii")
    sig = _b64url(hmac.new(api_secret.encode("utf-8"), signing_input, hashlib.sha256).digest())
    return f"{head}.{body}.{sig}"


def mint_livekit_token(
    *,
    room: str,
    identity: str,
    name: str = "Adu Voice Frontend",
    ttl_s: int | None = None,
    metadata: dict[str, Any] | None = None,
) -> tuple[str, int]:
    api_key = os.environ.get("LIVEKIT_API_KEY", "").strip()
    api_secret = os.environ.get("LIVEKIT_API_SECRET", "").strip()
    if not api_key or not api_secret:
        raise RuntimeError("LIVEKIT_API_KEY/LIVEKIT_API_SECRET is not configured on backend")

    now = int(time.time())
    ttl = int(ttl_s or os.environ.get("LIVEKIT_TOKEN_TTL_S", "600") or 600)
    exp = now + max(60, min(ttl, 3600))
    payload: dict[str, Any] = {
        "iss": api_key,
        "sub": identity,
        "name": name,
        "nbf": now - 5,
        "exp": exp,
        "video": {
            "room": room,
            "roomJoin": True,
            "canPublish": True,
            "canSubscribe": True,
            "canPublishData": True,
            "canUpdateOwnMetadata": True,
        },
        "metadata": json.dumps(metadata or {}, ensure_ascii=False, separators=(",", ":")),
    }
    return _sign_jwt(payload, api_secret), exp


async def dispatch_livekit_agent(room: str, metadata: dict[str, Any] | None = None) -> dict[str, Any]:
    """Ask LiveKit Cloud to attach the named Adu worker to this room.

    The session endpoint must stay usable even when the worker package is not
    installed locally yet, so dispatch failures are returned as metadata instead
    of breaking token minting.
    """
    if not _truthy_env("LIVEKIT_AUTO_DISPATCH_AGENT", "1"):
        return {"ok": False, "skipped": True, "reason": "LIVEKIT_AUTO_DISPATCH_AGENT=0"}
    try:
        from livekit import api  # type: ignore
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "skipped": True, "reason": f"livekit api unavailable: {exc}"}

    agent_name = _agent_name()
    try:
        request = api.CreateAgentDispatchRequest(
            agent_name=agent_name,
            room=room,
            metadata=json.dumps(metadata or {}, ensure_ascii=False, separators=(",", ":")),
        )
        async with api.LiveKitAPI() as lkapi:
            dispatch = await lkapi.agent_dispatch.create_dispatch(request)
        return {
            "ok": True,
            "agent_name": agent_name,
            "room": room,
            "dispatch_id": getattr(dispatch, "id", ""),
        }
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "agent_name": agent_name, "room": room, "error": str(exc)}


def create_realtime_session(payload: dict[str, Any] | None = None) -> dict[str, Any]:
    payload = payload or {}
    status = livekit_status()
    if not status["configured"]:
        raise RuntimeError("LiveKit backend env is incomplete")

    room = _clean_name(str(payload.get("room") or ""), f"adu-{secrets.token_urlsafe(8)}")
    identity = _clean_name(str(payload.get("identity") or ""), f"adu-client-{secrets.token_urlsafe(6)}")
    ttl_s = int(payload.get("ttl_s") or status["token_ttl_s"])
    token, expires_at = mint_livekit_token(
        room=room,
        identity=identity,
        ttl_s=ttl_s,
        metadata={
            "app": "adu-three-stage-v2",
            "transport": "livekit-webrtc",
            "client": payload.get("client") or "desktop-voice-ball",
        },
    )

    # The legacy /voice WebSocket remains for staged migration. New commercial
    # clients should prefer livekit.url + livekit.token.
    return {
        "object": "realtime.session",
        "transport": ["webrtc", "websocket"],
        "client_secret": {"value": token, "expires_at": expires_at},
        "livekit": {
            "url": status["url"],
            "room": room,
            "identity": identity,
            "token": token,
            "agent_name": status["agent_name"],
            "auto_dispatch": status["auto_dispatch"],
        },
        "voice_ws_path": f"/voice?client_secret={token}",
        "model": os.environ.get("ADU_REALTIME_MODEL", "adu-three-stage-v2"),
        "audio": {
            "input_format": "pcm_s16le_16000",
            "output_format": os.environ.get("ALIYUN_TTS_AUDIO_FORMAT", os.environ.get("ADU_TTS_AUDIO_FORMAT", "pcm")),
            "sample_rate": int(os.environ.get("ADU_OUTPUT_SAMPLE_RATE", "24000") or 24000),
        },
    }


async def create_realtime_session_async(payload: dict[str, Any] | None = None) -> dict[str, Any]:
    session = create_realtime_session(payload)
    livekit = session.get("livekit") or {}
    if livekit.get("auto_dispatch"):
        livekit["dispatch"] = await dispatch_livekit_agent(
            str(livekit.get("room") or ""),
            {
                "app": "adu-three-stage-v2",
                "session_identity": livekit.get("identity"),
                "model": session.get("model"),
            },
        )
    return session
