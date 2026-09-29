//
//  HomeChatView 2.swift
//  GPTsora
//
//  Created by 12345 on 1/29/26.
//



// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-580e6277d16c11bd30f9ddd426e2ac03aeae15d821bf1fe62ab6d83c97f7c4f5"
// Source-SHA256: "7141c07bc775d3ae3e2ce98b233aea4879b58f12ee31e5b470d4e84f43f7510e"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI
import UIKit
import WebKit
import AVFoundation
import PhotosUI
import Combine

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

    private let apiBase = "http://YOUR_LAN_IP:8000"
    private let chat = GPT5ChatService()
    private let uploader = MediaUploadService()
    // ✅ 稳态打字机参数（长代码自动加速）
    private let typeTickNs: UInt64 = 50_000_000     // 20fps（更顺滑可 40_000_000）
    private let typeStride: Int = 64                // 索引缓存步长，避免 substring O(n²)
    private let typeMaxDurationNormal: Double = 10.0
    private let typeMaxDurationHuge: Double = 6.0

    // ✅ 极速 Realtime 通道：全 App 复用同一个 RealtimeBridge
    //    同时避免某些可忽略的 cancel 错误触发断线。
    @ObservedObject private var fast = RealtimeFastLane.shared
    @ObservedObject private var rt = RealtimeFastLane.shared.bridge

    // ✅ 语音气泡播放（全局单实例）
    @StateObject private var audioPlayer = GlobalAudioPlayer()

    // ✅ 助手气泡播报（GPT TTS，全局单实例）
    @StateObject private var speechPlayer = GlobalSpeechPlayer()

    // ✅ 家居入口（状态探测 & 配置）
    @StateObject private var homeEntryVM = HAQuickHomeEntryVM()
    // ✅ 微信式：会话列表/联系人/人与人聊天/视频通话（GPT 也是一个“人”）
    @StateObject private var wechatStore = WeChatStore()
    @State private var typeTimer: Timer? = nil
    @State private var typeBuffer: [Character] = []
    @State private var typeTickChars: Int = 8   // 每次吐 8 个字（你可调 6~12）


    // ✅ 统一管理所有 sheet，避免多 sheet 互抢
    private enum ActiveSheet: Identifiable {
        case legacyVideo
        case wechatHome
        case homeControlLegacy

        var id: Int {
            switch self {
            case .legacyVideo: return 1
            case .wechatHome: return 2
            case .homeControlLegacy: return 3
            }
        }
    }
    @State private var activeSheet: ActiveSheet? = nil

    @State private var messages: [ChatMessage] = []
    @State private var inputText: String = ""
    @FocusState private var focused: Bool

    @State private var isSending = false
    @State private var sendTask: Task<Void, Never>? = nil
    @State private var typeTask: Task<Void, Never>? = nil
    // ✅ “播报开始才吞字”：当语音真正开始播放时才开始显示文本；若用户中止播报则立即补全全文
    @State private var revealTask: Task<Void, Never>? = nil
    @State private var revealTaskMessageId: UUID? = nil
    @State private var revealFullText: [UUID: String] = [:]

    // ✅ 预生成/预下载 TTS：当“播放”按钮出现时，音频已就绪（用户点才播）
    @State private var ttsPreparedURL: [UUID: URL] = [:]
    @State private var ttsPreparing: Set<UUID> = []
    @State private var ttsPrefetchTask: [UUID: Task<Void, Never>] = [:]



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

    // ✅ ChatGPT 两态：聊天 / 声音
    private enum ComposerMode { case chat, voice }
    @State private var composerMode: ComposerMode = .chat

    // ✅ 声音态：静音 & 音视频页
    @State private var isMutedInVoice = false
    @State private var showVideoCall = false

    // realtime assistant 打字消息 id
    @State private var rtAssistantId: UUID? = nil

    private struct CharIndexCache: Sendable {
        let stride: Int
        let anchors: [String.Index]   // 0, stride, 2*stride...
        let total: Int

        init(text: String, stride: Int) {
            self.stride = max(16, stride)
            var a: [String.Index] = [text.startIndex]
            var idx = text.startIndex
            var count = 0

            while idx < text.endIndex {
                if count > 0, count % self.stride == 0 { a.append(idx) }
                idx = text.index(after: idx)
                count += 1
            }
            if a.last != text.endIndex { a.append(text.endIndex) }
            self.anchors = a
            self.total = count
        }

        func endIndex(for charCount: Int, in text: String) -> String.Index {
            let c = max(0, min(charCount, total))
            if c == 0 { return text.startIndex }
            let chunk = c / stride
            let rem = c % stride
            let base = anchors[min(chunk, anchors.count - 1)]
            return text.index(base, offsetBy: rem, limitedBy: text.endIndex) ?? text.endIndex
        }
    }


    // UI 浅灰底
    private let uiGray = Color(white: 0.94)

    // MARK: - Attachments state

    @State private var pickedPhotoItems: [PhotosPickerItem] = []
    @State private var pendingImages: [PendingImage] = []
    @State private var isLoadingPhotos: Bool = false

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
    private var callActive: Bool { rt.isConnected }

    var body: some View {
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

        // ✅ 统一 sheet：视频生成 / 家居控制
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .legacyVideo:
                RootPagerView(startIndex: 3)

            case .wechatHome:
                WeChatHomeSheetView(
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
            }
        }

        // ✅ 退出视频页后回到“声音态”则恢复音频通话
        .fullScreenCover(isPresented: $showVideoCall, onDismiss: {
            if composerMode == .voice {
                fast.ensureConnected(apiBase: apiBase)
            }
        }) {
            RealtimeAVCallView(apiBase: apiBase, rt: rt) {
                showVideoCall = false
            }
        }

        .onAppear {
            fast.configure(apiBase: apiBase)
            homeEntryVM.refresh()

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
        self.scheduleScrollNow(to: .bottom, anchor: .bottom)
    }
}

rt.onAssistantPartial = { partial in
    Task { @MainActor in
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

        // ✅ 始终跟随最新输出（避免滚动跳回开头）        self.scheduleScroll()
}
}

