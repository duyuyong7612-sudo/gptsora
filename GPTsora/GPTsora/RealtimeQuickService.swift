//
//  RealtimeQuickService.swift
//  GPTsora / GPT Solara
//
//  商用级优化版（功能只增不退）
//  1) 首次接通优化：/session 与 音频权限/AudioSession 并行预热
//  2) UI不卡顿：assistant delta 文本节流合并（默认 80ms 刷新一次）
//  3) 线程安全：所有状态/缓冲/定时器统一 workQueue 串行处理
//
//  ✅ FIX/UPGRADE:
//  - 支持 Profile：sora(通用+视频助手) / remix(Remix 专用)
//  - 新增入口：startRemixAssistantCall() —— 从连接第一刻开始就是 Remix，不会被通用助手带跑
//  - /session payload 增加 profile（后端可路由到“专用助手模块”）
//  - remix profile 下不会触发 maybeTriggerSora（避免误触发视频生成）
//
//  ✅ 本次修复（素材先送入 Realtime）：
//  - 新增素材注入：injectImageDataURL(s)/injectImageURLs —— 先把图片/视频帧作为 input_image 注入 Realtime
//  - 使用稳定协议：conversation.item.create + input_image(image_url= data:...;base64,... 或 https://...)
//  - DataChannel 未 open 时事件排队，open 后自动 flush，避免“注入丢包”
//  - user 的 image-only item 不再报“未找到文本”噪音
//
//  ✅ 兼容：
//  - 你原 sendText 仍保留（input_text + response.create）
//  - response.create 增加 output_modalities 字段，兼容新旧
//

// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-1ec18339154553068c3e3a7a7b923547188dfea9882f57df777ec9581b9534b5"
// Source-SHA256: "14be1eb79d8cdcdb73c99eba4fa5f90d7fb0b86d0d605be26928a68b98b5b0a9"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import WebRTC

// MARK: - 后端配置

private enum Backend {
    static var apiBase: String { AppConfig.API.apiBase }
    static let sessionPath = "/session"
    static var sessionURL: URL { URL(string: apiBase + sessionPath)! }
}

// MARK: - 日志（商用：默认降噪，高频 delta 不刷 raw）

private enum RTLogLevel { case error, info, debug, verbose }

// ✅ 生产建议：DEBUG 才开 verbose；这里保留开关，不卡顿
private let kRTLogVerbose = false

fileprivate func rtLog(_ msg: String, level: RTLogLevel = .info) {
#if DEBUG
    NSLog("[RT-iOS] \(msg)")
#else
    if level == .error || level == .info {
        NSLog("[RT-iOS] \(msg)")
    }
#endif
}

// MARK: - 常量

private let kRealtimeDefaultVoice = "coral"
private let kRealtimeTextToUIEnabled_iOS = true

// UI 文本增量节流：越小越实时，越大越省主线程
private let kTranscriptUIFlushInterval: TimeInterval = 0.08

// keepalive
private let kKeepAliveInterval: TimeInterval = 15

// idle hang
private let kIdleCheckInterval: TimeInterval = 2
private let kMaxIdleSeconds: TimeInterval = 60

// Session cache
private let kSessionCacheTTL: TimeInterval = 25

// MARK: - 协议：给 View / Controller 用

protocol RealtimeQuickServiceDelegate: AnyObject {
    func realtimeServiceDidConnect(_ svc: RealtimeQuickService)
    func realtimeServiceDidDisconnect(_ svc: RealtimeQuickService)
    func realtimeService(_ svc: RealtimeQuickService, didUpdateStatus text: String)
    func realtimeService(_ svc: RealtimeQuickService, didUpdateTranscript text: String)
    func realtimeService(_ svc: RealtimeQuickService, didFailWith error: Error)

    /// ✅ 助手确认要「生成视频」时触发（最后一条用户口述 + 助手总结）
    func realtimeService(
        _ svc: RealtimeQuickService,
        didTriggerSoraWithUserPrompt userPrompt: String,
        assistantSummary: String
    )
}

// MARK: - RealtimeQuickService 核心

final class RealtimeQuickService: NSObject {

    // MARK: - Profile

    enum AssistantProfile: String {
        case soraPlanner = "sora"
        case remix = "remix"
    }

    // MARK: - Types

    private struct SessionInfo {
        let rtcURL: URL
        let ephemeralKey: String
        let iceServers: [RTCIceServer]
    }

    // MARK: - Singleton

    static let shared = RealtimeQuickService()

    weak var delegate: RealtimeQuickServiceDelegate?

    // MARK: - WebRTC / Session

    private var rtcURL: URL?
    private var ephemeralKey: String?
    private var iceServers: [RTCIceServer] = []

    private var factory: RTCPeerConnectionFactory!
    private var peerConnection: RTCPeerConnection?
    private var localAudioTrack: RTCAudioTrack?
    private var remoteAudioTrackBound = false
    private var dataChannel: RTCDataChannel?

    // ✅ 防止重复 session.update
    private var hasSentSessionUpdate: Bool = false

    // ✅ 当前 Profile（严格 workQueue 读写）
    private var assistantProfile: AssistantProfile = .soraPlanner

    // MARK: - State

    private(set) var isConnecting: Bool = false
    private(set) var isRunning: Bool = false
    private(set) var isMuted: Bool = false

    // 防止 stop 后旧回调乱改状态（严格只在 workQueue 读写）
    private var currentCallId = UUID()

    // 文本增量缓冲 + 简单会话（严格 workQueue）
    private var transcriptBuffer: String = ""
    private var conversation: [[String: String]] = []

    // ✅ UI 节流（严格 workQueue）
    private var transcriptFlushWorkItem: DispatchWorkItem?

    // keepalive（DispatchSourceTimer）
    private var pingTimer: DispatchSourceTimer?

    // 自动挂断（DispatchSourceTimer）
    private var idleTimer: DispatchSourceTimer?
    private var lastActivityAt: Date?

    // ICE 断线重连判定
    private var iceReconnectWorkItem: DispatchWorkItem?

    // ✅ 并行预热：session + audio
    private var pendingSessionInfo: SessionInfo?
    private var pendingAudioReady: Bool = false
    private var connectionBeganAt: Date?

    // ✅ Session cache（按 profile 分桶）
    private var cachedSessions: [AssistantProfile: (info: SessionInfo, fetchedAt: Date)] = [:]

    // ✅ NEW：DataChannel 未 ready 时，客户端事件排队（素材注入必需）
    private var queuedClientEvents: [[String: Any]] = []

    // 后台工作队列
    private let workQueue = DispatchQueue(label: "rt.service.queue", qos: .userInitiated)
    private let workQueueKey = DispatchSpecificKey<Void>()

    // 路由守护
    private var routeChangeObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?

    // MARK: - Init

    private override init() {
        super.init()
        workQueue.setSpecific(key: workQueueKey, value: ())
        setupFactory()
        installAudioSessionObservers()
    }

    deinit {
        removeAudioSessionObservers()
        workSync {
            hardResetState(notifyDelegate: false, deactivateAudioSession: true)
        }
    }

    // MARK: - Queue helpers

    private var isOnWorkQueue: Bool {
        DispatchQueue.getSpecific(key: workQueueKey) != nil
    }

