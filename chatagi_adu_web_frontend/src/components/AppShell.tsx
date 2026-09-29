// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-d8987e7f7ea34b2870c5fa6d96b8f6733d924ead5873417e7d1c0f68389f3cf6"
// Source-SHA256: "484c96b0035feeefe5b99a80226601abd7dfb8c7cd82d55ec9a894724459c590"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import { useEffect, useState } from "react";
import { TopNav, ViewName } from "./TopNav";
import { ChatPage } from "./ChatPage";
import { VoicePage } from "./VoicePage";
import { ComputerControlPage } from "./ComputerControlPage";
import { DevPage } from "./DevPage";
import { SettingsPage } from "./SettingsPage";
import { backendBase, getJson } from "../api/backendBase";
import { configureFeedback, feedback } from "../utils/feedback";

function viewClass(active: boolean): string {
  return active ? "view active" : "view";
}

/** 应用外壳：顶部导航 + 各视图（视觉与原 index.html 一致）。 */
export function AppShell() {
  const [activeView, setActiveView] = useState<ViewName>("home");
  const [backendInfo, setBackendInfo] = useState<string>(backendBase());
  const [buttonSoundEnabled, setButtonSoundEnabled] = useState(true);
  const [hapticEnabled, setHapticEnabled] = useState(true);

  useEffect(() => {
    configureFeedback({ sound: buttonSoundEnabled, haptics: hapticEnabled });
  }, [buttonSoundEnabled, hapticEnabled]);

  useEffect(() => {
    const onClick = (event: MouseEvent) => {
      const el = event.target instanceof Element ? event.target.closest("button") : null;
      if (!el || (el as HTMLButtonElement).disabled) return;
      feedback("tap");
    };
    document.addEventListener("click", onClick, true);
    return () => document.removeEventListener("click", onClick, true);
  }, []);

  // 接口自检：只写 console + 设置页小字，不弹大框。
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const apiBase = backendBase();
      const result = { backend: false, chat: "/chat/prepare", computer: false, realtime: false };
      try {
        await getJson("/health");
        result.backend = true;
      } catch (err) {
        console.warn("[selfcheck] health failed", err);
      }
      try {
        await getJson("/api/brain/computer/config");
        result.computer = true;
      } catch (err) {
        console.warn("[selfcheck] computer config failed", err);
      }
      try {
        await getJson("/api/realtime/health");
        result.realtime = true;
      } catch (err) {
        console.warn("[selfcheck] realtime failed", err);
      }
      console.info("[selfcheck]", result);
      if (!cancelled) {
        setBackendInfo(
          `${apiBase} · 后端：${result.backend ? "已连接" : "未连接"} · 聊天接口：${result.chat} · 电脑控制：${result.computer ? "已连接" : "未连接"} · 实时语音：${result.realtime ? "已就绪" : "未就绪"}`,
        );
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  return (
    <div className="app">
      <div className="shell">
        <TopNav activeView={activeView} onNavigate={setActiveView} />
        <main>
          <section id="home" className={viewClass(activeView === "home")}>
            <div className="hero">
              <div className="hero-grid">
                <div className="hero-copy">
                  <h1><span className="gradient-text">ChatAGI-阿杜</span></h1>
                  <p className="subtitle">你的全能 AI 大脑：可聊天、实时语音、看屏幕、控制电脑、自动开发。</p>
                  <div className="hero-actions">
                    <button className="entry" onClick={() => setActiveView("chat")}><b>开始聊天</b><span>进入主对话区，选择机器人 6 系模型。</span></button>
                    <button className="entry" onClick={() => setActiveView("voice")}><b>实时语音</b><span>检测后端会话能力，准备实时交互。</span></button>
                    <button className="entry" onClick={() => setActiveView("computer")}><b>控制电脑</b><span>截图、移动、点击、输入和执行任务。</span></button>
                  </div>
                </div>
                <aside className="glass orbit-panel">
                  <div className="panel-title">
                    <span>AGI Control Surface</span>
                    <span className="ok-text">online</span>
                  </div>
                  <div className="pulse-core">
                    <div className="core">AI</div>
                  </div>
                  <div className="metric-row">
                    <div className="metric"><strong>4</strong><span>机器人模型</span></div>
                    <div className="metric"><strong>7</strong><span>控制接口</span></div>
                    <div className="metric"><strong>1</strong><span>统一主页</span></div>
                  </div>
                </aside>
              </div>
            </div>
          </section>

          <section id="chat" className={viewClass(activeView === "chat")}>
            <ChatPage />
          </section>

          <section id="voice" className={viewClass(activeView === "voice")}>
            <VoicePage active={activeView === "voice"} />
          </section>

          <section id="computer" className={viewClass(activeView === "computer")}>
            <ComputerControlPage />
          </section>

          <section id="dev" className={viewClass(activeView === "dev")}>
            <DevPage />
          </section>

          <section id="settings" className={viewClass(activeView === "settings")}>
            <SettingsPage
              backendInfo={backendInfo}
              buttonSoundEnabled={buttonSoundEnabled}
              hapticEnabled={hapticEnabled}
              onButtonSoundChange={setButtonSoundEnabled}
              onHapticChange={setHapticEnabled}
            />
          </section>
        </main>
      </div>
    </div>
  );
}
