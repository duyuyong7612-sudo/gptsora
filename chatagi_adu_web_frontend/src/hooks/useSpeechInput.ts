// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-5ada948163f4d8904a79a361ff537ef49a73335203dc2928686b9ab39b418b2a"
// Source-SHA256: "5e672bad51584773919b39bde89f8049de3affa8ebafb9d1a8d75d07f9f554dd"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import { useRef, useState } from "react";

type StatusFn = (text: string, kind: string) => void;

/**
 * 输入框内小麦克风 = 语音转文字（不是实时通话）。
 * 优先后端 STT（当前后端无独立 STT 文本接口）→ 退回浏览器 SpeechRecognition。
 * 识别结果只回填，不自动发送。
 */
export function useSpeechInput() {
  const [listening, setListening] = useState(false);
  const [processing, setProcessing] = useState(false);
  const recognitionRef = useRef<any>(null);

  function start(onText: (text: string) => void, onStatus: StatusFn) {
    stop();
    const SR: any = (window as any).SpeechRecognition || (window as any).webkitSpeechRecognition;
    if (!SR) {
      onStatus("语音输入暂不可用", "danger-text");
      return;
    }
    const recognition = new SR();
    recognitionRef.current = recognition;
    recognition.lang = "zh-CN";
    recognition.interimResults = true;
    recognition.continuous = false;
    setListening(true);
    setProcessing(false);
    onStatus("正在听写...", "warn-text");
    let finalText = "";
    recognition.onresult = (event: any) => {
      setProcessing(true);
      let interimText = "";
      for (let i = event.resultIndex; i < event.results.length; i += 1) {
        const t = event.results[i][0].transcript || "";
        if (event.results[i].isFinal) finalText += t;
        else interimText += t;
      }
      onText(`${finalText}${interimText}`.trim());
    };
    recognition.onerror = () => {
      setListening(false);
      setProcessing(false);
      onStatus("语音输入暂不可用", "danger-text");
    };
    recognition.onend = () => {
      setListening(false);
      setProcessing(false);
      onStatus("", "");
      recognitionRef.current = null;
    };
    try {
      recognition.start();
    } catch {
      setListening(false);
      setProcessing(false);
      onStatus("语音输入暂不可用", "danger-text");
    }
  }

  function stop() {
    const recognition = recognitionRef.current;
    recognitionRef.current = null;
    try {
      recognition?.abort?.();
    } catch {
      try {
        recognition?.stop?.();
      } catch {
        // best effort
      }
    }
    setListening(false);
    setProcessing(false);
  }

  return { listening, processing, start, stop };
}
