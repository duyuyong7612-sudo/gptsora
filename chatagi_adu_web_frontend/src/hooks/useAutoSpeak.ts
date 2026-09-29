// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-55e2587362da58745df39e9e99e0aae6682fa92b9f90066c03c16534bc97d590"
// Source-SHA256: "2d76fa30619a4ba461b7aa54f0dbf2e63f683b1ccace107f48b73f9265c03804"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import { useCallback, useEffect, useRef, useState } from "react";
import { APP_TTS_SPEED, resolveBackendUrl, speakByBackend, stopBackendSpeak } from "../api/ttsApi";

const MIN_SEGMENT_CHARS = 18;
const MAX_SEGMENT_CHARS = 80;
const SENTENCE_BOUNDARY = new Set(["。", "！", "？", "；", "：", "!", "?", ";", ":", "\n"]);
const SECONDARY_BOUNDARY = new Set(["，", "、", ","]);

const BLOCKED_LINE = /\b(Memory replies|memory|debug|trace|internal|tool_debug|route_info)\b/i;

type SpeakSource = "backend" | "browser";
type QueueItem = { text: string; messageId: string; preparedUrl?: string };

function stripCodeBlocks(text: string): string {
  return text.replace(/```[\s\S]*?```/g, " ").replace(/`[^`]*`/g, " ");
}

function looksLikeRawJson(text: string): boolean {
  const trimmed = text.trim();
  if (!trimmed) return true;
  if (!((trimmed.startsWith("{") && trimmed.endsWith("}")) || (trimmed.startsWith("[") && trimmed.endsWith("]")))) return false;
  try {
    JSON.parse(trimmed);
    return true;
  } catch {
    return false;
  }
}

export function cleanSpeakText(text: string): string {
  const noCode = stripCodeBlocks(text)
    .split(/\n+/)
    .filter((line) => !BLOCKED_LINE.test(line))
    .join("\n");

  if (looksLikeRawJson(noCode)) return "";

  return noCode
    .replace(/https?:\/\/\S{18,}/gi, " ")
    .replace(/!\[[^\]]*]\([^)]+\)/g, " ")
    .replace(/\[([^\]]+)]\([^)]+\)/g, "$1")
    .replace(/^\s{0,3}#{1,6}\s+/gm, "")
    .replace(/[#>*_~|`]+/g, " ")
    .replace(/\b(debug|trace|internal):\s*\S+/gi, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function findCut(chars: string[], force: boolean): number {
  if (chars.length === 0) return -1;
  const upper = Math.min(chars.length, MAX_SEGMENT_CHARS);

  for (let i = upper - 1; i >= MIN_SEGMENT_CHARS - 1; i -= 1) {
    if (SENTENCE_BOUNDARY.has(chars[i])) return i + 1;
  }
  for (let i = upper - 1; i >= MIN_SEGMENT_CHARS - 1; i -= 1) {
    if (SECONDARY_BOUNDARY.has(chars[i])) return i + 1;
  }
  if (chars.length >= MAX_SEGMENT_CHARS) return upper;
  if (force) return chars.length;
  return -1;
}

function popSpeakableSegments(buffer: string, force = false): { segments: string[]; rest: string } {
  let rest = buffer.replace(/\r/g, "");
  const segments: string[] = [];

  while (rest.trim()) {
    const chars = Array.from(rest);
    if (!force && chars.length < MIN_SEGMENT_CHARS && !chars.some((ch) => SENTENCE_BOUNDARY.has(ch))) break;

    const cut = findCut(chars, force);
    if (cut < 0) break;

    const raw = chars.slice(0, cut).join("");
    const cleaned = cleanSpeakText(raw);
    if (cleaned) segments.push(cleaned);
    rest = chars.slice(cut).join("");

    if (!force && Array.from(rest).length < MIN_SEGMENT_CHARS) break;
  }

  return { segments, rest };
}

function scoreVoice(voice: SpeechSynthesisVoice): number {
  const haystack = `${voice.name} ${voice.lang} ${voice.voiceURI}`.toLowerCase();
  let score = 0;
  if (haystack.includes("zh-cn")) score += 100;
  if (haystack.includes("zh_hans") || haystack.includes("zh-hans")) score += 90;
  if (haystack.includes("mandarin")) score += 80;
  if (haystack.includes("chinese") || haystack.includes("中文") || haystack.includes("普通话")) score += 70;
  for (const token of ["tingting", "meijia", "sinji", "xiaoxiao", "xiaoyi", "yu-shu", "li-mu"]) {
    if (haystack.includes(token)) score += 120;
  }
  if (haystack.includes("female") || haystack.includes("woman") || haystack.includes("girl") || haystack.includes("女")) score += 20;
  if (voice.localService) score += 5;
  return score;
}

export function selectAppLikeVoice(): SpeechSynthesisVoice | null {
  if (!("speechSynthesis" in window)) return null;
  const voices = window.speechSynthesis.getVoices();
  if (!voices.length) return null;
  return voices
    .map((voice) => ({ voice, score: scoreVoice(voice) }))
    .filter((item) => item.score > 0)
    .sort((a, b) => b.score - a.score)[0]?.voice || null;
}

export function useAutoSpeak() {
  const [isSpeaking, setIsSpeaking] = useState(false);
  const [speakingMessageId, setSpeakingMessageId] = useState<string | null>(null);
  const [source, setSource] = useState<SpeakSource | null>(null);
  const queueRef = useRef<QueueItem[]>([]);
  const bufferRef = useRef("");
  const activeMessageIdRef = useRef<string | null>(null);
  const audioRef = useRef<HTMLAudioElement | null>(null);
  const utteranceRef = useRef<SpeechSynthesisUtterance | null>(null);
  const playingRef = useRef(false);
  const generationRef = useRef(0);
  const fallbackTextByMessageRef = useRef<Record<string, string>>({});

  const stop = useCallback(() => {
    generationRef.current += 1;
    queueRef.current = [];
    bufferRef.current = "";
    activeMessageIdRef.current = null;
    playingRef.current = false;
    utteranceRef.current = null;
    stopBackendSpeak(audioRef.current);
    audioRef.current = null;
    if ("speechSynthesis" in window) window.speechSynthesis.cancel();
    setIsSpeaking(false);
    setSpeakingMessageId(null);
    setSource(null);
  }, []);

  const speakWithBrowserFallback = useCallback((item: QueueItem, generation: number, onDone: () => void) => {
    if (!("speechSynthesis" in window) || generation !== generationRef.current) {
      onDone();
      return;
    }
    const fallbackText = cleanSpeakText(item.text || fallbackTextByMessageRef.current[item.messageId] || "");
    if (!fallbackText) {
      onDone();
      return;
    }

    const utterance = new SpeechSynthesisUtterance(fallbackText);
    utterance.lang = "zh-CN";
    utterance.rate = 0.95;
    utterance.pitch = 1.04;
    utterance.volume = 1.0;
    const voice = selectAppLikeVoice();
    if (voice) utterance.voice = voice;

    utterance.onend = onDone;
    utterance.onerror = onDone;

    utteranceRef.current = utterance;
    setSource("browser");
    window.speechSynthesis.speak(utterance);
  }, []);

  const speakNext = useCallback(() => {
    if (playingRef.current) return;
    const item = queueRef.current.shift();
    if (!item) {
      setIsSpeaking(false);
      setSpeakingMessageId(null);
      setSource(null);
      return;
    }

    const generation = generationRef.current;
    playingRef.current = true;
    setIsSpeaking(true);
    setSpeakingMessageId(item.messageId);
    setSource("backend");

    const done = () => {
      if (generation !== generationRef.current) return;
      playingRef.current = false;
      utteranceRef.current = null;
      audioRef.current = null;
      speakNext();
    };

    const playBackend = async () => {
      try {
        const url = item.preparedUrl || (await speakByBackend(item.text)).url;
        if (generation !== generationRef.current) return;
        const audio = new Audio(resolveBackendUrl(url));
        audio.preload = "auto";
        audioRef.current = audio;
        audio.onended = done;
        audio.onerror = () => speakWithBrowserFallback(item, generation, done);
        await audio.play();
      } catch {
        speakWithBrowserFallback(item, generation, done);
      }
    };

    void playBackend();
  }, [speakWithBrowserFallback]);

  const enqueueText = useCallback(
    (text: string, messageId = activeMessageIdRef.current || "manual", preparedUrl?: string) => {
      const cleaned = preparedUrl ? text.trim() || " " : cleanSpeakText(text);
      if (!preparedUrl && !cleaned) return;
      queueRef.current.push({ text: cleaned, messageId, preparedUrl });
      speakNext();
    },
    [speakNext],
  );

  const speakPreparedUrl = useCallback(
    (messageId: string, url: string, fallbackText = "") => {
      stop();
      activeMessageIdRef.current = messageId;
      if (fallbackText) fallbackTextByMessageRef.current[messageId] = fallbackText;
      queueRef.current.push({ text: "", messageId, preparedUrl: resolveBackendUrl(url) });
      speakNext();
    },
    [speakNext, stop],
  );

  const rememberFallbackDelta = useCallback((delta: string, messageId: string) => {
    if (!delta) return;
    fallbackTextByMessageRef.current[messageId] = (fallbackTextByMessageRef.current[messageId] || "") + delta;
  }, []);

  const speakText = useCallback(
    (text: string, messageId = "manual") => {
      stop();
      activeMessageIdRef.current = messageId;
      const { segments } = popSpeakableSegments(text, true);
      for (const segment of segments) enqueueText(segment, messageId);
    },
    [enqueueText, stop],
  );

  const speakStreamingDelta = useCallback(
    (delta: string, messageId: string) => {
      if (!delta.trim()) return;
      if (activeMessageIdRef.current !== messageId) {
        stop();
        activeMessageIdRef.current = messageId;
      }
      bufferRef.current += delta;
      const { segments, rest } = popSpeakableSegments(bufferRef.current, false);
      bufferRef.current = rest;
      for (const segment of segments) enqueueText(segment, messageId);
    },
    [enqueueText, stop],
  );

  const flush = useCallback(
    (messageId: string) => {
      if (activeMessageIdRef.current && activeMessageIdRef.current !== messageId) return;
      const { segments } = popSpeakableSegments(bufferRef.current, true);
      bufferRef.current = "";
      for (const segment of segments) enqueueText(segment, messageId);
    },
    [enqueueText],
  );

  useEffect(() => {
    if (!("speechSynthesis" in window)) return;
    const loadVoices = () => selectAppLikeVoice();
    window.speechSynthesis.addEventListener("voiceschanged", loadVoices);
    loadVoices();
    return () => window.speechSynthesis.removeEventListener("voiceschanged", loadVoices);
  }, []);

  useEffect(() => stop, [stop]);

  return {
    speakText,
    enqueueText,
    speakPreparedUrl,
    rememberFallbackDelta,
    speakStreamingDelta,
    flush,
    stop,
    isSpeaking,
    speakingMessageId,
    source,
    statusText: isSpeaking ? `阿杜正在播报${source === "browser" ? "（浏览器兜底）" : ""}...` : "",
    appTtsSpeed: APP_TTS_SPEED,
  };
}
