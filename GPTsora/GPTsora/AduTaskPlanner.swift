// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-7e503eeea06826262c7593db97b6dc226bf840c4274edb0a0c5e8ace54a10f45"
// Source-SHA256: "021a54a62b12922ba48ccf03c93ea00c812b5bd64afc848cc33f00b0a5d3cae9"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation

enum AduTaskIntentType: String, Equatable {
    case computerAction = "computer_action"
    case codexTask = "codex_task"
    case claudeTask = "claude_task"
    case chatAnswer = "chat_answer"
    case selfUpgradeTask = "self_upgrade_task"
    case continuePreviousTask = "continue_previous_task"
    case confirmPendingTask = "confirm_pending_task"
    case cancelPendingTask = "cancel_pending_task"
    case editPendingTask = "edit_pending_task"
    case askClarification = "ask_clarification"
    case fileSearchTask = "file_search_task"

    var title: String {
        switch self {
        case .computerAction: return "电脑控制 local-agent"
        case .codexTask: return "Codex 自动化编程"
        case .claudeTask: return "Claude 预览"
        case .chatAnswer: return "普通阿杜回答"
        case .selfUpgradeTask: return "自我升级任务"
        case .continuePreviousTask: return "继续上一任务"
        case .confirmPendingTask: return "确认待执行任务"
        case .cancelPendingTask: return "取消待执行任务"
        case .editPendingTask: return "修改待执行任务"
        case .askClarification: return "追问澄清"
        case .fileSearchTask: return "文件搜索"
        }
    }
}

enum AduPlannerSurface: String, Equatable {
    case homeChat
    case computerControl
    case engineeringAgent

    var backendValue: String {
        switch self {
        case .homeChat: return "home_chat"
        case .computerControl: return "computer_control"
        case .engineeringAgent: return "engineering_agent"
        }
    }
}

struct AduPlannerContext: Equatable {
    let currentSurface: AduPlannerSurface
    let hasPendingCodexTask: Bool
    let pendingCodexSummary: String?
    let lastAssistantIntent: String?
    let lastUserIntent: String?
    let recentConversationSummary: String?
    let selectedProject: String?
    let currentScreenState: String?

    init(
        currentSurface: AduPlannerSurface = .homeChat,
        hasPendingCodexTask: Bool = false,
        pendingCodexSummary: String? = nil,
        lastAssistantIntent: String? = nil,
        lastUserIntent: String? = nil,
        recentConversationSummary: String? = nil,
        selectedProject: String? = nil,
        currentScreenState: String? = nil
    ) {
        self.currentSurface = currentSurface
        self.hasPendingCodexTask = hasPendingCodexTask
        self.pendingCodexSummary = pendingCodexSummary
        self.lastAssistantIntent = lastAssistantIntent
        self.lastUserIntent = lastUserIntent
        self.recentConversationSummary = recentConversationSummary
        self.selectedProject = selectedProject
        self.currentScreenState = currentScreenState
    }
}

struct AduTaskPlan: Equatable {
    let type: AduTaskIntentType
    let originalInput: String
    let organizedTask: String
    let nextAction: String
    let suggestedProject: String?
    // 后端 registry 标准 id;有默认值,所以现有 18 处 AduTaskPlan(...) 构造不受影响。
    var suggestedProjectId: String? = nil
}

struct AduPlannerRecentMessage: Codable, Equatable {
    let role: String
    let content: String
}

struct AduPendingCodexTaskPayload: Codable, Equatable {
    let exists: Bool
    let project: String?
    let prompt: String?
    let summary: String?
    let riskLevel: String?
    let createdAt: String?
}

struct AduBackendPlannerRoute: Codable, Equatable {
    let ok: Bool
    let intent: String
    let confidence: Double
    let surface: String
    let project: String?
    // 后端 registry 的标准 id(gptsora / backend / little_beijing / chatagi_site),
    // 用于 /api/adu/codex/run 直接定位工程目录。convertFromSnakeCase 自动映射 project_id ↔ projectId。
    let projectId: String?
    let executor: String
    let title: String
    let summary: String
    let computerGoal: String
    let codexPrompt: String
    let claudePrompt: String
    let chatAnswer: String
    let riskLevel: String
    let needsUserConfirmation: Bool
    let blockedTerms: [String]
    let nextAction: String
    let message: String

