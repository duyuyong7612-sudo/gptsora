// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-e214c524e7f111bd1f83f95c6de2bc9e6e05d2726b0eff6ceb4669eccb736555"
// Source-SHA256: "7f25491fc17a43496b19b2ab6b1e036c3d407b37624d2b446e802cd988476c63"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation
import Combine

// MARK: - Adu Context Timeline
//
// 一个跨视图的"统一上下文时间线":
//   - HomeChatView 底部主输入框
//   - 电脑控制上半部分"电脑任务输入"
//   - 小麦克风转写
//   - 黑色实时语音
//   - + 按钮上传附件
//   - planner / computer_action / codex / health / self_upgrade 工具输出
// 全部写到同一个 store。
//
// 设计原则:
//   - 完整 stdout / stderr 不要进时间线(只进自动化编程卡片);时间线只放"摘要"。
//   - recentSummary() 用来塞进 /chat/prepare 上下文 + 实时语音 perception snapshot,
//     让普通聊天和实时语音助手都知道"刚才工具发生了什么"。
//   - 单一 store,通过 @StateObject 在 HomeChatView 创建,再以参数下传给
//     ComputerControlHomeView / EngineeringAgentPanel —— 后两者用 @ObservedObject 持有。
//   - 所有写入都在 MainActor,因为多个 UI 路径都会触发 append。

public enum AduTimelineSource: String, Codable, Equatable {
    case home_chat_input
    case computer_task_input
    case voice_mic
    case realtime_voice
    case attachment
    case planner
    case computer_action
    case codex
    case claude
    case file_search
    case health
    case self_upgrade
    case system
}

public enum AduTimelineKind: String, Codable, Equatable {
    case user_message
    case planner_decision
    case task_created
    case task_started
    case tool_result
    case tool_error
    case assistant_summary
    case status_update
    case confirmation_required
}

// MARK: - V3 self-upgrade → Codex 桥
//
// 当用户在自我升级计划卡上点"生成 Codex 任务"时,iOS 会:
//   1) 把 upgrade.codex_prompt 填进 EngineeringAgentPanel.taskText
//   2) 把这个 attachment 写到 store(下面的 pendingSelfUpgradeAttachment)
// EngineeringAgentPanel 跑完 Codex 后,会 consume() 这个 attachment,
// 决定要不要 POST /api/adu/self/evolution-memory 写一条经验。
// 用户如果中间手动改了 task / 跑了别的任务,后果就是 attachment 被一并消费,
// 我们仍按"它来自 self_upgrade"记录 —— 这正是想要的行为(用户基于推荐项做了调整也算)。
public struct PendingSelfUpgradeAttachment: Equatable {
    public let upgradeId: String
    public let title: String
    public let projectId: String?
    public let riskLevel: String
    public let suggestedMode: String
    public let verificationCommand: String?    // 第一条 verification_step.command,留作 memory.verification
    // V2 闭环:跟踪 self-upgrade session,Codex 完成后回传 /sessions/{id}/codex-result。
    // nil 表示走 legacy 直接写 /evolution-memory 的路径(向后兼容)。
    public let sessionId: String?
    public let attachedAt: Date

    public init(upgradeId: String, title: String, projectId: String?,
                riskLevel: String, suggestedMode: String,
                verificationCommand: String? = nil,
                sessionId: String? = nil,
                attachedAt: Date = Date()) {
        self.upgradeId = upgradeId
        self.title = title
        self.projectId = projectId
        self.riskLevel = riskLevel
        self.suggestedMode = suggestedMode
        self.verificationCommand = verificationCommand
        self.sessionId = sessionId
        self.attachedAt = attachedAt
    }
}

public struct SelfUpgradeNextRecommendationSnapshot: Equatable {
    public let id: String?
    public let title: String
    public let reason: String
    public let suggestedMode: String?
    public let riskLevel: String?
    public let projectId: String?
    public let score: Int?
    public let generatedAt: Date

    public init(id: String?, title: String, reason: String,
                suggestedMode: String?, riskLevel: String?,
                projectId: String?, score: Int?,
                generatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.reason = reason
        self.suggestedMode = suggestedMode
        self.riskLevel = riskLevel
        self.projectId = projectId
        self.score = score
        self.generatedAt = generatedAt
    }
}

public struct SelfUpgradeVerificationStepSnapshot: Equatable, Identifiable {
    public let tool: String
    public let command: String
    public let description: String?

    public var id: String { tool + "::" + command }

    public init(tool: String, command: String, description: String?) {
        self.tool = tool
        self.command = command
        self.description = description
    }
}

