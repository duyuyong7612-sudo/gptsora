//
//  RealtimeQuickService.swift
//  GPTsora
//
//  阿杜版：按 Flutter RealtimeQuickService 1:1 还原的 iOS 原生实现（优化版）
//
//  总原则：
//  1) 只送音频：本地只采集麦克风 → WebRTC → OpenAI Realtime，所有回声/轮次交给模型和 server_vad。
//  2) 模型选在后端：具体用哪个 Realtime 模型由 /session 后端决定，这里只负责拿 rtc_url + ephemeral_key。
//  3) 通话模式优先：强制使用 AVAudioSession.playAndRecord + .voiceChat + WebRTC AEC/NS，保证“像打电话一样”的音频路径。

// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-db43a46ed265ad7cd61398a872aad271d5bda17e62c66030580c2a286f6dadf9"
// Source-SHA256: "3d023def546db0c373eb9daf0bfcb8e50c972262f53e25ceb31555de70ce2bc0"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation
import AVFoundation
import WebRTC

// MARK: - 后端配置

private enum Backend {
    /// 你的 FastAPI 后端，比如 http://YOUR_LAN_IP:8000
    static let apiBase = "http://YOUR_LAN_IP:8000"
    static let sessionPath = "/session"

    static var sessionURL: URL {
        URL(string: apiBase + sessionPath)!
    }
}

// MARK: - 小工具

fileprivate func rtLog(_ msg: String) {
    NSLog("[RT-iOS] \(msg)")
}

/// Realtime 语音声线（后端模型选型在 /session 里，这里只控制 voice）
private let kRealtimeDefaultVoice = "alloy"

/// 是否把 GPT 文本增量同步到 UI（默认 false，只走语音）
let kRealtimeTextToUIEnabled_iOS: Bool = false

// MARK: - 协议：给 View / Controller 用

protocol RealtimeQuickServiceDelegate: AnyObject {
    func realtimeServiceDidConnect(_ svc: RealtimeQuickService)
    func realtimeServiceDidDisconnect(_ svc: RealtimeQuickService)
    func realtimeService(_ svc: RealtimeQuickService, didUpdateStatus text: String)
    func realtimeService(_ svc: RealtimeQuickService, didUpdateTranscript text: String)
    func realtimeService(_ svc: RealtimeQuickService, didFailWith error: Error)
}

// MARK: - RealtimeQuickService 核心

final class RealtimeQuickService: NSObject {

    static let shared = RealtimeQuickService()

    weak var delegate: RealtimeQuickServiceDelegate?

    // 后端 /session 返回
    private var rtcURL: URL?
    private var ephemeralKey: String?
    private var iceServers: [RTCIceServer] = []

    // WebRTC 核心
    private var factory: RTCPeerConnectionFactory!
    private var peerConnection: RTCPeerConnection?
    private var localAudioTrack: RTCAudioTrack?
    private var remoteAudioTrackBound = false
    private var dataChannel: RTCDataChannel?

    // 状态
    private(set) var isConnecting: Bool = false
    private(set) var isRunning: Bool = false
    private(set) var isMuted: Bool = false

    // 用来“废弃”旧通话的 token（防止 stop 之后旧回调乱改状态）
    private var currentCallId = UUID()

    // 文本增量缓冲 + 简单会话
    private var transcriptBuffer: String = ""
    private var conversation: [[String: String]] = []

    // keepalive 心跳
    private var pingTimer: Timer?

    // 后台工作队列（网络/WebRTC 协商都放这里，避免阻塞主线程）
    private let workQueue = DispatchQueue(label: "rt.service.queue", qos: .userInitiated)

    private override init() {
        super.init()
        setupFactory()
    }

    deinit {
        stopCall()
    }

    // MARK: - 初始化 Factory

    private func setupFactory() {
        RTCPeerConnectionFactory.initialize()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        factory = RTCPeerConnectionFactory(encoderFactory: encoderFactory,
                                           decoderFactory: decoderFactory)
    }

    // MARK: - 对外接口：开始/停止/静音/发文本

