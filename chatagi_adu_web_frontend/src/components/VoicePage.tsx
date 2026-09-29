// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-62de75dfd56f4cdaf388956a4f0261b200529adddd5f2ad907839759119c5b26"
// Source-SHA256: "57fd0f9169f98eedaa2d4fdba2bf732228d7af58c9c777c187ee8f70e0eaedac"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import { useEffect, useState } from "react";
import { useRealtimeVoice } from "../hooks/useRealtimeVoice";
import { useLiveKitRealtimeVoice } from "../hooks/useLiveKitRealtimeVoice";
import { feedback } from "../utils/feedback";

export interface VoicePageProps {
  active: boolean;
}

/** 实时语音页：复用 HomeChat 的 ChatAGI Native WebSocket 实时语音链路。 */
export function VoicePage({ active }: VoicePageProps) {
  const realtimeVoice = useRealtimeVoice();
  const { isActive, stop } = realtimeVoice;
  const kind = realtimeVoice.status === "connected" ? "ok-text" : realtimeVoice.status === "error" ? "danger-text" : "warn-text";

  useEffect(() => {
    if (!active && isActive) void stop();
  }, [active, isActive, stop]);

  return (
    <section className="glass page">
      <div className="page-head">
        <h2>实时语音</h2>
        <button
          className="ghost-btn"
          id="probeVoiceBtn"
          onClick={() => {
            void realtimeVoice.probe();
          }}
        >
          检测后端
        </button>
      </div>
      <div className="page-body voice-stage">
        <button
          className={`mic realtime-${realtimeVoice.status}`}
          id="micBtn"
          title="麦克风"
          onClick={() => {
            void realtimeVoice.toggle()
              .then(() => feedback(realtimeVoice.isActive ? "stopVoice" : "startVoice"))
              .catch(() => feedback("error"));
          }}
        >
          🎙
        </button>
        <div>
          <div className={`status-line ${kind}`} id="voiceStatus">{realtimeVoice.statusText}</div>
          <p className="muted">实时语音通过 ChatAGI Native WebSocket 链路连接，不在前端暴露密钥。</p>
        </div>
        <div className="voice-controls">
          <button
            className="primary-btn"
            id="voiceStartBtn"
            onClick={() => {
              void realtimeVoice.start().then(() => feedback("startVoice")).catch(() => feedback("error"));
            }}
          >
            开始实时语音
          </button>
          <button
            className="ghost-btn"
            id="voiceStopBtn"
            onClick={() => {
              void realtimeVoice.stop().then(() => feedback("stopVoice"));
            }}
          >
            停止实时语音
          </button>
        </div>
      </div>
    </section>
  );
}