    var intentType: AduTaskIntentType {
        AduTaskIntentType(rawValue: intent) ?? .askClarification
    }

    var asTaskPlan: AduTaskPlan {
        let organized: String
        switch intentType {
        case .computerAction:
            organized = computerGoal.isEmpty ? summary : computerGoal
        case .codexTask, .selfUpgradeTask, .continuePreviousTask, .confirmPendingTask, .editPendingTask:
            organized = codexPrompt.isEmpty ? summary : codexPrompt
        case .claudeTask:
            organized = claudePrompt.isEmpty ? summary : claudePrompt
        case .chatAnswer, .askClarification, .cancelPendingTask:
            organized = chatAnswer.isEmpty ? (message.isEmpty ? summary : message) : chatAnswer
        case .fileSearchTask:
            // 文件搜索 —— organizedTask 用 summary("在授权工作区搜索:xxx"),不走 codex/claude prompt。
            organized = summary.isEmpty ? message : summary
        }
        return AduTaskPlan(
            type: intentType,
            originalInput: summary.isEmpty ? (computerGoal.isEmpty ? organized : computerGoal) : summary,
            organizedTask: organized,
            nextAction: nextAction.isEmpty ? message : nextAction,
            suggestedProject: project,
            suggestedProjectId: projectId
        )
    }
}

