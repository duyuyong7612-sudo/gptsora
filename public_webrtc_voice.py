# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-3528770b35698ceee6bc78ff85c99e155e2353f2d608cbf30391e99f39fed41b"
# Source-SHA256: "87d9a6ca7520f252faae53d3e8bf2530fee544c0cf9e529996856a786157c2f0"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
from __future__ import annotations

import asyncio
import audioop
import base64
import json
import math
import os
import struct
import time
import uuid
from dataclasses import dataclass, field
from fractions import Fraction
from pathlib import Path
from typing import Any, Optional

try:
    from aiortc import MediaStreamTrack, RTCConfiguration, RTCIceServer, RTCPeerConnection, RTCSessionDescription
    from av import AudioFrame
    from av.audio.resampler import AudioResampler
except Exception:  # pragma: no cover - optional runtime dependency
    MediaStreamTrack = None  # type: ignore
    RTCConfiguration = None  # type: ignore
    RTCIceServer = None  # type: ignore
    RTCPeerConnection = None  # type: ignore
    RTCSessionDescription = None  # type: ignore
    AudioFrame = None  # type: ignore
    AudioResampler = None  # type: ignore

try:
    from voice_pipeline import run_voice_pipeline, _run_asr, TTSSession
except Exception:  # pragma: no cover - imported by server at runtime
    run_voice_pipeline = None  # type: ignore
    _run_asr = None  # type: ignore
    TTSSession = None  # type: ignore

