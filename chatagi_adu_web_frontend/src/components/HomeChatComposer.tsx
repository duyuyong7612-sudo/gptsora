// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-1757d1198b14ddbcb950f7980e1bf7b1d67dfc1da561a8eae4c473e35f9aad1e"
// Source-SHA256: "513af60350c5ebac93f1e5ac731cb1f38c1774ac16151e8c7fae96b12f16aa64"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import { useEffect, useRef, useState } from "react";
import { useComposerState } from "../hooks/useComposerState";
import { useSpeechInput } from "../hooks/useSpeechInput";
import { useRealtimeVoice } from "../hooks/useRealtimeVoice";
import { uploadFile, uploadImage } from "../api/uploadApi";
import type { UploadedAttachment } from "../api/uploadApi";
import { feedback } from "../utils/feedback";
import type { ComposerState } from "../types/homeChat";
import { isRealtimeComposerState } from "../types/homeChat";

export interface HomeChatComposerProps {
  onSendText: (text: string, attachments: UploadedAttachment[]) => Promise<void> | void;
  isSending?: boolean;
  onAbortSend?: () => void;
  realtimeVoice?: ReturnType<typeof useRealtimeVoice>;
  selectedModel?: string;
}

export function HomeChatComposer({ onSendText, isSending = false, onAbortSend, realtimeVoice: externalRealtimeVoice, selectedModel = "机器人 6.2" }: HomeChatComposerProps) {
  const { text, setText, menuOpen, setMenuOpen, status, setStatus } = useComposerState();
  const { listening, processing: speechProcessing, start: startSpeech, stop: stopSpeech } = useSpeechInput();
  const internalRealtimeVoice = useRealtimeVoice();
  const realtimeVoice = externalRealtimeVoice || internalRealtimeVoice;
  const [attachments, setAttachments] = useState<UploadedAttachment[]>([]);
  const [uploading, setUploading] = useState(false);

  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const imageInputRef = useRef<HTMLInputElement>(null);
  const cameraInputRef = useRef<HTMLInputElement>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);

  const hasText = text.trim().length > 0;
  const hasContent = hasText || attachments.length > 0;
  const realtimeComposerState: Partial<Record<typeof realtimeVoice.status, ComposerState>> = {
    checking: "realtime_checking",
    requesting_microphone: "realtime_connecting",
    connecting: "realtime_connecting",
    connected: "realtime_connected",
    assistant_speaking: "assistant_speaking",
    stopping: "realtime_stopping",
    error: "error",
  };
  const composerState: ComposerState = uploading
    ? "uploading"
    : isSending
      ? "sending"
      : listening
        ? "speech_listening"
        : speechProcessing
          ? "speech_processing"
          : realtimeComposerState[realtimeVoice.status] || (hasContent ? "typing" : "idle_empty");
  const isSpeechState = composerState === "speech_listening" || composerState === "speech_processing";
  const isRealtimeState = isRealtimeComposerState(composerState);
  const isStopState = composerState === "sending" || isSpeechState || isRealtimeState;
  const canOpenAttachMenu = !isSending && !isSpeechState && !isRealtimeState && !uploading;
  const canRemoveAttachment = !isSending;

  useEffect(() => {
    const el = textareaRef.current;
    if (!el) return;
    el.style.height = "auto";
    el.style.height = `${Math.min(el.scrollHeight, 92)}px`;
  }, [text]);

  useEffect(() => {
    const onDoc = () => setMenuOpen(false);
    document.addEventListener("click", onDoc);
    return () => document.removeEventListener("click", onDoc);
  }, [setMenuOpen]);

  useEffect(() => {
    if (status.kind !== "danger-text") return;
    const id = window.setTimeout(() => setStatus({ text: "", kind: "" }), 2200);
    return () => window.clearTimeout(id);
  }, [status.kind, setStatus]);

  async function submit() {
    const t = text.trim();
    if ((!t && attachments.length === 0) || composerState !== "typing") return;
    const attachmentsToSend = attachments;
    setText("");
    setMenuOpen(false);
    setStatus({ text: "正在发送...", kind: "warn-text" });
    try {
      await onSendText(t, attachmentsToSend);
      setAttachments([]);
      setStatus({ text: "", kind: "" });
      feedback("success");
    } catch {
      setText(t);
      setAttachments(attachmentsToSend);
      setStatus({ text: "发送失败，请重试", kind: "danger-text" });
      feedback("error");
    }
  }

  function abortSend() {
    onAbortSend?.();
    setStatus({ text: "已中止", kind: "warn-text" });
    feedback("stopVoice");
  }

  async function startRealtimeVoice() {
    try {
      setStatus({ text: "正在连接实时语音…", kind: "warn-text" });
      await realtimeVoice.start({ model: selectedModel, plan: selectedModel });
      setStatus({ text: "实时语音中", kind: "ok-text" });
      feedback("startVoice");
    } catch (err) {
      const message = err instanceof Error ? err.message : "实时语音连接失败";
      setStatus({ text: message, kind: "danger-text" });
      feedback("error");
    }
  }

  async function stopRealtimeVoice() {
    try {
      setStatus({ text: "正在停止...", kind: "warn-text" });
      await realtimeVoice.stop();
      setStatus({ text: "已停止", kind: "warn-text" });
      feedback("stopVoice");
    } catch {
      setStatus({ text: "实时语音连接失败", kind: "danger-text" });
      feedback("error");
    }
  }

  async function onWave() {
    if (composerState === "sending") return abortSend();
    if (isSpeechState) {
      stopSpeech();
      setStatus({ text: "语音输入已取消", kind: "warn-text" });
      feedback("stopVoice");
      return;
    }
    if (isRealtimeState) return stopRealtimeVoice();
    if (composerState === "uploading" || composerState === "realtime_stopping") return;
    if (composerState === "typing") return submit();
    return startRealtimeVoice();
  }

  function onKeyDown(e: React.KeyboardEvent<HTMLTextAreaElement>) {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      void submit();
    }
  }

  function onMic() {
    if (composerState !== "idle_empty") return;
    startSpeech(
      (t) => {
        setText(t);
        textareaRef.current?.focus();
      },
      (statusText, kind) => {
        setStatus({ text: statusText, kind });
        if (kind === "") feedback("success");
        if (kind === "danger-text") feedback("error");
      },
    );
  }

  function pick(kind: "image" | "camera" | "file") {
    if (!canOpenAttachMenu) return;
    const ref = kind === "image" ? imageInputRef : kind === "camera" ? cameraInputRef : fileInputRef;
    ref.current?.click();
    setMenuOpen(false);
  }

  async function onFile(kind: "image" | "camera" | "file", e: React.ChangeEvent<HTMLInputElement>) {
    const input = e.target;
    const files = Array.from(input.files || []);
    input.value = "";
    if (!files.length || !canOpenAttachMenu) return;
    setUploading(true);
    setStatus({ text: "上传中...", kind: "warn-text" });
    try {
      const uploaded: UploadedAttachment[] = [];
      for (const file of files) {
        const result = kind === "file" ? await uploadFile(file) : await uploadImage(file);
        if (result.ok) uploaded.push(result);
      }
      if (!uploaded.length) {
        setStatus({ text: "上传失败，请重试", kind: "danger-text" });
        feedback("error");
        return;
      }
      setAttachments((prev) => [...prev, ...uploaded]);
      setStatus({ text: "附件已添加", kind: "ok-text" });
      feedback("success");
    } finally {
      setUploading(false);
    }
  }

  function removeAttachment(index: number) {
    if (!canRemoveAttachment) return;
    setAttachments((prev) => prev.filter((_, i) => i !== index));
    feedback("stopVoice");
  }

  const rightButtonMode: "send" | "wave" | "stop" | "loading" =
    isStopState ? "stop" : composerState === "uploading" || composerState === "realtime_stopping" ? "loading" : hasContent ? "send" : "wave";
  const rightButtonLabel =
    composerState === "sending"
      ? "中止发送"
      : isSpeechState
        ? "停止语音输入"
        : isRealtimeState
          ? "停止实时语音"
          : rightButtonMode === "loading"
            ? "处理中"
            : hasContent
              ? "发送"
              : "实时语音";
  const statusText =
    status.text ||
    (composerState === "sending"
      ? "正在发送..."
      : composerState === "speech_listening"
        ? "正在听写..."
        : composerState === "speech_processing"
          ? "正在识别..."
          : composerState === "realtime_checking" || composerState === "realtime_connecting"
            ? "正在连接实时语音…"
            : composerState === "realtime_connected"
              ? "实时语音中"
              : composerState === "assistant_speaking"
                ? "阿杜正在回答..."
                : composerState === "realtime_stopping"
                  ? "正在停止..."
                  : composerState === "uploading"
                    ? "上传中..."
                    : "");

  return (
    <div className="adu-bottom-composer" data-composer-state={composerState}>
      <div className="adu-composer-row">
        <button
          className="adu-plus-btn"
          id="aduPlusBtn"
          type="button"
          aria-label="添加"
          disabled={!canOpenAttachMenu}
          onClick={(e) => {
            e.stopPropagation();
            if (!canOpenAttachMenu) return;
            feedback("tap");
            setMenuOpen(!menuOpen);
          }}
        >
          {composerState === "uploading" ? "…" : "+"}
        </button>
        <div
          className={`adu-plus-menu${menuOpen ? " open" : ""}`}
          id="aduPlusMenu"
          aria-label="添加菜单"
          onClick={(e) => e.stopPropagation()}
        >
          <button type="button" disabled={!canOpenAttachMenu} onClick={() => { feedback("tap"); pick("image"); }}>上传图片</button>
          <button type="button" disabled={!canOpenAttachMenu} onClick={() => { feedback("tap"); pick("camera"); }}>拍照</button>
          <button type="button" disabled={!canOpenAttachMenu} onClick={() => { feedback("tap"); pick("file"); }}>文件</button>
        </div>
        <div className={`adu-input-pill${hasText ? "" : " has-inline-mic"}${isRealtimeState ? " voice-mode" : ""}`}>
          {attachments.length > 0 && (
            <div className="adu-attachment-tray" aria-label="已添加附件">
              {attachments.map((att, index) => (
                <div className="adu-attachment-chip" key={`${att.id || att.url || att.name}-${index}`}>
                  {att.kind === "image" ? <img src={att.url} alt={att.name} /> : <span className="adu-file-badge">FILE</span>}
                  <span className="adu-attachment-name">{att.name}</span>
                  <button type="button" aria-label="移除附件" disabled={!canRemoveAttachment} onClick={() => removeAttachment(index)}>
                    x
                  </button>
                </div>
              ))}
            </div>
          )}
          {isRealtimeState ? (
            <div className="adu-voice-inline" aria-live="polite">
              <span className="adu-voice-dot"></span>
              <span>{composerState === "assistant_speaking" ? "阿杜正在回答" : composerState === "realtime_connected" ? "实时语音中" : "正在连接实时语音…"}</span>
              <small>点击右侧停止</small>
            </div>
          ) : (
            <textarea
              ref={textareaRef}
              className="adu-chat-input"
              id="chatInput"
              placeholder="问问任何问题"
              rows={1}
              value={text}
              disabled={composerState === "realtime_stopping"}
              onChange={(e) => setText(e.target.value)}
              onKeyDown={onKeyDown}
            ></textarea>
          )}
          {!hasText && attachments.length === 0 && !isSending && !isRealtimeState && (
            <button
              id="aduInlineMicBtn"
              className={`adu-inline-mic${listening ? " listening" : ""}`}
              type="button"
              title="语音输入"
              aria-label="语音输入"
            disabled={composerState !== "idle_empty"}
              onClick={() => {
                feedback("tap");
                onMic();
              }}
            >
              <svg className="adu-inline-mic-icon" viewBox="0 0 24 24" fill="none" aria-hidden="true">
                <path d="M12 3a3 3 0 0 0-3 3v6a3 3 0 0 0 6 0V6a3 3 0 0 0-3-3Z" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" />
                <path d="M19 11a7 7 0 0 1-14 0M12 18v3M8 21h8" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" />
              </svg>
            </button>
          )}
        </div>
        <button
          className={`adu-wave-btn${rightButtonMode === "send" ? " send-mode" : ""}${isRealtimeState ? " realtime-active" : ""} realtime-${realtimeVoice.status} composer-${composerState}`}
          id="aduWaveBtn"
          type="button"
          aria-label={rightButtonLabel}
          title={rightButtonLabel}
          disabled={rightButtonMode === "loading"}
          onClick={() => {
            feedback("tap");
            void onWave();
          }}
        >
          {rightButtonMode === "send" ? (
            <svg className="adu-send-icon" viewBox="0 0 24 24" fill="none" aria-hidden="true">
              <path d="M12 19V5M6 11l6-6 6 6" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" />
            </svg>
          ) : rightButtonMode === "stop" ? (
            <svg className="adu-send-icon" viewBox="0 0 24 24" fill="none" aria-hidden="true">
              <path d="M7 7h10v10H7z" fill="currentColor" />
            </svg>
          ) : rightButtonMode === "loading" ? (
            <span className="adu-loading-dot" aria-hidden="true"></span>
          ) : (
            <span className="adu-wave-bars" aria-hidden="true">
              <span></span>
              <span></span>
              <span></span>
              <span></span>
              <span></span>
            </span>
          )}
        </button>
      </div>
      <div className={`adu-composer-status${status.kind ? ` ${status.kind}` : ""}`} id="aduComposerStatus" aria-live="polite">
        {statusText}
      </div>
      <input ref={imageInputRef} id="aduImageInput" type="file" accept="image/*" multiple hidden onChange={(e) => onFile("image", e)} />
      <input ref={cameraInputRef} id="aduCameraInput" type="file" accept="image/*" capture="environment" hidden onChange={(e) => onFile("camera", e)} />
      <input ref={fileInputRef} id="aduFileInput" type="file" multiple hidden onChange={(e) => onFile("file", e)} />
    </div>
  );
}
