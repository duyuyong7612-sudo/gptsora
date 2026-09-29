//
//  RealtimeCompanionService.swift
//  GPT Solara
//
//  通用語音陪聊專用（1號波紋鍵）：只做 Realtime 語音聊天，不觸發 Sora 視頻生成
//

// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-e30319e496b1373d52b69d6fe7a8fef243e988227fc41eaec94fccc77173f4d9"
// Source-SHA256: "56f03501c3d010a2348d12712459d32c31d3a11c40e948301755bca922d9d490"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation
import AVFoundation
import WebRTC

// MARK: - 後端配置

private enum CompanionBackend {
    static let apiBase = "http://YOUR_LAN_IP:8000"
    static let sessionPath = "/session"

    static var sessionURL: URL {
        guard let url = URL(string: apiBase + sessionPath) else {
            fatalError("❌ CompanionBackend.sessionURL 無效，請檢查 apiBase / sessionPath")
        }
        return url
    }
}

// MARK: - 小工具

fileprivate func rtCompanionLog(_ msg: String) {
    NSLog("[RT-iOS Companion] \(msg)")
}

private let kRealtimeCompanionVoice = "coral"
fileprivate let kRealtimeTextToUIEnabledCompanion = true

// MARK: - 協議：給 View / Controller 用（陪聊線專用）

protocol RealtimeCompanionServiceDelegate: AnyObject {
    func realtimeServiceDidConnect(_ svc: RealtimeCompanionService)
    func realtimeServiceDidDisconnect(_ svc: RealtimeCompanionService)
    func realtimeService(_ svc: RealtimeCompanionService, didUpdateStatus text: String)
    /// 文本增量 / 最終文本：用前綴 "[U]" / "[A]" 區分使用者與助手
    func realtimeService(_ svc: RealtimeCompanionService, didUpdateTranscript text: String)
    func realtimeService(_ svc: RealtimeCompanionService, didFailWith error: Error)
}

// MARK: - RealtimeCompanionService 核心（按 Flutter 舊版邏輯簡化）

final class RealtimeCompanionService: NSObject {

    static let shared = RealtimeCompanionService()

    weak var delegate: RealtimeCompanionServiceDelegate?

    // 後端 /session 返回
    private var rtcURL: URL?
    private var ephemeralKey: String?
    private var iceServers: [RTCIceServer] = []

    private struct SessionInfo {
        let rtcURL: URL
        let ephemeralKey: String
        let iceServers: [RTCIceServer]
    }

    // WebRTC 核心
    private var factory: RTCPeerConnectionFactory!
    private var peerConnection: RTCPeerConnection?
    private var localAudioTrack: RTCAudioTrack?
    private var remoteAudioTrackBound = false
    private var dataChannel: RTCDataChannel?

    // 狀態（供 Bridge / UI 查單次通話狀態）
    private(set) var isConnecting: Bool = false
    private(set) var isRunning: Bool = false
    private(set) var isMuted: Bool = false

    // 用來“廢棄”舊通話的 token（防止 stop 之後舊回調亂改狀態）
    private var currentCallId = UUID()

    // 文本增量緩衝 + 簡單會話
    private var transcriptBuffer: String = ""
    private var conversation: [[String: String]] = []

    // keepalive 心跳
    private var pingTimer: Timer?

    // ICE 延時斷線任務（簡單處理）
    private var iceReconnectWorkItem: DispatchWorkItem?

