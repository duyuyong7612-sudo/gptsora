# iOS Voice Routes Audit: 6.1 Native Realtime and GPT Voice

Date: 2026-06-17

## 1. 所有语音入口列表

实际编译进 target 的主文件是 `GPTsora/Homechatview.swift`，不是 `GPTsora/JobAssistantView.swift` 或 `GPTsora/HomeChatView 2.swift`。

主聊天入口：
- 黑色实时语音按钮：`ChatGPTBlackButton`，无文本/附件时进入实时语音，见 `GPTsora/Homechatview.swift:2852`。
- 小麦克风按钮：聊天输入框内的 `Image(systemName: "mic")`，走 `AudioNoteRecorder` 录音笔记/普通聊天发送，不是 6.1 Native Realtime。
- 语音模式页面：`voiceScreen`，见 `GPTsora/Homechatview.swift:1107`。
- 语音模式底栏：`chatGPTVoiceBottomBar`，见 `GPTsora/Homechatview.swift:3033`。
- 语音/视频图标：底栏 video 按钮按套餐分流，Pro 回到 6.1 Native Realtime，Coder 才打开 OpenAI Realtime AV，见 `GPTsora/Homechatview.swift:3077`。

主实时服务：
- `RealtimeFastLane`：全局复用 `RealtimeBridge`，`ensureConnected()` 调 `bridge.startAudio()`。
- `RealtimeBridge`：`startAudio()` / `startAV()` 统一进入 `RealtimeAVService.start(mode:)`。
- `RealtimeAVService`：实际分流 provider、endpoint、WebSocket/WebRTC。
- `RealtimeAVCallView`：视频通话页硬性改成 `provider=openai`、`plan=coder`，见 `GPTsora/RealtimeAVCallView.swift:104`。

旧/旁路线：
- `RealtimeQuickService`：旧 `/session + WebRTC` 路线，仍被 `2ContentView.swift`、Remix 相关入口引用；不是 6.1 黑色按钮路线。
- `RealtimeCompanionService`：旧 companion `/session + WebRTC` 路线。
- `SemanticInterruptLabService`：实验室 OpenAI `/session + WebRTC` 路线。
- `AduVoiceService`：`/adu_voice` TTS/语音服务，不是实时 6.1。
- `/api/voice`：当前 Swift 主工程搜索未发现实际使用。

## 2. 6.1 当前实际调用路径

入口：ChatAGI Pro / 机器人 6.1 黑色按钮。

当前路径：
- `Homechatview.configureRealtimeForCurrentPlan()` 在 Pro 下设置 `preferredProvider = chatagi_native_realtime`，见 `GPTsora/Homechatview.swift:190`。
- 黑色按钮点击时调用 `startChatAGINativeRealtimeFromVoiceButton()`，见 `GPTsora/Homechatview.swift:2896`。
- 该函数强制设置：
  - `provider = chatagi_native_realtime`
  - `realtimePlan = pro`
  - `ws_url = AppConfig.Realtime.nativeRealtimeWSURLString`
  - 然后 `fast.stop()`，再 `fast.bridge.startAudio()`，见 `GPTsora/Homechatview.swift:211`。
- 默认 WS 地址是 `ws://YOUR_LAN_IP:8006/v1/realtime?mode=audio`，见 `GPTsora/AppConfig.swift:130`。
- `RealtimeAVService.fetchSessionFromBackend()` 遇到 `chatagi_native_realtime` 会直接构造 `SessionInfo(provider: .minicpm, wsURL: wsURL)` 并 return，不发 `/session`，见 `GPTsora/RealtimeAVService.swift:1221`。
- WebSocket 由 `connectQwenWebSocket()` 承载，但 wire provider 日志改为 `chatagi_native_realtime`，并且不加 OpenAI header，见 `GPTsora/RealtimeAVService.swift:4440`。

结论：
- 6.1 不走 `/api/voice`。
- 6.1 不走 OpenAI。
- 6.1 黑色按钮不再走普通 `/session`。
- UI 可见文案已改为 `ChatAGI 阿杜实时语音模型`，见 `GPTsora/Homechatview.swift:56`。

## 3. GPT 语音当前实际调用路径