public struct AduTimelineEvent: Identifiable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let source: AduTimelineSource
    public let kind: AduTimelineKind
    public let content: String           // 完整一句话(人类可读)
    public let summary: String?          // 给 recentSummary 用的压缩版;nil 表示直接复用 content
    public let metadata: [String: String]

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        source: AduTimelineSource,
        kind: AduTimelineKind,
        content: String,
        summary: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.kind = kind
        self.content = content
        self.summary = summary
        self.metadata = metadata
    }

    var displayLine: String {
        summary ?? content
    }
}

@MainActor
public final class AduContextStore: ObservableObject {

    // 时间线本身(最旧在前,最新在后)。
    @Published public private(set) var events: [AduTimelineEvent] = []

    // 当前是否有"来自 self-upgrade 计划"的 Codex 任务挂着。
    // 由 ComputerControlHomeView.adoptSelfUpgradeIntoCodexPanel(...) 写,
    // 由 EngineeringAgentPanel.runCodex 完成后 consume(读取并清空)。
    @Published public var pendingSelfUpgradeAttachment: PendingSelfUpgradeAttachment? = nil

    // V2.2:主输入栏(HomeChatView.onSendOrStop)识别到自我升级触发短语时,
    // 把原始 goal 写到这里 + 切 surfaceMode=.computer。
    // ComputerControlHomeView 的 .onChange 监听这个值,调 runSelfUpgradePlan(... surface:"home_chat")
    // 然后立即清空,避免重复触发。
    @Published public var pendingSelfUpgradeGoal: String? = nil
    @Published public var latestSelfUpgradeNextRecommendation: SelfUpgradeNextRecommendationSnapshot? = nil
    @Published public var latestSelfUpgradeVerificationSteps: [SelfUpgradeVerificationStepSnapshot] = []

    public func setSelfUpgradeAttachment(_ a: PendingSelfUpgradeAttachment) {
        pendingSelfUpgradeAttachment = a
    }

    public func consumeSelfUpgradeAttachment() -> PendingSelfUpgradeAttachment? {
        let a = pendingSelfUpgradeAttachment
        pendingSelfUpgradeAttachment = nil
        return a
    }

    public func markSelfUpgradeRunning(sessionId: String, upgradeId: String, title: String) {
        append(AduTimelineEvent(
            source: .self_upgrade,
            kind: .status_update,
            content: "自我升级任务正在执行: \(title)",
            summary: "self_upgrade: 自我升级任务正在执行",
            metadata: [
                "session_id": sessionId,
                "upgrade_id": upgradeId,
                "stage": "running",
            ]
        ))
    }

    public func setSelfUpgradeReport(nextRecommendation: SelfUpgradeNextRecommendationSnapshot?,
                                     verificationSteps: [SelfUpgradeVerificationStepSnapshot]) {
        latestSelfUpgradeNextRecommendation = nextRecommendation
        latestSelfUpgradeVerificationSteps = verificationSteps
    }

    // 上限,避免无限增长(超过就裁掉最早的)。
    public var maxEvents: Int = 300

    public init() {}

    // MARK: append

    public func append(_ event: AduTimelineEvent) {
        events.append(event)
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
    }

    // 便捷封装。所有外部点应该尽量用下面这些方法,而不是手搓 AduTimelineEvent。

    public func appendUserMessage(_ text: String, source: AduTimelineSource, metadata: [String: String] = [:]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        append(AduTimelineEvent(
            source: source, kind: .user_message,
            content: trimmed,
            summary: trimmed.count <= 80 ? trimmed : (String(trimmed.prefix(80)) + "…"),
            metadata: metadata
        ))
    }

    public func appendPlannerDecision(intent: String, confidence: Double,
                                      projectId: String?, project: String?,
                                      executor: String, riskLevel: String,
                                      needsConfirmation: Bool, nextAction: String,
                                      originalInput: String) {
        var pieces: [String] = ["intent=\(intent)", String(format: "conf=%.2f", confidence)]
        if let pid = projectId, !pid.isEmpty { pieces.append("project_id=\(pid)") }
        if !executor.isEmpty, executor != "none" { pieces.append("executor=\(executor)") }
        if !riskLevel.isEmpty, riskLevel != "low" { pieces.append("risk=\(riskLevel)") }
        if needsConfirmation { pieces.append("needs_confirmation") }
        let summary = "planner: " + pieces.joined(separator: " ")
        var meta: [String: String] = [
            "intent": intent,
            "confidence": String(format: "%.2f", confidence),
            "executor": executor,
            "risk_level": riskLevel,
            "needs_confirmation": needsConfirmation ? "true" : "false",
            "next_action": nextAction,
            "original_input": originalInput,
        ]
        if let pid = projectId { meta["project_id"] = pid }
        if let p = project { meta["project"] = p }
        append(AduTimelineEvent(
            source: .planner, kind: .planner_decision,
            content: summary, summary: summary, metadata: meta
        ))
    }