    // 後台工作隊列（網路 / WebRTC 協商都放這裡，避免阻塞主線程）
    private let workQueue = DispatchQueue(
        label: "rt.companion.service.queue",
        qos: .userInitiated
    )

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
        factory = RTCPeerConnectionFactory(
            encoderFactory: encoderFactory,
            decoderFactory: decoderFactory
        )
    }

    // MARK: - 對外接口：開始 / 停止 / 靜音 / 發文本

    /// 主入口：通用語音陪聊通話（1號波紋鍵控制）
    func startCall() {
        if isRunning {
            rtCompanionLog("startCall() 被忽略：已在運行")
            return
        }
        if isConnecting {
            rtCompanionLog("startCall() 被忽略：正在連接中")
            return
        }

        let callId = UUID()
        currentCallId = callId

        isConnecting = true
        DispatchQueue.main.async {
            self.delegate?.realtimeService(self, didUpdateStatus: "連接中…")
        }
        rtCompanionLog("startCall(): companion line")

        // 1) 先請求錄音權限
        let audioSession = AVAudioSession.sharedInstance()
        audioSession.requestRecordPermission { [weak self] granted in
            guard let self else { return }

            if callId != self.currentCallId {
                rtCompanionLog("startCall() 權限回調已過期，忽略")
                return
            }

            DispatchQueue.main.async {
                if !granted {
                    self.isConnecting = false
                    self.isRunning = false
                    let err = NSError(
                        domain: "RealtimeCompanionService",
                        code: -10,
                        userInfo: [NSLocalizedDescriptionKey: "麥克風未授權"]
                    )
                    rtCompanionLog("❌ 麥克風未授權")
                    self.delegate?.realtimeService(self, didUpdateStatus: "麥克風未授權")
                    self.delegate?.realtimeService(self, didFailWith: err)
                    return
                }

                // 2) 配置音頻路由（多媒體 + 外放揚聲器）
                do {
                    try self.configureAudioSession()
                } catch {
                    self.isConnecting = false
                    self.isRunning = false
                    rtCompanionLog("❌ AudioSession 配置失敗: \(error)")
                    self.delegate?.realtimeService(self, didUpdateStatus: "音頻配置失敗")
                    self.delegate?.realtimeService(self, didFailWith: error)
                    return
                }

                // 3) 調後端 /session + WebRTC 協商（放到後台隊列）
                self.workQueue.async {
                    self.openSessionAndConnect(callId: callId)
                }
            }
        }
    }

    /// 掛斷（強制清理）
    func stopCall() {
        rtCompanionLog("stopCall()")

        currentCallId = UUID()

        isConnecting = false
        isRunning = false
        isMuted = false

        // 停止心跳 & ICE 延時任務
        stopPing()
        iceReconnectWorkItem?.cancel()
        iceReconnectWorkItem = nil

        // DataChannel / PeerConnection
        dataChannel?.close()
        dataChannel?.delegate = nil
        dataChannel = nil

        peerConnection?.close()
        peerConnection?.delegate = nil
        peerConnection = nil

        remoteAudioTrackBound = false
        localAudioTrack = nil

        rtcURL = nil
        ephemeralKey = nil
        iceServers = []
        conversation.removeAll()
        transcriptBuffer = ""

        // 關閉 WebRTC 音頻
        let rtcSession = RTCAudioSession.sharedInstance()
        rtcSession.lockForConfiguration()
        rtcSession.isAudioEnabled = false
        rtcSession.unlockForConfiguration()

        DispatchQueue.main.async {
            self.delegate?.realtimeServiceDidDisconnect(self)
            self.delegate?.realtimeService(self, didUpdateStatus: "已掛斷")
        }
    }

    /// 靜音切換
    func toggleMute() {
        guard let audioTrack = localAudioTrack else { return }
        isMuted.toggle()
        audioTrack.isEnabled = !isMuted
        DispatchQueue.main.async {
            self.delegate?.realtimeService(
                self,
                didUpdateStatus: self.isMuted ? "已靜音" : "麥克風開啟"
            )
        }
    }

    /// 主動發文本（保留給未來“語音 + 文本”模式用）
    func sendText(_ text: String, speak: Bool = true) {
        guard let dc = dataChannel else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return }

        conversation.append(["role": "user", "text": t])
        markActivity()

        let msg1: [String: Any] = [
            "type": "input_text",
            "text": t
        ]
        let msg2: [String: Any] = [
            "type": "response.create",
            "response": [
                "modalities": speak ? ["audio", "text"] : ["text"],
                "audio": ["voice": kRealtimeCompanionVoice]
            ]
        ]
        do {
            let d1 = try JSONSerialization.data(withJSONObject: msg1, options: [])
            let d2 = try JSONSerialization.data(withJSONObject: msg2, options: [])
            dc.sendData(RTCDataBuffer(data: d1, isBinary: false))
            dc.sendData(RTCDataBuffer(data: d2, isBinary: false))
        } catch {
            rtCompanionLog("sendText JSON error: \(error)")
        }
    }
}
// MARK: - session.update（開啟 audio+text + server_vad）

