// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-9563487e8c2ff11f3a81c3a6a6f19fe7007936333af619cef104970f58b3d507"
// Source-SHA256: "96eb5834411d8d625005b31f1515fa1d03e7e9d081cd7b238df7da205e6dd165"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import { backendBase, clientId, getJson, postJson } from "./backendBase";

export interface RealtimeHealth {
  ok: boolean;
  provider?: string;
  ready?: boolean;
  reason?: string;
  model?: string;
  voice?: string;
  realtime?: {
    model?: string;
    voice?: string;
    has_default_instructions?: boolean;
  };
  endpoints?: {
    realtime_session?: string;
  };
  native?: {
    provider?: string;
    protocol?: string;
    ready?: boolean;
    ws_url_configured?: boolean;
  };
}

export interface RealtimeStartOptions {
  model?: string;
  plan?: string;
}

export interface RealtimeSessionInfo {
  ok: boolean;
  provider?: string;
  protocol?: string;
  ready?: boolean;
  reason?: string;
  model?: string;
  voice?: string;
  mode?: string;
  ws_url?: string;
  rtc_url?: string;
  ephemeral_key?: string;
  client_secret?: string | { value?: string; expires_at?: number };
  client_secret_value?: string;
  instructions?: string;
  session_id?: string;
  conversation_id?: string;
  object?: string;
  transport?: string[];
  voice_ws_path?: string;
  audio?: {
    input_format?: string;
    output_format?: string;
    sample_rate?: number;
  };
  livekit?: {
    url: string;
    room: string;
    identity?: string;
    token: string;
    agent_name?: string;
    auto_dispatch?: boolean;
    dispatch?: unknown;
  };
  input_audio_format?: string;
  output_audio_format?: string;
  sample_rate_in?: number;
  sample_rate_out?: number;
  supports_force_listen?: boolean;
  message?: string;
}

export type NativeRealtimeSession = RealtimeSessionInfo & {
  session_id: string;
  ws_url: string;
  protocol: string;
  provider: string;
};

export type LiveKitRealtimeSession = RealtimeSessionInfo & {
  livekit: NonNullable<RealtimeSessionInfo["livekit"]>;
};

export interface RealtimeOfferResult {
  ok: boolean;
  provider?: string;
  ready?: boolean;
  reason?: string;
  answer_sdp?: string;
  sdp?: string;
  answer?: string;
  message?: string;
  error?: string;
}

export async function checkRealtimeHealth(options: RealtimeStartOptions = {}): Promise<RealtimeHealth> {
  const params = new URLSearchParams();
  if (options.model) params.set("model", options.model);
  if (options.plan) params.set("plan", options.plan);
  const suffix = params.toString() ? `?${params.toString()}` : "";
  const data = await getJson<RealtimeHealth>(`/api/realtime/health${suffix}`);
  const nativeReady = Boolean(data.native?.ready);
  return {
    ...data,
    ready: data.ready ?? nativeReady ?? Boolean(data.ok && (data.realtime?.model || data.model)),
    model: data.model || data.realtime?.model,
    voice: data.voice || data.realtime?.voice,
  };
}

export async function checkNativeRealtimeHealth(): Promise<RealtimeHealth> {
  return checkRealtimeHealth({ model: "机器人 6.1" });
}

export async function createNativeRealtimeSession(): Promise<NativeRealtimeSession> {
  const data = await createRealtimeSession({ model: "机器人 6.1", plan: "机器人 6.1" }) as NativeRealtimeSession;
  if (!data.ok || data.ready === false || !data.ws_url) {
    throw new Error(data.reason || data.message || "实时语音后端未就绪");
  }
  return data;
}

