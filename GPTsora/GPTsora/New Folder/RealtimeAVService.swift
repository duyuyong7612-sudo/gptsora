
// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-21d3efa54645c003a12c519f764c43cc7aa98157867a7679edf64fe804e4a2c8"
// Source-SHA256: "c2dc36bbd5bccb3b3d7413256f40cd0aeaf140062231a78fcec3ac89fec70345"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation
import UIKit
import AVFoundation
import WebRTC
import ObjectiveC
import QuartzCore
import AudioToolbox
import CoreMedia

// 🆕 屏幕共享接入通知(由 mac_screen_attach/detach 工具触发,UI 层订阅)
extension Notification.Name {
    static let aduMacScreenAttachRequested = Notification.Name("aduMacScreenAttachRequested")
    static let aduMacScreenDetachRequested = Notification.Name("aduMacScreenDetachRequested")
    // ✅ 语义打断：模型输出控制符后，本地控制层立即冻结旧气泡并隐藏控制符。
    static let aduRealtimeSemanticInterrupt = Notification.Name("aduRealtimeSemanticInterrupt")
}

protocol RealtimeAVServiceDelegate: AnyObject {
    func realtimeAVServiceDidConnect(_ svc: RealtimeAVService)
    func realtimeAVServiceDidDisconnect(_ svc: RealtimeAVService)
    func realtimeAVService(_ svc: RealtimeAVService, didUpdateStatus text: String)
    func realtimeAVService(_ svc: RealtimeAVService, didReceiveUserTranscript text: String)
    func realtimeAVService(_ svc: RealtimeAVService, didReceiveAssistantText text: String, isFinal: Bool)
    func realtimeAVService(_ svc: RealtimeAVService, didFail error: Error)
}

final class RealtimeAVService: NSObject {

    static let shared = RealtimeAVService()
    weak var delegate: RealtimeAVServiceDelegate?

    enum CallMode { case audioOnly, audioVideo }

    var sessionEndpointOverride: String? = nil
    var instructionsOverride: String? = nil
    var apiBase: String = AppConfig.API.apiBase

    private struct SessionCache {
        let info: SessionInfo
        let fetchedAt: Date
        let wantVideo: Bool
        let apiBase: String
    }

    private let sessionCacheTTL: TimeInterval = 50
    private let sessionCacheQueue = DispatchQueue(label: "realtime.av.service.session_cache")
    private var sessionCache: SessionCache? = nil

    var sessionProfile: String = ""
    var sessionClientId: String = ""
    var sessionConversationId: String = ""
    var lastPerceptionSnapshot: [String: Any]? = nil

    var voiceName: String = AppConfig.Realtime.defaultVoice

    var assistantInstructions: String = """
    你是一个实时语音助手。
    回答尽量简洁、口语化。
    用户说中文就中文，用户说英文就英文。
    """

    var assistantPartialFlushInterval: TimeInterval = 0.06

    private let workQueue = DispatchQueue(label: "realtime.av.service.queue", qos: .userInitiated)

    private var currentCallId = UUID()

    private(set) var isConnecting: Bool = false
    private(set) var isRunning: Bool = false
    private(set) var isMuted: Bool = false
    private(set) var callMode: CallMode = .audioOnly

    enum RealtimeProvider: String {
        case openai
        case qwen
        case pipeline
        // ✅ 自部署 MiniCPM-o 4.5（ChatAGI Pro / 机器人 6.1）：全双工 WebSocket，float32 PCM。
        case minicpm
    }

    private var isWebSocketProvider: Bool {
        activeProvider == .qwen || activeProvider == .pipeline || activeProvider == .minicpm
    }

    private struct SessionInfo {
        let provider: RealtimeProvider
        let rtcURL: URL
        let ephemeralKey: String
        let iceServers: [RTCIceServer]
        let wsURL: URL?
        let apiKey: String?
        let pcm24ToPcm16Required: Bool
        let serverInstructions: String?
        let serverVoice: String?
        let serverConversationId: String?
        let serverTurnDetection: [String: Any]?
        // ✅ 自部署 Qwen3-Omni（provider == "qwen_selfhost"）：复用 .qwen 音频链路，
        //    但 session.update 需走自部署精简字段 + 错误时 minimal fallback。
        var isSelfhost: Bool = false
        // ✅ vLLM-Omni 官方协议：model 由前端在 session.update 顶层发送，从 /session 的 "model" 取。
        var selfhostModel: String? = nil
        // ✅ 后端 /session 下发的客户端 VAD / 插话参数（env 可调），连接时覆盖本地默认。
        var selfhostVAD: [String: Any]? = nil
        var selfhostBargeIn: [String: Any]? = nil
    }

    private var pendingSessionInfo: SessionInfo?
    private var pendingAudioReady: Bool = false

    private var rtcURL: URL?
    private var ephemeralKey: String?
    private var iceServers: [RTCIceServer] = []

    private var factory: RTCPeerConnectionFactory!
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?

    // ── 前端打断状态机（openai/三段云端通路）────────────────────────────
    // 参数 1:1 生产实测值：0.14 触发 / 0.08 迟滞释放 / 80ms 预热 / 100ms 持续判定。
    // 触发链：本地即刻静音远端音轨(<50ms) → played truncate → response.cancel。
    private let frontBarge = AduBargeMachine()
    private var frontBargeRemoteTrack: RTCAudioTrack?
    private var frontBargeEngine: AVAudioEngine?
    private var frontBargeSpeakStartAt: Date?
    private var localAudioTrack: RTCAudioTrack?
    private var localVideoTrack: RTCVideoTrack?
    private var localVideoCapturer: RTCCameraVideoCapturer?

    private var activeProvider: RealtimeProvider = .openai
    private var qwenWSTask: URLSessionWebSocketTask?
    private var qwenWSSession: URLSession?
    // ✅ WebSocket 握手/关闭回调代理（真实 open / 对端 close 诊断）。
    private var qwenWSDelegateProxy: QwenWSDelegateProxy?
    private var qwenApiKey: String?
    private var qwenPcm24ToPcm16: Bool = false
    private var serverInstructions: String? = nil
    private var serverTurnDetection: [String: Any]? = nil
    private var qwenIsReceivingMessages: Bool = false
    // ✅ Qwen WebSocket 长连接保活/诊断：避免 iOS/NAT/代理在几分钟后半断开，表现为“静默”。
    private var qwenKeepaliveTimer: DispatchSourceTimer?
    private var qwenLastServerEventAt: Date? = nil
    private var qwenLastClientSendAt: Date? = nil
    // ✅ 连接诊断快照：WebSocket 失败时一并打印 ws_url / provider / apiKeyEmpty。
    private var qwenConnectedWSURL: String = ""
    private var qwenConnectedApiKeyEmpty: Bool = true

    // VoiceProcessingIO driver
    private var vpAudio: VoiceProcessingIOAudioDriver?

    private var audioDebugCount: Int = 0
    private var playbackSampleRate: Double = 24000

    private var clientVADSpeaking: Bool = false
    private var clientVADSilenceFrames: Int = 0
    private let clientVADSilenceThreshold: Float = 0.01
    private let clientVADSilenceFramesToCommit: Int = 25
    private var clientVADCommitted: Bool = true
    private var pipelinePlaybackActive: Bool = false

    private var qwenPlaybackLikelyActive: Bool = false
    private var qwenPlaybackGateHoldUntil: Date? = nil
    // ✅ 播放结束后的尾音/回声保护窗口。原来 0.20s 太短，容易把助手自己的尾音送回云端触发“自己接自己”。
    private let qwenPlaybackTailHold: TimeInterval = 0.90
    private var qwenAudioStarted: Bool = false    // ✅ 音频启动后才允许发图片帧

    // ✅ 阿里官方 Java 范例的核心打断 gate：
    //   case "input_audio_buffer.speech_started": userIsSpeaking.set(true)
    //   case "response.audio.delta": if (!userIsSpeaking.get()) player.play(...)
    //   case "input_audio_buffer.speech_stopped": userIsSpeaking.set(false)
    // 用户开口期间（含 speech_started 到 speech_stopped 之间，以及发出
    // response.cancel 之后到服务端真正停止生成的 100~300ms 网络往返窗口）
    // 收到的所有 response.audio.delta 都必须丢弃，否则刚清掉的播放队列
    // 又会被新到的 delta 重新填入，造成"打断不彻底/残音冒头"。
    private var qwenUserIsSpeaking: Bool = false

    // ✅ Qwen 官方语义打断不在本地用 RMS 判定。
    // iOS 只根据阿里服务端事件 input_audio_buffer.speech_started 做本地播放层同步。

    private static let realtimeUserFacingError = "实时通话连接失败，请稍后再试"
    private static func userFacingError(code: Int = -1) -> NSError {
        NSError(domain: "RealtimeAVService", code: code, userInfo: [NSLocalizedDescriptionKey: Self.realtimeUserFacingError])
    }

    /// ✅ 套餐路由：nil=后端env决定, "chatagi_native_realtime"=ChatAGI 6.1 Native Voice,
    /// "qwen"=阿里, "openai"=GPT Realtime
    var preferredProvider: String? = nil
    /// ✅ 套餐：ultra=机器人 6.2, coder=机器人 6.2 Pro（走 /api/realtime/session + OpenAI），
    /// pro=机器人 6.1（走 ChatAGI Native Realtime 直连 WebSocket）。
    var realtimePlan: String? = nil

    private var hasSentSessionUpdate = false
    // ✅ 自部署 Qwen3-Omni（qwen_selfhost）：true 时复用 .qwen 链路，但 session.update
    //    不带 DashScope 专属字段（gummy transcription / 采样参数），错误时降级 minimal。
    private var isSelfhostQwen = false
    private var didSendSelfhostMinimalSessionUpdate = false
    // ✅ vLLM-Omni 官方协议：session.update 顶层 model（来自 /session 的 "model"）。
    private var qwenSelfhostModel: String = "/workspace/models/Qwen3-Omni-30B-A3B-Instruct"
    // ✅ selfhost 一轮语音输入的 client-VAD 状态：是否已发 commit{final:false}。
    private var selfhostTurnOpen = false
    private var selfhostAppendCount = 0   // append 日志节流

    // ✅ 自部署 MiniCPM-o 4.5（ChatAGI Pro / 机器人 6.1，替代 Qwen3-Omni）：
    //    全双工，float32 PCM。协议与 Qwen 不同：无 commit/final，麦克风持续
    //    append(float32 16k, force_listen)，服务端回 response.output_audio.delta
    //    (text + float32 24k + end_of_turn)。先不做自动打断。
    private var isMiniCPM = false
    private var minicpmInstructions: String? = nil
    private var minicpmAppendCount = 0          // append 日志节流
    private var minicpmPlaybackStarted = false  // 本轮是否已打印 playback start
    private var minicpmTurnActive = false       // 本轮助手回复是否进行中（用于分气泡）

    // ✅ MiniCPM-o 音频双工握手门控（对齐官方协议 / realtime-session.js）：
    //    连接 → 等 session.queue_done（必达）→ 发 session.update → 等 session.created → 才允许发 append。
    //    minicpmSessionReady=false 时麦克风帧不上行，避免 ACTIVE 之前发 append 触发 not_ready。
    private var minicpmSessionReady = false
    private var minicpmSessionUpdateSent = false

    // ✅ MiniCPM-o 4.5 官方 Audio Duplex 协议：
    //    上行不要按 VoiceProcessingIO 10~20ms 小帧逐条发送，否则服务端会一直 LISTEN/prefill
    //    而不进入 generate。官方 Demo 更接近 0.5~1s 音频块持续 append。
    //    这里聚合为 1 秒 float32 PCM 16k mono：16000 samples × 4 bytes = 64000 bytes。
    private var minicpmPendingFloat32 = Data()
    private var minicpmPendingMaxRMS: Float = 0
    private var minicpmPendingForceListen = false
    private var minicpmBargeHoldMs: Double = 0
    // ✅ 上行块大小：官方允许 250ms~1s（min 4000 samples）。用 0.5s（16000 samples×4=32000 bytes）
    //    在 real-time 节奏下显著降低"服务端看到用户说完"的延迟，比 1s 更跟手，又不会因发送过快被丢。
    private let minicpmAppendChunkBytes = 16000
    private let minicpmSampleRateIn: Double = 16000
    private let minicpmMinVoiceRMS: Float = 0.0005
    private let minicpmBargeRMS: Float = 0.006
    private let minicpmBargeHoldMsRequired: Double = 260
    private var minicpmPrewarmOnly = false
    private var minicpmWarmReady = false
    private var minicpmReconnectAttempted = false
    private var minicpmQueueWatchdogToken = 0
    private var minicpmUserSpeaking = false
    private var minicpmSpeechMs: Double = 0
    private var minicpmSilenceMs: Double = 0
    private var minicpmLastSubmitAt: Date? = nil
    private var minicpmDroppedAudioCount = 0
    private let minicpmSilenceSubmitMs: Double = 700
    private let minicpmTailSilenceMs: Double = 600
    private let minicpmMinRecordMs: Double = 600
    private let minicpmMaxRecordMs: Double = 6000

    // ✅ MiniCPM 播放端对齐 GPT Realtime 的流式播报方式：
    //    response.output_audio.delta 不能“一片一播”。先做 300ms jitter buffer，
    //    暖机后再持续喂给 VoiceProcessingIO 的唯一播放队列，避免一个字一顿。
    private var minicpmPlaybackPendingPCM16 = Data()
    private var minicpmEndOfTurnReceived = false
    private var minicpmPlaybackDrainChecks = 0
    private var minicpmContinuousPlaybackActive = false
    private var minicpmCallStartedAt: Date? = nil
    private var minicpmFirstAudioMs: Int? = nil
    private var minicpmFirstTextMs: Int? = nil
    private let minicpmOutputSampleRate: Double = 24000
    private let minicpmPlaybackWarmupMs: Double = 150
    private let minicpmPlaybackTailHoldMs: Double = 800
    private var minicpmPlaybackWarmupBytes: Int {
        Int(minicpmOutputSampleRate * minicpmPlaybackWarmupMs / 1000.0) * 2
    }

    private enum MiniCPMAudioQueueItem {
        case wav(Data)
        case float32PCM(Data)
    }

    private var minicpmAudioQueue: [MiniCPMAudioQueueItem] = []
    private var minicpmAudioEngine: AVAudioEngine?
    private var minicpmAudioPlayerNode: AVAudioPlayerNode?
    private var minicpmAudioIsPlaying = false
    private var minicpmAudioQueueEndOfTurn = false
    private let minicpmNativePlaybackSampleRate: Double = 16000

    // ✅ qwen_selfhost 客户端 VAD / 插话参数（规格 §7）。
    //    ⚠️ 修复：原来是写死的 let 常量，后端 /session 下发的 vad/barge_in 全被忽略，
    //    导致 Render env（QWEN_SELFHOST_COMMIT_RMS 等）调参完全不生效。
    //    现改为 var 默认值，连接时由 /session 返回的 vad{} / barge_in{} 覆盖。
    private var shMinVoiceRMS: Float = 0.015        // 有效人声门槛（后端 vad.rms_threshold）
    private var shMinAudioSeconds: Double = 0.8     // 少于 0.8s 不提交 final=true（vad.min_audio_seconds）
    private var shSilenceToCommitMs: Double = 800   // 静音 800ms 自动提交（vad.silence_duration_ms）
    private var shBargeInRMS: Float = 0.02          // 插话高阈值（barge_in.rms_threshold，后端默认 0.02）
    private var shBargeInHoldMs: Double = 250       // 插话需持续时长（barge_in.hold_ms，后端默认 250）
    private var shTailHoldMs: Double = 400          // 播放结束后忽略普通起声（barge_in.tail_hold_ms，后端默认 400）

    // ✅ 诊断：麦克风回调帧计数（验证 VoiceProcessingIO 真的在持续给 selfhost 上行链路送帧）。
    private var shMicFrameCount: Int = 0

    // ✅ 动态噪声底 VAD（修复：VPIO 的 AEC+AGC 把输入压到 0.0002 量级，固定 0.015 门槛永远打不开）。
    //    - 启动后采集前 500ms 安静帧 → ambientRMS
    //    - gateRMS = max(ambientRMS * 3.0, 0.00015)；插话 bargeGateRMS = max(ambientRMS * 8.0, 0.0006)
    //    - 校准完成前用临时宽松门槛 0.0002，保证用户一上来就说话也能开 turn
    //    - 校准后在 listening 静音期做慢速 EMA 漂移跟踪
    private var shAmbientRMS: Float = 0
    private var shAmbientAccumSum: Float = 0
    private var shAmbientAccumMs: Double = 0
    private var shAmbientLocked = false
    private var shGateRMS: Float = 0.0002        // 生效的开口门槛（动态）
    private var shBargeGateRMS: Float = 0.0008   // 生效的插话门槛（动态）
    private let shGateFloor: Float = 0.00015
    private let shBargeGateFloor: Float = 0.0006
    private let shAmbientCalibMs: Double = 500
    // ✅ 服务端音频形态自动检测：一旦收到过 JSON response.audio.delta，就永远忽略二进制帧，
    //    避免双音轨；若服务端只发二进制 PCM（部分 vLLM-Omni 版本），则播放二进制帧，保证有声。
    private var shSawJsonAudioDelta = false

    // ✅ qwen_selfhost 轮次/状态机（规格 §6/§9）
    private var selfhostTurnId: Int = 0
    private var shTurnStartAt: Date? = nil
    private var shLastVoiceAt: Date? = nil
    private var shTurnMaxRMS: Float = 0
    private var shTurnChunks: Int = 0
    private var shBargeAccumMs: Double = 0
    private var selfhostState: String = "idle"
    // ✅ 规格 §9.2：本地打断后没有服务端 cancel，旧 response 仍会流完。
    //    置位后丢弃全部旧轮 audio.delta，直到旧轮 audio.done（5s 兜底防 done 丢失误杀新回复）。
    private var shAwaitingStaleDone = false
    private var shInterruptAt: Date? = nil
    // ✅ 二：一轮只允许一次 final=true；assistantThinking/assistantSpeaking 期间拒绝重复 commit。
    private var shFinalCommitSentForTurn = false
    private var shPendingFinalCommit = false          // 旧响应未结束时暂存的 final=true
    private var shPendingFinalCommitSeconds: Double = 0

    // ✅ commit/append 节奏：按后端规格 chunk_ms=200 聚合上行（VPIO 回调是 10ms/320B，
    //    原来每帧一条 append = 100 条/秒；现在聚成 200ms/6400B 一条，节奏与规格一致）。
    private var shPendingPCM = Data()
    private let shAppendChunkBytes = 6400            // 200ms @ 16k mono pcm16

    // ✅ 每轮节奏看门狗（仿旧阿里链路"事件 + 兜底"双保险；selfhost 原来纯事件驱动，
    //    audio.done 丢一个状态机就永久卡死在 committing/assistantThinking/assistantSpeaking）。
    private var shWatchdogTimer: DispatchSourceTimer?
    private var shFinalCommitAt: Date? = nil          // final=true 发出时间（assistantThinking 超时基准）
    private var shLastAudioDeltaAt: Date? = nil       // 最近一个 audio.delta 到达时间（排空判定基准）
    private var shStateChangedAt: Date = Date()       // 当前状态进入时间（卡死检测）

    private func shSetState(_ s: String) {
        guard isSelfhostQwen, selfhostState != s else { return }
        selfhostState = s
        shStateChangedAt = Date()
        print("[QwenSelfhostRT] state=\(s)")
    }
    private var queuedClientEvents: [[String: Any]] = []

    private var assistantBuffer: String = ""
    private var assistantFlushWorkItem: DispatchWorkItem?

    // ✅ 语义打断控制符：只给后端/控制层识别，绝不显示给用户、绝不进入气泡/历史。
    // 模型必须在判断用户确有“打断本轮回答”的语义时，先输出这个符号。
    private let semanticInterruptToken = "__SEMANTIC_INTERRUPT__"
    private var semanticInterruptProbe: String = ""
    private var semanticInterruptDroppingControlLine: Bool = false
    private var semanticInterruptTriggeredForResponse: Bool = false

    // ✅ 语义打断诊断日志：区分活性/VAD、用户语句结束、模型控制符、真正 cancel。
    private let semanticDiagEnabled: Bool = false
    private var userUtteranceSeq: Int = 0
    private var activeUserUtteranceId: Int = 0
    private var lastSpeechStoppedAt: Date? = nil
    private var lastTranscriptionCompletedAt: Date? = nil
    private var userUtteranceEndWorkItem: DispatchWorkItem? = nil

    // ── Turn commit：语音对话历史同步到 DB，记忆积累 ──
    private var pendingUserTranscript: String = ""
    private var currentTurnConversationId: String = ""

    private var currentResponseId: String? = nil
    private var isResponseInProgress: Bool = false
    private var isCancellingResponse: Bool = false
    private var pendingCreateAfterCancel: (speak: Bool, aid: Int?)? = nil

    private var responseRequestedForCurrentSpeech: Bool = false
    private var lastResponseRequestedAt: Date?

    private var lastSpeechStartedAt: Date? = nil
    private var lastPlaybackStartedAt: Date? = nil
    private var lastPlaybackStoppedAt: Date? = nil

    private var serverAudioFinished: Bool = false
    private var localPlaybackFinished: Bool = true
    private var lastServerAudioDoneAt: Date? = nil
    private let audioDoneTailGrace: TimeInterval = 0.30

    private enum SpeechActivity {
        case idle
        case active(aid: Int)
    }

    private var speechActivity: SpeechActivity = .idle
    private var aidCounter: Int = 0
    private var lastSpeechAID: Int = 0
    private var lastEndKeyframeAID: Int = 0
    private var lastEndKeyframeTS: CFTimeInterval = 0

    private struct Frame {
        let data: Data
        let mime: String
        let ts: CFTimeInterval
    }

    private let maxHistoryFrames: Int = 6
    private let maxRollbackFramesPerTurn: Int = 1
    private let rollbackFrameInterval: TimeInterval = 0.22
    private let maxRollbackBufferedAmount: UInt64 = 900_000

    private var frameHistory: [Frame] = []
    private var latestImageData: Data?
    private var latestImageMime: String = "image/jpeg"
    private var injectedFrameCount: Int = 0
    private var latestImageUpdatedAt: CFTimeInterval = 0

    private var rollbackPendingAID: Int = 0
    private var rollbackStartedAID: Int = 0
    private var rollbackFrames: [Frame] = []
    private var rollbackCursor: Int = 0
    private var rollbackTimer: DispatchSourceTimer?

    private var imageStreamingEnabled: Bool = true
    private var imageStreamingFPS: Double = 0.5
    private var lastAuxSentAt: CFTimeInterval = 0
    private var imageTickTimer: DispatchSourceTimer?

    private let maxAuxImageBufferedAmount: UInt64 = 700_000
    private let maxKeyframeBufferedAmount: UInt64 = 2_000_000

    private var serverImageItemIds: [String] = []
    private let keepServerImages: Int = 1

    private enum ResponseCreateStyle {
        case outputModalities
        case modalities
        case minimal
    }

    private var responseCreateStyle: ResponseCreateStyle = .modalities
    private var hasWarnedResponseFallback: Bool = false

    private override init() {
        super.init()
        RTCPeerConnectionFactory.initialize()
        factory = RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
        installAudioRouteObservers()
        observeScreenAgentAudioHandoff()  // ✅ 监听屏幕共享 Agent 的 AudioSession 让出请求
    }

    deinit {
        removeAudioRouteObservers()
        NotificationCenter.default.removeObserver(self)
    }

    // ════════════════════════════════════════════════════════════════
    // ✅ ScreenAgent AudioSession 握手
    // 防止 ScreenAgentSession 启动时跟主 Realtime 抢 AVAudioSession 闪退
    // ════════════════════════════════════════════════════════════════

    private var pausedForScreenAgent = false

