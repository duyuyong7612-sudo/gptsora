// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-ff3826518f0a63dcc684933844300bcd490bd5e74f24f33feacc0f3b0d7164c0"
// Source-SHA256: "edd222f9601821deaee42cb3a5f91eaf0d10e837b1d707be170188bf600ee777"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI
import AVFoundation
import AVKit
import UIKit
import Combine
import ImageIO
import UniformTypeIdentifiers

// ✅ 二次生成：选中的基视频（必须带 openai video_id）
struct RemixBaseVideo: Identifiable, Equatable {
    let id: UUID
    let fileURL: URL
    let prompt: String
    let openaiVideoId: String
    var canRemix: Bool { openaiVideoId.hasPrefix("video_") && openaiVideoId.count > 12 }
}

struct RemixComposerView: View {

    @Environment(\.dismiss) private var dismiss

    @StateObject private var billing = SolaraBillingStore.shared
    @StateObject private var rt = RealtimeGateController.shared
    @ObservedObject private var pay = SolaraPaywallCenter.shared
    @StateObject private var jobManager = VideoJobManager.shared

    // ✅ DEBUG：解除二次生成(Remix)语音波纹/确认生成的门禁
    // true = 直接放行（不弹付费墙/不走扣费门禁）
    private var bypassRemixGate: Bool {
        UserDefaults.standard.object(forKey: "bypassRemixGate") as? Bool ?? true
    }


    @State private var base: RemixBaseVideo?

    // ✅ 输入框：草案最终也写回这里（用户可编辑）
    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    @State private var showPicker: Bool = false

    @State private var topToastText: String?
    @State private var showTopToast = false
    @State private var toastTask: Task<Void, Never>?

    // ✅ 语音状态
    @State private var voiceUILatched: Bool = false
    @State private var lastVoiceTapAt: Date = .distantPast
    @State private var callEpoch: UUID = UUID()

    private var uiVoiceActive: Bool {
        voiceUILatched || rt.isConnecting || rt.isRunning
    }

    // ✅ 预览框：可拖动 + 上划删除
    @State private var previewOffset: CGSize = .zero

    // ✅ 预览框：视频播放
    @State private var previewPlayer: AVPlayer?
    @State private var isPreviewPlaying: Bool = false

    private let corner: CGFloat = 28
    private let boxWidth: CGFloat = 230
    private let boxHeight: CGFloat = 280

    init(initialBase: RemixBaseVideo? = nil) {
        _base = State(initialValue: initialBase)
    }

    // ============================================================
    // ✅ 素材（视频关键帧）准备与注入状态（先送入 Realtime）
    // ============================================================

    @State private var isPreparingFrames: Bool = false
    @State private var framePrepTask: Task<Void, Never>?

    @State private var preparedFramesKey: String? = nil
    @State private var preparedFrameDatas: [Data] = []

    @State private var injectedFramesKey: String? = nil

    private var currentMaterialKey: String? { base?.openaiVideoId }

    // ============================================================
    // ✅ “草案→确认按钮→放行执行”状态机（草案由 Realtime 生成）
    // ============================================================

    private enum ConfirmStage: Equatable {
        case idle
        case drafting
        case draftReady
        case awaitYesNo
        case buttonReady
        case executing
        case done
    }

    @State private var stage: ConfirmStage = .idle

    @State private var userRawInstruction: String = ""
    @State private var draftText: String = ""

    @State private var confirmToken: String? = nil
    @State private var confirmStylePack: ConfirmStylePack? = nil
    @State private var confirmUsed: Bool = false

    // ✅ 草案请求跟踪：nonce 防串台
    @State private var pendingDraftNonce: String? = nil
    @State private var pendingAutoEnterButton: Bool = false
    @State private var pendingDraftRequestText: String? = nil