    private func workAsync(_ block: @escaping () -> Void) {
        workQueue.async(execute: block)
    }

    private func workSync<T>(_ block: () -> T) -> T {
        if isOnWorkQueue { return block() }
        return workQueue.sync(execute: block)
    }

    // MARK: - Factory

    private func setupFactory() {
        RTCPeerConnectionFactory.initialize()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        factory = RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)
    }

    // MARK: - 活动打点（workQueue）

    private func markActivity() {
        lastActivityAt = Date()
    }
}

// MARK: - 強制重置（清理所有狀態，保證新通話乾淨）

extension RealtimeQuickService {

    private func hardResetState(notifyDelegate: Bool, deactivateAudioSession: Bool) {
        if !isOnWorkQueue {
            workQueue.async { [weak self] in
                self?.hardResetState(notifyDelegate: notifyDelegate, deactivateAudioSession: deactivateAudioSession)
            }
            return
        }

        rtLog("hardResetState(notify=\(notifyDelegate), deactivateAudio=\(deactivateAudioSession))")

        currentCallId = UUID()

        isConnecting = false
        isRunning = false
        isMuted = false
        hasSentSessionUpdate = false

        assistantProfile = .soraPlanner

        pendingSessionInfo = nil
        pendingAudioReady = false
        connectionBeganAt = nil

        stopPing()
        stopIdleHangWatch()
        transcriptFlushWorkItem?.cancel()
        transcriptFlushWorkItem = nil

        iceReconnectWorkItem?.cancel()
        iceReconnectWorkItem = nil

        // ✅ NEW：清空排队事件（避免新通话误注入旧素材）
        queuedClientEvents.removeAll()

        dataChannel?.delegate = nil
        dataChannel?.close()
        dataChannel = nil

        peerConnection?.delegate = nil
        peerConnection?.close()
        peerConnection = nil

        remoteAudioTrackBound = false
        localAudioTrack = nil

        rtcURL = nil
        ephemeralKey = nil
        iceServers = []

        conversation.removeAll()
        transcriptBuffer = ""

        let rtcSession = RTCAudioSession.sharedInstance()
        rtcSession.lockForConfiguration()
        rtcSession.isAudioEnabled = false
        rtcSession.useManualAudio = false
        rtcSession.unlockForConfiguration()

        if deactivateAudioSession {
            deactivateAudioSessionFully()
        }

        if notifyDelegate {
            DispatchQueue.main.async {
                self.delegate?.realtimeServiceDidDisconnect(self)
                self.delegate?.realtimeService(self, didUpdateStatus: "已挂断")
            }
        }
    }

    private func deactivateAudioSessionFully() {
        let rtc = RTCAudioSession.sharedInstance()
        rtc.lockForConfiguration()
        rtc.isAudioEnabled = false
        rtc.useManualAudio = false
        do { try rtc.setActive(false) }
        catch { rtLog("RTCAudioSession setActive(false) error: \(error)", level: .error) }
        rtc.unlockForConfiguration()

        let sys = AVAudioSession.sharedInstance()
        do { try sys.setActive(false, options: [.notifyOthersOnDeactivation]) }
        catch { rtLog("AVAudioSession setActive(false) error: \(error)", level: .error) }
    }
}

// MARK: - Idle hang watch（DispatchSourceTimer）

extension RealtimeQuickService {

    private func startIdleHangWatch() {
        if !isOnWorkQueue {
            workAsync { [weak self] in self?.startIdleHangWatch() }
            return
        }

        idleTimer?.cancel()
        idleTimer = nil

        lastActivityAt = Date()

        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + kIdleCheckInterval, repeating: kIdleCheckInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.isRunning else { return }
            guard let last = self.lastActivityAt else { return }
            let idle = Date().timeIntervalSince(last)
            if idle >= kMaxIdleSeconds {
                rtLog("⏱ idle \(idle)s >= \(kMaxIdleSeconds)s，自動掛斷", level: .info)
                self.hardResetState(notifyDelegate: true, deactivateAudioSession: true)
            }
        }
        timer.resume()
        idleTimer = timer
    }

    private func stopIdleHangWatch() {
        if !isOnWorkQueue {
            workAsync { [weak self] in self?.stopIdleHangWatch() }
            return
        }
        idleTimer?.cancel()
        idleTimer = nil
        lastActivityAt = nil
    }
}

// MARK: - 对外接口：开始/停止/静音/发文本/硬重置/预热

extension RealtimeQuickService {

    func startSoraPlannerCall() { startCallInternal(profile: .soraPlanner) }
    func startCall() { startCallInternal(profile: .soraPlanner) }

    func startRemixAssistantCall() { startCallInternal(profile: .remix) }

    func prewarmSession(profile: AssistantProfile = .soraPlanner) {
        workAsync { [weak self] in
            guard let self else { return }
            self.fetchSessionFromBackend(wantVideo: false, profile: profile) { [weak self] result in
                guard let self else { return }
                self.workAsync {
                    switch result {
                    case .success(let info):
                        self.cachedSessions[profile] = (info, Date())
                        rtLog("prewarmSession ok (cached, profile=\(profile.rawValue))", level: .info)
                    case .failure(let err):
                        rtLog("prewarmSession failed: \(err)", level: .debug)
                    }
                }
            }
        }
    }

    func clearSessionCache(profile: AssistantProfile? = nil) {
        workAsync { [weak self] in
            guard let self else { return }
            if let p = profile {
                self.cachedSessions[p] = nil
            } else {
                self.cachedSessions.removeAll()
            }
        }
    }

    func stopCall() {
        rtLog("stopCall()")
        workAsync { [weak self] in
            guard let self else { return }
            self.hardResetState(notifyDelegate: true, deactivateAudioSession: true)
        }
    }

    func hardReset() {
        rtLog("hardReset(): 強制重置 RealtimeQuickService")
        workAsync { [weak self] in
            guard let self else { return }
            self.hardResetState(notifyDelegate: true, deactivateAudioSession: true)
        }
    }

    func toggleMute() {
        workAsync { [weak self] in
            guard let self else { return }
            guard let audioTrack = self.localAudioTrack else { return }
            self.isMuted.toggle()
            audioTrack.isEnabled = !self.isMuted
            DispatchQueue.main.async {
                self.delegate?.realtimeService(self, didUpdateStatus: self.isMuted ? "已静音" : "麦克风开启")
            }
        }
    }

    /// 主动发文本（保持你原逻辑不改，只做 workQueue 串行）
    func sendText(_ text: String, speak: Bool = true) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return }

        workAsync { [weak self] in
            guard let self else { return }

            self.conversation.append(["role": "user", "text": t])
            self.markActivity()

            // ✅ 使用稳定协议：conversation.item.create（让文本进入对话上下文，能与 input_image 共享上下文）
            let item: [String: Any] = [
                "type": "conversation.item.create",
                "event_id": UUID().uuidString,
                "item": [
                    "type": "message",
                    "role": "user",
                    "content": [
                        [
                            "type": "input_text",
                            "text": t
                        ]
                    ]
                ]
            ]
            self.sendClientEvent(item)

            // ✅ 兼容：加入 output_modalities（新），保留 modalities（旧）
            let outMods: [String] = speak ? ["audio", "text"] : ["text"]
            let msg2: [String: Any] = [
                "type": "response.create",
                "response": [
                    "output_modalities": outMods,
                    "modalities": outMods,
                    "audio": ["voice": kRealtimeDefaultVoice]
                ]
            ]
            self.sendClientEvent(msg2)
        }
    }
}

