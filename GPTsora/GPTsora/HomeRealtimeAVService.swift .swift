// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-9ca332c661c7ddb9a2e91a4d56abee7997d017f5e19efb306b2add330039cd3b"
// Source-SHA256: "fe09f2fd608d61b146634c6cec72b1ac3bf5b1ba0781250614a60230bf65b7db"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation
import AVFoundation
import WebRTC

// =======================================================
// HomeRealtimeAVService.swift
//
// ✅ 家居专用 Realtime 引擎（独立于通用 RealtimeAVService）
// - 会话：POST {apiBase}/home/session （后端必须返回 rtc_url + ephemeral_key + ice_servers）
// - DataChannel open 后：发送 session.update，但【不发送 instructions】
//   这样不会覆盖后端注入的 home-only instructions
// - 只做：音频通话 + 事件解析（用户转写 + 助手文本 delta/final）
//
// 你只需要在 Home 页面：
//   HomeRealtimeAVService.shared.apiBase = vm.config.apiBase
//   HomeRealtimeAVService.shared.clientId = vm.config.clientId
//   HomeRealtimeAVService.shared.start()
//
// =======================================================

final class HomeRealtimeAVService: NSObject {

    static let shared = HomeRealtimeAVService()

    weak var delegate: RealtimeAVServiceDelegate?

    // Backend
    var apiBase: String = "http://YOUR_LAN_IP:8000"

    // 必须与 /home/gateway_profile 绑定一致（非常关键）
    var clientId: String = ""

    // voice（仅影响 session.update 的 voice；后端如果已在 session 创建时指定 voice，这里也不会覆盖 instructions）
    var voiceName: String = "coral"

    // workQueue
    private let workQueue = DispatchQueue(label: "home.realtime.av.service.queue", qos: .userInitiated)

    // State
    private(set) var isConnecting: Bool = false
    private(set) var isRunning: Bool = false
    private(set) var isMuted: Bool = false

    // /home/session
    private struct SessionInfo {
        let rtcURL: URL
        let ephemeralKey: String
        let iceServers: [RTCIceServer]
    }

    private var pendingSessionInfo: SessionInfo?
    private var pendingAudioReady: Bool = false
    private var currentCallId = UUID()

    // WebRTC
    private var factory: RTCPeerConnectionFactory!
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private var localAudioTrack: RTCAudioTrack?

    private var hasSentSessionUpdate = false
    private var assistantBuffer: String = ""

    private override init() {
        super.init()
        RTCPeerConnectionFactory.initialize()
        factory = RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }

    // MARK: - Public API

    func start() {
        workQueue.async { [weak self] in
            self?.startInternal()
        }
    }

    func stop() {
        workQueue.async { [weak self] in
            self?.hardReset(notify: true)
        }
    }

