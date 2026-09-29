# iOS 阿里/Qwen Realtime 桥接审计

日期：2026-06-19

范围：只读检查 `GPTsora` iOS App 中阿里 / DashScope / Qwen 实时语音链路，以及可复用到 ChatAGI 6.1 Native Realtime 的部分。本次未修改 Swift 业务代码。

## 1. 是否已有阿里实时语音桥接

结论：有 Qwen/阿里 Realtime 风格的 WebSocket 桥接，但没有发现独立的 DashScope SDK 模块或单独 `DashScope` 命名服务。

已发现的主文件：

- `GPTsora/RealtimeAVService.swift`
  - 核心实时音视频服务。
  - 内部 provider 包括 `.openai`、`.qwen`、`.pipeline`、`.minicpm`。
  - `.qwen` 分支用于阿里 Qwen Omni Realtime。
  - `qwen_selfhost` 分支复用 `.qwen` WebSocket 链路。
  - `.minicpm` 分支是 6.1 ChatAGI Native Realtime。

- `GPTsora/Homechatview.swift`
  - 黑色实时语音按钮入口。
  - Pro / 机器人 6.1 路由到 `chatagi_native_realtime`。
  - Guest 路由到 `qwen`。
  - Ultra / Coder 路由到 `openai`。

- `GPTsora/JobAssistantView.swift`
  - 也有类似套餐路由和语音按钮入口。

- `GPTsora/AppConfig.swift`
  - 定义 6.1 Native Realtime 配置：
    - provider：`chatagi_native_realtime`
    - title：`ChatAGI 阿杜实时语音模型`
    - protocol：`minicpm_native`
    - ws_url：`ws://YOUR_LAN_IP:8006/v1/realtime?mode=audio`

触发按钮：

- `Homechatview.swift` 黑色语音按钮：
  - Pro / 6.1：`startChatAGINativeRealtimeFromVoiceButton()`
  - Guest：`qwen`
  - Ultra / Coder：OpenAI Realtime

Service：

- 统一走 `RealtimeAVService.shared`。
- WebSocket 统一使用 `connectQwenWebSocket(...)`、`qwenReceiveLoop(...)`、`sendClientEvent(...)`。

WebSocket URL：

- Qwen / qwen_selfhost：通常通过 `/session` 返回 `ws_url`。
- 6.1 ChatAGI Native：直接读取 `AppConfig.Realtime.nativeRealtimeWSURLString`，当前默认 `ws://YOUR_LAN_IP:8006/v1/realtime?mode=audio`，不依赖 `/session`。

是否通过 `/session` 获取配置：

- Qwen / qwen_selfhost：是，通过 `fetchSessionFromBackend(...)` POST `/session`。
- 6.1 ChatAGI Native：优先直接构造 `SessionInfo(provider: .minicpm, wsURL: nativeRealtimeWSURLString)`，不走 `/session`。

## 2. 阿里实时语音发送链路

麦克风采集：

- 入口：`startQwenAudioCapture(callId:)`
- 音频驱动：`VoiceProcessingIOAudioDriver`
- AudioUnit：`kAudioUnitSubType_VoiceProcessingIO`
- AudioSession：`playAndRecord + voiceChat + defaultToSpeaker + allowBluetooth`

输入采样率：

- 硬件侧：48kHz mono PCM16
- 服务侧输入目标：16kHz mono PCM16
- `VoiceProcessingIOAudioDriver` 用 `AVAudioConverter` 从 48kHz 转 16kHz。

输入格式：

- Qwen 官方：`input_audio_buffer.append`，字段 `audio`，内容是 base64 PCM16。
- qwen_selfhost：同样发送 `input_audio_buffer.append`，base64 PCM16。
- 6.1 MiniCPM：先将 PCM16 转为 Float32 LE，再发送 base64，字段仍是 `audio`。

chunk 大小和节奏：

