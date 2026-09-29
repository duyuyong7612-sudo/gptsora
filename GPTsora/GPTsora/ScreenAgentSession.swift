// ScreenAgentSession.swift
// 阿杜 屏幕共享 Agent · 复用主 RealtimeAVService 的薄会话层
//
// 职责:
//   1. 连接后端 /ws/screen/subscribe 接 Mac 屏幕帧
//   2. 把 JPEG 屏幕帧注入 RealtimeAVService.shared
//   3. 接收 RealtimeBridge 广播的转写/回复事件,桥接给 ScreenAgentView
//   4. 把 mac_* 工具调用转发到 Mac bridge
//
// 说明:
//   - 不再自建 Qwen / GPT Realtime 连接
//   - 音频 / TTS / WebRTC 全部复用主路径 RealtimeAVService.shared

// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-51c7c37abadaddde5fda437313260989b36a3779187e2011c2e2e4e3890d08f0"
// Source-SHA256: "a7f3d795199d415db0aec05a51f037e77bd943c24964fcbf211fe845426f48f0"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation
import AVFoundation

struct ScreenAgentConfig {
    let backendBase: String
    let userKey: String
    var provider: String = "openai"
    var sessionProfile: String = "default"
    var autoWatchOnStart: Bool = false
    var defaultFPS: Double = 1.0
}

protocol ScreenAgentSessionDelegate: AnyObject {
    func sessionDidConnect()
    func sessionDidDisconnect(error: String?)
    func sessionDidUpdateMacOnline(_ online: Bool)
    func sessionDidReceiveSubtitle(_ text: String, isFinal: Bool)
    func sessionDidStartUserSpeaking()
    func sessionDidStopUserSpeaking()
    func sessionDidStartAssistantSpeaking()
    func sessionDidStopAssistantSpeaking()
    func sessionDidExecuteTool(_ name: String, args: [String: Any])
}

@MainActor
final class ScreenAgentSession: NSObject {
    static weak var activeSession: ScreenAgentSession?

    weak var delegate: ScreenAgentSessionDelegate?
    private(set) var isRunning: Bool = false
    private(set) var macOnline: Bool = false
    private(set) var isMuted: Bool = false

    let config: ScreenAgentConfig

    private var session: URLSession!
    private var screenWS: URLSessionWebSocketTask?
    private var screenReconnectAttempts = 0
    private var lastImageSentAt: TimeInterval = 0
    private var currentFPS: Double
    private var assistantSpeaking = false
    private var observers: [NSObjectProtocol] = []

