
// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-8c88fd30694cc0423146f1071f096aba24a3729c199fe44dbe535812902449b3"
// Source-SHA256: "f1726ecf853030383e1d717055b296554ccfba71d02ee52ab2dfd0bbced94a9a"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation
import AVFoundation
import WebRTC
import Combine
import UIKit

/// 真实语音通话页专用 Service：
/// - 复用旧 RealtimeQuickService 的 /session + WebRTC + local_audio + oai-events 连接方式
/// - 不接主业务、不接 TTS、不接 ScreenAgent、不接摄像头
/// - 禁止活性打断：speech_started 只记录，不 clear，不 cancel
/// - 语义打断：只有语义判定为 interrupt 后才 response.cancel；否则旧回答继续说完
final class SemanticInterruptVoiceCallService: NSObject, ObservableObject {

    enum CallState: Equatable {
        case idle
        case connecting
        case connected
        case assistantSpeaking
        case listening
        case disconnecting
        case failed(String)

        var title: String {
            switch self {
            case .idle: return "未连接"
            case .connecting: return "连接中"
            case .connected: return "通话中"
            case .assistantSpeaking: return "助手正在说话"
            case .listening: return "正在听你说"
            case .disconnecting: return "断开中"
            case .failed(let s): return "错误：\(s)"
            }
        }
    }

    struct LogLine: Identifiable {
        let id = UUID()
        let date = Date()
        let text: String
    }

    @Published private(set) var state: CallState = .idle
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var isResponseActive: Bool = false
    @Published private(set) var isMuted: Bool = false
    @Published private(set) var userTranscript: String = ""
    @Published private(set) var assistantTranscript: String = ""
    @Published private(set) var logs: [LogLine] = []

    /// 语义判定接口。建议后端加 /realtime/semantic_judge。
    /// 若后端没有该接口，默认不打断，只让助手说完，符合“语义不生效就不打断”。
    var semanticJudgeEndpointEnabled: Bool = true

    /// 是否启用本地保守关键词兜底。默认关闭，避免又变成“假语义打断”。
    var localKeywordFallbackEnabled: Bool = false

    private enum Backend {
        static var apiBase: String { AppConfig.API.apiBase.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        static var sessionURL: URL { URL(string: apiBase + "/session")! }
        static var semanticJudgeURL: URL? { URL(string: apiBase + "/realtime/semantic_judge") }
        static var semanticNotifyURL: URL? { URL(string: apiBase + "/realtime/semantic_interrupt") }
    }

    private struct SessionInfo {
        let rtcURL: URL
        let ephemeralKey: String
        let iceServers: [RTCIceServer]
        let conversationId: String?
    }

    private let workQueue = DispatchQueue(label: "semantic.true.voice.call.queue", qos: .userInitiated)
    private let workKey = DispatchSpecificKey<Void>()

    private var factory: RTCPeerConnectionFactory!
    private var peerConnection: RTCPeerConnection?
    private var localAudioTrack: RTCAudioTrack?
    private var dataChannel: RTCDataChannel?

    private var currentCallId = UUID()
    private var rtcURL: URL?
    private var ephemeralKey: String?
    private var iceServers: [RTCIceServer] = []
    private var hasSentSessionUpdate = false
    private var queuedEvents: [[String: Any]] = []

    private var pendingSessionInfo: SessionInfo?
    private var pendingAudioReady = false

    private var currentResponseId: String?
    private var currentAssistantItemId: String?
    private var responseCancelInFlight = false
    private var pendingUserTextAfterCancel: String?
    private var pendingUserTextAfterCurrentResponse: String?

    private var currentAssistantText: String = ""
    private var assistantFlushWorkItem: DispatchWorkItem?

    private var semanticInterruptToken = "__SEMANTIC_INTERRUPT__"
    private var semanticProbe = ""
    private var droppingControlLine = false

    private let utteranceEndGrace: TimeInterval = 0.45
    private var utteranceEndWorkItem: DispatchWorkItem?

    private var clientId: String = {
        let key = "semantic.true.voice.call.client_id"
        if let v = UserDefaults.standard.string(forKey: key), !v.isEmpty { return v }
        let v = UUID().uuidString.lowercased()
        UserDefaults.standard.set(v, forKey: key)
        return v
    }()

    override init() {
        super.init()
        workQueue.setSpecific(key: workKey, value: ())
        RTCPeerConnectionFactory.initialize()
        factory = RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }

    deinit {
        stop()
    }

    // MARK: - Public

