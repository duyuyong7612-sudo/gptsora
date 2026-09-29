// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-a9c04d1115846f5504c7ab3ddc63cf44b85b428e947e732f80ea5bb3276559c0"
// Source-SHA256: "5135fdfb5719ebbecdc373fa13f0dbd683a8ee67ed745c4f51c82561e671077b"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import { backendBase, getJson, postJson } from "./backendBase";

export interface TtsPrepared {
  ok: boolean;
  ttsId?: string;
  url: string;
  expiresIn?: number;
}

export const APP_TTS_VOICE = "realtime";
export const APP_TTS_SPEED = 1.15;
export const APP_TTS_FORMAT = "mp3";

export function resolveBackendUrl(url: string): string {
  if (/^https?:\/\//i.test(url)) return url;
  return backendBase() + (url.startsWith("/") ? url : `/${url}`);
}

export async function checkTtsHealth(): Promise<boolean> {
  try {
    const data = await getJson("/health");
    return Boolean(data?.chat?.tts_prepare || data?.tts_prepare || data?.chat?.has_server_side_tts_stream);
  } catch {
    return false;
  }
}

export async function speakByBackend(text: string): Promise<TtsPrepared> {
  const data = await postJson("/tts_prepare", {
    text,
    voice: APP_TTS_VOICE,
    format: APP_TTS_FORMAT,
    speed: APP_TTS_SPEED,
  });

  const path = String(data?.url || data?.tts_url || data?.audio_url || "");
  if (!path) throw new Error("TTS /tts_prepare 返回异常（缺少 url）");

  return {
    ok: Boolean(data?.ok ?? true),
    ttsId: data?.tts_id,
    url: resolveBackendUrl(path),
    expiresIn: data?.expires_in,
  };
}

export function stopBackendSpeak(audio: HTMLAudioElement | null): void {
  if (!audio) return;
  audio.pause();
  audio.removeAttribute("src");
  audio.load();
}