- Qwen 官方：每个 VPIO 回调直接 append，代码中没有本地聚合。
- qwen_selfhost：聚合为 200ms，一包约 `6400` bytes PCM16。
- 6.1 MiniCPM：聚合 Float32 PCM，当前 `minicpmAppendChunkBytes = 16000`，约 250ms @16k float32；代码注释与常量略有不一致，但实际常量更接近低延迟目标。

VAD：

- Qwen 官方：依赖服务端 `server_vad`，本地不做 RMS 伪打断。
- qwen_selfhost：本地动态噪声底 VAD：
  - ambient RMS 校准
  - `gateRMS`
  - `bargeGateRMS`
  - 静音提交
- 6.1 MiniCPM：本地轻量 RMS：
  - `minicpmMinVoiceRMS`
  - `minicpmSilenceSubmitMs = 700`
  - `minicpmTailSilenceMs = 600`
  - `minicpmMinRecordMs = 600`

silence submit：

- Qwen 官方：由服务端 VAD。
- qwen_selfhost：静音达到 `shSilenceToCommitMs` 后发送 `input_audio_buffer.commit final=true`。
- 6.1 MiniCPM：静音达到阈值后 `minicpmSubmitBufferedAudio(reason: "silence")`，追加尾部静音并 append。

预热连接：

- 6.1 已有 `prewarmChatAGINativeRealtime()`。
- `Homechatview.swift` 在 Pro 套餐可调用 `prewarmChatAGINativeRealtimeIfNeeded()`。
- 预热后等待 `session.queue_done` / `session.created`，进入 `warm_ready`。

## 3. 阿里实时语音接收链路

主要事件：

- `session.created`
- `session.updated`
- `input_audio_buffer.speech_started`
- `input_audio_buffer.speech_stopped`
- `conversation.item.input_audio_transcription.completed`
- `response.created`
- `response.audio.delta`
- `response.output_audio.delta`
- `response.audio.done`
- `response.output_audio.done`
- `response.done`
- `response.cancelled`
- `transcription.delta`
- `transcription.done`

audio delta 字段名：

- Qwen 官方 / qwen_selfhost：
  - `response.audio.delta`
  - `response.output_audio.delta`
  - 音频从 `delta`、`delta.audio` 或 `audio` 提取。
- 6.1 ChatAGI Native：
  - `result.audio_data`
  - `response.output_audio.delta` / `response.audio.delta`
  - 兼容 `audio` 和 `audio_data`。

text 字段名：

- Qwen 官方：
  - 用户转写：`conversation.item.input_audio_transcription.completed`
  - 助手文本：`response.output_text.delta`、`response.text.delta`、`response.audio_transcript.delta`
- qwen_selfhost：
  - `transcription.delta` 被代码当作助手文本流。
- 6.1 ChatAGI Native：
  - `result.text`
  - `response.output_audio.delta.text`

end_of_turn / done 判断：

- Qwen：
  - `response.audio.done`
  - `response.output_audio.done`
  - `response.done`
- 6.1：
  - `end_of_turn == true`
  - 代码设置 `minicpmAudioQueueEndOfTurn = true`，等待队列播放完后结束本轮。

服务端打断事件：

- Qwen 官方有 `input_audio_buffer.speech_started`，客户端据此 stop playback + `response.cancel`。
- 6.1 当前主要靠本地 RMS barge-in，发送 `force_listen=true`，同时本地停播。

## 4. 阿里播放链路

Qwen / qwen_selfhost：

- 播放核心：`VoiceProcessingIOAudioDriver`
- 播放接口：`appendPlaybackPCM16(_:)`
- 内部队列：`CircularPCMBuffer`
- 输出目标：24kHz mono PCM16，渲染时转到 48kHz。
- 不是 `AVAudioPlayer`。
- 不是逐段新建播放器。
- 优点：单一播放缓冲，连续性较好，适合 realtime audio.delta。

6.1 MiniCPM：

- 播放核心：`AVAudioEngine + AVAudioPlayerNode`
- 队列：`minicpmAudioQueue`
- 数据类型：
  - `.wav(Data)`
  - `.float32PCM(Data)`