    /// 开始实时语音通话
    func startCall() {
        // ✅ 避免并发重复点
        if isRunning || isConnecting {
            rtLog("startCall() 被忽略：已在运行或正在连接")
            return
        }

        // 刷新本次通话的 callId，用于废弃旧回调
        let callId = UUID()
        currentCallId = callId

        isConnecting = true
        DispatchQueue.main.async {
            self.delegate?.realtimeService(self, didUpdateStatus: "连接中…")
        }
        rtLog("startCall()")

        // 1) 先请求录音权限（系统会弹窗，只有第一次会稍微慢一点）
        let audioSession = AVAudioSession.sharedInstance()
        audioSession.requestRecordPermission { [weak self] granted in
            guard let self = self else { return }

            // 如果在等待权限时用户已经点了“结束”，直接丢弃
            if callId != self.currentCallId {
                rtLog("startCall() 权限回调已过期，忽略")
                return
            }

            DispatchQueue.main.async {
                if !granted {
                    self.isConnecting = false
                    self.isRunning = false
                    let err = NSError(domain: "RealtimeQuickService", code: -10, userInfo: [
                        NSLocalizedDescriptionKey: "麦克风未授权"
                    ])
                    rtLog("❌ 麦克风未授权")
                    self.delegate?.realtimeService(self, didUpdateStatus: "麦克风未授权")
                    self.delegate?.realtimeService(self, didFailWith: err)
                    return
                }

                // 2) 配置音频路由（走电话通道 + 外放）
                do {
                    try self.configureAudioSession()
                } catch {
                    self.isConnecting = false
                    self.isRunning = false
                    rtLog("❌ AudioSession 配置失败: \(error)")
                    self.delegate?.realtimeService(self, didUpdateStatus: "音频配置失败")
                    self.delegate?.realtimeService(self, didFailWith: error)
                    return
                }

                // 3) 调后端 /session + WebRTC 协商（放到后台队列）
                self.workQueue.async {
                    self.openSessionAndConnect(callId: callId)
                }
            }
        }
    }

    /// 挂断（强制清理）
    func stopCall() {
        rtLog("stopCall()")

        // 让后续所有异步回调失效
        currentCallId = UUID()

        isConnecting = false
        isRunning = false

        stopPing()

        // DataChannel / PeerConnection
        dataChannel?.close()
        dataChannel?.delegate = nil
        dataChannel = nil

        peerConnection?.close()
        peerConnection?.delegate = nil
        peerConnection = nil

        remoteAudioTrackBound = false
        localAudioTrack = nil

        // 清理状态
        rtcURL = nil
        ephemeralKey = nil
        iceServers = []
        conversation.removeAll()
        transcriptBuffer = ""

        // 关闭 WebRTC 音频
        let rtcSession = RTCAudioSession.sharedInstance()
        rtcSession.lockForConfiguration()
        rtcSession.isAudioEnabled = false
        rtcSession.unlockForConfiguration()

        DispatchQueue.main.async {
            self.delegate?.realtimeServiceDidDisconnect(self)
            self.delegate?.realtimeService(self, didUpdateStatus: "已挂断")
        }
    }

    /// 静音切换
    func toggleMute() {
        guard let audioTrack = localAudioTrack else { return }
        isMuted.toggle()
        audioTrack.isEnabled = !isMuted
        DispatchQueue.main.async {
            self.delegate?.realtimeService(self,
                                           didUpdateStatus: self.isMuted ? "已静音" : "麦克风开启")
        }
    }

    /// 主动发文本
    func sendText(_ text: String, speak: Bool = true) {
        guard let dc = dataChannel else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return }

        conversation.append(["role": "user", "text": t])

