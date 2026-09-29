// AduWorkReportView.swift
// 阿杜工作报告界面 — 用户看阿杜在干什么、干了什么
// 设计风格：深色、工业感、像监控大屏，阿杜是在帮你盯着世界

// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-f5c2f013f5df67cf80c858fe3d0248e43141fd2bbb6c179d3ea0b482df2283ee"
// Source-SHA256: "0b6696d560412434e7d0d8ca042e09c46e432444ad26aedb7421dcbcd3b62af9"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI
import Combine

// MARK: - 数据模型

struct AduTask: Identifiable, Codable {
    let id: String
    var title: String
    var description: String
    var status: TaskStatus
    var createdAt: Date
    var updatedAt: Date?
    var result: String?
    var estimatedEarnings: Double?
    var type: String

    // ✅ v2 扩展字段：任务闭环
    var goal: String?           // 明确目标
    var scope: String?          // 操作范围
    var constraints: String?    // 约束限制
    var deliverables: String?   // 可交付物
    var doneDefinition: String? // 完成标准
    var progress: Int?          // 0-100
    var currentStep: String?    // 当前步骤
    var lastResult: String?     // 上次执行结果
    var nextAction: String?     // 下一步建议
    var errorCount: Int?        // 错误次数
    var maxRetries: Int?        // 最大重试次数

    enum CodingKeys: String, CodingKey {
        case id, title, description, status, result, type
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case estimatedEarnings = "estimated_earnings"
        case goal, scope, constraints, deliverables, progress
        case doneDefinition = "done_definition"
        case currentStep = "current_step"
        case lastResult = "last_result"
        case nextAction = "next_action"
        case errorCount = "error_count"
        case maxRetries = "max_retries"
    }

    enum TaskStatus: String, Codable {
        case pending   = "pending"
        case running   = "running"
        case completed = "completed"
        case failed    = "failed"

        var label: String {
            switch self {
            case .pending:   return "等待"
            case .running:   return "执行中"
            case .completed: return "完成"
            case .failed:    return "失败"
            }
        }

        var color: Color {
            switch self {
            case .pending:   return Color(hex: "8B8B8B")
            case .running:   return Color(hex: "F5A623")
            case .completed: return Color(hex: "4CD964")
            case .failed:    return Color(hex: "FF3B30")
            }
        }

        var icon: String {
            switch self {
            case .pending:   return "clock"
            case .running:   return "bolt.fill"
            case .completed: return "checkmark.circle.fill"
            case .failed:    return "xmark.circle.fill"
            }
        }
    }
}

struct AduDailySummary: Codable {
    var completed: Int
    var failed: Int
    var earnings: Double
    var date: Date
    var reflection: String?
}

// MARK: - ViewModel

@MainActor
class AduWorkReportViewModel: ObservableObject {

    @Published var tasks: [AduTask] = []
    @Published var todaySummary: AduDailySummary?
    @Published var aduStatus: AduStatus = .standby
    @Published var currentThought: String = "待命中，等待任务..."
    @Published var totalEarnings: Double = 0
    @Published var isLoading = false

    private var refreshTimer: AnyCancellable?
    private let backendURL = ProcessInfo.processInfo.environment["BACKEND_URL"]
                          ?? "https://your-service.example.com"

    enum AduStatus {
        case standby, working, sleeping
        var label: String {
            switch self {
            case .standby: return "待命"
            case .working: return "工作中"
            case .sleeping: return "休息"
            }
        }
        var color: Color {
            switch self {
            case .standby:  return Color(hex: "F5A623")
            case .working:  return Color(hex: "4CD964")
            case .sleeping: return Color(hex: "8B8B8B")
            }
        }
    }

    init() {
        startAutoRefresh()
        Task { await loadAll() }
    }

    func loadAll() async {
        isLoading = true
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadTasks() }
            group.addTask { await self.loadSummary() }
        }
        isLoading = false
    }

    func loadTasks() async {
        guard let url = URL(string: "\(backendURL)/tasks/pending?user_id=adu_system") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode([AduTask].self, from: data)
            tasks = decoded
            aduStatus = decoded.contains(where: { $0.status == .running }) ? .working : .standby
            currentThought = aduStatus == .working
                ? "正在执行：\(decoded.first(where: { $0.status == .running })?.title ?? "任务")"
                : "待命中，等待新任务..."
        } catch {
            // 使用示例数据
            tasks = AduTask.mockData()
        }
    }

    func loadSummary() async {
        // TODO: 接入真实API
        todaySummary = AduDailySummary(
            completed: 3,
            failed: 0,
            earnings: 24.50,
            date: Date(),
            reflection: "今天完成了3个任务，没有失误。老婆让我买的东西抢到了，女儿的作业辅导也安排好了。"
        )
        totalEarnings = todaySummary?.earnings ?? 0
    }

    func submitTask(title: String, description: String, type: String) async {
        guard let url = URL(string: "\(backendURL)/tasks") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["title": title, "description": description,
                    "type": type, "user_id": "adu_system"]
        req.httpBody = try? JSONEncoder().encode(body)
        _ = try? await URLSession.shared.data(for: req)
        await loadTasks()
    }

    private func startAutoRefresh() {
        refreshTimer = Timer.publish(every: 10, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { await self?.loadTasks() }
            }
    }
}

