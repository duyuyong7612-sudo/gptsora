// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-653cd7c9c3a7725a2256ece3a2b38959ddc995a9ffd2872d55d035fe566eb6d4"
// Source-SHA256: "7c149de1ea436c7d7a95cadbf3deec4481b54146f3db340ea232d172e287ba5d"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI
import UIKit
import Combine

struct RemixSheetView: View {

    let baseVideoId: String
    @Binding var text: String

    let onClose: () -> Void
    let onGenerate: () -> Void

    /// 兼容保留（外部可以不做任何事，传 {} 即可）
    let onStartVoice: () -> Void

    // ✅ 内置：把波纹键真正接入 Realtime（Remix 专用助手）
    @StateObject private var voice: RemixVoiceAgent

    // ✅ 自定义 init：确保 baseVideoId 注入 voice
    init(
        baseVideoId: String,
        text: Binding<String>,
        onClose: @escaping () -> Void,
        onGenerate: @escaping () -> Void,
        onStartVoice: @escaping () -> Void = {}
    ) {
        self.baseVideoId = baseVideoId
        self._text = text
        self.onClose = onClose
        self.onGenerate = onGenerate
        self.onStartVoice = onStartVoice
        _voice = StateObject(wrappedValue: RemixVoiceAgent(baseVideoId: baseVideoId))
    }

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {

                // 顶部栏
                HStack {
                    Text("二次生成（Remix）")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)

                    Spacer()

                    Button("关闭") {
                        voice.stop()
                        onClose()
                    }
                    .foregroundColor(.white.opacity(0.85))
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

                // ✅ Base ID 显示（必须）
                BaseIdRow(baseId: baseVideoId)

                // 输入框（无 placeholder/无提示）
                TextEditor(text: $text)
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .frame(height: 210)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.10), lineWidth: 1)
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 10)

                Spacer()

                // ✅ 波纹键：输入框有字时消失
                if !hasText {
                    RemixRippleButton(
                        size: 56, // ✅ 小一号
                        isConnected: voice.state == .listening,
                        isConnecting: voice.state == .connecting
                    ) {
                        RemixHaptics.impact(.heavy)

                        // 外部兼容回调
                        onStartVoice()

                        // 真正动作：切换语音
                        voice.toggle()
                    }
                    .transition(.scale(scale: 0.86).combined(with: .opacity))
                    .padding(.bottom, 10)
                }

                // ✅ 短白胶囊（文本手动触发）
                ShortWhiteCapsule(
                    title: voice.isGenerating ? "生成中…" : "开始生成",
                    enabled: !voice.isGenerating && hasText
                ) {
                    // ✅ 这里就是“用户最终确认”
                    // 后端要求 user_confirm_text 的话，你需要在 onGenerate() 里把 user_confirm_text="客户己确定" 一起带上。
                    onGenerate()
                }
                .padding(.bottom, 18)
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: hasText)
        .onAppear {
            // ✅ 语音触发点：拿到 REMIX 指令后 -> 只填入输入框（不自动生成，防确发）
            voice.onAutoInstruction = { inst in
                self.text = inst
                // ✅ 不再 self.onGenerate()
            }
        }
        .onDisappear {
            voice.stop()
        }
    }
}

// ======================================================================
// MARK: - Voice Agent (Realtime Remix Only, NOT Sora Planner)
// ======================================================================

@MainActor
private final class RemixVoiceAgent: NSObject, ObservableObject, RealtimeQuickServiceDelegate {

    enum State { case idle, connecting, listening }

    @Published var state: State = .idle
    @Published var isGenerating: Bool = false

    let baseVideoId: String
    var onAutoInstruction: ((String) -> Void)?

    private weak var prevDelegate: RealtimeQuickServiceDelegate?
    private var hasTriggered = false

    // ✅ 统一口令：你要求“客户己确定”（兼容“客户已确定”）
    private static let confirmPrimary = "客户己确定"
    private static let confirmCompat  = "客户已确定"

    init(baseVideoId: String) {
        self.baseVideoId = baseVideoId.trimmingCharacters(in: .whitespacesAndNewlines)
        super.init()
    }

    func toggle() {
        if state == .idle { start() } else { stop() }
    }

    func start() {
        guard state == .idle else { return }
        guard !baseVideoId.isEmpty else { return }

        hasTriggered = false
        prevDelegate = RealtimeQuickService.shared.delegate
        RealtimeQuickService.shared.delegate = self

        state = .connecting

        // ✅ 核心：只能走 Remix 专用助手（不会走通用助手）
        RealtimeQuickService.shared.startRemixAssistantCall()
    }

