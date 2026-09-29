# iOS HomeChat / RealtimeAV 证据审计

审计时间：2026-06-22

范围：

- iOS App 工程：`~/Desktop/GPTsora`
- Web 正式源码：`~/Desktop/backend/chatagi_adu_web_frontend`
- 后端：`~/Desktop/backend/server_session.py`

本次只读审计没有修改 Web 源码、没有运行 `npm run build`、没有修改 `server_session.py`。唯一写入是本审计报告文件。

## 1. 找到的 iOS 文件路径

### HomeChat / 输入栏相关

- `~/Desktop/GPTsora/GPTsora/Homechatview.swift`
- `~/Desktop/GPTsora/GPTsora/HomeChatView 2.swift`
- `~/Desktop/GPTsora/2HomeChatView.swift`
- `~/Desktop/GPTsora/GPTsora/ComputerControlHomeView.swift`
- `~/Desktop/GPTsora/GPTsora/PlusAttachmentModule.swift`

具体证据：

- `Homechatview.swift:70` 定义 `struct HomeChatView: View`。
- `Homechatview.swift:349` 定义 `@State private var inputText: String = ""`。
- `Homechatview.swift:353` 定义 `@State private var sendTask: Task<Void, Never>? = nil`。
- `Homechatview.swift:478` 定义 `@StateObject private var audioNote = AudioNoteRecorder()`。
- `Homechatview.swift:2995-3130` 是底部主输入栏主体：`+`、输入框、小麦克风、右侧黑/波纹/发送/停止按钮。
- `Homechatview.swift:3076-3078` 根据 `isSending`、`hasText`、`hasAttachments` 切换 `ChatGPTBlackButton` 的 `.stop / .send / .wave`。

### RealtimeAV / 实时语音相关

- `~/Desktop/GPTsora/GPTsora/RealtimeAVService.swift`
- `~/Desktop/GPTsora/GPTsora/RealtimeAVCallView.swift`
- `~/Desktop/GPTsora/GPTsora/RealtimeQuickService.swift`
- `~/Desktop/GPTsora/GPTsora/RealtimeBridge.swift`
- `~/Desktop/GPTsora/GPTsora/SemanticInterruptLabService.swift`
- `~/Desktop/GPTsora/RealtimeQuickService.swift`

具体证据：

- `RealtimeAVService.swift:28` 定义 `final class RealtimeAVService: NSObject`。
- `RealtimeAVService.swift:74` 定义 `RealtimeProvider`。
- `RealtimeAVService.swift:115-123` 持有 `RTCPeerConnectionFactory`、`RTCPeerConnection`、`URLSessionWebSocketTask`。
- `RealtimeAVService.swift:644-673` 定义 `prewarmChatAGINativeRealtime()`。
- `RealtimeAVService.swift:677-702` 定义 `activateChatAGINativeRealtime()`。
- `RealtimeAVService.swift:1360-1390` 对 `chatagi_native_realtime` 直接构造 MiniCPM/native `SessionInfo`，使用 `AppConfig.Realtime.nativeRealtimeWSURLString`。
- `RealtimeAVService.swift:4867-4881` 日志明确 ChatAGI Native 使用 `websocket(no-webrtc)`。
- `RealtimeAVService.swift:4921-4936` MiniCPM 分支等待 WebSocket open 后进入 `session.update + mic` 链路。
- `RealtimeAVService.swift:5150-5168` `startMiniCPMAfterOpen()` / `minicpmSendSessionUpdateAndStartMic()`：open 后发 session.update，flush queued events。
- `RealtimeAVService.swift:5192-5199` `qwenWSDidOpen()` 真实握手成功后打印 `[ChatAGINativeRealtime] connected` / `websocket open`。
- `RealtimeQuickService.swift:96` 定义 `final class RealtimeQuickService: NSObject`。
- `RealtimeQuickService.swift:570-708` 是 OpenAI/WebRTC profile 的 `startCallInternal` / `connectWithSessionInfo`。
- `RealtimeQuickService.swift:931-986` 是 WebRTC `offer -> setLocalDescription -> POST SDP -> setRemoteDescription(answer)`。

### 播报 / TTS 相关

- `~/Desktop/GPTsora/GPTsora/GlobalSpeechPlayer.swift`
- `~/Desktop/GPTsora/GPTsora/GlobalAudioPlayer.swift`
- `~/Desktop/GPTsora/GPTsora/MP3StreamPlayer.swift`
- `~/Desktop/GPTsora/GPTsora/TTSSlicer.swift`

具体证据：