    init(config: ScreenAgentConfig) {
        self.config = config
        self.currentFPS = config.defaultFPS
        super.init()
        self.session = URLSession(configuration: .default,
                                  delegate: self,
                                  delegateQueue: nil)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        ScreenAgentSession.activeSession = self

        let realtime = RealtimeAVService.shared
        realtime.apiBase = config.backendBase
        realtime.sessionClientId = config.userKey
        realtime.sessionProfile = config.sessionProfile
        realtime.preferredProvider = config.provider
        realtime.instructionsOverride = ScreenAgentInstructions.systemPrompt
        realtime.setImageStreamingEnabled(true)
        realtime.setImageStreamingFPS(config.defaultFPS)
        realtime.stop()
        realtime.start(mode: .audioVideo)

        connectScreen()
        installRealtimeObservers()

        if config.autoWatchOnStart {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self else { return }
                self.sendControlToMac(op: "screen_watch", params: ["fps": self.config.defaultFPS])
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        uninstallRealtimeObservers()

        screenWS?.cancel(with: .goingAway, reason: nil)
        screenWS = nil

        let realtime = RealtimeAVService.shared
        realtime.instructionsOverride = nil
        realtime.setImageStreamingEnabled(false)
        realtime.stop()

        if ScreenAgentSession.activeSession === self {
            ScreenAgentSession.activeSession = nil
        }
    }

    func toggleMute() {
        isMuted.toggle()
        RealtimeAVService.shared.setMuted(isMuted)
    }

    // MARK: - 工具适配（给 ScreenAgentTools 用）

    func glanceNow() {
        lastImageSentAt = 0
        sendControlToMac(op: "screen_glance", params: [:])
    }

    func setStreamingFPS(_ fps: Double) {
        currentFPS = max(0.1, min(5.0, fps))
    }

    func resumeStreaming() {
        sendControlToMac(op: "screen_watch", params: ["fps": currentFPS])
    }

    func pauseStreaming() {
        sendControlToMac(op: "screen_pause", params: [:])
    }

    private var screenWSURL: URL? {
        var s = config.backendBase
        if s.hasPrefix("https://") { s = "wss://" + s.dropFirst(8) }
        else if s.hasPrefix("http://") { s = "ws://" + s.dropFirst(7) }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(s)/ws/screen/subscribe/\(config.userKey)")
    }

    private func connectScreen() {
        guard let url = screenWSURL else { return }
        print("[ScreenAgent.A] connecting \(url.absoluteString)")
        screenWS = session.webSocketTask(with: url)
        screenWS?.resume()
        receiveScreenLoop()
    }

    private func receiveScreenLoop() {
        screenWS?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                Task { @MainActor in
                    self.macOnline = false
                    self.delegate?.sessionDidUpdateMacOnline(false)
                    self.delegate?.sessionDidDisconnect(error: err.localizedDescription)
                    self.scheduleScreenReconnect()
                }
            case .success(let msg):
                if case .string(let s) = msg {
                    self.handleScreenMessage(s)
                }
                self.receiveScreenLoop()
            }
        }
    }

    private func scheduleScreenReconnect() {
        guard isRunning else { return }
        screenReconnectAttempts += 1
        let delay = min(15.0, pow(1.5, Double(screenReconnectAttempts)))
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard self.isRunning else { return }
            self.screenWS = nil
            self.connectScreen()
        }
    }

    private func handleScreenMessage(_ json: String) {
        guard let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return
        }

        switch (obj["type"] as? String) ?? "" {
        case "frame":
            guard let b64 = obj["data"] as? String,
                  let imageData = Data(base64Encoded: b64) else { return }
            let now = CACurrentMediaTime()
            let minInterval = 1.0 / max(0.1, currentFPS)
            if now - lastImageSentAt < minInterval { return }
            lastImageSentAt = now
            RealtimeAVService.shared.injectImageData(imageData, mime: "image/jpeg")

        case "status":
            let online = (obj["mac_online"] as? Bool) ?? false
            macOnline = online
            Task { @MainActor in
                self.delegate?.sessionDidUpdateMacOnline(online)
            }

        case "control_result":
            if let payload = obj["payload"] as? [String: Any] {
                print("[ScreenAgent.A] control result: \(payload)")
            }

        default:
            break
        }
    }

    func sendControlToMac(op: String, params: [String: Any]) {
        var payload: [String: Any] = ["op": op]
        payload.merge(params) { _, new in new }
        let envelope: [String: Any] = ["type": "control", "payload": payload]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope),
              let str = String(data: data, encoding: .utf8) else { return }
        screenWS?.send(.string(str)) { err in
            if let err {
                print("[ScreenAgent.A] sendControl err: \(err.localizedDescription)")
            }
        }
    }

    private func installRealtimeObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default

        observers.append(center.addObserver(forName: .screenAgentRealtimeConnected, object: nil, queue: .main) { [weak self] _ in
            self?.delegate?.sessionDidConnect()
        })

        observers.append(center.addObserver(forName: .screenAgentRealtimeDisconnected, object: nil, queue: .main) { [weak self] note in
            self?.delegate?.sessionDidDisconnect(error: note.userInfo?["error"] as? String)
        })

        observers.append(center.addObserver(forName: .screenAgentRealtimeUserTranscript, object: nil, queue: .main) { [weak self] note in
            guard let self, let text = note.userInfo?["text"] as? String, !text.isEmpty else { return }
            self.delegate?.sessionDidStartUserSpeaking()
            self.delegate?.sessionDidReceiveSubtitle("(我:\(text))", isFinal: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.delegate?.sessionDidStopUserSpeaking()
            }
        })

        observers.append(center.addObserver(forName: .screenAgentRealtimeAssistantPartial, object: nil, queue: .main) { [weak self] note in
            guard let self, let text = note.userInfo?["text"] as? String else { return }
            if !self.assistantSpeaking {
                self.assistantSpeaking = true
                self.delegate?.sessionDidStartAssistantSpeaking()
            }
            self.delegate?.sessionDidReceiveSubtitle(text, isFinal: false)
        })

        observers.append(center.addObserver(forName: .screenAgentRealtimeAssistantFinal, object: nil, queue: .main) { [weak self] note in
            guard let self, let text = note.userInfo?["text"] as? String else { return }
            if !self.assistantSpeaking {
                self.delegate?.sessionDidStartAssistantSpeaking()
            }
            self.assistantSpeaking = false
            self.delegate?.sessionDidReceiveSubtitle(text, isFinal: true)
            self.delegate?.sessionDidStopAssistantSpeaking()
        })
    }

    private func uninstallRealtimeObservers() {
        let center = NotificationCenter.default
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
        assistantSpeaking = false
    }
}

extension ScreenAgentSession: URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession,
                                webSocketTask: URLSessionWebSocketTask,
                                didOpenWithProtocol proto: String?) {
        Task { @MainActor in
            if webSocketTask === self.screenWS {
                self.screenReconnectAttempts = 0
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                                reason: Data?) {
        Task { @MainActor in
            print("[ScreenAgent] WS closed code=\(closeCode.rawValue)")
        }
    }
}