extension RealtimeCompanionService {

    /// 不帶任何 instructions，完全交給 Realtime 預設行為
    private func sendSessionUpdate() {
        guard let dc = dataChannel else {
            rtCompanionLog("session.update skipped: dataChannel=nil")
            return
        }

        // 只告訴它：我要 audio+text、用哪條 voice、開 server_vad
        let msg: [String: Any] = [
            "type": "session.update",
            "session": [
                "modalities": ["audio", "text"],
                "voice": kRealtimeCompanionVoice,
                "turn_detection": [
                    "type": "server_vad",
                    "silence_duration_ms": 350,
                    "prefix_padding_ms": 150
                ]
                // ✅ 不再傳 instructions，完全用 OpenAI 的預設系統提示
            ]
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: msg, options: [])
            let buffer = RTCDataBuffer(data: data, isBinary: false)
            dc.sendData(buffer)
            rtCompanionLog("session.update sent (companion, no custom instructions)")
        } catch {
            rtCompanionLog("session.update JSON error: \(error)")
        }
    }

    // MARK: - 音頻路由（多媒體 + 揚聲器）

    private func configureAudioSession() throws {
        // 確保在主線程配置 AudioSession
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
            with: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers]
        )
        try rtcSession.setMode(AVAudioSession.Mode.default.rawValue)
        try rtcSession.setActive(true)

        rtcSession.isAudioEnabled = true
        rtcSession.useManualAudio = false

        // 再強制一次走手機外放揚聲器
        let sysSession = AVAudioSession.sharedInstance()
        try sysSession.overrideOutputAudioPort(.speaker)

        rtCompanionLog("AudioSession configured: playAndRecord + default + speaker (multimedia)")
    }

    // MARK: - 活動打點（目前只用於未來擴展）

    private func markActivity() {
        // 目前不做自動掛斷，只用來預留將來行為
    }
}
// MARK: - /session 調用

extension RealtimeCompanionService {

    private func fetchSessionFromBackend(
        completion: @escaping (Result<SessionInfo, Error>) -> Void
    ) {
        var request = URLRequest(url: CompanionBackend.sessionURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "want_video": false,
            "mode": "companion"   // 告訴後端：這是語音陪聊線（可選）
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
                let err = NSError(
                    domain: "RealtimeCompanionService",
                    code: code,
                    userInfo: [NSLocalizedDescriptionKey: "後端 /session 返回錯誤：\(code)"]
                )
                completion(.failure(err))
                return
            }

            do {
                let json = try JSONSerialization.jsonObject(with: data, options: [])
                guard let dict = json as? [String: Any] else {
                    throw NSError(
                        domain: "RealtimeCompanionService",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "無法解析 /session JSON"]
                    )
                }

                guard let urlStr = dict["rtc_url"] as? String,
                      let url = URL(string: urlStr) else {
                    throw NSError(
                        domain: "RealtimeCompanionService",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "缺少 rtc_url"]
                    )
                }

                let key = (dict["ephemeral_key"] as? String)
                ?? ((dict["client_secret"] as? [String: Any])?["value"] as? String)

                guard let ephemeral = key else {
                    throw NSError(
                        domain: "RealtimeCompanionService",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "缺少 ephemeral_key"]
                    )
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

                rtCompanionLog("session ok, rtc_url=\(urlStr)")
                completion(.success(SessionInfo(
                    rtcURL: url,
                    ephemeralKey: ephemeral,
                    iceServers: iceServers
                )))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }
}

// MARK: - /session + WebRTC 綜合流程

extension RealtimeCompanionService {

    private func openSessionAndConnect(callId: UUID) {

        fetchSessionFromBackend { [weak self] result in
            guard let self else { return }

            // 如果期間 stopCall() 了，這次結果直接丟棄
            guard callId == self.currentCallId else {
                rtCompanionLog("/session 回調已過期，忽略")
                return
            }

            switch result {
            case .failure(let err):
                DispatchQueue.main.async {
                    self.isConnecting = false
                    self.isRunning = false
                    self.delegate?.realtimeService(self, didUpdateStatus: "獲取會話失敗")
                    self.delegate?.realtimeService(self, didFailWith: err)
                }

            case .success(let info):
                self.rtcURL = info.rtcURL
                self.ephemeralKey = info.ephemeralKey
                self.iceServers = info.iceServers
                self.useSessionInfoAndConnect(callId: callId)
            }
        }
    }

