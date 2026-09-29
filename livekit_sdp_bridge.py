# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-52fcd67fe320d856dd6b7820a4ede74c79d2f3ea2b6083183becd363b6fe23b9"
# Source-SHA256: "c8b83d6b0e6cf7d20722e5235c234b0709f06396e7c1606f87f66140f1d29090"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""SDP <-> LiveKit 桥：把 OpenAI Realtime raw-SDP 客户端接到云端三段 agent。

App 侧协议不变（POST /v1/realtime/calls 换 SDP answer，datachannel "oai-events"，
音频走媒体轨）；服务端 aiortc 终结 App 的 WebRTC 后，以参与者身份加入 LiveKit
房间并 dispatch 云端 adu-three-stage-agent：

  App mic ──aiortc──▶ 本桥 ──LiveKit──▶ 云端 agent (fun-asr → brain → qwen-tts)
  App 扬声器 ◀─aiortc── 本桥 ◀─LiveKit── agent TTS 音轨
  App oai-events ◀── 本桥翻译 adu.events → OpenAI 事件；response.cancel → adu.control interrupt
"""

from __future__ import annotations

import asyncio
import audioop
import json
import os
import time
import uuid
from typing import Any, Optional

try:
    from aiortc import RTCConfiguration, RTCIceServer, RTCPeerConnection, RTCSessionDescription
    from av.audio.resampler import AudioResampler
except Exception:  # pragma: no cover
    RTCConfiguration = None  # type: ignore
    RTCIceServer = None  # type: ignore
    RTCPeerConnection = None  # type: ignore
    RTCSessionDescription = None  # type: ignore
    AudioResampler = None  # type: ignore

try:
    from livekit import rtc as lk_rtc
except Exception:  # pragma: no cover
    lk_rtc = None  # type: ignore

from public_webrtc_voice import (
    AduAudioOutputTrack,
    _array_to_pcm16,
    _normalize_transceiver_directions,
    _sanitize_sdp_answer_for_ios,
    media_track_available,
)
from livekit_sessions import create_realtime_session_async

LK_INPUT_RATE = 16000

_bridges: dict[str, "LiveKitSdpBridge"] = {}


def available() -> bool:
    return bool(
        RTCPeerConnection
        and lk_rtc is not None
        and media_track_available()
        and os.environ.get("LIVEKIT_URL", "").strip()
        and os.environ.get("LIVEKIT_API_KEY", "").strip()
        and os.environ.get("LIVEKIT_API_SECRET", "").strip()
    )


def _eid() -> str:
    return "evt_" + uuid.uuid4().hex[:16]


def _translate_adu_event(obj: dict[str, Any]) -> list[dict[str, Any]]:
    """云端 worker 的 adu.events → App 认识的 OpenAI Realtime 事件。未知类型原样透传。"""
    t = str(obj.get("type") or "")
    r = obj.get("r") or obj.get("round") or 0
    if t == "partial":
        return [{
            "type": "conversation.item.input_audio_transcription.delta",
            "event_id": _eid(),
            "delta": obj.get("text", ""),
        }]
    if t == "round":
        return [{
            "type": "conversation.item.input_audio_transcription.completed",
            "event_id": _eid(),
            "item_id": f"item_r{r}",
            "transcript": obj.get("text", ""),
        }]
    if t == "state":
        if obj.get("value") == "thinking":
            return [{
                "type": "response.created",
                "event_id": _eid(),
                "response": {"id": f"resp_r{r}", "object": "realtime.response", "status": "in_progress"},
            }]
        return [obj]
    if t == "delta":
        return [{
            "type": "response.text.delta",
            "event_id": _eid(),
            "response_id": f"resp_r{r}",
            "delta": obj.get("text", ""),
        }]
    if t == "audio_end":
        return [
            {"type": "response.output_audio.done", "event_id": _eid(), "response_id": f"resp_r{r}"},
            {"type": "audio_end", "event_id": _eid(), "response_id": f"resp_r{r}"},
            {
                "type": "response.done",
                "event_id": _eid(),
                "response": {"id": f"resp_r{r}", "status": "completed"},
            },
        ]
    if t == "bargein":
        return [{"type": "response.cancelled", "event_id": _eid(), "reason": "barge_in", "response_id": f"resp_r{r}"}]
    if t == "error":
        return [{"type": "error", "event_id": _eid(), "error": {"message": str(obj)[:300], "type": "adu_cloud"}}]
    return [obj]


class LiveKitSdpBridge:
    def __init__(self, session_id: str):
        self.session_id = session_id
        self.channel: Any = None
        self.audio_output = AduAudioOutputTrack(session_id=session_id)
        self.lk_room: Optional[Any] = None
        self.lk_source: Optional[Any] = None
        self.tasks: list[asyncio.Task] = []
        self.closed = False
        self.lk_info: dict[str, Any] = {}
        self.app_frames = 0  # 收到的 App 麦克风帧数；0 = 媒体通路没打通

    # ── App 方向 ──

    def send_event(self, obj: dict[str, Any]) -> None:
        try:
            if self.channel is not None and getattr(self.channel, "readyState", "") == "open":
                self.channel.send(json.dumps(obj, ensure_ascii=False))
        except Exception as exc:  # noqa: BLE001
            print(f"[lk-bridge] dc send failed: {exc}", flush=True)

    def on_app_message(self, message: Any) -> None:
        try:
            if not isinstance(message, str):
                return
            data = json.loads(message)
        except Exception:
            return
        mtype = str(data.get("type") or "")
        if mtype == "ping":
            # 弱网心跳：SDK 每 5s 一发，超时未见 pong 即自动重连
            self.send_event({"type": "pong", "t": data.get("t")})
            return
        if mtype in ("response.cancel", "input_audio.speech_started"):
            asyncio.create_task(self.publish_control({"type": "interrupt"}))
            if mtype == "input_audio.speech_started":
                return
        elif mtype in {"session.update", "input_audio_buffer.clear"}:
            pass  # 音频走媒体轨；云端 agent 自带 VAD/打断
        # 其余客户端事件与云端 agent 无对应语义，忽略

    # ── LiveKit 方向 ──

    async def publish_control(self, obj: dict[str, Any]) -> None:
        if self.lk_room is None:
            return
        try:
            payload = json.dumps(obj, ensure_ascii=False).encode("utf-8")
            await self.lk_room.local_participant.publish_data(payload, reliable=True, topic="adu.control")
        except Exception as exc:  # noqa: BLE001
            print(f"[lk-bridge] control publish failed: {exc}", flush=True)

    async def connect_livekit(self) -> None:
        sess = await create_realtime_session_async({
            "client": "sdp-bridge",
            "identity": f"adu-bridge-{self.session_id[-8:]}",
        })
        lk = sess.get("livekit") or {}
        self.lk_info = {"room": lk.get("room"), "identity": lk.get("identity"), "dispatch": lk.get("dispatch")}
        room = lk_rtc.Room()
        self.lk_room = room

        @room.on("data_received")
        def _on_data(pkt: Any) -> None:
            topic = getattr(pkt, "topic", "") or ""
            if topic not in ("", "adu.events"):
                return
            try:
                obj = json.loads(bytes(pkt.data).decode("utf-8"))
            except Exception:
                return
            for ev in _translate_adu_event(obj):
                self.send_event(ev)

        @room.on("track_subscribed")
        def _on_track(track: Any, pub: Any, participant: Any) -> None:
            if track.kind != lk_rtc.TrackKind.KIND_AUDIO:
                return
            self.tasks.append(asyncio.create_task(self._pull_agent_audio(track)))

        await room.connect(str(lk.get("url")), str(lk.get("token")))
        self.lk_source = lk_rtc.AudioSource(LK_INPUT_RATE, 1)
        mic = lk_rtc.LocalAudioTrack.create_audio_track("adu-bridge-mic", self.lk_source)
        options = lk_rtc.TrackPublishOptions()
        try:
            options.source = lk_rtc.TrackSource.SOURCE_MICROPHONE
        except Exception:  # noqa: BLE001
            pass
        await room.local_participant.publish_track(mic, options)
        print(f"[lk-bridge] joined room={lk.get('room')} dispatch={json.dumps(lk.get('dispatch'), ensure_ascii=False)}", flush=True)

    async def _pull_agent_audio(self, track: Any) -> None:
        try:
            stream = lk_rtc.AudioStream(track)
            async for ev in stream:
                if self.closed:
                    break
                frame = ev.frame
                self.audio_output.enqueue_pcm16(bytes(frame.data), sample_rate=int(frame.sample_rate))
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001
            print(f"[lk-bridge] agent audio ended: {exc}", flush=True)

    async def pump_app_audio(self, track: Any) -> None:
        """App(aiortc) mic → 16k mono → LiveKit AudioSource。"""
        resampler = None
        if AudioResampler is not None:
            try:
                resampler = AudioResampler(format="s16", layout="mono", rate=LK_INPUT_RATE)
            except Exception as exc:  # noqa: BLE001
                print(f"[lk-bridge] input resampler unavailable: {exc}", flush=True)
        debug = os.getenv("LK_BRIDGE_DEBUG", "0") == "1"
        n = 0
        t0 = time.perf_counter()
        try:
            while not self.closed:
                frame = await track.recv()
                frames = [frame]
                if resampler is not None:
                    out = resampler.resample(frame)
                    frames = out if isinstance(out, list) else ([out] if out else [])
                for f in frames:
                    pcm = _array_to_pcm16(f.to_ndarray())
                    if pcm and self.lk_source is not None:
                        n += 1
                        self.app_frames = n
                        if debug and n % 50 == 1:
                            rms = audioop.rms(pcm, 2)
                            print(f"[lk-bridge][in] n={n} t={time.perf_counter()-t0:.1f}s bytes={len(pcm)} rms={rms}", flush=True)
                        lk_frame = lk_rtc.AudioFrame(
                            data=pcm,
                            sample_rate=LK_INPUT_RATE,
                            num_channels=1,
                            samples_per_channel=len(pcm) // 2,
                        )
                        await self.lk_source.capture_frame(lk_frame)
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001
            print(f"[lk-bridge] app audio ended after n={n} t={time.perf_counter()-t0:.1f}s: {type(exc).__name__}: {exc}", flush=True)

    async def _no_audio_watchdog(self) -> None:
        """媒体通路看门狗：连接建立后 App 音频迟迟不来 = 单向媒体故障/麦克风没起来。
        先通知 App（让它立刻重连，而不是让用户对着空气说 54 秒），超时则回收会话
        （每个僵死会话都占着一个云端 agent 空转）。"""
        warn_s = float(os.getenv("LK_BRIDGE_NO_AUDIO_WARN_S", "6"))
        close_s = float(os.getenv("LK_BRIDGE_NO_AUDIO_CLOSE_S", "20"))
        await asyncio.sleep(warn_s)
        if self.closed or self.app_frames:
            return
        print(f"[lk-bridge] {self.session_id} 连接后 {warn_s:.0f}s 无 App 音频（媒体通路未打通）→ 通知重连", flush=True)
        self.send_event({
            "type": "error",
            "event_id": _eid(),
            "error": {
                "type": "media_path_dead",
                "message": "未收到麦克风音频，媒体通路未打通，请重新连接。",
                "recoverable": True,
            },
        })
        await asyncio.sleep(max(1.0, close_s - warn_s))
        if not self.closed and not self.app_frames:
            print(f"[lk-bridge] {self.session_id} 无音频 {close_s:.0f}s → 回收会话（释放云端 agent）", flush=True)
            await self.close()

    async def close(self) -> None:
        _bridges.pop(self.session_id, None)  # 无条件先摘表：任何路径都不能把尸体留在会话表里
        if self.closed:
            return
        self.closed = True
        for task in self.tasks:
            task.cancel()
        if self.lk_room is not None:
            try:
                await self.lk_room.disconnect()
            except Exception:  # noqa: BLE001
                pass
        _bridges.pop(self.session_id, None)
        print(f"[lk-bridge] closed session={self.session_id}", flush=True)


async def create_answer(payload: dict[str, Any]) -> dict[str, Any]:
    if not available():
        raise RuntimeError("livekit sdp bridge unavailable (aiortc/livekit/env missing)")

    session_id = payload.get("session_id") or "lkb_" + uuid.uuid4().hex[:16]
    # 会话上限：App 重复连接产生的旧会话直接回收（每个都占一个云端 agent）。
    # 必须先 pop 再 close——close() 对已 closed 的会话会早退不摘表，
    # 依赖它摘表会让本循环死转、阻塞整个事件循环（2026-08-03 生产事故）。
    max_sessions = int(os.getenv("LK_BRIDGE_MAX_SESSIONS", "2"))
    while len(_bridges) >= max_sessions:
        oldest_id = next(iter(_bridges))
        bridge_old = _bridges.pop(oldest_id, None)
        print(f"[lk-bridge] 会话数达上限 {max_sessions}，回收最旧 {oldest_id}", flush=True)
        if bridge_old is not None:
            try:
                await bridge_old.close()
            except Exception:  # noqa: BLE001
                pass
    bridge = LiveKitSdpBridge(session_id)
    _bridges[session_id] = bridge

    stun = os.getenv("PUBLIC_RTC_STUN_URL", "stun:stun.l.google.com:19302")
    config = RTCConfiguration(iceServers=[RTCIceServer(urls=[stun])]) if (RTCConfiguration and stun) else None
    pc = RTCPeerConnection(configuration=config)
    pc.addTrack(bridge.audio_output)

    @pc.on("datachannel")
    def _on_datachannel(channel: Any) -> None:
        bridge.channel = channel
        bridge.send_event({
            "type": "session.created",
            "event_id": _eid(),
            "session": {
                "id": session_id,
                "object": "realtime.session",
                "model": os.getenv("ADU_OPENAI_COMPAT_MODEL") or "adu-three-stage-v2",
                "modalities": ["audio", "text"],
                "transport": "webrtc->livekit-cloud",
                "livekit_room": bridge.lk_info.get("room"),
            },
        })

        @channel.on("message")
        def _on_message(message: Any) -> None:
            bridge.on_app_message(message)

    @pc.on("track")
    def _on_track(track: Any) -> None:
        if getattr(track, "kind", "") != "audio":
            return
        bridge.tasks.append(asyncio.create_task(bridge.pump_app_audio(track)))

    @pc.on("connectionstatechange")
    async def _on_state() -> None:
        if pc.connectionState in {"failed", "closed", "disconnected"}:
            await bridge.close()

    # 先入房 + dispatch agent（±1s），再答 SDP——App 完成 ICE 时云端 agent 已就位
    await bridge.connect_livekit()
    bridge.tasks.append(asyncio.create_task(bridge._no_audio_watchdog()))

    offer_sdp = payload.get("sdp") or payload.get("offer") or payload.get("offer_sdp")
    if not offer_sdp:
        raise ValueError("missing SDP offer")
    await pc.setRemoteDescription(RTCSessionDescription(sdp=offer_sdp, type=payload.get("type") or "offer"))
    _normalize_transceiver_directions(pc)
    answer = await pc.createAnswer()
    await pc.setLocalDescription(answer)
    answer_sdp = _sanitize_sdp_answer_for_ios(pc.localDescription.sdp)

    return {
        "ok": True,
        "session_id": session_id,
        "sdp": answer_sdp,
        "type": pc.localDescription.type,
        "transport": "webrtc->livekit-cloud",
        "livekit": bridge.lk_info,
    }


def status() -> dict[str, Any]:
    return {
        "ok": available(),
        "active_bridges": len(_bridges),
        "rooms": [b.lk_info.get("room") for b in _bridges.values()],
    }
