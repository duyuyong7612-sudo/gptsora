# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-706e1e89561f712e3e4684b36ce9f029c9b8fb9fee7f45cdb706711329b3e01b"
# Source-SHA256: "2930d9f67383b8e64ea058059ad73f43d68bd111634a9800a0ee358d995ceb43"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
import os
import json
import time
import logging
from typing import Any, Dict, List, Optional, Union

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel, Field


OPENCLAW_BASE_URL = os.getenv("OPENCLAW_BASE_URL", "http://127.0.0.1:18789")
OPENCLAW_API_KEY = os.getenv("OPENCLAW_API_KEY", os.getenv("OPENCLAW_GATEWAY_TOKEN", ""))
OPENCLAW_MODEL = os.getenv("OPENCLAW_MODEL", "openclaw")
REQUEST_TIMEOUT = float(os.getenv("OPENCLAW_REQUEST_TIMEOUT", "600"))

APP_HOST = os.getenv("APP_HOST", "127.0.0.1")  # 默认只听本机
APP_PORT = int(os.getenv("APP_PORT", "8000"))
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO").upper()

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s %(levelname)s %(name)s - %(message)s",
)
logger = logging.getLogger("chatagi_openclaw_http")

app = FastAPI(
    title="ChatAGI OpenClaw HTTP Bridge",
    version="1.0.0",
    description="HTTP compatible FastAPI bridge for OpenClaw local OpenAI compatible API",
)

