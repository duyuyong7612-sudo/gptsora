// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-31a3919a03495fce6a53cb7dca05fd4c370d6903e50ef938dc094eb002f4e118"
// Source-SHA256: "8f3ea7416e12ec3b532467e5b2ba319f87e0621d22fd804071dc50d228081168"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation
import Combine

@MainActor
final class RemixFlowController: NSObject, ObservableObject, RealtimeQuickServiceDelegate {

    enum VoiceState { case idle, connecting, listening }

    // =========================
    // ✅ 协议统一（前后端一致）
    // =========================
    static let triggerPrefix1 = "REMIX:"   // ✅ 新标准
    static let triggerPrefix2 = "RMX:"     // 兼容旧
    static let triggerPrefix3 = "SORA:"    // 兜底（不推荐）

    // ✅ 你要求输出“客户己确定”
    static let confirmPhrasePrimary = "客户己确定"
    // 兼容旧写法（如果某些端还没换完）
    static let confirmPhraseCompat  = "客户已确定"

    static let confirmTagPrimary = "##CONFIRM=\(confirmPhrasePrimary)"
    static let confirmTagCompat  = "##CONFIRM=\(confirmPhraseCompat)"
    static let codeTagPrefix = "##CODE="

    // =========================

    @Published var voiceState: VoiceState = .idle

    let baseVideoId: String

    /// ✅ 语音最终得到“稳定改动指令(prompt)”回调（通常写入输入框；是否触发生成由你 UI 决定）
    var onAutoInstruction: ((String) -> Void)?

    /// ✅ 可选：如果你要把“完整触发行 + 用户确认文本”一起交给 UI/网络层（更稳）
    /// promptEN: 剥离协议后的英文 prompt
    /// triggerLine: 原始触发行（REMIX: ... ##CONFIRM=客户己确定）
    /// userConfirmText: 用户最后确认口令（来自用户语音/按钮）
    var onAutoConfirmed: ((String, String, String) -> Void)?

    private weak var previousDelegate: RealtimeQuickServiceDelegate?
    private var hasTriggered = false

    // ✅ 防助手提前确发：必须先检测到“用户最后确认口令”
    private var userConfirmed = false
    private var lastUserConfirmText: String = ""

    init(baseVideoId: String) {
        self.baseVideoId = baseVideoId.trimmingCharacters(in: .whitespacesAndNewlines)
        super.init()
    }

    // MARK: - Submit (Text -> Backend)
    // ⚠️ 你后端现在要求 user_confirm_text，VideoJobManager 这里也要同步升级：
    // - JSON 需包含: user_confirm_text = "客户己确定"
    // - 推荐同时发 assistant_line（触发行）以便后端二次校验
    func submitText(instruction: String) {
        let t = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseVideoId.isEmpty, !t.isEmpty else { return }

        // ✅ 旧接口（如果 VideoJobManager 还没升级，会只发 instruction）
        // VideoJobManager.shared.enqueueRemix(baseVideoId: baseVideoId, instruction: t)

        // ✅ 推荐：升级 VideoJobManager 支持把确认口令一并传给后端
        // VideoJobManager.shared.enqueueRemix(baseVideoId: baseVideoId,
        //                                     instruction: t,
        //                                     assistantLine: nil,
        //                                     userConfirmText: Self.confirmPhrasePrimary)

        VideoJobManager.shared.enqueueRemix(baseVideoId: baseVideoId, instruction: t)
    }

    // MARK: - Voice (Realtime)

    func toggleVoice() {
        if voiceState == .idle { startVoiceAuto() }
        else { stopVoice() }
    }

    func startVoiceAuto() {
        guard voiceState == .idle else { return }
        guard !baseVideoId.isEmpty else { return }

        hasTriggered = false
        userConfirmed = false
        lastUserConfirmText = ""

        previousDelegate = RealtimeQuickService.shared.delegate
        RealtimeQuickService.shared.delegate = self

        voiceState = .connecting
        RealtimeQuickService.shared.startRemixAssistantCall()
    }

    func stopVoice() {
        RealtimeQuickService.shared.stopCall()
        voiceState = .idle
        restoreDelegateIfNeeded()
    }

    private func restoreDelegateIfNeeded() {
        if RealtimeQuickService.shared.delegate === self {
            RealtimeQuickService.shared.delegate = previousDelegate
        }
        previousDelegate = nil
    }

    // MARK: - RealtimeQuickServiceDelegate

    func realtimeServiceDidConnect(_ svc: RealtimeQuickService) {
        voiceState = .listening
    }

    func realtimeServiceDidDisconnect(_ svc: RealtimeQuickService) {
        voiceState = .idle
        restoreDelegateIfNeeded()
    }

    func realtimeService(_ svc: RealtimeQuickService, didUpdateStatus text: String) { }

    func realtimeService(_ svc: RealtimeQuickService, didFailWith error: Error) {
        voiceState = .idle
        restoreDelegateIfNeeded()
    }