- 播放函数：
  - `minicpmEnqueueAudioData(_:)`
  - `playNextMiniCPMAudioIfNeeded()`
  - `ensureMiniCPMAudioEngineRunning()`
  - `scheduleMiniCPMFloat32PCM(_:)`
  - `scheduleMiniCPMWAV(_:)`
- Stop：
  - `minicpmStopAudioPlayback(clearQueue:)`
  - `clearPlaybackBuffer(enterTailHold:)`

重要问题：

- 6.1 的 MiniCPM 播放路径已经有队列，但它是“每段播放完再 schedule 下一段”，不是提前连续 schedule 多段 buffer。
- `minicpmOutputSampleRate = 24000`，但 `scheduleMiniCPMFloat32PCM` 当前使用 `minicpmNativePlaybackSampleRate = 16000`。如果后端输出确认为 24k mono Float32 PCM，这里是高风险点，会造成播放速度/音调/连续性问题。
- Qwen 的 VPIO 播放链路更适合持续 PCM delta；6.1 可以考虑迁移到 VPIO 的 `appendPlaybackPCM16` 思路，或把 MiniCPM Float32 转 PCM16 后进入同一个 CircularPCMBuffer。

是否有 jitter buffer：

- Qwen：`CircularPCMBuffer` 本身是连续播放缓冲，但没有显式 warmup 字节阈值。
- 6.1：有 `minicpmPlaybackWarmupMs` 和 `minicpmPlaybackPendingPCM16` 变量，但当前主播放实际使用 `minicpmAudioQueue + AVAudioPlayerNode`，warmup PCM16 路径未形成主链路。

## 5. 阿里打断逻辑

Qwen 官方打断：

- 服务端发 `input_audio_buffer.speech_started`。
- 客户端执行：
  - `handleSpeechStarted()`
  - `qwenUserIsSpeaking = true`
  - `qwenStopLocalAssistantAudioForOfficialSpeechStart()`
  - `clearPlaybackBuffer(enterTailHold: false)`
  - 如有响应中，发送 `response.cancel`
- `handleAudioDelta` 在 `qwenUserIsSpeaking == true` 时丢弃后续 audio delta，避免旧残音冒头。

qwen_selfhost 打断：

- 本地 RMS 高阈值持续触发。
- 清播放队列。
- 设置 stale done gate。
- 不发送 OpenAI 的 `response.cancel`，避免协议污染。

6.1 ChatAGI Native 打断：

- 在 `minicpmHandleMicChunk(...)` 中，如果 `assistantSpeaking` 且 RMS 超过 `minicpmBargeRMS` 持续 `minicpmBargeHoldMsRequired`：
  - 打印 `barge_in`
  - 打印 `playback_stop`
  - 清 `minicpmPlaybackPendingPCM16`
  - `minicpmStopAudioPlayback(clearQueue: true)`
  - `clearPlaybackBuffer(enterTailHold: false)`
  - 后续 append 带 `force_listen=true`

差异：

- Qwen 官方打断由服务端 VAD 事件确认。
- 6.1 现在主要是本地 RMS 主动打断 + `force_listen` 通知服务端。
- 6.1 的做法对低延迟更直接，但需要更稳定的本地播放队列，否则“清了又被下一段 schedule”仍可能残音。

## 6. 与 6.1 Native Realtime 对照

当前 6.1 协议：

- URL：`ws://YOUR_LAN_IP:8006/v1/realtime?mode=audio`
- 握手：
  - `session.queue_done`
  - `session.update`
  - `session.created`
- 输入：
  - `input_audio_buffer.append`
  - 字段 `audio`
  - base64 16k mono Float32 PCM
  - 可带 `force_listen`
- 输出：
  - `result.text`
  - `result.audio_data`
  - `end_of_turn`
  - 兼容 `response.output_audio.delta` / `response.audio.delta`
- 目标输出：24k mono Float32 PCM base64

