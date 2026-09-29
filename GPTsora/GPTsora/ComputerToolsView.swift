// ComputerToolsView.swift
// 电脑控制工具调用结果展示 + 安全策略页
//
// 功能：
//   1. ToolCallResultView   — 单条工具调用结果卡片（用于 HomeChatView 聊天流）
//   2. ComputerControlPanel — 完整控制面板（工具调用 + 历史 + 安全配置）
//   3. SecurityPolicyView   — 安全策略配置页

// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-fc5d09ef6a3539ebcbe06cebcb45613c8cac71a39f130b26d3264436c60a977d"
// Source-SHA256: "fa75a689ef64c32dfd4297f5a4c11d9e60ea68bf0693d6e7e74badd7fbc4c5f5"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI

// MARK: - 数据模型

struct ToolCallResult: Identifiable, Equatable {
    let id: UUID
    let tool: String           // exec / read_file / write_file / search_code / list_dir
    let params: [String: String]
    let ok: Bool
    let output: String
    let blocked: Bool
    let reason: String         // 拦截原因
    let requiresConfirm: Bool
    let timestamp: Date

    var displayTitle: String {
        switch tool {
        case "exec":        return "⌨️ 执行命令"
        case "read_file":   return "📄 读取文件"
        case "write_file":  return "✏️ 写入文件"
        case "search_code": return "🔍 搜索代码"
        case "list_dir":    return "📁 列出目录"
        default:            return "🔧 \(tool)"
        }
    }

    var statusIcon: String {
        if blocked { return "🚫" }
        return ok ? "✅" : "❌"
    }

    var statusColor: Color {
        if blocked { return .orange }
        return ok ? .green : .red
    }

    var paramSummary: String {
        if let cmd = params["command"] { return cmd }
        if let path = params["path"] { return path }
        if let kw = params["keyword"] { return kw }
        return params.values.first ?? ""
    }

    static func == (lhs: ToolCallResult, rhs: ToolCallResult) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - 1. 单条工具调用结果卡片（嵌入 HomeChatView 聊天流）

struct ToolCallResultView: View {
    let result: ToolCallResult
    let onConfirm: (() -> Void)?   // 危险命令确认回调
    let onDismiss: (() -> Void)?   // 关闭回调

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── 标题行 ──
            HStack(spacing: 8) {
                Text(result.statusIcon)
                    .font(.system(size: 14))
                Text(result.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(result.statusColor)
                Spacer()
                if !result.output.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                    } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            // ── 参数摘要 ──
            if !result.paramSummary.isEmpty {
                Text(result.paramSummary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
            }

            // ── 拦截说明 ──
            if result.blocked {
                VStack(alignment: .leading, spacing: 6) {
                    Text("🚫 操作被安全策略拦截")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text(result.reason)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    if result.requiresConfirm, let confirm = onConfirm {
                        HStack(spacing: 8) {
                            Button("确认执行") {
                                confirm()
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Color.orange)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())

                            if let dismiss = onDismiss {
                                Button("取消") { dismiss() }
                                    .font(.system(size: 12))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color(.systemGray5))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }

            // ── 输出内容（可展开）──
            if expanded && !result.output.isEmpty {
                Divider().padding(.horizontal, 6)
                ScrollView {
                    Text(result.output)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 250)
                .background(Color.black.opacity(0.88))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.systemGray6))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(result.statusColor.opacity(0.3), lineWidth: 1)
                )
        )
    }
}

// MARK: - 2. 电脑控制面板（完整 UI）

struct ComputerControlPanel: View {
    let apiBase: String

    @State private var toolName: String = "exec"
    @State private var inputText: String = ""
    @State private var running = false
    @State private var history: [ToolCallResult] = []
    @State private var showSecurity = false
    @State private var pendingConfirm: ToolCallResult? = nil

    private let tools = ["exec", "read_file", "write_file", "search_code", "list_dir"]

    var body: some View {
        VStack(spacing: 0) {

            // ── 顶部工具栏 ──
            HStack {
                Text("💻 电脑控制")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button {
                    showSecurity = true
                } label: {
                    Label("安全策略", systemImage: "lock.shield")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(.systemGray6))

            Divider()

            ScrollView {
                VStack(spacing: 14) {

                    // ── 工具选择 ──
                    toolSelectorRow

                    // ── 输入框 ──
                    inputRow

                    // ── 历史记录 ──
                    if !history.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("历史（\(history.count)）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 2)

                            ForEach(history.reversed().prefix(10)) { item in
                                ToolCallResultView(
                                    result: item,
                                    onConfirm: item.requiresConfirm ? {
                                        retryWithConfirm(item)
                                    } : nil,
                                    onDismiss: nil
                                )
                            }
                        }
                    }
                }
                .padding(14)
            }
        }
        .sheet(isPresented: $showSecurity) {
            SecurityPolicyView(apiBase: apiBase)
        }
    }