        let msg1: [String: Any] = [
            "type": "input_text",
            "text": t
        ]
        let msg2: [String: Any] = [
            "type": "response.create",
            "response": [
                "modalities": speak ? ["audio", "text"] : ["text"],
                "audio": ["voice": kRealtimeDefaultVoice]
            ]
        ]
        do {
            let d1 = try JSONSerialization.data(withJSONObject: msg1, options: [])
            let d2 = try JSONSerialization.data(withJSONObject: msg2, options: [])
            dc.sendData(RTCDataBuffer(data: d1, isBinary: false))
            dc.sendData(RTCDataBuffer(data: d2, isBinary: false))
        } catch {
            rtLog("sendText JSON error: \(error)")
        }
    }

    // MARK: - session.update（开启 audio+text + server_vad）

    private func sendSessionUpdate() {
        guard let dc = dataChannel else { return }

        let msg: [String: Any] = [
            "type": "session.update",
            "session": [
                "modalities": ["audio", "text"],
                "voice": kRealtimeDefaultVoice,
                "turn_detection": [
                    "type": "server_vad",
                    "silence_duration_ms": 350,
                    "prefix_padding_ms": 150
                ],
                "instructions": "你是阿杜的语音助手，用自然口语、简短句子回答，适合直接播报。"
            ]
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: msg, options: [])
            let buffer = RTCDataBuffer(data: data, isBinary: false)
            dc.sendData(buffer)
            rtLog("session.update sent")
        } catch {
            rtLog("session.update JSON error: \(error)")
        }
    }

    // MARK: - 音频路由

        private func configureAudioSession() throws {
            // 确保在主线程配置 AudioSession
            if !Thread.isMainThread {
                var thrown: Error?
                DispatchQueue.main.sync {
                    do {
                        try self.configureAudioSession()
                    } catch {
                        thrown = error
                    }
                }
                if let e = thrown { throw e }
                return
            }

            let rtcSession = RTCAudioSession.sharedInstance()
            rtcSession.lockForConfiguration()
            defer { rtcSession.unlockForConfiguration() }

            try rtcSession.setCategory(
                AVAudioSession.Category.playAndRecord.rawValue,
                with: [.defaultToSpeaker, .allowBluetooth]   // 想简单可以改成 [.defaultToSpeaker]
            )
            try rtcSession.setMode(AVAudioSession.Mode.voiceChat.rawValue)
            try rtcSession.setActive(true)

            rtcSession.isAudioEnabled = true
            rtcSession.useManualAudio = false

            rtLog("AudioSession configured: playAndRecord + voiceChat + defaultToSpeaker")
        }

        // MARK: - /session 调用

        private struct SessionInfo {
            let rtcURL: URL
            let ephemeralKey: String
            let iceServers: [RTCIceServer]
        }

        private func fetchSessionFromBackend(
            completion: @escaping (Result<SessionInfo, Error>) -> Void
        ) {
            var request = URLRequest(url: Backend.sessionURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let payload: [String: Any] = [
                "want_video": false
            ]

            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
            } catch {
                completion(.failure(error))
                return
            }

            URLSession.shared.dataTask(with: request) { data, response, error in
                if let e = error {
                    completion(.failure(e))
                    return
                }
                guard let http = response as? HTTPURLResponse,
                      http.statusCode == 200,
                      let data = data else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    let err = NSError(domain: "RealtimeQuickService", code: code, userInfo: [
                        NSLocalizedDescriptionKey: "后端 /session 返回错误：\(code)"
                    ])
                    completion(.failure(err))
                    return
                }

                do {
                    let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] ?? [:]
                    guard let urlStr = json["rtc_url"] as? String,
                          let url = URL(string: urlStr) else {
                        throw NSError(domain: "RealtimeQuickService", code: -1, userInfo: [
                            NSLocalizedDescriptionKey: "缺少 rtc_url"
                        ])
                    }

                    let key = (json["ephemeral_key"] as? String)
                        ?? ((json["client_secret"] as? [String: Any])?["value"] as? String)

                    guard let ephemeral = key else {
                        throw NSError(domain: "RealtimeQuickService", code: -1, userInfo: [
                            NSLocalizedDescriptionKey: "缺少 ephemeral_key"
                        ])
                    }

                    // ICE
                    let rawIce = (json["ice_servers"] as? [[String: Any]]) ?? []
                    let iceServers: [RTCIceServer]
                    if rawIce.isEmpty {
                        iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
                    } else {
                        iceServers = rawIce.compactMap { dict in
                            guard let urls = dict["urls"] else { return nil }
                            if let str = urls as? String {
                                return RTCIceServer(
                                    urlStrings: [str],
                                    username: dict["username"] as? String,
                                    credential: dict["credential"] as? String
                                )
                            } else if let arr = urls as? [String] {
                                return RTCIceServer(
                                    urlStrings: arr,
                                    username: dict["username"] as? String,
                                    credential: dict["credential"] as? String
                                )
                            }
                            return nil
                        }
                    }

                    rtLog("session ok, rtc_url=\(urlStr)")
                    completion(.success(SessionInfo(rtcURL: url,
                                                    ephemeralKey: ephemeral,
                                                    iceServers: iceServers)))
                } catch {
                    completion(.failure(error))
                }
            }.resume()
        }

        // MARK: - /session + WebRTC 综合流程

        private func openSessionAndConnect(callId: UUID) {
            fetchSessionFromBackend { result in

                // 如果期间 stopCall() 了，这次结果直接丢弃
                guard callId == self.currentCallId else {
                    rtLog("/session 回调已过期，忽略")
                    return
                }

                switch result {
                case .failure(let err):
                    DispatchQueue.main.async {
                        self.isConnecting = false
                        self.isRunning = false
                        self.delegate?.realtimeService(self, didUpdateStatus: "获取会话失败")
                        self.delegate?.realtimeService(self, didFailWith: err)
                    }

                case .success(let info):
                    self.rtcURL = info.rtcURL
                    self.ephemeralKey = info.ephemeralKey
                    self.iceServers = info.iceServers

                    do {
                        try self.setupPeerConnection()
                    } catch {
                        DispatchQueue.main.async {
                            self.isConnecting = false
                            self.isRunning = false
                            self.delegate?.realtimeService(self, didUpdateStatus: "建立连接失败")
                            self.delegate?.realtimeService(self, didFailWith: error)
                        }
                        return
                    }

                    self.negotiate { error in
                        // 如果协商结果回来时 callId 已变，说明用户已挂断
                        guard callId == self.currentCallId else {
                            rtLog("negotiate 回调已过期，忽略结果")
                            return
                        }

                        DispatchQueue.main.async {
                            if let e = error {
                                self.isConnecting = false
                                self.isRunning = false
                                self.delegate?.realtimeService(self, didUpdateStatus: "协商失败")
                                self.delegate?.realtimeService(self, didFailWith: e)
                            } else {
                                self.isConnecting = false
                                self.isRunning = true
                                self.conversation.removeAll()
                                self.startPing()
                                self.delegate?.realtimeServiceDidConnect(self)
                                self.delegate?.realtimeService(self, didUpdateStatus: "已连接")
                            }
                        }
                    }
                }
            }
        }

    // MARK: - PeerConnection / DataChannel

        private func setupPeerConnection() throws {
            guard let factory = factory else {
                throw NSError(domain: "RealtimeQuickService", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "RTCPeerConnectionFactory 未初始化"
                ])
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

            let pc = factory.peerConnection(
                with: config,
                constraints: constraints,
                delegate: self
            )
            self.peerConnection = pc

            // 本地音频 track
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

            // Unified Plan：addTrack
            pc.add(audioTrack, streamIds: ["local_stream"])

            // DataChannel
            let dcConfig = RTCDataChannelConfiguration()
            dcConfig.isOrdered = true
            let dc = pc.dataChannel(forLabel: "oai-events", configuration: dcConfig)
            dc?.delegate = self
            self.dataChannel = dc

            rtLog("PeerConnection + local audio track ready")
        }

        /// SDP 协商：Offer -> POST rtc_url -> Answer
        private func negotiate(completion: @escaping (Error?) -> Void) {
            guard let pc = peerConnection,
                  let rtcURL = rtcURL,
                  let key = ephemeralKey else {
                completion(NSError(domain: "RealtimeQuickService", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "缺少 rtcURL / ephemeralKey / peerConnection"
                ]))
                return
            }

            let constraints = RTCMediaConstraints(
                mandatoryConstraints: [
                    "OfferToReceiveAudio": "true",
                    "OfferToReceiveVideo": "false"
                ],
                optionalConstraints: [
                    "voiceActivityDetection": "true"
                ])

            pc.offer(for: constraints) { [weak self] sdp, error in
                guard let self = self else { return }
                if let e = error {
                    completion(e)
                    return
                }
                guard let offer = sdp else {
                    completion(NSError(domain: "RealtimeQuickService", code: -1, userInfo: [
                        NSLocalizedDescriptionKey: "createOffer 返回空"
                    ]))
                    return
                }

                pc.setLocalDescription(offer) { error in
                    if let e = error {
                        completion(e)
                        return
                    }

                    self.workQueue.asyncAfter(deadline: .now() + 0.3) {
                        let sdpStr = pc.localDescription?.sdp ?? offer.sdp

                        var request = URLRequest(url: rtcURL)
                        request.httpMethod = "POST"
                        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
                        request.setValue("application/sdp", forHTTPHeaderField: "Accept")
                        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
                        request.httpBody = sdpStr.data(using: .utf8)

                        URLSession.shared.dataTask(with: request) { data, response, error in
                            if let e = error {
                                completion(e)
                                return
                            }
                            guard let http = response as? HTTPURLResponse,
                                  (200..<300).contains(http.statusCode),
                                  let data = data,
                                  let answerSDP = String(data: data, encoding: .utf8) else {
                                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                                completion(NSError(domain: "RealtimeQuickService", code: code, userInfo: [
                                    NSLocalizedDescriptionKey: "SDP 交换失败：\(code) \(body)"
                                ]))
                                return
                            }

                            let answer = RTCSessionDescription(type: .answer, sdp: answerSDP)
                            pc.setRemoteDescription(answer) { error in
                                completion(error)
                            }
                        }.resume()
                    }
                }
            }
        }

        // MARK: - keepalive 心跳

        private func startPing() {
            DispatchQueue.main.async {
                self.pingTimer?.invalidate()
                self.pingTimer = Timer.scheduledTimer(withTimeInterval: 15.0,
                                                      repeats: true) { [weak self] _ in
                    guard let self = self,
                          let dc = self.dataChannel,
                          dc.readyState == .open else { return }

                    let payload: [String: Any] = [
                        "type": "client.keepalive",
                        "ts": Int(Date().timeIntervalSince1970 * 1000)
                    ]
                    if let data = try? JSONSerialization.data(withJSONObject: payload, options: []) {
                        dc.sendData(RTCDataBuffer(data: data, isBinary: false))
                    }
                }
            }
        }

        private func stopPing() {
            DispatchQueue.main.async {
                self.pingTimer?.invalidate()
                self.pingTimer = nil
            }
        }

        // MARK: - Sora Hook（暂时只打 log）

        private func maybeTriggerSora(with assistantText: String) {
            let lower = assistantText.lowercased()
            let trigger = lower.contains("生成视频") ||
                          lower.contains("make video") ||
                          lower.contains("sora")

            guard trigger else { return }

            let lastUser = conversation
                .reversed()
                .first(where: { $0["role"] == "user" })?["text"] ?? ""
            guard !lastUser.isEmpty else { return }

            rtLog("🎬 (Hook) 触发视频生成: \(lastUser)")
            // TODO: 将来接 SoraVideoService 调 /video
        }
    }

    // MARK: - WebRTC Delegate 实现

    extension RealtimeQuickService: RTCPeerConnectionDelegate, RTCDataChannelDelegate {

        // MARK: - RTCPeerConnectionDelegate（最小实现）

        func peerConnection(_ peerConnection: RTCPeerConnection,
                            didChange stateChanged: RTCSignalingState) {
            rtLog("signaling state = \(stateChanged.rawValue)")
        }

        func peerConnection(_ peerConnection: RTCPeerConnection,
                            didOpen dataChannel: RTCDataChannel) {
            rtLog("didOpen dataChannel: \(dataChannel.label)")
            // 确保用同一个 dataChannel
            self.dataChannel = dataChannel
            dataChannel.delegate = self

            // 通道一打开就发 session.update
            sendSessionUpdate()
        }

        func peerConnection(_ peerConnection: RTCPeerConnection,
                            didChange newState: RTCIceConnectionState) {
            rtLog("ICE state = \(newState.rawValue)")

            if newState == .failed || newState == .disconnected {
                // 网络断开，直接强制挂断，避免残留心跳/状态
                DispatchQueue.main.async {
                    self.stopCall()
                    self.delegate?.realtimeService(self,
                                                   didUpdateStatus: "网络中断")
                }
            }
        }

        func peerConnection(_ peerConnection: RTCPeerConnection,
                            didChange newState: RTCIceGatheringState) {
            rtLog("ICE gathering = \(newState.rawValue)")
        }

        func peerConnection(_ peerConnection: RTCPeerConnection,
                            didGenerate candidate: RTCIceCandidate) {
            rtLog("didGenerate candidate: \(candidate.sdp)")
        }

        func peerConnection(_ peerConnection: RTCPeerConnection,
                            didRemove candidates: [RTCIceCandidate]) {
            rtLog("didRemove candidates: \(candidates.count)")
        }

        func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
            rtLog("peerConnectionShouldNegotiate()")
        }

        func peerConnection(_ peerConnection: RTCPeerConnection,
                            didAdd stream: RTCMediaStream) {
            rtLog("didAdd stream: \(stream.streamId)")
            if !remoteAudioTrackBound,
               let audioTrack = stream.audioTracks.first {
                remoteAudioTrackBound = true
                rtLog("remote audio track bound: \(audioTrack.trackId)")
                // 音频会通过 RTCAudioSession 自动播放
            }
        }

        func peerConnection(_ peerConnection: RTCPeerConnection,
                            didRemove stream: RTCMediaStream) {
            rtLog("didRemove stream: \(stream.streamId)")
        }

        func peerConnection(_ peerConnection: RTCPeerConnection,
                            didAdd rtpReceiver: RTCRtpReceiver,
                            streams: [RTCMediaStream]) {
            rtLog("didAdd rtpReceiver: \(rtpReceiver.track?.trackId ?? "nil")")
            if !remoteAudioTrackBound,
               let track = rtpReceiver.track as? RTCAudioTrack {
                remoteAudioTrackBound = true
                rtLog("remote audio track (RTP) bound: \(track.trackId)")
            }
        }

        func peerConnection(_ peerConnection: RTCPeerConnection,
                            didRemove rtpReceiver: RTCRtpReceiver) {
            rtLog("didRemove rtpReceiver: \(rtpReceiver.track?.trackId ?? "nil")")
        }

        // MARK: - RTCDataChannelDelegate

        func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
            rtLog("DataChannel state = \(dataChannel.readyState.rawValue)")
            if dataChannel.readyState == .open {
                // 通道打开后立刻配置 session：audio+text + server_vad
                sendSessionUpdate()
            }
        }

        func dataChannel(_ dataChannel: RTCDataChannel,
                         didReceiveMessageWith buffer: RTCDataBuffer) {
            // 只关心文本事件
            guard !buffer.isBinary else {
                rtLog("收到二进制 DataChannel 消息，忽略")
                return
            }
            guard let text = String(data: buffer.data, encoding: .utf8) else {
                rtLog("DataChannel 文本解码失败")
                return
            }
            rtLog("DataChannel recv: \(text)")

            guard let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else {
                return
            }

            switch type {
            // 模型回答的增量文本（可选）
            case "response.output_text.delta":
                if kRealtimeTextToUIEnabled_iOS,
                   let delta = json["delta"] as? String, !delta.isEmpty {
                    transcriptBuffer += delta
                    DispatchQueue.main.async {
                        self.delegate?.realtimeService(self,
                                                       didUpdateTranscript: self.transcriptBuffer)
                    }
                }

            // 模型回答完成
            case "response.output_text.done":
                if let full = json["text"] as? String, !full.isEmpty {
                    transcriptBuffer = full
                    DispatchQueue.main.async {
                        self.delegate?.realtimeService(self,
                                                       didUpdateTranscript: full)
                    }
                    maybeTriggerSora(with: full)
                    transcriptBuffer = ""
                }

            // 用户语音转写完成
            case "conversation.item.input_audio_transcription.completed":
                if let userText = json["transcript"] as? String, !userText.isEmpty {
                    conversation.append(["role": "user", "text": userText])
                    if kRealtimeTextToUIEnabled_iOS {
                        DispatchQueue.main.async {
                            self.delegate?.realtimeService(self,
                                                           didUpdateTranscript: userText)
                        }
                    }
                }

            // 错误
            case "error":
                let msg = (json["error"] as? [String: Any])?["message"] as? String
                    ?? (json["message"] as? String)
                    ?? "Realtime error"
                let err = NSError(domain: "RealtimeQuickService",
                                  code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: msg])
                DispatchQueue.main.async {
                    self.delegate?.realtimeService(self, didFailWith: err)
                    self.delegate?.realtimeService(self,
                                                   didUpdateStatus: "会话错误")
                }

            default:
                break
            }
        }
    }
