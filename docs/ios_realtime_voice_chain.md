# iOS 实时语音链路审计报告

生成时间：2026-06-23

## 1. 读取到的 iOS 文件路径

- `~/Desktop/GPTsora/GPTsora/Homechatview.swift`
- `~/Desktop/GPTsora/GPTsora/RealtimeAVService.swift`
- `~/Desktop/GPTsora/GPTsora/RealtimeAVCallView.swift`
- `~/Desktop/GPTsora/GPTsora/AppConfig.swift`
- `~/Desktop/GPTsora/GPTsora/RealtimeQuickService.swift`，已确认是旧 `/session + WebRTC` 旁路线，不是 HomeChat Pro/6.1 波纹键主链路。

## 2. 文件、类/函数、行号证据

- `Homechatview.swift`
  - `HomeChatView.body` 附近 `fullScreenCover`：第 634-644 行，退出视频页后回到 voice 模式会恢复音频连接，视频页用 `RealtimeAVCallView(apiBase: rt:)`。
  - `planModelMenuRow(_:)`：第 1314-1323 行，切换套餐时设置 `RealtimeAVService.shared.preferredProvider` 和 `realtimePlan`；Pro 会触发 `prewarmChatAGINativeRealtimeIfNeeded()`。
  - 波纹按钮点击逻辑：第 3093-3127 行；有文字/附件/语音附件时调用 `onSendOrStop()` 发送文本/内容；输入为空时，如果不是 Guest，停止本地播放后进入实时语音。Pro 调 `startChatAGINativeRealtimeFromVoiceButton()`，其他套餐走 `configureRealtimeForCurrentPlan()` + `fast.ensureConnected(...)`。
  - Voice 模式内操作：第 3301-3315 行，Pro 下有“我说完了”按钮，调用 `RealtimeAVService.shared.finishChatAGINativeUserTurnNow()`。
  - 视频按钮：第 3317-3339 行，先 `configureRealtimeForCurrentPlan()`，再打开 `RealtimeAVCallView`，不在按钮处重复 `startAV`。

- `RealtimeAVCallView.swift`
  - `RealtimeAVCallView`：第 9 行定义。
  - `.task`：第 101-139 行，配置 `RealtimeBridge`，按 plan/provider 兜底，调用 `rt.startAV()`，再启动相机并将 JPEG 交给 `rt.sendCameraFrameJPEG(data)`。
  - 顶部连接状态：第 179-185 行，`rt.isConnected ? "已连接" : "连接中…"`。
  - 底部控制：第 266-289 行为打断按钮，调用 `rt.interruptResponse()`；第 308-320 行为“结束”按钮，调用 `rt.stop()` 并关闭页面。

