// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-a7e2d8fe708ddeab2ad0d3ea6865f7ef44e57435a71384a10182e89ba089cbfe"
// Source-SHA256: "7d727515b65813eb3af82545288090a94d7fd6bb8c3a3fec65b76f9fbb2da945"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import { useEffect, useRef, useState } from "react";
import { useAutoSpeak } from "../hooks/useAutoSpeak";
import { useSseChat } from "../hooks/useSseChat";
import { useRealtimeVoice } from "../hooks/useRealtimeVoice";
import { MessageBubble } from "./MessageBubble";
import { HomeChatComposer } from "./HomeChatComposer";
import { VoiceModePanel } from "./VoiceModePanel";

/** 聊天页：会话侧栏 + 消息流 + 模型选择 + 底部输入栏。 */
export function ChatPage() {
  const autoSpeak = useAutoSpeak();
  const realtimeVoice = useRealtimeVoice();
  const { messages, chatStatus, send, newChat, abort, isSending } = useSseChat({
    onAssistantPreparedTts: autoSpeak.speakPreparedUrl,
    onAssistantTextDelta: autoSpeak.rememberFallbackDelta,
    onAssistantDelta: autoSpeak.speakStreamingDelta,
    onAssistantDone: autoSpeak.flush,
  });
  const [model, setModel] = useState("机器人 6.2");
  const messagesRef = useRef<HTMLDivElement>(null);
  const showVoiceMode = realtimeVoice.isActive || realtimeVoice.status === "assistant_speaking" || realtimeVoice.status === "error";

  useEffect(() => {
    const el = messagesRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [messages]);

  useEffect(() => autoSpeak.stop, [autoSpeak.stop]);

  function handleNewChat() {
    autoSpeak.stop();
    void realtimeVoice.stop();
    newChat();
  }

  return (
    <div className="workspace">
      <aside className="glass sidebar">
        <div className="side-head">
          <h2>会话</h2>
          <button className="mini-btn" id="newChatBtn" title="新会话" onClick={handleNewChat}>+</button>
        </div>
        <div className="session-list" id="sessionList">
          <button className="session active">阿杜主会话</button>
          <button className="session">电脑任务</button>
          <button className="session">开发计划</button>
        </div>
      </aside>
      <section className="glass chat-main">
        <div className="chat-head">
          <div>
            <h2 style={{ margin: 0, fontSize: "18px" }}>聊天</h2>
            <div className={`muted${chatStatus.kind ? ` ${chatStatus.kind}` : ""}`} id="chatStatus">
              {autoSpeak.statusText || chatStatus.text}
            </div>
          </div>
          <select
            className="model-select"
            id="modelSelect"
            aria-label="模型选择"
            value={model}
            onChange={(e) => setModel(e.target.value)}
          >
            <option>机器人 6.0</option>
            <option>机器人 6.1</option>
            <option>机器人 6.2</option>
            <option>机器人 6.2 Pro</option>
          </select>
        </div>
        {showVoiceMode ? (
          <VoiceModePanel realtimeVoice={realtimeVoice} />
        ) : (
          <div className="messages" id="messages" ref={messagesRef}>
            {messages.map((m) => (
              <MessageBubble
                key={m.id}
                id={m.id}
                role={m.role}
                text={m.text}
                attachments={m.attachments}
                isSpeaking={autoSpeak.speakingMessageId === m.id && autoSpeak.isSpeaking}
                onSpeak={() => autoSpeak.speakText(m.text, m.id)}
                onStopSpeak={autoSpeak.stop}
              />
            ))}
          </div>
        )}
        <HomeChatComposer
          onSendText={(t, attachments) => send(t, model, attachments)}
          isSending={isSending}
          onAbortSend={abort}
          realtimeVoice={realtimeVoice}
          selectedModel={model}
        />
      </section>
    </div>
  );
}