    private func looksLikeDirectGenerateCommand(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return false }
        if t.contains("生成") || t.contains("开始") || t.contains("现在") || t.contains("立刻") || t.contains("就这样") { return true }
        let low = t.lowercased()
        if low.contains("generate") || low.contains("start") || low.contains("do it") || low.contains("confirm") { return true }
        return false
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 14) {

                // 顶栏
                HStack {
                    Text("二次生成 Remix")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)

                    Spacer()

                    Button {
                        RemixComposerHaptics.heavy()
                        dismiss()
                    } label: {
                        Text("关闭")
                            .foregroundColor(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)

                // 预览框
                previewBox()
                    .offset(previewOffset)
                    .gesture(previewDragGesture())
                    .padding(.top, 4)

                // 状态条
                HStack(spacing: 10) {
                    Text(rt.isConnecting ? "Connecting…" : (uiVoiceActive ? "Voice Active" : "Idle"))
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.10))
                        .foregroundColor(.white.opacity(0.9))
                        .clipShape(Capsule())

                    if let _ = base {
                        if isPreparingFrames {
                            Text("Loading…")
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.white.opacity(0.10))
                                .foregroundColor(.white.opacity(0.85))
                                .clipShape(Capsule())
                        } else if preparedFramesKey == currentMaterialKey, !preparedFrameDatas.isEmpty {
                            Text("Frames Ready")
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.white.opacity(0.10))
                                .foregroundColor(.white.opacity(0.85))
                                .clipShape(Capsule())
                        }
                    }

                    Spacer()

                    if let b = base {
                        Button {
                            UIPasteboard.general.string = b.openaiVideoId
                            showToast("已复制 Base ID")
                        } label: {
                            Text("Base ID: \(b.openaiVideoId)")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white.opacity(0.9))
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text("请选择一个视频作为基视频")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.55))
                    }
                }
                .padding(.horizontal, 20)

                // ✅ 草案/确认区
                confirmPanel()
                    .padding(.horizontal, 16)

                // Realtime bubbles
                realtimeBubbles()
                    .padding(.horizontal, 16)

                Spacer()

                bottomBar()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
            }

            if showTopToast, let t = topToastText {
                VStack {
                    RemixTopToast(text: t)
                        .padding(.top, 12)
                    Spacer()
                }
                .transition(.opacity)
            }
        }
        .sheet(isPresented: $showPicker) {
            if #available(iOS 16.0, *) {
                RemixVideoPickerGridSheet(
                    onPick: { picked in
                        base = picked
                        stopPreviewPlayback()
                        previewOffset = .zero
                        showPicker = false
                        rt.transcript = ""
                        rt.hint = ""
                    },
                    onClose: { showPicker = false }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            } else {
                RemixVideoPickerGridSheet(
                    onPick: { picked in
                        base = picked
                        stopPreviewPlayback()
                        previewOffset = .zero
                        showPicker = false
                        rt.transcript = ""
                        rt.hint = ""
                    },
                    onClose: { showPicker = false }
                )
            }
        }
        .onAppear {
            rt.setupOnceIfNeeded()
            Task { await billing.refreshMe() }
            if let b = base { prepareFramesForRealtimeIfNeeded(for: b) }
        }
        .onChange(of: base?.id) { _, _ in
            stopPreviewPlayback()
            injectedFramesKey = nil
            resetDraftFlow(clearInput: true)

            if let b = base {
                prepareFramesForRealtimeIfNeeded(for: b)
            } else {
                clearPreparedFrames()
            }
        }
        // running 后：注入帧 + 触发草案请求
        .onChange(of: rt.isRunning) { _, running in
            if running {
                tryInjectPreparedFramesIfNeeded(trigger: "rt.isRunning")
                maybeSendDraftRequestIfReady(trigger: "rt.isRunning")
            }
        }
        // 抓 DRAFT(nonce):
        .onChange(of: rt.transcript) { _, newValue in
            guard stage == .drafting else { return }
            guard let nonce = pendingDraftNonce else { return }
            if let d = extractDraft(from: newValue, nonce: nonce) {
                draftText = d
                text = d
                stage = .awaitYesNo
                showToast("草案已生成，等待确认")
                if pendingAutoEnterButton { enterButtonReady() }
            }
        }
    }

    // MARK: - ✅ 确认面板

    @ViewBuilder
    private func confirmPanel() -> some View {
        if stage != .idle {
            VStack(alignment: .leading, spacing: 10) {

                HStack {
                    Text("草案")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.95))

                    Spacer()

                    Button {
                        RemixComposerHaptics.heavy()
                        resetDraftFlow(clearInput: true)
                        showToast("已取消草案")
                    } label: {
                        Text("取消草案")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.85))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Color.white.opacity(0.10))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Group {
                    switch stage {
                    case .drafting:
                        Text("正在由 Realtime 生成草案…")
                    case .awaitYesNo, .draftReady:
                        Text("我已根据素材整理了草案。确定要开始生成吗？")
                    case .buttonReady:
                        Text("我将输出一个确认按键，请点击确认开始生成。")
                    case .executing:
                        Text("已收到确认，正在提交…")
                    case .done:
                        Text("已提交。")
                    default:
                        Text("")
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.75))

                if stage == .awaitYesNo {
                    HStack(spacing: 10) {
                        Button {
                            RemixComposerHaptics.heavy()
                            stage = .draftReady
                            showToast("已暂停，你可以继续修改草案")
                        } label: {
                            Text("不生成")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white.opacity(0.85))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(Color.white.opacity(0.10))
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)

                        Button {
                            RemixComposerHaptics.heavy()
                            enterButtonReady()
                        } label: {
                            Text("是，生成")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.black)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)

                        Spacer()
                    }
                }

                if stage == .buttonReady || stage == .executing || stage == .done {
                    ConfirmActionButton(
                        title: confirmUsed ? "已确认" : "确认生成",
                        subtitle: confirmUsed ? "已放行" : "点击后开始执行",
                        pack: confirmStylePack ?? ConfirmStylePack.defaultPack,
                        isEnabled: !confirmUsed && stage != .executing,
                        onConfirm: {
                            RemixComposerHaptics.heavy()
                            executeRemixNow()
                        }
                    )
                    .opacity(stage == .done ? 0.92 : 1.0)
                }
            }
            .padding(12)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    private func enterButtonReady() {
        if confirmToken == nil {
            let token = "ct_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            confirmToken = token
            confirmStylePack = ConfirmStylePack.pick(seed: token)
        }
        confirmUsed = false
        stage = .buttonReady
    }

    private func resetDraftFlow(clearInput: Bool) {
        stage = .idle
        userRawInstruction = ""
        draftText = ""
        confirmToken = nil
        confirmStylePack = nil
        confirmUsed = false

        pendingDraftNonce = nil
        pendingAutoEnterButton = false
        pendingDraftRequestText = nil

        if clearInput { text = "" }
    }

    // MARK: - Preview

    @ViewBuilder
    private func previewBox() -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner).fill(Color.white.opacity(0.10))

            if let b = base {
                ZStack {
                    if isPreviewPlaying, let p = previewPlayer {
                        VideoPlayer(player: p)
                            .onAppear { p.play() }
                            .onDisappear { p.pause() }
                            .aspectRatio(contentMode: .fill)
                    } else {
                        RemixVideoThumbView(fileURL: b.fileURL)
                            .scaledToFill()

                        Image(systemName: "play.fill")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 46, height: 46)
                            .background(Color.black.opacity(0.45))
                            .clipShape(Circle())
                    }

                    HStack {
                        Spacer()
                        VStack {
                            Button {
                                RemixComposerHaptics.heavy()
                                if isPreviewPlaying { stopPreviewPlayback() }
                                else { clearBaseVideo() }
                            } label: {
                                Image(systemName: isPreviewPlaying ? "xmark" : "trash")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.white.opacity(0.92))
                                    .frame(width: 30, height: 30)
                                    .background(Color.black.opacity(0.35))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .padding(10)
                            Spacer()
                        }
                    }
                }
                .frame(width: boxWidth, height: boxHeight)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: corner))
                .overlay(RoundedRectangle(cornerRadius: corner).stroke(Color.white.opacity(0.30), lineWidth: 1))
                .contentShape(Rectangle())
                .onTapGesture {
                    RemixComposerHaptics.heavy()
                    togglePreviewPlayback(for: b.fileURL)
                }

            } else {
                VStack(spacing: 12) {
                    Image(systemName: "video.fill")
                        .font(.system(size: 42))
                        .foregroundColor(.white.opacity(0.9))
                    Text("点左侧图片键\n从九宫格选择基视频")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white.opacity(0.75))
                        .font(.system(size: 15, weight: .medium))
                }
            }
        }
        .frame(width: boxWidth, height: boxHeight)
    }

    private func previewDragGesture() -> some Gesture {
        DragGesture()
            .onChanged { value in
                let x = max(-140, min(140, value.translation.width))
                let y = max(-220, min(40, value.translation.height))
                previewOffset = CGSize(width: x, height: y)
            }
            .onEnded { value in
                if value.translation.height < -80 {
                    RemixComposerHaptics.heavy()
                    clearBaseVideo()
                    withAnimation { previewOffset = .zero }
                } else {
                    withAnimation { previewOffset = .zero }
                }
            }
    }

    private func clearBaseVideo() {
        stopPreviewPlayback()
        base = nil
        isFocused = false

        clearPreparedFrames()
        injectedFramesKey = nil

        resetDraftFlow(clearInput: true)
        showToast("已移除基视频")
    }

    private func togglePreviewPlayback(for url: URL) {
        if isPreviewPlaying { stopPreviewPlayback(); return }
        let p = AVPlayer(url: url)
        p.actionAtItemEnd = .pause
        previewPlayer = p
        isPreviewPlaying = true
    }

    private func stopPreviewPlayback() {
        previewPlayer?.pause()
        previewPlayer = nil
        isPreviewPlaying = false
    }

    // MARK: - Realtime bubbles

    @ViewBuilder
    private func realtimeBubbles() -> some View {
        let t = rt.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let h = rt.hint.trimmingCharacters(in: .whitespacesAndNewlines)
        let show = uiVoiceActive || !t.isEmpty || !h.isEmpty

        if show {
            VStack(spacing: 10) {
                if rt.isConnecting {
                    RemixHintBubble(text: h.isEmpty ? "Connecting…" : h)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if !h.isEmpty && t.isEmpty {
                    RemixHintBubble(text: h)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !t.isEmpty {
                    RemixTranscriptBubble(text: t)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Bottom bar

    private func bottomBar() -> some View {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let allowSend = (stage == .idle) && hasText
        let showRipple = uiVoiceActive || (!hasText && stage == .idle)

        return ZStack(alignment: .bottom) {
            HStack(spacing: 10) {

                Button {
                    RemixComposerHaptics.heavy()
                    showPicker = true
                    isFocused = false
                } label: {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(Color.white.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)

                ZStack(alignment: .leading) {
                    if text.isEmpty {
                        Text(stage == .idle ? "说说你要怎么改这条视频…" : "草案已生成，可编辑后确认")
                            .foregroundColor(.white.opacity(0.35))
                            .font(.system(size: 15))
                            .padding(.leading, 12)
                    }
                    TextField("", text: $text)
                        .foregroundColor(.white)
                        .font(.system(size: 15))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .focused($isFocused)
                }
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 16))

                Button {
                    RemixComposerHaptics.heavy()
                    handleSendTapped()
                } label: {
                    Image(systemName: stage == .idle ? "sparkles" : "lock.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(allowSend ? .black : .white.opacity(0.6))
                        .frame(width: 42, height: 42)
                        .background(allowSend ? Color.white : Color.white.opacity(0.10))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!allowSend)
                .opacity(allowSend ? 1.0 : 0.85)
            }

            RemixRippleButton(isActive: uiVoiceActive, isConnecting: rt.isConnecting) {
                RemixComposerHaptics.heavy()
                toggleVoice()
            }
            .offset(y: -72)
            .opacity(showRipple ? 1.0 : 0.0)
            .allowsHitTesting(showRipple)
            .animation(.easeInOut(duration: 0.18), value: showRipple)
        }
    }

    // MARK: - Draft via Realtime

    private func handleSendTapped() {
        guard let b = base, b.canRemix else {
            showToast("请先选择带 Base ID 的视频")
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        userRawInstruction = trimmed
        pendingAutoEnterButton = looksLikeDirectGenerateCommand(trimmed)

        let nonce = String(UUID().uuidString.prefix(8))
        pendingDraftNonce = nonce
        pendingDraftRequestText = trimmed

        stage = .drafting
        showToast("正在生成草案…")

        prepareFramesForRealtimeIfNeeded(for: b)

        // 如果你希望“没连接就自动连”，这里可以加：
        // if !rt.isRunning && !rt.isConnecting { rt.connect() }

        maybeSendDraftRequestIfReady(trigger: "handleSendTapped")
    }

    private func maybeSendDraftRequestIfReady(trigger: String) {
        guard stage == .drafting else { return }
        guard let b = base, b.canRemix else { return }
        guard rt.isRunning else { return }
        guard let req = pendingDraftRequestText else { return }
        guard let nonce = pendingDraftNonce else { return }

        if !preparedFrameDatas.isEmpty {
            if injectedFramesKey != b.openaiVideoId { return }
        }

        pendingDraftRequestText = nil

        let lang = detectUserLanguage(req)
        let prompt = buildDraftRequestPrompt(userInstruction: req, lang: lang, nonce: nonce)

        RealtimeQuickService.shared.sendText(prompt, speak: false)
        rt.hint = "正在生成草案…"
#if DEBUG
        print("[RemixComposer] sent draft request trigger=\(trigger) nonce=\(nonce)")
#endif
    }

    private func buildDraftRequestPrompt(userInstruction: String, lang: String, nonce: String) -> String {
        if lang == "zh" {
            return """
你是“二次生成(REMIX)草案整理器”。系统已给你发送了该视频的关键帧素材，请基于素材来写草案。
要求：
1) 必须用中文输出；
2) 必须包含三句锚点：
- 保持原视频的场景、主体、背景、构图与镜头运动完全一致。
- 只改动：...
- 不要改动：主体身份、背景/布局、构图/取景、镜头路径/运动。
3) 只输出一行，格式严格为：
DRAFT(\(nonce)): <草案文本>
不要输出任何其他文字。

用户需求：\(userInstruction)
"""
        } else {
            return """
You are a REMIX draft writer. The system has already provided keyframes of the video. Write a stable remix draft.
Rules:
1) Output in the user's language (English here).
2) Must include these anchors:
- Keep the same scene, subject, background, composition, and camera motion as the original video.
- Only change: ...
- Do not change: subject identity, background/layout, composition/framing, or camera path/motion.
3) Output EXACTLY ONE line:
DRAFT(\(nonce)): <draft text>
No other text.

User instruction: \(userInstruction)
"""
        }
    }

    private func extractDraft(from transcript: String, nonce: String) -> String? {
        let marker = "DRAFT(\(nonce)):"
        guard let range = transcript.range(of: marker, options: [.caseInsensitive]) else { return nil }
        let after = transcript[range.upperBound...]
        let line = after.split(whereSeparator: \.isNewline).first ?? Substring(after)
        let draft = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return draft.isEmpty ? nil : draft
    }

    // MARK: - Voice

    private func toggleVoice() {
        guard base != nil else {
            showToast("请先选择带 Base ID 的视频")
            return
        }

        let now = Date()
        if now.timeIntervalSince(lastVoiceTapAt) < 0.35 { return }
        lastVoiceTapAt = now

        if uiVoiceActive {
            Task { @MainActor in stopVoiceAndSubmitIfAny(submit: true) }
        } else {
            startVoice()
        }
    }

    private func startVoice() {
        callEpoch = UUID()
        voiceUILatched = true
        isFocused = false

        rt.transcript = ""
        rt.hint = "正在连接语音…（会先加载视频关键帧）"

        if bypassRemixGate {
            // ✅ 直接放行：不走付费门禁/扣费门禁
            rt.connect()
        } else {
            pay.requestStartVoice(
                connectRealtime: { rt.connect() },
                hangupRealtime: { Task { @MainActor in stopVoiceAndSubmitIfAny(submit: true) } }
            )
        }

        if let b = base { prepareFramesForRealtimeIfNeeded(for: b) }
    }

    @MainActor
    private func stopVoiceAndSubmitIfAny(submit: Bool) {
        let myEpoch = UUID()
        callEpoch = myEpoch

        voiceUILatched = false
        if !bypassRemixGate { pay.endVoiceIfNeeded() }
        rt.disconnect()

        guard submit else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard self.callEpoch == myEpoch else { return }
            guard self.base != nil else { return }

            let raw = self.rt.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else {
                self.showToast("没有捕获到语音内容")
                return
            }

            self.text = raw
            self.handleSendTapped()
        }
    }

    // MARK: - Execute (确认按钮放行)

    private func executeRemixNow() {
        guard let b = base, b.canRemix else {
            showToast("缺少 Base ID，无法执行")
            return
        }
        guard !confirmUsed else { return }

        if !bypassRemixGate && billing.videoCredits <= 0 {
            showToast("没有视频点数，请购买视频包")
            pay.openVideoPaywall()
            return
        }

        let finalDraft = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalDraft.isEmpty else {
            showToast("草案为空")
            return
        }

        confirmUsed = true
        stage = .executing

        jobManager.enqueueRemix(baseVideoId: b.openaiVideoId, instruction: finalDraft)

        showToast("已确认，开始二次生成…")
        stage = .done
    }

    // MARK: - Helpers

    private func detectUserLanguage(_ s: String) -> String {
        if s.range(of: #"[\u4E00-\u9FFF]"#, options: .regularExpression) != nil { return "zh" }
        if s.range(of: #"[\u3040-\u30FF]"#, options: .regularExpression) != nil { return "ja" }
        if s.range(of: #"[\uAC00-\uD7AF]"#, options: .regularExpression) != nil { return "ko" }
        return "en"
    }

    @MainActor
    private func showToast(_ text: String) {
        toastTask?.cancel()
        toastTask = nil
        topToastText = text
        withAnimation(.easeOut(duration: 0.18)) { showTopToast = true }
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_250_000_000)
            if Task.isCancelled { return }
            withAnimation(.easeOut(duration: 0.18)) { showTopToast = false }
        }
    }

    // ============================================================
    // ✅ 关键帧准备 + 注入 Realtime（仅 running 后注入）
    // ============================================================

    private func clearPreparedFrames() {
        framePrepTask?.cancel()
        framePrepTask = nil
        isPreparingFrames = false
        preparedFramesKey = nil
        preparedFrameDatas = []
    }

    private func prepareFramesForRealtimeIfNeeded(for b: RemixBaseVideo) {
        let key = b.openaiVideoId
        if preparedFramesKey == key, !preparedFrameDatas.isEmpty { return }
        if isPreparingFrames, preparedFramesKey == key { return }

        framePrepTask?.cancel()
        framePrepTask = nil

        isPreparingFrames = true
        preparedFramesKey = key
        preparedFrameDatas = []

        rt.hint = "正在加载视频关键帧…"

        framePrepTask = Task.detached(priority: .userInitiated) { [fileURL = b.fileURL] in
            let datas = _rc_extractKeyFramesJPEG(url: fileURL, count: 8, maxDimension: 640, jpegQuality: 0.72)
            await MainActor.run {
                self.isPreparingFrames = false
                guard self.preparedFramesKey == key else { return }
                self.preparedFrameDatas = datas
                if datas.isEmpty {
                    self.rt.hint = "未能提取关键帧（可直接描述改动）"
                } else {
                    self.rt.hint = "关键帧已准备好"
                    self.tryInjectPreparedFramesIfNeeded(trigger: "frames_ready")
                    self.maybeSendDraftRequestIfReady(trigger: "frames_ready")
                }
            }
        }
    }

    private func tryInjectPreparedFramesIfNeeded(trigger: String) {
        guard let b = base else { return }
        let key = b.openaiVideoId

        guard preparedFramesKey == key, !preparedFrameDatas.isEmpty else { return }
        guard injectedFramesKey != key else { return }

        // ✅ 只在 running 后注入
        guard rt.isRunning else { return }

        RealtimeQuickService.shared.injectImageDatas(preparedFrameDatas, mime: "image/jpeg", requestAck: false)
        injectedFramesKey = key
        rt.hint = "已将关键帧发送给助手"
#if DEBUG
        print("[RemixComposer] injected frames (\(preparedFrameDatas.count)) trigger=\(trigger)")
#endif
    }
}

// MARK: - ✅ 本文件专用震动（避免与其它文件撞名导致报红）
private enum RemixComposerHaptics {
    static func heavy(minInterval: CFAbsoluteTime = 0.16) { impact(.heavy, minInterval: minInterval) }
    private static var lastFire: CFAbsoluteTime = 0
    private static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle, minInterval: CFAbsoluteTime) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastFire >= minInterval else { return }
        lastFire = now
        let gen = UIImpactFeedbackGenerator(style: style)
        gen.prepare()
        gen.impactOccurred()
    }
}

// MARK: - Confirm Button styles (随机皮肤)
private struct ConfirmStylePack: Equatable {
    let templateId: Int
    let themeId: Int
    static let defaultPack = ConfirmStylePack(templateId: 0, themeId: 0)

    static func pick(seed: String) -> ConfirmStylePack {
        let h = abs(seed.hashValue)
        let template = h % 6
        let theme = (h / 7) % 4
        return ConfirmStylePack(templateId: template, themeId: theme)
    }
}

private struct ConfirmActionButton: View {
    let title: String
    let subtitle: String
    let pack: ConfirmStylePack
    let isEnabled: Bool
    let onConfirm: () -> Void

    var body: some View {
        Button(action: { if isEnabled { onConfirm() } }) { content }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1.0 : 0.72)
    }

    @ViewBuilder
    private var content: some View {
        let t = pack.templateId
        let th = pack.themeId
        switch t {
        case 0: capsuleGlass(theme: th)
        case 1: neonStroke(theme: th)
        case 2: gradientPulse(theme: th)
        case 3: cardConfirm(theme: th)
        case 4: blackHoleConfirm(theme: th)
        default: minimalConfirm(theme: th)
        }
    }

    private func themeColors(_ theme: Int) -> (bg: Color, fg: Color, accent: Color) {
        switch theme {
        case 0: return (Color.white.opacity(0.12), Color.white, Color.cyan)
        case 1: return (Color.purple.opacity(0.18), Color.white, Color.purple)
        case 2: return (Color.blue.opacity(0.16), Color.white, Color.blue)
        default: return (Color.orange.opacity(0.18), Color.white, Color.orange)
        }
    }

    private func capsuleGlass(theme: Int) -> some View {
        let c = themeColors(theme)
        return HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundColor(c.accent)
                .font(.system(size: 18, weight: .bold))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .bold)).foregroundColor(c.fg)
                Text(subtitle).font(.system(size: 12, weight: .medium)).foregroundColor(c.fg.opacity(0.75))
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundColor(c.fg.opacity(0.6))
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(c.bg)
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.14), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func neonStroke(theme: Int) -> some View {
        let c = themeColors(theme)
        return HStack(spacing: 10) {
            Image(systemName: "lock.open.fill").foregroundColor(c.accent).font(.system(size: 18, weight: .bold))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .bold)).foregroundColor(c.fg)
                Text(subtitle).font(.system(size: 12, weight: .medium)).foregroundColor(c.fg.opacity(0.75))
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Color.black.opacity(0.35))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(c.accent.opacity(0.75), lineWidth: 1.6)
                .shadow(color: c.accent.opacity(0.35), radius: 10, x: 0, y: 0)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func gradientPulse(theme: Int) -> some View {
        let c = themeColors(theme)
        return HStack(spacing: 10) {
            Image(systemName: "bolt.fill")
                .foregroundColor(Color.black.opacity(0.85))
                .font(.system(size: 16, weight: .bold))
                .padding(8)
                .background(c.accent)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .bold)).foregroundColor(.black)
                Text(subtitle).font(.system(size: 12, weight: .medium)).foregroundColor(.black.opacity(0.7))
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(LinearGradient(colors: [c.accent.opacity(0.9), Color.white], startPoint: .leading, endPoint: .trailing))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func cardConfirm(theme: Int) -> some View {
        let c = themeColors(theme)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 15, weight: .bold)).foregroundColor(c.fg)
                Spacer()
                Text("CONFIRM").font(.system(size: 11, weight: .bold)).foregroundColor(c.accent)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color.white.opacity(0.10)).clipShape(Capsule())
            }
            Text(subtitle).font(.system(size: 12, weight: .medium)).foregroundColor(c.fg.opacity(0.75))
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(c.bg)
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func blackHoleConfirm(theme: Int) -> some View {
        let c = themeColors(theme)
        return HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.black.opacity(0.9)).frame(width: 34, height: 34)
                Circle().stroke(c.accent.opacity(0.8), lineWidth: 2).frame(width: 34, height: 34)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .bold)).foregroundColor(c.fg)
                Text(subtitle).font(.system(size: 12, weight: .medium)).foregroundColor(c.fg.opacity(0.75))
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Color.white.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func minimalConfirm(theme: Int) -> some View {
        let c = themeColors(theme)
        return HStack {
            Text(title).font(.system(size: 15, weight: .bold)).foregroundColor(.black)
            Spacer()
            Image(systemName: "checkmark").foregroundColor(.black)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(c.accent.opacity(0.25), lineWidth: 1))
    }
}