- `GlobalSpeechPlayer.swift:117-118` 配置 `AVAudioSession` 为 `.playback` / `.spokenAudio`。
- `GlobalAudioPlayer.swift:7` 定义 `GlobalAudioPlayer`，内部使用 `AVAudioPlayer`。
- `Homechatview.swift:3047-3049` 开始本地录音前停止 `audioPlayer`、`speechPlayer`、`liveTTSPlayer`。
- `Homechatview.swift:3113-3116` 进入实时语音前停止本地播放，避免叠音。

### 上传相关

- `~/Desktop/GPTsora/GPTsora/MediaUploadService.swift`
- `~/Desktop/GPTsora/GPTsora/PlusAttachmentModule.swift`
- `~/Desktop/GPTsora/GPTsora/AudioNoteRecorder.swift`
- `Homechatview.swift` 内部也有一份 `AudioNoteRecorder` 定义。

具体证据：

- `MediaUploadService.swift:11-13` `uploadImage(apiBase:data)` 调 `/upload/image`。
- `MediaUploadService.swift:16-19` `uploadAudio(apiBase:fileURL)` 调 `/upload/audio`。
- `MediaUploadService.swift:22-45` 通过 multipart `URLSession.shared.upload` 上传。
- `Homechatview.swift:3784-3792` 发送前逐个上传 image/file。
- `Homechatview.swift:3805-3807` 发送前上传 audio。
- `Homechatview.swift:2989-2993` 输入框上方显示附件预览。
- `Homechatview.swift:3157-3165` 音频待发送附件可删除。

## 2. iOS HomeChat 底部输入栏状态机

### 空输入

证据：

- `Homechatview.swift:3030-3067` `!hasText` 时显示小麦克风按钮。
- `Homechatview.swift:3076-3078` `!hasText && !hasAttachments && !isSending` 时右侧按钮模式为 `.wave`。
- `Homechatview.swift:3097-3127` 空输入点击波纹进入实时语音入口。

行为：

- 左侧 `+` 可打开附件。
- 输入框 placeholder 为“询问任何问题”。
- 输入框内显示小麦克风。
- 右侧按钮是波纹。
- 点击波纹：Guest 弹付费墙；Pro 走 ChatAGI Native Realtime；Ultra/Coder 走 OpenAI/Realtime。

### 有文字 / 有附件

证据：

- `Homechatview.swift:3076-3078` `(hasText || hasAttachments) ? .send : .wave`。
- `Homechatview.swift:3093-3096` 有文字、附件或待发音频时调用 `onSendOrStop()`。

行为：

- 右侧按钮变发送。
- 不进入实时语音。

### 发送中

证据：

- `Homechatview.swift:3076-3077` `isSending ? .stop`。
- `Homechatview.swift:3081-3083` 发送中点击右侧按钮调用 `cancelAll()`。
- `Homechatview.swift:3769-3775` 发送前 `isSending = true`，创建 `sendTask`。
- `Homechatview.swift:5981` 有 `sendTask?.cancel(); sendTask = nil` 清理逻辑。

行为：

- 右侧按钮变停止。
- 支持取消当前任务。

### 语音转文字 / 录音输入中

证据：

- `Homechatview.swift:3001-3004` `audioNote.isRecording` 时输入框替换为录音波形。
- `Homechatview.swift:3016-3026` 录音中显示取消按钮。
- `Homechatview.swift:3051-3054` 点击小麦克风后 `audioNote.start()`。
- `Homechatview.swift:3086-3089` 录音中点击右侧按钮执行 `stopRecordingAndSend()`。
- `AudioNoteRecorder.swift:13-40` 独立 recorder 有 `start()` / `stop()`。

行为：

- 小麦克风不是实时通话，而是本地录音/语音输入入口。
- 录音前会停止本地播放。
- 通话中禁止本地录音。

### 实时语音连接中 / 实时语音中

证据：

- `Homechatview.swift:3118-3127` 点击空输入波纹后，Pro 调 `startChatAGINativeRealtimeFromVoiceButton()`，其他套餐调 `configureRealtimeForCurrentPlan()` + `fast.ensureConnected(apiBase:)`，随后 `composerMode = .voice`。
- `Homechatview.swift:3257-3335` 有独立 voice bottom bar。
- `Homechatview.swift:3301-3315` Pro 下显示“我说完了，立即发送”按钮，调用 `RealtimeAVService.shared.finishChatAGINativeUserTurnNow()`。
- `RealtimeAVService.swift:644-673` 支持 prewarm。
- `RealtimeAVService.swift:677-702` 支持 activate。

