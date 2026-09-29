// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-fe70281e6bfee02ec5d31ddbcedebc961d44b284e5834b51c53d30168fe2ec59"
// Source-SHA256: "623156435b521808a74b285d5ab46757be331a8f85a5e1e7d594af3403da28c6"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import { backendBase, clientId, getJson, postJson } from "./backendBase";

export interface NativeRealtimeHealth {
  ok: boolean;
  ready: boolean;
  protocol: "websocket-native";
  audio_format: "pcm16-base64";
  sample_rate: 16000;
  reason: string;
  provider?: string;
  model?: string;
  voice?: string;
}

export interface NativeRealtimeSession {
  ok: boolean;
  ready?: boolean;
  session_id: string;
  ws_url: string;
  protocol: "websocket-native";
  audio_format?: "pcm16-base64";
  sample_rate?: 16000;
  instructions?: string;
  reason?: string;
  message?: string;
}

export type NativeRealtimeEvent =
  | { type: "session.update"; config?: Record<string, unknown>; session?: Record<string, unknown>; instructions?: string }
  | { type: "mic_start" }
  | { type: "input_audio_buffer.append"; audio: string; sample_rate: 16000; format: "pcm16"; force_listen?: boolean }
  | { type: "end_of_turn" }
  | { type: "session.queue_done" }
  | { type: "interrupt" }
  | { type: "stop" };

export function resolveNativeRealtimeSocketUrl(wsUrl: string): string {
  if (/^wss?:\/\//i.test(wsUrl)) return wsUrl;
  const url = new URL(wsUrl, backendBase());
  url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
  return url.toString();
}

export async function checkNativeRealtimeHealth(): Promise<NativeRealtimeHealth> {
  return getJson<NativeRealtimeHealth>("/api/realtime/native/health");
}

export async function createNativeRealtimeSession(config?: Record<string, unknown>): Promise<NativeRealtimeSession> {
  const data = await postJson<NativeRealtimeSession>("/api/realtime/native/session", {
    source: "chatagi-adu-web",
    client_id: clientId(),
    mode: "audio",
    ...(config || {}),
  });
  if (!data.ok || !data.session_id || !data.ws_url) {
    throw new Error(data.reason || data.message || "实时语音会话创建失败");
  }
  return data;
}

export function connectNativeRealtimeSocket(session: NativeRealtimeSession): WebSocket {
  return new WebSocket(resolveNativeRealtimeSocketUrl(session.ws_url));
}

export function sendNativeEvent(ws: WebSocket | null, event: NativeRealtimeEvent): boolean {
  if (!ws || ws.readyState !== WebSocket.OPEN) return false;
  ws.send(JSON.stringify(event));
  return true;
}
