// AduDelegateView.swift
// 手机 ←→ 电脑阿杜 连接桥
// 用户在手机说一句话 → 阿杜自主去做 → 完成推送回手机
//
// 接入方式：在 HomeChatView.swift 或 TabView 里加一个 Tab 即可

// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-acb29683a3f16a40ce124dbca79090b7e06f9f5aecd0626fa540e0860b87f6cf"
// Source-SHA256: "b2691f178bcb61a9d7cba89a461279b043eec3a394e23af97c462e4ecd20493d"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI
import Combine
import UserNotifications

// MARK: - 推送注册（在 AppDelegate 或 App struct 里调用一次）

class AduPushManager: NSObject, UNUserNotificationCenterDelegate, ObservableObject {

    static let shared = AduPushManager()
    @Published var deviceToken: String = ""

    func register() {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    // AppDelegate didRegisterForRemoteNotificationsWithDeviceToken 里调用
    func setDeviceToken(_ data: Data) {
        deviceToken = data.map { String(format: "%02x", $0) }.joined()
        // 上报给后端
        Task { await uploadToken() }
    }

    private func uploadToken() async {
        guard !deviceToken.isEmpty,
              let url = URL(string: "\(AduConfig.backendURL)/push/register") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["user_id": AduConfig.userId, "device_token": deviceToken, "platform": "ios"]
        req.httpBody = try? JSONEncoder().encode(body)
        _ = try? await URLSession.shared.data(for: req)
    }

    // 前台收到推送时显示
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 willPresent notification: UNNotification,
                                 withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([.banner, .sound, .badge])
    }
}

// MARK: - 配置（复用项目统一的 AppConfig）

enum AduConfig {
    static var backendURL: String { AppConfig.API.apiBase }
    static let userId = "adu_system"
}

// MARK: - 主界面

struct AduDelegateView: View {

    @StateObject private var vm = AduDelegateViewModel()
    @State private var inputText = ""
    @State private var showVoice = false
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color(hex: "080808").ignoresSafeArea()

            VStack(spacing: 0) {

                // ── 顶栏 ──
                header

                // ── 任务流 ──
                taskFeed

                // ── 输入栏 ──
                inputBar
            }
        }
        .onAppear { Task { await vm.loadTasks() } }
        .refreshable { await vm.loadTasks() }
    }

    // MARK: Header
    var header: some View {
        HStack(spacing: 12) {
            // 阿杜状态灯
            ZStack {
                Circle()
                    .fill(vm.aduOnline ? Color(hex: "00FF87").opacity(0.15) : Color.gray.opacity(0.1))
                    .frame(width: 44, height: 44)
                Circle()
                    .fill(vm.aduOnline ? Color(hex: "00FF87") : Color.gray)
                    .frame(width: 10, height: 10)
                    .scaleEffect(vm.pulse ? 1.3 : 1.0)
                    .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                               value: vm.pulse)
            }
            .onAppear { vm.pulse = true }

            VStack(alignment: .leading, spacing: 2) {
                Text("阿杜")
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                Text(vm.aduOnline ? "在线 · 随时待命" : "离线")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(vm.aduOnline ? Color(hex: "00FF87") : .gray)
            }

            Spacer()

            // 今日收益
            VStack(alignment: .trailing, spacing: 2) {
                Text("今日完成")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(hex: "555555"))
                Text("\(vm.completedToday) 个任务")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(hex: "00FF87"))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 56)
        .padding(.bottom, 16)
    }

    // MARK: Task Feed
    var taskFeed: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if vm.tasks.isEmpty {
                        emptyState
                            .padding(.top, 60)
                    } else {
                        ForEach(vm.tasks) { task in
                            TaskBubble(task: task)
                                .id(task.id)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: vm.tasks.count) { _ in
                if let last = vm.tasks.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    // MARK: Empty State
    var emptyState: some View {
        VStack(spacing: 16) {
            Text("⬡")
                .font(.system(size: 48))
                .foregroundColor(Color(hex: "1A1A1A"))

            Text("告诉阿杜你要他做什么")
                .font(.system(size: 15, design: .monospaced))
                .foregroundColor(Color(hex: "333333"))

            VStack(alignment: .leading, spacing: 8) {
                ForEach(AduDelegateViewModel.suggestions, id: \.self) { s in
                    Button(action: { inputText = s }) {
                        Text("→ \(s)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Color(hex: "444444"))
                    }
                }
            }
        }
    }

    // MARK: Input Bar
    var inputBar: some View {
        VStack(spacing: 0) {
            Divider().background(Color(hex: "1A1A1A"))

            HStack(spacing: 10) {
                // 文字输入
                ZStack(alignment: .leading) {
                    if inputText.isEmpty {
                        Text("委托给阿杜...")
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(Color(hex: "333333"))
                            .padding(.leading, 4)
                    }
                    TextField("", text: $inputText, axis: .vertical)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1...4)
                        .focused($focused)
                        .tint(Color(hex: "00FF87"))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(hex: "111111"))
                .cornerRadius(10)

                // 发送
                Button(action: {
                    guard !inputText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    let text = inputText
                    inputText = ""
                    focused = false
                    Task { await vm.submitTask(text: text) }
                }) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(inputText.isEmpty
                                  ? Color(hex: "111111")
                                  : Color(hex: "00FF87"))
                            .frame(width: 44, height: 44)
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(inputText.isEmpty ? Color(hex: "333333") : .black)
                    }
                }
                .disabled(inputText.isEmpty || vm.isSubmitting)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .padding(.bottom, 20)
        }
        .background(Color(hex: "080808"))
    }
}