rt.onAssistantFinal = { final in
    Task { @MainActor in
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
    }
}
// ⚠️ 不要直接覆盖 rt.onError，否则会把 FastLane 的“错误过滤/稳态重连”逻辑冲掉。
            fast.setOnError { err in
                Task { @MainActor in
                    self.messages.append(.init(role: .system, text: "Realtime 错误：\(err)"))
                    self.scheduleScrollNow(to: .bottom, anchor: .bottom)
                }
            }
        }

        // MARK: PhotosPicker loader
        .onChange(of: pickedPhotoItems) { newItems in
            guard !newItems.isEmpty else { return }
            Task { @MainActor in
                await loadPhotos(items: newItems)
                pickedPhotoItems.removeAll()
            }
        }
    }

    // MARK: - Chat Screen

    private var chatScreen: some View {
        VStack(spacing: 0) {
            topBar
            Divider().opacity(0.15)

            chatList
        }
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

            Spacer()

            VStack(spacing: 10) {
                Text("开始说话")
                    .font(.system(size: 29, weight: .semibold))
                    .foregroundColor(.gray.opacity(0.70))

                Text(rt.status)
                    .font(.system(size: 14))
                    .foregroundColor(.gray.opacity(0.7))
            }

            Spacer()
        }
        .safeAreaInset(edge: .bottom) {
            chatGPTVoiceBottomBar
        }
        .onAppear {
            // ✅ 极速接通：只要进来就确保已连接（内部会判断是否已经 connected）
            fast.ensureConnected(apiBase: apiBase)

            // ✅ 通话态优先级最高：确保本地播放都停掉
            audioPlayer.stop()
            speechPlayer.stop()
            revealTask?.cancel(); revealTask = nil
            revealTaskMessageId = nil
            revealFullText.removeAll()
            if audioNote.isRecording { audioNote.cancel() }
        }
    }

    // MARK: - Top Bars

    private var topBar: some View {
        HStack(spacing: 10) {

            Button { HomeHaptics.light() } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)

            HStack(spacing: 6) {
                Text("Solara")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.black)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.gray)
            }

            Spacer()

            Button { HomeHaptics.light() } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)

            Button { HomeHaptics.light() } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var voiceTopBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("ChatGPT")
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(.black)

            Text("声音")
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(.gray.opacity(0.75))

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

    private struct InputBarHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }

    private var chatList: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(messages) { msg in
                            row(for: msg)
                                .id(ScrollTarget.msg(msg.id))
                        }

                        // ✅ 底部自动轻量回退空间：随输入栏高度动态变化
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
                    .padding(.horizontal, 14)
                    .padding(.top, 2)
                    .padding(.bottom, 6)
                }
                .coordinateSpace(name: "scroll")
                .onAppear {
                    scrollViewHeight = outer.size.height
                }
                .onChange(of: outer.size.height) { h in
                    scrollViewHeight = h
                }
                .onPreferenceChange(BottomOffsetKey.self) { bottomY in
                    self.isAtBottom = bottomY <= (self.scrollViewHeight + self.bottomThreshold)
                }
                