行为：

- 进入语音模式前停止本地播放。
- Pro/6.1 使用 ChatAGI Native Realtime。
- Voice bottom bar 与普通 chat 输入栏是两个 UI mode。

### 上传中 / 上传完成

证据：

- `Homechatview.swift:2989-2993` pending/loading/audio note 时显示附件预览。
- `Homechatview.swift:3784-3807` 发送任务中上传 image/file/audio。
- `MediaUploadService.swift:11-19` 上传接口为 `/upload/image` 和 `/upload/audio`。

行为：

- iOS 是“发送时上传”，不是 Web 当前的“选择后立即上传”。
- 上传完成后把远端 attachment 塞入 chat prepare payload。

## 3. iOS 实时语音真实链路

### 入口

主要入口在 `Homechatview.swift:3076-3127`：

- `ChatGPTBlackButton(mode: isSending ? .stop : ((hasText || hasAttachments) ? .send : .wave))`
- 空输入点击波纹：
  - Pro：`startChatAGINativeRealtimeFromVoiceButton()`
  - Ultra/Coder：`configureRealtimeForCurrentPlan()` + `fast.ensureConnected(apiBase:)`
  - 最后 `composerMode = .voice`

### ChatAGI 6.1 Native Realtime 链路

主要文件：`RealtimeAVService.swift`

关键链路：

1. `prewarmChatAGINativeRealtime()`：`RealtimeAVService.swift:644-673`
   - 设置 provider 为 `chatagi_native_realtime`
   - 设置 plan 为 `pro`
   - 设置中文 system instructions
   - 打印 `prewarm_start` / `ws_url`
   - 调 `startInternal(mode: .audioOnly)`

2. `activateChatAGINativeRealtime()`：`RealtimeAVService.swift:677-702`
   - 如果已连接，直接启动麦克风并进入“正在听”
   - 否则打印 `connecting...` 并 `startInternal`

3. Native session 信息：`RealtimeAVService.swift:1360-1390`
   - `requestedProvider == AppConfig.Realtime.chatAGINativeProvider`
   - 使用 `AppConfig.Realtime.nativeRealtimeWSURLString`
   - 返回 `SessionInfo(provider: .minicpm, rtcURL: wsURL, wsURL: wsURL, ...)`
   - 这里不是 OpenAI WebRTC，不需要 ephemeral key。

4. WebSocket 连接：`RealtimeAVService.swift:4867-4936`
   - 日志写明 `transport=websocket(no-webrtc)`
   - 创建 `URLSessionWebSocketTask`
   - MiniCPM 分支设置 running/connected，并等待真实 `didOpen` 或 fallback timer。

5. open 后协议：`RealtimeAVService.swift:5150-5168`
   - `startMiniCPMAfterOpen()`
   - 100ms 后 `minicpmSendSessionUpdateAndStartMic()`
   - `sendSessionUpdateIfNeeded()`，flush queued events。

6. 服务端 queue/session 事件：`RealtimeAVService.swift:2821-2827`
   - 收到 `session.queue_done`
   - 打印 `session.queue_done -> session.update`
   - 调 `minicpmSendSessionUpdateAndStartMic`

7. session ready：`RealtimeAVService.swift:2790-2807`
   - 收到 `session.created`
   - 设置 `minicpmSessionReady = true`
   - 非 prewarm 状态启动 `startQwenAudioCapture`
   - 状态变“正在听”。

8. 音频上行：`RealtimeAVService.swift:4534-4572`
   - `minicpmSubmitBufferedAudio()`
   - 加 tail silence
   - `minicpmFlushPendingFloat32()`
   - 发送 `{"type":"input_audio_buffer.append","audio":base64,"force_listen":...}`

9. 麦克风 chunk 处理：`RealtimeAVService.swift:4575-4618`
   - 16k mono float32 little-endian 聚合发送。
   - 助手说话时检测 RMS，触发 `barge_in` / `playback_stop` / `force_listen`。

10. 音频/文本下行：`RealtimeAVService.swift:3904-3957`
    - 解析 `result.text`
    - 解析 `result.audio_data`
    - 记录 `first_text_ms` / `first_audio_ms`
    - `end_of_turn` 后等待播放队列 drain。

11. 播放：`RealtimeAVService.swift:3964-4006`
    - WAV 走队列。
    - 非 WAV 默认 `float32_pcm_24k_mono`
    - 转 PCM16 后送入 `VoiceProcessingIOAudioDriver.appendPlaybackPCM16`
    - 打印 `playback_start` / `playback_next` / `audio_queue_length`。

