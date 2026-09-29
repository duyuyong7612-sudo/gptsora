# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-402a6c9e32c0264e67fabc4215f170946dba7781195a74b8983f156b4aa9aa50"
# Source-SHA256: "9c9b4d3fca50f9478b01da397a968872a763c34a62534c55bd97a8126bd81d35"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""Public realtime voice session routes.

The public contract intentionally mirrors OpenAI Realtime:
- Customer backend mints a short-lived client_secret.
- Browser/mobile clients use WebRTC.
- LiveKit is the media/SFU provider behind the OpenAI-shaped facade.
"""

from __future__ import annotations

import json
import logging
import os
from typing import Any, Dict, Optional

from fastapi import Body, HTTPException, Request
from fastapi.responses import Response

from livekit_sessions import create_realtime_session_async, livekit_status

logger = logging.getLogger("chatagi_public_livekit_voice")

OPENAI_CLIENT_EVENTS = [
    "session.update",
    "input_audio_buffer.append",
    "input_audio_buffer.commit",
    "input_audio_buffer.clear",
    "response.create",
    "response.cancel",
    "conversation.item.create",
]
OPENAI_SERVER_EVENTS = [
    "session.created",
    "session.updated",
    "input_audio_buffer.speech_started",
    "input_audio_buffer.speech_stopped",
    "conversation.item.input_audio_transcription.completed",
    "response.created",
    "response.output_audio.delta",
    "response.output_audio_transcript.delta",
    "response.done",
    "output_audio_buffer.started",
    "output_audio_buffer.stopped",
    "output_audio_buffer.cleared",
]


def _as_dict(value: Any) -> Dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _unwrap_openai_payload(payload: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    data = dict(payload or {})
    session = data.get("session")
    if isinstance(session, dict):
        merged = dict(session)
        for key in ("room", "identity", "client", "ttl_s"):
            if key in data and key not in merged:
                merged[key] = data[key]
        return merged
    return data


def _format_with_rate(fmt: str, sample_rate: int) -> str:
    fmt = (fmt or "pcm").strip()
    if fmt.startswith("pcm_s16le_") or fmt.startswith("mp3_"):
        return fmt
    if fmt == "pcm":
        return f"pcm_s16le_{sample_rate}"
    if fmt == "mp3":
        return f"mp3_{sample_rate}"
    return fmt


def _default_turn_detection(payload: Dict[str, Any]) -> Dict[str, Any]:
    turn_detection = payload.get("turn_detection")
    if isinstance(turn_detection, dict):
        return turn_detection
    return {
        "type": "server_vad",
        "threshold": float(os.environ.get("ADU_VAD_THRESHOLD", "0.5") or 0.5),
        "prefix_padding_ms": int(os.environ.get("ADU_VAD_PREFIX_PADDING_MS", "100") or 100),
        "silence_duration_ms": int(os.environ.get("ADU_UTTERANCE_SETTLE_MS", "200") or 200),
        "create_response": True,
        "interrupt_response": True,
    }


def _openai_audio_config(payload: Dict[str, Any], data: Dict[str, Any]) -> Dict[str, Any]:
    old_audio = _as_dict(data.get("audio"))
    requested_audio = _as_dict(payload.get("audio"))
    sample_rate = int(
        requested_audio.get("sample_rate")
        or old_audio.get("sample_rate")
        or os.environ.get("ADU_OUTPUT_SAMPLE_RATE", "24000")
        or 24000
    )
    input_format = (
        payload.get("input_audio_format")
        or requested_audio.get("input_format")
        or old_audio.get("input_format")
        or "pcm_s16le_16000"
    )
    output_format = (
        payload.get("output_audio_format")
        or requested_audio.get("output_format")
        or old_audio.get("output_format")
        or os.environ.get("ALIYUN_TTS_AUDIO_FORMAT")
        or os.environ.get("ADU_TTS_AUDIO_FORMAT")
        or "pcm"
    )
    return {
        "input": {"format": str(input_format), "sample_rate": 16000},
        "output": {
            "format": _format_with_rate(str(output_format), sample_rate),
            "sample_rate": sample_rate,
            "voice": payload.get("voice") or os.environ.get("ALIYUN_TTS_VOICE") or os.environ.get("ADU_TTS_VOICE") or "Neil",
        },
    }


def _decorate_openai_session(data: Dict[str, Any], payload: Dict[str, Any]) -> Dict[str, Any]:
    livekit = _as_dict(data.get("livekit"))
    client_secret = dict(_as_dict(data.get("client_secret")))
    if client_secret.get("value") and "type" not in client_secret:
        client_secret["type"] = "ephemeral"

    model = str(payload.get("model") or data.get("model") or os.environ.get("ADU_REALTIME_MODEL") or "adu-three-stage-v2")
    voice = str(payload.get("voice") or os.environ.get("ALIYUN_TTS_VOICE") or os.environ.get("ADU_TTS_VOICE") or "Neil")
    modalities = payload.get("modalities") if isinstance(payload.get("modalities"), list) else ["audio", "text"]
    sample_rate = int(_as_dict(data.get("audio")).get("sample_rate") or os.environ.get("ADU_OUTPUT_SAMPLE_RATE", "24000") or 24000)
    output_format = _as_dict(data.get("audio")).get("output_format") or os.environ.get("ALIYUN_TTS_AUDIO_FORMAT") or "pcm"
    session_id = data.get("id") or f"sess_{str(livekit.get('room') or 'adu')}"
    expires_at = client_secret.get("expires_at")

    out = {
        **data,
        "id": session_id,
        "object": "realtime.session",
        "type": "realtime",
        "model": model,
        "modalities": modalities,
        "voice": voice,
        "expires_at": expires_at,
        "client_secret": client_secret,
        "transport": ["webrtc"],
        "input_audio_format": str(payload.get("input_audio_format") or "pcm_s16le_16000"),
        "output_audio_format": _format_with_rate(str(payload.get("output_audio_format") or output_format), sample_rate),
        "turn_detection": _default_turn_detection(payload),
        "audio": _openai_audio_config(payload, data),
        "webrtc": {
            "provider": "livekit",
            "url": livekit.get("url"),
            "room": livekit.get("room"),
            "identity": livekit.get("identity"),
            "token": livekit.get("token"),
        },
        "adu": {
            "protocol": "openai-realtime-compatible",
            "transport_provider": "livekit",
            "client_events": OPENAI_CLIENT_EVENTS,
            "server_events": OPENAI_SERVER_EVENTS,
            "notes": "Use LiveKit WebRTC room/token as the media transport; JSON events mirror OpenAI Realtime semantics.",
        },
    }
    if "instructions" in payload:
        out["instructions"] = payload["instructions"]
    if livekit.get("dispatch") is not None:
        out["webrtc"]["agent_dispatch"] = livekit.get("dispatch")
    return out


async def _create_session(payload: Optional[Dict[str, Any]], *, openai_compatible: bool = False) -> Dict[str, Any]:
    normalized = _unwrap_openai_payload(payload)
    try:
        data = await create_realtime_session_async(normalized)
        data["ok"] = True
        data["protocol"] = "openai-realtime" if openai_compatible else "livekit"
        data["transport"] = ["webrtc"]
        if openai_compatible:
            return _decorate_openai_session(data, normalized)
        return data
    except RuntimeError as exc:
        logger.warning("LiveKit realtime session unavailable: %s", exc)
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except Exception as exc:
        logger.exception("LiveKit realtime session failed")
        raise HTTPException(status_code=500, detail="LiveKit session mint failed") from exc


def _looks_like_sdp(text: str) -> bool:
    head = (text or "").lstrip()[:5000]
    return head.startswith("v=0") and (
        "m=audio" in head or "a=ice-ufrag:" in head or "a=fingerprint:" in head
    )


async def _read_form_value(value: Any) -> str:
    if value is None:
        return ""
    if hasattr(value, "read"):
        data = await value.read()
        if isinstance(data, bytes):
            return data.decode("utf-8", errors="ignore")
        return str(data)
    return str(value)


async def _parse_calls_payload(request: Request) -> Dict[str, Any]:
    content_type = request.headers.get("content-type", "").lower()
    if "multipart/form-data" in content_type:
        try:
            form = await request.form()
        except Exception as exc:  # noqa: BLE001
            raise HTTPException(status_code=400, detail="invalid multipart form body") from exc
        payload: Dict[str, Any] = {}
        session_text = await _read_form_value(form.get("session"))
        if session_text:
            try:
                parsed = json.loads(session_text)
            except json.JSONDecodeError as exc:
                raise HTTPException(status_code=400, detail="invalid session JSON") from exc
            if isinstance(parsed, dict):
                payload.update(parsed)
        sdp_text = await _read_form_value(form.get("sdp"))
        if sdp_text:
            payload["sdp_offer"] = sdp_text
            payload["_adu_raw_sdp_request"] = True
        return payload

    body = await request.body()
    if not body:
        return {}
    if "json" in content_type:
        try:
            data = json.loads(body.decode("utf-8"))
        except json.JSONDecodeError as exc:
            raise HTTPException(status_code=400, detail="invalid JSON body") from exc
        if isinstance(data, dict):
            return data
        raise HTTPException(status_code=400, detail="JSON body must be an object")

    text = body.decode("utf-8", errors="ignore")
    if "application/sdp" in content_type or _looks_like_sdp(text):
        return {"sdp_offer": text, "_adu_raw_sdp_request": True}
    return {"sdp_offer": text}


def _extract_sdp_offer(payload: Dict[str, Any]) -> str:
    for key in ("sdp", "sdp_offer", "offer_sdp"):
        value = payload.get(key)
        if isinstance(value, str) and _looks_like_sdp(value):
            return value
    offer = payload.get("offer")
    if isinstance(offer, dict):
        value = offer.get("sdp")
        if isinstance(value, str) and _looks_like_sdp(value):
            return value
    return ""


async def _create_sdp_answer(payload: Dict[str, Any]) -> Dict[str, Any]:
    sdp_offer = _extract_sdp_offer(payload)
    if not sdp_offer:
        raise HTTPException(status_code=400, detail="missing SDP offer")
    request = {"sdp": sdp_offer, "type": str(payload.get("type") or "offer")}

    # 默认把 raw-SDP 客户端接到云端三段（LiveKit agent）；
    # ADU_CALLS_BACKEND=local 可切回本机 aiortc 三段管线。
    backend = (os.environ.get("ADU_CALLS_BACKEND") or "cloud").strip().lower()
    if backend != "local":
        try:
            import livekit_sdp_bridge
            if livekit_sdp_bridge.available():
                answer = await livekit_sdp_bridge.create_answer(request)
                if answer.get("ok"):
                    return answer
                logger.warning("livekit sdp bridge answer not ok: %s", answer)
        except Exception as exc:  # noqa: BLE001
            logger.warning("livekit sdp bridge failed, falling back to local pipeline: %s", exc)

    try:
        from public_webrtc_voice import create_answer as create_webrtc_answer
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=503, detail="SDP bridge unavailable") from exc
    answer = await create_webrtc_answer(request)
    if not answer.get("ok"):
        raise HTTPException(status_code=503, detail=str(answer.get("error") or "SDP bridge failed"))
    return answer


def register_public_livekit_voice(app) -> None:
    @app.get("/livekit/status")
    async def livekit_status_route() -> Dict[str, Any]:
        return livekit_status()

    @app.get("/api/realtime/livekit/status")
    async def api_livekit_status_route() -> Dict[str, Any]:
        return livekit_status()

    @app.get("/v1/realtime/status")
    async def openai_realtime_status_route() -> Dict[str, Any]:
        status = livekit_status()
        return {
            **status,
            "object": "realtime.status",
            "protocol": "openai-realtime-compatible",
            "transport": ["webrtc"],
            "routes": ["/v1/realtime/client_secrets", "/v1/realtime/sessions", "/v1/realtime/calls", "/v1/realtime/calls (application/sdp)"],
        }

    @app.post("/livekit/session")
    async def livekit_session_route(payload: Optional[Dict[str, Any]] = Body(default=None)) -> Dict[str, Any]:
        return await _create_session(payload)

    @app.post("/api/realtime/livekit/session")
    async def api_livekit_session_route(payload: Optional[Dict[str, Any]] = Body(default=None)) -> Dict[str, Any]:
        return await _create_session(payload)

    @app.post("/api/realtime/session/livekit")
    async def api_livekit_session_alias_route(payload: Optional[Dict[str, Any]] = Body(default=None)) -> Dict[str, Any]:
        return await _create_session(payload)

    @app.post("/v1/realtime/client_secrets")
    async def openai_client_secret_route(payload: Optional[Dict[str, Any]] = Body(default=None)) -> Dict[str, Any]:
        return await _create_session(payload, openai_compatible=True)

    @app.post("/v1/realtime/sessions")
    async def openai_session_route(payload: Optional[Dict[str, Any]] = Body(default=None)) -> Dict[str, Any]:
        return await _create_session(payload, openai_compatible=True)

    @app.post("/v1/realtime/calls")
    async def openai_calls_route(request: Request) -> Any:
        payload = await _parse_calls_payload(request)
        wants_raw_sdp = bool(payload.pop("_adu_raw_sdp_request", False)) or "application/sdp" in request.headers.get("accept", "").lower()
        sdp_offer = _extract_sdp_offer(payload)

        if sdp_offer:
            payload["sdp_offer"] = sdp_offer
            answer = await _create_sdp_answer(payload)
            session_id = str(answer.get("session_id") or "")
            sdp_answer = str(answer.get("sdp") or "")
            if wants_raw_sdp:
                return Response(
                    content=sdp_answer,
                    status_code=201,
                    media_type="application/sdp",
                    headers={
                        "Cache-Control": "no-store",
                        "X-Adu-Realtime-Protocol": "openai-raw-sdp",
                        "X-Adu-Transport-Provider": "aiortc-sdp-bridge",
                        "X-Adu-Session-Id": session_id,
                    },
                )
            return {
                "object": "realtime.call",
                "id": f"call_{session_id}",
                "call_id": f"call_{session_id}",
                "status": "ready",
                "type": str(answer.get("type") or "answer"),
                "sdp_answer": sdp_answer,
                "transport": ["webrtc"],
                "webrtc": {
                    "provider": "aiortc-sdp-bridge",
                    "mode": "raw-sdp-answer",
                    "session_id": session_id,
                    "data_channels": ["voice", "oai-events"],
                },
                "adu": {
                    "protocol": "openai-realtime-raw-sdp",
                    "notes": "POST application/sdp or multipart form field sdp; response is SDP answer when raw SDP is requested.",
                },
            }

        data = await _create_session(payload, openai_compatible=True)
        data["object"] = "realtime.call"
        data["call_id"] = data["id"].replace("sess_", "call_", 1)
        data["status"] = "ready"
        data["sdp_answer"] = None
        data["webrtc"]["mode"] = "livekit-room-token"
        return data
