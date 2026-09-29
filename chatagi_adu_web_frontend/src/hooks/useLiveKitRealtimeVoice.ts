// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-8c71e8d7bbb79c98c452dc873f1719c589a73f22b9af3007aa3583b8ee074892"
// Source-SHA256: "0a0d4efc44e86d8632f3455c9367ff847c74dadb9395d9817efdbf3e0c41e6a2"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import { useCallback, useRef, useState } from "react";
import { Room, RoomEvent, Track, createLocalAudioTrack } from "livekit-client";
import {
  checkLiveKitRealtimeHealth,
  createLiveKitRealtimeSession,
  RealtimeProbeResult,
} from "../api/realtimeApi";
import type { RealtimeVoiceStatus } from "./useRealtimeVoice";

const STATUS_TEXT: Record<RealtimeVoiceStatus, string> = {
  idle: "LiveKit WebRTC 待命",
  checking: "检查 LiveKit 后端",
  requesting_microphone: "请求麦克风权限",
  connecting: "接入 LiveKit 房间",
  connected: "LiveKit 实时语音已连接",
  assistant_speaking: "助手正在播报",
  stopping: "正在断开",
  error: "LiveKit 连接异常",
};

function friendlyLiveKitError(error: unknown): string {
  if (error instanceof Error) {
    const text = error.message || String(error);
    if (/permission|denied|microphone/i.test(text)) return "麦克风权限被拒绝，请在浏览器设置里允许麦克风。";
    if (/LIVEKIT|LiveKit|token|session/i.test(text)) return text;
    return text;
  }
  return "LiveKit 实时语音连接失败";
}

function decodePayload(payload: unknown): string {
  if (typeof payload === "string") return payload;
  if (payload instanceof ArrayBuffer) return new TextDecoder().decode(payload);
  if (payload instanceof Uint8Array) return new TextDecoder().decode(payload);
  return "";
}

function pickText(data: any): string {
  return String(
    data?.text ??
      data?.delta ??
      data?.transcript ??
      data?.user_text ??
      data?.assistant_text ??
      data?.payload?.text ??
      data?.payload?.delta ??
      "",
  );
}

function isAudioTrack(track: any): boolean {
  const kind = String(track?.kind || track?.mediaStreamTrack?.kind || "").toLowerCase();
  return kind === "audio" || kind === String((Track as any).Kind?.Audio || "audio").toLowerCase();
}