// MARK: - Small UI pieces
private struct RemixTopToast: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.14))
            .clipShape(Capsule())
            .padding(.horizontal, 16)
    }
}

private struct RemixHintBubble: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundColor(.white.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct RemixTranscriptBubble: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct RemixRippleButton: View {
    let isActive: Bool
    let isConnecting: Bool
    let onTap: () -> Void

    @State private var pulse: Bool = false

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .fill(isActive ? Color.blue.opacity(0.85) : Color.black.opacity(0.85))
                    .frame(width: 74, height: 74)
                    .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))

                Circle()
                    .fill(Color.white.opacity(isActive ? 0.08 : 0.10))
                    .frame(width: pulse ? 58 : 50, height: pulse ? 58 : 50)
                    .animation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true), value: pulse)

                Image(systemName: isActive ? "phone.down.fill" : "waveform")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                    .opacity(isConnecting ? 0.55 : 0.95)
            }
        }
        .buttonStyle(.plain)
        .onAppear { pulse = true }
    }
}

// MARK: - Local video thumbnail (UI 用 UIImage OK)
private struct RemixVideoThumbView: View {
    let fileURL: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable() }
            else {
                Color.white.opacity(0.06)
                    .overlay(
                        Image(systemName: "video.fill")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundColor(.white.opacity(0.65))
                    )
            }
        }
        .task(id: fileURL) {
            if let cached = RemixVideoThumbCache.shared.get(fileURL) {
                image = cached
                return
            }
            image = await RemixVideoThumbCache.shared.make(fileURL)
        }
    }
}