    func stop() {
        RealtimeQuickService.shared.stopCall()
        state = .idle
        restoreDelegateIfNeeded()
    }

    private func restoreDelegateIfNeeded() {
        if RealtimeQuickService.shared.delegate === self {
            RealtimeQuickService.shared.delegate = prevDelegate
        }
        prevDelegate = nil
    }

    // MARK: - Delegate callbacks

    func realtimeServiceDidConnect(_ svc: RealtimeQuickService) {
        state = .listening
    }

    func realtimeServiceDidDisconnect(_ svc: RealtimeQuickService) {
        state = .idle
        restoreDelegateIfNeeded()
    }

    func realtimeService(_ svc: RealtimeQuickService, didUpdateStatus text: String) { }

    func realtimeService(_ svc: RealtimeQuickService, didFailWith error: Error) {
        state = .idle
        restoreDelegateIfNeeded()
    }

    func realtimeService(_ svc: RealtimeQuickService, didTriggerSoraWithUserPrompt userPrompt: String, assistantSummary: String) {
        // ✅ Remix 模式不应走这里（为了安全：不触发）
    }

    func realtimeService(_ svc: RealtimeQuickService, didUpdateTranscript text: String) {
        // 只解析 assistant 文本，找到 REMIX: 触发行（且必须带 ##CONFIRM=客户己确定）
        guard !hasTriggered else { return }
        guard text.hasPrefix("[A]") else { return }
        let assistant = String(text.dropFirst(3))

        // ✅ 本地严格解析：必须确认标记存在，才算“语义最终确认”
        if let inst = Self.extractRemixInstructionStrict(from: assistant) {
            hasTriggered = true
            isGenerating = false

            // ✅ 只把指令交给 UI（写入输入框）
            onAutoInstruction?(inst)

            // ✅ 触发后立刻停掉 Realtime，避免重复/叠加
            stop()
        }
    }

    // MARK: - Strict Parser

    /// 只接受：
    /// REMIX: <english prompt> ##CONFIRM=客户己确定
    /// （兼容 ##CONFIRM=客户已确定）
    static func extractRemixInstructionStrict(from assistantText: String) -> String? {
        let normalized = assistantText.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        // 找 REMIX: 行
        guard let line = lines.first(where: {
            $0.uppercased().hasPrefix("REMIX:") || $0.uppercased().hasPrefix("REMIX：")
        }) else {
            return nil
        }

        // 必须带确认标记（己/已）
        let hasConfirm =
            line.contains("##CONFIRM=\(confirmPrimary)") ||
            line.contains("##CONFIRM=\(confirmCompat)")

        guard hasConfirm else { return nil }

        // 提取 REMIX: 后的 prompt，并剥离协议字段
        var body = String(line.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)

        if let r = body.range(of: "##CONFIRM=") {
            body = String(body[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let r = body.range(of: "##CODE=") {
            body = String(body[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 单行化
        body = body.replacingOccurrences(of: "\n", with: " ")
        while body.contains("  ") { body = body.replacingOccurrences(of: "  ", with: " ") }

        return body.isEmpty ? nil : body
    }
}

// ======================================================================
// MARK: - UI Components
// ======================================================================

private struct BaseIdRow: View {
    let baseId: String

    private var shortId: String {
        let s = baseId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count > 16 else { return s }
        return "\(s.prefix(10))…\(s.suffix(6))"
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("Base ID")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.75))

            Text(shortId)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.92))
                .lineLimit(1)

            Spacer()

            Button {
                UIPasteboard.general.string = baseId
                RemixHaptics.impact(.light)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(6)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
    }
}

private struct ShortWhiteCapsule: View {
    let title: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.black)
                .frame(width: UIScreen.main.bounds.width * 0.66, height: 50)
                .background(enabled ? Color.white.opacity(0.95) : Color.white.opacity(0.35))
                .clipShape(Capsule())
        }
        .disabled(!enabled)
        .buttonStyle(.plain)
    }
}

// ======================================================================
// MARK: - ✅ 波纹键：白圆紫波纹 / 点击瞬间蓝圆白波纹 + 波浪光 + 触感
// ======================================================================

private struct RemixRippleButton: View {

    let size: CGFloat
    let isConnected: Bool
    let isConnecting: Bool
    let action: () -> Void

    @State private var spin = false
    @State private var tapFlash = false

