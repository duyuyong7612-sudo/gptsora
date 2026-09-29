// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-5354b191f3264899b2b3c25df20a37dc87bc9b91af32ab2901cd87d52c799320"
// Source-SHA256: "b4ff472865328ea54e3bf9e3a95b7f6a7194a50cea22f9d541f07122de0fc027"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI
import UIKit
import Combine
import Foundation

// =======================================================
// ✅ 独立模块：WeixinHomeChatView
// - 由 HomeChatView 点击“聊天键”（message.fill）进入
// - 这里仅做代码分离：不改功能、不丢逻辑
// - 原先写在 HomeChatView.swift 内的「微信式子模块（HomeChatView2 + Store/Socket/UI）」全部搬到此文件
// =======================================================

struct WeixinHomeChatView: View {
    let apiBase: String
    @ObservedObject var store: WeChatStore

    let onOpenGPT: () -> Void
    let onOpenHomeLegacy: () -> Void

    var body: some View {
        HomeChatView2(
            apiBase: apiBase,
            store: store,
            onOpenGPT: onOpenGPT,
            onOpenHomeLegacy: onOpenHomeLegacy
        )
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
            if let cid = UserDefaults.standard.string(forKey: "solara.client_id"), !cid.isEmpty {
                req.setValue(cid, forHTTPHeaderField: "X-Client-ID")
            }

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
            if let cid = UserDefaults.standard.string(forKey: "solara.client_id"), !cid.isEmpty {
                req.setValue(cid, forHTTPHeaderField: "X-Client-ID")
            }
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
            if let cid = UserDefaults.standard.string(forKey: "solara.client_id"), !cid.isEmpty {
                req.setValue(cid, forHTTPHeaderField: "X-Client-ID")
            }
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

// =======================================================
// ✅ 子模块 2（HomeChatView2）
// - 保持 HomeChatView 主页面不变：只在点击“进入聊天”按钮时进入该子模块
// - 先做「微信式骨架」：会话列表 + 底部 4 Tab（WeChat/通讯录/发现/我）
// - 后续升级：把真实数据、联系人、朋友圈、通话等逐步接进来
// =======================================================

struct HomeChatView2: View {
    let apiBase: String
    @ObservedObject var store: WeChatStore

    let onOpenGPT: () -> Void
    let onOpenHomeLegacy: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var tab: Int = 0

    var body: some View {
        TabView(selection: $tab) {
            WeChatChatsTabView(
                apiBase: apiBase,
                store: store,
                onOpenGPT: {
                    onOpenGPT()
                    dismiss()
                },
                onOpenHomeLegacy: onOpenHomeLegacy
            )
            .tabItem {
                Label("WeChat", systemImage: "message")
            }
            .tag(0)

            WeChatContactsTabSkeletonView()
                .tabItem {
                    Label("通讯录", systemImage: "person.2")
                }
                .tag(1)

            WeChatDiscoverTabSkeletonView()
                .tabItem {
                    Label("发现", systemImage: "safari")
                }
                .tag(2)

            WeChatMeTabSkeletonView(store: store)
                .tabItem {
                    Label("我", systemImage: "person.crop.circle")
                }
                .tag(3)
        }
    }
}

// MARK: - WeChat Tab 1：聊天（会话列表）

private struct WeChatChatsTabView: View {
    let apiBase: String
    @ObservedObject var store: WeChatStore

    let onOpenGPT: () -> Void
    let onOpenHomeLegacy: () -> Void

    @State private var query: String = ""
    @State private var showingNewChat: Bool = false

    var body: some View {
        NavigationStack {
            List {
                // ✅ 顶部固定：GPT 入口（把 GPT 也当成“联系人/会话”）
                Button {
                    onOpenGPT()
                } label: {
                    WeChatConversationRowView(
                        title: "ChatAGI-阿杜（GPT）",
                        subtitle: "AI 聊天 · 语音/代码高亮/稳定流式",
                        timeText: ""
                    )
                }
                .buttonStyle(.plain)

                // ✅ 文件传输助手（占位，后续可接文件/图片流转）
                WeChatConversationRowView(
                    title: "文件传输助手",
                    subtitle: "[图片]",
                    timeText: ""
                )

                // ✅ 会话列表（后端接好后这里会有数据；为空时显示骨架）
                if filteredConversations.isEmpty {
                    ForEach(0..<8, id: \.self) { _ in
                        WeChatSkeletonRowView()
                    }
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(filteredConversations) { conv in
                        NavigationLink(value: conv) {
                            WeChatConversationRowView(
                                title: conv.title,
                                subtitle: conv.last_text ?? "",
                                timeText: Self.fmtTime(conv.updated_at)
                            )
                        }
                    }
                }

                // ✅ 家居旧入口（可选）
                Button {
                    onOpenHomeLegacy()
                } label: {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.blue.opacity(0.12))
                            .frame(width: 44, height: 44)
                            .overlay(
                                Image(systemName: "house.fill")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(.blue)
                            )

                        VStack(alignment: .leading, spacing: 4) {
                            Text("原家居语音控制（Legacy）")
                                .font(.system(size: 17, weight: .semibold))
                            if let e = store.errorText, !e.isEmpty {
                                Text(e)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.red)
                                    .lineLimit(1)
                            } else {
                                Text("可选入口")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .navigationDestination(for: WeChatConversationSummary.self) { conv in
                HumanChatRoomView(apiBase: apiBase, store: store, conv: conv)
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Text("WeChat")
                            .font(.headline)
                        if !store.isConnected {
                            ProgressView().scaleEffect(0.8)
                        }
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
            .refreshable {
                await store.refreshConversations()
            }
            .onAppear {
                Task { await store.bootstrap(apiBase: apiBase) }
            }
        }
    }

    private var filteredConversations: [WeChatConversationSummary] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return store.conversations }
        return store.conversations.filter { c in
            c.title.localizedCaseInsensitiveContains(q)
            || (c.last_text ?? "").localizedCaseInsensitiveContains(q)
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

// MARK: - WeChat Tab 2/3/4：骨架占位

private struct WeChatContactsTabSkeletonView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("新的朋友", systemImage: "person.badge.plus")
                    Label("群聊", systemImage: "person.3")
                    Label("标签", systemImage: "tag")
                    Label("公众号", systemImage: "bubble.left.and.bubble.right")
                }

                Section(header: Text("联系人（占位）")) {
                    ForEach(0..<12, id: \.self) { _ in
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.gray.opacity(0.18))
                                .frame(width: 36, height: 36)
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.gray.opacity(0.18))
                                .frame(width: 120, height: 14)
                            Spacer()
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("通讯录")
        }
    }
}

private struct WeChatDiscoverTabSkeletonView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("朋友圈（占位）", systemImage: "photo.on.rectangle")
                }
                Section {
                    Label("扫一扫", systemImage: "qrcode.viewfinder")
                    Label("摇一摇（占位）", systemImage: "wave.3.right")
                }
                Section {
                    Label("看一看（占位）", systemImage: "eye")
                    Label("搜一搜（占位）", systemImage: "magnifyingglass")
                }
                Section {
                    Label("附近（占位）", systemImage: "location")
                    Label("购物（占位）", systemImage: "bag")
                    Label("游戏（占位）", systemImage: "gamecontroller")
                }
            }
            .listStyle(.plain)
            .navigationTitle("发现")
        }
    }
}

