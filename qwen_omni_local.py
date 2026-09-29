#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-bf230b67764ef42054847cb94fb6a89aeb0d94f0da4bcc86dfe2a96228c1c0dd"
# Source-SHA256: "fda92fa11967e4163441f93ed4666632a4a7fbd3970c8cf2315525eb675df10a"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
qwen_omni_local —— 自建 Qwen3-Omni vLLM 服务（OpenAI 兼容）接入层。

把同一台自部署 vLLM-Omni 的其余几条线注册成一个统一 provider "qwen_omni_local"：
  - 文本：/v1/chat/completions（OpenAI SSE）
  - TTS ：/v1/audio/speech（整段）+ /v1/audio/speech/stream（流式 chunked 直转）
  - 视频：/v1/video/chat/stream（流式）
  - 音色：启动时 GET /v1/audio/voices 拉取并缓存
实时语音 /v1/realtime 由 server_session.py 既有逻辑负责，本模块不碰。

设计约束（与 server_session.py 其它 provider 一致）：
  - 全部配置走环境变量，不硬编码 IP，Render 容器可运行。
  - 每个请求独立 requests 调用，不持有跨请求/跨用户的连接状态 → 天然按 session 隔离。
  - 启动探活 8091；不可达时 is_up() 返回 False，由调用方各线自动降级回原 provider。
  - 每条线 per-stage 延迟打点，格式与现有日志一致：[xxx.qwen_omni_local] ...=%.3fs / connect_ms=%d。

环境变量：
  QWEN_OMNI_LOCAL_BASE_URL   例: http://<RUNPOD_HOST>:8091   （必填；为空则整模块禁用）
  QWEN_OMNI_LOCAL_MODEL      默认 Qwen3-Omni-30B-A3B-Instruct
  QWEN_OMNI_LOCAL_API_KEY    可选（vLLM 通常无鉴权，留空则不发 Authorization）
  QWEN_OMNI_LOCAL_VOICE      默认 chelsie
  QWEN_OMNI_LOCAL_AS_FALLBACK  =1 时允许作为文本 SMART 备选层级（默认 0，仅显式选用）
  QWEN_OMNI_LOCAL_CONNECT_TIMEOUT / _READ_TIMEOUT