enum AduBackendPlannerClient {
    static func route(
        apiBase: String,
        text: String,
        surface: AduPlannerSurface,
        recentMessages: [AduPlannerRecentMessage],
        pendingCodexTask: AduPendingCodexTaskPayload,
        selectedProject: String?,
        screenState: [String: Any]
    ) async throws -> AduBackendPlannerRoute {
        let normalized = apiBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: normalized + "/api/adu/planner/route") else {
            throw NSError(domain: "AduBackendPlanner", code: -1, userInfo: [NSLocalizedDescriptionKey: "invalid api base"])
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let pendingObject = try JSONSerialization.jsonObject(with: encoder.encode(pendingCodexTask)) as? [String: Any] ?? ["exists": false]
        let recentObjects = try recentMessages.map { msg -> [String: Any] in
            let data = try encoder.encode(msg)
            return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        }

        var payload: [String: Any] = [
            "text": text,
            "surface": surface.backendValue,
            "recent_messages": recentObjects,
            "pending_codex_task": pendingObject,
            "screen_state": screenState
        ]
        if let selectedProject, !selectedProject.isEmpty {
            payload["selected_project"] = selectedProject
        } else {
            payload["selected_project"] = NSNull()
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw NSError(domain: "AduBackendPlanner", code: status, userInfo: [NSLocalizedDescriptionKey: "planner http \(status)"])
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let route = try decoder.decode(AduBackendPlannerRoute.self, from: data)
        guard route.ok else {
            throw NSError(domain: "AduBackendPlanner", code: -2, userInfo: [NSLocalizedDescriptionKey: "planner ok=false"])
        }
        return route
    }
}

enum AduTaskPlanner {
    static func plan(_ rawText: String, context: AduPlannerContext) -> AduTaskPlan {
        let original = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = original.lowercased()

        if original.isEmpty {
            return AduTaskPlan(
                type: .chatAnswer,
                originalInput: original,
                organizedTask: "",
                nextAction: "空输入,不执行工具。",
                suggestedProject: nil
            )
        }

        if isCancellation(normalized) {
            if context.hasPendingCodexTask {
                return AduTaskPlan(
                    type: .cancelPendingTask,
                    originalInput: original,
                    organizedTask: context.pendingCodexSummary ?? "",
                    nextAction: "取消当前 pending Codex 任务。",
                    suggestedProject: context.selectedProject
                )
            }
            return AduTaskPlan(
                type: .chatAnswer,
                originalInput: original,
                organizedTask: "当前没有待取消的 Codex 任务。",
                nextAction: "没有 pending Codex 任务,按普通聊天处理。",
                suggestedProject: nil
            )
        }

        if isPendingEditInstruction(normalized) {
            if context.hasPendingCodexTask {
                return AduTaskPlan(
                    type: .editPendingTask,
                    originalInput: original,
                    organizedTask: original,
                    nextAction: "把用户补充约束合并到 pending Codex prompt。",
                    suggestedProject: context.selectedProject ?? suggestedCodexProject(for: normalized)
                )
            }
            return AduTaskPlan(
                type: .chatAnswer,
                originalInput: original,
                organizedTask: "我收到了这个约束,但当前没有待修改的 Codex 任务。你想把它应用到哪个任务?",
                nextAction: "没有 pending Codex 任务,询问约束归属。",
                suggestedProject: nil
            )
        }

        if isConfirmation(normalized) {
            if context.hasPendingCodexTask {
                return AduTaskPlan(
                    type: .confirmPendingTask,
                    originalInput: original,
                    organizedTask: context.pendingCodexSummary ?? "",
                    nextAction: "确认并运行当前 pending Codex 任务。",
                    suggestedProject: context.selectedProject
                )
            }
            return AduTaskPlan(
                type: .chatAnswer,
                originalInput: original,
                organizedTask: "我没有找到待执行的 Codex 任务。请先说明要让我做什么。",
                nextAction: "没有 pending Codex 任务,不运行 Codex。",
                suggestedProject: nil
            )
        }

        if isContinuation(normalized) {
            if context.hasPendingCodexTask {
                return AduTaskPlan(
                    type: .continuePreviousTask,
                    originalInput: original,
                    organizedTask: context.pendingCodexSummary ?? "",
                    nextAction: "继续指向当前 pending Codex 任务,不重新生成 prompt。",
                    suggestedProject: context.selectedProject
                )
            }

            let lastIntent = ((context.lastAssistantIntent ?? "") + " " + (context.lastUserIntent ?? "")).lowercased()
            if lastIntent.contains("computer") || context.currentSurface == .computerControl {
                return AduTaskPlan(
                    type: .chatAnswer,
                    originalInput: original,
                    organizedTask: "你想继续上一轮电脑动作的话,请告诉我下一步要点击、输入或打开什么。",
                    nextAction: "没有可自动继续的 pending 电脑动作,询问下一步。",
                    suggestedProject: nil
                )
            }

            return AduTaskPlan(
                type: .chatAnswer,
                originalInput: original,
                organizedTask: "我没有找到待继续的 Codex 任务,你想让我继续哪一个?",
                nextAction: "没有 pending Codex 任务,不生成新 Codex prompt。",
                suggestedProject: nil
            )
        }

        if isSelfUpgradeRequest(normalized) {
            return AduTaskPlan(
                type: .selfUpgradeTask,
                originalInput: original,
                organizedTask: selfUpgradePrompt(from: original),
                nextAction: "先请求 /api/adu/self/upgrade/plan 生成 plan_only 自我升级计划卡,不会自动进入 Codex。",
                suggestedProject: "GPTsora"
            )
        }

        if isQuestionOrExplanation(normalized) {
            return AduTaskPlan(
                type: .chatAnswer,
                originalInput: original,
                organizedTask: shortAnswer(for: original),
                nextAction: "普通阿杜回答,不执行电脑动作,不调用 Codex。",
                suggestedProject: nil
            )
        }

        if isTrueCodexTask(normalized, context: context) {
            let project = suggestedCodexProject(for: normalized, context: context)
            return AduTaskPlan(
                type: .codexTask,
                originalInput: original,
                organizedTask: codexPrompt(from: original, project: project),
                nextAction: "阿杜已整理为自动化编程任务,请确认后点击 Run Codex。",
                suggestedProject: project
            )
        }

        if isExplicitComputerAction(normalized) {
            return AduTaskPlan(
                type: .computerAction,
                originalInput: original,
                organizedTask: original,
                nextAction: "继续调用 /api/brain/computer/action,完成后刷新电脑截图。",
                suggestedProject: nil
            )
        }

        if containsAny(normalized, [
            "claude", "审查", "方案", "架构", "对比", "设计", "重构建议", "风险评估",
        ]) {
            return AduTaskPlan(
                type: .claudeTask,
                originalInput: original,
                organizedTask: claudePrompt(from: original),
                nextAction: "待接入 Claude。第一版只展示 prompt 预览,不执行。",
                suggestedProject: nil
            )
        }

        return AduTaskPlan(
            type: .chatAnswer,
            originalInput: original,
            organizedTask: "我先把这句话当作普通问题处理: \(original)",
            nextAction: "未命中明确工具意图,不执行电脑动作,不调用 Codex。",
            suggestedProject: nil
        )
    }

