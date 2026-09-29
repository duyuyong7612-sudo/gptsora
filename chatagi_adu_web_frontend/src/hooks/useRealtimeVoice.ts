// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-e34d8623f0a767a054b3a598078d78435846d0b5c87153f7299544b563b48da4"
// Source-SHA256: "4f4213b84e132a0579497e75f71b93aafc81d0a83ebff51b3d9fd491daec9ee2"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import { useCallback, useRef, useState } from "react";
import {
  connectNativeRealtimeWebSocket,
  createUnifiedRealtimeSession,
  NativeRealtimeSession,
  RealtimeProbeResult,
  realtimeProbe,
  sendRealtimeOffer,
} from "../api/realtimeApi";

export type RealtimeVoiceStatus =
  | "idle"
  | "checking"
  | "requesting_microphone"
  | "connecting"
  | "connected"
  | "assistant_speaking"
  | "stopping"
  | "error";

const STATUS_TEXT: Record<RealtimeVoiceStatus, string> = {
  idle: "未连接",
  checking: "正在检测实时语音后端...",
  requesting_microphone: "正在请求麦克风权限...",
  connecting: "正在连接实时语音...",
  connected: "正在聆听...",
  assistant_speaking: "阿杜正在回答...",
  stopping: "正在停止实时语音...",
  error: "实时语音连接失败",
};

const INPUT_SAMPLE_RATE = 16000;
const OUTPUT_SAMPLE_RATE = 24000;
const SEND_CHUNK_SAMPLES = Math.round(INPUT_SAMPLE_RATE * 0.25);

function friendlyRealtimeError(err: unknown): string {
  const name = err instanceof DOMException ? err.name : "";
  const message = err instanceof Error ? err.message : String(err || "");
  if (name === "NotAllowedError" || name === "SecurityError") return "麦克风权限未开启";
  if (message.includes("getUserMedia") || message.includes("mediaDevices")) return "当前浏览器不支持麦克风";
  if (message.includes("DASHSCOPE_API_KEY") || message.includes("阿里")) return "阿里实时语音未配置";
  if (message.includes("OPENAI_API_KEY") || message.includes("GPT")) return "GPT Realtime 未配置";
  if (message.includes("后端未就绪") || message.includes("not_ready")) return "实时语音后端未就绪";
  if (message.includes("unsupported_audio_format")) return "当前音频格式未被后端支持";
  return "实时语音连接失败，请重试";
}

function sendJson(ws: WebSocket | null, event: Record<string, unknown>) {
  if (!ws || ws.readyState !== WebSocket.OPEN) return false;
  ws.send(JSON.stringify(event));
  return true;
}

function resampleMono(input: Float32Array, inputRate: number, outputRate: number): Float32Array {
  if (inputRate === outputRate) return new Float32Array(input);
  const ratio = inputRate / outputRate;
  const outLength = Math.max(1, Math.floor(input.length / ratio));
  const output = new Float32Array(outLength);
  for (let i = 0; i < outLength; i += 1) {
    const pos = i * ratio;
    const left = Math.floor(pos);
    const right = Math.min(input.length - 1, left + 1);
    const frac = pos - left;
    output[i] = input[left] + (input[right] - input[left]) * frac;
  }
  return output;
}