// MARK: - 任务气泡

struct TaskBubble: View {

    let task: AduTaskItem
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // 主行
            HStack(spacing: 10) {
                // 状态图标
                statusIcon

                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(expanded ? nil : 1)

                    HStack(spacing: 6) {
                        Text(task.statusLabel)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(task.statusColor)

                        Text("·")
                            .foregroundColor(Color(hex: "333333"))

                        Text(task.timeAgo)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Color(hex: "444444"))
                    }
                }

                Spacer()

                Button(action: { withAnimation(.spring(response: 0.25)) { expanded.toggle() } }) {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "333333"))
                }
            }
            .padding(14)

            // 展开详情
            if expanded, let result = task.result {
                VStack(alignment: .leading, spacing: 6) {
                    Rectangle()
                        .fill(Color(hex: "1A1A1A"))
                        .frame(height: 1)
                        .padding(.horizontal, 14)

                    Text(result)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Color(hex: "AAAAAA"))
                        .lineLimit(nil)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(hex: "0E0E0E"))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(task.status == "running"
                                ? task.statusColor.opacity(0.5)
                                : Color(hex: "1A1A1A"),
                                lineWidth: 1)
                )
        )
    }

    var statusIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(task.statusColor.opacity(0.1))
                .frame(width: 34, height: 34)

            if task.status == "running" {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: task.statusColor))
                    .scaleEffect(0.7)
            } else {
                Image(systemName: task.statusIcon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(task.statusColor)
            }
        }
    }
}

// MARK: - ViewModel

@MainActor
class AduDelegateViewModel: ObservableObject {

    @Published var tasks: [AduTaskItem] = []
    @Published var aduOnline = false
    @Published var completedToday = 0
    @Published var isSubmitting = false
    @Published var pulse = false

    private var refreshTimer: AnyCancellable?

    static let suggestions = [
        "帮我监控茅台价格，低于1500就通知我",
        "搜索今天最重要的3条AI新闻",
        "帮我检查 GPTsora 项目有没有编译错误",
        "每小时检查一次我的邮件有没有重要内容",
    ]

    init() {
        // 每15秒自动刷新
        refreshTimer = Timer.publish(every: 15, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { await self?.loadTasks() }
            }
    }