.onChange(of: scrollTick) { _ in
                    var tx = Transaction()
                    tx.disablesAnimations = true
                    withTransaction(tx) {
                        proxy.scrollTo(scrollTarget, anchor: scrollAnchor)
                    }
                }
                
                
            }
        }
    }

    @ViewBuilder
    private func row(for msg: ChatMessage) -> some View {
        switch msg.role {
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {

                
    let raw = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let isThinking = msg.isTypingCursor && (raw == "正在思考中…" || raw == "正在思考中..." || raw.contains("正在思考"))
    let isPlayingThis = (speechPlayer.activeId == msg.id) && speechPlayer.isSpeaking
    let isPreparingTTS = ttsPreparing.contains(msg.id)
    let preparedURL = ttsPreparedURL[msg.id]

    // ✅ 文本渲染：
    // - 生成中：不再显示“三点”，改为“正在思考”字体+阴影呼吸动效
    // - 打字中：纯文本 + 光标（不跑 Markdown/代码高亮，避免抖动）
    // - 完成后：再渲染 Markdown/代码高亮
    VStack(alignment: .leading, spacing: 8) {

        if isThinking {
            ThinkingShadowText(text: "正在思考中…")
        } else if msg.isTypingCursor {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(msg.text)
                    .font(.system(size: 17))
                    .foregroundColor(.black)
                    .fixedSize(horizontal: false, vertical: true)
                TypingCursorPill()
            }
        } else {
            AssistantMarkdownView(text: msg.text)
        }

        // ✅ 播报按钮放在文本下方：仅当文本完成显示后才出现
        // ✅ “播放图标显示时”保证音频已下载准备好（preparedURL != nil）
        if !msg.isTypingCursor && !raw.isEmpty && !callActive {

            if isPreparingTTS && preparedURL == nil {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.85)
                    Text("准备播报…")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.black.opacity(0.60))
                }
                .padding(.top, 2)
            } else if let u = preparedURL {

                Button {
                    HomeHaptics.light()

                    // ✅ 避免语音消息与助手播报同时播放
                    audioPlayer.stop()

                    if isPlayingThis {
                        speechPlayer.stop()
                    } else {
                        speechPlayer.playPrepared(
                            id: msg.id,
                            url: u,
                            fallbackText: raw,
                            apiBase: apiBase,
                            voice: "realtime"
                        ) { errText in
                            messages.append(.init(role: .system, text: errText))
                            scheduleScrollNow(to: .bottom, anchor: .bottom)
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isPlayingThis ? "stop.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundColor(.white)
                            .frame(width: 28, height: 28)
                            .background(isPlayingThis ? Color.black : Color(red: 0.0, green: 0.48, blue: 1.0))
                            .clipShape(Circle())

                        Text(isPlayingThis ? "中止" : "播报")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.black.opacity(0.72))

                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
    }
}
.frame(maxWidth: CGFloat.infinity, alignment: .leading)

        case .user:
            HStack {
                Spacer(minLength: 40)
                UserBubble(
                    message: msg,
                    callActive: callActive,
                    onBlocked: {
                        messages.append(.init(role: .system, text: "通话进行中：已禁止语音消息播放（避免断流）。如需播放请先结束通话。"))
                        scheduleScrollNow(to: .bottom, anchor: .bottom)
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

    // MARK: - User Bubble (图片直接显示 + 语音可播放)

    private struct UserBubble: View {
        let message: ChatMessage
        let callActive: Bool
        let onBlocked: () -> Void
        @ObservedObject var audioPlayer: GlobalAudioPlayer
        @ObservedObject var speechPlayer: GlobalSpeechPlayer

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {

                if !message.attachments.isEmpty {
                    AttachmentsGridView(
                        attachments: message.attachments,
                        callActive: callActive,
                        onBlocked: onBlocked,
                        audioPlayer: audioPlayer,
                        speechPlayer: speechPlayer
                    )
                }

                if !message.renderText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(message.renderText)
                        .font(.system(size: 17))
                        .foregroundColor(.black)
                        .fixedSize(horizontal: false, vertical: true)
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
        @ObservedObject var audioPlayer: GlobalAudioPlayer
        @ObservedObject var speechPlayer: GlobalSpeechPlayer

        private var imageAttachments: [ChatMessageAttachment] {
            attachments.filter { if case .image = $0.kind { return true } else { return false } }
        }
        private var audioAttachments: [ChatMessageAttachment] {
            attachments.filter { if case .audio = $0.kind { return true } else { return false } }
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
                                audioPlayer: audioPlayer,
                                speechPlayer: speechPlayer,
                                attachmentId: att.id,
                                url: url,
                                duration: duration
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Audio bubble player row

    private struct AudioBubblePlayerRow: View {
        let callActive: Bool
        let onBlocked: () -> Void
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
                    speechPlayer.stop()
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

    // ✅ 输入框上方快捷入口（家居 / 视频生成）
    private var chatQuickToolsRow: some View {
        HStack(spacing: 10) {

            Button {
                HomeHaptics.light()
                focused = false
                audioPlayer.stop()
                speechPlayer.stop()
                activeSheet = .wechatHome
            } label: {
                toolCircleIcon(systemName: "message.fill")
            }
            .buttonStyle(.plain)

            Button {
                HomeHaptics.light()
                focused = false
                audioPlayer.stop()
                speechPlayer.stop()
                activeSheet = .legacyVideo
            } label: {
                toolCircleIcon(systemName: "film")
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .disabled(isSending || audioNote.isRecording)
        .onAppear { homeEntryVM.refresh() }
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
        VStack(spacing: 0) {
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

            // ✅ 新增：输入框上方图标入口（家居 / 视频生成）
            chatQuickToolsRow

            if !pendingImages.isEmpty || audioNote.hasPendingNote || isLoadingPhotos {
                attachmentPreviewBar
                    .padding(.horizontal, 14)
                    .padding(.top, 2)
            }

            HStack(spacing: 10) {

                PhotosPicker(
                    selection: $pickedPhotoItems,
                    maxSelectionCount: 6,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.black.opacity(0.75))
                        .frame(width: 40, height: 40)
                        .background(uiGray)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(isSending || audioNote.isRecording)

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
                        Button {
                            HomeHaptics.light()
                            focused = false

                            // ✅ 通话中禁止本地录音（避免抢占 session）
                            if callActive {
                                messages.append(.init(role: .system, text: "通话进行中：已禁止本地录音（避免断流）。如需录音请先结束通话。"))
                                scheduleScrollNow(to: .bottom, anchor: .bottom)
                                return
                            }

                            // ✅ 开始录音前，先停掉任何本地播放
                            audioPlayer.stop()
                            speechPlayer.stop()

                            Task { @MainActor in
                                do {
                                    try await audioNote.start()
                                } catch {
                                    messages.append(.init(role: .system, text: "录音失败：\(error.localizedDescription)"))
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
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(minHeight: 44)
                .background(uiGray)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                let hasText = !trimmed.isEmpty
                let hasAttachments = !pendingImages.isEmpty || audioNote.isRecording || audioNote.hasPendingNote || isLoadingPhotos

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

                        if hasText || !pendingImages.isEmpty || audioNote.hasPendingNote {
                            onSendOrStop()
                        } else {
                            // ✅ 切到 voice 前先停掉正在播的内容（避免叠音）
                            audioPlayer.stop()
                            speechPlayer.stop()

                            focused = false
                            // ✅ 极速接通：在切 UI 前先确保通话已启动，体感更快
                            fast.ensureConnected(apiBase: apiBase)
                            composerMode = .voice
                        }
                    }
                )
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

    private var attachmentPreviewBar: some View {
        VStack(alignment: .leading, spacing: 10) {

            if isLoadingPhotos {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.9)
                    Text("正在加载照片…")
                        .font(.system(size: 14))
                        .foregroundColor(.gray)
                }
            }

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
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            if !pendingImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(pendingImages) { img in
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: img.preview)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 66, height: 66)
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                                Button {
                                    HomeHaptics.light()
                                    pendingImages.removeAll { $0.id == img.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 16))
                                        .foregroundColor(.black.opacity(0.75))
                                        .background(Color.white.opacity(0.85).clipShape(Circle()))
                                }
                                .buttonStyle(.plain)
                                .offset(x: 6, y: -6)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
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

                Button { HomeHaptics.light() } label: {
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

                Button {
                    HomeHaptics.light()

                    // ✅ 进入音视频前停掉一切本地播放，避免音频路由抢占
                    audioPlayer.stop()
                    speechPlayer.stop()

                    // ✅ 确保已接通再进视频页（体感更快、更稳）
                    fast.ensureConnected(apiBase: apiBase)

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

    // MARK: - Photos loading

    @MainActor
    private func loadPhotos(items: [PhotosPickerItem]) async {
        isLoadingPhotos = true
        defer { isLoadingPhotos = false }

        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let ui = UIImage(data: data) else { continue }

                let compressed = ui.resizedJPEGData(maxDimension: 1600, quality: 0.78) ?? data
                let preview = UIImage(data: compressed) ?? ui

                pendingImages.append(PendingImage(data: compressed, preview: preview))
            } catch {
                messages.append(.init(role: .system, text: "加载照片失败：\(error.localizedDescription)"))
                scheduleScrollNow(to: .bottom, anchor: .bottom)
            }
        }
    }

    // MARK: - Recording send

    @MainActor
    private func stopRecordingAndSend() async {
        audioNote.stopAndMarkPending()
        onSendOrStop()
    }

    // MARK: - HTTP Chat Actions（支持 attachments + 音频转写回填到用户气泡）

    private func onSendOrStop() {
        if isSending {
            cancelAll()
            return
        }

        let t = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty && pendingImages.isEmpty && !audioNote.hasPendingNote { return }

        inputText = ""
        focused = false

        let imagesToSend = pendingImages
        pendingImages.removeAll()

        let staged = audioNote.stagePendingForUpload()
        let audioURLToSend = staged?.url
        let audioDurationToSend = staged?.duration ?? 0

        let userId = UUID()

        var userAttachments: [ChatMessageAttachment] = []
        userAttachments.append(contentsOf: imagesToSend.map { ChatMessageAttachment(kind: .image($0.preview)) })
        if let localURL = audioURLToSend {
            userAttachments.append(ChatMessageAttachment(kind: .audio(url: localURL, duration: audioDurationToSend)))
        }

        messages.append(ChatMessage(id: userId, role: .user, text: t, attachments: userAttachments))

        let assistantId = UUID()
        messages.append(ChatMessage(id: assistantId, role: .assistant, text: "正在思考中…", isTypingCursor: true))

        // ✅ 发送后始终跟随最新消息
        scheduleScrollNow(to: .bottom, anchor: .bottom)

        isSending = true
        sendTask?.cancel()
        typeTask?.cancel()

        // ✅ 新一轮开始前，停掉上一轮的助手播报（避免叠音）
        speechPlayer.stop()

        let context = ChatMessage.buildContext(from: messages, maxPairs: 20)

        sendTask = Task { @MainActor in
            defer { isSending = false }
            do {
                var attachments: [ChatAttachment] = []
                var uploadedAudioRemoteURL: URL? = nil

                for img in imagesToSend {
                    let uploaded = try await uploader.uploadImage(apiBase: apiBase, data: img.data)
                    attachments.append(.init(type: "image", id: uploaded.id, mime: uploaded.mime, url: uploaded.url))
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

                let result = try await chat.send(
                    apiBase: apiBase,
                    model: "gpt-5",
                    messages: context,
                    attachments: attachments
                )

                audioNote.finalizeStaged(deleteFile: uploadedAudioRemoteURL != nil)

                if let transcript = result.userTranscript?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !transcript.isEmpty {
                    updateMessage(id: userId) { m in
                        if m.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            m.text = transcript
                        } else {
                            m.text = m.text + "\n\n🎙️ " + transcript
                        }
                    }
                }

                let fullText = result.reply

                // ✅ 打字机：始终以稳定速度逐步显示（避免一次性显示和抖动）
                updateMessage(id: assistantId) {
                    $0.text = ""
                    $0.isTypingCursor = true
                }
                scheduleScrollNow(to: .bottom, anchor: .bottom)

                // ✅ 不自动播报：用户需要时点气泡里的“播放”按钮（更稳，且避免和输入/录音抢占音频会话）
                // 通话态也会自动禁播报（callActive）。
                if !callActive {
                    // 保险：开始新一条回复时先停掉上一条播报
                    speechPlayer.stop()
                }

                
// ✅ 预生成/预下载播报音频：与打字并行准备；按钮只在文本显示完后出现
if !callActive {
    startPrefetchTTS(messageId: assistantId, text: fullText)
}

await typewriter(fullText, into: assistantId)

} catch is CancellationError {
                audioNote.restoreStagedToPending()
                updateMessage(id: assistantId) { $0.isTypingCursor = false }

                // ✅ 取消时也停掉播报
                speechPlayer.stop()

            } catch {
                audioNote.restoreStagedToPending()

                // ✅ 失败时确保不继续播报
                speechPlayer.stop()

                updateMessage(id: assistantId) {
                    $0.isTypingCursor = false
                    $0.text = "（请求失败）\(error.localizedDescription)"
                }
                scheduleScrollNow(to: .bottom, anchor: .bottom)
            }
        }
    }

    private func cancelAll() {
        sendTask?.cancel(); sendTask = nil
        typeTask?.cancel(); typeTask = nil
        revealTask?.cancel(); revealTask = nil
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

        if audioNote.isRecording {
            audioNote.cancel()
        } else {
            audioNote.restoreStagedToPending()
        }

        pendingImages.removeAll()

        if let last = messages.last, last.role == .assistant {
            updateMessage(id: last.id) { $0.isTypingCursor = false }
        }
        scheduleScrollNow(to: .bottom, anchor: .bottom)
    }

    
// MARK: - TTS Prefetch (音频准备好后才显示播放按钮)

@MainActor
private func startPrefetchTTS(messageId: UUID, text: String) {
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
    let voice = "realtime"

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
    private func typewriter(_ full: String, into assistantId: UUID) async {
        // ✅ Chunk buffer（分块缓存）：每 tick 只追加“尾部增量”，不再重建整段字符串
        typeTask?.cancel()

        let fullText = full
        let hasCodeFence = fullText.contains("```")
        let cache = CharIndexCache(text: fullText, stride: typeStride)
        let total = cache.total

        guard total > 0 else {
            updateMessage(id: assistantId) { m in
                m.text = ""
                m.isTypingCursor = false
            }
            return
        }

        // ✅ 稳态速度：分档 cps（长文更快但有上限），避免“思考久后一下全跳”
        let cps: Double = {
            if total >= 12000 { return 92 }
            if total >= 6000  { return 84 }
            if total >= 2500  { return 74 }
            if total >= 1200  { return 62 }
            return 50
        }()

        // ✅ 每次最小推进：越长越大步，减少 UI 更新次数（避免后段变慢）
        let baseDelta: Int = {
            if total >= 12000 { return 36 }
            if total >= 6000  { return 28 }
            if total >= 2500  { return 22 }
            if hasCodeFence    { return 16 }
            return 10
        }()

        // ✅ tick：长文降低刷新频率（更稳）
        let tickNs: UInt64 = (total >= 2500) ? 80_000_000 : 50_000_000

        typeTask = Task { @MainActor in
            var shown = 0
            var built = ""
            built.reserveCapacity(min(total, 4000))

            var lastIndex = fullText.startIndex
            let startT = Date().timeIntervalSinceReferenceDate

            while !Task.isCancelled && shown < total {
                let elapsed = Date().timeIntervalSinceReferenceDate - startT
                let ideal = min(total, Int(elapsed * cps))

                // 动态 delta：越往后越少刷新
                let dynamicDelta = max(baseDelta, shown / 220)

                if ideal >= shown + dynamicDelta || ideal == total {
                    // ✅ 只追加增量尾部
                    let endIdx = cache.endIndex(for: ideal, in: fullText)
                    if endIdx > lastIndex {
                        built.append(contentsOf: fullText[lastIndex..<endIdx])
                        lastIndex = endIdx
                        shown = ideal

                        updateMessage(id: assistantId) { m in
                            m.text = built
                            m.isTypingCursor = true
                        }

                        // 滚动本身已有 8fps 限流：这里只触发一次即可
                        scheduleScroll()
                    }
                }

                try? await Task.sleep(nanoseconds: tickNs)
            }

            if Task.isCancelled { return }

            // ✅ 结束：补齐全文 + 关闭 cursor
            updateMessage(id: assistantId) { m in
                m.text = fullText
                m.isTypingCursor = false
            }
            scheduleScrollNow(to: .bottom, anchor: .bottom)
        }

        await typeTask?.value
    }



    @MainActor
    private func updateMessage(id: UUID, mutate: (inout ChatMessage) -> Void) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        var m = messages[idx]
        mutate(&m)
        messages[idx] = m
    }

    // MARK: - 播报开始才吞字（与语音播放同步）

    /// 一次性“播放开始门闩”：等待语音真正进入 `.playing` 才放行。
    private actor SpeechStartLatch {
        private var started: Bool = false
        private var continuations: [CheckedContinuation<Bool, Never>] = []

        func signal() {
            guard !started else { return }
            started = true
            continuations.forEach { $0.resume(returning: true) }
            continuations.removeAll()
        }

        func wait(timeoutSeconds: Double) async -> Bool {
            if started { return true }

            return await withTaskGroup(of: Bool.self) { group in
                group.addTask { [weak self] in
                    guard let self else { return false }
                    return await self.waitInternal()
                }
                group.addTask {
                    let ns = UInt64(max(0.05, timeoutSeconds) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: ns)
                    return false
                }

                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
        }

        private func waitInternal() async -> Bool {
            if started { return true }
            return await withCheckedContinuation { cont in
                continuations.append(cont)
            }
        }
    }

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
private struct ThinkingShadowText: View {
    let text: String
    @State private var pulse: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 17, weight: .semibold))
            .foregroundColor(.black.opacity(0.78))
            .shadow(color: Color.black.opacity(pulse ? 0.40 : 0.12),
                    radius: pulse ? 10 : 2,
                    x: 0,
                    y: 0)
            .scaleEffect(pulse ? 1.01 : 1.0)
            .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
            .padding(.top, 2)
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


// ✅ Markdown/代码高亮：独立管线（完成后再解析/高亮，避免打字期抖动）
// - 该 View 自己缓存解析结果：只有 text 变化时才重新 parse
private struct AssistantMarkdownView: View {
    let text: String
    @State private var blocks: [MarkdownBlock] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let t):
                    Text(t)
                        .font(.system(size: 17))
                        .foregroundColor(.black)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let lang, let code):
                    CodeBlock(lang: lang, code: code)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: text) {
            // 轻量节流：避免一瞬间多次重算
            try? await Task.sleep(nanoseconds: 90_000_000)
            blocks = MarkdownBlocks.parse(text)
        }
    }
}

    private func renderAssistantMarkdown(_ text: String) -> some View {
        let blocks = MarkdownBlocks.parse(text)
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let t):
                    Text(t)
                        .font(.system(size: 17))
                        .foregroundColor(.black)
                        .fixedSize(horizontal: false, vertical: true)

                case .code(let lang, let code):
                    CodeBlock(lang: lang, code: code)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private struct CodeBlock: View {
        let lang: String
        let code: String
        @State private var h: CGFloat = 80
        @State private var copied: Bool = false

        var body: some View {
            ZStack(alignment: .topTrailing) {
                LiveCodeHighlighterView(code: code, language: lang, dynamicHeight: $h)
                    .frame(height: h)
                    .frame(maxWidth: .infinity)

                Button {
                    HomeHaptics.light()
                    UIPasteboard.general.string = code
                    copied = true

                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        copied = false
                    }
                } label: {
                    Text(copied ? "已复制" : "复制")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.black.opacity(0.72))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.88))
                        .clipShape(Capsule(style: .continuous))
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(Color.black.opacity(0.12), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .padding(8)
            }
        }
    }

    private enum MarkdownBlock {
        case text(String)
        case code(lang: String, code: String)
    }

    private struct MarkdownBlocks {
        static func parse(_ s: String) -> [MarkdownBlock] {
            let lines = s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

            var out: [MarkdownBlock] = []
            var textBuf: [String] = []

            func flushText() {
                let t = textBuf.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append(.text(t)) }
                textBuf.removeAll()
            }

            var i = 0
            while i < lines.count {
                let line = lines[i]
                if line.hasPrefix("```") {
                    flushText()
                    let lang = line.replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                    i += 1

                    var codeLines: [String] = []
                    while i < lines.count && !lines[i].hasPrefix("```") {
                        codeLines.append(lines[i])
                        i += 1
                    }
                    if i < lines.count && lines[i].hasPrefix("```") { i += 1 }

                    let finalLang = lang.isEmpty ? "plaintext" : lang
                    out.append(.code(lang: finalLang, code: codeLines.joined(separator: "\n")))
                    continue
                } else {
                    textBuf.append(line)
                    i += 1
                }
            }

            flushText()
            return out
        }
    }

    // MARK: - Utils

    private func resolveMediaURLString(_ s: String?) -> URL? {
        guard let s = s, !s.isEmpty else { return nil }
        if let u = URL(string: s), u.scheme != nil { return u }
        if s.hasPrefix("/") { return URL(string: apiBase + s) }
        return URL(string: apiBase + "/" + s)
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
    }
    let id: UUID
    var kind: Kind
    init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }
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

struct ChatMessage: Identifiable {
    let id: UUID
    let role: Role
    var text: String
    var isTypingCursor: Bool
    var attachments: [ChatMessageAttachment]

    enum Role { case user, assistant, system }

    init(id: UUID = UUID(),
         role: Role,
         text: String,
         isTypingCursor: Bool = false,
         attachments: [ChatMessageAttachment] = []) {
        self.id = id
        self.role = role
        self.text = text
        self.isTypingCursor = isTypingCursor
        self.attachments = attachments
    }

    var renderText: String { text }

    static func buildContext(from uiMessages: [ChatMessage], maxPairs: Int) -> [LLMMessage] {
        let compact = uiMessages.compactMap { m -> ChatMessage? in
            if m.role == .assistant && m.text.isEmpty { return nil }
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

// MARK: - GPT5ChatService (支持 attachments + 返回 user_transcript)

struct ChatResult {
    let reply: String
    let userTranscript: String?
    /// Optional: backend can return a pre-generated (or streaming) URL so the app does NOT need to POST text to /tts*.
    /// Supported keys (best-effort): tts_url / ttsUrl / audio_url / audioUrl / speech_url / speechUrl
    let ttsURL: URL?
}

final class GPT5ChatService {

    func send(
        apiBase: String,
        model: String,
        messages: [LLMMessage],
        attachments: [ChatAttachment] = []
    ) async throws -> ChatResult {

        guard let url = URL(string: apiBase + "/chat") else {
            throw NSError(domain: "GPT5ChatService", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "无效 URL：\(apiBase)/chat"])
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var payload: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] }
        ]

        if !attachments.isEmpty {
            payload["attachments"] = attachments.map { a in
                var d: [String: Any] = ["type": a.type, "id": a.id]
                if let m = a.mime { d["mime"] = m }
                if let u = a.url { d["url"] = u }
                return d
            }
        }

        req.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "GPT5ChatService", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "无响应"])
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "GPT5ChatService", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "后端错误 \(http.statusCode): \(body)"])
        }

        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let reply =
            (obj["text"] as? String)
            ?? (obj["reply"] as? String)
            ?? (obj["output_text"] as? String)
            ?? (obj["message"] as? String)
            ?? ""

            let transcript =
            (obj["user_transcript"] as? String)
            ?? (obj["transcript"] as? String)

            let ttsString =
            (obj["tts_url"] as? String)
            ?? (obj["ttsUrl"] as? String)
            ?? (obj["audio_url"] as? String)
            ?? (obj["audioUrl"] as? String)
            ?? (obj["speech_url"] as? String)
            ?? (obj["speechUrl"] as? String)

            let ttsURL = resolve(apiBase: apiBase, urlString: ttsString)

            return ChatResult(reply: reply, userTranscript: transcript, ttsURL: ttsURL)
        }

        let raw = String(data: data, encoding: .utf8) ?? ""
        if !raw.isEmpty {
            return ChatResult(reply: raw, userTranscript: nil, ttsURL: nil)
        }

        throw NSError(domain: "GPT5ChatService", code: -4,
                      userInfo: [NSLocalizedDescriptionKey: "后端返回为空"])
    }

    // Resolve relative/absolute URL strings returned by backend.
    private func resolve(apiBase: String, urlString: String?) -> URL? {
        guard let s = urlString?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if let u = URL(string: s), u.scheme != nil { return u }
        if s.hasPrefix("/") { return URL(string: apiBase + s) }
        return URL(string: apiBase + "/" + s)
    }
}