// MARK: - 商用级外放音频：AudioSession 配置 + 路由守护

extension RealtimeQuickService {

    private func configureAudioSessionOnMain() throws {
        precondition(Thread.isMainThread, "configureAudioSessionOnMain must be called on main thread")

        let rtcSession = RTCAudioSession.sharedInstance()
        rtcSession.lockForConfiguration()
        defer { rtcSession.unlockForConfiguration() }

        let sysSession = AVAudioSession.sharedInstance()

        do { try sysSession.setPreferredSampleRate(48_000) } catch { rtLog("setPreferredSampleRate error: \(error)", level: .debug) }
        do { try sysSession.setPreferredIOBufferDuration(0.01) } catch { rtLog("setPreferredIOBufferDuration error: \(error)", level: .debug) }

        let options: AVAudioSession.CategoryOptions = [
            .defaultToSpeaker,
            .allowBluetooth
        ]

        try rtcSession.setCategory(AVAudioSession.Category.playAndRecord.rawValue, with: options)
        try rtcSession.setMode(AVAudioSession.Mode.videoChat.rawValue)
        try rtcSession.setActive(true)

        rtcSession.isAudioEnabled = true
        rtcSession.useManualAudio = false

        enforceSpeakerRouteIfNeeded()
        rtLog("AudioSession configured: playAndRecord + videoChat + speaker (no A2DP)", level: .info)
    }

    private func enforceSpeakerRouteIfNeeded() {
        let sysSession = AVAudioSession.sharedInstance()
        let outputs = sysSession.currentRoute.outputs

        let hasExternalOutput = outputs.contains { out in
            switch out.portType {
            case .headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .airPlay, .carAudio, .usbAudio:
                return true
            default:
                return false
            }
        }
        if hasExternalOutput { return }

        do { try sysSession.overrideOutputAudioPort(.speaker) }
        catch { rtLog("overrideOutputAudioPort(.speaker) error: \(error)", level: .debug) }
    }

    private func installAudioSessionObservers() {
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let active = self.workSync { self.isRunning || self.isConnecting }
            guard active else { return }
            self.enforceSpeakerRouteIfNeeded()
        }

        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let info = note.userInfo,
                  let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }

            switch type {
            case .began:
                rtLog("AVAudioSession interruption began", level: .info)
            case .ended:
                rtLog("AVAudioSession interruption ended -> re-enforce speaker", level: .info)
                let active = self.workSync { self.isRunning || self.isConnecting }
                if active { self.enforceSpeakerRouteIfNeeded() }
            @unknown default:
                break
            }
        }
    }

    private func removeAudioSessionObservers() {
        if let o = routeChangeObserver {
            NotificationCenter.default.removeObserver(o)
            routeChangeObserver = nil
        }
        if let o = interruptionObserver {
            NotificationCenter.default.removeObserver(o)
            interruptionObserver = nil
        }
    }
}

// MARK: - 实际执行连接逻辑（并行预热：Audio + /session）

extension RealtimeQuickService {

    private func startCallInternal(profile: AssistantProfile) {
        rtLog("startCallInternal(profile=\(profile.rawValue))")

        workAsync { [weak self] in
            guard let self else { return }

            self.hardResetState(notifyDelegate: false, deactivateAudioSession: true)

            self.assistantProfile = profile

            let callId = UUID()
            self.currentCallId = callId

            self.isConnecting = true
            self.isRunning = false
            self.isMuted = false

            self.pendingSessionInfo = nil
            self.pendingAudioReady = false
            self.connectionBeganAt = Date()

            DispatchQueue.main.async {
                self.delegate?.realtimeService(self, didUpdateStatus: "连接中…")
            }

            // 1) /session
            if let cache = self.cachedSessions[profile],
               Date().timeIntervalSince(cache.fetchedAt) < kSessionCacheTTL {
                rtLog("use cached /session (profile=\(profile.rawValue), age < \(kSessionCacheTTL)s)", level: .info)
                self.pendingSessionInfo = cache.info
                self.maybeBeginConnectIfReady(callId: callId)
            } else {
                self.fetchSessionFromBackend(wantVideo: false, profile: profile) { [weak self] result in
                    guard let self else { return }
                    self.workAsync {
                        guard callId == self.currentCallId else {
                            rtLog("/session 回调已过期，忽略", level: .debug)
                            return
                        }
                        switch result {
                        case .success(let info):
                            self.cachedSessions[profile] = (info, Date())
                            self.pendingSessionInfo = info
                            self.maybeBeginConnectIfReady(callId: callId)
                        case .failure(let err):
                            self.failAndReset(callId: callId, status: "获取会话失败", error: err)
                        }
                    }
                }
            }

            // 2) 权限 + AudioSession
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.preflightAudio(callId: callId)
            }
        }
    }

    private func preflightAudio(callId: UUID) {
        precondition(Thread.isMainThread)

        let perm = AVAudioSession.sharedInstance().recordPermission
        switch perm {
        case .granted:
            do {
                try configureAudioSessionOnMain()
                workAsync { [weak self] in
                    guard let self else { return }
                    guard callId == self.currentCallId else { return }
                    self.pendingAudioReady = true
                    self.maybeBeginConnectIfReady(callId: callId)
                }
            } catch {
                workAsync { [weak self] in
                    self?.failAndReset(callId: callId, status: "音频配置失败", error: error)
                }
            }

        case .denied:
            let err = NSError(domain: "RealtimeQuickService", code: -10,
                              userInfo: [NSLocalizedDescriptionKey: "麦克风未授权"])
            workAsync { [weak self] in
                self?.failAndReset(callId: callId, status: "麦克风未授权", error: err)
            }

        case .undetermined:
            AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
                guard let self else { return }
                DispatchQueue.main.async {
                    guard callId == self.workSync({ self.currentCallId }) else { return }
                    if !granted {
                        let err = NSError(domain: "RealtimeQuickService", code: -10,
                                          userInfo: [NSLocalizedDescriptionKey: "麦克风未授权"])
                        self.workAsync { [weak self] in
                            self?.failAndReset(callId: callId, status: "麦克风未授权", error: err)
                        }
                        return
                    }

                    do {
                        try self.configureAudioSessionOnMain()
                        self.workAsync { [weak self] in
                            guard let self else { return }
                            guard callId == self.currentCallId else { return }
                            self.pendingAudioReady = true
                            self.maybeBeginConnectIfReady(callId: callId)
                        }
                    } catch {
                        self.workAsync { [weak self] in
                            self?.failAndReset(callId: callId, status: "音频配置失败", error: error)
                        }
                    }
                }
            }

        @unknown default:
            let err = NSError(domain: "RealtimeQuickService", code: -11,
                              userInfo: [NSLocalizedDescriptionKey: "未知麦克风权限状态"])
            workAsync { [weak self] in
                self?.failAndReset(callId: callId, status: "麦克风权限异常", error: err)
            }
        }
    }

    private func maybeBeginConnectIfReady(callId: UUID) {
        guard isOnWorkQueue else {
            workAsync { [weak self] in self?.maybeBeginConnectIfReady(callId: callId) }
            return
        }
        guard callId == currentCallId else { return }
        guard pendingAudioReady else { return }
        guard let info = pendingSessionInfo else { return }

        pendingSessionInfo = nil
        connectWithSessionInfo(info, callId: callId)
    }

    private func connectWithSessionInfo(_ info: SessionInfo, callId: UUID) {
        guard callId == currentCallId else { return }

        self.rtcURL = info.rtcURL
        self.ephemeralKey = info.ephemeralKey
        self.iceServers = info.iceServers

        do {
            try setupPeerConnection()
        } catch {
            failAndReset(callId: callId, status: "建立连接失败", error: error)
            return
        }

        negotiate(callId: callId) { [weak self] error in
            guard let self else { return }
            self.workAsync {
                guard callId == self.currentCallId else {
                    rtLog("negotiate 回调已过期，忽略结果", level: .debug)
                    return
                }

                if let e = error {
                    self.failAndReset(callId: callId, status: "协商失败", error: e)
                } else {
                    self.isConnecting = false
                    self.isRunning = true
                    self.conversation.removeAll()
                    self.markActivity()
                    self.startPing()
                    self.startIdleHangWatch()

                    let cost: String
                    if let t0 = self.connectionBeganAt {
                        cost = String(format: "%.2fs", Date().timeIntervalSince(t0))
                    } else {
                        cost = "-"
                    }
                    rtLog("✅ connected(profile=\(self.assistantProfile.rawValue)), first-connect cost=\(cost)", level: .info)

                    DispatchQueue.main.async {
                        self.delegate?.realtimeServiceDidConnect(self)
                        self.delegate?.realtimeService(self, didUpdateStatus: "已连接")
                    }
                }
            }
        }
    }

    private func failAndReset(callId: UUID, status: String, error: Error) {
        guard isOnWorkQueue else {
            workAsync { [weak self] in self?.failAndReset(callId: callId, status: status, error: error) }
            return
        }
        guard callId == currentCallId else { return }

        rtLog("❌ \(status): \(error)", level: .error)
        hardResetState(notifyDelegate: false, deactivateAudioSession: true)

        DispatchQueue.main.async {
            self.delegate?.realtimeService(self, didUpdateStatus: status)
            self.delegate?.realtimeService(self, didFailWith: error)
        }
    }
}

