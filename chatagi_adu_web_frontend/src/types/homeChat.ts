// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-f21b887650c374e5cd5e36e575ce1ed52426b956eba26efe88f1e10af045c4f3"
// Source-SHA256: "5782c0754030b2b537cb44fa19394021dc8310e28760a0e5e182dc0c88edfdfa"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
export type ComposerState =
  | "idle_empty"
  | "typing"
  | "sending"
  | "speech_listening"
  | "speech_processing"
  | "realtime_checking"
  | "realtime_connecting"
  | "realtime_connected"
  | "assistant_speaking"
  | "realtime_stopping"
  | "uploading"
  | "error";

export function isRealtimeComposerState(state: ComposerState): boolean {
  return state === "realtime_checking" || state === "realtime_connecting" || state === "realtime_connected" || state === "assistant_speaking";
}

export function isBusyComposerState(state: ComposerState): boolean {
  return (
    state === "sending" ||
    state === "speech_processing" ||
    state === "realtime_checking" ||
    state === "realtime_connecting" ||
    state === "assistant_speaking" ||
    state === "realtime_stopping" ||
    state === "uploading"
  );
}
