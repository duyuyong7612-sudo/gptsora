// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-247e497488bfc9f8be9c8523bfeca9aa4f9187a7be3638bcab0df297cdfa9028"
// Source-SHA256: "bc23a0db688fd640657c7fd88d7e293baf450ab99705ce1b2f40e1a1ef9e8c02"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import { useEffect, useRef, useState } from "react";
import {
  eventSourceUrl,
  fallbackChat,
  isSseDonePayload,
  prepareChat,
  sseErrorMessage,
  textFromSsePayload,
} from "../api/chatApi";
import type { UploadedAttachment } from "../api/uploadApi";

export interface ChatMessage {
  id: string;
  role: "user" | "assistant";
  text: string;
  attachments?: UploadedAttachment[];
  isStreaming?: boolean;
}

export interface ChatStatus {
  text: string;
  kind: string;
}

const GREETING: ChatMessage = {
  id: "greeting",
  role: "assistant",
  text: "我是 ChatAGI-阿杜。你可以直接聊天，也可以切到实时语音或电脑控制。",
};

interface UseSseChatOptions {
  onAssistantDelta?: (delta: string, messageId: string) => void;
  onAssistantTextDelta?: (delta: string, messageId: string) => void;
  onAssistantPreparedTts?: (messageId: string, ttsUrl: string) => void;
  onAssistantDone?: (messageId: string) => void;
}

function newId(prefix: string) {
  return `${prefix}_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 9)}`;
}

function parseSseData(rawData: string): any {
  const raw = rawData.trim();
  if (!raw || raw === "[DONE]") return raw;
  try {
    return JSON.parse(raw);
  } catch {
    return raw;
  }
}

