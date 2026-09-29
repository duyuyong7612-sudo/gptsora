// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-9d0d5d03d8f48738693f43766a60212a6d4cb9c35d03d596399800a1292882d2"
// Source-SHA256: "0b63ee928f73f36aeecd9962126a4eb0a9758b4e5947477714d390a0f14a85b9"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation
import Combine
import ObjectiveC


extension Notification.Name {
    static let screenAgentRealtimeConnected = Notification.Name("screenAgentRealtimeConnected")
    static let screenAgentRealtimeDisconnected = Notification.Name("screenAgentRealtimeDisconnected")
    static let screenAgentRealtimeStatus = Notification.Name("screenAgentRealtimeStatus")
    static let screenAgentRealtimeUserTranscript = Notification.Name("screenAgentRealtimeUserTranscript")
    static let screenAgentRealtimeAssistantPartial = Notification.Name("screenAgentRealtimeAssistantPartial")
    static let screenAgentRealtimeAssistantFinal = Notification.Name("screenAgentRealtimeAssistantFinal")
}


@MainActor
final class RealtimeBridge: NSObject, ObservableObject, RealtimeAVServiceDelegate {

    /// Global shared instance (wired to the fast-lane bridge) so views can
    /// default to `.shared` without creating a second connection.
    static var shared: RealtimeBridge { RealtimeFastLane.shared.bridge }

    private let service: RealtimeAVService

    // UI state
    @Published var status: String = "未连接"
    @Published var isConnected: Bool = false
    @Published var isMuted: Bool = false

    @Published var lastUser: String = ""
    @Published var assistantLive: String = ""
    @Published var lastAssistantFinal: String = ""

    // ✅ 会话上下文（决定后端 /session 是否切到 home-only）
    @Published var sessionProfile: String = "default"     // "home" / "default" / "remix" ...
    @Published var sessionClientId: String = ""        // 用于绑定匹配（强烈建议传）

    // ✅ 记忆+感知联通：与文本助手共享 conversation_id 和感知快照
    var sessionConversationId: String = ""
    var perceptionSnapshot: [String: Any]? = nil

    // ✅ Debug：最近一次解析到的 HOME_CMD
    @Published var lastHomeCmd: String = ""

    var onUserTranscript: ((String) -> Void)?
    var onAssistantPartial: ((String) -> Void)?
    var onAssistantFinal: ((String) -> Void)?
    var onError: ((String) -> Void)?

    // ✅ 去重：避免 partial/final 或重复 delta 连续触发同一个命令
    private var lastHomeCmdSig: String = ""
    private var lastHomeCmdTS: TimeInterval = 0
    private let semanticInterruptToken = "__SEMANTIC_INTERRUPT__"

    init(service: RealtimeAVService) {
        self.service = service
        super.init()
        self.service.delegate = self
    }

    // MARK: - Config

    /// ✅ 把 client_id + profile 写到 service（用于 /session 带上）
    func configure(apiBase: String, profile: String = "default", clientId: String? = nil) {
        let base = normalizeBase(apiBase)
        service.apiBase = base

        sessionProfile = profile.trimmingCharacters(in: .whitespacesAndNewlines)

        if let cid = clientId?.trimmingCharacters(in: .whitespacesAndNewlines), !cid.isEmpty {
            sessionClientId = cid
        } else if sessionClientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sessionClientId = loadOrCreateClientId()
        }

        // ✅ 写入 service（这两个属性由下面 extension 提供，保证编译通过）
        service.haSessionProfile = sessionProfile
        service.haSessionClientId = sessionClientId