    func toggleCall() {
        if isConnected || state == .connecting {
            stop()
        } else {
            start()
        }
    }

    func start() {
        workAsync { [weak self] in
            self?.startInternal()
        }
    }

    func stop() {
        workAsync { [weak self] in
            self?.hardReset(notify: true, reason: "manual_stop")
        }
    }

    func toggleMute() {
        workAsync { [weak self] in
            guard let self else { return }
            self.isMuted.toggle()
            self.localAudioTrack?.isEnabled = !self.isMuted
            self.log(self.isMuted ? "MUTE_ON" : "MUTE_OFF")
            self.publish { $0.isMuted = self.isMuted }
        }
    }

    func clearLogs() {
        DispatchQueue.main.async { self.logs.removeAll() }
    }

    // MARK: - Start

    private func startInternal() {
        hardReset(notify: false, reason: "start_reset")

        let callId = UUID()
        currentCallId = callId
        publish {
            $0.state = .connecting
            $0.isConnected = false
            $0.isResponseActive = false
            $0.userTranscript = ""
            $0.assistantTranscript = ""
        }
        log("CALL_START")

        fetchSession { [weak self] result in
            guard let self else { return }
            self.workAsync {
                guard callId == self.currentCallId else { return }
                switch result {
                case .success(let info):
                    self.log("SESSION_OK rtc=\(info.rtcURL.absoluteString) conv=\(info.conversationId ?? "nil")")
                    self.pendingSessionInfo = info
                    self.maybeConnectIfReady(callId: callId)
                case .failure(let error):
                    self.fail("SESSION_FAILED \(error.localizedDescription)")
                }
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.preflightAudio(callId: callId)
        }
    }

    private func preflightAudio(callId: UUID) {
        let permission = AVAudioSession.sharedInstance().recordPermission
        switch permission {
        case .granted:
            do {
                try configureAudioSessionOnMain()
                workAsync { [weak self] in
                    guard let self, callId == self.currentCallId else { return }
                    self.pendingAudioReady = true
                    self.maybeConnectIfReady(callId: callId)
                }
            } catch {
                workAsync { [weak self] in self?.fail("AUDIO_SESSION_FAILED \(error.localizedDescription)") }
            }

        case .undetermined:
            AVAudioSession.sharedInstance().requestRecordPermission { [weak self] ok in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard ok else {
                        self.workAsync { self.fail("MIC_PERMISSION_DENIED") }
                        return
                    }
                    do {
                        try self.configureAudioSessionOnMain()
                        self.workAsync {
                            guard callId == self.currentCallId else { return }
                            self.pendingAudioReady = true
                            self.maybeConnectIfReady(callId: callId)
                        }
                    } catch {
                        self.workAsync { self.fail("AUDIO_SESSION_FAILED \(error.localizedDescription)") }
                    }
                }
            }

        case .denied:
            workAsync { [weak self] in self?.fail("MIC_PERMISSION_DENIED") }

        @unknown default:
            workAsync { [weak self] in self?.fail("MIC_PERMISSION_UNKNOWN") }
        }
    }

    private func maybeConnectIfReady(callId: UUID) {
        guard callId == currentCallId else { return }
        guard pendingAudioReady else { return }
        guard let info = pendingSessionInfo else { return }

        pendingSessionInfo = nil
        rtcURL = info.rtcURL
        ephemeralKey = info.ephemeralKey
        iceServers = info.iceServers

        do {
            try setupPeerConnection()
        } catch {
            fail("PEER_CONNECTION_FAILED \(error.localizedDescription)")
            return
        }

        negotiate(callId: callId) { [weak self] error in
            guard let self else { return }
            self.workAsync {
                guard callId == self.currentCallId else { return }
                if let error {
                    self.fail("NEGOTIATE_FAILED \(error.localizedDescription)")
                    return
                }
                self.log("CALL_CONNECTED")
                self.publish {
                    $0.state = .connected
                    $0.isConnected = true
                }
            }
        }
    }

    // MARK: - Session

