// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-a659bd19c9da7d6455b7219cb9321f2e5b0d2592935cb0f90565297be251d2c9"
// Source-SHA256: "7834c1800f98ad809f0cefe1be3ce4a55f7f118e942fa20cbd5a4a6d255bb259"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI
import UIKit
import Speech
import AVFoundation

// MARK: - 电脑控制主页
// 上半:Mac 屏幕截图(POST /api/brain/computer/action {action: "screenshot"} → 取
//      result.image_b64 解码)
// 下半:主页同款输入栏(左 +、中间 TextField+小麦克风、右黑色波纹键)
// 行为:
//   - 打开时自动拉一次截图
//   - 用户在输入框写"打开 Safari" / "输入 hello" / "按回车"
//   - 发送 → POST /api/brain/computer/action {goal: text}
//   - 成功后自动刷新一次截图
//   - 失败显示 message / error,不刷新截图
//   - 空输入不发送
// 注:本视图刻意保持最小可用,不引入 RealtimeAVService / 录音等主页里的高耦合组件。

struct ComputerControlHomeView: View {
    let apiBase: String
    var onClose: () -> Void
    var voiceStatus: ComputerControlVoiceStatus = ComputerControlVoiceStatus()
    var onStartVoiceControl: () -> Void = {}
    var onStopVoiceControl: () -> Void = {}
    var onCancelVoiceExecution: () -> Void = {}
    // ✅ V2 统一上下文:由 HomeChatView 创建,这里以 @ObservedObject 持有。
    @ObservedObject var aduContext: AduContextStore

    @State private var inputText: String = ""
    @State private var isSending: Bool = false
    @State private var isRefreshingShot: Bool = false
    @State private var screenshotImage: UIImage? = nil
    @State private var lastShotAt: Date? = nil
    @State private var statusMessage: String = ""
    @State private var statusIsError: Bool = false
    @State private var screenshotVersion: Int = 0       // 每次截图成功 +1;Image .id() 用它强制重绘,避免 SwiftUI 复用同一帧
    @State private var autoRefreshEnabled: Bool = true  // "实时刷新" 开关,默认开
    // ✅ 电脑控制页默认只做电脑控制：自动化编程(Codex)卡片默认隐藏，
    //    只有 planner 判定为 codex_task / 用户生成 Codex 任务后才置 true 显示。
    //    这样进入电脑控制页不会默认探测 / 显示 Codex。
    @State private var showCodingPanel: Bool = false
    @State private var pollingTask: Task<Void, Never>? = nil
    @State private var lastShotFailed: Bool = false
    @State private var lastPlan: AduTaskPlan? = nil
    @State private var codexProject: EngineeringAgentPanel.ProjectChoice = .gptsora
    @State private var codexTaskText: String =
        "只读扫描当前工程结构，不改文件，并总结入口文件和构建方式。"
    @State private var pendingCodexExists: Bool = false
    @State private var pendingCodexProject: String? = nil
    @State private var pendingCodexPrompt: String = ""
    @State private var pendingCodexSummary: String = ""
    @State private var pendingCodexRiskLevel: String = "medium"
    @State private var pendingCodexCreatedAt: Date? = nil
    // ─── V3 self-upgrade plan 卡片状态 ────────────────────────────
    // selfUpgradePlan != nil 时,在 plannerCard 与 internalTaskBar 之间渲染一张"阿杜自我升级计划卡"。
    // 用户点"生成 Codex 任务"会把选中的 recommended_upgrade.codex_prompt 灌入下方
    // EngineeringAgentPanel 的 codexTaskText,**但不自动 Run Codex**。
    @State private var selfUpgradePlan: AduSelfUpgradePlan? = nil
    @State private var selfUpgradeLoading: Bool = false
    @State private var selfUpgradeExpanded: Bool = false
    @State private var selfUpgradeExpandedIds: Set<String> = []     // 哪几条 upgrade 展开了 codex_prompt
    @State private var selfUpgradeError: String? = nil
    // ✅ V3.1:用户点"生成 Codex 任务"后,把这个 id 设成 EngineeringAgentPanel 的 anchor,
    //    ScrollViewReader 的 .onChange 监听这个值,触发 proxy.scrollTo + 立刻清空。
    @State private var scrollTargetID: String? = nil
    private let engineeringAgentPanelAnchor = "engineering_agent_panel"

    // ─── 复用 HomeChatView 的 + / 小麦克能力 ───────────────────────────
    // ChatPlusManager(拍照 / 相册 / 文件)和 AudioNoteRecorder(录音)直接从主页同款组件来。
    // 语音转文字走本机 SFSpeechRecognizer(zh-CN),不打后端;最终文本先进入 AduTaskPlanner。
    @StateObject private var plus = ChatPlusManager()
    @StateObject private var audioNote = AudioNoteRecorder()
    @State private var recordingStartedAt: Date? = nil
    @State private var recordingTick: Int = 0          // 让录音 UI 每秒刷新一次
    @State private var recordingTickerTask: Task<Void, Never>? = nil
    @State private var isTranscribing: Bool = false

    @FocusState private var focused: Bool

    private let uiGray = Color(red: 240/255, green: 240/255, blue: 240/255)
    private let pollingIntervalNs: UInt64 = 1_500_000_000   // 1.5 秒

