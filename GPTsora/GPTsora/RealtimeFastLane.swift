// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-9951d7993fc2650a6c486b3a725d6d0c4e87f5ccc9975c9c33cb84b1727a646a"
// Source-SHA256: "638826d066feb33e31ff43bbdb3535a27cad221d20b27aadc9beefd71219bf39"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation
import Combine

/// ✅ 全局“极速通话通道”
/// 目标：把所有助手的 Realtime 接入速度统一到你那版“纯语音控制”一样快：
/// - 复用同一个 RealtimeAVService.shared + RealtimeBridge（避免每页重建 WebRTC）
/// - 先 startAudio 立即接通；耗时 prework 并行做
/// - 过滤无害错误（Cancellation failed; no active response found）避免误断线
/// - 仅对连接类错误轻量重连（不影响首次接入速度）
@MainActor
final class RealtimeFastLane: ObservableObject {

    static let shared = RealtimeFastLane()

    /// 你项目里现有的 RealtimeBridge（WebRTC + 回调）
    let bridge: RealtimeBridge

    @Published private(set) var isListening: Bool = false
    @Published private(set) var lastError: String? = nil

    private var desiredListening: Bool = false
    private var reconnectTask: Task<Void, Never>? = nil
    private var reconnectAttempts: Int = 0

    private var currentApiBase: String = ""

    // user callbacks (so we can filter before forwarding)
    private var userOnError: ((String) -> Void)?

    private init() {
        self.bridge = RealtimeBridge(service: RealtimeAVService.shared)

        // 统一接管 onError：先过滤/分类，再转发给 UI
        bridge.onError = { [weak self] err in
            Task { @MainActor in
                self?.handleError(err)
            }
        }
    }

    // MARK: - Public API

    func setOnError(_ handler: @escaping (String) -> Void) {
        self.userOnError = handler
    }

    /// 只配置，不启动（用于页面 onAppear 预热）
    func configure(apiBase: String, clientId: String? = nil) {
        let base = apiBase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return }
        if currentApiBase != base {
            currentApiBase = base
        }
        // ✅ 每次都传 clientId，保证语音和文本 user_key 一致
        let cid = clientId ?? ClientIdentity.shared.clientId
        bridge.configure(apiBase: base, clientId: cid)
    }

    /// ✅ 秒连接预热：仅请求 /session 并缓存（不打开麦克风、不建立 WebRTC）。
    /// 建议在首页/聊天页 onAppear 调用一次即可。
    func prime(apiBase: String = AppConfig.API.apiBase) {
        configure(apiBase: apiBase)
        RealtimeAVService.shared.prewarmSession(apiBase: currentApiBase.isEmpty ? apiBase : currentApiBase, mode: .audioOnly)
    }

    /// ✅ 极速接通（保证“秒接”体验）：必要时才 startAudio
    func ensureConnected(apiBase: String = AppConfig.API.apiBase) {
        desiredListening = true
        configure(apiBase: apiBase, clientId: ClientIdentity.shared.clientId)

        if !bridge.isConnected {
            bridge.startAudio()
        }
        isListening = true
    }

    func stop() {
        desiredListening = false
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempts = 0

        bridge.stop()
        isListening = false
    }

    /// 切助手：不重连，只发 session.update（如果你的 RealtimeBridge 支持）
    func switchProfile(_ profile: String) {
        // ✅ 可选：如果你的 RealtimeBridge 支持在同一条会话里切“助手配置”（session.update / instructions / tools），
        // 可以在这里调用。
        //
        // 例如：
        // bridge.updateProfile(profile)
        //
        // 这份 FastLane 默认不强依赖该能力（先保证“极速接通 + 不掉线”）。
    }

    // MARK: - Error handling

    private func handleError(_ err: String) {
        let t = err.lowercased()

        // ✅ 必杀：这是“重复 cancel / 当前无 active response”，无害，不要断线/不要 toast
        if t.contains("cancellation failed") || t.contains("no active response found") {
            return
        }

        lastError = err
        userOnError?(err)

        guard desiredListening else { return }

        // 仅对连接类错误重连（不会牺牲接入实时性，只在断线后触发）
        if isTransportFatal(t) {
            scheduleReconnect()
        }
    }

    private func isTransportFatal(_ t: String) -> Bool {
        return t.contains("webrtc")
        || t.contains("ice")
        || t.contains("peerconnection")
        || t.contains("datachannel")
        || t.contains("disconnected")
        || t.contains("connection lost")
        || t.contains("closed")
        || t.contains("network")
        || t.contains("socket")
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectAttempts += 1

        // 0.25 / 0.5 / 1 / 2 秒
        if reconnectAttempts > 4 {
            stop()
            return
        }

        let base: Double = 0.25
        let delay = min(base * pow(2.0, Double(reconnectAttempts - 1)), 2.0)
        let ns = UInt64(delay * 1_000_000_000)

        reconnectTask = Task { @MainActor in
            bridge.stop()
            try? await Task.sleep(nanoseconds: ns)
            guard desiredListening else { return }
            bridge.startAudio()
            isListening = true
        }
    }
}

private extension RealtimeBridge {
    /// 兼容：如果你项目里已经有发 session.update 的方法，把实现替换进去即可
    func updateProfileIfSupported(_ profile: String) {
        // e.g.
        // self.sendSessionUpdate(profile: profile)
    }
}