    func setMuted(_ muted: Bool) {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.isMuted = muted
            self.localAudioTrack?.isEnabled = !muted
            DispatchQueue.main.async {
                self.delegate?.realtimeAVService(self, didUpdateStatus: muted ? "已静音" : "麦克风开启")
            }
        }
    }

    func toggleMute() {
        setMuted(!isMuted)
    }

    // MARK: - Internal start

    private func startInternal() {
        hardReset(notify: false)

        isConnecting = true
        isRunning = false
        isMuted = false
        hasSentSessionUpdate = false
        assistantBuffer = ""

        pendingSessionInfo = nil
        pendingAudioReady = false

        let callId = UUID()
        currentCallId = callId

        DispatchQueue.main.async {
            self.delegate?.realtimeAVService(self, didUpdateStatus: "家居通话连接中…")
        }

        // 1) 拉 /home/session（后端注入 home-only instructions）
        fetchHomeSessionFromBackend { [weak self] result in
            guard let self else { return }
            self.workQueue.async {
                guard callId == self.currentCallId else { return }
                switch result {
                case .success(let info):
                    self.pendingSessionInfo = info
                    self.maybeConnectIfReady(callId: callId)
                case .failure(let err):
                    self.failAndReset(callId: callId, status: "获取家居会话失败", error: err)
                }
            }
        }

        // 2) 音频预热
        DispatchQueue.main.async { [weak self] in
            self?.preflightAudio(callId: callId)
        }
    }

    // MARK: - Audio

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
                        let err = NSError(domain: "HomeRealtimeAVService", code: -10,
                                          userInfo: [NSLocalizedDescriptionKey: "麦克风未授权"])
                        self.workQueue.async { [weak self] in
                            self?.failAndReset(callId: callId, status: "麦克风未授权", error: err)
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
            let err = NSError(domain: "HomeRealtimeAVService", code: -10,
                              userInfo: [NSLocalizedDescriptionKey: "麦克风未授权"])
            workQueue.async { [weak self] in
                self?.failAndReset(callId: callId, status: "麦克风未授权", error: err)
            }

        @unknown default:
            let err = NSError(domain: "HomeRealtimeAVService", code: -11,
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

        let options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetooth]
        try rtc.setCategory(AVAudioSession.Category.playAndRecord.rawValue, with: options)
        try rtc.setMode(AVAudioSession.Mode.voiceChat.rawValue)
        try rtc.setActive(true)
        rtc.isAudioEnabled = true
        rtc.useManualAudio = false

        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
    }

    private func maybeConnectIfReady(callId: UUID) {
        guard callId == currentCallId else { return }
        guard pendingAudioReady else { return }
        guard let info = pendingSessionInfo else { return }

        pendingSessionInfo = nil

        do {
            try setupPeerConnection(iceServers: info.iceServers)
        } catch {
            failAndReset(callId: callId, status: "建立连接失败", error: error)
            return
        }

        negotiate(callId: callId, rtcURL: info.rtcURL, ephemeralKey: info.ephemeralKey) { [weak self] error in
            guard let self else { return }
            self.workQueue.async {
                guard callId == self.currentCallId else { return }

                if let error {
                    self.failAndReset(callId: callId, status: "协商失败", error: error)
                    return
                }

                self.isConnecting = false
                self.isRunning = true

                DispatchQueue.main.async {
                    self.delegate?.realtimeAVServiceDidConnect(self)
                    self.delegate?.realtimeAVService(self, didUpdateStatus: "家居通话已连接")
                }
            }
        }
    }

    // MARK: - Reset

    private func hardReset(notify: Bool) {
        currentCallId = UUID()

        isConnecting = false
        isRunning = false
        isMuted = false
        hasSentSessionUpdate = false
        assistantBuffer = ""

        pendingSessionInfo = nil
        pendingAudioReady = false

        dataChannel?.delegate = nil
        dataChannel?.close()
        dataChannel = nil

        peerConnection?.delegate = nil
        peerConnection?.close()
        peerConnection = nil

        localAudioTrack = nil

        let rtc = RTCAudioSession.sharedInstance()
        rtc.lockForConfiguration()
        rtc.isAudioEnabled = false
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
        DispatchQueue.main.async {
            self.delegate?.realtimeAVService(self, didUpdateStatus: status)
            self.delegate?.realtimeAVService(self, didFail: error)
        }
    }
}

// MARK: - /home/session

extension HomeRealtimeAVService {

    private func normalizedApiBase(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return s }
        let lower = s.lowercased()
        if !(lower.hasPrefix("http://") || lower.hasPrefix("https://")) {
            s = "http://" + s
        }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private var homeSessionURL: URL {
        let base = normalizedApiBase(apiBase)
        return URL(string: base + "/home/session")!
    }

    private func fetchHomeSessionFromBackend(
        completion: @escaping (Result<SessionInfo, Error>) -> Void
    ) {
        var req = URLRequest(url: homeSessionURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        req.cachePolicy = .reloadIgnoringLocalCacheData

        // ✅ 这里传 client_id，后端据此找绑定并注入 home-only instructions
        let cid = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload: [String: Any] = [
            "client_id": cid,
            "profile": "home",
            "want_video": false
        ]

        if !cid.isEmpty {
            req.setValue(cid, forHTTPHeaderField: "X-Client-ID")
        }

        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            completion(.failure(error))
            return
        }

        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err { completion(.failure(err)); return }
            guard let http = resp as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let data else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                completion(.failure(NSError(
                    domain: "HomeRealtimeAVService",
                    code: code,
                    userInfo: [NSLocalizedDescriptionKey: "后端 /home/session 返回错误：\(code)"]
                )))
                return
            }