private final class RemixVideoThumbCache {
    static let shared = RemixVideoThumbCache()
    private let cache = NSCache<NSString, UIImage>()

    func get(_ url: URL) -> UIImage? { cache.object(forKey: url.path as NSString) }

    func make(_ url: URL) async -> UIImage? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let asset = AVAsset(url: url)
                let gen = AVAssetImageGenerator(asset: asset)
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: 640, height: 640)
                do {
                    let cg = try gen.copyCGImage(at: CMTime(seconds: 0.0, preferredTimescale: 600), actualTime: nil)
                    cont.resume(returning: UIImage(cgImage: cg))
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
    }
}

// MARK: - ✅ Keyframes helper (不使用 UIImage/jpegData，避免 MainActor 推断)
private func _rc_extractKeyFramesJPEG(url: URL, count: Int, maxDimension: CGFloat, jpegQuality: CGFloat) -> [Data] {
    let asset = AVAsset(url: url)
    let duration = CMTimeGetSeconds(asset.duration)
    if !duration.isFinite || duration <= 0 { return [] }

    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.maximumSize = CGSize(width: maxDimension, height: maxDimension)
    gen.requestedTimeToleranceBefore = CMTime(seconds: 0.12, preferredTimescale: 600)
    gen.requestedTimeToleranceAfter  = CMTime(seconds: 0.12, preferredTimescale: 600)

    let n = max(1, min(count, 16))
    var times: [CMTime] = []
    if n == 1 {
        times = [CMTime(seconds: 0.0, preferredTimescale: 600)]
    } else {
        for i in 0..<n {
            let frac = Double(i) / Double(n - 1)
            let sec = max(0.0, min(duration, duration * frac))
            times.append(CMTime(seconds: sec, preferredTimescale: 600))
        }
    }

    var out: [Data] = []
    out.reserveCapacity(n)

    for t in times {
        do {
            let cg = try gen.copyCGImage(at: t, actualTime: nil)
            let scaled = _rc_downscaleCGImageIfNeeded(cg, maxDimension: maxDimension)
            if let data = _rc_jpegData(from: scaled, quality: jpegQuality) {
                out.append(data)
            }
        } catch {
            continue
        }
    }

    return out
}

private func _rc_downscaleCGImageIfNeeded(_ image: CGImage, maxDimension: CGFloat) -> CGImage {
    let w = CGFloat(image.width)
    let h = CGFloat(image.height)
    let maxSide = max(w, h)
    if maxSide <= maxDimension { return image }

    let scale = maxDimension / maxSide
    let newW = max(1, Int(w * scale))
    let newH = max(1, Int(h * scale))

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

    guard let ctx = CGContext(
        data: nil,
        width: newW,
        height: newH,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        return image
    }

    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(newW), height: CGFloat(newH)))
    return ctx.makeImage() ?? image
}

private func _rc_jpegData(from image: CGImage, quality: CGFloat) -> Data? {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(
        data as CFMutableData,
        UTType.jpeg.identifier as CFString,
        1,
        nil
    ) else { return nil }

    let q = max(0.1, min(1.0, quality))
    let options = [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary
    CGImageDestinationAddImage(dest, image, options)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return data as Data
}


