//
//  ContentView.swift  (MAIN MODULE)
//  ✅ Video generation chain stays here (submitPromptToSora -> VideoJobManager.enqueue -> worker -> SoraVideoService)
//  ✅ Paywall / subscription / video packs are centralized in BillingKit (SolaraPaywallCenter + PaywallView)
//  ✅ Voice intent uses Bus: SoraIntentBus.shared.publisher -> submitPromptToSora
//
//  ✅ Upgrade: Black ripple = toggle call; In Player -> Remix call
//    - Tap black ripple: start call -> blue ripple
//    - Tap blue ripple: end call -> back to black ripple
//    - If in Player + has OpenAI video_id: call is "Remix capture"; hangup triggers enqueue remix job (assistant completes).
//
//  ✅ NEW:
//  1) previewBox supports playable input video (tap play/pause)
//  2) On ripple start (normal voice): stage preview image / video keyframes -> send into Realtime as vision context
//
//  ✅ FIX (IMPORTANT):
//  - Do NOT send multiple base64 images in one DataChannel message (too large -> drops).
//  - Use RealtimeQuickService.injectImageURLs (one image per item + queue/flush) to reliably inject vision context.
//

// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-365640bb2811480d9466d2a129f4f836f6099065fd7cb8632e60393c2ca395d3"
// Source-SHA256: "6503af21166a5d023d7cae92291313d19eac64166326070b4cfdd8dfe8ddfbfe"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI
import AVKit
import UIKit
import AVFoundation
import Photos
import Combine

// MARK: - Haptics (heavy) — ✅ throttle 防止系统 haptics helper 报错/卡顿
enum Haptics {
    private static var lastFire: CFAbsoluteTime = 0
    static func heavy(minInterval: CFAbsoluteTime = 0.18) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastFire >= minInterval else { return }
        lastFire = now
        let gen = UIImpactFeedbackGenerator(style: .heavy)
        gen.prepare()
        gen.impactOccurred()
    }
}

struct ContentView: View {

    @Binding var libraryPlayURL: URL?
    init(libraryPlayURL: Binding<URL?> = .constant(nil)) { _libraryPlayURL = libraryPlayURL }

    @Environment(\.scenePhase) private var scenePhase

    // ✅ Only read billing snapshot for UI (credits badge / canSend). Purchases & paywall handled by SolaraPaywallCenter.
    @StateObject private var billing = SolaraBillingStore.shared

    // ✅ Realtime is pure realtime now (no paywall / no billing inside)
    @StateObject private var rt = RealtimeGateController.shared


    // MARK: - Debug / Feature Flags

    /// 临时：绕过“波纹键”门禁（不走 /billing/voice/start 等），直接连接 Realtime。
    /// Debug 默认开启；如果你想恢复门禁：
    ///   UserDefaults.standard.set(false, forKey: "bypassRippleGate")
    private var bypassRippleGate: Bool {
#if DEBUG
        return UserDefaults.standard.object(forKey: "bypassRippleGate") as? Bool ?? true
#else
        return UserDefaults.standard.bool(forKey: "bypassRippleGate")
#endif
    }

    // ✅ DEV: bypass video send/paywall gating (credits). Default true in DEBUG.
    // You can toggle at runtime via:
    //   UserDefaults.standard.set(false, forKey: "bypassVideoGate")
    private var bypassVideoGate: Bool {
#if DEBUG
        return UserDefaults.standard.object(forKey: "bypassVideoGate") as? Bool ?? true
#else
        return UserDefaults.standard.bool(forKey: "bypassVideoGate")
#endif
    }



    // ✅ Centralized paywall controller (BillingKit.swift)
    @ObservedObject private var pay = SolaraPaywallCenter.shared

    @State private var prompt: String = ""

    @State private var previewImage: UIImage?
    @State private var previewVideoURL: URL?

    // ✅ NEW: inline preview video player (input)
    @State private var previewVideoPlayer: AVPlayer?
    @State private var previewVideoIsPlaying: Bool = false

    @State private var outputVideoURL: URL?
    @State private var player: AVPlayer?
    @State private var showPlayer = false
    @State private var playerDragOffset: CGFloat = 0

    @State private var showPlayerActions = false
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
    @State private var playerToastText: String?
    @State private var showPlayerToast = false
    @State private var nowPlayingPrompt: String = ""

    // ✅ New: best-effort base OpenAI video_id for current playback (for remix)
    @State private var nowPlayingOpenAIVideoId: String? = nil

    @State private var showMediaSheet = false
    @State private var showImagePicker = false
    @State private var showVideoPicker = false
    @State private var pickFromCamera = false

    @State private var errorMessage: String?
    @State private var showErrorAlert = false

    @FocusState private var isTextFieldFocused: Bool
    @State private var previewOffset: CGSize = .zero

    @StateObject private var jobManager = VideoJobManager.shared
    @State private var showJobsSheet = false

    @State private var topToastText: String?
    @State private var showTopToastFlag = false
    @State private var topToastTask: Task<Void, Never>?

    @State private var playerToastTask: Task<Void, Never>?

    // ✅ Billing refresh: only one in-flight
    @State private var billingRefreshTask: Task<Void, Never>?

    // ✅ 阿杜委托界面
    @State private var showAduDelegate = false

    // ✅ 阿杜六足机器人模式
    @State private var showHexapodMode = false
    @State private var isRobotMode: Bool = false
    @State private var robotAutonomousMode: Bool = false
    @State private var currentRobotGoal: String = ""
    @State private var robotLoopRunning: Bool = false
    @State private var robotExecuteEnabled: Bool = false
    @State private var latestRobotScene: HexapodScene?
    @State private var lastRobotTranscript: String = ""
    @State private var lastRobotSkillId: String?
    @State private var lastRobotActions: [HexapodAction] = []
    @State private var lastRobotSay: String = ""
    @State private var lastRobotExecuted: Bool?
    @State private var robotStatusText: String = "未连接"
    @State private var robotLoopId: String = "robot_av_loop_001"
    @State private var robotLoopStartedAt: Date?
    @State private var robotLoopTask: Task<Void, Never>?
    @State private var robotSpeechSynthesizer = AVSpeechSynthesizer()
    @StateObject private var hexapodRobotService = HexapodRobotService()

    // ✅ Bus去重：防止 Realtime 同一段 summary 重复触发两次生成
    @State private var lastBusKey: Int?
    @State private var lastBusAt: Date = .distantPast

    // ✅ 波纹键“通话态”UI 锁存 + 防连点
    @State private var voiceUILatched: Bool = false
    @State private var lastVoiceTapAt: Date = .distantPast

    // ✅ “硬断”watchdog token：防止旧 hangup 的延迟断线误杀新通话
    @State private var callEpoch: UUID = UUID()

    // ✅ Ripple mode: normal voice call OR remix call (player)
    private enum RippleMode: Equatable {
        case normalVoice
        case remix(baseVideoId: String)
    }
    @State private var rippleMode: RippleMode? = nil

    // ✅ remix pending state (set when start remix call)
    @State private var remixPendingBaseVideoId: String? = nil
    @State private var remixSubmittedEpoch: UUID? = nil