function pcm16ToBase64(samples: Float32Array): string {
  const bytes = new Uint8Array(samples.length * 2);
  const view = new DataView(bytes.buffer);
  for (let i = 0; i < samples.length; i += 1) {
    const v = Math.max(-1, Math.min(1, samples[i] || 0));
    view.setInt16(i * 2, Math.max(-32768, Math.min(32767, Math.round(v * 32767))), true);
  }
  let binary = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

function base64ToBytes(b64: string) {
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i += 1) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

function isWave(bytes: Uint8Array): boolean {
  return bytes.length >= 12
    && String.fromCharCode(...bytes.subarray(0, 4)) === "RIFF"
    && String.fromCharCode(...bytes.subarray(8, 12)) === "WAVE";
}

function readEventText(json: any): string {
  return (
    json?.text ||
    json?.delta ||
    json?.transcript ||
    json?.item?.content?.[0]?.text ||
    json?.response?.output?.[0]?.content?.[0]?.text ||
    ""
  );
}

export function useRealtimeVoice() {
  const [status, setStatus] = useState<RealtimeVoiceStatus>("idle");
  const [errorText, setErrorText] = useState("");
  const [amplitude, setAmplitude] = useState(0);
  const [lastUserText, setLastUserText] = useState("");
  const [lastAssistantText, setLastAssistantText] = useState("");

  const wsRef = useRef<WebSocket | null>(null);
  const sessionRef = useRef<NativeRealtimeSession | null>(null);
  const peerRef = useRef<RTCPeerConnection | null>(null);
  const dataChannelRef = useRef<RTCDataChannel | null>(null);
  const remoteAudioRef = useRef<HTMLAudioElement | null>(null);
  const localStreamRef = useRef<MediaStream | null>(null);
  const audioCtxRef = useRef<AudioContext | null>(null);
  const sourceRef = useRef<MediaStreamAudioSourceNode | null>(null);
  const processorRef = useRef<ScriptProcessorNode | null>(null);
  const zeroGainRef = useRef<GainNode | null>(null);
  const playbackCtxRef = useRef<AudioContext | null>(null);
  const playbackNextTimeRef = useRef(0);
  const pendingSamplesRef = useRef<number[]>([]);
  const startingRef = useRef(false);
  const sessionUpdateSentRef = useRef(false);
  const statusRef = useRef<RealtimeVoiceStatus>("idle");
  const fallbackUpdateTimerRef = useRef<number | null>(null);

  const setVoiceStatus = useCallback((next: RealtimeVoiceStatus) => {
    statusRef.current = next;
    setStatus(next);
  }, []);

  const flushAudioChunk = useCallback((forceListen = false, reason = "chunk") => {
    const ws = wsRef.current;
    if (!ws || ws.readyState !== WebSocket.OPEN || pendingSamplesRef.current.length === 0) return;
    const samples = pendingSamplesRef.current.splice(0, pendingSamplesRef.current.length);
    const f32 = new Float32Array(samples);
    sendJson(ws, {
      type: "input_audio_buffer.append",
      audio: pcm16ToBase64(f32),
      format: "pcm16-base64",
      sample_rate: INPUT_SAMPLE_RATE,
      force_listen: forceListen,
      reason,
    });
  }, []);

  const stopPlayback = useCallback(() => {
    try {
      playbackCtxRef.current?.close();
    } catch {
      // ignore close races
    }
    playbackCtxRef.current = null;
    playbackNextTimeRef.current = 0;
  }, []);

  const cleanup = useCallback(() => {
    if (fallbackUpdateTimerRef.current !== null) {
      window.clearTimeout(fallbackUpdateTimerRef.current);
      fallbackUpdateTimerRef.current = null;
    }
    try {
      processorRef.current?.disconnect();
      sourceRef.current?.disconnect();
      zeroGainRef.current?.disconnect();
    } catch {
      // ignore disconnect races
    }
    processorRef.current = null;
    sourceRef.current = null;
    zeroGainRef.current = null;
    try {
      audioCtxRef.current?.close();
    } catch {
      // ignore close races
    }
    audioCtxRef.current = null;
    pendingSamplesRef.current = [];
    setAmplitude(0);

    localStreamRef.current?.getTracks().forEach((track) => {
      try {
        track.stop();
      } catch {
        // ignore stopped tracks
      }
    });
    localStreamRef.current = null;

    try {
      wsRef.current?.close();
    } catch {
      // ignore close races
    }
    wsRef.current = null;

    try {
      dataChannelRef.current?.close();
    } catch {
      // ignore close races
    }
    dataChannelRef.current = null;
    try {
      peerRef.current?.getSenders().forEach((sender) => sender.track?.stop());
      peerRef.current?.close();
    } catch {
      // ignore close races
    }
    peerRef.current = null;
    if (remoteAudioRef.current) {
      remoteAudioRef.current.pause();
      remoteAudioRef.current.srcObject = null;
    }
    remoteAudioRef.current = null;

    sessionRef.current = null;
    sessionUpdateSentRef.current = false;
    startingRef.current = false;
    stopPlayback();
  }, [stopPlayback]);

  const playAudioData = useCallback(async (b64: string) => {
    if (!b64) return;
    const bytes = base64ToBytes(b64);
    if (!bytes.length) return;
    setVoiceStatus("assistant_speaking");

    if (isWave(bytes)) {
      const url = URL.createObjectURL(new Blob([bytes], { type: "audio/wav" }));
      const audio = new Audio(url);
      audio.onended = () => {
        URL.revokeObjectURL(url);
        if (statusRef.current === "assistant_speaking") setVoiceStatus("connected");
      };
      audio.onerror = () => {
        URL.revokeObjectURL(url);
        if (statusRef.current === "assistant_speaking") setVoiceStatus("connected");
      };
      await audio.play().catch(() => {
        URL.revokeObjectURL(url);
      });
      return;
    }

    if (bytes.byteLength % 4 !== 0) {
      setErrorText("当前音频格式未被后端支持");
      return;
    }

    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const frames = bytes.byteLength / 4;
    const samples = new Float32Array(frames);
    for (let i = 0; i < frames; i += 1) {
      samples[i] = Math.max(-1, Math.min(1, view.getFloat32(i * 4, true)));
    }

    const Ctor = window.AudioContext || (window as any).webkitAudioContext;
    if (!Ctor) return;
    const ctx = playbackCtxRef.current || new Ctor({ sampleRate: OUTPUT_SAMPLE_RATE });
    playbackCtxRef.current = ctx;
    const buffer = ctx.createBuffer(1, samples.length, OUTPUT_SAMPLE_RATE);
    buffer.copyToChannel(samples, 0);
    const source = ctx.createBufferSource();
    source.buffer = buffer;
    source.connect(ctx.destination);
    const now = ctx.currentTime + 0.03;
    const when = Math.max(now, playbackNextTimeRef.current || now);
    playbackNextTimeRef.current = when + buffer.duration;
    source.onended = () => {
      if (ctx.currentTime + 0.05 >= playbackNextTimeRef.current && statusRef.current === "assistant_speaking") {
        setVoiceStatus("connected");
      }
    };
    source.start(when);
  }, [setVoiceStatus]);

  const startCapture = useCallback((stream: MediaStream) => {
    const Ctor = window.AudioContext || (window as any).webkitAudioContext;
    if (!Ctor) throw new Error("getUserMedia unsupported");
    const ctx = new Ctor();
    const source = ctx.createMediaStreamSource(stream);
    const processor = ctx.createScriptProcessor(4096, 1, 1);
    const zeroGain = ctx.createGain();
    zeroGain.gain.value = 0;

    processor.onaudioprocess = (event) => {
      const input = event.inputBuffer.getChannelData(0);
      const resampled = resampleMono(input, ctx.sampleRate, INPUT_SAMPLE_RATE);
      let sum = 0;
      for (let i = 0; i < resampled.length; i += 1) {
        const v = resampled[i] || 0;
        pendingSamplesRef.current.push(v);
        sum += v * v;
      }
      setAmplitude(Math.min(1, Math.sqrt(sum / Math.max(1, resampled.length)) * 5.2));
      while (pendingSamplesRef.current.length >= SEND_CHUNK_SAMPLES) {
        const chunk = pendingSamplesRef.current.splice(0, SEND_CHUNK_SAMPLES);
        const f32 = new Float32Array(chunk);
        sendJson(wsRef.current, {
          type: "input_audio_buffer.append",
          audio: pcm16ToBase64(f32),
          format: "pcm16-base64",
          sample_rate: INPUT_SAMPLE_RATE,
          force_listen: false,
        });
      }
    };

    source.connect(processor);
    processor.connect(zeroGain);
    zeroGain.connect(ctx.destination);
    audioCtxRef.current = ctx;
    sourceRef.current = source;
    processorRef.current = processor;
    zeroGainRef.current = zeroGain;
  }, []);

  const sendSessionUpdateAndStartMic = useCallback(() => {
    const session = sessionRef.current;
    const ws = wsRef.current;
    const stream = localStreamRef.current;
    if (!session || !ws || ws.readyState !== WebSocket.OPEN || !stream || sessionUpdateSentRef.current) return;
    sessionUpdateSentRef.current = true;
    sendJson(ws, {
      type: "session.update",
      session: {
        instructions: session.instructions || "你是 ChatAGI 阿杜实时语音模型，请用自然、简洁的中文回答。",
      },
      instructions: session.instructions || "你是 ChatAGI 阿杜实时语音模型，请用自然、简洁的中文回答。",
    });
    sendJson(ws, { type: "mic_start", sample_rate: INPUT_SAMPLE_RATE, format: "pcm16-base64" });
    startCapture(stream);
    setVoiceStatus("connected");
  }, [setVoiceStatus, startCapture]);

  const handleNativeEvent = useCallback((raw: string) => {
    let json: any = null;
    try {
      json = JSON.parse(raw);
    } catch {
      return;
    }
    const type = String(json?.type || "");
    if (type === "session.queue_done") {
      sendSessionUpdateAndStartMic();
      return;
    }
    if (type === "session.created" || type === "session.updated") {
      setVoiceStatus("connected");
      return;
    }
    if (type === "state") {
      const state = String(json?.state || "");
      if (state === "thinking" || state === "speaking") setVoiceStatus("assistant_speaking");
      else if (state === "error") setVoiceStatus("error");
      else if (state === "stopped") setVoiceStatus("idle");
      else setVoiceStatus("connected");
      return;
    }
    if (type === "input_audio_buffer.speech_started") {
      setVoiceStatus("connected");
      return;
    }
    if (type.includes("transcription") || type === "input_audio_buffer.committed") {
      const t = readEventText(json).trim();
      if (t) setLastUserText(t);
      return;
    }
    if (type === "result.text") {
      const t = readEventText(json);
      if (t) setLastAssistantText((prev) => `${prev}${t}`.slice(-260));
      if (json?.end_of_turn === true) setVoiceStatus("connected");
      return;
    }
    if (type === "result.audio_data") {
      const audio = json?.audio_data || json?.audio || json?.delta;
      if (typeof audio === "string" && audio) void playAudioData(audio);
      return;
    }
    if (type === "result" || type === "response.output_audio.delta" || type === "response.audio.delta") {
      const t = readEventText(json);
      if (t) setLastAssistantText((prev) => `${prev}${t}`.slice(-260));
      const audio = json?.audio_data || json?.audio || json?.delta;
      if (typeof audio === "string" && audio) void playAudioData(audio);
      if (json?.end_of_turn === true) setVoiceStatus("connected");
      return;
    }
    if (type === "response.listen") {
      stopPlayback();
      setVoiceStatus("connected");
      return;
    }
    if (type === "error") {
      setErrorText("实时语音连接失败，请重试");
      setVoiceStatus("error");
    }
  }, [playAudioData, sendSessionUpdateAndStartMic, setVoiceStatus, stopPlayback]);

  const stop = useCallback(async () => {
    if (statusRef.current === "idle") return;
    setVoiceStatus("stopping");
    flushAudioChunk(false, "stop");
    sendJson(wsRef.current, { type: "end_of_turn" });
    sendJson(wsRef.current, { type: "stop" });
    try {
      dataChannelRef.current?.send(JSON.stringify({ type: "response.cancel" }));
    } catch {
      // ignore data channel close races
    }
    cleanup();
    setErrorText("");
    setLastAssistantText("");
    setVoiceStatus("idle");
  }, [cleanup, flushAudioChunk, setVoiceStatus]);

  const startAliyunProxy = useCallback(async (session: NativeRealtimeSession, stream: MediaStream) => {
    sessionRef.current = session;
    setVoiceStatus("connecting");
    const ws = connectNativeRealtimeWebSocket(session);
    wsRef.current = ws;
    ws.onopen = () => {
      if (wsRef.current !== ws) return;
      fallbackUpdateTimerRef.current = window.setTimeout(() => {
        sendSessionUpdateAndStartMic();
      }, 120);
    };
    ws.onmessage = (event) => {
      if (typeof event.data === "string") handleNativeEvent(event.data);
    };
    ws.onerror = () => {
      if (wsRef.current === ws) {
        setErrorText("阿里实时语音未配置");
        setVoiceStatus("error");
      }
    };
    ws.onclose = () => {
      if (wsRef.current === ws && statusRef.current !== "stopping" && statusRef.current !== "idle") {
        cleanup();
        setErrorText("实时语音连接失败，请重试");
        setVoiceStatus("error");
      }
    };
    localStreamRef.current = stream;
  }, [cleanup, handleNativeEvent, sendSessionUpdateAndStartMic, setVoiceStatus]);

  const startOpenAiWebRtc = useCallback(async (
    session: NativeRealtimeSession,
    stream: MediaStream,
    options: { model?: string; plan?: string } = {},
  ) => {
    setVoiceStatus("connecting");
    const pc = new RTCPeerConnection();
    peerRef.current = pc;
    stream.getTracks().forEach((track) => pc.addTrack(track, stream));

    const audio = new Audio();
    audio.autoplay = true;
    remoteAudioRef.current = audio;
    pc.ontrack = (event) => {
      audio.srcObject = event.streams[0];
      void audio.play().catch(() => undefined);
    };

    const dc = pc.createDataChannel("oai-events");
    dataChannelRef.current = dc;
    dc.onopen = () => setVoiceStatus("connected");
    dc.onmessage = (event) => {
      if (typeof event.data !== "string") return;
      handleNativeEvent(event.data);
    };
    dc.onerror = () => {
      setErrorText("实时语音连接失败，请重试");
      setVoiceStatus("error");
    };
    pc.onconnectionstatechange = () => {
      if (pc.connectionState === "connected") setVoiceStatus("connected");
      if (pc.connectionState === "failed" || pc.connectionState === "disconnected") {
        setErrorText("实时语音连接失败，请重试");
        setVoiceStatus("error");
      }
    };

    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    const answerSdp = await sendRealtimeOffer(offer, {
      model: options.model,
      plan: options.plan || options.model,
    });
    await pc.setRemoteDescription({ type: "answer", sdp: answerSdp });
    sessionRef.current = session;
  }, [handleNativeEvent, setVoiceStatus]);

  const start = useCallback(async (options: { model?: string; plan?: string } = {}) => {
    if (startingRef.current || statusRef.current === "connected" || statusRef.current === "assistant_speaking" || statusRef.current === "connecting" || statusRef.current === "checking" || statusRef.current === "requesting_microphone") {
      return;
    }
    startingRef.current = true;
    cleanup();
    setErrorText("");
    setLastAssistantText("");
    setLastUserText("");
    try {
      setVoiceStatus("checking");
      const session = await createUnifiedRealtimeSession({ model: options.model, plan: options.plan || options.model }) as NativeRealtimeSession;

      if (!navigator.mediaDevices?.getUserMedia) throw new Error("getUserMedia unsupported");
      setVoiceStatus("requesting_microphone");
      const stream = await navigator.mediaDevices.getUserMedia({
        audio: {
          echoCancellation: true,
          noiseSuppression: true,
          autoGainControl: true,
        },
      });
      localStreamRef.current = stream;

      if (session.provider === "openai") await startOpenAiWebRtc(session, stream, options);
      else if (session.provider === "aliyun") await startAliyunProxy(session, stream);
      else throw new Error("实时语音后端未就绪");
      startingRef.current = false;
    } catch (err) {
      cleanup();
      const friendly = friendlyRealtimeError(err);
      setErrorText(friendly);
      setVoiceStatus("error");
      throw new Error(friendly);
    }
  }, [cleanup, setVoiceStatus, startAliyunProxy, startOpenAiWebRtc]);

  const toggle = useCallback(async () => {
    if (statusRef.current === "connected" || statusRef.current === "assistant_speaking" || statusRef.current === "connecting" || statusRef.current === "checking" || statusRef.current === "requesting_microphone") {
      await stop();
      return;
    }
    await start();
  }, [start, stop]);

  async function probe(): Promise<RealtimeProbeResult> {
    return realtimeProbe();
  }

  return {
    status,
    statusText: errorText || STATUS_TEXT[status],
    errorText,
    amplitude,
    lastUserText,
    lastAssistantText,
    isActive: status === "connected" || status === "assistant_speaking" || status === "connecting" || status === "checking" || status === "requesting_microphone",
    start,
    stop,
    toggle,
    probe,
  };
}
