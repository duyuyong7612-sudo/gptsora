//
//      // 状态
// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-e622c39abfd210298c00bbf3cbdd3d3e7d7454c612890ae762b046667405ae08"
// Source-SHA256: "6b682aa4824443e4b2d3eabb543943e68102888d40be2c1e8ca055fc5c5f34ba"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
RealtimeQuickService.swift
//  GPTsora / GPT Solara
//
//  ✅ 商用级稳定版（WebRTC Realtime → 语音对话做“视频规划”，抓 SORA 行给后端生成）
//
//  核心修复：
//  - 修复“第二次进来没声音”：对称完整释放 RTCAudioSession + AVAudioSession + WebRTC 对象
//  - 修复 AudioSession Code=-50：移除 voiceChat + A2DP 冲突 + 过低 buffer，提供多档 fallback
//  - Realtime 输出使用 output_modalities（Realtime client events）
//  - VAD：create_response / interrupt_response（用户停顿自动出声、支持打断）
//  - 事件处理统一 workQueue，UI 文本 50ms 合并节流，避免主线程卡顿
//  - idle 自动挂断 DispatchSourceTimer（不占主线程）
//  - 提供 interrupt/cancel：response.cancel + output_audio_buffer.clear（WebRTC）
//
//  ✅ 本次增强：把旧版“语义→自动触发生成视频”链路稳健接入（修复走不上链路）
//  - 兼容 response.output_audio_transcript.* 事件名（很多实际就是这个，不是 transcription）
//  - 加 SORA debounce 扫描：有些情况下不发 done，也能触发 SORA
//  - /session 预热 + waiters：优化首次连接慢（并避免重复 /session）
//
//  你需要改的：Backend.apiBase
//

import Foundation
import AVFoundation
import WebRTC

// MARK: - 后端配置

private enum Backend {
    /// 你的 FastAPI 后端，比如 "http://YOUR_LAN_IP:8000"
    static let apiBase = "http://YOUR_LAN_IP:8000"
    static let sessionPath = "/session"

    static var sessionURL: URL { URL(string: apiBase + sessionPath)! }
}

// MARK: - 日志

private let kRTLogEnabled = true
fileprivate func rtLog(_ msg: String) {
    guard kRTLogEnabled else { return }
    NSLog("[RT-iOS] \(msg)")
}

// MARK: - Realtime 配置

/// 默认 voice（后端也可返回覆盖）
private let kRealtimeDefaultVoice = "coral"

/// iOS 是否把转写文本同步到 UI（蓝色 Sora 页）
private let kRealtimeTextToUIEnabled_iOS = true

/// UI 文本节流间隔（50ms）
private let kAssistantEmitInterval: TimeInterval = 0.05

/// 空闲超过多少秒自动挂断
private let kMaxIdleSeconds: TimeInterval = 60

/// SORA 去重窗口（防止同一条重复触发）
private let kSoraDuplicateSuppressWindow: TimeInterval = 2.0

/// DataChannel label（OpenAI Realtime WebRTC 推荐用 oai-events）
private let kEventsDataChannelLabel = "oai-events"

/// ✅ /session 预热缓存有效期（ephemeral key 往往很短，保守一点）
private let kSessionCacheMaxAge: TimeInterval = 35.0

/// ✅ SORA debounce：如果没有 done 事件，连续多久没有新 delta 就尝试扫描一次
private let kSoraDebounceScanDelay: TimeInterval = 0.35

// MARK: - Delegate

protocol RealtimeQuickServiceDelegate: AnyObject {
    func realtimeServiceDidConnect(_ svc: RealtimeQuickService)
    func realtimeServiceDidDisconnect(_ svc: RealtimeQuickService)

    func realtimeService(_ svc: RealtimeQuickService, didUpdateStatus text: String)
    /// 文本增量/最终文本：用前缀 "[U]" / "[A]" 区分
    func realtimeService(_ svc: RealtimeQuickService, didUpdateTranscript text: String)

    func realtimeService(_ svc: RealtimeQuickService, didFailWith error: Error)

    /// ✅ 助手输出 SORA 行时触发（最后一条用户口述 + 助手总结）
    func realtimeService(
        _ svc: RealtimeQuickService,
        didTriggerSoraWithUserPrompt userPrompt: String,
        assistantSummary: String
    )
}

// MARK: - RealtimeQuickService

final class RealtimeQuickService: NSObject {

    // /session 返回内容
    private struct SessionInfo {
        let rtcURL: URL
        let ephemeralKey: String
        let iceServers: [RTCIceServer]
        let voice: String?
        let transcriptionModel: String?
        /// 是否强制“音频+文本”输出（有些模型不支持 audio-only）
        let forceAudioText: Bool
    }

    private struct SessionCache {
        let info: SessionInfo
        let fetchedAt: Date
    }

    enum OutputMode {
        /// 稳定默认：音频 + 文本（有些实现/模型需要）
        case audioAndText
        /// 仅文本（调试/静音需求）
        case textOnly
        /// 仅音频（仅当后端确认模型支持）
        case audioOnly
    }

    static let shared = RealtimeQuickService()

    weak var delegate: RealtimeQuickServiceDelegate?

    // WebRTC
    private var factory: RTCPeerConnectionFactory!
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private var localAudioTrack: RTCAudioTrack?

    // /session（当前通话使用）
    private var rtcURL: URL?
    private var ephemeralKey: String?
    private var iceServers: [RTCIceServer] = []
    private var voice: String = kRealtimeDefaultVoice
    private var transcriptionModel: String? = "gpt-4o-mini-transcribe" // 后端可覆盖

    // ✅ /session 预热缓存（优化首次连接慢）
    private var sessionCache: SessionCache?
    private var sessionPrefetchInFlight = false
    private var sessionPrefetchWaiters: [(Result<SessionInfo, Error>) -> Void] = []