    // ✅ NEW: staged visual context for realtime (image or keyframes)
    private enum StagedVisualKind { case image, video }
    private struct StagedRealtimeVisual {
        let epoch: UUID
        let kind: StagedVisualKind
        let imageDataURLs: [String]   // data:image/jpeg;base64,...
    }

    @State private var stagedRTVisual: StagedRealtimeVisual? = nil
    @State private var stagedRTVisualSentEpoch: UUID? = nil
    @State private var stagedRTVisualPreparingEpoch: UUID? = nil
    @State private var stagedRTVisualIsPreparing: Bool = false

    private var hasMedia: Bool { previewImage != nil || previewVideoURL != nil }
    private var hasTypedText: Bool { !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // ✅ 统一口径：UI 认为“语音活跃”的状态
    private var uiVoiceActive: Bool {
        (rippleMode != nil) || voiceUILatched || rt.isConnecting || rt.isRunning
    }

    // ✅ Decide which mode to start when ripple is tapped (player -> remix if possible)
    private var desiredRippleModeToStart: RippleMode {
        if showPlayer, let baseId = nowPlayingOpenAIVideoId, !baseId.isEmpty {
            return .remix(baseVideoId: baseId)
        }
        return .normalVoice
    }

    var body: some View {
        mainBody
            .background(appBackground)
            .applyAlerts(showErrorAlert: $showErrorAlert, errorMessage: errorMessage)
            .applyPaywall(
                showPaywall: $pay.showPaywall,
                offeringId: pay.offeringId,
                onDismiss: { pay.onPaywallDismissed() }
            )
            .applyJobs(showJobsSheet: $showJobsSheet, jobManager: jobManager) { job in
                guard let url = job.resultURL else { return }
                Task { @MainActor in
                    nowPlayingOpenAIVideoId = bestEffortExtractOpenAIVideoId(from: job)
                    stopRealtimeIfNeeded()
                    dismissAllTransientSheets()
                    nowPlayingPrompt = job.prompt
                    jobManager.markConsumed(job.id)
                    startPlayback(from: url)
                }
            }
            .applyOverlays(
                showTopToastFlag: $showTopToastFlag,
                topToastText: topToastText,
                hudJob: jobManager.hudJob,
                onHudTap: { job in
                    if job.state == .done, let url = job.resultURL {
                        Task { @MainActor in
                            nowPlayingOpenAIVideoId = bestEffortExtractOpenAIVideoId(from: job)
                            stopRealtimeIfNeeded()
                            dismissAllTransientSheets()
                            nowPlayingPrompt = job.prompt
                            jobManager.markConsumed(job.id)
                            startPlayback(from: url)
                        }
                    } else {
                        showJobsSheet = true
                    }
                }
            )
            .applyPlayer(
                showPlayer: $showPlayer,
                onDismiss: onPlayerDismiss,
                player: $player,
                outputVideoURL: $outputVideoURL,
                playerDragOffset: $playerDragOffset,
                showPlayerActions: $showPlayerActions,
                showShareSheet: $showShareSheet,
                shareItems: $shareItems,
                nowPlayingPrompt: $nowPlayingPrompt,
                showToast: $showPlayerToast,
                toastText: $playerToastText,
                onConfigureAudio: { configureAudioForVideoPlayback() },
                onSaveToPhotos: { saveCurrentPlaybackToAlbum() },
                onShare: { shareCurrentPlayback() },
                onCopyPrompt: { copyPromptNow() },
                onDelete: { deleteCurrentPlaybackEverywhere() },
                onToast: { showPlayerToastNow($0) }
            )
            .applyMediaPickers(
                showMediaSheet: $showMediaSheet,
                showImagePicker: $showImagePicker,
                showVideoPicker: $showVideoPicker,
                pickFromCamera: $pickFromCamera,
                onPickImage: { image in
                    Task { @MainActor in
                        if let image { setPreviewImage(image) }
                    }
                },
                onPickVideo: { url in
                    Task { @MainActor in
                        if let url { setPreviewVideo(url) }
                    }
                }
            )
            .task {
                rt.setupOnceIfNeeded()
                rt.onUserFinalTranscript = { text in
                    Task { @MainActor in
                        await self.handleRobotVoiceTranscript(text)
                    }
                }
                refreshBillingNow()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background || phase == .inactive {
                    stopRealtimeIfNeeded()
                } else if phase == .active {
                    rt.setupOnceIfNeeded()
                    refreshBillingNow()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                rt.setupOnceIfNeeded()
                refreshBillingNow()
            }
            .onReceive(SoraIntentBus.shared.publisher) { p in
                guard !isRobotMode else { return }
                let t = p.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { return }

                let key = t.hashValue
                let now = Date()
                if let k = lastBusKey, k == key, now.timeIntervalSince(lastBusAt) < 1.2 {
                    return
                }
                lastBusKey = key
                lastBusAt = now

                Task { await submitPromptToSora(t) }
            }
            .onReceive(rt.$isRunning.dropFirst()) { running in
                if running == false {
                    pay.endVoiceIfNeeded()
                }
                // ✅ NEW: call becomes running -> send staged media if ready
                if running == true {
                    Task { @MainActor in
                        await sendStagedRealtimeVisualIfNeeded()
                    }
                }
            }
            .onChange(of: libraryPlayURL) { _, newURL in
                guard let url = newURL else { return }
                DispatchQueue.main.async { self.libraryPlayURL = nil }

                Task { @MainActor in
                    stopRealtimeIfNeeded()
                    dismissAllTransientSheets()

                    if let meta = VideoLibraryStore.shared.videos.first(where: { $0.fileName == url.lastPathComponent }) {
                        nowPlayingPrompt = meta.prompt
                        nowPlayingOpenAIVideoId = bestEffortExtractOpenAIVideoId(from: meta)
                    } else {
                        nowPlayingOpenAIVideoId = nil
                    }

                    if showPlayer, player != nil {
                        outputVideoURL = url
                        player?.pause()
                        player = AVPlayer(url: url)
                        playerDragOffset = 0
                        return
                    }
                    startPlayback(from: url)
                }
            }
            .onChange(of: previewVideoURL) { _, newURL in
                Task { @MainActor in
                    configurePreviewVideoPlayer(with: newURL)
                }
            }
            .onChange(of: previewImage) { _, newImg in
                if newImg != nil {
                    Task { @MainActor in
                        configurePreviewVideoPlayer(with: nil)
                    }
                }
            }
    }
}

// MARK: - Main body
private extension ContentView {

    var mainBody: some View {
        ZStack {
            VStack(spacing: 16) {
                headerBar
                previewSection
                realtimeSection
                Spacer()
                robotControlSection
                bottomSection
            }
        }
    }

    @ViewBuilder
    var robotControlSection: some View {
        if isRobotMode {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        Task { @MainActor in
                            await sendRobotStopFromContentView()
                        }
                    } label: {
                        Label("STOP", systemImage: "stop.fill")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.red)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Toggle(isOn: Binding(
                        get: { robotAutonomousMode },
                        set: { enabled in
                            robotAutonomousMode = enabled
                            if enabled {
                                startRobotAutonomousLoopIfNeeded()
                            } else {
                                stopRobotAutonomousLoop(sendStop: false)
                            }
                        }
                    )) {
                        Text("视觉自主行走：\(robotAutonomousMode ? "开" : "关")")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.92))
                    }
                    .toggleStyle(.switch)
                    .tint(.orange)

                    Toggle(isOn: $robotExecuteEnabled) {
                        Text("自主执行：\(robotExecuteEnabled ? "开启" : "关闭")")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.92))
                    }
                    .toggleStyle(.switch)
                    .tint(.red)
                }

                Text(robotStatusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.78))
                    .lineLimit(2)

                if !currentRobotGoal.isEmpty {
                    Text("goal = \(currentRobotGoal) · loop = \(robotLoopRunning ? "running" : "idle")")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.68))
                        .lineLimit(1)
                }

                if let skill = lastRobotSkillId, !skill.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(lastRobotSay.isEmpty ? "动作预览" : lastRobotSay)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(3)
                        Text("skill_id = \(skill)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.75))
                            .lineLimit(1)
                        Text("actions = " + lastRobotActions.map { action in
                            if let d = action.duration_ms { return "\(action.cmd) \(d)" }
                            return action.cmd
                        }.joined(separator: "、"))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.82))
                        .lineLimit(3)
                        Text(lastRobotExecuted == true ? "已执行" : "动作预览，未执行")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(lastRobotExecuted == true ? Color.green.opacity(0.9) : Color.orange.opacity(0.95))
                    }
                    .padding(10)
                    .background(Color.black.opacity(0.22))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.12))
        }
    }

    var headerBar: some View {
        HStack {
            Text(isRobotMode ? "Ultra · 机器人 6.2 · 音视频自主行走" : "Solara AI")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.76)

            Spacer()

            Button {
                Haptics.heavy()
                openVideoPaywall()
            } label: {
                Text("🎬 \(billing.videoCredits)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.95))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.30))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Button {
                Haptics.heavy()
                stopRealtimeIfNeeded()
                dismissAllTransientSheets()
                pay.openSubscriptionPaywall(pendingStartVoice: false, connectRealtime: nil)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: billing.isPro ? "checkmark.seal.fill" : "crown.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Pro")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.30))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            // ✅ 阿杜委托按钮
            Button {
                Haptics.heavy()
                showAduDelegate = true
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color(red: 0, green: 1, blue: 0.53))
                        .frame(width: 7, height: 7)
                    Text("阿杜")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.30))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showAduDelegate) {
                AduDelegateView()
            }

            // ✅ 进入机器人（阿杜六足机器人模式）
            Button {
                Haptics.heavy()
                withAnimation(.easeInOut(duration: 0.18)) {
                    isRobotMode.toggle()
                }
                if isRobotMode {
                    robotStatusText = "音视频自主行走已开启"
                } else {
                    stopRobotAutonomousLoop(sendStop: false)
                    robotStatusText = "已退出机器人模式"
                }
            } label: {
                Image(systemName: "figure.walk.motion")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(isRobotMode ? Color.red.opacity(0.88) : Color.black.opacity(0.30))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }

    @ViewBuilder
    var previewSection: some View {
        if hasMedia {
            previewBox()
                .offset(previewOffset)
                // ✅ simultaneousGesture: allow play/pause button while keeping drag-to-clear
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            let x = max(-140, min(140, value.translation.width))
                            let y = max(-220, min(40, value.translation.height))
                            previewOffset = CGSize(width: x, height: y)
                        }
                        .onEnded { value in
                            if value.translation.height < -80 {
                                Haptics.heavy()
                                clearPreviewMedia()
                                withAnimation { previewOffset = .zero }
                            } else {
                                withAnimation { previewOffset = .zero }
                            }
                        }
                )
                .padding(.top, 4)
        } else {
            Spacer().frame(height: 8)
        }
    }

    @ViewBuilder
    var realtimeSection: some View {
        let t = rt.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let h = rt.hint.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldShow = uiVoiceActive || !t.isEmpty || !h.isEmpty || stagedRTVisualIsPreparing

        if shouldShow {
            VStack(spacing: 10) {

                if stagedRTVisualIsPreparing {
                    RealtimeHintBubble(text: "Preparing media for assistant…")
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if rt.isConnecting {
                    RealtimeHintBubble(text: h.isEmpty ? "Connecting…" : h)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if !h.isEmpty && t.isEmpty {
                    RealtimeHintBubble(text: h)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !t.isEmpty {
                    RealtimeTranscriptBubble(text: t)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
        }
    }

    var bottomSection: some View {
        ZStack(alignment: .bottom) {
            BottomInputBar(
                text: $prompt,
                hasMedia: hasMedia,
                isTextFieldFocused: $isTextFieldFocused,
                canSend: isRobotMode || (bypassVideoGate || billing.videoCredits > 0),
                placeholder: isRobotMode ? "对阿杜说：来我这里 / 跟着我 / 往前走但别撞到东西" : "Describe a new video",
                onPlus: { Haptics.heavy(); showMediaSheet = true },
                onSend: { handleSendTapped() },
                onSendBlocked: { openVideoPaywall() }
            )

            // ✅ 通话中强制显示“可挂断”按钮，不允许变回黑色 idle
            let showVoiceButton = uiVoiceActive || !hasTypedText

            CenterRealtimeButton(
                isConnecting: rt.isConnecting,
                isRunning: uiVoiceActive,
                onTap: { Haptics.heavy(); handleRippleTapped() }
            )
            .offset(y: -74)
            .opacity(showVoiceButton ? 1 : 0)
            .allowsHitTesting(showVoiceButton)
            .animation(.easeInOut(duration: 0.2), value: showVoiceButton)
        }
    }

    var appBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 0.22, green: 0.30, blue: 0.44),
                Color(red: 0.16, green: 0.26, blue: 0.42),
                Color(red: 0.08, green: 0.12, blue: 0.27)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

// MARK: - Helpers
private extension ContentView {

    // MARK: - Preview media setters

    @MainActor
    func setPreviewImage(_ image: UIImage) {
        previewImage = image
        previewVideoURL = nil
        configurePreviewVideoPlayer(with: nil)
        stagedRTVisual = nil
        stagedRTVisualSentEpoch = nil
        stagedRTVisualPreparingEpoch = nil
        stagedRTVisualIsPreparing = false
    }

    @MainActor
    func setPreviewVideo(_ url: URL) {
        previewVideoURL = url
        previewImage = nil
        configurePreviewVideoPlayer(with: url)
        stagedRTVisual = nil
        stagedRTVisualSentEpoch = nil
        stagedRTVisualPreparingEpoch = nil
        stagedRTVisualIsPreparing = false
    }

    @MainActor
    func clearPreviewMedia() {
        previewImage = nil
        previewVideoURL = nil
        configurePreviewVideoPlayer(with: nil)
        stagedRTVisual = nil
        stagedRTVisualSentEpoch = nil
        stagedRTVisualPreparingEpoch = nil
        stagedRTVisualIsPreparing = false
    }

    @MainActor
    func configurePreviewVideoPlayer(with url: URL?) {
        previewVideoPlayer?.pause()
        previewVideoPlayer = nil
        previewVideoIsPlaying = false

        guard let url else { return }
        let p = AVPlayer(url: url)
        p.actionAtItemEnd = .pause
        previewVideoPlayer = p
    }

    @MainActor
    func togglePreviewVideoPlayPause() {
        guard let p = previewVideoPlayer else { return }
        if previewVideoIsPlaying {
            p.pause()
            previewVideoIsPlaying = false
        } else {
            p.play()
            previewVideoIsPlaying = true
        }
    }

    // MARK: - Stage preview media -> Realtime (vision)

    func stagePreviewMediaForRealtimeIfNeeded() {
        guard hasMedia else {
            stagedRTVisual = nil
            stagedRTVisualSentEpoch = nil
            stagedRTVisualPreparingEpoch = nil
            stagedRTVisualIsPreparing = false
            return
        }

        let epoch = UUID()
        stagedRTVisualPreparingEpoch = epoch
        stagedRTVisualIsPreparing = true

        let img = previewImage
        let vid = previewVideoURL

        Task.detached(priority: .userInitiated) {
            let payload = await Self.buildStagedRealtimeVisual(epoch: epoch, image: img, videoURL: vid)

            await MainActor.run {
                guard self.stagedRTVisualPreparingEpoch == epoch else { return }
                self.stagedRTVisualIsPreparing = false
                self.stagedRTVisual = payload
                self.stagedRTVisualSentEpoch = nil

                if self.rt.isRunning {
                    Task { @MainActor in
                        await self.sendStagedRealtimeVisualIfNeeded()
                    }
                }
            }
        }
    }

    // ✅ must be private because return type is private
    private static func buildStagedRealtimeVisual(
        epoch: UUID,
        image: UIImage?,
        videoURL: URL?
    ) async -> StagedRealtimeVisual? {

        // ✅ 更稳：降低分辨率/质量，避免 dataURL 过大导致 DataChannel 丢包
        let maxDim: CGFloat = 512

        if let image {
            guard let dataURL = Self.jpegDataURL(from: image, maxDim: maxDim, quality: 0.68) else { return nil }
            return StagedRealtimeVisual(epoch: epoch, kind: .image, imageDataURLs: [dataURL])
        }

        if let videoURL {
            let frames = await Self.keyframeJPEGDataURLs(from: videoURL, maxFrames: 3, maxDim: maxDim, quality: 0.62)
            guard !frames.isEmpty else { return nil }
            return StagedRealtimeVisual(epoch: epoch, kind: .video, imageDataURLs: frames)
        }

        return nil
    }

    private static func jpegDataURL(from image: UIImage, maxDim: CGFloat, quality: CGFloat) -> String? {
        guard let data = Self.jpegData(from: image, maxDim: maxDim, quality: quality) else { return nil }
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }

    private static func jpegData(from image: UIImage, maxDim: CGFloat, quality: CGFloat) -> Data? {
        let size = image.size
        let maxSide = max(size.width, size.height)
        let scale = min(1.0, maxDim / maxSide)
        let newSize = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))

        let renderer = UIGraphicsImageRenderer(size: newSize)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return rendered.jpegData(compressionQuality: quality)
    }

    private static func keyframeJPEGDataURLs(
        from videoURL: URL,
        maxFrames: Int,
        maxDim: CGFloat,
        quality: CGFloat
    ) async -> [String] {

        let asset = AVAsset(url: videoURL)

        let duration: CMTime
        if #available(iOS 16.0, *) {
            duration = (try? await asset.load(.duration)) ?? .zero
        } else {
            duration = asset.duration
        }

        let total = CMTimeGetSeconds(duration)
        guard total.isFinite, total > 0.05 else { return [] }

        let a = 0.05
        let b = min(total * 0.50, max(0.06, total - 0.08))
        let c = min(total * 0.85, max(0.06, total - 0.08))
        let secs = [a, b, c].prefix(maxFrames)

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxDim, height: maxDim)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero

        var out: [String] = []
        for s in secs {
            do {
                var actual = CMTime.zero
                let cg = try gen.copyCGImage(at: CMTime(seconds: s, preferredTimescale: 600), actualTime: &actual)
                let ui = UIImage(cgImage: cg)
                if let url = Self.jpegDataURL(from: ui, maxDim: maxDim, quality: quality) {
                    out.append(url)
                }
            } catch { continue }
        }
        return out
    }

    /// ✅ FIX: 用 RealtimeQuickService 的 injectImageURLs（分片 + 排队 + flush）
    /// - 不再用反射找 RTCDataChannel
    /// - 不再把多张 base64 放进一个巨大 JSON 里
    @MainActor
    func sendStagedRealtimeVisualIfNeeded() async {
        guard rt.isRunning else { return }
        guard let staged = stagedRTVisual else { return }
        if stagedRTVisualSentEpoch == staged.epoch { return }

        stagedRTVisualSentEpoch = staged.epoch

        // ✅ 关键：一张图一个 item + DC 未 open 自动排队（你 RealtimeQuickService 已实现）
        // requestAck: true -> 让模型回一句确认已收到（避免用户误以为没上传）
        RealtimeQuickService.shared.injectImageURLs(staged.imageDataURLs, requestAck: true)

        // 可选：提示用户（不影响原功能）
        showTopToast(staged.kind == .image ? "Image sent to Realtime." : "Video frames sent to Realtime.")
    }

    // MARK: - Billing refresh / player dismiss

    func refreshBillingNow() {
        billingRefreshTask?.cancel()
        billingRefreshTask = Task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            if Task.isCancelled { return }
            await billing.refreshMe()
        }
    }

    func onPlayerDismiss() {
        player?.pause()
        player = nil
        playerDragOffset = 0
        showPlayerActions = false
        showShareSheet = false

        let stillInCall = uiVoiceActive
        nowPlayingOpenAIVideoId = nil

        if !stillInCall {
            remixPendingBaseVideoId = nil
            rippleMode = nil
            voiceUILatched = false
        }
    }

    // MARK: - Ripple Toggle (Black -> Blue call, Blue -> end)

    func handleRippleTapped() {
        // ✅ 挂断永远不 debounce（避免“刚接通立刻点关闭被 0.35s 过滤”）
        if uiVoiceActive {
            stopRealtimeIfNeeded()
            return
        }

        // ✅ 只有“开始通话”才做防连点
        let now = Date()
        if now.timeIntervalSince(lastVoiceTapAt) < 0.35 { return }
        lastVoiceTapAt = now

        startRippleCall(mode: desiredRippleModeToStart)
    }

    private func startRippleCall(mode: RippleMode) {
        let epoch = UUID()
        callEpoch = epoch
        rippleMode = mode
        voiceUILatched = true
        isTextFieldFocused = false
        dismissAllTransientSheets()

        switch mode {
        case .normalVoice:
            remixPendingBaseVideoId = nil

            // ✅ stage preview media (if any) before connect (仅做压缩/抽帧，不发送)
            stagePreviewMediaForRealtimeIfNeeded()

            if bypassRippleGate {
                rt.connect()
            } else {
                pay.requestStartVoice(
                    connectRealtime: {
                        Task { @MainActor in
                            guard self.callEpoch == epoch else { return }   // 防止 payflow 延迟回调“复活通话”
                            self.rt.connect()
                        }
                    },
                    hangupRealtime: {
                        Task { @MainActor in self.stopRealtimeIfNeeded() }
                    }
                )
            }

        case .remix(let baseVideoId):
            remixPendingBaseVideoId = baseVideoId
            rt.transcript = ""
            rt.hint = "Tell me how to modify this video…"

            if bypassRippleGate {
                rt.connect()
            } else {
                pay.requestStartVoice(
                    connectRealtime: {
                        Task { @MainActor in
                            guard self.callEpoch == epoch else { return }   // 防止 payflow 延迟回调“复活通话”
                            self.rt.connect()
                        }
                    },
                    hangupRealtime: {
                        Task { @MainActor in self.stopRealtimeIfNeeded() }
                    }
                )
            }

            showTopToast("🎤 Speak changes for remix…")
        }
    }

    /// ✅ 高级稳定挂断：
    /// 1) 永远调用 rt.disconnect()
    /// 2) watchdog 再断两次（防偶发）
    /// 3) Remix 模式：挂断后自动提交二次生成任务（由助手完成）
    func stopRealtimeIfNeeded() {
        let myEpoch = UUID()
        callEpoch = myEpoch
        let pendingBaseId = remixPendingBaseVideoId
        let wasRemixMode: Bool = (pendingBaseId != nil)

        voiceUILatched = false
        rippleMode = nil
        pay.endVoiceIfNeeded()

        // keep staged media but reset "sent" marker for next call
        stagedRTVisualSentEpoch = nil
        stagedRTVisualPreparingEpoch = nil
        stagedRTVisualIsPreparing = false

        rt.disconnect()
        rt.disconnect() // ✅ 硬停底层 WebRTC/AudioSession，防“UI已关但仍在通话”

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            guard self.callEpoch == myEpoch else { return }
            self.rt.disconnect()
            self.rt.disconnect()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            guard self.callEpoch == myEpoch else { return }
            self.rt.disconnect()
            self.rt.disconnect()
        }

        if wasRemixMode, let baseId = pendingBaseId {
            remixPendingBaseVideoId = nil

            let submitEpoch = UUID()
            remixSubmittedEpoch = submitEpoch

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                guard self.remixSubmittedEpoch == submitEpoch else { return }

                let raw = self.rt.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else {
                    self.showTopToast("No remix instruction captured.")
                    return
                }
                self.enqueueRemixViaAssistant(baseVideoId: baseId, userVoiceText: raw)
            }
        }
    }

    // MARK: - Remix enqueue (assistant completes)

    @MainActor
    func enqueueRemixViaAssistant(baseVideoId: String, userVoiceText: String) {
        if (!bypassVideoGate && billing.videoCredits <= 0) {
            showTopToast("No video credits. Please buy a pack.")
            openVideoPaywall()
            return
        }

        let structured =
        """
        [REMIX_REQUEST]
        base_video_id: \(baseVideoId)
        user_instruction: \(userVoiceText)
        rules:
        - convert to ONE concise English remix prompt
        - preserve subject & camera motion unless user explicitly requests changes
        - no extra explanation in output
        [/REMIX_REQUEST]
        """

        jobManager.enqueue(prompt: structured, imageFileURL: nil, videoFileURL: nil)
        showTopToast("Remix queued…")
    }

    // MARK: - Other helpers

    func dismissAllTransientSheets() {
        showMediaSheet = false
        showImagePicker = false
        showVideoPicker = false
        showShareSheet = false
        showPlayerActions = false
        showJobsSheet = false
    }

    func openVideoPaywall() {
        stopRealtimeIfNeeded()
        dismissAllTransientSheets()
        pay.openVideoPaywall()
    }

    func handleSendTapped() {
        let hasContent = (!prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || hasMedia
        guard hasContent else { return }

        if isRobotMode {
            let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            prompt = ""
            Task { @MainActor in
                await handleRobotVoiceTranscript(text)
            }
            return
        }

        if (!bypassVideoGate && billing.videoCredits <= 0) {
            Task { @MainActor in showTopToast("No video credits. Please buy a pack.") }
            openVideoPaywall()
            return
        }
        Task { await tapGenerate() }
    }

    @MainActor
    func handleRobotVoiceTranscript(_ transcript: String) async {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard isRobotMode else { return }

        lastRobotTranscript = text

        if isRobotStopTranscript(text) {
            await sendRobotStopFromContentView()
            return
        }

        currentRobotGoal = inferRobotGoal(from: text)
        robotLoopId = "robot_av_loop_\(Int(Date().timeIntervalSince1970))"

        if robotAutonomousMode {
            robotStatusText = robotExecuteEnabled ? "目标已更新，正在自主闭环执行…" : "目标已更新，正在自主闭环预览…"
            startRobotAutonomousLoopIfNeeded()
            return
        }

        let scene = currentHexapodSceneFromVision()
        latestRobotScene = scene
        robotStatusText = robotExecuteEnabled ? "正在执行语音视觉动作…" : "正在生成动作预览…"

        do {
            let response = try await hexapodRobotService.sendPerceptionTick(
                goal: currentRobotGoal,
                transcript: text,
                scene: scene,
                execute: robotExecuteEnabled
            )
            lastRobotSkillId = response.skill_id
            lastRobotActions = response.actions ?? []
            lastRobotSay = response.after_action_say ?? response.error ?? "好的。"
            lastRobotExecuted = response.executed
            robotStatusText = response.executed == true ? "已执行" : "动作预览，未执行"
            if response.continue_loop == true,
               robotExecuteEnabled,
               let next = response.next_tick_after_ms {
                robotStatusText += " · 下次建议 \(next)ms 后感知"
            }
            showTopToast(lastRobotSay)
            if response.executed == true {
                speakRobotAfterAction(lastRobotSay)
            }
        } catch {
            robotStatusText = "机器人感知失败：\(error.localizedDescription)"
            showTopToast(robotStatusText)
        }
    }

    @MainActor
    func sendRobotStopFromContentView() async {
        stopRobotAutonomousLoop(sendStop: false)
        do {
            try await hexapodRobotService.sendStop()
            lastRobotSkillId = "safe_stop"
            lastRobotActions = [HexapodAction(cmd: "STOP", duration_ms: nil)]
            lastRobotSay = "已停止。"
            lastRobotExecuted = true
            robotStatusText = "已发送 STOP"
            showTopToast("已停止。")
            speakRobotAfterAction("已停止。")
        } catch {
            robotStatusText = "STOP 失败：\(error.localizedDescription)"
            showTopToast(robotStatusText)
        }
    }

    func inferRobotGoal(from transcript: String) -> String {
        let text = transcript.lowercased()
        if containsAny(text, ["来我这里", "过来", "靠近我", "到我这边"]) {
            return "approach_user"
        }
        if containsAny(text, ["跟着我", "跟随我"]) {
            return "follow_user"
        }
        if containsAny(text, ["找门", "门口"]) {
            return "find_door"
        }
        if containsAny(text, ["往前", "前进", "走", "靠近一点"]) {
            return "move_forward_safely"
        }
        if containsAny(text, ["看到了什么", "看一下", "观察"]) {
            return "describe_scene"
        }
        if containsAny(text, ["巡逻"]) {
            return "patrol"
        }
        return "general_robot_intent"
    }

    @MainActor
    func startRobotAutonomousLoopIfNeeded() {
        guard isRobotMode, robotAutonomousMode else { return }
        guard !currentRobotGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            robotStatusText = "请先说一个目标，例如：来我这里"
            return
        }
        guard robotLoopTask == nil else { return }

        robotLoopRunning = true
        robotLoopStartedAt = Date()
        robotLoopTask = Task { @MainActor in
            await runRobotAutonomousAVLoop()
        }
    }

    @MainActor
    func stopRobotAutonomousLoop(sendStop: Bool) {
        robotLoopTask?.cancel()
        robotLoopTask = nil
        robotLoopRunning = false
        if sendStop {
            Task { @MainActor in
                await sendRobotStopFromContentView()
            }
        }
    }

    @MainActor
    func runRobotAutonomousAVLoop() async {
        defer {
            robotLoopTask = nil
            robotLoopRunning = false
        }

        let started = robotLoopStartedAt ?? Date()
        while !Task.isCancelled && robotAutonomousMode && isRobotMode {
            if Date().timeIntervalSince(started) > 60 {
                robotStatusText = "自主行走已到 60 秒上限，自动停止"
                try? await hexapodRobotService.sendStop()
                break
            }

            let goal = currentRobotGoal.trimmingCharacters(in: .whitespacesAndNewlines)
            if goal.isEmpty {
                robotStatusText = "等待语音目标"
                break
            }

            let scene = currentHexapodSceneFromVision()
            latestRobotScene = scene

            if !robotSceneAllowsForwardOrMotion(scene), goalRequiresMotion(goal) {
                robotStatusText = "视觉不确定或前方不安全，先停下"
                lastRobotSkillId = "low_confidence_stop"
                lastRobotActions = [HexapodAction(cmd: "STOP", duration_ms: nil)]
                lastRobotSay = "我还没看清楚，先停下。"
                lastRobotExecuted = false
                try? await hexapodRobotService.sendStop()
                break
            }

            do {
                let response = try await hexapodRobotService.sendAutonomousTick(
                    goal: goal,
                    transcript: lastRobotTranscript,
                    scene: scene,
                    execute: robotExecuteEnabled
                )
                lastRobotSkillId = response.skill_id
                lastRobotActions = clampRobotActionsForDisplay(response.actions ?? [])
                lastRobotSay = response.after_action_say ?? response.error ?? "好的。"
                lastRobotExecuted = response.executed
                robotStatusText = response.executed == true ? "动作后继续观察…" : "闭环预览，未执行"

                if response.executed == true {
                    showTopToast(lastRobotSay)
                    speakRobotAfterAction(lastRobotSay)
                }

                guard response.continue_loop == true else {
                    robotStatusText = response.executed == true ? "本轮目标完成" : "预览完成"
                    break
                }

                let waitMs = min(max(response.next_tick_after_ms ?? 800, 500), 1200)
                try? await Task.sleep(nanoseconds: UInt64(waitMs) * 1_000_000)
            } catch {
                robotStatusText = "自主闭环失败：\(error.localizedDescription)"
                break
            }
        }
    }

    func goalRequiresMotion(_ goal: String) -> Bool {
        ["approach_user", "follow_user", "move_forward_safely", "find_door", "patrol"].contains(goal)
    }

    func robotSceneAllowsForwardOrMotion(_ scene: HexapodScene) -> Bool {
        if scene.floor_unclear == true { return false }
        if scene.obstacle_front == true { return false }
        if (scene.confidence ?? 0) < 0.5 { return false }
        return true
    }

    func clampRobotActionsForDisplay(_ actions: [HexapodAction]) -> [HexapodAction] {
        actions.prefix(2).map { action in
            HexapodAction(cmd: action.cmd, duration_ms: action.duration_ms.map { min($0, 500) })
        }
    }

    func speakRobotAfterAction(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        robotSpeechSynthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: clean)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = 0.52
        robotSpeechSynthesizer.speak(utterance)
    }

    func currentHexapodSceneFromVision() -> HexapodScene {
        let snap = RobotPerceptionStore.shared.snapshot()
        let caption = snap.sceneDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let decision = snap.decision.trimmingCharacters(in: .whitespacesAndNewlines)
        let objectLabels = snap.objects.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let combined = (caption + " " + decision + " " + objectLabels.joined(separator: " ")).lowercased()
        let effectiveCaption = caption.isEmpty ? "暂无视觉结果" : caption

        return HexapodScene(
            caption: effectiveCaption,
            objects: objectLabels.isEmpty ? nil : objectLabels,
            vision_decision: decision.isEmpty ? nil : decision,
            person_visible: containsAny(combined, ["人", "person", "用户"]),
            person_position: inferRobotPersonPosition(from: combined),
            obstacle_front: containsAny(combined, ["障碍", "椅子", "桌子", "墙", "chair", "table", "wall"]),
            door_visible: containsAny(combined, ["门", "door"]),
            floor_unclear: effectiveCaption == "暂无视觉结果" || containsAny(combined, ["看不清", "不清楚", "unclear"]),
            free_space: containsAny(combined, ["空旷", "无障碍", "clear", "free"]) ? "front" : nil,
            confidence: snap.confidence > 0 ? snap.confidence : (caption.isEmpty ? 0.3 : 0.6)
        )
    }

    func inferRobotPersonPosition(from text: String) -> String? {
        if containsAny(text, ["右", "right"]) { return "right_front" }
        if containsAny(text, ["左", "left"]) { return "left_front" }
        if containsAny(text, ["中间", "正前方", "前方", "front"]) { return "center" }
        return nil
    }

    func isRobotStopTranscript(_ transcript: String) -> Bool {
        containsAny(transcript.lowercased(), ["停下", "停止", "别动", "stop"])
    }

    func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0.lowercased()) }
    }

    // MARK: - ✅ Preview Box (playable video)

    @ViewBuilder
    func previewBox() -> some View {
        let corner: CGFloat = 28
        let boxWidth: CGFloat = 230
        let boxHeight: CGFloat = 280

        ZStack {
            RoundedRectangle(cornerRadius: corner).fill(Color.white.opacity(0.10))

            if let img = previewImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: boxWidth, height: boxHeight)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: corner))
                    .overlay(
                        RoundedRectangle(cornerRadius: corner)
                            .stroke(Color.white.opacity(0.3), lineWidth: 1)
                    )

            } else if previewVideoURL != nil {

                ZStack {
                    if let p = previewVideoPlayer {
                        VideoPlayer(player: p)
                            .frame(width: boxWidth, height: boxHeight)
                            .clipShape(RoundedRectangle(cornerRadius: corner))
                            .overlay(
                                RoundedRectangle(cornerRadius: corner)
                                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
                            )
                            .onDisappear {
                                p.pause()
                                previewVideoIsPlaying = false
                            }
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "video.fill")
                                .font(.system(size: 40))
                                .foregroundColor(.white)
                            Text("1 video selected")
                                .foregroundColor(.white.opacity(0.9))
                                .font(.system(size: 15))
                        }
                    }

                    Button {
                        Haptics.heavy(minInterval: 0.12)
                        togglePreviewVideoPlayPause()
                    } label: {
                        Image(systemName: previewVideoIsPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Color.black.opacity(0.35))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 10)
                    .padding(.bottom, 10)
                }
                .frame(width: boxWidth, height: boxHeight)
                .clipShape(RoundedRectangle(cornerRadius: corner))

            } else {
                Text("Preview your media here")
                    .foregroundColor(.white.opacity(0.8))
                    .font(.system(size: 15))
            }

            VStack {
                Spacer()
                Text("Swipe up to clear")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.45))
                    .padding(.bottom, 10)
            }
            .frame(width: boxWidth, height: boxHeight)
        }
        .frame(width: boxWidth, height: boxHeight)
    }

    // MARK: - Playback / generation

    @MainActor
    func startPlayback(from url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "Video file is missing."
            showErrorAlert = true
            return
        }
        stopRealtimeIfNeeded()
        dismissAllTransientSheets()
        outputVideoURL = url
        playerDragOffset = 0
        player = AVPlayer(url: url)
        showPlayer = true
    }

    func tapGenerate() async {
        let (raw, hasMediaSnapshot) = await MainActor.run {
            (self.prompt.trimmingCharacters(in: .whitespacesAndNewlines),
             self.previewImage != nil || self.previewVideoURL != nil)
        }
        if raw.isEmpty && !hasMediaSnapshot { return }

        await MainActor.run {
            self.prompt = ""
            self.isTextFieldFocused = false
        }

        await submitPromptToSora(raw)
    }

    func submitPromptToSora(_ externalPrompt: String) async {
        let raw = externalPrompt.trimmingCharacters(in: .whitespacesAndNewlines)

        let (hasMediaSnapshot, snapshotImage, snapshotVideoURL) = await MainActor.run {
            (self.previewImage != nil || self.previewVideoURL != nil, self.previewImage, self.previewVideoURL)
        }
        if raw.isEmpty && !hasMediaSnapshot { return }

        let finalPrompt = raw.isEmpty ? "Create a short cinematic video based on the user's media." : raw

        let activeCount = await MainActor.run {
            self.jobManager.jobs.filter { $0.state == .queued || $0.state == .running }.count
        }
        if activeCount >= 3 {
            await MainActor.run { self.showTopToast("Too many tasks. Please wait…") }
            return
        }

        var imageURL: URL? = nil
        if let img = snapshotImage { imageURL = try? saveImageToTemp(img) }
        let videoURL = snapshotVideoURL

        await MainActor.run {
            self.nowPlayingPrompt = finalPrompt
            self.previewImage = nil
            self.previewVideoURL = nil
            self.configurePreviewVideoPlayer(with: nil)

            self.jobManager.enqueue(prompt: finalPrompt, imageFileURL: imageURL, videoFileURL: videoURL)
            self.showTopToast("Generating in background…")
        }
    }

    func saveImageToTemp(_ image: UIImage) throws -> URL {
        let data = image.jpegData(compressionQuality: 0.9) ?? Data()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("solara_input_\(UUID().uuidString).jpg")
        try data.write(to: tmp, options: .atomic)
        return tmp
    }

    // MARK: - Audio config / toasts / share / delete

    func configureAudioForVideoPlayback() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            print("Audio session error: \(error)")
        }
    }

    @MainActor
    func showTopToast(_ text: String) {
        topToastTask?.cancel()
        topToastTask = nil
        topToastText = text
        withAnimation(.easeOut(duration: 0.18)) { showTopToastFlag = true }
        topToastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if Task.isCancelled { return }
            withAnimation(.easeOut(duration: 0.18)) { showTopToastFlag = false }
        }
    }

    func shareCurrentPlayback() {
        if let url = preferredURLForCurrentPlaybackStable() {
            shareItems = [url]
            showShareSheet = true
        } else {
            showPlayerToastNow("Video file not found")
        }
    }

    func copyPromptNow() {
        let p = nowPlayingPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return }
        UIPasteboard.general.string = p
        showPlayerToastNow("Copied")
    }

    @MainActor
    func showPlayerToastNow(_ text: String) {
        playerToastTask?.cancel()
        playerToastTask = nil
        playerToastText = text
        withAnimation(.easeOut(duration: 0.18)) { showPlayerToast = true }
        playerToastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if Task.isCancelled { return }
            withAnimation(.easeOut(duration: 0.18)) { showPlayerToast = false }
        }
    }

    func preferredURLForCurrentPlaybackStable() -> URL? {
        guard let base = preferredURLForCurrentPlaybackRaw() else { return nil }
        return ensureStableLocalVideo(url: base) ?? base
    }

    func preferredURLForCurrentPlaybackRaw() -> URL? {
        if let url = outputVideoURL, FileManager.default.fileExists(atPath: url.path) { return url }
        let p = nowPlayingPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.isEmpty, let v = VideoLibraryStore.shared.videos.first(where: { $0.prompt == p }) {
            let u = VideoLibraryStore.shared.url(for: v)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    func ensureStableLocalVideo(url: URL) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first
        if let docs, url.path.hasPrefix(docs.path) { return url }

        do {
            let exportsDir = (docs ?? fm.temporaryDirectory).appendingPathComponent("exports", isDirectory: true)
            if !fm.fileExists(atPath: exportsDir.path) {
                try fm.createDirectory(at: exportsDir, withIntermediateDirectories: true)
            }
            let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
            let dest = exportsDir.appendingPathComponent("export_\(UUID().uuidString).\(ext)")
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: url, to: dest)
            return dest
        } catch {
            print("ensureStableLocalVideo copy failed: \(error)")
            return nil
        }
    }

    func saveCurrentPlaybackToAlbum() {
        guard let url = preferredURLForCurrentPlaybackStable() else {
            Task { @MainActor in showPlayerToastNow("Video file not found") }
            return
        }
        saveVideoToPhotosSafely(fileURL: url) { result in
            DispatchQueue.main.async {
                switch result {
                case .success: self.showPlayerToastNow("Saved to Photos")
                case .failure: self.showPlayerToastNow("Save failed. Please allow Photos access.")
                }
            }
        }
    }

    func deleteCurrentPlaybackEverywhere() {
        guard let url = preferredURLForCurrentPlaybackRaw() else {
            Task { @MainActor in showPlayerToastNow("Video file not found") }
            return
        }
        let fileName = url.lastPathComponent
        if let v = VideoLibraryStore.shared.videos.first(where: { $0.fileName == fileName }) {
            VideoLibraryStore.shared.delete(v)
        } else {
            try? FileManager.default.removeItem(at: url)
        }

        DispatchQueue.main.async {
            self.player?.pause()
            self.player = nil
            self.outputVideoURL = nil
            self.showPlayerToastNow("Deleted")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                self.showPlayer = false
            }
        }
    }

    func saveVideoToPhotosSafely(fileURL: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            completion(.failure(NSError(domain: "ContentView", code: -2,
                                        userInfo: [NSLocalizedDescriptionKey: "Video file missing"])))
            return
        }

        if #available(iOS 14, *) {
            let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            switch status {
            case .authorized, .limited:
                saveVideoToPhotos(fileURL: fileURL, completion: completion)
            case .notDetermined:
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                    if newStatus == .authorized || newStatus == .limited {
                        saveVideoToPhotos(fileURL: fileURL, completion: completion)
                    } else {
                        completion(.failure(NSError(domain: "ContentView", code: -3,
                                                    userInfo: [NSLocalizedDescriptionKey: "Photos permission denied"])))
                    }
                }
            default:
                completion(.failure(NSError(domain: "ContentView", code: -3,
                                            userInfo: [NSLocalizedDescriptionKey: "Photos permission denied"])))
            }
        } else {
            let status = PHPhotoLibrary.authorizationStatus()
            switch status {
            case .authorized:
                saveVideoToPhotos(fileURL: fileURL, completion: completion)
            case .notDetermined:
                PHPhotoLibrary.requestAuthorization { newStatus in
                    if newStatus == .authorized {
                        saveVideoToPhotos(fileURL: fileURL, completion: completion)
                    } else {
                        completion(.failure(NSError(domain: "ContentView", code: -3,
                                                    userInfo: [NSLocalizedDescriptionKey: "Photos permission denied"])))
                    }
                }
            default:
                completion(.failure(NSError(domain: "ContentView", code: -3,
                                            userInfo: [NSLocalizedDescriptionKey: "Photos permission denied"])))
            }
        }
    }

    func saveVideoToPhotos(fileURL: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
        }) { success, error in
            if success { completion(.success(())) }
            else {
                completion(.failure(error ?? NSError(domain: "ContentView", code: -4,
                                                     userInfo: [NSLocalizedDescriptionKey: "Save failed"])))
            }
        }
    }

    // MARK: - Best-effort extraction of OpenAI video id (no compile dependency)

    func bestEffortExtractOpenAIVideoId(from obj: Any) -> String? {
        let candidates = [
            "openaiVideoId", "openAIVideoId", "videoId", "remoteVideoId", "resultVideoId",
            "openai_id", "openaiId", "remoteId", "idRemote", "originVideoId", "sourceVideoId",
            "video_id", "id"
        ]

        let m = Mirror(reflecting: obj)
        for c in candidates {
            if let v = mirrorFindString(m, key: c), isLikelyVideoId(v) { return v }
        }

        for child in m.children {
            let mm = Mirror(reflecting: child.value)
            for c in candidates {
                if let v = mirrorFindString(mm, key: c), isLikelyVideoId(v) { return v }
            }
        }
        return nil
    }

    func mirrorFindString(_ mirror: Mirror, key: String) -> String? {
        for child in mirror.children {
            guard let label = child.label else { continue }
            if label == key {
                if let s = child.value as? String { return s }
                if let s = child.value as? String? { return s }
            }
        }
        return nil
    }

    func isLikelyVideoId(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("video_") && t.count > 12
    }
}