    public func appendComputerActionStarted(goal: String) {
        append(AduTimelineEvent(
            source: .computer_action, kind: .task_started,
            content: "computer_action 开始:\(goal)",
            summary: "computer_action: 执行 \(goal)",
            metadata: ["goal": goal]
        ))
    }

    public func appendComputerActionResult(goal: String, ok: Bool,
                                            message: String,
                                            metadata extra: [String: String] = [:]) {
        var meta = extra
        meta["goal"] = goal
        meta["ok"] = ok ? "true" : "false"
        if ok {
            append(AduTimelineEvent(
                source: .computer_action, kind: .tool_result,
                content: "已执行电脑动作:\(goal) " + (message.isEmpty ? "" : "(\(message))"),
                summary: "computer_action ok: \(goal)",
                metadata: meta
            ))
        } else {
            append(AduTimelineEvent(
                source: .computer_action, kind: .tool_error,
                content: "电脑动作失败:\(goal) — \(message)",
                summary: "computer_action FAILED: \(goal) — \(message)",
                metadata: meta
            ))
        }
    }

    public func appendCodexStarted(task: String, projectId: String?, projectDir: String?, timeout: Int) {
        var meta: [String: String] = ["task_head": String(task.prefix(120)), "timeout": "\(timeout)"]
        if let pid = projectId { meta["project_id"] = pid }
        if let pdir = projectDir { meta["project_dir"] = pdir }
        let where_ = projectId.map { "project_id=\($0)" } ?? (projectDir ?? "")
        append(AduTimelineEvent(
            source: .codex, kind: .task_started,
            content: "Codex 开始执行任务 (\(where_))",
            summary: "codex: 开始任务 \(where_)",
            metadata: meta
        ))
    }

    public func appendCodexStatus(_ message: String, metadata: [String: String] = [:]) {
        append(AduTimelineEvent(
            source: .codex, kind: .status_update,
            content: "Codex: \(message)",
            summary: "codex: \(message)",
            metadata: metadata
        ))
    }

    public func appendCodexSuccess(exitCode: Int?, durationSec: Double?,
                                   projectId: String?, summaryLine: String?) {
        var pieces: [String] = []
        if let e = exitCode { pieces.append("exit=\(e)") }
        if let d = durationSec { pieces.append(String(format: "用时 %.1f 秒", d)) }
        if let pid = projectId, !pid.isEmpty { pieces.append("project=\(pid)") }
        let line = "Codex 已完成" + (pieces.isEmpty ? "" : " (" + pieces.joined(separator: ", ") + ")")
        var meta: [String: String] = [:]
        if let e = exitCode { meta["exit_code"] = "\(e)" }
        if let d = durationSec { meta["duration_sec"] = String(format: "%.2f", d) }
        if let pid = projectId { meta["project_id"] = pid }
        append(AduTimelineEvent(
            source: .codex, kind: .tool_result,
            content: line + (summaryLine.map { ":\n" + $0 } ?? ""),
            summary: line,
            metadata: meta
        ))
    }

    public func appendCodexFailure(error: String?, message: String?, blockedTerms: [String],
                                    needsConfirmation: Bool, httpStatus: Int, projectId: String?) {
        var pieces: [String] = []
        if let e = error, !e.isEmpty { pieces.append(e) }
        if needsConfirmation { pieces.append("needs_user_confirmation") }
        if !blockedTerms.isEmpty { pieces.append("blocked: " + blockedTerms.joined(separator: ", ")) }
        if pieces.isEmpty, httpStatus > 0 { pieces.append("HTTP \(httpStatus)") }
        let line = "Codex 失败" + (pieces.isEmpty ? "" : " (" + pieces.joined(separator: " | ") + ")")
        var meta: [String: String] = [
            "http_status": "\(httpStatus)",
            "needs_confirmation": needsConfirmation ? "true" : "false",
        ]
        if let e = error { meta["error"] = e }
        if let m = message { meta["message_head"] = String(m.prefix(180)) }
        if !blockedTerms.isEmpty { meta["blocked_terms"] = blockedTerms.joined(separator: ",") }
        if let pid = projectId { meta["project_id"] = pid }
        append(AduTimelineEvent(
            source: .codex,
            kind: needsConfirmation ? .confirmation_required : .tool_error,
            content: line + (message.map { ":\n" + $0 } ?? ""),
            summary: line,
            metadata: meta
        ))
    }