            do {
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard let dict = json else {
                    throw NSError(domain: "HomeRealtimeAVService", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "无法解析 /home/session JSON"])
                }

                guard let urlStr = dict["rtc_url"] as? String,
                      let url = URL(string: urlStr) else {
                    throw NSError(domain: "HomeRealtimeAVService", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "缺少 rtc_url"])
                }

                let key = (dict["ephemeral_key"] as? String)
                ?? ((dict["client_secret"] as? [String: Any])?["value"] as? String)

                guard let ephemeral = key else {
                    throw NSError(domain: "HomeRealtimeAVService", code: -1,
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

                completion(.success(SessionInfo(rtcURL: url, ephemeralKey: ephemeral, iceServers: iceServers)))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }
}

// MARK: - WebRTC + DataChannel

extension HomeRealtimeAVService: RTCPeerConnectionDelegate, RTCDataChannelDelegate {

    private func setupPeerConnection(iceServers: [RTCIceServer]) throws {
        guard let factory else {
            throw NSError(domain: "HomeRealtimeAVService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "RTCPeerConnectionFactory 未初始化"])
        }

        let config = RTCConfiguration()
        config.iceServers = iceServers
        config.sdpSemantics = .unifiedPlan
        config.iceCandidatePoolSize = 1

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "true",
                                   "OfferToReceiveVideo": "false"],
            optionalConstraints: nil
        )

        let pc = factory.peerConnection(with: config, constraints: constraints, delegate: self)
        peerConnection = pc

        let audioSource = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let track = factory.audioTrack(with: audioSource, trackId: "home_local_audio")
        track.isEnabled = true
        localAudioTrack = track
        pc.add(track, streamIds: ["home_local_stream"])