    private func observeScreenAgentAudioHandoff() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onScreenAgentWillTakeAudio),
            name: Notification.Name("ScreenAgentWillTakeAudioSession"),
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onScreenAgentDidReleaseAudio),
            name: Notification.Name("ScreenAgentDidReleaseAudioSession"),
            object: nil
        )
    }

    @objc private func onScreenAgentWillTakeAudio() {
        print("[RealtimeAV] ScreenAgent 要用 AudioSession,主路径暂停")
        if isStreaming() {
            pausedForScreenAgent = true
            stop()
        }
    }

    @objc private func onScreenAgentDidReleaseAudio() {
        print("[RealtimeAV] ScreenAgent 已释放 AudioSession")
        // 不自动恢复 — 用户从 ScreenAgentView 退出后,会在主页 onAppear 自然重连
        pausedForScreenAgent = false
    }

    /// 简单判断是否在跑(有 PC 或 WS)
    private func isStreaming() -> Bool {
        return peerConnection != nil || qwenWSTask != nil
    }

    private func semanticDiag(_ message: String) {
        guard semanticDiagEnabled else { return }
        let provider = activeProvider.rawValue
        let running = isRunning ? "running" : "not_running"
        let responding = isResponseInProgress ? "responding" : "idle_response"
        print("[SemanticInterruptDiag][provider=\(provider)][\(running)][\(responding)] \(message)")
    }

    func start(mode: CallMode) {
        workQueue.async { [weak self] in
            self?.semanticDiag("start mode=\(mode)")
            self?.startInternal(mode: mode)
        }
    }

    func stop() {
        workQueue.async { [weak self] in
            guard let self else { return }
            if self.isSelfhostQwen {
                print("[QwenSelfhostRT] close requested reason=stop() (UI挂断/FastLane.stop/页面切换) state=\(self.selfhostState) connecting=\(self.isConnecting) running=\(self.isRunning)")
            }
            self.hardReset(notify: true)
        }
    }

    func setMuted(_ muted: Bool) {
        workQueue.async { [weak self] in
            self?.setMutedForActiveProvider(muted)
        }
    }

    func prewarmSession() {
        workQueue.async { [weak self] in
            guard let self else { return }

            // ✅ FIX: Do not let prewarm create an extra realtime conversation.
            // /session auto-creates a conversation_id when none is supplied. A blind prewarm
            // before HomeChatView has assigned sessionConversationId can create a second ID
            // that later alternates with the real chat ID in TurnCommit logs.
            let convId = self.sessionConversationId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !convId.isEmpty else {
                self.semanticDiag("prewarm_skipped_no_conversation_id")
                return
            }

            self.fetchSessionFromBackend(wantVideo: false) { [weak self] result in
                guard let self else { return }
                if case .success(let info) = result {
                    self.workQueue.async {
                        self.syncServerConversationId(info.serverConversationId)
                    }
                }
            }
        }
    }

    // 兼容旧版调用，忽略参数
    func prewarmSession(apiBase: String, mode: CallMode) {
        if !apiBase.isEmpty {
            self.apiBase = apiBase
        }
        prewarmSession()
    }

    func toggleMute() {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.setMutedForActiveProvider(!self.isMuted)
        }
    }

    func setImageStreamingEnabled(_ enabled: Bool) {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.imageStreamingEnabled = enabled
            if enabled {
                self.restartImageTickTimerIfNeeded()
            } else {
                self.stopImageTickTimer()
            }
        }
    }

    func setImageStreamingFPS(_ fps: Double) {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.imageStreamingFPS = fps
        }
    }

    func sendText(_ text: String, speak: Bool = true) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return }
        workQueue.async { [weak self] in
            guard let self else { return }
            self.markAssistantNewTurn()
            self.sendConversationTextItem(t)
            if self.isWebSocketProvider { return }
            self.requestResponse(speak: speak, aid: nil)
        }
    }

    func interruptResponse() {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.isCancellingResponse = true
            self.sendClientEvent(["type": "response.cancel"], droppable: true)
            DispatchQueue.main.async {
                self.delegate?.realtimeAVService(self, didUpdateStatus: "已打断")
            }
        }
    }

    func injectImageData(_ data: Data, mime: String = "image/jpeg") {
        workQueue.async { [weak self] in
            guard let self else { return }
            guard self.callMode == .audioVideo else { return }
            guard self.imageStreamingEnabled else { return }

            let ts = CACurrentMediaTime()
            self.latestImageData = data
            self.latestImageMime = mime
            self.latestImageUpdatedAt = ts
            self.appendFrameToHistory(data: data, mime: mime, ts: ts)
            self.injectedFrameCount += 1
            if self.injectedFrameCount == 1 || self.injectedFrameCount % 25 == 0 {
                print("[OpenAIRealtime] camera frame injected count=\(self.injectedFrameCount) bytes=\(data.count)")
            }
        }
    }

    // ============================================================
    // ✅ 旧 API 兼容入口（RealtimeAVCallView / RealtimeBridge 历史调用名）。
    //    6.2 = startAudio()，6.2 Pro = startAV()；摄像头帧走 sendCameraFrameJPEG。
    // ============================================================
    func startAudio() { start(mode: .audioOnly) }

    func startAV() { start(mode: .audioVideo) }

    /// 摄像头 JPEG 帧入口（与 injectImageData 同源；保留旧名）。
    func sendCameraFrameJPEG(_ data: Data) {
        injectImageData(data, mime: "image/jpeg")
    }

    /// 视频帧档位：eco / balanced / turbo → 辅助帧 FPS。
    func setCameraFramePreset(_ preset: String) {
        let fps: Double
        switch preset.lowercased() {
        case "eco":      fps = 0.25
        case "turbo":    fps = 1.0
        default:         fps = 0.5   // balanced
        }
        print("[OpenAIRealtime] camera frame preset=\(preset.lowercased()) fps=\(fps)")
        setImageStreamingFPS(fps)
    }

    func prewarmChatAGINativeRealtime() {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.preferredProvider = AppConfig.Realtime.chatAGINativeProvider
            self.realtimePlan = "pro"
            self.instructionsOverride = "你是 ChatAGI 阿杜实时语音模型，请用自然、简洁的中文回答。"
            print("[ChatAGINativeRealtime] prewarm_start")
            print("[ChatAGINativeRealtime] ws_url=\(AppConfig.Realtime.nativeRealtimeWSURLString)")

            if self.isMiniCPM && self.isRunning && self.minicpmWarmReady {
                print("[ChatAGINativeRealtime] warm_ready")
                DispatchQueue.main.async {
                    self.delegate?.realtimeAVService(self, didUpdateStatus: "已就绪")
                }
                return
            }

            if self.isConnecting || (self.isMiniCPM && self.isRunning) {
                DispatchQueue.main.async {
                    self.delegate?.realtimeAVService(self, didUpdateStatus: self.minicpmWarmReady ? "已就绪" : "预热中")
                }
                return
            }

            self.minicpmPrewarmOnly = true
            self.minicpmReconnectAttempted = false
            DispatchQueue.main.async {
                self.delegate?.realtimeAVService(self, didUpdateStatus: "预热中")
            }
            self.startInternal(mode: .audioOnly)
        }
    }

    func activateChatAGINativeRealtime() {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.preferredProvider = AppConfig.Realtime.chatAGINativeProvider
            self.realtimePlan = "pro"
            self.instructionsOverride = "你是 ChatAGI 阿杜实时语音模型，请用自然、简洁的中文回答。"
            self.minicpmPrewarmOnly = false

            if self.isMiniCPM && self.isRunning {
                self.minicpmCallStartedAt = Date()
                self.minicpmFirstAudioMs = nil
                self.minicpmFirstTextMs = nil
                if self.vpAudio == nil {
                    self.startQwenAudioCapture(callId: self.currentCallId)
                }
                self.qwenAudioStarted = true
                print("[ChatAGINativeRealtime] mic_start")
                DispatchQueue.main.async {
                    self.delegate?.realtimeAVService(self, didUpdateStatus: self.minicpmSessionReady ? "正在听" : "已连接，等待模型就绪")
                }
                return
            }

            print("[ChatAGINativeRealtime] connecting...")
            self.startInternal(mode: .audioOnly)
        }
    }

    func finishChatAGINativeUserTurnNow() {
        workQueue.async { [weak self] in
            guard let self, self.isMiniCPM else { return }
            self.minicpmSubmitBufferedAudio(reason: "manual_finish")
            DispatchQueue.main.async {
                self.delegate?.realtimeAVService(self, didUpdateStatus: "正在思考")
            }
        }
    }

    private func appendFrameToHistory(data: Data, mime: String, ts: CFTimeInterval) {
        frameHistory.append(Frame(data: data, mime: mime, ts: ts))
        if frameHistory.count > maxHistoryFrames {
            frameHistory.removeFirst(frameHistory.count - maxHistoryFrames)
        }
    }

    private func latestFrame() -> Frame? {
        if let f = frameHistory.last { return f }
        if let d = latestImageData, latestImageUpdatedAt > 0 {
            return Frame(data: d, mime: latestImageMime, ts: latestImageUpdatedAt)
        }
        return nil
    }

    private func syncServerConversationId(_ serverId: String?) {
        let sc = (serverId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sc.isEmpty else { return }

        // ✅ Server is the source of truth for the realtime call's conversation_id.
        // If the client sent an existing chat id, the server returns the same id;
        // if the client did not have one yet, this locks the newly-created id once.
        sessionConversationId = sc
        currentTurnConversationId = sc
        semanticDiag("conversation_id_synced conv=\(sc)")
    }

    private func resetPlaybackCompletionStateForNewResponse() {
        serverAudioFinished = false
        localPlaybackFinished = true
        lastServerAudioDoneAt = nil
    }

    private func markQwenPlaybackStarted() {
        qwenPlaybackLikelyActive = true
        qwenPlaybackGateHoldUntil = nil
        lastPlaybackStartedAt = Date()
        localPlaybackFinished = false
    }

    private func markQwenPlaybackStoppedSoon() {
        qwenPlaybackLikelyActive = false
        qwenPlaybackGateHoldUntil = Date().addingTimeInterval(qwenPlaybackTailHold)
        lastPlaybackStoppedAt = Date()
        localPlaybackFinished = true
    }

    private func startInternal(mode: CallMode) {
        // ✅ 日志标签按套餐路由分流：6.2/6.2 Pro（preferredProvider=openai）打 [OpenAIRealtime]，
        //    6.1（chatagi_native_realtime）打 [ChatAGINativeRealtime]，其余自部署打 [QwenSelfhostRT]。
        let _provLower = preferredProvider?.lowercased() ?? ""
        let logTag: String = {
            if _provLower == "openai" { return "[OpenAIRealtime]" }
            if _provLower == AppConfig.Realtime.chatAGINativeProvider || _provLower.hasPrefix("minicpm") { return "[ChatAGINativeRealtime]" }
            return "[QwenSelfhostRT]"
        }()
        // ✅ 一.1/一.2/一.4：已在连接/通话中 → 绝不重复 connect。
        //    所有入口（startAudio / startAV / ensureConnected / retry / UI 重绘）都经过这里，
        //    在此拦截即可保证只存在一个 realtime 连接，避免连接风暴。
        if isConnecting || isRunning {
            // ✅ 音频已在通话中、用户切到视频：原地升级为 audioVideo（开启图片流 + tick），
            //    不重连、不打断音频。否则 callMode 卡在 .audioOnly → injectImageData 被
            //    `guard callMode == .audioVideo` 拦掉 → 摄像头帧永远存不进 latestFrame → 三档都没视频。
            if isRunning, mode == .audioVideo, callMode == .audioOnly {
                callMode = .audioVideo
                imageStreamingEnabled = true
                if activeProvider == .qwen { qwenAudioStarted = true }  // 音频已在跑，允许立即发图片帧
                restartImageTickTimerIfNeeded()
                print("\(logTag) upgrade audioOnly -> audioVideo (启用图片流，不重连) provider=\(activeProvider.rawValue)")
                DispatchQueue.main.async {
                    self.delegate?.realtimeAVService(self, didUpdateStatus: "已连接")
                }
                return
            }
            print("\(logTag) ignore duplicate start (connecting=\(isConnecting) running=\(isRunning)) mode=\(mode)")
            DispatchQueue.main.async {
                self.delegate?.realtimeAVService(self, didUpdateStatus: self.isRunning ? "已连接" : "连接中…")
            }
            return
        }

        print("\(logTag) connect begin mode=\(mode) plan=\(realtimePlan ?? "nil") provider=\(preferredProvider ?? "nil")")
        hardReset(notify: false)

        callMode = mode
        isConnecting = true
        isRunning = false
        isMuted = false
        hasSentSessionUpdate = false
        isSelfhostQwen = false
        didSendSelfhostMinimalSessionUpdate = false
        isMiniCPM = false
        minicpmInstructions = nil
        minicpmSessionReady = false
        minicpmSessionUpdateSent = false
        minicpmWarmReady = false
        minicpmQueueWatchdogToken += 1
        minicpmAppendCount = 0
        minicpmPlaybackStarted = false
        minicpmTurnActive = false
        minicpmEndOfTurnReceived = false
        minicpmContinuousPlaybackActive = false
        minicpmPlaybackPendingPCM16.removeAll(keepingCapacity: true)
        minicpmStopAudioPlayback(clearQueue: true, logStop: false)
        minicpmPlaybackDrainChecks = 0
        minicpmCallStartedAt = nil
        minicpmFirstAudioMs = nil
        minicpmFirstTextMs = nil
        minicpmPendingFloat32.removeAll(keepingCapacity: true)
        minicpmPendingMaxRMS = 0
        minicpmPendingForceListen = false
        minicpmBargeHoldMs = 0
        minicpmUserSpeaking = false
        minicpmSpeechMs = 0
        minicpmSilenceMs = 0
        minicpmLastSubmitAt = nil
        minicpmDroppedAudioCount = 0
        selfhostTurnOpen = false
        selfhostAppendCount = 0
        selfhostState = "idle"
        shBargeAccumMs = 0
        shAwaitingStaleDone = false
        shInterruptAt = nil
        shFinalCommitSentForTurn = false
        shPendingFinalCommit = false
        shPendingFinalCommitSeconds = 0
        queuedClientEvents.removeAll()

        assistantBuffer = ""
        assistantFlushWorkItem?.cancel()
        assistantFlushWorkItem = nil
        resetSemanticInterruptParser()

        pendingUserTranscript = ""
        currentTurnConversationId = sessionConversationId.trimmingCharacters(in: .whitespacesAndNewlines)

        currentResponseId = nil
        isResponseInProgress = false
        isCancellingResponse = false
        pendingCreateAfterCancel = nil
        responseRequestedForCurrentSpeech = false
        lastResponseRequestedAt = nil
        lastSpeechStartedAt = nil
        lastPlaybackStartedAt = nil
        lastPlaybackStoppedAt = nil

        resetPlaybackCompletionStateForNewResponse()

        speechActivity = .idle
        lastSpeechAID = 0
        lastEndKeyframeAID = 0
        lastEndKeyframeTS = 0

        rollbackPendingAID = 0
        rollbackStartedAID = 0
        stopRollback()

        frameHistory.removeAll()
        latestImageData = nil
        latestImageUpdatedAt = 0
        lastAuxSentAt = 0
        serverImageItemIds.removeAll()

        if mode == .audioVideo {
            imageStreamingEnabled = true
            restartImageTickTimerIfNeeded()
        } else {
            imageStreamingEnabled = false
            stopImageTickTimer()
        }

        pendingSessionInfo = nil
        pendingAudioReady = false

        let callId = UUID()
        currentCallId = callId
        minicpmCallStartedAt = Date()

        DispatchQueue.main.async {
            self.delegate?.realtimeAVService(self, didUpdateStatus: "连接中…")
        }

        fetchSessionFromBackend(wantVideo: (mode == .audioVideo)) { [weak self] result in
            guard let self else { return }
            self.workQueue.async {
                guard callId == self.currentCallId else { return }
                switch result {
                case .success(let info):
                    self.pendingSessionInfo = info
                    self.maybeConnectIfReady(callId: callId)
                case .failure(let err):
                    // Guest / 机器人 6.0 使用 OpenAI Realtime 兼容协议，但实际接入阿杜三段 WebRTC 桥。
                    let st = (self.preferredProvider?.lowercased() == "openai")
                        ? "阿杜三段实时语音 session 创建失败" : "获取会话失败"
                    if self.preferredProvider?.lowercased() == "openai" {
                        print("[AduThreeStageRealtime] session create FAILED error=\(err.localizedDescription)")
                    }
                    self.failAndReset(callId: callId, status: st, error: err)
                }
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.preflightAudio(callId: callId)
        }
    }

    private func preflightAudio(callId: UUID) {
        let perm = AVAudioSession.sharedInstance().recordPermission
        switch perm {
        case .granted:
            do {
                try configureAudioSession()
                workQueue.async { [weak self] in
                    guard let self else { return }
                    guard callId == self.currentCallId else { return }
                    self.pendingAudioReady = true
                    self.maybeConnectIfReady(callId: callId)
                }
            } catch {
                workQueue.async { [weak self] in
                    self?.failAndReset(callId: callId, status: "音频配置失败", error: error)
                }
            }

        case .undetermined:
            AVAudioSession.sharedInstance().requestRecordPermission { [weak self] ok in
                guard let self else { return }
                DispatchQueue.main.async {
                    if !ok {
                        let err = NSError(domain: "RealtimeAVService", code: -10,
                                          userInfo: [NSLocalizedDescriptionKey: "麦克风权限未开启"])
                        self.workQueue.async { [weak self] in
                            self?.failAndReset(callId: callId, status: "麦克风权限未开启", error: err)
                        }
                        return
                    }
                    do {
                        try self.configureAudioSession()
                        self.workQueue.async { [weak self] in
                            guard let self else { return }
                            guard callId == self.currentCallId else { return }
                            self.pendingAudioReady = true
                            self.maybeConnectIfReady(callId: callId)
                        }
                    } catch {
                        self.workQueue.async { [weak self] in
                            self?.failAndReset(callId: callId, status: "音频配置失败", error: error)
                        }
                    }
                }
            }

        case .denied:
            let err = NSError(domain: "RealtimeAVService", code: -10,
                              userInfo: [NSLocalizedDescriptionKey: "麦克风权限未开启"])
            workQueue.async { [weak self] in
                self?.failAndReset(callId: callId, status: "麦克风权限未开启", error: err)
            }

        @unknown default:
            let err = NSError(domain: "RealtimeAVService", code: -11,
                              userInfo: [NSLocalizedDescriptionKey: "未知麦克风权限状态"])
            workQueue.async { [weak self] in
                self?.failAndReset(callId: callId, status: "麦克风权限异常", error: err)
            }
        }
    }

    private func configureAudioSession() throws {
        let rtc = RTCAudioSession.sharedInstance()
        rtc.lockForConfiguration()
        defer { rtc.unlockForConfiguration() }

        let sys = AVAudioSession.sharedInstance()
        do { try sys.setPreferredSampleRate(48_000) } catch {}
        do { try sys.setPreferredIOBufferDuration(0.01) } catch {}

        // ✅ 规格 §5：playAndRecord + voiceChat + defaultToSpeaker/allowBluetooth/allowBluetoothA2DP
        let options: AVAudioSession.CategoryOptions = [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
        try rtc.setCategory(AVAudioSession.Category.playAndRecord.rawValue, with: options)
        try rtc.setMode(AVAudioSession.Mode.voiceChat.rawValue)
        try rtc.setActive(true)

        rtc.isAudioEnabled = true
        rtc.useManualAudio = false
    }

    private func maybeConnectIfReady(callId: UUID) {
        guard callId == currentCallId else { return }
        guard pendingAudioReady else { return }
        guard let info = pendingSessionInfo else { return }

        pendingSessionInfo = nil
        activeProvider = info.provider

        switch info.provider {
        case .openai:
            rtcURL = info.rtcURL
            ephemeralKey = info.ephemeralKey
            iceServers = info.iceServers
            serverInstructions = info.serverInstructions  // ✅ GPT 也要存 instructions
            serverTurnDetection = info.serverTurnDetection
            if let sv = info.serverVoice, !sv.isEmpty { voiceName = sv }
            // ✅ 后端返回的 conversation_id 是本次实时通话唯一会话 ID
            syncServerConversationId(info.serverConversationId)

            do {
                try setupPeerConnection()
            } catch {
                print("[OpenAIRealtime] peer connection setup FAILED error=\(error.localizedDescription)")
                failAndReset(callId: callId, status: "WebRTC 连接失败", error: error)
                return
            }

            negotiate(callId: callId) { [weak self] error in
                guard let self else { return }
                self.workQueue.async {
                    guard callId == self.currentCallId else { return }
                    if let error {
                        print("[OpenAIRealtime] negotiate FAILED error=\(error.localizedDescription)")
                        self.failAndReset(callId: callId, status: "WebRTC 连接失败", error: error)
                        return
                    }
                    print("[OpenAIRealtime] webrtc negotiated (SDP answer applied), waiting data channel open")
                    self.isConnecting = false
                    self.isRunning = true
                    DispatchQueue.main.async {
                        self.delegate?.realtimeAVServiceDidConnect(self)
                        self.delegate?.realtimeAVService(self, didUpdateStatus: "已连接")
                    }
                }
            }

        case .qwen, .pipeline, .minicpm:
            guard let wsURL = info.wsURL else {
                failAndReset(callId: callId, status: "缺少 ws_url", error: NSError(
                    domain: "RealtimeAVService",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "session 缺少 ws_url"]
                ))
                return
            }
            // ✅ ChatAGI Native Realtime（ChatAGI Pro / 机器人 6.1）：复用 WebSocket 链路，但音频走 float32，
            //    session.update 只发 instructions，麦克风持续 append + force_listen，无 commit/final。
            isMiniCPM = (info.provider == .minicpm)
            minicpmInstructions = info.serverInstructions
            minicpmSessionReady = false
            minicpmSessionUpdateSent = false
            minicpmAppendCount = 0
            minicpmPlaybackStarted = false
            minicpmTurnActive = false
            // ✅ 自部署 Qwen3-Omni：复用 .qwen 链路，仅 session.update 字段与鉴权策略不同。
            isSelfhostQwen = (info.provider == .qwen && info.isSelfhost)
            if let m = info.selfhostModel?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty {
                qwenSelfhostModel = m
            }
            // ✅ 应用后端 /session 下发的客户端 VAD / 插话参数（env 可调，缺省保留本地默认）。
            if isSelfhostQwen {
                if let v = info.selfhostVAD {
                    if let x = (v["rms_threshold"] as? NSNumber)?.floatValue, x > 0 { shMinVoiceRMS = x }
                    if let x = (v["silence_duration_ms"] as? NSNumber)?.doubleValue, x > 0 { shSilenceToCommitMs = x }
                    if let x = (v["min_audio_seconds"] as? NSNumber)?.doubleValue, x > 0 { shMinAudioSeconds = x }
                }
                if let bcfg = info.selfhostBargeIn {
                    if let x = (bcfg["rms_threshold"] as? NSNumber)?.floatValue, x > 0 { shBargeInRMS = x }
                    if let x = (bcfg["hold_ms"] as? NSNumber)?.doubleValue, x > 0 { shBargeInHoldMs = x }
                    if let x = (bcfg["tail_hold_ms"] as? NSNumber)?.doubleValue, x >= 0 { shTailHoldMs = x }
                }
                print("[QwenSelfhostRT] vad config (server) rms=\(shMinVoiceRMS) silence_ms=\(Int(shSilenceToCommitMs)) min_sec=\(shMinAudioSeconds) barge_rms=\(shBargeInRMS) barge_hold_ms=\(Int(shBargeInHoldMs)) tail_hold_ms=\(Int(shTailHoldMs)) — 开口/插话门槛改用动态噪声底 gateRMS=max(ambient*3, 0.00015)")
                // ✅ 动态噪声底：每次新连接重新校准（服务端 rms_threshold 只作参考，不再做门槛——
                //    VPIO AGC 下实测 rms 仅 0.0002 量级，固定 0.015 永远打不开）。
                shAmbientRMS = 0
                shAmbientAccumSum = 0
                shAmbientAccumMs = 0
                shAmbientLocked = false
                shGateRMS = 0.0002
                shBargeGateRMS = 0.0008
            }
            selfhostTurnOpen = false
            qwenApiKey = info.apiKey
            serverInstructions = info.serverInstructions
            serverTurnDetection = info.serverTurnDetection
            if let sv = info.serverVoice, !sv.isEmpty { voiceName = sv }  // ✅ 使用后端返回的音色
            // ✅ 后端返回的 conversation_id 是本次实时通话唯一会话 ID
            syncServerConversationId(info.serverConversationId)
            qwenPcm24ToPcm16 = false

            do { try configureAudioSession() } catch {
                failAndReset(callId: callId, status: "音频配置失败", error: error)
                return
            }

            connectQwenWebSocket(callId: callId, wsURL: wsURL, apiKey: info.apiKey ?? "")
        }
    }

    private func hardReset(notify: Bool) {
        // ✅ 修复死日志：原来 close 日志放在函数后半段、且 gate 在 isSelfhostQwen 上，
        //    但函数开头已把 isSelfhostQwen 清零 → "[QwenSelfhostRT] close requested" 永远不打印，
        //    导致"刚连上就 closed"完全查不到是谁关的。现在先快照、先打印，再清状态。
        if isSelfhostQwen, qwenWSTask != nil {
            let caller = Thread.callStackSymbols.dropFirst(2).prefix(5)
                .map { $0.components(separatedBy: " ").suffix(3).joined(separator: " ") }
                .joined(separator: " <- ")
            print("[QwenSelfhostRT] close requested reason=hardReset(notify:\(notify)) state=\(selfhostState) connecting=\(isConnecting) running=\(isRunning) caller=\(caller)")
        }

        currentCallId = UUID()

        isConnecting = false
        isRunning = false
        isMuted = false
        hasSentSessionUpdate = false
        isSelfhostQwen = false
        didSendSelfhostMinimalSessionUpdate = false
        isMiniCPM = false
        minicpmInstructions = nil
        minicpmSessionReady = false
        minicpmSessionUpdateSent = false
        minicpmWarmReady = false
        minicpmQueueWatchdogToken += 1
        minicpmAppendCount = 0
        minicpmPlaybackStarted = false
        minicpmTurnActive = false
        minicpmEndOfTurnReceived = false
        minicpmContinuousPlaybackActive = false
        minicpmPlaybackPendingPCM16.removeAll(keepingCapacity: true)
        minicpmStopAudioPlayback(clearQueue: true, logStop: false)
        minicpmPlaybackDrainChecks = 0
        minicpmPendingFloat32.removeAll(keepingCapacity: true)
        minicpmPendingMaxRMS = 0
        minicpmPendingForceListen = false
        minicpmBargeHoldMs = 0
        minicpmUserSpeaking = false
        minicpmSpeechMs = 0
        minicpmSilenceMs = 0
        minicpmLastSubmitAt = nil
        minicpmDroppedAudioCount = 0
        selfhostTurnOpen = false
        selfhostAppendCount = 0
        selfhostState = "idle"
        shBargeAccumMs = 0
        shAwaitingStaleDone = false
        shInterruptAt = nil
        shFinalCommitSentForTurn = false
        shPendingFinalCommit = false
        shPendingFinalCommitSeconds = 0

        pendingSessionInfo = nil
        pendingAudioReady = false

        assistantFlushWorkItem?.cancel()
        assistantFlushWorkItem = nil
        assistantBuffer = ""

        currentResponseId = nil
        isResponseInProgress = false
        isCancellingResponse = false
        pendingCreateAfterCancel = nil
        responseRequestedForCurrentSpeech = false
        lastResponseRequestedAt = nil

        lastSpeechStartedAt = nil
        lastPlaybackStartedAt = nil
        lastPlaybackStoppedAt = nil

        resetPlaybackCompletionStateForNewResponse()

        qwenPlaybackLikelyActive = false
        qwenPlaybackGateHoldUntil = nil
        qwenAudioStarted = false
        qwenUserIsSpeaking = false
        queuedClientEvents.removeAll()
        userUtteranceEndWorkItem?.cancel()
        userUtteranceEndWorkItem = nil

        stopImageTickTimer()
        stopRollback()

        latestImageData = nil
        latestImageUpdatedAt = 0
        lastAuxSentAt = 0

        frameHistory.removeAll()
        serverImageItemIds.removeAll()

        speechActivity = .idle
        lastSpeechAID = 0
        lastEndKeyframeAID = 0
        lastEndKeyframeTS = 0

        rollbackPendingAID = 0
        rollbackStartedAID = 0

        dataChannel?.delegate = nil
        dataChannel?.close()
        dataChannel = nil
        frontBargeStopTap()

        peerConnection?.delegate = nil
        peerConnection?.close()
        peerConnection = nil
        localAudioTrack = nil
        localVideoCapturer?.stopCapture()
        localVideoCapturer = nil
        localVideoTrack = nil

        stopQwenKeepaliveTimer()
        qwenLastServerEventAt = nil
        qwenLastClientSendAt = nil

        qwenIsReceivingMessages = false
        // （close 来源日志已上移到函数顶部——这里 isSelfhostQwen 已被清零，原日志是死代码。）
        qwenWSTask?.cancel(with: .goingAway, reason: nil)
        qwenWSTask = nil
        qwenWSSession?.invalidateAndCancel()
        qwenWSSession = nil
        qwenWSDelegateProxy = nil
        shStopWatchdog()
        shPendingPCM.removeAll(keepingCapacity: false)
        shFinalCommitAt = nil
        shLastAudioDeltaAt = nil
        shMicFrameCount = 0
        shSawJsonAudioDelta = false
        injectedFrameCount = 0
        shAmbientRMS = 0
        shAmbientAccumSum = 0
        shAmbientAccumMs = 0
        shAmbientLocked = false
        shGateRMS = 0.0002
        shBargeGateRMS = 0.0008

        qwenApiKey = nil
        serverInstructions = nil
        serverTurnDetection = nil
        qwenPcm24ToPcm16 = false

        stopQwenAudioIO()

        VoiceprintGate.shared.resetBuffer()

        rtcURL = nil
        ephemeralKey = nil
        iceServers = []

        let rtc = RTCAudioSession.sharedInstance()
        rtc.lockForConfiguration()
        rtc.isAudioEnabled = false
        rtc.useManualAudio = false
        try? rtc.setActive(false)
        rtc.unlockForConfiguration()

        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])

        if notify {
            DispatchQueue.main.async {
                self.delegate?.realtimeAVServiceDidDisconnect(self)
                self.delegate?.realtimeAVService(self, didUpdateStatus: "已挂断")
            }
        }
    }

    private func failAndReset(callId: UUID, status: String, error: Error) {
        guard callId == currentCallId else { return }
        hardReset(notify: false)
        let unsafeStatus = status.contains("Qwen") || status.contains("ws_url") || status.contains("/session") || status.contains("ephemeral") || status.contains("rtcURL")
        let allowedStatus = [
            "麦克风权限未开启",
            "摄像头权限未开启",
            "摄像头不可用",
            "后端未配置 OPENAI_API_KEY",
            "当前套餐暂不可用",
            "实时通话连接失败，请稍后再试",
            // OpenAI Realtime 兼容入口的阿杜三段 WebRTC session 错误。
            "阿杜三段实时语音 session 创建失败",
            "WebRTC 连接失败",
            "WebSocket 失败",
            "SDP 交换失败",
            "DataChannel 未打开",
            "视频帧发送失败",
            "麦克风启动失败",
            "音频解码失败",
            "播放失败"
        ]
        let errDesc = (error as NSError).localizedDescription
        let displayStatus = unsafeStatus ? Self.realtimeUserFacingError : status
        let finalStatus = allowedStatus.contains(errDesc) ? errDesc : displayStatus
        let safeError = allowedStatus.contains(finalStatus)
            ? NSError(domain: "RealtimeAVService", code: (error as NSError).code, userInfo: [NSLocalizedDescriptionKey: finalStatus])
            : Self.userFacingError(code: (error as NSError).code)
        DispatchQueue.main.async {
            self.delegate?.realtimeAVService(self, didUpdateStatus: finalStatus)
            self.delegate?.realtimeAVService(self, didFail: safeError)
        }
    }
}

extension RealtimeAVService {

    private var sessionURL: URL {
        if let s = sessionEndpointOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !s.isEmpty,
           let u = URL(string: s) {
            return u
        }

        let baseTrimmed = apiBase
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let appBaseTrimmed = AppConfig.API.apiBase
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let plan = realtimePlan?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let provider = preferredProvider?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let useOfficialOpenAI = provider == "openai" && (plan == "guest" || plan == "ultra" || plan == "coder")
        let path = useOfficialOpenAI ? "/api/realtime/session" : "/session"

        if !appBaseTrimmed.isEmpty, baseTrimmed == appBaseTrimmed {
            return AppConfig.API.resolve(path)
        }

        return URL(string: baseTrimmed + path)!
    }

    private func refreshPerceptionSnapshotFromManagerIfNeeded() {
        if let snap = lastPerceptionSnapshot, !snap.isEmpty { return }
        if let snap = AduPerceptionManager.shared.lastSnapshot,
           let d = try? JSONEncoder().encode(snap),
           let dict = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           !dict.isEmpty {
            lastPerceptionSnapshot = dict
            semanticDiag("perception_refreshed_from_manager keys=\(Array(dict.keys).sorted())")
        } else {
            semanticDiag("perception_missing_before_session")
        }
    }

    private func fetchSessionFromBackend(
        wantVideo: Bool,
        completion: @escaping (Result<SessionInfo, Error>) -> Void
    ) {
        let requestedProvider = preferredProvider?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if requestedProvider == AppConfig.Realtime.chatAGINativeProvider {
            let ws = AppConfig.Realtime.nativeRealtimeWSURLString
            guard let wsURL = URL(string: ws), ["ws", "wss"].contains(wsURL.scheme?.lowercased() ?? "") else {
                completion(.failure(NSError(
                    domain: "RealtimeAVService",
                    code: -61,
                    userInfo: [NSLocalizedDescriptionKey: "ChatAGI Native Realtime ws_url 无效"]
                )))
                return
            }
            print("[ChatAGINativeRealtime] provider=\(AppConfig.Realtime.chatAGINativeProvider)")
            print("[ChatAGINativeRealtime] ws_url=\(ws)")
            print("[ChatAGINativeRealtime] direct ws_url=\(wsURL.absoluteString)")
            let info = SessionInfo(
                provider: .minicpm,
                rtcURL: wsURL,
                ephemeralKey: "",
                iceServers: [],
                wsURL: wsURL,
                apiKey: "",
                pcm24ToPcm16Required: false,
                serverInstructions: "你是 ChatAGI 阿杜实时语音模型，请用自然、简洁的中文回答。",
                serverVoice: nil,
                serverConversationId: nil,
                serverTurnDetection: nil,
                isSelfhost: false,
                selfhostModel: AppConfig.Realtime.chatAGINativeModelDisplay,
                selfhostVAD: nil,
                selfhostBargeIn: nil
            )
            completion(.success(info))
            return
        }

        var req = URLRequest(url: sessionURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        req.cachePolicy = .reloadIgnoringLocalCacheData

        // ✅ 防止 HomeChatView 没及时写入导致位置/感知丢失：发 /session 前兜底刷新一次。
        refreshPerceptionSnapshotFromManagerIfNeeded()

        var payload: [String: Any] = [
            "want_video": wantVideo,
            "allow_web": true,
            "enable_memory": true,
            ]

        // ✅ 套餐路由：preferredProvider 由调用方按套餐设置
        if let prov = preferredProvider?.trimmingCharacters(in: .whitespacesAndNewlines), !prov.isEmpty {
            payload["provider"] = prov
        }

        let plan = realtimePlan?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if plan == "guest" || plan == "ultra" || plan == "coder" {
            payload["plan"] = plan
            payload["mode"] = wantVideo ? "video" : "voice"
            payload["model"] = AppConfig.Realtime.defaultModel
            payload["voice"] = AppConfig.Realtime.defaultVoice
            if plan == "guest" {
                payload["model_display"] = "机器人 6.0"
                payload["robot_version"] = "6.0"
            }
        } else if plan == "pro" {
            // ✅ 旧兼容分支：如果调用方没有直接指定 chatagi_native_realtime，后端仍可据
            //    plan=pro / model_display=机器人 6.1 返回自部署实时语音配置。
            payload["plan"] = plan
            payload["mode"] = wantVideo ? "video" : "voice"
            payload["model_display"] = "机器人 6.1"
            payload["robot_version"] = "6.1"
        }

        // ✅ profile 必须传，否则 home binding 可能误判
        let prof = sessionProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        payload["profile"] = prof.isEmpty ? "default" : prof

        // ✅ client_id 强制有值 — 保证语音和文本聊天用同一个 user_key，记忆才能共享
        let cid = sessionClientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveCid = cid.isEmpty
            ? (UIDevice.current.identifierForVendor?.uuidString ?? "ios-anonymous")
            : cid
        payload["client_id"] = effectiveCid
        payload["user_key"] = effectiveCid

        let convId = sessionConversationId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !convId.isEmpty { payload["conversation_id"] = convId }

        if let snapshot = lastPerceptionSnapshot, !snapshot.isEmpty {
            payload["perception"] = snapshot
        }
        semanticDiag("session_payload wantVideo=\(wantVideo) profile=\(payload["profile"] ?? "") client_id=\(effectiveCid) perception_present=\(payload["perception"] != nil) conv=\(payload["conversation_id"] ?? "")")
        print("[AduThreeStageRealtime] session request url=\(sessionURL.absoluteString) plan=\(plan.isEmpty ? "(none)" : plan) compatProvider=\(requestedProvider.isEmpty ? "(none)" : requestedProvider)")

        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            completion(.failure(error))
            return
        }

        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err {
                print("[AduThreeStageRealtime] session network error url=\(self.sessionURL.absoluteString) error=\(err.localizedDescription)")
                completion(.failure(err))
                return
            }

            guard let http = resp as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let data else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                print("[AduThreeStageRealtime] session HTTP failed code=\(code) body=\(body.prefix(800))")
                if let data,
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let err = obj["error"] as? String {
                    let message: String
                    if err == "OPENAI_API_KEY_missing" {
                        message = "后端未配置 OPENAI_API_KEY"
                    } else if err == "plan_not_available" {
                        message = "当前套餐暂不可用"
                    } else {
                        message = Self.realtimeUserFacingError
                    }
                    completion(.failure(NSError(domain: "RealtimeAVService", code: code, userInfo: [NSLocalizedDescriptionKey: message])))
                    return
                }
                completion(.failure(Self.userFacingError(code: code)))
                return
            }

