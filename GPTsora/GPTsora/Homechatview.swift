
// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-1141c483ee46da4b867b2ff6c6e45a82a1b11213a1787407d40c5780bbc439d8"
// Source-SHA256: "0cdfb1501d75a6beb592a0164ffde189878c9b730d5b0a92ae78eba2d064d18a"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI
import UIKit
import AVFoundation
import PhotosUI
import Combine
import AuthenticationServices
import CryptoKit

// HomeChatView 的"上半部分"在两个模式之间切换;下半部分输入栏保持原样。
// .chat:聊天消息流(原 chatList);.computer:电脑控制嵌入面板。
enum HomeSurfaceMode: Equatable {
    case chat
    case computer
}

enum ComputerControlVoiceExecutionState: Equatable {
    case idle
    case connecting
    case listening
    case executing
    case succeeded
    case failed
    case cancelled

    var title: String {
        switch self {
        case .idle: return "语音未连接"
        case .connecting: return "语音连接中"
        case .listening: return "语音控制中"
        case .executing: return "正在执行"
        case .succeeded: return "执行完成"
        case .failed: return "执行失败"
        case .cancelled: return "已取消"
        }
    }
}

struct ComputerControlVoiceStatus: Equatable {
    var executionState: ComputerControlVoiceExecutionState = .idle
    var realtimeStatus: String = "未连接"
    var isRealtimeConnected: Bool = false
    var lastCommand: String = ""
    var lastResult: String = ""
    var lastError: String = ""

    var isExecuting: Bool { executionState == .executing }
}

enum ComputerControlUnifiedResponseFormatter {
    static func finalText(from result: UnifiedResult) -> String {
        let raw = result.raw
        let candidates = [
            raw["final_text"] as? String,
            raw["message"] as? String,
            raw["result"] as? String,
            (raw["result"] as? [String: Any])?["message"] as? String,
            (raw["result"] as? [String: Any])?["final_text"] as? String
        ]
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        if !result.ok {
            let err = (raw["error"] as? String) ?? (raw["detail"] as? String) ?? ""
            if !err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return err }
        }
        if result.route == "computer" {
            return result.ok ? "电脑动作已执行。" : "电脑动作执行失败。"
        }
        return result.ok ? "指令已发送。" : "指令发送失败。"
    }
}

@MainActor
final class RobotPerceptionStore: ObservableObject {
    static let shared = RobotPerceptionStore()

    struct Snapshot {
        var sceneDescription: String
        var objects: [String]
        var decision: String
        var confidence: Double
        var updatedAt: Date?
    }

    @Published private(set) var sceneDescription: String = ""
    @Published private(set) var objects: [String] = []
    @Published private(set) var decision: String = ""
    @Published private(set) var confidence: Double = 0
    @Published private(set) var updatedAt: Date? = nil

    private init() {}

    func update(sceneDescription: String, objects: [String], decision: String, confidence: Double) {
        self.sceneDescription = sceneDescription
        self.objects = objects
        self.decision = decision
        self.confidence = max(0, min(1, confidence))
        self.updatedAt = Date()
    }

    func snapshot() -> Snapshot {
        Snapshot(
            sceneDescription: sceneDescription,
            objects: objects,
            decision: decision,
            confidence: confidence,
            updatedAt: updatedAt
        )
    }
}

// MARK: - HomeChatView (FastLane 稳态通话 + 语音播报 + 照片/语音消息)
// 目标：
// - 语音通话 / 音视频通话两条链路更稳：切换更快、减少重复重连、过滤可忽略的 cancel 错误
// - 系统调用更协调：通话优先级最高；通话期间禁止本地播报/语音消息播放/本地录音，避免抢占 AVAudioSession 导致断流
// - TTS：短文本优先尝试 /tts_prepare（流式 URL），长文本直接“下载完再播”更稳（可调阈值）
//
// 使用方式：
// - 用此文件完整替换原来的 HomeChatView.swift（避免重复类型冲突）
// - 同时把 RealtimeFastLane.swift 加入工程（同一个 Target）
//
// 说明：
// - 本文件仍假设工程里已存在：RealtimeBridge / RealtimeAVService / RealtimeAVCallView / HAHomeVoiceControlView / RootPagerView 等。
// - 若你的工程里这些名字不同，请对应替换。

struct HomeChatView: View {

@EnvironmentObject private var authManager: AuthManager
@ObservedObject private var iap = IAPManager.shared


private var hasProEntitlement: Bool {
    authManager.hasActiveSubscription || iap.hasActiveSubscription
}

// MARK: - Plan Picker (ChatGPT-style)
// ✅ 开发/内测版：恢复四个套餐显示，并允许直接选择对应文本模型。
private enum PlanOption: String, CaseIterable, Identifiable {
    case guest, pro, ultra, coder
    var id: String { rawValue }

    var title: String {
        switch self {
        case .guest: return "Guest"
        case .pro: return "ChatAGI Pro"
        case .ultra: return "Ultra"
        case .coder: return "Coder"
        }
    }

    var subtitle: String {
        switch self {
        case .guest: return "三段实时语音 / 机器人 6.0"
        case .pro: return AppConfig.Realtime.chatAGINativeTitle
        case .ultra: return "Ultra 深度能力 / GPT 5 Pro"
        case .coder: return "高级编程 / 推理与代码模型"
        }
    }

    // ⚠️ 前后端对齐：这四个 ID 必须与后端 server_session.py 的
    //   CHAT_MODEL_GUEST / CHAT_MODEL_PRO / CHAT_MODEL_ULTRA / CHAT_MODEL_CODER 一一对应。
    //   后端会校验该 ID 是否在 ALLOWED_CHAT_MODELS 内；命中才信任，否则回落到 plan 映射。
    //   线上若某模型不可用，后端会自动降级到 CHAT_MODEL_FALLBACK，不再返回“网络问题”。
    var modelName: String {
        switch self {
        case .guest: return "qwen3.6-plus"
        case .pro: return "claude-opus-4-7"
        case .ultra: return "claude-opus-4-8"
        case .coder: return "gpt-5.5-pro"
        }
    }

    // ✅ UI-only display label. Never leak raw model IDs to the user.
    var displayName: String {
        switch self {
        case .guest: return "机器人 6.0"
        case .pro:   return AppConfig.Realtime.chatAGINativeTitle
        case .ultra: return "机器人 6.2"
        case .coder: return "机器人 6.2 Pro"
        }
    }

    var iconName: String {
        switch self {
        case .guest: return "bubble.left.and.bubble.right.fill"
        case .pro: return "sparkles"
        case .ultra: return "crown.fill"
        case .coder: return "chevron.left.forwardslash.chevron.right"
        }
    }

    // ✅ 四个套餐全部开放选择，不再显示 Coming soon。
    var isComingSoon: Bool { false }
}

@AppStorage("chatagi.current_plan") private var selectedPlanRaw: String = PlanOption.guest.rawValue
@State private var pendingPlanAfterPurchase: PlanOption? = nil

// MARK: - V1 Single Pro Paywall Gates
// V1 定版：一个套餐 ChatAGI Pro，$4.99/week，Product ID: solara_pro_weekly_799。
// 免费体验：文本 5 次；“+”号上传/图片/文件 3 次；语音/音视频点击即弹订阅。
@AppStorage("chatagi.v1.guest_text_used") private var guestTextUsed: Int = 0
@AppStorage("chatagi.v1.guest_plus_used") private var guestPlusUsed: Int = 0
@AppStorage("chatagi.paywall_reason") private var paywallReasonRaw: String = PaywallReason.generic.rawValue
@State private var lastObservedPlusPendingCount: Int = 0

private let v1GuestTextLimit = 5
private let v1GuestPlusLimit = 3

private enum PaywallReason: String {
    case generic
    case textLimit
    case plusLimit
    case voiceLocked
}

private var selectedPlan: PlanOption {
    PlanOption(rawValue: selectedPlanRaw) ?? .guest
}

// ✅ 当前生效套餐：开发/内测版直接相信用户在 UI 中选择的套餐。
private var entitledPlan: PlanOption {
    selectedPlan
}

// ✅ UI 套餐（保持主界面为 Ultra 的界面）
// 需求：即使选择了“高级编程版”（最高版本），主页仍保持 Ultra 的界面/入口布局。
private var uiPlan: PlanOption {
    (entitledPlan == .coder) ? .ultra : entitledPlan
}


// ✅ Plan -> Chat model mapping
// 前端只传当前套餐的模型 ID；深度思考由后端基于 thinking:true 用 CHAT_MODEL_THINKING 权威切换，
// 不在前端硬编码 reasoning 模型，避免与后端 _select_model_for_request 冲突。
private var selectedTextModel: String {
    return entitledPlan.modelName
}

// ✅ 用户主动选择的回复速度模式：fast(默认) / deep(深度思考)
private enum ThinkingMode: String, CaseIterable {
    case fast      // 🚀 快速回答
    case deep      // 🧠 深度思考（reasoning 模型）

    var label: String {
        switch self {
        case .fast: return "快速回答"
        case .deep: return "深度思考"
        }
    }
    var icon: String {
        switch self {
        case .fast: return "bolt.fill"
        case .deep: return "brain.head.profile"
        }
    }
    var tint: Color {
        switch self {
        case .fast: return Color(red: 0.10, green: 0.65, blue: 0.55)  // 青绿（与 RouteTier.fast 对齐）
        case .deep: return Color(red: 0.55, green: 0.35, blue: 0.85)  // 紫（与 RouteTier.deep 对齐）
        }
    }
}

@AppStorage("chatagi.thinking_mode") private var thinkingModeRaw: String = ThinkingMode.fast.rawValue
private var thinkingMode: ThinkingMode {
    ThinkingMode(rawValue: thinkingModeRaw) ?? .fast
}

// ✅ 快捷入口显隐
private var showWeChatEntry: Bool { false }
private var showComputerDebugEntry: Bool { true }

private func configureRealtimeForCurrentPlan() {
    let svc = RealtimeAVService.shared
    svc.apiBase = apiBase
    svc.sessionConversationId = self.currentConversationId ?? ""
    svc.sessionClientId = clientId
    svc.sessionEndpointOverride = nil
    svc.realtimePlan = (entitledPlan == .coder) ? "coder" : ((entitledPlan == .ultra) ? "ultra" : ((entitledPlan == .pro) ? "pro" : "guest"))

    switch entitledPlan {
    case .pro:
        // ✅ 6.1 切回阿里官方 Qwen Omni Realtime（不再走 ChatAGI-native / MiniCPM 自部署）。
        svc.preferredProvider = "qwen"
        svc.instructionsOverride = "你是 ChatAGI 阿杜实时语音模型，请用自然、简洁的中文回答。"
    case .ultra, .coder:
        svc.preferredProvider = "openai"
        svc.instructionsOverride = nil
    case .guest:
        // Guest / 机器人 6.0 接入我们的三段实时语音云端桥，走 OpenAI Realtime 风格入口。
        svc.preferredProvider = "openai"
        svc.instructionsOverride = "你是 ChatAGI 阿杜 机器人 6.0 三段实时语音模型，请用自然、简洁的中文回答。"
    }

    if let snap = AduPerceptionManager.shared.lastSnapshot,
       let d = try? JSONEncoder().encode(snap),
       var dict = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
        let summary = aduContext.recentSummary(limit: 12)
        if !summary.isEmpty { dict["adu_context_summary"] = summary }
        svc.lastPerceptionSnapshot = dict
    }
}

private func prewarmChatAGINativeRealtimeIfNeeded() {
    guard entitledPlan == .pro else { return }
    // ✅ 6.1 已切回阿里官方 Qwen：按需连接，不再预热自部署 MiniCPM。
    //    仅做套餐/会话配置，让首次进语音/视频时直接走 /session → qwen。
    configureRealtimeForCurrentPlan()
    fast.configure(apiBase: apiBase, clientId: clientId)
}

private func startChatAGINativeRealtimeFromVoiceButton() {
    print("[QwenRealtime] pro voice button_tapped (6.1 -> 阿里官方 Qwen)")
    lastChatAGINativeVoiceStartAt = Date()
    configureRealtimeForCurrentPlan()
    // ✅ 6.1 切回阿里官方 Qwen Omni Realtime：走标准 /session → qwen WebSocket 链路，
    //    不再连自部署 ChatAGI-native / MiniCPM。
    RealtimeAVService.shared.preferredProvider = "qwen"
    RealtimeAVService.shared.realtimePlan = PlanOption.pro.rawValue
    RealtimeAVService.shared.instructionsOverride = "你是 ChatAGI 阿杜实时语音模型，请用自然、简洁的中文回答。"

    print("[QwenRealtime] provider=qwen plan=pro connecting...")

    fast.configure(apiBase: apiBase, clientId: clientId)
    RealtimeAVService.shared.startAudio()
}



    /// ✅ Single source of truth for API base
    private var apiBase: String { AppConfig.API.apiBase }
    private let chat = GPT5ChatService()
    private let uploader = MediaUploadService()

    // ✅ 极速 Realtime 通道：全 App 复用同一个 RealtimeBridge
    //    同时避免某些可忽略的 cancel 错误触发断线。
    @ObservedObject private var fast = RealtimeFastLane.shared
    @ObservedObject private var rt = RealtimeFastLane.shared.bridge

    // ✅ 语音气泡播放（全局单实例）
    @StateObject private var audioPlayer = GlobalAudioPlayer()

    @StateObject var aduVoice = AduVoiceService.shared

    // ✅ 助手气泡播报（GPT TTS，全局单实例）
    @StateObject private var speechPlayer = GlobalSpeechPlayer()

    // ✅ 实时播报开关（最高体验：/chat/prepare tts_stream=true -> /tts/live/<id>.mp3）
    @State private var showPhoneAgent = false

    @State private var autoSpeakEnabled: Bool = true
    @State private var autoSpeakVoice: String = "alloy"
    @StateObject private var liveTTSPlayer = LiveTTSStreamController()


    // ✅ 家居入口（状态探测 & 配置）
    @StateObject private var homeEntryVM = HAQuickHomeEntryVM()
    // ✅ 微信式：会话列表/联系人/人与人聊天/视频通话（GPT 也是一个“人”）
    @StateObject private var wechatStore = WeChatStore()


    // ✅ 统一管理所有 sheet，避免多 sheet 互抢
    private enum ActiveSheet: Identifiable {
        case legacyVideo
        case wechatHome
        case homeControlLegacy
        case planPicker
        case visionNav
        case account

        var id: Int {
            switch self {
            case .legacyVideo: return 1
            case .wechatHome: return 2
            case .homeControlLegacy: return 3
            case .planPicker: return 4
            case .visionNav: return 5
            case .account: return 6
            }
        }
    }
    @State private var activeSheet: ActiveSheet? = nil

    // ✅ ChatGPT-style：标题旁 “>” 打开紧凑模型/套餐选择浮层
    @State private var showPlanMenu: Bool = false

    // ✅ ChatGPT 模式：历史会话半屏抽屉（点击汉堡键 / 右划打开；左划 / 点空白关闭）
    //    说明：当前联网已稳定，保持 FastLane 全局复用；此处只改 UI 呈现方式，不触碰网络链路。
    @State private var historyDrawerOpen: Bool = false
    @State private var historyDrawerDragX: CGFloat = 0
    @State private var historyDrawerDragging: Bool = false

    // ✅ 视觉导航页（左划进入）
    @State private var showVisionNav: Bool = false
    @State private var navSwipeDragX: CGFloat = 0


    @State private var messages: [ChatMessage] = []
    @State private var currentConversationId: String? = nil

    @State private var inputText: String = ""
    @FocusState private var focused: Bool

    @State private var isSending = false
    @State private var sendTask: Task<Void, Never>? = nil

    // ✅ ChatGPT-style stable typing pump (stream deltas -> fixed UI cadence)
    @State private var typingAssistantId: UUID? = nil
    @State private var typingPending: String = ""
    @State private var typingPumpTask: Task<Void, Never>? = nil
    @State private var typingLastDeltaAt: TimeInterval = 0
    
    // ✅ “播报开始才吞字”：当语音真正开始播放时才开始显示文本；若用户中止播报则立即补全全文
    @State private var revealTask: Task<Void, Never>? = nil
    @State private var revealTaskMessageId: UUID? = nil
    @State private var revealFullText: [UUID: String] = [:]

    // ✅ 预生成/预下载 TTS：当“播放”按钮出现时，音频已就绪（用户点才播）
    @State private var ttsPreparedURL: [UUID: URL] = [:]
    @State private var ttsRemoteURL: [UUID: URL] = [:]   // 后端 /chat/prepare 给的 tts_url（优先用它下载，省钱且更快）
    @State private var ttsPreparing: Set<UUID> = []
    @State private var ttsPrefetchTask: [UUID: Task<Void, Never>] = [:]

    // ✅ 用户手动中止某条消息的播报后：显示“带斜杠的小喇叭”
    @State private var mutedSpeechMessageIds: Set<UUID> = []



    // ✅ Scroll control
    private enum ScrollTarget: Hashable {
        case msg(UUID)
        case bottom
    }
    @State private var scrollTick: Int = 0
    @State private var scrollTask: Task<Void, Never>? = nil
    @State private var scrollTarget: ScrollTarget = .bottom
    @State private var scrollAnchor: UnitPoint = .bottom

    // ✅ Auto-scroll rate limit (ChatGPT 同款“稳态”策略：最多 8fps 自动滚动，避免抖动)
    @State private var lastAutoScrollAt: TimeInterval = 0
    private let autoScrollMinInterval: TimeInterval = 0.12

    // ✅ ⬇️ 显示逻辑
    @State private var isAtBottom: Bool = true
    @State private var scrollViewHeight: CGFloat = 0
    private let bottomThreshold: CGFloat = 10

    // ✅ 推理进度文字（推理模型等待期间轮播，keepalive/delta到来时更新）
    @State private var thinkingPhaseText: String = "正在思考中…"
    /// ✅ 路由档位胶囊隐藏触发(完成 1.2s 后翻转,触发视图重算 shouldShowRouteTier)
    @State private var routeTierHideTick: Int = 0
    @State private var thinkingPhaseTask: Task<Void, Never>? = nil

    // ✅ ChatGPT 两态：聊天 / 声音
    private enum ComposerMode { case chat, voice }
    @State private var composerMode: ComposerMode = .chat
    @State private var lastChatAGINativeVoiceStartAt: Date? = nil

    // ✅ 声音态：静音 & 音视频页
    @State private var isMutedInVoice = false
    @State private var showVideoCall = false

    @State private var showComputerDebugPanel = false   // ✅ 局域网电脑控制调试面板
    // ✅ 首页入口简化：除“电脑控制”外的圆形入口（机器人 / 视频 / 地图 / 设置·滑杆 /
    //    电脑Body调试等）统一隐藏到此开关后；首页只保留一个“电脑控制”主入口。
    //    需要时把它改回 true 即可恢复旧入口（代码未删除，可逆）。
    private let showLegacyHomeEntries = false
    @State private var isRobotMode = false               // ✅ 阿杜机器人脑 v1：主聊天页内切换，不跳遥控器页
    @State private var robotStatusLine = "六足待连接"
    @State private var robotPlannerBusy = false
    @StateObject private var robotPerception = RobotPerceptionStore.shared
    @StateObject private var hexapodRobotService = HexapodRobotService()
    @State private var showBodyDebugPanel = false        // ✅ Computer Body Gateway V2 高级调试面板
    @State private var showComputerControl = false       // ⚠️ 保留只为防御 onAppear 复位逻辑;
                                                          // 真正的"是否在电脑控制面板"由 surfaceMode 决定。
    @State private var computerControlMode = false
    @State private var computerVoiceStatus = ComputerControlVoiceStatus()
    @State private var computerVoiceExecutionTask: Task<Void, Never>? = nil
    @State private var computerVoiceExecutionId: UUID? = nil
    // HomeChatView 上半部分模式:聊天消息流 vs 电脑控制嵌入面板。
    // 下半部分输入栏(chatGPTChatInputBar)恒定不动 —— 任何模式下都是普通聊天输入。
    @State private var surfaceMode: HomeSurfaceMode = .chat
    // 统一 Adu 上下文时间线 —— 入口在 HomeChatView 持有,下传到 ComputerControl / EngineeringAgentPanel。
    // 主聊天发送时会把 recentSummary() 当成临时 system 消息塞进 /chat/prepare 的 context,让
    // 主聊天助手实时知道刚才工具发生了什么(Codex / 电脑动作 / planner / Health 等)。
    @StateObject private var aduContext = AduContextStore()
    @State private var pendingComputerControlInstruction = ""
    @State private var pendingEngineeringGoal: String? = nil   // ✅ V1.5 工程修复：两段式确认。计划阶段记下原 goal，等用户回"确认执行"再二轮提交。
    @State private var pendingCodexTask: AduTaskPlan? = nil
    @State private var pendingProject: String? = nil
    @State private var pendingPrompt: String = ""
    @State private var pendingRiskLevel: String = "medium"
    // V3 新增:阿杜判断的"原因摘要"(planner 的 summary 字段) + 选中工程的绝对路径,
    // 用来在 Codex 确认卡里展示"为什么选这个工程"+"将操作哪个授权工作区"。
    @State private var pendingReason: String = ""
    @State private var pendingWorkspacePath: String = ""
    @State private var pendingCreatedAt: Date? = nil
    @State private var pendingCodexAssistantId: UUID? = nil
    @State private var codexPlannerRunning: Bool = false
    // 当 planner 判定为非工具意图(chat_answer / ask_clarification / 低置信 / 网络错)时,
    // routeAduPlannerInput 会把这个标志位拨成 true 后重入 onSendOrStop(),
    // 以便完整复用原始普通聊天链路(记忆/联网/图片/文件/主人格)而不重复代码。一次性,用后自动复位。
    @State private var bypassPlannerOnce: Bool = false
    @State private var showAduDelegate = false  // ✅ 阿杜委托界面
    @State private var showVoiceClone = false   // ✅ 声音克隆
    @State private var showSemanticLab = false  // ✅ 语义打断真实通话页（独立入口，不走主 FastLane）

    // realtime assistant 打字消息 id
    @State private var rtAssistantId: UUID? = nil
    // ✅ 缓存最近一条用户转写
    @State private var rtLastUserText: String = ""

    // ✅ 置顶用户气泡（右上角）
    @State private var pinnedUserId: UUID? = nil
    @State private var pinnedAssistantId: UUID? = nil
    @State private var pinnedUserHeight: CGFloat = 0
    // ✅ Stable per-device client id (history + memory are keyed by this)
    @State private var clientId: String = {
        let k = "solara.client_id"
        if let v = UserDefaults.standard.string(forKey: k), !v.isEmpty { return v }
        let v = UUID().uuidString.lowercased()
        UserDefaults.standard.set(v, forKey: k)
        return v
    }()

    // UI 浅灰底
    private let uiGray = Color(white: 0.94)

    // MARK: - Attachments state (统一交给 ChatPlusFeature.swift)

    @StateObject private var plus = ChatPlusManager()

    @StateObject private var audioNote = AudioNoteRecorder()

    // ✅ 输入栏高度（用于“自动轻量回退”）
    @State private var inputBarHeight: CGFloat = 56

    // ✅ “轻量回退”高度：跟随输入栏变化（预览/录音/工具行时输入栏变高，会自动增加回退）
    private var bottomBreathingSpace: CGFloat {
        let base: CGFloat = 18
        let extra = min(28, inputBarHeight * 0.28) // 控制“轻量”
        return base + extra
    }

    /// ✅ 音频优先级：Realtime 通话最高，通话期间禁止本地播放/录音，避免 AVAudioSession 抢占导致断流
    /// ✅ 音频优先级：Realtime 通话最高。
    ///
    /// ⚠️ 注意：rt.isConnected 只是“底层通道已连接”，并不代表用户正在通话。
    /// 如果用它来判断“通话中”，会导致文本模式下永远认为在通话，从而把 tts_stream 永久关掉。
    ///
    /// 我们只在真正进入语音态/音视频页或本地录音时，才认为 callActive。
    private var callActive: Bool {
        if showVideoCall { return true }
        if composerMode == .voice { return true }
        if audioNote.isRecording { return true }
        return false
    }

    // ✅ 当前置顶的用户消息（右上角）
    private var pinnedUserMessage: ChatMessage? {
        guard let pid = pinnedUserId else { return nil }
        return messages.first(where: { $0.id == pid })
    }


        // ✅ 当前置顶的助手消息（紧跟在置顶用户消息之后）
    private var pinnedAssistantMessage: ChatMessage? {
        if let aid = pinnedAssistantId, let m = messages.first(where: { $0.id == aid }) {
            return m
        }
        guard let pid = pinnedUserId,
              let idx = messages.firstIndex(where: { $0.id == pid })
        else { return nil }
        let after = messages.suffix(from: min(messages.count, idx + 1))
        return after.first(where: { $0.role == .assistant })
    }

    // MARK: - 置顶区域（只显示最新用户消息，固定在右上角）
    @ViewBuilder
    private var pinnedUserHeader: some View {
        if let msg = pinnedUserMessage {
            HStack {
                Spacer(minLength: 8)
                row(for: msg) // 复用现有渲染
                    .fixedSize(horizontal: false, vertical: true)
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: PinnedUserHeightKey.self, value: geo.size.height)
                        }
                    )
                            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 6)
        }
    }

    private var rootContentStack: some View {
        ZStack(alignment: .leading) {

            // 主界面（聊天 / 声音）
            ZStack {
                Color.white.ignoresSafeArea()

                if composerMode == .chat {
                    chatScreen
                        .transition(.opacity)
                } else {
                    voiceScreen
                        .transition(.opacity)
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.92), value: composerMode)
            // ✅ 视觉导航入口保留，并与已移除的视频生成器入口解耦。
            .overlay(alignment: .trailing) {
                if !showVisionNav {
                    Color.clear
                        .frame(width: 22)
                        .contentShape(Rectangle())
                        .gesture(navEdgeSwipeGesture)
                        .ignoresSafeArea()
                }
            }

            // ✅ ChatGPT 模式：历史会话半屏抽屉（左侧栏）
            historyDrawerLayer

            // ✅ 视觉导航全屏覆盖层
            if showVisionNav {
                ZStack(alignment: .topLeading) {
                    AIVisionNavView()
                        .ignoresSafeArea()

                    // 回退键
                    Button { showPhoneAgent = true } label: {
                        Image(systemName: "iphone")
                    }
                    .fullScreenCover(isPresented: $showPhoneAgent) {
                        iPhoneAgentView()
                    }
                    Button {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            showVisionNav = false
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .semibold))
                            Text("返回")
                                .font(.system(size: 16, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.45))
                        .clipShape(Capsule())
                        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                    }
                    .padding(.top, 56)
                    .padding(.leading, 16)
                    .buttonStyle(.plain)
                }
                .transition(.move(edge: .trailing))
                .zIndex(10)
            }

            // ✅ ChatGPT-style：点击标题旁 “>” 后，在标题下方弹出紧凑模型/套餐菜单
            if showPlanMenu {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { closePlanMenu() }
                    .zIndex(30)

                planModelMenuOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                    .zIndex(31)
            }
        }
    }

    var body: some View {
        rootContentStack
        // ✅ 统一 sheet：视频生成 / 家居控制
        .sheet(item: $activeSheet) { sheet in
            activeSheetView(for: sheet)
        }

        // ✅ 退出视频页后回到“声音态”则恢复音频通话
        .fullScreenCover(isPresented: $showVideoCall, onDismiss: {
            if composerMode == .voice {
                RealtimeAVService.shared.sessionConversationId = self.currentConversationId ?? ""
            fast.ensureConnected(apiBase: apiBase)
            }
        }) {
            RealtimeAVCallView(apiBase: apiBase, rt: rt, messages: $messages) {
                showVideoCall = false
            }
        }

        // ✅ 局域网电脑控制调试面板（APP -> 后端 -> local-agent -> Mac）
        .fullScreenCover(isPresented: $showComputerDebugPanel) {
            LocalAgentComputerDebugPanel(
                backendBase: apiBase,
                pendingInstruction: $pendingComputerControlInstruction,
                computerControlMode: $computerControlMode,
                onClose: {
                    showComputerDebugPanel = false
                    computerControlMode = false
                }
            )
        }
        .sheet(isPresented: $showBodyDebugPanel) {
            ComputerBodyDebugView(onClose: { showBodyDebugPanel = false })
        }

        // ⚠️ fullScreenCover(showComputerControl) 已经移除。
        //    电脑控制不再是独立全屏页;现在通过 surfaceMode == .computer 嵌入到 chatScreen 上半部分。
        //    入口按钮已改为 `surfaceMode = .computer`,返回按钮设回 `.chat`。

        .onChange(of: hasProEntitlement) { _ in
            // ✅ 四套餐开放选择：订阅状态不再强制改写用户当前选择。
            pendingPlanAfterPurchase = nil
        }
        .onChange(of: plus.pending.count) { newCount in
            enforceGuestPlusLimitIfNeeded(currentCount: newCount)
        }
        .onChange(of: rt.status) { newValue in
            computerVoiceStatus.realtimeStatus = newValue
        }
        .onChange(of: rt.isConnected) { newValue in
            computerVoiceStatus.isRealtimeConnected = newValue
            if surfaceMode == .computer {
                if newValue, computerVoiceStatus.executionState == .connecting {
                    computerVoiceStatus.executionState = .listening
                } else if !newValue, !computerVoiceStatus.isExecuting {
                    computerVoiceStatus.executionState = .idle
                }
            }
        }

        .onReceive(NotificationCenter.default.publisher(for: .aduRealtimeSemanticInterrupt)) { _ in
            // ✅ 语义打断：旧 assistant 气泡立即冻结；控制符不进入 UI，新回答会从新气泡继续。
            if let id = rtAssistantId {
                updateMessage(id: id) {
                    $0.isTypingCursor = false
                }
            }
            rtAssistantId = nil
            pinnedAssistantId = nil
            scheduleScrollNow(to: .bottom, anchor: .bottom)
        }

        // ✅ 账号中心 -> 付费墙：AccountCenterView 点"升级 / 订阅"按钮触发
        .onReceive(NotificationCenter.default.publisher(for: .openPaywall)) { note in
            // 先关闭账号面板（如果在前台）
            if activeSheet == .account {
                activeSheet = nil
            }
            // 0.35 秒后弹付费墙（等账号面板关闭动画结束，避免双层 sheet 冲突）
            let reasonRaw = (note.userInfo?["reason"] as? String) ?? PaywallReason.generic.rawValue
            let reason = PaywallReason(rawValue: reasonRaw) ?? .generic
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                showProPaywall(reason: reason)
            }
        }

        .onAppear {
            // ✅ 防御:iOS 26 scene 恢复会把上次的 fullScreenCover 也带回来,
            //    导致冷启动直接卡在电脑控制页。这里强制把所有 overlay 状态归零,
            //    保证 ChatAGI 主页面永远是第一屏,电脑控制只能由用户主动点击进入。
            showComputerControl = false
            showComputerDebugPanel = false
            computerControlMode = false
            computerVoiceExecutionTask?.cancel()
            computerVoiceExecutionTask = nil
            computerVoiceExecutionId = nil
            computerVoiceStatus = ComputerControlVoiceStatus()
            surfaceMode = .chat   // ← 上半部分一律先回到聊天

            // ✅ 四套餐开放选择：只在本地缓存异常时回到 Guest，不再按订阅状态降级。
            if PlanOption(rawValue: selectedPlanRaw) == nil {
                selectedPlanRaw = PlanOption.guest.rawValue
            }
            lastObservedPlusPendingCount = plus.pending.count

            fast.configure(apiBase: apiBase)
            configureRealtimeForCurrentPlan()
            prewarmChatAGINativeRealtimeIfNeeded()

            // ✅ Home 状态探测需要知道当前 apiBase
            homeEntryVM.configure(apiBase: apiBase)
            homeEntryVM.refresh()
            Task { @MainActor in
                await refreshRobotBrainStatus()
            }

            // ✅ 感知模块：请求定位权限 + 首次读取
            AduPerceptionBootstrap.setup()

            // ✅ (+) 内部错误统一走 system message（不在各处散落）
            plus.onErrorMessage = { msg in
                Task { @MainActor in
                    self.messages.append(.init(role: .system, text: msg))
                    self.scheduleScrollNow(to: .bottom, anchor: .bottom)
                }
            }

            // ⚠️ 不在主页 .task 自动 bootstrap 微信式 P2P 聊天 ——
            // 后端 /auth/login 已废弃为 /v2/auth/login 且 body 模型不兼容，
            // 自动调用只会刷 404 噪声而 wechatStore 在 WeChat 子视图自己的
            // .task 里也会 bootstrap，按需触发即可。
            // Task { @MainActor in
            //     await wechatStore.bootstrap(apiBase: apiBase)
            // }

            // ✅ realtime 文本写回 messages（回到聊天态可见）
            rt.onUserTranscript = { text in
                Task { @MainActor in
                    let uid = UUID()
                    self.messages.append(.init(id: uid, role: .user, text: text))

                    self.pinnedUserId = uid
                    self.pinnedAssistantId = nil
                    self.rtLastUserText = text

                    self.scheduleScrollNow(to: .bottom, anchor: .bottom)

                    if self.isRobotMode {
                        await self.routeRobotPlannerInput(text, existingUserMessageId: uid, source: "realtime_voice")
                        return
                    }

                    if self.surfaceMode == .computer {
                        await self.routeComputerControlRealtimeUtterance(text, existingUserMessageId: uid)
                        return
                    }

                    if self.isComputerControlOpenCommand(text) {
                        self.openComputerControlPanel()
                        return
                    }

                    if self.computerControlMode {
                        self.pendingComputerControlInstruction = text
                        self.showComputerDebugPanel = true
                        return
                    }

                    // 🔥 核心：语音/音视频 → 统一入口 /api/brain/adu/act
                    guard self.looksLikeComputerTask(text) else { return }

                    let assistantId = UUID()
                    self.messages.append(.init(
                        id: assistantId,
                        role: .assistant,
                        text: "正在执行电脑操作…",
                        isTypingCursor: true
                    ))
                    self.pinnedAssistantId = assistantId

                    do {
                        let aduSource = self.showVideoCall ? "realtime_av" : "realtime_voice"
                        let resp = try await self.submitComputerTask(goal: text, source: aduSource)

                        if resp.route == "chat" {
                            // realtime 链路已并行处理聊天回复，这里不再叠加
                            self.messages.removeAll { $0.id == assistantId }
                            if self.pinnedAssistantId == assistantId { self.pinnedAssistantId = nil }
                            return
                        }

                        self.updateMessage(id: assistantId) {
                            $0.text = resp.finalText ?? "电脑动作已执行。"
                            $0.isTypingCursor = false
                        }

                    } catch {
                        self.updateMessage(id: assistantId) {
                            $0.text = friendlyNetworkMessage(error)
                            $0.isTypingCursor = false
                        }
                    }
                }
            }

rt.onAssistantPartial = { partial in
    Task { @MainActor in
        guard self.surfaceMode != .computer else { return }
        if self.rtAssistantId == nil {
            let id = UUID()
            self.rtAssistantId = id
            self.messages.append(.init(id: id, role: .assistant, text: "", isTypingCursor: true))
        }
        guard let id = self.rtAssistantId else { return }
        self.updateMessage(id: id) {
            $0.text = partial
            $0.isTypingCursor = true
        }

        // ✅ 始终跟随最新输出（避免滚动跳回开头）
        self.scheduleScroll()
}
}

rt.onAssistantFinal = { final in
    Task { @MainActor in
        guard self.surfaceMode != .computer else { return }
        if self.rtAssistantId == nil {
            let id = UUID()
            self.rtAssistantId = id
            self.messages.append(.init(id: id, role: .assistant, text: "", isTypingCursor: true))
        }
        guard let id = self.rtAssistantId else { return }
        self.updateMessage(id: id) {
            $0.text = final
            $0.isTypingCursor = false
        }
        self.rtAssistantId = nil

        // ✅ 最终输出后滚动到最新
        self.scheduleScrollNow(to: .bottom, anchor: .bottom)

        // ✅ 提交 turn commit — 语音对话持久化（与文本聊天共用同一个会话）
        let userText = self.rtLastUserText
        let assistantText = final
        let cid = self.currentConversationId ?? ""
        let clientIdVal = self.clientId
        self.rtLastUserText = ""

        if !userText.isEmpty || !assistantText.isEmpty {
            Task {
                if let newCid = await Self.commitRealtimeTurn(
                    apiBase: AppConfig.API.apiBase,
                    clientId: clientIdVal,
                    conversationId: cid,
                    userText: userText,
                    assistantText: assistantText
                ) {
                    await MainActor.run {
                        if self.currentConversationId == nil || self.currentConversationId?.isEmpty == true {
                            self.currentConversationId = newCid
                        }
                        RealtimeAVService.shared.sessionConversationId = newCid
                    }
                }
            }
        }
    }
}
// ⚠️ 不要直接覆盖 rt.onError，否则会把 FastLane 的“错误过滤/稳态重连”逻辑冲掉。
            fast.setOnError { err in
                Task { @MainActor in
                    // ✅ 七：不再一失败就刷很多条“网络问题”。与上一条相同则不重复追加（连接风暴时只留一条）。
                    if self.messages.last?.text == "网络问题，稍后再试。" { return }
                    self.messages.append(.init(role: .system, text: "网络问题，稍后再试。"))
                    self.scheduleScrollNow(to: .bottom, anchor: .bottom)
                }
            }
        }


    }

    // ✅ 统一 sheet 内容：从 body 的 .sheet(item:) 闭包里拆出来，
    //    避免 SwiftUI body 单表达式类型检查超时（unable to type-check in reasonable time）。
    @ViewBuilder
    private func activeSheetView(for sheet: ActiveSheet) -> some View {
        switch sheet {

        case .legacyVideo:
            RootPagerView(startIndex: 3)

        case .wechatHome:
            // ✅ 子模块 2：微信式骨架（后续逐步升级）
            HomeChatView2(
                apiBase: apiBase,
                store: wechatStore,
                onOpenGPT: {
                    activeSheet = nil
                },
                onOpenHomeLegacy: {
                    activeSheet = .homeControlLegacy
                }
            )

        case .homeControlLegacy:
            HAHomeVoiceControlView()

        case .visionNav:
            AIVisionNavView()

        case .account:
            AccountGateView(apiBase: apiBase)
                .environmentObject(AccountManager.shared)

        case .planPicker:
            PlanPickerSheet(
                selectedPlanRaw: $selectedPlanRaw,
                isPro: hasProEntitlement,
                onRequirePro: { lockedPlan in
                    pendingPlanAfterPurchase = lockedPlan
                    showProPaywall(reason: .generic)
                }
            )
        }
    }



    // MARK: - History Drawer（ChatGPT 半边页侧栏）

    private var historyDrawerWidth: CGFloat {
        // ChatGPT iPhone 侧栏视觉上约 80% 宽度；限制最大宽度避免 iPad 过宽
        min(UIScreen.main.bounds.width * 0.82, 420)
    }

    private var historyDrawerOffsetX: CGFloat {
        let w = historyDrawerWidth
        // open: base = 0；closed: base = -w
        let base: CGFloat = historyDrawerOpen ? 0 : -w
        let raw = base + historyDrawerDragX
        return max(-w, min(0, raw))
    }

    private var historyDrawerProgress: CGFloat {
        let w = historyDrawerWidth
        guard w > 0 else { return 0 }
        // 0=完全隐藏, 1=完全展开
        return 1 - abs(historyDrawerOffsetX) / w
    }

    /// ✅ ChatGPT-style 左侧抽屉：点击汉堡键 / 右划打开；左划 / 点空白关闭
    private var historyDrawerLayer: some View {
        let w = historyDrawerWidth
        let progress = historyDrawerProgress

        return ZStack(alignment: .leading) {

            // 右侧遮罩（点击关闭）
            if progress > 0.001 {
                Color.black.opacity(Double(progress) * 0.28)
                    .ignoresSafeArea()
                    .onTapGesture {
                        closeHistoryDrawer()
                    }
                    .transition(.opacity)
            }

            // 左侧抽屉内容
            ConversationHistorySheetView(
                apiBase: apiBase,
                currentConversationId: $currentConversationId,
                messages: $messages,
                pinnedUserId: $pinnedUserId,
                pinnedAssistantId: $pinnedAssistantId,
                onConversationLoaded: {
                    // ✅ 打开历史会话后：自动回到当前轮（不需要手动划找气泡/文本）
                    scheduleScrollNow(to: .bottom, anchor: .bottom)
                },
                onDismiss: {
                    closeHistoryDrawer()
                }
            )
            .frame(width: w)
            .frame(maxHeight: .infinity)
            .background(Color.white)
            .offset(x: historyDrawerOffsetX)
            .shadow(color: Color.black.opacity(0.18), radius: 18, x: 8, y: 0)
            .gesture(historyDrawerDragGesture)
        }
        // 仅在抽屉可见时接管触控（避免挡住聊天界面滚动）
        .allowsHitTesting(progress > 0.001)
        // 抽屉关闭时：左侧 22pt 边缘区域支持右划打开
        .overlay(alignment: .leading) {
            if !historyDrawerOpen && !historyDrawerDragging {
                Color.clear
                    .frame(width: 22)
                    .contentShape(Rectangle())
                    .gesture(historyEdgeOpenGesture)
                    .ignoresSafeArea()
            }
        }
        .animation(.easeInOut(duration: 0.18), value: historyDrawerOpen)
    }

    /// ✅ Ultra：从屏幕右边缘左划进入视觉导航页
    private var navEdgeSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onEnded { value in
                // 必须从右边缘起手，且向左滑动超过 60pt
                guard value.startLocation.x >= UIScreen.main.bounds.width - 22 else { return }
                guard value.translation.width < -60 else { return }
                withAnimation(.easeInOut(duration: 0.22)) {
                    showVisionNav = true
                }
            }
    }

    /// 关闭状态：从屏幕左边缘右划打开
    private var historyEdgeOpenGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                // 必须从左侧边缘起手（避免影响 ScrollView 左右滑动）
                guard value.startLocation.x <= 22 else { return }
                historyDrawerDragging = true
                let w = historyDrawerWidth
                historyDrawerDragX = min(max(value.translation.width, 0), w)
            }
            .onEnded { value in
                guard historyDrawerDragging else { return }
                let w = historyDrawerWidth
                let predicted = min(max(value.predictedEndTranslation.width, 0), w)
                let shouldOpen = predicted > (w * 0.35)

                historyDrawerDragX = 0
                historyDrawerDragging = false

                withAnimation(.easeInOut(duration: 0.18)) {
                    historyDrawerOpen = shouldOpen
                }
            }
    }

    /// 打开状态：在抽屉上左划关闭（可交互拖拽）
    private var historyDrawerDragGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                historyDrawerDragging = true
                let w = historyDrawerWidth

                if historyDrawerOpen {
                    // 只允许向左拖（负值），最大拖到 -w
                    historyDrawerDragX = max(min(value.translation.width, 0), -w)
                } else {
                    // 理论上不会走到（抽屉关闭时 hit-testing 为 false），保底
                    historyDrawerDragX = min(max(value.translation.width, 0), w)
                }
            }
            .onEnded { value in
                let w = historyDrawerWidth

                if historyDrawerOpen {
                    let predicted = max(min(value.predictedEndTranslation.width, 0), -w)
                    let shouldClose = predicted < -(w * 0.35)

                    historyDrawerDragX = 0
                    historyDrawerDragging = false

                    withAnimation(.easeInOut(duration: 0.18)) {
                        historyDrawerOpen = !shouldClose
                    }
                } else {
                    let predicted = min(max(value.predictedEndTranslation.width, 0), w)
                    let shouldOpen = predicted > (w * 0.35)

                    historyDrawerDragX = 0
                    historyDrawerDragging = false

                    withAnimation(.easeInOut(duration: 0.18)) {
                        historyDrawerOpen = shouldOpen
                    }
                }
            }
    }

    private func togglePlanMenu() {
        focused = false
        historyDrawerDragX = 0
        historyDrawerDragging = false
        historyDrawerOpen = false
        withAnimation(.spring(response: 0.24, dampingFraction: 0.92)) {
            showPlanMenu.toggle()
        }
    }

    private func closePlanMenu() {
        guard showPlanMenu else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            showPlanMenu = false
        }
    }

    private func openHistoryDrawer() {
        // 打开抽屉时收起键盘（ChatGPT 同款行为）
        closePlanMenu()
        focused = false
        historyDrawerDragX = 0
        historyDrawerDragging = false
        withAnimation(.easeInOut(duration: 0.18)) {
            historyDrawerOpen = true
        }
    }

    private func closeHistoryDrawer() {
        historyDrawerDragX = 0
        historyDrawerDragging = false
        withAnimation(.easeInOut(duration: 0.18)) {
            historyDrawerOpen = false
        }
    }
    // MARK: - Chat Screen

    private var chatScreen: some View {
        VStack(spacing: 0) {
            if surfaceMode == .chat {
                topBar
                    .zIndex(22)
                Divider().opacity(0.15)
                chatList
            } else {
                // 上半部分:电脑控制嵌入面板。自带 Mac/Backend/Codex 状态、实时截图、
                // 阿杜判断卡片、内部任务栏、自动化编程、Codex 输出、返回聊天按钮。
                ComputerControlHomeView(
                    apiBase: apiBase,
                    onClose: { leaveComputerControlSurface() },
                    voiceStatus: computerVoiceStatus,
                    onStartVoiceControl: { startComputerControlVoice() },
                    onStopVoiceControl: { stopComputerControlVoice() },
                    onCancelVoiceExecution: { cancelComputerVoiceExecution() },
                    aduContext: aduContext
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: surfaceMode)
        .safeAreaInset(edge: .bottom) {
            chatGPTChatInputBar
        }
        // ✅ 读取输入栏高度（用于动态“轻量回退”）
        .onPreferenceChange(InputBarHeightKey.self) { h in
            if h > 0, abs(h - inputBarHeight) > 0.5 {
                inputBarHeight = h
            }
        }
        .onDisappear {
            // 离开页面时停掉语音播放/播报（避免后台继续）
            audioPlayer.stop()
            speechPlayer.stop()
            liveTTSPlayer.stop()
            revealTask?.cancel(); revealTask = nil
            revealTaskMessageId = nil
            revealFullText.removeAll()

            // ✅ 取消播报预取任务
            for (_, t) in ttsPrefetchTask { t.cancel() }
            ttsPrefetchTask.removeAll()
            ttsPreparing.removeAll()
            ttsPreparedURL.removeAll()
        }
    }

    // MARK: - Voice Screen

    private var voiceScreen: some View {
        VStack(spacing: 0) {
            voiceTopBar
            Divider().opacity(0.15)

            // ✅ 语音通话态也展示聊天文本（用户转写/助手回复会实时写回 messages）
            ZStack {
                chatList

                // 空态：没有任何用户/助手文本时居中提示
                if messages.filter({ ($0.role == .user || $0.role == .assistant) && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }).isEmpty {
                    VStack(spacing: 10) {
                        Text("开始说话")
                            .font(.system(size: 29, weight: .semibold))
                            .foregroundColor(.gray.opacity(0.70))

                        Text(rt.status)
                            .font(.system(size: 14))
                            .foregroundColor(.gray.opacity(0.7))
                    }
                    .padding(.horizontal, 24)
                } else {
                    // 有文本时：顶部小状态条，不遮挡聊天内容
                    VStack {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(rt.isConnected ? Color.green : Color.gray.opacity(0.6))
                                .frame(width: 8, height: 8)

                            Text(rt.status)
                                .font(.system(size: 12))
                                .foregroundColor(.gray.opacity(0.75))

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 10)

                        Spacer()
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            chatGPTVoiceBottomBar
        }
        .onAppear {
            // ✅ 极速接通：只要进来就确保已连接（内部会判断是否已经 connected）
            if entitledPlan == .pro {
                let recentlyStarted = lastChatAGINativeVoiceStartAt
                    .map { Date().timeIntervalSince($0) < 2.0 } ?? false
                if !recentlyStarted {
                    startChatAGINativeRealtimeFromVoiceButton()
                }
            } else {
                configureRealtimeForCurrentPlan()
                fast.ensureConnected(apiBase: apiBase)
            }

            // ✅ 通话态优先级最高：确保本地播放都停掉
            audioPlayer.stop()
            speechPlayer.stop()
            liveTTSPlayer.stop()
            revealTask?.cancel(); revealTask = nil
            revealTaskMessageId = nil
            revealFullText.removeAll()
            if audioNote.isRecording { audioNote.cancel() }

            // ✅ 进声音页时默认滚到最新（方便直接看到转写/回复）
            scheduleScrollNow(to: .bottom, anchor: .bottom)
        }
    }

// MARK: - Top Bars

    /// ✅ ChatGPT-style 标题下拉菜单：不是底部大 Sheet，而是标题旁 “>” 弹出的紧凑浮层。
    private var planModelMenuOverlay: some View {
        GeometryReader { geo in
            let menuWidth = min(max(260, geo.size.width * 0.68), 300)
            let leading = min(max(geo.size.width * 0.18, 56), geo.size.width - menuWidth - 14)
            let top = geo.safeAreaInsets.top + 54

            VStack(alignment: .leading, spacing: 0) {
                Text("套餐 / 模型")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 20)
                    .frame(height: 42, alignment: .center)

                Divider().opacity(0.55)

                ForEach(PlanOption.allCases) { plan in
                    planModelMenuRow(plan)

                    if plan.id != PlanOption.allCases.last?.id {
                        Divider()
                            .padding(.leading, 20)
                            .opacity(0.48)
                    }
                }

                Rectangle()
                    .fill(Color.black.opacity(0.045))
                    .frame(height: 8)

                Button {
                    HomeHaptics.light()
                    closePlanMenu()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        activeSheet = .planPicker
                    }
                } label: {
                    HStack(spacing: 10) {
                        Text("配置")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.black)
                        Spacer(minLength: 12)
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.black)
                    }
                    .padding(.horizontal, 20)
                    .frame(height: 58)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(width: menuWidth)
            .background(Color.white.opacity(0.98))
            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(Color.black.opacity(0.07), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.14), radius: 24, x: 0, y: 12)
            .offset(x: leading, y: top)
        }
    }

    private func planModelMenuRow(_ plan: PlanOption) -> some View {
        let isSelected = plan == selectedPlan

        return Button {
            HomeHaptics.light()
            selectedPlanRaw = plan.rawValue
            RealtimeAVService.shared.preferredProvider = (plan == .guest || plan == .ultra || plan == .coder) ? "openai" : "qwen"
            RealtimeAVService.shared.realtimePlan = (plan == .coder) ? "coder" : ((plan == .ultra) ? "ultra" : ((plan == .pro) ? "pro" : "guest"))
            if plan == .pro {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    prewarmChatAGINativeRealtimeIfNeeded()
                }
            }
            closePlanMenu()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(plan.title)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(.black)
                        .lineLimit(1)

                    Text(plan.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 12)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.black)
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 62)
            .contentShape(Rectangle())
            .background(isSelected ? Color.black.opacity(0.035) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private var planPickerButton: some View {
        Button {
            HomeHaptics.light()
            activeSheet = .planPicker
        } label: {
            HStack(spacing: 7) {
                Image(systemName: selectedPlan.iconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color.blue)

                VStack(alignment: .leading, spacing: 1) {
                    Text(selectedPlan.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.black)
                        .lineLimit(1)
                    Text(entitledPlan.displayName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.gray.opacity(0.85))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(white: 0.92))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.black.opacity(0.08), lineWidth: 0.8)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: Color.black.opacity(0.04), radius: 1.2, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("选择套餐和模型：\(selectedPlan.title)，\(entitledPlan.displayName)")
    }



/// ✅ 模型/套餐选择框：放在“文本显示区”正上方，居中（对齐 ChatGPT）
private var planPickerCenterBar: some View {
    HStack {
        Spacer(minLength: 0)
        planPickerButton
        Spacer(minLength: 0)
    }
    .padding(.top, 8)
    .padding(.bottom, 10)
    .background(Color.white)
}


private struct PlanPickerSheet: View {
    @Binding var selectedPlanRaw: String
    let isPro: Bool
    let onRequirePro: (PlanOption) -> Void

    @Environment(\.dismiss) private var dismiss

    private var currentPlan: PlanOption {
        PlanOption(rawValue: selectedPlanRaw) ?? .guest
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("选择套餐 / 模型")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(.black)
                    Text("四个套餐已全部开放，可以直接切换当前聊天使用的模型。")
                        .font(.system(size: 14))
                        .foregroundColor(.gray)
                        .lineSpacing(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(Color.black.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                VStack(spacing: 10) {
                    ForEach(PlanOption.allCases) { plan in
                        Button {
                            HomeHaptics.light()
                            selectedPlanRaw = plan.rawValue
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: plan.iconName)
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(plan == currentPlan ? .white : .black)
                                    .frame(width: 34, height: 34)
                                    .background(plan == currentPlan ? Color.black : Color.black.opacity(0.06))
                                    .clipShape(Circle())

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 8) {
                                        Text(plan.title)
                                            .font(.system(size: 16, weight: .bold))
                                            .foregroundColor(.black)
                                        Text(plan.displayName)
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundColor(.blue)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 3)
                                            .background(Color.blue.opacity(0.10))
                                            .clipShape(Capsule())
                                    }
                                    Text(plan.subtitle)
                                        .font(.system(size: 13))
                                        .foregroundColor(.gray)
                                }

                                Spacer(minLength: 8)

                                Image(systemName: plan == currentPlan ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundColor(plan == currentPlan ? .blue : .gray.opacity(0.55))
                            }
                            .padding(14)
                            .background(plan == currentPlan ? Color.blue.opacity(0.08) : Color.black.opacity(0.035))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(plan == currentPlan ? Color.blue.opacity(0.38) : Color.black.opacity(0.06), lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text("当前选择会随 /chat/prepare payload 一起发送：plan = 当前套餐，model = 当前套餐对应模型。")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                    .lineSpacing(3)
                    .padding(.top, 4)

                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("模型选择")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .applyPlanPickerDetentsIfAvailable()
    }
}




    private var topBar: some View {
        HStack(spacing: 10) {

            Button {
                HomeHaptics.light()
                openHistoryDrawer()
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)

            // ✅ ChatGPT-style：品牌标题旁放 “>”，点击弹出紧凑套餐/模型选择框
            Button {
                HomeHaptics.light()
                togglePlanMenu()
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text("ChatAGI-阿杜")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(.black)
                            .lineLimit(1)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.black.opacity(0.72))
                            .rotationEffect(.degrees(showPlanMenu ? 90 : 0))
                    }

                    Text(isRobotMode ? "Ultra · 机器人 6.2 · 六足已接入" : "\(selectedPlan.title) · \(entitledPlan.displayName)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(isRobotMode ? Color.red.opacity(0.85) : Color(red: 0, green: 0.7, blue: 0.35))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button {
                HomeHaptics.light()
                openHistoryDrawer()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)

            // ✅ 返回太阳系门户
            Button {
                closePlanMenu()
                HomeHaptics.light()
                NotificationCenter.default.post(name: .returnToPortal, object: nil)
            } label: {
                Image(systemName: "globe.asia.australia.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color(red: 0.31, green: 0.90, blue: 0.76),
                                Color(red: 1.0, green: 0.66, blue: 0.20)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)

            // ✅ 右上角合并：长按弹菜单（历史 / 返回太阳系），单击进账号中心
            Menu {
                Button {
                    closePlanMenu()
                    HomeHaptics.light()
                    activeSheet = .account
                } label: {
                    Label(AccountManager.shared.isSignedIn ? "账号中心" : "登录 / 注册",
                          systemImage: AccountManager.shared.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle.badge.plus")
                }
                Button {
                    HomeHaptics.light()
                    openHistoryDrawer()
                } label: {
                    Label("历史记录", systemImage: "clock")
                }
                Button {
                    closePlanMenu()
                    HomeHaptics.light()
                    NotificationCenter.default.post(name: .returnToPortal, object: nil)
                } label: {
                    Label("返回太阳系", systemImage: "globe.asia.australia.fill")
                }
            } label: {
                AccountAvatarBadge()
                    .frame(width: 36, height: 36)
            } primaryAction: {
                closePlanMenu()
                HomeHaptics.light()
                activeSheet = .account
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white)
    }

    private var voiceTopBar: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("ChatAGI-阿杜")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.black)
                Text("声音模式")
                    .font(.system(size: 12))
                    .foregroundColor(Color(red: 0, green: 0.7, blue: 0.35))
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 2)
        .padding(.bottom, 6)
        .background(Color.white)
    }

    // MARK: - Chat List

    private struct BottomOffsetKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }

    private struct PinnedUserHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }

    private struct InputBarHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }

    
    
    // MARK: - Chat list（栏板隔离：历史在上，新主页面在下，像 ChatGPT 但“每轮”固定在新页顶部）

    /// ✅ 历史区：置顶用户气泡之前的所有内容（旧的用户+助手气泡不会删除，而是被推上去）
    private var historyMessages: [ChatMessage] {
        guard let pid = pinnedUserId,
              let idx = messages.firstIndex(where: { $0.id == pid })
        else { return [] }
        if idx > messages.startIndex {
            return Array(messages[..<idx])
        } else {
            return []
        }
    }

    /// ✅ 新主页面：栏板下方，只显示“这一轮”（置顶用户气泡及其后续助手回复等）
    private var scrolledMessages: [ChatMessage] {
        guard let pid = pinnedUserId,
              let idx = messages.firstIndex(where: { $0.id == pid })
        else { return messages }
        let start = idx
        if start < messages.endIndex {
            return Array(messages[start...])
        } else {
            return []
        }
    }

    /// ✅ 栏板：隔离“历史区”和“新主页面”
    private var isolationBoard: some View {
        HStack {
            Spacer()
            Capsule()
                .fill(Color.black.opacity(0.12))
                .frame(width: 72, height: 6)
            Spacer()
        }
        .padding(.vertical, 10)
        .accessibilityLabel("历史与新消息分隔")
    }

    private var chatList: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {

                        // ✅ 1) 历史区（可下拉查看全部内容）
                        if !historyMessages.isEmpty {
                            ForEach(historyMessages) { msg in
                                row(for: msg)
                                    .transaction { $0.animation = nil }
                                    .id(ScrollTarget.msg(msg.id))
                            }
                        }

                        // ✅ 2) 新主页面：最少占满一屏，保证“这一轮”的用户气泡总是出现在栏板下方的右上角
                        VStack(alignment: .leading, spacing: 14) {
                            // ✅ 栏板：固定在“新主页面”顶部，用来隔离新旧气泡
                            if pinnedUserMessage != nil {
                                isolationBoard
                                    .transaction { $0.animation = nil }
                            }

                            ForEach(scrolledMessages) { msg in
                                row(for: msg)
                                    .transaction { $0.animation = nil }
                                    .id(ScrollTarget.msg(msg.id))
                            }

                            // ✅ 让“新主页面”占满可视高度：内容少时，把底部空白撑出来，顶部锚定不变
                            Spacer(minLength: 0)

                            // ✅ 底部留一点空白，避免新消息被输入框盖住
                            Color.clear.frame(height: bottomBreathingSpace)

                            Color.clear
                                .frame(height: 1)
                                .id(ScrollTarget.bottom)
                                .background(
                                    GeometryReader { geo in
                                        Color.clear
                                            .preference(key: BottomOffsetKey.self,
                                                        value: geo.frame(in: .named("scroll")).minY)
                                    }
                                )
                        }
                        .frame(minHeight: outer.size.height, alignment: .top)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 0)
                }
                .coordinateSpace(name: "scroll")
                .onPreferenceChange(BottomOffsetKey.self) { bottomY in
                    // ✅ “历史文本推上去”：只有用户在底部时才自动跟随
                    let h = outer.size.height
                    let threshold: CGFloat = 120
                    isAtBottom = (bottomY <= (h + threshold))
                }
                .onChange(of: scrollTick) { _, _ in
                    var tx = Transaction()
                    tx.disablesAnimations = true
                    withTransaction(tx) {
                        proxy.scrollTo(scrollTarget, anchor: scrollAnchor)
                    }
                }
            }
        }
    }

    private func robotActionsCard(_ plan: RobotBrainPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: plan.need_confirm ? "exclamationmark.triangle.fill" : "figure.walk.motion")
                    .font(.system(size: 12, weight: .semibold))
                Text(plan.need_confirm ? "待确认动作" : "六足动作")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Text(plan.executed == true ? "已执行" : "未执行")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }

            let prefix = plan.executed == true ? "已执行：" : "计划："
            Text(prefix + plan.actions.map(\.displayText).joined(separator: "、"))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.black.opacity(0.82))
                .lineLimit(3)

            if let skillId = plan.skill_id, !skillId.isEmpty {
                Text("skill_id = \(skillId)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            if let message = plan.message, !message.isEmpty {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(plan.need_confirm ? .orange : .secondary)
            }

            HStack(spacing: 8) {
                Button {
                    Task { @MainActor in
                        await executeRobotPreview(plan)
                    }
                } label: {
                    Label("执行本轮动作", systemImage: "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Color.black)
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(plan.perceptionPayload == nil || plan.executed == true || robotPlannerBusy)

                Button {} label: {
                    Label("自主运行", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.06))
                        .foregroundColor(.secondary)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(true)
            }
        }
        .padding(10)
        .background(Color.black.opacity(0.045))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(plan.need_confirm ? Color.orange.opacity(0.35) : Color.black.opacity(0.08), lineWidth: 0.8)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }




    @ViewBuilder
    private func row(for msg: ChatMessage) -> some View {
        switch msg.role {
        case .assistant:
            let raw = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let isThinking = msg.isTypingCursor && (raw == "正在思考中…" || raw == "正在思考中..." || raw.contains("正在思考"))
            let preparedURL = ttsPreparedURL[msg.id]
            let isPlayingThis = (speechPlayer.activeId == msg.id) && speechPlayer.isSpeaking
            let isMutedThis = mutedSpeechMessageIds.contains(msg.id)

            VStack(alignment: .leading, spacing: 8) {

                // ✅ 路由档位胶囊：回复时显示,完成 1.2s 后自动淡出
                if let tier = msg.routeTier, shouldShowRouteTier(msg: msg) {
                    RouteTierCapsule(tier: tier, isLive: msg.isTypingCursor)
                        .animation(.easeInOut(duration: 0.25), value: msg.routeTier)
                }

                // 推理展开框
                if !msg.reasoningText.isEmpty {
                    ReasoningBubble(text: msg.reasoningText, isDone: msg.reasoningDone)
                }

                // 内容（思考中扫光 / Markdown + 光标）
                VStack(alignment: .leading, spacing: 8) {
                    if isThinking && msg.reasoningText.isEmpty {
                        ShimmerThinkingText(text: thinkingPhaseText)
                            .transition(.opacity)
                    } else if !isThinking || !msg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        AssistantMarkdownView(text: msg.text)
                            .transition(.opacity.animation(.easeIn(duration: 0.25)))
                        if msg.isTypingCursor {
                            TypingCursorPill()
                        }
                    }
                }
                .animation(.easeIn(duration: 0.25), value: isThinking)
                .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)

                if let robotPlan = msg.robotPlan {
                    robotActionsCard(robotPlan)
                }

                if let plan = pendingCodexTask, pendingCodexAssistantId == msg.id {
                    codexPlanConfirmationCard(
                        plan: plan,
                        prompt: pendingPrompt,
                        project: pendingProject ?? plan.suggestedProject ?? "GPTsora",
                        riskLevel: pendingRiskLevel,
                        createdAt: pendingCreatedAt,
                        messageId: msg.id
                    )
                }

                // ✅ 文本结束后：在底部显示“单一小喇叭” + 搜索站点图标
                if !callActive, !msg.isTypingCursor, !raw.isEmpty {
                    HStack(spacing: 12) {

                        // 小喇叭：出现即代表可以播报；点“中止”后变成带斜杠
                        
                        // ✅ Copy
                        Button {
                            HomeHaptics.light()
                            UIPasteboard.general.string = raw
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.black)
                        }
                        .buttonStyle(.plain)

                        // ✅ 播报（第 2 个位置，和 ChatGPT 一样）
                        Button {
                            HomeHaptics.light()

                            // 通话中避免抢占 audio session
                            if callActive {
                                messages.append(.init(role: .system, text: "通话进行中：已禁止播报（避免断流）。如需播报请先结束通话。"))
                                scheduleScrollNow(to: .bottom, anchor: .bottom)
                                return
                            }

                            // 正在播/正在加载：视为“中止”
                            if (speechPlayer.activeId == msg.id && speechPlayer.isSpeaking) || (speechPlayer.loadingId == msg.id) {
                                speechPlayer.stop()
                                liveTTSPlayer.stop()
                                mutedSpeechMessageIds.insert(msg.id)
                                Task { @MainActor in
                                    forceRevealFull(for: msg.id)
                                }
                                return
                            }

                            // 开始播报：去掉“斜杠”状态
                            mutedSpeechMessageIds.remove(msg.id)
                            liveTTSPlayer.stop()

                            if let u = preparedURL ?? ttsRemoteURL[msg.id] {
                                speechPlayer.playPrepared(
                                    id: msg.id,
                                    url: u,
                                    fallbackText: raw,
                                    apiBase: apiBase,
                                    voice: autoSpeakVoice,
                                    onError: { err in
                                        Task { @MainActor in
                                            messages.append(.init(role: .system, text: "网络问题，稍后再试。"))
                                            scheduleScrollNow(to: .bottom, anchor: .bottom)
                                        }
                                    }
                                )
                            } else {
                                speechPlayer.toggle(
                                    id: msg.id,
                                    text: raw,
                                    apiBase: apiBase,
                                    voice: autoSpeakVoice,
                                    onError: { err in
                                        Task { @MainActor in
                                            messages.append(.init(role: .system, text: "网络问题，稍后再试。"))
                                            scheduleScrollNow(to: .bottom, anchor: .bottom)
                                        }
                                    }
                                )
                            }
                        } label: {
                            if speechPlayer.loadingId == msg.id {
                                ProgressView()
                                    .scaleEffect(0.85)
                            } else {
                                Image(
                                    systemName: mutedSpeechMessageIds.contains(msg.id)
                                        ? "speaker.slash.fill"
                                        : ((speechPlayer.activeId == msg.id && speechPlayer.isSpeaking)
                                            ? "speaker.wave.2.fill"
                                            : "speaker.wave.2")
                                )
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.black)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                HomeHaptics.light()
                                autoSpeakEnabled.toggle()
                                if !autoSpeakEnabled {
                                    liveTTSPlayer.stop()
                                }
                            } label: {
                                Label("自动播报：" + (autoSpeakEnabled ? "开" : "关"), systemImage: autoSpeakEnabled ? "speaker.wave.2" : "speaker.slash")
                            }
                        }

                        // ✅ Feedback icons (UI-only for now)
                        Button {
                HomeHaptics.light()
                openHistoryDrawer()
            } label: {
                            Image(systemName: "hand.thumbsup")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.black)
                        }
                        .buttonStyle(.plain)

                        Button {
                HomeHaptics.light()
                openHistoryDrawer()
            } label: {
                            Image(systemName: "hand.thumbsdown")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.black)
                        }
                        .buttonStyle(.plain)

                        if !msg.sources.isEmpty {
                            WebSourcesBar(sources: msg.sources)
                        }

                        Spacer()
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .user:
            HStack {
                Spacer(minLength: 8)
                UserBubble(
                    message: msg,
                    callActive: callActive,
                    onBlocked: {
                        Task { @MainActor in
                            messages.append(.init(role: .system, text: "通话进行中：已禁止语音消息播放（避免断流）。如需播放请先结束通话。"))
                            scheduleScrollNow(to: .bottom, anchor: .bottom)
                        }
                    },
                    stopAllSpeech: {
                        speechPlayer.stop()
                        liveTTSPlayer.stop()
                    },
                    audioPlayer: audioPlayer,
                    speechPlayer: speechPlayer
                )
            }
            .frame(maxWidth: CGFloat.infinity, alignment: .trailing)

        case .system:
            Text(msg.renderText)
                .font(.system(size: 14))
                .foregroundColor(.gray)
        }
    }

    @ViewBuilder
    private func codexPlanConfirmationCard(
        plan: AduTaskPlan,
        prompt: String,
        project: String,
        riskLevel: String,
        createdAt: Date?,
        messageId: UUID
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: plan.type == .selfUpgradeTask ? "exclamationmark.triangle" : "hammer")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.black.opacity(0.78))
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.type == .selfUpgradeTask ? "自我升级计划" : "Codex 任务确认")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.black)
                    if let pid = plan.suggestedProjectId, !pid.isEmpty {
                        Text("阿杜自动选择工程: \(pid)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.black.opacity(0.72))
                        Text("\(project) · 风险 \(riskLevel)")
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                    } else {
                        Text("\(project) · 风险 \(riskLevel)")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                    }
                    // V3 新增:阿杜判断原因(planner summary) + 将操作的授权工作区(绝对路径)
                    if !pendingReason.isEmpty {
                        Text("阿杜判断原因: \(pendingReason)")
                            .font(.system(size: 11))
                            .foregroundColor(.black.opacity(0.62))
                            .lineLimit(3)
                    }
                    if !pendingWorkspacePath.isEmpty {
                        Text("将操作的授权工作区: \(pendingWorkspacePath)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.gray)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                if let createdAt {
                    Text(pendingCodexAgeText(createdAt))
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                }
                if codexPlannerRunning {
                    ProgressView().scaleEffect(0.8)
                }
            }

            ScrollView(.vertical, showsIndicators: true) {
                Text(prompt)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.black.opacity(0.82))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 220)
            .background(Color(white: 0.96))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        HomeHaptics.light()
                        editPendingCodexPlan(messageId: messageId)
                    } label: {
                        Label("编辑", systemImage: "pencil")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.black.opacity(0.75))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(white: 0.94))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(codexPlannerRunning)

                    Button {
                        HomeHaptics.light()
                        UIPasteboard.general.string = prompt
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.black.opacity(0.75))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(white: 0.94))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(codexPlannerRunning)

                    Button {
                        HomeHaptics.light()
                        cancelPendingCodexPlan(messageId: messageId)
                    } label: {
                        Label("取消", systemImage: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.black.opacity(0.75))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(white: 0.94))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(codexPlannerRunning)

                    Spacer(minLength: 0)
                }

                Button {
                    HomeHaptics.light()
                    confirmPendingCodexPlan(messageId: messageId)
                } label: {
                    Label(codexPlannerRunning ? "运行中" : "确认运行", systemImage: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(codexPlannerRunning ? Color.gray : Color.black)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(codexPlannerRunning)
            }
        }
        .padding(12)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.black.opacity(0.10), lineWidth: 1)
        )
    }

    private func pendingCodexAgeText(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "刚刚" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)分钟前" }
        return "\(minutes / 60)小时前"
    }

    // MARK: - Web sources bar (OpenAI 原生来源入口)

    private struct WebSourcesBar: View {
        let sources: [WebSource]

        private var deduped: [WebSource] {
            var seen = Set<String>()
            var out: [WebSource] = []
            for s in sources {
                let h = s.normalizedHost
                guard !h.isEmpty else { continue }
                if seen.contains(h) { continue }
                seen.insert(h)
                out.append(s)
                if out.count >= 6 { break }
            }
            return out
        }

        private var firstSourceURL: URL? {
            guard let first = deduped.first else { return nil }
            return URL(string: first.url)
        }

        var body: some View {
            if !deduped.isEmpty {
                Button {
                    HomeHaptics.light()
                    if let u = firstSourceURL {
                        UIApplication.shared.open(u)
                    }
                } label: {
                    HStack(spacing: 7) {
                        OpenAISearchSourceIcon()
                            .frame(width: 22, height: 22)

                        Text("来源")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)

                        if deduped.count > 1 {
                            Text("+\(deduped.count - 1)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.secondary.opacity(0.82))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(white: 0.95))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("OpenAI 搜索来源，共 \(deduped.count) 个来源"))
            }
        }

        /// OpenAI-style source icon, drawn locally in SwiftUI.
        ///
        /// 这里彻底去掉网站 favicon / 站点来源图标逻辑：底部只显示 OpenAI 原生搜索来源入口。
        private struct OpenAISearchSourceIcon: View {
            var body: some View {
                ZStack {
                    Circle()
                        .fill(Color.black)

                    OpenAIKnot()
                        .stroke(
                            Color.white,
                            style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round)
                        )
                        .padding(4.2)
                }
                .accessibilityHidden(true)
            }
        }

        /// A compact OpenAI-knot style glyph.
        /// Six rounded arcs are drawn around the center so it reads as one OpenAI mark,
        /// not as website favicons or stacked domain icons.
        private struct OpenAIKnot: Shape {
            func path(in rect: CGRect) -> Path {
                var p = Path()
                let cx = rect.midX
                let cy = rect.midY
                let r = min(rect.width, rect.height) * 0.34
                let inner = r * 0.58

                for i in 0..<6 {
                    let a0 = CGFloat(i) * (.pi / 3.0) - .pi / 2.0
                    let a1 = a0 + (.pi / 3.0)
                    let mid = a0 + (.pi / 6.0)

                    let start = CGPoint(x: cx + cos(a0) * inner, y: cy + sin(a0) * inner)
                    let end = CGPoint(x: cx + cos(a1) * inner, y: cy + sin(a1) * inner)
                    let c1 = CGPoint(x: cx + cos(mid - 0.22) * r * 1.18, y: cy + sin(mid - 0.22) * r * 1.18)
                    let c2 = CGPoint(x: cx + cos(mid + 0.22) * r * 1.18, y: cy + sin(mid + 0.22) * r * 1.18)

                    p.move(to: start)
                    p.addCurve(to: end, control1: c1, control2: c2)
                }

                return p
            }
        }
    }

    // MARK: - User Bubble (图片直接显示 + 语音可播放)

    private struct UserBubble: View {
        let message: ChatMessage
        let callActive: Bool
        let onBlocked: () -> Void
        let stopAllSpeech: () -> Void
        @ObservedObject var audioPlayer: GlobalAudioPlayer
        @ObservedObject var speechPlayer: GlobalSpeechPlayer

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {

                if !message.attachments.isEmpty {
                    AttachmentsGridView(
                        attachments: message.attachments,
                        callActive: callActive,
                        onBlocked: onBlocked,
                        stopAllSpeech: stopAllSpeech,
                        audioPlayer: audioPlayer,
                        speechPlayer: speechPlayer
                    )
                }

                let rawText = message.renderText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !rawText.isEmpty {
                    Text(message.renderText)
                        .font(.system(size: 17))
                        .foregroundColor(.black)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .contextMenu {
                            Button {
                                HomeHaptics.light()
                                UIPasteboard.general.string = rawText
                            } label: {
                                Label("复制文本", systemImage: "doc.on.doc")
                            }
                        }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(white: 0.92))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private struct AttachmentsGridView: View {
        let attachments: [ChatMessageAttachment]
        let callActive: Bool
        let onBlocked: () -> Void
        let stopAllSpeech: () -> Void
        @ObservedObject var audioPlayer: GlobalAudioPlayer
        @ObservedObject var speechPlayer: GlobalSpeechPlayer

        private var imageAttachments: [ChatMessageAttachment] {
            attachments.filter { if case .image = $0.kind { return true } else { return false } }
        }
        private var audioAttachments: [ChatMessageAttachment] {
            attachments.filter { if case .audio = $0.kind { return true } else { return false } }
        }
        private var fileAttachments: [ChatMessageAttachment] {
            attachments.filter { if case .file = $0.kind { return true } else { return false } }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {

                if !imageAttachments.isEmpty {
                    let cols = [GridItem(.fixed(120), spacing: 8), GridItem(.fixed(120), spacing: 8)]
                    LazyVGrid(columns: cols, alignment: .leading, spacing: 8) {
                        ForEach(imageAttachments) { att in
                            if case .image(let ui) = att.kind {
                                Image(uiImage: ui)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 120, height: 120)
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: Color.black.opacity(0.04), radius: 1.2, x: 0, y: 1)
                                    .contextMenu {
                                        Button {
                                            HomeHaptics.light()
                                            UIPasteboard.general.image = ui
                                        } label: {
                                            Label("复制图片", systemImage: "doc.on.doc")
                                        }
                                    }
                            }
                        }
                    }
                }

                if !audioAttachments.isEmpty {
                    ForEach(audioAttachments) { att in
                        if case .audio(let url, let duration) = att.kind {
                            AudioBubblePlayerRow(
                                callActive: callActive,
                                onBlocked: onBlocked,
                                stopAllSpeech: stopAllSpeech,
                                audioPlayer: audioPlayer,
                                speechPlayer: speechPlayer,
                                attachmentId: att.id,
                                url: url,
                                duration: duration
                            )
                        }
                    }
                }

                if !fileAttachments.isEmpty {
                    ForEach(fileAttachments) { att in
                        if case .file(let url, let filename) = att.kind {
                            FileAttachmentRow(filename: filename, url: url)
                        }
                    }
                }
            }
        }

        private struct FileAttachmentRow: View {
            let filename: String
            let url: URL

            // 图标 + 主色 + 类型标签
            private var fileIcon: (symbol: String, color: Color, label: String) {
                let ext = (filename as NSString).pathExtension.lowercased()
                switch ext {
                case "pdf":              return ("doc.richtext.fill",                    Color(red:0.85,green:0.18,blue:0.18), "PDF")
                case "doc","docx":       return ("doc.fill",                             Color(red:0.18,green:0.40,blue:0.85), "WORD")
                case "xls","xlsx","csv": return ("tablecells.fill",                      Color(red:0.13,green:0.62,blue:0.32), "EXCEL")
                case "ppt","pptx":       return ("chart.bar.doc.horizontal.fill",        Color(red:0.90,green:0.42,blue:0.12), "PPT")
                case "py":               return ("terminal.fill",                        Color(red:0.22,green:0.55,blue:0.78), "PY")
                case "swift":            return ("swift",                                Color(red:0.98,green:0.35,blue:0.18), "SWIFT")
                case "js","jsx":         return ("curlybraces",                          Color(red:0.95,green:0.72,blue:0.10), "JS")
                case "ts","tsx":         return ("curlybraces",                          Color(red:0.29,green:0.56,blue:0.89), "TS")
                case "json":             return ("curlybraces.square.fill",              Color(red:0.55,green:0.38,blue:0.82), "JSON")
                case "html":             return ("globe",                                Color(red:0.18,green:0.58,blue:0.90), "HTML")
                case "css":              return ("paintbrush.fill",                      Color(red:0.26,green:0.62,blue:0.96), "CSS")
                case "xml":              return ("chevron.left.forwardslash.chevron.right", Color(red:0.45,green:0.62,blue:0.32), "XML")
                case "md","txt":         return ("doc.plaintext.fill",                  Color(red:0.45,green:0.45,blue:0.50), "TXT")
                case "zip","tar","gz":   return ("archivebox.fill",                     Color(red:0.60,green:0.48,blue:0.35), "ZIP")
                case "mp3","wav","m4a":  return ("waveform",                            Color(red:0.28,green:0.68,blue:0.78), "AUDIO")
                case "mp4","mov":        return ("video.fill",                          Color(red:0.65,green:0.18,blue:0.85), "VIDEO")
                case "go":               return ("hare.fill",                           Color(red:0.00,green:0.68,blue:0.78), "GO")
                case "rs":               return ("gearshape.fill",                      Color(red:0.72,green:0.25,blue:0.05), "RUST")
                case "kt","java":        return ("cup.and.heat.waves.fill",             Color(red:0.85,green:0.42,blue:0.12), "JAVA")
                default:
                    let lbl = ext.uppercased()
                    return ("doc.fill", Color(red:0.50,green:0.50,blue:0.55), lbl.isEmpty ? "FILE" : lbl)
                }
            }

            private var fileSizeLabel: String {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                if size <= 0 { return "" }
                if size < 1024 { return "\(size) B" }
                if size < 1048576 { return String(format: "%.1f KB", Double(size)/1024) }
                return String(format: "%.1f MB", Double(size)/1_048_576)
            }

            private var baseName: String { (filename as NSString).deletingPathExtension }

            var body: some View {
                Button {
                    HomeHaptics.light()
                    UIApplication.shared.open(url)
                } label: {
                    // ── 书页卡片（ZStack实现右上角翘起折角）────────────
                    ZStack(alignment: .topTrailing) {

                        // 底层：叠错的两张"书页"阴影
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(fileIcon.color.opacity(0.07))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 4)
                            .padding(.trailing, 4)
                            .offset(x: 3, y: 3)

                        // 主卡片
                        HStack(spacing: 12) {

                            // 左侧图标
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(fileIcon.color.opacity(0.13))
                                    .frame(width: 48, height: 48)
                                Image(systemName: fileIcon.symbol)
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundColor(fileIcon.color)
                            }

                            // 文件名 + 类型标签 + 大小
                            VStack(alignment: .leading, spacing: 4) {
                                Text(baseName)
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                    .foregroundColor(Color(red:0.95, green:0.25, blue:0.55))
                                    .lineLimit(1)
                                HStack(spacing: 6) {
                                    Text(fileIcon.label)
                                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                                        .foregroundColor(fileIcon.color)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(fileIcon.color.opacity(0.12))
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                    if !fileSizeLabel.isEmpty {
                                        Text(fileSizeLabel)
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary.opacity(0.6))
                                    }
                                }
                            }

                            Spacer(minLength: 0)

                            // 右侧「打开」按钮
                            Text("打开")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(fileIcon.color)
                                .clipShape(Capsule())
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color(.systemBackground))
                                .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 4)
                                .shadow(color: fileIcon.color.opacity(0.12), radius: 10, x: 0, y: 5)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(fileIcon.color.opacity(0.15), lineWidth: 1)
                        )

                        // ── 右上角折角（书本翻开效果）────────────────────
                        ZStack {
                            // 折角底层
                            BookPageCorner()
                                .fill(fileIcon.color.opacity(0.18))
                                .frame(width: 24, height: 24)
                            // 折角高光线
                            BookPageCorner()
                                .stroke(fileIcon.color.opacity(0.35), lineWidth: 0.8)
                                .frame(width: 24, height: 24)
                        }
                        .offset(x: 0, y: 0)
                    }
                }
                .buttonStyle(.plain)
            }
        }

        // 右上角折页三角
        private struct BookPageCorner: Shape {
            func path(in rect: CGRect) -> Path {
                var p = Path()
                p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
                p.closeSubpath()
                return p
            }
        }
    }

    // MARK: - Audio bubble player row

    private struct AudioBubblePlayerRow: View {
        let callActive: Bool
        let onBlocked: () -> Void
        let stopAllSpeech: () -> Void
        @ObservedObject var audioPlayer: GlobalAudioPlayer
        @ObservedObject var speechPlayer: GlobalSpeechPlayer
        let attachmentId: UUID
        let url: URL
        let duration: TimeInterval

        private var isActive: Bool { audioPlayer.activeId == attachmentId }
        private var isPlaying: Bool { isActive && audioPlayer.isPlaying }

        private var progress: CGFloat {
            guard isActive else { return 0 }
            let d = max(0.001, audioPlayer.duration > 0 ? audioPlayer.duration : duration)
            return CGFloat(min(1, max(0, audioPlayer.currentTime / d)))
        }

        private var timeText: String {
            let d = isActive && audioPlayer.duration > 0 ? audioPlayer.duration : duration
            let c = isActive ? audioPlayer.currentTime : 0
            return "\(formatTime(c)) / \(formatTime(d))"
        }

        var body: some View {
            HStack(spacing: 10) {

                Button {
                    HomeHaptics.light()

                    if callActive {
                        onBlocked()
                        return
                    }

                    // ✅ 避免语音消息与助手播报同时播放
                    stopAllSpeech()
                    audioPlayer.toggle(id: attachmentId, url: url, fallbackDuration: duration)
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.black)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                AudioProgressBar(progress: progress)
                    .frame(height: 5)

                Text(timeText)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.black.opacity(0.70))
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: Color.black.opacity(0.04), radius: 1.2, x: 0, y: 1)
        }

        private func formatTime(_ t: TimeInterval) -> String {
            let sec = Int(t.rounded(.down))
            let m = sec / 60
            let s = sec % 60
            return String(format: "%02d:%02d", m, s)
        }
    }

    private struct AudioProgressBar: View {
        let progress: CGFloat // 0..1

        var body: some View {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.black.opacity(0.10))
                    Capsule(style: .continuous)
                        .fill(Color.black.opacity(0.35))
                        .frame(width: max(4, w * progress))
                }
            }
        }
    }

    // MARK: - Chat input bar

    // ✅ 输入框左上角的思考模式胶囊（快速 / 深度思考）
    // 截图位置：chatQuickToolsRow 之前、输入框 HStack 之上，左对齐
    private var thinkingModeChipRow: some View {
        HStack(spacing: 0) {
            Button {
                HomeHaptics.light()
                // 切换：fast <-> deep
                thinkingModeRaw = (thinkingMode == .fast)
                    ? ThinkingMode.deep.rawValue
                    : ThinkingMode.fast.rawValue
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: thinkingMode.icon)
                        .font(.system(size: 11, weight: .semibold))
                    Text(thinkingMode.label)
                        .font(.system(size: 12, weight: .semibold))
                    // 小指示点（与 RouteTier 胶囊视觉一致）
                    Circle()
                        .fill(thinkingMode.tint)
                        .frame(width: 4, height: 4)
                }
                .foregroundColor(thinkingMode == .deep ? .white : thinkingMode.tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(
                            thinkingMode == .deep
                                ? thinkingMode.tint
                                : thinkingMode.tint.opacity(0.12)
                        )
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            thinkingMode == .deep
                                ? Color.clear
                                : thinkingMode.tint.opacity(0.25),
                            lineWidth: 0.6
                        )
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("切换回复速度")
            .accessibilityValue(thinkingMode.label)
            .animation(.spring(response: 0.28, dampingFraction: 0.85), value: thinkingMode)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 0)
        .disabled(isSending || audioNote.isRecording)
    }

    // ✅ 输入框上方快捷入口（家居 / 视频生成）
    
// ✅ 输入框上方快捷入口（按套餐显隐）
// - Guest / Pro：隐藏入口（不影响功能本身）
// - Ultra：显示“视频生成”
// - Coder：显示“微信聊天 + 视频生成”
private var chatQuickToolsRow: some View {
    // ✅ 始终可见(不再按 plan 隐藏整行)——"电脑控制"是所有用户都能用的入口。
    //    其余按钮仍保持原有按 plan 显隐逻辑,变化只是行不再消失。
    HStack(spacing: 10) {

        // ✅ 电脑控制(始终显示;胶囊带文案,比图标更明显)。
        //    点击只切换 surfaceMode —— 不 fullScreenCover、不 sheet、不 navigation push。
        Button {
            HomeHaptics.light()
            enterComputerControlSurface(startVoice: true)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 16, weight: .semibold))
                Text("电脑控制")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(surfaceMode == .computer ? .white : .black.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(surfaceMode == .computer ? Color.black : uiGray)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)

        // ✅ 首页简化：机器人入口隐藏到 showLegacyHomeEntries 之后（代码保留，可逆）
        if showLegacyHomeEntries {
        // ✅ 阿杜六足机器人模式入口（明确可见的“机器人”按钮）
        Button {
            HomeHaptics.light()
            focused = false
            audioPlayer.stop()
            speechPlayer.stop()
            liveTTSPlayer.stop()
            withAnimation(.easeInOut(duration: 0.18)) {
                isRobotMode.toggle()
                surfaceMode = .chat
            }
            if isRobotMode {
                Task { @MainActor in
                    await refreshRobotBrainStatus()
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "figure.walk.motion")
                    .font(.system(size: 16, weight: .semibold))
                Text(isRobotMode ? "六足已接入" : "机器人")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(isRobotMode ? .white : .black.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(isRobotMode ? Color.black : uiGray)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        }  // end if showLegacyHomeEntries (机器人入口)

        if isRobotMode {
            Button {
                HomeHaptics.light()
                Task { @MainActor in
                    await stopRobotImmediately()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 13, weight: .heavy))
                    Text("STOP")
                        .font(.system(size: 13, weight: .heavy))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(Color.red)
                .clipShape(Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(robotPlannerBusy)

            Text(robotStatusLine)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.red.opacity(0.82))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.08))
                .clipShape(Capsule())
        }

        if showWeChatEntry {
            Button {
                HomeHaptics.light()
                focused = false
                audioPlayer.stop()
                speechPlayer.stop()
                liveTTSPlayer.stop()
                activeSheet = .wechatHome
            } label: {
                toolCircleIcon(systemName: "message.fill")
            }
            .buttonStyle(.plain)
        }

        // ✅ 首页简化：视觉导航(map) 入口隐藏到 showLegacyHomeEntries 之后
        if showLegacyHomeEntries {
            // ✅ Ultra 视觉导航入口
            Button {
                HomeHaptics.light()
                focused = false
                audioPlayer.stop()
                speechPlayer.stop()
                liveTTSPlayer.stop()
                activeSheet = .visionNav
            } label: {
                toolCircleIcon(systemName: "map.fill")
            }
            .buttonStyle(.plain)
        }

        // ✅ 局域网电脑控制调试面板(老入口) —— 首页简化后隐藏到 showLegacyHomeEntries 之后
        //    （这是与“电脑控制”重复的旧入口，首页不再独立展示）
        if showLegacyHomeEntries && showComputerDebugEntry {
            Button {
                HomeHaptics.light()
                focused = false
                audioPlayer.stop()
                speechPlayer.stop()
                liveTTSPlayer.stop()
                showComputerDebugPanel = true
            } label: {
                toolCircleIcon(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.plain)

            // ✅ Computer Body Gateway V2 高级调试入口(拆成独立组件,降低类型检查负担)
            ComputerBodyEntryButton {
                HomeHaptics.light()
                focused = false
                showBodyDebugPanel = true
            }
        }

        Spacer(minLength: 0)
    }
    .padding(.horizontal, 14)
    .padding(.top, 6)
    .padding(.bottom, 2)
    .disabled(isSending || audioNote.isRecording)
}

private func toolCircleIcon(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .semibold))
            .foregroundColor(.black.opacity(0.75))
            .frame(width: 40, height: 40)
            .background(uiGray)
            .clipShape(Circle())
            .contentShape(Circle())
    }

    private var homeDotColor: Color {
        switch homeEntryVM.status {
        case .online: return .green
        case .checking: return .orange
        case .offline: return .gray
        case .unknown: return .gray
        }
    }

    private var homeDotOpacity: Double {
        switch homeEntryVM.status {
        case .online: return 0.95
        case .checking: return 0.95
        case .offline: return 0.45
        case .unknown: return 0.25
        }
    }

    private var chatGPTChatInputBar: some View {
        let trimmedInput = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasText = !trimmedInput.isEmpty
        let hasAttachments = plus.hasPending || plus.isLoading || audioNote.isRecording || audioNote.hasPendingNote
        let voiceLocked = false
        let disableWaveTap = false

        return VStack(spacing: 0) {
            Divider().opacity(0.15)

            if !isAtBottom {
                Button {
                    HomeHaptics.light()
                    scheduleScrollNow(to: .bottom, anchor: .bottom)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundColor(.black)
                        .frame(width: 34, height: 34)
                        .background(Color.white)
                        .clipShape(Circle())
                        .shadow(color: Color.black.opacity(0.10), radius: 10, x: 0, y: 4)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
                .padding(.bottom, 6)
            }

            // ✅ 输入框左上：用户主动选择的"思考模式"胶囊（快速 / 深度思考）
            thinkingModeChipRow

            // ✅ 新增：输入框上方图标入口（家居 / 视频生成）
            chatQuickToolsRow

            if plus.hasPending || plus.isLoading || audioNote.hasPendingNote {
                chatAttachmentPreviewBar
                    .padding(.horizontal, 14)
                    .padding(.top, 2)
            }

            HStack(spacing: 10) {

                ChatPlusButton(manager: plus, disabled: isSending || audioNote.isRecording)

                HStack(spacing: 8) {

                    if audioNote.isRecording {
                        RecordingInlineView(durationText: audioNote.durationText,
                                            samples: audioNote.waveformSamples)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        TextField("询问任何问题", text: $inputText, axis: .vertical)
                            .font(.system(size: 18))
                            .foregroundColor(.black)
                            .focused($focused)
                            .textInputAutocapitalization(.sentences)
                            .disableAutocorrection(false)
                            .lineLimit(1...6)
                            .disabled(isSending)
                    }

                    if audioNote.isRecording {
                        Button {
                            HomeHaptics.light()
                            audioNote.cancel()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.gray.opacity(0.75))
                        }
                        .buttonStyle(.plain)
                        .disabled(isSending)

                    } else {

                        if !hasText {
                            Button {
                                HomeHaptics.light()
                                focused = false

                                // ✅ 录音转文字属于“文本交互”入口：四个套餐都允许录音，
                                //    由 /chat/prepare 在后端转写后按当前 selectedPlan 的文本模型继续回答。
                                //    不再用 hasProEntitlement 拦截，否则内测四套餐选择 Pro/Ultra/Coder 时也会无法录音。

                                // ✅ 通话中禁止本地录音（避免抢占 session）
                                if callActive {
                                    messages.append(.init(role: .system, text: "通话进行中：已禁止本地录音（避免断流）。如需录音请先结束通话。"))
                                    scheduleScrollNow(to: .bottom, anchor: .bottom)
                                    return
                                }

                                // ✅ 开始录音前，先停掉任何本地播放
                                audioPlayer.stop()
                                speechPlayer.stop()
                                liveTTSPlayer.stop()

                                Task { @MainActor in
                                    do {
                                        try await audioNote.start()
                                    } catch {
                                        messages.append(.init(role: .system, text: "录音暂时不可用，请稍后再试。"))
                                        scheduleScrollNow(to: .bottom, anchor: .bottom)
                                    }
                                }
                            } label: {
                                Image(systemName: "mic")
                                    .font(.system(size: 17))
                                    .foregroundColor(.gray.opacity(0.85))
                                    .padding(.trailing, 2)
                            }
                            .buttonStyle(.plain)
                            .disabled(isSending)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(minHeight: 44)
                .background(uiGray)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                ChatGPTBlackButton(
                    mode: isSending ? .stop : ((hasText || hasAttachments) ? .send : .wave),
                    onTap: {
                        HomeHaptics.light()

                        if isSending {
                            cancelAll()
                            return
                        }

                        if audioNote.isRecording {
                            Task { @MainActor in
                                await stopRecordingAndSend()
                            }
                            return
                        }

                        if hasText || plus.hasPending || audioNote.hasPendingNote {
                            Task { @MainActor in
                                 onSendOrStop()
                             }
                        } else {
                            // ✅ 未订阅时点击黑波纹：直接打开 StoreKit 付费墙，而不是静默禁用。
                            //    注意：仅 Guest 锁定；ChatAGI Pro / 机器人 6.1 不锁，点击直接进实时语音，
                            //    不弹套餐选择器（套餐选择器只由顶部 “ChatAGI-阿杜 >” 打开）。
                            if voiceLocked {
                                showProPaywall(reason: .voiceLocked)
                                return
                            }

                            // ✅ 验收日志：确认点击黑波纹时的套餐 / 机器人版本 / 实时 provider。
                            //    Pro → plan=pro robot=6.1 provider=chatagi_native_realtime。
                            let vbProvider = (entitledPlan == .guest || entitledPlan == .ultra || entitledPlan == .coder) ? "openai" : "qwen"
                            let vbPlan = (entitledPlan == .coder) ? "coder" : ((entitledPlan == .ultra) ? "ultra" : ((entitledPlan == .pro) ? "pro" : "guest"))
                            let vbRobot = (entitledPlan == .coder) ? "6.2pro" : ((entitledPlan == .ultra) ? "6.2" : ((entitledPlan == .pro) ? "6.1" : "6.0"))
                            print("[VoiceButton] tapped plan=\(vbPlan) robot=\(vbRobot) provider=\(vbProvider)")

                            // ✅ 切到 voice 前先停掉正在播的内容（避免叠音）
                            audioPlayer.stop()
                            speechPlayer.stop()
                            liveTTSPlayer.stop()

                            focused = false
                            // ✅ 极速接通：在切 UI 前先确保通话已启动，体感更快
                            if entitledPlan == .pro {
                                startChatAGINativeRealtimeFromVoiceButton()
                            } else {
                                configureRealtimeForCurrentPlan()
                                fast.ensureConnected(apiBase: apiBase)
                            }
                            composerMode = .voice
                        }
                    }
                )
                .disabled(disableWaveTap)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.white)
        }
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: InputBarHeightKey.self, value: geo.size.height)
            }
        )
    }

    private var chatAttachmentPreviewBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if audioNote.hasPendingNote {
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.gray.opacity(0.85))

                    Text("语音待发送 \(audioNote.durationText)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.black.opacity(0.85))

                    Spacer()

                    Button {
                        HomeHaptics.light()
                        audioNote.clearPending()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.gray.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(white: 0.96))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: Color.black.opacity(0.04), radius: 1.2, x: 0, y: 1)
            }

            ChatPlusPreviewBar(manager: plus)
        }
    }

    // MARK: - Recording inline waveform view

    private struct RecordingInlineView: View {
        let durationText: String
        let samples: [CGFloat]

        var body: some View {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.red.opacity(0.85))
                    .frame(width: 8, height: 8)

                SiriWaveform(samples: samples)
                    .frame(height: 18)

                Text(durationText)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.black.opacity(0.75))
            }
        }
    }

    private struct SiriWaveform: View {
        let samples: [CGFloat]

        private func level() -> CGFloat {
            guard !samples.isEmpty else { return 0.12 }
            let tail = samples.suffix(12)
            let avg = tail.reduce(0, +) / CGFloat(max(1, tail.count))
            return max(0.08, min(1.0, avg))
        }

        var body: some View {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let amp = level()

                Canvas { context, size in
                    let midY = size.height / 2
                    let width = size.width

                    let configs: [(CGFloat, CGFloat, CGFloat)] = [
                        (1.00, 1.6, 0.70),
                        (0.55, 2.2, 0.40),
                        (0.35, 3.1, 0.28),
                    ]

                    for (gain, freq, alpha) in configs {
                        var path = Path()
                        let step: CGFloat = 2.0
                        var x: CGFloat = 0

                        let phase = CGFloat(t * 2.1 * Double(freq))
                        let A = amp * gain * (size.height * 0.42)

                        func envelope(_ x: CGFloat) -> CGFloat {
                            let k = x / width
                            let v = 1 - pow(2 * k - 1, 2)
                            return max(0, v)
                        }

                        path.move(to: CGPoint(x: 0, y: midY))
                        while x <= width {
                            let norm = x / width
                            let env = envelope(x)
                            let y = midY + sin((norm * .pi * 2 * freq) + phase) * A * env
                            path.addLine(to: CGPoint(x: x, y: y))
                            x += step
                        }

                        context.stroke(path, with: .color(Color.black.opacity(alpha)), lineWidth: 2.0)
                    }
                }
            }
        }
    }

    // MARK: - Voice bottom bar

    private var chatGPTVoiceBottomBar: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.15)

            HStack(spacing: 10) {

                Button {
                HomeHaptics.light()
                openHistoryDrawer()
            } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.black.opacity(0.75))
                        .frame(width: 40, height: 40)
                        .background(uiGray)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                Button {
                    HomeHaptics.light()
                    // ✅ 通话仍可能保持：回到聊天界面时也停掉本地播放（保险）
                    audioPlayer.stop()
                    speechPlayer.stop()
                    liveTTSPlayer.stop()

                    composerMode = .chat
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        focused = true
                    }
                } label: {
                    HStack {
                        Text("输入")
                            .font(.system(size: 17, weight: .regular))
                            .foregroundColor(.gray.opacity(0.85))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .frame(width: 150, height: 44)
                    .background(uiGray)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .buttonStyle(.plain)

                if entitledPlan == .pro {
                    Button {
                        HomeHaptics.light()
                        RealtimeAVService.shared.finishChatAGINativeUserTurnNow()
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundColor(.black.opacity(0.75))
                            .frame(width: 40, height: 40)
                            .background(uiGray)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("我说完了，立即发送")
                }

                Button {
                    HomeHaptics.light()

                    // ✅ 音视频权限：仅 Guest 弹升级 ChatAGI Pro（不调 /session）。
                    //    6.1(pro,阿里官方 Qwen) / 6.2(ultra) / 6.2 Pro(coder) 都进入音视频通话页。
                    if entitledPlan == .guest {
                        showProPaywall(reason: .voiceLocked)
                        return
                    }

                    // ✅ 进入音视频前停掉一切本地播放，避免音频路由抢占
                    audioPlayer.stop()
                    speechPlayer.stop()
                    liveTTSPlayer.stop()

                    // ✅ 确保已接通再进视频页（体感更快、更稳）。
                    //    provider 由 configureRealtimeForCurrentPlan 按套餐设置：
                    //      pro → qwen（阿里官方 Omni Realtime，视频=图片帧）
                    //      ultra / coder → openai（GPT Realtime，视频=图片帧）
                    configureRealtimeForCurrentPlan()
                    // ✅ 不在此处 startAV：音视频链路统一交给 RealtimeAVCallView.task 单独拉起，
                    //    避免「按钮 startAV + CallView startAV」双重 start 竞态（接入不稳定的根因）。
                    showVideoCall = true
                } label: {
                    Image(systemName: "video")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.black.opacity(0.7))
                        .frame(width: 40, height: 40)
                        .background(uiGray)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                Button {
                    HomeHaptics.light()
                    openComputerControlPanel()
                } label: {
                    Image(systemName: computerControlMode ? "desktopcomputer.trianglebadge.exclamationmark" : "desktopcomputer")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.black.opacity(0.7))
                        .frame(width: 40, height: 40)
                        .background(computerControlMode ? Color.green.opacity(0.18) : uiGray)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                Button {
                    HomeHaptics.light()
                    isMutedInVoice.toggle()
                    rt.setMuted(isMutedInVoice)
                } label: {
                    Image(systemName: isMutedInVoice ? "mic.slash" : "mic")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.black.opacity(0.7))
                        .frame(width: 40, height: 40)
                        .background(uiGray)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                Button {
                    HomeHaptics.light()
                    composerMode = .chat
                    isMutedInVoice = false
                    fast.stop()

                    // ✅ NEW：结束时也停掉本地播放（保险）
                    audioPlayer.stop()
                    speechPlayer.stop()
                    liveTTSPlayer.stop()
                } label: {
                    HStack(spacing: 8) {
                        Text("····")
                            .font(.system(size: 18, weight: .heavy))
                            .foregroundColor(.white.opacity(0.95))
                        Text("结束")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .frame(height: 44)
                    .padding(.horizontal, 16)
                    .background(Color(red: 0.0, green: 0.48, blue: 1.0))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.white)
        }
    }

    // MARK: - V1 Paywall Gates

    @MainActor
    private func showProPaywall(reason: PaywallReason) {
        // ✅ 四套餐开放选择版：不再弹付费墙/不再强制降级，只打开模型选择面板。
        paywallReasonRaw = reason.rawValue
        pendingPlanAfterPurchase = nil
        activeSheet = .planPicker
    }

    @MainActor
    private func consumeGuestTextUseOrShowPaywall() -> Bool {
        // ✅ 四套餐开放选择版：文本次数不再拦截。
        return true
    }

    @MainActor
    private func enforceGuestPlusLimitIfNeeded(currentCount: Int) {
        // ✅ 四套餐开放选择版：+ 上传次数不再拦截，仅同步计数基准。
        lastObservedPlusPendingCount = plus.pending.count
    }

    // MARK: - Recording send

    @MainActor
    func stopRecordingAndSend() async {
        audioNote.stopAndMarkPending()
        onSendOrStop()
    }

    // MARK: - Chat Actions（流式文本 + attachments + 音频转写回填）

    
    // MARK: - User-facing Error Copy

    private func friendlyNetworkMessage(_ error: Error? = nil) -> String {
        if let error {
            let ns = error as NSError
            let s = (ns.localizedDescription + " " + ns.domain).lowercased()
            if ns.domain == NSURLErrorDomain ||
                s.contains("timed out") ||
                s.contains("network connection") ||
                s.contains("cannot connect") ||
                s.contains("offline") ||
                s.contains("lost") ||
                s.contains("cancelled") ||
                s.contains("canceled") {
                return "网络问题，稍后再试。"
            }
            if ns.code == 402 || s.contains("quota") || s.contains("upgrade") {
                return "免费体验已用完，请升级 ChatAGI Pro 继续使用。"
            }
        }
        return "网络问题，稍后再试。"
    }

    /// 聊天流错误的 UI 文案：
    /// - 后端/流自身产生的错误（GPT5ChatService.Streaming，含 backend error、HTTP error、30 秒兜底）
    ///   直接显示真实内容，不被 friendlyNetworkMessage 吞掉。
    /// - 其余（URLError 等纯传输层问题）仍走 friendlyNetworkMessage。
    private func chatStreamErrorMessage(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == "GPT5ChatService.Streaming" {
            let raw = ns.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty { return raw }
        }
        return friendlyNetworkMessage(error)
    }

    // MARK: - Streaming Chat Actions（仅流式：/chat/prepare -> /chat/events/{chat_id}）
    @MainActor
    func onSendOrStop() {
        if isSending {
            cancelAll()
            return
        }

        liveTTSPlayer.stop()

        let t = inputText.trimmingCharacters(in: .whitespacesAndNewlines)

        if !t.isEmpty && isComputerControlOpenCommand(t) {
            inputText = ""
            focused = false
            openComputerControlPanel()
            return
        }

        if !t.isEmpty && computerControlMode {
            inputText = ""
            focused = false
            pendingComputerControlInstruction = t
            showComputerDebugPanel = true
            return
        }

        // ✅ V2.2:主输入栏识别"自我升级"触发短语 → 走 /api/adu/self/upgrade/plan,
        //    不走 /chat/prepare、不消耗 Guest 文本额度、不调 Codex。
        //    把 goal 通过 aduContext.pendingSelfUpgradeGoal 透传给嵌入的 ComputerControlHomeView,
        //    后者监听到值变化后即调 runSelfUpgradePlan(... surface:"home_chat"),用现有计划卡渲染。
        if !t.isEmpty && isSelfUpgradeTrigger(t) {
            routeSelfUpgradeToPlanCard(goal: t)
            return
        }

        // ✅ V1 免费文本门禁：录音最终会转写成文字，因此也按“文本交互”处理。
        //    四套餐内测版可自由切换模型；若当前仍是 Guest，则保持 Guest 文本额度逻辑。
        let willUseTextInteraction = !t.isEmpty || audioNote.hasPendingNote
        if willUseTextInteraction, !consumeGuestTextUseOrShowPaywall() {
            return
        }

        if isRobotMode, !plus.hasPending {
            if routeRobotModeSend(text: t) {
                return
            }
        }

        // ❌ V2 主输入栏不再过 Adu planner ——
        //    HomeChatView 下半部分输入栏只承担"普通聊天/语音/图片/文件",
        //    AduTaskPlanner 工具路由现在只由"上半部分电脑控制面板的内部任务栏"调用。
        //    bypassPlannerOnce 和 routeAduPlannerInput 仍保留,留作未来需要时复用。
        if bypassPlannerOnce { bypassPlannerOnce = false }

        // 🔥 自动化编程 / 递归自我升级 → DevBrain 统一入口 /api/brain/dev/run
        if !t.isEmpty && looksLikeDevTask(t) {
            inputText = ""
            focused = false

            let userId = UUID()
            messages.append(.init(id: userId, role: .user, text: t))
            pinnedUserId = userId

            let assistantId = UUID()
            messages.append(.init(
                id: assistantId,
                role: .assistant,
                text: "🧠 DevBrain 正在理解目标并自动执行(observe→plan→act→verify→repair)…",
                isTypingCursor: true
            ))
            pinnedAssistantId = assistantId

            Task { @MainActor in
                do {
                    let resp = try await submitDevTask(goal: t)
                    updateMessage(id: assistantId) {
                        $0.text = resp.rendered
                        $0.isTypingCursor = false
                        if let image = resp.screenshotImage {
                            $0.attachments = [ChatMessageAttachment(kind: .image(image), filename: "devbrain-screenshot.png")]
                        }
                    }
                    scheduleScrollNow(to: .bottom, anchor: .bottom)
                } catch {
                    updateMessage(id: assistantId) {
                        $0.text = friendlyNetworkMessage(error)
                        $0.isTypingCursor = false
                    }
                }
            }
            return
        }

        // 🔥 文本 → 统一入口 /api/brain/adu/act
        if !t.isEmpty && looksLikeComputerTask(t) {
            inputText = ""
            focused = false

            let userId = UUID()
            messages.append(.init(id: userId, role: .user, text: t))
            pinnedUserId = userId

            let assistantId = UUID()
            messages.append(.init(
                id: assistantId,
                role: .assistant,
                text: "正在执行电脑操作…",
                isTypingCursor: true
            ))
            pinnedAssistantId = assistantId

            Task { @MainActor in
                do {
                    let resp = try await submitComputerTask(goal: t, source: "text_chat")

                    if resp.route == "chat" {
                        // 后端判定为聊天：撤回乐观占位，让用户重发走聊天流
                        messages.removeAll { $0.id == assistantId || $0.id == userId }
                        if pinnedUserId == userId { pinnedUserId = nil }
                        if pinnedAssistantId == assistantId { pinnedAssistantId = nil }
                        inputText = t
                        return
                    }

                    updateMessage(id: assistantId) {
                        // ✅ V1 连续执行:展示 final_message + steps trace + 截图
                        var rendered = resp.finalText ?? "电脑动作已执行。"
                        if !resp.errorText.isEmpty, resp.errorText != resp.finalText {
                            rendered += "\n\n⚠️ " + resp.errorText
                        }
                        if !resp.stepsText.isEmpty { rendered += "\n\n" + resp.stepsText }
                        $0.text = rendered
                        $0.isTypingCursor = false
                        if let image = resp.screenshotImage {
                            $0.attachments = [ChatMessageAttachment(kind: .image(image), filename: "computer-loop-screenshot.png")]
                        }
                    }
                    scheduleScrollNow(to: .bottom, anchor: .bottom)

                } catch {
                    updateMessage(id: assistantId) {
                        $0.text = friendlyNetworkMessage(error)
                        $0.isTypingCursor = false
                    }
                }
            }

            return
        }

        // ✅ V1.5 工程修复入口（最小安全两段式）：
        //   - 用户说"修复编译错误/修 bug/自动修工程/跑测试" → 先 allow_execute=false，显示计划，记 pendingEngineeringGoal
        //   - 用户回"确认执行" → 用记下来的 goal 跑 allow_execute=true
        //   - 任何其他输入都会清掉 pending，自动回到普通聊天
        if !t.isEmpty, let pendingGoal = pendingEngineeringGoal, isEngineeringConfirmation(t) {
            inputText = ""
            focused = false

            let userId = UUID()
            messages.append(.init(id: userId, role: .user, text: t))
            pinnedUserId = userId

            let assistantId = UUID()
            messages.append(.init(
                id: assistantId,
                role: .assistant,
                text: "🛠 启动工程修复（task 排队中）…",
                isTypingCursor: true
            ))
            pinnedAssistantId = assistantId

            Task { @MainActor in
                await runEngineeringLoop(goal: pendingGoal, allowExecute: true, assistantId: assistantId)
            }
            return
        }

        if !t.isEmpty && looksLikeEngineeringRequest(t) {
            inputText = ""
            focused = false

            let userId = UUID()
            messages.append(.init(id: userId, role: .user, text: t))
            pinnedUserId = userId

            let assistantId = UUID()
            messages.append(.init(
                id: assistantId,
                role: .assistant,
                text: "🛠 正在生成修复计划…",
                isTypingCursor: true
            ))
            pinnedAssistantId = assistantId

            Task { @MainActor in
                await runEngineeringLoop(goal: t, allowExecute: false, assistantId: assistantId)
            }
            return
        }

        // 走到这里说明既不是工程触发，也不是确认；之前若有 pending，视为放弃，清掉
        if pendingEngineeringGoal != nil { pendingEngineeringGoal = nil }

        let plusItemsToSend = plus.consumePending()

        if t.isEmpty && plusItemsToSend.isEmpty && !audioNote.hasPendingNote { return }

        let staged = audioNote.stagePendingForUpload()
        let audioURLToSend = staged?.url
        let audioDurationToSend = staged?.duration ?? 0

        let userId = UUID()
        var userAttachments: [ChatMessageAttachment] = []
        for item in plusItemsToSend {
            switch item.kind {
            case .image(_, let preview, let filename, _):
                userAttachments.append(ChatMessageAttachment(id: item.id, kind: .image(preview), filename: filename))
            case .file(let url, let filename, _):
                userAttachments.append(ChatMessageAttachment(id: item.id, kind: .file(url: url, filename: filename), filename: filename))
            }
        }
        if let localURL = audioURLToSend {
            userAttachments.append(ChatMessageAttachment(kind: .audio(url: localURL, duration: audioDurationToSend)))
        }

        let shouldRouteComputer = shouldUseComputerGateway(
            text: t,
            plusItemsCount: plusItemsToSend.count,
            hasPendingAudio: audioNote.hasPendingNote,
            isVoiceMode: composerMode == .voice
        )

        inputText = ""
        focused = false

        messages.append(ChatMessage(id: userId, role: .user, text: t, attachments: userAttachments))
        pinnedUserId = userId

        let assistantId = UUID()
        messages.append(ChatMessage(id: assistantId, role: .assistant, text: "正在思考中…", isTypingCursor: true, routeTier: .thinking))
        pinnedAssistantId = assistantId
        scheduleScrollNow(to: .bottom, anchor: .bottom)

        if shouldRouteComputer {
            isSending = true
            sendTask?.cancel()
            speechPlayer.stop()
            liveTTSPlayer.stop()

            sendTask = Task { @MainActor in
                defer { isSending = false }
                await runComputerGatewayFlow(goal: t, assistantId: assistantId)
            }
            return
        }

        // ✅ V2 统一上下文:把最近 Adu Timeline 摘要塞进 context 头部(system),
        //    让主聊天助手实时知道刚才电脑动作 / Codex / planner / Health 的状态;
        //    完整 stdout/stderr 不会进入(只在自动化编程卡片里),所以不会爆 token。
        var context = ChatMessage.buildContext(from: messages, maxPairs: 20)
        let aduSummary = aduContext.recentSummary(limit: 12)
        if !aduSummary.isEmpty {
            context.insert(LLMMessage(role: "system", content: aduSummary), at: 0)
        }
        // ✅ 主输入栏发送 → 写入统一时间线(home_chat_input / user_message)。
        if !t.isEmpty {
            aduContext.appendUserMessage(t, source: .home_chat_input)
        }

        thinkingPhaseText = "正在思考中…"
        thinkingPhaseTask?.cancel()
        thinkingPhaseTask = Task { @MainActor in
            let phases = [
                "正在思考中…",
                "分析问题中…",
                "深度推理中…",
                "搜索相关信息…",
                "整理思路中…",
                "组织答案中…",
                "生成回答中…",
            ]
            var idx = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if Task.isCancelled { break }
                idx = (idx + 1) % phases.count
                thinkingPhaseText = phases[idx]
            }
        }

        isSending = true
        sendTask?.cancel()
        speechPlayer.stop()
        liveTTSPlayer.stop()

        sendTask = Task { @MainActor in
            defer { isSending = false }

            // ✅ 出错日志需要 chat_id，但 prep 作用域在内层 do；这里提到外层捕获。
            var streamChatIdForDebug = ""

            do {
                var attachments: [ChatAttachment] = []
                var uploadedAudioRemoteURL: URL? = nil

                for item in plusItemsToSend {
                    switch item.kind {
                    case .image(let data, _, let filename, let mime):
                        let uploaded = try await uploader.uploadImage(apiBase: apiBase, data: data, filename: filename, mime: mime)
                        attachments.append(.init(type: "image", id: uploaded.id, mime: uploaded.mime, url: uploaded.url))

                    case .file(let localURL, let filename, let mime):
                        let uploaded = try await uploader.uploadFile(apiBase: apiBase, fileURL: localURL, filename: filename, mime: mime)
                        attachments.append(.init(type: "file", id: uploaded.id, mime: uploaded.mime, url: uploaded.url))

                        if let remote = resolveMediaURLString(uploaded.url) {
                            updateMessage(id: userId) { m in
                                if let idx = m.attachments.firstIndex(where: { $0.id == item.id }) {
                                    m.attachments[idx].kind = .file(url: remote, filename: filename)
                                    m.attachments[idx].filename = filename
                                }
                            }
                        }
                    }
                }

                if let url = audioURLToSend {
                    let uploaded = try await uploader.uploadAudio(apiBase: apiBase, fileURL: url)
                    attachments.append(.init(type: "audio", id: uploaded.id, mime: uploaded.mime, url: uploaded.url))

                    if let remote = resolveMediaURLString(uploaded.url) {
                        uploadedAudioRemoteURL = remote
                        updateMessage(id: userId) { m in
                            if let idx = m.attachments.firstIndex(where: { att in
                                if case .audio = att.kind { return true } else { return false }
                            }) {
                                if case .audio(_, let d) = m.attachments[idx].kind {
                                    m.attachments[idx].kind = .audio(url: remote, duration: d)
                                }
                            }
                        }
                    }
                }

                let wantLiveTTS = (autoSpeakEnabled && !callActive)
                let currentPerception = AduPerceptionManager.shared.lastSnapshot
                let searchEnabled = shouldEnableWebSearchForQuery(t)

                let prep = try await prepareChat(
                    apiBase: apiBase,
                    plan: selectedPlan.rawValue,
                    model: selectedTextModel,
                    provider: wantLiveTTS ? "openai" : nil,
                    messages: context,
                    attachments: attachments,
                    conversationId: currentConversationId,
                    clientId: clientId,
                    ttsStream: wantLiveTTS,
                    ttsVoice: autoSpeakVoice,
                    perception: currentPerception,
                    searchEnabled: searchEnabled,
                    thinking: (thinkingMode == .deep)  // ✅ 深度思考交后端权威选 reasoning 模型
                )
                streamChatIdForDebug = prep.chatId

                if let cid = prep.conversationId, !cid.isEmpty {
                    currentConversationId = cid
                }

                // ✅ 用后端真实路由决策更新档位（前后端对齐:准确度 100%）
                let backendTier = RouteTier.fromDecision(
                    route: prep.routeDecision?.route,
                    model: prep.routeDecision?.model
                )
                updateMessage(id: assistantId) { m in
                    if (m.routeTier?.priority ?? 0) <= backendTier.priority {
                        m.routeTier = backendTier
                    }
                }

                if let transcript = prep.userTranscript?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !transcript.isEmpty {
                    updateMessage(id: userId) { m in
                        if m.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            m.text = transcript
                        } else {
                            m.text = m.text + "\n\n🎙️ " + transcript
                        }
                    }

                    // ✅ 录音转写 → 统一入口 /api/brain/adu/act
                    //   - 仅当此次提交包含录音 (audioURLToSend != nil) 且文本看起来像电脑动作
                    //   - 与聊天主流并行；若 route=chat，静默丢弃；若 route=computer，追加一条结果消息
                    if audioURLToSend != nil, self.looksLikeComputerTask(transcript) {
                        let aduGoal = transcript
                        Task { @MainActor in
                            do {
                                let resp = try await self.submitComputerTask(goal: aduGoal, source: "audio_transcript")
                                if resp.route == "computer", let final = resp.finalText, !final.isEmpty {
                                    let aduId = UUID()
                                    self.messages.append(.init(id: aduId, role: .assistant, text: final))
                                    self.scheduleScrollNow(to: .bottom, anchor: .bottom)
                                }
                            } catch {
                                // 静默：聊天主流仍在进行，电脑任务的失败不打断
                            }
                        }
                    }
                }
                updateMessage(id: assistantId) { m in
                    m.text = "正在思考中…"
                    m.isTypingCursor = true
                }
                scheduleScrollNow(to: .bottom, anchor: .bottom)

                var built = ""
                var finalTranscript: String? = nil
                var finalTtsURL: URL? = prep.ttsURL
                if let u = finalTtsURL {
                    ttsRemoteURL[assistantId] = u
                }

                if !callActive, autoSpeakEnabled, let u = finalTtsURL {
                    liveTTSPlayer.play(url: u)
                }

                do {
                    // ✅ 路由档位兜底推断:旧后端没 route_decision 时使用首字延迟推断
                    let streamStartedAt = Date()
                    var firstDeltaSeen = false

                    streamLoop: for try await ev in chat.streamEvents(
                        apiBase: apiBase,
                        chatId: prep.chatId,
                        debug: .init(
                            plan: selectedPlan.rawValue,
                            model: selectedTextModel,
                            thinking: (thinkingMode == .deep)
                        )
                    ) {
                        if Task.isCancelled { break }

                        switch ev {
                        case .delta(let d):
                            if thinkingPhaseTask != nil {
                                thinkingPhaseTask?.cancel()
                                thinkingPhaseTask = nil
                                thinkingPhaseText = "正在思考中…"
                            }
                            // ✅ 兜底:首字到达 < 800ms 视为快速回答 (高优先级档位不会被覆盖)
                            if !firstDeltaSeen {
                                firstDeltaSeen = true
                                let elapsed = Date().timeIntervalSince(streamStartedAt)
                                let inferredTier: RouteTier = elapsed < 0.8 ? .fast : .thinking
                                updateMessage(id: assistantId) { m in
                                    if (m.routeTier?.priority ?? 0) <= inferredTier.priority {
                                        m.routeTier = inferredTier
                                    }
                                }
                            }
                            built.append(contentsOf: d)
                            typingPending.append(contentsOf: d)
                            typingLastDeltaAt = Date().timeIntervalSinceReferenceDate

                            if speechPlayer.activeId == assistantId || speechPlayer.loadingId == assistantId {
                                speechPlayer.updateFallbackText(for: assistantId, text: built)
                            }

                            if typingAssistantId != assistantId {
                                typingAssistantId = assistantId
                                typingPending = built
                                typingPumpTask?.cancel()
                                typingPumpTask = Task { @MainActor in
                                    var lastAppliedCount = 0
                                    while !Task.isCancelled, typingAssistantId == assistantId {
                                        let backlog = max(0, built.count - lastAppliedCount)
                                        if backlog > 0 {
                                            let chunk: Int
                                            if backlog > 2000 { chunk = 600 }
                                            else if backlog > 600 { chunk = 200 }
                                            else { chunk = 48 }

                                            let targetCount = min(built.count, lastAppliedCount + chunk)
                                            if targetCount > lastAppliedCount {
                                                let idx = built.index(built.startIndex, offsetBy: targetCount)
                                                let visible = String(built[..<idx])
                                                lastAppliedCount = targetCount
                                                updateMessage(id: assistantId) { m in
                                                    m.text = visible
                                                    m.isTypingCursor = true
                                                }
                                                scheduleScroll()
                                            }
                                        }

                                        try? await Task.sleep(nanoseconds: 24_000_000)

                                        let now = Date().timeIntervalSinceReferenceDate
                                        if now - typingLastDeltaAt > 0.08 {
                                            if built.count > lastAppliedCount {
                                                let idx2 = built.index(built.startIndex, offsetBy: built.count)
                                                let visible2 = String(built[..<idx2])
                                                lastAppliedCount = built.count
                                                updateMessage(id: assistantId) { m in
                                                    m.text = visible2
                                                    m.isTypingCursor = true
                                                }
                                                scheduleScroll()
                                            }
                                        }
                                    }
                                }
                            }

                        case .thinking(let phaseHint):
                            let _ = phaseHint

                        case .reasoningDelta(let rd):
                            updateMessage(id: assistantId) { m in
                                m.reasoningText += rd
                                // ✅ 升级到深度思考(优先级最高)
                                m.routeTier = .deep
                            }

                        case .reasoningDone:
                            updateMessage(id: assistantId) { m in
                                m.reasoningDone = true
                                if m.text.contains("正在思考") { m.text = "" }
                            }

                        case .sources(let srcs):
                            if !srcs.isEmpty {
                                updateMessage(id: assistantId) { m in
                                    var merged = m.sources
                                    for s in srcs {
                                        if !merged.contains(where: { $0.url == s.url }) {
                                            merged.append(s)
                                        }
                                    }
                                    m.sources = merged
                                    // ✅ 升级到联网搜索(仅当当前不是深度思考)
                                    if (m.routeTier?.priority ?? 0) < RouteTier.web.priority {
                                        m.routeTier = .web
                                    }
                                }
                            }

                        case .final(let full, let transcript, let ttsURL):
                            if !full.isEmpty {
                                built = full
                            }
                            if let tr = transcript?.trimmingCharacters(in: .whitespacesAndNewlines), !tr.isEmpty {
                                finalTranscript = tr
                            }
                            if let u = ttsURL {
                                finalTtsURL = u
                                ttsRemoteURL[assistantId] = u
                            }

                            if speechPlayer.activeId == assistantId || speechPlayer.loadingId == assistantId {
                                speechPlayer.updateFallbackText(for: assistantId, text: built)
                            }

                        case .error(let msg):
                            throw NSError(domain: "GPT5ChatService.Streaming", code: -100,
                                          userInfo: [NSLocalizedDescriptionKey: msg])

                        case .done:
                            break streamLoop
                        }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                }

                if Task.isCancelled { return }

                if let transcript = finalTranscript?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !transcript.isEmpty {
                    updateMessage(id: userId) { m in
                        if m.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            m.text = transcript
                        } else if !m.text.contains(transcript) {
                            m.text = m.text + "\n\n🎙️ " + transcript
                        }
                    }
                }

                typingPumpTask?.cancel(); typingPumpTask = nil
                typingAssistantId = nil
                typingPending = ""
                thinkingPhaseTask?.cancel(); thinkingPhaseTask = nil
                thinkingPhaseText = "正在思考中…"

                updateMessage(id: assistantId) { m in
                    m.text = built
                    m.isTypingCursor = false
                    m.routeTierFinishedAt = Date()
                }
                scheduleScrollNow(to: .bottom, anchor: .bottom)
                scheduleRouteTierHide()

                if !callActive, autoSpeakEnabled {
                    if let u = finalTtsURL {
                        liveTTSPlayer.play(url: u)
                    } else {
                        liveTTSPlayer.speak(text: built, voice: autoSpeakVoice, format: "mp3")
                    }
                }
                if !callActive, !autoSpeakEnabled {
                    startPrefetchTTS(messageId: assistantId, text: built, remoteURL: finalTtsURL)
                }
                audioNote.finalizeStaged(deleteFile: uploadedAudioRemoteURL != nil)

            } catch is CancellationError {
                if !plusItemsToSend.isEmpty {
                    plus.pending.insert(contentsOf: plusItemsToSend, at: 0)
                }
                audioNote.restoreStagedToPending()
                updateMessage(id: assistantId) {
                    $0.isTypingCursor = false
                    $0.routeTierFinishedAt = Date()
                }
                speechPlayer.stop()
                liveTTSPlayer.stop()
                scheduleRouteTierHide()
            } catch {
                if !plusItemsToSend.isEmpty {
                    plus.pending.insert(contentsOf: plusItemsToSend, at: 0)
                }
                audioNote.restoreStagedToPending()
                speechPlayer.stop()
                liveTTSPlayer.stop()
                // ✅ 后端 error / 30 秒兜底 / HTTP error 直接显示真实内容；其余走友好文案。
                let shown = chatStreamErrorMessage(error)
                print("[ChatSSE][ui_error] chat_id=\(streamChatIdForDebug) shown=\(shown) raw=\((error as NSError).domain)#\((error as NSError).code): \((error as NSError).localizedDescription)")
                updateMessage(id: assistantId) {
                    $0.isTypingCursor = false
                    $0.text = shown
                    $0.routeTierFinishedAt = Date()
                }
                scheduleScrollNow(to: .bottom, anchor: .bottom)
                scheduleRouteTierHide()
            }
        }
    }

    // MARK: - AduTaskPlanner main chat routing

    private func makeAduPlannerContext() -> AduPlannerContext {
        let lastUserText = messages.reversed().first(where: { $0.role == .user })?.text
        let lastAssistantText = messages.reversed().first(where: { $0.role == .assistant })?.text
        let recent = messages.suffix(6).map { message -> String in
            switch message.role {
            case .user: return "user: \(message.text)"
            case .assistant: return "assistant: \(message.text)"
            case .system: return "system: \(message.text)"
            }
        }.joined(separator: "\n")

        return AduPlannerContext(
            currentSurface: computerControlMode || showComputerControl ? .computerControl : .homeChat,
            hasPendingCodexTask: pendingCodexTask != nil,
            pendingCodexSummary: pendingPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : pendingPrompt,
            lastAssistantIntent: inferPlannerIntent(from: lastAssistantText),
            lastUserIntent: inferPlannerIntent(from: lastUserText),
            recentConversationSummary: recent,
            selectedProject: pendingProject,
            currentScreenState: showComputerControl ? "computerControlVisible" : "homeChatVisible"
        )
    }

    private func makeAduPlannerRecentMessages() -> [AduPlannerRecentMessage] {
        messages.suffix(8).compactMap { message in
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            switch message.role {
            case .user:
                return AduPlannerRecentMessage(role: "user", content: text)
            case .assistant:
                return AduPlannerRecentMessage(role: "assistant", content: text)
            case .system:
                return AduPlannerRecentMessage(role: "system", content: text)
            }
        }
    }

    private func makePendingCodexPayload() -> AduPendingCodexTaskPayload {
        AduPendingCodexTaskPayload(
            exists: pendingCodexTask != nil,
            project: pendingProject,
            prompt: pendingPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : pendingPrompt,
            summary: pendingCodexTask?.organizedTask,
            riskLevel: pendingRiskLevel,
            createdAt: pendingCreatedAt.map { ISO8601DateFormatter().string(from: $0) }
        )
    }

    private func makeAduPlannerScreenState() -> [String: Any] {
        [
            "computer_panel_open": showComputerControl || computerControlMode,
            "codex_running": codexPlannerRunning,
            "last_health": showComputerControl ? "computer control open" : "home chat visible"
        ]
    }

    // ─── planner 拦截规则 ─────────────────────────────────────────────
    //
    // 设计原则:HomeChatView 仍以"普通聊天"为主,planner 只是"工具路由器"。
    // 只有这些 intent 才允许拦截原聊天链路(其余一律 fallthrough 到 /chat/prepare):
    //
    //     computer_action            打开 Safari / 截图 / 鼠标键盘
    //     codex_task                 帮我修 Swift 编译错误
    //     claude_task                Claude 预览任务
    //     self_upgrade_task          你自己检查系统哪里还能升级
    //     continue_previous_task     继续给 codex 任务(有 pending 才命中)
    //     confirm_pending_task       确认运行
    //     cancel_pending_task        取消上一轮 Codex 任务
    //     edit_pending_task          修改 prompt
    //     file_search_task           找 server_session.py(后端 intent 未来加)
    //     file_read_task             读 menu.json(后端 intent 未来加)
    //     web_business_task          预订/购物/查询业务(后端 intent 未来加)
    //
    // 凡是 chat_answer / ask_clarification / 未知 intent / confidence<0.65 /
    // planner 网络错 / 解析错 → fallthroughToNormalChat,让原 /chat/prepare 接管,
    // 保留记忆、联网、图片/文件理解、主人格。
    private static let plannerInterceptIntents: Set<String> = [
        "computer_action", "codex_task", "claude_task", "self_upgrade_task",
        "continue_previous_task", "confirm_pending_task",
        "cancel_pending_task", "edit_pending_task",
        "file_search_task", "file_read_task", "web_business_task",
    ]
    private static let plannerInterceptConfidenceFloor: Double = 0.65

    private func plannerShouldIntercept(intent: String, confidence: Double) -> Bool {
        guard confidence >= Self.plannerInterceptConfidenceFloor else { return false }
        return Self.plannerInterceptIntents.contains(intent)
    }

    @MainActor
    private func routeRobotModeSend(text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && !audioNote.hasPendingNote { return false }

        inputText = ""
        focused = false
        speechPlayer.stop()
        liveTTSPlayer.stop()

        let staged = audioNote.stagePendingForUpload()
        let userId = UUID()
        var attachments: [ChatMessageAttachment] = []
        if let staged {
            attachments.append(ChatMessageAttachment(kind: .audio(url: staged.url, duration: staged.duration)))
        }

        let userText = trimmed.isEmpty ? "🎙️ 语音指令" : trimmed
        messages.append(.init(id: userId, role: .user, text: userText, attachments: attachments))
        pinnedUserId = userId
        pinnedAssistantId = nil
        scheduleScrollNow(to: .bottom, anchor: .bottom)

        if let staged {
            sendTask?.cancel()
            robotPlannerBusy = true
            sendTask = Task { @MainActor in
                defer { robotPlannerBusy = false }
                await routeRobotPlannerAudio(url: staged.url, duration: staged.duration, userMessageId: userId)
            }
        } else {
            Task { @MainActor in
                await routeRobotPlannerInput(trimmed, existingUserMessageId: userId, source: "text_chat")
            }
        }
        return true
    }

    @MainActor
    private func refreshRobotBrainStatus() async {
        do {
            let obj = try await robotGET(path: "/api/adu/robot/hexapod/status")
            let reachable = (obj["lowlevel_reachable"] as? Bool) ?? false
            if reachable {
                robotStatusLine = "六足已接入"
            } else {
                robotStatusLine = "六足后端可达，8081 未就绪"
            }
        } catch {
            robotStatusLine = "六足状态未知：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func routeRobotPlannerInput(_ text: String, existingUserMessageId: UUID? = nil, source: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        robotPlannerBusy = true
        defer { robotPlannerBusy = false }

        let userId: UUID
        if let existingUserMessageId {
            userId = existingUserMessageId
        } else {
            userId = UUID()
            messages.append(.init(id: userId, role: .user, text: trimmed))
            pinnedUserId = userId
        }

        if isRobotStopTranscript(trimmed) {
            await stopRobotImmediately()
            return
        }

        let assistantId = UUID()
        messages.append(.init(id: assistantId, role: .assistant, text: "正在结合视觉场景预览六足动作…", isTypingCursor: true, routeTier: .fast))
        pinnedAssistantId = assistantId
        scheduleScrollNow(to: .bottom, anchor: .bottom)

        do {
            let plan = try await postRobotPerceptionTick(transcript: trimmed, source: source)
            updateMessage(id: assistantId) {
                $0.text = plan.say
                $0.isTypingCursor = false
                $0.robotPlan = plan
                $0.routeTierFinishedAt = Date()
            }
            robotStatusLine = plan.need_confirm ? "动作待确认，未执行" : "动作预览，未执行"
            if autoSpeakEnabled, !plan.say.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                liveTTSPlayer.speak(text: plan.say, voice: autoSpeakVoice, format: "mp3")
            }
        } catch {
            updateMessage(id: assistantId) {
                $0.text = "六足动作解析失败：\(error.localizedDescription)"
                $0.isTypingCursor = false
            }
            robotStatusLine = "六足动作预览失败"
        }
        scheduleScrollNow(to: .bottom, anchor: .bottom)
    }

    @MainActor
    private func routeRobotPlannerAudio(url: URL, duration: TimeInterval, userMessageId: UUID) async {
        let assistantId = UUID()
        messages.append(.init(id: assistantId, role: .assistant, text: "正在识别语音并解析六足动作…", isTypingCursor: true, routeTier: .fast))
        pinnedAssistantId = assistantId
        scheduleScrollNow(to: .bottom, anchor: .bottom)

        do {
            let plan = try await postRobotAudioIntent(audioURL: url)
            updateMessage(id: userMessageId) { m in
                if let source = plan.source, source == "audio_intent", !plan.say.isEmpty, m.text == "🎙️ 语音指令" {
                    m.text = "🎙️ 语音指令"
                }
            }
            updateMessage(id: assistantId) {
                $0.text = plan.say
                $0.isTypingCursor = false
                $0.robotPlan = plan
                $0.routeTierFinishedAt = Date()
            }
            audioNote.finalizeStaged(deleteFile: true)
            robotStatusLine = plan.need_confirm ? "动作待确认，未执行" : "语音动作预览，未执行"
            if autoSpeakEnabled, !plan.say.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                liveTTSPlayer.speak(text: plan.say, voice: autoSpeakVoice, format: "mp3")
            }
        } catch {
            audioNote.restoreStagedToPending()
            updateMessage(id: assistantId) {
                $0.text = "语音动作解析失败：\(error.localizedDescription)"
                $0.isTypingCursor = false
            }
            robotStatusLine = "六足语音解析失败"
        }
        scheduleScrollNow(to: .bottom, anchor: .bottom)
    }

    @MainActor
    private func stopRobotImmediately() async {
        speechPlayer.stop()
        liveTTSPlayer.stop()
        robotStatusLine = "正在 STOP"
        do {
            let plan = try await postRobotCommand(cmd: "STOP")
            let assistantId = UUID()
            messages.append(.init(
                id: assistantId,
                role: .assistant,
                text: plan.say,
                robotPlan: plan,
                routeTier: .fast,
                routeTierFinishedAt: Date()
            ))
            pinnedAssistantId = assistantId
            robotStatusLine = "STOP 已执行"
        } catch {
            messages.append(.init(role: .system, text: "STOP 发送失败：\(error.localizedDescription)"))
            robotStatusLine = "STOP 发送失败"
        }
        scheduleScrollNow(to: .bottom, anchor: .bottom)
    }

    private func robotURL(path: String) throws -> URL {
        let base = apiBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + path) else {
            throw NSError(domain: "RobotBrain", code: -1, userInfo: [NSLocalizedDescriptionKey: "URL 无效"])
        }
        return url
    }

    private func robotGET(path: String) async throws -> [String: Any] {
        let url = try robotURL(path: path)
        let (data, resp) = try await URLSession.shared.data(from: url)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            throw NSError(domain: "RobotBrain", code: code, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"])
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func postRobotVoiceIntent(text: String, source: String) async throws -> RobotBrainPlan {
        let obj = try await postRobotJSON(path: "/api/adu/robot/hexapod/voice_intent", body: [
            "text": text,
            "execute": false,
            "source": source,
            "system_definition": robotSystemDefinition
        ])
        return parseRobotPlan(obj)
    }

    private func postRobotPerceptionTick(transcript: String, source: String) async throws -> RobotBrainPlan {
        let scene = buildRobotPerceptionScene(transcript: transcript)
        let goal = inferRobotPerceptionGoal(transcript: transcript, scene: scene)
        let response = try await hexapodRobotService.sendPerceptionTick(
            goal: goal,
            transcript: transcript,
            scene: scene,
            execute: false
        )
        let payload = HexapodPerceptionTickRequest(goal: goal, transcript: transcript, scene: scene, execute: false)
        return parseRobotPlan(response, payload: payload, source: source)
    }

    @MainActor
    private func executeRobotPreview(_ plan: RobotBrainPlan) async {
        guard var payload = plan.perceptionPayload else { return }
        guard plan.executed != true else { return }
        robotPlannerBusy = true
        robotStatusLine = "正在执行本轮动作"
        defer { robotPlannerBusy = false }

        payload.execute = true
        do {
            let response = try await hexapodRobotService.sendPerceptionTick(
                goal: payload.goal,
                transcript: payload.transcript,
                scene: payload.scene,
                execute: true
            )
            let executedPlan = parseRobotPlan(response, payload: payload, source: "perception_tick_execute")
            let assistantId = UUID()
            messages.append(.init(
                id: assistantId,
                role: .assistant,
                text: executedPlan.say,
                robotPlan: executedPlan,
                routeTier: .fast,
                routeTierFinishedAt: Date()
            ))
            pinnedAssistantId = assistantId
            robotStatusLine = executedPlan.executed == true ? "本轮动作已执行" : "执行请求已返回"
        } catch {
            messages.append(.init(role: .system, text: "执行本轮动作失败：\(error.localizedDescription)"))
            robotStatusLine = "执行失败"
        }
        scheduleScrollNow(to: .bottom, anchor: .bottom)
    }

    private func buildRobotPerceptionScene(transcript: String) -> HexapodScene {
        let snap = robotPerception.snapshot()
        let caption = snap.sceneDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let decision = snap.decision.trimmingCharacters(in: .whitespacesAndNewlines)
        let objectLabels = snap.objects.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let lowerText = (caption + " " + decision + " " + objectLabels.joined(separator: " ")).lowercased()

        let personVisible = containsAny(lowerText, ["person", "human", "用户", "人", "行人"])
        let obstacleFront = containsAny(lowerText, ["obstacle", "wall", "table", "chair", "障碍", "墙", "桌", "椅", "挡住", "危险"])
        let doorVisible = containsAny(lowerText, ["door", "门"])
        let floorUnclear = caption.isEmpty || containsAny(lowerText, ["地面不清", "看不清", "unclear", "unknown floor", "floor_unclear"])

        return HexapodScene(
            caption: caption,
            objects: objectLabels,
            vision_decision: decision,
            person_visible: personVisible,
            person_position: inferPersonPosition(from: lowerText),
            obstacle_front: obstacleFront,
            door_visible: doorVisible,
            floor_unclear: floorUnclear,
            free_space: containsAny(lowerText, ["空旷", "无障碍", "clear", "free"]) ? "front" : nil,
            confidence: snap.confidence > 0 ? snap.confidence : (caption.isEmpty ? 0.6 : 0.82)
        )
    }

    private func inferRobotPerceptionGoal(transcript: String, scene: HexapodScene) -> String {
        let text = transcript.lowercased()
        if isRobotStopTranscript(text) {
            return "stop"
        }
        if containsAny(text, ["门", "door", "出口"]) {
            return "find_door"
        }
        if containsAny(text, ["看到了什么", "看一下", "看看周围", "describe", "scene"]) {
            return "describe_scene"
        }
        if containsAny(text, ["过来", "靠近", "来我", "到我", "跟着", "follow", "approach"]) {
            return "approach_user"
        }
        if containsAny(text, ["往前", "前进", "走", "forward"]) {
            return "move_forward_safely"
        }
        if scene.person_visible == true && containsAny(text, ["挪", "动", "演示"]) {
            return "approach_user"
        }
        return "preview"
    }

    private func inferPersonPosition(from text: String) -> String {
        if containsAny(text, ["right_front", "右前", "右前方", "右侧前方"]) { return "right_front" }
        if containsAny(text, ["left_front", "左前", "左前方", "左侧前方"]) { return "left_front" }
        if containsAny(text, ["center", "front", "正前", "前方", "中间"]) { return "front" }
        return "unknown"
    }

    private func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0.lowercased()) }
    }

    private func isRobotStopTranscript(_ text: String) -> Bool {
        containsAny(text.lowercased(), ["停下", "停止", "别动", "马上停", "stop"])
    }

    private func postRobotCommand(cmd: String) async throws -> RobotBrainPlan {
        let obj = try await postRobotJSON(path: "/api/adu/robot/hexapod/command", body: ["cmd": cmd])
        let action = RobotBrainAction(cmd: cmd.uppercased(), duration_ms: nil)
        let ok = (obj["ok"] as? Bool) ?? false
        return RobotBrainPlan(
            say: ok ? "已安全停止。" : "STOP 已发送，但底层未确认。",
            actions: [action],
            need_confirm: false,
            executed: ok,
            plan_only: false,
            message: (obj["message"] as? String) ?? (obj["error"] as? String),
            source: "command"
        )
    }

    private func postRobotJSON(path: String, body: [String: Any]) async throws -> [String: Any] {
        let url = try robotURL(path: path)
        var req = AccountManager.makeAuthorizedRequest(url)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(clientId, forHTTPHeaderField: "X-Client-ID")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(code) else {
            let detail = (obj["detail"] as? String) ?? (obj["error"] as? String) ?? "HTTP \(code)"
            throw NSError(domain: "RobotBrain", code: code, userInfo: [NSLocalizedDescriptionKey: detail])
        }
        return obj
    }

    private func postRobotAudioIntent(audioURL: URL) async throws -> RobotBrainPlan {
        let url = try robotURL(path: "/api/adu/robot/hexapod/audio_intent")
        let boundary = "RobotBrainBoundary-\(UUID().uuidString)"
        var req = AccountManager.makeAuthorizedRequest(url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue(clientId, forHTTPHeaderField: "X-Client-ID")

        let data = try Data(contentsOf: audioURL)
        var body = Data()
        func append(_ s: String) { body.append(Data(s.utf8)) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"execute\"\r\n\r\nfalse\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"audio\"; filename=\"voice.m4a\"\r\n")
        append("Content-Type: audio/mp4\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")
        req.httpBody = body

        let (respData, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let obj = (try? JSONSerialization.jsonObject(with: respData)) as? [String: Any] ?? [:]
        guard (200..<300).contains(code) else {
            let detail = (obj["detail"] as? String) ?? (obj["error"] as? String) ?? "HTTP \(code)"
            throw NSError(domain: "RobotBrainAudio", code: code, userInfo: [NSLocalizedDescriptionKey: detail])
        }
        return parseRobotPlan(obj)
    }

    private var robotSystemDefinition: String {
        "你是 ChatAGI 阿杜的六足机器人助手模式。你仍然是通用 AI 助手，但当前连接了六足机器人身体。你需要一边和用户互动，一边把用户的机器人动作意图实时解析为安全动作序列。动作库只保留开机帅站立和安全停止，其余动作都由你现场解析生成。你只能输出白名单动作原语，不得输出舵机角度。STOP 永远最高优先级。"
    }

    private func parseRobotPlan(_ obj: [String: Any]) -> RobotBrainPlan {
        let rawActions = (obj["actions"] as? [[String: Any]]) ?? []
        let actions = rawActions.compactMap { item -> RobotBrainAction? in
            guard let cmd = item["cmd"] as? String, !cmd.isEmpty else { return nil }
            let duration = (item["duration_ms"] as? Int) ?? (item["duration_ms"] as? NSNumber)?.intValue
            return RobotBrainAction(cmd: cmd, duration_ms: duration)
        }
        let fallbackActions = actions.isEmpty ? [RobotBrainAction(cmd: "STOP", duration_ms: nil)] : actions
        let say = ((obj["say"] as? String)
            ?? (obj["after_action_say"] as? String)
            ?? (obj["message"] as? String)
            ?? "好的。")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let source = (obj["source"] as? String) ?? (obj["skill_id"] as? String)
        let executed = obj["executed"] as? Bool
        return RobotBrainPlan(
            say: say.isEmpty ? "好的。" : say,
            actions: fallbackActions,
            need_confirm: (obj["need_confirm"] as? Bool) ?? false,
            executed: executed,
            plan_only: (obj["plan_only"] as? Bool) ?? (executed == false ? true : nil),
            message: obj["message"] as? String,
            source: source,
            skill_id: obj["skill_id"] as? String
        )
    }

    private func parseRobotPlan(_ response: HexapodPerceptionResponse, payload: HexapodPerceptionTickRequest?, source: String) -> RobotBrainPlan {
        let actions = (response.actions ?? []).map {
            RobotBrainAction(cmd: $0.cmd, duration_ms: $0.duration_ms)
        }
        let fallbackActions = actions.isEmpty ? [RobotBrainAction(cmd: "STOP", duration_ms: nil)] : actions
        let say = (response.after_action_say ?? response.error ?? "好的。")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return RobotBrainPlan(
            say: say.isEmpty ? "好的。" : say,
            actions: fallbackActions,
            need_confirm: false,
            executed: response.executed,
            plan_only: response.executed == false ? true : nil,
            message: response.error,
            source: source,
            skill_id: response.skill_id,
            perceptionPayload: payload
        )
    }

    @MainActor
    private func fallthroughToNormalChat(text: String) {
        // 用 bypassPlannerOnce 重入 onSendOrStop —— 等同于"用户原样按下发送、不要再进 planner",
        // 这样原始 /chat/prepare 链路(记忆/联网/文件图片理解/主人格)一次都不漏。
        bypassPlannerOnce = true
        isSending = false
        focused = false
        inputText = text
        onSendOrStop()
    }

    @MainActor
    private func routeAduPlannerInput(_ text: String) async {
        do {
            let route = try await AduBackendPlannerClient.route(
                apiBase: apiBase,
                text: text,
                surface: computerControlMode || showComputerControl ? .computerControl : .homeChat,
                recentMessages: makeAduPlannerRecentMessages(),
                pendingCodexTask: makePendingCodexPayload(),
                selectedProject: pendingProject,
                screenState: makeAduPlannerScreenState()
            )
            isSending = false
            if plannerShouldIntercept(intent: route.intent, confidence: route.confidence) {
                dispatchBackendPlannerRoute(route, originalText: text)
            } else {
                // chat_answer / ask_clarification / unknown / 低置信 → 走原聊天
                fallthroughToNormalChat(text: text)
            }
        } catch {
            // planner 网络错 / 解析错 → 先用本地启发,但只在本地启发命中"工具"时才拦截。
            // 否则同样 fallthrough,让用户的"你是谁"之类问题始终被普通聊天接住。
            let plan = AduTaskPlanner.plan(text, context: makeAduPlannerContext())
            isSending = false
            if Self.plannerInterceptIntents.contains(plan.type.rawValue) {
                dispatchLocalPlannerFallback(plan, originalText: text)
            } else {
                fallthroughToNormalChat(text: text)
            }
        }
    }

    @MainActor
    private func dispatchBackendPlannerRoute(_ route: AduBackendPlannerRoute, originalText: String) {
        let plan = route.asTaskPlan
        switch route.intentType {
        case .computerAction:
            let goal = route.computerGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? originalText : route.computerGoal
            startPlannerComputerAction(plan: AduTaskPlan(type: .computerAction, originalInput: originalText, organizedTask: goal, nextAction: route.nextAction, suggestedProject: route.project))
        case .codexTask:
            showCodexPlanConfirmation(plan: AduTaskPlan(type: .codexTask, originalInput: originalText, organizedTask: route.codexPrompt.isEmpty ? plan.organizedTask : route.codexPrompt, nextAction: route.nextAction, suggestedProject: route.project ?? "GPTsora", suggestedProjectId: route.projectId))
            pendingRiskLevel = route.riskLevel.isEmpty ? "medium" : route.riskLevel
            pendingReason = route.summary
            pendingWorkspacePath = codexProjectPath(for: route.projectId ?? route.project)
        case .selfUpgradeTask:
            routeSelfUpgradeToPlanCard(goal: originalText)
            pendingRiskLevel = route.riskLevel.isEmpty ? "high" : route.riskLevel
            pendingReason = route.summary.isEmpty ? "自我升级:阿杜检查系统可升级点" : route.summary
            pendingWorkspacePath = codexProjectPath(for: route.projectId ?? route.project)
        case .continuePreviousTask:
            continuePendingCodexPlan(userText: originalText)
        case .confirmPendingTask:
            confirmPendingCodexPlan(userText: originalText)
        case .cancelPendingTask:
            cancelPendingCodexPlan(userText: originalText)
        case .editPendingTask:
            editPendingCodexPlan(userText: originalText, plan: plan)
        case .chatAnswer, .askClarification:
            // 防御:routeAduPlannerInput 已经在 intercept 之前拦截过这两类,
            // 一旦走到这里说明上层判断走样,直接 fallthrough,绝不弹弱回答。
            fallthroughToNormalChat(text: originalText)
        case .claudeTask:
            // claude_task 是工具意图,但当前仍只展示 prompt,不自动执行。
            _ = appendPlannerUserAndAssistant(userText: originalText, assistantText: route.message.isEmpty ? "已整理为 Claude 预览任务，当前只展示 prompt，不自动执行。\n\n\(plan.organizedTask)" : route.message)
        case .fileSearchTask:
            // V3:HomeChat 主输入栏已断 planner;若外部强行调用到这里,直接转给普通聊天,
            //    让助手通过 recentSummary 引导用户进入电脑控制面板做真正的搜索。
            fallthroughToNormalChat(text: originalText)
        }
    }

    @MainActor
    private func dispatchLocalPlannerFallback(_ plan: AduTaskPlan, originalText: String) {
        let fallbackPrefix = "已使用本地 fallback 判断。\n\n"
        switch plan.type {
        case .computerAction:
            startPlannerComputerAction(plan: AduTaskPlan(type: plan.type, originalInput: plan.originalInput, organizedTask: plan.organizedTask, nextAction: fallbackPrefix + plan.nextAction, suggestedProject: plan.suggestedProject))
        case .codexTask:
            showCodexPlanConfirmation(plan: plan)
            if let messageId = pendingCodexAssistantId {
                updateMessage(id: messageId) { $0.text = fallbackPrefix + $0.text }
            }
        case .selfUpgradeTask:
            routeSelfUpgradeToPlanCard(goal: originalText)
        case .continuePreviousTask:
            continuePendingCodexPlan(userText: originalText)
        case .confirmPendingTask:
            confirmPendingCodexPlan(userText: originalText)
        case .cancelPendingTask:
            cancelPendingCodexPlan(userText: originalText)
        case .editPendingTask:
            editPendingCodexPlan(userText: originalText, plan: plan)
        case .chatAnswer, .askClarification:
            // 本地启发已经不该走到这里(routeAduPlannerInput 已先 fallthrough),保险起见再兜一道。
            fallthroughToNormalChat(text: originalText)
        case .claudeTask:
            _ = appendPlannerUserAndAssistant(userText: originalText, assistantText: fallbackPrefix + plan.organizedTask)
        case .fileSearchTask:
            fallthroughToNormalChat(text: originalText)
        }
    }

    private func inferPlannerIntent(from text: String?) -> String? {
        guard let text else { return nil }
        let lower = text.lowercased()
        if lower.contains("codex") || lower.contains("自动化编程") { return AduTaskIntentType.codexTask.rawValue }
        if lower.contains("电脑操作") || lower.contains("local-agent") || lower.contains("computer") { return AduTaskIntentType.computerAction.rawValue }
        if lower.contains("自我升级") { return AduTaskIntentType.selfUpgradeTask.rawValue }
        return AduTaskIntentType.chatAnswer.rawValue
    }

    @MainActor
    private func appendPlannerUserAndAssistant(userText: String, assistantText: String, typing: Bool = false) -> UUID {
        inputText = ""
        focused = false

        let userId = UUID()
        messages.append(.init(id: userId, role: .user, text: userText))
        pinnedUserId = userId

        let assistantId = UUID()
        messages.append(.init(id: assistantId, role: .assistant, text: assistantText, isTypingCursor: typing))
        pinnedAssistantId = assistantId
        scheduleScrollNow(to: .bottom, anchor: .bottom)
        return assistantId
    }

    @MainActor
    private func startPlannerComputerAction(plan: AduTaskPlan) {
        let fallbackPrefix = "已使用本地 fallback 判断。\n\n"
        let assistantId = appendPlannerUserAndAssistant(
            userText: plan.originalInput,
            assistantText: plan.nextAction.hasPrefix(fallbackPrefix) ? fallbackPrefix + "正在执行电脑操作..." : "正在执行电脑操作...",
            typing: true
        )

        isSending = true
        sendTask?.cancel()
        speechPlayer.stop()
        liveTTSPlayer.stop()

        sendTask = Task { @MainActor in
            defer { isSending = false }
            do {
                let result = try await postPlannerComputerAction(goal: plan.originalInput)
                updateMessage(id: assistantId) {
                    $0.text = result
                    $0.isTypingCursor = false
                }
            } catch {
                updateMessage(id: assistantId) {
                    $0.text = friendlyNetworkMessage(error)
                    $0.isTypingCursor = false
                }
            }
            scheduleScrollNow(to: .bottom, anchor: .bottom)
        }
    }

    @MainActor
    private func showCodexPlanConfirmation(plan: AduTaskPlan) {
        let assistantId = appendPlannerUserAndAssistant(
            userText: plan.originalInput,
            assistantText: "已整理为 Codex 自动化编程任务。请检查下面的 prompt，确认后再运行。",
            typing: false
        )
        pendingCodexTask = plan
        pendingProject = plan.suggestedProject ?? "GPTsora"
        pendingPrompt = plan.organizedTask
        pendingRiskLevel = plan.type == .selfUpgradeTask ? "high" : "medium"
        pendingCreatedAt = Date()
        pendingCodexAssistantId = assistantId
    }

    @MainActor
    private func showSelfUpgradePlan(plan: AduTaskPlan) {
        routeSelfUpgradeToPlanCard(goal: plan.originalInput)
    }

    @MainActor
    private func cancelPendingCodexPlan(messageId: UUID) {
        guard pendingCodexAssistantId == messageId else { return }
        clearPendingCodexTask()
        codexPlannerRunning = false
        updateMessage(id: messageId) {
            $0.text = "已取消 Codex 任务。"
            $0.isTypingCursor = false
        }
    }

    @MainActor
    private func cancelPendingCodexPlan(userText: String) {
        guard let messageId = pendingCodexAssistantId else {
            _ = appendPlannerUserAndAssistant(userText: userText, assistantText: "当前没有待取消的 Codex 任务。")
            return
        }
        _ = appendPlannerUserAndAssistant(userText: userText, assistantText: "已取消 Codex 任务。")
        clearPendingCodexTask()
        codexPlannerRunning = false
        updateMessage(id: messageId) {
            $0.text = "已取消 Codex 任务。"
            $0.isTypingCursor = false
        }
    }

    @MainActor
    private func continuePendingCodexPlan(userText: String) {
        guard pendingCodexTask != nil else {
            _ = appendPlannerUserAndAssistant(userText: userText, assistantText: "我没有找到待继续的 Codex 任务，你想让我继续哪一个？")
            return
        }
        _ = appendPlannerUserAndAssistant(userText: userText, assistantText: "将继续上一条 Codex 任务。你可以确认运行、取消、编辑或复制 prompt。")
    }

    @MainActor
    private func editPendingCodexPlan(messageId: UUID) {
        guard pendingCodexAssistantId == messageId, !pendingPrompt.isEmpty else { return }
        inputText = pendingPrompt
        focused = true
    }

    @MainActor
    private func editPendingCodexPlan(userText: String, plan: AduTaskPlan) {
        guard pendingCodexTask != nil else {
            _ = appendPlannerUserAndAssistant(
                userText: userText,
                assistantText: "我收到了这个约束，但当前没有待修改的 Codex 任务。你想把它应用到哪个任务？"
            )
            return
        }

        pendingPrompt = pendingPrompt.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n补充约束:\n- \(userText)"
        if let suggested = plan.suggestedProject, suggested == "GPTsora" {
            pendingProject = suggested
        }
        _ = appendPlannerUserAndAssistant(userText: userText, assistantText: "已更新上一条 Codex 任务的 prompt，未重新生成新任务。")
    }

    @MainActor
    private func clearPendingCodexTask() {
        pendingCodexTask = nil
        pendingProject = nil
        pendingPrompt = ""
        pendingRiskLevel = "medium"
        pendingReason = ""
        pendingWorkspacePath = ""
        pendingCreatedAt = nil
        pendingCodexAssistantId = nil
    }

    @MainActor
    private func confirmPendingCodexPlan(messageId: UUID) {
        guard let plan = pendingCodexTask, pendingCodexAssistantId == messageId, !codexPlannerRunning else { return }
        codexPlannerRunning = true
        isSending = true
        sendTask?.cancel()
        speechPlayer.stop()
        liveTTSPlayer.stop()

        updateMessage(id: messageId) {
            $0.text = "正在运行 Codex 任务..."
            $0.isTypingCursor = true
        }

        let task = pendingPrompt.isEmpty ? plan.organizedTask : pendingPrompt
        let projectDir = codexProjectPath(for: pendingProject ?? plan.suggestedProject)
        // planner 自动选好的 registry id;若有,后端用 id 直接定位工程目录,projectDir 只做兼容。
        let projectId = plan.suggestedProjectId

        sendTask = Task { @MainActor in
            defer {
                isSending = false
                codexPlannerRunning = false
            }

            let result = await CodexAgentClient.run(
                apiBase: apiBase,
                task: task,
                projectDir: projectDir,
                timeout: 900,
                projectId: projectId
            )
            if Task.isCancelled { return }

            clearPendingCodexTask()

            updateMessage(id: messageId) {
                $0.text = formatCodexRunResult(result, projectDir: projectDir)
                $0.isTypingCursor = false
            }
            scheduleScrollNow(to: .bottom, anchor: .bottom)
        }
    }

    @MainActor
    private func confirmPendingCodexPlan(userText: String) {
        guard let messageId = pendingCodexAssistantId else {
            _ = appendPlannerUserAndAssistant(userText: userText, assistantText: "我没有找到待执行的 Codex 任务。")
            return
        }
        let userId = UUID()
        messages.append(.init(id: userId, role: .user, text: userText))
        pinnedUserId = userId
        scheduleScrollNow(to: .bottom, anchor: .bottom)
        confirmPendingCodexPlan(messageId: messageId)
    }

    private func codexProjectPath(for suggested: String?) -> String {
        // 优先按后端 registry 标准 id 匹配(planner 现在会填 project_id),再回退到老的 display name。
        switch (suggested ?? "").lowercased() {
        case "backend":        return "~/Desktop/backend"
        case "little_beijing", "littlebeijing", "little beijing":
                               return "~/Desktop/little-beijing-edge-box"
        case "chatagi_site", "chatagisite", "chatagi site":
                               return "~/Desktop/chatagi-site"
        case "gptsora":        return "~/Desktop/GPTsora"
        default: break
        }
        switch suggested {
        case "Backend":        return "~/Desktop/backend"
        case "Little Beijing": return "~/Desktop/little-beijing-edge-box"
        case "ChatAGISite":    return "~/Desktop/chatagi-site"
        default:               return "~/Desktop/GPTsora"
        }
    }

    private func formatCodexRunResult(_ result: CodexRunResult, projectDir: String) -> String {
        if result.needsUserConfirmation {
            let blocked = result.blockedTerms.isEmpty ? "" : "\nblocked_terms: \(result.blockedTerms.joined(separator: ", "))"
            let reason = result.riskReason.isEmpty ? "" : "\nreason: \(result.riskReason)"
            return "Codex 后端要求额外确认，App 不会自动继续执行。\nproject: \(projectDir)\(blocked)\(reason)"
        }

        var parts: [String] = []
        parts.append(result.ok ? "Codex 任务完成。" : "Codex 任务失败。")
        parts.append("project: \(projectDir)")
        if let code = result.exitCode { parts.append("exit_code: \(code)") }
        if let duration = result.durationSec { parts.append(String(format: "duration: %.1fs", duration)) }
        if let error = result.error, !error.isEmpty { parts.append("error: \(error)") }
        if let message = result.message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            parts.append("message:\n\(message)")
        }
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stdout.isEmpty { parts.append("stdout:\n\(truncateForChat(stdout, limit: 4000))") }
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { parts.append("stderr:\n\(truncateForChat(stderr, limit: 2000))") }
        return parts.joined(separator: "\n\n")
    }

    private func truncateForChat(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let idx = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<idx]) + "\n...(已截断)"
    }

    private func postPlannerComputerAction(goal: String) async throws -> String {
        let base = apiBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/api/brain/computer/action") else {
            throw NSError(domain: "PlannerComputerAction", code: -1, userInfo: [NSLocalizedDescriptionKey: "URL 无效"])
        }

        var req = AccountManager.makeAuthorizedRequest(url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(clientId, forHTTPHeaderField: "X-Client-ID")

        var body: [String: Any] = [
            "goal": goal,
            "text": goal,
            "client_id": clientId,
            "conversation_id": currentConversationId ?? ""
        ]
        if let parsed = buildComputerActionPayload(from: goal) {
            body["action"] = parsed.action
            body["payload"] = parsed.payload
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        guard (200..<300).contains(code) else {
            let err = (obj["error"] as? String) ?? (obj["detail"] as? String) ?? "HTTP \(code)"
            throw NSError(domain: "PlannerComputerAction", code: code, userInfo: [NSLocalizedDescriptionKey: err])
        }

        let ok = (obj["ok"] as? Bool) ?? false
        if !ok {
            let err = (obj["error"] as? String) ?? (obj["detail"] as? String) ?? "电脑动作执行失败"
            throw NSError(domain: "PlannerComputerAction", code: 500, userInfo: [NSLocalizedDescriptionKey: err])
        }

        let action = (obj["action"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let directMessage = (obj["message"] as? String)
            ?? (obj["final_text"] as? String)
            ?? ((obj["result"] as? [String: Any])?["message"] as? String)
            ?? ""
        var final = directMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if final.isEmpty, let parsed = buildComputerActionPayload(from: goal) {
            final = parsed.message
        }
        if final.isEmpty {
            final = "电脑动作已执行。"
        }
        if !action.isEmpty {
            return "[\(action)] \(final)"
        }
        return final
    }

    // MARK: - Computer Action Routing (只保留新 local-agent 链路)

    @MainActor
    private func enterComputerControlSurface(startVoice: Bool) {
        focused = false
        audioPlayer.stop()
        speechPlayer.stop()
        liveTTSPlayer.stop()
        computerControlMode = true
        computerVoiceStatus.lastError = ""
        computerVoiceStatus.lastResult = ""

        withAnimation(.easeInOut(duration: 0.18)) {
            surfaceMode = .computer
        }

        Task {
            try? await UnifiedTaskService.shared.sendComputerModeCommand(
                text: "",
                action: "open_computer_control",
                sessionId: currentConversationId,
                userId: clientId
            )
        }

        if startVoice {
            startComputerControlVoice()
        }
    }

    @MainActor
    private func leaveComputerControlSurface() {
        cancelComputerVoiceExecution()
        stopComputerControlVoice()
        computerControlMode = false
        withAnimation(.easeInOut(duration: 0.18)) {
            surfaceMode = .chat
        }
    }

    @MainActor
    private func startComputerControlVoice() {
        computerVoiceStatus.executionState = rt.isConnected ? .listening : .connecting
        computerVoiceStatus.realtimeStatus = rt.status
        computerVoiceStatus.isRealtimeConnected = rt.isConnected
        configureRealtimeForCurrentPlan()
        fast.ensureConnected(apiBase: apiBase)
    }

    @MainActor
    private func stopComputerControlVoice() {
        cancelComputerVoiceExecution()
        fast.stop()
        computerVoiceStatus.executionState = .idle
        computerVoiceStatus.realtimeStatus = "已断开"
        computerVoiceStatus.isRealtimeConnected = false
    }

    @MainActor
    private func cancelComputerVoiceExecution() {
        computerVoiceExecutionTask?.cancel()
        computerVoiceExecutionTask = nil
        computerVoiceExecutionId = nil
        if computerVoiceStatus.isExecuting {
            computerVoiceStatus.executionState = .cancelled
            computerVoiceStatus.lastResult = "已取消当前电脑控制指令。"
            aduContext.appendSystem("已取消当前电脑控制语音指令。")
        }
    }

    @MainActor
    private func routeComputerControlRealtimeUtterance(_ text: String, existingUserMessageId: UUID) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        computerVoiceExecutionTask?.cancel()
        computerVoiceStatus.executionState = .executing
        computerVoiceStatus.realtimeStatus = rt.status
        computerVoiceStatus.isRealtimeConnected = rt.isConnected
        computerVoiceStatus.lastCommand = trimmed
        computerVoiceStatus.lastResult = ""
        computerVoiceStatus.lastError = ""

        aduContext.appendUserMessage(trimmed, source: .computer_task_input, metadata: ["input": "realtime_voice"])
        aduContext.appendComputerActionStarted(goal: trimmed)

        let executionId = UUID()
        computerVoiceExecutionId = executionId

        let task = Task { @MainActor in
            do {
                let result = try await UnifiedTaskService.shared.sendComputerModeCommand(
                    text: trimmed,
                    source: "realtime_voice",
                    requiresRealtime: true,
                    sessionId: currentConversationId,
                    userId: clientId
                )
                guard !Task.isCancelled, computerVoiceExecutionId == executionId else { return }
                let final = ComputerControlUnifiedResponseFormatter.finalText(from: result)
                computerVoiceStatus.executionState = result.ok ? .succeeded : .failed
                computerVoiceStatus.lastResult = final
                computerVoiceStatus.lastError = result.ok ? "" : final
                aduContext.appendComputerActionResult(
                    goal: trimmed,
                    ok: result.ok,
                    message: final,
                    metadata: [
                        "route": result.route,
                        "status_code": "\(result.statusCode)",
                        "input": "realtime_voice"
                    ]
                )
                computerVoiceExecutionId = nil
                computerVoiceExecutionTask = nil
            } catch is CancellationError {
                guard computerVoiceExecutionId == executionId else { return }
                computerVoiceStatus.executionState = .cancelled
                computerVoiceStatus.lastResult = "已取消当前电脑控制指令。"
                computerVoiceExecutionId = nil
                computerVoiceExecutionTask = nil
            } catch {
                guard computerVoiceExecutionId == executionId else { return }
                let message = friendlyNetworkMessage(error)
                computerVoiceStatus.executionState = .failed
                computerVoiceStatus.lastError = message
                computerVoiceStatus.lastResult = message
                aduContext.appendComputerActionResult(
                    goal: trimmed,
                    ok: false,
                    message: message,
                    metadata: ["input": "realtime_voice"]
                )
                computerVoiceExecutionId = nil
                computerVoiceExecutionTask = nil
            }
        }
        computerVoiceExecutionTask = task
    }

    private func isComputerControlOpenCommand(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "，", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "。", with: "")
            .replacingOccurrences(of: "！", with: "")
            .replacingOccurrences(of: "!", with: "")
        let triggers = [
            "控制电脑",
            "打开电脑控制",
            "显示电脑画面",
            "帮我操作电脑"
        ]
        return triggers.contains { normalized.contains($0) }
    }

    private func openComputerControlPanel(prefill: String = "") {
        if !prefill.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pendingComputerControlInstruction = prefill
        }
        enterComputerControlSurface(startVoice: true)
    }

    private func looksLikeComputerTask(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.isEmpty { return false }
        let keywords = [
            "截图", "截屏", "看屏幕", "打开微信", "打开浏览器", "打开 chrome", "打开chrome",
            "打开 safari", "打开safari", "点击", "鼠标", "打字", "输入", "粘贴", "按键",
            "command", "cmd", "enter", "回车", "运行扫描", "控制电脑", "computer",
            "screenshot", "click", "type", "press", "open app"
        ]
        return keywords.contains { t.contains($0.lowercased()) }
    }

    /// 自动化编程 / 递归自我升级意图 → 走 DevBrain /api/brain/dev/run。
    /// 比 looksLikeComputerTask 更具体,放在它前面判断。
    private func looksLikeDevTask(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.isEmpty { return false }
        let keywords = [
            "自动化编程", "递归升级", "递归自我", "自我升级", "自我进化", "自动改代码", "自动修复",
            "修复代码", "修复工程", "修工程", "修一下工程", "检查工程", "检查项目",
            "跑测试", "运行测试", "跑一下测试", "run tests", "编译", "build", "compile",
            "打开 xcode", "打开xcode", "open xcode",
            "调 codex", "调codex", "用 codex", "调 claude", "调claude", "用 claude",
            "codex", "claude", "dev agent", "devbrain", "dev brain", "自动化升级"
        ]
        return keywords.contains { t.contains($0.lowercased()) }
    }

    // V2.2:主输入栏自我升级触发短语识别。
    // 跟后端 adu_planner_router._fallback_plan 的 self_upgrade 关键词对齐(中文为主),
    // 命中即由 onSendOrStop 拉 /api/adu/self/upgrade/plan,不进 /chat/prepare、不消耗免费额度、不调 Codex。
    private func isSelfUpgradeTrigger(_ text: String) -> Bool {
        let needles = [
            "你自己检查系统哪里还能升级",
            "检查系统哪里还能升级",
            "哪里还能升级",
            "自我升级",
            "自己升级",
            "自我进化",
            "递归自我进化",
            "递归自我改进",
            "自我改进",
            "检查当前系统能力",
            "检查当前系统问题",
            "生成升级计划",
            "自己诊断一下系统",
            "阿杜你自己诊断一下系统",
            "你自己升级一下",
        ]
        return needles.contains(where: { text.contains($0) })
    }

    @MainActor
    private func routeSelfUpgradeToPlanCard(goal: String) {
        inputText = ""
        focused = false
        clearPendingCodexTask()
        codexPlannerRunning = false
        aduContext.appendUserMessage(goal, source: .home_chat_input)
        let userId = UUID()
        messages.append(.init(id: userId, role: .user, text: goal))
        messages.append(.init(role: .system, text: "已识别为自我升级任务,切换到电脑控制面板并请求 /api/adu/self/upgrade/plan(plan_only · 不自动执行 Codex)。"))
        pinnedUserId = userId
        aduContext.pendingSelfUpgradeGoal = goal
        withAnimation(.easeInOut(duration: 0.18)) {
            surfaceMode = .computer
        }
    }

    private struct ComputerTaskGatewayResponse {
        let ok: Bool
        let taskId: String
        let status: String
        let needConfirm: Bool
        let confirmText: String
        let errorText: String
        let finalText: String?
        let stepsText: String
        let screenshotImage: UIImage?
        // ✅ 统一入口语义：computer = 电脑任务；chat = 后端判定为聊天，前端继续走聊天流
        let route: String
    }



    /// ✅ 把“打开微信/打开Chrome/启动终端”等自然语言，转换成 Mac Spotlight 可搜索的 App 名称。
    /// 只走新链路：/api/brain/computer/action(action=open_app)。
    private func extractAppToOpen(from raw: String) -> (query: String, display: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        let lower = trimmed.lowercased()
        let compact = lower
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "，", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "。", with: "")
            .replacingOccurrences(of: "！", with: "")
            .replacingOccurrences(of: "!", with: "")

        // 这些不是“打开应用”，先交给后面的基础动作分支。
        if trimmed.contains("聚焦搜索") || trimmed.contains("打开搜索") || trimmed.contains("打开电脑搜索") || lower.contains("spotlight") {
            return nil
        }

        // 明确应用别名。query 用英文更容易被 macOS Spotlight 命中。
        let aliases: [(keys: [String], query: String, display: String)] = [
            (["微信", "wechat", "we chat"], "WeChat", "微信"),
            (["chrome", "谷歌浏览器", "谷歌", "googlechrome"], "Google Chrome", "Chrome"),
            (["safari", "苹果浏览器"], "Safari", "Safari"),
            (["xcode"], "Xcode", "Xcode"),
            (["终端", "terminal", "命令行"], "Terminal", "终端"),
            (["备忘录", "notes"], "Notes", "备忘录"),
            (["访达", "finder"], "Finder", "访达"),
            (["设置", "系统设置", "systemsettings", "system settings"], "System Settings", "系统设置"),
            (["邮件", "mail"], "Mail", "邮件"),
            (["照片", "photos"], "Photos", "照片"),
            (["日历", "calendar"], "Calendar", "日历"),
            (["音乐", "music"], "Music", "音乐")
        ]

        let hasOpenIntent = compact.contains("打开") || compact.contains("启动") || compact.contains("运行") || lower.hasPrefix("open ") || lower.hasPrefix("launch ")
        guard hasOpenIntent else { return nil }

        for item in aliases {
            for key in item.keys {
                let k = key.lowercased().replacingOccurrences(of: " ", with: "")
                if compact.contains(k) {
                    return (item.query, item.display)
                }
            }
        }

        // 通用解析：打开 XXX / 启动 XXX / open XXX / launch XXX
        let patterns = [
            "打开", "启动", "运行", "帮我打开", "给我打开"
        ]
        for marker in patterns {
            if let range = trimmed.range(of: marker) {
                let value = String(trimmed[range.upperBound...])
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "：:，,。.!！")))
                if !value.isEmpty, value.count <= 40 {
                    return (value, value)
                }
            }
        }

        if lower.hasPrefix("open ") {
            let value = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return (value, value) }
        }
        if lower.hasPrefix("launch ") {
            let value = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return (value, value) }
        }
        return nil
    }

    /// ✅ 文本/语音 → 新电脑控制动作。
    /// 只走新链路：iPhone -> /api/brain/computer/action -> local-agent 4317。
    /// 这里做前端显式解析，不再依赖旧的 computer task / screen streamer。
    private func buildComputerActionPayload(from text: String) -> (action: String, payload: [String: Any], message: String)? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return nil }

        let lower = raw.lowercased()
        let compact = lower
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "，", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "。", with: "")
            .replacingOccurrences(of: "！", with: "")
            .replacingOccurrences(of: "!", with: "")


        // 打开应用：打开微信 / 打开 Chrome / 启动终端
        if let app = extractAppToOpen(from: raw) {
            return ("open_app", ["app": app.query], "正在打开\(app.display)。")
        }

        // 截图 / 看屏幕
        if raw.contains("截图") || raw.contains("截屏") || raw.contains("看屏幕") || raw.contains("看一下屏幕") || lower.contains("screenshot") {
            return ("screenshot", [:], "已截图。")
        }

        // 鼠标位置
        if raw.contains("鼠标位置") || raw.contains("鼠标在哪") || raw.contains("鼠标哪里") || lower.contains("mouse position") {
            return ("mouse_position", [:], "已获取鼠标位置。")
        }

        // V1.5: 前台应用 / 当前窗口（只读）
        if raw.contains("前台应用") || raw.contains("当前应用") || raw.contains("当前窗口") || raw.contains("哪个应用") || raw.contains("什么应用") || raw.contains("前台窗口") || lower.contains("active window") || lower.contains("frontmost") {
            return ("active_window", [:], "已读取前台窗口。")
        }

        // V1.5: 鼠标移动到 (X, Y)
        if let coords = HomeChatView.parseMoveCoords(from: raw) {
            return ("mouse_move", ["x": coords.0, "y": coords.1], "鼠标已移动到 \(coords.0),\(coords.1)。")
        }

        // 聚焦搜索 / Spotlight / Command+Space
        if raw.contains("聚焦搜索") || raw.contains("聚焦") || lower.contains("spotlight") || raw.contains("打开搜索") || compact.contains("cmdspace") || compact.contains("commandspace") || compact.contains("command+space") || compact.contains("cmd+space") || raw.contains("打开电脑搜索") {
            return ("press_keys", ["keys": ["cmd", "space"]], "已打开聚焦搜索。")
        }

        // V1.5: 通用 hotkey "按 Command S" / "按 cmd+s" / "按 control alt delete"
        if let keys = HomeChatView.parseHotkeyKeys(from: raw), keys.count >= 2 {
            return ("press_keys", ["keys": keys], "已按快捷键：\(keys.joined(separator: "+"))。")
        }

        // 回车 / Enter
        if raw.contains("回车") || lower.contains("enter") || raw.contains("确认键") {
            return ("press_keys", ["keys": ["enter"]], "已按回车。")
        }

        // Esc / Escape
        if lower.contains("escape") || lower.contains("esc") || raw.contains("退出键") || raw.contains("取消键") {
            return ("press_keys", ["keys": ["escape"]], "已按 Esc。")
        }

        // 空格
        if raw.contains("按空格") || raw.contains("空格键") || lower == "space" || lower.contains("press space") {
            return ("press_keys", ["keys": ["space"]], "已按空格。")
        }

        // 删除 / 退格
        if raw.contains("退格") || raw.contains("删除一个") || lower.contains("backspace") {
            return ("press_keys", ["keys": ["backspace"]], "已按退格。")
        }
        if raw.contains("删除键") || lower.contains("delete") {
            return ("press_keys", ["keys": ["delete"]], "已按 Delete。")
        }

        // 左右点击 / 双击：默认当前位置
        if raw.contains("双击") || lower.contains("double click") {
            return ("double_click", [:], "已双击。")
        }
        if raw.contains("右键") || lower.contains("right click") {
            return ("click", ["button": "right"], "已右键点击。")
        }
        if raw.contains("左键") || raw.contains("点一下") || raw.contains("点击") || lower.contains("left click") || lower == "click" {
            return ("click", ["button": "left"], "已左键点击。")
        }

        // 输入 / 打字 / 键入 / type
        if let textToType = extractTextToType(from: raw) {
            return ("type_text", ["text": textToType], "已输入：\(textToType)")
        }

        // V1.5: 粘贴 X / paste X
        if let textToPaste = HomeChatView.extractTextToPaste(from: raw) {
            return ("paste_text", ["text": textToPaste], "已粘贴：\(textToPaste)")
        }

        return nil
    }

    // MARK: - V1.5 NL parser helpers

    /// "移动到 500,500" / "移到 (500, 500)" / "鼠标移到 500、500"
    private static func parseMoveCoords(from raw: String) -> (Int, Int)? {
        let pattern = #"(?:鼠标)?\s*(?:移动到|移到|移动至)\s*[\(\[（【]?\s*(\d+)\s*[,，、\s]+\s*(\d+)\s*[\)\]）】]?"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsRange = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let m = re.firstMatch(in: raw, options: [], range: nsRange) else { return nil }
        guard m.numberOfRanges >= 3,
              let r1 = Range(m.range(at: 1), in: raw),
              let r2 = Range(m.range(at: 2), in: raw),
              let x = Int(raw[r1]), let y = Int(raw[r2]) else { return nil }
        return (x, y)
    }

    /// "按 Command S" / "按 cmd+s" / "按 ctrl alt delete"。必须含修饰键，避免误判。
    private static func parseHotkeyKeys(from raw: String) -> [String]? {
        let pattern = #"按\s*((?:cmd|ctrl|alt|shift|command|control|option|meta|⌘|⌃|⌥|⇧)(?:\s*[+\s,，、]\s*[A-Za-z0-9⌘⌃⌥⇧]+){1,3})"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let nsRange = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let m = re.firstMatch(in: raw, options: [], range: nsRange), m.numberOfRanges >= 2,
              let r = Range(m.range(at: 1), in: raw) else { return nil }
        let body = String(raw[r])
        let split = body.split(whereSeparator: { c -> Bool in
            return c == "+" || c == " " || c == "," || c == "，" || c == "、"
        })
        let symMap: [String: String] = ["⌘": "cmd", "⌃": "ctrl", "⌥": "alt", "⇧": "shift"]
        let keys: [String] = split.map { token in
            let s = token.trimmingCharacters(in: .whitespaces).lowercased()
            return symMap[s] ?? s
        }.filter { !$0.isEmpty }
        return keys.count >= 2 ? keys : nil
    }

    /// "粘贴 xxx" / "paste xxx"
    private static func extractTextToPaste(from raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        for prefix in ["粘贴", "paste"] {
            if t.lowercased().hasPrefix(prefix.lowercased()) {
                let value = String(t.dropFirst(prefix.count))
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "：:，,")))
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    private func extractTextToType(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        let prefixes = [
            "输入文字", "输入文本", "输入一下", "帮我输入", "给我输入", "输入",
            "打字", "键入", "type text", "type"
        ]
        for prefix in prefixes {
            if trimmed.lowercased().hasPrefix(prefix.lowercased()) {
                let value = String(trimmed.dropFirst(prefix.count))
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "：:，,")))
                return value.isEmpty ? nil : value
            }
        }

        // “在电脑上输入 xxx”
        let markers = ["在电脑上输入", "电脑输入", "往电脑输入"]
        for marker in markers {
            if let range = trimmed.range(of: marker) {
                let value = String(trimmed[range.upperBound...])
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "：:，,")))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    private func shouldUseComputerGateway(text: String, plusItemsCount: Int, hasPendingAudio: Bool, isVoiceMode: Bool) -> Bool {
        // 只保留新 local-agent 基础动作链路。
        // 带附件/语音消息的普通聊天不走电脑控制，避免误触发。
        if plusItemsCount > 0 || hasPendingAudio { return false }
        return buildComputerActionPayload(from: text) != nil
    }

    @MainActor
    private func runComputerGatewayFlow(goal: String, assistantId: UUID) async {
        do {
            let resp = try await submitComputerTask(goal: goal, source: "text_chat")
            if resp.route == "chat" {
                // 后端判定为聊天：提示重新发送即可走聊天流
                // 注：完美的 fall-through 需要把 onSendOrStop 的聊天分支抽成独立方法。
                updateMessage(id: assistantId) {
                    $0.text = "（未识别为电脑动作，请重新发送即可走聊天。）"
                    $0.isTypingCursor = false
                }
            } else {
                updateMessage(id: assistantId) {
                    var rendered = resp.finalText ?? "电脑动作已执行。"
                    if !resp.stepsText.isEmpty { rendered += "\n\n" + resp.stepsText }
                    $0.text = rendered
                    $0.isTypingCursor = false
                    if let image = resp.screenshotImage {
                        $0.attachments = [ChatMessageAttachment(kind: .image(image), filename: "computer-loop-screenshot.png")]
                    }
                }
            }
        } catch {
            updateMessage(id: assistantId) {
                $0.text = friendlyNetworkMessage(error)
                $0.isTypingCursor = false
            }
        }
        scheduleScrollNow(to: .bottom, anchor: .bottom)
    }

    // MARK: - V1.5 工程修复入口（最小安全版：两段式确认）
    //   触发词只走 /api/brain/adu/act + engineering_root 硬编码在 /tmp 沙箱。
    //   第一轮 allow_execute=false → 显示计划 + 等待"确认执行"。
    //   第二轮 allow_execute=true → 真启动 + 客户端轮询任务进度。

    /// /tmp 沙箱：iOS 端目前只允许工程修复跑在这一个目录里。
    /// 真要扩大范围必须由后端 _start_engineering_run 同步允许，且 server 端独立校验 /tmp/ 前缀。
    private static let aduEngineeringDefaultRoot = "/tmp/chatagi_agent_loop_real_test"

    /// 工程修复触发词（与后端 _ADU_ENG_TRIGGERS 对齐）。
    private static let aduEngineeringTriggers: [String] = [
        "修复工程", "修工程", "修一下工程", "修一下项目", "修复项目",
        "修复 bug", "修 bug", "修一下 bug", "修复bug", "修bug", "修一下bug",
        "修一下编译", "检查编译", "编译错误", "compile error", "build fail", "构建失败",
        "跑测试", "运行测试", "跑一下测试", "跑 test", "跑test",
        "自动改代码", "自动修代码", "自动修复",
        "工程修复",
    ]

    /// 用户明确确认词（仅在 pendingEngineeringGoal != nil 时才生效）。
    private static let aduEngineeringConfirmTriggers: [String] = [
        "确认执行", "开始修复", "允许执行", "执行修复", "go modify", "go fix",
    ]

    private func looksLikeEngineeringRequest(_ text: String) -> Bool {
        let t = text.lowercased()
        for kw in Self.aduEngineeringTriggers {
            if t.contains(kw.lowercased()) { return true }
        }
        return false
    }

    private func isEngineeringConfirmation(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for kw in Self.aduEngineeringConfirmTriggers {
            if t.contains(kw.lowercased()) { return true }
        }
        return false
    }

    /// 主入口：触发或确认工程修复任务。
    /// - Parameter allowExecute: false=只拿计划；true=真启动 + 轮询任务进度
    @MainActor
    private func runEngineeringLoop(goal: String, allowExecute: Bool, assistantId: UUID) async {
        guard let url = URL(string: "\(apiBase)/api/brain/adu/act") else {
            updateMessage(id: assistantId) {
                $0.text = "URL 无效"
                $0.isTypingCursor = false
            }
            pendingEngineeringGoal = nil
            return
        }
        var req = AccountManager.makeAuthorizedRequest(url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(clientId, forHTTPHeaderField: "X-Client-ID")

        let body: [String: Any] = [
            "source": "text_chat",
            "text": goal,
            "client_id": clientId,
            "conversation_id": currentConversationId ?? "",
            "allow_execute": allowExecute,
            "engineering_root": Self.aduEngineeringDefaultRoot,
        ]
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            updateMessage(id: assistantId) {
                $0.text = "请求构造失败：\(error.localizedDescription)"
                $0.isTypingCursor = false
            }
            pendingEngineeringGoal = nil
            return
        }

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(code) else {
                let bodyText = String(data: data, encoding: .utf8) ?? ""
                updateMessage(id: assistantId) {
                    $0.text = "HTTP \(code)\n\(bodyText.prefix(400))"
                    $0.isTypingCursor = false
                }
                pendingEngineeringGoal = nil
                return
            }

            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let route = (obj["route"] as? String) ?? ""
            let taskId = (obj["task_id"] as? String) ?? ""
            let needConfirm = (obj["need_confirm"] as? Bool) ?? false
            let riskLevel = (obj["risk_level"] as? Int) ?? 0
            let finalText = ((obj["final_text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            guard route == "engineering" else {
                updateMessage(id: assistantId) {
                    $0.text = "后端未识别为工程任务（route=\(route)）。原文：\(finalText.isEmpty ? "(空)" : finalText)"
                    $0.isTypingCursor = false
                }
                pendingEngineeringGoal = nil
                return
            }

            if !allowExecute || needConfirm {
                // 计划态：显示计划 + 等待用户确认
                pendingEngineeringGoal = goal
                let riskLabel: String = {
                    switch riskLevel {
                    case 0: return "0（只读）"
                    case 1: return "1（有副作用但常用）"
                    default: return "\(riskLevel)（高风险）"
                    }
                }()
                let plan = """
                🛠 已识别为工程修复任务（V1.5 沙箱）
                目标：\(goal)
                工作目录：\(Self.aduEngineeringDefaultRoot)
                风险等级：\(riskLabel)

                \(finalText.isEmpty ? "（后端无 final_text）" : finalText)

                👉 回复"确认执行"开始修复，回复别的内容则取消。
                """
                updateMessage(id: assistantId) {
                    $0.text = plan
                    $0.isTypingCursor = false
                }
                return
            }

            // 二轮：真启动
            pendingEngineeringGoal = nil
            if taskId.isEmpty {
                updateMessage(id: assistantId) {
                    $0.text = "已启动但未拿到 task_id：\(finalText)"
                    $0.isTypingCursor = false
                }
                return
            }
            updateMessage(id: assistantId) {
                $0.text = "🛠 修复中…（task=\(taskId.prefix(8))，状态：queued）"
                $0.isTypingCursor = true
            }
            await pollEngineeringTask(taskId: taskId, assistantId: assistantId)

        } catch {
            updateMessage(id: assistantId) {
                $0.text = friendlyNetworkMessage(error)
                $0.isTypingCursor = false
            }
            pendingEngineeringGoal = nil
        }
    }

    /// 轮询 /agent/result/{task_id} 直到 done/failed/error 或 90s 超时。
    @MainActor
    private func pollEngineeringTask(taskId: String, assistantId: UUID) async {
        guard let url = URL(string: "\(apiBase)/agent/result/\(taskId)") else { return }

        for _ in 0..<45 {  // 45 * 2s = 90s
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            var req = AccountManager.makeAuthorizedRequest(url)
            req.timeoutInterval = 10
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                continue
            }
            let state = (obj["state"] as? [String: Any]) ?? [:]
            let status = (state["status"] as? String) ?? ""
            let report = (state["report"] as? String) ?? ""
            let lastError = (state["last_error"] as? String) ?? ""
            let changedFiles = (state["changed_files"] as? [String]) ?? []

            if status == "done" {
                let head = report.split(separator: "\n").first.map(String.init) ?? ""
                let summary = """
                ✅ 工程修复完成
                changed_files: \(changedFiles.joined(separator: ", "))
                \(head.isEmpty ? "" : "首行：" + head)

                \(report.prefix(500))
                """
                updateMessage(id: assistantId) {
                    $0.text = summary
                    $0.isTypingCursor = false
                }
                return
            }
            if status == "failed" || status == "error" {
                updateMessage(id: assistantId) {
                    $0.text = "❌ 工程修复失败（status=\(status)）\nlast_error: \(lastError.prefix(400))"
                    $0.isTypingCursor = false
                }
                return
            }
            updateMessage(id: assistantId) {
                $0.text = "🛠 修复中…（status=\(status)，task=\(taskId.prefix(8))）"
                $0.isTypingCursor = true
            }
        }

        updateMessage(id: assistantId) {
            $0.text = "⏱ 客户端轮询 90s 超时，任务可能仍在跑。task_id=\(taskId)"
            $0.isTypingCursor = false
        }
    }

    /// ✅ 统一入口：电脑任务直接走连续自主执行 loop。
    /// 手机一句话 -> /api/brain/computer/agent/loop -> observe/act/observe -> steps trace。
    private func submitComputerTask(
        goal: String,
        source: String = "text_chat",
        allowExecute: Bool = true
    ) async throws -> ComputerTaskGatewayResponse {
        guard let url = URL(string: "\(apiBase)/api/brain/computer/agent/loop") else {
            throw NSError(domain: "ComputerAgentLoop", code: -1, userInfo: [NSLocalizedDescriptionKey: "URL 无效"])
        }

        var req = AccountManager.makeAuthorizedRequest(url)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(clientId, forHTTPHeaderField: "X-Client-ID")

        let body: [String: Any] = [
            "task": goal,
            "max_steps": 8,
            "dry_run": !allowExecute,
            "require_confirm": false,
            "source": source,
            "client_id": clientId,
            "conversation_id": currentConversationId ?? ""
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "ComputerAgentLoop", code: code, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code) \(bodyText)"])
        }

        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let okFlag = (obj["ok"] as? Bool) ?? false
        let status = (obj["status"] as? String) ?? (okFlag ? "done" : "failed")
        let finalMessage = ((obj["final_message"] as? String) ?? (obj["message"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let errorText = ((obj["error"] as? String) ?? (obj["risk_reason"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let stepsText = Self.renderComputerLoopSteps(obj["steps"] as? [[String: Any]])
        let screenshotImage = Self.decodeComputerLoopScreenshot(from: obj)

        if !okFlag && status != "max_steps" {
            let err = !errorText.isEmpty ? errorText : (!finalMessage.isEmpty ? finalMessage : "电脑 loop 执行失败")
            return ComputerTaskGatewayResponse(
                ok: false,
                taskId: "loop_" + UUID().uuidString.lowercased(),
                status: status,
                needConfirm: false,
                confirmText: "",
                errorText: err,
                finalText: err,
                stepsText: stepsText,
                screenshotImage: screenshotImage,
                route: "computer"
            )
        }

        return ComputerTaskGatewayResponse(
            ok: okFlag,
            taskId: "loop_" + UUID().uuidString.lowercased(),
            status: status,
            needConfirm: false,
            confirmText: "",
            errorText: errorText,
            finalText: finalMessage.isEmpty ? "电脑 loop 已完成。" : finalMessage,
            stepsText: stepsText,
            screenshotImage: screenshotImage,
            route: "computer"
        )
    }


    private static func renderComputerLoopSteps(_ steps: [[String: Any]]?) -> String {
        guard let steps, !steps.isEmpty else { return "" }
        var lines: [String] = ["Steps:"]
        for step in steps.prefix(12) {
            let index = step["index"] ?? "?"
            let action = (step["action"] as? String) ?? (step["kind"] as? String) ?? "step"
            let ok = ((step["ok"] as? Bool) ?? false) ? "OK" : "FAIL"
            let message = ((step["message"] as? String) ?? (step["error"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("\(index). [\(ok)] \(action)\(message.isEmpty ? "" : " - " + message)")
        }
        return lines.joined(separator: "\n")
    }

    private static func decodeComputerLoopScreenshot(from obj: [String: Any]) -> UIImage? {
        if let shots = obj["screenshots"] as? [[String: Any]] {
            for shot in shots {
                if let b64 = shot["image_b64"] as? String, let image = decodeBase64Image(b64) { return image }
            }
        }
        if let steps = obj["steps"] as? [[String: Any]] {
            for step in steps {
                if let b64 = step["image_b64"] as? String, let image = decodeBase64Image(b64) { return image }
                if let shot = step["screenshot"] as? [String: Any], let b64 = shot["image_b64"] as? String, let image = decodeBase64Image(b64) { return image }
            }
        }
        return nil
    }

    private static func decodeBase64Image(_ raw: String) -> UIImage? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comma = s.firstIndex(of: ","), s[..<comma].contains("base64") {
            s = String(s[s.index(after: comma)...])
        }
        guard let data = Data(base64Encoded: s) else { return nil }
        return UIImage(data: data)
    }

    // MARK: - DevBrain V1 (自动化编程闭环)

    private struct DevTaskResult {
        let ok: Bool
        let status: String
        let rendered: String
        let screenshotImage: UIImage?
    }

    /// 手机一句话 -> /api/brain/dev/run -> observe→plan→act(codex/claude/local-agent)→verify→repair。
    private func submitDevTask(goal: String) async throws -> DevTaskResult {
        guard let url = URL(string: "\(apiBase)/api/brain/dev/run") else {
            throw NSError(domain: "DevBrain", code: -1, userInfo: [NSLocalizedDescriptionKey: "URL 无效"])
        }
        var req = AccountManager.makeAuthorizedRequest(url)
        req.httpMethod = "POST"
        req.timeoutInterval = 600   // 自动化编程可能跑较久(codex/claude)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(clientId, forHTTPHeaderField: "X-Client-ID")

        let body: [String: Any] = [
            "goal": goal,
            "mode": "auto",
            "max_steps": 16,
            "allow_write": true,
            "allow_tools": true,
            "executor_preference": "codex_first",
            "return_trace": true,
            "source": "ios_home_chat",
            "client_id": clientId,
            "conversation_id": currentConversationId ?? ""
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "DevBrain", code: code, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code) \(bodyText)"])
        }

        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let ok = (obj["ok"] as? Bool) ?? false
        let status = (obj["status"] as? String) ?? (ok ? "done" : "failed")
        let finalMessage = ((obj["final_message"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let errorText = ((obj["error"] as? String) ?? (obj["blocked_reason"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let image = Self.decodeComputerLoopScreenshot(from: obj) ?? Self.decodeDevVerificationShot(from: obj)

        var lines: [String] = []
        let statusIcon = ["done": "✅", "running": "⏳", "need_confirm": "⚠️", "failed": "❌", "max_steps": "🛑"][status] ?? "•"
        lines.append("\(statusIcon) DevBrain status: \(status)")
        if !finalMessage.isEmpty { lines.append(finalMessage) }

        if let steps = obj["steps"] as? [[String: Any]], !steps.isEmpty {
            lines.append("\nSteps:")
            for s in steps.prefix(20) {
                let i = s["i"] ?? "?"
                let phase = (s["phase"] as? String) ?? "?"
                let tool = (s["tool"] as? String) ?? "?"
                let action = (s["action"] as? String) ?? ""
                let sok = ((s["ok"] as? Bool) ?? true) ? "OK" : "FAIL"
                lines.append("  \(i). [\(sok)] \(phase)/\(tool) \(action)")
            }
        }
        if let files = obj["files_touched"] as? [String], !files.isEmpty {
            lines.append("\nFiles touched: " + files.joined(separator: ", "))
        }
        if let v = obj["verifications"] as? [String: Any] {
            var vbits: [String] = []
            if let pc = v["py_compile"] as? [String: Any] { vbits.append("py_compile=\((pc["ok"] as? Bool) ?? false)") }
            if let ch = v["core_health"] as? [String: Any] { vbits.append("core_health=\((ch["ok"] as? Bool) ?? false)") }
            if let lh = v["local_agent_health"] as? [String: Any] { vbits.append("local_agent=\((lh["ok"] as? Bool) ?? false)") }
            if let sh = v["screenshot"] as? [String: Any] { vbits.append("screenshot=\((sh["ok"] as? Bool) ?? false)") }
            if !vbits.isEmpty { lines.append("\nVerifications: " + vbits.joined(separator: " · ")) }
        }
        if !errorText.isEmpty { lines.append("\n⚠️ error: \(errorText)") }

        return DevTaskResult(ok: ok, status: status,
                             rendered: lines.joined(separator: "\n"),
                             screenshotImage: image)
    }

    /// 从 DevBrain 顶层 screenshot_b64(未裁剪)或 verifications.screenshot.image_b64 解码截图。
    private static func decodeDevVerificationShot(from obj: [String: Any]) -> UIImage? {
        if let b64 = obj["screenshot_b64"] as? String, let img = decodeBase64Image(b64) {
            return img
        }
        if let v = obj["verifications"] as? [String: Any],
           let shot = v["screenshot"] as? [String: Any],
           let b64 = shot["image_b64"] as? String {
            return decodeBase64Image(b64)
        }
        return nil
    }

    private func submitComputerDirectAction(goal: String) async throws -> ComputerTaskGatewayResponse? {
        guard let parsed = buildComputerActionPayload(from: goal) else { return nil }
        guard let url = URL(string: "\(apiBase)/api/brain/computer/action") else { return nil }

        var req = AccountManager.makeAuthorizedRequest(url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(clientId, forHTTPHeaderField: "X-Client-ID")

        let body: [String: Any] = [
            "action": parsed.action,
            "payload": parsed.payload,
            "goal": goal,
            "text": goal,
            "client_id": clientId,
            "conversation_id": currentConversationId ?? ""
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "ComputerActionGateway", code: code, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code) \(bodyText)"])
        }

        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let ok = (obj["ok"] as? Bool) ?? false
        if !ok {
            let err = (obj["error"] as? String) ?? (obj["detail"] as? String) ?? "电脑动作执行失败"
            throw NSError(domain: "ComputerActionGateway", code: 500, userInfo: [NSLocalizedDescriptionKey: err])
        }

        let message = (obj["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let action = (obj["action"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? parsed.action
        var final = message?.isEmpty == false ? message! : parsed.message

        if let result = obj["result"] as? [String: Any] {
            if let x = result["x"], let y = result["y"], action == "mouse_position" {
                final = "鼠标位置：x=\(x), y=\(y)"
            } else if let stdout = result["stdout"] as? String, !stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                final += "\n\n" + stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return ComputerTaskGatewayResponse(
            ok: true,
            taskId: "direct_" + UUID().uuidString.lowercased(),
            status: "done",
            needConfirm: false,
            confirmText: "",
            errorText: "",
            finalText: final,
            stepsText: "",
            screenshotImage: nil,
            route: "computer"
        )
    }

    private func parseComputerTaskGatewayResponse(data: Data) -> ComputerTaskGatewayResponse {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let ok = (obj["ok"] as? Bool) ?? false
        let taskId = (obj["task_id"] as? String) ?? (obj["taskId"] as? String) ?? ""
        let status = (obj["status"] as? String) ?? ""
        let needConfirm = (obj["need_confirm"] as? Bool) ?? false
        let confirmText = (obj["confirm_text"] as? String) ?? ""
        let errorText = (obj["error"] as? String) ?? (obj["hint"] as? String) ?? ""

        var finalText: String? = nil
        if let result = obj["result"] as? [String: Any] {
            let summary = (result["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let details = (result["details"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !summary.isEmpty && !details.isEmpty {
                finalText = summary + "\n\n" + details
            } else if !summary.isEmpty {
                finalText = summary
            } else if !details.isEmpty {
                finalText = details
            } else if let message = result["message"] as? String, !message.isEmpty {
                finalText = message
            }
        }
        if finalText == nil, let message = obj["message"] as? String, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            finalText = message.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if finalText == nil, !errorText.isEmpty, status == "error" {
            finalText = "电脑任务执行失败：\(errorText)"
        }

        let route = ((obj["route"] as? String) ?? "computer").lowercased()
        return ComputerTaskGatewayResponse(
            ok: ok,
            taskId: taskId,
            status: status,
            needConfirm: needConfirm,
            confirmText: confirmText,
            errorText: errorText,
            finalText: finalText,
            stepsText: "",
            screenshotImage: nil,
            route: route
        )
    }
    @MainActor
    private func cancelAll() {
        sendTask?.cancel(); sendTask = nil
        revealTask?.cancel(); revealTask = nil
        clearPendingCodexTask()
        codexPlannerRunning = false
        if let rid = revealTaskMessageId {
            forceRevealFull(for: rid)
        }
        revealTaskMessageId = nil
        revealFullText.removeAll()

        // ✅ 取消播报预取任务（避免后台任务引用已释放对象）
        for (_, t) in ttsPrefetchTask { t.cancel() }
        ttsPrefetchTask.removeAll()
        ttsPreparing.removeAll()

        isSending = false

        // ✅ 点击“停止”时，也停止助手播报（避免继续播放）
        speechPlayer.stop()
        liveTTSPlayer.stop()

        if audioNote.isRecording {
            audioNote.cancel()
        } else {
            audioNote.restoreStagedToPending()
        }

        // ✅ 取消发送：清空 (+) 附件缓存
        plus.clear()

        if let last = messages.last, last.role == .assistant {
            updateMessage(id: last.id) { $0.isTypingCursor = false }
        }
        scheduleScrollNow(to: .bottom, anchor: .bottom)
    }


// MARK: - TTS Prefetch (音频准备好后才显示播放按钮)

@MainActor
private func startPrefetchTTS(messageId: UUID, text: String, remoteURL: URL? = nil, autoPlayWhenReady: Bool = false) {
    // 通话优先级最高：通话中不做本地播报准备
    if callActive { return }

    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    if ttsPreparedURL[messageId] != nil { return }
    if ttsPreparing.contains(messageId) { return }

    // 取消旧任务（同 id）
    if let old = ttsPrefetchTask[messageId] {
        old.cancel()
    }

    ttsPreparing.insert(messageId)

    let api = apiBase
    let voice = "alloy"

    let task = Task {
        do {
            // ✅ 直接“下载到本地再播” —— 确保按钮出现时音频已就绪
            let local = try await GPTTtsService.fetchDownloadedAudioURL(
                apiBase: api,
                text: trimmed,
                messageId: messageId,
                voice: voice
            )
            if Task.isCancelled { return }
            await MainActor.run {
                self.ttsPreparedURL[messageId] = local
                self.ttsPreparing.remove(messageId)
                self.ttsPrefetchTask[messageId] = nil
            }
        } catch {
            if Task.isCancelled { return }
            await MainActor.run {
                self.ttsPreparing.remove(messageId)
                self.ttsPrefetchTask[messageId] = nil
            }
        }
    }

    ttsPrefetchTask[messageId] = task
}


@MainActor
    private func updateMessage(id: UUID, mutate: (inout ChatMessage) -> Void) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        var m = messages[idx]
        mutate(&m)
        messages[idx] = m
    }

    /// ✅ 路由档位胶囊是否应该显示
    /// - 还在打字 → 一直显示
    /// - 完成后 1.2 秒内 → 显示
    /// - 完成超过 1.2 秒 → 隐藏
    private func shouldShowRouteTier(msg: ChatMessage) -> Bool {
        // 引用 routeTierHideTick 让 SwiftUI 在 tick 翻转时重算
        _ = routeTierHideTick
        if msg.isTypingCursor { return true }
        guard let finishedAt = msg.routeTierFinishedAt else { return true }
        let elapsed = Date().timeIntervalSince(finishedAt)
        return elapsed < 1.2
    }

    /// ✅ 完成 1.3 秒后翻转 tick,触发胶囊视图重算并淡出
    private func scheduleRouteTierHide() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            withAnimation(.easeOut(duration: 0.25)) {
                routeTierHideTick &+= 1
            }
        }
    }

    // MARK: - 播报开始才吞字（与语音播放同步）

    /// 一次性“播放开始门闩”：等待语音真正进入 `.playing` 才放行。

    /// 用户中止播报时：立即把全文补齐（避免只显示前半段）。
    @MainActor
    private func forceRevealFull(for id: UUID) {
        guard let full = revealFullText[id] else { return }

        updateMessage(id: id) { m in
            m.text = full
            m.isTypingCursor = false
        }

        revealFullText.removeValue(forKey: id)

        if revealTaskMessageId == id {
            revealTask?.cancel()
            revealTask = nil
            revealTaskMessageId = nil
        }

        scheduleScrollNow(to: .bottom, anchor: .bottom)
    }

    /// 当播报开始后：按语音进度推进显示文本（更像 ChatGPT：字随声走）。
    @MainActor
    private func revealDuringSpeech(_ fullText: String, assistantId: UUID) async {
        let chars = Array(fullText)
        let total = chars.count
        guard total > 0 else {
            updateMessage(id: assistantId) { $0.isTypingCursor = false }
            revealFullText.removeValue(forKey: assistantId)
            return
        }

        var lastCount = 0
        let tick: UInt64 = 80_000_000 // ~12.5 fps，稳定不抖

        while !Task.isCancelled {
            // 只同步“当前正在播的那条”
            guard speechPlayer.activeId == assistantId else { break }

            let d = speechPlayer.duration
            let t = speechPlayer.currentTime

            let count: Int
            if d > 0.2, t >= 0, d.isFinite, t.isFinite {
                let ratio = max(0, min(1, t / d))
                count = Int(Double(total) * ratio)
            } else {
                // duration 未知：按固定步长推进
                count = min(total, lastCount + 6)
            }

            if count != lastCount {
                lastCount = count
                let visible = String(chars.prefix(count))

                updateMessage(id: assistantId) { m in
                    m.text = visible
                    m.isTypingCursor = (count < total)
                }

                if count % 24 == 0 { scheduleScroll() }
            }

            if lastCount >= total { break }
            try? await Task.sleep(nanoseconds: tick)
        }

        // 播放结束/被中止：保证全文可见
        forceRevealFull(for: assistantId)
    }


    // MARK: - Scroll scheduling

    @MainActor
    private func scheduleScrollNow(to target: ScrollTarget, anchor: UnitPoint) {
        scrollTask?.cancel()
        scrollTarget = target
        scrollAnchor = anchor
        scrollTick &+= 1
    }

    @MainActor
    private func scheduleScrollNow(to target: UUID, anchor: UnitPoint) {
        scheduleScrollNow(to: .msg(target), anchor: anchor)
    }

    
@MainActor
private func scheduleScroll(to target: UUID, anchor: UnitPoint) {
    guard isAtBottom else { return }
    let now = Date().timeIntervalSinceReferenceDate
    if now - lastAutoScrollAt < autoScrollMinInterval { return }
    lastAutoScrollAt = now

    scrollTarget = .msg(target)
    scrollAnchor = anchor
    scrollTick &+= 1
}
@MainActor
private func scheduleScroll() {
    guard isAtBottom else { return }
    let now = Date().timeIntervalSinceReferenceDate
    if now - lastAutoScrollAt < autoScrollMinInterval { return }
    lastAutoScrollAt = now
    scrollTarget = .bottom
    scrollAnchor = .bottom
    scrollTick &+= 1
}

// MARK: - Thinking / Typing indicators (no dots)
// MARK: - Thinking / Typing indicators (no dots)
// ✅ 删除“三点式”动态：改为“正在思考”字体 + 阴影呼吸动效（更明显、更稳定）
// ✅ 推理过程展开框（推理完成后自动折叠）

// ✅ 路由档位提示胶囊（聊天回复开始时显示在气泡上方）
private struct RouteTierCapsule: View {
    let tier: RouteTier
    let isLive: Bool   // true: 还在出回答；false: 已完成,1.2s 后会淡出

    @State private var pulse: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tier.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(tier.tint)
                .symbolEffect(.pulse, isActive: isLive)

            Text(tier.label)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(tier.tint)

            if isLive {
                Circle()
                    .fill(tier.tint.opacity(pulse ? 0.95 : 0.35))
                    .frame(width: 4, height: 4)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulse)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4.5)
        .background(
            Capsule()
                .fill(tier.tint.opacity(0.10))
        )
        .overlay(
            Capsule()
                .strokeBorder(tier.tint.opacity(0.25), lineWidth: 0.6)
        )
        .onAppear { pulse = true }
        .transition(.asymmetric(
            insertion: .scale(scale: 0.85).combined(with: .opacity),
            removal: .opacity
        ))
    }
}

private struct ReasoningBubble: View {
    let text: String
    let isDone: Bool
    @State private var expanded: Bool = true
    @State private var dotPhase: CGFloat = 0

    private let bgColor   = Color(red: 0.97, green: 0.95, blue: 1.0)
    private let border    = Color(red: 0.75, green: 0.60, blue: 0.95)
    private let accent    = Color(red: 0.55, green: 0.35, blue: 0.85)
    private let textColor = Color(red: 0.35, green: 0.20, blue: 0.55)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isDone ? "brain.filled.head.profile" : "brain.head.profile")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(accent)
                        .symbolEffect(.pulse, isActive: !isDone)

                    Text(isDone ? "推理完成" : "深度推理中")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(accent)

                    if !isDone {
                        HStack(spacing: 3) {
                            ForEach(0..<3, id: \.self) { i in
                                Circle()
                                    .fill(accent.opacity(
                                        dotPhase >= CGFloat(i) && dotPhase < CGFloat(i + 1) ? 1.0 : 0.28
                                    ))
                                    .frame(width: 4, height: 4)
                            }
                        }
                        .onAppear {
                            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                                dotPhase = 3
                            }
                        }
                    }

                    Spacer()

                    if !isDone {
                        Text("\(text.count) 字")
                            .font(.system(size: 11))
                            .foregroundColor(accent.opacity(0.5))
                    }

                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(accent.opacity(0.6))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }
            .buttonStyle(.plain)

            if expanded {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        Text(text)
                            .font(.system(size: 12.5, weight: .regular, design: .monospaced))
                            .foregroundColor(textColor.opacity(0.80))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 12)
                            .id("rb_bottom")
                    }
                    .frame(maxHeight: isDone ? 130 : 220)
                    .onChange(of: text) { _, _ in
                        guard !isDone else { return }
                        withAnimation { proxy.scrollTo("rb_bottom", anchor: .bottom) }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(bgColor)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(border.opacity(0.45), lineWidth: 1)
        )
        .onChange(of: isDone) { _, done in
            guard done else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    expanded = false
                }
            }
        }
    }
}

private struct ShimmerThinkingText: View {
    let text: String
    @State private var phase: CGFloat = -1
    @State private var breathe: Bool = false

    var body: some View {
        ZStack(alignment: .leading) {

            // base (breathing)
            Text(text)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.black.opacity(breathe ? 0.30 : 0.55))
                .shadow(color: Color.black.opacity(breathe ? 0.10 : 0.02), radius: breathe ? 10 : 2, x: 0, y: 0)

            // shimmer overlay (sweeping light)
            Text(text)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.black.opacity(0.90))
                .mask(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color.black.opacity(0.10),
                            Color.black.opacity(0.95),
                            Color.black.opacity(0.10)
                        ]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .rotationEffect(.degrees(12))
                    .offset(x: phase * 240)
                )
        }
        .onAppear {
            // sweep
            phase = -1
            withAnimation(.linear(duration: 1.05).repeatForever(autoreverses: false)) {
                phase = 1
            }

            // breathe
            breathe = false
            withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
    }
}

// ✅ 打字光标：固定宽度胶囊，不拼接字符，避免换行抖动
private struct TypingCursorPill: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.35)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let on = (Int((t * 2).rounded(.down)) % 2) == 0
            Capsule(style: .continuous)
                .fill(Color.black.opacity(on ? 0.55 : 0.10))
                .frame(width: 6, height: 16)
                .offset(y: 2)
        }
    }
}


// ✅ Markdown/代码高亮：ChatGPT 风格排版（标题/列表/间距）
// - 支持：# / ## / ### 标题、-/*/+ 无序列表、1. 有序列表、--- 分割线、``` 代码块
// - 目标：不直接显示 Markdown 符号（#、*、- 等），字体大小有层级，行间距更舒适
private struct AssistantMarkdownView: View {
    let text: String
    @State private var blocks: [MarkdownBlock] = []
    @State private var lastParsedText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {

                case .paragraph(let t):
                    Text(inlineAttributed(t))
                        .font(.system(size: 17))
                        .foregroundColor(.black)
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)

                case .heading(let level, let t):
                    let (size, weight): (CGFloat, Font.Weight) = {
                        switch level {
                        case 1: return (24, .bold)
                        case 2: return (20, .semibold)
                        case 3: return (18, .semibold)
                        default: return (17, .semibold)
                        }
                    }()

                    Text(inlineAttributed(t))
                        .font(.system(size: size, weight: weight))
                        .foregroundColor(.black)
                        .lineSpacing(6)
                        .padding(.top, level <= 2 ? 8 : 6)
                        .padding(.bottom, 2)
                        .fixedSize(horizontal: false, vertical: true)

                case .list(let items, let ordered):
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(items.enumerated()), id: \.offset) { idx, it in
                            HStack(alignment: .top, spacing: 10) {
                                Text(ordered ? it.marker : "•")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundColor(.black.opacity(0.85))
                                    .frame(minWidth: 22, alignment: .trailing)
                                    .padding(.top, 1)

                                Text(inlineAttributed(it.text))
                                    .font(.system(size: 17))
                                    .foregroundColor(.black)
                                    .lineSpacing(5)
                                    .fixedSize(horizontal: false, vertical: true)

                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(.leading, 2)

                case .quote(let t):
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.black.opacity(0.15))
                            .frame(width: 3)
                            .padding(.top, 2)

                        Text(inlineAttributed(t))
                            .font(.system(size: 17))
                            .foregroundColor(.black.opacity(0.85))
                            .lineSpacing(5)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.black.opacity(0.04))
                    )

                case .hr:
                    Divider()
                        .opacity(0.55)
                        .padding(.vertical, 6)

                case .code(let lang, let code):
                    CodeBlock(lang: lang, code: code)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            blocks = MarkdownBlocks.parse(text)
            lastParsedText = text
        }
        .onChange(of: text) { _, v in
            // ✅ 增量解析：流式 token 追加时只重解析，非全量刷新
            if v.hasPrefix(lastParsedText), !blocks.isEmpty, !v.isEmpty {
                blocks = MarkdownBlocks.parse(v)
            } else {
                blocks = MarkdownBlocks.parse(v)
            }
            lastParsedText = v
        }
    }

    /// Inline markdown: **bold**, *italic*, `code`, [link](url)
    /// 我们只用它来“去掉符号 + 应用粗体/链接等样式”，块级布局（标题/列表）由上面 switch 控制。
    private func inlineAttributed(_ s: String) -> AttributedString {
        // 一些模型会输出奇怪的全角空格/多余回车，这里做轻量清洗
        let cleaned = s
            .replacingOccurrences(of: "\u{00A0}", with: " ") // nbsp
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let a = try? AttributedString(markdown: cleaned) {
            return a
        }
        return AttributedString(cleaned)
    }
}

private struct MarkdownListItem {
    let marker: String   // ordered list marker: "1." / "2." ...
    let text: String     // markdown inline text
}

private enum MarkdownBlock {
    case paragraph(String)
    case heading(level: Int, text: String)
    case list(items: [MarkdownListItem], ordered: Bool)
    case quote(String)
    case hr
    case code(lang: String, code: String)
}

private struct MarkdownBlocks {

    /// 轻量块级解析：
    /// - 标题：# / ## / ###
    /// - 分割线：---
    /// - 列表：-/*/+ 或 1.
    /// - 引用：>
    /// - 代码块：```lang ... ```
    static func parse(_ s: String) -> [MarkdownBlock] {
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var out: [MarkdownBlock] = []
        var paraBuf: [String] = []

        func flushPara() {
            let t = paraBuf.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(.paragraph(t)) }
            paraBuf.removeAll()
        }

        func isHR(_ t: String) -> Bool {
            let x = t.trimmingCharacters(in: .whitespacesAndNewlines)
            return x == "---" || x == "***" || x == "___"
        }

        func parseHeading(_ t: String) -> (Int, String)? {
            let x = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard x.first == "#" else { return nil }

            var level = 0
            for ch in x {
                if ch == "#" { level += 1 } else { break }
            }
            guard (1...6).contains(level) else { return nil }

            let rest = x.dropFirst(level)
            guard rest.first == " " || rest.first == "\t" else { return nil }

            let title = rest.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "#")) // 去掉一些结尾的 ####
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if title.isEmpty { return nil }
            return (level, title)
        }

        func parseListItem(_ t: String) -> (ordered: Bool, marker: String, content: String)? {
            let x = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !x.isEmpty else { return nil }

            // unordered: - / * / +
            if x.hasPrefix("- ") || x.hasPrefix("* ") || x.hasPrefix("+ ") {
                let content = String(x.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if content.isEmpty { return nil }
                return (false, "", content)
            }

            // ordered: 1. / 1)
            var i = x.startIndex
            var digits = ""
            while i < x.endIndex, x[i].isNumber {
                digits.append(x[i])
                i = x.index(after: i)
            }
            if !digits.isEmpty, i < x.endIndex {
                let ch = x[i]
                if ch == "." || ch == ")" {
                    var j = x.index(after: i)
                    while j < x.endIndex, x[j].isWhitespace { j = x.index(after: j) }
                    if j < x.endIndex {
                        let content = String(x[j...]).trimmingCharacters(in: .whitespaces)
                        if !content.isEmpty {
                            return (true, digits + ".", content)
                        }
                    }
                }
            }

            return nil
        }

        func parseQuote(from start: Int) -> (block: MarkdownBlock?, next: Int) {
            var i = start
            var buf: [String] = []
            while i < lines.count {
                let raw = lines[i]
                let t = raw.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix(">") else { break }

                var q = t.dropFirst()
                if q.first == " " { q = q.dropFirst() }
                buf.append(String(q))
                i += 1
            }
            let qt = buf.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if qt.isEmpty { return (nil, i) }
            return (.quote(qt), i)
        }

        func parseList(from start: Int) -> (block: MarkdownBlock?, next: Int) {
            var i = start
            let first = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let firstItem = parseListItem(first) else { return (nil, start) }

            let ordered = firstItem.ordered
            var items: [MarkdownListItem] = [.init(marker: firstItem.marker, text: firstItem.content)]
            i += 1

            while i < lines.count {
                let raw = lines[i]
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

                if trimmed.isEmpty { break }
                if isHR(trimmed) { break }
                if parseHeading(trimmed) != nil { break }
                if trimmed.hasPrefix("```") { break }
                if trimmed.trimmingCharacters(in: .whitespaces).hasPrefix(">") { break }

                if let it = parseListItem(trimmed) {
                    // 不同类型的列表就结束（ordered vs unordered）
                    if it.ordered != ordered { break }
                    items.append(.init(marker: it.marker, text: it.content))
                    i += 1
                    continue
                }

                // continuation line（缩进续行）：并入上一条 item
                if raw.hasPrefix(" ") || raw.hasPrefix("\t") {
                    let cont = trimmed
                    if var last = items.popLast() {
                        last = .init(marker: last.marker, text: last.text + "\n" + cont)
                        items.append(last)
                    }
                    i += 1
                    continue
                }

                break
            }

            if items.isEmpty { return (nil, i) }
            return (.list(items: items, ordered: ordered), i)
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            // fenced code block
            if trimmed.hasPrefix("```") {
                flushPara()
                let lang = trimmed.replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                i += 1

                var codeLines: [String] = []
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                if i < lines.count && lines[i].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") { i += 1 }

                let finalLang = lang.isEmpty ? "plaintext" : lang
                out.append(.code(lang: finalLang, code: codeLines.joined(separator: "\n")))
                continue
            }

            // divider
            if isHR(trimmed) {
                flushPara()
                out.append(.hr)
                i += 1
                continue
            }

            // heading
            if let (lvl, title) = parseHeading(trimmed) {
                flushPara()
                out.append(.heading(level: lvl, text: title))
                i += 1
                continue
            }

            // quote
            if trimmed.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                flushPara()
                let r = parseQuote(from: i)
                if let b = r.block { out.append(b) }
                i = r.next
                continue
            }

            // list
            if parseListItem(trimmed) != nil {
                flushPara()
                let r = parseList(from: i)
                if let b = r.block { out.append(b) }
                i = r.next
                continue
            }

            // blank line => paragraph break
            if trimmed.isEmpty {
                flushPara()
                i += 1
                continue
            }

            // normal paragraph line
            paraBuf.append(line)
            i += 1
        }

        flushPara()
        return out
    }
}

    private struct CodeBlock: View {
        let lang: String
        let code: String
        @State private var h: CGFloat = 80
        @State private var copied: Bool = false
        @State private var downloading: Bool = false

        // 根据 lang 推断文件扩展名
        private var fileExt: String {
            switch lang.lowercased() {
            case "python", "py":       return "py"
            case "swift":              return "swift"
            case "javascript", "js":   return "js"
            case "typescript", "ts":   return "ts"
            case "kotlin", "kt":       return "kt"
            case "java":               return "java"
            case "c":                  return "c"
            case "cpp", "c++":         return "cpp"
            case "go":                 return "go"
            case "rust", "rs":         return "rs"
            case "shell", "bash", "sh":return "sh"
            case "json":               return "json"
            case "yaml", "yml":        return "yaml"
            case "html":               return "html"
            case "css":                return "css"
            case "sql":                return "sql"
            case "markdown", "md":     return "md"
            case "dart":               return "dart"
            case "ruby", "rb":         return "rb"
            case "php":                return "php"
            default:                   return lang.isEmpty ? "txt" : lang
            }
        }

        var body: some View {
            ZStack(alignment: .topTrailing) {
                NativeCodeHighlighterView(code: code, language: lang, dynamicHeight: $h)
                    .frame(height: h)
                    .frame(maxWidth: .infinity)

                // ── 右上角操作栏（复制 + 下载）─────────────────────
                HStack(spacing: 6) {

                    // 下载按钮（粉色书页风格）
                    Button {
                        guard !downloading else { return }
                        HomeHaptics.light()
                        downloading = true
                        let filename = "code.\(fileExt)"
                        let apiBase = AppConfig.API.apiBase
                        guard let url = URL(string: "\(apiBase)/file/generate") else {
                            downloading = false; return
                        }
                        var req = AccountManager.makeAuthorizedRequest(url)
                        req.httpMethod = "POST"
                        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        let body: [String: Any] = ["content": code, "filename": filename]
                        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
                        URLSession.shared.dataTask(with: req) { data, _, _ in
                            DispatchQueue.main.async {
                                downloading = false
                                guard let data = data,
                                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                      let dlPath = json["download_url"] as? String,
                                      let dlURL = URL(string: "\(apiBase)\(dlPath)") else { return }
                                UIApplication.shared.open(dlURL)
                            }
                        }.resume()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: downloading ? "arrow.down.circle" : "arrow.down.to.line")
                                .font(.system(size: 11, weight: .bold))
                            Text(downloading ? "生成中" : "下载")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(red:0.95, green:0.25, blue:0.55))
                        .clipShape(Capsule())
                        .shadow(color: Color(red:0.95,green:0.25,blue:0.55).opacity(0.35), radius: 4, x:0, y:2)
                    }
                    .buttonStyle(.plain)

                    // 复制按钮（原有逻辑不变）
                    Button {
                        HomeHaptics.light()
                        UIPasteboard.general.string = code
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { copied = false }
                    } label: {
                        Text(copied ? "已复制" : "复制")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.black.opacity(0.72))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.88))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Color.black.opacity(0.12), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
            }
        }
    }

    // MARK: - Utils

    private func resolveMediaURLString(_ s: String?) -> URL? {
        guard let s = s, !s.isEmpty else { return nil }
        if let u = URL(string: s), u.scheme != nil { return u }
        if s.hasPrefix("/") { return URL(string: apiBase + s) }
        return URL(string: apiBase + "/" + s)
    }

    // MARK: - ✅ Realtime turn commit (持久化语音对话到后端)

    private static func commitRealtimeTurn(
        apiBase: String, clientId: String, conversationId: String,
        userText: String, assistantText: String
    ) async -> String? {
        let base = apiBase.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty, let url = URL(string: "\(base)/realtime/turn/commit") else { return nil }
        var req = AccountManager.makeAuthorizedRequest(url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10
        let body: [String: Any] = [
            "client_id": clientId, "conversation_id": conversationId,
            "user_text": userText, "assistant_text": assistantText, "profile": "default",
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if code >= 200, code < 300,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let cid = json["conversation_id"] as? String, !cid.isEmpty {
                return cid
            }
        } catch { }
        return nil
    }
}

// MARK: - Attachment models

private struct PendingImage: Identifiable {
    let id = UUID()
    let data: Data
    let preview: UIImage
}

struct ChatAttachment: Codable {
    let type: String           // "image" | "audio"
    let id: String             // backend media id
    let mime: String?
    let url: String?
}

struct ChatMessageAttachment: Identifiable {
    enum Kind {
        case image(UIImage)
        case audio(url: URL, duration: TimeInterval)
        case file(url: URL, filename: String)
    }
    let id: UUID
    var kind: Kind
    var filename: String?

    init(id: UUID = UUID(), kind: Kind, filename: String? = nil) {
        self.id = id
        self.kind = kind
        self.filename = filename
    }
}

struct RobotBrainAction: Codable, Identifiable {
    var id = UUID()
    var cmd: String
    var duration_ms: Int?

    enum CodingKeys: String, CodingKey { case cmd, duration_ms }

    init(id: UUID = UUID(), cmd: String, duration_ms: Int? = nil) {
        self.id = id
        self.cmd = cmd
        self.duration_ms = duration_ms
    }

    var displayText: String {
        if let duration_ms { return "\(cmd) \(duration_ms)" }
        return cmd
    }
}

struct RobotBrainPlan: Codable {
    var say: String
    var actions: [RobotBrainAction]
    var need_confirm: Bool
    var executed: Bool?
    var plan_only: Bool?
    var message: String?
    var source: String?
    var skill_id: String? = nil
    var perceptionPayload: HexapodPerceptionTickRequest? = nil
}

// MARK: - UI small components

private struct ChatGPTBlackButton: View {
    enum Mode { case wave, send, stop }
    let mode: Mode
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .fill(Color.black)
                    .frame(width: 44, height: 44)

                switch mode {
                case .wave:
                    Image(systemName: "waveform")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                case .send:
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundColor(.white)
                case .stop:
                    Image(systemName: "stop.fill")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundColor(.white)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Models / Services / Haptics / Offline Highlighter

// ✅ 路由档位提示（聊天回复时的小胶囊框）
enum RouteTier: String {
    case fast       // 🚀 快速回答（首字 < 800ms）
    case thinking   // 💭 思考中（首字慢但无 reasoning）
    case deep       // 🧠 深度思考（thinking 模型 / reasoning 流）
    case web        // 🌐 联网搜索（路由判定为 web 或收到 sources）

    var label: String {
        switch self {
        case .fast:     return "快速回答"
        case .thinking: return "思考中"
        case .deep:     return "深度思考"
        case .web:      return "联网搜索"
        }
    }

    var icon: String {
        switch self {
        case .fast:     return "bolt.fill"
        case .thinking: return "bubble.left.and.bubble.right.fill"
        case .deep:     return "brain.head.profile"
        case .web:      return "globe"
        }
    }

    var tint: Color {
        switch self {
        case .fast:     return Color(red: 0.10, green: 0.65, blue: 0.55)  // 青绿
        case .thinking: return Color(red: 0.20, green: 0.45, blue: 0.85)  // 蓝
        case .deep:     return Color(red: 0.55, green: 0.35, blue: 0.85)  // 紫
        case .web:      return Color(red: 0.95, green: 0.55, blue: 0.20)  // 橙
        }
    }

    /// 优先级：高的不会被低的覆盖（deep > web > thinking > fast）
    var priority: Int {
        switch self {
        case .fast:     return 0
        case .thinking: return 1
        case .web:      return 2
        case .deep:     return 3
        }
    }

    /// ✅ 从后端 /chat/prepare 的 route_decision 推导初始档位（最准确）
    /// 后端字段说明：
    ///   - route: "vision" / "file_question" / "openai_web_search" / "normal_chat"
    ///   - model: 实际选用的模型名
    static func fromDecision(route: String?, model: String?) -> RouteTier {
        let r = (route ?? "").lowercased()
        let m = (model ?? "").lowercased()

        // 联网搜索（最高识别优先级）
        if r == "openai_web_search" || r.contains("web") { return .web }

        // 视觉 / 文件 → 多模态深度处理
        if r == "vision" || r == "file_question" { return .deep }

        // thinking 类模型（默认开启思考的）→ 深度
        if m.hasPrefix("qwen3.5-") || m.hasPrefix("qwen3.6-") { return .deep }
        if m.hasPrefix("o1") || m.hasPrefix("o3") { return .deep }
        if m.contains("gpt-5") || m.contains("opus") { return .deep }

        // 普通对话 → 先标 thinking,首字到达再升级 fast
        return .thinking
    }
}

struct ChatMessage: Identifiable {
    let id: UUID
    let role: Role
    var text: String
    var isTypingCursor: Bool
    var attachments: [ChatMessageAttachment]
    var sources: [WebSource]
    var reasoningText: String
    var reasoningDone: Bool
    var robotPlan: RobotBrainPlan?
    // ✅ 路由档位 + 完成时间（用于 1.2s 后淡出）
    var routeTier: RouteTier?
    var routeTierFinishedAt: Date?

    enum Role { case user, assistant, system }

    init(id: UUID = UUID(),
         role: Role,
         text: String,
         isTypingCursor: Bool = false,
         attachments: [ChatMessageAttachment] = [],
         sources: [WebSource] = [],
         reasoningText: String = "",
         reasoningDone: Bool = false,
         robotPlan: RobotBrainPlan? = nil,
         routeTier: RouteTier? = nil,
         routeTierFinishedAt: Date? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.isTypingCursor = isTypingCursor
        self.attachments = attachments
        self.sources = sources
        self.reasoningText = reasoningText
        self.reasoningDone = reasoningDone
        self.robotPlan = robotPlan
        self.routeTier = routeTier
        self.routeTierFinishedAt = routeTierFinishedAt
    }

    var renderText: String {
        Self.stripInlineSearchFooter(from: text)
    }

    /// 后端旧版本曾把“联网来源：URL 列表”拼进正文。
    /// 上架版对标 OpenAI：正文只讲解，来源由 sources 图标条单独渲染。
    private static func stripInlineSearchFooter(from raw: String) -> String {
        var out = raw
        let markers = ["\n\n---\n联网来源：", "\n联网来源：", "联网来源："]
        for marker in markers {
            if let range = out.range(of: marker) {
                out = String(out[..<range.lowerBound])
                break
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func buildContext(from uiMessages: [ChatMessage], maxPairs: Int) -> [LLMMessage] {
        let compact = uiMessages.compactMap { m -> ChatMessage? in
            if m.role == .assistant && (m.text.isEmpty || m.isTypingCursor) { return nil }
            return m
        }
        let tail = compact.suffix(maxPairs * 2)
        return tail.map { m in
            switch m.role {
            case .user: return .init(role: "user", content: m.text)
            case .assistant: return .init(role: "assistant", content: m.text)
            case .system: return .init(role: "system", content: m.text)
            }
        }
    }
}

struct LLMMessage: Codable {
    let role: String
    let content: String
}

// MARK: - Web Search models (联网搜索 -> 站点图标)

struct WebSource: Identifiable, Codable, Hashable {
    let title: String
    let url: String

    // ✅ 用 url 做稳定 id（服务端无需额外字段）
    var id: String { url }

    var host: String {
        URL(string: url)?.host ?? ""
    }

    var normalizedHost: String {
        host.lowercased().replacingOccurrences(of: "www.", with: "")
    }

    var displayName: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            // OpenAI-style: keep the source chip short and scannable.
            return String(trimmed.prefix(18))
        }
        return normalizedHost.isEmpty ? "来源" : normalizedHost
    }

    /// 站点图标（DuckDuckGo favicon service）
    var faviconURL: URL? {
        let h = host
        guard !h.isEmpty else { return nil }
        return URL(string: "https://icons.duckduckgo.com/ip3/\(h).ico")
    }
}

enum WebSearchService {
    struct Response: Decodable {
        let ok: Bool?
        let results: [WebSource]
    }

    static func search(apiBase: String, query: String, k: Int = 6) async throws -> [WebSource] {
        guard var comp = URLComponents(string: apiBase + "/web_search") else {
            throw NSError(domain: "WebSearchService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "web_search URL 无效"])
        }
        comp.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "k", value: String(k))
        ]
        guard let url = comp.url else {
            throw NSError(domain: "WebSearchService", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "web_search URL 组装失败"])
        }

        var req = AccountManager.makeAuthorizedRequest(url)
        req.httpMethod = "GET"
        req.timeoutInterval = 15

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "WebSearchService", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "web_search 无响应"])
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "WebSearchService", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "web_search 失败 \(http.statusCode): \(body)"])
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return decoded.results
    }
}



// MARK: - ✅ Chat prepare (inline, to pass tts_stream)
struct _ChatPrepareAPIResponse: Decodable {
    let ok: Bool
    let chatId: String
    let conversationId: String?
    let eventsURL: String?
    let ttsURL: String?
    let ttsStream: Bool?
    let userTranscript: String?
    let routeDecision: RouteDecisionDTO?  // ✅ 后端智能路由真实决策

    struct RouteDecisionDTO: Decodable {
        let route: String?
        let provider: String?
        let model: String?
        let needWeb: Bool?
        let needVision: Bool?
        let needFile: Bool?

        enum CodingKeys: String, CodingKey {
            case route, provider, model
            case needWeb = "need_web"
            case needVision = "need_vision"
            case needFile = "need_file"
        }
    }

    enum CodingKeys: String, CodingKey {
        case ok
        case chatId = "chat_id"
        case conversationId = "conversation_id"
        case eventsURL = "events_url"
        case ttsURL = "tts_url"
        case ttsStream = "tts_stream"
        case userTranscript = "user_transcript"
        case routeDecision = "route_decision"
    }
}

struct _ChatPrepareResult {
    let chatId: String
    let conversationId: String?
    let userTranscript: String?
    let ttsURL: URL?
    let ttsStream: Bool
    let routeDecision: _ChatPrepareAPIResponse.RouteDecisionDTO?  // ✅ 透传给 UI 决定档位
}



struct _ChatPreparePayload: Encodable {
    let plan: String?
    let model: String
    let provider: String?
    let messages: [LLMMessage]
    let attachments: [ChatAttachment]
    let conversationId: String?
    let searchEnabled: Bool
    let useWebSearch: Bool
    let webSearchEnabled: Bool
    let enableWebSearch: Bool
    let allowWeb: Bool
    let forceWebSearch: Bool
    let ttsVoice: String
    let ttsStream: Bool
    let perception: PerceptionSnapshot?  // ✅ 物理世界感知
    // ✅ 前后端对齐：深度思考由后端权威决定模型（CHAT_MODEL_THINKING）。
    //    true 时后端忽略 model 字段，统一走 reasoning 模型。
    let thinking: Bool
}


private func shouldEnableWebSearchForQuery(_ text: String) -> Bool {
    let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if raw.isEmpty { return false }
    let lower = raw.lowercased()
    let compact = lower.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    let keywords = [
        "今天", "今日", "现在", "目前", "当前", "最新", "刚刚", "最近", "这几天", "近几天",
        "价格", "天气", "新闻", "消息", "官网", "发布", "发生", "查一下", "查下", "搜一下",
        "搜索", "联网", "浏览", "全网", "current", "latest", "today", "now", "news", "price",
        "weather", "search", "browse", "look up", "official"
    ]
    return keywords.contains { lower.contains($0) || compact.contains($0) }
}


private func resolveAbsoluteURL(apiBase: String, urlString: String) -> URL? {
    if let u = URL(string: urlString), u.scheme != nil { return u }
    if urlString.hasPrefix("/") { return URL(string: apiBase + urlString) }
    return URL(string: apiBase + "/" + urlString)
}

/// Inline prepare to support `tts_stream=true` without touching GPT5ChatService+Streaming.swift
func prepareChat(
    apiBase: String,
    plan: String?,
    model: String,
    provider: String?,
    messages: [LLMMessage],
    attachments: [ChatAttachment],
    conversationId: String?,
    clientId: String,
    ttsStream: Bool,
    ttsVoice: String,
    perception: PerceptionSnapshot? = nil,
    searchEnabled: Bool = false,
    thinking: Bool = false
) async throws -> _ChatPrepareResult {

    let url = URL(string: apiBase + "/chat/prepare")!
    var req = AccountManager.makeAuthorizedRequest(url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    if !clientId.isEmpty {
        req.setValue(clientId, forHTTPHeaderField: "X-Client-ID")
    }
    if let p = plan?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
        req.setValue(p, forHTTPHeaderField: "X-ChatAGI-Plan")
    }
    req.timeoutInterval = 60

    let cid = conversationId?.trimmingCharacters(in: .whitespacesAndNewlines)
    let payload = _ChatPreparePayload(
    plan: plan,
    model: model,
    provider: provider,
    messages: messages,
    attachments: attachments,
    conversationId: (cid?.isEmpty ?? true) ? nil : cid,
    searchEnabled: searchEnabled,
    useWebSearch: searchEnabled,
    webSearchEnabled: searchEnabled,
    enableWebSearch: searchEnabled,
    allowWeb: true,
    forceWebSearch: searchEnabled,
    ttsVoice: ttsVoice,
    ttsStream: ttsStream,
    perception: perception,  // ✅ 附带感知（主线程已读取）
    thinking: thinking
)

let enc = JSONEncoder()
enc.keyEncodingStrategy = .convertToSnakeCase
req.httpBody = try enc.encode(payload)


    let (data, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse else {
        throw NSError(domain: "ChatPrepare", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
    }
    guard (200..<300).contains(http.statusCode) else {
        let body = String(data: data, encoding: .utf8) ?? ""
        throw NSError(domain: "ChatPrepare", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "prepare failed: \(http.statusCode) \(body)"])
    }

    let decoded = try JSONDecoder().decode(_ChatPrepareAPIResponse.self, from: data)
    guard decoded.ok else {
        throw NSError(domain: "ChatPrepare", code: -2, userInfo: [NSLocalizedDescriptionKey: "prepare returned ok=false"])
    }

    let ttsFullURL: URL?
    if let t = decoded.ttsURL, !t.isEmpty {
        ttsFullURL = resolveAbsoluteURL(apiBase: apiBase, urlString: t)
    } else {
        ttsFullURL = nil
    }

    // ✅ 商用隔离：优先用后端返回的 events_url 提取 `chatId?access_token=...`，
    // 这样旧的 streamEvents(apiBase:chatId:) 仍能带上一次性 job token，
    // /chat/events 和 /chat/result 就可以做 owner/token 校验。
    let streamChatId: String
    if let ev = decoded.eventsURL, let r = ev.range(of: "/chat/events/") {
        streamChatId = String(ev[r.upperBound...])
    } else {
        streamChatId = decoded.chatId
    }

    return _ChatPrepareResult(
        chatId: streamChatId,
        conversationId: decoded.conversationId,
        userTranscript: decoded.userTranscript,
        ttsURL: ttsFullURL,
        ttsStream: (decoded.ttsStream ?? false),
        routeDecision: decoded.routeDecision
    )
}

// MARK: - GPT5ChatService（Streaming only）
//
// 文本输出只走：POST /chat/prepare  ->  GET /chat/events/{chat_id} (SSE)
// 具体实现见：GPT5ChatService+Streaming.swift
final class GPT5ChatService { }


// MARK: - Media uploader
// ✅ 上传统一放在 ChatPlusFeature.swift 里：MediaUploadService / UploadedMedia

// MARK: - Audio bubble playback (全局单实例：避免同时播放多段)



// MARK: - ✅ Live TTS stream player (GET /tts/live/{id}.mp3 -> MP3StreamPlayer)
@MainActor
final class LiveTTSStreamController: ObservableObject {
    @Published private(set) var isPlaying: Bool = false

    private let player = MP3StreamPlayer()
    private var currentURL: URL? = nil

    func play(url: URL) {
        currentURL = url

        var req = AccountManager.makeAuthorizedRequest(url)
        req.httpMethod = "GET"
        req.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        req.timeoutInterval = 600

        isPlaying = true
        player.play(request: req)
    }

    /// ✅ Align with backend curl:
    /// curl -sS --no-buffer -X POST "$BASE/tts_stream.mp3" -H "Content-Type: application/json" \
    ///   -d '{"text":"...","voice":"alloy","format":"mp3"}' | ffplay -nodisp -autoexit -i -
    func speak(text: String, voice: String = "alloy", format: String = "mp3") {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let url = AppConfig.API.resolve("/tts_stream.mp3")
        currentURL = url

        var req = AccountManager.makeAuthorizedRequest(url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        req.timeoutInterval = 600

        let payload: [String: Any] = [
            "text": trimmed,
            "voice": voice,
            "format": format
        ]
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            print("[TTS] JSON encode failed: \(error)")
            return
        }

        isPlaying = true
        player.play(request: req)
    }


    func stop() {
        isPlaying = false
        currentURL = nil
        player.stop()
    }
}

final class GlobalAudioPlayer: ObservableObject {

    // ✅ 把底层资源放到 nonisolated Box：Box.deinit 会清理；避免 @MainActor deinit 触发编译错误
    private final class PlayerBox {
        var player: AVPlayer?
        var timeObserver: Any?
        var endObserver: NSObjectProtocol?
        var statusObs: NSKeyValueObservation?

        func cleanup() {
            if let t = timeObserver, let p = player {
                p.removeTimeObserver(t)
            }
            timeObserver = nil

            if let ob = endObserver {
                NotificationCenter.default.removeObserver(ob)
            }
            endObserver = nil

            statusObs = nil
            player?.pause()
            player = nil
        }

        deinit { cleanup() }
    }

    private let box = PlayerBox()

    @Published private(set) var activeId: UUID? = nil
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    func toggle(id: UUID, url: URL, fallbackDuration: TimeInterval) {
        if activeId == id {
            if isPlaying { pause() } else { resume() }
            return
        }

        // 换一段新的
        stop()

        activeId = id
        currentTime = 0
        duration = max(0, fallbackDuration)

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        // ✅ 更快起播（更“流式”），必要时可注释掉
        player.automaticallyWaitsToMinimizeStalling = false
        box.player = player

        box.statusObs = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            guard let self else { return }
            if it.status == .readyToPlay {
                let seconds = CMTimeGetSeconds(it.asset.duration)
                if seconds.isFinite, seconds > 0 {
                    Task { @MainActor in
                        self.duration = seconds
                    }
                }
            }
        }

        box.timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { [weak self] t in
            guard let self else { return }
            let secs = t.seconds.isFinite ? t.seconds : 0
            Task { @MainActor in
                self.currentTime = secs
            }
        }

        box.endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.stop()
            }
        }

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.allowBluetoothA2DP, .allowAirPlay])
        try? session.setActive(true)

        resume()
    }

    func stop() {
        pause()
        activeId = nil
        currentTime = 0
        duration = 0
        box.cleanup()
    }

    private func resume() {
        box.player?.play()
        isPlaying = true
    }

    private func pause() {
        box.player?.pause()
        isPlaying = false
    }
}

// MARK: - Assistant bubble speech（GPT 播报：流式优先，长文本强制下载）

@MainActor
final class GlobalSpeechPlayer: ObservableObject {

    @Published private(set) var activeId: UUID? = nil
    @Published private(set) var isSpeaking: Bool = false
    @Published private(set) var isPaused: Bool = false
    @Published private(set) var loadingId: UUID? = nil

    // ✅ 播报进度（用于“字随声走”）
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    /// 播报真正进入 `.playing` 时回调（用于“播报开始才吞字”）
    var onStart: ((UUID) -> Void)? = nil
    private var didNotifyStartForId: UUID? = nil

    private final class PlayerBox {
        var player: AVPlayer?
        var endObserver: NSObjectProtocol?
        var statusObs: NSKeyValueObservation?
        var timeControlObs: NSKeyValueObservation?
        var timeObserver: Any?

        func cleanup() {
            if let ob = endObserver {
                NotificationCenter.default.removeObserver(ob)
            }
            endObserver = nil

            statusObs = nil
            timeControlObs = nil

            if let to = timeObserver, let p = player {
                p.removeTimeObserver(to)
            }
            timeObserver = nil

            player?.pause()
            player = nil
        }

        deinit { cleanup() }
    }

    private let box = PlayerBox()

    private var cache: [UUID: URL] = [:]
    private var task: Task<Void, Never>? = nil
    private var timeoutTask: Task<Void, Never>? = nil

    private var currentText: String = ""
    private var currentApiBase: String = ""
    private var currentVoice: String = "alloy"
    private var currentOnError: ((String) -> Void)? = nil

    private var fallbackTried: Set<UUID> = []

    /// 长文本阈值：超过则强制“下载完再播”（更稳，避免流式首包/播放失败）
    private let streamingMaxChars = 900

    /// 后端已经准备好的 URL（避免“前端再 POST 文本去 /tts”）
    func playPrepared(
        id: UUID,
        url: URL,
        fallbackText: String,
        apiBase: String,
        voice: String = "alloy",
        onError: ((String) -> Void)? = nil
    ) {
        stop()
        fallbackTried.remove(id)

        currentOnError = onError
        currentText = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        currentApiBase = apiBase
        currentVoice = voice

        activeId = id
        cache[id] = url
        loadingId = nil

        // ✅ 文本太长：优先把 prepared URL 先下载到本地再播（更稳）
        if !url.isFileURL, currentText.count > streamingMaxChars {
            loadingId = id
            task = Task { [weak self] in
                guard let self else { return }
                do {
                    let local = try await Self.downloadToCache(remoteURL: url, messageId: id)
                    if Task.isCancelled { return }
                    await MainActor.run {
                        self.cache[id] = local
                        self.loadingId = nil
                        self.play(id: id, url: local, allowFallbackDownload: false)
                    }
                } catch {
                    if Task.isCancelled { return }
                    let nsError = error as NSError
                    if nsError.domain == NSURLErrorDomain && nsError.code == URLError.cancelled.rawValue {
                        return
                    }
                    await MainActor.run {
                        self.loadingId = nil
                        // prepared URL 下载失败 -> 回退到 /tts_prepare 再生成（单一链路）
                        self.fallbackDownloadAndPlay(reason: "prepared URL 下载失败：\(error.localizedDescription)")
                    }
                }
            }
            return
        }

        play(id: id, url: url, allowFallbackDownload: true)
    }

    /// ✅ 流式生成过程中持续补全 fallbackText（用于回退下载/兜底）
    func updateFallbackText(for id: UUID, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 只允许更新当前这条，避免串音
        guard activeId == id || loadingId == id else { return }
        if trimmed.count > currentText.count {
            currentText = trimmed
        }
    }

    /// 点击同一条：未播 -> 生成并播放；播放中/生成中 -> 中止
    func toggle(
        id: UUID,
        text: String,
        apiBase: String,
        voice: String = "alloy",
        onError: ((String) -> Void)? = nil
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        currentText = trimmed
        currentApiBase = apiBase
        currentVoice = voice
        currentOnError = onError
        fallbackTried.remove(id)

        if loadingId == id {
            stop()
            return
        }

        if activeId == id, isSpeaking {
            stop()
            return
        }

        stop()

        activeId = id
        isPaused = false

        if let u = cache[id] {
            play(id: id, url: u, allowFallbackDownload: true)
            return
        }

        loadingId = id
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await GPTTtsService.fetchAudioURL(
                    apiBase: apiBase,
                    text: trimmed,
                    messageId: id,
                    voice: voice
                )
                if Task.isCancelled { return }

                await MainActor.run {
                    self.cache[id] = url
                    self.loadingId = nil
                    self.play(id: id, url: url, allowFallbackDownload: true)
                }
            } catch is CancellationError {
                await MainActor.run { self.loadingId = nil }
            } catch {
                await MainActor.run {
                    self.loadingId = nil
                    self.activeId = nil
                    self.isSpeaking = false
                    self.isPaused = false
                    onError?("语音播报暂时不可用，请稍后再试。")
                }
            }
        }
    }

    func stop() {
        task?.cancel(); task = nil
        timeoutTask?.cancel(); timeoutTask = nil
        loadingId = nil

        isSpeaking = false
        isPaused = false
        activeId = nil
        didNotifyStartForId = nil
        currentTime = 0
        duration = 0

        box.cleanup()
    }

    private func play(id: UUID, url: URL, allowFallbackDownload: Bool) {
        box.cleanup()
        timeoutTask?.cancel(); timeoutTask = nil

        currentTime = 0
        duration = 0
        didNotifyStartForId = nil

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.allowBluetoothA2DP, .allowAirPlay, .duckOthers])
        try? session.setActive(true)

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        // ✅ 更快起播：让 AVPlayer 不要等到“最小卡顿缓冲”才开始
        player.automaticallyWaitsToMinimizeStalling = false
        box.player = player

        box.timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { [weak self] t in
            guard let self else { return }
            Task { @MainActor in
                guard self.activeId == id else { return }
                let sec = t.seconds
                if sec.isFinite { self.currentTime = sec }
            }
        }


        box.statusObs = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.activeId == id else { return }
                if it.status == .readyToPlay {
                    let sec = it.asset.duration.seconds
                    if sec.isFinite, sec > 0 { self.duration = sec }
                }

                if it.status == .failed {
                    let err = it.error?.localizedDescription ?? "unknown"
                    if allowFallbackDownload {
                        self.fallbackDownloadAndPlay(reason: "流式播放失败：\(err)")
                    } else {
                        self.currentOnError?("语音播报暂时不可用，请稍后再试。")
                        self.stop()
                    }
                }
            }
        }

        box.timeControlObs = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.activeId == id else { return }
                if p.timeControlStatus == .playing {
                    self.isSpeaking = true
                    self.isPaused = false
                    if self.didNotifyStartForId != id {
                        self.didNotifyStartForId = id
                        self.onStart?(id)
                    }
                } else if p.timeControlStatus == .paused {
                    self.isPaused = true
                }
            }
        }

        box.endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.stop() }
        }

        activeId = id
        isSpeaking = true
        isPaused = false
        loadingId = nil
        player.currentItem?.audioTimePitchAlgorithm = .timeDomain   // 更自然的变速
        player.playImmediately(atRate: 1.35)                         // ✅ 语速 1.35


        if allowFallbackDownload, !url.isFileURL {
            timeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 18_000_000_000)
                guard self.activeId == id else { return }
                guard let p = self.box.player else { return }
                if p.timeControlStatus != .playing {
                    self.fallbackDownloadAndPlay(reason: "流式起播超时")
                }
            }
        }
    }

    private func fallbackDownloadAndPlay(reason: String) {
        guard let id = activeId else { return }
        guard !fallbackTried.contains(id) else {
            currentOnError?("语音播报暂时不可用，请稍后再试。")
            stop()
            return
        }
        fallbackTried.insert(id)

        let t = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !currentApiBase.isEmpty else {
            currentOnError?("语音播报暂时不可用，请稍后再试。")
            stop()
            return
        }

        box.cleanup()
        isSpeaking = false
        isPaused = false
        loadingId = id

        task?.cancel(); task = nil
        timeoutTask?.cancel(); timeoutTask = nil

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let localURL = try await GPTTtsService.fetchDownloadedAudioURL(
                    apiBase: self.currentApiBase,
                    text: t,
                    messageId: id,
                    voice: self.currentVoice
                )
                if Task.isCancelled { return }

                await MainActor.run {
                    self.cache[id] = localURL
                    self.loadingId = nil
                    self.play(id: id, url: localURL, allowFallbackDownload: false)
                }
            } catch is CancellationError {
                await MainActor.run { self.loadingId = nil }
            } catch {
                await MainActor.run {
                    self.loadingId = nil
                    self.currentOnError?("语音播报暂时不可用，请稍后再试。")
                    self.stop()
                }
            }
        }
    }

    private static func downloadToCache(remoteURL: URL, messageId: UUID) async throws -> URL {
        let (data, resp) = try await URLSession.shared.data(from: remoteURL)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(code) else {
            throw NSError(domain: "GPTTTS", code: code, userInfo: [NSLocalizedDescriptionKey: "下载失败：HTTP \(code)"])
        }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let url = dir.appendingPathComponent("gpt_tts_prepared_\(messageId.uuidString).mp3")
        try data.write(to: url, options: [.atomic])
        return url
    }
}

// MARK: - GPTTtsService
// - 短文本：优先尝试 /tts_prepare（流式 URL）
// - 长文本：直接走“下载完再播”更稳（可调 streamingMaxChars）

private enum GPTTtsService {

    /// 统一入口：返回一个可播放 URL（短文本可能是远端流式 URL；长文本强制返回本地文件 URL）
    static func fetchAudioURL(
        apiBase: String,
        text: String,
        messageId: UUID,
        voice: String
    ) async throws -> URL {

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // ✅ 文本太长时：仍走 /tts_prepare，但会“先下载到本地再播”更稳
        let streamingMaxChars = 900 // 想更激进就调小；想尽量流式就调大
        if trimmed.count > streamingMaxChars {
            return try await fetchDownloadedAudioURL(apiBase: apiBase, text: trimmed, messageId: messageId, voice: voice)
        }

        // ✅ try streaming URL first
        if let streamURL = try? await fetchStreamingURL(apiBase: apiBase, text: trimmed, voice: voice) {
            return streamURL
        }

        // ---- fallback: download bytes then play ----
        return try await fetchDownloadedAudioURL(apiBase: apiBase, text: trimmed, messageId: messageId, voice: voice)
    }

    /// ✅ 强制“先下载再播放”（不走 /tts_prepare），且尽量返回本地 file URL
    
/// ✅ 强制“先下载再播放”（单一链路：只走 /tts_prepare -> /tts/live）
/// - 后端返回一个可播放 URL（通常是 /tts/live/<id>.mp3）
/// - 这里把它下载到本地缓存再播，避免流式首包/网络抖动导致失败
static func fetchDownloadedAudioURL(
    apiBase: String,
    text: String,
    messageId: UUID,
    voice: String
) async throws -> URL {

    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

    guard let remote = try await fetchStreamingURL(apiBase: apiBase, text: trimmed, voice: voice) else {
        throw NSError(domain: "GPTTTS", code: -2,
                      userInfo: [NSLocalizedDescriptionKey: "TTS /tts_prepare 返回异常（缺少 url）"])
    }

    if remote.isFileURL { return remote }
    return try await downloadAndCache(remoteURL: remote, messageId: messageId)
}

    // ✅ backend returns { ok:true, url:"/tts/<id>.mp3", tts_id:"...", expires_in:600 }
    private static func fetchStreamingURL(apiBase: String, text: String, voice: String) async throws -> URL? {
        guard let url = URL(string: apiBase + "/tts_prepare") else { return nil }

        var req = AccountManager.makeAuthorizedRequest(url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let cid = UserDefaults.standard.string(forKey: "solara.client_id"), !cid.isEmpty {
                req.setValue(cid, forHTTPHeaderField: "X-Client-ID")
            }

        let payload: [String: Any] = ["text": text, "voice": voice, "format": "mp3"]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { return nil }

        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else { return nil }

        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        guard let path = obj["url"] as? String else { return nil }

        return resolve(apiBase: apiBase, urlString: path)
    }

    

/// 直接把后端 /chat/prepare 返回的 tts_url 下载到本地缓存（用于：手动播报，可中止/可复播）
static func fetchDownloadedAudioURL(remoteURL: URL, messageId: UUID) async throws -> URL {
    try await downloadAndCache(remoteURL: remoteURL, messageId: messageId)
}
private static func downloadAndCache(remoteURL: URL, messageId: UUID) async throws -> URL {
        let (data, resp) = try await URLSession.shared.data(from: remoteURL)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(code) else {
            throw NSError(domain: "GPTTTS", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "下载失败：HTTP \(code)"])
        }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let url = dir.appendingPathComponent("gpt_tts_\(messageId.uuidString).mp3")
        try data.write(to: url, options: [.atomic])
        return url
    }

    private static func writeToCache(data: Data, messageId: UUID) throws -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let url = dir.appendingPathComponent("gpt_tts_\(messageId.uuidString).mp3")
        try data.write(to: url, options: [.atomic])
        return url
    }

    private static func resolve(apiBase: String, urlString: String) -> URL? {
        if let u = URL(string: urlString), u.scheme != nil { return u }
        if urlString.hasPrefix("/") { return URL(string: apiBase + urlString) }
        return URL(string: apiBase + "/" + urlString)
    }

    private static func looksLikeJSON(_ data: Data) -> Bool {
        guard let s = String(data: data, encoding: .utf8) else { return false }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("{") || t.hasPrefix("[")
    }
}

// MARK: - AudioNoteRecorder (发送前不删文件；成功后可删；失败可恢复；录音落在 Caches，保证气泡可播放)

@MainActor
final class AudioNoteRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {

    @Published private(set) var isRecording: Bool = false
    @Published private(set) var duration: TimeInterval = 0

    @Published private(set) var waveformSamples: [CGFloat] = Array(repeating: 0.12, count: 32)

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var smoothLevel: CGFloat = 0.12

    private(set) var pendingFileURL: URL? = nil
    private(set) var pendingDuration: TimeInterval = 0
    var hasPendingNote: Bool { pendingFileURL != nil }

    private(set) var stagedFileURL: URL? = nil
    private(set) var stagedDuration: TimeInterval = 0

    var durationText: String {
        let t: TimeInterval
        if isRecording { t = duration }
        else if hasPendingNote { t = pendingDuration }
        else { t = stagedDuration }
        let sec = Int(t.rounded())
        return String(format: "%02d:%02d", sec / 60, sec % 60)
    }

    func start() async throws {
        if isRecording { return }

        let ok = await requestPermission()
        if !ok {
            throw NSError(domain: "AudioNoteRecorder", code: -10,
                          userInfo: [NSLocalizedDescriptionKey: "麦克风未授权"])
        }

        let session = AVAudioSession.sharedInstance()
        // ✅ 录音优先使用 playAndRecord；加入 allowBluetooth，避免蓝牙耳机/车载麦克风下启动失败。
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
        try session.setActive(true, options: [])

        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let url = cacheDir.appendingPathComponent("voice_note_\(UUID().uuidString).m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let rec = try AVAudioRecorder(url: url, settings: settings)
        rec.delegate = self
        rec.isMeteringEnabled = true
        rec.prepareToRecord()

        if !rec.record() {
            throw NSError(domain: "AudioNoteRecorder", code: -11,
                          userInfo: [NSLocalizedDescriptionKey: "录音启动失败"])
        }

        recorder = rec
        isRecording = true
        duration = 0
        smoothLevel = 0.12
        waveformSamples = Array(repeating: 0.12, count: 32)

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
            guard let self, self.isRecording else { return }
            self.duration = self.recorder?.currentTime ?? self.duration

            guard let r = self.recorder else { return }
            r.updateMeters()
            let power = r.averagePower(forChannel: 0)
            let level = self.normalizePower(power)

            let alpha: CGFloat = 0.22
            self.smoothLevel = self.smoothLevel * (1 - alpha) + level * alpha
            self.pushWaveSample(self.smoothLevel)
        }
    }

    func stopAndMarkPending() {
        guard isRecording else { return }
        recorder?.stop()
        timer?.invalidate(); timer = nil
        isRecording = false

        pendingFileURL = recorder?.url
        pendingDuration = duration

        recorder = nil
        duration = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func stagePendingForUpload() -> (url: URL, duration: TimeInterval)? {
        guard let url = pendingFileURL else { return nil }
        stagedFileURL = url
        stagedDuration = pendingDuration
        pendingFileURL = nil
        pendingDuration = 0
        return (url, stagedDuration)
    }

    func finalizeStaged(deleteFile: Bool) {
        if deleteFile, let url = stagedFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        stagedFileURL = nil
        stagedDuration = 0
    }

    func restoreStagedToPending() {
        guard pendingFileURL == nil else { return }
        pendingFileURL = stagedFileURL
        pendingDuration = stagedDuration
        stagedFileURL = nil
        stagedDuration = 0
    }

    func clearPending() {
        if let url = pendingFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        pendingFileURL = nil
        pendingDuration = 0
    }

    func cancel() {
        if isRecording {
            recorder?.stop()
            timer?.invalidate(); timer = nil
            isRecording = false
        }
        if let url = recorder?.url {
            try? FileManager.default.removeItem(at: url)
        }
        recorder = nil
        duration = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])

        clearPending()
        stagedFileURL = nil
        stagedDuration = 0
    }

    private func normalizePower(_ db: Float) -> CGFloat {
        let clamped = max(-60, min(0, db))
        let linear = pow(10, clamped / 20)
        return CGFloat(max(0.08, min(1.0, linear)))
    }

    private func pushWaveSample(_ v: CGFloat) {
        var s = waveformSamples
        s.append(v)
        if s.count > 32 { s.removeFirst(s.count - 32) }
        waveformSamples = s
    }

    private func requestPermission() async -> Bool {
        let perm = AVAudioSession.sharedInstance().recordPermission
        switch perm {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { cont in
                AVAudioSession.sharedInstance().requestRecordPermission { ok in
                    cont.resume(returning: ok)
                }
            }
        @unknown default:
            return false
        }
    }
}

enum HomeHaptics {
    static func light() {
        let gen = UIImpactFeedbackGenerator(style: .light)
        gen.prepare()
        gen.impactOccurred()
    }
}

// MARK: - UIImage helpers (缩放+压缩)

private extension UIImage {
    func resizedJPEGData(maxDimension: CGFloat, quality: CGFloat) -> Data? {
        let w = size.width
        let h = size.height
        let maxSide = max(w, h)
        guard maxSide > maxDimension else {
            return jpegData(compressionQuality: quality)
        }
        let scale = maxDimension / maxSide
        let newSize = CGSize(width: w * scale, height: h * scale)

        UIGraphicsBeginImageContextWithOptions(newSize, true, 1.0)
        defer { UIGraphicsEndImageContext() }
        draw(in: CGRect(origin: .zero, size: newSize))
        let img = UIGraphicsGetImageFromCurrentImageContext()
        return img?.jpegData(compressionQuality: quality)
    }
}


// MARK: - NativeCodeHighlighterView（原生 Swift：无 WebKit、无第三方库）

/// 说明：
/// - 这是一个“轻量级语法高亮”，目标是 **稳定、不卡顿、字符不丢失**（尤其是流式输出时）
/// - 重点覆盖：Swift / Python / JS / JSON / Bash
/// - 不依赖 WebView，不依赖第三方库（你已删除的高亮库也不会再被引用）
struct NativeCodeHighlighterView: UIViewRepresentable {
    let code: String
    let language: String
    @Binding var dynamicHeight: CGFloat

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        tv.textContainer.lineFragmentPadding = 0
        tv.adjustsFontForContentSizeCategory = true
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        tv.dataDetectorTypes = []
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        uiView.attributedText = NativeSyntaxHighlighter.highlight(code: code, language: language)

        // 动态高度（让代码块自然撑开；外层仍可决定是否给 ScrollView）
        DispatchQueue.main.async {
            let width = uiView.bounds.width > 0 ? uiView.bounds.width : (UIScreen.main.bounds.width - 80)
            let target = CGSize(width: width, height: .greatestFiniteMagnitude)
            let size = uiView.sizeThatFits(target)
            if abs(dynamicHeight - size.height) > 0.5 {
                dynamicHeight = size.height
            }
        }
    }
}

// ---- Lightweight syntax highlighter (UIKit AttributedString) ----

private enum NativeCodeLang {
    case swift, python, javascript, json, bash, unknown

    static func detect(_ raw: String) -> NativeCodeLang {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["swift"].contains(s) { return .swift }
        if ["py", "python"].contains(s) { return .python }
        if ["js", "javascript", "ts", "typescript"].contains(s) { return .javascript }
        if ["json"].contains(s) { return .json }
        if ["sh", "bash", "zsh", "shell"].contains(s) { return .bash }
        return .unknown
    }
}

private struct NativeSyntaxHighlighter {
    static func highlight(code: String, language: String) -> NSAttributedString {
        let lang = NativeCodeLang.detect(language)

        let font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let baseColor = UIColor.label

        let attr = NSMutableAttributedString(string: code, attributes: [
            .font: font,
            .foregroundColor: baseColor
        ])

        let ns = code as NSString
        let full = NSRange(location: 0, length: ns.length)

        // 1) 先扫描字符串/注释范围（后续关键字/数字不覆盖这些范围）
        let scan = scanStringsAndComments(code: code, lang: lang)
        let protected = scan.strings + scan.comments

        // 2) 先上色：注释、字符串
        for r in scan.comments {
            safeAdd(attr, [
                .foregroundColor: UIColor.systemGray
            ], range: r, within: full)
        }
        for r in scan.strings {
            safeAdd(attr, [
                .foregroundColor: UIColor.systemGreen
            ], range: r, within: full)
        }

        // 3) JSON 特化：key / true|false|null
        if lang == .json {
            applyRegex(#""(?:\\.|[^"\\])*"(?=\s*:)"#, to: attr, color: UIColor.systemTeal, protected: protected)
            applyRegex(#"\b(true|false|null)\b"#, to: attr, color: UIColor.systemBlue, protected: protected, options: [.caseInsensitive])
        }

        // 4) 数字
        applyRegex(#"\b\d+(\.\d+)?\b"#, to: attr, color: UIColor.systemOrange, protected: protected)

        // 5) 关键字
        let kws = keywords(for: lang)
        if !kws.isEmpty {
            let joined = kws.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
            let pattern = #"\b("# + joined + #")\b"#
            applyRegex(pattern, to: attr, color: UIColor.systemBlue, protected: protected)
        }

        // 6) 一点点“函数名”高亮（可读性更像 ChatGPT，但不过度）
        //    foo(...) / bar(...)
        applyRegex(#"\b([A-Za-z_][A-Za-z0-9_]*)\s*(?=\()"#, to: attr, color: UIColor.systemPurple, protected: protected)

        return attr
    }

    private static func keywords(for lang: NativeCodeLang) -> [String] {
        switch lang {
        case .swift:
            return [
                "import","let","var","func","if","else","switch","case","default","for","while","repeat","in",
                "break","continue","return","throw","throws","rethrows","try","catch","do","defer","guard",
                "struct","class","enum","protocol","extension","init","self","super","static","final",
                "public","private","internal","fileprivate","open","mutating","nonmutating",
                "true","false","nil","as","is","where"
            ]
        case .python:
            return [
                "def","class","if","elif","else","for","while","try","except","finally","with","as","return",
                "import","from","pass","break","continue","lambda","yield","async","await","raise",
                "True","False","None","and","or","not","in","is"
            ]
        case .javascript:
            return [
                "function","const","let","var","if","else","for","while","try","catch","finally","return",
                "import","from","export","default","class","extends","new","this","super","async","await",
                "throw","switch","case","break","continue","true","false","null","undefined"
            ]
        case .bash:
            return [
                "if","then","fi","for","in","do","done","case","esac","function","select","while","until",
                "break","continue","return","export","unset","local","readonly","echo","printf","cd","exit"
            ]
        case .json, .unknown:
            return []
        }
    }

    private struct ScanResult {
        var strings: [NSRange] = []
        var comments: [NSRange] = []
    }

    /// 使用 UTF16 下标扫描（与 NSRange 对齐），避免 emoji 等字符导致 range 错位。
    private static func scanStringsAndComments(code: String, lang: NativeCodeLang) -> ScanResult {
        let u = Array(code.utf16)
        let n = u.count

        func ch(_ i: Int) -> UInt16 { u[i] }
        func isNewline(_ x: UInt16) -> Bool { x == 10 || x == 13 } // \n or \r

        var res = ScanResult()

        var i = 0

        var inString: UInt16? = nil          // 34 " or 39 '
        var stringStart = 0
        var triple = false

        var inBlockComment = false
        var blockStart = 0

        while i < n {
            let c = ch(i)
            let next = (i + 1 < n) ? ch(i + 1) : 0
            let next2 = (i + 2 < n) ? ch(i + 2) : 0

            // ---- block comment ----
            if inBlockComment {
                if c == 42 && next == 47 { // */
                    let end = i + 2
                    res.comments.append(NSRange(location: blockStart, length: end - blockStart))
                    inBlockComment = false
                    i = end
                    continue
                }
                i += 1
                continue
            }

            // ---- string ----
            if let quote = inString {
                if c == 92 { // backslash escape
                    i = min(i + 2, n)
                    continue
                }
                if triple {
                    if c == quote && next == quote && next2 == quote {
                        let end = min(i + 3, n)
                        res.strings.append(NSRange(location: stringStart, length: end - stringStart))
                        inString = nil
                        triple = false
                        i = end
                        continue
                    }
                    i += 1
                    continue
                } else {
                    if c == quote {
                        let end = i + 1
                        res.strings.append(NSRange(location: stringStart, length: end - stringStart))
                        inString = nil
                        i = end
                        continue
                    }
                    i += 1
                    continue
                }
            }

            // ---- comment start ----
            if (lang == .swift || lang == .javascript) {
                if c == 47 && next == 47 { // //
                    let start = i
                    var j = i + 2
                    while j < n && !isNewline(ch(j)) { j += 1 }
                    res.comments.append(NSRange(location: start, length: j - start))
                    i = j
                    continue
                }
                if c == 47 && next == 42 { // /*
                    inBlockComment = true
                    blockStart = i
                    i += 2
                    continue
                }
            }
            if (lang == .python || lang == .bash) {
                if c == 35 { // #
                    let start = i
                    var j = i + 1
                    while j < n && !isNewline(ch(j)) { j += 1 }
                    res.comments.append(NSRange(location: start, length: j - start))
                    i = j
                    continue
                }
            }

            // ---- string start ----
            if c == 34 || c == 39 { // " or '
                if lang == .python {
                    // triple quotes
                    if next == c && next2 == c {
                        inString = c
                        triple = true
                        stringStart = i
                        i = min(i + 3, n)
                        continue
                    }
                }
                inString = c
                triple = false
                stringStart = i
                i += 1
                continue
            }

            i += 1
        }

        // 未闭合字符串/注释，直接到末尾（流式输出时经常发生）
        if let _ = inString {
            res.strings.append(NSRange(location: stringStart, length: n - stringStart))
        }
        if inBlockComment {
            res.comments.append(NSRange(location: blockStart, length: n - blockStart))
        }

        return res
    }

    private static func applyRegex(
        _ pattern: String,
        to attr: NSMutableAttributedString,
        color: UIColor,
        protected: [NSRange],
        options: NSRegularExpression.Options = []
    ) {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return }
        let ns = attr.string as NSString
        let full = NSRange(location: 0, length: ns.length)

        re.enumerateMatches(in: attr.string, options: [], range: full) { m, _, _ in
            guard let r = m?.range else { return }
            if intersectsAny(r, protected) { return }
            safeAdd(attr, [.foregroundColor: color], range: r, within: full)
        }
    }

    private static func intersectsAny(_ r: NSRange, _ list: [NSRange]) -> Bool {
        for x in list {
            if NSIntersectionRange(r, x).length > 0 { return true }
        }
        return false
    }

    private static func safeAdd(_ attr: NSMutableAttributedString, _ attrs: [NSAttributedString.Key: Any], range: NSRange, within full: NSRange) {
        guard range.location >= 0, range.length >= 0 else { return }
        let end = range.location + range.length
        let fullEnd = full.location + full.length
        guard end <= fullEnd else { return }
        attr.addAttributes(attrs, range: range)
    }
}

// MARK: - 微信式：AI + 人与人聊天 + 视频通话（GPT 也是一个“人”）
//
// 说明：
// - 这里先把“家居模块”改成微信会话入口（聊天列表 + 新建会话 + 人与人聊天页 + 视频通话占位）
// - GPT 作为一个固定会话项：点击后返回到 HomeChatView（即 GPT 对话页）
// - 人与人聊天走新增后端：/auth/login /conversations /messages + /ws（信令/消息推送）
// - 视频通话：当前先提供“信令层 + UI骨架”，WebRTC 媒体层你现有工程里已用过（RealtimeAVService），后续可把 PeerConnection 挂进去
//

// MARK: Models

struct WeChatUser: Codable, Hashable {
    let user_id: String
    let display_name: String
}

struct WeChatConversationSummary: Codable, Identifiable, Hashable {
    let id: String
    let type: String
    let title: String
    let peer_id: String?
    let last_text: String?
    let updated_at: Double
}

struct WeChatMessageDTO: Codable, Identifiable, Hashable {
    let id: String
    let conversation_id: String
    let sender_id: String
    let kind: String
    let text: String
    let created_at: Double
}

struct WeChatLoginResponse: Codable {
    let ok: Bool
    let user_id: String
    let token: String
    let display_name: String
}

struct WeChatListConversationsResponse: Codable {
    let ok: Bool
    let conversations: [WeChatConversationSummary]
}

struct WeChatListMessagesResponse: Codable {
    let ok: Bool
    let messages: [WeChatMessageDTO]
}

struct WeChatCreateDirectResponse: Codable {
    let ok: Bool
    let conversation: WeChatConversationSummary
}

struct WeChatSendMessageResponse: Codable {
    let ok: Bool
    let message: WeChatMessageDTO
}

// MARK: - Store + Socket

@MainActor
final class WeChatStore: ObservableObject {
    @Published private(set) var me: WeChatUser? = nil
    @Published private(set) var token: String? = nil

    @Published var conversations: [WeChatConversationSummary] = []
    @Published var isConnected: Bool = false
    @Published var errorText: String? = nil

    private(set) var apiBase: String = ""
    private var socket: WeChatSocket? = nil

    /// 当前打开的人与人会话（用于把 ws 新消息推给前台 chatroom）
    private var activeConversationId: String? = nil
    private var onIncomingForActiveConversation: ((WeChatMessageDTO) -> Void)? = nil

    func bootstrap(apiBase: String) async {
        self.apiBase = apiBase

        if let savedToken = UserDefaults.standard.string(forKey: "wechat.token"),
           let savedUid = UserDefaults.standard.string(forKey: "wechat.user_id"),
           let savedName = UserDefaults.standard.string(forKey: "wechat.display_name") {
            self.token = savedToken
            self.me = .init(user_id: savedUid, display_name: savedName)
        }

        if token == nil {
            await login()
        }

        if let tok = token {
            connectSocket(token: tok)
        }

        await refreshConversations()
    }

    func login(displayName: String? = nil) async {
        do {
            let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
            let name = (displayName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? (UserDefaults.standard.string(forKey: "wechat.display_name") ?? "iPhone")

            var req = AccountManager.makeAuthorizedRequest(URL(string: "\(apiBase)/auth/login")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let cid = UserDefaults.standard.string(forKey: "solara.client_id"), !cid.isEmpty {
                req.setValue(cid, forHTTPHeaderField: "X-Client-ID")
            }

            let body: [String: Any] = [
                "device_id": deviceId,
                "display_name": name
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(code) else {
                let t = String(data: data, encoding: .utf8) ?? ""
                throw NSError(domain: "wechat.login", code: code, userInfo: [NSLocalizedDescriptionKey: t])
            }

            let r = try JSONDecoder().decode(WeChatLoginResponse.self, from: data)
            guard r.ok else { throw NSError(domain: "wechat.login", code: -1, userInfo: [NSLocalizedDescriptionKey: "login failed"]) }

            self.me = .init(user_id: r.user_id, display_name: r.display_name)
            self.token = r.token

            UserDefaults.standard.setValue(r.user_id, forKey: "wechat.user_id")
            UserDefaults.standard.setValue(r.display_name, forKey: "wechat.display_name")
            UserDefaults.standard.setValue(r.token, forKey: "wechat.token")

        } catch {
            self.errorText = "登录失败：\(error.localizedDescription)"
        }
    }

    func refreshConversations() async {
        guard let tok = token else { return }
        do {
            var req = AccountManager.makeAuthorizedRequest(URL(string: "\(apiBase)/conversations")!)
            req.httpMethod = "GET"
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")

            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(code) else {
                let t = String(data: data, encoding: .utf8) ?? ""
                throw NSError(domain: "wechat.conversations", code: code, userInfo: [NSLocalizedDescriptionKey: t])
            }

            let r = try JSONDecoder().decode(WeChatListConversationsResponse.self, from: data)
            guard r.ok else { return }
            self.conversations = r.conversations.sorted(by: { $0.updated_at > $1.updated_at })
        } catch {
            self.errorText = "拉取会话失败：\(error.localizedDescription)"
        }
    }

    func createDirectConversation(peerId: String) async -> WeChatConversationSummary? {
        guard let tok = token else { return nil }
        do {
            var req = AccountManager.makeAuthorizedRequest(URL(string: "\(apiBase)/conversations/direct")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let cid = UserDefaults.standard.string(forKey: "solara.client_id"), !cid.isEmpty {
                req.setValue(cid, forHTTPHeaderField: "X-Client-ID")
            }
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")

            let body: [String: Any] = ["peer_id": peerId]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(code) else {
                let t = String(data: data, encoding: .utf8) ?? ""
                throw NSError(domain: "wechat.direct", code: code, userInfo: [NSLocalizedDescriptionKey: t])
            }

            let r = try JSONDecoder().decode(WeChatCreateDirectResponse.self, from: data)
            guard r.ok else { return nil }

            // 更新列表：插到最前
            if let idx = conversations.firstIndex(where: { $0.id == r.conversation.id }) {
                conversations.remove(at: idx)
            }
            conversations.insert(r.conversation, at: 0)
            return r.conversation
        } catch {
            self.errorText = "创建会话失败：\(error.localizedDescription)"
            return nil
        }
    }

    func fetchMessages(conversationId: String) async -> [WeChatMessageDTO] {
        guard let tok = token else { return [] }
        do {
            var comps = URLComponents(string: "\(apiBase)/messages")!
            comps.queryItems = [URLQueryItem(name: "conversation_id", value: conversationId)]
            var req = AccountManager.makeAuthorizedRequest(comps.url!)
            req.httpMethod = "GET"
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")

            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(code) else { return [] }

            let r = try JSONDecoder().decode(WeChatListMessagesResponse.self, from: data)
            return r.messages
        } catch {
            return []
        }
    }

    func sendMessage(conversationId: String, text: String) async -> WeChatMessageDTO? {
        guard let tok = token else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        do {
            var req = AccountManager.makeAuthorizedRequest(URL(string: "\(apiBase)/messages")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let cid = UserDefaults.standard.string(forKey: "solara.client_id"), !cid.isEmpty {
                req.setValue(cid, forHTTPHeaderField: "X-Client-ID")
            }
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")

            let body: [String: Any] = [
                "conversation_id": conversationId,
                "text": trimmed
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(code) else { return nil }

            let r = try JSONDecoder().decode(WeChatSendMessageResponse.self, from: data)
            return r.message
        } catch {
            return nil
        }
    }

    func setActiveConversation(_ id: String?, onIncoming: ((WeChatMessageDTO) -> Void)?) {
        activeConversationId = id
        onIncomingForActiveConversation = onIncoming
    }

    // MARK: Socket

    private func connectSocket(token: String) {
        socket?.disconnect()
        let s = WeChatSocket()
        socket = s

        s.onConnectChanged = { [weak self] ok in
            Task { @MainActor in self?.isConnected = ok }
        }

        s.onJSON = { [weak self] obj in
            guard let self else { return }
            self.handleSocketJSON(obj)
        }

        s.connect(apiBase: apiBase, token: token)
    }

    private func handleSocketJSON(_ obj: [String: Any]) {
        let type = (obj["type"] as? String) ?? ""

        if type == "msg.new",
           let convId = obj["conversation_id"] as? String,
           let msgDict = obj["message"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: msgDict),
           let msg = try? JSONDecoder().decode(WeChatMessageDTO.self, from: data) {

            // 更新会话列表 preview
            if let idx = conversations.firstIndex(where: { $0.id == convId }) {
                var c = conversations[idx]
                let updated = WeChatConversationSummary(
                    id: c.id,
                    type: c.type,
                    title: c.title,
                    peer_id: c.peer_id,
                    last_text: msg.text,
                    updated_at: msg.created_at
                )
                conversations.remove(at: idx)
                conversations.insert(updated, at: 0)
            } else {
                // 不存在就刷新
                Task { await refreshConversations() }
            }

            // 若当前打开该会话，直接推给 chatroom
            if activeConversationId == convId {
                onIncomingForActiveConversation?(msg)
            }
        }

        // ✅ 视频通话/信令：目前只做透传（call.* / webrtc.*），后续可挂 WebRTC 媒体层
        // 你可以在这里解析 type == "call.invite" 等，触发系统来电 UI 或内置通话页
    }
}

final class WeChatSocket {
    var onJSON: (([String: Any]) -> Void)? = nil
    var onConnectChanged: ((Bool) -> Void)? = nil

    private var task: URLSessionWebSocketTask? = nil
    private var receiveTask: Task<Void, Never>? = nil

    func connect(apiBase: String, token: String) {
        disconnect()

        let wsURL = Self.makeWSURL(apiBase: apiBase, token: token)
        let t = URLSession.shared.webSocketTask(with: wsURL)
        task = t
        t.resume()
        onConnectChanged?(true)

        receiveTask = Task { [weak self] in
            guard let self else { return }
            await self.receiveLoop()
        }
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil

        task?.cancel(with: .goingAway, reason: nil)
        task = nil

        onConnectChanged?(false)
    }

    func sendJSON(_ obj: [String: Any]) {
        guard let task else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }

        task.send(.string(text)) { _ in }
    }

    private func receiveLoop() async {
        guard let task else { return }
        while !Task.isCancelled {
            do {
                let msg = try await task.receive()
                switch msg {
                case .string(let s):
                    if let data = s.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        onJSON?(obj)
                    }
                case .data(let d):
                    if let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                        onJSON?(obj)
                    }
                @unknown default:
                    break
                }
            } catch {
                onConnectChanged?(false)
                break
            }
        }
    }

    private static func makeWSURL(apiBase: String, token: String) -> URL {
        // http(s)://host -> ws(s)://host
        if apiBase.hasPrefix("https://") {
            let base = apiBase.replacingOccurrences(of: "https://", with: "wss://")
            return URL(string: "\(base)/ws?token=\(token)")!
        } else if apiBase.hasPrefix("http://") {
            let base = apiBase.replacingOccurrences(of: "http://", with: "ws://")
            return URL(string: "\(base)/ws?token=\(token)")!
        } else {
            return URL(string: "\(apiBase)/ws?token=\(token)")!
        }
    }
}

// MARK: - WeChat UI

// =======================================================
// ✅ 子模块 2（HomeChatView2）
// - 保持 HomeChatView 主页面不变：只在点击“进入聊天”按钮时进入该子模块
// - 先做「微信式骨架」：会话列表 + 底部 4 Tab（WeChat/通讯录/发现/我）
// - 后续升级：把真实数据、联系人、朋友圈、通话等逐步接进来
// =======================================================

struct HomeChatView2: View {
    let apiBase: String
    @ObservedObject var store: WeChatStore

    let onOpenGPT: () -> Void
    let onOpenHomeLegacy: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var tab: Int = 0

    var body: some View {
        TabView(selection: $tab) {
            WeChatChatsTabView(
                apiBase: apiBase,
                store: store,
                onOpenGPT: {
                    onOpenGPT()
                    dismiss()
                },
                onOpenHomeLegacy: onOpenHomeLegacy
            )
            .tabItem {
                Label("WeChat", systemImage: "message")
            }
            .tag(0)

            WeChatContactsTabSkeletonView()
                .tabItem {
                    Label("通讯录", systemImage: "person.2")
                }
                .tag(1)

            WeChatDiscoverTabSkeletonView()
                .tabItem {
                    Label("发现", systemImage: "safari")
                }
                .tag(2)

            WeChatMeTabSkeletonView(store: store)
                .tabItem {
                    Label("我", systemImage: "person.crop.circle")
                }
                .tag(3)
        }
    }
}

// MARK: - WeChat Tab 1：聊天（会话列表）

private struct WeChatChatsTabView: View {
    let apiBase: String
    @ObservedObject var store: WeChatStore

    let onOpenGPT: () -> Void
    let onOpenHomeLegacy: () -> Void

    @State private var query: String = ""
    @State private var showingNewChat: Bool = false

    var body: some View {
        NavigationStack {
            List {
                // ✅ 顶部固定：GPT 入口（把 GPT 也当成“联系人/会话”）
                Button {
                    onOpenGPT()
                } label: {
                    WeChatConversationRowView(
                        title: "ChatAGI-阿杜（GPT）",
                        subtitle: "AI 聊天 · 语音/代码高亮/稳定流式",
                        timeText: ""
                    )
                }
                .buttonStyle(.plain)

                // ✅ 文件传输助手（占位，后续可接文件/图片流转）
                WeChatConversationRowView(
                    title: "文件传输助手",
                    subtitle: "[图片]",
                    timeText: ""
                )

                // ✅ 会话列表（后端接好后这里会有数据；为空时显示骨架）
                if filteredConversations.isEmpty {
                    ForEach(0..<8, id: \.self) { _ in
                        WeChatSkeletonRowView()
                    }
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(filteredConversations) { conv in
                        NavigationLink(value: conv) {
                            WeChatConversationRowView(
                                title: conv.title,
                                subtitle: conv.last_text ?? "",
                                timeText: Self.fmtTime(conv.updated_at)
                            )
                        }
                    }
                }

                // ✅ 家居旧入口（可选）
                Button {
                    onOpenHomeLegacy()
                } label: {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.blue.opacity(0.12))
                            .frame(width: 44, height: 44)
                            .overlay(
                                Image(systemName: "house.fill")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(.blue)
                            )

                        VStack(alignment: .leading, spacing: 4) {
                            Text("原家居语音控制（Legacy）")
                                .font(.system(size: 17, weight: .semibold))
                            if let e = store.errorText, !e.isEmpty {
                                Text(e)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.red)
                                    .lineLimit(1)
                            } else {
                                Text("可选入口")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .navigationDestination(for: WeChatConversationSummary.self) { conv in
                HumanChatRoomView(apiBase: apiBase, store: store, conv: conv)
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Text("WeChat")
                            .font(.headline)
                        if !store.isConnected {
                            ProgressView().scaleEffect(0.8)
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingNewChat = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingNewChat) {
                WeChatNewChatSheet(apiBase: apiBase, store: store)
            }
            .refreshable {
                await store.refreshConversations()
            }
            .onAppear {
                Task { await store.bootstrap(apiBase: apiBase) }
            }
        }
    }

    private var filteredConversations: [WeChatConversationSummary] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return store.conversations }
        return store.conversations.filter { c in
            c.title.localizedCaseInsensitiveContains(q)
            || (c.last_text ?? "").localizedCaseInsensitiveContains(q)
        }
    }

    private static func fmtTime(_ ts: Double) -> String {
        guard ts > 0 else { return "" }
        let d = Date(timeIntervalSince1970: ts)
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}

// MARK: - WeChat Tab 2/3/4：骨架占位

private struct WeChatContactsTabSkeletonView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("新的朋友", systemImage: "person.badge.plus")
                    Label("群聊", systemImage: "person.3")
                    Label("标签", systemImage: "tag")
                    Label("公众号", systemImage: "bubble.left.and.bubble.right")
                }

                Section(header: Text("联系人（占位）")) {
                    ForEach(0..<12, id: \.self) { _ in
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.gray.opacity(0.18))
                                .frame(width: 36, height: 36)
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.gray.opacity(0.18))
                                .frame(width: 120, height: 14)
                            Spacer()
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("通讯录")
        }
    }
}

private struct WeChatDiscoverTabSkeletonView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("朋友圈（占位）", systemImage: "photo.on.rectangle")
                }
                Section {
                    Label("扫一扫", systemImage: "qrcode.viewfinder")
                    Label("摇一摇（占位）", systemImage: "wave.3.right")
                }
                Section {
                    Label("看一看（占位）", systemImage: "eye")
                    Label("搜一搜（占位）", systemImage: "magnifyingglass")
                }
                Section {
                    Label("附近（占位）", systemImage: "location")
                    Label("购物（占位）", systemImage: "bag")
                    Label("游戏（占位）", systemImage: "gamecontroller")
                }
            }
            .listStyle(.plain)
            .navigationTitle("发现")
        }
    }
}

private struct WeChatMeTabSkeletonView: View {
    @ObservedObject var store: WeChatStore

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.gray.opacity(0.18))
                            .frame(width: 56, height: 56)
                            .overlay(
                                Text("我")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            )
                        VStack(alignment: .leading, spacing: 4) {
                            Text(store.me?.display_name ?? "未登录")
                                .font(.system(size: 18, weight: .semibold))
                            Text("ID: \(store.me?.user_id ?? "-")")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }

                Section {
                    Label("服务（占位）", systemImage: "creditcard")
                    Label("收藏（占位）", systemImage: "star")
                    Label("朋友圈（占位）", systemImage: "photo")
                    Label("卡包（占位）", systemImage: "wallet.pass")
                    Label("表情（占位）", systemImage: "face.smiling")
                }

                Section {
                    Label("设置（占位）", systemImage: "gear")
                }
            }
            .listStyle(.plain)
            .navigationTitle("我")
        }
    }
}

// MARK: - Skeleton Row

private struct WeChatSkeletonRowView: View {
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.gray.opacity(0.18))
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.gray.opacity(0.18))
                    .frame(width: 160, height: 14)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.gray.opacity(0.18))
                    .frame(width: 220, height: 12)
            }

            Spacer(minLength: 0)

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.gray.opacity(0.14))
                .frame(width: 44, height: 10)
        }
        .padding(.vertical, 6)
        .redacted(reason: .placeholder)
    }
}

struct WeChatHomeSheetView: View {
    let apiBase: String
    @ObservedObject var store: WeChatStore

    @Environment(\.dismiss) private var dismiss

    let onOpenGPT: () -> Void
    let onOpenHomeLegacy: () -> Void
    @State private var query: String = ""
    @State private var showingNewChat: Bool = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        onOpenGPT()
                        dismiss()
                    } label: {
                        WeChatConversationRowView(
                            title: "ChatAGI-阿杜（GPT）",
                            subtitle: "AI 聊天 · 语音/代码高亮/稳定流式",
                            timeText: ""
                        )
                    }
                    .buttonStyle(.plain)
                }

                Section(header: Text("聊天")) {
                    let filtered = store.conversations.filter { c in
                        if query.isEmpty { return true }
                        return c.title.localizedCaseInsensitiveContains(query)
                            || (c.last_text ?? "").localizedCaseInsensitiveContains(query)
                    }

                    ForEach(filtered) { conv in
                        NavigationLink(value: conv) {
                            WeChatConversationRowView(
                                title: conv.title,
                                subtitle: conv.last_text ?? "",
                                timeText: Self.fmtTime(conv.updated_at)
                            )
                        }
                    }
                }

                Section(header: Text("家居旧入口（可选）")) {
                    Button {
                        onOpenHomeLegacy()
                    } label: {
                        Label("原家居语音控制（Legacy）", systemImage: "house.fill")
                    }
                }

                if let e = store.errorText, !e.isEmpty {
                    Section {
                        Text(e).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .listStyle(.plain)
            .navigationDestination(for: WeChatConversationSummary.self) { conv in
                HumanChatRoomView(apiBase: apiBase, store: store, conv: conv)
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        if store.isConnected {
                            ProgressView().scaleEffect(0.8)
                        }
                        Text("收取中…").font(.headline)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingNewChat = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingNewChat) {
                WeChatNewChatSheet(apiBase: apiBase, store: store)
            }
            .onAppear {
                Task { await store.bootstrap(apiBase: apiBase) }
            }
        }
    }

    private static func fmtTime(_ ts: Double) -> String {
        guard ts > 0 else { return "" }
        let d = Date(timeIntervalSince1970: ts)
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}

struct WeChatNewChatSheet: View {
    let apiBase: String
    @ObservedObject var store: WeChatStore
    @State private var peerId: String = ""

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("我的ID") {
                    Text(store.me?.user_id ?? "-")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("把你的 ID 发给对方，对方登录后用你的 ID 建立会话。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("新建聊天") {
                    TextField("对方 user_id", text: $peerId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("创建/打开会话") {
                        Task {
                            let id = peerId.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !id.isEmpty else { return }
                            _ = await store.createDirectConversation(peerId: id)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("新建聊天")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

struct WeChatConversationRowView: View {
    let title: String
    let subtitle: String
    let timeText: String

    var body: some View {
        HStack(spacing: 12) {
            // 微信式头像：圆角方块
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.gray.opacity(0.18))
                .frame(width: 44, height: 44)
                .overlay(
                    Text(String(title.prefix(1)))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.secondary)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(timeText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}

struct HumanChatRoomView: View {
    let apiBase: String
    @ObservedObject var store: WeChatStore
    let conv: WeChatConversationSummary

    @State private var draft: String = ""
    @State private var items: [WeChatMessageDTO] = []
    @State private var showingCall: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(items) { m in
                            HumanBubbleRow(
                                isMe: (m.sender_id == store.me?.user_id),
                                text: m.text
                            )
                            .id(m.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                }
                .onChange(of: items.count) { _, _ in
                    if let last = items.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 10) {
                TextField("发消息", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)

                Button {
                    Task {
                        let t = draft
                        draft = ""
                        if let sent = await store.sendMessage(conversationId: conv.id, text: t) {
                            items.append(sent)
                        }
                    }
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 18, weight: .semibold))
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(10)
        }
        .navigationTitle(conv.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingCall = true
                } label: {
                    Image(systemName: "video.fill")
                }
            }
        }
        .sheet(isPresented: $showingCall) {
            WeChatCallPlaceholderView(conv: conv)
        }
        .onAppear {
            Task {
                let ms = await store.fetchMessages(conversationId: conv.id)
                items = ms
                store.setActiveConversation(conv.id) { incoming in
                    items.append(incoming)
                }
            }
        }
        .onDisappear {
            store.setActiveConversation(nil, onIncoming: nil)
        }
    }
}

struct HumanBubbleRow: View {
    let isMe: Bool
    let text: String

    var body: some View {
        HStack(alignment: .top) {
            if isMe { Spacer(minLength: 8) }

            Text(text)
                .font(.system(size: 16))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(isMe ? Color.blue.opacity(0.14) : Color.gray.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: Color.black.opacity(0.04), radius: 1.2, x: 0, y: 1)
                .frame(maxWidth: 280, alignment: isMe ? .trailing : .leading)

            if !isMe { Spacer(minLength: 8) }
        }
    }
}

// MARK: - 视频通话占位（信令层在后端 /ws，媒体层可后续接 WebRTC）

struct WeChatCallPlaceholderView: View {
    let conv: WeChatConversationSummary
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "video.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(.secondary)

                Text("视频通话（占位）")
                    .font(.system(size: 18, weight: .semibold))

                Text("""
当前版本已具备：
- 微信式会话入口
- 人与人聊天（后端 /messages + /ws 推送）
- 通话信令通道（/ws 透传 call.* / webrtc.*）

下一步把 WebRTC PeerConnection 接到信令即可真正视频通话。
""")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Text("关闭")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.black.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: Color.black.opacity(0.04), radius: 1.2, x: 0, y: 1)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            .navigationTitle(conv.title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

























// =======================================================
// ✅ Conversation History Sheet (ChatGPT-style hamburger list)
// - Powered by backend: GET /conversations and GET /conversations/{id}/messages
// =======================================================

private struct ConversationSummaryDTO: Decodable, Identifiable {
    let id: String
    let title: String
    let updated_at: Double?
    let last_preview: String?
}

private struct ConversationsListResponse: Decodable {
    let ok: Bool
    let conversations: [ConversationSummaryDTO]
}

private struct ConversationMessagesResponse: Decodable {
    let ok: Bool
    let conversation_id: String
    let messages: [LLMMessage]
}

private struct ConversationHistorySheetView: View {
    let apiBase: String
    @Binding var currentConversationId: String?
    @Binding var messages: [ChatMessage]
    @Binding var pinnedUserId: UUID?
    @Binding var pinnedAssistantId: UUID?
    let onConversationLoaded: () -> Void
    let onDismiss: () -> Void
    @State private var items: [ConversationSummaryDTO] = []
    @State private var isLoading: Bool = false
    @State private var errorText: String? = nil
    @State private var query: String = ""

    var body: some View {
        NavigationStack {
            List {
                if isLoading {
                    Section { Text("收取中…").foregroundStyle(.secondary) }
                }
                if let e = errorText, !e.isEmpty {
                    Section { Text(e).foregroundStyle(.red) }
                }

                Section(header: Text("历史会话")) {
                    ForEach(filtered) { c in
                        Button {
                            Task { await openConversation(c.id) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(c.title).font(.system(size: 17, weight: .semibold))
                                Text(c.last_preview ?? "")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("会话")
            .searchable(text: $query, prompt: "搜索")
            .toolbar {                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") {
                        onDismiss()
                    }
                }
            }
            .onAppear {
                Task { await reload() }
            }
        }
    }

    private var filtered: [ConversationSummaryDTO] {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return items }
        let q = query.lowercased()
        return items.filter { $0.title.lowercased().contains(q) || ($0.last_preview ?? "").lowercased().contains(q) }
    }

    private func reload() async {
        await MainActor.run {
            isLoading = true
            errorText = nil
        }
        do {
            guard let url = URL(string: apiBase + "/conversations") else { throw URLError(.badURL) }
            var req = AccountManager.makeAuthorizedRequest(url)
            if let cid = UserDefaults.standard.string(forKey: "solara.client_id"), !cid.isEmpty {
                req.setValue(cid, forHTTPHeaderField: "X-Client-ID")
            }
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let t = String(data: data, encoding: .utf8) ?? ""
                throw NSError(domain: "conversations", code: (resp as? HTTPURLResponse)?.statusCode ?? -1,
                              userInfo: [NSLocalizedDescriptionKey: t])
            }
            let decoded = try JSONDecoder().decode(ConversationsListResponse.self, from: data)
            await MainActor.run {
                items = decoded.conversations
                isLoading = false
            }
        } catch {
            await MainActor.run {
                isLoading = false
                errorText = "加载失败：\(error.localizedDescription)"
            }
        }
    }

    private func createNewConversation() async {
        do {
            guard let url = URL(string: apiBase + "/conversations") else { throw URLError(.badURL) }
            var req = AccountManager.makeAuthorizedRequest(url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let cid = UserDefaults.standard.string(forKey: "solara.client_id"), !cid.isEmpty {
                req.setValue(cid, forHTTPHeaderField: "X-Client-ID")
            }
            req.httpBody = try JSONSerialization.data(withJSONObject: ["title": "新对话"], options: [])
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw NSError(domain: "conversations", code: (resp as? HTTPURLResponse)?.statusCode ?? -1,
                              userInfo: [NSLocalizedDescriptionKey: "create failed"])
            }
            await reload()
        } catch {
            await MainActor.run { errorText = "新建失败：\(error.localizedDescription)" }
        }
    }

    private func openConversation(_ id: String) async {
        do {
            guard let url = URL(string: apiBase + "/conversations/\(id)/messages") else { throw URLError(.badURL) }
            var req = AccountManager.makeAuthorizedRequest(url)
            if let cid = UserDefaults.standard.string(forKey: "solara.client_id"), !cid.isEmpty {
                req.setValue(cid, forHTTPHeaderField: "X-Client-ID")
            }
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let t = String(data: data, encoding: .utf8) ?? ""
                throw NSError(domain: "conversations", code: (resp as? HTTPURLResponse)?.statusCode ?? -1,
                              userInfo: [NSLocalizedDescriptionKey: t])
            }
            let decoded = try JSONDecoder().decode(ConversationMessagesResponse.self, from: data)

            await MainActor.run {
                currentConversationId = id
                // convert LLMMessage -> ChatMessage
                var ui: [ChatMessage] = []
                for m in decoded.messages {
                    let role: ChatMessage.Role = (m.role == "assistant") ? .assistant : ((m.role == "system") ? .system : .user)
                    ui.append(.init(role: role, text: m.content))
                }
                messages = ui

                // ✅ 打开历史会话后：自动把“最后一条用户消息”作为栏板下方的新主页面起点
                pinnedUserId = ui.last(where: { $0.role == .user })?.id

                // ✅ 可选：记录最后一轮的首条助手消息（目前 UI 不依赖，但保持状态一致）
                if let pid = pinnedUserId,
                   let idx = ui.firstIndex(where: { $0.id == pid }) {
                    let after = ui.suffix(from: min(ui.count, idx + 1))
                    pinnedAssistantId = after.first(where: { $0.role == .assistant })?.id
                } else {
                    pinnedAssistantId = nil
                }

                // ✅ 自动定位到当前轮（无需手动划找）
                onConversationLoaded()

                onDismiss()
            }
        } catch {
            await MainActor.run {
                errorText = "打开失败：\(error.localizedDescription)"
            }
        }
    }
}




// MARK: - HAQuickHomeEntryVM
/// Home 入口状态探测（仅用于 UI 的状态点显示）。
///
/// - 只做 HTTP 健康检查；不依赖 HomeKit / Home Assistant SDK。
/// - 优先探测 `/home/health`，不存在则自动 fallback 到 `/health`。
@MainActor
final class HAQuickHomeEntryVM: ObservableObject {

    enum Status {
        case unknown
        case checking
        case online
        case offline
    }

    @Published private(set) var status: Status = .unknown

    private var apiBase: String = ""
    private var checkTask: Task<Void, Never>?

    /// 传入当前后端 base（例如: "<BASE>"）。
    func configure(apiBase: String) {
        self.apiBase = Self.normalizeBase(apiBase)
    }

    /// 立即刷新状态（2 秒超时，失败即 offline）。
    func refresh() {
        checkTask?.cancel()
        guard !apiBase.isEmpty else {
            status = .unknown
            return
        }
        status = .checking

        let base = apiBase
        checkTask = Task {
            let ok = await Self.checkHealth(apiBase: base)
            await MainActor.run { [weak self] in
                self?.status = ok ? .online : .offline
            }
        }
    }

    deinit {
        checkTask?.cancel()
    }

    // MARK: - Internals

    private static func normalizeBase(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private static func checkHealth(apiBase: String) async -> Bool {
        let paths = ["/health"]
        for p in paths {
            guard let url = URL(string: apiBase + p) else { continue }
            if await ping(url) { return true }
        }
        return false
    }

    private static func ping(_ url: URL) async -> Bool {
        var req = AccountManager.makeAuthorizedRequest(url)
        req.httpMethod = "GET"
        req.timeoutInterval = 2.0
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse {
                return (200..<300).contains(http.statusCode)
            }
            return true
        } catch {
            return false
        }
    }

}


// MARK: - Local Agent Computer Debug Panel

private struct LocalAgentComputerDebugPanel: View {
    let backendBase: String
    @Binding var pendingInstruction: String
    @Binding var computerControlMode: Bool
    let onClose: () -> Void

    @StateObject private var vm = LocalAgentComputerDebugViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statusCard
                    screenshotCard
                    instructionCard
                    controlCard
                    logCard
                }
                .padding(16)
            }
            .background(Color(white: 0.96).ignoresSafeArea())
            .navigationTitle("电脑控制")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { onClose() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await vm.refreshAll() }
                    } label: {
                        if vm.isLoading {
                            ProgressView().scaleEffect(0.85)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(vm.isLoading)
                }
            }
            .onAppear {
                vm.configure(backendBase: backendBase)
                if !pendingInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    vm.setCommandInput(pendingInstruction)
                    pendingInstruction = ""
                }
                Task {
                    await vm.refreshAll()
                    vm.startAutoRefresh()
                }
            }
            .onDisappear {
                vm.stopAutoRefresh()
            }
            .onChange(of: pendingInstruction) { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                vm.setCommandInput(trimmed)
                pendingInstruction = ""
            }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("连接状态", systemImage: vm.isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(vm.isHealthy ? .green : .orange)
                Spacer()
                Text(vm.connectionText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
            }

            Text(vm.backendBaseDisplay)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)

            infoLine(title: "模式", value: computerControlMode ? "电脑控制模式已开启" : "电脑控制模式未开启")

            HStack(spacing: 10) {
                LocalAgentDebugButton(title: "配置", systemName: "gearshape") {
                    Task { await vm.fetchConfig() }
                }
                LocalAgentDebugButton(title: "健康", systemName: "heart.text.square") {
                    Task { await vm.fetchHealth() }
                }
                LocalAgentDebugButton(title: "鼠标", systemName: "cursorarrow.motionlines") {
                    Task { await vm.fetchMouse() }
                }
            }

            Text(vm.mouseText)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(.black.opacity(0.75))

            if !vm.lastInstruction.isEmpty {
                infoLine(title: "最近指令", value: vm.lastInstruction)
            }

            if !vm.lastResult.isEmpty {
                infoLine(title: "最近结果", value: vm.lastResult)
            }
        }
        .padding(16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.black.opacity(0.05), radius: 10, y: 4)
    }

    private var screenshotCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("电脑实时画面", systemImage: "display")
                    .font(.system(size: 17, weight: .bold))
                Spacer()
                Toggle("自动", isOn: $vm.autoRefreshEnabled)
                    .font(.system(size: 13, weight: .semibold))
                    .toggleStyle(.switch)
                    .fixedSize()
                    .onChange(of: vm.autoRefreshEnabled) { enabled in
                        if enabled {
                            vm.startAutoRefresh()
                        } else {
                            vm.stopAutoRefresh()
                        }
                    }
                Button {
                    Task { await vm.takeScreenshot() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.isLoading)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(0.06))
                    .frame(minHeight: 210)

                if let image = vm.screenshotImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.black.opacity(0.08), lineWidth: 1)
                        )
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "display.trianglebadge.exclamationmark")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundColor(.secondary)
                        Text("等待电脑画面")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 210)
                }
            }
        }
        .padding(16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.black.opacity(0.05), radius: 10, y: 4)
    }

    private var instructionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("电脑控制指令", systemImage: "paperplane")
                .font(.system(size: 17, weight: .bold))

            HStack(spacing: 6) {
                Circle()
                    .fill(vm.commandStatusColor)
                    .frame(width: 8, height: 8)
                Text(vm.commandStatusText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
            }

            TextField("例如：打开 Safari、点击、输入 hello、按回车", text: $vm.commandInput, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit {
                    Task { await vm.sendCurrentInstruction() }
                }

            HStack(spacing: 10) {
                Button {
                    Task { await vm.sendCurrentInstruction() }
                } label: {
                    Label(vm.commandRunning ? "发送中" : "发送", systemImage: "arrow.up.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.commandRunning || vm.commandInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    vm.commandInput = ""
                } label: {
                    Image(systemName: "xmark.circle")
                        .frame(width: 44, height: 34)
                }
                .buttonStyle(.bordered)
                .disabled(vm.commandRunning || vm.commandInput.isEmpty)
            }
        }
        .padding(16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.black.opacity(0.05), radius: 10, y: 4)
    }

    private func infoLine(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.black.opacity(0.75))
                .textSelection(.enabled)
                .lineLimit(6)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var controlCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("基础动作", systemImage: "keyboard")
                .font(.system(size: 17, weight: .bold))

            HStack(spacing: 10) {
                TextField("X", text: $vm.moveX)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                TextField("Y", text: $vm.moveY)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                Button("移动") {
                    Task { await vm.moveMouse() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.isLoading)
            }

            HStack(spacing: 10) {
                LocalAgentDebugButton(title: "左键", systemName: "cursorarrow.click") {
                    Task { await vm.click(button: "left") }
                }
                LocalAgentDebugButton(title: "右键", systemName: "contextualmenu.and.cursorarrow") {
                    Task { await vm.click(button: "right") }
                }
                LocalAgentDebugButton(title: "回车", systemName: "return") {
                    Task { await vm.press(key: "enter") }
                }
            }

            TextField("输入文字", text: $vm.typeText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)

            HStack(spacing: 10) {
                Button {
                    Task { await vm.typeCurrentText() }
                } label: {
                    Label("输入", systemImage: "text.cursor")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.isLoading || vm.typeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    Task { await vm.press(key: "escape") }
                } label: {
                    Label("Esc", systemImage: "escape")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(vm.isLoading)
            }

            Button {
                Task { await vm.press(keys: ["cmd", "space"]) }
            } label: {
                Label("Command + Space", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(vm.isLoading)
        }
        .padding(16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.black.opacity(0.05), radius: 10, y: 4)
    }

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("日志", systemImage: "doc.text.magnifyingglass")
                    .font(.system(size: 17, weight: .bold))
                Spacer()
                Button("清空") { vm.clearLog() }
                    .font(.system(size: 13, weight: .semibold))
            }

            Text(vm.logText.isEmpty ? "暂无日志" : vm.logText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.black.opacity(0.72))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.black.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.black.opacity(0.05), radius: 10, y: 4)
    }
}

private struct LocalAgentDebugButton: View {
    let title: String
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 17, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(.black.opacity(0.78))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color(white: 0.94))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

@MainActor
private final class LocalAgentComputerDebugViewModel: ObservableObject {
    @Published var isLoading: Bool = false
    @Published var isHealthy: Bool = false
    @Published var mouseText: String = "鼠标：未读取"
    @Published var screenshotImage: UIImage? = nil
    @Published var autoRefreshEnabled: Bool = true
    @Published var commandInput: String = ""
    @Published var commandRunning: Bool = false
    @Published var commandStatusText: String = "idle"
    @Published var commandStatusColor: Color = .gray
    @Published var lastInstruction: String = ""
    @Published var lastResult: String = ""
    @Published var moveX: String = "500"
    @Published var moveY: String = "500"
    @Published var typeText: String = "hello from iPhone"
    @Published var logText: String = ""

    private var backendBase: String = ""
    private var autoRefreshTask: Task<Void, Never>? = nil

    var backendBaseDisplay: String {
        let base = normalizedBase
        return base.isEmpty ? "后端地址为空" : base
    }

    var connectionText: String {
        if isLoading { return "请求中" }
        return isHealthy ? "已连接" : "待验证"
    }

    private var normalizedBase: String {
        backendBase.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    func configure(backendBase: String) {
        self.backendBase = backendBase
    }

    func setCommandInput(_ text: String) {
        commandInput = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func startAutoRefresh() {
        guard autoRefreshEnabled else { return }
        autoRefreshTask?.cancel()
        autoRefreshTask = Task { @MainActor in
            while !Task.isCancelled {
                await takeScreenshot(silent: true)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    func refreshAll() async {
        await fetchConfig()
        await fetchHealth()
        await fetchMouse()
    }

    func fetchConfig() async {
        await run("GET config") {
            let obj = try await self.requestJSON(path: "/config", method: "GET")
            self.appendLog("/config\n" + self.pretty(obj))
        }
    }

    func fetchHealth() async {
        await run("GET health") {
            let obj = try await self.requestJSON(path: "/health", method: "GET")
            if let dict = obj as? [String: Any] {
                self.isHealthy = (dict["ok"] as? Bool) ?? false
            }
            self.appendLog("/health\n" + self.pretty(obj))
        }
    }

    func fetchMouse() async {
        await run("GET mouse") {
            let obj = try await self.requestJSON(path: "/mouse", method: "GET")
            if let dict = obj as? [String: Any] {
                let xValue = self.intValue(dict["x"])
                let yValue = self.intValue(dict["y"])
                let x = xValue.map(String.init) ?? "?"
                let y = yValue.map(String.init) ?? "?"
                self.mouseText = "鼠标：x=\(x), y=\(y)"

                // ✅ click 接口必须带 x/y；读取鼠标后同步到点击坐标输入框。
                if let xValue = xValue { self.moveX = String(xValue) }
                if let yValue = yValue { self.moveY = String(yValue) }
            }
            self.appendLog("/mouse\n" + self.pretty(obj))
        }
    }

    func takeScreenshot(silent: Bool = false) async {
        await run("POST screenshot") {
            let obj = try await self.requestJSON(path: "/screenshot", method: "POST", body: [:])
            if let image = self.decodeScreenshotImage(from: obj) {
                self.screenshotImage = image
                self.lastResult = "截图已更新"
                if !silent {
                    self.appendLog("/screenshot\n截图已更新")
                }
            } else {
                let result = "未找到可解码图片字段"
                self.lastResult = result
                self.appendLog("/screenshot\n\(result)\n" + self.pretty(obj))
            }
        }
    }

    func sendCurrentInstruction() async {
        let text = commandInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        commandRunning = true
        commandStatusText = "sending"
        commandStatusColor = .orange
        lastInstruction = text
        lastResult = "执行中..."
        defer { commandRunning = false }

        do {
            let result = try await executeInstruction(text)
            commandStatusText = "success"
            commandStatusColor = .green
            lastResult = result
            appendLog("instruction: \(text)\n\(result)")
            await takeScreenshot(silent: true)
        } catch {
            commandStatusText = "failed"
            commandStatusColor = .red
            lastResult = error.localizedDescription
            appendLog("instruction: \(text)\n失败：\(error.localizedDescription)")
        }
    }

    private func executeInstruction(_ text: String) async throws -> String {
        if isScreenshotInstruction(text) {
            await takeScreenshot()
            return "截图已刷新"
        }

        guard let parsed = parseInstruction(text) else {
            throw NSError(
                domain: "LocalAgentDebug",
                code: -20,
                userInfo: [NSLocalizedDescriptionKey: "未识别指令。可用：打开 Safari、点击、右键、双击、移动到 500,500、输入 hello、粘贴 hello、按回车、按 Command Space。"]
            )
        }

        let obj = try await requestJSON(
            path: "/action",
            method: "POST",
            body: [
                "action": parsed.action,
                "payload": parsed.payload,
                "goal": text,
                "text": text
            ]
        )
        if let dict = obj as? [String: Any],
           let ok = dict["ok"] as? Bool,
           ok == false {
            let message = (dict["message"] as? String)
                ?? (dict["error"] as? String)
                ?? (dict["detail"] as? String)
                ?? "电脑动作执行失败"
            throw NSError(
                domain: "LocalAgentDebug",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        return summarizeActionResult(obj, fallback: parsed.message)
    }

    func moveMouse() async {
        let x = Int(moveX.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let y = Int(moveY.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        await run("POST move") {
            let obj = try await self.requestJSON(path: "/move", method: "POST", body: ["x": x, "y": y])
            self.lastInstruction = "移动到 \(x),\(y)"
            self.lastResult = self.pretty(obj)
            self.appendLog("/move x=\(x) y=\(y)\n" + self.pretty(obj))
            await self.fetchMouse()
            await self.takeScreenshot(silent: true)
        }
    }

    func click(button: String) async {
        let x = Int(moveX.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let y = Int(moveY.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        await run("POST click") {
            // ✅ local-agent 的 /click 要求 x/y，不能只传 button。
            let obj = try await self.requestJSON(
                path: "/click",
                method: "POST",
                body: ["x": x, "y": y, "button": button]
            )
            self.lastInstruction = button == "right" ? "右键点击" : "左键点击"
            self.lastResult = self.pretty(obj)
            self.appendLog("/click button=\(button) x=\(x) y=\(y)\n" + self.pretty(obj))
            await self.fetchMouse()
            await self.takeScreenshot(silent: true)
        }
    }

    func typeCurrentText() async {
        let text = typeText
        await run("POST type") {
            let obj = try await self.requestJSON(path: "/type", method: "POST", body: ["text": text])
            self.lastInstruction = "输入 \(text)"
            self.lastResult = self.pretty(obj)
            self.appendLog("/type\n" + self.pretty(obj))
            await self.takeScreenshot(silent: true)
        }
    }

    func press(key: String) async {
        await press(keys: [key])
    }

    func press(keys: [String]) async {
        let cleanKeys = keys
            .map { self.normalizedKeyName($0) }
            .filter { !$0.isEmpty }

        guard !cleanKeys.isEmpty else {
            appendLog("POST press 失败：keys 为空")
            return
        }

        if cleanKeys.count > 1 {
            await run("POST action press_keys") {
                // ✅ 组合键走统一 action 入口，后端会把 command/cmd/space 规范化，避免旧 local-agent 的 command,space 错误。
                let obj = try await self.requestJSON(
                    path: "/action",
                    method: "POST",
                    body: ["action": "press_keys", "payload": ["keys": cleanKeys]]
                )
                self.lastInstruction = "按 \(cleanKeys.joined(separator: "+"))"
                self.lastResult = self.pretty(obj)
                self.appendLog("/action press_keys=\(cleanKeys.joined(separator: "+"))\n" + self.pretty(obj))
                await self.takeScreenshot(silent: true)
            }
            return
        }

        await run("POST press") {
            // ✅ local-agent 的 /press 要求 {"keys":[...]}，不能再传 {"key":"enter"}。
            let obj = try await self.requestJSON(path: "/press", method: "POST", body: ["keys": cleanKeys])
            self.lastInstruction = "按 \(cleanKeys.joined(separator: "+"))"
            self.lastResult = self.pretty(obj)
            self.appendLog("/press keys=\(cleanKeys.joined(separator: "+"))\n" + self.pretty(obj))
            await self.takeScreenshot(silent: true)
        }
    }

    private struct ParsedInstruction {
        let action: String
        let payload: [String: Any]
        let message: String
    }

    private func parseInstruction(_ raw: String) -> ParsedInstruction? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        let compact = lower
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "，", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "。", with: "")
            .replacingOccurrences(of: "！", with: "")
            .replacingOccurrences(of: "!", with: "")

        if let app = extractAppToOpen(from: text) {
            return ParsedInstruction(action: "open_app", payload: ["app": app.query], message: "正在打开\(app.display)")
        }
        if lower.contains("mouse position") || text.contains("鼠标位置") || text.contains("鼠标在哪") {
            return ParsedInstruction(action: "mouse_position", payload: [:], message: "已读取鼠标位置")
        }
        if let coords = parseMoveCoords(from: text) {
            return ParsedInstruction(action: "mouse_move", payload: ["x": coords.0, "y": coords.1], message: "鼠标已移动到 \(coords.0),\(coords.1)")
        }
        if compact.contains("cmdspace") || compact.contains("commandspace") || compact.contains("cmd+space") || compact.contains("command+space") || lower.contains("spotlight") || text.contains("聚焦搜索") || text.contains("打开搜索") {
            return ParsedInstruction(action: "press_keys", payload: ["keys": ["cmd", "space"]], message: "已按 Command+Space")
        }
        if let keys = parseHotkeyKeys(from: text), !keys.isEmpty {
            return ParsedInstruction(action: "press_keys", payload: ["keys": keys], message: "已按 \(keys.joined(separator: "+"))")
        }
        if text.contains("回车") || lower.contains("enter") {
            return ParsedInstruction(action: "press_keys", payload: ["keys": ["enter"]], message: "已按回车")
        }
        if lower.contains("escape") || lower.contains("esc") || text.contains("退出键") {
            return ParsedInstruction(action: "press_keys", payload: ["keys": ["escape"]], message: "已按 Esc")
        }
        if text.contains("双击") || lower.contains("double click") {
            return ParsedInstruction(action: "double_click", payload: [:], message: "已双击")
        }
        if text.contains("右键") || lower.contains("right click") {
            return ParsedInstruction(action: "click", payload: ["button": "right"], message: "已右键点击")
        }
        if text.contains("左键") || text.contains("点击") || text.contains("点一下") || lower == "click" || lower.contains("left click") {
            return ParsedInstruction(action: "click", payload: ["button": "left"], message: "已左键点击")
        }
        if let value = extractTextToType(from: text) {
            return ParsedInstruction(action: "type_text", payload: ["text": value], message: "已输入：\(value)")
        }
        if let value = extractTextToPaste(from: text) {
            return ParsedInstruction(action: "paste_text", payload: ["text": value], message: "已粘贴：\(value)")
        }
        return nil
    }

    private func isScreenshotInstruction(_ text: String) -> Bool {
        let lower = text.lowercased()
        return text.contains("截图") || text.contains("截屏") || text.contains("显示电脑画面") || text.contains("刷新画面") || lower.contains("screenshot")
    }

    private func extractAppToOpen(from raw: String) -> (query: String, display: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let compact = lower.replacingOccurrences(of: " ", with: "")
        let hasOpenIntent = compact.contains("打开") || compact.contains("启动") || lower.hasPrefix("open ") || lower.hasPrefix("launch ")
        guard hasOpenIntent else { return nil }

        let aliases: [(keys: [String], query: String, display: String)] = [
            (["微信", "wechat"], "WeChat", "微信"),
            (["chrome", "谷歌浏览器"], "Google Chrome", "Chrome"),
            (["safari", "浏览器"], "Safari", "Safari"),
            (["终端", "terminal"], "Terminal", "终端"),
            (["xcode"], "Xcode", "Xcode"),
            (["备忘录", "notes"], "Notes", "备忘录"),
            (["访达", "finder"], "Finder", "访达"),
            (["设置", "系统设置"], "System Settings", "系统设置")
        ]
        for item in aliases where item.keys.contains(where: { compact.contains($0.lowercased().replacingOccurrences(of: " ", with: "")) }) {
            return (item.query, item.display)
        }

        for marker in ["打开", "启动", "运行"] {
            if let range = trimmed.range(of: marker) {
                let value = String(trimmed[range.upperBound...])
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "：:，,。.!！")))
                if !value.isEmpty { return (value, value) }
            }
        }
        if lower.hasPrefix("open ") {
            let value = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return (value, value) }
        }
        if lower.hasPrefix("launch ") {
            let value = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return (value, value) }
        }
        return nil
    }

    private func parseMoveCoords(from raw: String) -> (Int, Int)? {
        let pattern = #"(?:鼠标)?\s*(?:移动到|移到|移动至)\s*[\(\[（【]?\s*(\d+)\s*[,，、\s]+\s*(\d+)\s*[\)\]）】]?"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsRange = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let m = re.firstMatch(in: raw, options: [], range: nsRange),
              m.numberOfRanges >= 3,
              let r1 = Range(m.range(at: 1), in: raw),
              let r2 = Range(m.range(at: 2), in: raw),
              let x = Int(raw[r1]), let y = Int(raw[r2]) else { return nil }
        return (x, y)
    }

    private func parseHotkeyKeys(from raw: String) -> [String]? {
        let pattern = #"按\s*((?:cmd|ctrl|alt|shift|command|control|option|meta|⌘|⌃|⌥|⇧)(?:\s*[+\s,，、]\s*[A-Za-z0-9⌘⌃⌥⇧]+){1,3})"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let nsRange = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let m = re.firstMatch(in: raw, options: [], range: nsRange),
              m.numberOfRanges >= 2,
              let r = Range(m.range(at: 1), in: raw) else { return nil }
        let body = String(raw[r])
        let symMap: [String: String] = ["⌘": "cmd", "⌃": "ctrl", "⌥": "alt", "⇧": "shift"]
        let keys = body
            .split { $0 == "+" || $0 == " " || $0 == "," || $0 == "，" || $0 == "、" }
            .map { symMap[String($0)] ?? String($0).lowercased() }
            .map(normalizedKeyName)
            .filter { !$0.isEmpty }
        return keys.count >= 2 ? keys : nil
    }

    private func extractTextToType(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["输入文字", "输入文本", "输入一下", "帮我输入", "给我输入", "输入", "打字", "键入", "type text", "type"] {
            if trimmed.lowercased().hasPrefix(prefix.lowercased()) {
                let value = String(trimmed.dropFirst(prefix.count))
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "：:，,")))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    private func extractTextToPaste(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["粘贴", "paste"] {
            if trimmed.lowercased().hasPrefix(prefix.lowercased()) {
                let value = String(trimmed.dropFirst(prefix.count))
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "：:，,")))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    private func summarizeActionResult(_ obj: Any, fallback: String) -> String {
        if let dict = obj as? [String: Any] {
            if let result = dict["result"] as? [String: Any] {
                if let x = result["x"], let y = result["y"] {
                    return "鼠标位置：x=\(x), y=\(y)"
                }
                if let stdout = result["stdout"] as? String, !stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let message = result["message"] as? String, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return message.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            if let message = dict["message"] as? String, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return message.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let output = dict["output"] as? String, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return fallback + "\n" + pretty(obj)
    }

    private func normalizedKeyName(_ key: String) -> String {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch k {
        case "command", "cmd", "meta", "super", "⌘": return "cmd"
        case "control", "ctrl": return "ctrl"
        case "option", "opt", "alt": return "alt"
        case "return", "enter": return "enter"
        case "esc", "escape": return "escape"
        case "spacebar", "space", "空格": return "space"
        default: return k
        }
    }

    func clearLog() {
        logText = ""
    }

    private func run(_ name: String, operation: @escaping () async throws -> Void) async {
        guard !normalizedBase.isEmpty else {
            appendLog("\(name) 失败：后端地址为空")
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            try await operation()
        } catch {
            appendLog("\(name) 失败：\(error.localizedDescription)")
        }
    }

    private func intValue(_ value: Any?) -> Int? {
        if let intValue = value as? Int { return intValue }
        if let doubleValue = value as? Double { return Int(doubleValue) }
        if let number = value as? NSNumber { return number.intValue }
        if let stringValue = value as? String { return Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private func requestJSON(path: String, method: String, body: [String: Any]? = nil) async throws -> Any {
        guard let url = URL(string: normalizedBase + "/api/brain/computer" + path) else {
            throw NSError(domain: "LocalAgentDebug", code: -1, userInfo: [NSLocalizedDescriptionKey: "URL 无效"])
        }

        var req = AccountManager.makeAuthorizedRequest(url)
        req.httpMethod = method
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body = body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "LocalAgentDebug", code: code, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code) \(text)"])
        }

        if data.isEmpty { return ["ok": true] }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func decodeScreenshotImage(from obj: Any) -> UIImage? {
        guard let b64 = findBase64ImageString(in: obj) else { return nil }
        let clean: String
        if let comma = b64.range(of: ",") {
            clean = String(b64[comma.upperBound...])
        } else {
            clean = b64
        }
        guard let data = Data(base64Encoded: clean, options: [.ignoreUnknownCharacters]) else { return nil }
        return UIImage(data: data)
    }

    private func findBase64ImageString(in obj: Any) -> String? {
        if let str = obj as? String {
            let s = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.hasPrefix("data:image") || s.count > 1000 {
                return s
            }
            return nil
        }

        if let dict = obj as? [String: Any] {
            let priorityKeys = ["image_base64", "screenshot_base64", "png_base64", "jpeg_base64", "jpg_base64", "base64", "screenshot", "image", "data"]
            for key in priorityKeys {
                if let value = dict[key], let found = findBase64ImageString(in: value) {
                    return found
                }
            }
            for (_, value) in dict {
                if let found = findBase64ImageString(in: value) { return found }
            }
        }

        if let arr = obj as? [Any] {
            for value in arr {
                if let found = findBase64ImageString(in: value) { return found }
            }
        }

        return nil
    }

    private func pretty(_ obj: Any) -> String {
        if JSONSerialization.isValidJSONObject(obj),
           let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]),
           let text = String(data: data, encoding: .utf8) {
            return String(text.prefix(2500))
        }
        return String(String(describing: obj).prefix(2500))
    }

    private func appendLog(_ text: String) {
        let stamp = Self.timeFormatter.string(from: Date())
        let next = "[\(stamp)] \(text)\n\n" + logText
        logText = String(next.prefix(8000))
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

// MARK: - Plan Picker Detents helper (fix compile error)
private extension View {
    @ViewBuilder
    func applyPlanPickerDetentsIfAvailable() -> some View {
        if #available(iOS 16.0, *) {
            self
                .presentationDetents([.height(360), .medium])
                .presentationDragIndicator(.visible)
        } else {
            self
        }
    }
}























































// ════════════════════════════════════════════════════════════════════════════
// MARK: - Account System (V2)
//
// 完整账号系统：注册 / 登录 / 退出 + 账号中心
// 后端接口：
//   POST /v2/auth/register  { username, password, display_name } -> { access_token, user }
//   POST /v2/auth/login     { username, password }               -> { access_token, user }
//   POST /v2/auth/logout    Bearer token                         -> { ok: true }
//   GET  /v2/auth/me        Bearer token                         -> { user, followers, following }
//
// 入口：右上角头像按钮（HomeChatView 顶部工具栏）
//   - 单击 → AccountGateView（未登录 LoginView，已登录 AccountCenterView）
//   - 长按 → 菜单（账号 / 历史 / 返回太阳系）
//
// 持久化：UserDefaults
//   - chatagi.access_token  (String)
//   - chatagi.user_json     (Data, JSON-encoded AccountUser)
//
// 与现有系统的衔接：
//   - 登录后所有 /chat /chat/prepare 等请求会自动带 Bearer 头
//   - 后端 _derive_user_key 优先用 token.sub 作为 user_key（账号驱动记忆/历史）
// ════════════════════════════════════════════════════════════════════════════

struct AccountUser: Codable, Equatable {
    let user_id: String
    let username: String
    let display_name: String
    let avatar_url: String?
    let created_at: Int?
    let email: String?

    var initial: String {
        let s = display_name.trimmingCharacters(in: .whitespaces)
        if s.isEmpty {
            return username.first.map { String($0).uppercased() } ?? "?"
        }
        return String(s.prefix(1)).uppercased()
    }
}

@MainActor
final class AccountManager: ObservableObject {
    static let shared = AccountManager()

    @Published private(set) var user: AccountUser? = nil
    @Published private(set) var token: String? = nil
    @Published private(set) var isLoading: Bool = false

    private let kToken = "chatagi.access_token"
    private let kUser  = "chatagi.user_json"

    var isSignedIn: Bool { token != nil && user != nil }

    private init() {
        // 启动时从本地恢复
        if let t = UserDefaults.standard.string(forKey: kToken), !t.isEmpty {
            self.token = t
        }
        if let data = UserDefaults.standard.data(forKey: kUser),
           let u = try? JSONDecoder().decode(AccountUser.self, from: data) {
            self.user = u
        }
    }

    // ✅ 给所有请求生成统一 header（HomeChatView 中其他请求可调用此方法）
    func authHeaders() -> [String: String] {
        guard let t = token, !t.isEmpty else { return [:] }
        return ["Authorization": "Bearer \(t)"]
    }

    /// ✅ 统一的请求构造器：自动挂 Bearer token（如果已登录）。
    /// 现有 `var req = URLRequest(url: url)` 全部替换成
    /// `var req = AccountManager.makeAuthorizedRequest(url)` 即可。
    /// 没登录时行为和裸 URLRequest 一致，不会变更糟。
    static func makeAuthorizedRequest(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        for (k, v) in AccountManager.shared.authHeaders() {
            req.setValue(v, forHTTPHeaderField: k)
        }
        return req
    }

    /// ✅ 设备数据迁移：登录成功后立即调用一次。
    /// 把当前设备 client_id 名下的会话/记忆迁移到登录账号。
    /// 后端会做严格校验：只迁一次、目标空账号、绑定唯一性。
    /// 失败不抛异常，只静默失败（不影响登录流程）。
    func migrateDeviceData(apiBase: String, clientId: String) async {
        guard !clientId.isEmpty, token != nil else { return }
        guard let url = URL(string: apiBase + "/v2/auth/migrate_device") else { return }
        var req = AccountManager.makeAuthorizedRequest(url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: ["client_id": clientId])
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if (200..<300).contains(code) {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let migrated = json["migrated"] as? Bool, migrated,
                   let stats = json["stats"] as? [String: Any] {
                    print("[migrate_device] ✅ migrated: \(stats)")
                } else {
                    print("[migrate_device] no migration: \(String(data: data, encoding: .utf8) ?? "")")
                }
            } else {
                print("[migrate_device] code=\(code) body=\(String(data: data, encoding: .utf8) ?? "")")
            }
        } catch {
            print("[migrate_device] error: \(error)")
        }
    }

    // MARK: - 网络

    private struct AuthResponse: Decodable {
        let ok: Bool
        let access_token: String?
        let token_type: String?
        let user: AccountUser?
    }

    private struct MeResponse: Decodable {
        let ok: Bool
        let user: AccountUser?
        let followers: Int?
        let following: Int?
    }

    enum AccountError: LocalizedError {
        case network(String)
        case server(Int, String)
        case decode

        var errorDescription: String? {
            switch self {
            case .network(let s): return "网络错误：\(s)"
            case .server(_, let body):
                if body.isEmpty { return "服务器错误" }
                return body
            case .decode: return "返回数据解析失败"
            }
        }
    }

    private func parseError(_ data: Data, _ code: Int) -> AccountError {
        struct ErrShape: Decodable { let detail: String?; let error: String?; let message: String? }
        if let e = try? JSONDecoder().decode(ErrShape.self, from: data) {
            let msg = e.detail ?? e.message ?? e.error ?? ""
            return .server(code, msg)
        }
        let s = String(data: data, encoding: .utf8) ?? ""
        return .server(code, s)
    }

    func register(apiBase: String, username: String, password: String, displayName: String) async throws -> AccountUser {
        try await postAuth(apiBase: apiBase, path: "/v2/auth/register", body: [
            "username": username,
            "password": password,
            "display_name": displayName
        ])
    }

    func login(apiBase: String, username: String, password: String) async throws -> AccountUser {
        try await postAuth(apiBase: apiBase, path: "/v2/auth/login", body: [
            "username": username,
            "password": password
        ])
    }

    /// ✅ Sign in with Apple
    /// iOS 端 ASAuthorizationAppleIDCredential 拿到 identityToken 后调本方法。
    /// fullName 仅在用户首次授权时由 Apple 返回，后端只在新建账号时落库。
    func signInWithApple(apiBase: String,
                         identityToken: String,
                         fullName: String?,
                         email: String?) async throws -> AccountUser {
        var body: [String: Any] = ["identity_token": identityToken]
        if let n = fullName?.trimmingCharacters(in: .whitespaces), !n.isEmpty {
            body["full_name"] = n
        }
        if let e = email?.trimmingCharacters(in: .whitespaces), !e.isEmpty {
            body["email_hint"] = e
        }
        return try await postAuth(apiBase: apiBase, path: "/v2/auth/apple", body: body)
    }

    @discardableResult
    private func postAuth(apiBase: String, path: String, body: [String: Any]) async throws -> AccountUser {
        guard let url = URL(string: apiBase + path) else { throw AccountError.network("invalid url") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        await setLoading(true)
        defer { Task { @MainActor in self.isLoading = false } }

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw AccountError.network(error.localizedDescription)
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else { throw parseError(data, code) }

        guard let r = try? JSONDecoder().decode(AuthResponse.self, from: data),
              r.ok, let tok = r.access_token, let u = r.user else {
            throw AccountError.decode
        }

        await applyAuth(token: tok, user: u)

        // ✅ 登录成功后异步触发设备数据迁移（不阻塞登录流程）
        // 后端会做严格校验：已迁过 / 目标非空 / 绑定唯一 → 都会安全跳过
        if let cid = UserDefaults.standard.string(forKey: "solara.client_id"), !cid.isEmpty {
            Task.detached { [weak self] in
                await self?.migrateDeviceData(apiBase: apiBase, clientId: cid)
            }
        }

        return u
    }

    func logout(apiBase: String) async {
        // 先记下原 token，本地立刻清空保证 UI 即时切换
        let oldToken = self.token
        await applyAuth(token: nil, user: nil)

        // 后端 best-effort 撤销，不阻塞 UI
        guard let tok = oldToken,
              let url = URL(string: apiBase + "/v2/auth/logout") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 8
        _ = try? await URLSession.shared.data(for: req)
    }

    /// 启动 / 进面板时拉一次 me，token 失效就清空。
    func refresh(apiBase: String) async {
        guard let tok = token, !tok.isEmpty,
              let url = URL(string: apiBase + "/v2/auth/me") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 12
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if code == 401 || code == 403 {
                await applyAuth(token: nil, user: nil)
                return
            }
            guard (200..<300).contains(code),
                  let r = try? JSONDecoder().decode(MeResponse.self, from: data),
                  r.ok, let u = r.user else { return }
            await MainActor.run { self.user = u }
            if let data = try? JSONEncoder().encode(u) {
                UserDefaults.standard.set(data, forKey: kUser)
            }
        } catch {
            // 忽略；可能只是网络抖动
        }
    }

    // MARK: - 私有

    @MainActor
    private func setLoading(_ v: Bool) async { self.isLoading = v }

    @MainActor
    private func applyAuth(token: String?, user: AccountUser?) async {
        self.token = token
        self.user = user
        if let t = token, !t.isEmpty {
            UserDefaults.standard.set(t, forKey: kToken)
        } else {
            UserDefaults.standard.removeObject(forKey: kToken)
        }
        if let u = user, let data = try? JSONEncoder().encode(u) {
            UserDefaults.standard.set(data, forKey: kUser)
        } else {
            UserDefaults.standard.removeObject(forKey: kUser)
        }
    }
}

// MARK: - 头像徽章（用在右上角入口）

struct AccountAvatarBadge: View {
    @ObservedObject private var account = AccountManager.shared

    var body: some View {
        ZStack {
            Circle()
                .fill(account.isSignedIn ? gradientFill() : LinearGradient(
                    colors: [Color(white: 0.92), Color(white: 0.86)],
                    startPoint: .top, endPoint: .bottom
                ))
                .overlay(
                    Circle().stroke(Color.black.opacity(0.06), lineWidth: 0.5)
                )

            if let u = account.user {
                Text(u.initial)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.15), radius: 0.5, x: 0, y: 0.5)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.gray.opacity(0.75))
            }
        }
        .accessibilityLabel(account.isSignedIn ? "账号中心" : "登录")
    }

    private func gradientFill() -> LinearGradient {
        // 用户名首字母确定色相，每个账号视觉稳定
        let seed = account.user?.username ?? "x"
        let hue = Double(abs(seed.hashValue) % 360) / 360.0
        return LinearGradient(
            colors: [
                Color(hue: hue, saturation: 0.55, brightness: 0.95),
                Color(hue: hue, saturation: 0.70, brightness: 0.78)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - 入口分发：未登录 -> Login，已登录 -> AccountCenter

struct AccountGateView: View {
    let apiBase: String
    @EnvironmentObject private var account: AccountManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if account.isSignedIn {
                    AccountCenterView(apiBase: apiBase)
                } else {
                    AccountLoginView(apiBase: apiBase)
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .task {
            await account.refresh(apiBase: apiBase)
        }
    }
}

// MARK: - 登录 / 注册

struct AccountLoginView: View {
    let apiBase: String
    @EnvironmentObject private var account: AccountManager

    @State private var errorText: String? = nil
    @State private var busy: Bool = false
    @State private var currentNonce: String? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Logo / 标题
                VStack(spacing: 10) {
                    Image(systemName: "sparkles.rectangle.stack.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(
                            LinearGradient(colors: [.purple, .blue],
                                           startPoint: .topLeading,
                                           endPoint: .bottomTrailing)
                        )
                    Text("登录 ChatAGI")
                        .font(.system(size: 26, weight: .bold))
                    Text("用 Apple 账号一键登录,记忆与历史会跨设备同步。")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .padding(.top, 36)
                .padding(.bottom, 8)

                // Sign in with Apple 按钮
                SignInWithAppleButton(
                    .signIn,
                    onRequest: { request in
                        let nonce = AccountLoginView.randomNonceString()
                        currentNonce = nonce
                        request.requestedScopes = [.fullName, .email]
                        request.nonce = AccountLoginView.sha256(nonce)
                    },
                    onCompletion: { result in
                        Task { await handleAppleResult(result) }
                    }
                )
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 24)
                .opacity(busy ? 0.5 : 1.0)
                .disabled(busy)

                if busy {
                    ProgressView()
                        .padding(.top, 4)
                }

                if let err = errorText {
                    Text(err)
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                Spacer(minLength: 12)

                // 隐私说明（合规要求 + 大厂常见做法）
                Text("我们仅获取您的姓名和邮箱用于创建账号,不会向第三方共享。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)
            }
        }
        .navigationTitle("登录")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    // MARK: - Apple 回调处理

    @MainActor
    private func handleAppleResult(_ result: Result<ASAuthorization, Error>) async {
        errorText = nil
        switch result {
        case .failure(let error):
            // 用户取消不算错误
            if let asErr = error as? ASAuthorizationError, asErr.code == .canceled {
                return
            }
            errorText = "Apple 登录失败:\(error.localizedDescription)"
            return

        case .success(let auth):
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = cred.identityToken,
                  let tokenStr = String(data: tokenData, encoding: .utf8),
                  !tokenStr.isEmpty else {
                errorText = "未获取到 Apple identity token"
                return
            }

            // Apple 仅在首次授权返回 fullName，注意拼接顺序
            var fullName: String? = nil
            if let pn = cred.fullName {
                let parts = [pn.familyName, pn.givenName].compactMap { $0 }.filter { !$0.isEmpty }
                if !parts.isEmpty {
                    fullName = parts.joined(separator: " ")
                }
            }
            let email = cred.email

            busy = true
            defer { Task { @MainActor in busy = false } }

            do {
                _ = try await account.signInWithApple(
                    apiBase: apiBase,
                    identityToken: tokenStr,
                    fullName: fullName,
                    email: email
                )
                HomeHaptics.light()
            } catch let e as AccountManager.AccountError {
                errorText = e.errorDescription
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    // MARK: - Nonce 工具（防重放）

    static func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remainingLength = length
        while remainingLength > 0 {
            let randoms: [UInt8] = (0..<16).map { _ in
                var random: UInt8 = 0
                let errorCode = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
                if errorCode != errSecSuccess {
                    fatalError("Unable to generate nonce. SecRandomCopyBytes failed with OSStatus \(errorCode)")
                }
                return random
            }
            randoms.forEach { random in
                if remainingLength == 0 { return }
                if random < charset.count {
                    result.append(charset[Int(random)])
                    remainingLength -= 1
                }
            }
        }
        return result
    }

    static func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashed = SHA256.hash(data: inputData)
        let hashString = hashed.compactMap { String(format: "%02x", $0) }.joined()
        return hashString
    }
}

// MARK: - 账号中心

struct AccountCenterView: View {
    let apiBase: String
    @EnvironmentObject private var account: AccountManager
    @ObservedObject private var iap = IAPManager.shared

    @State private var showLogoutConfirm = false
    @State private var restoreToast: String? = nil   // 恢复购买结果提示
    @State private var restoring: Bool = false

    var body: some View {
        List {
            // ─── 顶部用户卡片 ─────────────────────
            Section {
                HStack(spacing: 14) {
                    AccountAvatarBadge()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(account.user?.display_name ?? "—")
                            .font(.system(size: 18, weight: .semibold))
                        if let email = account.user?.email, !email.isEmpty {
                            Text(email)
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        } else {
                            Text("@" + (account.user?.username ?? ""))
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
            }

            // ─── 帐户 ─────────────────────
            Section("帐户") {
                if let email = account.user?.email, !email.isEmpty {
                    settingsRow(icon: "envelope", iconColor: .blue,
                                title: "电子邮件", trailing: email, monospaced: false)
                }

                // ✅ 订阅：已订阅时只读显示；未订阅时点击进付费墙
                Button {
                    if !hasProEntitlement {
                        HomeHaptics.light()
                        NotificationCenter.default.post(
                            name: .openPaywall,
                            object: nil,
                            userInfo: ["reason": "generic"]
                        )
                    }
                } label: {
                    settingsRow(icon: "checkmark.seal.fill",
                                iconColor: hasProEntitlement ? .green : .gray,
                                title: "订阅",
                                trailing: hasProEntitlement ? "Adu Robot 8.0" : "免费版",
                                chevron: !hasProEntitlement)
                }
                .buttonStyle(.plain)
                .disabled(hasProEntitlement)

                // ✅ 升级：已订阅时隐藏；未订阅时点击进付费墙
                if !hasProEntitlement {
                    Button {
                        HomeHaptics.light()
                        NotificationCenter.default.post(
                            name: .openPaywall,
                            object: nil,
                            userInfo: ["reason": "generic"]
                        )
                    } label: {
                        settingsRow(icon: "sparkles", iconColor: .purple,
                                    title: "升级到 Adu Robot 8.0",
                                    trailing: "$4.99/week",
                                    chevron: true)
                    }
                    .buttonStyle(.plain)
                }

                // ✅ 恢复购买：直接调 StoreKit
                Button {
                    Task { await restorePurchases() }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.clockwise.circle")
                            .foregroundColor(.blue)
                            .frame(width: 24)
                        Text("恢复购买")
                            .foregroundColor(.primary)
                        Spacer()
                        if restoring {
                            ProgressView().scaleEffect(0.8)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(restoring)
            }

            // ─── 退出登录 ─────────────────────
            Section {
                Button(role: .destructive) {
                    showLogoutConfirm = true
                } label: {
                    HStack {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                        Text("退出登录")
                    }
                }
            }

            // ─── 账号信息（折叠：默认收起，需要时展开看 ID/注册时间）─────────────────────
            Section {
                DisclosureGroup {
                    infoRow(label: "用户 ID", value: account.user?.user_id ?? "—", monospaced: true)
                    if let ts = account.user?.created_at, ts > 0 {
                        let date = Date(timeIntervalSince1970: TimeInterval(ts))
                        infoRow(label: "注册时间", value: formatDate(date))
                    }
                    if let cid = UserDefaults.standard.string(forKey: "solara.client_id"), !cid.isEmpty {
                        infoRow(label: "设备 ID", value: cid, monospaced: true)
                    }
                } label: {
                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundColor(.gray)
                            .frame(width: 24)
                        Text("账号信息")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("退出后将无法跨设备同步,确定吗?",
                            isPresented: $showLogoutConfirm,
                            titleVisibility: .visible) {
            Button("退出登录", role: .destructive) {
                Task { await account.logout(apiBase: apiBase) }
            }
            Button("取消", role: .cancel) { }
        }
        .alert("恢复购买", isPresented: Binding(
            get: { restoreToast != nil },
            set: { if !$0 { restoreToast = nil } }
        )) {
            Button("好") { restoreToast = nil }
        } message: {
            Text(restoreToast ?? "")
        }
        .refreshable {
            await account.refresh(apiBase: apiBase)
        }
    }

    private var hasProEntitlement: Bool {
        // 与 HomeChatView 顶部使用同一判定（StoreKit 入口在 HomeChatView 里维护）
        UserDefaults.standard.bool(forKey: "chatagi.has_pro_entitlement")
            || iap.hasActiveSubscription
    }

    // ✅ 恢复购买：调 StoreKit2 同步当前 Apple ID 的订阅状态
    @MainActor
    private func restorePurchases() async {
        guard !restoring else { return }
        restoring = true
        defer { restoring = false }

        let beforeActive = iap.hasActiveSubscription
        await iap.restore()
        let afterActive = iap.hasActiveSubscription

        if afterActive {
            restoreToast = beforeActive
                ? "您的 Adu Robot 8.0 订阅已经激活。"
                : "✅ 已恢复 Adu Robot 8.0 订阅。"
        } else if let err = iap.lastError, !err.isEmpty {
            // IAPManager 报了具体原因(如未登录/同步失败),优先展示
            restoreToast = err
        } else {
            restoreToast = "未找到可恢复的订阅。如果您之前在其他设备购买过,请确认登录的是同一个 Apple ID。"
        }
    }

    // 大厂风格行：左图标 + 标题 + (可选)右值 + (可选)雪佛龙
    private func settingsRow(icon: String,
                             iconColor: Color = .gray,
                             title: String,
                             trailing: String? = nil,
                             chevron: Bool = false,
                             monospaced: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(iconColor)
                .frame(width: 24)
            Text(title)
                .foregroundColor(.primary)
            Spacer()
            if let t = trailing {
                Text(t)
                    .font(monospaced ? .system(size: 13, design: .monospaced) : .system(size: 14))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.5))
            }
        }
        .contentShape(Rectangle())   // ✅ 让整行（含 Spacer）都可点
    }

    private func infoRow(label: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .font(monospaced
                      ? .system(size: 13, design: .monospaced)
                      : .system(size: 14))
                .textSelection(.enabled)
        }
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}




// ════════════════════════════════════════════════════════════════════════════
// MARK: - Account ↔ Paywall 通知桥接
//
// AccountCenterView 是 top-level struct，无法直接调用 HomeChatView 内部的
// showProPaywall(reason:) 方法。用 NotificationCenter 解耦：
//   - AccountCenterView 点"订阅 / 升级"按钮 → post .openPaywall
//   - HomeChatView onReceive(.openPaywall) → 弹付费墙
// ════════════════════════════════════════════════════════════════════════════

extension Notification.Name {
    /// AccountCenterView -> HomeChatView：请求显示付费墙（升级订阅）
    static let openPaywall = Notification.Name("chatagi.openPaywall")
}