// MARK: - /session 调用（增加 profile）

extension RealtimeQuickService {

    private func fetchSessionFromBackend(
        wantVideo: Bool,
        profile: AssistantProfile,
        completion: @escaping (Result<SessionInfo, Error>) -> Void
    ) {
        var request = URLRequest(url: Backend.sessionURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let payload: [String: Any] = [
            "want_video": wantVideo,
            "profile": profile.rawValue
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
                let json = try JSONSerialization.jsonObject(with: data, options: [])
                guard let dict = json as? [String: Any] else {
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

                let rawIce = (dict["ice_servers"] as? [[String: Any]]) ?? []
                let iceServers: [RTCIceServer]
                if rawIce.isEmpty {
                    iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
                } else {
                    iceServers = rawIce.compactMap { d in
                        guard let urls = d["urls"] else { return nil }
                        if let s = urls as? String {
                            return RTCIceServer(
                                urlStrings: [s],
                                username: d["username"] as? String,
                                credential: d["credential"] as? String
                            )
                        } else if let arr = urls as? [String] {
                            return RTCIceServer(
                                urlStrings: arr,
                                username: d["username"] as? String,
                                credential: d["credential"] as? String
                            )
                        }
                        return nil
                    }
                }

                rtLog("session ok(profile=\(profile.rawValue)), rtc_url=\(urlStr)", level: .info)
                completion(.success(SessionInfo(rtcURL: url, ephemeralKey: ephemeral, iceServers: iceServers)))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }
}

// MARK: - WebRTC：PeerConnection + Negotiate

extension RealtimeQuickService {

    private func setupPeerConnection() throws {
        guard let factory = factory else {
            throw NSError(domain: "RealtimeQuickService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "RTCPeerConnectionFactory 未初始化"])
        }

        let config = RTCConfiguration()
        config.iceServers = iceServers
        config.sdpSemantics = .unifiedPlan
        config.iceCandidatePoolSize = 1

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "false"],
            optionalConstraints: nil
        )

        let pc = factory.peerConnection(with: config, constraints: constraints, delegate: self)
        self.peerConnection = pc

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

        pc.add(audioTrack, streamIds: ["local_stream"])

        let dcConfig = RTCDataChannelConfiguration()
        dcConfig.isOrdered = true
        let dc = pc.dataChannel(forLabel: "oai-events", configuration: dcConfig)
        dc?.delegate = self
        self.dataChannel = dc

        rtLog("PeerConnection + local audio track ready", level: .info)
    }

    private func negotiate(callId: UUID, completion: @escaping (Error?) -> Void) {
        guard let pc = peerConnection,
              let rtcURL = rtcURL,
              let key = ephemeralKey else {
            completion(NSError(domain: "RealtimeQuickService", code: -1,
                               userInfo: [NSLocalizedDescriptionKey: "缺少 rtcURL / ephemeralKey / peerConnection"]))
            return
        }

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "false"],
            optionalConstraints: ["voiceActivityDetection": "true"]
        )

        pc.offer(for: constraints) { [weak self] sdp, error in
            guard let self else { return }
            self.workAsync {
                guard callId == self.currentCallId, pc === self.peerConnection else {
                    rtLog("offer callback stale, ignore", level: .debug)
                    return
                }
                if let e = error { completion(e); return }
                guard let offer = sdp else {
                    completion(NSError(domain: "RealtimeQuickService", code: -1,
                                       userInfo: [NSLocalizedDescriptionKey: "createOffer 返回空"]))
                    return
                }

                pc.setLocalDescription(offer) { [weak self] error in
                    guard let self else { return }
                    self.workAsync {
                        guard callId == self.currentCallId, pc === self.peerConnection else {
                            rtLog("setLocalDescription callback stale, ignore", level: .debug)
                            return
                        }
                        if let e = error { completion(e); return }

                        let sdpStr = pc.localDescription?.sdp ?? offer.sdp

                        var request = URLRequest(url: rtcURL)
                        request.httpMethod = "POST"
                        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
                        request.setValue("application/sdp", forHTTPHeaderField: "Accept")
                        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
                        request.timeoutInterval = 20
                        request.httpBody = sdpStr.data(using: .utf8)

                        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                            guard let self else { return }
                            self.workAsync {
                                guard callId == self.currentCallId, pc === self.peerConnection else {
                                    rtLog("SDP exchange callback stale, ignore", level: .debug)
                                    return
                                }
                                if let e = error { completion(e); return }

                                guard let http = response as? HTTPURLResponse,
                                      (200..<300).contains(http.statusCode),
                                      let data = data,
                                      let answerSDP = String(data: data, encoding: .utf8) else {
                                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                                    let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                                    completion(NSError(domain: "RealtimeQuickService", code: code,
                                                       userInfo: [NSLocalizedDescriptionKey: "SDP 交换失败：\(code) \(body)"]))
                                    return
                                }

                                let answer = RTCSessionDescription(type: .answer, sdp: answerSDP)
                                pc.setRemoteDescription(answer) { [weak self] error in
                                    guard let self else { return }
                                    self.workAsync {
                                        guard callId == self.currentCallId, pc === self.peerConnection else {
                                            rtLog("setRemoteDescription callback stale, ignore", level: .debug)
                                            return
                                        }
                                        completion(error)
                                    }
                                }
                            }
                        }.resume()
                    }
                }
            }
        }
    }
}