        let dcConfig = RTCDataChannelConfiguration()
        dcConfig.isOrdered = true
        let dc = pc.dataChannel(forLabel: "oai-events", configuration: dcConfig)
        dc?.delegate = self
        dataChannel = dc
    }

    private func negotiate(callId: UUID, rtcURL: URL, ephemeralKey: String, completion: @escaping (Error?) -> Void) {
        guard let pc = peerConnection else {
            completion(NSError(domain: "HomeRealtimeAVService", code: -1,
                               userInfo: [NSLocalizedDescriptionKey: "peerConnection 缺失"]))
            return
        }

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "true",
                                   "OfferToReceiveVideo": "false"],
            optionalConstraints: ["voiceActivityDetection": "true"]
        )

        pc.offer(for: constraints) { [weak self] sdp, err in
            guard let self else { return }
            self.workQueue.async {
                guard callId == self.currentCallId else { return }
                if let err { completion(err); return }
                guard let offer = sdp else {
                    completion(NSError(domain: "HomeRealtimeAVService", code: -1,
                                       userInfo: [NSLocalizedDescriptionKey: "createOffer 返回空"]))
                    return
                }

                pc.setLocalDescription(offer) { [weak self] err in
                    guard let self else { return }
                    self.workQueue.async {
                        guard callId == self.currentCallId else { return }
                        if let err { completion(err); return }

                        let sdpStr = pc.localDescription?.sdp ?? offer.sdp

                        var req = URLRequest(url: rtcURL)
                        req.httpMethod = "POST"
                        req.timeoutInterval = 20
                        req.setValue("Bearer \(ephemeralKey)", forHTTPHeaderField: "Authorization")
                        req.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
                        req.setValue("application/sdp", forHTTPHeaderField: "Accept")
                        req.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
                        req.httpBody = sdpStr.data(using: .utf8)

                        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
                            guard let self else { return }
                            self.workQueue.async {
                                guard callId == self.currentCallId else { return }
                                if let err { completion(err); return }

                                guard let http = resp as? HTTPURLResponse,
                                      (200..<300).contains(http.statusCode),
                                      let data,
                                      let answerSDP = String(data: data, encoding: .utf8) else {
                                    let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                                    let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                                    completion(NSError(domain: "HomeRealtimeAVService", code: code,
                                                       userInfo: [NSLocalizedDescriptionKey: "SDP 交换失败：\(code) \(body)"]))
                                    return
                                }

                                let answer = RTCSessionDescription(type: .answer, sdp: answerSDP)
                                pc.setRemoteDescription(answer) { err in
                                    self.workQueue.async {
                                        guard callId == self.currentCallId else { return }
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

    // DataChannel state
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        workQueue.async { [weak self] in
            guard let self else { return }
            if dataChannel.readyState == .open {
                self.sendHomeSessionUpdateOnce()
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

    // ✅ 关键：不发送 instructions，避免覆盖后端注入的 home-only instructions
    private func sendHomeSessionUpdateOnce() {
        guard !hasSentSessionUpdate else { return }
        hasSentSessionUpdate = true

        let turnDetection: [String: Any] = [
            "type": "server_vad",
            "silence_duration_ms": 220,
            "prefix_padding_ms": 120,
            "create_response": true,      // 家居模块建议让 server 自动出回复（更稳）
            "interrupt_response": true
        ]

        let sessionDict: [String: Any] = [
            "modalities": ["audio", "text"],
            "voice": voiceName,
            "turn_detection": turnDetection
            // ✅ 不传 instructions
        ]

        sendClientEvent([
            "type": "session.update",
            "session": sessionDict
        ])
    }

    private func sendClientEvent(_ event: [String: Any]) {
        guard let dc = dataChannel, dc.readyState == .open else { return }
        if let data = try? JSONSerialization.data(withJSONObject: event, options: []) {
            dc.sendData(RTCDataBuffer(data: data, isBinary: false))
        }
    }

    // Minimal PC delegate
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if newState == .failed || newState == .disconnected {
            workQueue.async { [weak self] in
                guard let self else { return }
                if self.isRunning || self.isConnecting {
                    self.hardReset(notify: true)
                    DispatchQueue.main.async {
                        self.delegate?.realtimeAVService(self, didUpdateStatus: "网络不稳定，已断开")
                    }
                }
            }
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.dataChannel = dataChannel
            dataChannel.delegate = self
            self.sendHomeSessionUpdateOnce()
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove rtpReceiver: RTCRtpReceiver) {}
}

// MARK: - Server event parsing（只做你需要的：用户转写 + 助手文本）

extension HomeRealtimeAVService {

    private func handleServerEvent(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }

        let type = (json["type"] as? String) ?? ""

        switch type {

        case "conversation.item.input_audio_transcription.completed":
            if let user = Self.extractUserTranscript(from: json), !user.isEmpty {
                DispatchQueue.main.async {
                    self.delegate?.realtimeAVService(self, didReceiveUserTranscript: user)
                }
            }

        case "response.output_text.delta":
            if let d = Self.extractAssistantDelta(from: json), !d.isEmpty {
                assistantBuffer.append(d)
                DispatchQueue.main.async {
                    self.delegate?.realtimeAVService(self, didReceiveAssistantText: self.assistantBuffer, isFinal: false)
                }
            }

        case "response.output_text.done":
            // 可能仅文本完成，不一定表示整轮结束；先不清空

            break

        case "response.done", "response.completed":
            let final = assistantBuffer
            assistantBuffer = ""
            if !final.isEmpty {
                DispatchQueue.main.async {
                    self.delegate?.realtimeAVService(self, didReceiveAssistantText: final, isFinal: true)
                }
            }

        case "error":
            let msg =
            (json["error"] as? [String: Any])?["message"] as? String
            ?? (json["message"] as? String)
            ?? "Realtime error"

            DispatchQueue.main.async {
                self.delegate?.realtimeAVService(self, didFail: NSError(
                    domain: "HomeRealtimeAVService",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: msg]
                ))
            }

        default:
            break
        }
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
        return nil
    }
}