    private(set) var isConnecting: Bool = false
    private(set) var isRunning: Bool = false
    private(set) var isMuted: Bool = false
    private var outputMode: OutputMode = .audioAndText
    private var sessionUpdateSent = false

    /// 防止 stop 后旧回调乱改状态
    private var currentCallId = UUID()

    // 文本 & 会话
    private var transcriptBuffer: String = ""
    private var conversation: [[String: String]] = []

    // 自动挂断
    private var idleHangTimer: DispatchSourceTimer?
    private var lastActivityAt: Date?

    // ICE 断线重连判定
    private var iceReconnectWorkItem: DispatchWorkItem?

    // UI 节流
    private var assistantEmitScheduled = false
    private var assistantEmitWorkItem: DispatchWorkItem?

    // ✅ SORA debounce 扫描
    private var soraDebounceWorkItem: DispatchWorkItem?

    // SORA 去重
    private var lastTriggeredSoraLine: String?
    private var lastTriggeredSoraAt: Date?

    // workQueue（所有状态/事件都在这里串行）
    fileprivate let workQueue = DispatchQueue(label: "rt.service.queue", qos: .userInitiated)

    // 音频通知
    private var audioObserversInstalled = false

    private override init() {
        super.init()
        setupFactory()
        installAudioObserversIfNeeded()

        // ✅ 启动后预热 /session（减少第一次连接慢；也能提前把后端冷启动拉起来）
        workQueue.async { [weak self] in
            self?.prefetchSessionIfNeeded(force: true)
        }
    }

    deinit {
        workQueue.sync { hardResetState(notifyDelegate: false) }
        removeAudioObserversIfNeeded()
    }

    // MARK: - Public API

    /// ✅ Sora 规划模式入口（视频页波纹键）
    func startSoraPlannerCall() {
        startCallInternal()
    }

    /// 兼容旧接口
    func startCall() {
        startCallInternal()
    }

    func stopCall() {
        rtLog("stopCall()")
        workQueue.async { [weak self] in
            self?.stopCallNow(statusText: nil)
        }
    }

    /// 极端情况：从 UI 彻底重置
    func hardReset() {
        rtLog("hardReset()")
        workQueue.async { [weak self] in
            self?.hardResetState(notifyDelegate: true)
        }
    }

    /// ✅ 可选：手动预热（你不改 ContentView 也没关系，这里 init 已自动预热）
    func prewarmSession() {
        workQueue.async { [weak self] in
            self?.prefetchSessionIfNeeded(force: true)
        }
    }

    func toggleMute() {
        workQueue.async { [weak self] in
            guard let self else { return }
            guard let track = self.localAudioTrack else { return }

            self.isMuted.toggle()
            track.isEnabled = !self.isMuted

            DispatchQueue.main.async {
                self.delegate?.realtimeService(self, didUpdateStatus: self.isMuted ? "已静音" : "麦克风开启")
            }
        }
    }

