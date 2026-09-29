// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-d15b124bf13155f546b57fdc2733beb0a2733f6936dda97c462a893fcfbc3195"
// Source-SHA256: "9cea6c24c6d6a534b51b2ae8b6547b91edcdaf5acb52a361ed6d85e3288d698b"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import { useCallback, useRef, useState } from "react";
import {
  checkNativeRealtimeHealth,
  connectNativeRealtimeSocket,
  createNativeRealtimeSession,
  NativeRealtimeSession,
  sendNativeEvent,
} from "../api/nativeRealtimeApi";
import { createMicPcmStream, MicPcmStream } from "../utils/audioPcm";

export type NativeRealtimeVoiceState =
  | "idle"
  | "checking"
  | "requesting_mic"
  | "connecting"
  | "listening"
  | "thinking"
  | "speaking"
  | "stopping"
  | "error";

export interface NativeRealtimeVoiceController {
  state: NativeRealtimeVoiceState;
  error: string;
  resultText: string;
  audioChunksSent: number;
  start: () => Promise<void>;
  stop: () => void;
  interrupt: () => void;
}

function friendlyError(err: unknown): string {
  const domName = err instanceof DOMException ? err.name : "";
  const message = err instanceof Error ? err.message : String(err || "");
  if (domName === "NotAllowedError" || domName === "SecurityError") return "麦克风权限未开启";
  if (message.includes("mediaDevices") || message.includes("getUserMedia")) return "当前浏览器不支持麦克风";
  if (message.includes("模型服务未接入") || message.includes("未就绪")) return "后端 realtime 模型服务未接入";
  return message || "实时语音连接失败";
}

export function useNativeRealtimeVoice(): NativeRealtimeVoiceController {
  const [state, setState] = useState<NativeRealtimeVoiceState>("idle");
  const [error, setError] = useState("");
  const [resultText, setResultText] = useState("");
  const [audioChunksSent, setAudioChunksSent] = useState(0);

  const stateRef = useRef<NativeRealtimeVoiceState>("idle");
  const wsRef = useRef<WebSocket | null>(null);
  const sessionRef = useRef<NativeRealtimeSession | null>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const micPcmRef = useRef<MicPcmStream | null>(null);
  const startingRef = useRef(false);

  const setVoiceState = useCallback((next: NativeRealtimeVoiceState) => {
    stateRef.current = next;
    setState(next);
  }, []);

  const cleanup = useCallback(() => {
    try { micPcmRef.current?.stop(); } catch {}
    micPcmRef.current = null;
    streamRef.current?.getTracks().forEach((track) => {
      try { track.stop(); } catch {}
    });
    streamRef.current = null;
    try { wsRef.current?.close(); } catch {}
    wsRef.current = null;
    sessionRef.current = null;
    startingRef.current = false;
  }, []);

  const handleServerEvent = useCallback((raw: string) => {
    let event: any = null;
    try {
      event = JSON.parse(raw);
    } catch {
      return;
    }
    const type = String(event?.type || "");
    if (type === "state") {
      const next = String(event.state || "");
      if (["listening", "thinking", "speaking", "stopped", "error"].includes(next)) {
        setVoiceState(next === "stopped" ? "idle" : next as NativeRealtimeVoiceState);
      }
      return;
    }
    if (type === "session.queue_done" || type === "session.created" || type === "session.updated") {
      setVoiceState("listening");
      return;
    }
    if (type === "result.text") {
      setResultText((prev) => `${prev}${event.text || ""}`.slice(-1000));
      return;
    }
    if (type === "result.audio_data") {
      setVoiceState("speaking");
      return;
    }
    if (type === "error") {
      setError(String(event.message || "实时语音连接失败"));
      setVoiceState("error");
    }
  }, [setVoiceState]);

  const start = useCallback(async () => {
    if (startingRef.current || stateRef.current !== "idle" && stateRef.current !== "error") return;
    startingRef.current = true;
    cleanup();
    setError("");
    setResultText("");
    setAudioChunksSent(0);

    try {
      setVoiceState("checking");
      const health = await checkNativeRealtimeHealth();
      if (!health.ok) throw new Error(health.reason || "实时语音健康检查失败");

      const session = await createNativeRealtimeSession();
      sessionRef.current = session;

      if (!navigator.mediaDevices?.getUserMedia) throw new Error("mediaDevices unavailable");
      setVoiceState("requesting_mic");
      const stream = await navigator.mediaDevices.getUserMedia({
        audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true },
      });
      streamRef.current = stream;

      setVoiceState("connecting");
      const ws = connectNativeRealtimeSocket(session);
      wsRef.current = ws;
      ws.onopen = () => {
        if (wsRef.current !== ws) return;
        sendNativeEvent(ws, {
          type: "session.update",
          config: { instructions: session.instructions || "你是 ChatAGI 阿杜实时语音模型，请用自然、简洁的中文回答。" },
        });
        sendNativeEvent(ws, { type: "mic_start" });
        micPcmRef.current = createMicPcmStream(stream, (chunk) => {
          if (sendNativeEvent(wsRef.current, {
            type: "input_audio_buffer.append",
            audio: chunk.audio,
            sample_rate: 16000,
            format: "pcm16",
          })) {
            setAudioChunksSent((count) => count + 1);
          }
        });
        setVoiceState("listening");
      };
      ws.onmessage = (event) => {
        if (typeof event.data === "string") handleServerEvent(event.data);
      };
      ws.onerror = () => {
        setError("WebSocket 连接失败");
        setVoiceState("error");
      };
      ws.onclose = () => {
        if (stateRef.current !== "idle" && stateRef.current !== "stopping") {
          cleanup();
          setError("WebSocket 已断开");
          setVoiceState("error");
        }
      };
      startingRef.current = false;
    } catch (err) {
      cleanup();
      setError(friendlyError(err));
      setVoiceState("error");
    }
  }, [cleanup, handleServerEvent, setVoiceState]);

  const stop = useCallback(() => {
    if (stateRef.current === "idle") return;
    setVoiceState("stopping");
    sendNativeEvent(wsRef.current, { type: "end_of_turn" });
    sendNativeEvent(wsRef.current, { type: "session.queue_done" });
    sendNativeEvent(wsRef.current, { type: "stop" });
    cleanup();
    setVoiceState("idle");
  }, [cleanup, setVoiceState]);

  const interrupt = useCallback(() => {
    sendNativeEvent(wsRef.current, { type: "interrupt" });
    setVoiceState("listening");
  }, [setVoiceState]);

  return {
    state,
    error,
    resultText,
    audioChunksSent,
    start,
    stop,
    interrupt,
  };
}
