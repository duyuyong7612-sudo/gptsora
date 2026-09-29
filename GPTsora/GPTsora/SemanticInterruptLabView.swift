
// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-478e97a53e650b1d99d31e207670845edcc94aad977b041ec57737d87e082ea9"
// Source-SHA256: "9bbf28337ec2386a698289d2f0a785e65990aed49efc7196d70409936328380e"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI

/// 只保留真实通话按键的语义打断测试页。
/// 用法：点中间大按钮开始真实语音通话，然后直接用麦克风说话。
struct SemanticInterruptVoiceCallView: View {
    @StateObject private var service = SemanticInterruptVoiceCallService()
    @State private var showLogs = true

    var body: some View {
        VStack(spacing: 0) {
            header

            VStack(spacing: 18) {
                transcriptBlock(title: "用户转写", text: service.userTranscript.isEmpty ? "等待你说话…" : service.userTranscript)
                transcriptBlock(title: "助手字幕", text: service.assistantTranscript.isEmpty ? "等待助手输出…" : service.assistantTranscript, minHeight: 150)

                Spacer(minLength: 8)

                callButton

                HStack(spacing: 12) {
                    Button {
                        service.toggleMute()
                    } label: {
                        Label(service.isMuted ? "解除静音" : "静音", systemImage: service.isMuted ? "mic.slash.fill" : "mic.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .padding(.horizontal, 18)
                            .frame(height: 46)
                            .background(Color.gray.opacity(0.14))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        service.clearLogs()
                    } label: {
                        Label("清日志", systemImage: "trash")
                            .font(.system(size: 16, weight: .semibold))
                            .padding(.horizontal, 18)
                            .frame(height: 46)
                            .background(Color.gray.opacity(0.14))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Text("真实通话测试：没有模拟插话按钮。助手正在说话时，你直接用麦克风插话；如果语义判断没触发，就不会打断，助手会自己说完。")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)

            Divider().padding(.top, 16)

            logPanel
        }
        .background(Color.white.ignoresSafeArea())
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Circle()
                    .fill(service.isConnected ? Color.green : Color.gray.opacity(0.5))
                    .frame(width: 12, height: 12)
                Text(service.isConnected ? "实时语音已连接" : "未连接")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Text(service.isResponseActive ? "Response active" : "Response idle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(service.isResponseActive ? .orange : .secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Color.gray.opacity(0.12))
                    .clipShape(Capsule())
            }

            Text("语义打断真实通话")
                .font(.system(size: 28, weight: .bold))

            Text(service.state.title)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .background(Color.white)
    }

    private var callButton: some View {
        Button {
            service.toggleCall()
        } label: {
            VStack(spacing: 10) {
                Image(systemName: service.isConnected || service.state == .connecting ? "phone.down.fill" : "phone.fill")
                    .font(.system(size: 40, weight: .bold))
                Text(service.isConnected || service.state == .connecting ? "断开语音" : "开始语音")
                    .font(.system(size: 24, weight: .bold))
            }
            .foregroundColor(.white)
            .frame(width: 178, height: 178)
            .background(service.isConnected || service.state == .connecting ? Color.red : Color.blue)
            .clipShape(Circle())
            .shadow(color: (service.isConnected ? Color.red : Color.blue).opacity(0.25), radius: 20, y: 8)
        }
        .buttonStyle(.plain)
    }

    private func transcriptBlock(title: String, text: String, minHeight: CGFloat = 78) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.secondary)
            ScrollView {
                Text(text)
                    .font(.system(size: 20, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .frame(minHeight: minHeight, maxHeight: minHeight)
            .background(Color(white: 0.95))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("关键日志")
                    .font(.system(size: 20, weight: .bold))
                Spacer()
                Button(showLogs ? "收起" : "展开") {
                    showLogs.toggle()
                }
                .font(.system(size: 15, weight: .semibold))
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            if showLogs {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(service.logs.suffix(24)) { line in
                            Text(line.text)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(Color(white: 0.96))
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }
            }
        }
        .frame(maxHeight: showLogs ? 220 : 52)
    }
}