SAMPLE_RATE = int(os.getenv("PUBLIC_RTC_INPUT_SAMPLE_RATE", "16000"))
TTS_SAMPLE_RATE = int(os.getenv("PUBLIC_RTC_TTS_SAMPLE_RATE", "24000"))
OUTPUT_SAMPLE_RATE = int(os.getenv("PUBLIC_RTC_OUTPUT_SAMPLE_RATE", "48000"))
FRAME_MS = int(os.getenv("PUBLIC_RTC_FRAME_MS", "20"))
OUTPUT_FRAME_MS = int(os.getenv("PUBLIC_RTC_OUTPUT_FRAME_MS", "20"))
FRAME_BYTES = SAMPLE_RATE * FRAME_MS // 1000 * 2
OUTPUT_FRAME_SAMPLES = max(1, OUTPUT_SAMPLE_RATE * OUTPUT_FRAME_MS // 1000)
OUTPUT_FRAME_BYTES = OUTPUT_FRAME_SAMPLES * 2
MAX_SILENCE_MS = int(os.getenv("PUBLIC_RTC_ENDPOINT_SILENCE_MS", "220"))
MIN_UTTERANCE_MS = int(os.getenv("PUBLIC_RTC_MIN_UTTERANCE_MS", "120"))
RMS_THRESHOLD = float(os.getenv("PUBLIC_RTC_RMS_THRESHOLD", "0.008"))
OPENAI_AUDIO_DELTAS = os.getenv("PUBLIC_RTC_OPENAI_AUDIO_DELTAS", "0").lower() in {"1", "true", "yes", "on"}
PUBLIC_RTC_ANSWER_STRICT_IOS = os.getenv("PUBLIC_RTC_ANSWER_STRICT_IOS", "1").lower() in {"1", "true", "yes", "on"}
PUBLIC_RTC_PREFERRED_HOST = os.getenv("PUBLIC_RTC_PREFERRED_HOST", "").strip()

_WEB_ROOT = Path(os.getenv("PUBLIC_RTC_WEB_ROOT", Path(__file__).resolve().parent / "static"))
_pcs: dict[str, RTCPeerConnection] = {}
_sessions: dict[str, "RtcVoiceSession"] = {}
_TRACE_PATH = Path(
    os.getenv(
        "PUBLIC_RTC_TRACE_JSONL",
        str(Path(__file__).resolve().parent / "logs" / "public_webrtc_trace.jsonl"),
    )
)


def _redact_trace_value(value: Any) -> Any:
    if isinstance(value, dict):
        out: dict[str, Any] = {}
        for key, child in value.items():
            low = str(key).lower()
            if any(mark in low for mark in ("secret", "token", "authorization", "api_key", "client_secret")):
                out[key] = "***"
            else:
                out[key] = _redact_trace_value(child)
        return out
    if isinstance(value, list):
        return [_redact_trace_value(child) for child in value]
    if isinstance(value, str):
        return value if len(value) <= 500 else value[:500] + "...<truncated>"
    return value


def _trace(event: str, **fields: Any) -> None:
    try:
        _TRACE_PATH.parent.mkdir(parents=True, exist_ok=True)
        rec = {
            "ts_ms": round(_now_ms(), 1),
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "event": event,
        }
        rec.update(_redact_trace_value(fields))
        with _TRACE_PATH.open("a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False, separators=(",", ":")) + "\n")
    except Exception as exc:  # pragma: no cover - trace must never break voice
        print(f"[public-webrtc][trace-error] {exc}", flush=True)


def available() -> bool:
    return bool(RTCPeerConnection and RTCSessionDescription and run_voice_pipeline and _run_asr)


def media_track_available() -> bool:
    return bool(MediaStreamTrack and AudioFrame)

_VALID_TRANSCEIVER_DIRECTIONS = {"sendrecv", "sendonly", "recvonly", "inactive"}


def _normalize_transceiver_directions(pc: Any) -> None:
    """aiortc can leave transceiver.direction as None for raw SDP offers.

    OpenAI-style clients normally send an audio m-line, but iOS/WebRTC variants
    differ in whether they mark it sendrecv/sendonly before the answer is built.
    Normalizing here keeps the SDP bridge from failing during setLocalDescription.
    """
    try:
        transceivers = list(pc.getTransceivers())
    except Exception:
        return
    for transceiver in transceivers:
        if getattr(transceiver, "direction", None) in _VALID_TRANSCEIVER_DIRECTIONS:
            continue
        sender_track = getattr(getattr(transceiver, "sender", None), "track", None)
        receiver_track = getattr(getattr(transceiver, "receiver", None), "track", None)
        if sender_track is not None and receiver_track is not None:
            transceiver.direction = "sendrecv"
        elif sender_track is not None:
            transceiver.direction = "sendonly"
        elif receiver_track is not None:
            transceiver.direction = "recvonly"
        else:
            transceiver.direction = "sendrecv"


def _candidate_host_and_type(line: str) -> tuple[str, str]:
    parts = line.split()
    host = parts[4] if len(parts) > 4 else ""
    typ = parts[7] if len(parts) > 7 else ""
    return host, typ


def _is_private_ipv4(host: str) -> bool:
    try:
        parts = host.split(".")
        if len(parts) != 4:
            return False
        a, b, c, d = [int(x) for x in parts]
    except Exception:
        return False
    if not all(0 <= x <= 255 for x in (a, b, c, d)):
        return False
    return a == 10 or (a == 192 and b == 168) or (a == 172 and 16 <= b <= 31)


def _sanitize_sdp_answer_for_ios(sdp: str) -> str:
    normalized = sdp.replace("\r\n", "\n").replace("\r", "\n")
    if not PUBLIC_RTC_ANSWER_STRICT_IOS:
        return normalized.strip() + "\r\n"

    out: list[str] = []
    seen_fp = False
    kept_candidates = 0
    for line in normalized.split("\n"):
        if not line:
            continue
        lower = line.lower()
        if lower.startswith("a=fingerprint:"):
            if "sha-256" in lower and not seen_fp:
                out.append(line)
                seen_fp = True
            continue
        if lower.startswith("a=candidate:"):
            host, typ = _candidate_host_and_type(line)
            if not host or ":" in host or host.startswith("127.") or host.startswith("100."):
                continue
            if PUBLIC_RTC_PREFERRED_HOST and host != PUBLIC_RTC_PREFERRED_HOST and typ != "srflx":
                continue
            if typ == "host" and _is_private_ipv4(host):
                out.append(line)
                kept_candidates += 1
                continue
            if typ == "srflx":
                out.append(line)
                kept_candidates += 1
                continue
            continue
        out.append(line)
    sanitized = "\r\n".join(out).strip() + "\r\n"
    print(
        f"[public-webrtc] sanitized answer raw={len(sdp)} out={len(sanitized)} "
        f"kept_candidates={kept_candidates} strict_ios={PUBLIC_RTC_ANSWER_STRICT_IOS}",
        flush=True,
    )
    return sanitized


def _event_id() -> str:
    return "evt_" + uuid.uuid4().hex[:16]


def _now_ms() -> float:
    return time.perf_counter() * 1000.0


def _rms(pcm: bytes) -> float:
    if not pcm:
        return 0.0
    count = len(pcm) // 2
    if count <= 0:
        return 0.0
    vals = struct.unpack("<" + "h" * count, pcm[: count * 2])
    return math.sqrt(sum(v * v for v in vals) / count) / 32768.0


def _pcm_duration_ms(pcm: bytes, sample_rate: int = SAMPLE_RATE) -> int:
    return int((len(pcm) / 2) / sample_rate * 1000)


def _array_to_pcm16(arr: Any) -> bytes:
    if arr is None:
        return b""
    try:
        # 必须在 mean() 之前记录原始 dtype：int16 均值后会变 float64，
        # 但数值仍是 ±32767 量级，绝不能再按归一化 float 乘 32767。
        orig_kind = getattr(getattr(arr, "dtype", None), "kind", "")
        if getattr(arr, "ndim", 0) > 1:
            # PyAV audio arrays are usually shaped as channels x samples.
            arr = arr.reshape(arr.shape[0], -1).mean(axis=0)
        if orig_kind == "f":
            arr = (arr.clip(-1.0, 1.0) * 32767.0).astype("<i2")
            return arr.tobytes()
        arr = arr.round().clip(-32768, 32767).astype("<i2")
        return arr.tobytes()
    except Exception as exc:
        print(f"[public-webrtc] audio frame convert failed: {exc}", flush=True)
        return b""


class NullChannel:
    label = "media"
    readyState = "closed"

    def send(self, _payload: str) -> None:
        return None


_AudioTrackBase = MediaStreamTrack if MediaStreamTrack is not None else object


class AduAudioOutputTrack(_AudioTrackBase):
    kind = "audio"

    def __init__(self, session_id: str):
        if MediaStreamTrack is not None:
            super().__init__()
        self.session_id = session_id
        self._queue: asyncio.Queue[bytes] = asyncio.Queue(maxsize=512)
        self._buffer = bytearray()
        self._pts = 0
        self._started_at = time.monotonic()
        self._rate_state: Any = None

    def clear(self) -> None:
        self._buffer.clear()
        self._rate_state = None
        while not self._queue.empty():
            try:
                self._queue.get_nowait()
            except Exception:
                break

    def enqueue_pcm16(self, chunk: bytes, sample_rate: int = TTS_SAMPLE_RATE) -> None:
        if not chunk:
            return
        try:
            if sample_rate != OUTPUT_SAMPLE_RATE:
                chunk, self._rate_state = audioop.ratecv(
                    chunk,
                    2,
                    1,
                    sample_rate,
                    OUTPUT_SAMPLE_RATE,
                    self._rate_state,
                )
        except Exception as exc:
            print(f"[public-webrtc] output resample failed: {exc}", flush=True)
            return
        if not chunk:
            return
        try:
            self._queue.put_nowait(chunk)
        except asyncio.QueueFull:
            try:
                self._queue.get_nowait()
            except Exception:
                pass
            try:
                self._queue.put_nowait(chunk)
            except Exception:
                pass

    async def recv(self) -> AudioFrame:
        if AudioFrame is None:
            raise RuntimeError("PyAV AudioFrame is not available")

        target_at = self._started_at + (self._pts / OUTPUT_SAMPLE_RATE)
        wait = target_at - time.monotonic()
        if wait > 0:
            await asyncio.sleep(wait)

        deadline = max(0.001, OUTPUT_FRAME_MS / 1000.0)
        while len(self._buffer) < OUTPUT_FRAME_BYTES:
            try:
                chunk = await asyncio.wait_for(self._queue.get(), timeout=deadline)
                self._buffer.extend(chunk)
            except asyncio.TimeoutError:
                break
            except asyncio.CancelledError:
                raise
            except Exception:
                break

        if len(self._buffer) >= OUTPUT_FRAME_BYTES:
            payload = bytes(self._buffer[:OUTPUT_FRAME_BYTES])
            del self._buffer[:OUTPUT_FRAME_BYTES]
        else:
            missing = OUTPUT_FRAME_BYTES - len(self._buffer)
            payload = bytes(self._buffer) + (b"\x00" * missing)
            self._buffer.clear()

        frame = AudioFrame(format="s16", layout="mono", samples=OUTPUT_FRAME_SAMPLES)
        frame.planes[0].update(payload)
        frame.sample_rate = OUTPUT_SAMPLE_RATE
        frame.pts = self._pts
        frame.time_base = Fraction(1, OUTPUT_SAMPLE_RATE)
        self._pts += OUTPUT_FRAME_SAMPLES
        return frame


@dataclass
class RtcVoiceSession:
    channel: Any
    session_id: str
    audio_output: Optional[AduAudioOutputTrack] = None
    queue: asyncio.Queue[bytes | None] = field(default_factory=asyncio.Queue)
    history: list[dict[str, str]] = field(default_factory=list)
    audio: bytearray = field(default_factory=bytearray)
    started_at_ms: Optional[float] = None
    last_voice_ms: Optional[float] = None
    speech_active: bool = False
    speaking: bool = False
    cancelled: bool = False
    cancel_event: Optional[asyncio.Event] = None
    tts: Optional[Any] = None
    round_id: int = 0
    channel_label: str = ""
    media_input_seen: bool = False

    async def send(self, payload: dict[str, Any]) -> None:
        try:
            if getattr(self.channel, "readyState", "") == "open":
                self.channel.send(json.dumps(payload, ensure_ascii=False))
        except Exception as exc:
            print(f"[public-webrtc] send failed: {exc}", flush=True)

    def enqueue(self, pcm: bytes) -> None:
        self.queue.put_nowait(pcm)

    def _clear_output(self) -> None:
        if self.audio_output:
            self.audio_output.clear()

    def cancel_round(self) -> None:
        self.cancelled = True
        if self.cancel_event is not None:
            self.cancel_event.set()
        self._clear_output()

    def _should_send_audio_delta(self) -> bool:
        # OpenAI-style WebRTC clients should receive audio as a media track.
        # The legacy Adu browser client uses a data channel labelled "voice".
        return OPENAI_AUDIO_DELTAS or self.audio_output is None or self.channel_label == "voice"

    async def run(self) -> None:
        await self.send(
            {
                "type": "session.created",
                "event_id": _event_id(),
                "session": {
                    "id": self.session_id,
                    "object": "realtime.session",
                    "modalities": ["audio", "text"],
                    "voice": os.getenv("ADU_TTS_VOICE", os.getenv("ALIYUN_TTS_VOICE", "Neil")),
                    "input_audio_format": f"pcm_s16le_{SAMPLE_RATE}",
                    "output_audio_format": f"pcm_s16le_{TTS_SAMPLE_RATE}",
                    "transport": "webrtc-media-track+datachannel",
                    "media_tracks": {
                        "input": "audio",
                        "output": "audio",
                        "output_sample_rate": OUTPUT_SAMPLE_RATE,
                    },
                },
            }
        )
        # 每个会话复用一条 TTS websocket，并在会话建立时预连接，
        # 否则每个句子都要重新握手，首音频延迟会多出数秒。
        if TTSSession is not None and self.tts is None:
            self.tts = TTSSession()

            async def _preconnect() -> None:
                try:
                    await self.tts.ensure()
                except Exception as exc:
                    print(f"[public-webrtc] tts preconnect failed (will retry per sentence): {exc}", flush=True)

            asyncio.create_task(_preconnect())
        try:
            while True:
                item = await self.queue.get()
                if item is None:
                    return
                await self._handle_pcm(item)
        finally:
            if self.tts is not None:
                try:
                    await self.tts.close()
                except Exception:
                    pass

    _dbg_frames: int = 0

    async def _handle_pcm(self, pcm: bytes) -> None:
        now = _now_ms()
        active = _rms(pcm) >= RMS_THRESHOLD
        if os.getenv("PUBLIC_RTC_DEBUG_VAD", "0") == "1":
            self._dbg_frames += 1
            if self._dbg_frames % 25 == 0 or (active and not self.speech_active):
                print(f"[public-webrtc][vad] n={self._dbg_frames} bytes={len(pcm)} rms={_rms(pcm):.4f} active={active} speech_active={self.speech_active} buffered_ms={_pcm_duration_ms(bytes(self.audio))}", flush=True)
        if active:
            if self.speaking and not self.cancelled:
                self.cancel_round()
                await self.send({"type": "response.cancelled", "event_id": _event_id(), "reason": "barge_in"})
            if not self.speech_active:
                self.speech_active = True
                self.started_at_ms = now
                await self.send({"type": "input_audio_buffer.speech_started", "event_id": _event_id()})
            self.last_voice_ms = now
            self.audio.extend(pcm)
            return

        if self.speech_active:
            self.audio.extend(pcm)
            silence = now - (self.last_voice_ms or now)
            total = _pcm_duration_ms(bytes(self.audio))
            if silence >= MAX_SILENCE_MS and total >= MIN_UTTERANCE_MS:
                await self._commit(bytes(self.audio))
                self.audio.clear()
                self.speech_active = False
                self.started_at_ms = None
                self.last_voice_ms = None

    async def _commit(self, pcm: bytes) -> None:
        self.round_id += 1
        rid = f"rsp_{self.round_id}_{uuid.uuid4().hex[:8]}"
        started = _now_ms()
        # 新回合开始 = 上一回合作废（防止旧回合霸占共享 TTS 连接、新回合排队）
        if self.cancel_event is not None:
            self.cancel_event.set()
        self._clear_output()
        self.cancelled = False
        await self.send(
            {
                "type": "input_audio_buffer.speech_stopped",
                "event_id": _event_id(),
                "audio_ms": _pcm_duration_ms(pcm),
            }
        )
        await self.send({"type": "input_audio_buffer.committed", "event_id": _event_id(), "item_id": rid})
        asyncio.create_task(self._run_round(rid, pcm, started, self.round_id))

    async def _run_round(self, response_id: str, pcm: bytes, started_ms: float, round_no: int = 0) -> None:
        # 回合代数判废：self.cancelled 是会话级标志，会被下一回合重置（有竞态）；
        # round_id 只增不减，stale 判断不受任何重置影响。
        def _stale() -> bool:
            return round_no != self.round_id
        self.speaking = True
        first_audio_ms: Optional[float] = None
        try:
            if _run_asr is None or run_voice_pipeline is None:
                raise RuntimeError("voice_pipeline is not available")
            text = await _run_asr(pcm)
            text = (text or "").strip()
            if not text or _stale():
                await self.send({"type": "response.done", "event_id": _event_id(), "response": {"id": response_id, "status": "completed" if text else "cancelled"}})
                return

            await self.send(
                {
                    "type": "conversation.item.input_audio_transcription.completed",
                    "event_id": _event_id(),
                    "item_id": response_id,
                    "transcript": text,
                }
            )
            await self.send(
                {
                    "type": "response.created",
                    "event_id": _event_id(),
                    "response": {"id": response_id, "object": "realtime.response", "status": "in_progress"},
                }
            )
            async def on_text(delta: str) -> None:
                if self.cancelled or _stale():
                    return
                await self.send(
                    {
                        "type": "response.text.delta",
                        "event_id": _event_id(),
                        "response_id": response_id,
                        "delta": delta,
                    }
                )

            _audio_seq = 0

            async def on_audio_chunk(chunk: bytes) -> None:
                nonlocal first_audio_ms, _audio_seq
                if self.cancelled or _stale() or not chunk:
                    return
                _audio_seq += 1
                if first_audio_ms is None:
                    first_audio_ms = _now_ms() - started_ms
                    await self.send(
                        {
                            "type": "response.audio.started",
                            "event_id": _event_id(),
                            "response_id": response_id,
                            "latency_ms": round(first_audio_ms, 1),
                        }
                    )
                if self.audio_output:
                    self.audio_output.enqueue_pcm16(chunk, sample_rate=TTS_SAMPLE_RATE)
                if self._should_send_audio_delta():
                    b64 = base64.b64encode(chunk).decode("ascii")
                    await self.send(
                        {
                            "type": "response.output_audio.delta",
                            "event_id": _event_id(),
                            "response_id": response_id,
                            "sequence": _audio_seq,  # 防"旧音频复活"：客户端按 id+seq 丢弃已取消回合的迟到包
                            "delta": b64,
                            "sample_rate": TTS_SAMPLE_RATE,
                        }
                    )
                    await self.send(
                        {
                            "type": "audio",
                            "event_id": _event_id(),
                            "b64": b64,
                            "format": "pcm_s16le",
                            "sample_rate": TTS_SAMPLE_RATE,
                        }
                    )

            cancel_event = asyncio.Event()
            if self.cancelled or _stale():
                cancel_event.set()
            else:
                self.cancel_event = cancel_event
            result = await run_voice_pipeline(
                text,
                conversation_history=list(self.history),
                on_sentence=on_text,
                on_audio_chunk=on_audio_chunk,
                cancel_event=cancel_event,
                tts_session=self.tts,
            )
            reply = (result or {}).get("assistant_text") or ""
            if not _stale():
                self.history.append({"role": "user", "content": text})
                if reply:
                    self.history.append({"role": "assistant", "content": reply})
            await self.send({"type": "response.output_audio.done", "event_id": _event_id(), "response_id": response_id})
            await self.send({"type": "audio_end", "event_id": _event_id(), "response_id": response_id})
            await self.send(
                {
                    "type": "response.done",
                    "event_id": _event_id(),
                    "response": {
                        "id": response_id,
                        "status": "cancelled" if (self.cancelled or _stale()) else "completed",
                        "latency_ms": round(first_audio_ms or 0.0, 1),
                        "output": [{"type": "message", "role": "assistant", "content": reply}],
                    },
                }
            )
        except Exception as exc:
            await self.send(
                {
                    "type": "error",
                    "event_id": _event_id(),
                    "error": {"message": str(exc), "type": exc.__class__.__name__},
                }
            )
        finally:
            # 只有仍是当前回合才允许重置会话状态，否则会踩掉新回合的 speaking/cancelled
            if not _stale():
                self.speaking = False
                self.cancelled = False


async def _consume_audio_track(session: RtcVoiceSession, track: Any) -> None:
    session.media_input_seen = True
    resampler = None
    if AudioResampler is not None:
        try:
            resampler = AudioResampler(format="s16", layout="mono", rate=SAMPLE_RATE)
        except Exception as exc:
            print(f"[public-webrtc] input resampler unavailable: {exc}", flush=True)
            resampler = None
    try:
        while True:
            frame = await track.recv()
            frames = [frame]
            if resampler is not None:
                frames = resampler.resample(frame)
                if frames is None:
                    frames = []
                elif not isinstance(frames, list):
                    frames = [frames]
            for out_frame in frames:
                pcm = _array_to_pcm16(out_frame.to_ndarray())
                if pcm:
                    session.enqueue(pcm)
    except asyncio.CancelledError:
        raise
    except Exception as exc:
        print(f"[public-webrtc] audio track ended: {exc}", flush=True)


def _ice_servers() -> list[Any]:
    if RTCIceServer is None:
        return []
    servers: list[Any] = []
    stun = os.getenv("PUBLIC_RTC_STUN_URL", "stun:stun.l.google.com:19302")
    if stun:
        servers.append(RTCIceServer(urls=[stun]))
    turn = os.getenv("PUBLIC_RTC_TURN_URL", "")
    if turn:
        servers.append(
            RTCIceServer(
                urls=[turn],
                username=os.getenv("PUBLIC_RTC_TURN_USERNAME", ""),
                credential=os.getenv("PUBLIC_RTC_TURN_PASSWORD", ""),
            )
        )
    return servers


async def create_answer(payload: dict[str, Any]) -> dict[str, Any]:
    if not available():
        raise RuntimeError("aiortc/voice_pipeline is not available")

    session_id = payload.get("session_id") or "rtc_" + uuid.uuid4().hex[:16]
    config = RTCConfiguration(iceServers=_ice_servers()) if RTCConfiguration else None
    pc = RTCPeerConnection(configuration=config)
    _pcs[session_id] = pc

    audio_output = AduAudioOutputTrack(session_id=session_id) if media_track_available() else None
    if audio_output is not None:
        pc.addTrack(audio_output)

    session: Optional[RtcVoiceSession] = None
    session_task: Optional[asyncio.Task] = None
    track_tasks: list[asyncio.Task] = []

    def ensure_session(channel: Any | None = None) -> RtcVoiceSession:
        nonlocal session, session_task
        if session is None:
            session = RtcVoiceSession(
                channel=channel or NullChannel(),
                session_id=session_id,
                audio_output=audio_output,
            )
            _sessions[session_id] = session
            session_task = asyncio.create_task(session.run())
            session_task.add_done_callback(lambda _task: _sessions.pop(session_id, None))
        elif channel is not None:
            session.channel = channel
            session.channel_label = getattr(channel, "label", "") or session.channel_label
        return session

    @pc.on("datachannel")
    def _on_datachannel(channel: Any) -> None:
        active_session = ensure_session(channel)
        active_session.channel_label = getattr(channel, "label", "") or ""

        @channel.on("message")
        def _on_message(message: Any) -> None:
            try:
                if isinstance(message, bytes):
                    active_session.enqueue(message)
                    return
                if not isinstance(message, str):
                    return
                data = json.loads(message)
                mtype = data.get("type")
                if mtype == "input_audio_buffer.append":
                    raw = base64.b64decode(data.get("audio") or data.get("delta") or "")
                    active_session.enqueue(raw)
                elif mtype == "input_audio_buffer.commit":
                    if active_session.audio:
                        asyncio.create_task(active_session._commit(bytes(active_session.audio)))
                        active_session.audio.clear()
                        active_session.speech_active = False
                elif mtype == "input_audio_buffer.clear":
                    active_session.audio.clear()
                    active_session._clear_output()
                elif mtype == "response.cancel":
                    active_session.cancel_round()
            except Exception as exc:
                asyncio.create_task(
                    active_session.send(
                        {
                            "type": "error",
                            "event_id": _event_id(),
                            "error": {"message": str(exc), "type": exc.__class__.__name__},
                        }
                    )
                )

    @pc.on("track")
    def _on_track(track: Any) -> None:
        if getattr(track, "kind", "") != "audio":
            return
        active_session = ensure_session()
        task = asyncio.create_task(_consume_audio_track(active_session, track))
        track_tasks.append(task)

    @pc.on("connectionstatechange")
    async def _on_connectionstatechange() -> None:
        if pc.connectionState in {"failed", "closed", "disconnected"}:
            if session is not None:
                await session.queue.put(None)
            for task in track_tasks:
                task.cancel()
            _pcs.pop(session_id, None)

    offer_sdp = payload.get("sdp") or payload.get("offer") or payload.get("offer_sdp")
    if not offer_sdp:
        raise ValueError("missing SDP offer")
    offer_type = payload.get("type") or "offer"
    await pc.setRemoteDescription(RTCSessionDescription(sdp=offer_sdp, type=offer_type))
    _normalize_transceiver_directions(pc)
    answer = await pc.createAnswer()
    await pc.setLocalDescription(answer)
    answer_sdp = _sanitize_sdp_answer_for_ios(pc.localDescription.sdp)

    # Make sure a media-only client still gets a session object and lifecycle logs.
    ensure_session()

    return {
        "ok": True,
        "session_id": session_id,
        "sdp": answer_sdp,
        "type": pc.localDescription.type,
        "transport": "webrtc-media-track+datachannel",
        "media_track_available": media_track_available(),
        "data_channel_audio_deltas": OPENAI_AUDIO_DELTAS,
        "ice": {"servers": [getattr(s, "urls", []) for s in _ice_servers()]},
    }


async def close_all() -> None:
    for session in list(_sessions.values()):
        await session.queue.put(None)
    for pc in list(_pcs.values()):
        await pc.close()
    _pcs.clear()
    _sessions.clear()


def status() -> dict[str, Any]:
    return {
        "ok": available(),
        "transport": "webrtc-media-track+datachannel",
        "active_peer_connections": len(_pcs),
        "active_sessions": len(_sessions),
        "sample_rate": SAMPLE_RATE,
        "tts_sample_rate": TTS_SAMPLE_RATE,
        "output_sample_rate": OUTPUT_SAMPLE_RATE,
        "media_track_available": media_track_available(),
        "datachannel_audio_for_openai": OPENAI_AUDIO_DELTAS,
        "endpoint": {"silence_ms": MAX_SILENCE_MS, "min_utterance_ms": MIN_UTTERANCE_MS, "rms": RMS_THRESHOLD},
    }


def register_public_webrtc_voice(app: Any) -> None:
    from fastapi import Body, HTTPException, Request
    from fastapi.responses import HTMLResponse, JSONResponse, PlainTextResponse
    from fastapi.staticfiles import StaticFiles

    if _WEB_ROOT.exists():
        app.mount("/rtc-static", StaticFiles(directory=str(_WEB_ROOT)), name="rtc-static")

    @app.get("/v1/realtime/webrtc/status")
    async def _rtc_status() -> JSONResponse:
        return JSONResponse(status())

    @app.post("/v1/realtime/webrtc/sessions")
    async def _rtc_session(body: dict[str, Any] = Body(default_factory=dict)) -> JSONResponse:
        if not available():
            raise HTTPException(status_code=503, detail=status())
        return JSONResponse(await create_answer(body))

    @app.post("/v1/realtime/calls")
    async def _openai_raw_sdp_calls(request: Request) -> Any:
        if not available():
            raise HTTPException(status_code=503, detail=status())
        ctype = request.headers.get("content-type", "")
        accept = request.headers.get("accept", "")
        if "application/sdp" in ctype:
            offer_sdp = (await request.body()).decode("utf-8", errors="replace")
            payload = {"sdp": offer_sdp, "type": "offer"}
        else:
            payload = await request.json()
        answer = await create_answer(payload)
        if "application/sdp" in accept or "application/sdp" in ctype:
            return PlainTextResponse(
                answer["sdp"],
                status_code=201,
                media_type="application/sdp",
                headers={
                    "X-Adu-Realtime-Protocol": "openai-raw-sdp",
                    "X-Adu-Transport-Provider": "aiortc-sdp-bridge",
                    "X-Adu-Session-Id": answer["session_id"],
                },
            )
        return JSONResponse(answer)

    @app.get("/v1/realtime/webrtc")
    async def _rtc_page() -> HTMLResponse:
        html = """<!doctype html>
<html><head><meta charset='utf-8'><title>Adu WebRTC Realtime</title></head>
<body style='font-family:system-ui;background:#0b0d10;color:#e8eef6'>
<h3>Adu WebRTC Realtime</h3>
<p>POST raw SDP to <code>/v1/realtime/calls</code>, OpenAI Realtime style.</p>
<script>console.log('Adu WebRTC status:', %s)</script>
</body></html>""" % json.dumps(status(), ensure_ascii=False)
        return HTMLResponse(html)