// MARK: - Media uploader (先 upload 再发消息)

struct UploadedMedia: Codable {
    let id: String
    let mime: String?
    let url: String?
}

final class MediaUploadService {

    func uploadImage(apiBase: String, data: Data) async throws -> UploadedMedia {
        let url = URL(string: apiBase + "/upload/image")!
        return try await uploadMultipart(url: url, fieldName: "file", fileName: "photo.jpg", mime: "image/jpeg", data: data)
    }

    func uploadAudio(apiBase: String, fileURL: URL) async throws -> UploadedMedia {
        let url = URL(string: apiBase + "/upload/audio")!
        let data = try Data(contentsOf: fileURL)
        return try await uploadMultipart(url: url, fieldName: "file", fileName: "voice.m4a", mime: "audio/mp4", data: data)
    }

    private func uploadMultipart(
        url: URL,
        fieldName: String,
        fileName: String,
        mime: String,
        data: Data
    ) async throws -> UploadedMedia {

        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func append(_ s: String) {
            body.append(s.data(using: .utf8)!)
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: \(mime)\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")

        let (respData, resp) = try await URLSession.shared.upload(for: req, from: body)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "MediaUploadService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "upload 无响应"])
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: respData, encoding: .utf8) ?? ""
            throw NSError(domain: "MediaUploadService", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "upload 失败 \(http.statusCode): \(bodyText)"])
        }

        return try JSONDecoder().decode(UploadedMedia.self, from: respData)
    }
}

