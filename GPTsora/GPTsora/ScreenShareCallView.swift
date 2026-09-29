// ScreenShareCallView.swift
// 阿杜屏幕共享语音通话页
//
// 用户体验:
//   - 大画面显示 Mac 屏幕(每秒刷新)
//   - 底部 3 个按钮:静音 / 挂断 / (预留)
//   - 顶部状态:Mac 在线状态 + 通话中
//
// 数据流:
//   - HomeChatView 传入 latestImage (Mac 屏幕),实时刷新
//   - HomeChatView 已经启动了 Realtime 音频(fast.bridge.startAudio())
//   - HomeChatView 已经启动了 MacScreenSource,Mac 帧已注入 Realtime
//   - 这里只是 UI 展示 + 通话控制

// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-d482fa92cea48ed96072d135d4e0bac1f2a0b8893e91adb905072e739be54916"
// Source-SHA256: "267eb495649c87be76ac623d0ed8b7ddf319fedf902a6c39b928686be531b6c4"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI

struct ScreenShareCallView: View {

    let apiBase: String
    let userKey: String
    @Binding var latestImage: UIImage?
    @Binding var macOnline: Bool
    let onClose: () -> Void

    @ObservedObject private var fast = RealtimeFastLane.shared
    @State private var isMuted = false

    var body: some View {
        ZStack {
            // 黑色全屏背景
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {

                // ════ 顶部状态栏 ════
                HStack {
                    Button {
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
                            .fill(macOnline ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                        Text(macOnline ? "电脑屏幕共享中" : "等待电脑接入")
                            .font(.subheadline)
                            .foregroundColor(.white)
                    }

                    Spacer()

                    // 占位让标题居中
                    Color.clear.frame(width: 36, height: 36)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                // ════ Mac 屏幕预览 ════
                ZStack {
                    if let img = latestImage {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .cornerRadius(14)
                            .padding(.horizontal, 12)
                    } else {
                        VStack(spacing: 14) {
                            Image(systemName: "desktopcomputer")
                                .font(.system(size: 56))
                                .foregroundColor(.gray)
                            if macOnline {
                                Text("正在接收屏幕画面...")
                                    .font(.subheadline)
                                    .foregroundColor(.gray)
                            } else {
                                Text("请确认 Mac 上 adu-bridge 已运行")
                                    .font(.subheadline)
                                    .foregroundColor(.gray)
                                Text("./adu-bridge --backend ws://… --user-key …")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.gray.opacity(0.7))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // ════ 通话状态文字 ════
                VStack(spacing: 4) {
                    Text(connectionStatusText)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                }
                .padding(.bottom, 12)

                // ════ 底部控制按钮 ════
                HStack(spacing: 32) {

                    // 静音
                    Button {
                        isMuted.toggle()
                        fast.bridge.setMuted(isMuted)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundColor(isMuted ? .red : .white)
                                .frame(width: 64, height: 64)
                                .background(Color.white.opacity(0.15))
                                .clipShape(Circle())
                            Text(isMuted ? "已静音" : "麦克风")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }

                    // 挂断
                    Button {
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

                    // 占位(后续可放"切换 Mac" / "发送指令"等)
                    VStack(spacing: 6) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundColor(.white.opacity(0.4))
                            .frame(width: 64, height: 64)
                            .background(Color.white.opacity(0.08))
                            .clipShape(Circle())
                        Text("更多")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
                .padding(.bottom, 40)
            }
        }
    }

    private var connectionStatusText: String {
        if !macOnline { return "等待电脑端 adu-bridge 上线" }
        if !fast.isListening { return "正在接通语音..." }
        return "通话中 — 直接对阿杜说话"
    }
}