            do {
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard let dict = json else {
                    throw Self.userFacingError()
                }

                let providerStr = (dict["provider"] as? String)?.lowercased() ?? "openai"

                // 硬保险：本机请求的是 OpenAI-compatible WebRTC，后端却返回了 qwen/qwen_selfhost/pipeline
                // → 直接报错拒绝，避免兼容 WebRTC 套餐滑进 WebSocket/vLLM-Omni 分支。
                if self.preferredProvider?.lowercased() == "openai", providerStr != "openai" {
                    print("[AduThreeStageRealtime] REJECT session: requested openai-compatible but got provider=\(providerStr)")
                    completion(.failure(NSError(domain: "RealtimeAVService", code: -23,
                                                userInfo: [NSLocalizedDescriptionKey: "阿杜三段实时语音 session 创建失败"])))
                    return
                }

                if providerStr == AppConfig.Realtime.chatAGINativeProvider || providerStr == "minicpm_selfhost" || providerStr == "minicpm" || providerStr == "minicpm_native" {
                    // ✅ ChatAGI Native Realtime（ChatAGI Pro / 机器人 6.1）全双工链路：
                    //    session.update(instructions) / input_audio_buffer.append(float32 16k, force_listen) /
                    //    response.output_audio.delta(text + float32 24k + end_of_turn)。
                    //    ⚠️ ws_url 带 ?mode=audio query；优先取 ws_url，不要丢弃 query。
                    guard let wsUrlStr = (dict["ws_url"] as? String) ?? (dict["rtc_url"] as? String),
                          let wsURL = URL(string: wsUrlStr) else {
                        throw Self.userFacingError()
                    }
                    let serverInstr = dict["instructions"] as? String
                    let serverVoice = dict["voice"] as? String
                    let info = SessionInfo(
                        provider: .minicpm,
                        rtcURL: wsURL,
                        ephemeralKey: "",
                        iceServers: [],
                        wsURL: wsURL,
                        apiKey: "",                       // 自部署无鉴权
                        pcm24ToPcm16Required: false,
                        serverInstructions: serverInstr,
                        serverVoice: serverVoice,
                        serverConversationId: dict["conversation_id"] as? String,
                        serverTurnDetection: nil,
                        isSelfhost: false,
                        selfhostModel: dict["model"] as? String,
                        selfhostVAD: nil,
                        selfhostBargeIn: nil
                    )
                    completion(.success(info))
                    return
                }

                if providerStr == "qwen" || providerStr == "pipeline" || providerStr == "qwen_selfhost" {
                    // ✅ qwen_selfhost（自部署 Qwen3-Omni）直接复用已有 Qwen WebSocket 链路：
                    //    session.update / input_audio_buffer.append / speech_started/stopped /
                    //    response.audio.delta / response.cancel / userIsSpeaking gate / VoiceProcessingIO。
                    let provider: RealtimeProvider = (providerStr == "pipeline") ? .pipeline : .qwen
                    let isSelfhost = (providerStr == "qwen_selfhost")

                    guard let wsUrlStr = (dict["ws_url"] as? String) ?? (dict["rtc_url"] as? String),
                          let wsURL = URL(string: wsUrlStr) else {
                        throw Self.userFacingError()
                    }

                    let apiKey = (dict["api_key"] as? String) ?? (dict["ephemeral_key"] as? String) ?? ""
                    let pcm24 = (dict["pcm24_to_pcm16_required"] as? Bool) ?? false
                    let serverInstr = dict["instructions"] as? String
                    let serverVoice = dict["voice"] as? String  // ✅ 后端返回的音色

                    let info = SessionInfo(
                        provider: provider,
                        rtcURL: wsURL,
                        ephemeralKey: apiKey,
                        iceServers: [],
                        wsURL: wsURL,
                        apiKey: apiKey,
                        pcm24ToPcm16Required: pcm24,
                        serverInstructions: serverInstr,
                        serverVoice: serverVoice,
                        serverConversationId: dict["conversation_id"] as? String,
                        serverTurnDetection: dict["turn_detection"] as? [String: Any],
                        isSelfhost: isSelfhost,
                        // ✅ vLLM-Omni：保存 /session 返回的 model，用于 session.update 顶层 model。
                        selfhostModel: dict["model"] as? String,
                        // ✅ 后端 env 驱动的客户端 VAD / 插话参数（原来被忽略，现在真正生效）。
                        selfhostVAD: dict["vad"] as? [String: Any],
                        selfhostBargeIn: dict["barge_in"] as? [String: Any]
                    )
                    completion(.success(info))
                    return
                }

                guard let urlStr = dict["rtc_url"] as? String,
                      let url = URL(string: urlStr) else {
                    print("[AduThreeStageRealtime] session missing rtc_url, keys=\(Array(dict.keys).sorted())")
                    throw NSError(domain: "RealtimeAVService", code: -20,
                                  userInfo: [NSLocalizedDescriptionKey: "阿杜三段实时语音 session 创建失败"])
                }

                // ✅ 协议防污染：openai 路径绝不接受 vllm_omni_realtime / RunPod ws_url。
                let proto = (dict["protocol"] as? String)?.lowercased() ?? ""
                if proto == "vllm_omni_realtime" || urlStr.contains("proxy.runpod.net") {
                    print("[AduThreeStageRealtime] REJECT polluted session protocol=\(proto) rtc_url=\(urlStr)")
                    throw NSError(domain: "RealtimeAVService", code: -21,
                                  userInfo: [NSLocalizedDescriptionKey: "阿杜三段实时语音 session 创建失败"])
                }

                let key = (dict["ephemeral_key"] as? String)
                    ?? (dict["client_secret"] as? String)
                    ?? (dict["client_secret_value"] as? String)
                    ?? ((dict["client_secret"] as? [String: Any])?["value"] as? String)

                guard let ephemeral = key, !ephemeral.isEmpty else {
                    print("[AduThreeStageRealtime] session missing ephemeral key / client_secret")
                    throw NSError(domain: "RealtimeAVService", code: -22,
                                  userInfo: [NSLocalizedDescriptionKey: "阿杜三段实时语音 session 创建失败"])
                }

                // 验收日志：session 已就绪。key 只打长度，不打值。
                let actualProvider = (dict["provider_actual"] as? String) ?? "unknown"
                print("[AduThreeStageRealtime] session received provider=openai-compatible actual=\(actualProvider) protocol=\(proto.isEmpty ? "(legacy)" : proto) model=\((dict["model"] as? String) ?? "?") want_video=\(String(describing: dict["want_video"] ?? "n/a"))")
                print("[AduThreeStageRealtime] rtc_url=\(urlStr)")
                print("[AduThreeStageRealtime] ephemeral key received len=\(ephemeral.count)")

                let serverInstr = dict["instructions"] as? String
                let serverVoice = dict["voice"] as? String
                let info = SessionInfo(
                    provider: .openai,
                    rtcURL: url,
                    ephemeralKey: ephemeral,
                    iceServers: [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])],
                    wsURL: nil,
                    apiKey: nil,
                    pcm24ToPcm16Required: false,
                    serverInstructions: serverInstr,
                    serverVoice: serverVoice,
                    serverConversationId: dict["conversation_id"] as? String,
                    serverTurnDetection: dict["turn_detection"] as? [String: Any]
                    )
                    completion(.success(info))
            } catch {
                let body = String(data: data, encoding: .utf8) ?? ""
                print("[AduThreeStageRealtime] session parse/validation failed error=\(error.localizedDescription) body=\(body.prefix(1200))")
                completion(.failure(error))
            }
        }.resume()
    }
}


private extension String {
    func dropLeadingWhitespaceButKeepNewline() -> String {
        var idx = startIndex
        while idx < endIndex {
            let ch = self[idx]
            if ch == " " || ch == "\t" {
                idx = index(after: idx)
            } else {
                break
            }
        }
        return String(self[idx...])
    }
}

extension RealtimeAVService: RTCPeerConnectionDelegate, RTCDataChannelDelegate {

    private func setupPeerConnection() throws {
        let config = RTCConfiguration()
        config.iceServers = iceServers
        config.sdpSemantics = .unifiedPlan
        config.iceCandidatePoolSize = 1

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                "OfferToReceiveVideo": "false"
            ],
            optionalConstraints: nil
        )

        let pc = factory.peerConnection(with: config, constraints: constraints, delegate: self)
        peerConnection = pc
        print("[OpenAIRealtime] peer connection created")

        let audioConstraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: [
                "googEchoCancellation": "true",
                "googAutoGainControl": "true",
                "googNoiseSuppression": "true"
            ]
        )
        let audioSource = factory.audioSource(with: audioConstraints)
        let track = factory.audioTrack(with: audioSource, trackId: "local_audio")
        localAudioTrack = track
        pc.add(track, streamIds: ["local_stream"])
        print("[OpenAIRealtime] local audio track added")

        if callMode == .audioVideo {
            // ✅ 6.2 Pro：摄像头权限明确检查，失败给真实错误而不是笼统"网络问题"。
            let camAuth = AVCaptureDevice.authorizationStatus(for: .video)
            if camAuth == .denied || camAuth == .restricted {
                print("[OpenAIRealtime] camera permission DENIED status=\(camAuth.rawValue)")
                DispatchQueue.main.async {
                    self.delegate?.realtimeAVService(self, didUpdateStatus: "摄像头权限未开启")
                    self.delegate?.realtimeAVService(self, didFail: NSError(
                        domain: "RealtimeAVService", code: -12,
                        userInfo: [NSLocalizedDescriptionKey: "摄像头权限未开启"]))
                }
                // 摄像头失败不终止音频通话：继续以纯音频跑完连接。
            } else {
                let videoSource = factory.videoSource()
                let capturer = RTCCameraVideoCapturer(delegate: videoSource)
                let videoTrack = factory.videoTrack(with: videoSource, trackId: "local_video")
                localVideoCapturer = capturer
                localVideoTrack = videoTrack
                pc.add(videoTrack, streamIds: ["local_stream"])
                print("[OpenAIRealtime] local video track added")
                startLocalCameraCapture(capturer)
            }
        }

        let dcConfig = RTCDataChannelConfiguration()
        dcConfig.isOrdered = true
        let dc = pc.dataChannel(forLabel: "oai-events", configuration: dcConfig)
        dc?.delegate = self
        dataChannel = dc
    }

    private func startLocalCameraCapture(_ capturer: RTCCameraVideoCapturer) {
        guard let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == .front })
                ?? RTCCameraVideoCapturer.captureDevices().first else {
            print("[OpenAIRealtime] camera start FAILED: no capture device")
            DispatchQueue.main.async {
                self.delegate?.realtimeAVService(self, didUpdateStatus: "摄像头不可用")
            }
            return
        }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        guard let format = formats.max(by: {
            let a = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            let b = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
            return (a.width * a.height) < (b.width * b.height)
        }) else {
            print("[OpenAIRealtime] camera start FAILED: no supported format")
            return
        }
        let fps = (format.videoSupportedFrameRateRanges.first?.maxFrameRate).map { min(Int($0), 30) } ?? 24
        capturer.startCapture(with: device, format: format, fps: fps)
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        print("[OpenAIRealtime] camera started device=\(device.localizedName) \(dims.width)x\(dims.height)@\(fps)fps")
    }

    private func negotiate(callId: UUID, completion: @escaping (Error?) -> Void) {
        guard let pc = peerConnection, let rtcURL, let key = ephemeralKey else {
            completion(NSError(domain: "RealtimeAVService", code: -1,
                               userInfo: [NSLocalizedDescriptionKey: "缺少 rtcURL / ephemeralKey / peerConnection"]))
            return
        }

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                "OfferToReceiveVideo": "false"
            ],
            optionalConstraints: ["voiceActivityDetection": "true"]
        )

        pc.offer(for: constraints) { [weak self] sdp, err in
            guard let self else { return }
            self.workQueue.async {
                guard callId == self.currentCallId else { return }
                if let err {
                    completion(err)
                    return
                }
                guard let offer = sdp else {
                    completion(NSError(domain: "RealtimeAVService", code: -1,
                                       userInfo: [NSLocalizedDescriptionKey: "createOffer 返回空"]))
                    return
                }

                pc.setLocalDescription(offer) { [weak self] err in
                    guard let self else { return }
                    self.workQueue.async {
                        guard callId == self.currentCallId else { return }
                        if let err {
                            completion(err)
                            return
                        }

                        let offerBody = pc.localDescription?.sdp ?? offer.sdp
                        print("[OpenAIRealtime] SDP offer bytes=\(offerBody.utf8.count) url=\(rtcURL.absoluteString)")

                        var req = URLRequest(url: rtcURL)
                        req.httpMethod = "POST"
                        req.timeoutInterval = 20
                        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                        req.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
                        req.setValue("application/sdp", forHTTPHeaderField: "Accept")
                        req.httpBody = offerBody.data(using: .utf8)

                        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
                            guard let self else { return }
                            self.workQueue.async {
                                guard callId == self.currentCallId else { return }
                                if let err {
                                    print("[OpenAIRealtime] SDP exchange network failed: \(err.localizedDescription)")
                                    completion(err)
                                    return
                                }

                                let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
                                let contentType = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "-"
                                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                                let preview = String(body
                                    .replacingOccurrences(of: "\r", with: "\\r")
                                    .replacingOccurrences(of: "\n", with: "\\n")
                                    .prefix(800))

                                guard (200..<300).contains(status), !body.isEmpty else {
                                    print("[OpenAIRealtime] SDP exchange HTTP failed status=\(status) contentType=\(contentType) body=\(preview)")
                                    completion(NSError(domain: "RealtimeAVService", code: status,
                                                       userInfo: [NSLocalizedDescriptionKey: "SDP 交换失败 HTTP \(status): \(preview)"]))
                                    return
                                }

                                let answerSDP = body.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard answerSDP.hasPrefix("v=0") else {
                                    print("[OpenAIRealtime] SDP exchange invalid answer status=\(status) contentType=\(contentType) body=\(preview)")
                                    completion(NSError(domain: "RealtimeAVService", code: status,
                                                       userInfo: [NSLocalizedDescriptionKey: "SDP answer 非法: \(preview)"]))
                                    return
                                }

                                print("[OpenAIRealtime] SDP answer received status=\(status) contentType=\(contentType) bytes=\(answerSDP.utf8.count)")
                                // libwebrtc 的 SDP 解析器要求最后一行必须以换行结尾；上面 trim 掉了，这里补回。
                                pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: answerSDP + "\r\n")) { err in
                                    self.workQueue.async {
                                        guard callId == self.currentCallId else { return }
                                        if let err {
                                            let answerPreview = String(answerSDP
                                                .replacingOccurrences(of: "\r", with: "\\r")
                                                .replacingOccurrences(of: "\n", with: "\\n")
                                                .prefix(220))
                                            print("[OpenAIRealtime] setRemoteDescription FAILED: \(err.localizedDescription) answer=\(answerPreview)")
                                        }
                                        completion(err)
                                    }
                                }
                            }
                        }.resume()
                    }
                }
            }
        }
    }

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        workQueue.async { [weak self] in
            guard let self else { return }
            if dataChannel.readyState == .open {
                print("[OpenAIRealtime] data channel open")
                self.sendSessionUpdateIfNeeded()
                self.flushQueuedEventsIfAny()
                self.restartImageTickTimerIfNeeded()
                if self.activeProvider == .openai { self.frontBargeStartTap() }
            } else if dataChannel.readyState == .closed, self.activeProvider == .openai, self.isRunning {
                print("[OpenAIRealtime] data channel CLOSED mid-call")
                DispatchQueue.main.async {
                    self.delegate?.realtimeAVService(self, didUpdateStatus: "DataChannel 未打开")
                }
            }
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard !buffer.isBinary else { return }
        guard let text = String(data: buffer.data, encoding: .utf8) else { return }
        workQueue.async { [weak self] in
            self?.handleServerEvent(text)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        if !stream.audioTracks.isEmpty {
            print("[OpenAIRealtime] remote audio track received (stream, tracks=\(stream.audioTracks.count))")
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        if rtpReceiver.track?.kind == "audio" {
            print("[OpenAIRealtime] remote audio track received")
            frontBargeRemoteTrack = rtpReceiver.track as? RTCAudioTrack
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove rtpReceiver: RTCRtpReceiver) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        print("[OpenAIRealtime] ice state=\(newState.rawValue) (0new 1checking 2connected 3completed 4failed 5disconnected 6closed)")
        if newState == .failed || newState == .disconnected {
            workQueue.async { [weak self] in
                guard let self else { return }
                if self.isRunning || self.isConnecting {
                    self.hardReset(notify: true)
                    DispatchQueue.main.async {
                        self.delegate?.realtimeAVService(self, didUpdateStatus: newState == .failed ? "WebRTC 连接失败" : "网络不稳定，已断开")
                    }
                }
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.dataChannel = dataChannel
            dataChannel.delegate = self
            self.sendSessionUpdateIfNeeded()
            self.flushQueuedEventsIfAny()
            self.restartImageTickTimerIfNeeded()
        }
    }
}

extension RealtimeAVService {

    private func sendSessionUpdateIfNeeded() {
        guard !hasSentSessionUpdate else { return }
        hasSentSessionUpdate = true
        sendSessionUpdate()
    }

    private func sendSessionUpdate() {
        switch activeProvider {
        case .pipeline:
            sendClientEvent([
                "type": "session.update",
                "session": [
                    "modalities": ["audio", "text"],
                    "voice": "Cherry"
                ]
            ])

        case .qwen:
            // ✅ 自部署 vLLM-Omni（qwen_selfhost）官方 realtime 协议：session.update 只发顶层 model，
            //    不发 OpenAI/阿里 的 session{} 包裹（已用 Mac probe 验证：不再报 Missing required field: model，
            //    也不发 conversation.item.create / response.create）。
            if isSelfhostQwen {
                // 规格 §2：model 必须在顶层；session{} 携带 modalities/voice/instructions。
                let shVoice = voiceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "chelsie" : voiceName
                var shSession: [String: Any] = [
                    "modalities": ["text", "audio"],
                    "voice": shVoice
                ]
                let shDefaultInstr =
                    "你是 ChatAGI 阿杜的本地机器人智能大脑。用户说中文你必须中文回答。" +
                    "回答简短自然，适合语音播放。不要说你来自阿里、通义、Qwen 或通义千问。" +
                    "没听清时只说：我没听清，你再说一遍。"
                if let ovr = instructionsOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !ovr.isEmpty {
                    shSession["instructions"] = ovr
                } else if let srv = serverInstructions?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !srv.isEmpty {
                    // 后端注入的完整 instructions（身份+记忆+感知）
                    shSession["instructions"] = srv
                } else {
                    shSession["instructions"] = shDefaultInstr
                }
                sendClientEvent([
                    "type": "session.update",
                    "model": qwenSelfhostModel,
                    "session": shSession
                ])
                print("[QwenSelfhostRT] session.update sent model=\(qwenSelfhostModel) voice=\(shVoice)")
                shSetState("listening")
                return
            }
            // ✅ 阿里 Qwen-Omni-Realtime 官方 client-events 协议，turn_detection 只接受
            //   type / threshold / silence_duration_ms 三个字段。
            //   - type 必须是 "server_vad"（文档原文："Always server_vad"）。
            //   - prefix_padding_ms / create_response / interrupt_response 是 OpenAI Realtime
            //     的扩展字段，Qwen 服务端会静默忽略，导致以为开了 interrupt_response 实际没生效。
            // semantic_vad 是 Qwen3.5 模型层的"避免附和声打断"能力，不是 turn_detection.type
            // 的取值。打断的真正实现路径是：服务端发 speech_started → 客户端清播放队列 + 发
            // response.cancel + 用 userIsSpeaking gate 丢弃后续 audio.delta。
            let defaultQwenTurnDetection: [String: Any] = [
                "type": "server_vad",
                "threshold": 0.5,
                "silence_duration_ms": 800
            ]

            var sessionDict: [String: Any] = [
                "modalities": ["text", "audio"],
                "voice": voiceName,
                // ✅ 阿里官方当前仅支持 pcm；不要发 OpenAI 的 pcm16 字符串。
                "input_audio_format": "pcm",
                "output_audio_format": "pcm",
                // ✅ 阿里官方文档明确："The model for transcribing input audio. Only
                // gummy-realtime-v1 is supported."  qwen3-asr-flash-realtime 是独立的
                // 实时 ASR 模型，不能放在 omni-realtime 的 transcription 字段下。
                "input_audio_transcription": ["model": "gummy-realtime-v1"],
                "turn_detection": serverTurnDetection ?? defaultQwenTurnDetection
            ]

            // ✅ 自部署 vLLM-Omni 不支持 DashScope 专属的 gummy-realtime-v1 转写字段，
            //    下发可能被服务端拒绝；其余字段保持与阿里 Qwen 路径一致。
            if isSelfhostQwen {
                sessionDict.removeValue(forKey: "input_audio_transcription")
            }

            // ✅ qwen-omni-turbo-realtime 系列文档明确不支持修改 temperature/top_p/
            // repetition_penalty/presence_penalty/seed/max_tokens；带上会被服务端拒绝或
            // 抛 error。只在 qwen3-omni-flash-realtime / qwen3.5-omni-*-realtime 上下发。
            // 通过 wsURL 的 ?model=... query 判断模型。
            let modelHint: String = {
                guard let url = qwenWSTask?.originalRequest?.url
                        ?? (qwenWSTask?.currentRequest?.url) else { return "" }
                let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
                return (comps?.queryItems?.first(where: { $0.name == "model" })?.value ?? "").lowercased()
            }()
            let supportsSamplingOverrides = !modelHint.contains("turbo") && !isSelfhostQwen
            if supportsSamplingOverrides {
                sessionDict["temperature"] = 0.8
                sessionDict["top_p"] = 1.0
                sessionDict["repetition_penalty"] = 1.05
            }

            if let override = instructionsOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
               !override.isEmpty {
                sessionDict["instructions"] = override
            } else if let srv = serverInstructions?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !srv.isEmpty {
                // ✅ 使用后端注入的完整 instructions（含长期记忆+感知+联网+agent提示）
                sessionDict["instructions"] = srv
            } else {
                sessionDict["instructions"] = "你是ChatAGI-阿杜，一个智能语音助手。用简洁自然的口语化中文回答。"
            }

            sendClientEvent([
                "type": "session.update",
                "session": sessionDict
            ])

        case .minicpm:
            // ✅ ChatAGI Native Realtime：session.update 只发 instructions（无 model/voice/turn_detection）。
            let mcpInstr: String = {
                if let ovr = instructionsOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !ovr.isEmpty {
                    return ovr
                }
                if let srv = (minicpmInstructions ?? serverInstructions)?.trimmingCharacters(in: .whitespacesAndNewlines), !srv.isEmpty {
                    return srv
                }
                return "你是 ChatAGI 阿杜实时语音模型，请用自然、简洁的中文回答。"
            }()
            sendClientEvent([
                "type": "session.update",
                "session": [
                    "instructions": mcpInstr,
                    "provider": AppConfig.Realtime.chatAGINativeProvider,
                    "model_display": AppConfig.Realtime.chatAGINativeModelDisplay,
                    "title": AppConfig.Realtime.chatAGINativeTitle,
                    "protocol": AppConfig.Realtime.chatAGINativeProtocol
                ]
            ])
            print("[ChatAGINativeRealtime] session.update sent provider=\(AppConfig.Realtime.chatAGINativeProvider) protocol=\(AppConfig.Realtime.chatAGINativeProtocol)")

        case .openai:
            let openAIVoice = voiceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? AppConfig.Realtime.defaultVoice : voiceName.lowercased()
            let turnDetection = serverTurnDetection ?? [
                "type": "semantic_vad",
                "eagerness": "medium",
                "create_response": true,
                "interrupt_response": true
            ] as [String: Any]
            var sessionDict: [String: Any] = [
                "type": "realtime",
                "modalities": ["audio", "text"],
                "voice": openAIVoice,
                "audio": [
                    "output": ["voice": openAIVoice],
                    "input": ["turn_detection": turnDetection]
                ] as [String: Any],
                "turn_detection": turnDetection,
                "tools": [
                    [
                        "type": "function",
                        "name": "semantic_interrupt",
                        "description": "当且仅当用户在你回答过程中明确表达打断、否定、纠正、改口、换话题或停止本轮回答时调用。普通附和如嗯、对、继续、然后呢不要调用。调用后停止上一轮未输出内容，并基于用户新语句继续回答。",
                        "parameters": [
                            "type": "object",
                            "properties": [
                                "reason": ["type": "string", "description": "触发原因，如 user_correction / user_stop / topic_shift"],
                                "new_user_text": ["type": "string", "description": "用户新的语义内容，尽量原文"],
                                "confidence": ["type": "number", "description": "0 到 1 的判断置信度"]
                            ]
                        ]
                    ] as [String: Any],
                    [
                        "type": "function",
                        "name": "search_memory",
                        "description": "查询用户长期记忆、事实、偏好、项目上下文和历史事件。用户问到历史信息、个人信息、之前说过的事时主动调用。",
                        "parameters": [
                            "type": "object",
                            "properties": [
                                "query": ["type": "string", "description": "搜索关键词"],
                                "top_k": ["type": "integer", "description": "返回条数，默认5"],
                                "scope": ["type": "string", "enum": ["facts", "timeline", "hybrid"], "description": "搜索范围"]
                            ],
                            "required": ["query"]
                        ]
                    ] as [String: Any],
                    [
                        "type": "function",
                        "name": "adu_agent_exec",
                        "description": "控制用户的笔记本电脑执行操作。用户说'编译项目'、'查看文件'、'打开应用'、'执行命令'、'帮我安装'等时调用。",
                        "parameters": [
                            "type": "object",
                            "properties": [
                                "action": ["type": "string", "description": "要执行的操作，用中文描述，例如：编译GPT Solara项目、查看桌面文件列表、打开Safari"]
                            ],
                            "required": ["action"]
                        ]
                    ] as [String: Any],

                    // ────────── 屏幕共享接入(让 AI 看到 Mac 屏幕) ──────────
                    [
                        "type": "function",
                        "name": "mac_screen_attach",
                        "description": "用户说\"看我电脑\"、\"接入电脑\"、\"看我的Mac\"、\"打开屏幕共享\"、\"我要让你看着我操作\"等意图时调用。会自动把用户的 Mac 屏幕接入到这个对话,你之后每秒都能收到一帧屏幕画面,可以基于看到的内容帮用户操作。需要用户的 Mac 上 adu-bridge 在运行。",
                        "parameters": [
                            "type": "object",
                            "properties": [:]
                        ]
                    ] as [String: Any],
                    [
                        "type": "function",
                        "name": "mac_screen_detach",
                        "description": "用户说\"不看了\"、\"断开电脑\"、\"我自己来\"、\"关闭屏幕共享\"等意图时调用,断开 Mac 屏幕共享。",
                        "parameters": [
                            "type": "object",
                            "properties": [:]
                        ]
                    ] as [String: Any],

                    // ────────── 看屏幕后的物理控制工具 ──────────
                    [
                        "type": "function",
                        "name": "mac_click",
                        "description": "在 Mac 屏幕指定坐标点击。从看到的屏幕图像中读出按钮/图标位置,直接传 x,y 像素。坐标系:左上角 (0,0),屏幕宽度 1280。",
                        "parameters": [
                            "type": "object",
                            "properties": [
                                "x": ["type": "integer"],
                                "y": ["type": "integer"],
                                "button": ["type": "string", "enum": ["left", "right"]],
                                "double": ["type": "boolean"]
                            ],
                            "required": ["x", "y"]
                        ]
                    ] as [String: Any],
                    [
                        "type": "function",
                        "name": "mac_key",
                        "description": "按 Mac 快捷键。例: cmd-f, cmd-v, enter, esc, cmd-tab, cmd-space(Spotlight), cmd-l(地址栏)。",
                        "parameters": [
                            "type": "object",
                            "properties": [
                                "name": ["type": "string"]
                            ],
                            "required": ["name"]
                        ]
                    ] as [String: Any],
                    [
                        "type": "function",
                        "name": "mac_paste",
                        "description": "把文本写入 Mac 剪贴板并自动 Cmd+V 粘贴。输入中文必须用这个。",
                        "parameters": [
                            "type": "object",
                            "properties": [
                                "text": ["type": "string"]
                            ],
                            "required": ["text"]
                        ]
                    ] as [String: Any],
                    [
                        "type": "function",
                        "name": "mac_scroll",
                        "description": "Mac 滚动鼠标滚轮。dy 负值向下滚。",
                        "parameters": [
                            "type": "object",
                            "properties": [
                                "dy": ["type": "integer"],
                                "dx": ["type": "integer"]
                            ],
                            "required": ["dy"]
                        ]
                    ] as [String: Any],

                    [
                        "type": "function",
                        "name": "mac_drag",
                        "description": "在 Mac 屏幕上拖拽鼠标。从 (x1,y1) 拖到 (x2,y2)。用于拖动窗口、拖文件、框选区域、拖进度条等。",
                        "parameters": [
                            "type": "object",
                            "properties": [
                                "x1": ["type": "integer"],
                                "y1": ["type": "integer"],
                                "x2": ["type": "integer"],
                                "y2": ["type": "integer"]
                            ],
                            "required": ["x1", "y1", "x2", "y2"]
                        ]
                    ] as [String: Any],

                    // ────────── 万能钥匙:任意 zsh shell 命令 ──────────
                    [
                        "type": "function",
                        "name": "mac_shell",
                        "description": "在用户的 Mac 上执行 zsh shell 命令。用于:文件操作(ls/find/cp/mv/cat)、Git、Python、curl、xcodebuild 编译、读取文本文件等。例:ls ~/Desktop | head、git -C ~/Desktop/backend status、python3 script.py。需要 Mac 屏幕共享已接入(mac_screen_attach)。",
                        "parameters": [
                            "type": "object",
                            "properties": [
                                "command": ["type": "string", "description": "完整 shell 命令"]
                            ],
                            "required": ["command"]
                        ]
                    ] as [String: Any],

                    // ────────── 万能钥匙:任意 AppleScript ──────────
                    [
                        "type": "function",
                        "name": "mac_applescript",
                        "description": "在用户的 Mac 上执行 AppleScript,控制任何 Mac 应用(Safari/Mail/日历/Spotify/Finder/系统设置/微信等)。⚠️ 中文输入禁止用 keystroke,改用 mac_paste。例: tell application \"Safari\" to open location \"https://github.com\"。需要 Mac 屏幕共享已接入。",
                        "parameters": [
                            "type": "object",
                            "properties": [
                                "script": ["type": "string", "description": "完整 AppleScript 代码"]
                            ],
                            "required": ["script"]
                        ]
                    ] as [String: Any],

                    // ════════════════════════════════════════════════════
                    // 🆕 主动视觉(AI 自己决定何时看屏幕,默认不推流省钱)
                    // ════════════════════════════════════════════════════
                    [
                        "type": "function",
                        "name": "mac_screen_glance",
                        "description": "主动看一眼用户 Mac 当前屏幕。用于:执行了一步操作后确认效果、需要看清当前界面状态、拿不准下一步怎么做。调用后 0.5-1 秒内你会收到最新屏幕画面。省钱原则:能推断的不看;连续可预期的动作不用每步都看;关键节点看一下即可。注意:glance 只是看,不是完成任务。看完后应继续调用 mac_click_by_title / mac_click / mac_key / mac_paste / mac_shell 等工具推进任务。",
                        "parameters": ["type": "object", "properties": [:]]
                    ] as [String: Any],
                    [
                        "type": "function",
                        "name": "mac_screen_watch",
                        "description": "开启持续屏幕监控。用于:等待加载完成、看视频、监控长时间任务、需要连续感知屏幕变化。默认 1 fps。开启后请记得 mac_screen_pause 节省资源。",
                        "parameters": [
                            "type": "object",
                            "properties": [
                                "fps": ["type": "number", "description": "每秒帧数。0.5=慢,1.0=标准,2.0=快。默认 1.0"]
                            ]
                        ]
                    ] as [String: Any],
                    [
                        "type": "function",
                        "name": "mac_screen_pause",
                        "description": "停止屏幕监控,回到不推流状态。任务完成、切到纯对话、不再需要看屏幕时调用,节省 token 和带宽。",
                        "parameters": ["type": "object", "properties": [:]]
                    ] as [String: Any],

                    // ════════════════════════════════════════════════════
                    // 🆕 macOS Accessibility API(苹果系统级,99% 准确)
                    // ════════════════════════════════════════════════════
                    [
                        "type": "function",
                        "name": "mac_click_by_title",
                        "description": "⭐ 最推荐:直接按元素文字点击,不需要先看屏幕找坐标。系统通过 Accessibility API 定位按钮/联系人/菜单项/链接,精度 99%、延迟 50ms、零 token 成本。例:用户说'点登录' → mac_click_by_title('登录'),必中。给信玉发消息时切到微信后 → mac_click_by_title('信玉')。优先级:凡是有明确文字标签的元素,都用这个,不要用 mac_click。",
                        "parameters": [
                            "type": "object",
                            "properties": [
                                "title": ["type": "string", "description": "要点击的元素文字(完整或部分匹配)。例:'登录'、'信玉'、'发送'、'确定'"],
                                "double": ["type": "boolean", "description": "是否双击,默认 false"]
                            ],
                            "required": ["title"]
                        ]
                    ] as [String: Any],
                    [
                        "type": "function",
                        "name": "mac_ax_tree",
                        "description": "读取当前最前台 App 的 UI 元素树(按钮/输入框/列表项的精确坐标和标题)。比纯视觉 glance 快 30 倍、准 40%。适用:点按钮、填表单、点列表项等需要精确定位的场景。",
                        "parameters": [
                            "type": "object",
                            "properties": [
                                "max_depth": ["type": "integer", "description": "递归深度,默认 8。简单界面 5,复杂 10"]
                            ]
                        ]
                    ] as [String: Any]
                ],
                "tool_choice": "auto"
            ]

            // ✅ GPT Realtime 接入后端完整 instructions（人格/记忆/感知）
            if let override = instructionsOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
               !override.isEmpty {
                sessionDict["instructions"] = override
            } else if let srv = serverInstructions?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !srv.isEmpty {
                sessionDict["instructions"] = srv
            } else {
                sessionDict["instructions"] = "你是ChatAGI-阿杜，一个智能语音助手。用简洁自然的口语化中文回答。直接回答，不废话。"
            }

            sendClientEvent([
                "type": "session.update",
                "session": sessionDict
            ])
        }
    }


    private func sendClientEvent(_ event: [String: Any], droppable: Bool = false) {
        // ✅ 自部署 vLLM-Omni（qwen_selfhost）官方协议：绝不发送 OpenAI GPT Realtime 的对话事件。
        //    打断在客户端本地完成（停播 + 清队列 + userIsSpeaking gate），不发服务端 response.cancel。
        if isSelfhostQwen, let t = event["type"] as? String,
           t == "response.create" || t == "conversation.item.create" || t == "response.cancel" {
            print("[QwenSelfhostRT] suppress \(t) (vLLM-Omni protocol, not OpenAI GPT Realtime)")
            return
        }

        var eventToSend = event
        if eventToSend["event_id"] == nil {
            eventToSend["event_id"] = "event_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        }

        if let type = eventToSend["type"] as? String,
           type == "response.cancel" || type == "response.create" || type == "input_audio_buffer.commit" || type == "session.update" {
            semanticDiag("send_event type=\(type) droppable=\(droppable)")
        }
        if isWebSocketProvider {
            guard let ws = qwenWSTask else {
                if !droppable { queuedClientEvents.append(eventToSend) }
                return
            }
            do {
                let data = try JSONSerialization.data(withJSONObject: eventToSend, options: [])
                let str = String(data: data, encoding: .utf8) ?? ""
                qwenLastClientSendAt = Date()
                let callId = currentCallId
                ws.send(.string(str)) { [weak self] error in
                    guard let self, let error else { return }
                    self.workQueue.async {
                        guard callId == self.currentCallId, self.qwenIsReceivingMessages else { return }
                        self.semanticDiag("qwen_send_failed type=\((eventToSend["type"] as? String) ?? "") error=\(error.localizedDescription)")
                        self.failAndReset(callId: callId, status: "语音通话暂时连接失败", error: Self.userFacingError())
                    }
                }
            } catch {
                semanticDiag("send_event_json_encode_failed error=\(error.localizedDescription)")
            }
            return
        }

        guard let dc = dataChannel, dc.readyState == .open else {
            if !droppable { queuedClientEvents.append(eventToSend) }
            return
        }
        if let data = try? JSONSerialization.data(withJSONObject: eventToSend, options: []) {
            dc.sendData(RTCDataBuffer(data: data, isBinary: false))
        }
    }

    private func flushQueuedEventsIfAny() {
        guard !queuedClientEvents.isEmpty else { return }
        let pending = queuedClientEvents
        queuedClientEvents.removeAll()
        for ev in pending { sendClientEvent(ev) }
    }

    private func markAssistantNewTurn() {
        assistantBuffer = ""
        assistantFlushWorkItem?.cancel()
        assistantFlushWorkItem = nil
        resetSemanticInterruptParser()
    }

    private func resetSemanticInterruptParser() {
        semanticInterruptProbe = ""
        semanticInterruptDroppingControlLine = false
        semanticInterruptTriggeredForResponse = false
    }

    /// ✅ 拦截模型输出的语义打断控制符。
    /// - 控制符不能展示、不能播报、不能写入历史。
    /// - 收到后立即清掉旧播放缓冲/旧 partial，并通知 UI 冻结旧 assistant 气泡。
    /// - 不取消当前 response：当前 response 已经是"新用户插话"后的回答，取消会把新回答也切掉。
    private func filterSemanticInterruptControl(from delta: String) -> String {
        guard !delta.isEmpty else { return "" }

        if semanticInterruptDroppingControlLine {
            if let nl = delta.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                semanticInterruptDroppingControlLine = false
                let rest = String(delta[delta.index(after: nl)...])
                return rest.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return ""
        }

        // 只在一轮回答刚开始时探测，避免普通正文中偶然出现类似字符串造成误杀。
        guard assistantBuffer.isEmpty || !semanticInterruptProbe.isEmpty else {
            return semanticInterruptTriggeredForResponse ? stripSemanticInterruptFragments(from: delta) : delta
        }

        // ✅ 兜底防御：Qwen 是端到端语音模型，可能把后端注入的语义打断协议
        // (__SEMANTIC_INTERRUPT__{...}) 中的下划线 token 在 ASR 转写时丢失，
        // 导致前端拿到的 transcript 只剩裸 JSON 片段，例如：
        //   {"reason":"user_correction","mode":"replace_current_turn"}
        // 后端 _augment_realtime_instructions 已按 provider 分流（Qwen/pipeline 不再
        // 注入这套协议），但保留这道前端兜底处理三种残留情况：
        //   1) 旧客户端连接已合并、新客户端连未合并的后端
        //   2) 调用方传入的 instructionsOverride 自带语义打断协议
        //   3) 模型推理时偶发把控制符 hallucinate 成正文
        // 检测条件：buffer 仍为空（一轮回答的首个 delta），且文本以 {"reason"
        // 或 {"mode" 开头——这两个键就是后端协议里固定的字段。
        let combinedRaw = semanticInterruptProbe + delta
        let probeStripped = combinedRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        if assistantBuffer.isEmpty,
           probeStripped.hasPrefix("{\"reason\"") || probeStripped.hasPrefix("{\"mode\"") {
            if let end = Self.endIndexOfFirstJSONObject(in: probeStripped) {
                semanticInterruptProbe = ""
                semanticInterruptTriggeredForResponse = true
                semanticDiag("BARE_JSON_INTERRUPT_FRAGMENT_DROPPED head=\(String(probeStripped.prefix(80)))")
                let after = String(probeStripped[probeStripped.index(after: end)...])
                let visible = after.trimmingCharacters(in: .whitespacesAndNewlines)
                // 不触发 performSemanticInterruptSideEffects——裸 JSON 已经是滞后产物，
                // 真正的打断早就由 server_vad+gate 完成了；这里只做"擦掉残留"。
                return visible
            }
            // JSON 还没到全：把它存到 probe 里，等后续 delta 补齐。
            semanticInterruptProbe = combinedRaw
            return ""
        }

        let combined = semanticInterruptProbe + delta
        if combined.contains(semanticInterruptToken) {
            semanticInterruptProbe = ""
            semanticInterruptTriggeredForResponse = true
            performSemanticInterruptSideEffects(rawControlText: combined)
            return visibleTextAfterSemanticInterruptControl(in: combined)
        }

        if semanticInterruptToken.hasPrefix(combined) {
            semanticInterruptProbe = combined
            return ""
        }

        semanticInterruptProbe = ""
        return combined
    }

    private func stripSemanticInterruptFragments(from text: String) -> String {
        guard text.contains(semanticInterruptToken) else { return text }
        return visibleTextAfterSemanticInterruptControl(in: text)
    }

    private func visibleTextAfterSemanticInterruptControl(in text: String) -> String {
        guard let r = text.range(of: semanticInterruptToken) else { return text }
        var rest = String(text[r.upperBound...]).dropLeadingWhitespaceButKeepNewline()

        // 支持：__SEMANTIC_INTERRUPT__{"reason":"..."}
        if rest.first == "{" {
            if let end = Self.endIndexOfFirstJSONObject(in: rest) {
                rest = String(rest[rest.index(after: end)...])
            } else {
                semanticInterruptDroppingControlLine = true
                return ""
            }
        }

        // 支持控制符单独一行：丢掉该行，只放行下一行开始的新回答。
        if let nl = rest.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            rest = String(rest[rest.index(after: nl)...])
            return rest.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 没有换行时，认为本 delta 仍是控制行，继续吞掉，直到下一次看到换行。
        if rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ""
        }
        semanticInterruptDroppingControlLine = true
        return ""
    }

    private func performSemanticInterruptSideEffects(rawControlText: String) {
        semanticDiag("SEMANTIC_CONTROL_TRIGGERED raw=\(String(rawControlText.prefix(160)))")
        assistantFlushWorkItem?.cancel()
        assistantFlushWorkItem = nil
        assistantBuffer = ""
        pendingCreateAfterCancel = nil
        stopRollback()
        clearPlaybackBuffer(enterTailHold: false)
        pipelinePlaybackActive = false
        qwenPlaybackLikelyActive = false
        qwenPlaybackGateHoldUntil = nil

        notifyBackendSemanticInterrupt(rawControlText: rawControlText)

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .aduRealtimeSemanticInterrupt,
                object: nil,
                userInfo: ["token": self.semanticInterruptToken]
            )
            self.delegate?.realtimeAVService(self, didUpdateStatus: "已语义打断")
        }
    }

    private func notifyBackendSemanticInterrupt(rawControlText: String) {
        let base = apiBase.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty, let url = URL(string: base + "/realtime/semantic_interrupt") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 3
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "token": semanticInterruptToken,
            "client_id": sessionClientId,
            "conversation_id": sessionConversationId,
            "reason": "model_semantic_interrupt",
            "raw_control_preview": String(rawControlText.prefix(240))
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])
        semanticDiag("notify_backend_semantic_interrupt url=\(url.absoluteString)")
        URLSession.shared.dataTask(with: req) { [weak self] _, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            self?.workQueue.async { self?.semanticDiag("backend_semantic_interrupt_result code=\(code) err=\(err?.localizedDescription ?? "nil")") }
        }.resume()
    }

    private static func endIndexOfFirstJSONObject(in text: String) -> String.Index? {
        var depth = 0
        var inString = false
        var escaping = false
        var started = false

        for i in text.indices {
            let ch = text[i]
            if !started {
                if ch == "{" {
                    started = true
                    depth = 1
                }
                continue
            }

            if inString {
                if escaping {
                    escaping = false
                } else if ch == "\\" {
                    escaping = true
                } else if ch == "\"" {
                    inString = false
                }
                continue
            }

            if ch == "\"" {
                inString = true
            } else if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 { return i }
            }
        }
        return nil
    }

    private func cancelActiveResponse(reason: String) {
        guard isResponseInProgress, !isCancellingResponse else {
            semanticDiag("cancel_ignored reason=\(reason) isResponseInProgress=\(isResponseInProgress) isCancelling=\(isCancellingResponse)")
            return
        }
        semanticDiag("CANCEL_ACTIVE_RESPONSE reason=\(reason)")
        isCancellingResponse = true
        sendClientEvent(["type": "response.cancel"], droppable: true)
    }

    private func requestResponse(speak: Bool, aid: Int?) {
        if isCancellingResponse {
            semanticDiag("request_response_deferred_cancelling aid=\(aid.map(String.init) ?? "nil")")
            pendingCreateAfterCancel = (speak: speak, aid: aid)
            return
        }

        if isResponseInProgress {
            // ✅ 语义打断原则：普通用户开口/语句结束不能主动 cancel 旧回答。
            // 真正打断只能来自模型输出 __SEMANTIC_INTERRUPT__ 或 semantic_interrupt tool。
            semanticDiag("request_response_blocked_active_response_wait_semantic_control reason=no_active_cancel aid=\(aid.map(String.init) ?? "nil")")
            return
        }

        semanticDiag("request_response_create speak=\(speak) aid=\(aid.map(String.init) ?? "nil")")
        isResponseInProgress = true
        isCancellingResponse = false
        currentResponseId = nil
        resetPlaybackCompletionStateForNewResponse()
        rollbackPendingAID = aid ?? 0
        rollbackStartedAID = 0

        sendClientEvent([
            "type": "response.create",
            "response": [
                "modalities": speak ? ["audio", "text"] : ["text"]
            ]
        ])
        lastResponseRequestedAt = Date()
    }

    private func sendConversationTextItem(_ text: String) {
        sendClientEvent([
            "type": "conversation.item.create",
            "event_id": UUID().uuidString,
            "item": [
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": text]]
            ]
        ])
    }

    private func sendTaggedImageItem(tag: String, imageURL: String?, droppable: Bool) {
        if activeProvider == .qwen, let imageURL {
            // ✅ Qwen 用 input_image_buffer.append（官方格式）
            // 提取 base64 部分（去掉 "data:image/jpeg;base64," 前缀）
            let b64: String
            if let commaIdx = imageURL.firstIndex(of: ",") {
                b64 = String(imageURL[imageURL.index(after: commaIdx)...])
            } else {
                b64 = imageURL
            }
            sendClientEvent([
                "type": "input_image_buffer.append",
                "event_id": UUID().uuidString,
                "image": b64
            ], droppable: droppable)
            return
        }

        // GPT Realtime: 原格式 conversation.item.create + input_image
        var content: [[String: Any]] = [["type": "input_text", "text": tag]]
        if let imageURL {
            content.append(["type": "input_image", "image_url": imageURL])
        }

        sendClientEvent([
            "type": "conversation.item.create",
            "event_id": UUID().uuidString,
            "item": [
                "type": "message",
                "role": "user",
                "content": content
            ]
        ], droppable: droppable)
    }

    private func sendEndKeyframeH0(aid: Int) {
        guard callMode == .audioVideo else { return }
        guard imageStreamingEnabled else { return }
        if activeProvider == .qwen { guard qwenAudioStarted else { return } }
        guard let f = latestFrame() else { return }

        lastEndKeyframeTS = f.ts
        lastEndKeyframeAID = aid

        let tag = "[AID=\(aid) END] 关键帧H0（最新）。请先基于这张图立即回答；其他帧仅作辅助。不要复述标记。"
        let url = "data:\(f.mime);base64,\(f.data.base64EncodedString())"
        if activeProvider == .openai {
            print("[OpenAIRealtime] sendCameraFrameJPEG bytes=\(f.data.count) (keyframe H0 aid=\(aid))")
        }
        sendTaggedImageItem(tag: tag, imageURL: url, droppable: false)
    }
}