// MARK: - keepalive（DispatchSourceTimer）

extension RealtimeQuickService {

    private func startPing() {
        if !isOnWorkQueue {
            workAsync { [weak self] in self?.startPing() }
            return
        }

        pingTimer?.cancel()
        pingTimer = nil

        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + kKeepAliveInterval, repeating: kKeepAliveInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard let _ = self.dataChannel, self.dataChannel?.readyState == .open else { return }
            // no-op (WebRTC 자체 keepalive)
        }
        timer.resume()
        pingTimer = timer
    }

    private func stopPing() {
        if !isOnWorkQueue {
            workAsync { [weak self] in self?.stopPing() }
            return
        }
        pingTimer?.cancel()
        pingTimer = nil
    }
}

// MARK: - session.update（只保留通用助手 work definition；Remix instructions 由后端注入）
// ✅ 通用+视频助手保留；Remix 不再在前端提供 instructions（避免与后端“唯一真源”冲突）

extension RealtimeQuickService {

    private static let soraInstructions: String = {
        return """
        Safari。
        """
    }()

    private var currentInstructions: String? {
        switch assistantProfile {
        case .soraPlanner:
            return Self.soraInstructions
        case .remix:
            return nil
        }
    }

    private func sendSessionUpdateIfNeeded() {
        if !isOnWorkQueue {
            workAsync { [weak self] in self?.sendSessionUpdateIfNeeded() }
            return
        }
        guard !hasSentSessionUpdate else { return }
        hasSentSessionUpdate = true
        sendSessionUpdate()
    }

    private func sendSessionUpdate() {
        guard let dc = dataChannel, dc.readyState == .open else {
            rtLog("session.update skipped: dataChannel not open", level: .debug)
            return
        }

        var sessionDict: [String: Any] = [
            "modalities": ["audio", "text"],
            "voice": kRealtimeDefaultVoice,
            "turn_detection": [
                "type": "server_vad",
                "silence_duration_ms": 350,
                "prefix_padding_ms": 150
            ]
        ]

        if let inst = currentInstructions, !inst.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sessionDict["instructions"] = inst
        }

        let msg: [String: Any] = [
            "type": "session.update",
            "session": sessionDict
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: msg, options: [])
            dc.sendData(RTCDataBuffer(data: data, isBinary: false))
            rtLog("session.update sent (profile=\(assistantProfile.rawValue))", level: .info)

            // ✅ NEW：session.update 发完后，flush 排队事件（素材注入/草案等）
            flushQueuedClientEventsIfAny()
        } catch {
            rtLog("session.update JSON error: \(error)", level: .error)
        }
    }

    private func maybeTriggerSora(with assistantText: String) {
        guard assistantProfile == .soraPlanner else { return }

        let normalized = assistantText.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)

        guard let soraLineSub = lines.first(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("SORA:")
        }) else {
            rtLog("🎬 (Hook) assistantText 中沒有 SORA: 行，跳過", level: .debug)
            return
        }

        var soraLine = String(soraLineSub)
        if let range = soraLine.range(of: "SORA:") {
            soraLine = String(soraLine[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !soraLine.isEmpty else {
            rtLog("🎬 (Hook) SORA 行內容為空，跳過", level: .debug)
            return
        }

        let lastUser = conversation.reversed().first(where: { $0["role"] == "user" })?["text"] ?? ""
        rtLog("🎬 (Hook) 觸發視頻生成, lastUser=\(lastUser), soraSummary=\(soraLine)", level: .info)

        DispatchQueue.main.async {
            self.delegate?.realtimeService(
                self,
                didTriggerSoraWithUserPrompt: lastUser,
                assistantSummary: soraLine
            )
        }
    }

    func applyRemixProfile() {
        workAsync { [weak self] in
            guard let self else { return }
            self.assistantProfile = .remix
            if let dc = self.dataChannel, dc.readyState == .open {
                self.hasSentSessionUpdate = true
                self.sendSessionUpdate()
            }
        }
    }

    func applySoraPlannerProfile() {
        workAsync { [weak self] in
            guard let self else { return }
            self.assistantProfile = .soraPlanner
            if let dc = self.dataChannel, dc.readyState == .open {
                self.hasSentSessionUpdate = true
                self.sendSessionUpdate()
            }
        }
    }

    static func extractRMXInstruction(from assistantText: String) -> String? {
        let normalized = assistantText.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: true)
        for lnSub in lines {
            let ln = lnSub.trimmingCharacters(in: .whitespacesAndNewlines)
            if ln.uppercased().hasPrefix("RMX:") {
                let body = ln.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
                return body.isEmpty ? nil : String(body)
            }
        }
        return nil
    }
}

// MARK: - ✅ NEW：DataChannel 发送封装（支持排队 + flush）

extension RealtimeQuickService {

    private func sendClientEvent(_ event: [String: Any]) {
        if !isOnWorkQueue {
            workAsync { [weak self] in self?.sendClientEvent(event) }
            return
        }

        guard let dc = dataChannel, dc.readyState == .open else {
            queuedClientEvents.append(event)
            return
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: event, options: [])
            dc.sendData(RTCDataBuffer(data: data, isBinary: false))
        } catch {
            rtLog("sendClientEvent JSON error: \(error)", level: .error)
        }
    }

    private func flushQueuedClientEventsIfAny() {
        guard isOnWorkQueue else {
            workAsync { [weak self] in self?.flushQueuedClientEventsIfAny() }
            return
        }
        guard let dc = dataChannel, dc.readyState == .open else { return }
        guard !queuedClientEvents.isEmpty else { return }

        let pending = queuedClientEvents
        queuedClientEvents.removeAll()

        for e in pending {
            do {
                let data = try JSONSerialization.data(withJSONObject: e, options: [])
                dc.sendData(RTCDataBuffer(data: data, isBinary: false))
            } catch {
                rtLog("flushQueuedClientEvents JSON error: \(error)", level: .error)
            }
        }

        rtLog("flushQueuedClientEvents ok: \(pending.count) events", level: .info)
    }
}

// MARK: - ✅ NEW：素材注入（图片/视频帧先送入 Realtime）

extension RealtimeQuickService {

    /// 注入一张图片（dataURL 或 https URL 都可）
    func injectImageURL(_ imageURL: String, requestAck: Bool = false) {
        injectImageURLs([imageURL], requestAck: requestAck)
    }

