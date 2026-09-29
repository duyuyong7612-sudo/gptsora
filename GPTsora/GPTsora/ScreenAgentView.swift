// ScreenAgentView.swift
// 阿杜 屏幕共享 Agent · 极简全屏 UI
//
// 设计原则:
//   - 用户在看电脑屏幕,iPhone 只是麦克风+音响+遥控器
//   - UI 元素只有 4 个:状态点、字幕、波纹动画、挂断按钮
//   - 黑底白字,语音通话风格

// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-93f7bcceafeaf74656728e63887db4022ca812cb64691504981023c4b5982575"
// Source-SHA256: "4d8727a16f7ffbf9b0dcd9d3d84cdd83555281b2308b01a9f68ddee5aae307fe"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI
import Combine

struct ScreenAgentView: View {

    let backendBase: String
    let userKey: String
    let onClose: () -> Void

    // MARK: 状态

    @StateObject private var vm: ScreenAgentVM
    @Environment(\.scenePhase) private var scenePhase

    init(backendBase: String, userKey: String, onClose: @escaping () -> Void) {
        self.backendBase = backendBase
        self.userKey = userKey
        self.onClose = onClose
        _vm = StateObject(wrappedValue: ScreenAgentVM(
            backendBase: backendBase,
            userKey: userKey
        ))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {

                // ═══ 顶部:关闭 + 状态 ═══
                HStack {
                    Button {
                        vm.stop()
                        onClose()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.15))
                            .clipShape(Circle())
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        Text(statusText)
                            .font(.subheadline)
                            .foregroundColor(.white)
                    }

                    Spacer()
                    Color.clear.frame(width: 36, height: 36)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                Spacer()

                // ═══ 中央:字幕区(AI 最近一句话) ═══
                VStack(spacing: 12) {
                    if !vm.assistantSubtitle.isEmpty {
                        Text(vm.assistantSubtitle)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .lineLimit(4)
                            .animation(.easeInOut(duration: 0.2), value: vm.assistantSubtitle)
                    }
                    if !vm.userSubtitle.isEmpty {
                        Text(vm.userSubtitle)
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.5))
                            .padding(.horizontal, 24)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 40)

                Spacer()

                // ═══ 中下:浪花动画 ═══
                VoiceWaveView(active: vm.userSpeaking || vm.assistantSpeaking,
                              accent: vm.assistantSpeaking ? .green : .blue)
                    .frame(height: 80)
                    .padding(.bottom, 16)

                Text(callStatusText)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.bottom, 30)

                // ═══ 底部:控制按钮 ═══
                HStack(spacing: 32) {

                    // 静音
                    Button {
                        vm.toggleMute()
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: vm.isMuted ? "mic.slash.fill" : "mic.fill")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundColor(vm.isMuted ? .red : .white)
                                .frame(width: 64, height: 64)
                                .background(Color.white.opacity(0.15))
                                .clipShape(Circle())
                            Text(vm.isMuted ? "已静音" : "麦克风")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }

                    // 挂断
                    Button {
                        vm.stop()
                        onClose()
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "phone.down.fill")
                                .font(.system(size: 26, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 72, height: 72)
                                .background(Color.red)
                                .clipShape(Circle())
                            Text("挂断")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .onAppear { vm.start() }
        .onDisappear { vm.stop() }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .background {
                // 后台保活:不停,Realtime + Mac 共享继续工作
            }
        }
    }

    // MARK: 派生属性

    private var statusColor: Color {
        switch vm.linkStatus {
        case .ready: return .green
        case .connecting: return .yellow
        case .reconnecting: return .orange
        case .disconnected: return .gray
        }
    }

    private var statusText: String {
        switch vm.linkStatus {
        case .ready:
            return vm.macOnline ? "已就绪 · 看着电脑" : "等待 Mac 上线"
        case .connecting: return "正在接通..."
        case .reconnecting: return "重连中..."
        case .disconnected: return "未连接"
        }
    }

    private var callStatusText: String {
        if vm.linkStatus != .ready { return " " }
        if vm.assistantSpeaking { return "阿杜在说话..." }
        if vm.userSpeaking { return "在听你说..." }
        return "随时说话即可"
    }
}

// ════════════════════════════════════════════════════════════════
// MARK: ViewModel — 桥接 ScreenAgentSession
// ════════════════════════════════════════════════════════════════

@MainActor
final class ScreenAgentVM: ObservableObject, ScreenAgentSessionDelegate {

