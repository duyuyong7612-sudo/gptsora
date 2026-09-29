// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-1a730a657b6b33ed7637f946afcd3b9c0d99023bed153d72e7b977ff8e07f98e"
// Source-SHA256: "881eed41f171b7374dfcbcc5ddf49a41fc3b4f881e0ed9a21c9e0e3da827cf9b"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import type { RealtimeVoiceStatus } from "../hooks/useRealtimeVoice";
import { feedback } from "../utils/feedback";
import { SciFiVoiceOrb } from "./SciFiVoiceOrb";

export interface VoiceControllerLike {
  status: RealtimeVoiceStatus;
  statusText: string;
  errorText: string;
  amplitude: number;
  lastUserText: string;
  lastAssistantText: string;
  isActive: boolean;
  start: (options?: { model?: string; plan?: string }) => Promise<void> | void;
  stop: () => Promise<void> | void;
  toggle: (options?: { model?: string; plan?: string }) => Promise<void> | void;
  probe: () => Promise<unknown>;
}

export interface VoiceModePanelProps {
  realtimeVoice: VoiceControllerLike;
}

function voiceModeTitle(status: RealtimeVoiceStatus) {
  if (status === "checking" || status === "requesting_microphone" || status === "connecting") return "正在连接实时语音…";
  if (status === "assistant_speaking") return "阿杜正在回答...";
  if (status === "connected") return "实时语音中";
  if (status === "stopping") return "正在停止...";
  if (status === "error") return "实时语音连接失败";
  return "语音模式";
}

export function VoiceModePanel({ realtimeVoice }: VoiceModePanelProps) {
  const title = voiceModeTitle(realtimeVoice.status);
  const hint =
    realtimeVoice.status === "error"
      ? realtimeVoice.errorText || "实时语音连接失败，请重试"
      : realtimeVoice.lastUserText
        ? `你说：${realtimeVoice.lastUserText}`
        : realtimeVoice.status === "assistant_speaking"
          ? realtimeVoice.lastAssistantText || "正在生成语音回复"
          : "点击停止";

  return (
    <div className={`voice-mode-panel realtime-${realtimeVoice.status}`} aria-live="polite">
      <div className="voice-mode-status">
        <span className="voice-mode-kicker">语音模式</span>
        <h2>{title}</h2>
        <p>{hint}</p>
      </div>
      <SciFiVoiceOrb status={realtimeVoice.status} amplitude={realtimeVoice.amplitude} />
      <button
        className="voice-mode-stop"
        type="button"
        onClick={() => {
          feedback("stopVoice");
          void realtimeVoice.stop();
        }}
      >
        停止
      </button>
    </div>
  );
}