    /// 主动发文本（可用于补充提示/纯文字调试）
    func sendText(_ text: String, speak: Bool = true) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return }

        workQueue.async { [weak self] in
            guard let self else { return }
            guard let dc = self.dataChannel, dc.readyState == .open else { return }

            self.conversation.append(["role": "user", "text": t])
            self.markActivity()

            // 1) 写入会话（conversation.item.create）
            let msg1: [String: Any] = [
                "type": "conversation.item.create",
                "item": [
                    "type": "message",
                    "role": "user",
                    "content": [
                        ["type": "input_text", "text": t]
                    ]
                ]
            ]

            // 2) 触发推理（response.create）——注意是 output_modalities
            let outModes: [String]
            if speak {
                outModes = self.outputModalitiesForSpeech()
            } else {
                outModes = ["text"]
            }

            let msg2: [String: Any] = [
                "type": "response.create",
                "response": [
                    "output_modalities": outModes,
                    "metadata": [
                        "purpose": "user_text"
                    ]
                ]
            ]

            self.sendJSON(msg1, on: dc)
            self.sendJSON(msg2, on: dc)
        }
    }

    /// 手动打断/停止助手当前播报（可绑“打断”按钮）
    func interruptAssistant() {
        workQueue.async { [weak self] in
            guard let self else { return }
            guard let dc = self.dataChannel, dc.readyState == .open else { return }

            // 1) cancel 推理
            self.sendJSON(["type": "response.cancel"], on: dc)
            // 2) 清空音频 buffer（WebRTC）
            self.sendJSON(["type": "output_audio_buffer.clear"], on: dc)
        }
    }

    // MARK: - Setup

    private func setupFactory() {
        RTCPeerConnectionFactory.initialize()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        factory = RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)
    }

    // MARK: - /session 预热（优化首次连接慢）

    /// ⚠️ 只在 workQueue 调用
    private func prefetchSessionIfNeeded(force: Bool) {
        if sessionPrefetchInFlight { return }

        if !force, let cache = sessionCache {
            let age = Date().timeIntervalSince(cache.fetchedAt)
            if age <= kSessionCacheMaxAge {
                return
            }
        }

        sessionPrefetchInFlight = true
        rtLog("prefetch /session ...")

        fetchSessionFromBackend { [weak self] result in
            guard let self else { return }
            self.workQueue.async {
                self.sessionPrefetchInFlight = false

                switch result {
                case .success(let info):
                    self.sessionCache = SessionCache(info: info, fetchedAt: Date())
                    rtLog("prefetch /session OK (cached)")
                case .failure(let err):
                    self.sessionCache = nil
                    rtLog("prefetch /session FAILED: \(err)")
                }

                let waiters = self.sessionPrefetchWaiters
                self.sessionPrefetchWaiters.removeAll()
                for w in waiters {
                    w(result)
                }
            }
        }
    }

    /// ⚠️ 只在 workQueue 调用：取一个可用缓存（取到就消费掉，避免复用同一 ephemeral key）
    private func popUsableCachedSession() -> SessionInfo? {
        guard let cache = sessionCache else { return nil }
        let age = Date().timeIntervalSince(cache.fetchedAt)
        guard age <= kSessionCacheMaxAge else {
            sessionCache = nil
            return nil
        }
        sessionCache = nil
        return cache.info
    }

    // MARK: - Core flow

    private func startCallInternal() {
        rtLog("startCallInternal()")

        workQueue.async { [weak self] in
            guard let self else { return }

            // ✅ 每次开始前强制清理（不通知 UI）
            self.hardResetState(notifyDelegate: false)

            let callId = UUID()
            self.currentCallId = callId

            // ✅ 开始连接前就预热 /session（并发跑，提升首连体验）
            self.prefetchSessionIfNeeded(force: false)

            self.isConnecting = true
            DispatchQueue.main.async {
                self.delegate?.realtimeService(self, didUpdateStatus: "连接中…")
            }

            // 1) 录音权限（主线程发起更稳）
            DispatchQueue.main.async {
                AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
                    guard let self else { return }
                    self.workQueue.async {
                        guard callId == self.currentCallId else {
                            rtLog("permission callback expired, ignore")
                            return
                        }

                        if !granted {
                            self.isConnecting = false
                            self.isRunning = false
                            let err = NSError(
                                domain: "RealtimeQuickService",
                                code: -10,
                                userInfo: [NSLocalizedDescriptionKey: "麦克风未授权"]
                            )
                            DispatchQueue.main.async {
                                self.delegate?.realtimeService(self, didUpdateStatus: "麦克风未授权")
                                self.delegate?.realtimeService(self, didFailWith: err)
                            }
                            return
                        }

                        // 2) 配置音频（多档 fallback，解决 -50）
                        do {
                            try self.configureAudioSessionWithFallbacks()
                        } catch {
                            self.isConnecting = false
                            self.isRunning = false
                            rtLog("❌ AudioSession 配置失败(最终): \(error)")
                            DispatchQueue.main.async {
                                self.delegate?.realtimeService(self, didUpdateStatus: "音频配置失败")
                                self.delegate?.realtimeService(self, didFailWith: error)
                            }
                            return
                        }

                        // 3) /session + 建连接
                        self.openSessionAndConnect(callId: callId)
                    }
                }
            }
        }
    }

    private func openSessionAndConnect(callId: UUID) {
        // ✅ 优先用预热缓存（如果新鲜）
        if let cached = popUsableCachedSession() {
            rtLog("openSessionAndConnect: use cached session")
            workQueue.async { [weak self] in
                guard let self else { return }
                guard callId == self.currentCallId else { return }
                self.connectWithSessionInfo(cached, callId: callId)
            }
            return
        }

        // ✅ 如果预热正在进行，则等待预热结果（避免重复 /session）
        if sessionPrefetchInFlight {
            rtLog("openSessionAndConnect: wait for in-flight prefetch")
            sessionPrefetchWaiters.append { [weak self] result in
                guard let self else { return }
                self.workQueue.async {
                    guard callId == self.currentCallId else { return }
                    switch result {
                    case .success(let info):
                        self.connectWithSessionInfo(info, callId: callId)
                    case .failure(let err):
                        self.isConnecting = false
                        self.isRunning = false
                        DispatchQueue.main.async {
                            self.delegate?.realtimeService(self, didUpdateStatus: "获取会话失败")
                            self.delegate?.realtimeService(self, didFailWith: err)
                        }
                    }
                }
            }
            return
        }

        // 否则：正常拉 /session
        fetchSessionFromBackend { [weak self] result in
            guard let self else { return }
            self.workQueue.async {
                guard callId == self.currentCallId else {
                    rtLog("/session callback expired, ignore")
                    return
                }

                switch result {
                case .failure(let err):
                    self.isConnecting = false
                    self.isRunning = false
                    DispatchQueue.main.async {
                        self.delegate?.realtimeService(self, didUpdateStatus: "获取会话失败")
                        self.delegate?.realtimeService(self, didFailWith: err)
                    }

                case .success(let info):
                    self.connectWithSessionInfo(info, callId: callId)
                }
            }
        }
    }

    /// ⚠️ 只在 workQueue 调用
    private func connectWithSessionInfo(_ info: SessionInfo, callId: UUID) {
        applySessionInfo(info)
        do {
            try setupPeerConnection()
        } catch {
            isConnecting = false
            isRunning = false
            DispatchQueue.main.async {
                self.delegate?.realtimeService(self, didUpdateStatus: "建立连接失败")
                self.delegate?.realtimeService(self, didFailWith: error)
            }
            return
        }

        negotiate { [weak self] err in
            guard let self else { return }
            self.workQueue.async {
                guard callId == self.currentCallId else {
                    rtLog("negotiate callback expired, ignore")
                    return
                }

                if let err {
                    self.isConnecting = false
                    self.isRunning = false
                    DispatchQueue.main.async {
                        self.delegate?.realtimeService(self, didUpdateStatus: "协商失败")
                        self.delegate?.realtimeService(self, didFailWith: err)
                    }
                    return
                }

                self.isConnecting = false
                self.isRunning = true
                self.conversation.removeAll()

                self.startIdleHangWatch()

                DispatchQueue.main.async {
                    self.delegate?.realtimeServiceDidConnect(self)
                    self.delegate?.realtimeService(self, didUpdateStatus: "已连接")
                }
            }
        }
    }

    private func applySessionInfo(_ info: SessionInfo) {
        self.rtcURL = info.rtcURL
        self.ephemeralKey = info.ephemeralKey
        self.iceServers = info.iceServers

        if let v = info.voice, !v.isEmpty { self.voice = v }
        if let tm = info.transcriptionModel, !tm.isEmpty { self.transcriptionModel = tm }

        // 如果后端说必须 audio+text，就强制
        if info.forceAudioText {
            self.outputMode = .audioAndText
        }
    }

    // MARK: - Stop / Reset

    private func stopCallNow(statusText: String?) {
        hardResetState(notifyDelegate: true)
        if let statusText {
            DispatchQueue.main.async {
                self.delegate?.realtimeService(self, didUpdateStatus: statusText)
            }
        }
    }

    /// ⚠️ 只在 workQueue 调用
    private func hardResetState(notifyDelegate: Bool) {
        rtLog("hardResetState(notify=\(notifyDelegate))")

        currentCallId = UUID()

        // cancel UI 节流
        assistantEmitWorkItem?.cancel()
        assistantEmitWorkItem = nil
        assistantEmitScheduled = false

        // cancel SORA debounce
        soraDebounceWorkItem?.cancel()
        soraDebounceWorkItem = nil

        // cancel ICE reconnect
        iceReconnectWorkItem?.cancel()
        iceReconnectWorkItem = nil

        // stop timers
        stopIdleHangWatch()

        // close dc/pc
        if let dc = dataChannel {
            dc.delegate = nil
            dc.close()
        }
        dataChannel = nil

        if let pc = peerConnection {
            pc.delegate = nil
            pc.close()
        }
        peerConnection = nil
        localAudioTrack = nil

        // session data（当前通话）
        rtcURL = nil
        ephemeralKey = nil
        iceServers = []

        // conversation
        transcriptBuffer = ""
        conversation.removeAll()

        // state
        isConnecting = false
        isRunning = false
        isMuted = false
        sessionUpdateSent = false

        // SORA dedup
        lastTriggeredSoraLine = nil
        lastTriggeredSoraAt = nil

        // ✅ 最关键：彻底释放音频（修复第二次无声）
        deactivateAudioSessionFully()

        if notifyDelegate {
            DispatchQueue.main.async {
                self.delegate?.realtimeServiceDidDisconnect(self)
                self.delegate?.realtimeService(self, didUpdateStatus: "已挂断")
            }
        }
    }

    // MARK: - Idle hang watch

    fileprivate func markActivity() {
        lastActivityAt = Date()
    }

    private func startIdleHangWatch() {
        stopIdleHangWatch()
        lastActivityAt = Date()

        let t = DispatchSource.makeTimerSource(queue: workQueue)
        t.schedule(deadline: .now() + 2.0, repeating: 2.0)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            guard let last = self.lastActivityAt else { return }
            let idle = Date().timeIntervalSince(last)
            if idle >= kMaxIdleSeconds {
                rtLog("⏱ idle \(idle)s >= \(kMaxIdleSeconds)s -> auto hang up")
                self.stopCallNow(statusText: "长时间未说话，已自动断开")
            }
        }
        t.resume()
        idleHangTimer = t
    }

    private func stopIdleHangWatch() {
        idleHangTimer?.cancel()
        idleHangTimer = nil
        lastActivityAt = nil
    }

    // MARK: - AudioSession (Fix -50 + Symmetric release)

    /// ✅ 多档 fallback，尽最大可能避免 Code=-50
    private func configureAudioSessionWithFallbacks() throws {
        let rtc = RTCAudioSession.sharedInstance()
        rtc.lockForConfiguration()
        defer { rtc.unlockForConfiguration() }

        func apply(_ cfg: RTCAudioSessionConfiguration, name: String) throws {
            do {
                try rtc.setConfiguration(cfg, active: true)
                rtc.useManualAudio = false
                rtc.isAudioEnabled = true
                rtLog("AudioSession configured OK (\(name))")
            } catch {
                rtLog("AudioSession config FAILED (\(name)): \(error)")
                throw error
            }
        }

        // 尝试 #1：voiceChat + playAndRecord + allowBluetooth + defaultToSpeaker
        // 重要：不要加 allowBluetoothA2DP（voiceChat 下很容易参数非法 -> -50）
        do {
            let cfg = RTCAudioSessionConfiguration.webRTC()
            cfg.category = AVAudioSession.Category.playAndRecord.rawValue
            cfg.categoryOptions = [.allowBluetooth, .defaultToSpeaker]
            cfg.mode = AVAudioSession.Mode.voiceChat.rawValue
            cfg.sampleRate = 48000
            cfg.ioBufferDuration = 0.01 // 10ms 更稳（0.005 在部分设备/系统会 -50）
            try apply(cfg, name: "voiceChat + bt + speaker + 48k + 10ms")
            return
        } catch { /* fallthrough */ }

        // 尝试 #2：去掉 sampleRate/ioBufferDuration（让系统自己决定）
        do {
            let cfg = RTCAudioSessionConfiguration.webRTC()
            cfg.category = AVAudioSession.Category.playAndRecord.rawValue
            cfg.categoryOptions = [.allowBluetooth, .defaultToSpeaker]
            cfg.mode = AVAudioSession.Mode.voiceChat.rawValue
            try apply(cfg, name: "voiceChat + bt + speaker (no SR/IO)")
            return
        } catch { /* fallthrough */ }

        // 尝试 #3：videoChat（有些系统对 voiceChat 更挑）
        do {
            let cfg = RTCAudioSessionConfiguration.webRTC()
            cfg.category = AVAudioSession.Category.playAndRecord.rawValue
            cfg.categoryOptions = [.allowBluetooth, .defaultToSpeaker]
            cfg.mode = AVAudioSession.Mode.videoChat.rawValue
            try apply(cfg, name: "videoChat + bt + speaker")
            return
        } catch { /* fallthrough */ }

        // 尝试 #4：mode 用 default（最宽松）
        do {
            let cfg = RTCAudioSessionConfiguration.webRTC()
            cfg.category = AVAudioSession.Category.playAndRecord.rawValue
            cfg.categoryOptions = [.allowBluetooth, .defaultToSpeaker]
            cfg.mode = AVAudioSession.Mode.default.rawValue
            try apply(cfg, name: "default mode + bt + speaker")
            return
        } catch {
            throw error
        }
    }

    /// ✅ 对称彻底释放（修复第二次无声）
    private func deactivateAudioSessionFully() {
        // 1) WebRTC session
        let rtc = RTCAudioSession.sharedInstance()
        rtc.lockForConfiguration()
        rtc.isAudioEnabled = false
        rtc.useManualAudio = false
        do {
            try rtc.setActive(false)
        } catch {
            rtLog("RTCAudioSession setActive(false) error: \(error)")
        }
        rtc.unlockForConfiguration()

        // 2) System session
        let sys = AVAudioSession.sharedInstance()
        do {
            try sys.setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            rtLog("AVAudioSession setActive(false) error: \(error)")
        }
    }

    // MARK: - Backend /session

    private func fetchSessionFromBackend(
        completion: @escaping (Result<SessionInfo, Error>) -> Void
    ) {
        var request = URLRequest(url: Backend.sessionURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // 你可以让后端按模型能力返回 force_audio_text / voice / transcription_model
        let payload: [String: Any] = [
            "want_video": false,
            "client": "ios_webrtc"
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            completion(.failure(error))
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let e = error { completion(.failure(e)); return }

            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let data = data else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                completion(.failure(NSError(
                    domain: "RealtimeQuickService",
                    code: code,
                    userInfo: [NSLocalizedDescriptionKey: "后端 /session 返回错误：\(code)"]
                )))
                return
            }

            do {
                let any = try JSONSerialization.jsonObject(with: data, options: [])
                guard let dict = any as? [String: Any] else {
                    throw NSError(domain: "RealtimeQuickService", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "无法解析 /session JSON"])
                }

                guard let urlStr = dict["rtc_url"] as? String,
                      let url = URL(string: urlStr) else {
                    throw NSError(domain: "RealtimeQuickService", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "缺少 rtc_url"])
                }

                let key = (dict["ephemeral_key"] as? String)
                ?? ((dict["client_secret"] as? [String: Any])?["value"] as? String)

                guard let ephemeral = key else {
                    throw NSError(domain: "RealtimeQuickService", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "缺少 ephemeral_key"])
                }

                // ICE servers
                let rawIce = (dict["ice_servers"] as? [[String: Any]]) ?? []
                let ice: [RTCIceServer]
                if rawIce.isEmpty {
                    ice = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
                } else {
                    ice = rawIce.compactMap { d in
                        guard let urls = d["urls"] else { return nil }
                        if let s = urls as? String {
                            return RTCIceServer(urlStrings: [s],
                                                username: d["username"] as? String,
                                                credential: d["credential"] as? String)
                        } else if let arr = urls as? [String] {
                            return RTCIceServer(urlStrings: arr,
                                                username: d["username"] as? String,
                                                credential: d["credential"] as? String)
                        }
                        return nil
                    }
                }

                let voice = dict["voice"] as? String
                let transcriptionModel = dict["transcription_model"] as? String
                let forceAudioText = (dict["force_audio_text"] as? Bool) ?? true

                rtLog("session ok, rtc_url=\(urlStr)")
                completion(.success(SessionInfo(
                    rtcURL: url,
                    ephemeralKey: ephemeral,
                    iceServers: ice,
                    voice: voice,
                    transcriptionModel: transcriptionModel,
                    forceAudioText: forceAudioText
                )))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    // MARK: - WebRTC setup

    private func setupPeerConnection() throws {
        guard let factory else {
            throw NSError(domain: "RealtimeQuickService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "RTCPeerConnectionFactory 未初始化"])
        }

        let config = RTCConfiguration()
        config.iceServers = iceServers
        config.sdpSemantics = .unifiedPlan

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                "OfferToReceiveVideo": "false"
            ],
            optionalConstraints: nil
        )

        let pc = factory.peerConnection(with: config, constraints: constraints, delegate: self)
        self.peerConnection = pc

        // local audio
        let audioConstraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: [
                "googEchoCancellation": "true",
                "googAutoGainControl": "true",
                "googNoiseSuppression": "true"
            ]
        )
        let audioSource = factory.audioSource(with: audioConstraints)
        let audioTrack = factory.audioTrack(with: audioSource, trackId: "local_audio")
        audioTrack.isEnabled = true
        self.localAudioTrack = audioTrack

        _ = pc.add(audioTrack, streamIds: ["local_stream"])

        // DataChannel (oai-events)
        let dcConfig = RTCDataChannelConfiguration()
        dcConfig.isOrdered = true
        let dc = pc.dataChannel(forLabel: kEventsDataChannelLabel, configuration: dcConfig)
        dc?.delegate = self
        self.dataChannel = dc

        rtLog("PeerConnection ready (local audio + dataChannel=\(kEventsDataChannelLabel))")
    }

    /// Offer -> POST rtc_url -> Answer
    private func negotiate(completion: @escaping (Error?) -> Void) {
        guard let pc = peerConnection,
              let rtcURL = rtcURL,
              let key = ephemeralKey else {
            completion(NSError(domain: "RealtimeQuickService", code: -1,
                               userInfo: [NSLocalizedDescriptionKey: "缺少 rtcURL / ephemeralKey / peerConnection"]))
            return
        }

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                "OfferToReceiveVideo": "false"
            ],
            optionalConstraints: [
                "voiceActivityDetection": "true"
            ]
        )

        pc.offer(for: constraints) { [weak self] sdp, error in
            guard let self else { return }
            if let error { completion(error); return }
            guard let offer = sdp else {
                completion(NSError(domain: "RealtimeQuickService", code: -1,
                                   userInfo: [NSLocalizedDescriptionKey: "createOffer 返回空"]))
                return
            }

            pc.setLocalDescription(offer) { err in
                if let err { completion(err); return }

                self.workQueue.async {
                    let sdpStr = pc.localDescription?.sdp ?? offer.sdp

                    var request = URLRequest(url: rtcURL)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
                    request.setValue("application/sdp", forHTTPHeaderField: "Accept")
                    request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
                    request.httpBody = sdpStr.data(using: .utf8)

                    URLSession.shared.dataTask(with: request) { data, response, error in
                        if let error { completion(error); return }

                        guard let http = response as? HTTPURLResponse,
                              (200..<300).contains(http.statusCode),
                              let data,
                              let answerSDP = String(data: data, encoding: .utf8) else {
                            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                            completion(NSError(domain: "RealtimeQuickService", code: code,
                                               userInfo: [NSLocalizedDescriptionKey: "SDP 交换失败：\(code) \(body)"]))
                            return
                        }

                        pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: answerSDP)) { err in
                            completion(err)
                        }
                    }.resume()
                }
            }
        }
    }

    // MARK: - session.update (Sora Planner)

    private func sendSessionUpdateIfNeeded() {
        guard !sessionUpdateSent else { return }
        guard let dc = dataChannel, dc.readyState == .open else {
            rtLog("session.update skipped: dataChannel not open")
            return
        }

        sessionUpdateSent = true

        let sessionUpdate: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "instructions": buildSoraInstructions(),
                "voice": voice,
                "output_audio_format": "pcm16",
                "output_modalities": outputModalitiesForSpeech(),
                "turn_detection": [
                    "type": "server_vad",
                    "silence_duration_ms": 350,
                    "prefix_padding_ms": 150,
                    "create_response": true,
                    "interrupt_response": true
                ],
                "input_audio_transcription": transcriptionModel == nil
                ? NSNull()
                : [
                    "model": transcriptionModel as Any
                ]
            ]
        ]

        sendJSON(sessionUpdate, on: dc)
        rtLog("session.update sent (Sora planner + VAD + transcription)")
    }

    private func outputModalitiesForSpeech() -> [String] {
        switch outputMode {
        case .textOnly:
            return ["text"]
        case .audioOnly:
            return ["audio"] // 仅当后端确认模型支持
        case .audioAndText:
            return ["audio", "text"] // 维持你原默认
        }
    }

    // ✅ 语义规划提示词（对齐 ContentView 的自动生成链路）
    private func buildSoraInstructions() -> String {
        return """
你是「GPT Solara」的即時語音影片設計師。你的任務：把使用者口述的畫面想法，整理成一條可直接給 Sora 的中文提示語。

【目標】
- 不是閒聊；是「聽描述 → 補齊關鍵要素 → 輸出最終生成描述」。

【你需要補齊的三要素（缺就追問）】
1) 主體：誰/什麼（人物/物體/生物）
2) 場景：在哪裡（室內/戶外/時間/天氣）
3) 風格/鏡頭：寫實/電影感/動畫；運鏡/節奏（可簡短）

【對話節奏】
- 多聽少講；每次回覆 1～2 句。
- 只問一個問題，不要連環追問。

【收尾條件（只要滿足任一條，就必須輸出 SORA 行）】
- 使用者說：差不多了 / OK / 就這樣 / 生成吧 / 開始生成 / 完成
- 或者：三要素已齊全且使用者停頓（你判斷信息足夠即可直接收尾）

【輸出硬規則（非常重要）】
- 一旦收尾：你只能輸出「單獨一行」：
  SORA: <不超過50字的畫面描述>
- 除了這一行，不能輸出任何其他文字、解釋、標點、換行、代碼塊。

【畫面純淨要求】
- 只描述畫面可見內容（人物/物體/場景/光線/運動/鏡頭）。
- 禁止要求畫面出現文字、字幕、LOGO、水印、App介面、按鈕等。
"""
    }

    // MARK: - Sora Hook（语义→生成视频链路）

    /// ✅ 从助手输出里解析出 SORA 行，并通过 delegate 抛给 ContentView → submitPromptToSora()
    private func maybeTriggerSora(with assistantText: String) {
        // 统一换行
        let normalized = assistantText.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)

        // ✅ 容错匹配：SORA: / SORA：/ Sora: / 前置空格 / "SORA :"
        let pattern = #"^\s*sora\s*[:：]\s*(.+?)\s*$"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])

        var extracted: String?
        for lineSub in lines {
            let line = String(lineSub)
            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)
            if let match = regex?.firstMatch(in: line, options: [], range: range),
               match.numberOfRanges >= 2 {
                let contentRange = match.range(at: 1)
                extracted = ns.substring(with: contentRange).trimmingCharacters(in: .whitespacesAndNewlines)
                if extracted?.isEmpty == false { break }
            }
        }

        guard let soraLine = extracted, !soraLine.isEmpty else { return }

        // 去重
        if let last = lastTriggeredSoraLine,
           let lastAt = lastTriggeredSoraAt,
           last == soraLine,
           Date().timeIntervalSince(lastAt) <= kSoraDuplicateSuppressWindow {
            rtLog("🎬 SORA duplicate suppressed")
            return
        }
        lastTriggeredSoraLine = soraLine
        lastTriggeredSoraAt = Date()

        let lastUser = conversation.reversed().first(where: { $0["role"] == "user" })?["text"] ?? ""
        rtLog("🎬 Trigger SORA: lastUser=\(lastUser), sora=\(soraLine)")

        DispatchQueue.main.async {
            self.delegate?.realtimeService(self, didTriggerSoraWithUserPrompt: lastUser, assistantSummary: soraLine)
        }
    }

    /// ✅ 如果没有 done 事件：在 delta 后做一个 debounce 扫描
    private func scheduleSoraDebouncedScan() {
        soraDebounceWorkItem?.cancel()

        // 只有在看起来“可能出现 SORA”时才安排扫描，减少无意义开销
        let lower = transcriptBuffer.lowercased()
        guard lower.contains("sora") else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let snapshot = self.transcriptBuffer
            self.maybeTriggerSora(with: snapshot)
        }
        soraDebounceWorkItem = work
        workQueue.asyncAfter(deadline: .now() + kSoraDebounceScanDelay, execute: work)
    }

    // MARK: - JSON send helper

    fileprivate func sendJSON(_ obj: [String: Any], on dc: RTCDataChannel) {
        do {
            let data = try JSONSerialization.data(withJSONObject: obj, options: [])
            dc.sendData(RTCDataBuffer(data: data, isBinary: false))
        } catch {
            rtLog("sendJSON error: \(error)")
        }
    }

    // MARK: - UI throttle

    fileprivate func throttleEmitAssistantTranscript() {
        guard kRealtimeTextToUIEnabled_iOS else { return }
        guard !assistantEmitScheduled else { return }

        assistantEmitScheduled = true

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.assistantEmitScheduled = false
            let full = self.transcriptBuffer
            DispatchQueue.main.async {
                self.delegate?.realtimeService(self, didUpdateTranscript: "[A]" + full)
            }
        }

        assistantEmitWorkItem = work
        workQueue.asyncAfter(deadline: .now() + kAssistantEmitInterval, execute: work)
    }

    // MARK: - Audio notifications (stability)

    private func installAudioObserversIfNeeded() {
        guard !audioObserversInstalled else { return }
        audioObserversInstalled = true

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleAudioInterruption(_:)),
                       name: AVAudioSession.interruptionNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleRouteChange(_:)),
                       name: AVAudioSession.routeChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleMediaServicesReset(_:)),
                       name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    }

    private func removeAudioObserversIfNeeded() {
        guard audioObserversInstalled else { return }
        audioObserversInstalled = false
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleAudioInterruption(_ n: Notification) {
        guard let info = n.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        rtLog("Audio interruption: \(type.rawValue)")

        workQueue.async { [weak self] in
            guard let self else { return }
            self.markActivity()
            if type == .ended, self.isRunning {
                do { try self.configureAudioSessionWithFallbacks() }
                catch { rtLog("Re-config audio after interruption failed: \(error)") }
            }
        }
    }

    @objc private func handleRouteChange(_ n: Notification) {
        rtLog("Audio route change")
        workQueue.async { [weak self] in
            self?.markActivity()
        }
    }

    @objc private func handleMediaServicesReset(_ n: Notification) {
        rtLog("MediaServicesWereReset -> hard reset recommended")
        workQueue.async { [weak self] in
            self?.stopCallNow(statusText: "系统音频服务重置，已断开")
        }
    }
}