- `RealtimeAVService.swift`
  - `RealtimeAVService`：第 28 行定义；`RealtimeProvider`：第 74-80 行，支持 `openai/qwen/pipeline/minicpm`，其中第 78-79 行注释说明 MiniCPM 是 ChatAGI Pro/机器人 6.1 的全双工 WebSocket。
  - Provider 判断：第 82-84 行，`qwen/pipeline/minicpm` 都是 WebSocket provider。
  - `preferredProvider/realtimePlan`：第 177-182 行，注释写明 `chatagi_native_realtime` 是 ChatAGI 6.1 Native Voice，`pro` 走 ChatAGI Native Realtime 直连 WebSocket。
  - `start(mode:)`：第 496-500 行进入连接；`stop()`：第 503-510 行调用 `hardReset(notify: true)`。
  - `startAudio()/startAV()`：第 623-625 行，旧 API 兼容入口。
  - `prewarmChatAGINativeRealtime()`：第 644-674 行，设置 provider 为 `chatagi_native_realtime`、plan 为 `pro`，打印 ws_url 并走 `startInternal(.audioOnly)`。
  - `activateChatAGINativeRealtime()`：第 677-702 行，若已预热运行则启动麦克风并打印 `mic_start`，否则开始连接。
  - `finishChatAGINativeUserTurnNow()`：第 705-710 行，调用 `minicpmSubmitBufferedAudio(reason: "manual_finish")`。
  - `startInternal(mode:)`：第 762-920 行，防重复连接；第 893-895 行设置“连接中…”；第 897-918 行并行获取 session 和音频权限。
  - `fetchSessionFromBackend(...)` 的 ChatAGI Native 直连分支：第 1357-1391 行；当 `requestedProvider == chatagi_native_realtime` 时直接读取 `AppConfig.Realtime.nativeRealtimeWSURLString`，构造 `SessionInfo(provider: .minicpm, wsURL: wsURL)`，不请求 `/session`。
  - 后端 `/session` 兼容 MiniCPM 分支：第 1501-1530 行，若 JSON provider 是 `chatagi_native_realtime/minicpm*`，读取 `ws_url` 并构造 `.minicpm`。
  - MiniCPM `session.update`：第 2001-2022 行，只发送 `instructions/provider/model_display/title/protocol`。
  - `handleServerEvent(_:)`：第 2764-2838 行，处理 `session.created/session.updated/session.queued/session.queue_done/session.closed`；第 2821-2827 行收到 `session.queue_done` 后调用 `minicpmSendSessionUpdateAndStartMic(...)`。
  - MiniCPM 下行：第 3889-3951 行处理 `response.output_audio.delta/result` 的 `text/audio/audio_data/end_of_turn`；第 3950-3951 行处理 `end_of_turn`。
  - MiniCPM 上行：第 4534-4572 行 `minicpmSubmitBufferedAudio`/`minicpmFlushPendingFloat32` 发送 `input_audio_buffer.append`，字段是 base64 `audio` 和 `force_listen`，日志为 `audio_chunk sent`。
  - 麦克风 chunk：第 4575-4670 行，PCM16 转 float32 16k mono，聚合后持续 append；没有 commit/final。
  - WebSocket 连接：第 4854-4985 行 `connectQwenWebSocket(...)`，MiniCPM 打印 `transport=websocket(no-webrtc)`，第 4924-4936 行设置 connected 并等待 open/兜底。
  - MiniCPM open 后：第 5151-5189 行，open 后等/触发 `session.update`，启动麦克风并打印 `mic_start`，2.5s 未见 `session.created` 时兜底解锁 append。
  - 真正 WebSocket open：第 5192-5199 行，打印 `connected` 和 `websocket open`。
  - `hardReset(notify:)`：第 1112-1275 行，清理 dataChannel、peerConnection、WebSocket、音频 IO、timers、队列、AudioSession，并回调断开。

- `AppConfig.swift`
  - API base：第 15 行固定 `http://YOUR_LAN_IP:8000`。
  - ChatAGI Native 常量：第 120-130 行，`chatAGINativeProvider = "chatagi_native_realtime"`，`chatAGINativeProtocol = "minicpm_native"`，默认 ws 为 `ws://YOUR_LAN_IP:8006/v1/realtime?mode=audio`。
  - `nativeRealtimeWSURLString`：第 132-148 行，读取 UserDefaults override，否则使用默认 native ws。

- `RealtimeQuickService.swift`
  - `RealtimeQuickService`：第 96 行定义；`Backend.sessionPath = "/session"` 在第 38 行。
  - `fetchSessionFromBackend`：第 778-867 行请求 `/session` 并取 `rtc_url/ephemeral_key`。
  - `setupPeerConnection/negotiate`：第 874-980 行是 OpenAI WebRTC offer/answer 旧链路。
  - 结论：这是旧 RealtimeQuickService 路线，HomeChat 当前 Pro/6.1 波纹键主入口使用 `RealtimeAVService` 的 ChatAGI Native/MiniCPM WebSocket。

## 3. 手机 App 蓝色/波纹键真实逻辑

- 输入框为空：`Homechatview.swift:3097-3127` 进入实时语音。Guest 弹付费墙；Pro 调 `startChatAGINativeRealtimeFromVoiceButton()`；Ultra/Coder 配置后走 `fast.ensureConnected(...)`。进入前停止 `audioPlayer/speechPlayer/liveTTSPlayer`，避免叠音。
- 有文字/附件/语音附件：`Homechatview.swift:3093-3096` 调 `onSendOrStop()`，只走文本/附件发送，不进入实时语音。
- 连接中状态：`RealtimeAVService.startInternal` 第 893-895 行回调“连接中…”，MiniCPM WebSocket 第 4892-4896 行显示“连接中… ChatAGI 阿杜实时语音模型”。
- connected 后停止键：音视频页 `RealtimeAVCallView.swift:308-320` 有“结束”按钮调用 `rt.stop()`；Voice 模式内右侧按钮逻辑在 HomeChat 中切换为停止/完成类控件，Pro 还有第 3301-3315 行“我说完了”。
- stop/cancel 清理：`RealtimeAVService.stop()` 第 503-510 行进入 `hardReset`；`hardReset` 第 1112-1275 行清理 WebSocket、dataChannel、RTCPeerConnection、音频 IO、图片/回滚 timers、AudioSession 和状态。
- 失败恢复：`failAndReset` 第 1277 行开始，失败时 `hardReset(notify:false)` 并只显示白名单错误；MiniCPM WebSocket 失败第 5097-5114 行先重连一次，再显示 `WebSocket 失败` 并 reset。