    private func fetchSession(completion: @escaping (Result<SessionInfo, Error>) -> Void) {
        var req = URLRequest(url: Backend.sessionURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "want_video": false,
            "allow_web": true,
            "enable_memory": true,
            "provider": "openai",
            "profile": "semantic_voice_call",
            "client_id": clientId
        ]

        log("SESSION_PAYLOAD provider=openai profile=semantic_voice_call")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload, options: [])

        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err { completion(.failure(err)); return }
            guard let http = resp as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let data else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                completion(.failure(NSError(domain: "SemanticVoiceCall", code: code, userInfo: [NSLocalizedDescriptionKey: "/session failed \(code)"])))
                return
            }
            do {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw NSError(domain: "SemanticVoiceCall", code: -1, userInfo: [NSLocalizedDescriptionKey: "invalid session json"])
                }
                let provider = (json["provider"] as? String)?.lowercased() ?? "openai"
                guard provider == "openai" else {
                    throw NSError(domain: "SemanticVoiceCall", code: -2, userInfo: [NSLocalizedDescriptionKey: "only openai provider is supported here, got \(provider)"])
                }
                guard let rtc = json["rtc_url"] as? String, let rtcURL = URL(string: rtc) else {
                    throw NSError(domain: "SemanticVoiceCall", code: -3, userInfo: [NSLocalizedDescriptionKey: "missing rtc_url"])
                }
                let key = (json["ephemeral_key"] as? String)
                    ?? ((json["client_secret"] as? [String: Any])?["value"] as? String)
                guard let ephemeral = key else {
                    throw NSError(domain: "SemanticVoiceCall", code: -4, userInfo: [NSLocalizedDescriptionKey: "missing ephemeral_key"])
                }

                let rawIce = (json["ice_servers"] as? [[String: Any]]) ?? []
                let ice: [RTCIceServer]
                if rawIce.isEmpty {
                    ice = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
                } else {
                    ice = rawIce.compactMap { d in
                        guard let urls = d["urls"] else { return nil }
                        if let s = urls as? String {
                            return RTCIceServer(urlStrings: [s], username: d["username"] as? String, credential: d["credential"] as? String)
                        }
                        if let arr = urls as? [String] {
                            return RTCIceServer(urlStrings: arr, username: d["username"] as? String, credential: d["credential"] as? String)
                        }
                        return nil
                    }
                }

                completion(.success(SessionInfo(
                    rtcURL: rtcURL,
                    ephemeralKey: ephemeral,
                    iceServers: ice,
                    conversationId: json["conversation_id"] as? String
                )))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    // MARK: - WebRTC

    private func configureAudioSessionOnMain() throws {
        precondition(Thread.isMainThread)
        let rtc = RTCAudioSession.sharedInstance()
        rtc.lockForConfiguration()
        defer { rtc.unlockForConfiguration() }

        let sys = AVAudioSession.sharedInstance()
        do { try sys.setPreferredSampleRate(48_000) } catch {}
        do { try sys.setPreferredIOBufferDuration(0.01) } catch {}

        try rtc.setCategory(
            AVAudioSession.Category.playAndRecord.rawValue,
            with: [.defaultToSpeaker, .allowBluetooth]
        )
        try rtc.setMode(AVAudioSession.Mode.videoChat.rawValue)
        try rtc.setActive(true)

        rtc.isAudioEnabled = true
        rtc.useManualAudio = false

        try? sys.overrideOutputAudioPort(.speaker)
        log("AUDIO_SESSION_CONFIGURED playAndRecord videoChat speaker")
    }

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

        // 注意：你当前 WebRTC SDK 这里返回非 Optional，不能 guard let。
        let pc = factory.peerConnection(with: config, constraints: constraints, delegate: self)
        peerConnection = pc