extension RealtimeAVService {

    private func restartImageTickTimerIfNeeded() {
        stopImageTickTimer()
        guard callMode == .audioVideo else { return }
        guard imageStreamingEnabled else { return }
        guard imageStreamingFPS > 0 else { return }

        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + 0.2, repeating: 0.2, leeway: .milliseconds(60))
        timer.setEventHandler { [weak self] in self?.maybeSendAuxImageTick() }
        timer.resume()
        imageTickTimer = timer
    }

    private func stopImageTickTimer() {
        imageTickTimer?.cancel()
        imageTickTimer = nil
    }

    private func maybeSendAuxImageTick() {
        guard callMode == .audioVideo else { return }
        guard imageStreamingEnabled else { return }
        if activeProvider == .qwen {
            // ✅ Qwen: 音频必须先启动，否则报错 "append image before append audio"
            guard qwenAudioStarted else { return }
        } else {
            // GPT: 回复期间不发辅助帧
            guard !isResponseInProgress else { return }
        }
        guard let frame = latestFrame() else { return }

        let now = CACurrentMediaTime()
        let minInterval = 1.0 / max(0.2, imageStreamingFPS)
        if now - lastAuxSentAt < minInterval { return }
        lastAuxSentAt = now

        let b64 = frame.data.base64EncodedString()
        if activeProvider == .qwen {
            // ✅ Qwen 辅助帧：input_image_buffer.append
            sendClientEvent([
                "type": "input_image_buffer.append",
                "event_id": UUID().uuidString,
                "image": b64
            ], droppable: true)
        } else {
            let url = "data:\(frame.mime);base64,\(b64)"
            print("[OpenAIRealtime] sendCameraFrameJPEG bytes=\(frame.data.count) (aux tick)")
            sendClientEvent([
                "type": "conversation.item.create",
                "event_id": UUID().uuidString,
                "item": [
                    "type": "message",
                    "role": "user",
                    "content": [["type": "input_image", "image_url": url]]
                ]
            ], droppable: true)
        }
    }
}

extension RealtimeAVService {

    private func maybeStartRollbackIfNeededOnFirstDelta() {
        guard callMode == .audioVideo else { return }
        guard maxRollbackFramesPerTurn > 0 else { return }

        let aid = rollbackPendingAID
        guard aid > 0 else { return }
        guard rollbackStartedAID != aid else { return }
        guard lastEndKeyframeAID == aid, lastEndKeyframeTS > 0 else { return }

        rollbackStartedAID = aid
        startRollbackFrames(aid: aid)
    }

    private func startRollbackFrames(aid: Int) {
        stopRollback()
        let candidates = frameHistory.filter { $0.ts > 0 && $0.ts < lastEndKeyframeTS }
        guard !candidates.isEmpty else { return }

        let take = min(maxRollbackFramesPerTurn, candidates.count)
        rollbackFrames = Array(candidates.suffix(take).reversed())
        rollbackCursor = 0

        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + rollbackFrameInterval,
                       repeating: rollbackFrameInterval,
                       leeway: .milliseconds(80))
        timer.setEventHandler { [weak self] in self?.sendNextRollbackFrame() }
        timer.resume()
        rollbackTimer = timer
    }

    private func sendNextRollbackFrame() {
        guard rollbackCursor < rollbackFrames.count else { stopRollback(); return }
        let frame = rollbackFrames[rollbackCursor]
        rollbackCursor += 1

        let h = rollbackCursor
        let tag = "[AID=\(rollbackStartedAID) H\(h)] 倒序历史帧（更旧）。仅用于校验/补充。不要复述标记。"
        let url = "data:\(frame.mime);base64,\(frame.data.base64EncodedString())"
        sendTaggedImageItem(tag: tag, imageURL: url, droppable: true)
    }

    private func stopRollback() {
        rollbackTimer?.cancel()
        rollbackTimer = nil
        rollbackFrames.removeAll()
        rollbackCursor = 0
    }
}

extension RealtimeAVService {

    private func tryFinishResponseIfPlaybackCompleted(reason: String) {
        guard isResponseInProgress else { return }
        guard serverAudioFinished else { return }
        guard localPlaybackFinished else { return }
        finishResponseCycle(status: reason)
    }

    private func handleServerEvent(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return
        }

        let type = (json["type"] as? String) ?? ""
        if activeProvider == .qwen { qwenLastServerEventAt = Date() }
        // ✅ 前端打断状态机（openai/三段云端通路）：播报起止信号喂给 BargeMachine
        if activeProvider == .openai {
            if type == "state", (json["value"] as? String) == "speaking" {
                frontBargeSpeakingStarted()
            } else if type == "audio_end" || type == "response.done"
                        || type == "response.audio.done" || type == "response.output_audio.done"
                        || type == "response.cancelled" || type == "bargein" {
                frontBargeSpeakingStopped()
            }
        }
        // ✅ 验收链路日志：selfhost 把所有非高频 delta 的服务端事件类型打出来，
        //    确认 commit 后服务端到底回了什么（或什么都没回）。
        if isSelfhostQwen,
           type != "response.audio.delta", type != "response.output_audio.delta",
           type != "transcription.delta", type != "session.created" {
            print("[QwenSelfhostRT] recv event=\(type)")
        }
        if type.contains("speech") || type.contains("transcription") || type.contains("response.created") || type.contains("response.cancel") || type.contains("response.done") || type.contains("function_call") {
            semanticDiag("server_event type=\(type)")
        }