可以直接复用：

- `URLSessionWebSocketTask` 状态机：
  - `connectQwenWebSocket(...)`
  - `qwenReceiveLoop(...)`
  - `QwenWSDelegateProxy`
  - `startQwenKeepaliveTimer(...)`
- AudioSession / VoiceProcessingIO：
  - `configureAudioSession()`
  - `VoiceProcessingIOAudioDriver`
  - `startQwenAudioCapture(...)`
- WebSocket 发送：
  - `sendClientEvent(...)`
  - queued event 机制
- 打断 gate 思路：
  - `qwenUserIsSpeaking`
  - `clearPlaybackBuffer(...)`
  - `markQwenPlaybackStarted/StoppedSoon`
- qwen_selfhost 的 watchdog 设计思想。

必须替换或谨慎改造：

- Qwen `session.update` 字段不能直接用于 6.1。
  - Qwen 有 `modalities`、`voice`、`input_audio_format: pcm`、`gummy-realtime-v1`、`turn_detection`。
  - 6.1 只应发 ChatAGI Native 所需 `instructions/provider/model_display/title/protocol`。
- Qwen 的 `response.cancel` 不一定适用于 6.1。
  - 6.1 应优先 `force_listen=true` 或后端支持的 `barge_in/force_listen`。
- Qwen 输出 PCM16 24k 路径不能直接播放 6.1 Float32 PCM，必须转换或独立播放。
- 6.1 `result.audio_data` 字段名不是 Qwen 的标准 `response.audio.delta`。
- 6.1 的 `end_of_turn` 不是 Qwen 的 `response.audio.done`。

不能复用的协议字段：

- DashScope/Qwen `input_audio_transcription.model = gummy-realtime-v1`
- Qwen `input_audio_format = pcm` / `output_audio_format = pcm` 的语义
- OpenAI `response.create` / `conversation.item.create` 在 6.1 native 主线不应作为必须事件
- Qwen 官方 `server_vad` 配置不能原样投给 6.1，除非后端显式支持。

应该迁移到 6.1 的播放逻辑：

- 更推荐把 6.1 的 Float32 24k 输出转换成 PCM16 24k，然后走 `VoiceProcessingIOAudioDriver.appendPlaybackPCM16(...)` 的连续 CircularPCMBuffer。
- 如果继续用 `AVAudioPlayerNode`，应修正输出采样率并提前 schedule 多段 buffer，而不是严格等 completion 后再 schedule 下一段。
- Stop / barge-in 必须统一清：
  - `minicpmAudioQueue`
  - 已 schedule 的 player node
  - VPIO playback buffer
  - pending PCM buffer

## 7. 最小改造方案

推荐下一步实现只改 6.1 分支，不动普通聊天、电脑控制、6.0 / 6.2 / 6.2 Pro。

最小方案：

1. 保留现有 `chatagi_native_realtime` 路由。
2. 继续复用 `connectQwenWebSocket` / `qwenReceiveLoop` / `sendClientEvent`。
3. 继续复用 `VoiceProcessingIOAudioDriver` 的麦克风采集。
4. 6.1 上行保持 16k mono Float32 PCM base64。
5. 6.1 下行优先统一到一个连续播放缓冲：
   - `result.audio_data` base64 decode
   - 如果是 WAV，解析或临时保留现有 WAV path
   - 如果是 Float32 PCM，按真实采样率 24k 转 PCM16
   - 投喂 `vpAudio?.appendPlaybackPCM16(...)`
6. 若继续保留 `AVAudioPlayerNode`：
   - 修正 `scheduleMiniCPMFloat32PCM` 使用 24k，而不是 `minicpmNativePlaybackSampleRate = 16000`
   - 增加 warmup buffer
   - 连续 schedule 后续 buffer
7. 打断：
   - 播放中检测 RMS 超阈值，立即 `clearPlaybackBuffer(false)`。
   - 同时下一包 append 带 `force_listen=true`。
   - 保留日志 `barge_in` / `playback_stop`。
