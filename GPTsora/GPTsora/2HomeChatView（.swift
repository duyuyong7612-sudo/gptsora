// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-889386f8c7e9ce9046468bb14943b08b5a206b86afe7dd6bca0d3393999f2618"
// Source-SHA256: "55f661a79dbe14cf27c4e69398c7022a15463ba161e78e6f3198eb645695afe9"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI
import AVFoundation

/// 微信式聊天页骨架（子模块）
/// - 只负责：顶部栏 + 聊天区域 + 底部输入栏（微信皮肤）
/// - 以后“逐步微信化”只在这个文件上升级
struct TwoHomeChatView: View {

    var onClose: (() -> Void)? = nil

    // MARK: - Demo data (先用本地互发模拟，后面接你的 WS/后端)
    enum Role { case me, other }

    struct Msg: Identifiable, Equatable {
        let id = UUID()
        let role: Role
        var text: String
        var ts: Date = Date()
    }

    @State private var messages: [Msg] = [
        .init(role: .other, text: "你好～这里是微信式聊天页骨架。"),
        .init(role: .me, text: "收到。先把顶栏/底栏做成微信。")
    ]

    @State private var inputText: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().opacity(0.12)

            chatArea
                .background(Color(white: 0.95))
        }
        .safeAreaInset(edge: .bottom) {
            inputBar
        }
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: - Top Bar
    private var topBar: some View {
        ZStack {
            HStack(spacing: 10) {
                Button {
                    focused = false
                    onClose?()
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                        Text("微信")
                            .font(.system(size: 17))
                    }
                    .foregroundColor(.black)
                }

                Spacer()

                Button {} label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(width: 36, height: 36)
                }
            }
            .padding(.horizontal, 12)

            Text("聊天")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.black)
        }
        .frame(height: 44)
        .background(Color(white: 0.93).ignoresSafeArea(edges: .top))
    }

    // MARK: - Chat Area
    private var chatArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(messages) { msg in
                        bubbleRow(msg)
                            .id(msg.id)
                    }
                    Color.clear.frame(height: 8).id("BOTTOM")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .onChange(of: messages.count) { _ in
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("BOTTOM", anchor: .bottom)
                }
            }
        }
    }

    private func bubbleRow(_ msg: Msg) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            if msg.role == .other {
                avatarCircle(text: "对")
                bubble(text: msg.text, role: .other)
                Spacer(minLength: 40)
            } else {
                Spacer(minLength: 40)
                bubble(text: msg.text, role: .me)
                avatarCircle(text: "我")
            }
        }
    }

    private func bubble(text: String, role: Role) -> some View {
        Text(text)
            .font(.system(size: 16))
            .foregroundColor(.black)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(role == .me ? Color(red: 0.74, green: 0.93, blue: 0.63) : Color.white) // 近似微信绿/白
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.black.opacity(0.05), lineWidth: 1)
            )
    }

    private func avatarCircle(text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 28, height: 28)
            .background(Color.black.opacity(0.75))
            .clipShape(Circle())
    }

    // MARK: - Input Bar
    private var inputBar: some View {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let canSend = !trimmed.isEmpty

        return VStack(spacing: 0) {
            Divider().opacity(0.15)

            HStack(spacing: 10) {
                Button {
                    // 预留：语音/键盘切换（后面接你录音→语音气泡）
                    focused = false
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.black.opacity(0.85))
                        .frame(width: 28, height: 28)
                }

                TextField("发消息", text: $inputText, axis: .vertical)
                    .focused($focused)
                    .lineLimit(1...4)
                    .font(.system(size: 16))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Button {} label: {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 18))
                        .foregroundColor(.black.opacity(0.85))
                        .frame(width: 28, height: 28)
                }

                if canSend {
                    Button {
                        sendMyText(trimmed)
                    } label: {
                        Text("发送")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 56, height: 32)
                            .background(Color(red: 0.12, green: 0.75, blue: 0.28))
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                } else {
                    Button {} label: {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.black.opacity(0.85))
                            .frame(width: 28, height: 28)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(white: 0.93))
        }
    }

    private func sendMyText(_ text: String) {
        inputText = ""
        messages.append(.init(role: .me, text: text))

        // ✅ 本地互发模拟：你后面接后端 WS 时删掉这段
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            messages.append(.init(role: .other, text: "对方收到：\(text)"))
        }
    }
}