        switch type {
        case "session.created", "session.updated":
            if isSelfhostQwen && type == "session.created" {
                print("[QwenSelfhostRT] recv event=session.created")
                // ✅ 一：与 Mac probe 一致——收到 session.created 后确保 session.update 已发（幂等）。
                sendSessionUpdateIfNeeded()
            }
            if isMiniCPM && type == "session.created" {
                // ✅ 音频双工进入 ACTIVE：此后才允许上行 input_audio_buffer.append（之前发会被 not_ready 拒）。
                let sid = (json["session_id"] as? String) ?? ""
                print("[ChatAGINativeRealtime] session.created session_id=\(sid) -> appends enabled")
                minicpmSessionReady = true
                minicpmWarmReady = true
                print("[ChatAGINativeRealtime] warm_ready")
                if !minicpmPrewarmOnly {
                    minicpmCallStartedAt = Date()
                    minicpmFirstAudioMs = nil
                    minicpmFirstTextMs = nil
                    if vpAudio == nil { startQwenAudioCapture(callId: currentCallId) }
                    qwenAudioStarted = true
                    print("[ChatAGINativeRealtime] mic_start")
                }
                DispatchQueue.main.async {
                    self.delegate?.realtimeAVService(self, didUpdateStatus: self.minicpmPrewarmOnly ? "已就绪" : "正在听")
                }
            }
            handleSessionConfigured(json)

        case "session.queued", "session.queue_update":
            if isMiniCPM {
                let pos = (json["position"] as? Int).map(String.init) ?? "?"
                print("[ChatAGINativeRealtime] queue \(type) position=\(pos)")
                DispatchQueue.main.async {
                    self.delegate?.realtimeAVService(self, didUpdateStatus: "排队中...(\(pos))")
                }
                startMiniCPMQueueWatchdog(position: pos)
            }

        case "session.queue_done":
            if isMiniCPM {
                // ✅ 必达事件：Worker 已分配。现在才发 session.update（协议要求 queue_done 之后）。
                print("[ChatAGINativeRealtime] session.queue_done")
                print("[ChatAGINativeRealtime] session.queue_done -> session.update")
                minicpmSendSessionUpdateAndStartMic(callId: currentCallId)
            }

        case "session.closed":
            if isMiniCPM {
                let reason = (json["reason"] as? String) ?? "(none)"
                print("[ChatAGINativeRealtime] session.closed reason=\(reason)")
                DispatchQueue.main.async {
                    self.delegate?.realtimeAVService(self, didUpdateStatus: "通话已结束 (\(reason))")
                }
                failAndReset(callId: currentCallId, status: "通话已结束 (\(reason))", error: Self.userFacingError())
                break
            }

        case "input_audio_buffer.speech_started":
            handleSpeechStarted()

        case "input_audio_buffer.speech_stopped":
            handleSpeechStopped()

        case "conversation.item.input_audio_transcription.completed":
            if let user = Self.extractUserTranscript(from: json), !user.isEmpty {
                lastTranscriptionCompletedAt = Date()
                pendingUserTranscript = user   // ✅ 缓存，等助手回复完后一起 commit
                semanticDiag("user_transcript_final utterance=\(activeUserUtteranceId) text=\(String(user.prefix(120)))")
                DispatchQueue.main.async {
                    self.delegate?.realtimeAVService(self, didReceiveUserTranscript: user)
                }
            } else {
                semanticDiag("user_transcript_completed_empty utterance=\(activeUserUtteranceId)")
            }
            // Qwen WebSocket + create_response=true 时由服务端自动响应；OpenAI/DataChannel 才会在该函数里手动 response.create。
            maybeAutoRequestResponseIfNeeded(reason: "transcription_completed")

        case "response.created":
            if let rid = Self.extractResponseId(from: json) {
                currentResponseId = rid
            }
            isResponseInProgress = true
            isCancellingResponse = false
            resetSemanticInterruptParser()
            resetPlaybackCompletionStateForNewResponse()

        case "response.cancelled":
            finishResponseCycle(status: "cancelled")

        case "response.output_text.delta", "response.text.delta", "response.audio_transcript.delta":
            isResponseInProgress = true
            maybeStartRollbackIfNeededOnFirstDelta()
            if let d = Self.extractAssistantDelta(from: json), !d.isEmpty {
                let visible = filterSemanticInterruptControl(from: d)
                if !visible.isEmpty {
                    assistantBuffer.append(visible)
                    scheduleAssistantFlush()
                }
            }

        case "response.text.done", "response.audio_transcript.done":
            // Qwen 音频回复的文字通常通过 response.audio_transcript.delta/done 返回。
            // 若前面没有收到 delta，用 done 里的完整文本兜底，保证 UI 有最终文字。
            let full = (json["text"] as? String) ?? (json["transcript"] as? String) ?? ""
            if assistantBuffer.isEmpty, !full.isEmpty {
                assistantBuffer = full
                scheduleAssistantFlush()
            }

        case "transcription.delta":
            // ✅ vLLM-Omni 自部署官方协议：transcription.* 承载的是【助手回复文本流】（probe 已验证），
            //    不是用户转写。按助手增量文本显示。
            isResponseInProgress = true
            maybeStartRollbackIfNeededOnFirstDelta()
            if let d = (json["delta"] as? String) ?? (json["text"] as? String), !d.isEmpty {
                if isSelfhostQwen { print("[QwenSelfhostRT] transcription.delta=\(d)") }
                let visible = filterSemanticInterruptControl(from: d)
                if !visible.isEmpty {
                    assistantBuffer.append(visible)
                    scheduleAssistantFlush()
                }
            }

        case "transcription.done":
            let full = (json["transcript"] as? String) ?? (json["text"] as? String) ?? ""
            if isSelfhostQwen { print("[QwenSelfhostRT] transcription.done len=\(full.count)") }
            if !full.isEmpty {
                assistantBuffer = full
                scheduleAssistantFlush()
            }

        case "response.listen":
            if isMiniCPM {
                // ✅ 服务端切回"在听"。两种情况：
                //   1) 本轮被打断（turn 进行中但没收到 end_of_turn）→ 立即清残留，避免播放旧句尾。
                //   2) 本轮自然说完（已收 end_of_turn）→ 不硬切，让 drain 把尾音放完，避免把句尾"咔"掉。
                let interrupted = minicpmTurnActive && !minicpmEndOfTurnReceived
                if interrupted {
                    print("[ChatAGINativeRealtime] response.listen (interrupted) -> clear residual playback")
                    minicpmPlaybackPendingPCM16.removeAll(keepingCapacity: true)
                    minicpmStopAudioPlayback(clearQueue: true)
                    clearPlaybackBuffer(enterTailHold: false)
                    minicpmTurnActive = false
                    minicpmPlaybackStarted = false
                    minicpmEndOfTurnReceived = false
                    markQwenPlaybackStoppedSoon()
                }
                isResponseInProgress = false
                DispatchQueue.main.async {
                    self.delegate?.realtimeAVService(self, didUpdateStatus: "正在听")
                }
                break
            }

        case "error":
            let msg =
                (json["error"] as? [String: Any])?["message"] as? String
                ?? (json["message"] as? String)
                ?? "Realtime error"

            if isSelfhostQwen {
                // ✅ 要件III.7：完整打印 type/code/error/message。
                let errObj = json["error"] as? [String: Any]
                let code = (errObj?["code"] as? String) ?? (json["code"] as? String) ?? "(none)"
                let etype = (errObj?["type"] as? String) ?? "(none)"
                print("[QwenSelfhostRT] error= type=\(etype) code=\(code) message=\(msg) raw=\(String(text.prefix(400)))")
            }

            let lower = msg.lowercased()
            if lower.contains("active response") || lower.contains("already has an active") ||
               (lower.contains("cancel") && (lower.contains("no response") || lower.contains("not found") || lower.contains("available"))) {
                isResponseInProgress = false
                isCancellingResponse = false
                currentResponseId = nil
                semanticDiag("non_fatal_realtime_state_error msg=\(String(msg.prefix(160)))")
                break
            }

            // ✅ 自部署 vLLM-Omni：若服务端拒绝 session.update 的某些字段
            //    （unsupported / unknown / invalid field 等），不要崩溃断线，
            //    打印日志并自动降级到 minimal session.update（仅 modalities + voice）。
            if isSelfhostQwen && !didSendSelfhostMinimalSessionUpdate &&
               (lower.contains("session") || lower.contains("unsupported") || lower.contains("unknown") ||
                lower.contains("invalid") || lower.contains("field") || lower.contains("param") ||
                lower.contains("argument") || lower.contains("not supported")) {
                didSendSelfhostMinimalSessionUpdate = true
                semanticDiag("selfhost_session_update_fallback_minimal msg=\(String(msg.prefix(160)))")
                // ✅ vLLM-Omni 官方协议：fallback 仍只发顶层 model（不发 session{} 包裹）。
                sendClientEvent([
                    "type": "session.update",
                    "model": qwenSelfhostModel
                ])
                print("[QwenSelfhostRT] session.update fallback model=\(qwenSelfhostModel)")
                break
            }

            // ✅ 收到服务端 error 事件 = 传输层已连通（事件本身就是从 data channel / WebSocket 收到的）。
            //    应用层 error（未知字段 / 转写抖动 / 工具报错 / 图片帧被拒 / response 状态冲突等）
            //    绝大多数 *非致命*，绝不能因此弹「实时通话连接失败」并打断整条链路——真正的掉线
            //    由 data channel / WebSocket 的 close 回调单独捕获。仅在尚未接通（!isRunning）时才视为致命。
            print("[Realtime] server error event provider=\(activeProvider.rawValue) running=\(isRunning) msg=\(String(msg.prefix(200)))")
            if isRunning {
                semanticDiag("non_fatal_server_error_while_running msg=\(String(msg.prefix(160)))")
                break
            }
            DispatchQueue.main.async {
                self.delegate?.realtimeAVService(self, didFail: Self.userFacingError())
            }

        case "result":
            if isMiniCPM {
                if (json["is_listen"] as? Bool) == true {
                    print("[ChatAGINativeRealtime] response.listen (result compat)")
                    DispatchQueue.main.async {
                        self.delegate?.realtimeAVService(self, didUpdateStatus: "正在听")
                    }
                    break
                }
                var compat = json
                compat["type"] = "response.output_audio.delta"
                if compat["audio"] == nil, let a = json["audio_data"] {
                    compat["audio"] = a
                }
                handleMiniCPMOutputAudioDelta(compat)
                break
            }

        case "response.audio.delta", "response.output_audio.delta":
            // ✅ 自部署 MiniCPM-o（机器人 6.1）全双工：text + float32 24k + end_of_turn。
            if isMiniCPM {
                handleMiniCPMOutputAudioDelta(json)
                break
            }
            // ✅ qwen_selfhost 规格 §9.2：被打断的旧轮 delta 全部丢弃，直到旧轮 audio.done。
            if isSelfhostQwen, shAwaitingStaleDone {
                if let t = shInterruptAt, Date().timeIntervalSince(t) > 5.0 {
                    // 兜底：旧轮 done 迟迟不来（可能服务端已静默终止），视后续 delta 为新回复
                    shAwaitingStaleDone = false
                    print("[QwenSelfhostRT] stale-done timeout (5s), treating deltas as new turn")
                } else {
                    print("[QwenSelfhostRT] drop stale audio oldTurn=\(max(0, selfhostTurnId - 1))")
                    break
                }
            }
            isResponseInProgress = true
            if let audioB64 = Self.extractAudioDelta(from: json), !audioB64.isEmpty {
                if isSelfhostQwen {
                    shSawJsonAudioDelta = true   // ✅ 确认服务端走 JSON 音频 → 永久忽略二进制帧
                    shLastAudioDeltaAt = Date()  // ✅ 看门狗排空判定基准
                    let nbytes = Data(base64Encoded: audioB64)?.count ?? 0
                    let queueCount = vpAudio?.playbackBufferedFrames ?? 0
                    // ✅ 规格 §I.5：每个 audio.delta 只打印 turnId / bytes / sampleRate=24000 / queueCount。
                    print("[QwenSelfhostRT] audio.delta turnId=\(selfhostTurnId) bytes=\(nbytes) sampleRate=24000 queueCount=\(queueCount)")
                    if !qwenUserIsSpeaking { shSetState("assistantSpeaking") }
                }
                handleAudioDelta(base64: audioB64)
            }

        case "response.audio.done", "response.output_audio.done":
            if isSelfhostQwen, shAwaitingStaleDone {
                // 被打断的旧轮收尾：清旗标即可，不触发正常的播放完成流程
                shAwaitingStaleDone = false
                print("[QwenSelfhostRT] audio.done turn=\(max(0, selfhostTurnId - 1)) (stale old turn closed)")
                isResponseInProgress = false
                // 旧轮结束 → 若打断后有被暂存的 final=true，现在补发。
                shFlushPendingFinalCommitIfAny()
                break
            }
            if isSelfhostQwen { print("[QwenSelfhostRT] audio.done turn=\(selfhostTurnId)") }
            lastServerAudioDoneAt = Date()
            serverAudioFinished = true

            workQueue.asyncAfter(deadline: .now() + audioDoneTailGrace) { [weak self] in
                guard let self else { return }
                if self.vpAudio?.playbackBufferedFrames ?? 0 == 0 {
                    self.markQwenPlaybackStoppedSoon()
                }
                self.tryFinishResponseIfPlaybackCompleted(reason: "audio_done_tail_grace")
            }

        case "response.output_item.done":
            // ✅ GPT function call 처리
            if let item = json["item"] as? [String: Any],
               (item["type"] as? String) == "function_call" {
                let name = item["name"] as? String ?? ""
                let callId = item["call_id"] as? String ?? ""
                let args = item["arguments"] as? String ?? "{}"
                handleFunctionCall(name: name, callId: callId, argumentsJSON: args)
            }

        case "response.function_call_arguments.done":
            let name = json["name"] as? String ?? ""
            let callId = json["call_id"] as? String ?? ""
            let args = json["arguments"] as? String ?? "{}"
            if !name.isEmpty && !callId.isEmpty {
                handleFunctionCall(name: name, callId: callId, argumentsJSON: args)
            }

        case "response.done":
            serverAudioFinished = true
            // response.done can arrive while PCM already queued locally is still draining.
            // Do not force localPlaybackFinished=true here; wait for audio_done tail grace/underrun.
            if (vpAudio?.playbackBufferedFrames ?? 0) == 0 {
                localPlaybackFinished = true
            }
            if isResponseInProgress {
                tryFinishResponseIfPlaybackCompleted(reason: "response.done")
            }

        default:
            break
        }
    }

    // ✅ 实时 RAG：处理 function call
    private func handleFunctionCall(name: String, callId: String, argumentsJSON: String) {
        semanticDiag("function_call name=\(name) callId=\(callId) args=\(String(argumentsJSON.prefix(160)))")
        switch name {
        case "semantic_interrupt":
            handleSemanticInterruptTool(callId: callId, argumentsJSON: argumentsJSON)
        case "search_memory":
            handleSearchMemory(callId: callId, argumentsJSON: argumentsJSON)
        case "adu_agent_exec":
            handleAduAgentExec(callId: callId, argumentsJSON: argumentsJSON)
        case "adu_mac_send":
            handleAduMacSend(callId: callId, argumentsJSON: argumentsJSON)

        // ── 屏幕共享接入 ──
        case "mac_screen_attach":
            handleMacScreenAttach(callId: callId)
        case "mac_screen_detach":
            handleMacScreenDetach(callId: callId)

        // ── 物理控制 ──
        case "mac_click":
            handleMacClick(callId: callId, argumentsJSON: argumentsJSON)
        case "mac_key":
            handleMacKey(callId: callId, argumentsJSON: argumentsJSON)
        case "mac_paste":
            handleMacPaste(callId: callId, argumentsJSON: argumentsJSON)
        case "mac_scroll":
            handleMacScroll(callId: callId, argumentsJSON: argumentsJSON)
        case "mac_drag":
            handleMacDrag(callId: callId, argumentsJSON: argumentsJSON)

        // ── 万能钥匙(走 WebSocket → adu-bridge) ──
        case "mac_shell":
            handleMacShell(callId: callId, argumentsJSON: argumentsJSON)
        case "mac_applescript":
            handleMacApplescript(callId: callId, argumentsJSON: argumentsJSON)

        // ── 🆕 主动视觉 ──
        case "mac_screen_glance":
            handleMacScreenGlance(callId: callId)
        case "mac_screen_watch":
            handleMacScreenWatch(callId: callId, argumentsJSON: argumentsJSON)
        case "mac_screen_pause":
            handleMacScreenPause(callId: callId)

        // ── 🆕 Accessibility API ──
        case "mac_click_by_title":
            handleMacClickByTitle(callId: callId, argumentsJSON: argumentsJSON)
        case "mac_ax_tree":
            handleMacAxTree(callId: callId, argumentsJSON: argumentsJSON)

        default:
            sendToolResult(callId: callId, output: ["error": "unknown tool: \(name)"])
        }
    }

    private func handleSemanticInterruptTool(callId: String, argumentsJSON: String) {
        semanticDiag("SEMANTIC_TOOL_TRIGGERED callId=\(callId) args=\(String(argumentsJSON.prefix(200)))")
        performSemanticInterruptSideEffects(rawControlText: semanticInterruptToken + argumentsJSON)
        sendToolResult(callId: callId, output: [
            "ok": true,
            "cmd": "semantic_interrupt",
            "message": "旧回答已停止，继续用户的新语义。"
        ])
    }

    // ════════════════════════════════════════════════════════════
    // 🆕 Mac 屏幕共享:接入/断开
    // 通过通知中心广播,让 HomeChatView 启动 MacScreenSource
    // ════════════════════════════════════════════════════════════

    private func handleMacScreenAttach(callId: String) {
        // 主线程发通知,UI 层订阅了会启动 MacScreenSource
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .aduMacScreenAttachRequested, object: nil)
        }
        sendToolResult(callId: callId, output: [
            "ok": true,
            "message": "已请求接入 Mac 屏幕,1-2 秒后你将收到第一帧画面。如果用户 Mac 没在线,你会看不到画面。"
        ])
    }

    private func handleMacScreenDetach(callId: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .aduMacScreenDetachRequested, object: nil)
        }
        sendToolResult(callId: callId, output: ["ok": true, "message": "已断开 Mac 屏幕共享"])
    }

    // ════════════════════════════════════════════════════════════
    // 🆕 物理控制(mac_click / mac_key / mac_paste / mac_scroll)
    // 通过 RealtimeFastLane.shared.macScreenSource 下发到 Mac (旧路径,已废弃)
    // ════════════════════════════════════════════════════════════

    private func sendMacCommand(op: String, params: [String: Any]) {
        Task { @MainActor in
            if let session = ScreenAgentSession.activeSession {
                session.sendControlToMac(op: op, params: params)
            } else {
                print("[RealtimeAVService] mac op '\(op)' 未发送 — 当前没有激活的 ScreenAgentSession")
            }
        }
    }

    private func handleMacClick(callId: String, argumentsJSON: String) {
        let data = argumentsJSON.data(using: .utf8) ?? Data()
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let x: Double = (obj["x"] as? Int).map(Double.init) ?? (obj["x"] as? Double ?? 0)
        let y: Double = (obj["y"] as? Int).map(Double.init) ?? (obj["y"] as? Double ?? 0)
        var params: [String: Any] = ["x": x, "y": y]
        if let btn = obj["button"] as? String { params["button"] = btn }
        if let dbl = obj["double"] as? Bool { params["double"] = dbl }
        sendMacCommand(op: "click", params: params)
        sendToolResult(callId: callId, output: ["ok": true, "clicked_at": "(\(Int(x)), \(Int(y)))"])
    }

    private func handleMacKey(callId: String, argumentsJSON: String) {
        let data = argumentsJSON.data(using: .utf8) ?? Data()
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let name = (obj["name"] as? String) ?? ""
        guard !name.isEmpty else {
            sendToolResult(callId: callId, output: ["ok": false, "error": "empty key name"])
            return
        }
        sendMacCommand(op: "key", params: ["name": name])
        sendToolResult(callId: callId, output: ["ok": true, "pressed": name])
    }

    private func handleMacPaste(callId: String, argumentsJSON: String) {
        let data = argumentsJSON.data(using: .utf8) ?? Data()
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let text = (obj["text"] as? String) ?? ""
        guard !text.isEmpty else {
            sendToolResult(callId: callId, output: ["ok": false, "error": "empty text"])
            return
        }
        sendMacCommand(op: "paste", params: ["text": text])
        sendToolResult(callId: callId, output: ["ok": true, "pasted_chars": text.count])
    }

    private func handleMacScroll(callId: String, argumentsJSON: String) {
        let data = argumentsJSON.data(using: .utf8) ?? Data()
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let dy = (obj["dy"] as? Int) ?? 0
        let dx = (obj["dx"] as? Int) ?? 0
        sendMacCommand(op: "scroll", params: ["dx": dx, "dy": dy])
        sendToolResult(callId: callId, output: ["ok": true])
    }

    private func handleMacDrag(callId: String, argumentsJSON: String) {
        let data = argumentsJSON.data(using: .utf8) ?? Data()
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let x1 = (obj["x1"] as? Int) ?? 0
        let y1 = (obj["y1"] as? Int) ?? 0
        let x2 = (obj["x2"] as? Int) ?? 0
        let y2 = (obj["y2"] as? Int) ?? 0
        sendMacCommand(op: "drag", params: ["fromX": x1, "fromY": y1, "toX": x2, "toY": y2])
        sendToolResult(callId: callId, output: [
            "ok": true,
            "dragged": ["from": ["x": x1, "y": y1], "to": ["x": x2, "y": y2]]
        ])
    }

    // ────────── 万能钥匙:shell + applescript ──────────

    private func handleMacShell(callId: String, argumentsJSON: String) {
        let data = argumentsJSON.data(using: .utf8) ?? Data()
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let command = (obj["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            sendToolResult(callId: callId, output: ["ok": false, "error": "empty command"])
            return
        }
        sendMacCommand(op: "shell", params: ["command": command])
        // ⚠️ 当前版本下发后立即回包,不等 Mac 执行结果
        // 后续可加 callId 关联,等 ws_control 回包后再 sendToolResult
        sendToolResult(callId: callId, output: [
            "ok": true,
            "executing": command,
            "note": "命令已下发到 Mac 执行,执行结果会在屏幕变化中体现,你可以再次描述屏幕来确认效果。"
        ])
    }

    private func handleMacApplescript(callId: String, argumentsJSON: String) {
        let data = argumentsJSON.data(using: .utf8) ?? Data()
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let script = (obj["script"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else {
            sendToolResult(callId: callId, output: ["ok": false, "error": "empty script"])
            return
        }
        sendMacCommand(op: "applescript", params: ["source": script])
        sendToolResult(callId: callId, output: [
            "ok": true,
            "executing": "applescript (\(script.count) chars)",
            "note": "AppleScript 已下发到 Mac 执行,效果会在屏幕变化中体现。"
        ])
    }

    // ════════════════════════════════════════════════════
    // 🆕 主动视觉(glance / watch / pause)
    // ════════════════════════════════════════════════════

    private func handleMacScreenGlance(callId: String) {
        sendMacCommand(op: "screen_glance", params: [:])
        sendToolResult(callId: callId, output: [
            "ok": true,
            "note": "已请求当前屏幕画面,0.5-1 秒内你会看到。请基于看到的内容继续。"
        ])
    }

    private func handleMacScreenWatch(callId: String, argumentsJSON: String) {
        let data = argumentsJSON.data(using: .utf8) ?? Data()
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let fps = (obj["fps"] as? Double) ?? 1.0
        let clamped = max(0.2, min(fps, 5.0))
        sendMacCommand(op: "screen_watch", params: ["fps": clamped])
        sendToolResult(callId: callId, output: [
            "ok": true, "mode": "watching", "fps": clamped,
            "note": "已开启屏幕监控 \(clamped) fps。完成观察后记得 mac_screen_pause 节省资源。"
        ])
    }

    private func handleMacScreenPause(callId: String) {
        sendMacCommand(op: "screen_pause", params: [:])
        sendToolResult(callId: callId, output: [
            "ok": true, "mode": "idle",
            "note": "已停止屏幕推流。需要看屏时调 mac_screen_glance。"
        ])
    }

    // ════════════════════════════════════════════════════
    // 🆕 Accessibility API:精确点击 + 元素树
    // ════════════════════════════════════════════════════

    /// ⭐ 最有价值的工具:直接按文字点击,Mac 端用 AXUIElement 精准定位
    private func handleMacClickByTitle(callId: String, argumentsJSON: String) {
        let data = argumentsJSON.data(using: .utf8) ?? Data()
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let title = (obj["title"] as? String) ?? ""
        let double = (obj["double"] as? Bool) ?? false
        guard !title.isEmpty else {
            sendToolResult(callId: callId, output: ["ok": false, "error": "empty title"])
            return
        }
        sendMacCommand(op: "click_by_title", params: ["title": title, "double": double])
        sendToolResult(callId: callId, output: [
            "ok": true, "clicking": title,
            "note": "已请求精准点击 '\(title)'。Mac 通过 Accessibility API 定位并点击。若找不到,可 mac_screen_glance 看屏幕状态。"
        ])
    }

    private func handleMacAxTree(callId: String, argumentsJSON: String) {
        let data = argumentsJSON.data(using: .utf8) ?? Data()
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let maxDepth = (obj["max_depth"] as? Int) ?? 8
        sendMacCommand(op: "ax_tree", params: ["max_depth": maxDepth])
        sendToolResult(callId: callId, output: [
            "ok": true,
            "note": "已请求元素树。当前异步实现,完整 JSON 暂时不直接返回到对话上下文。建议优先使用 mac_click_by_title 直接点击,或 mac_screen_glance 看屏幕。"
        ])
    }

    // ✅ adu_mac_send：发微信消息
    private func handleAduMacSend(callId: String, argumentsJSON: String) {
        let data = argumentsJSON.data(using: .utf8) ?? Data()
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let contact = (obj["contact"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let message = (obj["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard !contact.isEmpty, !message.isEmpty else {
            sendToolResult(callId: callId, output: ["ok": false, "error": "missing contact or message"])
            return
        }

        let base = apiBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/agent/mac_send") else {
            sendToolResult(callId: callId, output: ["ok": false, "error": "invalid url"])
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        applyAgentToken(&req)

        let payload: [String: Any] = ["contact": contact, "message": message]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self else { return }
            let result: [String: Any]
            if let data, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                result = obj
            } else {
                result = ["ok": true, "result": "已发送给\(contact)"]
            }
            self.workQueue.async { self.sendToolResult(callId: callId, output: result) }
        }.resume()
    }

    // ✅ search_memory 处理
    private func handleSearchMemory(callId: String, argumentsJSON: String) {
        let name = "search_memory"
        _ = name

        let data = argumentsJSON.data(using: .utf8) ?? Data()
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let query = (obj["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let topK = obj["top_k"] as? Int ?? 5
        let scope = obj["scope"] as? String ?? "hybrid"

        guard !query.isEmpty else {
            sendToolResult(callId: callId, output: ["query": "", "items": []])
            return
        }

        let base = apiBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/tools/search_memory") else {
            sendToolResult(callId: callId, output: ["query": query, "items": []])
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10

        let cid = sessionClientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (UIDevice.current.identifierForVendor?.uuidString ?? "anonymous")
            : sessionClientId

        let payload: [String: Any] = ["client_id": cid, "query": query, "top_k": topK, "scope": scope]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self else { return }
            let result: [String: Any]
            if let data, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                result = obj
            } else {
                result = ["query": query, "items": []]
            }
            self.workQueue.async { self.sendToolResult(callId: callId, output: result) }
        }.resume()
    }

    // ✅ adu_agent_exec 处理：语音控制笔记本
    private func handleAduAgentExec(callId: String, argumentsJSON: String) {
        let data = argumentsJSON.data(using: .utf8) ?? Data()
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let action = (obj["action"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard !action.isEmpty else {
            sendToolResult(callId: callId, output: ["ok": false, "error": "empty action"])
            return
        }

        let base = apiBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // 智能路由：根据 action 关键词选择接口
        let actionLower = action.lowercased()
        let endpoint: String
        var body: [String: Any]

        if actionLower.contains("编译") || actionLower.contains("compile") || actionLower.contains("build") {
            if actionLower.contains("安装") || actionLower.contains("install") {
                endpoint = "/agent/install"
                body = ["path": "~/Desktop/GPTsora", "scheme": "GPT Solara"]
            } else {
                endpoint = "/agent/build"
                body = ["path": "~/Desktop/GPTsora", "scheme": "GPT Solara"]
            }
        } else if actionLower.contains("文件") || actionLower.contains("项目树") || actionLower.contains("filetree") {
            endpoint = "/agent/filetree"
            body = ["path": "~/Desktop/GPTsora/GPTsora", "depth": 2, "extensions": [".swift"]]
        } else {
            // 公开版不提供「语音 → 通用命令执行」：把任意语音转成 shell 命令太危险（2026-09-29 安全修复）
            sendToolResult(callId: callId, output: ["ok": false, "error": "disabled_in_public_release"])
            return
        }

        guard let url = URL(string: base + endpoint) else {
            sendToolResult(callId: callId, output: ["ok": false, "error": "invalid url"])
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300  // 编译最多5分钟
        applyAgentToken(&req)
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            guard let self else { return }
            var result: [String: Any]
            if let err {
                result = ["ok": false, "error": err.localizedDescription]
            } else if let data, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                result = obj
                // 编译结果精简化（避免太长）
                if let output = result["output"] as? String, output.count > 500 {
                    let lines = output.components(separatedBy: "\n")
                    let key = lines.filter { $0.contains("BUILD") || $0.contains("error:") || $0.contains("✅") }.prefix(5)
                    result["output"] = key.joined(separator: "\n")
                    result["full_output_truncated"] = true
                }
            } else {
                result = ["ok": false, "error": "no response"]
            }
            self.workQueue.async { self.sendToolResult(callId: callId, output: result) }
        }.resume()
    }

    /// 后端受保护接口（/agent/*）要求 X-Agent-Token；令牌来自 Info.plist 的 AGENT_API_TOKEN
    private func applyAgentToken(_ req: inout URLRequest) {
        let token = AppConfig.agentToken
        if !token.isEmpty {
            req.setValue(token, forHTTPHeaderField: "X-Agent-Token")
        }
    }

    private func sendToolResult(callId: String, output: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: output),
              let jsonStr = String(data: jsonData, encoding: .utf8) else { return }

        sendClientEvent([
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": callId,
                "output": jsonStr
            ] as [String: Any]
        ])
        // ✅ 结果回给模型后，让模型继续生成回答
        sendClientEvent(["type": "response.create"])
    }

    private func finishResponseCycle(status: String) {
        semanticDiag("finish_response status=\(status) final_len=\(assistantBuffer.count) pending_user_len=\(pendingUserTranscript.count)")
        assistantFlushWorkItem?.cancel()
        assistantFlushWorkItem = nil

        let final = assistantBuffer
        assistantBuffer = ""
        resetSemanticInterruptParser()

        isResponseInProgress = false
        isCancellingResponse = false
        currentResponseId = nil
        pipelinePlaybackActive = false
        lastPlaybackStoppedAt = Date()

        qwenPlaybackLikelyActive = false
        qwenPlaybackGateHoldUntil = Date().addingTimeInterval(qwenPlaybackTailHold)

        serverAudioFinished = false
        localPlaybackFinished = true
        lastServerAudioDoneAt = nil

        // ✅ qwen_selfhost：本轮播放收尾 → 回到 listening（tail hold 由 shHandleMicFrame 用
        //    lastPlaybackStoppedAt 计时，900ms 内仅强插话能开口）。
        if isSelfhostQwen && !selfhostTurnOpen { shSetState("listening") }

        rollbackPendingAID = 0
        rollbackStartedAID = 0
        stopRollback()

        cleanupOldServerImages()

        if let pending = pendingCreateAfterCancel, status.lowercased().contains("cancel") {
            pendingCreateAfterCancel = nil
            requestResponse(speak: pending.speak, aid: pending.aid)
        } else {
            pendingCreateAfterCancel = nil
        }

        if !final.isEmpty {
            DispatchQueue.main.async {
                self.delegate?.realtimeAVService(self, didReceiveAssistantText: final, isFinal: true)
            }
        }

        // ✅ 自动 commit 本轮对话到后端 DB（历史同步 + 记忆积累）
        let userTurn = pendingUserTranscript
        pendingUserTranscript = ""
        if !userTurn.isEmpty || !final.isEmpty {
            commitTurn(userText: userTurn, assistantText: final)
        }
    }

    private func recordServerItemIfNeeded(_ json: [String: Any]) {
        let item = (json["item"] as? [String: Any])
            ?? (json["conversation_item"] as? [String: Any])
            ?? (json["data"] as? [String: Any])

        guard let itemDict = item else { return }
        guard let itemId = (itemDict["id"] as? String), !itemId.isEmpty else { return }

        if Self.itemHasInputImage(itemDict) {
            serverImageItemIds.append(itemId)
        }
    }

    private func cleanupOldServerImages() {
        guard serverImageItemIds.count > keepServerImages else { return }
        let deleteCount = serverImageItemIds.count - keepServerImages
        if deleteCount <= 0 { return }

        let toDelete = Array(serverImageItemIds.prefix(deleteCount))
        serverImageItemIds.removeFirst(deleteCount)

        for id in toDelete {
            sendClientEvent([
                "type": "conversation.item.delete",
                "event_id": UUID().uuidString,
                "item_id": id
            ], droppable: true)
        }
    }

    private func handleSessionConfigured(_ json: [String: Any]) {
        guard activeProvider == .qwen else { return }

        if let session = json["session"] as? [String: Any],
           let td = session["turn_detection"] as? [String: Any] {
            serverTurnDetection = td
            let tdType = td["type"] as? String ?? ""
            let threshold = td["threshold"] ?? ""
            let prefix = td["prefix_padding_ms"] ?? ""
            let silence = td["silence_duration_ms"] ?? ""
            let create = td["create_response"] ?? ""
            let interrupt = td["interrupt_response"] ?? ""
            semanticDiag("QWEN_SESSION_CONFIRMED turn_detection type=\(tdType) threshold=\(threshold) prefix=\(prefix) silence=\(silence) create=\(create) interrupt=\(interrupt)")
        }
    }

    private func qwenStopLocalAssistantAudioForOfficialSpeechStart() {
        guard activeProvider == .qwen else { return }

        let buffered = vpAudio?.playbackBufferedFrames ?? 0
        let assistantAudible = isResponseInProgress || qwenPlaybackLikelyActive || buffered > 0 || !localPlaybackFinished
        guard assistantAudible else { return }

        // 阿里官方示例：speech_started 且当前正在响应时，客户端应发送 response.cancel，
        // 否则只清本地播放会造成“本地停了、服务端还在生成”，后续容易卡成静默。
        semanticDiag("QWEN_OFFICIAL_SPEECH_STARTED_CANCEL_RESPONSE buffered=\(buffered) response=\(isResponseInProgress)")
        clearPlaybackBuffer(enterTailHold: false)
        if isResponseInProgress || currentResponseId != nil {
            cancelActiveResponse(reason: "qwen_official_speech_started")
        }

        assistantFlushWorkItem?.cancel()
        assistantFlushWorkItem = nil
        if !assistantBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let partial = assistantBuffer
            DispatchQueue.main.async {
                self.delegate?.realtimeAVService(self, didReceiveAssistantText: partial, isFinal: true)
            }
        }
    }

    private func handleSpeechStarted() {
        userUtteranceEndWorkItem?.cancel()
        userUtteranceEndWorkItem = nil
        responseRequestedForCurrentSpeech = false
        lastSpeechStartedAt = Date()

        // ✅ 阿里官方 Java 范例的核心打断 gate：从 speech_started 这一刻起，
        // 所有 response.audio.delta 必须丢弃，直到收到 speech_stopped。
        // 这堵住了"客户端发出 response.cancel 到服务端真正停止生成"之间
        // 100~300ms 的网络往返窗口期，避免刚清掉的播放队列被新到的
        // delta 重新填入。
        qwenUserIsSpeaking = true

        // ✅ 阿里官方打断流程：speech_started 是服务端确认的用户开口事件。
        // 客户端三件事：清本地播放缓存（立即停声）+ 发 response.cancel（停服务端生成）
        // + 设 userIsSpeaking=true（堵 100~300ms 窗口期内继续到达的 audio.delta）。
        qwenStopLocalAssistantAudioForOfficialSpeechStart()

        aidCounter &+= 1
        userUtteranceSeq &+= 1
        let aid = aidCounter
        activeUserUtteranceId = userUtteranceSeq
        lastSpeechAID = aid
        speechActivity = .active(aid: aid)
        semanticDiag("USER_SPEECH_STARTED utterance=\(activeUserUtteranceId) aid=\(aid) active_response=\(isResponseInProgress) playback_qwen=\(qwenPlaybackLikelyActive) playback_pipeline=\(pipelinePlaybackActive) user_speaking=true")
    }

    private func handleSpeechStopped() {
        let aid: Int
        switch speechActivity {
        case .active(let a): aid = a
        case .idle: aid = max(1, lastSpeechAID)
        }
        speechActivity = .idle
        lastSpeechStoppedAt = Date()

        // ✅ 用户说话结束：释放 gate，允许下一轮 response.audio.delta 写入播放队列。
        // 注意：这里释放的是"用户在说话"的状态门，不影响"服务端是否还在发上一轮残音"
        // 的判断——上一轮残音由 cancelActiveResponse + clearPlaybackBuffer 处理，
        // 真正生效的去重靠服务端 response.cancelled 事件。
        qwenUserIsSpeaking = false

        semanticDiag("USER_SPEECH_STOPPED utterance=\(activeUserUtteranceId) aid=\(aid) wait_for_transcription_or_grace")

        sendEndKeyframeH0(aid: aid)

        // ✅ 用户语句结束判断：speech_stopped 只是 VAD 静音，不等于语义文本已结束。
        // 先等 final transcription；若没来，再用 grace fallback。
        let utterance = activeUserUtteranceId
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.activeUserUtteranceId == utterance else { return }
            self.semanticDiag("USER_UTTERANCE_END_GRACE utterance=\(utterance) aid=\(aid) transcript_seen=\(self.lastTranscriptionCompletedAt != nil)")
            self.maybeAutoRequestResponseIfNeeded(reason: "speech_stopped_grace", forcedAid: aid)
        }
        userUtteranceEndWorkItem = item
        workQueue.asyncAfter(deadline: .now() + 0.45, execute: item)
    }

    private func maybeAutoRequestResponseIfNeeded(reason: String, forcedAid: Int? = nil) {
        semanticDiag("maybe_request_response reason=\(reason) provider=\(activeProvider.rawValue) forcedAid=\(forcedAid.map(String.init) ?? "nil")")
        if isWebSocketProvider {
            // Qwen 官方 VAD 打开 create_response=true 后，服务端会自动触发回复。
            // 这里禁止重复手动 response.create，避免 active response 冲突和打断延迟。
            semanticDiag("maybe_request_response_skip websocket_provider_official_auto_create")
            return
        }

        let now = Date()
        if responseRequestedForCurrentSpeech { return }
        if let last = lastResponseRequestedAt, now.timeIntervalSince(last) < 0.35 { return }

        responseRequestedForCurrentSpeech = true
        let aid = forcedAid ?? (lastSpeechAID > 0 ? lastSpeechAID : nil)

        if callMode == .audioVideo, let aid, lastEndKeyframeAID != aid {
            sendEndKeyframeH0(aid: aid)
        }

        markAssistantNewTurn()
        requestResponse(speak: true, aid: aid)
    }

    private func scheduleAssistantFlush() {
        guard assistantFlushWorkItem == nil else { return }
        let callId = currentCallId
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard callId == self.currentCallId else { return }
            self.assistantFlushWorkItem = nil
            let partial = self.assistantBuffer
            DispatchQueue.main.async {
                self.delegate?.realtimeAVService(self, didReceiveAssistantText: partial, isFinal: false)
            }
        }
        assistantFlushWorkItem = item
        workQueue.asyncAfter(deadline: .now() + assistantPartialFlushInterval, execute: item)
    }

    private static func extractUserTranscript(from json: [String: Any]) -> String? {
        if let t = json["transcript"] as? String, !t.isEmpty { return t }
        if let item = json["item"] as? [String: Any] {
            if let t = item["transcript"] as? String, !t.isEmpty { return t }
            if let trans = item["transcription"] as? [String: Any],
               let t = trans["text"] as? String, !t.isEmpty { return t }
        }
        return nil
    }

    private static func extractAssistantDelta(from json: [String: Any]) -> String? {
        if let t = json["delta"] as? String, !t.isEmpty { return t }
        if let t = json["text"] as? String, !t.isEmpty { return t }
        if let deltaDict = json["delta"] as? [String: Any],
           let t = deltaDict["text"] as? String, !t.isEmpty { return t }
        return nil
    }

    private static func extractResponseId(from json: [String: Any]) -> String? {
        if let r = json["response"] as? [String: Any], let id = r["id"] as? String { return id }
        if let id = json["response_id"] as? String { return id }
        return nil
    }

    private static func extractResponseStatus(from json: [String: Any]) -> String? {
        if let r = json["response"] as? [String: Any], let status = r["status"] as? String { return status }
        if let status = json["status"] as? String { return status }
        return nil
    }

    private static func itemHasInputImage(_ item: [String: Any]) -> Bool {
        guard let content = item["content"] as? [[String: Any]] else { return false }
        return content.contains { ($0["type"] as? String) == "input_image" }
    }

    private static func extractAudioDelta(from json: [String: Any]) -> String? {
        if let d = json["delta"] as? String, !d.isEmpty { return d }
        if let dd = json["delta"] as? [String: Any], let a = dd["audio"] as? String, !a.isEmpty { return a }
        if let a = json["audio"] as? String, !a.isEmpty { return a }
        return nil
    }

    // ── Turn commit：把本轮语音对话写入后端 DB ──
    // 同时写入 user + assistant 文本，后端自动写 memory_timeline
    // GPT Realtime 和 Qwen Realtime 通用
    private func commitTurn(userText: String, assistantText: String) {
        guard !userText.isEmpty || !assistantText.isEmpty else { return }

        let baseTrimmed = apiBase
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !baseTrimmed.isEmpty, let url = URL(string: baseTrimmed + "/realtime/turn/commit") else { return }

        var payload: [String: Any] = [:]
        let cid = sessionClientId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cid.isEmpty { payload["client_id"] = cid }

        // 用通话开始时锁定的 conv_id，保证语音和文本共用同一个会话
        // 若没有（纯语音新通话），后端会自动创建并返回，下一轮 turn 会复用
        let convId = currentTurnConversationId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !convId.isEmpty { payload["conversation_id"] = convId }

        if !userText.isEmpty      { payload["user_text"] = userText }
        if !assistantText.isEmpty { payload["assistant_text"] = assistantText }

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        req.httpBody = body

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            guard let self else { return }
            if let err {
                print("[TurnCommit] ❌ \(err.localizedDescription)")
                return
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let newConvId = json["conversation_id"] as? String,
               !newConvId.isEmpty {
                // 后端自动创建了 conv_id，锁定供后续 turn 使用
                self.workQueue.async {
                    if self.currentTurnConversationId.isEmpty {
                        self.currentTurnConversationId = newConvId
                    }
                }
                print("[TurnCommit] ✅ code=\(code) conv=\(newConvId) added=\(json["messages_added"] ?? "?")")
            } else {
                print("[TurnCommit] ⚠️ code=\(code)")
            }
        }.resume()
    }
}