    // ✅ 点击瞬间也变蓝（即使未接通）
    private var showBlue: Bool { isConnected || tapFlash }

    private var baseFill: Color {
        showBlue ? Color(hex: 0x0A84FF) : Color.white.opacity(0.98)
    }

    private var rippleColor: Color {
        showBlue ? .white : Color(hex: 0x8B5CF6)
    }

    private var dotColor: Color {
        showBlue ? .white : Color(hex: 0x7C4DFF)
    }

    var body: some View {
        Button {
            // ✅ 点击确感：触感 + 蓝闪
            RemixHaptics.impact(.heavy)
            withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) {
                tapFlash = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                withAnimation(.easeOut(duration: 0.18)) {
                    tapFlash = false
                }
            }
            action()
        } label: {
            ZStack {
                // 1) 波纹（连接中更急促）
                RemixRippleRing(color: rippleColor, baseSize: size, duration: isConnecting ? 1.00 : 1.25, delay: 0.00)
                RemixRippleRing(color: rippleColor, baseSize: size, duration: isConnecting ? 1.00 : 1.25, delay: 0.38)
                RemixRippleRing(color: rippleColor, baseSize: size, duration: isConnecting ? 1.00 : 1.25, delay: 0.76)

                // 2) 波浪光环（旋转光）
                RemixWaveGlowRing(color: rippleColor, spin: spin)
                    .frame(width: size + 26, height: size + 26)
                    .opacity(showBlue ? 0.95 : 0.86)

                // 3) 主圆按钮（确感：高光+描边+阴影）
                ZStack {
                    Circle()
                        .fill(baseFill)
                        .shadow(color: rippleColor.opacity(showBlue ? 0.18 : 0.22), radius: 16, x: 0, y: 0)
                        .shadow(color: Color.black.opacity(0.25), radius: 10, x: 0, y: 8)

                    // 高光
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(showBlue ? 0.30 : 0.70),
                                    Color.white.opacity(0.0)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .blendMode(.screen)
                        .opacity(0.92)

                    Circle()
                        .strokeBorder(
                            Color.white.opacity(showBlue ? 0.70 : 0.55),
                            lineWidth: 1.2
                        )

                    // 中心点：紫 / 白
                    Circle()
                        .fill(dotColor.opacity(isConnecting ? 0.60 : 0.95))
                        .frame(width: 9, height: 9)
                        .shadow(color: dotColor.opacity(0.35), radius: 6, x: 0, y: 0)
                }
                .frame(width: size, height: size)
            }
            .frame(width: size + 34, height: size + 34)
        }
        .buttonStyle(.plain)
        .onAppear { spin = true }
        .accessibilityLabel(isConnected ? "语音已接通" : "开始语音")
    }
}

private struct RemixRippleRing: View {
    let color: Color
    let baseSize: CGFloat
    let duration: Double
    let delay: Double

    @State private var go = false

    var body: some View {
        Circle()
            .stroke(color.opacity(0.58), lineWidth: 2)
            .frame(width: baseSize, height: baseSize)
            .scaleEffect(go ? 1.90 : 0.95)
            .opacity(go ? 0.0 : 0.70)
            .blur(radius: 0.25)
            .onAppear {
                withAnimation(.easeOut(duration: duration).repeatForever(autoreverses: false).delay(delay)) {
                    go = true
                }
            }
    }
}

private struct RemixWaveGlowRing: View {
    let color: Color
    let spin: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.22), lineWidth: 10)
                .blur(radius: 10)
                .opacity(0.85)

            Circle()
                .strokeBorder(
                    AngularGradient(
                        colors: [
                            color.opacity(0.0),
                            color.opacity(0.80),
                            color.opacity(0.0),
                            color.opacity(0.55),
                            color.opacity(0.0)
                        ],
                        center: .center
                    ),
                    lineWidth: 3
                )
                .blur(radius: 0.7)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(.linear(duration: 3.8).repeatForever(autoreverses: false), value: spin)

            Circle()
                .stroke(color.opacity(0.34), lineWidth: 1)
                .blur(radius: 0.35)
        }
    }
}

// ======================================================================
// MARK: - Helpers
// ======================================================================

private enum RemixHaptics {
    private static var lastFire: CFAbsoluteTime = 0
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle,
                       minInterval: CFAbsoluteTime = 0.16) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastFire >= minInterval else { return }
        lastFire = now
        let gen = UIImpactFeedbackGenerator(style: style)
        gen.prepare()
        gen.impactOccurred()
    }
}

private extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