    /// 注入多张图片（例如视频关键帧：8~16 张）
    /// - imageURLs 支持：
    ///   - "data:image/jpeg;base64,...."
    ///   - "https://...."
    func injectImageURLs(_ imageURLs: [String], requestAck: Bool = false) {
        let urls = imageURLs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if urls.isEmpty { return }

        workAsync { [weak self] in
            guard let self else { return }
            self.markActivity()

            // ✅ 一张图一个 item，避免单包过大
            for u in urls {
                let ev: [String: Any] = [
                    "type": "conversation.item.create",
                    "event_id": UUID().uuidString,
                    "item": [
                        "type": "message",
                        "role": "user",
                        "content": [
                            [
                                "type": "input_image",
                                "image_url": u
                            ]
                        ]
                    ]
                ]
                self.sendClientEvent(ev)
            }

            if requestAck {
                // 让模型用一句话确认它已收到素材（默认 text-only，避免突然播报吓用户）
                let ack: [String: Any] = [
                    "type": "response.create",
                    "response": [
                        "output_modalities": ["text"],
                        "instructions": "请用一句话确认你已收到并看到了这些图片素材，然后等待用户继续描述需求。"
                    ]
                ]
                self.sendClientEvent(ack)
            }

            rtLog("injectImageURLs queued=\(urls.count), requestAck=\(requestAck)", level: .info)
        }
    }

    /// 便捷：直接传原始图片 bytes（你在 UI 层压缩后传进来）
    func injectImageData(_ data: Data, mime: String = "image/jpeg", requestAck: Bool = false) {
        let b64 = data.base64EncodedString()
        let dataURL = "data:\(mime);base64,\(b64)"
        injectImageURLs([dataURL], requestAck: requestAck)
    }

    /// 便捷：批量图片 bytes
    func injectImageDatas(_ datas: [Data], mime: String = "image/jpeg", requestAck: Bool = false) {
        let urls = datas.map { "data:\(mime);base64,\($0.base64EncodedString())" }
        injectImageURLs(urls, requestAck: requestAck)
    }
}


// MARK: - ✅ NEW：本地媒体（图片/视频）→ JPEG(关键帧) → 注入 Realtime（让模型“看图聊”）

extension RealtimeQuickService {

    /// ✅ 本地图片文件（HEIC/JPG/PNG…）→ 压缩 JPEG → input_image
    /// - 建议：maxDimension 1024（够看图，体积可控）
    func injectLocalImageFile(
        _ url: URL,
        maxDimension: CGFloat = 1024,
        jpegQuality: CGFloat = 0.78,
        requestAck: Bool = false
    ) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            guard let cg = Self._rt_downsampleImageCG(url: url, maxDimension: maxDimension) else {
                rtLog("injectLocalImageFile failed: decode \(url.lastPathComponent)", level: .error)
                return
            }
            guard let data = Self._rt_jpegData(from: cg, quality: jpegQuality) else {
                rtLog("injectLocalImageFile failed: encode jpeg", level: .error)
                return
            }
            self.injectImageData(data, mime: "image/jpeg", requestAck: requestAck)
        }
    }

    /// ✅ 本地视频文件 → 提取关键帧（默认 8 帧）→ input_image(多张)
    /// - 建议：maxDimension 640（关键帧够用且体积小）
    func injectLocalVideoKeyFrames(
        _ url: URL,
        frameCount: Int = 8,
        maxDimension: CGFloat = 640,
        jpegQuality: CGFloat = 0.72,
        requestAck: Bool = false
    ) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let datas = Self._rt_extractKeyFramesJPEG(
                url: url,
                count: frameCount,
                maxDimension: maxDimension,
                jpegQuality: jpegQuality
            )
            if datas.isEmpty {
                rtLog("injectLocalVideoKeyFrames failed: no frames", level: .error)
                return
            }
            self.injectImageDatas(datas, mime: "image/jpeg", requestAck: requestAck)
        }
    }


    /// ✅ 一次性：本地图片文件 + 文本 -> 让模型直接“看图回复”
    /// - 适用：相册/拍照得到的本地图片 URL
    func sendTextWithLocalImageFile(
        _ text: String?,
        imageURL: URL,
        maxDimension: CGFloat = 1024,
        jpegQuality: CGFloat = 0.78,
        speak: Bool = true,
        instructions: String? = nil
    ) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            guard let cg = Self._rt_downsampleImageCG(url: imageURL, maxDimension: maxDimension),
                  let data = Self._rt_jpegData(from: cg, quality: jpegQuality) else {
                rtLog("sendTextWithLocalImageFile failed: \(imageURL.lastPathComponent)", level: .error)
                return
            }
            self.sendTextWithImages(text, imageDatas: [data], mime: "image/jpeg", speak: speak, instructions: instructions)
        }
    }

    /// ✅ 一次性：本地视频文件（关键帧）+ 文本 -> 让模型“看视频帧回复”
    /// - 适用：相册/拍摄得到的本地视频 URL（会抽 8 帧左右）
    func sendTextWithLocalVideoKeyFrames(
        _ text: String?,
        videoURL: URL,
        frameCount: Int = 8,
        maxDimension: CGFloat = 640,
        jpegQuality: CGFloat = 0.72,
        speak: Bool = true,
        instructions: String? = nil
    ) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let datas = Self._rt_extractKeyFramesJPEG(
                url: videoURL,
                count: frameCount,
                maxDimension: maxDimension,
                jpegQuality: jpegQuality
            )
            if datas.isEmpty {
                rtLog("sendTextWithLocalVideoKeyFrames failed: no frames", level: .error)
                return
            }
            self.sendTextWithImages(text, imageDatas: datas, mime: "image/jpeg", speak: speak, instructions: instructions)
        }
    }

    /// ✅ 一次性：把「文本 + 图片/关键帧」作为同一个用户输入发给 Realtime，让它基于画面直接回复
    /// - 这会触发 response.create，所以助手会立刻开始“看图聊”
    /// - 如果 profile 是 soraPlanner，助手也可以在合适时机输出 `SORA: ...` 触发视频生成
    func sendTextWithImages(
        _ text: String?,
        imageDatas: [Data],
        mime: String = "image/jpeg",
        speak: Bool = true,
        instructions: String? = nil
    ) {
        let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty && imageDatas.isEmpty { return }

        let urls = imageDatas.map { "data:\(mime);base64,\($0.base64EncodedString())" }

        workAsync { [weak self] in
            guard let self else { return }
            self.markActivity()

            // ✅ conversation 用来在助手触发 SORA 时拿 lastUser
            if !t.isEmpty {
                self.conversation.append(["role": "user", "text": t])
            } else if !urls.isEmpty {
                self.conversation.append(["role": "user", "text": "（用户上传了图片/视频关键帧）"])
            }

            // 1) 第一条 item：text + 第一张图（若没有图则仅 text）
            var firstContent: [[String: Any]] = []
            if !t.isEmpty {
                firstContent.append(["type": "input_text", "text": t])
            }
            if let first = urls.first {
                firstContent.append(["type": "input_image", "image_url": first])
            }

            let firstItem: [String: Any] = [
                "type": "conversation.item.create",
                "event_id": UUID().uuidString,
                "item": [
                    "type": "message",
                    "role": "user",
                    "content": firstContent
                ]
            ]
            self.sendClientEvent(firstItem)

            // 2) 其它图片逐张发（避免单包过大）
            if urls.count > 1 {
                for u in urls.dropFirst() {
                    let ev: [String: Any] = [
                        "type": "conversation.item.create",
                        "event_id": UUID().uuidString,
                        "item": [
                            "type": "message",
                            "role": "user",
                            "content": [
                                [
                                    "type": "input_image",
                                    "image_url": u
                                ]
                            ]
                        ]
                    ]
                    self.sendClientEvent(ev)
                }
            }

            // 3) response.create：让模型开始回复（text/audio）
            let outMods: [String] = speak ? ["audio", "text"] : ["text"]
            var responsePayload: [String: Any] = [
                "output_modalities": outMods,
                "modalities": outMods,
                "audio": ["voice": kRealtimeDefaultVoice]
            ]
            if let inst = instructions, !inst.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                responsePayload["instructions"] = inst
            }

            let resp: [String: Any] = [
                "type": "response.create",
                "response": responsePayload
            ]
            self.sendClientEvent(resp)
        }
    }
}

