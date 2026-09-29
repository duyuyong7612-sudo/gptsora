// MacScreenShareView.swift
// 阿杜 iOS 端:Mac 屏幕共享入口 UI
//
// 功能:
//   - 顶部状态栏(Mac 在线/离线)
//   - 屏幕预览(实时显示 Mac 画面)
//   - 启动屏幕共享 → 每帧自动注入 Realtime,AI 立即能看见
//   - "进入语音控制" → 跳转到现有的 RealtimeAVCallView
//
// 依赖: MacScreenSource.swift, RealtimeFastLane, RealtimeAVCallView, AppConfig

// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-88295c476c34314174620729963e1c48e71280db87210c6a2104b2b92a720d8b"
// Source-SHA256: "26915aff32aa5c688a9d3f0ef9f560230323963cd7a933e25e08608326f4ab98"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI

struct MacScreenShareView: View {
    let apiBase: String
    let userKey: String

    @StateObject private var source: MacScreenSource
    @State private var sharingStarted = false
    @State private var showRealtimeCall = false
    @State private var showCopyToast = false

    init(apiBase: String, userKey: String) {
        self.apiBase = apiBase
        self.userKey = userKey
        _source = StateObject(wrappedValue: MacScreenSource(apiBase: apiBase, userKey: userKey))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {

                // ═══ 状态栏 ═══
                HStack {
                    Circle()
                        .fill(source.macOnline ? Color.green : Color.gray)
                        .frame(width: 10, height: 10)
                    Text(source.macOnline ? "Mac 已连接" : "Mac 未连接")
                        .font(.subheadline)

                    if sharingStarted {
                        Text("· 推帧中")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }

                    Spacer()
                    Text(source.connected ? "iOS 已订阅" : "未订阅")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                // ═══ 屏幕预览 ═══
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.92))

                    if let img = source.latestImage {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .cornerRadius(12)
                    } else {
                        VStack(spacing: 14) {
                            Image(systemName: "desktopcomputer")
                                .font(.system(size: 50))
                                .foregroundStyle(.gray)

                            if source.macOnline {
                                Text("等待第一帧...")
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("请在 Mac 启动 adu-bridge")
                                    .foregroundStyle(.secondary)

                                VStack(spacing: 6) {
                                    Text("终端运行:")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text("./adu-bridge --backend \(wsBase) \\\n  --user-key \(userKey.prefix(8))...")
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal)
                                }
                                .padding(.top, 8)
                            }
                        }
                    }
                }
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .padding(.horizontal)

                // ═══ 操作按钮 ═══
                if sharingStarted {
                    Button {
                        showRealtimeCall = true
                    } label: {
                        Label("进入语音控制", systemImage: "waveform.circle.fill")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accentColor)
                            .cornerRadius(14)
                    }
                    .padding(.horizontal)

                    Button(role: .destructive) {
                        stopSharing()
                    } label: {
                        Text("停止屏幕共享")
                    }
                    .padding(.top, 4)

                } else {
                    Button {
                        startSharing()
                    } label: {
                        Label("开始屏幕共享", systemImage: "rectangle.on.rectangle")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(source.macOnline ? Color.accentColor : Color.gray)
                            .cornerRadius(14)
                    }
                    .disabled(!source.macOnline)
                    .padding(.horizontal)

                    if !source.macOnline {
                        Text("提示:在 Mac 上运行 adu-bridge 后会自动连接")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }
                }

                // ═══ 调试信息 ═══
                VStack(alignment: .leading, spacing: 4) {
                    Text("调试信息")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("apiBase: \(apiBase)")
                        .font(.system(.caption2, design: .monospaced))
                    Text("ws: \(wsBase)/ws/screen/subscribe/...")
                        .font(.system(.caption2, design: .monospaced))
                    Text("user_key: \(userKey)")
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .onTapGesture {
                            UIPasteboard.general.string = userKey
                            showCopyToast = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                showCopyToast = false
                            }
                        }
                    if showCopyToast {
                        Text("✅ 已复制到剪贴板")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 12)
            }
            .padding(.vertical)
        }
        .navigationTitle("🖥️ 电脑屏幕共享")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showRealtimeCall) {
            // ⚠️ 这里需要替换成你项目里真实的 RealtimeAVCallView 入口
            // 关键:启动时必须是 audioVideo 模式,这样 injectImageData 才生效
            RealtimeVoiceCallShim(apiBase: apiBase)
        }
        .onDisappear { stopSharing() }
    }

    // MARK: Helpers

    private var wsBase: String {
        var s = apiBase
        if s.hasPrefix("https://") { s = "wss://" + String(s.dropFirst("https://".count)) }
        else if s.hasPrefix("http://") { s = "ws://" + String(s.dropFirst("http://".count)) }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func startSharing() {
        guard source.macOnline else { return }
        sharingStarted = true

        // 🆕 让 RealtimeAVService 的 mac_click / mac_key / mac_paste / mac_scroll 工具能下发指令
        RealtimeFastLane.shared.macScreenSource = source

        source.start { jpegData in
            // ⭐️ 核心一行:Mac 屏幕帧 → Realtime,AI 立刻看见
            // (复用摄像头帧通道,GPT/Qwen 两家都已适配)
            RealtimeFastLane.shared.bridge.sendCameraFrameJPEG(jpegData)
        }
    }

    private func stopSharing() {
        sharingStarted = false
        source.stop()
        RealtimeFastLane.shared.macScreenSource = nil
    }
}


// MARK: - Realtime 通话壳
// 复用项目里的 RealtimeAVCallView。
// 屏幕共享场景下:
//   - Mac 屏幕帧由 MacScreenSource 持续推(每秒 1 帧)
//   - iPhone 摄像头帧由 RealtimeAVCallView 推(被 isSendingFrames toggle 控制)
//   - 进入后用户可以手动按"眼睛"按钮关掉 iPhone 帧,只让 Mac 帧进入

private struct RealtimeVoiceCallShim: View {
    let apiBase: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        RealtimeAVCallView(
            apiBase: apiBase,
            rt: RealtimeFastLane.shared.bridge,
            messages: .constant([]),
            onClose: { dismiss() }
        )
    }
}