当前 GPT 语音对应 Ultra / Coder 路线：
- `configureRealtimeForCurrentPlan()` 在 Ultra/Coder 下设置 `preferredProvider = openai`，见 `GPTsora/Homechatview.swift:194`。
- `RealtimeAVService.sessionURL` 只有在 `provider=openai` 且 `plan=ultra/coder` 时使用 `/api/realtime/session`，见 `GPTsora/RealtimeAVService.swift:1196`。
- OpenAI session 返回后进入 `.openai` 分支，建立 WebRTC 并 negotiate，见 `GPTsora/RealtimeAVService.swift:891`。
- 视频通话页 `RealtimeAVCallView` 会强制 `provider=openai`、`plan=coder`，避免残留自部署 provider，见 `GPTsora/RealtimeAVCallView.swift:104`。

是否走 OpenAI Realtime：
- 是。Ultra/Coder 的主实时语音是 OpenAI Realtime WebRTC。

是否走旧 `/api/voice`：
- 否。主工程 Swift 搜索未发现 `/api/voice` 使用。

是否走普通 `/session`：
- 主 OpenAI GPT 语音不走普通 `/session`，走 `/api/realtime/session`。
- 旧 `RealtimeQuickService`、`RealtimeCompanionService`、`SemanticInterruptLabService` 仍有普通 `/session` 旁路线，但不是当前黑色按钮 6.1 路线。

当前是否可用：
- 代码路径完整，但真机可用性取决于后端 `/api/realtime/session` 是否返回有效 OpenAI Realtime session，以及 WebRTC 框架/麦克风权限是否正常。
- 如果不可用，优先查：
  - `/api/realtime/session` HTTP 状态和 JSON 是否包含 OpenAI `rtc_url` / ephemeral key。
  - App 日志是否出现 `[OpenAIRealtime] REJECT session: requested openai but got provider=...`。
  - WebRTC negotiate 是否失败。
  - 麦克风权限和 AVAudioSession 是否被其它模块占用。

## 4. 已修复内容

- Pro / 6.1 黑色按钮强制走 `chatagi_native_realtime`，并在启动前 `fast.stop()` 清掉旧连接，避免复用旧 `/session -> minicpm_selfhost` 连接。
- `RealtimeAVService.fetchSessionFromBackend()` 对 `chatagi_native_realtime` 直接使用 `ws://YOUR_LAN_IP:8006/v1/realtime?mode=audio`，不再请求 `/session`。
- 6.1 所需日志已覆盖：
  - `[ChatAGINativeRealtime] button_tapped`
  - `[ChatAGINativeRealtime] provider=chatagi_native_realtime`
  - `[ChatAGINativeRealtime] ws_url=ws://YOUR_LAN_IP:8006/v1/realtime?mode=audio`
  - `[ChatAGINativeRealtime] connecting...`
  - `[ChatAGINativeRealtime] connected`
  - `[ChatAGINativeRealtime] session.queue_done`
  - `[ChatAGINativeRealtime] session.update sent`
  - `[ChatAGINativeRealtime] audio_chunk sent`
  - `[ChatAGINativeRealtime] result.text`
  - `[ChatAGINativeRealtime] result.audio_data`
  - `[ChatAGINativeRealtime] end_of_turn`
- Pro 套餐 UI 副标题从 OpenAI 文案改成 `ChatAGI 阿杜实时语音模型`。
- `RealtimeAVService` 注释更新为 6.1 直连 Native WebSocket，减少后续误判。
- GPT/OpenAI 路线保留独立 provider，不和 6.1 共用错误 `/api/voice` 或旧 `/session`。

## 5. 还需要手动测试什么

1. 真机选择 ChatAGI Pro / 机器人 6.1，点击黑色实时语音按钮。
2. Xcode 控制台确认依次出现 `button_tapped`、`provider=chatagi_native_realtime`、`ws_url=...8006...`、`connecting...`、`connected`。
3. Mac 后端确认出现 8006 WebSocket 连接日志，不应再只看到 `POST /session -> 200 provider=minicpm_selfhost`。
4. 开口说话，确认出现 `audio_chunk sent`。
5. 后端返回时确认出现 `result.text`、`result.audio_data`、`end_of_turn`，并且 App 能播放声音。
6. 切到 Ultra/Coder，测试 GPT 语音，确认走 `/api/realtime/session` 和 `[OpenAIRealtime]` 日志。
7. 回到 Pro 再点黑色按钮，确认不会残留 OpenAI/Qwen provider。