// MARK: - 主界面

struct AduWorkReportView: View {

    @StateObject private var vm = AduWorkReportViewModel()
    @State private var showNewTask = false
    @State private var pulse = false

    var body: some View {
        ZStack {
            // 背景
            Color(hex: "0A0A0A").ignoresSafeArea()

            // 网格背景纹理
            GridBackgroundView()
                .opacity(0.06)
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {

                    // ── 顶部：阿杜状态 ──
                    AduStatusHeader(vm: vm, pulse: $pulse)
                        .padding(.top, 60)
                        .padding(.horizontal, 20)

                    // ── 今日数据 ──
                    if let summary = vm.todaySummary {
                        TodayStatsBar(summary: summary)
                            .padding(.top, 24)
                            .padding(.horizontal, 20)
                    }

                    // ── 任务列表 ──
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("委托任务")
                                .font(.custom("Courier New", size: 11))
                                .foregroundColor(Color(hex: "666666"))
                                .tracking(3)

                            Spacer()

                            Text("\(vm.tasks.count) 个")
                                .font(.custom("Courier New", size: 11))
                                .foregroundColor(Color(hex: "444444"))
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 32)

                        if vm.tasks.isEmpty {
                            EmptyTasksView()
                                .padding(.horizontal, 20)
                        } else {
                            ForEach(vm.tasks) { task in
                                TaskCard(task: task)
                                    .padding(.horizontal, 20)
                            }
                        }
                    }

                    // ── 今日复盘 ──
                    if let reflection = vm.todaySummary?.reflection {
                        ReflectionCard(text: reflection)
                            .padding(.horizontal, 20)
                            .padding(.top, 24)
                    }

                    Spacer(minLength: 120)
                }
            }

            // ── 底部：新建任务按钮 ──
            VStack {
                Spacer()
                NewTaskButton(action: { showNewTask = true })
                    .padding(.horizontal, 20)
                    .padding(.bottom, 34)
            }
        }
        .sheet(isPresented: $showNewTask) {
            NewTaskSheet(vm: vm, isPresented: $showNewTask)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

// MARK: - 子组件

struct AduStatusHeader: View {
    @ObservedObject var vm: AduWorkReportViewModel
    @Binding var pulse: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("阿杜")
                        .font(.custom("Courier New", size: 36))
                        .fontWeight(.bold)
                        .foregroundColor(.white)

                    HStack(spacing: 8) {
                        Circle()
                            .fill(vm.aduStatus.color)
                            .frame(width: 8, height: 8)
                            .scaleEffect(pulse && vm.aduStatus == .working ? 1.4 : 1.0)

                        Text(vm.aduStatus.label)
                            .font(.custom("Courier New", size: 13))
                            .foregroundColor(vm.aduStatus.color)
                            .tracking(2)
                    }
                }

                Spacer()

                // 收益显示
                VStack(alignment: .trailing, spacing: 4) {
                    Text("今日收益")
                        .font(.custom("Courier New", size: 10))
                        .foregroundColor(Color(hex: "555555"))
                        .tracking(2)

                    Text("$\(vm.totalEarnings, specifier: "%.2f")")
                        .font(.custom("Courier New", size: 28))
                        .fontWeight(.bold)
                        .foregroundColor(Color(hex: "4CD964"))
                }
            }

            // 当前想法
            Text(vm.currentThought)
                .font(.custom("Courier New", size: 13))
                .foregroundColor(Color(hex: "888888"))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(hex: "141414"))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(hex: "222222"), lineWidth: 1)
                )
        }
    }
}

struct TodayStatsBar: View {
    let summary: AduDailySummary

    var body: some View {
        HStack(spacing: 1) {
            StatCell(value: "\(summary.completed)", label: "完成", color: "4CD964")
            StatCell(value: "\(summary.failed)", label: "失败", color: "FF3B30")
            StatCell(value: "\(summary.completed + summary.failed)", label: "总计", color: "F5A623")
        }
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(hex: "1E1E1E"), lineWidth: 1)
        )
    }
}

