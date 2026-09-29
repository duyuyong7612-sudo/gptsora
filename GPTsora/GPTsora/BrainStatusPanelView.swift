// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-2003d277b4fcfca0aaffdb2ccb26f940a406ce1751cf5984f605b3494c32c2f4"
// Source-SHA256: "da90e34b615d98edf7f9ba5305ee01ef086b4fbc44eadc6dbbb34bdc3ad612b6"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI
import Foundation

// MARK: - ChatAGI Left Brain Status Panel (No Auto Network Version)
// 说明：
// - 这个版本不会在页面一出现时自动访问 AppConfig.API.apiBase。
// - 只有用户点击“同步左脑 / 闪现一次 / 右脑观察”按钮时才会请求后端。
// - 用来避免 Xcode 调试器在 AppConfig.API.fixedBaseURLString 初始化处反复暂停。

struct BrainStatusPanelView: View {
    let clientId: String

    @State private var state: BrainConsciousnessState?
    @State private var todayMemory: [BrainMemoryItem] = []
    @State private var isLoading: Bool = false
    @State private var message: String? = "左脑模块已加载，点击同步开始连接后端"
    @State private var expanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    brainLine(icon: "person.crop.circle", title: "我是谁", value: state?.whoAmI ?? "ChatAGI，阿杜的长期 AI 大脑")
                    brainLine(icon: "scope", title: "当前任务", value: state?.currentTask ?? "等待左脑状态同步")
                    brainLine(icon: "eye", title: "当前环境", value: state?.currentEnvironment ?? "iPhone App + 后端 + local-agent")
                    brainLine(icon: "target", title: "今日目标", value: state?.todayGoal ?? "接通左右脑 MVP")
                    brainLine(icon: "infinity", title: "长期目标", value: state?.longTermGoal ?? "构建可迁移到机器人身体的 AI Brain")

                    if let next = state?.nextAction, !next.isEmpty {
                        brainLine(icon: "arrow.triangle.branch", title: "下一步", value: next)
                    }

                    HStack(spacing: 8) {
                        statusPill(
                            title: state?.tools?.localAgentConfigured == true ? "电脑身体在线" : "电脑身体待连接",
                            systemImage: state?.tools?.localAgentConfigured == true ? "desktopcomputer" : "desktopcomputer.trianglebadge.exclamationmark"
                        )
                        statusPill(title: "左脑闪现", systemImage: "brain.head.profile")
                        statusPill(title: "记忆时间线", systemImage: "clock.arrow.circlepath")
                    }