private struct WeChatMeTabSkeletonView: View {
    @ObservedObject var store: WeChatStore

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.gray.opacity(0.18))
                            .frame(width: 56, height: 56)
                            .overlay(
                                Text("我")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            )
                        VStack(alignment: .leading, spacing: 4) {
                            Text(store.me?.display_name ?? "未登录")
                                .font(.system(size: 18, weight: .semibold))
                            Text("ID: \(store.me?.user_id ?? "-")")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }

                Section {
                    Label("服务（占位）", systemImage: "creditcard")
                    Label("收藏（占位）", systemImage: "star")
                    Label("朋友圈（占位）", systemImage: "photo")
                    Label("卡包（占位）", systemImage: "wallet.pass")
                    Label("表情（占位）", systemImage: "face.smiling")
                }

                Section {
                    Label("设置（占位）", systemImage: "gear")
                }
            }
            .listStyle(.plain)
            .navigationTitle("我")
        }
    }
}

// MARK: - Skeleton Row

private struct WeChatSkeletonRowView: View {
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.gray.opacity(0.18))
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.gray.opacity(0.18))
                    .frame(width: 160, height: 14)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.gray.opacity(0.18))
                    .frame(width: 220, height: 12)
            }

            Spacer(minLength: 0)

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.gray.opacity(0.14))
                .frame(width: 44, height: 10)
        }
        .padding(.vertical, 6)
        .redacted(reason: .placeholder)
    }
}

struct WeChatHomeSheetView: View {
    let apiBase: String
    @ObservedObject var store: WeChatStore

    @Environment(\.dismiss) private var dismiss

    let onOpenGPT: () -> Void
    let onOpenHomeLegacy: () -> Void
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
                            title: "ChatAGI-阿杜（GPT）",
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
    @State private var peerId: String = ""

    @Environment(\.dismiss) private var dismiss

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
            // 微信式头像：圆角方块
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.gray.opacity(0.18))
                .frame(width: 44, height: 44)
                .overlay(
                    Text(String(title.prefix(1)))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.secondary)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
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
            if isMe { Spacer(minLength: 8) }

            Text(text)
                .font(.system(size: 16))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(isMe ? Color.blue.opacity(0.14) : Color.gray.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .frame(maxWidth: 280, alignment: isMe ? .trailing : .leading)

            if !isMe { Spacer(minLength: 8) }
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



























