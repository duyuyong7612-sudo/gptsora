// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-c42a86ae0dac7e8d7c4c365b569c9952da6c34c0d244b101cefb195dd9c98714"
// Source-SHA256: "6dcca586fe673c6cb95b58890fdbe6558fd3dc292c2a4d9c22cacd155dcc9ed4"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI

// MARK: - Mac 控制视图
// 顶部：实时屏幕画面（MJPEG）
// 底部：原有 ScreenAgentView（语音控制）

struct MacControlView: View {

    let backendBase: String
    let userKey:     String
    let onClose:     () -> Void

    @State private var showStream = true   // 默认显示屏幕画面

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if showStream {
                // ── 全屏屏幕画面模式 ──
                ZStack {
                    ScreenStreamView(
                        userKey:    userKey,
                        backendURL: backendBase
                    )

                    // 顶部工具栏
                    VStack {
                        HStack {
                            // 关闭
                            Button {
                                onClose()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.white.opacity(0.8))
                                    .shadow(radius: 4)
                            }

                            Spacer()

                            // 切换到 Agent 模式
                            Button {
                                showStream = false
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "mic.fill")
                                    Text("语音控制")
                                        .font(.caption.bold())
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.blue.opacity(0.8))
                                .clipShape(Capsule())
                                .shadow(radius: 4)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 56)  // 避开状态栏

                        Spacer()
                    }
                }
                .ignoresSafeArea()

            } else {
                // ── Agent 语音控制模式 ──
                ZStack(alignment: .topLeading) {
                    ScreenAgentView(
                        backendBase: backendBase,
                        userKey:     userKey,
                        onClose:     onClose
                    )

                    // 切换回画面按钮
                    Button {
                        showStream = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "display")
                            Text("看屏幕")
                                .font(.caption.bold())
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.6))
                        .clipShape(Capsule())
                    }
                    .padding(.top, 60)
                    .padding(.leading, 16)
                }
            }
        }
    }
}