    var body: some View {
        // ⚠️ V2:本视图现在作为 HomeChatView 上半部分嵌入,不再是独立全屏页。
        //    - 屏幕底部的"主输入栏"由 HomeChatView 提供(普通聊天 + 语音 + 图片 + 文件)。
        //    - 这里只保留"内部任务栏"用于电脑控制专用任务,放在滚动内容里(不再贴屏幕底)。
        VStack(spacing: 0) {
            topBar
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 12) {
                        realtimeVoiceControlCard
                        screenArea
                            .frame(maxWidth: .infinity, minHeight: 280, maxHeight: 480)
                        recentStatusCard           // ✅ V2 最近状态卡(读 aduContext)
                        plannerCard
                        selfUpgradeFollowupCards
                        internalTaskBar
                        // ✅ V3 自我升级计划卡 —— 仅在 planner 返回 self_upgrade_task 后出现。
                        //    放在 EngineeringAgentPanel 上方,让用户点"生成 Codex 任务"后
                        //    马上看到下面的自动化编程框被填好。
                        if selfUpgradeLoading || selfUpgradePlan != nil || selfUpgradeError != nil {
                            selfUpgradePlanCard
                        }
                        // ✅ 自动化编程(Codex)已移出电脑控制页默认区域，改为独立“工程模式”页面
                        //    （.sheet，仅 showCodingPanel=true 时弹出）。
                        //    电脑控制页默认只做电脑控制，不混入 Codex，也不触发 codex health 探测。
                        Color.clear.frame(height: 4)
                    }
                    .padding(.vertical, 8)
                }
                .background(Color.white)
                .onChange(of: scrollTargetID) { newValue in
                    // 用户点"生成 Codex 任务"后,scrollTargetID 被设成 anchor 字符串。
                    // 这里触发动画滚动到 EngineeringAgentPanel,然后立刻清空,允许下次再触发。
                    if let target = newValue, !target.isEmpty {
                        withAnimation(.easeInOut(duration: 0.32)) {
                            proxy.scrollTo(target, anchor: .top)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            if scrollTargetID == target { scrollTargetID = nil }
                        }
                    }
                }
            }
        }
        .background(Color.white)
        .onAppear {
            refreshScreenshot()
            startPolling()
        }
        .onDisappear {
            stopPolling()
            // 离开页面如果还在录音/转写,统一收尾,不留尾巴
            if audioNote.isRecording { cancelVoiceRecording() }
            stopRecordingTicker()
        }
        .onChange(of: autoRefreshEnabled) { newValue in
            if newValue {
                refreshScreenshot()
                startPolling()
            } else {
                stopPolling()
            }
        }
        // V2.2:HomeChatView 主输入栏识别到自我升级触发短语后,会把 goal 投递到
        // aduContext.pendingSelfUpgradeGoal,并切 surfaceMode=.computer。这里消费一次:
        // 调 runSelfUpgradePlan(surface:"home_chat"),立刻清空 store 字段。
        .onChange(of: aduContext.pendingSelfUpgradeGoal) { newGoal in
            guard let goal = newGoal, !goal.isEmpty else { return }
            aduContext.pendingSelfUpgradeGoal = nil
            runSelfUpgradePlan(originalText: goal,
                               surface: "home_chat",
                               fallbackRisk: "high")
        }
        // ✅ 自动化编程独立页面（工程模式）。与电脑控制页解耦：
        //    只有 showCodingPanel=true（planner 判 coding / 用户点“工程模式”/生成 Codex 任务）才弹出。
        .sheet(isPresented: $showCodingPanel) {
            engineeringModeSheet
        }
    }

    // MARK: - 工程模式 / 自动化编程（独立 sheet）
    //    Run Codex 已迁到统一通道：CodexAgentClient.run → /api/adu/unified/input
    //    （source=coding_button / surface=coding / requires_code_agent=true）。
    private var engineeringModeSheet: some View {
        NavigationView {
            ScrollView {
                EngineeringAgentPanel(
                    apiBase: apiBase,
                    project: $codexProject,
                    taskText: $codexTaskText,
                    aduContext: aduContext
                )
                .padding(.vertical, 8)
            }
            .background(Color.white)
            .navigationTitle("工程模式 · 自动化编程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { showCodingPanel = false }
                }
            }
        }
    }

    // MARK: - 顶部
    private var topBar: some View {
        HStack {
            // ⬅️ 返回聊天 —— 只切换 HomeChatView 的 surfaceMode,不 dismiss、不 pop。
            Button { onClose() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                    Text("聊天")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(uiGray)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回聊天")

            Spacer()

            VStack(spacing: 2) {
                Text("电脑控制")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.black)
                Text(refreshStatusText)
                    .font(.system(size: 11))
                    .foregroundColor(refreshStatusColor)
                    .lineLimit(1)
            }

            Spacer()

            // ⚡ 实时刷新开关(默认开;关上则停 polling,只保留手动刷新)
            Button { autoRefreshEnabled.toggle() } label: {
                Image(systemName: autoRefreshEnabled ? "bolt.fill" : "bolt.slash.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(autoRefreshEnabled ? .black : .gray)
                    .frame(width: 36, height: 36)
                    .background(uiGray)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Button { refreshScreenshot() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(width: 36, height: 36)
                    .background(uiGray)
                    .clipShape(Circle())
                    .opacity(isRefreshingShot ? 0.45 : 1.0)
            }
            .buttonStyle(.plain)
            .disabled(isRefreshingShot)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white)
    }

    private var realtimeVoiceControlCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(voiceStatusColor)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(voiceStatus.executionState.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.black.opacity(0.86))
                    Text(voiceStatus.realtimeStatus)
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if voiceStatus.isExecuting {
                    Button {
                        onCancelVoiceExecution()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.red.opacity(0.85))
                            .frame(width: 34, height: 34)
                            .background(Color.red.opacity(0.10))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("取消当前电脑指令")
                }

                Button {
                    voiceStatus.isRealtimeConnected ? onStopVoiceControl() : onStartVoiceControl()
                } label: {
                    Image(systemName: voiceStatus.isRealtimeConnected ? "mic.slash.fill" : "waveform.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(voiceStatus.isRealtimeConnected ? .black.opacity(0.72) : .white)
                        .frame(width: 38, height: 38)
                        .background(voiceStatus.isRealtimeConnected ? uiGray : Color.black)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(voiceStatus.isRealtimeConnected ? "断开电脑语音控制" : "连接电脑语音控制")
            }

            if !voiceStatus.lastCommand.isEmpty || !voiceStatus.lastResult.isEmpty || !voiceStatus.lastError.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    if !voiceStatus.lastCommand.isEmpty {
                        Text("指令: \(voiceStatus.lastCommand)")
                            .font(.system(size: 12))
                            .foregroundColor(.black.opacity(0.72))
                            .lineLimit(2)
                    }
                    let detail = voiceStatus.lastError.isEmpty ? voiceStatus.lastResult : voiceStatus.lastError
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundColor(voiceStatus.lastError.isEmpty ? .gray : .red.opacity(0.85))
                            .lineLimit(3)
                    }
                }
            }
        }
        .padding(12)
        .background(uiGray.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.black.opacity(0.06), lineWidth: 1)
        )
        .padding(.horizontal, 12)
    }

    private var voiceStatusColor: Color {
        switch voiceStatus.executionState {
        case .executing, .connecting:
            return .orange
        case .listening, .succeeded:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .orange.opacity(0.75)
        case .idle:
            return voiceStatus.isRealtimeConnected ? .green : .gray
        }
    }

    // MARK: - 屏幕区
    private var screenArea: some View {
        ZStack {
            uiGray
            if let img = screenshotImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(8)
                    .id(screenshotVersion)   // 每次成功 +1 → SwiftUI 必重绘,根除"图片不变"错觉
            } else if isRefreshingShot {
                VStack(spacing: 12) {
                    ProgressView().scaleEffect(1.1)
                    Text("正在抓取电脑屏幕…")
                        .font(.system(size: 13))
                        .foregroundColor(.gray)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "display.trianglebadge.exclamationmark")
                        .font(.system(size: 40, weight: .light))
                        .foregroundColor(.gray.opacity(0.5))
                    Text("还没有截图。点右上角刷新,或直接输入指令(成功后会自动刷新)。")
                        .font(.system(size: 13))
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }

            if !statusMessage.isEmpty {
                VStack {
                    Spacer()
                    Text(statusMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(statusIsError ? .red : .black.opacity(0.78))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.95))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 2)
                        .padding(.bottom, 10)
                        .padding(.horizontal, 16)
                        .lineLimit(3)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 底部输入栏(主页同款,复用 ChatPlusButton / AudioNoteRecorder)
    // ─── 内部任务栏 ────────────────────────────────────────────────
    // V2 内部任务栏 —— 嵌入在滚动内容里,不再贴屏幕底部。
    // 职责:专门用于"电脑控制专用任务",输入后走 AduTaskPlanner:
    //   • computer_action      → /api/brain/computer/action
    //   • codex_task           → 填入下方自动化编程卡片(EngineeringAgentPanel),等用户确认 Run Codex
    //   • self_upgrade_task    → 生成自我升级计划(同上)
    //   • file_search_task     → 待接入(planner 暂不返回该 intent,默认提示)
    // 屏幕底部的"主输入栏"由 HomeChatView 提供,与本任务栏无关。
    // 为了与 HomeChat 主输入栏区分开,这里只保留 文本 + 黑色发送键 + 可选小麦克;
    // 拍照 / 相册 / 文件 / 黑色波纹键等"普通聊天"功能不重复出现。
    private var internalTaskBar: some View {
        let hasText = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let recording = audioNote.isRecording

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.black.opacity(0.7))
                Text("电脑任务输入")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.black.opacity(0.78))
                Spacer()
                // ✅ 自动化编程入口（独立工程模式页），不在电脑控制页默认区域常驻。
                Button { showCodingPanel = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "hammer")
                            .font(.system(size: 11, weight: .semibold))
                        Text("工程模式")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(.black.opacity(0.7))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(uiGray)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                // 中间胶囊:录音中显示录音状态;否则显示输入框 + 小麦克
                HStack(spacing: 8) {
                    if recording {
                        recordingChip
                    } else if isTranscribing {
                        transcribingChip
                    } else {
                        TextField("打开 Safari / 输入 hello / 修 server_session.py / 你自己检查系统哪里还能升级",
                                  text: $inputText, axis: .vertical)
                            .font(.system(size: 15))
                            .foregroundColor(.black)
                            .focused($focused)
                            .textInputAutocapitalization(.sentences)
                            .disableAutocorrection(false)
                            .lineLimit(1...4)
                            .disabled(isSending)
                            .onSubmit { send() }

                        // 小麦克(可选;独立于 HomeChat 主输入栏的麦克,用作快速电脑任务听写)
                        Button {
                            startVoiceRecording()
                        } label: {
                            Image(systemName: "mic")
                                .font(.system(size: 15))
                                .foregroundColor(.gray.opacity(0.85))
                                .padding(.trailing, 2)
                        }
                        .buttonStyle(.plain)
                        .disabled(isSending || isTranscribing)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(minHeight: 40)
                .background(uiGray)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                // 右键:录音中=停并转文字;转写中=spinner;否则=送 planner
                Button {
                    if recording {
                        stopVoiceRecordingAndTranscribe()
                    } else if !isTranscribing {
                        send()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(recording ? Color.red : (hasText ? Color.black : Color.gray.opacity(0.35)))
                            .frame(width: 40, height: 40)
                        if isSending || isTranscribing {
                            ProgressView().tint(.white).scaleEffect(0.8)
                        } else if recording {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.white)
                        } else {
                            Image(systemName: hasText ? "arrow.up" : "mic.fill")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isSending || isTranscribing || (!recording && !hasText))
            }
        }
        .padding(12)
        .background(Color(white: 0.98))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal, 12)
    }

    // ─── V2 最近状态卡 ────────────────────────────────────────────────
    // 读 aduContext 的派生属性,展示给用户(也是主聊天/实时语音助手看到的同一份)。
    private var recentStatusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.black.opacity(0.7))
                Text("最近状态")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.black.opacity(0.78))
                Spacer()
                Text("\(aduContext.events.count) 条")
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
            }

            recentStatusRow("最近电脑动作", aduContext.lastComputerActionLine ?? "无")
            recentStatusRow("最近 Codex 状态", aduContext.lastCodexStatusLine ?? "无")
            recentStatusRow("最近 planner 判断", aduContext.lastPlannerDecisionLine ?? "无")
            recentStatusRow("pending Codex 任务", aduContext.pendingCodexHint ?? "无")
            if let err = aduContext.lastErrorLine {
                recentStatusRow("最近错误", err, accent: .red)
            }
        }
        .padding(12)
        .background(Color(white: 0.98))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal, 12)
    }

    private func recentStatusRow(_ title: String, _ value: String, accent: Color = .black.opacity(0.78)) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.gray)
            Text(value)
                .font(.system(size: 12))
                .foregroundColor(accent)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var selfUpgradeFollowupCards: some View {
        if aduContext.latestSelfUpgradeNextRecommendation != nil ||
            !aduContext.latestSelfUpgradeVerificationSteps.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if let rec = aduContext.latestSelfUpgradeNextRecommendation {
                    selfUpgradeNextRecommendationCard(rec)
                }
                if !aduContext.latestSelfUpgradeVerificationSteps.isEmpty {
                    selfUpgradeVerificationChips(aduContext.latestSelfUpgradeVerificationSteps)
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private func selfUpgradeNextRecommendationCard(_ rec: SelfUpgradeNextRecommendationSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.black.opacity(0.72))
                Text("下一轮建议")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.black.opacity(0.82))
                Spacer()
                if let risk = rec.riskLevel, !risk.isEmpty {
                    selfUpgradeBadge("risk \(risk)", color: selfUpgradeRiskColor(risk))
                }
                if let mode = rec.suggestedMode, !mode.isEmpty {
                    selfUpgradeBadge(mode, color: .black.opacity(0.62))
                }
            }

            Text(rec.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.black.opacity(0.86))
                .lineLimit(2)

            if !rec.reason.isEmpty {
                Text(rec.reason)
                    .font(.system(size: 11))
                    .foregroundColor(.black.opacity(0.62))
                    .lineLimit(3)
            }

            Button {
                prefillNextSelfUpgradePlan(rec)
            } label: {
                Label("生成下一轮计划", systemImage: "arrow.down.to.line")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.black.opacity(0.78))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(white: 0.94))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color(white: 0.985))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        )
    }

    private func selfUpgradeVerificationChips(_ steps: [SelfUpgradeVerificationStepSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.black.opacity(0.72))
                Text("验证建议")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.black.opacity(0.82))
                Spacer()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(steps) { step in
                        Button {
                            inputText = step.command
                            focused = true
                            statusIsError = false
                            statusMessage = "已填入验证命令,不会自动执行。"
                        } label: {
                            Text(verificationChipTitle(step))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(.black.opacity(0.76))
                                .lineLimit(1)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(Color(white: 0.94))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(10)
        .background(Color(white: 0.985))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        )
    }

    private func prefillNextSelfUpgradePlan(_ rec: SelfUpgradeNextRecommendationSnapshot) {
        var parts: [String] = ["你自己检查系统哪里还能升级"]
        if !rec.title.isEmpty { parts.append("下一轮建议: \(rec.title)") }
        if !rec.reason.isEmpty { parts.append("原因: \(rec.reason)") }
        inputText = parts.joined(separator: "\n")
        focused = true
        statusIsError = false
        statusMessage = "已带入下一轮 self-upgrade 输入,不会自动执行。"
    }

    private func verificationChipTitle(_ step: SelfUpgradeVerificationStepSnapshot) -> String {
        let raw = step.command.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.count <= 34 { return raw }
        return String(raw.prefix(31)) + "…"
    }

    // ─── V3 自我升级计划卡 ────────────────────────────────────────
    @ViewBuilder
    private var selfUpgradePlanCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 标题行
            HStack(spacing: 8) {
                Image(systemName: "infinity.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.black)
                Text("阿杜自我升级计划")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.black)
                Spacer()
                if selfUpgradeLoading {
                    ProgressView().scaleEffect(0.8)
                }
                if selfUpgradePlan != nil {
                    selfUpgradeBadge("plan_only", color: .black.opacity(0.75))
                }
            }

            if let err = selfUpgradeError {
                Text("加载失败:\(err)")
                    .font(.system(size: 12))
                    .foregroundColor(.red.opacity(0.85))
            }

            if selfUpgradeLoading && selfUpgradePlan == nil {
                Text("正在请求 /api/adu/self/upgrade/plan …")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
            }

            if let plan = selfUpgradePlan {
                if !plan.identity.isEmpty {
                    Text(plan.identity)
                        .font(.system(size: 12))
                        .foregroundColor(.black.opacity(0.7))
                        .lineLimit(selfUpgradeExpanded ? 8 : 2)
                }

                VStack(alignment: .leading, spacing: 4) {
                    selfUpgradeInfoRow("mode_effective", plan.modeEffective ?? "plan_only")
                    selfUpgradeInfoRow("requires_user_confirmation", plan.requiresUserConfirmation ? "true" : "false")
                    selfUpgradeInfoRow("auto_executed", plan.autoExecuted ? "true" : "false")
                    if !plan.message.isEmpty {
                        selfUpgradeInfoRow("message", plan.message)
                    }
                }

                // 今日优先(横向胶囊)
                if !plan.todayPriorities.isEmpty {
                    selfUpgradeSectionTitle("今日优先级")
                    HStack(spacing: 6) {
                        ForEach(plan.todayPriorities) { p in
                            selfUpgradeBadge("\(p.title.prefix(14))…  \(p.riskLevel)",
                                             color: selfUpgradeRiskColor(p.riskLevel))
                        }
                        Spacer(minLength: 0)
                    }
                }

                // 推荐升级列表
                if !plan.recommendedUpgrades.isEmpty {
                    selfUpgradeSectionTitle("推荐升级 (\(plan.recommendedUpgrades.count))")
                    ForEach(plan.recommendedUpgrades) { u in
                        selfUpgradeRow(u)
                    }
                }

                if !plan.currentState.isEmpty {
                    selfUpgradeSectionTitle("当前能力状态 current_state")
                    ForEach((selfUpgradeExpanded ? plan.currentState : Array(plan.currentState.prefix(4))), id: \.self) { s in
                        selfUpgradeBullet(s)
                    }
                }
                if !plan.capabilityBuckets.isEmpty {
                    selfUpgradeSectionTitle("能力桶 capability_buckets")
                    ForEach((selfUpgradeExpanded ? plan.capabilityBuckets : Array(plan.capabilityBuckets.prefix(4))), id: \.self) { s in
                        selfUpgradeBullet(s)
                    }
                }
                if !plan.findings.isEmpty {
                    selfUpgradeSectionTitle("发现的问题 findings")
                    ForEach((selfUpgradeExpanded ? plan.findings : Array(plan.findings.prefix(4))), id: \.self) { s in
                        selfUpgradeBullet(s)
                    }
                }
                if let memory = plan.evolutionMemorySummary, !memory.isEmpty {
                    selfUpgradeSectionTitle("进化记忆摘要 evolution_memory_summary")
                    Text(memory)
                        .font(.system(size: 11))
                        .foregroundColor(.black.opacity(0.62))
                        .lineLimit(selfUpgradeExpanded ? 8 : 3)
                }

                // 底部按钮:查看详情 / 稍后再说
                HStack(spacing: 10) {
                    Button {
                        selfUpgradeExpanded.toggle()
                    } label: {
                        Label(selfUpgradeExpanded ? "收起" : "查看详情",
                              systemImage: selfUpgradeExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.black.opacity(0.78))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(white: 0.94))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        dismissSelfUpgradePlan()
                    } label: {
                        Label("稍后再说", systemImage: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.black.opacity(0.7))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(white: 0.94))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                if plan.requiresUserConfirmation {
                    Text("plan_only · 不会自动调用 Codex。点'生成 Codex 任务'只填入下方任务框,仍需手动 Run。")
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                }
            }
        }
        .padding(12)
        .background(Color(white: 0.985))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.black.opacity(0.1), lineWidth: 1)
        )
        .padding(.horizontal, 12)
    }

    private func selfUpgradeRow(_ u: AduSelfUpgradeRecommended) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(u.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.black.opacity(0.85))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                selfUpgradeBadge("risk \(u.riskLevel)", color: selfUpgradeRiskColor(u.riskLevel))
                selfUpgradeBadge("cost \(u.estimatedCostLevel)", color: selfUpgradeCostColor(u.estimatedCostLevel))
                selfUpgradeBadge("mode \(u.suggestedMode)", color: .black.opacity(0.6))
                selfUpgradeBadge("confirm \(u.requiresUserConfirmation ? "true" : "false")", color: .black.opacity(0.55))
                if let pid = u.projectId, !pid.isEmpty {
                    selfUpgradeBadge(pid, color: .black.opacity(0.75))
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 2) {
                selfUpgradeInfoRow("project_id", u.projectId ?? "")
                selfUpgradeInfoRow("risk_level", u.riskLevel)
                selfUpgradeInfoRow("estimated_cost_level", u.estimatedCostLevel)
                selfUpgradeInfoRow("suggested_mode", u.suggestedMode)
                selfUpgradeInfoRow("requires_user_confirmation", u.requiresUserConfirmation ? "true" : "false")
            }
            Text(u.reason)
                .font(.system(size: 11))
                .foregroundColor(.black.opacity(0.6))
                .lineLimit(3)

            // codex_prompt 折叠预览
            if selfUpgradeExpandedIds.contains(u.id) {
                ScrollView(.vertical, showsIndicators: true) {
                    Text(u.codexPrompt)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.black.opacity(0.78))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 140)
                .background(Color(white: 0.96))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                if !u.verificationSteps.isEmpty {
                    Text("验证步骤")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.gray)
                    ForEach(u.verificationSteps) { v in
                        Text("· [\(v.tool)] \(v.command)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.black.opacity(0.6))
                            .lineLimit(2)
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    adoptSelfUpgradeIntoCodexPanel(u)
                } label: {
                    Label("生成 Codex 任务", systemImage: "arrow.down.to.line")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.black)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    if selfUpgradeExpandedIds.contains(u.id) {
                        selfUpgradeExpandedIds.remove(u.id)
                    } else {
                        selfUpgradeExpandedIds.insert(u.id)
                    }
                } label: {
                    Label(selfUpgradeExpandedIds.contains(u.id) ? "收起 prompt" : "查看 prompt",
                          systemImage: "doc.text.magnifyingglass")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.black.opacity(0.7))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(white: 0.94))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.black.opacity(0.06), lineWidth: 1)
        )
    }

    private func selfUpgradeSectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.gray)
    }

    private func selfUpgradeBullet(_ text: String) -> some View {
        Text("· \(text)")
            .font(.system(size: 11))
            .foregroundColor(.black.opacity(0.6))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func selfUpgradeInfoRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.black.opacity(0.48))
                .frame(width: 168, alignment: .leading)
            Text(value.isEmpty ? "-" : value)
                .font(.system(size: 11))
                .foregroundColor(.black.opacity(0.68))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func selfUpgradeBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color)
            .clipShape(Capsule())
    }

    private func selfUpgradeRiskColor(_ raw: String) -> Color {
        switch raw.lowercased() {
        case "low":    return Color.green.opacity(0.78)
        case "medium": return Color.orange.opacity(0.85)
        case "high":   return Color.red.opacity(0.85)
        default:       return .gray
        }
    }

    private func selfUpgradeCostColor(_ raw: String) -> Color {
        switch raw.lowercased() {
        case "low":    return Color.green.opacity(0.65)
        case "medium": return Color.orange.opacity(0.7)
        case "high":   return Color.red.opacity(0.7)
        default:       return Color.gray.opacity(0.7)
        }
    }

    // ─── V3 self-upgrade actions ─────────────────────────────────
    private func runSelfUpgradePlan(originalText: String,
                                    surface: String,
                                    fallbackRisk: String) {
        selfUpgradeLoading = true
        selfUpgradeError = nil
        statusIsError = false
        statusMessage = "正在请求阿杜自我升级计划 (plan_only) …"
        aduContext.append(AduTimelineEvent(
            source: .self_upgrade,
            kind: .user_message,
            content: "用户触发 self upgrade:\(originalText)",
            summary: "self_upgrade: 用户触发 \(String(originalText.prefix(80)))",
            metadata: ["surface": surface]
        ))
        aduContext.append(AduTimelineEvent(
            source: .self_upgrade,
            kind: .task_started,
            content: "请求 /api/adu/self/upgrade/plan 开始",
            summary: "self_upgrade: 请求计划开始",
            metadata: [
                "endpoint": "/api/adu/self/upgrade/plan",
                "surface": surface,
                "plan_only": "true",
                "goal_head": String(originalText.prefix(120)),
            ]
        ))

        Task { @MainActor in
            let result = await AduSelfUpgradeClient.fetchPlan(
                apiBase: apiBase,
                goal: originalText,
                surface: surface
            )
            selfUpgradeLoading = false
            if let plan = result.plan, plan.ok {
                selfUpgradePlan = plan
                selfUpgradeExpanded = false
                selfUpgradeExpandedIds = []
                statusIsError = false
                let sidHint = plan.sessionId.map { " · session=\($0)" } ?? ""
                statusMessage = plan.message + sidHint
                // ✅ 写 timeline:source=self_upgrade, kind=assistant_summary
                let summary = "已生成自我升级计划 · \(plan.todayPriorities.count) 优先 / \(plan.recommendedUpgrades.count) 候选\(sidHint)"
                aduContext.appendSelfUpgradePlan(summary: summary, riskLevel: fallbackRisk)
            } else {
                selfUpgradePlan = nil
                selfUpgradeError = result.errorMessage ?? "未知错误"
                statusIsError = true
                statusMessage = "无法生成自我升级计划:\(selfUpgradeError ?? "")"
                aduContext.append(AduTimelineEvent(
                    source: .self_upgrade,
                    kind: .tool_error,
                    content: "self_upgrade plan 请求失败:\(selfUpgradeError ?? "")",
                    summary: "self_upgrade: 请求计划失败",
                    metadata: [
                        "endpoint": "/api/adu/self/upgrade/plan",
                        "http_status": "\(result.httpStatus)",
                        "error_head": String((selfUpgradeError ?? "").prefix(180)),
                    ]
                ))
            }
        }
    }

    private func adoptSelfUpgradeIntoCodexPanel(_ u: AduSelfUpgradeRecommended) {
        // 只做本地预填 + 滚动。这里不调用 /api/adu/codex/run,也不推进任何后端执行状态。
        codexTaskText = u.codexPrompt
        codexProject = projectChoice(from: u.projectId)
        showCodingPanel = true   // ✅ 用户点“生成 Codex 任务”后才显示自动化编程卡片
        statusIsError = false
        statusMessage = "已生成 Codex 任务,已跳转到自动化编程卡片,请确认后手动运行。"
        // 先写 attachment(本地侧),让 EngineeringAgentPanel.runCodex 立刻有据可依。
        let sid = selfUpgradePlan?.sessionId
        aduContext.setSelfUpgradeAttachment(PendingSelfUpgradeAttachment(
            upgradeId: u.id,
            title: u.title,
            projectId: u.projectId,
            riskLevel: u.riskLevel,
            suggestedMode: u.suggestedMode,
            verificationCommand: u.verificationSteps.first?.command,
            sessionId: sid
        ))
        aduContext.append(AduTimelineEvent(
            source: .self_upgrade,
            kind: .task_created,
            content: "阿杜自我升级 → 已把『\(u.title)』(project=\(u.projectId ?? "?"), risk=\(u.riskLevel)\(sid.map { ", session=\($0)" } ?? "")) 填入自动化编程任务,等待用户点 Run Codex。",
            summary: "self_upgrade: 用户点击生成 Codex 任务 \(u.title)",
            metadata: [
                "upgrade_id": u.id,
                "project_id": u.projectId ?? "",
                "risk_level": u.riskLevel,
                "session_id": sid ?? "",
                "auto_run_codex": "false",
            ]
        ))
        // 触发自动滚动到 EngineeringAgentPanel
        scrollTargetID = engineeringAgentPanelAnchor
    }

    private func dismissSelfUpgradePlan() {
        selfUpgradePlan = nil
        selfUpgradeExpanded = false
        selfUpgradeExpandedIds = []
        selfUpgradeError = nil
        statusMessage = "已收起自我升级计划卡。可随时再说一次「你自己检查系统哪里还能升级」重新生成。"
        statusIsError = false
    }

    private var plannerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.black.opacity(0.78))
                Text("阿杜判断")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.black)
                Spacer()
            }

            if let plan = lastPlan {
                plannerRow("类型", "\(plan.type.rawValue) · \(plan.type.title)")
                plannerRow("原始输入", plan.originalInput)
                plannerRow("阿杜整理后的任务", plan.organizedTask)
                if let pid = plan.suggestedProjectId, !pid.isEmpty {
                    plannerRow("阿杜自动选择工程",
                               "\(pid)" + (plan.suggestedProject.map { " · \($0)" } ?? ""))
                }
                if pendingCodexExists {
                    plannerRow("风险等级", riskLevelLabel(pendingCodexRiskLevel))
                }
                plannerRow("下一步动作", plan.nextAction)
            } else {
                plannerRow("类型", "等待输入")
                plannerRow("原始输入", "底部输入框、小麦克语音转文字、黑色发送键都会先进入 planner。")
                plannerRow("阿杜整理后的任务", "尚未生成")
                plannerRow("下一步动作", "输入后按右侧黑色按钮,或录音转文字完成后自动判断。")
            }
        }
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal, 12)
    }

    private func plannerRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.gray)
            Text(value)
                .font(.system(size: 13))
                .foregroundColor(.black.opacity(0.78))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(title == "阿杜整理后的任务" ? 8 : 4)
        }
    }

    // MARK: - 行为

    // 同步壳:给"按钮 onClick" / "onAppear" / "send 成功补刷"这类同步入口用
    private func refreshScreenshot() {
        Task { @MainActor in
            await refreshScreenshotOnce()
        }
    }

    // 真正的单次取图。可重入保护;成功 bump screenshotVersion 强制 Image 重绘。
    @MainActor
    private func refreshScreenshotOnce() async {
        guard !isRefreshingShot else { return }
        isRefreshingShot = true
        defer { isRefreshingShot = false }

        // ✅ 唯一链路：刷新 = 统一入口 screenshot → ComputerGateway → local_agent:4317。
        //    绝不经过 Codex / 自动化编程链路。
        var result: [String: Any]
        do {
            let r = try await UnifiedTaskService.shared.sendComputerModeCommand(
                text: "",
                action: "screenshot"
            )
            result = r.raw
        } catch {
            result = [
                "ok": false,
                "type": "error",
                "error": "unified_screenshot_failed",
                "__exception": "\(error.localizedDescription)",
            ]
        }
        if let img = decodeImage(from: result) {
            screenshotImage = img
            lastShotAt = Date()
            screenshotVersion &+= 1
            lastShotFailed = false
            // 若 statusMessage 是上一轮"截图失败"留下的,清掉;但不要覆盖 action 的真实错误
            if statusIsError, statusMessage.contains("截图") {
                statusMessage = ""
                statusIsError = false
            }
        } else {
            lastShotFailed = true
            if statusMessage.isEmpty {
                statusIsError = true
                statusMessage = friendlyError(result, default: "获取截图失败")
            }
        }
    }

    // ─── 录音 + 本机转文字(SFSpeechRecognizer zh-CN)──────────────────
    // 复用主页同款 AudioNoteRecorder 拿到 wav 文件,再走本机 Speech 转写,
    // 结果直接填进 inputText —— 不发到聊天、不动后端。

    private var recordingChip: some View {
        // 中间胶囊在录音时的视觉:红点 + "录音中" + 计时
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .opacity((recordingTick % 2 == 0) ? 1.0 : 0.35)
            Text("录音中 · \(recordingDurationText)")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.black.opacity(0.78))
            Spacer()
            Button {
                cancelVoiceRecording()
            } label: {
                Text("取消")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.gray)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.white)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var transcribingChip: some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.7)
            Text("识别中…")
                .font(.system(size: 14))
                .foregroundColor(.gray)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var recordingDurationText: String {
        guard let started = recordingStartedAt else { return "0:00" }
        let s = max(0, Int(Date().timeIntervalSince(started)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func startVoiceRecording() {
        // 已在录音 / 已在转写 / 正在送 action 都不许重新开始
        guard !audioNote.isRecording, !isTranscribing, !isSending else { return }
        statusMessage = ""
        statusIsError = false
        // 主页同款 AudioNoteRecorder.start 是 async throws(内部请求 mic 权限)
        Task { @MainActor in
            do {
                try await audioNote.start()
                recordingStartedAt = Date()
                recordingTick = 0
                startRecordingTicker()
            } catch {
                statusIsError = true
                statusMessage = "录音启动失败:\(error.localizedDescription)"
            }
        }
    }

    private func cancelVoiceRecording() {
        stopRecordingTicker()
        audioNote.cancel()    // 主页同款 cancel:停录音 + 删临时文件
        recordingStartedAt = nil
    }

    private func stopVoiceRecordingAndTranscribe() {
        stopRecordingTicker()
        audioNote.stopAndMarkPending()    // 停录音,文件落到 pendingFileURL
        recordingStartedAt = nil
        guard let url = audioNote.pendingFileURL else {
            statusIsError = true
            statusMessage = "没有拿到录音文件"
            return
        }
        // 本机 Speech 转写 zh-CN;识别完成后先进入 AduTaskPlanner,
        // 再按 planner 类型决定是电脑动作、Codex 预填、Claude 预览还是普通回答。
        isTranscribing = true
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    self.isTranscribing = false
                    self.statusIsError = true
                    self.statusMessage = "语音识别未授权(系统设置 → ChatAGI → 语音识别)"
                    return
                }
                guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
                      recognizer.isAvailable else {
                    self.isTranscribing = false
                    self.statusIsError = true
                    self.statusMessage = "本机语音识别暂不可用"
                    return
                }
                let req = SFSpeechURLRecognitionRequest(url: url)
                req.shouldReportPartialResults = false
                recognizer.recognitionTask(with: req) { result, error in
                    DispatchQueue.main.async {
                        if let result = result, result.isFinal {
                            let text = result.bestTranscription.formattedString
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if !text.isEmpty {
                                // 小麦克转写完成 → 走统一 planner 入口,source 标记为 voice_mic。
                                self.routePlannerInput(text, source: .voice_mic)
                            }
                            self.isTranscribing = false
                            return
                        }
                        if let error = error {
                            self.isTranscribing = false
                            self.statusIsError = true
                            self.statusMessage = "识别失败:\(error.localizedDescription)"
                        }
                    }
                }
            }
        }
    }

    private func startRecordingTicker() {
        stopRecordingTicker()
        recordingTickerTask = Task { @MainActor in
            while !Task.isCancelled, audioNote.isRecording {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { break }
                recordingTick &+= 1
            }
        }
    }

    private func stopRecordingTicker() {
        recordingTickerTask?.cancel()
        recordingTickerTask = nil
    }

    // ─── Polling ──────────────────────────────────────────────────────
    // 页面 onAppear 启动;onDisappear 取消;实时开关关闭时停。
    // 不用 Timer,用 Task + Task.sleep,跟 SwiftUI 生命周期更对齐,取消干净。
    // 与 EngineeringAgentPanel 的 Codex Task 完全独立(各自 Task,不互相 await),
    // 所以 Codex Running 时截图照常每 1.5s 刷新。
    private func startPolling() {
        stopPolling()
        let interval = pollingIntervalNs
        pollingTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                if Task.isCancelled { break }
                guard autoRefreshEnabled else { continue }
                guard !isRefreshingShot else { continue }
                await refreshScreenshotOnce()
            }
        }
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    // ─── 顶栏状态文本 ────────────────────────────────────────────────
    private var refreshStatusText: String {
        if isRefreshingShot { return "刷新中…" }
        if !autoRefreshEnabled {
            if let t = lastShotAt { return "已暂停 · 上次 " + relativeTime(t) }
            return "已暂停 · 点⚡开启"
        }
        if lastShotFailed { return "刷新失败 · 点⟳重试" }
        if let t = lastShotAt { return "截图 " + relativeTime(t) }
        return "等待截图…"
    }

    private var refreshStatusColor: Color {
        if lastShotFailed { return .red }
        if !autoRefreshEnabled { return .orange }
        return .gray
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        routePlannerInput(text, source: .computer_task_input)
    }

    private func routePlannerInput(_ text: String, source: AduTimelineSource = .computer_task_input) {
        // ✅ V2 统一上下文:键盘 / 小麦克 / 程序填入,都会从这里落库一次,避免重复或漏记。
        aduContext.appendUserMessage(text, source: source)
        inputText = ""
        focused = false
        statusIsError = false
        isSending = true

        Task { @MainActor in
            do {
                let route = try await AduBackendPlannerClient.route(
                    apiBase: apiBase,
                    text: text,
                    surface: .computerControl,
                    recentMessages: makePlannerRecentMessages(),
                    pendingCodexTask: makePendingCodexPayload(),
                    selectedProject: pendingCodexProject,
                    screenState: makePlannerScreenState()
                )
                isSending = false
                dispatchBackendPlannerRoute(route, originalText: text)
            } catch {
                let plan = localFallbackPlan(text)
                isSending = false
                dispatchLocalPlannerFallback(plan)
            }
        }
    }

    private func localFallbackPlan(_ text: String) -> AduTaskPlan {
        AduTaskPlanner.plan(
            text,
            context: AduPlannerContext(
                currentSurface: .computerControl,
                hasPendingCodexTask: pendingCodexExists,
                pendingCodexSummary: pendingCodexSummary.isEmpty ? nil : pendingCodexSummary,
                lastAssistantIntent: lastPlan?.type.rawValue,
                lastUserIntent: lastPlan?.originalInput,
                recentConversationSummary: statusMessage,
                selectedProject: pendingCodexProject,
                currentScreenState: "computerControl"
            )
        )
    }

    private func makePlannerRecentMessages() -> [AduPlannerRecentMessage] {
        var out: [AduPlannerRecentMessage] = []
        if let lastPlan {
            out.append(AduPlannerRecentMessage(role: "user", content: lastPlan.originalInput))
            out.append(AduPlannerRecentMessage(role: "assistant", content: statusMessage.isEmpty ? lastPlan.nextAction : statusMessage))
        } else if !statusMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append(AduPlannerRecentMessage(role: "assistant", content: statusMessage))
        }
        return out
    }

    private func makePendingCodexPayload() -> AduPendingCodexTaskPayload {
        AduPendingCodexTaskPayload(
            exists: pendingCodexExists,
            project: pendingCodexProject,
            prompt: pendingCodexPrompt.isEmpty ? nil : pendingCodexPrompt,
            summary: pendingCodexSummary.isEmpty ? nil : pendingCodexSummary,
            riskLevel: pendingCodexRiskLevel,
            createdAt: pendingCodexCreatedAt.map { ISO8601DateFormatter().string(from: $0) }
        )
    }

    private func makePlannerScreenState() -> [String: Any] {
        [
            "computer_panel_open": true,
            "codex_running": false,
            "last_health": statusMessage.isEmpty ? refreshStatusText : statusMessage,
            "screenshot_auto_refresh": autoRefreshEnabled,
            "screenshot_refreshing": isRefreshingShot
        ]
    }

    private func dispatchBackendPlannerRoute(_ route: AduBackendPlannerRoute, originalText: String) {
        let plan = route.asTaskPlan
        lastPlan = AduTaskPlan(
            type: route.intentType,
            originalInput: originalText,
            organizedTask: plan.organizedTask,
            nextAction: route.nextAction,
            suggestedProject: route.project,
            suggestedProjectId: route.projectId
        )
        statusIsError = false

        // ✅ V2 写入统一上下文 —— planner 的判断结果(无论后续如何分发)。
        aduContext.appendPlannerDecision(
            intent: route.intent,
            confidence: route.confidence,
            projectId: route.projectId,
            project: route.project,
            executor: route.executor,
            riskLevel: route.riskLevel,
            needsConfirmation: route.needsUserConfirmation,
            nextAction: route.nextAction,
            originalInput: originalText
        )

        switch route.intentType {
        case .computerAction:
            let goal = route.computerGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? originalText : route.computerGoal
            sendComputerAction(goal: goal)
        case .codexTask:
            // 优先用 registry id(后端 planner 自动选好的),没有再回退 display name。
            setPendingCodexTask(prompt: route.codexPrompt.isEmpty ? plan.organizedTask : route.codexPrompt, project: route.projectId ?? route.project, summary: route.summary, risk: route.riskLevel)
            // ✅ 编程任务 → 提示并切到独立“工程模式”页（setPendingCodexTask 已置 showCodingPanel=true）。
            statusMessage = "这是自动化编程任务，已切换到工程模式。"
        case .selfUpgradeTask:
            // ✅ V3 self-evolution:不再走 Codex 卡片。直接调 /api/adu/self/upgrade/plan
            //    获取计划卡渲染。即使 backend planner 仍带 codex_prompt 兜底,这里也忽略它。
            runSelfUpgradePlan(originalText: originalText,
                               surface: "home_chat",
                               fallbackRisk: route.riskLevel.isEmpty ? "high" : route.riskLevel)
        case .continuePreviousTask, .confirmPendingTask:
            if pendingCodexExists {
                codexTaskText = pendingCodexPrompt
                codexProject = projectChoice(from: pendingCodexProject)
                statusMessage = route.message.isEmpty ? "已找到待继续的 Codex 任务，请确认后点击 Run Codex" : route.message
            } else {
                statusIsError = true
                statusMessage = route.message.isEmpty ? "当前没有待执行任务。" : route.message
            }
        case .cancelPendingTask:
            if pendingCodexExists { clearPendingCodexTask() }
            statusMessage = route.message.isEmpty ? "已取消待执行的 Codex 任务。" : route.message
        case .editPendingTask:
            if pendingCodexExists {
                pendingCodexPrompt = pendingCodexPrompt.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n补充约束:\n- \(originalText)"
                codexTaskText = pendingCodexPrompt
                statusMessage = route.message.isEmpty ? "已更新待执行的 Codex prompt。" : route.message
            } else {
                statusIsError = true
                statusMessage = route.message.isEmpty ? "当前没有待修改的 Codex 任务，请先创建任务" : route.message
            }
        case .chatAnswer:
            statusMessage = route.chatAnswer.isEmpty ? (route.message.isEmpty ? plan.organizedTask : route.message) : route.chatAnswer
        case .askClarification:
            statusMessage = route.message.isEmpty ? "请再说明你想让我做什么。" : route.message
        case .claudeTask:
            statusMessage = route.message.isEmpty ? "待接入 Claude" : route.message
        case .fileSearchTask:
            // ✅ V3 授权工作区文件搜索 —— 只调 /api/adu/files/search,绝不递归系统盘。
            //    project_id 优先用 planner 推断好的;若为空,后端会自动在所有授权工程内搜。
            let q = extractSearchQuery(from: originalText)
            statusMessage = "正在授权工作区搜索 \(q) …"
            statusIsError = false
            runFileSearch(query: q, projectId: route.projectId)
        }
    }

    // 从 "帮我找 server_session.py" / "找 HomeChatView" 抽出真正的关键词。失败回退到 originalText。
    private func extractSearchQuery(from text: String) -> String {
        // 去掉常见动词,留下文件名/标识符
        var t = text
        for verb in ["帮我找一下", "帮我找", "找一下", "找", "搜一下", "搜索", "搜",
                     "查一下", "查找", "在哪里", "在哪", "where is", "where", "locate"] {
            t = t.replacingOccurrences(of: verb, with: " ")
        }
        let candidate = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? text : candidate
    }

    private func runFileSearch(query: String, projectId: String?) {
        Task { @MainActor in
            let result = await postFileSearch(query: query, projectId: projectId)
            let okFlag = (result["ok"] as? Bool) ?? false
            let hits = (result["hits"] as? [[String: Any]]) ?? []
            let hitCount = (result["hit_count"] as? Int) ?? hits.count
            if okFlag {
                let samples: [String] = hits.prefix(5).compactMap { h in
                    guard let pid = h["project_id"] as? String,
                          let rel = h["relative_path"] as? String else { return nil }
                    return "\(pid)/\(rel)"
                }
                aduContext.appendFileSearchResult(query: query, hitCount: hitCount, sampleHits: samples)
                if hitCount == 0 {
                    statusMessage = "在授权工作区里没找到 \(query)"
                } else {
                    let head = samples.first ?? ""
                    statusMessage = "找到 \(hitCount) 个文件,例如: \(head)"
                }
            } else {
                statusIsError = true
                let err = (result["error"] as? String) ?? "未知错误"
                statusMessage = "文件搜索失败:\(err)"
                aduContext.appendSystem("file_search 失败:\(query) — \(err)", kind: .tool_error)
            }
        }
    }

    private func postFileSearch(query: String, projectId: String?) async -> [String: Any] {
        let base = apiBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/api/adu/files/search") else {
            return ["ok": false, "error": "invalid_api_base"]
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        var body: [String: Any] = ["query": query, "max_results": 20]
        if let pid = projectId, !pid.isEmpty { body["project_id"] = pid }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                if !(200..<300).contains(code), json["ok"] == nil {
                    return ["ok": false, "error": "HTTP \(code)"]
                }
                return json
            }
            return ["ok": false, "error": "invalid_response"]
        } catch {
            return ["ok": false, "error": "\(error.localizedDescription)"]
        }
    }

    private func dispatchLocalPlannerFallback(_ plan: AduTaskPlan) {
        lastPlan = plan
        statusIsError = false
        let fallbackPrefix = "已使用本地 fallback 判断。\n\n"

        switch plan.type {
        case .computerAction:
            sendComputerAction(goal: plan.originalInput, noticePrefix: fallbackPrefix)
        case .codexTask:
            setPendingCodexTask(prompt: plan.organizedTask, project: plan.suggestedProject, summary: plan.organizedTask, risk: "medium")
            statusMessage = fallbackPrefix + "这是自动化编程任务，已切换到工程模式。"
        case .claudeTask:
            statusMessage = fallbackPrefix + "待接入 Claude"
        case .chatAnswer:
            statusMessage = fallbackPrefix + plan.organizedTask
        case .selfUpgradeTask:
            // ✅ V3:本地启发也走 /api/adu/self/upgrade/plan,不再 setPendingCodexTask。
            runSelfUpgradePlan(originalText: plan.originalInput,
                               surface: "home_chat",
                               fallbackRisk: "high")
        case .continuePreviousTask, .confirmPendingTask:
            if pendingCodexExists {
                codexTaskText = pendingCodexPrompt
                statusMessage = fallbackPrefix + "已找到待继续的 Codex 任务，请确认后点击 Run Codex"
            } else {
                statusIsError = true
                statusMessage = fallbackPrefix + "当前没有待执行任务。"
            }
        case .cancelPendingTask:
            if pendingCodexExists { clearPendingCodexTask() }
            statusMessage = fallbackPrefix + "已取消待执行的 Codex 任务。"
        case .editPendingTask:
            statusMessage = fallbackPrefix + (pendingCodexExists ? "已更新待执行的 Codex prompt。" : "当前没有待修改的 Codex 任务，请先创建任务")
        case .askClarification:
            statusMessage = fallbackPrefix + "请再说明你想让我做什么。"
        case .fileSearchTask:
            // 本地启发也走真后端 /api/adu/files/search;失败时只在 timeline 留摘要。
            let q = extractSearchQuery(from: plan.originalInput)
            statusMessage = fallbackPrefix + "正在授权工作区搜索 \(q) …"
            runFileSearch(query: q, projectId: plan.suggestedProjectId)
        }
    }

    private func setPendingCodexTask(prompt: String, project: String?, summary: String, risk: String) {
        pendingCodexExists = true
        pendingCodexProject = project ?? "GPTsora"
        pendingCodexPrompt = prompt
        pendingCodexSummary = summary.isEmpty ? prompt : summary
        pendingCodexRiskLevel = risk.isEmpty ? "medium" : risk
        pendingCodexCreatedAt = Date()
        codexProject = projectChoice(from: pendingCodexProject)
        codexTaskText = prompt
        showCodingPanel = true   // ✅ planner 判为 codex_task 后才显示自动化编程卡片
    }

    private func clearPendingCodexTask() {
        pendingCodexExists = false
        pendingCodexProject = nil
        pendingCodexPrompt = ""
        pendingCodexSummary = ""
        pendingCodexRiskLevel = "medium"
        pendingCodexCreatedAt = nil
    }

    private func sendComputerAction(goal text: String, noticePrefix: String = "") {
        guard !isSending else { return }
        isSending = true
        statusMessage = noticePrefix.isEmpty ? "" : noticePrefix + "正在执行电脑操作..."
        // ✅ V2 写入统一上下文 —— computer_action 开始。
        aduContext.appendComputerActionStarted(goal: text)

        Task { @MainActor in
            let result = await postBrainComputerAction(body: ["goal": text])
            let okFlag = (result["ok"] as? Bool) ?? false
            let (msgOk, msg) = parseActionResult(result, fallbackGoal: text)
            statusIsError = !msgOk
            statusMessage = noticePrefix + msg
            isSending = false

            // ✅ V2 写入统一上下文 —— computer_action 结果(摘要,不塞完整 stdout)。
            var meta: [String: String] = [:]
            if let action = result["action"] as? String { meta["action"] = action }
            if let status = result["status"] as? String { meta["status"] = status }
            if let keys = result["keys"] as? [String] { meta["keys"] = keys.joined(separator: ",") }
            if let typed = result["text"] as? String { meta["text_head"] = String(typed.prefix(60)) }
            aduContext.appendComputerActionResult(
                goal: text,
                ok: msgOk && okFlag,
                message: msg,
                metadata: meta
            )

            if okFlag {
                // 成功 → 两次补刷:0.3s 抓刚跳出来的窗口动画,1.0s 抓稳态。
                // 跑在独立 Task 里,不阻塞 send 返回,也不影响 polling。
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    await refreshScreenshotOnce()
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    await refreshScreenshotOnce()
                }
            }
        }
    }

    private func projectChoice(from suggested: String?) -> EngineeringAgentPanel.ProjectChoice {
        // 优先按 registry id 匹配(planner 现在会填 project_id),再回退到老的 display name。
        switch (suggested ?? "").lowercased() {
        case "backend": return .backend
        case "little_beijing", "littlebeijing", "little beijing": return .littleBeijing
        case "chatagi_site", "chatagisite", "chatagi site": return .chatagiSite
        case "gptsora": return .gptsora
        default: break
        }
        switch suggested {
        case "Backend": return .backend
        case "Little Beijing": return .littleBeijing
        case "ChatAGI Site": return .chatagiSite
        default: return .gptsora
        }
    }

    private func riskLevelLabel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "low": return "low(低)"
        case "high": return "high(高 · 需用户确认)"
        case "medium", "": return "medium(中)"
        default: return raw
        }
    }

    // MARK: - 网络

    private func postBrainComputerAction(body: [String: Any]) async -> [String: Any] {
        let normalized = apiBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: normalized + "/api/brain/computer/action") else {
            return ["ok": false, "error": "invalid_api_base"]
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let raw = String(data: data, encoding: .utf8) ?? ""
            if !(200..<300).contains(code) {
                var out = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                out["ok"] = false
                out["error"] = "http_error"
                out["__http_status"] = code
                out["__raw"] = raw
                return out
            }
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                var out = json
                out["__http_status"] = code
                out["__raw"] = raw
                return out
            }
            return [
                "ok": false,
                "error": "non_json_response",
                "__http_status": code,
                "__raw": String(data: data, encoding: .utf8) ?? "",
            ]
        } catch {
            return [
                "ok": false,
                "error": "network_error",
                "__exception": "\(type(of: error)): \(error.localizedDescription)",
            ]
        }
    }

    // MARK: - 解析

    private func decodeImage(from result: [String: Any]) -> UIImage? {
        guard (result["ok"] as? Bool) ?? false else { return nil }
        // 期望:{"ok":true,"action":"screenshot","result":{"image_b64":"...","bytes":N,"format":"png"}}
        if let inner = result["result"] as? [String: Any],
           let b64 = (inner["image_b64"] as? String) ?? (inner["image_base64"] as? String),
           let data = Data(base64Encoded: b64),
           let img = UIImage(data: data) {
            return img
        }
        // 顶层兜底
        if let b64 = (result["image_b64"] as? String) ?? (result["image_base64"] as? String),
           let data = Data(base64Encoded: b64),
           let img = UIImage(data: data) {
            return img
        }
        return nil
    }

    private func parseActionResult(_ result: [String: Any], fallbackGoal: String) -> (Bool, String) {
        let ok = (result["ok"] as? Bool) ?? false
        if ok {
            let act = (result["action"] as? String) ?? ""
            let msg = (result["message"] as? String)
                ?? (result["final_text"] as? String)
                ?? ((result["result"] as? [String: Any])?["message"] as? String)
                ?? "已发送:\(fallbackGoal)"
            if act.isEmpty { return (true, msg) }
            return (true, "[\(act)] \(msg)")
        }
        return (false, friendlyError(result, default: "执行失败"))
    }

    private func friendlyError(_ result: [String: Any], default def: String) -> String {
        if let code = result["__http_status"] as? Int, code >= 0, !(200..<300).contains(code) {
            let raw = (result["__raw"] as? String) ?? ""
            return raw.isEmpty ? "\(def)(HTTP \(code))" : "\(def)(HTTP \(code)): \(raw)"
        }
        if let s = result["__exception"] as? String, !s.isEmpty { return s }
        if let s = result["error"] as? String, !s.isEmpty { return s }
        if let s = result["message"] as? String, !s.isEmpty { return s }
        if let d = result["detail"] {
            if let s = d as? String, !s.isEmpty { return s }
            if let dict = d as? [String: Any] {
                if let e = dict["error"] as? String, !e.isEmpty { return e }
                if let m = dict["message"] as? String, !m.isEmpty { return m }
                if let h = dict["hint"] as? String, !h.isEmpty { return h }
            }
        }
        if let code = result["__http_status"] as? Int, code >= 0 {
            let raw = (result["__raw"] as? String) ?? ""
            return raw.isEmpty ? "\(def)(HTTP \(code))" : "\(def)(HTTP \(code)): \(raw)"
        }
        return def
    }

    private func relativeTime(_ t: Date) -> String {
        let diff = Int(Date().timeIntervalSince(t))
        if diff < 5 { return "刚刚" }
        if diff < 60 { return "\(diff) 秒前" }
        if diff < 3600 { return "\(diff / 60) 分钟前" }
        return "更早"
    }
}