// MARK: - View Modifiers (local helpers)
private extension View {

    func applyAlerts(showErrorAlert: Binding<Bool>, errorMessage: String?) -> some View {
        self.alert("Error", isPresented: showErrorAlert) {
            Button("OK", role: .cancel) { Haptics.heavy() }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    func applyPaywall(
        showPaywall: Binding<Bool>,
        offeringId: String?,
        onDismiss: @escaping () -> Void
    ) -> some View {
        self.sheet(isPresented: showPaywall) {
            PaywallView(offeringId: offeringId ?? "default")
        }
        .onChange(of: showPaywall.wrappedValue) { _, showing in
            if showing == false { onDismiss() }
        }
    }

    func applyJobs(
        showJobsSheet: Binding<Bool>,
        jobManager: VideoJobManager,
        onPick: @escaping (VideoJob) -> Void
    ) -> some View {
        self.sheet(isPresented: showJobsSheet) {
            JobsListSheet(jobManager: jobManager) { job in
                onPick(job)
            }
        }
    }

    func applyOverlays(
        showTopToastFlag: Binding<Bool>,
        topToastText: String?,
        hudJob: VideoJob?,
        onHudTap: @escaping (VideoJob) -> Void
    ) -> some View {
        self
            .overlay(alignment: .top) {
                if showTopToastFlag.wrappedValue, let t = topToastText {
                    MiniTopToast(text: t)
                        .padding(.top, 10)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .overlay(alignment: .topTrailing) {
                if let job = hudJob {
                    Button { onHudTap(job) } label: { JobRingView(job: job) }
                        .buttonStyle(.plain)
                        .padding(.top, 10)
                        .padding(.trailing, 12)
                }
            }
    }

    func applyPlayer(
        showPlayer: Binding<Bool>,
        onDismiss: @escaping () -> Void,
        player: Binding<AVPlayer?>,
        outputVideoURL: Binding<URL?>,
        playerDragOffset: Binding<CGFloat>,
        showPlayerActions: Binding<Bool>,
        showShareSheet: Binding<Bool>,
        shareItems: Binding<[Any]>,
        nowPlayingPrompt: Binding<String>,
        showToast: Binding<Bool>,
        toastText: Binding<String?>,
        onConfigureAudio: @escaping () -> Void,
        onSaveToPhotos: @escaping () -> Void,
        onShare: @escaping () -> Void,
        onCopyPrompt: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onToast: @escaping (String) -> Void
    ) -> some View {
        self.fullScreenCover(isPresented: showPlayer, onDismiss: onDismiss) {
            PlayerFullscreenView(
                isPresented: showPlayer,
                player: player,
                outputVideoURL: outputVideoURL,
                playerDragOffset: playerDragOffset,
                showPlayerActions: showPlayerActions,
                showShareSheet: showShareSheet,
                shareItems: shareItems,
                nowPlayingPrompt: nowPlayingPrompt,
                showToast: showToast,
                toastText: toastText,
                onConfigureAudio: onConfigureAudio,
                onSaveToPhotos: onSaveToPhotos,
                onShare: onShare,
                onCopyPrompt: onCopyPrompt,
                onDelete: onDelete,
                onToast: onToast
            )
        }
    }

    func applyMediaPickers(
        showMediaSheet: Binding<Bool>,
        showImagePicker: Binding<Bool>,
        showVideoPicker: Binding<Bool>,
        pickFromCamera: Binding<Bool>,
        onPickImage: @escaping (UIImage?) -> Void,
        onPickVideo: @escaping (URL?) -> Void
    ) -> some View {
        self
            .confirmationDialog("Add media", isPresented: showMediaSheet, titleVisibility: .visible) {
                Button("Take photo")  { Haptics.heavy(); pickFromCamera.wrappedValue = true;  showImagePicker.wrappedValue = true }
                Button("Choose photo"){ Haptics.heavy(); pickFromCamera.wrappedValue = false; showImagePicker.wrappedValue = true }
                Button("Take video")  { Haptics.heavy(); pickFromCamera.wrappedValue = true;  showVideoPicker.wrappedValue = true }
                Button("Choose video"){ Haptics.heavy(); pickFromCamera.wrappedValue = false; showVideoPicker.wrappedValue = true }
                Button("Cancel", role: .cancel) { Haptics.heavy() }
            }
            .sheet(isPresented: showImagePicker) {
                ImagePicker(sourceType: pickFromCamera.wrappedValue ? .camera : .photoLibrary) { image in
                    onPickImage(image)
                }
            }
            .sheet(isPresented: showVideoPicker) {
                VideoPicker(sourceType: pickFromCamera.wrappedValue ? .camera : .photoLibrary) { url in
                    onPickVideo(url)
                }
            }
    }
}