                    HStack(spacing: 10) {
                        Button {
                            Task { await refresh() }
                        } label: {
                            Label("同步左脑", systemImage: "arrow.clockwise")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .buttonStyle(.bordered)

                        Button {
                            Task { await flash() }
                        } label: {
                            Label("闪现一次", systemImage: "sparkles")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .buttonStyle(.bordered)

                        Button {
                            Task { await executeRightBrain(goal: "截图") }
                        } label: {
                            Label("右脑观察", systemImage: "eye.fill")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .buttonStyle(.bordered)

                        Spacer(minLength: 0)
                    }

                    if let message, !message.isEmpty {
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.8)
        )
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 15, weight: .semibold))
            Text("AI Brain Online")
                .font(.system(size: 14, weight: .semibold))
            Spacer(minLength: 0)
            if isLoading {
                ProgressView()
                    .scaleEffect(0.75)
            }
            Button {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
                    expanded.toggle()
                }
            } label: {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private func brainLine(icon: String, title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func statusPill(title: String, systemImage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
            Text(title)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule(style: .continuous).fill(Color.white.opacity(0.72)))
    }

    private var encodedClientId: String {
        clientId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? clientId
    }

    @MainActor
    private func refresh() async {
        let apiBase = AppConfig.API.apiBase
        guard let url = URL(string: "\(apiBase)/api/brain/consciousness/state?client_id=\(encodedClientId)") else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.timeoutInterval = 20
            req.setValue(clientId, forHTTPHeaderField: "X-Client-ID")
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(code) else { throw NSError(domain: "BrainStatus", code: code) }
            let decoded = try JSONDecoder().decode(BrainConsciousnessResponse.self, from: data)
            self.state = decoded.state
            self.todayMemory = decoded.todayMemory ?? []
            self.message = "左脑状态已同步"
        } catch {
            self.message = "左脑暂时未连接：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func flash() async {
        let apiBase = AppConfig.API.apiBase
        guard let url = URL(string: "\(apiBase)/api/brain/consciousness/flash") else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 20
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(clientId, forHTTPHeaderField: "X-Client-ID")
            let body: [String: Any] = [
                "client_id": clientId,
                "text": "用户正在使用 iPhone App 查看 AI Brain 当前意识。",
                "current_task": "运行左脑意识闪现面板",
                "environment": "iPhone App + server_session.py + local-agent",
                "today_goal": "完成左右脑 AI Brain MVP",
                "importance": 6
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(code) else { throw NSError(domain: "BrainFlash", code: code) }
            let decoded = try JSONDecoder().decode(BrainConsciousnessResponse.self, from: data)
            self.state = decoded.state
            self.todayMemory = decoded.todayMemory ?? self.todayMemory
            self.message = "左脑已完成一次意识闪现"
        } catch {
            self.message = "闪现失败：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func executeRightBrain(goal: String) async {
        let apiBase = AppConfig.API.apiBase
        guard let url = URL(string: "\(apiBase)/api/brain/right-brain/execute") else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 30
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(clientId, forHTTPHeaderField: "X-Client-ID")
            let body: [String: Any] = [
                "client_id": clientId,
                "goal": goal,
                "risk_level": 1
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(code) else { throw NSError(domain: "RightBrain", code: code) }
            self.message = "右脑已执行：\(goal)"
            await refresh()
        } catch {
            self.message = "右脑执行失败：\(error.localizedDescription)"
        }
    }
}

struct BrainConsciousnessResponse: Decodable {
    let ok: Bool
    let userKey: String?
    let state: BrainConsciousnessState?
    let todayMemory: [BrainMemoryItem]?

    enum CodingKeys: String, CodingKey {
        case ok
        case userKey = "user_key"
        case state
        case todayMemory = "today_memory"
    }
}

struct BrainConsciousnessState: Decodable {
    let whoAmI: String?
    let existenceMeaning: String?
    let currentEnvironment: String?
    let currentTask: String?
    let todayGoal: String?
    let longTermGoal: String?
    let currentCondition: String?
    let nextAction: String?
    let lastFlashAt: String?
    let tools: BrainTools?
    let rightBrainInstruction: BrainRightBrainInstruction?

    enum CodingKeys: String, CodingKey {
        case whoAmI = "who_am_i"
        case existenceMeaning = "existence_meaning"
        case currentEnvironment = "current_environment"
        case currentTask = "current_task"
        case todayGoal = "today_goal"
        case longTermGoal = "long_term_goal"
        case currentCondition = "current_condition"
        case nextAction = "next_action"
        case lastFlashAt = "last_flash_at"
        case tools
        case rightBrainInstruction = "right_brain_instruction"
    }
}

struct BrainTools: Decodable {
    let localAgentConfigured: Bool?
    let memoryTimeline: Bool?
    let brainStateEngine: Bool?

    enum CodingKeys: String, CodingKey {
        case localAgentConfigured = "local_agent_configured"
        case memoryTimeline = "memory_timeline"
        case brainStateEngine = "brain_state_engine"
    }
}

struct BrainRightBrainInstruction: Decodable {
    let type: String?
    let target: String?
    let tool: String?
    let goal: String?
    let action: String?
    let requiresConfirmation: Bool?
    let riskLevel: Int?

    enum CodingKeys: String, CodingKey {
        case type, target, tool, goal, action
        case requiresConfirmation = "requires_confirmation"
        case riskLevel = "risk_level"
    }
}

struct BrainMemoryItem: Decodable, Identifiable {
    let id: String?
    let date: String?
    let type: String?
    let summary: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, date, type, summary
        case createdAt = "created_at"
    }
}

