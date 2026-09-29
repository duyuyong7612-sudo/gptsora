// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-90c6b2f23d0869f7398b596bf9a3c979996d0d003d5f0be61fc201bbfa113147"
// Source-SHA256: "66c5d1b85c92b2c8ad655ea86ec506ea13dc3f71f6f79aed9b9a298429642baa"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
export type FeedbackType = "tap" | "success" | "error" | "startVoice" | "stopVoice";

interface FeedbackOptions {
  sound: boolean;
  haptics: boolean;
}

let options: FeedbackOptions = { sound: true, haptics: true };
let audioCtx: AudioContext | null = null;

function audioCtor(): typeof AudioContext | null {
  return (window.AudioContext || (window as any).webkitAudioContext || null) as typeof AudioContext | null;
}

export function configureFeedback(next: Partial<FeedbackOptions>) {
  options = { ...options, ...next };
}

export function ensureAudioContext(): AudioContext | null {
  if (!options.sound) return null;
  const Ctor = audioCtor();
  if (!Ctor) return null;
  try {
    if (!audioCtx) audioCtx = new Ctor();
    if (audioCtx.state === "suspended") void audioCtx.resume();
    return audioCtx;
  } catch {
    return null;
  }
}

export function vibrateLight(duration = 16) {
  if (!options.haptics) return;
  try {
    if ("vibrate" in navigator) navigator.vibrate(duration);
  } catch {
    // Haptics are best effort only.
  }
}

function playSequence(steps: Array<[number, number, number]>) {
  const ctx = ensureAudioContext();
  if (!ctx) return;
  const start = ctx.currentTime + 0.005;
  let cursor = start;
  for (const [freq, duration, gainValue] of steps) {
    const osc = ctx.createOscillator();
    const gain = ctx.createGain();
    osc.type = "sine";
    osc.frequency.setValueAtTime(freq, cursor);
    gain.gain.setValueAtTime(0.0001, cursor);
    gain.gain.exponentialRampToValueAtTime(gainValue, cursor + 0.012);
    gain.gain.exponentialRampToValueAtTime(0.0001, cursor + duration);
    osc.connect(gain);
    gain.connect(ctx.destination);
    osc.start(cursor);
    osc.stop(cursor + duration + 0.012);
    cursor += duration + 0.025;
  }
}

export function playTap() {
  playSequence([[520, 0.035, 0.018]]);
}

export function playSuccess() {
  playSequence([[660, 0.045, 0.018], [880, 0.055, 0.016]]);
}

export function playError() {
  playSequence([[220, 0.075, 0.02], [170, 0.065, 0.016]]);
}

export function playStartVoice() {
  playSequence([[520, 0.045, 0.018], [740, 0.06, 0.017]]);
}

export function playStopVoice() {
  playSequence([[740, 0.045, 0.016], [420, 0.06, 0.015]]);
}

export function feedback(type: FeedbackType) {
  if (type === "tap") {
    vibrateLight(12);
    playTap();
    return;
  }
  if (type === "success") {
    vibrateLight(18);
    playSuccess();
    return;
  }
  if (type === "error") {
    vibrateLight(24);
    playError();
    return;
  }
  if (type === "startVoice") {
    vibrateLight(18);
    playStartVoice();
    return;
  }
  if (type === "stopVoice") {
    vibrateLight(14);
    playStopVoice();
  }
}