// MARK: - Audio bubble playback (全局单实例：避免同时播放多段)

@MainActor
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
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.allowBluetooth, .allowAirPlay])
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
    private var currentVoice: String = "realtime"
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
        voice: String = "realtime",
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

    /// 点击同一条：未播 -> 生成并播放；播放中/生成中 -> 中止
    func toggle(
        id: UUID,
        text: String,
        apiBase: String,
        voice: String = "realtime",
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
                    onError?("GPT播报失败：\(error.localizedDescription)")
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
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.allowBluetooth, .allowAirPlay, .duckOthers])
        try? session.setActive(true)

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        if url.isFileURL {
            player.automaticallyWaitsToMinimizeStalling = false
        }
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
                        self.currentOnError?("GPT 播报播放失败：\(err)")
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
        player.playImmediately(atRate: 1.20)                         // ✅ 语速 1.20


        if allowFallbackDownload, !url.isFileURL {
            timeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
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
            currentOnError?("GPT 播报失败：\(reason)")
            stop()
            return
        }
        fallbackTried.insert(id)

        let t = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !currentApiBase.isEmpty else {
            currentOnError?("GPT 播报失败：\(reason)（无法回退：缺少文本/地址）")
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
                    self.currentOnError?("GPT 播报失败：\(error.localizedDescription)")
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

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

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
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)

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