8. 预热：
   - 保留 `prewarmChatAGINativeRealtime()`。
   - HomeChatView 中 Pro/6.1 进入后预热，点击按钮只启动麦克风。
9. 错误恢复：
   - 保留现有 reconnect once。
   - 对 worker busy / queue_update 使用当前 UI status，不归类为普通连接失败。

## 8. 不允许改动项确认

本次审计没有修改：

- 普通聊天
- 电脑控制
- 6.0 / 6.2 / 6.2 Pro
- 后端
- 模型
- App 套餐 UI 文案

## 已发现的阿里实时语音桥接文件列表

- `GPTsora/RealtimeAVService.swift`
- `GPTsora/Homechatview.swift`
- `GPTsora/JobAssistantView.swift`
- `GPTsora/AppConfig.swift`
- `GPTsora/ScreenAgentAudio.swift`：不是主 Realtime 桥接，但有 24k PCM 队列播放参考。
- `GPTsora/RealtimeQuickService.swift`：OpenAI/WebRTC 实时语音，不是阿里直连，但有通用 session / DataChannel / 文本增量经验。

## 应该复用的函数列表

- `RealtimeAVService.fetchSessionFromBackend(...)`
- `RealtimeAVService.connectQwenWebSocket(...)`
- `RealtimeAVService.qwenReceiveLoop(...)`
- `RealtimeAVService.sendClientEvent(...)`
- `RealtimeAVService.startQwenKeepaliveTimer(...)`
- `RealtimeAVService.startQwenAudioCapture(...)`
- `RealtimeAVService.clearPlaybackBuffer(...)`
- `RealtimeAVService.handleAudioDelta(base64:)` 的 gate 思路
- `RealtimeAVService.handleSpeechStarted()` 的 stop/cancel/gate 思路
- `VoiceProcessingIOAudioDriver.appendPlaybackPCM16(...)`
- `VoiceProcessingIOAudioDriver.clearPlayback()`

## 应该迁移到 6.1 的播放队列代码

优先迁移方向：

- 使用 `VoiceProcessingIOAudioDriver` 的 `CircularPCMBuffer` 作为 6.1 下行主播放队列。
- 新增 Float32 24k -> PCM16 24k 转换。
- 让 `result.audio_data` 连续进入同一个 playback buffer。

可保留但需修正：

- `minicpmAudioQueue`
- `ensureMiniCPMAudioEngineRunning()`
- `scheduleMiniCPMFloat32PCM(_:)`
- `minicpmStopAudioPlayback(clearQueue:)`

其中 `scheduleMiniCPMFloat32PCM(_:)` 当前疑似使用 16k 播放 Float32 PCM；如果后端输出是 24k，应修正。

## 需要改的精确文件

下一步实现时建议只改：

- `GPTsora/RealtimeAVService.swift`
  - 6.1 下行播放队列 / jitter buffer / sample rate 修正
  - barge-in 清队列一致性
  - `result.audio_data` 到 VPIO 播放缓冲

- `GPTsora/Homechatview.swift`
  - 只在必要时补 UI 状态显示和预热入口，不改套餐文案。

- `GPTsora/AppConfig.swift`
  - 仅当需要新增 6.1 音频参数开关时修改。

## 下一步实现命令

建议下一步：

```bash
cd ~/Desktop/GPTsora
codex exec --skip-git-repo-check "
只改 6.1 ChatAGI Native Realtime 播放链路：
1. 保留现有 WebSocket / 麦克风 / 预热；
2. 将 result.audio_data Float32 24k 转 PCM16 24k 后送入 VoiceProcessingIOAudioDriver 连续播放缓冲；
3. 修正或绕开 MiniCPM AVAudioPlayerNode 16k 播放风险；
4. barge-in / Stop 必须同时清 VPIO buffer、minicpmAudioQueue、pending buffer；
5. 不改普通聊天、电脑控制、6.0 / 6.2 / 6.2 Pro。
"
```