### OpenAI/WebRTC 实时语音链路

主要文件：`RealtimeQuickService.swift` / `RealtimeAVService.swift`

关键证据：

- `RealtimeQuickService.swift:570-708` `startCallInternal` 和 `connectWithSessionInfo`。
- `RealtimeQuickService.swift:931-986` WebRTC `offer -> setLocalDescription -> POST SDP -> setRemoteDescription(answer)`。
- `RealtimeAVService.swift:1747-1797` 也有 WebRTC SDP offer/answer 逻辑。

这条链路适合 OpenAI/GPT Realtime，不等同于 ChatAGI 6.1 Native WebSocket 链路。

## 4. Web 当前实现对比

检查文件：

- `~/Desktop/backend/chatagi_adu_web_frontend/src/components/HomeChatComposer.tsx`
- `~/Desktop/backend/chatagi_adu_web_frontend/src/hooks/useRealtimeVoice.ts`
- `~/Desktop/backend/chatagi_adu_web_frontend/src/api/realtimeApi.ts`
- `~/Desktop/backend/chatagi_adu_web_frontend/src/hooks/useSpeechInput.ts`
- `~/Desktop/backend/chatagi_adu_web_frontend/src/hooks/useAutoSpeak.ts`
- `~/Desktop/backend/chatagi_adu_web_frontend/src/types/homeChat.ts`

### 已经和 App 行为一致的部分

- `HomeChatComposer.tsx:42-50` 有明确 composer state 推导。
- `homeChat.ts:1-13` 定义了 `idle_empty / typing / sending / speech_listening / speech_processing / realtime_checking / realtime_connecting / realtime_connected / assistant_speaking / realtime_stopping / uploading / error`。
- `HomeChatComposer.tsx:202-215` 根据状态切换右侧按钮为 send/wave/stop/loading。
- `HomeChatComposer.tsx:127-139` 右侧按钮按状态分发：发送中 abort、听写中 stop、实时语音中 stop、typing send、idle start realtime。
- `HomeChatComposer.tsx:148-160` 小麦克只做 speech input，识别结果回填输入框。
- `HomeChatComposer.tsx:163-194` 有图片、拍照、文件上传。
- `HomeChatComposer.tsx:278-283` 实时语音状态下输入区显示“正在聆听/阿杜正在回答/语音模式连接中”。
- `useSpeechInput.ts:15-59` 使用浏览器 SpeechRecognition，结果只回填，不自动发送。
- `useSpeechInput.ts:61-75` 支持停止/取消。
- `useAutoSpeak.ts:30-47` 清理播报文本，避免 raw JSON/debug/trace/internal。
- `useAutoSpeak.ts:124-137` 支持停止播报队列。

### 只是按行为重建、不是完整搬 App 代码的部分

- Web 是 React/DOM，无法逐行搬 SwiftUI。当前实现是根据 iOS 行为重建状态机。
- iOS `Homechatview.swift` 使用 `AudioNoteRecorder` 本地录音并作为 audio attachment 发送；Web 当前小麦克使用浏览器 `SpeechRecognition`，没有实现“录音附件待发送”的完全等价流程。
- iOS 上传是在发送任务中批量上传；Web 当前是选择文件后立即上传，并显示已上传附件。
- iOS `composerMode = .voice` 后切到独立 voice bottom bar；Web 当前在同一个 composer 内显示实时语音状态，没有复制 iOS 的 voice bottom bar。
- iOS 有 `finishChatAGINativeUserTurnNow()` 手动“我说完了，立即发送”；Web 当前 OpenAI WebRTC 实时语音没有对应按钮。

### 接口/协议不一致的部分

最重要差异：

- iOS 6.1 ChatAGI Native Realtime：
  - `RealtimeAVService.swift:1360-1390` 直接走 `ws://.../v1/realtime?mode=audio`
  - provider 是 `.minicpm`
  - transport 是 `websocket(no-webrtc)`
  - 服务端事件是 `session.queue_done / session.created / result.text / result.audio_data / end_of_turn`
  - 上行是 `input_audio_buffer.append`，音频是 16k mono float32 base64

- Web 当前 `useRealtimeVoice.ts:241-293`：
  - 使用 `RTCPeerConnection`
  - `getUserMedia`
  - `createDataChannel("oai-events")`
  - `createOffer`
  - `sendRealtimeOffer`
  - `setRemoteDescription(answer)`