// MARK: - LiveCodeHighlighterView（代码一出现就高亮：不 reload，JS 增量更新）
//
// 说明：
// - makeUIView 时只 load 一次 HTML（内嵌 highlight.js + CSS）
// - updateUIView 只通过 evaluateJavaScript 增量更新代码内容，不会反复 reload -> 文本/滚动更稳
//
struct LiveCodeHighlighterView: UIViewRepresentable {
    let code: String
    let language: String
    @Binding var dynamicHeight: CGFloat

    private static let cached: (js: String, css: String) = {
        let jsURL = Bundle.main.url(forResource: "highlight.min", withExtension: "js")

        // ✅ 优先 atom-one-light.min.css，读不到再回退 atom-one-light.css / atom-one-light.min.css 的其他命名
        let cssURL =
            Bundle.main.url(forResource: "atom-one-light.min", withExtension: "css")
            ?? Bundle.main.url(forResource: "atom-one-light", withExtension: "css")
            ?? Bundle.main.url(forResource: "atom-one-light.min", withExtension: "css") // 再保险（有些人会误加扩展名）

        let js = (try? String(contentsOf: jsURL ?? URL(fileURLWithPath: ""), encoding: .utf8)) ?? ""
        let css = (try? String(contentsOf: cssURL ?? URL(fileURLWithPath: ""), encoding: .utf8)) ?? ""
        return (js, css)
    }()


    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true