    func loadTasks() async {
        guard let url = URL(string: "\(AduConfig.backendURL)/tasks?user_id=\(AduConfig.userId)&limit=30") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode([AduTaskItem].self, from: data)
            tasks = decoded.reversed()
            completedToday = decoded.filter { $0.status == "completed" }.count
            aduOnline = true
        } catch {
            aduOnline = false
        }
    }

    func submitTask(text: String) async {
        isSubmitting = true
        defer { isSubmitting = false }

        guard let url = URL(string: "\(AduConfig.backendURL)/tasks") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // 智能识别任务类型
        let type = detectType(text)
        let body: [String: Any] = [
            "user_id": AduConfig.userId,
            "title": text.count > 30 ? String(text.prefix(30)) + "..." : text,
            "description": text,
            "type": type,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if (response as? HTTPURLResponse)?.statusCode == 201 {
                // 乐观更新：立刻加一条pending
                let newTask = AduTaskItem(
                    id: UUID().uuidString,
                    title: text.count > 30 ? String(text.prefix(30)) + "..." : text,
                    description: text,
                    status: "pending",
                    type: type,
                    result: nil,
                    createdAt: ISO8601DateFormatter().string(from: Date()),
                    updatedAt: nil
                )
                tasks.insert(newTask, at: 0)

                // 1秒后刷新真实状态
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await loadTasks()
            }
        } catch {
            print("[AduDelegate] 提交失败: \(error)")
        }
    }

    private func detectType(_ text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("监控") || lower.contains("价格") || lower.contains("通知") { return "monitor" }
        if lower.contains("游戏") || lower.contains("代打") || lower.contains("代玩") { return "game" }
        if lower.contains("买") || lower.contains("抢") || lower.contains("购") { return "shopping" }
        if lower.contains("写") || lower.contains("文章") || lower.contains("内容") { return "content" }
        if lower.contains("搜") || lower.contains("查") || lower.contains("新闻") { return "search" }
        return "general"
    }
}

// MARK: - 数据模型

struct AduTaskItem: Identifiable, Codable {
    let id: String
    let title: String
    let description: String
    let status: String
    let type: String
    let result: String?
    let createdAt: String
    let updatedAt: String?

    var statusLabel: String {
        switch status {
        case "pending":   return "等待阿杜"
        case "running":   return "阿杜执行中..."
        case "completed": return "完成"
        case "failed":    return "失败"
        case "cancelled": return "已取消"
        default:          return status
        }
    }

    var statusColor: Color {
        switch status {
        case "pending":   return Color(hex: "F5A623")
        case "running":   return Color(hex: "00FF87")
        case "completed": return Color(hex: "4CD964")
        case "failed":    return Color(hex: "FF3B30")
        default:          return Color.gray
        }
    }

    var statusIcon: String {
        switch status {
        case "pending":   return "clock"
        case "completed": return "checkmark.circle.fill"
        case "failed":    return "xmark.circle.fill"
        case "cancelled": return "minus.circle"
        default:          return "bolt.fill"
        }
    }

    var timeAgo: String {
        let fmt = ISO8601DateFormatter()
        guard let date = fmt.date(from: createdAt) else { return "" }
        let diff = Int(Date().timeIntervalSince(date))
        if diff < 60 { return "刚刚" }
        if diff < 3600 { return "\(diff/60)分钟前" }
        if diff < 86400 { return "\(diff/3600)小时前" }
        return "\(diff/86400)天前"
    }

    enum CodingKeys: String, CodingKey {
        case id, title, description, status, type, result
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - 推送后端支持（加入 server_session.py）
/*
 在后端加这个端点，阿杜完成任务后会自动调用：

 @app.post("/push/register")
 async def push_register(body: dict):
     # 存储 device_token 到数据库
     save_token(body["user_id"], body["device_token"])
     return {"status": "ok"}

 @app.post("/push/send")
 async def push_send(body: dict):
     token = get_token(body["user_id"])
     if token:
         await send_apns(token, body["notification"]["title"],
                         body["notification"]["body"])
     return {"status": "ok"}
*/

// MARK: - Color Extension（如项目已有请删除）
// extension Color { init(hex: String) { ... } }

// MARK: - Preview
struct AduDelegateView_Previews: PreviewProvider {
    static var previews: some View {
        AduDelegateView()
            .preferredColorScheme(.dark)
    }
}