    // ── 工具选择器 ──
    private var toolSelectorRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tools, id: \.self) { t in
                    Button {
                        toolName = t
                        inputText = defaultInput(for: t)
                    } label: {
                        Text(toolLabel(t))
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(toolName == t ? Color.accentColor : Color(.systemGray5))
                            .foregroundStyle(toolName == t ? .white : .primary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // ── 输入行 ──
    private var inputRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(inputHint)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .bottom, spacing: 8) {
                TextField(inputPlaceholder, text: $inputText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .font(.system(size: 14, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                Button {
                    callTool()
                } label: {
                    if running {
                        ProgressView().scaleEffect(0.85)
                    } else {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.blue)
                    }
                }
                .disabled(running || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .buttonStyle(.plain)
            }
        }
    }

    // ── 工具调用 ──
    private func callTool(confirm: Bool = false) {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        running = true

        Task {
            let result = await invokeToolAPI(
                toolName: toolName,
                input: text,
                confirm: confirm
            )
            await MainActor.run {
                history.append(result)
                if history.count > 50 { history.removeFirst() }
                running = false
            }
        }
    }

    private func retryWithConfirm(_ original: ToolCallResult) {
        inputText = original.paramSummary
        callTool(confirm: true)
    }

    // ── API 调用 ──
    private func invokeToolAPI(toolName: String, input: String, confirm: Bool) async -> ToolCallResult {
        let base = apiBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/agent/tool") else {
            return makeResult(tool: toolName, input: input, ok: false, output: "❌ 无效 API 地址")
        }

        let params = buildParams(toolName: toolName, input: input, confirm: confirm)
        let body: [String: Any] = ["tool": toolName, "params": params]

        do {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 60
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, _) = try await URLSession.shared.data(for: req)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

            let ok      = json["ok"] as? Bool ?? false
            let blocked = json["blocked"] as? Bool ?? false
            let reason  = json["reason"] as? String ?? ""
            let needConfirm = json["requires_confirm"] as? Bool ?? false
            let output  = (json["output"] as? String)
                       ?? (json["content"] as? String)
                       ?? (json["results"] as? String)
                       ?? ((json["files"] as? [String])?.joined(separator: "\n"))
                       ?? (json["error"] as? String)
                       ?? ""
            return ToolCallResult(
                id: UUID(),
                tool: toolName,
                params: params.mapValues { "\($0)" },
                ok: ok,
                output: output,
                blocked: blocked,
                reason: reason,
                requiresConfirm: needConfirm,
                timestamp: Date()
            )
        } catch {
            return makeResult(tool: toolName, input: input, ok: false, output: "❌ \(error.localizedDescription)")
        }
    }

    private func buildParams(toolName: String, input: String, confirm: Bool) -> [String: Any] {
        switch toolName {
        case "exec":
            return ["command": input, "timeout": 30, "confirm": confirm]
        case "read_file":
            return ["path": input]
        case "write_file":
            // 格式: "路径\n---\n内容"
            let parts = input.components(separatedBy: "\n---\n")
            return ["path": parts[0], "content": parts.dropFirst().joined(separator: "\n---\n"), "confirm": confirm]
        case "search_code":
            // 格式: "关键词 路径" 或仅 "关键词"
            let comps = input.split(separator: " ", maxSplits: 1).map(String.init)
            var p: [String: Any] = ["keyword": comps[0]]
            if comps.count > 1 { p["path"] = comps[1] }
            return p
        case "list_dir":
            return ["path": input, "depth": 2]
        default:
            return ["input": input]
        }
    }

    private func makeResult(tool: String, input: String, ok: Bool, output: String) -> ToolCallResult {
        ToolCallResult(
            id: UUID(), tool: tool,
            params: ["input": input], ok: ok, output: output,
            blocked: false, reason: "", requiresConfirm: false, timestamp: Date()
        )
    }

    // ── 文案辅助 ──
    private func toolLabel(_ t: String) -> String {
        switch t {
        case "exec":        return "⌨️ exec"
        case "read_file":   return "📄 read"
        case "write_file":  return "✏️ write"
        case "search_code": return "🔍 search"
        case "list_dir":    return "📁 ls"
        default:            return t
        }
    }

    private var inputHint: String {
        switch toolName {
        case "exec":        return "输入要执行的终端命令"
        case "read_file":   return "输入文件路径（如 ~/Desktop/GPTsora/GPTsora/HomeChatView.swift）"
        case "write_file":  return "输入：路径\\n---\\n内容"
        case "search_code": return "输入：关键词 [路径]（如 sendMessage ~/Desktop/GPTsora）"
        case "list_dir":    return "输入目录路径"
        default:            return "输入参数"
        }
    }

    private var inputPlaceholder: String {
        switch toolName {
        case "exec":        return "ls ~/Desktop/backend"
        case "read_file":   return "~/Desktop/GPTsora/GPTsora/HomeChatView.swift"
        case "write_file":  return "~/Desktop/test.txt\n---\nHello World"
        case "search_code": return "func sendMessage"
        case "list_dir":    return "~/Desktop/GPTsora"
        default:            return ""
        }
    }

    private func defaultInput(for tool: String) -> String {
        switch tool {
        case "exec":        return "ls ~/Desktop/backend | head -20"
        case "read_file":   return "~/Desktop/GPTsora/GPTsora/HomeChatView.swift"
        case "search_code": return "func sendMessage"
        case "list_dir":    return "~/Desktop/GPTsora"
        default:            return ""
        }
    }
}

// MARK: - 3. 安全策略页

struct SecurityPolicyView: View {
    let apiBase: String