- Web 当前 `realtimeApi.ts:63-87`：
  - `sendRealtimeOffer()` 实际 POST 到 `/session?...`，`Content-Type: application/sdp`
  - 不是 `/api/realtime/offer`
  - 不是 ChatAGI 6.1 Native WebSocket。

结论：Web 当前实时语音更接近 iOS 的 OpenAI/WebRTC 实时语音链路，未完整搬入 iOS 6.1 ChatAGI Native Realtime 的 WebSocket 原生链路。

### 可能对不上的接口

- 用户要求曾提到 `/api/realtime/offer`，但 Web 当前 `realtimeApi.ts:70` 调的是 `/session?...`。
- iOS 6.1 不走 offer/answer；Web 当前空输入波纹走 offer/answer。
- Web 的 `checkRealtimeHealth()` 当前 `realtimeApi.ts:40-48` 调 `/health`，不是 `/api/realtime/health`。如果后端 `/health` 返回 realtime 字段则可用，但与任务描述的目标接口名不一致。

## 5. 最终结论

### 之前是否真的完整搬了 App 代码逻辑？

没有完整搬。

更准确的结论是：

- 之前确实通过 `find/grep` 触达了 iOS 工程，找到了 HomeChat / RealtimeAV 相关文件。
- 但 Web 改造主要是“参考 iOS 行为后用 React 重新实现”，不是从 iOS HomeChat / RealtimeAV 逐项完整迁移。
- 尤其是 6.1 ChatAGI Native Realtime 的核心协议并没有搬到 Web：iOS 是 WebSocket MiniCPM native，Web 当前是 OpenAI/WebRTC SDP offer/answer。

### 当前 Web 已补上的能力

- 底部输入栏有状态机。
- 空输入启动实时语音，有文字发送文本。
- 发送中可中止。
- 小麦克语音输入可停止。
- 实时语音连接/通话可停止。
- 上传图片/拍照/文件有入口。
- 自动播报有清洗和队列。

### 当前 Web 缺的 iOS 能力

1. 6.1 ChatAGI Native Realtime WebSocket 原生链路：
   - `ws://.../v1/realtime?mode=audio`
   - `session.queue_done`
   - `session.update`
   - `input_audio_buffer.append`
   - `result.text`
   - `result.audio_data`
   - `end_of_turn`

2. Native 音频格式处理：
   - 上行 16k mono float32 base64
   - 下行 24k mono float32 PCM base64 / WAV 检测
   - audio queue / jitter buffer / continuous playback

3. 6.1 的手动“我说完了，立即发送”能力。

4. iOS 式录音附件：
   - 本地录音
   - 波形预览
   - 作为 audio attachment 上传
   - 发送失败后可恢复

5. iOS 上传时机：
   - iOS 在发送任务里上传附件。
   - Web 现在选择即上传。

6. 与 iOS 完全一致的套餐/provider 路由：
   - Pro/6.1 -> `chatagi_native_realtime`
   - Ultra/Coder -> OpenAI/WebRTC
   - Guest -> gated/paywall equivalent

## 6. 下一步建议

只做下一阶段改造时，建议优先改这些 Web 文件：

1. `src/hooks/useRealtimeVoice.ts`
   - 拆成两条 provider：
     - `openai_webrtc`
     - `chatagi_native_realtime`
   - 空输入蓝色波纹如果是 ChatAGI 阿杜主站默认，应优先走 `chatagi_native_realtime`。

2. `src/api/realtimeApi.ts`
   - 保留 OpenAI/WebRTC `/session` 或 `/api/realtime/offer`。
   - 新增 ChatAGI Native WebSocket URL 获取/配置。

3. 新增 `src/hooks/useChatAGINativeRealtime.ts`
   - 直接实现 iOS `RealtimeAVService.swift` 的 MiniCPM native 核心行为：
     - WebSocket connect
     - wait `session.queue_done`
     - send `session.update`
     - getUserMedia + AudioWorklet/ScriptProcessor 转 16k mono float32
     - send `input_audio_buffer.append`
     - parse `result.text` / `result.audio_data`
     - audio queue 播放
     - stop/cleanup/barge-in

4. `src/components/HomeChatComposer.tsx`
   - 根据 provider 状态加入“我说完了”小按钮，等价 `finishChatAGINativeUserTurnNow()`。
   - 保留当前输入状态机。

5. `src/hooks/useSpeechInput.ts`
   - 如果要完全对齐 iOS，应新增录音上传模式；当前浏览器 SpeechRecognition 只能算轻量替代。

本阶段不应继续改 `server_session.py`，除非后端需要暴露 native websocket 配置或代理。