// MARK: - ✅ NEW：底层工具（Downsample 图片 / 提取视频关键帧 / JPEG 编码）

private extension RealtimeQuickService {

    static func _rt_downsampleImageCG(url: URL, maxDimension: CGFloat) -> CGImage? {
        let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, srcOpts) else { return nil }

        let maxPx = max(64, Int(maxDimension))
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPx,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary)
    }

    static func _rt_extractKeyFramesJPEG(url: URL, count: Int, maxDimension: CGFloat, jpegQuality: CGFloat) -> [Data] {
        let asset = AVAsset(url: url)
        let duration = CMTimeGetSeconds(asset.duration)
        if !duration.isFinite || duration <= 0 { return [] }

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.12, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter  = CMTime(seconds: 0.12, preferredTimescale: 600)

        let n = max(1, min(count, 16))

        // ✅ 避免第一帧黑屏：尽量从 0.2s 开始（过短视频则 0）
        let start = min(0.2, max(0.0, duration * 0.02))

        var times: [CMTime] = []
        if n == 1 {
            times = [CMTime(seconds: start, preferredTimescale: 600)]
        } else {
            for i in 0..<n {
                let frac = Double(i) / Double(n - 1)
                let sec = max(0.0, min(duration, start + (duration - start) * frac))
                times.append(CMTime(seconds: sec, preferredTimescale: 600))
            }
        }

        var out: [Data] = []
        out.reserveCapacity(n)

        for t in times {
            do {
                let cg = try gen.copyCGImage(at: t, actualTime: nil)
                let scaled = _rt_downscaleCGImageIfNeeded(cg, maxDimension: maxDimension)
                if let data = _rt_jpegData(from: scaled, quality: jpegQuality) {
                    out.append(data)
                }
            } catch {
                continue
            }
        }

        return out
    }

    static func _rt_downscaleCGImageIfNeeded(_ image: CGImage, maxDimension: CGFloat) -> CGImage {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let maxSide = max(w, h)
        if maxSide <= maxDimension { return image }

        let scale = maxDimension / maxSide
        let newW = max(1, Int(w * scale))
        let newH = max(1, Int(h * scale))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let ctx = CGContext(
            data: nil,
            width: newW,
            height: newH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return image
        }

        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(newW), height: CGFloat(newH)))
        return ctx.makeImage() ?? image
    }

    static func _rt_jpegData(from image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }

        let q = max(0.1, min(1.0, quality))
        let options = [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary
        CGImageDestinationAddImage(dest, image, options)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}


// MARK: - WebRTC Delegate 实现