struct StatCell: View {
    let value: String
    let label: String
    let color: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.custom("Courier New", size: 24))
                .fontWeight(.bold)
                .foregroundColor(Color(hex: color))

            Text(label)
                .font(.custom("Courier New", size: 10))
                .foregroundColor(Color(hex: "555555"))
                .tracking(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color(hex: "111111"))
    }
}

struct TaskCard: View {
    let task: AduTask
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { withAnimation(.spring(response: 0.3)) { expanded.toggle() } }) {
                HStack(spacing: 12) {
                    // 状态指示器
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(task.status.color.opacity(0.12))
                            .frame(width: 36, height: 36)

                        Image(systemName: task.status.icon)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(task.status.color)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.title)
                            .font(.custom("Courier New", size: 14))
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .lineLimit(1)

                        Text(task.status.label)
                            .font(.custom("Courier New", size: 11))
                            .foregroundColor(task.status.color)
                            .tracking(1)
                    }

                    Spacer()

                    if let earnings = task.estimatedEarnings, earnings > 0 {
                        Text("$\(earnings, specifier: "%.2f")")
                            .font(.custom("Courier New", size: 13))
                            .foregroundColor(Color(hex: "4CD964"))
                    }

                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "444444"))
                }
                .padding(14)
            }
            .buttonStyle(PlainButtonStyle())

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    Divider().background(Color(hex: "1E1E1E"))

                    Text(task.description)
                        .font(.custom("Courier New", size: 12))
                        .foregroundColor(Color(hex: "888888"))
                        .lineLimit(nil)

                    if let result = task.result {
                        Text("结果：\(result)")
                            .font(.custom("Courier New", size: 12))
                            .foregroundColor(Color(hex: "AAAAAA"))
                            .lineLimit(nil)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color(hex: "111111"))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(task.status == .running
                        ? task.status.color.opacity(0.4)
                        : Color(hex: "1E1E1E"),
                        lineWidth: 1)
        )
    }
}

struct ReflectionCard: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("阿杜今日复盘")
                .font(.custom("Courier New", size: 10))
                .foregroundColor(Color(hex: "555555"))
                .tracking(3)

            Text(text)
                .font(.custom("Courier New", size: 13))
                .foregroundColor(Color(hex: "AAAAAA"))
                .lineLimit(nil)
                .lineSpacing(4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "0D0D0D"))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(hex: "1A1A1A"), lineWidth: 1)
        )
    }
}

struct EmptyTasksView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundColor(Color(hex: "2A2A2A"))

            Text("还没有委托任务")
                .font(.custom("Courier New", size: 13))
                .foregroundColor(Color(hex: "444444"))

            Text("告诉阿杜你要他做什么")
                .font(.custom("Courier New", size: 11))
                .foregroundColor(Color(hex: "333333"))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

struct NewTaskButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .bold))
                Text("委托新任务给阿杜")
                    .font(.custom("Courier New", size: 14))
                    .fontWeight(.semibold)
                    .tracking(1)
            }
            .foregroundColor(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color.white)
            .cornerRadius(12)
        }
    }
}

struct NewTaskSheet: View {
    @ObservedObject var vm: AduWorkReportViewModel
    @Binding var isPresented: Bool
    @State private var title = ""
    @State private var description = ""
    @State private var selectedType = "general"
    @State private var isSubmitting = false

    let taskTypes = [
        ("general",  "通用任务"),
        ("monitor",  "监控任务"),
        ("content",  "内容创作"),
        ("data",     "数据处理"),
        ("game",     "游戏代玩"),
        ("shopping", "代购抢购"),
    ]