        // ✅ 兼容旧 demo / bridge 检查（可留）
        service.sessionProfileCompat = sessionProfile
        service.sessionClientIdCompat = sessionClientId
    }

    // MARK: - Start/Stop

    func startAudio() {
        status = "连接中…"
        ensureMetaBeforeStart()
        service.start(mode: .audioOnly)
    }

    func startAV() {
        status = "连接中…"
        ensureMetaBeforeStart()
        service.start(mode: .audioVideo)
    }

    /// ✅ 明确进入“家居助手”
    func startHomeAudio(clientId: String? = nil) {
        sessionProfile = "home"
        if let c = clientId?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty {
            sessionClientId = c
        }
        startAudio()
    }

    func stop() {
        service.stop()
    }

    func interruptResponse() {
        status = "已打断"
        service.interruptResponse()
    }

    func toggleMute() {
        service.toggleMute()
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        service.setMuted(muted)
    }

    func sendCameraFrameJPEG(_ data: Data) {
        service.injectImageData(data, mime: "image/jpeg")
    }

    // ✅ 让 UI 调 service 的“图片流”策略
    func setImageStreamingEnabled(_ enabled: Bool) {
        service.setImageStreamingEnabled(enabled)
    }

    func setImageStreamingFPS(_ fps: Double) {
        service.setImageStreamingFPS(fps)
    }

    // MARK: - ✅ Direct test (绕过 Realtime，直接打 /home/dispatch)

    func testLightOffDirect() {
        Task { await dispatchHomeCmd("light_off") }
    }

    func testLightOnDirect() {
        Task { await dispatchHomeCmd("light_on") }
    }

    // MARK: - Delegate

    func realtimeAVServiceDidConnect(_ svc: RealtimeAVService) {
        isConnected = true
        status = "已连接"
        NotificationCenter.default.post(name: .screenAgentRealtimeConnected, object: nil)
        NotificationCenter.default.post(name: .screenAgentRealtimeStatus, object: nil, userInfo: ["text": status])
    }

    func realtimeAVServiceDidDisconnect(_ svc: RealtimeAVService) {
        isConnected = false
        status = "已断开"
        assistantLive = ""
        NotificationCenter.default.post(name: .screenAgentRealtimeDisconnected, object: nil)
        NotificationCenter.default.post(name: .screenAgentRealtimeStatus, object: nil, userInfo: ["text": status])
    }

    func realtimeAVService(_ svc: RealtimeAVService, didUpdateStatus text: String) {
        status = text
        NotificationCenter.default.post(name: .screenAgentRealtimeStatus, object: nil, userInfo: ["text": text])
    }

    func realtimeAVService(_ svc: RealtimeAVService, didReceiveUserTranscript text: String) {
        lastUser = text
        NotificationCenter.default.post(name: .screenAgentRealtimeUserTranscript, object: nil, userInfo: ["text": text])
        onUserTranscript?(text)
    }

    func realtimeAVService(_ svc: RealtimeAVService, didReceiveAssistantText text: String, isFinal: Bool) {
        let visibleText = stripHiddenControlCommands(from: text)
        guard !visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        assistantLive = visibleText

        // ✅ 核心：抓 HOME_CMD 并触发控灯
        maybeHandleHomeCmd(from: visibleText)

        if isFinal {
            lastAssistantFinal = visibleText
            NotificationCenter.default.post(name: .screenAgentRealtimeAssistantFinal, object: nil, userInfo: ["text": visibleText])
            onAssistantFinal?(visibleText)
        } else {
            NotificationCenter.default.post(name: .screenAgentRealtimeAssistantPartial, object: nil, userInfo: ["text": visibleText])
            onAssistantPartial?(visibleText)
        }
    }

    private func stripHiddenControlCommands(from text: String) -> String {
        guard text.contains(semanticInterruptToken) else { return text }
        print("[SemanticInterruptDiag][bridge] hidden token stripped before UI")
        NotificationCenter.default.post(name: .aduRealtimeSemanticInterrupt, object: nil, userInfo: ["token": semanticInterruptToken])
        guard let r = text.range(of: semanticInterruptToken) else { return text }
        var rest = String(text[r.upperBound...])
        if let nl = rest.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            rest = String(rest[rest.index(after: nl)...])
        } else {
            rest = ""
        }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func realtimeAVService(_ svc: RealtimeAVService, didFail error: Error) {
        onError?(error.localizedDescription)
        status = "错误：\(error.localizedDescription)"
    }

    // MARK: - ✅ HOME_CMD parse + dispatch

    private func maybeHandleHomeCmd(from text: String) {
        guard text.contains("HOME_CMD") else { return }
        guard let json = extractHomeCmdJSON(from: text) else { return }

        // 解析 cmd
        guard
            let data = json.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let cmd = obj["cmd"] as? String,
            !cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        lastHomeCmd = cmd

        // 去重：同一个 cmd + clientId 在短时间内只触发一次
        let now = Date().timeIntervalSince1970
        let sig = "\(cmd)|\(sessionClientId)"
        if sig == lastHomeCmdSig, (now - lastHomeCmdTS) < 1.2 {
            return
        }
        lastHomeCmdSig = sig
        lastHomeCmdTS = now

        Task { await dispatchHomeCmd(cmd) }
    }

    private func extractHomeCmdJSON(from text: String) -> String? {
        // 支持：HOME_CMD: {"cmd":"light_off"}  （可能在长文本中间）
        let pattern = #"HOME_CMD:\s*(\{[\s\S]*?\})"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)

        // 取“最后一个匹配”（避免 earlier partial 的旧命令）
        let matches = re.matches(in: text, options: [], range: range)
        guard let m = matches.last, m.numberOfRanges >= 2 else { return nil }
        guard let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private func dispatchHomeCmd(_ cmd: String) async {
        // 兜底：确保 meta 有值
        if sessionClientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sessionClientId = loadOrCreateClientId()
        }

        let base = service.apiBase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, let url = URL(string: "\(base)/home/dispatch") else {
            status = "dispatch失败：apiBase 为空/非法"
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "cmd": cmd,
            "client_id": sessionClientId
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let text = String(data: data, encoding: .utf8) ?? ""
            status = "HOME dispatch \(cmd) -> \(code) \(text)"
        } catch {
            status = "HOME dispatch异常：\(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    private func ensureMetaBeforeStart() {
        let p = sessionProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.isEmpty { sessionProfile = p }

        if sessionClientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sessionClientId = loadOrCreateClientId()
        }

        service.haSessionProfile = sessionProfile
        service.haSessionClientId = sessionClientId

        // legacy compat
        service.sessionProfileCompat = sessionProfile
        service.sessionClientIdCompat = sessionClientId

        // ✅ 记忆联通：注入 conversation_id（与文本助手共享同一对话）
        service.sessionConversationId = sessionConversationId

        // ✅ 感知联通：注入最新感知快照（位置/运动等）。
        // 优先用外部显式传入；若没有，兜底从 AduPerceptionManager 读取，避免位置被语义打断补丁覆盖后丢失。
        if let snap = perceptionSnapshot, !snap.isEmpty {
            service.lastPerceptionSnapshot = snap
            print("[SemanticInterruptDiag][bridge] perception injected from bridge keys=\(Array(snap.keys).sorted())")
        } else if let snap = AduPerceptionManager.shared.lastSnapshot,
                  let d = try? JSONEncoder().encode(snap),
                  let dict = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  !dict.isEmpty {
            service.lastPerceptionSnapshot = dict
            print("[SemanticInterruptDiag][bridge] perception injected from manager keys=\(Array(dict.keys).sorted())")
        } else {
            print("[SemanticInterruptDiag][bridge] perception missing at configure")
        }
    }

    private func normalizeBase(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return s }
        let lower = s.lowercased()
        if !(lower.hasPrefix("http://") || lower.hasPrefix("https://")) {
            s = "http://" + s
        }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// ✅ 统一用 ClientIdentity，保证语音和文本聊天 user_key 一致，记忆共享
    private func loadOrCreateClientId() -> String {
        return ClientIdentity.shared.clientId
    }
}

// =======================================================
// ✅ Bridge <-> Service meta storage (ObjC associated objects)
// IMPORTANT: keep ONLY ONE copy of this extension in whole project.
// =======================================================

extension RealtimeAVService {

    private struct AssocKeys {
        static var haProfile: UInt8 = 0
        static var haClientId: UInt8 = 0
    }

    /// ✅ 你 Bridge 在用的字段名（保证 RealtimeBridge.swift 编译通过）
    var haSessionProfile: String {
        get { (objc_getAssociatedObject(self, &AssocKeys.haProfile) as? String) ?? "" }
        set { objc_setAssociatedObject(self, &AssocKeys.haProfile, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    var haSessionClientId: String {
        get { (objc_getAssociatedObject(self, &AssocKeys.haClientId) as? String) ?? "" }
        set { objc_setAssociatedObject(self, &AssocKeys.haClientId, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    // ✅ 兼容旧命名（如果你工程里还有用 sessionProfileCompat / sessionClientIdCompat）
    var sessionProfileCompat: String {
        get { haSessionProfile }
        set { haSessionProfile = newValue }
    }

    var sessionClientIdCompat: String {
        get { haSessionClientId }
        set { haSessionClientId = newValue }
    }
}