extension RealtimeAVService {

    private func handleAudioDelta(base64: String) {
        guard isWebSocketProvider else { return }

        // ✅ 阿里官方 Java 范例核心：用户在说话期间到达的 audio.delta 必须丢弃。
        //   case "response.audio.delta":
        //     if (!userIsSpeaking.get()) { player.play(...) }
        // 这段窗口包含两部分：
        //   1) speech_started 到 speech_stopped 之间用户实际在说话；
        //   2) 客户端已发 response.cancel，但服务端因为网络往返还会继续发
        //      100~300ms 的残余 audio.delta。
        // 没有这段 gate，clearPlaybackBuffer 清掉之后又会被新到的 delta 重填，
        // 表现为"打断了一下又冒出一截"——这就是当前打断不彻底的根因。
        if activeProvider == .qwen, qwenUserIsSpeaking {
            if isSelfhostQwen {
                print("[QwenSelfhostRT] drop stale audio oldTurn=\(max(0, selfhostTurnId - 1))")
            }
            return
        }

        guard let rawData = Data(base64Encoded: base64), !rawData.isEmpty else { return }

        let pcm16Data: Data
        if qwenPcm24ToPcm16 && rawData.count % 3 == 0 {
            pcm16Data = Self.pcm24ToPcm16(rawData)
        } else {
            pcm16Data = rawData
        }
        guard !pcm16Data.isEmpty else { return }

        // ✅ 四：单一播放队列（VoiceProcessingIO 24k mono），不当 wav、不重复播放。
        if isSelfhostQwen {
            let wasActive = qwenPlaybackLikelyActive
            print("[QwenSelfhostRT] enqueue playback sampleRate=24000 channels=1 bytes=\(pcm16Data.count) turn=\(selfhostTurnId)")
            if !wasActive { print("[QwenSelfhostRT] playback start turn=\(selfhostTurnId)") }
        }
        markQwenPlaybackStarted()
        vpAudio?.appendPlaybackPCM16(pcm16Data)
    }

    // ✅ 自部署 MiniCPM-o 4.5 全双工：response.output_audio.delta/result 承载
    //    text（助手文本增量）+ audio_data/audio（base64 WAV 或 Float32 PCM）+ end_of_turn。
    //    Float32 PCM 下行转 PCM16 后复用 VoiceProcessingIO/CircularPCMBuffer 连续播放；
    //    WAV 兼容路径保留 AVAudioEngine + AVAudioPlayerNode。不要把 Float32 PCM 当 mp3/wav。
    private func handleMiniCPMOutputAudioDelta(_ json: [String: Any]) {
        isResponseInProgress = true

        // 新一轮助手回复：开新气泡。
        if !minicpmTurnActive {
            minicpmTurnActive = true
            minicpmEndOfTurnReceived = false
            minicpmPlaybackDrainChecks += 1
            markAssistantNewTurn()
        }

        let text = (json["text"] as? String) ?? ""
        let endOfTurn = (json["end_of_turn"] as? Bool) ?? false
        print("[ChatAGINativeRealtime] result.text len=\(text.count) end_of_turn=\(endOfTurn)")

        if !text.isEmpty {
            print("[ChatAGINativeRealtime] result.text=\(text)")
            if minicpmFirstTextMs == nil, let started = minicpmCallStartedAt {
                minicpmFirstTextMs = Int(Date().timeIntervalSince(started) * 1000.0)
                print("[ChatAGINativeRealtime] first_text_ms=\(minicpmFirstTextMs ?? 0)")
            }
            let visible = filterSemanticInterruptControl(from: text)
            if !visible.isEmpty {
                assistantBuffer.append(visible)
                scheduleAssistantFlush()
            }
        }

        if let audioB64 = ((json["audio"] as? String) ?? (json["audio_data"] as? String)), !audioB64.isEmpty {
            print("[ChatAGINativeRealtime] result.audio_data chars=\(audioB64.count)")
            guard let audioData = Data(base64Encoded: audioB64), !audioData.isEmpty else {
                print("[ChatAGINativeRealtime] playback_error=音频解码失败 base64_invalid")
                DispatchQueue.main.async {
                    self.delegate?.realtimeAVService(self, didUpdateStatus: "音频解码失败")
                    self.delegate?.realtimeAVService(self, didFail: NSError(domain: "RealtimeAVService", code: -61, userInfo: [NSLocalizedDescriptionKey: "音频解码失败"]))
                }
                return
            }

            print("[ChatAGINativeRealtime] decoded bytes=\(audioData.count)")
            print("[ChatAGINativeRealtime] audio_delta_received bytes=\(audioData.count)")

            if minicpmFirstAudioMs == nil, let started = minicpmCallStartedAt {
                minicpmFirstAudioMs = Int(Date().timeIntervalSince(started) * 1000.0)
                print("[ChatAGINativeRealtime] result.audio_data bytes=\(audioData.count) first_audio_ms=\(minicpmFirstAudioMs ?? 0)")
                print("[ChatAGINativeRealtime] first_audio_ms=\(minicpmFirstAudioMs ?? 0)")
            } else {
                print("[ChatAGINativeRealtime] result.audio_data bytes=\(audioData.count)")
            }
            DispatchQueue.main.async {
                let a = self.minicpmFirstAudioMs.map { "first_audio_ms=\($0)" } ?? "first_audio_ms=-"
                let t = self.minicpmFirstTextMs.map { "first_text_ms=\($0)" } ?? "first_text_ms=-"
                self.delegate?.realtimeAVService(self, didUpdateStatus: "正在说话 · \(a) · \(t)")
            }
            minicpmEnqueueAudioData(audioData)
        }

        if endOfTurn {
            print("[ChatAGINativeRealtime] end_of_turn first_audio_ms=\(minicpmFirstAudioMs.map(String.init) ?? "nil") first_text_ms=\(minicpmFirstTextMs.map(String.init) ?? "nil")")
            lastServerAudioDoneAt = Date()
            serverAudioFinished = true
            minicpmEndOfTurnReceived = true
            minicpmAudioQueueEndOfTurn = true
            if minicpmContinuousPlaybackActive || (vpAudio?.playbackBufferedFrames ?? 0) > 0 {
                minicpmCheckContinuousPlaybackDrain(token: minicpmPlaybackDrainChecks)
            } else {
                playNextMiniCPMAudioIfNeeded()
            }
        }
    }

    private func minicpmEnqueueAudioData(_ data: Data) {
        let isWav = Self.isRIFFWAVE(data)
        if isWav {
            print("[ChatAGINativeRealtime] audio_format=wav")
            minicpmAudioQueue.append(.wav(data))
            print("[ChatAGINativeRealtime] audio_queue_length=\(minicpmAudioQueue.count)")
            playNextMiniCPMAudioIfNeeded()
            return
        }

        print("[ChatAGINativeRealtime] audio_format=float32_pcm_24k_mono")
        let pcm16 = Self.float32LEToPcm16(data)
        guard !pcm16.isEmpty else {
            print("[ChatAGINativeRealtime] playback_error=音频解码失败 float32_pcm_empty")
            DispatchQueue.main.async {
                self.delegate?.realtimeAVService(self, didUpdateStatus: "音频解码失败")
                self.delegate?.realtimeAVService(self, didFail: NSError(domain: "RealtimeAVService", code: -69, userInfo: [NSLocalizedDescriptionKey: "音频解码失败"]))
            }
            return
        }
        print("[ChatAGINativeRealtime] pcm16_converted bytes=\(pcm16.count)")

        if vpAudio == nil {
            startQwenAudioCapture(callId: currentCallId)
        }
        guard let audioDriver = vpAudio else {
            print("[ChatAGINativeRealtime] playback_error=VoiceProcessingIO unavailable")
            DispatchQueue.main.async {
                self.delegate?.realtimeAVService(self, didUpdateStatus: "播放失败")
                self.delegate?.realtimeAVService(self, didFail: NSError(domain: "RealtimeAVService", code: -70, userInfo: [NSLocalizedDescriptionKey: "播放失败"]))
            }
            return
        }

        let isFirstInTurn = !minicpmPlaybackStarted && !minicpmContinuousPlaybackActive
        minicpmPlaybackStarted = true
        minicpmContinuousPlaybackActive = true
        localPlaybackFinished = false
        markQwenPlaybackStarted()

        print(isFirstInTurn ? "[ChatAGINativeRealtime] playback_start" : "[ChatAGINativeRealtime] playback_next")
        audioDriver.appendPlaybackPCM16(pcm16)
        print("[ChatAGINativeRealtime] audio_queue_length=\(audioDriver.playbackBufferedFrames)")
    }

    private func playNextMiniCPMAudioIfNeeded() {
        guard activeProvider == .minicpm else { return }
        guard !minicpmAudioIsPlaying else { return }

        guard !minicpmAudioQueue.isEmpty else {
            if minicpmAudioQueueEndOfTurn {
                finishMiniCPMAudioQueue()
            }
            return
        }

        let item = minicpmAudioQueue.removeFirst()
        let isFirstInTurn = !minicpmPlaybackStarted
        minicpmPlaybackStarted = true
        minicpmAudioIsPlaying = true
        localPlaybackFinished = false
        markQwenPlaybackStarted()

        print(isFirstInTurn ? "[ChatAGINativeRealtime] playback_start" : "[ChatAGINativeRealtime] playback_next")

        do {
            try ensureMiniCPMAudioEngineRunning()
            switch item {
            case .float32PCM(let data):
                try scheduleMiniCPMFloat32PCM(data)
            case .wav(let data):
                try scheduleMiniCPMWAV(data)
            }
        } catch {
            minicpmAudioIsPlaying = false
            print("[ChatAGINativeRealtime] playback_error=\(error.localizedDescription)")
            DispatchQueue.main.async {
                self.delegate?.realtimeAVService(self, didUpdateStatus: "播放失败")
                self.delegate?.realtimeAVService(self, didFail: NSError(domain: "RealtimeAVService", code: -62, userInfo: [NSLocalizedDescriptionKey: "播放失败"]))
            }
            playNextMiniCPMAudioIfNeeded()
        }
    }