    static func plan(_ rawText: String) -> AduTaskPlan {
        plan(rawText, context: AduPlannerContext())
    }

    private static func isSelfUpgradeRequest(_ text: String) -> Bool {
        containsAny(text, [
            "自我升级", "自己升级", "递归", "自我进化", "自我改进", "检查系统", "检查当前系统",
            "系统问题", "升级计划", "诊断一下系统", "自己诊断", "优化自己", "agi", "自主升级",
        ]) && containsAny(text, ["系统", "自己", "阿杜", "chatagi", "adu", "能力", "哪里还能升级", "检查", "诊断"])
    }

    private static func isContinuation(_ text: String) -> Bool {
        let compact = text.replacingOccurrences(of: " ", with: "")
        if ["继续", "接着做", "继续上一个", "继续上一条", "继续刚才", "接着"].contains(compact) { return true }
        return containsAny(text, ["继续给 codex", "继续给codex", "接着给 codex", "接着做上一个", "继续这个任务"])
    }

    private static func isConfirmation(_ text: String) -> Bool {
        let compact = text.replacingOccurrences(of: " ", with: "")
        if ["确认", "运行", "运行吧", "执行", "开始执行", "确认运行", "确认执行", "就按这个", "就按这个运行", "按这个运行"].contains(compact) {
            return true
        }
        return containsAny(text, ["可以运行", "开始跑", "run it", "go ahead", "do it"])
    }

    private static func isCancellation(_ text: String) -> Bool {
        let compact = text.replacingOccurrences(of: " ", with: "")
        return ["取消", "别运行", "不要运行", "不用了", "算了", "停止", "先取消"].contains(compact)
    }

    private static func isPendingEditInstruction(_ text: String) -> Bool {
        containsAny(text, ["修改一下", "改一下", "补充", "加上", "不要改", "不改", "只修", "只改", "别改", "限制", "约束"])
    }

    private static func isQuestionOrExplanation(_ text: String) -> Bool {
        containsAny(text, ["为什么", "什么意思", "讲讲", "解释", "分析一下", "这是什么", "原因", "含义", "区别"]) ||
            (text.hasSuffix("?") || text.hasSuffix("？"))
    }

    private static func isExplicitComputerAction(_ text: String) -> Bool {
        let compact = text.replacingOccurrences(of: " ", with: "")
        if compact.hasPrefix("打开") || compact.hasPrefix("点击") || compact.hasPrefix("输入") ||
            compact.hasPrefix("按") || compact.hasPrefix("切换到") || compact.hasPrefix("关闭") {
            return containsAny(text, ["safari", "微信", "浏览器", "按钮", "回车", "enter", "return", "窗口", "hello", "这个", "那里"]) ||
                compact.hasPrefix("输入")
        }
        return containsAny(text, ["打开 safari", "点击这个按钮", "输入 hello", "按回车", "切换到微信"])
    }

