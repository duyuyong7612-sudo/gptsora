// 上传：图片走 /upload/image，文件走 /upload/file。
// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-ed84e8b6318f829c41c52bb0c51aed2b6543fb9341973cb43b82901243a50279"
// Source-SHA256: "7cdb1ac0d96b9c7a239db03bf163492100bd2da1a3e66b6bee90736a62d68233"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import { backendBase } from "./backendBase";

export interface UploadedAttachment {
  ok: true;
  kind: "image" | "file";
  name: string;
  size: number;
  mime: string;
  url: string;
  id: string;
  raw: any;
}

export interface UploadFailure {
  ok: false;
  kind: "image" | "file";
  name: string;
  size: number;
  mime: string;
  error: string;
  raw?: any;
}

export type UploadResult = UploadedAttachment | UploadFailure;

function absoluteUrl(value: unknown): string {
  const raw = String(value || "").trim();
  if (!raw) return "";
  if (/^https?:\/\//i.test(raw) || raw.startsWith("data:")) return raw;
  if (raw.startsWith("/")) return backendBase() + raw;
  return `${backendBase()}/${raw.replace(/^\/+/, "")}`;
}

function firstString(data: any, keys: string[]): string {
  for (const key of keys) {
    const value = data?.[key];
    if (typeof value === "string" && value.trim()) return value.trim();
  }
  return "";
}

async function postUpload(path: string, file: File): Promise<any> {
  const fd = new FormData();
  fd.append("file", file);
  const res = await fetch(backendBase() + path, { method: "POST", body: fd });
  const text = await res.text();
  let data: any = {};
  try {
    data = text ? JSON.parse(text) : {};
  } catch {
    data = { text };
  }
  if (!res.ok) {
    const msg = data?.detail || data?.error || data?.message || "上传失败，请重试";
    throw Object.assign(new Error(String(msg)), { raw: data });
  }
  return data;
}

async function upload(kind: "image" | "file", file: File): Promise<UploadResult> {
  const path = kind === "file" ? "/upload/file" : "/upload/image";
  try {
    const data = await postUpload(path, file);
    const url = absoluteUrl(firstString(data, ["url", "file_url", "media_url", "path", "href"]));
    const id = firstString(data, ["id", "file_id", "media_id", "filename", "name"]);
    return {
      ok: true,
      kind,
      name: firstString(data, ["filename", "name"]) || file.name,
      size: file.size,
      mime: firstString(data, ["mime", "mime_type", "content_type"]) || file.type || "application/octet-stream",
      url,
      id,
      raw: data,
    };
  } catch (err: any) {
    return {
      ok: false,
      kind,
      name: file.name,
      size: file.size,
      mime: file.type || "application/octet-stream",
      error: "上传失败，请重试",
      raw: err?.raw,
    };
  }
}

export function uploadImage(file: File): Promise<UploadResult> {
  return upload("image", file);
}

export function uploadFile(file: File): Promise<UploadResult> {
  return upload("file", file);
}