export function useLiveKitRealtimeVoice() {
  const [status, setStatus] = useState<RealtimeVoiceStatus>("idle");
  const [errorText, setErrorText] = useState("");
  const [amplitude, setAmplitude] = useState(0);
  const [lastUserText, setLastUserText] = useState("");
  const [lastAssistantText, setLastAssistantText] = useState("");

  const roomRef = useRef<any>(null);
  const localTrackRef = useRef<any>(null);
  const remoteAudioRef = useRef<HTMLAudioElement | null>(null);
  const audioContextRef = useRef<AudioContext | null>(null);
  const rafRef = useRef<number | null>(null);
  const startingRef = useRef(false);
  const stoppingRef = useRef(false);

  const setVoiceStatus = useCallback((next: RealtimeVoiceStatus) => {
    setStatus(next);
  }, []);

  const cleanupAnalyser = useCallback(() => {
    if (rafRef.current) cancelAnimationFrame(rafRef.current);
    rafRef.current = null;
    if (audioContextRef.current) {
      void audioContextRef.current.close().catch(() => undefined);
      audioContextRef.current = null;
    }
    setAmplitude(0);
  }, []);

  const startAnalyser = useCallback(
    (stream: MediaStream) => {
      cleanupAnalyser();
      try {
        const AudioContextClass = window.AudioContext || (window as any).webkitAudioContext;
        const ctx = new AudioContextClass();
        const source = ctx.createMediaStreamSource(stream);
        const analyser = ctx.createAnalyser();
        analyser.fftSize = 256;
        const data = new Uint8Array(analyser.frequencyBinCount);
        source.connect(analyser);
        audioContextRef.current = ctx;

        const tick = () => {
          analyser.getByteTimeDomainData(data);
          let peak = 0;
          for (const sample of data) peak = Math.max(peak, Math.abs(sample - 128) / 128);
          setAmplitude((value) => value * 0.72 + Math.min(1, peak * 2.4) * 0.28);
          rafRef.current = requestAnimationFrame(tick);
        };
        tick();
      } catch {
        setAmplitude(0.28);
      }
    },
    [cleanupAnalyser],
  );

  const sendControl = useCallback((event: Record<string, unknown>) => {
    const room = roomRef.current;
    if (!room?.localParticipant) return false;
    const payload = new TextEncoder().encode(JSON.stringify({ ...event, ts: Date.now(), source: "chatagi-adu-web" }));
    try {
      const result = room.localParticipant.publishData(payload, { reliable: true, topic: "adu.control" });
      void Promise.resolve(result).catch(() => undefined);
      return true;
    } catch {
      try {
        const result = room.localParticipant.publishData(payload, "reliable", { topic: "adu.control" });
        void Promise.resolve(result).catch(() => undefined);
        return true;
      } catch {
        return false;
      }
    }
  }, []);

  const handleServerEvent = useCallback((payload: unknown) => {
    const raw = decodePayload(payload);
    if (!raw) return;
    let data: any = null;
    try {
      data = JSON.parse(raw);
    } catch {
      data = { type: "assistant.text", text: raw };
    }

    const type = String(data.type || data.event || data.state || "").toLowerCase();
    const text = pickText(data);
    if (text) {
      if (/user|input|transcript|asr/.test(type)) {
        setLastUserText(text);
      } else if (/assistant|reply|response|tts|text|delta/.test(type)) {
        setLastAssistantText((prev) => (type.includes("delta") ? `${prev}${text}` : text));
      }
    }

    if (/speaking|audio|tts|first_audio|assistant/.test(type)) setVoiceStatus("assistant_speaking");
    if (/listen|idle|done|complete|end/.test(type)) setVoiceStatus("connected");
    if (/error/.test(type)) {
      setErrorText(text || String(data.message || "LiveKit 语音事件异常"));
      setVoiceStatus("error");
    }
  }, [setVoiceStatus]);

  const detachRemoteAudio = useCallback(() => {
    const audio = remoteAudioRef.current;
    if (audio) {
      audio.pause();
      audio.srcObject = null;
      audio.remove();
    }
    remoteAudioRef.current = null;
  }, []);

  const stop = useCallback(async () => {
    stoppingRef.current = true;
    setVoiceStatus("stopping");
    sendControl({ type: "interrupt", reason: "client_stop" });
    cleanupAnalyser();
    detachRemoteAudio();

    try {
      localTrackRef.current?.stop?.();
    } catch {
      // ignore
    }
    localTrackRef.current = null;

    try {
      await roomRef.current?.disconnect?.();
    } catch {
      // ignore
    }
    roomRef.current = null;
    startingRef.current = false;
    stoppingRef.current = false;
    setVoiceStatus("idle");
  }, [cleanupAnalyser, detachRemoteAudio, sendControl, setVoiceStatus]);

  const start = useCallback(
    async (options: { model?: string; plan?: string } = {}) => {
      if (startingRef.current || roomRef.current) return;
      startingRef.current = true;
      stoppingRef.current = false;
      setErrorText("");
      setLastUserText("");
      setLastAssistantText("");

      try {
        setVoiceStatus("checking");
        const session = await createLiveKitRealtimeSession(options);

        setVoiceStatus("requesting_microphone");
        const localTrack = await createLocalAudioTrack({
          echoCancellation: true,
          noiseSuppression: true,
          autoGainControl: true,
        });
        localTrackRef.current = localTrack;
        const mediaStreamTrack = (localTrack as any).mediaStreamTrack;
        if (mediaStreamTrack) startAnalyser(new MediaStream([mediaStreamTrack]));

        const room: any = new Room({ adaptiveStream: false, dynacast: false });
        roomRef.current = room;

        room.on(RoomEvent.DataReceived, (payload: unknown, _participant: unknown, _kind: unknown, topic?: string) => {
          if (!topic || topic === "adu.events") handleServerEvent(payload);
        });
        room.on(RoomEvent.TrackSubscribed, async (track: any) => {
          if (!isAudioTrack(track)) return;
          detachRemoteAudio();
          const audio = document.createElement("audio");
          audio.autoplay = true;
          audio.setAttribute("playsinline", "");
          audio.style.display = "none";
          document.body.appendChild(audio);
          remoteAudioRef.current = audio;
          try {
            if (typeof track.attach === "function") track.attach(audio);
            else if (track.mediaStreamTrack) audio.srcObject = new MediaStream([track.mediaStreamTrack]);
            await audio.play();
          } catch {
            // Browser autoplay may require user gesture; the mic button already supplies one in normal use.
          }
          setVoiceStatus("assistant_speaking");
        });
        room.on(RoomEvent.TrackUnsubscribed, (track: any) => {
          if (isAudioTrack(track)) {
            try {
              track.detach?.().forEach((el: HTMLMediaElement) => el.remove());
            } catch {
              // ignore
            }
            detachRemoteAudio();
            if (!stoppingRef.current) setVoiceStatus("connected");
          }
        });
        room.on(RoomEvent.Disconnected, () => {
          if (!stoppingRef.current) {
            setErrorText("LiveKit 房间连接已断开");
            setVoiceStatus("error");
          }
        });

        setVoiceStatus("connecting");
        await room.connect(session.livekit.url, session.livekit.token, { autoSubscribe: true });
        await room.localParticipant.publishTrack(localTrack, {
          name: "adu-user-mic",
          source: Track.Source.Microphone,
        });
        setVoiceStatus("connected");
        sendControl({ type: "warmup", room: session.livekit.room });
      } catch (error) {
        setErrorText(friendlyLiveKitError(error));
        await stop();
        setVoiceStatus("error");
      } finally {
        startingRef.current = false;
      }
    },
    [detachRemoteAudio, handleServerEvent, sendControl, setVoiceStatus, startAnalyser, stop],
  );

  const toggle = useCallback(async (options?: { model?: string; plan?: string }) => {
    if (roomRef.current || startingRef.current) await stop();
    else await start(options || {});
  }, [start, stop]);

  const probe = useCallback(async (): Promise<RealtimeProbeResult> => {
    const health = await checkLiveKitRealtimeHealth();
    if (!health.ok || health.ready === false) {
      return { ok: false, summary: health.reason || "LiveKit 后端未就绪", details: health };
    }
    return { ok: true, summary: "LiveKit WebRTC 实时语音后端可用", details: health };
  }, []);

  return {
    status,
    statusText: STATUS_TEXT[status],
    errorText,
    amplitude,
    lastUserText,
    lastAssistantText,
    isActive: status !== "idle" && status !== "error",
    start,
    stop,
    toggle,
    probe,
  };
}