        let web = WKWebView(frame: .zero, configuration: cfg)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.navigationDelegate = context.coordinator

        web.loadHTMLString(Self.baseHTML, baseURL: nil)
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.enqueueUpdate(code: code, language: language, in: uiView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: LiveCodeHighlighterView
        private var ready: Bool = false

        // ✅ 最新一次输入（永远只保留最后一份）
        private var latest: (code: String, language: String)? = nil
        private var lastHash: Int = 0

        // ✅ debounce
        private var workItem: DispatchWorkItem? = nil

        init(_ parent: LiveCodeHighlighterView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            // 页面 ready 后：立刻 flush 一次最新内容
            flush(in: webView, force: true)
        }

        func enqueueUpdate(code: String, language: String, in webView: WKWebView) {
            let h = (code + "||" + language).hashValue
            if h == lastHash { return }
            lastHash = h

            latest = (code, language)

            guard ready else { return }

            // ✅ 取消上一次 pending 高亮，重排一次
            workItem?.cancel()

            let delay: TimeInterval = {
                let n = code.count
                if n < 1200 { return 0.07 }
                if n < 6000 { return 0.12 }
                return 0.22
            }()

            let item = DispatchWorkItem { [weak self, weak webView] in
                guard let self, let webView else { return }
                self.flush(in: webView, force: false)
            }
            workItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }

        private func flush(in webView: WKWebView, force: Bool) {
            guard ready else { return }
            guard let p = latest else { return }

            // force=true 时：不等 debounce，直接应用（比如 webView 刚 ready）
            if force {
                workItem?.cancel()
                workItem = nil
            }

            apply(code: p.code, language: p.language, in: webView)
        }

        private func apply(code: String, language: String, in webView: WKWebView) {
            let b64 = Data(code.utf8).base64EncodedString()
            let lang = language.isEmpty ? "plaintext" : language

            let js = "setCode('\(escapeJS(lang))','\(b64)')"
            webView.evaluateJavaScript(js) { [weak self] ret, _ in
                guard let self else { return }
                if let n = ret as? NSNumber {
                    let h = CGFloat(truncating: n)
                    if abs(self.parent.dynamicHeight - h) > 1 {
                        DispatchQueue.main.async {
                            self.parent.dynamicHeight = h
                        }
                    }
                }
            }
        }

        private func escapeJS(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "")
        }
    }


    // MARK: - HTML
    private static var baseHTML: String {
        let js = cached.js
        let css = cached.css
        return """
<!doctype html>
<html>
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0"/>
<style>
\(css)
html, body { margin:0; padding:0; background: transparent; }
pre { margin:0; padding:0; }
code { display:block; padding:12px; font-size: 13px; line-height: 18px; }
</style>
<script>
\(js)
</script>
<script>
function setCode(lang, b64) {
  try {
    var raw = atob(b64);
    var el = document.getElementById('code');
    el.className = 'language-' + (lang || 'plaintext');
    el.textContent = raw;
    if (window.hljs && window.hljs.highlightElement) {
      window.hljs.highlightElement(el);
    }
    return document.body.scrollHeight;
  } catch(e) {
    return document.body.scrollHeight;
  }
}
</script>
</head>
<body>
<pre><code id="code" class="language-plaintext"></code></pre>
</body>
</html>
"""
    }
}


// MARK: - OfflineCodeHighlighterView（保持原样）

struct OfflineCodeHighlighterView: UIViewRepresentable {
    let code: String
    let language: String
    @Binding var dynamicHeight: CGFloat

    private static let cached: (js: String, css: String)? = {
        guard
            let jsURL = Bundle.main.url(forResource: "highlight.min", withExtension: "js"),
            let cssURL = Bundle.main.url(forResource: "atom-one-light.min", withExtension: "css"),
            let jsData = try? Data(contentsOf: jsURL),
            let cssData = try? Data(contentsOf: cssURL),
            var js = String(data: jsData, encoding: .utf8),
            let css = String(data: cssData, encoding: .utf8)
        else { return nil }

        js = js.replacingOccurrences(of: "</script", with: "<\\/script")
        return (js: js, css: css)
    }()

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.navigationDelegate = context.coordinator
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        guard let cached = Self.cached else {
            web.loadHTMLString("<pre>Missing hljs assets</pre>", baseURL: nil)
            return
        }