_cors_origins = [s.strip() for s in os.getenv("CORS_ORIGINS", "*").split(",") if s.strip()]
app.add_middleware(
    CORSMiddleware,
    allow_origins=_cors_origins or ["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

try:
    from public_webrtc_voice import register_public_webrtc_voice

    register_public_webrtc_voice(app)
    logger.info("[PublicWebRTCVoice] /rtc/offer + /rtc/status + /ui/webrtc-client.html registered")
except Exception as e:
    logger.warning("[PublicWebRTCVoice] registration failed: %s", e)

try:
    from public_livekit_voice import register_public_livekit_voice

    register_public_livekit_voice(app)
    logger.info("[PublicLiveKitVoice] /livekit/status + /livekit/session + /api/realtime/livekit/session registered")
except Exception as e:
    logger.warning("[PublicLiveKitVoice] registration failed: %s", e)


class ChatMessage(BaseModel):
    role: str
    content: Union[str, List[Any], Dict[str, Any]]


class ChatCompletionsRequest(BaseModel):
    model: Optional[str] = None
    messages: List[ChatMessage]
    temperature: Optional[float] = None
    top_p: Optional[float] = None
    max_tokens: Optional[int] = Field(default=None)
    stream: Optional[bool] = False
    user: Optional[str] = None
    metadata: Optional[Dict[str, Any]] = None


class AskRequest(BaseModel):
    text: str
    model: Optional[str] = None
    temperature: Optional[float] = None
    stream: Optional[bool] = False
    user: Optional[str] = None
    metadata: Optional[Dict[str, Any]] = None


def build_headers() -> Dict[str, str]:
    if not OPENCLAW_API_KEY:
        raise HTTPException(status_code=500, detail="OPENCLAW_API_KEY or OPENCLAW_GATEWAY_TOKEN is missing")
    return {
        "Authorization": f"Bearer {OPENCLAW_API_KEY}",
        "Content-Type": "application/json",
    }


def resolve_model(req_model: Optional[str]) -> str:
    return req_model or OPENCLAW_MODEL or "openclaw"


def extract_text_from_response(data: Dict[str, Any]) -> str:
    try:
        choices = data.get("choices") or []
        if not choices:
            return ""
        message = choices[0].get("message") or {}
        content = message.get("content")
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            parts = []
            for item in content:
                if isinstance(item, dict) and item.get("text"):
                    parts.append(item["text"])
            return "".join(parts)
        if content is None:
            return ""
        return json.dumps(content, ensure_ascii=False)
    except Exception:
        return ""


async def forward_chat_completions(payload: Dict[str, Any]) -> Dict[str, Any]:
    url = f"{OPENCLAW_BASE_URL.rstrip('/')}/v1/chat/completions"
    headers = build_headers()

    logger.info("Forwarding request to OpenClaw: %s", url)

    async with httpx.AsyncClient(timeout=REQUEST_TIMEOUT) as client:
        try:
            resp = await client.post(url, headers=headers, json=payload)
        except httpx.RequestError as e:
            logger.exception("Request to OpenClaw failed")
            raise HTTPException(status_code=502, detail=f"Request to OpenClaw failed: {str(e)}")

    if resp.status_code >= 400:
        logger.error("OpenClaw error: status=%s body=%s", resp.status_code, resp.text)
        raise HTTPException(status_code=resp.status_code, detail=resp.text)

    try:
        return resp.json()
    except Exception:
        logger.exception("Invalid JSON from OpenClaw")
        raise HTTPException(status_code=502, detail=f"OpenClaw returned non JSON content: {resp.text}")


async def stream_chat_completions(payload: Dict[str, Any]):
    url = f"{OPENCLAW_BASE_URL.rstrip('/')}/v1/chat/completions"
    headers = build_headers()

    async def event_generator():
        async with httpx.AsyncClient(timeout=REQUEST_TIMEOUT) as client:
            try:
                async with client.stream("POST", url, headers=headers, json=payload) as resp:
                    if resp.status_code >= 400:
                        body = await resp.aread()
                        text = body.decode("utf-8", errors="ignore")
                        yield f"data: {json.dumps({'error': text}, ensure_ascii=False)}\n\n"
                        return

                    async for line in resp.aiter_lines():
                        if line and line.strip():
                            yield line + "\n"
            except Exception as e:
                yield f"data: {json.dumps({'error': str(e)}, ensure_ascii=False)}\n\n"

    return StreamingResponse(event_generator(), media_type="text/event-stream")


@app.get("/health")
async def health():
    return {
        "ok": True,
        "service": "chatagi-openclaw-http-bridge",
        "openclaw_base_url": OPENCLAW_BASE_URL,
        "default_model": OPENCLAW_MODEL,
        "has_api_key": bool(OPENCLAW_API_KEY),
        "ts": int(time.time()),
    }


@app.get("/v1/models")
async def models():
    return {
        "object": "list",
        "data": [
            {
                "id": OPENCLAW_MODEL,
                "object": "model",
                "owned_by": "openclaw",
            }
        ],
    }


@app.post("/v1/chat/completions")
async def chat_completions(req: ChatCompletionsRequest):
    model = resolve_model(req.model)
    payload = {
        "model": model,
        "messages": [m.model_dump() for m in req.messages],
        "stream": bool(req.stream),
    }

    if req.temperature is not None:
        payload["temperature"] = req.temperature
    if req.top_p is not None:
        payload["top_p"] = req.top_p
    if req.max_tokens is not None:
        payload["max_tokens"] = req.max_tokens
    if req.user is not None:
        payload["user"] = req.user
    if req.metadata is not None:
        payload["metadata"] = req.metadata

    if req.stream:
        return await stream_chat_completions(payload)

    data = await forward_chat_completions(payload)
    return JSONResponse(content=data)


@app.post("/api/ask")
async def ask(req: AskRequest):
    model = resolve_model(req.model)
    payload = {
        "model": model,
        "messages": [
            {
                "role": "user",
                "content": req.text,
            }
        ],
        "stream": bool(req.stream),
    }

    if req.temperature is not None:
        payload["temperature"] = req.temperature
    if req.user is not None:
        payload["user"] = req.user
    if req.metadata is not None:
        payload["metadata"] = req.metadata

    if req.stream:
        return await stream_chat_completions(payload)

    data = await forward_chat_completions(payload)
    answer = extract_text_from_response(data)

    return {
        "ok": True,
        "answer": answer,
        "model": model,
        "raw": data,
    }


@app.post("/api/chat")
async def api_chat(request: Request):
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="Request body is not valid JSON")

    if not isinstance(body, dict):
        raise HTTPException(status_code=400, detail="Request body must be a JSON object")

    if "messages" not in body:
        raise HTTPException(status_code=400, detail="Missing messages field")

    body["model"] = resolve_model(body.get("model"))

    if body.get("stream") is True:
        return await stream_chat_completions(body)

    data = await forward_chat_completions(body)
    return JSONResponse(content=data)


@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception):
    logger.exception("Unhandled error: %s", str(exc))
    if isinstance(exc, HTTPException):
        return JSONResponse(
            status_code=exc.status_code,
            content={"ok": False, "error": exc.detail},
        )
    return JSONResponse(
        status_code=500,
        content={"ok": False, "error": str(exc)},
    )


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("app:app", host=APP_HOST, port=APP_PORT, reload=False)