        let audioConstraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: [
                "googEchoCancellation": "true",
                "googAutoGainControl": "true",
                "googNoiseSuppression": "true"
            ]
        )
        let audioSource = factory.audioSource(with: audioConstraints)
        let track = factory.audioTrack(with: audioSource, trackId: "semantic_true_voice_local_audio")
        track.isEnabled = true
        localAudioTrack = track
        pc.add(track, streamIds: ["semantic_true_voice_stream"])

        let dcConfig = RTCDataChannelConfiguration()
        dcConfig.isOrdered = true
        let dc = pc.dataChannel(forLabel: "oai-events", configuration: dcConfig)
        dc?.delegate = self
        dataChannel = dc

        log("PEER_READY local_audio + oai-events")
    }

    private func negotiate(callId: UUID, completion: @escaping (Error?) -> Void) {
        guard let pc = peerConnection, let rtcURL, let key = ephemeralKey else {
            completion(NSError(domain: "SemanticVoiceCall", code: -1, userInfo: [NSLocalizedDescriptionKey: "missing pc/rtc/key"]))
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

        pc.offer(for: constraints) { [weak self] sdp, err in
            guard let self else { return }
            self.workAsync {
                guard callId == self.currentCallId, pc === self.peerConnection else { return }
                if let err { completion(err); return }
                guard let offer = sdp else {
                    completion(NSError(domain: "SemanticVoiceCall", code: -1, userInfo: [NSLocalizedDescriptionKey: "empty offer"]))
                    return
                }

                pc.setLocalDescription(offer) { [weak self] err in
                    guard let self else { return }
                    self.workAsync {
                        guard callId == self.currentCallId, pc === self.peerConnection else { return }
                        if let err { completion(err); return }

                        var req = URLRequest(url: rtcURL)
                        req.httpMethod = "POST"
                        req.timeoutInterval = 20
                        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                        req.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
                        req.setValue("application/sdp", forHTTPHeaderField: "Accept")
                        req.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
                        req.httpBody = (pc.localDescription?.sdp ?? offer.sdp).data(using: .utf8)

                        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
                            guard let self else { return }
                            self.workAsync {
                                guard callId == self.currentCallId, pc === self.peerConnection else { return }
                                if let err { completion(err); return }

                                guard let http = resp as? HTTPURLResponse,
                                      (200..<300).contains(http.statusCode),
                                      let data,
                                      let answer = String(data: data, encoding: .utf8) else {
                                    let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                                    let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                                    completion(NSError(domain: "SemanticVoiceCall", code: code, userInfo: [NSLocalizedDescriptionKey: "SDP exchange failed \(code) \(body)"]))
                                    return
                                }

                                pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: answer)) { err in
                                    self.workAsync { completion(err) }
                                }
                            }
                        }.resume()
                    }
                }
            }
        }
    }

    // MARK: - Realtime session + events

    private func sendSessionUpdateIfNeeded() {
        guard !hasSentSessionUpdate else { return }
        hasSentSessionUpdate = true

        let instructions = """
        你是阿杜的实时语音通话助手。

        【语义打断定义】
        用户在你正在回答时插话，你要根据上下文判断当前用户语句是不是想打断本轮回答。
        真打断包括：等一下、不是这个、你理解错了、别说了、停一下、我是说、我说的是、换一个、先别讲这个、重新来。
        非打断包括：嗯、对、好、继续、然后呢、你接着说、明白、可以。

        如果是真打断，优先调用工具 semantic_interrupt。
        如果工具不可用，则输出控制符：\(semanticInterruptToken){"reason":"user_correction","mode":"replace_current_turn"}
        控制符不是给用户看的内容。不要解释控制符。
        如果不是打断，就继续当前回答，不要调用工具，不要输出控制符。
        """

        var session: [String: Any] = [
            "modalities": ["audio", "text"],
            "voice": "alloy",
            "instructions": instructions,
            "input_audio_transcription": ["model": "whisper-1"],
            "turn_detection": [
                "type": "server_vad",
                "silence_duration_ms": 220,
                "prefix_padding_ms": 120,
                "create_response": false,
                "interrupt_response": false
            ] as [String: Any],
            "tools": [[
                "type": "function",
                "name": "semantic_interrupt",
                "description": "当且仅当用户在你回答过程中明确表达打断、否定、纠正、改口、换话题或停止本轮回答时调用。普通附和如嗯、对、继续、然后呢不要调用。",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "reason": ["type": "string"],
                        "new_user_text": ["type": "string"],
                        "confidence": ["type": "number"]
                    ]
                ]
            ]],
            "tool_choice": "auto"
        ]

        // 兼容新字段；旧 endpoint 会忽略未知字段。
        session["output_modalities"] = ["audio", "text"]

        log("SESSION_UPDATE create_response=false interrupt_response=false")
        sendEvent(["type": "session.update", "session": session])
        flushQueuedEvents()
    }

    private func handleServerEvent(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let type = (json["type"] as? String) ?? ""
        switch type {
        case "session.created", "session.updated":
            log(type.uppercased())

        case "input_audio_buffer.speech_started":
            log("USER_SPEECH_STARTED no_clear_no_cancel activeResponse=\(isResponseActive)")
            publish { $0.state = .listening }

        case "input_audio_buffer.speech_stopped":
            log("USER_SPEECH_STOPPED grace=\(utteranceEndGrace)")

        case "conversation.item.input_audio_transcription.completed":
            if let t = Self.extractUserTranscript(from: json), !t.isEmpty {
                userTranscript = t
                publish { $0.userTranscript = t }
                log("USER_TRANSCRIPT_FINAL \(short(t))")
                scheduleUtteranceEnd(userText: t)
            } else {
                log("USER_TRANSCRIPT_EMPTY")
            }

        case "response.created":
            currentResponseId = Self.extractResponseId(from: json)
            responseCancelInFlight = false
            isResponseActive = true
            currentAssistantText = ""
            resetSemanticParser()
            publish {
                $0.isResponseActive = true
                $0.state = .assistantSpeaking
                $0.assistantTranscript = ""
            }
            log("RESPONSE_CREATED id=\(currentResponseId ?? "nil")")

        case "response.output_item.added":
            if let item = json["item"] as? [String: Any],
               let id = item["id"] as? String,
               let type = item["type"] as? String,
               type == "message" {
                currentAssistantItemId = id
                log("ASSISTANT_ITEM id=\(id)")
            }

        case "response.output_text.delta", "response.text.delta", "response.audio_transcript.delta", "response.output_audio_transcript.delta":
            if let delta = Self.extractAssistantDelta(from: json), !delta.isEmpty {
                let visible = filterSemanticControl(from: delta)
                if !visible.isEmpty {
                    currentAssistantText.append(visible)
                    scheduleAssistantFlush()
                }
            }

        case "response.function_call_arguments.done":
            if Self.extractFunctionName(from: json) == "semantic_interrupt" {
                let args = Self.extractFunctionArguments(from: json) ?? "{}"
                log("SEMANTIC_TOOL_TRIGGERED \(short(args))")
                executeSemanticInterrupt(source: "tool", reason: args, userText: userTranscript)
            }

        case "response.audio.done", "response.output_audio.done":
            log("RESPONSE_AUDIO_DONE")

        case "response.done", "response.completed":
            let status = Self.extractResponseStatus(from: json) ?? "nil"
            log("RESPONSE_DONE status=\(status)")
            finishResponse(reason: "done")
            if let queued = pendingUserTextAfterCurrentResponse {
                pendingUserTextAfterCurrentResponse = nil
                sendUserTextAndResponse(queued, reason: "after_previous_response_done")
            }

        case "response.cancelled":
            log("RESPONSE_CANCELLED")
            finishResponse(reason: "cancelled")
            if let pending = pendingUserTextAfterCancel {
                pendingUserTextAfterCancel = nil
                sendUserTextAndResponse(pending, reason: "after_semantic_cancel")
            }

        case "error":
            let msg = (json["error"] as? [String: Any])?["message"] as? String
                ?? json["message"] as? String
                ?? "Realtime error"
            log("SERVER_ERROR \(msg)")
            if msg.contains("active response") || msg.contains("already has an active") {
                isResponseActive = false
                responseCancelInFlight = false
                publish { $0.isResponseActive = false }
            }

        default:
            break
        }
    }

    private func scheduleUtteranceEnd(userText: String) {
        utteranceEndWorkItem?.cancel()
        let callId = currentCallId
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard callId == self.currentCallId else { return }
            self.handleUtteranceEnd(userText: userText)
        }
        utteranceEndWorkItem = item
        workQueue.asyncAfter(deadline: .now() + utteranceEndGrace, execute: item)
    }

    private func handleUtteranceEnd(userText: String) {
        log("USER_UTTERANCE_END activeResponse=\(isResponseActive) text=\(short(userText))")

        if isResponseActive {
            judgeSemanticInterrupt(userText: userText) { [weak self] shouldInterrupt, reason in
                guard let self else { return }
                self.workAsync {
                    self.log("SEMANTIC_DECISION \(shouldInterrupt ? "interrupt" : "continue") reason=\(reason)")
                    if shouldInterrupt {
                        self.executeSemanticInterrupt(source: "judge", reason: reason, userText: userText)
                    } else {
                        // 不打断：旧回答继续说完。若这不是简单附和，则排队到旧回答结束后再问。
                        if !self.looksLikeBackchannel(userText) {
                            self.pendingUserTextAfterCurrentResponse = userText
                            self.log("QUEUE_AFTER_CURRENT_RESPONSE text=\(self.short(userText))")
                        }
                    }
                }
            }
            return
        }

        sendUserTextAndResponse(userText, reason: "user_utterance_no_active_response")
    }

    private func judgeSemanticInterrupt(userText: String, completion: @escaping (Bool, String) -> Void) {
        if semanticJudgeEndpointEnabled, let url = Backend.semanticJudgeURL {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 2.5
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = [
                "client_id": clientId,
                "user_text": userText,
                "assistant_text": String(currentAssistantText.suffix(1200)),
                "active_response": true
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])
            log("SEMANTIC_JUDGE_REQUEST")
            URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                if let err {
                    self?.workAsync { self?.log("SEMANTIC_JUDGE_ERROR code=\(code) err=\(err.localizedDescription)") }
                    if self?.localKeywordFallbackEnabled == true {
                        completion(Self.localKeywordJudge(userText), "local_fallback_after_error")
                    } else {
                        completion(false, "judge_unavailable_no_interrupt")
                    }
                    return
                }

                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self?.workAsync { self?.log("SEMANTIC_JUDGE_BAD_RESPONSE code=\(code)") }
                    if self?.localKeywordFallbackEnabled == true {
                        completion(Self.localKeywordJudge(userText), "local_fallback_bad_response")
                    } else {
                        completion(false, "judge_bad_response_no_interrupt")
                    }
                    return
                }

                let interrupt = (json["interrupt"] as? Bool) ?? (json["should_interrupt"] as? Bool) ?? false
                let reason = (json["reason"] as? String) ?? "backend_judge"
                completion(interrupt, reason)
            }.resume()
            return
        }

        if localKeywordFallbackEnabled {
            completion(Self.localKeywordJudge(userText), "local_keyword_fallback")
        } else {
            completion(false, "no_judge_no_interrupt")
        }
    }

    private func executeSemanticInterrupt(source: String, reason: String, userText: String) {
        log("SEMANTIC_INTERRUPT_EXECUTE source=\(source) reason=\(short(reason))")
        notifyBackendSemanticInterrupt(source: source, reason: reason, userText: userText)

        guard isResponseActive else {
            sendUserTextAndResponse(userText, reason: "semantic_interrupt_no_active_response")
            return
        }

        pendingUserTextAfterCancel = userText
        cancelActiveResponse(reason: "semantic_interrupt_\(source)")
    }

    private func cancelActiveResponse(reason: String) {
        guard isResponseActive, !responseCancelInFlight else {
            log("CANCEL_IGNORED reason=\(reason) active=\(isResponseActive) inFlight=\(responseCancelInFlight)")
            return
        }
        responseCancelInFlight = true
        log("CANCEL_ACTIVE_RESPONSE reason=\(reason)")
        sendEvent(["type": "response.cancel"], droppable: true)
    }

    private func sendUserTextAndResponse(_ text: String, reason: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        guard !isResponseActive else {
            log("RESPONSE_CREATE_BLOCKED_ACTIVE reason=\(reason)")
            pendingUserTextAfterCurrentResponse = t
            return
        }

        log("USER_ITEM_CREATE reason=\(reason) text=\(short(t))")
        sendEvent([
            "type": "conversation.item.create",
            "event_id": UUID().uuidString,
            "item": [
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": t]]
            ]
        ])

        isResponseActive = true
        publish { $0.isResponseActive = true }
        log("RESPONSE_CREATE reason=\(reason)")
        sendEvent([
            "type": "response.create",
            "response": [
                "modalities": ["audio", "text"],
                "output_modalities": ["audio", "text"],
                "audio": ["voice": "alloy"]
            ]
        ])
    }

    // MARK: - Hidden control token

    private func filterSemanticControl(from delta: String) -> String {
        guard !delta.isEmpty else { return "" }

        if droppingControlLine {
            if let nl = delta.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                droppingControlLine = false
                return String(delta[delta.index(after: nl)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return ""
        }

        // 只在回答开头探测控制符，避免误杀正文。
        guard currentAssistantText.isEmpty || !semanticProbe.isEmpty else { return delta }

        let combined = semanticProbe + delta
        if combined.contains(semanticInterruptToken) {
            semanticProbe = ""
            log("SEMANTIC_TOKEN_TRIGGERED \(short(combined))")
            executeSemanticInterrupt(source: "model_token", reason: combined, userText: userTranscript)
            return visibleTextAfterControl(in: combined)
        }

        if semanticInterruptToken.hasPrefix(combined) {
            semanticProbe = combined
            return ""
        }

        semanticProbe = ""
        return combined
    }

    private func visibleTextAfterControl(in text: String) -> String {
        guard let r = text.range(of: semanticInterruptToken) else { return text }
        var rest = String(text[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

        if rest.first == "{" {
            if let end = Self.endIndexOfFirstJSONObject(in: rest) {
                rest = String(rest[rest.index(after: end)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                droppingControlLine = true
                return ""
            }
        }

        if let nl = rest.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            return String(rest[rest.index(after: nl)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        droppingControlLine = true
        return ""
    }

    private func resetSemanticParser() {
        semanticProbe = ""
        droppingControlLine = false
    }

    private func notifyBackendSemanticInterrupt(source: String, reason: String, userText: String) {
        guard let url = Backend.semanticNotifyURL else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 2
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "token": semanticInterruptToken,
            "client_id": clientId,
            "source": source,
            "reason": reason,
            "new_user_text": userText
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])
        URLSession.shared.dataTask(with: req).resume()
    }

    private func finishResponse(reason: String) {
        log("FINISH_RESPONSE reason=\(reason)")
        isResponseActive = false
        responseCancelInFlight = false
        currentResponseId = nil
        currentAssistantItemId = nil
        resetSemanticParser()
        publish {
            $0.isResponseActive = false
            $0.state = self.isConnected ? .connected : .idle
        }
    }

    // MARK: - Transport

    private func sendEvent(_ event: [String: Any], droppable: Bool = false) {
        let type = event["type"] as? String ?? "unknown"
        if ["session.update", "conversation.item.create", "response.create", "response.cancel"].contains(type) {
            log("SEND_EVENT type=\(type) droppable=\(droppable)")
        }

        guard let dc = dataChannel, dc.readyState == .open else {
            if !droppable { queuedEvents.append(event) }
            log("QUEUE_EVENT type=\(type)")
            return
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: event, options: [])
            dc.sendData(RTCDataBuffer(data: data, isBinary: false))
        } catch {
            log("SEND_EVENT_JSON_ERROR \(error.localizedDescription)")
        }
    }

    private func flushQueuedEvents() {
        guard let dc = dataChannel, dc.readyState == .open else { return }
        guard !queuedEvents.isEmpty else { return }
        let pending = queuedEvents
        queuedEvents.removeAll()
        log("FLUSH_EVENTS count=\(pending.count)")
        pending.forEach { sendEvent($0) }
    }

    // MARK: - Reset / fail

    private func hardReset(notify: Bool, reason: String) {
        log("HARD_RESET reason=\(reason) notify=\(notify)")
        currentCallId = UUID()
        utteranceEndWorkItem?.cancel(); utteranceEndWorkItem = nil
        assistantFlushWorkItem?.cancel(); assistantFlushWorkItem = nil
        queuedEvents.removeAll()
        hasSentSessionUpdate = false
        pendingSessionInfo = nil
        pendingAudioReady = false
        isResponseActive = false
        responseCancelInFlight = false
        currentResponseId = nil
        currentAssistantItemId = nil
        pendingUserTextAfterCancel = nil
        pendingUserTextAfterCurrentResponse = nil
        currentAssistantText = ""
        resetSemanticParser()

        dataChannel?.delegate = nil
        dataChannel?.close()
        dataChannel = nil

        peerConnection?.delegate = nil
        peerConnection?.close()
        peerConnection = nil
        localAudioTrack = nil

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
            publish {
                $0.state = .idle
                $0.isConnected = false
                $0.isResponseActive = false
            }
        }
    }

    private func fail(_ message: String) {
        log("FAIL \(message)")
        hardReset(notify: false, reason: "fail")
        publish {
            $0.state = .failed(message)
            $0.isConnected = false
            $0.isResponseActive = false
        }
    }

    // MARK: - UI helpers

    private func log(_ text: String) {
        print("[SemanticTrueCall] \(text)")
        DispatchQueue.main.async {
            self.logs.append(LogLine(text: text))
            if self.logs.count > 80 { self.logs.removeFirst(self.logs.count - 80) }
        }
    }

    private func scheduleAssistantFlush() {
        guard assistantFlushWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.assistantFlushWorkItem = nil
            let text = self.currentAssistantText
            self.publish { $0.assistantTranscript = text }
        }
        assistantFlushWorkItem = item
        workQueue.asyncAfter(deadline: .now() + 0.06, execute: item)
    }

    private func publish(_ update: @escaping (SemanticInterruptVoiceCallService) -> Void) {
        DispatchQueue.main.async {
            update(self)
        }
    }

    private func workAsync(_ block: @escaping () -> Void) {
        workQueue.async(execute: block)
    }

    private func short(_ text: String, _ n: Int = 120) -> String {
        let t = text.replacingOccurrences(of: "\n", with: " ")
        return t.count > n ? String(t.prefix(n)) + "…" : t
    }

    // MARK: - Simple helpers

    private func looksLikeBackchannel(_ text: String) -> Bool {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = ["嗯", "对", "好", "好的", "继续", "接着", "然后呢", "明白", "可以", "你继续", "你接着说"]
        return words.contains { s == $0 || (s.contains($0) && s.count <= 8) }
    }

    private static func localKeywordJudge(_ text: String) -> Bool {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let continueWords = ["嗯", "对", "好", "好的", "继续", "然后呢", "你继续", "你接着说"]
        if continueWords.contains(where: { s == $0 || (s.contains($0) && s.count <= 8) }) { return false }
        let interruptWords = ["等一下", "等等", "不是", "不对", "别说", "停一下", "我不是", "我是说", "我说的是", "你理解错", "换一个", "先别", "重新来", "不是这个", "打住"]
        return interruptWords.contains { s.contains($0) }
    }

    // MARK: - JSON Extractors

    private static func extractUserTranscript(from json: [String: Any]) -> String? {
        if let t = json["transcript"] as? String, !t.isEmpty { return t }
        if let item = json["item"] as? [String: Any] {
            if let t = item["transcript"] as? String, !t.isEmpty { return t }
            if let trans = item["transcription"] as? [String: Any], let t = trans["text"] as? String, !t.isEmpty { return t }
        }
        return nil
    }

    private static func extractAssistantDelta(from json: [String: Any]) -> String? {
        if let t = json["delta"] as? String, !t.isEmpty { return t }
        if let t = json["text"] as? String, !t.isEmpty { return t }
        if let delta = json["delta"] as? [String: Any], let t = delta["text"] as? String, !t.isEmpty { return t }
        return nil
    }

    private static func extractResponseId(from json: [String: Any]) -> String? {
        if let r = json["response"] as? [String: Any], let id = r["id"] as? String { return id }
        return json["response_id"] as? String
    }

    private static func extractResponseStatus(from json: [String: Any]) -> String? {
        if let r = json["response"] as? [String: Any], let s = r["status"] as? String { return s }
        return json["status"] as? String
    }

    private static func extractFunctionName(from json: [String: Any]) -> String? {
        if let name = json["name"] as? String { return name }
        if let item = json["item"] as? [String: Any], let name = item["name"] as? String { return name }
        if let call = json["function_call"] as? [String: Any], let name = call["name"] as? String { return name }
        return nil
    }

    private static func extractFunctionArguments(from json: [String: Any]) -> String? {
        if let args = json["arguments"] as? String { return args }
        if let item = json["item"] as? [String: Any], let args = item["arguments"] as? String { return args }
        if let call = json["function_call"] as? [String: Any], let args = call["arguments"] as? String { return args }
        return nil
    }

    private static func endIndexOfFirstJSONObject(in text: String) -> String.Index? {
        var depth = 0
        var inString = false
        var escaping = false
        var started = false
        for i in text.indices {
            let ch = text[i]
            if !started {
                if ch == "{" { started = true; depth = 1 }
                continue
            }
            if inString {
                if escaping { escaping = false }
                else if ch == "\\" { escaping = true }
                else if ch == "\"" { inString = false }
                continue
            }
            if ch == "\"" { inString = true }
            else if ch == "{" { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 { return i }
            }
        }
        return nil
    }
}

// MARK: - WebRTC delegates

extension SemanticInterruptVoiceCallService: RTCPeerConnectionDelegate, RTCDataChannelDelegate {

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        workAsync { [weak self] in
            guard let self else { return }
            self.log("DATA_CHANNEL_STATE \(dataChannel.readyState.rawValue)")
            if dataChannel.readyState == .open {
                self.sendSessionUpdateIfNeeded()
                self.flushQueuedEvents()
            }
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard dataChannel === self.dataChannel else { return }
        guard !buffer.isBinary, let text = String(data: buffer.data, encoding: .utf8) else { return }
        workAsync { [weak self] in self?.handleServerEvent(text) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove rtpReceiver: RTCRtpReceiver) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        workAsync { [weak self] in
            guard let self else { return }
            if let audio = rtpReceiver.track as? RTCAudioTrack {
                audio.isEnabled = true
                self.log("REMOTE_AUDIO_TRACK_ENABLED")
            } else {
                self.log("REMOTE_TRACK kind=\(rtpReceiver.track?.kind ?? "nil")")
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        workAsync { [weak self] in
            guard let self else { return }
            self.log("ICE_STATE \(newState.rawValue)")
            if newState == .failed || newState == .disconnected {
                self.hardReset(notify: true, reason: "ice_state_\(newState.rawValue)")
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        workAsync { [weak self] in
            guard let self else { return }
            self.dataChannel = dataChannel
            dataChannel.delegate = self
            self.log("DATA_CHANNEL_DID_OPEN")
            self.sendSessionUpdateIfNeeded()
            self.flushQueuedEvents()
        }
    }
}

