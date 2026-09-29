//
//  3ContentView_UIComponents.swift  (SUBMODULE 3)
//  ✅ UI Components (Reusable)
//  ✅ No video generation logic here (no enqueue / no Sora calls)
//  - RealtimeHintBubble
//  - BottomInputBar (gating + onSend / onSendBlocked callbacks)
//  - CenterRealtimeButton
//  - RealtimeTranscriptBubble (稳定实时字幕)
//  - PlayerShareSheet / Toasts
//  - ImagePicker / VideoPicker
//

// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-6cb62641d5fe99949a257cab633c07a35bfb6803f28f6e87b3844d13f526a27f"
// Source-SHA256: "4e7ad1ea8e10edb250582c8036309ae3eba07bb4b7c7336a83b6bac486e78c43"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI
import UIKit

// MARK: - OnChange compatibility (iOS16/17+)
private struct OnChangeCompat<Value: Equatable>: ViewModifier {
    let value: Value
    let action: (Value) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.onChange(of: value) { _, newValue in
                action(newValue)
            }
        } else {
            content.onChange(of: value) { newValue in
                action(newValue)
            }
        }
    }
}

private extension View {
    func onChangeCompat<Value: Equatable>(_ value: Value, perform action: @escaping (Value) -> Void) -> some View {
        modifier(OnChangeCompat(value: value, action: action))
    }
}

// MARK: - Realtime hint bubble
struct RealtimeHintBubble: View {
    let text: String
    var body: some View {
        Text(text)
            .foregroundColor(.white)
            .font(.system(size: 13, weight: .semibold))
            .padding(10)
            .background(Color.white.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// ✅ NEW: 稳定实时字幕（不做打字机，避免高频更新把 displayed 清空）
struct RealtimeTranscriptBubble: View {
    let text: String
    var body: some View {
        Text(text)
            .foregroundColor(.white)
            .font(.system(size: 15, weight: .semibold))
            .padding(12)
            .background(Color.white.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Bottom input bar (supports gating)
struct BottomInputBar: View {
    @Binding var text: String
    let hasMedia: Bool
    @FocusState.Binding var isTextFieldFocused: Bool

    /// ✅ 视频包门禁：是否允许发送（例如 videoCredits > 0）
    let canSend: Bool
    var placeholder: String = "Describe a new video"

    let onPlus: () -> Void
    /// ✅ 允许发送时触发（主模块负责真正生成）
    let onSend: () -> Void
    /// ✅ 被门禁拦截时触发（例如打开 video offering）
    let onSendBlocked: () -> Void

    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var hasContent: Bool { hasText || hasMedia }

    private func triggerSend() {
        guard hasContent else { return }
        if canSend { onSend() } else { onSendBlocked() }
    }

    var body: some View {
        let circleSize: CGFloat = 46
        let iconSize: CGFloat = 20
        let barHeight: CGFloat = 48

        VStack(spacing: 6) {
            HStack(spacing: 10) {

                Button(action: onPlus) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.18))
                            .frame(width: circleSize, height: circleSize)
                        Image(systemName: "photo.on.rectangle")
                            .foregroundColor(.white)
                            .font(.system(size: iconSize, weight: .medium))
                    }
                }
                .buttonStyle(.plain)

                ZStack(alignment: .leading) {
                    if text.isEmpty {
                        Text(placeholder)
                            .foregroundColor(.white.opacity(0.5))
                            .padding(.horizontal, 16)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    TextField("", text: $text)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .focused($isTextFieldFocused)
                        .submitLabel(.send)
                        .onSubmit { triggerSend() } // ✅ 回车也走门禁
                }
                .frame(height: barHeight)
                .background(Color.white.opacity(0.16))
                .clipShape(Capsule())

                Button(action: { triggerSend() }) {
                    ZStack {
                        Circle()
                            .fill((hasContent && canSend) ? Color.black : Color.black.opacity(0.25))
                            .frame(width: circleSize, height: circleSize)

                        if hasContent {
                            if canSend {
                                Image(systemName: "arrow.up")
                                    .foregroundColor(.white)
                                    .font(.system(size: iconSize + 2, weight: .bold))
                            } else {
                                Image(systemName: "lock.fill")
                                    .foregroundColor(.white.opacity(0.75))
                                    .font(.system(size: 16, weight: .semibold))
                            }
                        } else {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.black.opacity(0.8))
                                .frame(width: 14, height: 14)
                        }
                    }
                }
                .buttonStyle(.plain)
                .opacity(hasContent ? 1.0 : 0.5)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }
}

// MARK: - Center realtime button
struct CenterRealtimeButton: View {
    let isConnecting: Bool
    let isRunning: Bool
    let onTap: () -> Void

    @State private var pulse = false

    var body: some View {
        let circleSize: CGFloat = 46
        let isActive = isConnecting || isRunning

        let bgColor: Color = isActive ? Color(red: 0.10, green: 0.46, blue: 0.98) : .black
        let fgColor: Color = .white

        return VStack(spacing: 6) {
            Button(action: {
                if isConnecting { return }
                onTap()
            }) {
                ZStack {
                    Circle().fill(bgColor).frame(width: circleSize, height: circleSize)

                    if isConnecting {
                        ProgressView().tint(fgColor)
                    } else {
                        Image(systemName: "waveform")
                            .foregroundColor(fgColor)
                            .font(.system(size: 22, weight: .medium))
                            .scaleEffect((!isActive && pulse) ? 1.08 : 0.96)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isConnecting)

            Text(isConnecting ? "Connecting…" : (isRunning ? "Connected" : ""))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

// MARK: - Share sheet
struct PlayerShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Toasts
struct PlayerToastHUD: View {
    let text: String
    var body: some View {
        VStack {
            Text(text)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.65))
                .clipShape(Capsule())
                .padding(.top, 22)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

struct MiniTopToast: View {
    let text: String
    var body: some View {
        HStack {
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.65))
                .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
        .allowsHitTesting(false)
    }
}

// MARK: - UIKit pickers
struct ImagePicker: UIViewControllerRepresentable {
    var sourceType: UIImagePickerController.SourceType
    var completion: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let completion: (UIImage?) -> Void
        init(completion: @escaping (UIImage?) -> Void) { self.completion = completion }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true) { self.completion(nil) }
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            let img = info[.originalImage] as? UIImage
            picker.dismiss(animated: true) { self.completion(img) }
        }
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        picker.delegate = context.coordinator
        picker.mediaTypes = ["public.image"]
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
}

struct VideoPicker: UIViewControllerRepresentable {
    var sourceType: UIImagePickerController.SourceType
    var completion: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let completion: (URL?) -> Void
        init(completion: @escaping (URL?) -> Void) { self.completion = completion }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true) { self.completion(nil) }
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            let url = info[.mediaURL] as? URL
            picker.dismiss(animated: true) { self.completion(url) }
        }
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        picker.delegate = context.coordinator
        picker.mediaTypes = ["public.movie"]
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
}