"""

import os
import json
import time
import logging
import threading
from typing import Any, Dict, Iterator, List, Optional

import requests

log = logging.getLogger("solara-backend")

PROVIDER_NAME = "qwen_omni_local"
PROVIDER_ALIASES = ("qwen_omni_local", "qwen-omni-local", "qwenomnilocal", "omni_local", "local_omni")

BASE_URL = (os.getenv("QWEN_OMNI_LOCAL_BASE_URL") or "").strip().rstrip("/")
MODEL = (os.getenv("QWEN_OMNI_LOCAL_MODEL") or "Qwen3-Omni-30B-A3B-Instruct").strip()
API_KEY = (os.getenv("QWEN_OMNI_LOCAL_API_KEY") or "").strip()
DEFAULT_VOICE = (os.getenv("QWEN_OMNI_LOCAL_VOICE") or "chelsie").strip()
AS_FALLBACK = (os.getenv("QWEN_OMNI_LOCAL_AS_FALLBACK") or "0").strip().lower() in ("1", "true", "yes", "on")

CONNECT_TIMEOUT = float(os.getenv("QWEN_OMNI_LOCAL_CONNECT_TIMEOUT") or "5")
READ_TIMEOUT = float(os.getenv("QWEN_OMNI_LOCAL_READ_TIMEOUT") or "120")
HEALTH_TTL = float(os.getenv("QWEN_OMNI_LOCAL_HEALTH_TTL") or "30")

ENABLED = bool(BASE_URL)

_health_lock = threading.Lock()
_health = {"up": False, "checked_at": 0.0}
_voices_lock = threading.Lock()
_voices = {"list": [], "fetched_at": 0.0}


# ───────────────────────── 基础 ─────────────────────────
def is_enabled() -> bool:
    return ENABLED


def as_fallback_enabled() -> bool:
    return ENABLED and AS_FALLBACK


def is_provider_name(p: str) -> bool:
    return (p or "").strip().lower().replace("-", "_") in (a.replace("-", "_") for a in PROVIDER_ALIASES)


def is_model_name(m: str) -> bool:
    s = (m or "").strip().lower()
    if not s:
        return False
    return s == MODEL.lower() or s.startswith("qwen3-omni") or "qwen-omni-local" in s


def _root() -> str:
    """服务根（去掉末尾 /v1）。用于 /health 等非 /v1 路径。"""
    b = BASE_URL
    return b[:-3] if b.endswith("/v1") else b


def _api(path: str) -> str:
    """OpenAI 兼容 /v1 路径。BASE_URL 带不带 /v1 都能正确拼出单个 /v1。
    path 形如 '/chat/completions'。"""
    b = BASE_URL
    if b.endswith("/v1"):
        return b + path
    return b + "/v1" + path


def _headers(stream: bool = False) -> Dict[str, str]:
    h = {"Content-Type": "application/json"}
    if API_KEY:
        h["Authorization"] = f"Bearer {API_KEY}"
    if stream:
        h["Accept"] = "text/event-stream"
    return h


def default_voice() -> str:
    return DEFAULT_VOICE


# ───────────────────────── 探活 / 降级 ─────────────────────────
def health_check(force: bool = False) -> bool:
    """探活 8091（GET /health 或 /v1/models）。30s 缓存。不可达 → False，调用方降级。"""
    if not ENABLED:
        return False
    now = time.time()
    if not force:
        with _health_lock:
            if now - _health["checked_at"] < HEALTH_TTL:
                return _health["up"]
    up = False
    for url in (_root() + "/health", _api("/models")):
        try:
            r = requests.get(url, timeout=CONNECT_TIMEOUT)
            # 必须是成功响应（200/2xx/3xx）。404/405/5xx 视为不可达 → 降级。
            if r.status_code < 400:
                up = True
                break
        except Exception:
            continue
    with _health_lock:
        _health["up"] = up
        _health["checked_at"] = now
    if not up:
        log.warning("[qwen_omni_local] health probe FAILED base=%s (callers degrade to fallback provider)",
                    BASE_URL or "(unset)")
    return up


def is_up() -> bool:
    """带缓存的可用性查询（各线在分流前调用，决定是否降级）。"""
    return health_check(force=False)


def probe_on_startup() -> bool:
    """服务启动时调用：探活 + 预拉音色。不可达只 warning，绝不抛异常打断主流程。"""
    if not ENABLED:
        log.warning("[qwen_omni_local] disabled: QWEN_OMNI_LOCAL_BASE_URL not set (all 4 lines stay on original providers)")
        return False
    try:
        up = health_check(force=True)
    except Exception as e:
        log.warning("[qwen_omni_local] startup probe error: %s", e)
        up = False
    log.info("[qwen_omni_local] startup base=%s model=%s up=%s as_fallback=%s", BASE_URL, MODEL, up, AS_FALLBACK)
    if up:
        try:
            fetch_voices(force=True)
        except Exception as e:
            log.warning("[qwen_omni_local] startup voices fetch failed: %s", e)
    return up


# ───────────────────────── 一、文本线 /v1/chat/completions ─────────────────────────
def stream_chat_events(messages: List[Dict[str, Any]], *, model: Optional[str] = None,
                       max_tokens: Optional[int] = None, temperature: float = 0.7) -> Iterator[Dict[str, Any]]:
    """
    OpenAI 协议 SSE 流式文本。yield 的事件 dict 与 server_session 其它 provider 完全一致：
      {"type":"response.output_text.delta","delta":..., "sequence_number":n, "output_index":0,"content_index":0}
      末尾 {"type":"solara._provider_done","finish_reason":...}
    抛 RuntimeError 时由 server_session 的 _guard_stream 兜底降级。
    """
    url = _api("/chat/completions")
    use_model = (model or MODEL)
    payload: Dict[str, Any] = {
        "model": use_model,
        "messages": messages,
        "stream": True,
        "temperature": temperature,
        # ✅ 关键：Qwen3-Omni 默认会把 base64 WAV（UklGR=RIFF）混进文本 content。
        #    文本线显式只要 text，抑制音频注入（已实测 modalities:["text"] 后 content 干净）。
        "modalities": ["text"],
    }
    if max_tokens and int(max_tokens) > 0:
        payload["max_tokens"] = max(128, min(int(max_tokens), 16384))

    t0 = time.time()
    r = requests.post(url, headers=_headers(stream=True), json=payload, stream=True,
                      timeout=(CONNECT_TIMEOUT, READ_TIMEOUT))
    log.info("[chat.qwen_omni_local] model=%s status=%s connect_ms=%d", use_model, r.status_code,
             int((time.time() - t0) * 1000))
    if r.status_code >= 400:
        body = ""
        try:
            body = r.text[:600]
        except Exception:
            pass
        try:
            r.close()
        except Exception:
            pass
        raise RuntimeError(f"qwen_omni_local_chat_error {r.status_code}: {body}")

    seq = 0
    first_token_at: Optional[float] = None
    finish_reason: Optional[str] = None
    try:
        for raw in r.iter_lines(decode_unicode=False):
            if not raw or raw.startswith(b":"):
                continue
            line = raw.decode("utf-8", errors="ignore").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            try:
                obj = json.loads(data)
            except Exception:
                continue
            choice = (obj.get("choices") or [None])[0]
            if not isinstance(choice, dict):
                continue
            fr = choice.get("finish_reason")
            if fr:
                finish_reason = str(fr)
            delta = str((choice.get("delta") or {}).get("content") or "")
            # 防御：极个别构建即使 modalities:["text"] 仍可能漏出 base64 WAV，丢弃这类音频块。
            if delta and (delta.startswith("UklGR") or delta.startswith("data:audio")):
                continue
            if delta:
                if first_token_at is None:
                    first_token_at = time.time()
                    log.info("[chat.qwen_omni_local] TTFT=%.3fs", first_token_at - t0)
                seq += 1
                yield {
                    "type": "response.output_text.delta",
                    "delta": delta,
                    "sequence_number": seq,
                    "output_index": 0,
                    "content_index": 0,
                }
    finally:
        try:
            r.close()
        except Exception:
            pass
    log.info("[chat.qwen_omni_local] done total=%.3fs deltas=%d finish=%s", time.time() - t0, seq, finish_reason or "")
    yield {"type": "solara._provider_done", "finish_reason": (finish_reason or "")}


# ───────────────────────── 二、TTS 线 /v1/audio/speech(+stream) ─────────────────────────
def fetch_voices(force: bool = False) -> List[Any]:
    """启动时缓存 /v1/audio/voices。失败返回已缓存（可能为空），只 warning。"""
    now = time.time()
    if not force:
        with _voices_lock:
            if _voices["list"] and (now - _voices["fetched_at"] < 600):
                return _voices["list"]
    try:
        r = requests.get(_api("/audio/voices"), timeout=CONNECT_TIMEOUT)
        if r.status_code < 400:
            data = r.json()
            voices = data.get("voices") if isinstance(data, dict) else None
            if voices is None and isinstance(data, dict):
                voices = data.get("data")
            if voices is None:
                voices = data
            if isinstance(voices, list):
                with _voices_lock:
                    _voices["list"] = voices
                    _voices["fetched_at"] = now
                log.info("[qwen_omni_local] voices cached n=%d", len(voices))
        else:
            log.warning("[qwen_omni_local] /audio/voices status=%s", r.status_code)
    except Exception as e:
        log.warning("[qwen_omni_local] fetch_voices failed: %s", e)
    with _voices_lock:
        return list(_voices["list"])


def cached_voices() -> List[Any]:
    with _voices_lock:
        return list(_voices["list"])


def tts_bytes(text: str, *, voice: Optional[str] = None, fmt: str = "mp3",
              model: Optional[str] = None) -> bytes:
    """整段 TTS：POST /v1/audio/speech，返回完整音频字节。"""
    url = _api("/audio/speech")
    use_voice = (voice or DEFAULT_VOICE)
    payload: Dict[str, Any] = {"model": (model or MODEL), "voice": use_voice, "input": text}
    if fmt and fmt != "mp3":
        payload["response_format"] = fmt
    t0 = time.time()
    r = requests.post(url, headers=_headers(), json=payload, timeout=(CONNECT_TIMEOUT, READ_TIMEOUT))
    log.info("[tts.qwen_omni_local] status=%s elapsed=%.3fs voice=%s fmt=%s", r.status_code,
             time.time() - t0, use_voice, fmt)
    if r.status_code >= 400:
        body = ""
        try:
            body = r.text[:300]
        except Exception:
            pass
        raise RuntimeError(f"qwen_omni_local_tts_error {r.status_code}: {body}")
    return r.content


def tts_stream(text: str, *, voice: Optional[str] = None, fmt: str = "mp3",
               model: Optional[str] = None, chunk_size: int = 8192) -> Iterator[bytes]:
    """
    流式 TTS：POST /v1/audio/speech/stream，chunked 直接转发。
    ⚠️ 严禁服务端攒完整段再发：拿到一块 yield 一块（TTFA 打点）。
    """
    url = _api("/audio/speech/stream")
    use_voice = (voice or DEFAULT_VOICE)
    payload: Dict[str, Any] = {"model": (model or MODEL), "voice": use_voice, "input": text, "stream": True}
    if fmt and fmt != "mp3":
        payload["response_format"] = fmt
    t0 = time.time()
    first_at: Optional[float] = None
    r = requests.post(url, headers=_headers(stream=True), json=payload, stream=True,
                      timeout=(CONNECT_TIMEOUT, READ_TIMEOUT))
    if r.status_code >= 400:
        try:
            r.close()
        except Exception:
            pass
        raise RuntimeError(f"qwen_omni_local_tts_stream_error {r.status_code}")
    try:
        for chunk in r.iter_content(chunk_size=chunk_size):
            if chunk:
                if first_at is None:
                    first_at = time.time()
                    log.info("[tts.qwen_omni_local.stream] TTFA=%.3fs voice=%s", first_at - t0, use_voice)
                yield chunk
    finally:
        try:
            r.close()
        except Exception:
            pass
    log.info("[tts.qwen_omni_local.stream] done total=%.3fs voice=%s", time.time() - t0, use_voice)


# ───────────────────────── 三、视频线 /v1/video/chat/stream ─────────────────────────
def video_chat_stream(messages: List[Dict[str, Any]], *, model: Optional[str] = None,
                      extra: Optional[Dict[str, Any]] = None, chunk_size: int = 8192) -> Iterator[bytes]:
    """
    流式视频对话：POST /v1/video/chat/stream，chunked 直接转发。
    人格/记忆由调用方通过 build_unified_memory_context 注入到 messages（共享 sessionConversationId）。
    """
    url = _api("/video/chat/stream")
    payload: Dict[str, Any] = {"model": (model or MODEL), "messages": messages, "stream": True}
    if extra:
        payload.update(extra)
    t0 = time.time()
    first_at: Optional[float] = None
    r = requests.post(url, headers=_headers(stream=True), json=payload, stream=True,
                      timeout=(CONNECT_TIMEOUT, READ_TIMEOUT))
    if r.status_code >= 400:
        try:
            r.close()
        except Exception:
            pass
        raise RuntimeError(f"qwen_omni_local_video_error {r.status_code}")
    try:
        for chunk in r.iter_content(chunk_size=chunk_size):
            if chunk:
                if first_at is None:
                    first_at = time.time()
                    log.info("[video.qwen_omni_local] TTFB=%.3fs", first_at - t0)
                yield chunk
    finally:
        try:
            r.close()
        except Exception:
            pass
    log.info("[video.qwen_omni_local] done total=%.3fs", time.time() - t0)