    enum LinkStatus {
        case disconnected, connecting, reconnecting, ready
    }

    @Published var linkStatus: LinkStatus = .disconnected
    @Published var macOnline: Bool = false
    @Published var assistantSubtitle: String = ""
    @Published var userSubtitle: String = ""
    @Published var userSpeaking: Bool = false
    @Published var assistantSpeaking: Bool = false
    @Published var lastToolName: String = ""
    @Published var isMuted: Bool = false

    private let session: ScreenAgentSession

    init(backendBase: String, userKey: String) {
        let cfg = ScreenAgentConfig(
            backendBase: backendBase,
            userKey: userKey
        )
        self.session = ScreenAgentSession(config: cfg)
        session.delegate = self
    }

    func start() {
        guard linkStatus == .disconnected else { return }
        linkStatus = .connecting
        session.start()
    }

    func stop() {
        session.stop()
        linkStatus = .disconnected
    }

    func toggleMute() {
        session.toggleMute()
        isMuted = session.isMuted
    }

    // MARK: ScreenAgentSessionDelegate

    func sessionDidConnect() {
        linkStatus = .ready
    }

    func sessionDidDisconnect(error: String?) {
        if linkStatus == .ready {
            linkStatus = .reconnecting
        }
    }

    func sessionDidUpdateMacOnline(_ online: Bool) {
        macOnline = online
    }

    func sessionDidReceiveSubtitle(_ text: String, isFinal: Bool) {
        if text.hasPrefix("(我:") {
            // 用户字幕(已经在 ScreenAgentSession 加了前缀)
            userSubtitle = String(text.dropFirst(3).dropLast())
        } else {
            // 助手字幕
            if isFinal {
                assistantSubtitle = text
            } else {
                // 流式增量
                assistantSubtitle = text
            }
        }
    }

    func sessionDidStartUserSpeaking() {
        userSpeaking = true
        // 用户开口说话,清空之前 AI 字幕避免误读
        assistantSubtitle = ""
    }

    func sessionDidStopUserSpeaking() {
        userSpeaking = false
    }

    func sessionDidStartAssistantSpeaking() {
        assistantSpeaking = true
        assistantSubtitle = ""  // 新一轮 AI 输出,清空旧字幕
    }

    func sessionDidStopAssistantSpeaking() {
        assistantSpeaking = false
    }

    func sessionDidExecuteTool(_ name: String, args: [String: Any]) {
        // 把 mac_screen_glance → "看一眼" 这种简短显示
        lastToolName = toolDisplayName(name)
        // 1.5 秒后淡出
        Task { @MainActor in
            let snapshot = lastToolName
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if lastToolName == snapshot {
                lastToolName = ""
            }
        }
    }

    private func toolDisplayName(_ name: String) -> String {
        switch name {
        case "mac_screen_glance": return "看一眼"
        case "mac_screen_watch": return "持续看"
        case "mac_screen_pause": return "暂停看"
        case "mac_click_by_title": return "精准点击"  // ⭐
        case "mac_ax_tree": return "查元素树"  // ⭐
        case "mac_click": return "点击"
        case "mac_key": return "按键"
        case "mac_paste": return "输入"
        case "mac_scroll": return "滚动"
        case "mac_drag": return "拖拽"
        case "mac_shell": return "命令"
        case "mac_applescript": return "脚本"
        case "ask_user": return "请示"
        case "report_done": return "完成"
        default: return name
        }
    }
}

// ════════════════════════════════════════════════════════════════
// MARK: 浪花波形动画
// ════════════════════════════════════════════════════════════════

private struct VoiceWaveView: View {
    let active: Bool
    let accent: Color

    @State private var phase: Double = 0
    private let timer = Timer.publish(every: 1.0/30, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 4) {
                ForEach(0..<24, id: \.self) { i in
                    let amp = barAmplitude(index: i)
                    Capsule()
                        .fill(accent.opacity(active ? 0.9 : 0.3))
                        .frame(width: 4, height: max(6, amp * geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.1), value: phase)
        }
        .onReceive(timer) { _ in
            if active {
                phase += 0.15
            } else {
                phase += 0.05
            }
        }
    }

    private func barAmplitude(index: Int) -> Double {
        let base = sin(phase + Double(index) * 0.4) * 0.5 + 0.5
        let center = 1.0 - abs(Double(index) - 12) / 12.0
        let energy = active ? base : 0.15
        return energy * center
    }
}