/** 聊天消息流 + 发送（走 chatApi：/chat/prepare + SSE）。 */
export function useSseChat(options: UseSseChatOptions = {}) {
  const [messages, setMessages] = useState<ChatMessage[]>([GREETING]);
  const [chatStatus, setChatStatus] = useState<ChatStatus>({ text: "准备就绪", kind: "" });
  const [isSending, setIsSending] = useState(false);
  const sourceRef = useRef<EventSource | null>(null);
  const abortRef = useRef<AbortController | null>(null);
  const activeAssistantIdRef = useRef<string>("");
  const cancelRequestedRef = useRef(false);
  const callbacksRef = useRef(options);

  callbacksRef.current = options;

  function closeSource() {
    sourceRef.current?.close();
    sourceRef.current = null;
  }

  function abort() {
    cancelRequestedRef.current = true;
    abortRef.current?.abort();
    abortRef.current = null;
    closeSource();
    const assistantId = activeAssistantIdRef.current;
    if (assistantId) {
      updateAssistant(assistantId, (msg) => ({
        ...msg,
        text: msg.text && msg.text !== "正在思考..." ? `${msg.text}\n\n（已中止）` : "已中止",
        isStreaming: false,
      }));
    }
    setIsSending(false);
    setChatStatus({ text: "已中止", kind: "warn-text" });
  }

  function updateAssistant(messageId: string, mutate: (message: ChatMessage) => ChatMessage) {
    setMessages((prev) => prev.map((msg) => (msg.id === messageId ? mutate(msg) : msg)));
  }

  async function send(text: string, model: string, attachments: UploadedAttachment[] = []): Promise<void> {
    const trimmed = text.trim();
    if (!trimmed && attachments.length === 0) return;
    if (isSending) return;

    closeSource();
    abortRef.current?.abort();
    const aborter = new AbortController();
    abortRef.current = aborter;
    cancelRequestedRef.current = false;
    const userId = newId("user");
    const assistantId = newId("assistant");
    activeAssistantIdRef.current = assistantId;

    setMessages((prev) => [
      ...prev,
      { id: userId, role: "user", text: trimmed, attachments },
      { id: assistantId, role: "assistant", text: "正在思考...", isStreaming: true },
    ]);
    setIsSending(true);
    setChatStatus({ text: "正在连接聊天后端", kind: "warn-text" });
    let usePreparedTts = false;

    const replaceAssistant = (value: string, streaming = false) => {
      updateAssistant(assistantId, (msg) => ({ ...msg, text: value, isStreaming: streaming }));
    };

    const appendAssistantDelta = (delta: string) => {
      updateAssistant(assistantId, (msg) => {
        const current = msg.text === "正在思考..." ? "" : msg.text;
        return { ...msg, text: current + delta, isStreaming: true };
      });
      callbacksRef.current.onAssistantTextDelta?.(delta, assistantId);
      if (!usePreparedTts) callbacksRef.current.onAssistantDelta?.(delta, assistantId);
    };

    try {
      const prepared = await prepareChat(trimmed, model, "chat", attachments, aborter.signal);
      if (cancelRequestedRef.current || aborter.signal.aborted) throw new DOMException("aborted", "AbortError");
      setChatStatus({ text: "正在生成回复", kind: "warn-text" });
      usePreparedTts = Boolean(prepared.ttsUrl && prepared.ttsStream);
      if (usePreparedTts && prepared.ttsUrl) {
        callbacksRef.current.onAssistantPreparedTts?.(assistantId, prepared.ttsUrl);
      }

      await new Promise<void>((resolve, reject) => {
        let built = "";
        let settled = false;
        const source = new EventSource(eventSourceUrl(prepared.eventsUrl));
        sourceRef.current = source;

        function finish() {
          if (settled) return;
          settled = true;
          source.close();
          if (sourceRef.current === source) sourceRef.current = null;
          if (abortRef.current === aborter) abortRef.current = null;
          updateAssistant(assistantId, (msg) => ({
            ...msg,
            text: msg.text === "正在思考..." ? built : msg.text,
            isStreaming: false,
          }));
          callbacksRef.current.onAssistantDone?.(assistantId);
          setChatStatus({ text: `已接入：${prepared.endpoint}`, kind: "ok-text" });
          setIsSending(false);
          resolve();
        }

        function fail(message: string) {
          if (settled) return;
          settled = true;
          source.close();
          if (sourceRef.current === source) sourceRef.current = null;
          if (abortRef.current === aborter) abortRef.current = null;
          setIsSending(false);
          reject(new Error(message));
        }

        source.onmessage = (event) => {
          const payload = parseSseData(event.data || "");
          if (!payload) return;
          if (payload === "[DONE]") {
            finish();
            return;
          }

          const err = sseErrorMessage(payload);
          if (err) {
            fail("聊天生成失败");
            return;
          }

          const type = typeof payload === "object" ? String(payload.type || payload.event || "") : "";
          const isDone = isSseDonePayload(payload);
          const text = textFromSsePayload(payload);

          if (text) {
            if (/delta/i.test(type) || typeof payload === "string" || !isDone) {
              built += text;
              appendAssistantDelta(text);
            } else if (!built) {
              built = text;
              replaceAssistant(text, !isDone);
              callbacksRef.current.onAssistantTextDelta?.(text, assistantId);
              if (!usePreparedTts) callbacksRef.current.onAssistantDelta?.(text, assistantId);
            }
          }

          if (isDone) finish();
        };

        source.onerror = () => {
          if (built.trim()) finish();
          else fail("聊天事件流不可用");
        };
      });
    } catch (err) {
      if (cancelRequestedRef.current || (err instanceof DOMException && err.name === "AbortError")) {
        return;
      }
      console.warn("[useSseChat] /chat/prepare SSE unavailable", err);
      closeSource();
      try {
        if (aborter.signal.aborted) throw new DOMException("aborted", "AbortError");
        const result = await fallbackChat(trimmed, model, "chat", attachments);
        replaceAssistant(result.reply || "后端没有返回文本。", false);
        callbacksRef.current.onAssistantTextDelta?.(result.reply || "", assistantId);
        callbacksRef.current.onAssistantDelta?.(result.reply || "", assistantId);
        callbacksRef.current.onAssistantDone?.(assistantId);
        setChatStatus({ text: `已接入：${result.endpoint}`, kind: "ok-text" });
        setIsSending(false);
      } catch (fallbackErr) {
        if (cancelRequestedRef.current || (fallbackErr instanceof DOMException && fallbackErr.name === "AbortError")) {
          return;
        }
        console.warn("[useSseChat] chat unavailable", fallbackErr);
        replaceAssistant("聊天接口暂不可用", false);
        callbacksRef.current.onAssistantDone?.(assistantId);
        setChatStatus({ text: "聊天接口未接入或不可用", kind: "danger-text" });
        setIsSending(false);
        throw fallbackErr;
      }
    } finally {
      if (abortRef.current === aborter) abortRef.current = null;
      if (!cancelRequestedRef.current) setIsSending(false);
    }
  }

  function newChat() {
    closeSource();
    abortRef.current?.abort();
    abortRef.current = null;
    setIsSending(false);
    setMessages([{ id: newId("assistant"), role: "assistant", text: "新会话已创建。" }]);
  }

  useEffect(() => {
    return () => {
      abortRef.current?.abort();
      closeSource();
    };
  }, []);

  return { messages, chatStatus, send, newChat, abort, isSending };
}
