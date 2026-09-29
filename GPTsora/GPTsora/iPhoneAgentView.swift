// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-ba004e41198bd220fc9f92491e45b65cd0a26f53b735f1c810fe3939c6697664"
// Source-SHA256: "e92b0fa7631c255a9a2c2b93d1b1704deefbf047e7887e91269e96139c6d2db3"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI
import EventKit

// MARK: - iPhone Agent View (本地控制手机)
// 纯 iOS SDK，不走网络，直接操控手机

struct iPhoneAgentView: View {
    @StateObject private var agent = iPhoneAgentService.shared
    @State private var selectedSection: AgentSection = .device
    @State private var resultText = ""
    @State private var showResult = false

    enum AgentSection: String, CaseIterable {
        case device = "📱 设备"
        case contacts = "👤 通讯录"
        case calendar = "📅 日历"
        case reminders = "✅ 提醒"
        case apps = "📲 App"
        case tools = "🔧 工具"
        case mac = "💻 电脑"
        case dev = "🧪 开发"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab bar
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(AgentSection.allCases, id: \.self) { section in
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) { selectedSection = section }
                            } label: {
                                Text(section.rawValue)
                                    .font(.system(size: 13, weight: .semibold))
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(selectedSection == section ? Color.accentColor : Color(.systemGray5))
                                    .foregroundStyle(selectedSection == section ? .white : .primary)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                }
                .background(.bar)

                Divider()

                // Content
                ScrollView {
                    VStack(spacing: 16) {
                        switch selectedSection {
                        case .device: deviceSection
                        case .contacts: contactsSection
                        case .calendar: calendarSection
                        case .reminders: remindersSection
                        case .apps: appsSection
                        case .tools: toolsSection
                        case .mac:
                            VStack(spacing: 0) {
                                // 电脑控制面板（新版：统一工具协议）
                                ComputerControlPanel(apiBase: AppConfig.API.apiBase)
                                    .frame(height: 380)
                                Divider()
                                // 原有 MacAgentSection（项目树/命令/编译）
                                MacAgentSection(apiBase: AppConfig.API.apiBase)
                            }
                        case .dev:
                            VStack(spacing: 14) {
                                AduCodexRunDebugPanel(apiBase: AppConfig.API.apiBase)

                                Divider()

                                DevAgentReadOnlyPanel(apiBase: AppConfig.API.apiBase)
                                    .frame(minHeight: 600)
                            }
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("🐾 手机助手")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showResult) {
                ResultSheet(text: resultText)
            }
        }
    }

    // MARK: - 📱 Device Info