    var body: some View {
        ZStack {
            Color(hex: "0A0A0A").ignoresSafeArea()

            VStack(alignment: .leading, spacing: 24) {
                // 标题
                HStack {
                    Text("委托任务给阿杜")
                        .font(.custom("Courier New", size: 20))
                        .fontWeight(.bold)
                        .foregroundColor(.white)

                    Spacer()

                    Button(action: { isPresented = false }) {
                        Image(systemName: "xmark")
                            .foregroundColor(Color(hex: "666666"))
                    }
                }
                .padding(.top, 32)

                // 任务类型
                VStack(alignment: .leading, spacing: 8) {
                    Text("类型")
                        .font(.custom("Courier New", size: 10))
                        .foregroundColor(Color(hex: "666666"))
                        .tracking(2)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(taskTypes, id: \.0) { type in
                                Button(action: { selectedType = type.0 }) {
                                    Text(type.1)
                                        .font(.custom("Courier New", size: 12))
                                        .foregroundColor(selectedType == type.0 ? .black : Color(hex: "888888"))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(selectedType == type.0 ? Color.white : Color(hex: "161616"))
                                        .cornerRadius(6)
                                }
                            }
                        }
                    }
                }

                // 任务标题
                VStack(alignment: .leading, spacing: 8) {
                    Text("任务名称")
                        .font(.custom("Courier New", size: 10))
                        .foregroundColor(Color(hex: "666666"))
                        .tracking(2)

                    TextField("", text: $title)
                        .font(.custom("Courier New", size: 14))
                        .foregroundColor(.white)
                        .placeholder(when: title.isEmpty) {
                            Text("例：帮我在Fiverr上接文章写作订单")
                                .font(.custom("Courier New", size: 14))
                                .foregroundColor(Color(hex: "333333"))
                        }
                        .padding(12)
                        .background(Color(hex: "111111"))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(hex: "222222"), lineWidth: 1)
                        )
                }

                // 详细描述
                VStack(alignment: .leading, spacing: 8) {
                    Text("详细说明")
                        .font(.custom("Courier New", size: 10))
                        .foregroundColor(Color(hex: "666666"))
                        .tracking(2)

                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $description)
                            .font(.custom("Courier New", size: 13))
                            .foregroundColor(.white)
                            .frame(height: 100)
                            .padding(8)
                            .background(Color(hex: "111111"))
                            .cornerRadius(8)
                            .scrollContentBackground(.hidden)

                        if description.isEmpty {
                            Text("告诉阿杜：目标是什么，要怎么做，完成的标准是什么...")
                                .font(.custom("Courier New", size: 13))
                                .foregroundColor(Color(hex: "333333"))
                                .padding(16)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(hex: "222222"), lineWidth: 1)
                    )
                }

                Spacer()

                // 提交按钮
                Button(action: {
                    guard !title.isEmpty else { return }
                    isSubmitting = true
                    Task {
                        await vm.submitTask(title: title,
                                           description: description,
                                           type: selectedType)
                        isPresented = false
                    }
                }) {
                    HStack {
                        if isSubmitting {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .black))
                                .scaleEffect(0.8)
                        }
                        Text(isSubmitting ? "提交中..." : "交给阿杜")
                            .font(.custom("Courier New", size: 15))
                            .fontWeight(.bold)
                    }
                    .foregroundColor(title.isEmpty ? Color(hex: "555555") : .black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(title.isEmpty ? Color(hex: "1A1A1A") : Color.white)
                    .cornerRadius(12)
                }
                .disabled(title.isEmpty || isSubmitting)
                .padding(.bottom, 34)
            }
            .padding(.horizontal, 24)
        }
    }
}

// MARK: - 辅助组件

struct GridBackgroundView: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 30
            var x: CGFloat = 0
            while x < size.width {
                context.stroke(
                    Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)) },
                    with: .color(.white), lineWidth: 0.5
                )
                x += spacing
            }
            var y: CGFloat = 0
            while y < size.height {
                context.stroke(
                    Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)) },
                    with: .color(.white), lineWidth: 0.5
                )
                y += spacing
            }
        }
    }
}

extension View {
    func placeholder<Content: View>(when shouldShow: Bool, @ViewBuilder placeholder: () -> Content) -> some View {
        ZStack(alignment: .leading) {
            if shouldShow { placeholder() }
            self
        }
    }
}

// Color(hex:) 扩展已在项目其他文件中定义，此处不重复声明

// MARK: - Mock数据（开发测试用）

extension AduTask {
    static func mockData() -> [AduTask] {
        [
            AduTask(id: "1", title: "监控iPhone 16 Pro降价", description: "在Apple官网和京东监控价格，低于8000就立刻买",
                    status: .running, createdAt: Date(), updatedAt: Date(), result: nil,
                    estimatedEarnings: nil, type: "monitor"),
            AduTask(id: "2", title: "Fiverr文章写作订单", description: "接受并完成一篇500字英文科技文章",
                    status: .completed, createdAt: Date(), updatedAt: Date(),
                    result: "已完成，客户满意，获得5星好评", estimatedEarnings: 15.0, type: "content"),
            AduTask(id: "3", title: "王者荣耀代打钻石", description: "账号信息已提供，目标从黄金到钻石",
                    status: .pending, createdAt: Date(), updatedAt: nil, result: nil,
                    estimatedEarnings: 30.0, type: "game"),
        ]
    }
}

// MARK: - Preview

struct AduWorkReportView_Previews: PreviewProvider {
    static var previews: some View {
        AduWorkReportView()
            .preferredColorScheme(.dark)
    }
}

