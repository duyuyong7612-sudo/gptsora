// 文本聊天：旧版真实链路 POST /chat/prepare + SSE GET /chat/events/{chat_id}
// 失败再 fallback /api/chat → /api/adu/chat → /api/home/chat → /api/home_chat
// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-a2212594a5954c992c236bd0f07968972cc5930915a8c9c68f36a1badc0f7120"
// Source-SHA256: "e2e2ccf661e1f4251e340a374c7f48919cdf80970008f61c9c5ee7842a625003"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import { backendBase, clientId, postJson, readReply } from "./backendBase";
import type { UploadedAttachment } from "./uploadApi";

export const MODEL_PLANS: Record<string, { plan: string; model: string }> = {
  "机器人 6.0": { plan: "guest", model: "gpt-4o-mini" },
  "机器人 6.1": { plan: "pro", model: "gpt-4o" },
  "机器人 6.2": { plan: "ultra", model: "gpt-5.2-pro" },
  "机器人 6.2 Pro": { plan: "coder", model: "gpt-5.2-pro" },
};

export interface ChatResult {
  reply: string;
  endpoint: string;
  data: any;
}

export interface PreparedChat {
  chatId: string;
  eventsUrl: string;
  ttsUrl?: string;
  ttsStream?: boolean;
  endpoint: string;
  data: any;
}

const BLOCKED_REPLY_PATTERNS = [
  /Memory replies/i,
  /\bmemory\b/i,
  /\bdebug\b/i,
  /\btrace\b/i,
  /\binternal\b/i,
  /\btool_debug\b/i,
  /\broute_info\b/i,
];

const BLOCKED_KEYS = new Set(["memory", "memory_replies", "debug", "trace", "internal", "tool_debug", "route_info"]);

function attachmentFields(attachments: UploadedAttachment[]) {
  const images = attachments.filter((a) => a.kind === "image" && a.url);
  const files = attachments.filter((a) => a.kind === "file" && a.url);
  return {
    attachments,
    files: attachments,
    media: attachments,
    image_url: images[0]?.url || undefined,
    image_urls: images.map((a) => a.url),
    file_url: files[0]?.url || undefined,
    file_urls: files.map((a) => a.url),
  };
}

export function buildChatPayload(text: string, selectedModel: string, selectedMode: string, attachments: UploadedAttachment[] = []) {
  return {
    text,
    message: text,
    prompt: text,
    query: text,
    model: selectedModel,
    plan: selectedModel,
    mode: selectedMode || "chat",
    client_id: clientId(),
    source: "chatagi-adu-web",
    ...attachmentFields(attachments),
  };
}

export function buildPreparePayload(text: string, selectedModel: string, selectedMode: string, attachments: UploadedAttachment[] = []) {
  const mapped = MODEL_PLANS[selectedModel] || { plan: selectedModel, model: selectedModel };
  return {
    ...buildChatPayload(text, selectedModel, selectedMode, attachments),
    plan: mapped.plan,
    model: mapped.model,
    model_display: selectedModel,
    robot_version: selectedModel,
    messages: [{ role: "user", content: text }],
    conversation_id: localStorage.getItem("chatagi_adu_conversation_id") || null,
    tts_voice: "realtime",
    tts_stream: true,
  };
}

export function cleanReply(value: unknown): string {
  if (typeof value !== "string") return "";
  const text = value.trim();
  if (!text || BLOCKED_REPLY_PATTERNS.some((pattern) => pattern.test(text))) return "";
  if ((text.startsWith("{") && text.endsWith("}")) || (text.startsWith("[") && text.endsWith("]"))) return "";
  return text;
}