    private func finishMiniCPMAudioSegment() {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.minicpmAudioIsPlaying = false
            self.playNextMiniCPMAudioIfNeeded()
        }
    }

    private func finishMiniCPMAudioQueue() {
        guard !minicpmAudioIsPlaying, minicpmAudioQueue.isEmpty else { return }
        print("[ChatAGINativeRealtime] playback_end")
        markQwenPlaybackStoppedSoon()
        localPlaybackFinished = true
        minicpmTurnActive = false
        minicpmPlaybackStarted = false
        minicpmContinuousPlaybackActive = false
        minicpmAudioQueueEndOfTurn = false
        minicpmEndOfTurnReceived = false
        isResponseInProgress = false
        DispatchQueue.main.async {
            let a = self.minicpmFirstAudioMs.map { "first_audio_ms=\($0)" } ?? "first_audio_ms=-"
            let t = self.minicpmFirstTextMs.map { "first_text_ms=\($0)" } ?? "first_text_ms=-"
            self.delegate?.realtimeAVService(self, didUpdateStatus: "已结束 · \(a) · \(t)")
        }
        tryFinishResponseIfPlaybackCompleted(reason: "minicpm_audio_queue_drained")

        workQueue.asyncAfter(deadline: .now() + minicpmPlaybackTailHoldMs / 1000.0) { [weak self] in
            guard let self else { return }
            if !self.minicpmTurnActive && !self.minicpmPlaybackStarted && self.activeProvider == .minicpm {
                DispatchQueue.main.async {
                    self.delegate?.realtimeAVService(self, didUpdateStatus: "正在听")
                }
            }
        }
    }

    private func ensureMiniCPMAudioEngineRunning() throws {
        if minicpmAudioEngine == nil || minicpmAudioPlayerNode == nil {
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: nil)
            minicpmAudioEngine = engine
            minicpmAudioPlayerNode = player
        }

        guard let engine = minicpmAudioEngine, let player = minicpmAudioPlayerNode else {
            throw NSError(domain: "RealtimeAVService", code: -63, userInfo: [NSLocalizedDescriptionKey: "播放失败"])
        }

        if !engine.isRunning {
            try engine.start()
        }
        if !player.isPlaying {
            player.play()
        }
    }

    private func scheduleMiniCPMFloat32PCM(_ data: Data) throws {
        guard let player = minicpmAudioPlayerNode else {
            throw NSError(domain: "RealtimeAVService", code: -64, userInfo: [NSLocalizedDescriptionKey: "播放失败"])
        }
        let bytes = data.count - (data.count % MemoryLayout<Float>.size)
        guard bytes > 0 else {
            throw NSError(domain: "RealtimeAVService", code: -65, userInfo: [NSLocalizedDescriptionKey: "音频解码失败"])
        }
        let frameCount = AVAudioFrameCount(bytes / MemoryLayout<Float>.size)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: minicpmNativePlaybackSampleRate,
                                   channels: 1,
                                   interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = buffer.floatChannelData?[0] else {
            throw NSError(domain: "RealtimeAVService", code: -66, userInfo: [NSLocalizedDescriptionKey: "音频解码失败"])
        }
        buffer.frameLength = frameCount
        var samples = [Float](repeating: 0, count: Int(frameCount))
        samples.withUnsafeMutableBytes { dst in
            _ = data.prefix(bytes).copyBytes(to: dst.bindMemory(to: UInt8.self))
        }
        samples.withUnsafeBufferPointer { src in
            channel.update(from: src.baseAddress!, count: samples.count)
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.finishMiniCPMAudioSegment()
        }
    }

    private func scheduleMiniCPMWAV(_ data: Data) throws {
        guard let player = minicpmAudioPlayerNode else {
            throw NSError(domain: "RealtimeAVService", code: -67, userInfo: [NSLocalizedDescriptionKey: "播放失败"])
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chatagi_native_\(UUID().uuidString).wav")
        try data.write(to: url, options: [.atomic])
        let file = try AVAudioFile(forReading: url)
        player.scheduleFile(file, at: nil) { [weak self] in
            try? FileManager.default.removeItem(at: url)
            self?.finishMiniCPMAudioSegment()
        }
    }

    private func minicpmStopAudioPlayback(clearQueue: Bool, logStop: Bool = true) {
        if logStop {
            print("[ChatAGINativeRealtime] playback_stop")
        }
        minicpmPlaybackDrainChecks += 1
        minicpmAudioPlayerNode?.stop()
        minicpmAudioEngine?.stop()
        minicpmAudioEngine?.reset()
        vpAudio?.clearPlayback()
        minicpmAudioIsPlaying = false
        minicpmPlaybackStarted = false
        minicpmContinuousPlaybackActive = false
        minicpmAudioQueueEndOfTurn = false
        if clearQueue {
            minicpmAudioQueue.removeAll(keepingCapacity: true)
            print("[ChatAGINativeRealtime] audio_queue_length=0")
        }
        localPlaybackFinished = true
        qwenPlaybackLikelyActive = false
        qwenPlaybackGateHoldUntil = nil
        lastPlaybackStoppedAt = Date()
    }

    private func minicpmCheckContinuousPlaybackDrain(token: Int) {
        guard activeProvider == .minicpm else { return }
        guard token == minicpmPlaybackDrainChecks else { return }
        guard minicpmAudioQueueEndOfTurn else { return }
        guard minicpmAudioQueue.isEmpty, !minicpmAudioIsPlaying else {
            workQueue.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.minicpmCheckContinuousPlaybackDrain(token: token)
            }
            return
        }

        let bufferedFrames = vpAudio?.playbackBufferedFrames ?? 0
        if bufferedFrames > 0 {
            workQueue.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.minicpmCheckContinuousPlaybackDrain(token: token)
            }
            return
        }

        minicpmContinuousPlaybackActive = false
        finishMiniCPMAudioQueue()
    }

    private func ensurePlaybackEngineRunning() {}

    private func stopQwenAudioIO() {
        vpAudio?.stop()
        vpAudio = nil
        qwenPlaybackLikelyActive = false
        qwenPlaybackGateHoldUntil = nil
        localPlaybackFinished = true
        minicpmPendingFloat32.removeAll(keepingCapacity: true)
        minicpmPendingMaxRMS = 0
        minicpmPendingForceListen = false
        minicpmBargeHoldMs = 0
        minicpmPlaybackPendingPCM16.removeAll(keepingCapacity: true)
        minicpmStopAudioPlayback(clearQueue: true, logStop: false)
        minicpmEndOfTurnReceived = false
        minicpmPlaybackDrainChecks = 0
    }

    func clearPlaybackBuffer(enterTailHold: Bool = true) {
        semanticDiag("CLEAR_PLAYBACK_BUFFER enterTailHold=\(enterTailHold)")
        vpAudio?.clearPlayback()
        if activeProvider == .minicpm {
            if !minicpmPlaybackPendingPCM16.isEmpty {
                minicpmDroppedAudioCount += 1
            }
            minicpmPlaybackPendingPCM16.removeAll(keepingCapacity: true)
            minicpmStopAudioPlayback(clearQueue: true)
            minicpmPlaybackStarted = false
            minicpmEndOfTurnReceived = false
            minicpmPlaybackDrainChecks += 1   // 让排空检查失效
            print("[ChatAGIPlayback] cleared enterTailHold=\(enterTailHold) dropped_audio_count=\(minicpmDroppedAudioCount)")
        }
        qwenPlaybackLikelyActive = false
        qwenPlaybackGateHoldUntil = enterTailHold ? Date().addingTimeInterval(qwenPlaybackTailHold) : nil
        localPlaybackFinished = true
        lastPlaybackStoppedAt = Date()
    }

    // ============================================================
    // ✅ qwen_selfhost 客户端 VAD 状态机（规格 §6/§7/§9/§10）
    //    listening → userSpeaking → committing → assistantThinking
    //    → assistantSpeaking →（tail hold）→ listening
    //    播放/尾音期插话（活性打断）：assistantSpeaking → interrupted(瞬时) → listening
    //    → 下一帧人声走普通开口路径 → userSpeaking。任何事件丢失由 watchdog 兜底回 listening。
    // ============================================================
    private func shHandleMicFrame(pcm16Data: Data, rms: Float, b64: String) {
        let now = Date()
        // 16k mono PCM16：每毫秒 32 字节
        let frameMs = Double(pcm16Data.count) / 32.0

        // ✅ peak 诊断：和 rms 一起打印，用来区分"整体增益低"（peak 也低）
        //    与"短促削顶/采样异常"（peak 高 rms 低）。160 个样本，开销可忽略。
        var peak: Float = 0
        pcm16Data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for s in p {
                let v = abs(Float(s)) / 32768.0
                if v > peak { peak = v }
            }
        }

        // 思考期（final=true 已发、回复未出声）也按"助手占用"处理：
        // 只有强插话能开口，避免把生成中的旧回复和新输入搅在一起。
        // ⚠️ 不再把 shAwaitingStaleDone 算进来：打断后旧轮 delta 由接收侧丢弃即可，
        //    上行侧必须立刻回 listening 正常开口，否则打断完用户说话还要再过插话高门槛。
        let assistantAudible = qwenPlaybackLikelyActive || isResponseInProgress
            || selfhostState == "assistantThinking"
        let inTailHold: Bool = {
            guard let t = lastPlaybackStoppedAt else { return false }
            return now.timeIntervalSince(t) * 1000.0 < shTailHoldMs
        }()

        // ✅ 动态噪声底校准：启动后采集前 500ms 的安静帧（排除播放期/已开口/明显人声帧），
        //    ambientRMS = 平均值；gateRMS = max(ambient*3, 0.00015)，bargeGate = max(ambient*8, 0.0006)。
        //    校准完成前 shGateRMS 保持临时宽松值 0.0002（用户一上来就说话也能开 turn）。
        if !shAmbientLocked {
            if !selfhostTurnOpen, !assistantAudible, rms < 0.005 {
                shAmbientAccumSum += rms * Float(frameMs)
                shAmbientAccumMs += frameMs
                if shAmbientAccumMs >= shAmbientCalibMs {
                    shAmbientRMS = shAmbientAccumSum / Float(shAmbientAccumMs)
                    shGateRMS = max(shAmbientRMS * 3.0, shGateFloor)
                    shBargeGateRMS = max(shAmbientRMS * 8.0, shBargeGateFloor)
                    shAmbientLocked = true
                    print("[QwenSelfhostRT] ambient calibrated ambientRMS=\(String(format: "%.5f", shAmbientRMS)) gateRMS=\(String(format: "%.5f", shGateRMS)) bargeGateRMS=\(String(format: "%.5f", shBargeGateRMS))")
                }
            }
        } else if !selfhostTurnOpen, !assistantAudible, !inTailHold, rms < shGateRMS {
            // ✅ 校准后慢速 EMA 漂移跟踪（只用静音帧），门槛随环境噪声缓慢自适应，floor 兜底。
            shAmbientRMS = shAmbientRMS * 0.98 + rms * 0.02
            shGateRMS = max(shAmbientRMS * 3.0, shGateFloor)
            shBargeGateRMS = max(shAmbientRMS * 8.0, shBargeGateFloor)
        }

        // ✅ 验收链路日志：rms / peak / ambientRMS / gateRMS / turnOpen / state 全打印。
        //    前 10 帧逐帧打印（覆盖校准期），之后每 25 帧（约 5 秒，VPIO 10ms 帧则约 0.25s 一条
        //    时改为每 100 帧）打一条心跳。
        shMicFrameCount += 1
        let heartbeatEvery = frameMs <= 20 ? 100 : 25
        if shMicFrameCount <= 10 || shMicFrameCount % heartbeatEvery == 0 {
            print("[QwenSelfhostRT] voice callback frames=\(shMicFrameCount) bytes=\(pcm16Data.count) rms=\(String(format: "%.5f", rms)) peak=\(String(format: "%.5f", peak)) ambientRMS=\(String(format: "%.5f", shAmbientRMS)) gateRMS=\(String(format: "%.5f", shGateRMS)) turnOpen=\(selfhostTurnOpen) state=\(selfhostState)")
        }

        // —— 用户说话中：聚合 200ms 上行，静音达标后判定提交/丢弃 ——
        if selfhostTurnOpen {
            shPendingPCM.append(pcm16Data)
            if shPendingPCM.count >= shAppendChunkBytes {
                shFlushPendingAppend(rms: rms)
            }
            if rms > shTurnMaxRMS { shTurnMaxRMS = rms }
            if rms >= shGateRMS { shLastVoiceAt = now }

            let silenceMs = now.timeIntervalSince(shLastVoiceAt ?? now) * 1000.0
            let voicedSeconds = (shLastVoiceAt ?? now).timeIntervalSince(shTurnStartAt ?? now)

            if silenceMs >= shSilenceToCommitMs {
                if voicedSeconds >= shMinAudioSeconds && shTurnMaxRMS >= shGateRMS {
                    // 规格 §7：录够 0.8s 有效人声 + 静音 800ms → final=true（经 commit gate）。
                    selfhostTurnOpen = false
                    qwenUserIsSpeaking = false
                    shFlushPendingAppend(rms: rms)   // ✅ 提交前把不足 200ms 的尾巴也发出去
                    shSetState("committing")
                    shTrySendFinalCommit(seconds: voicedSeconds)
                } else {
                    // 规格 §7：没有有效人声/太短 → 不发 final=true，丢弃本轮
                    selfhostTurnOpen = false
                    qwenUserIsSpeaking = false
                    shPendingPCM.removeAll(keepingCapacity: true)
                    print("[QwenSelfhostRT] turn discarded (voiced=\(String(format: "%.2f", voicedSeconds))s maxRMS=\(String(format: "%.5f", shTurnMaxRMS)) gateRMS=\(String(format: "%.5f", shGateRMS))) no final commit")
                    shSetState("listening")
                }
            }
            return
        }

        // —— 助手播放中 / 尾音保护期：只有强插话能开口（规格 §9/§10，活性打断：本地 RMS 判定）——
        if assistantAudible || inTailHold {
            if rms >= shBargeGateRMS {
                shBargeAccumMs += frameMs
                if shBargeAccumMs >= shBargeInHoldMs {
                    shBargeAccumMs = 0
                    selfhostTurnId += 1
                    // 旧响应仍在飞：置位旧轮收尾旗标，丢弃其全部迟到 delta 直到旧轮 audio.done
                    if isResponseInProgress || qwenPlaybackLikelyActive || selfhostState == "assistantThinking" {
                        shAwaitingStaleDone = true
                        shInterruptAt = now
                    }
                    clearPlaybackBuffer(enterTailHold: false)  // 立即停播 + 清队列
                    isResponseInProgress = false
                    // ✅ 仿旧阿里链路：打断 = 本地 speech_started（清播放 + gate 丢旧 delta），
                    //    但状态机不停在 interrupted —— 立刻回 listening，下一帧用户的声音
                    //    走普通开口路径（gateRMS）开新 turn。interrupted 只作为瞬时日志。
                    print("[QwenSelfhostRT] interrupt local_stop turn=\(selfhostTurnId) rms=\(String(format: "%.5f", rms)) bargeGateRMS=\(String(format: "%.5f", shBargeGateRMS)) -> listening")
                    shSetState("interrupted")
                    shSetState("listening")
                    lastPlaybackStoppedAt = nil   // 打断不进尾音保护：用户正在说话，立刻允许开口
                }
            } else {
                shBargeAccumMs = max(0, shBargeAccumMs - frameMs)
            }
            return
        }

        // —— 普通监听期起声 ——
        shBargeAccumMs = 0
        if rms >= shGateRMS {
            shOpenTurn(now: now, rms: rms, b64: b64)
        }
    }

    // ✅ 二：唯一的 final=true 出口。assistantThinking/assistantSpeaking 或旧响应未结束时拒绝/暂存，
    //    一轮只发一次，拦截 "Generation already in progress, ignoring commit"。
    @discardableResult
    private func shTrySendFinalCommit(seconds: Double) -> Bool {
        if shFinalCommitSentForTurn {
            print("[QwenSelfhostRT] ignore commit reason=already_committed state=\(selfhostState) turn=\(selfhostTurnId)")
            return false
        }
        if selfhostState == "assistantSpeaking" || selfhostState == "assistantThinking"
            || isResponseInProgress || shAwaitingStaleDone {
            // 旧响应仍在生成 → 暂存，等旧轮 audio.done 再补发，避免服务端 ignoring commit。
            if !shPendingFinalCommit {
                shPendingFinalCommit = true
                shPendingFinalCommitSeconds = seconds
                print("[QwenSelfhostRT] ignore commit reason=generation_in_progress state=\(selfhostState) (deferred turn=\(selfhostTurnId))")
            }
            return false
        }
        shFinalCommitSentForTurn = true
        shPendingFinalCommit = false
        shFinalCommitAt = Date()
        sendClientEvent(["type": "input_audio_buffer.commit", "final": true])
        print("[QwenSelfhostRT] commit final=true turn=\(selfhostTurnId) seconds=\(String(format: "%.2f", seconds)) chunks=\(shTurnChunks)")
        shSetState("assistantThinking")
        return true
    }

    // ✅ 旧轮收尾后，若有被暂存的 final=true，补发（在 response.audio.done 时调用）。
    private func shFlushPendingFinalCommitIfAny() {
        guard isSelfhostQwen, shPendingFinalCommit else { return }
        guard selfhostState != "assistantSpeaking", selfhostState != "assistantThinking",
              !isResponseInProgress, !shAwaitingStaleDone else { return }
        shPendingFinalCommit = false
        let secs = shPendingFinalCommitSeconds
        shPendingFinalCommitSeconds = 0
        print("[QwenSelfhostRT] flush deferred commit turn=\(selfhostTurnId)")
        shTrySendFinalCommit(seconds: secs)
    }

    // ============================================================
    // ✅ 每轮节奏看门狗（仿旧阿里链路"服务端事件 + 本地兜底"双保险）。
    //    selfhost 没有 server_vad / response.done 可靠闭环，任何一个事件丢失
    //    都会卡死状态机。500ms 巡检一次，规则：
    //    1) 打断后旧轮 audio.done 超 3s 不来 → 强制清 staleDone + 补发暂存 commit
    //    2) committing 卡超 3s（暂存 commit 没机会补发）→ 强制补发 / 回 listening
    //    3) assistantThinking 超 15s 无任何 delta → 服务端没回，放弃本轮回 listening
    //    4) assistantSpeaking 但播放队列已排空且 1.5s 无新 delta（audio.done 丢失）
    //       → 走 finishResponseCycle 正常收尾回 listening
    //    5) interrupted 残留超 1s（理论不会发生，兜底）→ 回 listening
    // ============================================================
    private func shStartWatchdog(callId: UUID) {
        shStopWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self, callId == self.currentCallId, self.isSelfhostQwen, self.isRunning else { return }
            let now = Date()
            let stateAgeS = now.timeIntervalSince(self.shStateChangedAt)

            // 1) staleDone 超时：旧轮 done 永远不来 → 解锁 + 补发暂存 commit
            if self.shAwaitingStaleDone, let t = self.shInterruptAt, now.timeIntervalSince(t) > 3.0 {
                self.shAwaitingStaleDone = false
                self.shInterruptAt = nil
                print("[QwenSelfhostRT] watchdog: staleDone timeout(3s) -> cleared")
                self.shFlushPendingFinalCommitIfAny()
            }

            // 2) committing 卡死：暂存 commit 的补发时机（旧轮 audio.done）一直没来
            if self.selfhostState == "committing", stateAgeS > 3.0 {
                if self.shPendingFinalCommit {
                    print("[QwenSelfhostRT] watchdog: committing stuck \(String(format: "%.1f", stateAgeS))s -> force flush deferred commit")
                    self.shAwaitingStaleDone = false
                    self.isResponseInProgress = false
                    self.shFlushPendingFinalCommitIfAny()
                } else if !self.shFinalCommitSentForTurn {
                    print("[QwenSelfhostRT] watchdog: committing stuck without commit -> listening")
                    self.shSetState("listening")
                }
            }

            // 3) assistantThinking 超时：commit 发了，服务端始终没回任何 delta
            if self.selfhostState == "assistantThinking",
               let t = self.shFinalCommitAt, now.timeIntervalSince(t) > 15.0,
               self.shLastAudioDeltaAt == nil || (self.shLastAudioDeltaAt ?? .distantPast) < t {
                print("[QwenSelfhostRT] watchdog: assistantThinking timeout(15s) no response -> listening")
                self.isResponseInProgress = false
                self.serverAudioFinished = false
                self.shFinalCommitAt = nil
                self.shSetState("listening")
            }

            // 4) assistantSpeaking 排空但 audio.done 丢失：本地收尾
            if self.selfhostState == "assistantSpeaking",
               (self.vpAudio?.playbackBufferedFrames ?? 0) == 0,
               let t = self.shLastAudioDeltaAt, now.timeIntervalSince(t) > 1.5 {
                print("[QwenSelfhostRT] watchdog: playback drained, audio.done missing -> finish cycle")
                self.serverAudioFinished = true
                self.markQwenPlaybackStoppedSoon()
                self.tryFinishResponseIfPlaybackCompleted(reason: "selfhost_watchdog_drain")
                if self.selfhostState == "assistantSpeaking" { self.shSetState("listening") }
            }

            // 5) interrupted 残留兜底
            if self.selfhostState == "interrupted", stateAgeS > 1.0 {
                print("[QwenSelfhostRT] watchdog: interrupted residue -> listening")
                self.shSetState("listening")
            }
        }
        timer.resume()
        shWatchdogTimer = timer
        print("[QwenSelfhostRT] watchdog started (500ms)")
    }

    private func shStopWatchdog() {
        shWatchdogTimer?.cancel()
        shWatchdogTimer = nil
    }

    private func shOpenTurn(now: Date, rms: Float, b64: String) {
        selfhostTurnOpen = true
        shFinalCommitSentForTurn = false      // 新一轮：允许一次 final=true
        // ✅ 仿旧阿里链路 userIsSpeaking gate：用户开口期间到达的旧 audio.delta 全部丢弃
        //    （speech_started→true / speech_stopped→false 的本地等价物：开 turn→true / 提交或丢弃→false）。
        qwenUserIsSpeaking = true
        shTurnStartAt = now
        shLastVoiceAt = now
        shTurnMaxRMS = rms
        shTurnChunks = 0
        shPendingPCM.removeAll(keepingCapacity: true)
        markAssistantNewTurn()
        shSetState("userSpeaking")
        print("[QwenSelfhostRT] voice.detected rms=\(String(format: "%.5f", rms)) gateRMS=\(String(format: "%.5f", shGateRMS))")
        print("[QwenSelfhostRT] commit start final=false turn=\(selfhostTurnId)")
        sendClientEvent(["type": "input_audio_buffer.commit", "final": false])
        // ✅ 起声帧立即作为 chunk=1 上行（低延迟），之后按 200ms 聚合。
        if let first = Data(base64Encoded: b64), !first.isEmpty {
            shTurnChunks += 1
            sendClientEvent(["type": "input_audio_buffer.append", "audio": b64], droppable: true)
            print("[QwenSelfhostRT] append chunk=\(shTurnChunks) bytes=\(first.count) rms=\(String(format: "%.5f", rms)) (first)")
        }
    }

    // ✅ 聚合上行：把缓冲里的 PCM 作为一个 append chunk 发出（≥200ms 或提交前的尾巴）。
    private func shFlushPendingAppend(rms: Float) {
        guard !shPendingPCM.isEmpty else { return }
        let chunk = shPendingPCM
        shPendingPCM.removeAll(keepingCapacity: true)
        shTurnChunks += 1
        sendClientEvent(["type": "input_audio_buffer.append", "audio": chunk.base64EncodedString()], droppable: true)
        if shTurnChunks <= 3 || shTurnChunks % 5 == 0 {
            print("[QwenSelfhostRT] append chunk=\(shTurnChunks) bytes=\(chunk.count) rms=\(String(format: "%.5f", rms))")
        }
    }


    private func startMiniCPMQueueWatchdog(position: String) {
        minicpmQueueWatchdogToken += 1
        let token = minicpmQueueWatchdogToken
        workQueue.asyncAfter(deadline: .now() + 12.0) { [weak self] in
            guard let self else { return }
            guard token == self.minicpmQueueWatchdogToken, self.isMiniCPM, !self.minicpmWarmReady else { return }
            print("[ChatAGINativeRealtime] worker busy queue_position=\(position)")
            DispatchQueue.main.async {
                self.delegate?.realtimeAVService(self, didUpdateStatus: "worker 正忙，请停止其他语音页面或稍后再试。")
            }
        }
    }

    private func minicpmSubmitBufferedAudio(reason: String) {
        guard activeProvider == .minicpm, minicpmSessionReady else { return }
        guard !minicpmPendingFloat32.isEmpty else { return }

        let now = Date()
        if let last = minicpmLastSubmitAt, now.timeIntervalSince(last) < 0.45 {
            return
        }
        minicpmLastSubmitAt = now

        let tailBytes = Int(minicpmSampleRateIn * minicpmTailSilenceMs / 1000.0) * 4
        if tailBytes > 0 {
            minicpmPendingFloat32.append(Data(repeating: 0, count: tailBytes))
        }
        print("[ChatAGINativeRealtime] silence_submit reason=\(reason) buffered_bytes=\(minicpmPendingFloat32.count)")
        minicpmFlushPendingFloat32(forceListen: minicpmPendingForceListen, reason: reason)
        minicpmPendingForceListen = false
        DispatchQueue.main.async {
            self.delegate?.realtimeAVService(self, didUpdateStatus: "正在思考")
        }
    }

    private func minicpmFlushPendingFloat32(forceListen: Bool, reason: String) {
        guard !minicpmPendingFloat32.isEmpty else { return }
        let chunk = minicpmPendingFloat32
        minicpmPendingFloat32.removeAll(keepingCapacity: true)

        let chunkRMS = minicpmPendingMaxRMS
        minicpmPendingMaxRMS = 0

        minicpmAppendCount += 1
        let seconds = Double(chunk.count / 4) / minicpmSampleRateIn
        print("[ChatAGINativeRealtime] audio_chunk sent chunk=\(minicpmAppendCount) seconds=\(String(format: "%.2f", seconds)) bytes=\(chunk.count) rms=\(String(format: "%.5f", chunkRMS)) force_listen=\(forceListen) reason=\(reason)")

        sendClientEvent([
            "type": "input_audio_buffer.append",
            "audio": chunk.base64EncodedString(),
            "force_listen": forceListen
        ], droppable: true)
    }

    // ✅ MiniCPM-o 官方全双工上行：聚合 250ms float32 PCM 再发送。
    //    - 16k mono float32 little-endian
    //    - 无 commit/final
    //    - 插话时通过 force_listen=true 告诉服务端转入 listen，同时本地清旧播放队列。
    private func minicpmHandleMicChunk(_ pcm16Data: Data, rms: Float) {
        guard activeProvider == .minicpm else { return }
        // ✅ 握手门控：未到 ACTIVE（session.created）前不上行，避免 not_ready。
        guard minicpmSessionReady else { return }

        let f32 = Self.pcm16ToFloat32LE(pcm16Data)
        guard !f32.isEmpty else { return }

        let samples = f32.count / 4
        let chunkMs = (Double(samples) / minicpmSampleRateIn) * 1000.0

        // ✅ 全双工（对齐 6.2 GPT Realtime / 官方 realtime-session.js）：
        //    麦克风【始终连续上传】，不在助手说话时静音——回声由 VoiceProcessingIO 的硬件 AEC 消除。
        //    服务端自己做 VAD 决定 listen/speak，并通过 response.listen 通知客户端停播。
        //    这里只额外做一个"强插话提速"：助手说话期检测到明显人声并持续一小段，
        //    就主动 force_listen=true + 立刻清本地播放，让打断更跟手（服务端随后回 response.listen）。
        let assistantSpeaking = qwenPlaybackLikelyActive
            || minicpmTurnActive
            || minicpmPlaybackStarted
            || minicpmAudioIsPlaying
            || !minicpmAudioQueue.isEmpty
            || ((vpAudio?.playbackBufferedFrames ?? 0) > 0)
            || !minicpmPlaybackPendingPCM16.isEmpty

        if assistantSpeaking {
            if rms > minicpmBargeRMS {
                minicpmBargeHoldMs += chunkMs
                if minicpmBargeHoldMs >= minicpmBargeHoldMsRequired && !minicpmPendingForceListen {
                    minicpmPendingForceListen = true
                    print("[ChatAGINativeRealtime] barge_in")
                    print("[ChatAGINativeRealtime] playback_stop")
                    print("[ChatAGINativeRealtime] barge_in rms=\(String(format: "%.5f", rms)) holdMs=\(Int(minicpmBargeHoldMs)) -> force_listen")
                    print("[ChatAGINativeRealtime] playback_stop reason=barge_in")
                    minicpmPlaybackPendingPCM16.removeAll(keepingCapacity: true)
                    minicpmStopAudioPlayback(clearQueue: true, logStop: false)
                    clearPlaybackBuffer(enterTailHold: false)
                    minicpmTurnActive = false
                    minicpmPlaybackStarted = false
                    minicpmEndOfTurnReceived = false
                    markQwenPlaybackStoppedSoon()
                }
            } else if rms < (minicpmBargeRMS * 0.5) {
                minicpmBargeHoldMs = 0
            }
        } else {
            minicpmBargeHoldMs = 0
        }

        // ✅ 始终累积并按 real-time 节奏（每满 0.5s）上行——这就是"全双工，客户端始终在发 append"。
        minicpmPendingFloat32.append(f32)
        if rms > minicpmPendingMaxRMS {
            minicpmPendingMaxRMS = rms
        }

        if rms > minicpmMinVoiceRMS {
            if !minicpmUserSpeaking {
                minicpmUserSpeaking = true
                minicpmSpeechMs = 0
                minicpmSilenceMs = 0
                minicpmLastSubmitAt = nil
            }
            minicpmSpeechMs += chunkMs
            minicpmSilenceMs = 0
            if minicpmSpeechMs >= minicpmMaxRecordMs {
                minicpmSubmitBufferedAudio(reason: "max_record")
                minicpmUserSpeaking = false
                minicpmSpeechMs = 0
                minicpmSilenceMs = 0
            }
        } else if minicpmUserSpeaking {
            minicpmSilenceMs += chunkMs
            if minicpmSpeechMs >= minicpmMinRecordMs && minicpmSilenceMs >= minicpmSilenceSubmitMs {
                minicpmSubmitBufferedAudio(reason: "silence")
                minicpmUserSpeaking = false
                minicpmSpeechMs = 0
                minicpmSilenceMs = 0
            }
        }

        while minicpmPendingFloat32.count >= minicpmAppendChunkBytes {
            let chunk = Data(minicpmPendingFloat32.prefix(minicpmAppendChunkBytes))
            minicpmPendingFloat32.removeSubrange(0..<minicpmAppendChunkBytes)

            let forceListen = minicpmPendingForceListen
            minicpmPendingForceListen = false
            let chunkRMS = minicpmPendingMaxRMS
            minicpmPendingMaxRMS = 0

            minicpmAppendCount += 1
            let seconds = Double(chunk.count / 4) / minicpmSampleRateIn
            if minicpmAppendCount <= 3 || minicpmAppendCount % 6 == 0 || forceListen {
                print("[ChatAGINativeRealtime] audio_chunk sent chunk=\(minicpmAppendCount) seconds=\(String(format: "%.2f", seconds)) bytes=\(chunk.count) rms=\(String(format: "%.5f", chunkRMS)) force_listen=\(forceListen)")
            }

            sendClientEvent([
                "type": "input_audio_buffer.append",
                "audio": chunk.base64EncodedString(),
                "force_listen": forceListen
            ], droppable: true)
        }
    }

    private func startQwenAudioCapture(callId: UUID) {
        let driver = VoiceProcessingIOAudioDriver(
            inputSampleRate: 16000,
            outputSampleRate: 24000,
            inputHandler: { [weak self] pcm16Data, rms in
                guard let self else { return }
                self.workQueue.async {
                    guard callId == self.currentCallId, self.isWebSocketProvider, !self.isMuted else { return }

                    // ✅ 自部署 MiniCPM-o（机器人 6.1）：全双工，麦克风持续上传 float32 PCM 16k mono。
                    //    重要：不要每个 10~20ms VPIO 回调就发一条 append；MiniCPM 官方 audio-duplex
                    //    文档/前端 Demo 更适合 0.5~1s 音频块。这里聚合 1s 后再 append，避免服务端
                    //    长时间 LISTEN / prefill 而不 generate。
                    if self.activeProvider == .minicpm {
                        self.minicpmHandleMicChunk(pcm16Data, rms: rms)
                        return
                    }

                    let b64 = pcm16Data.base64EncodedString()

                    if self.activeProvider == .pipeline {
                        if rms > self.clientVADSilenceThreshold {
                            VoiceprintGate.shared.isPlaybackActive = self.pipelinePlaybackActive
                            VoiceprintGate.shared.observe(pcm16Data: pcm16Data, rms: rms)
                            self.clientVADSilenceFrames = 0
                            if !self.clientVADSpeaking {
                                self.clientVADSpeaking = true
                                self.clientVADCommitted = false
                                self.semanticDiag("PIPELINE_CLIENT_VAD_STARTED rms=\(String(format: "%.4f", rms)) active_response=\(self.isResponseInProgress) playback=\(self.pipelinePlaybackActive) no_auto_cancel")
                            }
                            self.sendClientEvent(["type": "input_audio_buffer.append", "audio": b64], droppable: true)
                        } else if self.clientVADSpeaking {
                            self.sendClientEvent(["type": "input_audio_buffer.append", "audio": b64], droppable: true)
                            self.clientVADSilenceFrames += 1
                            if self.clientVADSilenceFrames >= self.clientVADSilenceFramesToCommit && !self.clientVADCommitted {
                                self.clientVADCommitted = true
                                self.clientVADSpeaking = false
                                self.clientVADSilenceFrames = 0
                                self.semanticDiag("PIPELINE_CLIENT_VAD_COMMIT silence_frames=\(self.clientVADSilenceFrames)")
                                self.sendClientEvent(["type": "input_audio_buffer.commit"])
                                self.markAssistantNewTurn()
                            }
                        }
                        return
                    }

                    // ✅ 自部署 vLLM-Omni（qwen_selfhost）官方协议：客户端 VAD 驱动一轮输入
                    //    （规格 §6/§7/§9/§10：最短人声门槛、静音提交、高阈值持续插话、tail hold）。
                    if self.isSelfhostQwen {
                        self.shHandleMicFrame(pcm16Data: pcm16Data, rms: rms, b64: b64)
                        return
                    }

                    // ✅ Qwen 官方实时语音路径：不在客户端用 RMS 做本地“伪打断”。
                    // 打断由阿里服务端 server_vad 触发 speech_started 事件，客户端
                    // 在 handleSpeechStarted 里清播放 + cancel + 设 user_speaking gate。
                    // 这里只负责把麦克风 PCM 持续上传给 Qwen。
                    if self.activeProvider == .qwen {
                        self.sendClientEvent(["type": "input_audio_buffer.append", "audio": b64], droppable: true)
                        return
                    }

                    self.sendClientEvent(["type": "input_audio_buffer.append", "audio": b64], droppable: true)
                }
            },
            playbackUnderrunHandler: { [weak self] in
                guard let self else { return }
                self.workQueue.async {
                    self.markQwenPlaybackStoppedSoon()
                    self.tryFinishResponseIfPlaybackCompleted(reason: "vpio_playback_underrun")
                }
            }
        )

        do {
            try driver.start()
            vpAudio = driver
            // ✅ 验收链路日志：麦克风（VoiceProcessingIO）真正启动成功。
            if isMiniCPM {
                print("[ChatAGINativeRealtime] mic started")
            } else if isSelfhostQwen {
                print("[QwenSelfhostRT] mic started inputSR=16000 outputSR=24000 (VoiceProcessingIO)")
            } else {
                print("[RealtimeAV][qwen] mic started (VoiceProcessingIO)")
            }
        } catch {
            // ✅ 修复静默失败：原来只回调 didFail，Console 无任何 [QwenSelfhostRT] 痕迹，
            //    且 socket 不清理 → 表现为 RunPod open→closed、真机无声、无日志。
            //    VPIO 在真机上启动失败（蓝牙路由切换 / 其他 App 占用 / -10851 等）必须可见。
            print("[QwenSelfhostRT] mic start FAILED error=\((error as NSError).domain) code=\((error as NSError).code) desc=\(error.localizedDescription)")
            failAndReset(callId: callId, status: "麦克风启动失败", error: error)
        }
    }

    // ✅ MiniCPM-o 全双工音频转换：内部音频引擎是 PCM16，MiniCPM 协议用 float32 PCM。
    //    上行：麦克风 PCM16(Int16) → float32 LE（归一化到 [-1, 1]）。
    static func pcm16ToFloat32LE(_ data: Data) -> Data {
        let n = data.count / 2
        guard n > 0 else { return Data() }
        var out = Data(count: n * 4)
        data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            let s = src.bindMemory(to: Int16.self)
            out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                let d = dst.bindMemory(to: Float32.self)
                for i in 0..<n {
                    d[i] = Float32(s[i]) / 32768.0
                }
            }
        }
        return out
    }

    static func isRIFFWAVE(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let bytes = [UInt8](data.prefix(12))
        return bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 &&
               bytes[8] == 0x57 && bytes[9] == 0x41 && bytes[10] == 0x56 && bytes[11] == 0x45
    }

    //    下行旧路径：MiniCPM float32 LE → PCM16(Int16)。
    static func float32LEToPcm16(_ data: Data) -> Data {
        let n = data.count / 4
        guard n > 0 else { return Data() }
        var out = Data(count: n * 2)
        data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            let s = src.bindMemory(to: Float32.self)
            out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                let d = dst.bindMemory(to: Int16.self)
                for i in 0..<n {
                    let v = max(-1.0, min(1.0, s[i]))
                    d[i] = Int16(v * 32767.0)
                }
            }
        }
        return out
    }

    static func pcm24ToPcm16(_ data: Data) -> Data {
        let count = data.count
        let alignedCount = count - (count % 3)
        guard alignedCount >= 3 else { return Data() }

        var out = Data(capacity: alignedCount / 3 * 2)
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i < alignedCount {
                out.append(bytes[i + 1])
                out.append(bytes[i + 2])
                i += 3
            }
        }
        return out
    }
}

extension RealtimeAVService {

    /// ✅ WebSocket 失败诊断：聚合 error / close code / close reason / ws_url / provider / apiKeyEmpty。
    private func qwenWSFailureDiag(_ error: Error) -> (console: String, ui: String) {
        let nsErr = error as NSError
        let desc = nsErr.localizedDescription
        let provider = isMiniCPM ? AppConfig.Realtime.chatAGINativeProvider : (isSelfhostQwen ? "qwen_selfhost" : activeProvider.rawValue)
        let closeCodeRaw = qwenWSTask?.closeCode.rawValue ?? -1
        var closeReason = "(none)"
        if let d = qwenWSTask?.closeReason, let s = String(data: d, encoding: .utf8), !s.isEmpty {
            closeReason = s
        }
        let console = "provider=\(provider) apiKeyEmpty=\(qwenConnectedApiKeyEmpty) closeCode=\(closeCodeRaw) closeReason=\(closeReason) ws_url=\(qwenConnectedWSURL) error=\(desc)"
        let ui = "WebSocket 连接失败: \(desc) [code=\(closeCodeRaw) reason=\(closeReason)] provider=\(provider) apiKeyEmpty=\(qwenConnectedApiKeyEmpty)"
        return (console, ui)
    }

    func connectQwenWebSocket(callId: UUID, wsURL: URL, apiKey: String) {
        var request = URLRequest(url: wsURL)
        request.timeoutInterval = 120

        // ✅ api_key 为空时不加 Authorization header（自部署 qwen_selfhost 通常无鉴权）。
        let apiKeyEmpty = apiKey.isEmpty
        let addAuthHeader = (activeProvider == .qwen && !apiKeyEmpty)
        if addAuthHeader {
            // ✅ 阿里 Qwen Realtime 官方 WebSocket 鉴权只需要 Authorization: Bearer DASHSCOPE_API_KEY。
            // 不发送 OpenAI-Beta，避免混用 OpenAI Realtime 头。
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        // ✅ 连接日志：自部署 Qwen3-Omni（qwen_selfhost）复用 .qwen WebSocket 链路，
        //    确认没有走 OpenAI WebRTC offer/answer。保留原始 provider=qwen_selfhost。
        let wireProvider = isMiniCPM ? AppConfig.Realtime.chatAGINativeProvider : (isSelfhostQwen ? "qwen_selfhost" : activeProvider.rawValue)
        qwenConnectedWSURL = wsURL.absoluteString
        qwenConnectedApiKeyEmpty = apiKeyEmpty
        if isMiniCPM {
            print("[ChatAGINativeRealtime] connecting...")
            print("[ChatAGINativeRealtime] ws connected begin title=\(AppConfig.Realtime.chatAGINativeTitle)")
        }
        print("[RealtimeAV][connect] provider=\(wireProvider)")
        print("[RealtimeAV][connect] activeProvider=\(activeProvider.rawValue)")
        print("[RealtimeAV][connect] transport=websocket(no-webrtc)")
        print("[RealtimeAV][connect] apiKeyEmpty=\(apiKeyEmpty)")
        print("[RealtimeAV][connect] authHeader=\(addAuthHeader)")
        print("[RealtimeAV][connect] ws_url=\(wsURL.absoluteString)")
        if isSelfhostQwen {
            selfhostTurnOpen = false
            selfhostAppendCount = 0
            selfhostTurnId = 0
            shBargeAccumMs = 0
            shAwaitingStaleDone = false
            shInterruptAt = nil
            shSetState("connecting")
            print("[QwenSelfhostRT] connect ws=\(wsURL.absoluteString)")
        }
        DispatchQueue.main.async {
            let status = self.isMiniCPM
                ? "连接中… \(AppConfig.Realtime.chatAGINativeTitle)"
                : "连接中… provider=\(wireProvider) activeProvider=\(self.activeProvider.rawValue) transport=websocket(no-webrtc) apiKeyEmpty=\(apiKeyEmpty) authHeader=\(addAuthHeader)"
            self.delegate?.realtimeAVService(self, didUpdateStatus: status)
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        // ✅ 修复假 open 日志：原来没有 URLSessionWebSocketDelegate，"websocket open" 是
        //    task.resume() 后立刻打印的，握手没完成也照打；对端/系统关闭也无回调。
        //    现在挂 delegate：didOpen 打真实 open，didClose 打 close code/reason（是谁先关一目了然）。
        let proxy = QwenWSDelegateProxy(service: self, callId: callId)
        let session = URLSession(configuration: config, delegate: proxy, delegateQueue: nil)
        qwenWSDelegateProxy = proxy
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 16 * 1024 * 1024

        qwenWSSession = session
        qwenWSTask = task

        task.resume()

        qwenIsReceivingMessages = true
        qwenLastServerEventAt = Date()
        qwenLastClientSendAt = Date()
        startQwenKeepaliveTimer(callId: callId)
        qwenReceiveLoop(callId: callId)

        // ✅ 自部署 MiniCPM-o 4.5（机器人 6.1）：等真实握手 didOpen 再发 session.update + 起麦克风，
        //    保证日志顺序：connect begin → websocket open → session.update sent → mic started。
        //    另挂 1.5s 兜底定时器：万一 didOpen 未触发，也能把链路拉起来。
        if isMiniCPM {
            isConnecting = false
            isRunning = true
            DispatchQueue.main.async {
                self.delegate?.realtimeAVServiceDidConnect(self)
                self.delegate?.realtimeAVService(self, didUpdateStatus: "已连接 (\(AppConfig.Realtime.chatAGINativeTitle))")
            }
            workQueue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, callId == self.currentCallId, self.isMiniCPM, !self.hasSentSessionUpdate else { return }
                print("[ChatAGINativeRealtime] websocket open (fallback timer)")
                self.startMiniCPMAfterOpen(callId: callId)
            }
            return
        }

        // ✅ 一/三：自部署 qwen_selfhost —— resume 后【立刻】发 session.update（URLSession 会
        //    把消息排队到握手完成后发出），同时立刻起音频上行。真实握手成功由 delegate 打
        //    "websocket open (handshake confirmed)"；这里只表示握手已发起。
        if isSelfhostQwen {
            print("[QwenSelfhostRT] websocket handshake started (waiting didOpen)")
            shMicFrameCount = 0
            shSawJsonAudioDelta = false
            shPendingPCM.removeAll(keepingCapacity: true)
            shFinalCommitAt = nil
            shLastAudioDeltaAt = nil
            shSetState("connected")
            sendSessionUpdateIfNeeded()            // 顶层 model + session{modalities,voice,instructions}
            flushQueuedEventsIfAny()
            startQwenAudioCapture(callId: callId)
            qwenAudioStarted = true
            isConnecting = false
            isRunning = true
            shSetState("listening")
            shStartWatchdog(callId: callId)   // ✅ 每轮节奏兜底巡检
            DispatchQueue.main.async {
                self.delegate?.realtimeAVServiceDidConnect(self)
                self.delegate?.realtimeAVService(self, didUpdateStatus: "已连接 (\(AppConfig.Realtime.chatAGINativeTitle))")
            }
            return
        }

        workQueue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, callId == self.currentCallId else { return }

            self.sendSessionUpdateIfNeeded()
            self.flushQueuedEventsIfAny()
            self.startQwenAudioCapture(callId: callId)
            self.qwenAudioStarted = true  // ✅ 音频已启动，现在可以发图片帧
            self.restartImageTickTimerIfNeeded()  // ✅ 在音频启动后才开图片流

            self.isConnecting = false
            self.isRunning = true

            // ✅ Qwen 官方打断由服务端 server_vad + 客户端 user_speaking gate 处理。
            // 不启动本地“旁听/声纹注册”，避免误解为另一路音频监听。
            let label = self.activeProvider == .pipeline ? "Pipeline" : "Qwen"
            DispatchQueue.main.async {
                self.delegate?.realtimeAVServiceDidConnect(self)
                self.delegate?.realtimeAVService(self, didUpdateStatus: "已连接 (\(label))")
            }
        }
    }

