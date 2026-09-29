// MacScreenSource.swift
// 阿杜 iOS 端:订阅 Mac 屏幕流,每帧注入 Realtime 让 AI 能看。

// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-a669f4f4508c9a83338f5db42ff33086a2283b030450a280a59f62590235712d"
// Source-SHA256: "c85db5244ffe207625ca696329bc9bd763cc6fd854d4f0c016f101a7f8b1d510"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation
import Combine     // ← @Published 必需
import UIKit       // ← UIImage 必需

@MainActor
final class MacScreenSource: NSObject, ObservableObject, URLSessionWebSocketDelegate {

    // MARK: Published state

    @Published private(set) var latestImage: UIImage?
    @Published private(set) var macOnline: Bool = false
    @Published private(set) var connected: Bool = false

    // MARK: Private

    private let apiBase: String
    private let userKey: String
    private var session: URLSession!
    private var subTask: URLSessionWebSocketTask?
    private var onFrame: ((Data) -> Void)?
    private var reconnectAttempts = 0

    // MARK: Init

    init(apiBase: String, userKey: String) {
        self.apiBase = apiBase
        self.userKey = userKey
        super.init()
        self.session = URLSession(configuration: .default,
                                  delegate: self,
                                  delegateQueue: nil)
    }

    // MARK: Public

    /// 仅建立 WebSocket 连接,不注册帧回调(用于检查 Mac 在线状态)
    func connectIfNeeded() {
        if subTask == nil {
            connect()
        }
    }

    /// 开始接收帧(注册回调)
    func start(onFrame: @escaping (Data) -> Void) {
        self.onFrame = onFrame
        connect()
    }

    func stop() {
        subTask?.cancel(with: .goingAway, reason: nil)
        subTask = nil
        connected = false
        onFrame = nil
    }

    /// 给 RealtimeAVService 的 mac_* 工具用
    nonisolated func sendControl(op: String, params: [String: Any] = [:]) {
        var payload: [String: Any] = ["op": op]
        payload.merge(params) { _, new in new }
        let envelope: [String: Any] = ["type": "control", "payload": payload]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope),
              let str = String(data: data, encoding: .utf8) else { return }

        Task { @MainActor in
            self.subTask?.send(.string(str)) { err in
                if let err {
                    print("[MacScreen] sendControl err: \(err.localizedDescription)")
                }
            }
        }
    }

    // MARK: WebSocket

    private var wsURL: URL? {
        var scheme = "ws"
        if apiBase.hasPrefix("https://") { scheme = "wss" }
        let host = apiBase
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(scheme)://\(host)/ws/screen/subscribe/\(userKey)")
    }

    private func connect() {
        // 已在连接中,不重复
        if subTask != nil {
            return
        }
        guard let url = wsURL else {
            print("[MacScreen] bad url, apiBase=\(apiBase)")
            return
        }
        print("[MacScreen] connecting \(url.absoluteString)")
        subTask = session.webSocketTask(with: url)
        subTask?.resume()
        receiveLoop()
    }

    private func scheduleReconnect() {
        reconnectAttempts += 1
        let delay = min(30.0, pow(2.0, Double(reconnectAttempts)))
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self.subTask = nil  // 清掉旧连接,connect 才能继续
            self.connect()
        }
    }

    private func receiveLoop() {
        subTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                print("[MacScreen] lost: \(err.localizedDescription)")
                Task { @MainActor in
                    self.connected = false
                    self.macOnline = false
                    self.scheduleReconnect()
                }

            case .success(let msg):
                Task { @MainActor in
                    self.reconnectAttempts = 0
                    self.connected = true
                }
                if case .string(let s) = msg {
                    self.handleMessage(s)
                }
                self.receiveLoop()
            }
        }
    }

    private func handleMessage(_ json: String) {
        guard let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return
        }
        let type = (obj["type"] as? String) ?? ""

        switch type {
        case "frame":
            guard let b64 = obj["data"] as? String,
                  let frameData = Data(base64Encoded: b64) else { return }
            onFrame?(frameData)
            if let img = UIImage(data: frameData) {
                Task { @MainActor in self.latestImage = img }
            }

        case "status":
            let online = (obj["mac_online"] as? Bool) ?? false
            Task { @MainActor in self.macOnline = online }

        case "control_result":
            if let payload = obj["payload"] as? [String: Any] {
                print("[MacScreen] control result: \(payload)")
            }

        default:
            break
        }
    }
}