    private var deviceSection: some View {
        VStack(spacing: 16) {
            let info = agent.deviceInfo()

            sectionHeader("设备信息")

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                infoCard("📱", "型号", info["model"] ?? "")
                infoCard("📟", "名称", info["name"] ?? "")
                infoCard("⚙️", "系统", info["system"] ?? "")
                infoCard("🔋", "电量", info["battery"] ?? "")
                infoCard("💾", "总空间", info["storage_total"] ?? "")
                infoCard("📂", "可用", info["storage_free"] ?? "")
                infoCard("🧠", "内存", info["memory_total"] ?? "")
                infoCard("📐", "屏幕", info["screen"] ?? "")
            }

            sectionHeader("屏幕亮度")
            HStack(spacing: 12) {
                Image(systemName: "sun.min").foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { Double(UIScreen.main.brightness) },
                    set: { newValue in UIScreen.main.brightness = CGFloat(newValue) }
                ), in: 0...1)
                Image(systemName: "sun.max.fill").foregroundStyle(.yellow)
            }

            sectionHeader("相册统计")
            Button("查看相册统计") {
                Task {
                    do {
                        let stats = try await agent.photoLibraryStats()
                        resultText = "📸 照片: \(stats.photoCount) 张\n🎬 视频: \(stats.videoCount) 个"
                        showResult = true
                    } catch { showError(error) }
                }
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
        }
    }

    // MARK: - 👤 Contacts
    @State private var contactSearch = ""
    @State private var contacts: [ContactInfo] = []

    private var contactsSection: some View {
        VStack(spacing: 12) {
            sectionHeader("搜索通讯录")
            HStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("姓名关键词…", text: $contactSearch).autocorrectionDisabled()
                    if !contactSearch.isEmpty {
                        Button { contactSearch = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(10).background(Color(.systemGray6)).clipShape(RoundedRectangle(cornerRadius: 10))
                Button("搜索") {
                    Task {
                        do { contacts = try await agent.searchContacts(keyword: contactSearch) }
                        catch { showError(error) }
                    }
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
            }
            if contacts.isEmpty {
                emptyHint("输入关键词搜索联系人")
            } else {
                ForEach(contacts) { c in
                    HStack(spacing: 12) {
                        Circle()
                            .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 44, height: 44)
                            .overlay(Text(String(c.name.prefix(1))).font(.headline).foregroundStyle(.white))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(c.name).font(.body.weight(.medium))
                            if !c.organization.isEmpty { Text(c.organization).font(.caption).foregroundStyle(.secondary) }
                            if let phone = c.phones.first { Text(phone).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        HStack(spacing: 6) {
                            if let phone = c.phones.first {
                                circleBtn("phone.fill", .green) { _ = agent.openApp("tel:\(phone)") }
                                circleBtn("message.fill", .blue) { _ = agent.openApp("sms:\(phone)") }
                            }
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemBackground)))
                }
                Text("\(contacts.count) 个联系人").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - 📅 Calendar
    @State private var events: [EventInfo] = []
    @State private var newEventTitle = ""

    private var calendarSection: some View {
        VStack(spacing: 12) {
            sectionHeader("未来 7 天日程")
            Button { Task { do { events = try await agent.upcomingEvents() } catch { showError(error) } } }
            label: { Label("加载日历", systemImage: "calendar") }
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
            if events.isEmpty {
                emptyHint("点击加载查看日程")
            } else {
                ForEach(events) { ev in
                    HStack(spacing: 12) {
                        VStack(spacing: 2) {
                            Text(ev.dateString).font(.caption.monospacedDigit().bold()).foregroundColor(.accentColor)
                        }.frame(width: 56)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(ev.title).font(.body.weight(.medium))
                            if let loc = ev.location, !loc.isEmpty { Label(loc, systemImage: "mappin").font(.caption).foregroundStyle(.secondary) }
                            Text(ev.calendar).font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if ev.isAllDay { Text("全天").font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 6).padding(.vertical, 2).background(Color(.systemGray5)).clipShape(Capsule()) }
                    }
                    .padding(12).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.secondarySystemBackground)))
                }
            }
            Divider().padding(.vertical, 6)
            sectionHeader("快速创建事件")
            HStack(spacing: 8) {
                TextField("事件标题…", text: $newEventTitle).textFieldStyle(.roundedBorder)
                Button("创建") {
                    guard !newEventTitle.isEmpty else { return }
                    Task {
                        let start = Date().addingTimeInterval(3600)
                        do {
                            let msg = try await agent.createEvent(title: newEventTitle, startDate: start, endDate: start.addingTimeInterval(3600))
                            resultText = msg; showResult = true; newEventTitle = ""
                            events = (try? await agent.upcomingEvents()) ?? events
                        } catch { showError(error) }
                    }
                }
                .buttonStyle(.borderedProminent).disabled(newEventTitle.isEmpty)
            }
        }
    }

    // MARK: - ✅ Reminders
    @State private var reminderList: [ReminderInfo] = []
    @State private var newReminderTitle = ""

    private var remindersSection: some View {
        VStack(spacing: 12) {
            sectionHeader("待完成提醒")
            Button { Task { do { reminderList = try await agent.reminders() } catch { showError(error) } } }
            label: { Label("加载提醒", systemImage: "checklist") }
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
            if reminderList.isEmpty {
                emptyHint("点击加载查看提醒")
            } else {
                ForEach(reminderList) { r in
                    HStack(spacing: 10) {
                        Image(systemName: r.isCompleted ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(r.isCompleted ? .green : Color(.systemGray3))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.title).font(.body).strikethrough(r.isCompleted, color: .secondary)
                            if let due = r.dueDate { Text(due, style: .date).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Text(r.list).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(Color(.systemGray5)).clipShape(Capsule())
                    }
                    .padding(10).background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.secondarySystemBackground)))
                }
            }
            Divider().padding(.vertical, 6)
            sectionHeader("快速创建提醒")
            HStack(spacing: 8) {
                TextField("提醒内容…", text: $newReminderTitle).textFieldStyle(.roundedBorder)
                Button("创建") {
                    guard !newReminderTitle.isEmpty else { return }
                    Task {
                        do {
                            let msg = try await agent.createReminder(title: newReminderTitle)
                            resultText = msg; showResult = true; newReminderTitle = ""
                            reminderList = (try? await agent.reminders()) ?? reminderList
                        } catch { showError(error) }
                    }
                }
                .buttonStyle(.borderedProminent).disabled(newReminderTitle.isEmpty)
            }
        }
    }

    // MARK: - 📲 Apps
    private var appsSection: some View {
        VStack(spacing: 12) {
            sectionHeader("快捷打开 App")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 16) {
                ForEach(0..<iPhoneAgentService.appSchemes.count, id: \.self) { i in
                    let app = iPhoneAgentService.appSchemes[i]
                    Button {
                        let ok = agent.openApp(app.scheme)
                        if !ok { resultText = "⚠️ 无法打开「\(app.name)」\n可能未安装该 App"; showResult = true }
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: app.icon).font(.title2).frame(width: 52, height: 52)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.accentColor.opacity(0.1)))
                            Text(app.name).font(.caption).foregroundStyle(.primary).lineLimit(1)
                        }
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 🔧 Tools
    private var toolsSection: some View {
        VStack(spacing: 12) {
            sectionHeader("实用工具")
            actionCard(icon: "flashlight.on.fill", iconColor: agent.isFlashlightOn ? .yellow : .secondary, title: "🔦 手电筒", subtitle: agent.isFlashlightOn ? "已开启 · 点击关闭" : "已关闭 · 点击开启") {
                let ok = agent.toggleFlashlight()
                if !ok { resultText = "⚠️ 手电筒不可用"; showResult = true }
            }
            actionCard(icon: "doc.on.clipboard", iconColor: .orange, title: "📋 读取剪贴板", subtitle: "查看当前剪贴板内容") {
                resultText = "📋 剪贴板内容:\n\n\(agent.clipboardRead())"; showResult = true
            }
            actionCard(icon: "doc.on.clipboard.fill", iconColor: .purple, title: "📝 写入剪贴板", subtitle: "将文本复制到剪贴板") {
                agent.clipboardWrite("ChatAGI-阿杜 🐾"); resultText = "✅ 已写入剪贴板"; showResult = true
            }
            actionCard(icon: "location.fill", iconColor: .blue, title: "📍 当前位置", subtitle: agent.currentLocationString()) {
                agent.requestLocation()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    resultText = "📍 位置:\n\n\(agent.currentLocationString())"; showResult = true
                }
            }
            actionCard(icon: "bell.badge.fill", iconColor: .red, title: "🔔 测试通知", subtitle: "5秒后发送本地通知") {
                Task {
                    do {
                        let msg = try await agent.scheduleNotification(title: "Adu-Agent 🐾", body: "这是一条测试通知，手机助手运行正常！", seconds: 5)
                        resultText = msg; showResult = true
                    } catch { showError(error) }
                }
            }
            actionCard(icon: "waveform", iconColor: .green, title: "📳 震动反馈", subtitle: "触觉引擎测试") { agent.haptic(.heavy) }
            actionCard(icon: "folder.fill", iconColor: .teal, title: "📁 本地文件", subtitle: "查看 App 文档目录") {
                let files = agent.listDocuments()
                resultText = "📁 文档目录 (\(files.count) 个文件):\n\n" + (files.isEmpty ? "(空)" : files.joined(separator: "\n"))
                showResult = true
            }
        }
    }

    // MARK: - Shared Components
    private func sectionHeader(_ title: String) -> some View {
        HStack { Text(title).font(.headline); Spacer() }
    }

    private func infoCard(_ icon: String, _ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(icon + " " + label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .monospaced, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.secondarySystemBackground)))
    }

    private func actionCard(icon: String, iconColor: Color, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title3).foregroundStyle(iconColor).frame(width: 36, height: 36)
                    .background(iconColor.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body.weight(.medium)).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(14).background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemBackground)))
        }.buttonStyle(.plain)
    }

    private func emptyHint(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "tray").font(.largeTitle).foregroundStyle(.quaternary)
            Text(text).font(.subheadline).foregroundStyle(.tertiary)
        }.frame(maxWidth: .infinity).padding(.vertical, 24)
    }

    private func circleBtn(_ icon: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(.white)
                .frame(width: 32, height: 32).background(color).clipShape(Circle())
        }.buttonStyle(.plain)
    }

    private func showError(_ error: Error) { resultText = "❌ \(error.localizedDescription)"; showResult = true }
}

// MARK: - Result Sheet
private struct ResultSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text).font(.system(.body, design: .monospaced)).padding()
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            .navigationTitle("执行结果").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Button { UIPasteboard.general.string = text } label: { Image(systemName: "doc.on.doc") }
                }
            }
        }
    }
}

#Preview { iPhoneAgentView() }