export function resolveNativeRealtimeWebSocketURL(wsUrl: string): string {
  if (/^wss?:\/\//i.test(wsUrl)) return wsUrl;
  const url = new URL(wsUrl, backendBase());
  url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
  return url.toString();
}

export function connectNativeRealtimeWebSocket(session: NativeRealtimeSession): WebSocket {
  return new WebSocket(resolveNativeRealtimeWebSocketURL(session.ws_url));
}

export async function createRealtimeSession(options: RealtimeStartOptions = {}): Promise<RealtimeSessionInfo> {
  const selectedModel = options.model || "机器人 6.2";
  const data = await postJson<RealtimeSessionInfo>("/session", {
    model: selectedModel,
    plan: options.plan || selectedModel,
    realtime_plan: "pro",
    mode: "voice",
    allow_web: true,
    enable_memory: true,
    profile: "default",
    source: "chatagi-adu-web",
    client_id: clientId(),
  });
  if (!data.ok || data.ready === false || !(data.ws_url || data.rtc_url || data.client_secret || data.ephemeral_key)) {
    throw new Error(data.reason || data.message || "实时语音后端未就绪");
  }
  return data;
}

export async function createUnifiedRealtimeSession(options: RealtimeStartOptions = {}): Promise<RealtimeSessionInfo> {
  const selectedModel = options.model || "机器人 6.2";
  const data = await postJson<RealtimeSessionInfo>("/api/realtime/session", {
    model: selectedModel,
    plan: options.plan || selectedModel,
    source: "chatagi-adu-web",
    mode: "voice",
    allow_web: true,
    enable_memory: true,
    profile: "home",
    client_id: clientId(),
  });
  if (!data.ok || data.ready === false) {
    if (data.provider === "aliyun") throw new Error(data.reason || "阿里实时语音未配置");
    if (data.provider === "openai") throw new Error(data.reason || "GPT Realtime 未配置");
    throw new Error(data.reason || data.message || "实时语音后端未就绪");
  }
  return data;
}

export async function checkLiveKitRealtimeHealth(): Promise<RealtimeHealth> {
  try {
    const data = await getJson<RealtimeHealth>("/api/realtime/livekit/status");
    return {
      ...data,
      ok: Boolean(data.ok),
      ready: data.ready ?? Boolean(data.ok),
      provider: data.provider || "livekit",
    };
  } catch (error) {
    return {
      ok: false,
      ready: false,
      provider: "livekit",
      reason: error instanceof Error ? error.message : "LiveKit 后端未就绪",
    };
  }
}

export async function createLiveKitRealtimeSession(options: RealtimeStartOptions = {}): Promise<LiveKitRealtimeSession> {
  const selectedModel = options.model || "机器人 6.2";
  const data = await postJson<RealtimeSessionInfo>("/api/realtime/livekit/session", {
    model: selectedModel,
    plan: options.plan || selectedModel,
    source: "chatagi-adu-web",
    mode: "voice",
    transport: "livekit",
    allow_web: true,
    enable_memory: true,
    profile: "home",
    client_id: clientId(),
  });

  if (!data.ok || data.ready === false || !data.livekit?.url || !data.livekit?.token) {
    throw new Error(data.reason || data.message || "LiveKit 实时语音后端未就绪");
  }
  return data as LiveKitRealtimeSession;
}

export async function sendRealtimeOffer(
  offer: Pick<RTCSessionDescriptionInit, "sdp" | "type"> | string,
  options: RealtimeStartOptions = {},
): Promise<string> {
  const selectedModel = options.model || "机器人 6.2";
  const offerSdp = (typeof offer === "string" ? offer : offer.sdp || "").trim();
  const offerType = typeof offer === "string" ? "offer" : offer.type;
  const data = await postJson<RealtimeOfferResult>("/api/realtime/offer", {
    model: selectedModel,
    plan: options.plan || selectedModel,
    sdp: offerSdp,
    offer: offerSdp,
    offer_sdp: offerSdp,
    type: offerType,
    profile: "home",
    mode: "voice",
    source: "chatagi-adu-web",
    client_id: clientId(),
    enable_memory: true,
    enable_web: true,
  });
  const answer = (data.answer_sdp || data.sdp || data.answer || "").trim();
  if (!answer || !/^v=/m.test(answer)) {
    if (data.provider === "openai" && data.ready === false) throw new Error(data.reason || "GPT Realtime 未配置");
    throw new Error(data.reason || data.message || data.error || "实时语音连接失败");
  }
  return answer;
}

export interface RealtimeProbeResult {
  ok: boolean;
  endpoint?: string;
  summary?: string;
  details?: unknown;
}

export async function realtimeProbe(): Promise<RealtimeProbeResult> {
  try {
    const health = await checkRealtimeHealth({ model: "机器人 6.2" });
    if (!health.ok || health.ready === false) return { ok: false, endpoint: "/api/realtime/health" };
    return { ok: true, endpoint: "/api/realtime/session" };
  } catch {
    return { ok: false, endpoint: "" };
  }
}
