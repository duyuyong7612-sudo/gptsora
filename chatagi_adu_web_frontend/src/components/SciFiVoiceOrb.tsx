// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-225fd557cf0caf0e2f18a925aec8d38c14030630882c787820a176b3cc59d707"
// Source-SHA256: "7cba8e7e164bd8cf7eff3bf30a8ae018b91fcd19e126a5fc566ab5e27be8660c"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import type { CSSProperties } from "react";
import type { RealtimeVoiceStatus } from "../hooks/useRealtimeVoice";

export interface SciFiVoiceOrbProps {
  status: RealtimeVoiceStatus;
  amplitude?: number;
}

export function SciFiVoiceOrb({ status, amplitude = 0 }: SciFiVoiceOrbProps) {
  const level = Math.max(0, Math.min(1, amplitude));
  const mode =
    status === "assistant_speaking"
      ? "speaking"
      : status === "connected"
        ? "listening"
        : status === "error"
          ? "error"
          : status === "stopping"
            ? "stopping"
            : status === "checking" || status === "requesting_microphone" || status === "connecting"
            ? "connecting"
            : "idle";

  return (
    <div
      className={`sci-orb sci-orb-${mode}`}
      style={{ "--voice-level": level.toFixed(3) } as CSSProperties}
      aria-hidden="true"
    >
      <div className="sci-orb-shockwave one"></div>
      <div className="sci-orb-shockwave two"></div>
      <div className="sci-orb-core">
        <div className="sci-orb-grid lat"></div>
        <div className="sci-orb-grid lon"></div>
        <div className="sci-orb-grid lon alt"></div>
        <div className="sci-orb-energy"></div>
        <div className="sci-orb-crack c1"></div>
        <div className="sci-orb-crack c2"></div>
        <div className="sci-orb-crack c3"></div>
      </div>
      <div className="sci-orb-ring r1"></div>
      <div className="sci-orb-ring r2"></div>
      <div className="sci-orb-ring r3"></div>
    </div>
  );
}