        let escaped = htmlEscape(code)
        let lang = language.trimmingCharacters(in: .whitespacesAndNewlines)
        let langClass = lang.isEmpty ? "" : "language-\(lang)"

        let html = """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <style>
            body { margin: 0; background: transparent; }
            pre {
              margin: 0; padding: 12px;
              border-radius: 12px;
              background: #f6f8fa;
              overflow-x: auto;
              font-family: ui-monospace, Menlo, Monaco, Consolas, "Courier New", monospace;
              font-size: 14.5px; line-height: 1.45;
            }
          </style>
          <style>\(cached.css)</style>
          <script>\(cached.js)</script>
        </head>
        <body>
          <pre><code class="\(langClass)">\(escaped)</code></pre>
          <script>
            try {
              var el = document.querySelector('pre code');
              if (window.hljs && el) { hljs.highlightElement(el); }
            } catch(e) {}
          </script>
        </body>
        </html>
        """

        web.loadHTMLString(html, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(dynamicHeight: $dynamicHeight)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var dynamicHeight: CGFloat
        init(dynamicHeight: Binding<CGFloat>) { _dynamicHeight = dynamicHeight }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("document.body.scrollHeight") { [weak self] result, _ in
                guard let self else { return }
                if let h = result as? Double {
                    DispatchQueue.main.async { self.dynamicHeight = max(44, CGFloat(h)) }
                }
            }
        }
    }

    private func htmlEscape(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: "&", with: "&amp;")
        t = t.replacingOccurrences(of: "<", with: "&lt;")
        t = t.replacingOccurrences(of: ">", with: "&gt;")
        t = t.replacingOccurrences(of: "\"", with: "&quot;")
        return t
    }
}

// =======================================================
// ✅ Home quick status (for HomeChatView icon dot)
// =======================================================

@MainActor
final class HAQuickHomeEntryVM: ObservableObject {

    enum Status: Equatable {
        case unknown
        case checking
        case online
        case offline
    }

    @Published private(set) var status: Status = .unknown

    private var task: Task<Void, Never>?

    func refresh() {
        task?.cancel()

        guard let gw = loadGateway() else {
            status = .unknown
            return
        }

        status = .checking

        task = Task { [weak self] in
            guard let self else { return }
            let ok = await self.health(baseURL: gw.baseURL, token: gw.token)
            if Task.isCancelled { return }
            self.status = ok ? .online : .offline
        }
    }

    // MARK: - Gateway config loader

    private struct Gateway {
        let baseURL: String
        let token: String?
    }

    private func loadGateway() -> Gateway? {

        // 1) Standalone module store: ha_home_gateway_config_v2
        if let data = UserDefaults.standard.data(forKey: "ha_home_gateway_config_v2"),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {

            let base =
            (obj["gatewayBaseURL"] as? String)
            ?? (obj["gateway_base_url"] as? String)
            ?? (obj["baseURL"] as? String)
            ?? (obj["base_url"] as? String)

            let token =
            (obj["gatewayToken"] as? String)
            ?? (obj["gateway_token"] as? String)
            ?? (obj["token"] as? String)

            if let base = base?.trimmingCharacters(in: .whitespacesAndNewlines),
               !base.isEmpty {
                return Gateway(baseURL: normalizeBaseURL(base), token: normalizeToken(token))
            }
        }

        // 2) Fallback store: home_device_profile_v1 (older module)
        if let data = UserDefaults.standard.data(forKey: "home_device_profile_v1"),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {

            if let pi = obj["pi"] as? [String: Any] {
                let base = (pi["baseURL"] as? String) ?? (pi["base_url"] as? String) ?? (pi["pi_base_url"] as? String)
                let token = pi["token"] as? String
                if let base = base?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !base.isEmpty {
                    return Gateway(baseURL: normalizeBaseURL(base), token: normalizeToken(token))
                }
            }
        }

        return nil
    }

    private func normalizeBaseURL(_ s: String) -> String {
        var v = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while v.hasSuffix("/") { v.removeLast() }
        return v
    }

    private func normalizeToken(_ t: String?) -> String? {
        let raw = (t ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if raw.lowercased().hasPrefix("bearer ") { return raw }
        return "Bearer \(raw)"
    }

    // MARK: - Health check

    private func health(baseURL: String, token: String?) async -> Bool {
        guard let url = URL(string: baseURL + "/health") else { return false }

        var req = URLRequest(url: url, timeoutInterval: 2.5)
        req.httpMethod = "GET"
        if let token, !token.isEmpty {
            req.setValue(token, forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(code) else { return false }

            if let s = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !s.isEmpty {
                let u = s.uppercased()
                return u == "OK" || u == "TRUE" || u.contains("OK") || u.contains("TRUE")
            }
            return true
        } catch {
            return false
        }
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

            var req = URLRequest(url: URL(string: "\(apiBase)/auth/login")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")

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
            var req = URLRequest(url: URL(string: "\(apiBase)/conversations")!)
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
            var req = URLRequest(url: URL(string: "\(apiBase)/conversations/direct")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
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
            var req = URLRequest(url: comps.url!)
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
            var req = URLRequest(url: URL(string: "\(apiBase)/messages")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
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

struct WeChatHomeSheetView: View {
    let apiBase: String
    @ObservedObject var store: WeChatStore

    let onOpenGPT: () -> Void
    let onOpenHomeLegacy: () -> Void

    @Environment(\.dismiss) private var dismiss

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
                            title: "Solara（GPT）",
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
    @Environment(\.dismiss) private var dismiss

    @State private var peerId: String = ""

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
            Circle()
                .fill(Color.gray.opacity(0.25))
                .frame(width: 44, height: 44)
                .overlay(Text(String(title.prefix(1))).font(.headline))

            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 17, weight: .semibold))
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
                .onChange(of: items.count) { _ in
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
            if isMe { Spacer(minLength: 40) }

            Text(text)
                .font(.system(size: 16))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(isMe ? Color.blue.opacity(0.14) : Color.gray.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .frame(maxWidth: 280, alignment: isMe ? .trailing : .leading)

            if !isMe { Spacer(minLength: 40) }
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
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            .navigationTitle(conv.title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}