    private func useSessionInfoAndConnect(callId: UUID) {
        do {
            try self.setupPeerConnection()
        } catch {
            DispatchQueue.main.async {
                self.isConnecting = false
                self.isRunning = false
                self.delegate?.realtimeService(self, didUpdateStatus: "建立連接失敗")
                self.delegate?.realtimeService(self, didFailWith: error)
            }
            return
        }

        self.negotiate { [weak self] error in
            guard let self else { return }
            guard callId == self.currentCallId else {
                rtCompanionLog("negotiate 回調已過期，忽略結果")
                return
            }

            DispatchQueue.main.async {
                if let e = error {
                    self.isConnecting = false
                    self.isRunning = false
                    self.delegate?.realtimeService(self, didUpdateStatus: "協商失敗")
                    self.delegate?.realtimeService(self, didFailWith: e)
                } else {
                    self.isConnecting = false
                    self.isRunning = true
                    self.conversation.removeAll()
                    self.startPing()
                    self.delegate?.realtimeServiceDidConnect(self)
                    self.delegate?.realtimeService(self, didUpdateStatus: "已連接")
                }
            }
        }
    }

    // MARK: - PeerConnection / DataChannel

    private func setupPeerConnection() throws {
        guard let factory = factory else {
            throw NSError(
                domain: "RealtimeCompanionService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "RTCPeerConnectionFactory 未初始化"]
            )
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

        // 本地音頻 track（開啟 AEC/AGC/NS）
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

        // DataChannel
        let dcConfig = RTCDataChannelConfiguration()
        dcConfig.isOrdered = true
        let dc = pc.dataChannel(forLabel: "oai-events", configuration: dcConfig)
        dc?.delegate = self
        self.dataChannel = dc

        rtCompanionLog("PeerConnection + local audio track ready")
    }

    /// SDP 協商：Offer -> POST rtc_url -> Answer
    private func negotiate(completion: @escaping (Error?) -> Void) {
        guard let pc = peerConnection,
              let rtcURL = rtcURL,
              let key = ephemeralKey else {
            completion(NSError(
                domain: "RealtimeCompanionService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "缺少 rtcURL / ephemeralKey / peerConnection"]
            ))
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
            if let e = error {
                completion(e)
                return
            }
            guard let offer = sdp else {
                completion(NSError(
                    domain: "RealtimeCompanionService",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "createOffer 返回空"]
                ))
                return
            }

            pc.setLocalDescription(offer) { error in
                if let e = error {
                    completion(e)
                    return
                }

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
                            completion(NSError(
                                domain: "RealtimeCompanionService",
                                code: code,
                                userInfo: [NSLocalizedDescriptionKey: "SDP 交換失敗：\(code) \(body)"]
                            ))
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
            self.pingTimer = Timer.scheduledTimer(
                withTimeInterval: 15.0,
                repeats: true
            ) { [weak self] _ in
                guard let self,
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
}
// MARK: - WebRTC Delegate 實現

extension RealtimeCompanionService: RTCPeerConnectionDelegate, RTCDataChannelDelegate {

    // MARK: - RTCPeerConnectionDelegate（最小實現）

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didChange stateChanged: RTCSignalingState) {
        rtCompanionLog("signaling state = \(stateChanged.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didOpen dataChannel: RTCDataChannel) {
        rtCompanionLog("didOpen dataChannel: \(dataChannel.label)")
        self.dataChannel = dataChannel
        dataChannel.delegate = self
        sendSessionUpdate()
    }

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didChange newState: RTCIceConnectionState) {
        rtCompanionLog("ICE state = \(newState.rawValue)")

        switch newState {
        case .connected, .completed:
            iceReconnectWorkItem?.cancel()
            iceReconnectWorkItem = nil

        case .disconnected:
            iceReconnectWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let state = self.peerConnection?.iceConnectionState ?? .new
                if state == .disconnected {
                    rtCompanionLog("ICE 長時間 disconnected，執行 stopCall()")
                    self.stopCall()
                    DispatchQueue.main.async {
                        self.delegate?.realtimeService(self, didUpdateStatus: "網路不穩定，已斷開")
                    }
                } else {
                    rtCompanionLog("ICE 已在延時期間恢復，不再斷開（state=\(state.rawValue))")
                }
            }
            iceReconnectWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)

        case .failed:
            iceReconnectWorkItem?.cancel()
            iceReconnectWorkItem = nil
            rtCompanionLog("ICE failed，直接斷開")
            DispatchQueue.main.async {
                self.stopCall()
                self.delegate?.realtimeService(self, didUpdateStatus: "網路失敗，已斷開")
            }

        default:
            break
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didChange newState: RTCIceGatheringState) {
        rtCompanionLog("ICE gathering = \(newState.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didGenerate candidate: RTCIceCandidate) {
        rtCompanionLog("didGenerate candidate: \(candidate.sdp)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didRemove candidates: [RTCIceCandidate]) {
        rtCompanionLog("didRemove candidates: \(candidates.count)")
    }

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        rtCompanionLog("peerConnectionShouldNegotiate()")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didAdd stream: RTCMediaStream) {
        rtCompanionLog("didAdd stream: \(stream.streamId)")
        if !remoteAudioTrackBound,
           let audioTrack = stream.audioTracks.first {
            remoteAudioTrackBound = true
            rtCompanionLog("remote audio track bound: \(audioTrack.trackId)")
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didRemove stream: RTCMediaStream) {
        rtCompanionLog("didRemove stream: \(stream.streamId)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didAdd rtpReceiver: RTCRtpReceiver,
                        streams: [RTCMediaStream]) {
        rtCompanionLog("didAdd rtpReceiver: \(rtpReceiver.track?.trackId ?? "nil")")
        if !remoteAudioTrackBound,
           let track = rtpReceiver.track as? RTCAudioTrack {
            remoteAudioTrackBound = true
            rtCompanionLog("remote audio track (RTP) bound: \(track.trackId)")
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didRemove rtpReceiver: RTCRtpReceiver) {
        rtCompanionLog("didRemove rtpReceiver: \(rtpReceiver.track?.trackId ?? "nil")")
    }

    // MARK: - RTCDataChannelDelegate

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        rtCompanionLog("DataChannel state = \(dataChannel.readyState.rawValue)")
        if dataChannel.readyState == .open {
            sendSessionUpdate()
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel,
                     didReceiveMessageWith buffer: RTCDataBuffer) {
        guard !buffer.isBinary else {
            rtCompanionLog("收到二進制 DataChannel 消息，忽略")
            return
        }
        guard let text = String(data: buffer.data, encoding: .utf8) else {
            rtCompanionLog("DataChannel 文本解碼失敗")
            return
        }
        rtCompanionLog("DataChannel recv raw: \(text)")

        guard let data = text.data(using: .utf8) else { return }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            rtCompanionLog("DataChannel recv: 非標準 JSON")
            return
        }

        let type = (json["type"] as? String) ?? ""
        rtCompanionLog("DataChannel event type = \(type)")

        markActivity()

        if type.hasPrefix("conversation.item.") {
            handleConversationItemEvent(json)
            return
        }

        switch type {

        case "response.output_text.delta":
            if let deltaText = Self.extractAssistantText(from: json) {
                transcriptBuffer.append(deltaText)
                if kRealtimeTextToUIEnabledCompanion {
                    let full = transcriptBuffer
                    DispatchQueue.main.async {
                        self.delegate?.realtimeService(
                            self,
                            didUpdateTranscript: "[A]" + full
                        )
                    }
                }
            }

        case "response.output_text.done",
             "response.completed",
             "response.done":
            let full =
                Self.extractAssistantText(from: json) ??
                (transcriptBuffer.isEmpty ? nil : transcriptBuffer)

            if let finalText = full, !finalText.isEmpty {
                transcriptBuffer = ""
                if kRealtimeTextToUIEnabledCompanion {
                    DispatchQueue.main.async {
                        self.delegate?.realtimeService(
                            self,
                            didUpdateTranscript: "[A]" + finalText
                        )
                    }
                }
            } else {
                rtCompanionLog("output_text.done / response.done: 未找到文本字段")
            }

        case "conversation.item.input_audio_transcription.completed":
            if let userText = Self.extractUserTranscript(from: json), !userText.isEmpty {
                conversation.append(["role": "user", "text": userText])
                if kRealtimeTextToUIEnabledCompanion {
                    DispatchQueue.main.async {
                        self.delegate?.realtimeService(
                            self,
                            didUpdateTranscript: "[U]" + userText
                        )
                    }
                }
            } else {
                rtCompanionLog("input_audio_transcription.completed: 未找到 transcript")
            }

        case "error":
            let msg = (json["error"] as? [String: Any])?["message"] as? String
            ?? (json["message"] as? String)
            ?? "Realtime error"
            let err = NSError(
                domain: "RealtimeCompanionService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: msg]
            )
            DispatchQueue.main.async {
                self.delegate?.realtimeService(self, didFailWith: err)
                self.delegate?.realtimeService(self, didUpdateStatus: "會話錯誤")
            }

        default:
            if let item = json["item"] as? [String: Any],
               let role = item["role"] as? String {
                rtCompanionLog("fallback by item, role=\(role)")
                handleConversationItem(item: item)
            } else {
                rtCompanionLog("忽略事件 type=\(type)")
            }
        }
    }

    // MARK: - conversation.item.* 統一處理

    private func handleConversationItemEvent(_ json: [String: Any]) {
        guard let item = json["item"] as? [String: Any] else {
            rtCompanionLog("conversation.item.*: 缺少 item")
            return
        }
        handleConversationItem(item: item)
    }

    private func handleConversationItem(item: [String: Any]) {
        let role = (item["role"] as? String) ?? ""
        rtCompanionLog("handleConversationItem role=\(role)")

        if role == "assistant" {
            guard let text = Self.extractAssistantTextFromItem(item), !text.isEmpty else {
                rtCompanionLog("conversation.item(assistant): 未找到文本")
                return
            }
            if kRealtimeTextToUIEnabledCompanion {
                DispatchQueue.main.async {
                    self.delegate?.realtimeService(
                        self,
                        didUpdateTranscript: "[A]" + text
                    )
                }
            }

        } else if role == "user" {
            guard let text = Self.extractUserTextFromItem(item), !text.isEmpty else {
                rtCompanionLog("conversation.item(user): 未找到文本")
                return
            }
            conversation.append(["role": "user", "text": text])
            if kRealtimeTextToUIEnabledCompanion {
                DispatchQueue.main.async {
                    self.delegate?.realtimeService(
                        self,
                        didUpdateTranscript: "[U]" + text
                    )
                }
            }

        } else {
            rtCompanionLog("conversation.item: 未處理的 role=\(role)")
        }
    }

    // MARK: - 事件解析輔助方法

    fileprivate static func extractAssistantText(from json: [String: Any]) -> String? {
        if let t = json["text"] as? String, !t.isEmpty { return t }
        if let t = json["delta"] as? String, !t.isEmpty { return t }
        if let deltaDict = json["delta"] as? [String: Any],
           let t = deltaDict["text"] as? String,
           !t.isEmpty { return t }

        if let response = json["response"] as? [String: Any],
           let outputs = response["output"] as? [[String: Any]] {
            for out in outputs {
                if let contents = out["content"] as? [[String: Any]] {
                    for c in contents {
                        if let t = c["text"] as? String, !t.isEmpty { return t }
                        if let t = c["transcript"] as? String, !t.isEmpty { return t }
                        if let d = c["delta"] as? String, !d.isEmpty { return d }
                        if let d2 = c["delta"] as? [String: Any],
                           let t = d2["text"] as? String,
                           !t.isEmpty { return t }
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
        if let t = json["transcript"] as? String, !t.isEmpty {
            return t
        }
        if let item = json["item"] as? [String: Any] {
            if let t = item["transcript"] as? String, !t.isEmpty {
                return t
            }
            if let trans = item["transcription"] as? [String: Any],
               let t = trans["text"] as? String,
               !t.isEmpty {
                return t
            }
        }
        if let delta = json["delta"] as? String, !delta.isEmpty {
            return delta
        }
        return nil
    }
}