    private func startQwenKeepaliveTimer(callId: UUID) {
        stopQwenKeepaliveTimer()
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + 20, repeating: 20, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard callId == self.currentCallId, self.qwenIsReceivingMessages else { return }
            guard let ws = self.qwenWSTask else { return }

            ws.sendPing { [weak self] error in
                guard let self, let error else { return }
                self.workQueue.async {
                    guard callId == self.currentCallId, self.qwenIsReceivingMessages else { return }
                    let diag = self.qwenWSFailureDiag(error)
                    self.semanticDiag("qwen_ping_failed \(diag.console)")
                    print("[RealtimeAV][qwen][ws_ping_failure] \(diag.console)")
                    DispatchQueue.main.async {
                        self.delegate?.realtimeAVService(self, didUpdateStatus: diag.ui)
                    }
                    self.failAndReset(callId: callId, status: diag.ui, error: error)
                }
            }
        }
        timer.resume()
        qwenKeepaliveTimer = timer
    }

    private func stopQwenKeepaliveTimer() {
        qwenKeepaliveTimer?.cancel()
        qwenKeepaliveTimer = nil
    }

    private func qwenReceiveLoop(callId: UUID) {
        guard qwenIsReceivingMessages else { return }
        qwenWSTask?.receive { [weak self] result in
            guard let self else { return }
            self.workQueue.async {
                guard callId == self.currentCallId, self.qwenIsReceivingMessages else { return }

                switch result {
                case .success(let message):
                    self.qwenLastServerEventAt = Date()
                    switch message {
                    case .string(let text):
                        self.handleServerEvent(text)

                    case .data(let data):
                        // ✅ 自部署 MiniCPM-o：音频正常走 JSON response.output_audio.delta；
                        //    若某版本服务端改推二进制帧，复用同一套 WAV/Float32 PCM 播放队列。
                        if self.isMiniCPM {
                            if !data.isEmpty {
                                print("[ChatAGINativeRealtime] audio_delta_received bytes=\(data.count)")
                                self.isResponseInProgress = true
                                self.minicpmEnqueueAudioData(data)
                            }
                            break
                        }
                        // ✅ qwen_selfhost：音频形态自动检测。
                        //    规格说音频走 JSON response.audio.delta，但部分 vLLM-Omni 版本
                        //    实际用二进制帧推 PCM。原代码无条件丢弃二进制 → 那种服务端下永远无声。
                        //    规则：本会话收到过 JSON audio.delta → 永久忽略二进制（防双音轨）；
                        //         否则把二进制按 PCM16 24k 播放，并套用同样的打断/旧轮 gate。
                        if self.isSelfhostQwen {
                            if self.shSawJsonAudioDelta {
                                break
                            }
                            if self.shAwaitingStaleDone || self.qwenUserIsSpeaking {
                                print("[QwenSelfhostRT] recv binary bytes=\(data.count) dropped (stale/userSpeaking)")
                                break
                            }
                            if !data.isEmpty {
                                print("[QwenSelfhostRT] recv binary audio bytes=\(data.count) -> playback (服务端走二进制帧)")
                                self.isResponseInProgress = true
                                self.shLastAudioDeltaAt = Date()
                                self.shSetState("assistantSpeaking")
                                let wasActive = self.qwenPlaybackLikelyActive
                                self.markQwenPlaybackStarted()
                                if !wasActive { print("[QwenSelfhostRT] playback start turn=\(self.selfhostTurnId) (binary)") }
                                self.vpAudio?.appendPlaybackPCM16(data)
                            }
                            break
                        }
                        let pcm16: Data
                        if self.qwenPcm24ToPcm16 && data.count % 3 == 0 {
                            pcm16 = Self.pcm24ToPcm16(data)
                        } else {
                            pcm16 = data
                        }
                        if !pcm16.isEmpty {
                            self.markQwenPlaybackStarted()
                            self.vpAudio?.appendPlaybackPCM16(pcm16)
                        }

                    @unknown default:
                        break
                    }
                    self.qwenReceiveLoop(callId: callId)

                case .failure(let error):
                    guard callId == self.currentCallId else { return }
                    // ✅ WebSocket 连接失败：把真实错误（含 close code / reason / ws_url / provider /
                    //    apiKeyEmpty）显示到日志和 UI，不要只显示“网络问题”，便于 qwen_selfhost 排错。
                    let diag = self.qwenWSFailureDiag(error)
                    if self.isSelfhostQwen {
                        let code = self.qwenWSTask?.closeCode.rawValue ?? -1
                        var reason = "(none)"
                        if let d = self.qwenWSTask?.closeReason, let s = String(data: d, encoding: .utf8), !s.isEmpty { reason = s }
                        print("[QwenSelfhostRT] socket closed code=\(code) reason=\(reason)")
                    }
                    print("[RealtimeAV][qwen][ws_failure] \(diag.console)")
                    if self.isMiniCPM {
                        print("[ChatAGINativeRealtime] error=\(error.localizedDescription) ws_url=\(self.qwenConnectedWSURL)")
                        if !self.minicpmReconnectAttempted {
                            self.minicpmReconnectAttempted = true
                            print("[ChatAGINativeRealtime] reconnect_once")
                            DispatchQueue.main.async {
                                self.delegate?.realtimeAVService(self, didUpdateStatus: "连接失败，正在重连... \(error.localizedDescription) · \(self.qwenConnectedWSURL)")
                            }
                            self.hardReset(notify: false)
                            self.startInternal(mode: .audioOnly)
                            return
                        }
                        print("[ChatAGINativeRealtime] playback_error=WebSocket 失败 \(error.localizedDescription)")
                        DispatchQueue.main.async {
                            self.delegate?.realtimeAVService(self, didUpdateStatus: "WebSocket 失败")
                        }
                        self.failAndReset(callId: callId, status: "WebSocket 失败", error: NSError(domain: "RealtimeAVService", code: -68, userInfo: [NSLocalizedDescriptionKey: "WebSocket 失败"]))
                        return
                    }
                    self.semanticDiag("qwen_ws_failure \(diag.console)")
                    DispatchQueue.main.async {
                        self.delegate?.realtimeAVService(self, didUpdateStatus: diag.ui)
                    }
                    self.failAndReset(callId: callId, status: diag.ui, error: error)
                }
            }
        }
    }
}

// ✅ WebSocket 握手/关闭回调代理：URLSessionWebSocketDelegate 需要 NSObject，
//    单独小类持弱引用回调进 service，避免改 RealtimeAVService 的继承结构。
final class QwenWSDelegateProxy: NSObject, URLSessionWebSocketDelegate {
    private weak var service: RealtimeAVService?
    private let callId: UUID
    init(service: RealtimeAVService, callId: UUID) {
        self.service = service
        self.callId = callId
    }
    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocolName: String?) {
        service?.qwenWSDidOpen(callId: callId, protocolName: protocolName)
    }
    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        let r = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "(none)"
        service?.qwenWSDidClose(callId: callId, code: closeCode.rawValue, reason: r)
    }
}

extension RealtimeAVService {
    // ✅ 自部署 MiniCPM-o 音频双工握手（对齐官方 realtime-session.js）：
    //    open 后等 session.queue_done 再发 session.update；100ms 兜底（服务端可能跳过排队）。
    //    session.update 发出后预热麦克风驱动（AEC 校准），但 append 仍等 session.created（minicpmSessionReady）。
    fileprivate func startMiniCPMAfterOpen(callId: UUID) {
        guard callId == currentCallId, isMiniCPM else { return }
        workQueue.asyncAfter(deadline: .now() + 0.10) { [weak self] in
            guard let self, callId == self.currentCallId, self.isMiniCPM else { return }
            self.minicpmSendSessionUpdateAndStartMic(callId: callId)
        }
    }

    fileprivate func minicpmSendSessionUpdateAndStartMic(callId: UUID) {
        guard callId == currentCallId, isMiniCPM else { return }
        guard !minicpmSessionUpdateSent else { return }
        minicpmSessionUpdateSent = true
        sendSessionUpdateIfNeeded()        // → "[ChatAGINativeRealtime] session.update sent"
        flushQueuedEventsIfAny()
        if minicpmPrewarmOnly {
            DispatchQueue.main.async {
                self.delegate?.realtimeAVService(self, didUpdateStatus: "预热中")
            }
        } else {
            if vpAudio == nil {
                startQwenAudioCapture(callId: callId)
            }
            qwenAudioStarted = true
            print("[ChatAGINativeRealtime] mic_start")
        }
        // 兜底：万一 session.created 丢失（正常应必达），2.5s 后也解锁上行，避免通话静默卡死。
        workQueue.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, callId == self.currentCallId, self.isMiniCPM, !self.minicpmSessionReady else { return }
            print("[ChatAGINativeRealtime] session.created not seen in 2.5s -> enable appends (fallback)")
            self.minicpmSessionReady = true
            self.minicpmWarmReady = true
            print("[ChatAGINativeRealtime] warm_ready")
            DispatchQueue.main.async {
                self.delegate?.realtimeAVService(self, didUpdateStatus: self.minicpmPrewarmOnly ? "已就绪" : "正在听")
            }
        }
    }

    fileprivate func qwenWSDidOpen(callId: UUID, protocolName: String?) {
        workQueue.async { [weak self] in
            guard let self, callId == self.currentCallId else { return }
            if self.isMiniCPM {
                // ✅ 真实握手成功（URLSessionWebSocketDelegate didOpen）。
                print("[ChatAGINativeRealtime] connected")
                print("[ChatAGINativeRealtime] websocket open")
                self.startMiniCPMAfterOpen(callId: callId)
                return
            }
            if self.isSelfhostQwen {
                // ✅ 这才是真实握手成功（之前的 open 日志是 resume 后立刻打的）。
                print("[QwenSelfhostRT] websocket open (handshake confirmed) protocol=\(protocolName ?? "(none)")")
            } else {
                print("[RealtimeAV][qwen][ws_open] handshake confirmed protocol=\(protocolName ?? "(none)")")
            }
        }
    }

    fileprivate func qwenWSDidClose(callId: UUID, code: Int, reason: String) {
        workQueue.async { [weak self] in
            guard let self else { return }
            // ✅ 对端（RunPod 服务器 / 代理 / 系统）主动关闭时一定走这里；
            //    如果 Console 里没有这条而 RunPod 显示 connection closed，就是 iOS 自己 cancel 的
            //    （会有 "close requested reason=..." 日志）。
            let tag = self.isSelfhostQwen ? "[QwenSelfhostRT]" : "[RealtimeAV][qwen]"
            print("\(tag) socket closed by peer code=\(code) reason=\(reason) state=\(self.selfhostState) callIdMatch=\(callId == self.currentCallId)")
        }
    }
}

extension RealtimeAVService {

    func setMutedForActiveProvider(_ muted: Bool) {
        isMuted = muted
        if !isWebSocketProvider {
            localAudioTrack?.isEnabled = !muted
        }
        DispatchQueue.main.async {
            self.delegate?.realtimeAVService(self, didUpdateStatus: muted ? "已静音" : "麦克风开启")
        }
    }
}

extension RealtimeAVService {

    private var routeChangeName: Notification.Name { AVAudioSession.routeChangeNotification }

    private var routeObserver: NSObjectProtocol? {
        get { objc_getAssociatedObject(self, &AssocKeys.routeObs) as? NSObjectProtocol }
        set { objc_setAssociatedObject(self, &AssocKeys.routeObs, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private enum AssocKeys { static var routeObs = 0 }

    private func installAudioRouteObservers() {
        routeObserver = NotificationCenter.default.addObserver(
            forName: routeChangeName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.isRunning || self.isConnecting {
                // 外放测试可保留 speaker；如要听筒优先改为 .none
                try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
            }
        }
    }

    private func removeAudioRouteObservers() {
        if let o = routeObserver {
            NotificationCenter.default.removeObserver(o)
            routeObserver = nil
        }
    }
}

// MARK: - VoiceProcessingIO driver

final class VoiceProcessingIOAudioDriver {

    typealias InputHandler = (_ pcm16Data: Data, _ rms: Float) -> Void
    typealias PlaybackUnderrunHandler = () -> Void

    private let inputSampleRate: Double
    private let outputSampleRate: Double
    private let inputHandler: InputHandler
    private let playbackUnderrunHandler: PlaybackUnderrunHandler

    private var audioUnit: AudioUnit?
    private let stateQueue = DispatchQueue(label: "vpio.driver.state")

    private var inputConverter: AVAudioConverter?
    private var outputConverter: AVAudioConverter?

    private let outputInputFormat: AVAudioFormat
    private let outputPlaybackFormat: AVAudioFormat
    private let inputHardwareFormat: AVAudioFormat
    private let targetInputFormat: AVAudioFormat

    private var playbackBuffer = CircularPCMBuffer(capacityBytes: 1024 * 1024)

    init(
        inputSampleRate: Double,
        outputSampleRate: Double,
        inputHandler: @escaping InputHandler,
        playbackUnderrunHandler: @escaping PlaybackUnderrunHandler
    ) {
        self.inputSampleRate = inputSampleRate
        self.outputSampleRate = outputSampleRate
        self.inputHandler = inputHandler
        self.playbackUnderrunHandler = playbackUnderrunHandler

        self.inputHardwareFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                                 sampleRate: 48000,
                                                 channels: 1,
                                                 interleaved: true)!
        self.targetInputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: inputSampleRate,
                                               channels: 1,
                                               interleaved: true)!
        self.outputInputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: outputSampleRate,
                                               channels: 1,
                                               interleaved: true)!
        self.outputPlaybackFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                                  sampleRate: 48000,
                                                  channels: 1,
                                                  interleaved: true)!

        self.inputConverter = AVAudioConverter(from: inputHardwareFormat, to: targetInputFormat)
        self.outputConverter = AVAudioConverter(from: outputInputFormat, to: outputPlaybackFormat)
    }

    var playbackBufferedFrames: Int {
        playbackBuffer.count / 2
    }

    func start() throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_VoiceProcessingIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw NSError(domain: "VoiceProcessingIO", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "找不到 VoiceProcessingIO"])
        }

        var au: AudioUnit?
        AudioComponentInstanceNew(comp, &au)
        guard let audioUnit = au else {
            throw NSError(domain: "VoiceProcessingIO", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "创建 VoiceProcessingIO 失败"])
        }
        self.audioUnit = audioUnit

        var enableIO: UInt32 = 1
        AudioUnitSetProperty(audioUnit,
                             kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Input,
                             1,
                             &enableIO,
                             UInt32(MemoryLayout<UInt32>.size))

        AudioUnitSetProperty(audioUnit,
                             kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Output,
                             0,
                             &enableIO,
                             UInt32(MemoryLayout<UInt32>.size))

        var streamFormat = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        AudioUnitSetProperty(audioUnit,
                             kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Output,
                             1,
                             &streamFormat,
                             UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

        AudioUnitSetProperty(audioUnit,
                             kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Input,
                             0,
                             &streamFormat,
                             UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

        var inputCallback = AURenderCallbackStruct(
            inputProc: voiceProcessingInputCallback,
            inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
        AudioUnitSetProperty(audioUnit,
                             kAudioOutputUnitProperty_SetInputCallback,
                             kAudioUnitScope_Global,
                             0,
                             &inputCallback,
                             UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        var renderCallback = AURenderCallbackStruct(
            inputProc: voiceProcessingRenderCallback,
            inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
        AudioUnitSetProperty(audioUnit,
                             kAudioUnitProperty_SetRenderCallback,
                             kAudioUnitScope_Input,
                             0,
                             &renderCallback,
                             UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        let statusInit = AudioUnitInitialize(audioUnit)
        guard statusInit == noErr else {
            throw NSError(domain: "VoiceProcessingIO", code: Int(statusInit),
                          userInfo: [NSLocalizedDescriptionKey: "AudioUnitInitialize 失败"])
        }

        let statusStart = AudioOutputUnitStart(audioUnit)
        guard statusStart == noErr else {
            throw NSError(domain: "VoiceProcessingIO", code: Int(statusStart),
                          userInfo: [NSLocalizedDescriptionKey: "AudioOutputUnitStart 失败"])
        }
    }

    func stop() {
        guard let audioUnit else { return }
        AudioOutputUnitStop(audioUnit)
        AudioUnitUninitialize(audioUnit)
        AudioComponentInstanceDispose(audioUnit)
        self.audioUnit = nil
    }

    func appendPlaybackPCM16(_ data: Data) {
        stateQueue.async {
            self.playbackBuffer.write(data)
        }
    }

    func clearPlayback() {
        stateQueue.async {
            self.playbackBuffer.clear()
        }
    }

    fileprivate func handleInput(ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                 inTimeStamp: UnsafePointer<AudioTimeStamp>,
                                 inBusNumber: UInt32,
                                 inNumberFrames: UInt32) -> OSStatus {
        guard let audioUnit else { return noErr }

        let byteCount = Int(inNumberFrames) * 2
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 2)
        defer { raw.deallocate() }

        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(byteCount),
                mData: raw
            )
        )

        let status = AudioUnitRender(audioUnit,
                                     ioActionFlags,
                                     inTimeStamp,
                                     1,
                                     inNumberFrames,
                                     &bufferList)
        guard status == noErr else { return status }

        let pcm48k = Data(bytes: raw, count: byteCount)

        if inputSampleRate == 48000 {
            var rmsSum: Float = 0
            pcm48k.withUnsafeBytes { rawBuf in
                let p = rawBuf.bindMemory(to: Int16.self)
                for i in 0..<Int(inNumberFrames) {
                    let s = Float(p[i]) / 32768.0
                    rmsSum += s * s
                }
            }
            let rms = sqrt(rmsSum / Float(max(1, Int(inNumberFrames))))
            inputHandler(pcm48k, rms)
            return noErr
        }

        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inputHardwareFormat,
                                           frameCapacity: AVAudioFrameCount(inNumberFrames)),
              let converter = inputConverter else {
            return noErr
        }

        inBuf.frameLength = AVAudioFrameCount(inNumberFrames)
        memcpy(inBuf.int16ChannelData![0], raw, byteCount)

        let outCapacity = AVAudioFrameCount(Double(inNumberFrames) * inputSampleRate / 48000.0 + 32)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetInputFormat,
                                            frameCapacity: outCapacity) else {
            return noErr
        }

        var error: NSError?
        var provided = false
        converter.convert(to: outBuf, error: &error) { _, status in
            if provided {
                status.pointee = .noDataNow
                return nil
            }
            provided = true
            status.pointee = .haveData
            return inBuf
        }

        guard error == nil, let ch = outBuf.int16ChannelData else { return noErr }
        let frames = Int(outBuf.frameLength)
        if frames <= 0 { return noErr }

        let outData = Data(bytes: ch[0], count: frames * 2)

        var rmsSum: Float = 0
        for i in 0..<frames {
            let s = Float(ch[0][i]) / 32768.0
            rmsSum += s * s
        }
        let rms = sqrt(rmsSum / Float(frames))
        inputHandler(outData, rms)
        return noErr
    }

    fileprivate func handleRender(ioData: UnsafeMutablePointer<AudioBufferList>?,
                                  inNumberFrames: UInt32) -> OSStatus {
        guard let ioData else { return noErr }

        let outBytes = Int(inNumberFrames) * 2

        let need48k = Int(inNumberFrames)
        let need24k = Int(Double(need48k) * outputSampleRate / 48000.0 + 1.0)

        var sourceData = Data()
        stateQueue.sync {
            let availableFrames24k = self.playbackBuffer.count / 2
            let takeFrames24k = min(availableFrames24k, need24k)
            sourceData = self.playbackBuffer.read(byteCount: takeFrames24k * 2)
        }

        if sourceData.isEmpty {
            for i in 0..<Int(ioData.pointee.mNumberBuffers) {
                memset(UnsafeMutableAudioBufferListPointer(ioData)[i].mData, 0, outBytes)
                UnsafeMutableAudioBufferListPointer(ioData)[i].mDataByteSize = UInt32(outBytes)
            }
            playbackUnderrunHandler()
            return noErr
        }

        let rendered48k: Data
        if outputSampleRate == 48000 {
            rendered48k = sourceData
        } else {
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: outputInputFormat,
                                               frameCapacity: AVAudioFrameCount(sourceData.count / 2)),
                  let converter = outputConverter else {
                rendered48k = sourceData
                goto_copy(rendered48k, ioData: ioData, outBytes: outBytes)
                return noErr
            }

            inBuf.frameLength = AVAudioFrameCount(sourceData.count / 2)
            sourceData.withUnsafeBytes { raw in
                memcpy(inBuf.int16ChannelData![0], raw.baseAddress!, sourceData.count)
            }

            let outCap = AVAudioFrameCount(Double(inBuf.frameLength) * 48000.0 / outputSampleRate + 32)
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outputPlaybackFormat,
                                                frameCapacity: outCap) else {
                rendered48k = sourceData
                goto_copy(rendered48k, ioData: ioData, outBytes: outBytes)
                return noErr
            }

            var error: NSError?
            var provided = false
            converter.convert(to: outBuf, error: &error) { _, status in
                if provided {
                    status.pointee = .noDataNow
                    return nil
                }
                provided = true
                status.pointee = .haveData
                return inBuf
            }

            if error == nil, let ch = outBuf.int16ChannelData {
                rendered48k = Data(bytes: ch[0], count: Int(outBuf.frameLength) * 2)
            } else {
                rendered48k = sourceData
            }
        }

        goto_copy(rendered48k, ioData: ioData, outBytes: outBytes)
        return noErr
    }

    private func goto_copy(_ data: Data,
                           ioData: UnsafeMutablePointer<AudioBufferList>,
                           outBytes: Int) {
        let copyBytes = min(outBytes, data.count)
        data.withUnsafeBytes { raw in
            for i in 0..<Int(ioData.pointee.mNumberBuffers) {
                let dst = UnsafeMutableAudioBufferListPointer(ioData)[i].mData!
                memcpy(dst, raw.baseAddress!, copyBytes)
                if outBytes > copyBytes {
                    memset(dst.advanced(by: copyBytes), 0, outBytes - copyBytes)
                }
                UnsafeMutableAudioBufferListPointer(ioData)[i].mDataByteSize = UInt32(outBytes)
            }
        }
    }
}

private func voiceProcessingInputCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let driver = Unmanaged<VoiceProcessingIOAudioDriver>.fromOpaque(inRefCon).takeUnretainedValue()
    return driver.handleInput(ioActionFlags: ioActionFlags,
                              inTimeStamp: inTimeStamp,
                              inBusNumber: inBusNumber,
                              inNumberFrames: inNumberFrames)
}

private func voiceProcessingRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let driver = Unmanaged<VoiceProcessingIOAudioDriver>.fromOpaque(inRefCon).takeUnretainedValue()
    return driver.handleRender(ioData: ioData, inNumberFrames: inNumberFrames)
}

// MARK: - Circular buffer

final class CircularPCMBuffer {
    private var buffer: Data
    private let capacity: Int
    private var readIndex: Int = 0
    private var writeIndex: Int = 0
    private var used: Int = 0

    init(capacityBytes: Int) {
        self.capacity = max(4096, capacityBytes)
        self.buffer = Data(count: self.capacity)
    }

    var count: Int { used }

    func clear() {
        readIndex = 0
        writeIndex = 0
        used = 0
    }

    func write(_ data: Data) {
        if data.isEmpty { return }
        var incoming = data
        if incoming.count > capacity {
            incoming = incoming.suffix(capacity)
            clear()
        }

        let overflow = max(0, used + incoming.count - capacity)
        if overflow > 0 {
            _ = read(byteCount: overflow)
        }

        incoming.withUnsafeBytes { src in
            let base = src.bindMemory(to: UInt8.self).baseAddress!
            let first = min(incoming.count, capacity - writeIndex)
            buffer.withUnsafeMutableBytes { dst in
                memcpy(dst.baseAddress!.advanced(by: writeIndex), base, first)
                if incoming.count > first {
                    memcpy(dst.baseAddress!, base.advanced(by: first), incoming.count - first)
                }
            }
        }

        writeIndex = (writeIndex + incoming.count) % capacity
        used += incoming.count
    }

    func read(byteCount: Int) -> Data {
        let n = min(byteCount, used)
        guard n > 0 else { return Data() }

        var out = Data(count: n)
        out.withUnsafeMutableBytes { dst in
            let first = min(n, capacity - readIndex)
            buffer.withUnsafeBytes { src in
                memcpy(dst.baseAddress!, src.baseAddress!.advanced(by: readIndex), first)
                if n > first {
                    memcpy(dst.baseAddress!.advanced(by: first), src.baseAddress!, n - first)
                }
            }
        }

        readIndex = (readIndex + n) % capacity
        used -= n
        return out
    }
}

// MARK: - 前端打断状态机（openai/三段云端通路）
// 与交付版 adu-voice-sdk/src/barge-machine.js 同一规范：参数与触发链 1:1。

final class AduBargeMachine {
    let level: Float
    let release: Float
    let warmupMs: Double
    let activeMs: Double
    private var speakingActive = false
    private var speakingSince: Double = 0
    private var activeAccMs: Double = 0
    private var lastFeed: Double = 0
    private var echoBaseline: Float = 0   // 播报回声电平基线（tap 无 AEC，必须自适应）

    init(level: Float = 0.14, release: Float = 0.08, warmupMs: Double = 80, activeMs: Double = 100) {
        self.level = level
        self.release = release
        self.warmupMs = warmupMs
        self.activeMs = activeMs
    }

    var speaking: Bool { speakingActive }

    func speakingStarted(_ nowMs: Double) {
        guard !speakingActive else { return }
        speakingActive = true
        speakingSince = nowMs
        activeAccMs = 0
        lastFeed = nowMs
    }

    func speakingStopped() {
        speakingActive = false
        speakingSince = 0
        activeAccMs = 0
        echoBaseline = 0
    }

    /// 每个麦克风块喂归一化 RMS；返回 true = 触发打断
    func feed(rms: Float, nowMs: Double) -> Bool {
        guard speakingActive else { return false }
        let dt = lastFeed > 0 ? min(nowMs - lastFeed, 200) : 0
        lastFeed = nowMs
        let sinceSpeak = nowMs - speakingSince
        // 前 350ms：学习扬声器回声在 tap 上的电平（EMA），不做判定
        if sinceSpeak < 350 {
            echoBaseline = echoBaseline == 0 ? rms : (echoBaseline * 0.7 + rms * 0.3)
            return false
        }
        let gate = max(level, echoBaseline * 2.2)  // 用户插话需明显盖过回声
        let warmed = sinceSpeak >= warmupMs
        if warmed && rms >= gate {
            activeAccMs += dt
        } else if rms < release {
            activeAccMs = 0  // 迟滞：level~release 之间保持累计，跌破 release 才清零
        }
        if activeAccMs >= activeMs {
            speakingStopped()
            return true
        }
        return false
    }
}

extension RealtimeAVService {

    func frontBargeSpeakingStarted() {
        frontBargeSpeakStartAt = Date()
        frontBarge.speakingStarted(Date().timeIntervalSince1970 * 1000)
    }

    func frontBargeSpeakingStopped() {
        frontBarge.speakingStopped()
        frontBargeSpeakStartAt = nil
    }

    /// dc open 后启动：AVAudioEngine 只读电平 tap（不动 WebRTC 采集链，仅取 RMS）
    func frontBargeStartTap() {
        guard frontBargeEngine == nil else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            print("[FrontBarge] 输入格式不可用，跳过前端打断（服务端活性打断兜底）")
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let ch = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            guard n > 0 else { return }
            var acc: Float = 0
            let step = max(1, n / 256)
            var count = 0
            var i = 0
            while i < n { acc += ch[i] * ch[i]; count += 1; i += step }
            let rms = sqrtf(acc / Float(max(1, count)))
            if self.frontBarge.feed(rms: rms, nowMs: Date().timeIntervalSince1970 * 1000) {
                self.workQueue.async { self.frontBargeTriggered(rms: rms) }
            }
        }
        do {
            try engine.start()
            frontBargeEngine = engine
            print("[FrontBarge] 电平 tap 已启动（level=\(frontBarge.level) active=\(Int(frontBarge.activeMs))ms）")
        } catch {
            input.removeTap(onBus: 0)
            print("[FrontBarge] AVAudioEngine 启动失败：\(error.localizedDescription)（服务端活性打断兜底）")
        }
    }

    func frontBargeStopTap() {
        if let engine = frontBargeEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        frontBargeEngine = nil
        frontBarge.speakingStopped()
        frontBargeRemoteTrack = nil
        frontBargeSpeakStartAt = nil
    }

    private func frontBargeTriggered(rms: Float) {
        guard activeProvider == .openai, isRunning else { return }
        let playedMs = Int((Date().timeIntervalSince(frontBargeSpeakStartAt ?? Date())) * 1000)
        print("[FrontBarge] 触发打断 rms=\(String(format: "%.3f", rms)) played=\(playedMs)ms")
        // 不做本地禁音：tap 采集的是未回声消除的原始麦克风，误触发时本地禁音会把
        // 播报彻底掐哑（2026-08-03 "没有播报声音"事故）。停声交给服务端打断链
        // （bargein + clear_queue，实测事件后 ~50ms 停声），误触发最多切一轮不致哑。
        // truncate 契约 + 服务端硬打断
        sendClientEvent(["type": "played", "ms": max(0, playedMs)], droppable: true)
        sendClientEvent(["type": "response.cancel"], droppable: true)
    }
}