// MARK: - WebRTC Delegates

extension RealtimeQuickService: RTCPeerConnectionDelegate, RTCDataChannelDelegate {

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        rtLog("signaling state = \(stateChanged.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        workQueue.async { [weak self] in
            guard let self else { return }
            rtLog("ICE state = \(newState.rawValue)")

            switch newState {
            case .connected, .completed:
                self.iceReconnectWorkItem?.cancel()
                self.iceReconnectWorkItem = nil

            case .disconnected:
                self.iceReconnectWorkItem?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    let state = self.peerConnection?.iceConnectionState ?? .new
                    if state == .disconnected {
                        rtLog("ICE disconnected too long -> stop")
                        self.stopCallNow(statusText: "网络不稳定，已断开")
                    }
                }
                self.iceReconnectWorkItem = work
                self.workQueue.asyncAfter(deadline: .now() + 5.0, execute: work)

            case .failed:
                self.iceReconnectWorkItem?.cancel()
                self.iceReconnectWorkItem = nil
                rtLog("ICE failed -> stop")
                self.stopCallNow(statusText: "网络失败，已断开")

            default:
                break
            }
        }
    }

    // ✅（很多 WebRTC 版本要求）PeerConnection 打开 DataChannel 的回调
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        rtLog("peerConnection didOpen dataChannel label=\(dataChannel.label)")
        workQueue.async { [weak self] in
            guard let self else { return }
            self.dataChannel = dataChannel
            self.dataChannel?.delegate = self
            self.sendSessionUpdateIfNeeded()
            self.markActivity()
        }
    }

    // ✅（部分 WebRTC 版本要求）整体 PeerConnection 连接状态变化
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        rtLog("PeerConnection state = \(newState.rawValue)")
        workQueue.async { [weak self] in
            self?.markActivity()
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        rtLog("ICE gathering = \(newState.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        rtLog("didRemove candidates: \(candidates.count)")
    }

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        rtLog("peerConnectionShouldNegotiate()")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didAdd rtpReceiver: RTCRtpReceiver,
                        streams: [RTCMediaStream]) {
        if let track = rtpReceiver.track as? RTCAudioTrack {
            rtLog("remote audio track: \(track.trackId)")
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove rtpReceiver: RTCRtpReceiver) {}

    // MARK: - DataChannel

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        rtLog("DataChannel state = \(dataChannel.readyState.rawValue)")
        workQueue.async { [weak self] in
            guard let self else { return }
            if dataChannel.readyState == .open {
                self.dataChannel = dataChannel
                self.dataChannel?.delegate = self
                self.sendSessionUpdateIfNeeded()
            }
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard !buffer.isBinary else { return }
        let raw = buffer.data
        workQueue.async { [weak self] in
            self?.handleIncomingEventData(raw)
        }
    }

    // MARK: - Event handling (workQueue only)

    private func handleIncomingEventData(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        rtLog("recv: \(text.prefix(140))")

        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let type = (json["type"] as? String) ?? ""
        markActivity()

        if type.hasPrefix("conversation.item.") {
            if let item = json["item"] as? [String: Any] {
                handleConversationItem(item: item)
            }
            return
        }

        switch type {

        case "conversation.item.input_audio_transcription.completed":
            if let userText = Self.extractUserTranscript(from: json), !userText.isEmpty {
                conversation.append(["role": "user", "text": userText])
                if kRealtimeTextToUIEnabled_iOS {
                    DispatchQueue.main.async {
                        self.delegate?.realtimeService(self, didUpdateTranscript: "[U]" + userText)
                    }
                }
            }

        // ✅ 助手文本 delta（兼容 transcript/transcription 多种命名）
        case "response.output_text.delta",
             "response.text.delta",
             "response.output_audio_transcript.delta",
             "response.audio_transcript.delta",
             "response.output_audio_transcription.delta",
             "response.audio_transcription.delta":
            if let delta = Self.extractAssistantText(from: json) {
                transcriptBuffer.append(delta)
                throttleEmitAssistantTranscript()
                scheduleSoraDebouncedScan()
            }

        // ✅ 助手文本 done（兼容 transcript/transcription 多种命名）
        case "response.output_text.done",
             "response.text.done",
             "response.output_audio_transcript.done",
             "response.audio_transcript.done",
             "response.output_audio_transcription.done",
             "response.audio_transcription.done",
             "response.done",
             "response.completed":
            let full = Self.extractAssistantText(from: json) ?? (transcriptBuffer.isEmpty ? nil : transcriptBuffer)
            if let finalText = full, !finalText.isEmpty {
                transcriptBuffer = ""
                soraDebounceWorkItem?.cancel()
                soraDebounceWorkItem = nil

                if kRealtimeTextToUIEnabled_iOS {
                    DispatchQueue.main.async {
                        self.delegate?.realtimeService(self, didUpdateTranscript: "[A]" + finalText)
                    }
                }
                maybeTriggerSora(with: finalText)
            }

        case "error":
            let msg = (json["error"] as? [String: Any])?["message"] as? String
            ?? (json["message"] as? String)
            ?? "Realtime error"

            rtLog("Realtime error: \(msg)")

            // ✅ 更稳健的 outputMode 自适应（不破坏你原逻辑）
            if (msg.contains("output_modalities") || msg.contains("modalities")) {
                // 若 audioOnly 不行 -> 退回 audio+text
                if self.outputMode == .audioOnly {
                    rtLog("Fallback outputMode: audioOnly -> audioAndText")
                    self.outputMode = .audioAndText
                    self.sessionUpdateSent = false
                    self.sendSessionUpdateIfNeeded()
                } else if self.outputMode == .audioAndText {
                    // 若 audio+text 不行 -> 尝试 audioOnly
                    rtLog("Fallback outputMode: audioAndText -> audioOnly")
                    self.outputMode = .audioOnly
                    self.sessionUpdateSent = false
                    self.sendSessionUpdateIfNeeded()
                }
            }

            let err = NSError(domain: "RealtimeQuickService", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: msg])
            DispatchQueue.main.async {
                self.delegate?.realtimeService(self, didFailWith: err)
                self.delegate?.realtimeService(self, didUpdateStatus: "会话错误")
            }

        default:
            if let item = json["item"] as? [String: Any] {
                handleConversationItem(item: item)
            }
        }
    }

    private func handleConversationItem(item: [String: Any]) {
        let role = (item["role"] as? String) ?? ""
        if role == "assistant" {
            guard let text = Self.extractAssistantTextFromItem(item), !text.isEmpty else { return }
            if kRealtimeTextToUIEnabled_iOS {
                DispatchQueue.main.async {
                    self.delegate?.realtimeService(self, didUpdateTranscript: "[A]" + text)
                }
            }
            maybeTriggerSora(with: text)

        } else if role == "user" {
            guard let text = Self.extractUserTextFromItem(item), !text.isEmpty else { return }
            conversation.append(["role": "user", "text": text])
            if kRealtimeTextToUIEnabled_iOS {
                DispatchQueue.main.async {
                    self.delegate?.realtimeService(self, didUpdateTranscript: "[U]" + text)
                }
            }
        }
    }

    // MARK: - Parsing helpers

    fileprivate static func extractAssistantText(from json: [String: Any]) -> String? {
        if let t = json["text"] as? String, !t.isEmpty { return t }
        if let t = json["transcript"] as? String, !t.isEmpty { return t }
        if let t = json["delta"] as? String, !t.isEmpty { return t }

        if let deltaDict = json["delta"] as? [String: Any],
           let t = deltaDict["text"] as? String, !t.isEmpty { return t }

        if let response = json["response"] as? [String: Any],
           let outputs = response["output"] as? [[String: Any]] {
            for out in outputs {
                if let contents = out["content"] as? [[String: Any]] {
                    for c in contents {
                        if let t = c["text"] as? String, !t.isEmpty { return t }
                        if let t = c["transcript"] as? String, !t.isEmpty { return t }
                        if let d = c["delta"] as? String, !d.isEmpty { return d }
                        if let audio = c["audio"] as? [String: Any],
                           let t = audio["transcript"] as? String, !t.isEmpty { return t }
                    }
                }
            }
        }
        return nil
    }

    fileprivate static func extractAssistantTextFromItem(_ item: [String: Any]) -> String? {
        guard let contents = item["content"] as? [[String: Any]] else { return nil }
        for c in contents {
            if let t = c["text"] as? String, !t.isEmpty { return t }
            if let t = c["transcript"] as? String, !t.isEmpty { return t }
            if let audio = c["audio"] as? [String: Any],
               let t = audio["transcript"] as? String, !t.isEmpty { return t }
        }
        return nil
    }

    fileprivate static func extractUserTextFromItem(_ item: [String: Any]) -> String? {
        guard let contents = item["content"] as? [[String: Any]] else { return nil }
        for c in contents {
            if let t = c["text"] as? String, !t.isEmpty { return t }
            if let t = c["transcript"] as? String, !t.isEmpty { return t }
        }
        return nil
    }

    fileprivate static func extractUserTranscript(from json: [String: Any]) -> String? {
        if let t = json["transcript"] as? String, !t.isEmpty { return t }

        if let item = json["item"] as? [String: Any] {
            if let t = item["transcript"] as? String, !t.isEmpty { return t }
            if let trans = item["transcription"] as? [String: Any],
               let t = trans["text"] as? String, !t.isEmpty { return t }
        }

        if let delta = json["delta"] as? String, !delta.isEmpty { return delta }
        return nil
    }
}

