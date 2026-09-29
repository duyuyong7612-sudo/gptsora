// 统一后端地址 + 基础 fetch 封装 + 回复文本提取。
// 不写死 127.0.0.1，不暴露任何 token/key。

// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-2758f4383373c1afbfbe51b39e396408811e51e96d81ca3d4ec5519571703fed"
// Source-SHA256: "fd88a548ae55025b54beb434ed1bc87942771743f3445fb8c03b19501eeb8a9a"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
export interface ReqOptions {
  headers?: Record<string, string>;
  signal?: AbortSignal;
}

/** 后端地址自适配：8000 端口用 origin，否则用 hostname:8000。 */
export function backendBase() {
  if (window.location.port === "8000") return window.location.origin;
  return `${window.location.protocol}//${window.location.hostname}:8000`;
}

/** 稳定的浏览器 client_id（记忆/会话需要），存 localStorage。 */
export function clientId(): string {
  let id = localStorage.getItem("chatagi_adu_client_id");
  if (!id) {
    id = `web_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 10)}`;
    localStorage.setItem("chatagi_adu_client_id", id);
  }
  return id;
}

async function parse(res: Response): Promise<any> {
  const text = await res.text();
  let data: any = null;
  try {
    data = text ? JSON.parse(text) : {};
  } catch {
    data = { text };
  }
  if (!res.ok) {
    const msg = data && (data.detail || data.error || data.message || data.text);
    throw new Error(msg || `HTTP ${res.status}`);
  }
  return data;
}

export async function postJson<T = any>(path: string, payload?: any, options?: ReqOptions): Promise<T> {
  const res = await fetch(backendBase() + path, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...(options?.headers || {}) },
    body: JSON.stringify(payload || {}),
    signal: options?.signal,
  });
  return parse(res);
}

export async function getJson<T = any>(path: string, options?: ReqOptions): Promise<T> {
  const res = await fetch(backendBase() + path, { method: "GET", signal: options?.signal });
  return parse(res);
}

export async function postMultipart(path: string, file: File): Promise<any> {
  const form = new FormData();
  form.append("file", file);
  const res = await fetch(backendBase() + path, { method: "POST", body: form });
  return parse(res);
}

/** 只取真正的回复文本；绝不回退到 raw JSON / memory / debug 结构。 */
export function readReply(data: any): string {
  if (!data) return "";
  if (typeof data === "string") return data;
  if (data.debug || data.trace || data.internal || data.memory || data.memory_replies) return "";
  const responseText = typeof data.response === "string" ? data.response : "";
  return (
    data.reply ||
    data.answer ||
    data.content ||
    data.message ||
    data.text ||
    data.output ||
    responseText ||
    (data.data && (data.data.reply || data.data.answer || data.data.text || data.data.message || readReply(data.data))) ||
    (data.response && readReply(data.response)) ||
    (data.result && readReply(data.result)) ||
    ""
  );
}