    public func appendHealth(ok: Bool, line: String, version: String?, error: String?) {
        var meta: [String: String] = ["ok": ok ? "true" : "false"]
        if let v = version { meta["version"] = v }
        if let e = error { meta["error"] = e }
        append(AduTimelineEvent(
            source: .health,
            kind: ok ? .status_update : .tool_error,
            content: "Codex Health: " + line,
            summary: "health: " + line,
            metadata: meta
        ))
    }

    public func appendSelfUpgradePlan(summary: String, riskLevel: String) {
        append(AduTimelineEvent(
            source: .self_upgrade, kind: .assistant_summary,
            content: "自我升级计划已生成。风险=\(riskLevel)。摘要:" + summary,
            summary: "self_upgrade: 已生成计划 (risk=\(riskLevel))",
            metadata: ["risk_level": riskLevel]
        ))
    }

    public func appendFileSearchResult(query: String, hitCount: Int, sampleHits: [String]) {
        var meta: [String: String] = ["query": query, "hit_count": "\(hitCount)"]
        if !sampleHits.isEmpty {
            meta["sample_hits"] = sampleHits.prefix(5).joined(separator: " | ")
        }
        append(AduTimelineEvent(
            source: .file_search,
            kind: hitCount > 0 ? .tool_result : .status_update,
            content: "file_search '\(query)' → \(hitCount) 命中",
            summary: "file_search '\(query)' → \(hitCount) 命中",
            metadata: meta
        ))
    }

    public func appendSystem(_ text: String, kind: AduTimelineKind = .status_update) {
        append(AduTimelineEvent(source: .system, kind: kind, content: text, summary: text))
    }

    public func clearAll() {
        events.removeAll()
    }

    // MARK: 查询

    public func recent(limit: Int = 20) -> [AduTimelineEvent] {
        if events.count <= limit { return events }
        return Array(events.suffix(limit))
    }

    // 给主聊天 / 实时语音注入的"压缩摘要"。
    // 控制长度,保证不会爆 token。
    public func recentSummary(limit: Int = 12) -> String {
        let lines: [String] = recent(limit: limit).map { e in
            let ts = AduContextStore.shortTime(e.timestamp)
            return "[\(ts)] \(e.source.rawValue)/\(e.kind.rawValue): \(e.displayLine)"
        }
        var body: [String] = []
        body.append("[阿杜上下文 · 最近 \(lines.count) 条]")
        if lines.isEmpty {
            body.append("(暂无事件)")
        } else {
            body.append(contentsOf: lines)
        }
        body.append("---")
        body.append("pending Codex 任务: " + (pendingCodexHint ?? "无"))
        body.append("最近 Codex: " + (lastCodexStatusLine ?? "无"))
        body.append("最近电脑动作: " + (lastComputerActionLine ?? "无"))
        body.append("最近 planner 判断: " + (lastPlannerDecisionLine ?? "无"))
        body.append("最近错误: " + (lastErrorLine ?? "无"))
        return body.joined(separator: "\n")
    }

    // MARK: 派生

    public var lastCodexStatusLine: String? {
        for e in events.reversed() where e.source == .codex {
            return e.displayLine
        }
        return nil
    }

    public var pendingCodexHint: String? {
        // 取最近一次 task_started 是否被后续 tool_result / tool_error 终结。
        var started: AduTimelineEvent? = nil
        for e in events {
            if e.source == .codex && e.kind == .task_started { started = e }
            if e.source == .codex && (e.kind == .tool_result || e.kind == .tool_error) { started = nil }
        }
        return started?.displayLine
    }

    public var lastComputerActionLine: String? {
        for e in events.reversed() where e.source == .computer_action {
            return e.displayLine
        }
        return nil
    }

    public var lastPlannerDecisionLine: String? {
        for e in events.reversed() where e.source == .planner {
            return e.displayLine
        }
        return nil
    }

    public var lastErrorLine: String? {
        for e in events.reversed() where e.kind == .tool_error {
            return e.displayLine
        }
        return nil
    }

    // MARK: helpers

    private static let _timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    public static func shortTime(_ d: Date) -> String {
        return _timeFmt.string(from: d)
    }
}