    private static func isTrueCodexTask(_ text: String, context: AduPlannerContext) -> Bool {
        if isQuestionOrExplanation(text) { return false }
        if isContinuation(text) || isConfirmation(text) || isCancellation(text) { return false }

        let hasEngineeringVerb = containsAny(text, [
            "修复", "修一下", "修 ", "新增", "创建", "检查", "跑构建", "构建", "编译", "修某个页面",
            "实现", "重构", "接入", "更新", "白屏", "崩溃", "报错", "build", "xcodebuild"
        ])
        let hasEngineeringObject = containsAny(text, [
            "app", "ios", "swift", "xcode", "代码", "工程", "项目", "页面", "功能", "编译错误",
            "电脑控制页", "截图不实时刷新", "入口", "接口", "白屏", "codex", "构建"
        ])
        let explicitCodexWithGoal = containsAny(text, ["给 codex", "让 codex", "codex 任务", "自动化编程"]) && hasEngineeringVerb
        let surfaceBias = context.currentSurface == .engineeringAgent && hasEngineeringVerb
        return (hasEngineeringVerb && hasEngineeringObject) || explicitCodexWithGoal || surfaceBias
    }

    private static func containsAny(_ text: String, _ keywords: [String]) -> Bool {
        keywords.contains { text.contains($0.lowercased()) }
    }

    private static func suggestedCodexProject(for text: String, context: AduPlannerContext = AduPlannerContext()) -> String {
        if let selected = context.selectedProject, !selected.isEmpty {
            return selected
        }

        if containsAny(text, ["little beijing", "小北京", "餐厅", "ordering"]) {
            return "Little Beijing"
        }

        let backendNegated = containsAny(text, ["不要改后端", "不改后端", "别改后端", "无需改后端"])
        if !backendNegated, containsAny(text, ["后端", "backend", "server_session", "api"]) {
            return "Backend"
        }

        if containsAny(text, ["ios", "swift", "app", "xcode", "gptsora", "电脑控制页"]) {
            return "GPTsora"
        }

        return "GPTsora"
    }

    private static func codexPrompt(from original: String, project: String) -> String {
        """
        请在 \(project) 项目中处理下面任务。

        用户原始需求:
        \(original)

        执行要求:
        1. 先阅读相关代码,只改本任务需要的 iOS 前端 Swift 文件。
        2. 不改后端、不改 local-agent、不改 Codex runner、不改 Little Beijing、不改 billing。
        3. 不部署、不 git commit、不运行发布或付费相关操作。
        4. 保持现有电脑截图实时刷新、Health、Run Codex、底部 + 按钮、小麦克和返回主页面能力不被破坏。
        5. 修改后说明改了哪些文件,并运行可行的编译验证;如果失败,只修本次 Swift 修改引入的问题。
        """
    }

    private static func claudePrompt(from original: String) -> String {
        """
        请作为 Claude 自动化编程/代码审查层预览以下请求。

        用户原始需求:
        \(original)

        请输出:
        1. 方案或审查重点
        2. 架构影响
        3. 风险评估
        4. 建议的最小改动范围
        """
    }

    private static func selfUpgradePrompt(from original: String) -> String {
        """
        自我升级任务需要高风险确认。请只读检查当前 ChatAGI 阿杜系统可以改进的地方,不要自动执行破坏性操作。

        用户原始需求:
        \(original)

        请输出:
        1. 当前系统能力边界和可升级点
        2. 前端、后端、agent、Codex runner 的分层风险
        3. 最小可行升级计划
        4. 需要用户确认的步骤
        5. 明确禁止: 不读取或泄露 .env/API key,不部署,不 git commit,不 git push,不删除数据
        """
    }

    private static func shortAnswer(for original: String) -> String {
        if original.lowercased().contains("not_simple_computer_action") {
            return "not_simple_computer_action 通常表示这句话没有被识别成一个可直接执行的简单电脑动作。阿杜会把它留在解释/规划层,避免误触发电脑控制或 Codex。"
        }
        return "这更像是在问原因或含义。第一版 planner 会把它作为普通阿杜回答处理,不会执行电脑动作,也不会调用 Codex。"
    }
}
