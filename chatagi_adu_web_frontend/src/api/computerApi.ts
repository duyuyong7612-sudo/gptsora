// 电脑控制：只走后端 /api/brain/computer/*（后端再代理到 local_agent:4317）。
// 前端不直连 4317，不暴露任何 token。
// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-e31a2fc220180ba445f15b76662d8adbb7856ec7cb1c296b0e31a14ef243fa83"
// Source-SHA256: "a2225792dd517b7c99c6c0a2f5dca6f58d5ded176a63d680b29667593afc9fc3"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import { getJson, postJson } from "./backendBase";

export function computerConfig(): Promise<any> {
  return getJson("/api/brain/computer/config");
}

export function computerScreenshot(): Promise<any> {
  return postJson("/api/brain/computer/screenshot", {});
}

export function computerMove(x: number, y: number): Promise<any> {
  return postJson("/api/brain/computer/move", { x, y });
}

export function computerClick(x: number, y: number): Promise<any> {
  return postJson("/api/brain/computer/click", { x, y });
}

export function computerType(text: string): Promise<any> {
  return postJson("/api/brain/computer/type", { text });
}

export function computerPress(key: string): Promise<any> {
  return postJson("/api/brain/computer/press", { key });
}

export function computerAction(text: string): Promise<any> {
  return postJson("/api/brain/computer/action", {
    text,
    message: text,
    prompt: text,
    task: text,
    source: "chatagi-adu-web",
  });
}
