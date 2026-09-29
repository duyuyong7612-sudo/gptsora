// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-0e88a81c90b30a84da2e9c0d2bf046d24309d7d422156e6dcad7be96c5fe4a7f"
// Source-SHA256: "0783c3408d846b947e3373434ad9f2d2407ca916ba01c173eaccfa85e362ae0d"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import type { UploadedAttachment } from "../api/uploadApi";
import { feedback } from "../utils/feedback";

export interface MessageBubbleProps {
  id: string;
  role: "user" | "assistant";
  text: string;
  attachments?: UploadedAttachment[];
  isSpeaking?: boolean;
  onSpeak?: () => void;
  onStopSpeak?: () => void;
}

/** 单条消息气泡。只渲染纯文本（textContent 等价），绝不注入 HTML / raw JSON。 */
export function MessageBubble({ role, text, attachments = [], isSpeaking = false, onSpeak, onStopSpeak }: MessageBubbleProps) {
  function toggleSpeak() {
    if (isSpeaking) {
      onStopSpeak?.();
      feedback("stopVoice");
      return;
    }
    onSpeak?.();
    feedback("startVoice");
  }

  return (
    <div className={`message ${role}`}>
      {attachments.length > 0 && (
        <div className="message-attachments">
          {attachments.map((att) =>
            att.kind === "image" ? (
              <a className="message-attachment image" href={att.url} target="_blank" rel="noreferrer" key={att.id || att.url || att.name}>
                <img src={att.url} alt={att.name} />
              </a>
            ) : (
              <a className="message-attachment file" href={att.url} target="_blank" rel="noreferrer" key={att.id || att.url || att.name}>
                <span className="file-icon">FILE</span>
                <span className="file-name">{att.name}</span>
              </a>
            ),
          )}
        </div>
      )}
      {text.trim() && <span className="message-text">{text}</span>}
      {role === "assistant" && text.trim() && (
        <button
          className={`speaker-btn${isSpeaking ? " speaking" : ""}`}
          type="button"
          title={isSpeaking ? "停止播报" : "播报回复"}
          aria-label={isSpeaking ? "停止播报" : "播报回复"}
          onClick={toggleSpeak}
        >
          {isSpeaking ? (
            <svg viewBox="0 0 24 24" fill="none" aria-hidden="true">
              <path d="M8 7h3v10H8zM13 7h3v10h-3z" fill="currentColor" />
            </svg>
          ) : (
            <svg viewBox="0 0 24 24" fill="none" aria-hidden="true">
              <path
                d="M4 9v6h4l5 4V5L8 9H4Z"
                stroke="currentColor"
                strokeWidth="1.8"
                strokeLinecap="round"
                strokeLinejoin="round"
              />
              <path
                d="M16 9.5a4 4 0 0 1 0 5M18.5 7a7 7 0 0 1 0 10"
                stroke="currentColor"
                strokeWidth="1.8"
                strokeLinecap="round"
              />
            </svg>
          )}
        </button>
      )}
    </div>
  );
}