## 4. 手机 App 实时语音真实链路

当前 HomeChat Pro/机器人 6.1 波纹键真实链路是：

- `WebSocket / MiniCPM 原生链路`。
- 不是 OpenAI Realtime WebRTC。
- 不是后端 SDP proxy。
- iOS 当前 `chatagi_native_realtime` 分支甚至不请求后端 `/session`，而是直接从 `AppConfig.Realtime.nativeRealtimeWSURLString` 取 `ws://YOUR_LAN_IP:8006/v1/realtime?mode=audio` 并连接。

协议细节：

- WebSocket 地址：`AppConfig.swift:128-140` 默认 `ws://YOUR_LAN_IP:8006/v1/realtime?mode=audio`。
- `session.queue_done`：等待/处理，见 `RealtimeAVService.swift:2821-2827`。
- `session.update`：发送，见 `RealtimeAVService.swift:2001-2022`，只发 instructions 和 ChatAGI Native 标识字段。
- `mic_start`：连接 ready 后打印并启动麦克风，见 `RealtimeAVService.swift:5172-5178` 和 `2797-2804`。
- `audio_chunk`：上行是 `input_audio_buffer.append`，`audio` 为 float32 16k mono base64，`force_listen` 可选，见 `RealtimeAVService.swift:4556-4572`。
- 下行等待 `response.output_audio.delta`/兼容 result，读取 `text/audio/audio_data/end_of_turn`，见 `RealtimeAVService.swift:3889-3951`。
- `end_of_turn`：用于标记播放收尾，见第 3950-3951 行。
- 无 OpenAI `RTCPeerConnection` / SDP offer/answer；无 OpenAI `response.create`；MiniCPM 分支无 commit/final。

## 5. Web 当前实现对比

检查文件：

- `~/Desktop/backend/chatagi_adu_web_frontend/src/hooks/useRealtimeVoice.ts`
  - 第 53 行注释明确是 `OpenAI Realtime WebRTC voice chain through the backend SDP proxy`。
  - 第 222-224 行先查 health。
  - 第 241-293 行创建 `RTCPeerConnection`、`oai-events` DataChannel，生成 SDP offer，并调用 `sendRealtimeOffer(...)`。
  - 这与 iOS Pro/6.1 的 MiniCPM WebSocket 链路不一致。

- `~/Desktop/backend/chatagi_adu_web_frontend/src/api/realtimeApi.ts`
  - `checkRealtimeHealth()` 走 `/health`，不是要求测试的 `/api/realtime/health`。
  - `createRealtimeSession()` 请求 `/api/realtime/session` 且 `probe:true`，后端只返回 OpenAI probe。
  - `sendRealtimeOffer()` 把 SDP 直接 POST 到 `/session`，这是 OpenAI WebRTC SDP proxy。

- `~/Desktop/backend/chatagi_adu_web_frontend/src/components/HomeChatComposer.tsx`
  - 第 93-108 行空输入时开始 realtime，文本时提交；行为框架正确。
  - 第 317-348 行右侧按钮会在 realtime 状态显示停止图标。
  - 问题不在按钮，而在 hook 内真实连接链路走错。

- `~/Desktop/backend/chatagi_adu_web_frontend/src/components/VoiceModePanel.tsx`
  - 根据 realtime status 显示连接中/回答/停止，停止按钮调用 `realtimeVoice.stop()`。

- `~/Desktop/backend/chatagi_adu_web_frontend/src/components/SciFiVoiceOrb.tsx`
  - `connected -> listening`，`assistant_speaking -> speaking`，状态同步逻辑存在。

当前 Web 连接失败原因：

- Web 走 OpenAI WebRTC SDP proxy，而手机 App Pro/6.1 走 ChatAGI Native MiniCPM WebSocket。
- Web `checkRealtimeHealth()` 查 `/health`，但测试和后端 realtime 专用 health 是 `/api/realtime/health`。
- Web 没有发送 iOS MiniCPM 所需的 `session.update`、`input_audio_buffer.append`、`force_listen`，也没有等待 `session.queue_done/session.created`。
- Web 没有处理 MiniCPM 下行 `response.output_audio.delta` 的 `audio_data` float32 24k，也不会按 `end_of_turn` 恢复 listening。
- 后端 `/session` 有 MiniCPM 响应结构，但当前 provider 路由会把 Pro/minicpm 纠回 qwen；Web 需要显式请求 `chatagi_native_realtime` 并由后端返回 native ws_url。