function parseJsonString(value: string): any | null {
  const raw = value.trim();
  if (!raw) return null;
  if (!((raw.startsWith("{") && raw.endsWith("}")) || (raw.startsWith("[") && raw.endsWith("]")))) return null;
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function hasBlockedKey(value: any): boolean {
  if (!value || typeof value !== "object") return false;
  return Object.keys(value).some((key) => BLOCKED_KEYS.has(key.toLowerCase()));
}

function textValue(value: unknown): string {
  if (typeof value !== "string") return "";
  const parsed = parseJsonString(value);
  if (parsed) return textFromSsePayload(parsed);
  return cleanReply(value);
}

export function textFromSsePayload(payload: any): string {
  if (typeof payload === "string") return textValue(payload);
  if (!payload || typeof payload !== "object") return "";
  const type = String(payload.type || payload.event || "");
  if (/debug|trace|internal|memory/i.test(type)) return "";
  if (hasBlockedKey(payload)) return "";

  const candidates = [
    payload.delta,
    payload.reply,
    payload.answer,
    payload.content,
    payload.message,
    payload.text,
    payload.output,
    payload.response,
    payload.data?.delta,
    payload.data?.reply,
    payload.data?.answer,
    payload.data?.content,
    payload.data?.text,
  ];
  for (const candidate of candidates) {
    const text = textValue(candidate);
    if (text) return text;
  }

  if (typeof payload.data === "string") return textValue(payload.data);
  return "";
}

function chatIdFrom(data: any): string {
  return String(data?.chat_id || data?.id || data?.session_id || data?.conversation_id || "");
}

function ttsUrlFrom(data: any): string {
  return String(data?.tts_url || data?.ttsUrl || data?.audio_url || data?.audioUrl || data?.speech_url || data?.speechUrl || "");
}

export function eventSourceUrl(eventsUrl: string): string {
  if (/^https?:\/\//i.test(eventsUrl)) return eventsUrl;
  return backendBase() + eventsUrl;
}

export function isSseDonePayload(payload: any): boolean {
  if (payload === "[DONE]") return true;
  if (!payload || typeof payload !== "object") return false;
  const marker = String(payload.type || payload.event || payload.status || "").toLowerCase();
  return /(^|\.|_|-)(done|completed|complete|end)$/.test(marker) || marker === "response.completed";
}

export function sseErrorMessage(payload: any): string {
  if (!payload || typeof payload !== "object") return "";
  const type = String(payload.type || payload.event || "").toLowerCase();
  if (type !== "error" && type !== "response.failed") return "";
  const error = payload.error;
  if (typeof error === "string") return error;
  if (error && typeof error === "object" && typeof error.message === "string") return error.message;
  if (typeof payload.message === "string") return payload.message;
  return "聊天生成失败";
}

export async function prepareChat(
  text: string,
  selectedModel: string,
  selectedMode: string,
  attachments: UploadedAttachment[] = [],
  signal?: AbortSignal,
): Promise<PreparedChat> {
  const prep = await postJson("/chat/prepare", buildPreparePayload(text, selectedModel, selectedMode, attachments), {
    headers: {
      "X-Client-ID": clientId(),
      "X-ChatAGI-Plan": (MODEL_PLANS[selectedModel] || {}).plan || selectedModel,
    },
    signal,
  });
  if (prep.conversation_id) localStorage.setItem("chatagi_adu_conversation_id", prep.conversation_id);
  const id = chatIdFrom(prep);
  if (!id && !prep.events_url) throw new Error(prep.error || "missing chat_id");
  return {
    chatId: id,
    eventsUrl: prep.events_url || `/chat/events/${encodeURIComponent(id)}`,
    ttsUrl: ttsUrlFrom(prep) || undefined,
    ttsStream: Boolean(prep.tts_stream),
    endpoint: "/chat/prepare",
    data: prep,
  };
}

export async function fallbackChat(
  text: string,
  selectedModel: string,
  selectedMode: string,
  attachments: UploadedAttachment[] = [],
): Promise<ChatResult> {
  const fallbackEndpoints = ["/api/chat", "/api/adu/chat", "/api/home/chat", "/api/home_chat"];
  const payload = buildChatPayload(text, selectedModel, selectedMode, attachments);
  let lastError: any = null;
  for (const path of fallbackEndpoints) {
    try {
      const data = await postJson(path, payload);
      const reply = cleanReply(readReply(data));
      if (!reply) throw new Error("empty reply");
      return { reply, endpoint: path, data };
    } catch (err) {
      lastError = err;
      console.warn(`[chatApi] ${path} failed`, err);
    }
  }
  throw lastError || new Error("chat backend unavailable");
}

/** 读取 SSE，只累积真实回复字段，绝不显示 raw JSON。 */
async function readChatSse(eventsUrl: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const source = new EventSource(eventSourceUrl(eventsUrl));
    let built = "";
    let settled = false;
    const timeout = window.setTimeout(() => {
      if (built.trim()) finish();
    }, 120000);

    function finish() {
      if (settled) return;
      settled = true;
      window.clearTimeout(timeout);
      source.close();
      resolve(cleanReply(built));
    }

    function fail(message: string) {
      if (settled) return;
      settled = true;
      window.clearTimeout(timeout);
      source.close();
      reject(new Error(message));
    }

    source.onmessage = (event) => {
      const raw = event.data?.trim();
      if (!raw || raw === "[DONE]") {
        finish();
        return;
      }
      let payload: any;
      try {
        payload = JSON.parse(raw);
      } catch {
        const plain = cleanReply(raw);
        if (plain) built += plain;
        return;
      }
      if (payload.type === "error") {
        fail("聊天生成失败");
        return;
      }
      const text = textFromSsePayload(payload);
      if (text) {
        if (payload.delta || /delta/i.test(String(payload.type || ""))) built += text;
        else built = text;
      }
      if (/done|complete|end/i.test(String(payload.type || payload.event || ""))) finish();
    };

    source.onerror = () => {
      if (built.trim()) finish();
      else fail("聊天事件流不可用");
    };
  });
}

export async function chat(
  text: string,
  selectedModel: string,
  selectedMode: string,
  attachments: UploadedAttachment[] = [],
): Promise<ChatResult> {
  try {
    const prep = await prepareChat(text, selectedModel, selectedMode, attachments);
    const reply = await readChatSse(prep.eventsUrl);
    if (!reply) throw new Error("empty reply");
    return { reply, endpoint: prep.endpoint, data: prep.data };
  } catch (err) {
    console.warn("[chatApi] /chat/prepare failed", err);
  }

  return fallbackChat(text, selectedModel, selectedMode, attachments);
}