extension RealtimeQuickService: RTCPeerConnectionDelegate, RTCDataChannelDelegate {

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        workAsync { [weak self] in
            guard let self else { return }
            guard peerConnection === self.peerConnection else { rtLog("ignore stale signaling callback", level: .debug); return }
            rtLog("signaling state = \(stateChanged.rawValue)", level: .debug)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        workAsync { [weak self] in
            guard let self else { return }
            guard peerConnection === self.peerConnection else { rtLog("ignore stale didOpen dataChannel callback", level: .debug); return }
            rtLog("didOpen dataChannel: \(dataChannel.label)", level: .info)

            self.dataChannel = dataChannel
            dataChannel.delegate = self

            self.sendSessionUpdateIfNeeded()
            // session.update 里会 flushQueuedClientEventsIfAny()
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        workAsync { [weak self] in
            guard let self else { return }
            guard peerConnection === self.peerConnection else { rtLog("ignore stale ICE state callback", level: .debug); return }
            rtLog("ICE state = \(newState.rawValue)", level: .info)

            switch newState {
            case .connected, .completed:
                self.iceReconnectWorkItem?.cancel()
                self.iceReconnectWorkItem = nil

            case .disconnected:
                self.iceReconnectWorkItem?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    guard self.peerConnection === peerConnection else {
                        rtLog("ICE reconnect check: stale pc, ignore", level: .debug)
                        return
                    }
                    let state = self.peerConnection?.iceConnectionState ?? .new
                    if state == .disconnected {
                        rtLog("ICE 長時間 disconnected，執行斷開", level: .info)
                        self.hardResetState(notifyDelegate: true, deactivateAudioSession: true)
                        DispatchQueue.main.async {
                            self.delegate?.realtimeService(self, didUpdateStatus: "网络不稳定，已断开")
                        }
                    } else {
                        rtLog("ICE 已在延時期間恢復，不再斷開（state=\(state.rawValue))", level: .debug)
                    }
                }
                self.iceReconnectWorkItem = work
                self.workQueue.asyncAfter(deadline: .now() + 5, execute: work)

            case .failed:
                self.iceReconnectWorkItem?.cancel()
                self.iceReconnectWorkItem = nil
                rtLog("ICE failed，直接斷開", level: .info)
                self.hardResetState(notifyDelegate: true, deactivateAudioSession: true)
                DispatchQueue.main.async {
                    self.delegate?.realtimeService(self, didUpdateStatus: "网络失败，已断开")
                }

            default:
                break
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        workAsync { [weak self] in
            guard let self else { return }
            guard peerConnection === self.peerConnection else { rtLog("ignore stale ICE gathering callback", level: .debug); return }
            rtLog("ICE gathering = \(newState.rawValue)", level: .debug)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        if kRTLogVerbose {
            rtLog("didGenerate candidate: \(candidate.sdp)", level: .verbose)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        if kRTLogVerbose {
            rtLog("didRemove candidates: \(candidates.count)", level: .verbose)
        }
    }

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        if kRTLogVerbose {
            rtLog("peerConnectionShouldNegotiate()", level: .verbose)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        workAsync { [weak self] in
            guard let self else { return }
            guard peerConnection === self.peerConnection else { rtLog("ignore stale didAdd stream callback", level: .debug); return }
            rtLog("didAdd stream: \(stream.streamId)", level: .debug)

            if !self.remoteAudioTrackBound, let audioTrack = stream.audioTracks.first {
                self.remoteAudioTrackBound = true
                rtLog("remote audio track bound: \(audioTrack.trackId)", level: .info)
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        if kRTLogVerbose {
            rtLog("didRemove stream: \(stream.streamId)", level: .verbose)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        workAsync { [weak self] in
            guard let self else { return }
            guard peerConnection === self.peerConnection else { rtLog("ignore stale didAdd rtpReceiver callback", level: .debug); return }
            rtLog("didAdd rtpReceiver: \(rtpReceiver.track?.trackId ?? "nil")", level: .debug)

            if !self.remoteAudioTrackBound, let track = rtpReceiver.track as? RTCAudioTrack {
                self.remoteAudioTrackBound = true
                rtLog("remote audio track (RTP) bound: \(track.trackId)", level: .info)
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove rtpReceiver: RTCRtpReceiver) {
        if kRTLogVerbose {
            rtLog("didRemove rtpReceiver: \(rtpReceiver.track?.trackId ?? "nil")", level: .verbose)
        }
    }

    // MARK: - RTCDataChannelDelegate

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        workAsync { [weak self] in
            guard let self else { return }
            guard dataChannel === self.dataChannel else { rtLog("ignore stale DataChannel state callback", level: .debug); return }
            rtLog("DataChannel state = \(dataChannel.readyState.rawValue)", level: .info)

            if dataChannel.readyState == .open {
                self.sendSessionUpdateIfNeeded()
                // session.update 里会 flushQueuedClientEventsIfAny()
            }
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard dataChannel === self.dataChannel else { return }
        guard !buffer.isBinary else { return }
        guard let text = String(data: buffer.data, encoding: .utf8) else { return }

        workAsync { [weak self] in
            self?.handleDataChannelText(text)
        }
    }
}

// MARK: - DataChannel 事件解析 + UI节流

extension RealtimeQuickService {

    private func handleDataChannelText(_ text: String) {
        guard isOnWorkQueue else {
            workAsync { [weak self] in self?.handleDataChannelText(text) }
            return
        }

        if kRTLogVerbose {
            rtLog("DataChannel recv raw: \(text)", level: .verbose)
        }

        guard let data = text.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            rtLog("DataChannel recv: 非标准 JSON", level: .debug)
            return
        }

        let type = (json["type"] as? String) ?? ""
        if kRTLogVerbose || (!type.contains("delta")) {
            rtLog("DataChannel event type = \(type)", level: .debug)
        }

        markActivity()

        if type.hasPrefix("conversation.item.") {
            handleConversationItemEvent(json)
            return
        }

        switch type {
        case "response.output_text.delta":
            if let deltaText = Self.extractAssistantText(from: json) {
                transcriptBuffer.append(deltaText)
                scheduleAssistantTranscriptFlushIfNeeded()
            }

        case "response.output_text.done", "response.completed", "response.done":
            transcriptFlushWorkItem?.cancel()
            transcriptFlushWorkItem = nil

            let full = Self.extractAssistantText(from: json) ?? (transcriptBuffer.isEmpty ? nil : transcriptBuffer)
            if let finalText = full, !finalText.isEmpty {
                transcriptBuffer = ""
                if kRealtimeTextToUIEnabled_iOS {
                    DispatchQueue.main.async {
                        self.delegate?.realtimeService(self, didUpdateTranscript: "[A]" + finalText)
                    }
                }
                maybeTriggerSora(with: finalText)
            } else {
                rtLog("output_text.done / response.done: 未找到文本字段", level: .debug)
            }

        case "conversation.item.input_audio_transcription.completed":
            if let userText = Self.extractUserTranscript(from: json), !userText.isEmpty {
                conversation.append(["role": "user", "text": userText])
                if kRealtimeTextToUIEnabled_iOS {
                    DispatchQueue.main.async {
                        self.delegate?.realtimeService(self, didUpdateTranscript: "[U]" + userText)
                    }
                }
            } else {
                rtLog("input_audio_transcription.completed: 未找到 transcript", level: .debug)
            }

        case "error":
            let msg = (json["error"] as? [String: Any])?["message"] as? String
            ?? (json["message"] as? String)
            ?? "Realtime error"
            let err = NSError(domain: "RealtimeQuickService", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: msg])
            DispatchQueue.main.async {
                self.delegate?.realtimeService(self, didFailWith: err)
                self.delegate?.realtimeService(self, didUpdateStatus: "会话错误")
            }

        default:
            if let item = json["item"] as? [String: Any],
               let _ = item["role"] as? String {
                handleConversationItem(item: item)
            } else {
                if kRTLogVerbose {
                    rtLog("忽略事件 type=\(type)", level: .verbose)
                }
            }
        }
    }

    private func scheduleAssistantTranscriptFlushIfNeeded() {
        guard kRealtimeTextToUIEnabled_iOS else { return }
        guard transcriptFlushWorkItem == nil else { return }

        let callIdSnapshot = currentCallId
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard callIdSnapshot == self.currentCallId else { return }
            self.transcriptFlushWorkItem = nil
            let full = self.transcriptBuffer
            DispatchQueue.main.async {
                self.delegate?.realtimeService(self, didUpdateTranscript: "[A]" + full)
            }
        }

        transcriptFlushWorkItem = item
        workQueue.asyncAfter(deadline: .now() + kTranscriptUIFlushInterval, execute: item)
    }

    private func handleConversationItemEvent(_ json: [String: Any]) {
        guard let item = json["item"] as? [String: Any] else {
            rtLog("conversation.item.*: 缺少 item", level: .debug)
            return
        }
        handleConversationItem(item: item)
    }

    private func handleConversationItem(item: [String: Any]) {
        let role = (item["role"] as? String) ?? ""

        if role == "assistant" {
            guard let text = Self.extractAssistantTextFromItem(item), !text.isEmpty else {
                rtLog("conversation.item(assistant): 未找到文本", level: .debug)
                return
            }
            if kRealtimeTextToUIEnabled_iOS {
                DispatchQueue.main.async {
                    self.delegate?.realtimeService(self, didUpdateTranscript: "[A]" + text)
                }
            }
            maybeTriggerSora(with: text)

        } else if role == "user" {
            // ✅ NEW：如果是 image-only user item，直接忽略，不刷“未找到文本”
            if Self.itemContainsInputImageOnly(item) {
                return
            }

            guard let text = Self.extractUserTextFromItem(item), !text.isEmpty else {
                rtLog("conversation.item(user): 未找到文本", level: .debug)
                return
            }
            conversation.append(["role": "user", "text": text])
            if kRealtimeTextToUIEnabled_iOS {
                DispatchQueue.main.async {
                    self.delegate?.realtimeService(self, didUpdateTranscript: "[U]" + text)
                }
            }
        } else {
            if kRTLogVerbose {
                rtLog("conversation.item: 未处理的 role=\(role)", level: .verbose)
            }
        }
    }

    fileprivate static func itemContainsInputImageOnly(_ item: [String: Any]) -> Bool {
        guard let contents = item["content"] as? [[String: Any]] else { return false }
        let hasText = contents.contains { ($0["type"] as? String) == "input_text" }
        let hasImage = contents.contains { ($0["type"] as? String) == "input_image" }
        return hasImage && !hasText
    }

    // MARK: - 事件解析辅助方法

    fileprivate static func extractAssistantText(from json: [String: Any]) -> String? {
        if let t = json["text"] as? String, !t.isEmpty { return t }
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
                        if let d2 = c["delta"] as? [String: Any],
                           let t = d2["text"] as? String, !t.isEmpty { return t }
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
               let t = audio["transcript"] as? String,
               !t.isEmpty { return t }
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