    func realtimeService(_ svc: RealtimeQuickService,
                         didTriggerSoraWithUserPrompt userPrompt: String,
                         assistantSummary: String) {
        // 兼容旧逻辑：但 Remix 现在应走 REMIX 触发行
    }

    /// ✅ 核心：从 transcript 里做“双保险”
    /// 1) 必须检测到用户最后说了“客户己确定”（或兼容“客户已确定”）
    /// 2) 助手触发行必须是 REMIX:/RMX: 且包含 ##CONFIRM=客户己确定
    /// 才允许触发 onAutoInstruction / onAutoConfirmed
    func realtimeService(_ svc: RealtimeQuickService, didUpdateTranscript text: String) {
        guard !hasTriggered else { return }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // ---------- 1) User transcript ----------
        if trimmed.hasPrefix("[U]") {
            let userText = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)

            if Self.userHasFinalConfirm(userText) {
                userConfirmed = true
                lastUserConfirmText = Self.extractUserConfirmText(userText)
            }
            return
        }

        // ---------- 2) Assistant transcript ----------
        guard trimmed.hasPrefix("[A]") else { return }
        let assistantText = String(trimmed.dropFirst(3))

        // 找触发行（整行）
        guard let triggerLine = Self.extractTriggerLine(from: assistantText) else { return }

        // 必须包含确认 tag（##CONFIRM=客户己确定 / 兼容旧）
        guard Self.triggerLineHasConfirmTag(triggerLine) else { return }

        // ✅ 最关键：必须用户也确认过（防止助手提前确发）
        guard userConfirmed else {
            // 没检测到用户确认，就算助手吐了触发行也直接忽略
            return
        }

        // 提取英文 prompt（剥离 REMIX:、##CONFIRM、##CODE）
        let promptEN = Self.extractPromptFromTriggerLine(triggerLine)
        guard !promptEN.isEmpty else { return }

        hasTriggered = true

        // ✅ 交给 UI：你可以写入输入框；也可以直接提交到后端
        onAutoInstruction?(promptEN)
        onAutoConfirmed?(promptEN, triggerLine, lastUserConfirmText)

        // 自动触发后立刻挂断，避免重复触发/叠加
        stopVoice()
    }

    // MARK: - Parsers

    /// ✅ 用户最终确认：建议“严格只认这句”，误判概率最低
    static func userHasFinalConfirm(_ userText: String) -> Bool {
        let s = (userText).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.contains(confirmPhrasePrimary) || s.contains(confirmPhraseCompat)
    }

    static func extractUserConfirmText(_ userText: String) -> String {
        // 如果用户说了确认码（例如“客户己确定 4821”）也保留原文，方便后端做 code 校验
        return userText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// ✅ 从 assistant 文本中提取触发行“整行”
    /// 优先 REMIX，其次 RMX，再兜底 SORA
    static func extractTriggerLine(from assistantText: String) -> String? {
        let normalized = assistantText.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        // 1) REMIX:
        if let line = lines.first(where: {
            $0.uppercased().hasPrefix("REMIX:") || $0.uppercased().hasPrefix("REMIX：")
        }) {
            return line
        }

        // 2) RMX:
        if let line = lines.first(where: {
            $0.uppercased().hasPrefix("RMX:") || $0.uppercased().hasPrefix("RMX：")
        }) {
            return line
        }

        // 3) SORA:（临时兜底）
        if let line = lines.first(where: {
            $0.uppercased().hasPrefix("SORA:") || $0.uppercased().hasPrefix("SORA：")
        }) {
            return line
        }

        return nil
    }

    /// ✅ 触发行必须带确认 tag（防误触发）
    static func triggerLineHasConfirmTag(_ line: String) -> Bool {
        return line.contains(confirmTagPrimary) || line.contains(confirmTagCompat)
    }

    /// ✅ 从触发行中提取纯英文 prompt（剥离协议字段）
    /// 支持：
    /// REMIX: <prompt> ##CONFIRM=客户己确定 ##CODE=1234
    static func extractPromptFromTriggerLine(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespacesAndNewlines)

        // 去掉前缀（REMIX/RMX/SORA）
        if s.uppercased().hasPrefix("REMIX:") || s.uppercased().hasPrefix("REMIX：") {
            s = String(s.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if s.uppercased().hasPrefix("RMX:") || s.uppercased().hasPrefix("RMX：") {
            s = String(s.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if s.uppercased().hasPrefix("SORA:") || s.uppercased().hasPrefix("SORA：") {
            s = String(s.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 截断协议字段
        if let r = s.range(of: "##CONFIRM=") {
            s = String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let r = s.range(of: "##CODE=") {
            s = String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 单行化
        s = s.replacingOccurrences(of: "\n", with: " ")
        s = s.replacingOccurrences(of: "\r", with: " ")
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