    @State private var allowedRoots: [String] = []
    @State private var tools: [String] = []
    @State private var loading = true
    @State private var newRoot = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if loading {
                    Section { ProgressView("加载中…").frame(maxWidth: .infinity) }
                } else {
                    Section("📁 允许的工作区目录") {
                        ForEach(allowedRoots, id: \.self) { root in
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption)
                                Text(root)
                                    .font(.system(size: 12, design: .monospaced))
                                    .lineLimit(2)
                            }
                        }

                        HStack {
                            TextField("添加新目录路径…", text: $newRoot)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 13, design: .monospaced))
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            Button("添加") {
                                addRoot()
                            }
                            .disabled(newRoot.trimmingCharacters(in: .whitespaces).isEmpty)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }

                    Section("🔧 可用工具") {
                        ForEach(tools, id: \.self) { t in
                            Label(t, systemImage: "terminal")
                                .font(.system(size: 13, design: .monospaced))
                        }
                    }

                    Section("🚫 自动拦截的危险操作") {
                        ForEach(dangerousOps, id: \.self) { op in
                            HStack {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                                    .font(.caption)
                                Text(op)
                                    .font(.system(size: 12))
                            }
                        }
                    }

                    Section("ℹ️ 说明") {
                        Text("电脑控制功能默认只允许操作上方列出的目录。危险命令会被自动拦截，需要用户明确确认才能执行。如需扩大权限范围，可在上方添加目录。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("⚙️ 安全策略")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear { loadConfig() }
        }
    }

    private let dangerousOps = [
        "rm -rf（批量删除）",
        "sudo（权限提升）",
        "mkfs（格式化磁盘）",
        "curl/wget | sh（执行远程脚本）",
        "chmod 777（开放所有权限）",
        "killall（终止所有进程）",
        "launchctl（修改系统服务）",
    ]

    private func loadConfig() {
        loading = true
        Task {
            let base = apiBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let url = URL(string: "\(base)/agent/security") else {
                await MainActor.run { loading = false }
                return
            }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                let roots = json["allowed_roots"] as? [String] ?? []
                let toolList = json["tool_names"] as? [String] ?? []
                await MainActor.run {
                    self.allowedRoots = roots
                    self.tools = toolList
                    self.loading = false
                }
            } catch {
                await MainActor.run { loading = false }
            }
        }
    }

    private func addRoot() {
        let path = newRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        let base = apiBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        Task {
            guard let url = URL(string: "\(base)/agent/security/allow_root") else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["path": path])
            _ = try? await URLSession.shared.data(for: req)
            await MainActor.run {
                if !allowedRoots.contains(path) { allowedRoots.append(path) }
                newRoot = ""
            }
        }
    }
}

// MARK: - 4. 说明：工具调用结果通过 .system role 渲染
// ChatMessage.Role.system 已用于工具结果展示，无需扩展
