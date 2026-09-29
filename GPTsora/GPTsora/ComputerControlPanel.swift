// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-6274cca3562017c72f8bd1e3cd68415b80e3179f704b7a524657ec6d1f8196ba"
// Source-SHA256: "ecf4ebeebaf4e185f5d15c5eceae9819a168d1c16b7378e5028b890bedf372ed"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI

// MARK: - ComputerControlPanel
// 电脑控制面板：快捷操作 + 自然语言输入 + /agent/tools 统一工具接口
// 嵌在 iPhoneAgentView 的 💻 电脑 tab 顶部

struct ComputerControlPanel: View {
    let apiBase: String

    @State private var nlInput: String = ""
    @State private var nlRunning = false
    @State private var nlResult: String = ""
    @State private var confirmState: ConfirmPanelState? = nil

    var body: some View {
        VStack(spacing: 0) {
            // ── 标题 ──
            HStack {
                Label("电脑控制", systemImage: "desktopcomputer")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                // 在线状态指示
                OnlineIndicator(apiBase: apiBase)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.systemGray6))

            Divider()

            ScrollView {
                VStack(spacing: 12) {
                    // ── 自然语言指令输入 ──
                    nlInputSection

                    Divider()

                    // ── 快捷操作区 ──
                    quickActionsSection
                }
                .padding(12)
            }
        }
        .alert(item: $confirmState) { state in
            Alert(
                title: Text("⚠️ 确认执行"),
                message: Text(state.message),
                primaryButton: .destructive(Text("确认")) { state.onConfirm() },
                secondaryButton: .cancel()
            )
        }
    }

    // MARK: - 自然语言输入区
    private var nlInputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("告诉电脑做什么（如：打开计算器）", text: $nlInput, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...2)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(size: 14))
                    .onSubmit { runNL() }

                Button { runNL() } label: {
                    if nlRunning {
                        ProgressView().scaleEffect(0.75)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.blue)
                    }
                }
                .disabled(nlRunning || nlInput.trimmingCharacters(in: .whitespaces).isEmpty)
                .buttonStyle(.plain)
            }

            // 结果显示
            if !nlResult.isEmpty {
                Text(nlResult.prefix(500))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.green)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.85))
                    .cornerRadius(6)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - 快捷操作
    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("快速操作")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                quickBtn("🧮", "计算器",  "open -a Calculator")
                quickBtn("📝", "备忘录",  "open -a Notes")
                quickBtn("🌐", "Safari",  "open -a Safari")
                quickBtn("💬", "微信",    "open -a WeChat")
                quickBtn("📂", "Finder",  "open ~")
                quickBtn("📸", "截图",    "screencapture ~/Desktop/shot_$(date +%H%M%S).png && echo done")
                quickBtn("💾", "磁盘",    "df -h ~ | tail -1")
                quickBtn("🧠", "内存",    "vm_stat | head -5")
                quickBtn("📱", "设备",    "xcrun xctrace list devices 2>/dev/null | grep iPhone | grep -v Simulator | head -3")
            }
        }
    }

    // MARK: - 快捷按钮
    private func quickBtn(_ emoji: String, _ label: String, _ cmd: String) -> some View {
        Button {
            runCommand(cmd, label: label)
        } label: {
            VStack(spacing: 3) {
                Text(emoji).font(.title3)
                Text(label).font(.system(size: 11)).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Color(.systemGray5))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .disabled(nlRunning)
    }

    // MARK: - 执行逻辑

    private func runNL() {
        let text = nlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        nlInput = ""
        nlRunning = true
        nlResult = ""
        Task {
            let result = await callComputerAction(goal: text)
            await MainActor.run {
                nlResult = result
                nlRunning = false
            }
        }
    }

    private func runCommand(_ cmd: String, label: String) {
        nlRunning = true
        nlResult = ""
        Task {
            let result = await callTool("exec", params: ["command": cmd, "timeout": 30])
            await MainActor.run {
                if result.needsConfirm, let reason = result.confirmReason {
                    nlResult = reason
                    nlRunning = false
                    confirmState = ConfirmPanelState(message: reason) {
                        Task {
                            nlRunning = true
                            let r2 = await callTool("exec", params: ["command": cmd, "timeout": 30], confirm: true)
                            await MainActor.run {
                                nlResult = r2.output.trimmingCharacters(in: .whitespacesAndNewlines)
                                nlRunning = false
                            }
                        }
                    }
                } else {
                    nlResult = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    nlRunning = false
                }
            }
        }
    }

    // MARK: - 工具调用
    private func callTool(_ tool: String, params: [String: Any], confirm: Bool = false) async -> ToolResult {
        let base = apiBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/agent/tools") else {
            return ToolResult(ok: false, output: "❌ 无效地址", needsConfirm: false)
        }
        do {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 60
            req.httpBody = try JSONSerialization.data(withJSONObject: ["tool": tool, "params": params, "confirm": confirm])
            let (data, _) = try await URLSession.shared.data(for: req)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return ToolResult(
                ok: json?["ok"] as? Bool ?? false,
                output: json?["output"] as? String ?? "",
                needsConfirm: json?["needs_confirm"] as? Bool ?? false,
                confirmReason: json?["reason"] as? String,
                blocked: json?["blocked"] as? Bool ?? false
            )
        } catch {
            return ToolResult(ok: false, output: "❌ \(error.localizedDescription)", needsConfirm: false)
        }
    }

    private func callComputerAction(goal: String) async -> String {
        let text = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "空指令未发送" }

        let base = AppConfig.API.apiBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/api/brain/computer/action") else {
            return "无效地址: " + base
        }

        do {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 60
            req.httpBody = try JSONSerialization.data(withJSONObject: ["goal": text])

            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

            guard (200..<300).contains(code) else {
                return bodyText.isEmpty ? "HTTP \(code)" : "HTTP \(code): \(bodyText)"
            }

            let ok = (json?["ok"] as? Bool) ?? false
            if !ok {
                if let error = json?["error"] as? String, !error.isEmpty {
                    let message = (json?["message"] as? String) ?? ""
                    return message.isEmpty ? error : "\(error): \(message)"
                }
                if let message = json?["message"] as? String, !message.isEmpty { return message }
                if let detail = json?["detail"] as? String, !detail.isEmpty { return detail }
                return bodyText.isEmpty ? "电脑动作执行失败" : bodyText
            }

            let action = (json?["action"] as? String) ?? ""
            let message = (json?["message"] as? String)
                ?? (json?["final_text"] as? String)
                ?? ((json?["result"] as? [String: Any])?["message"] as? String)
                ?? "已发送: \(text)"
            return action.isEmpty ? message : "[\(action)] \(message)"
        } catch {
            return "\(type(of: error)): \(error.localizedDescription)"
        }
    }

    // MARK: - 自然语言 → 命令
    private func nlToCommand(_ text: String) -> String {
        let t = text.lowercased()
        if t.contains("计算器") { return "open -a Calculator && echo ✅" }
        if t.contains("微信") { return "open -a WeChat && echo ✅" }
        if t.contains("备忘") { return "open -a Notes && echo ✅" }
        if t.contains("safari") || t.contains("浏览器") { return "open -a Safari && echo ✅" }
        if t.contains("截图") || t.contains("screenshot") { return "screencapture ~/Desktop/shot_$(date +%H%M%S).png && echo 截图已保存" }
        if t.contains("磁盘") || t.contains("空间") { return "df -h ~" }
        if t.contains("内存") { return "vm_stat | head -6" }
        if t.contains("cpu") || t.contains("处理器") { return "top -l 1 -s 0 | head -12" }
        if t.contains("网络") || t.contains("ip") { return "ifconfig | grep 'inet ' | grep -v 127" }
        if t.contains("电量") || t.contains("battery") { return "pmset -g batt" }
        if t.contains("进程") { return "ps aux | sort -k3 -rn | head -8" }
        if t.contains("桌面") { return "ls -lh ~/Desktop" }
        if t.contains("git") && t.contains("状态") { return "cd ~/Desktop/GPTsora && git status" }
        if t.contains("后端") && t.contains("状态") { return "ps aux | grep server_session | grep -v grep" }
        // 透传原始命令
        return text
    }
}

// MARK: - 在线状态指示器
private struct OnlineIndicator: View {
    let apiBase: String
    @State private var online: Bool? = nil

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(online == true ? Color.green : (online == nil ? Color.gray : Color.red))
                .frame(width: 7, height: 7)
            Text(online == true ? "已连接" : (online == nil ? "检测中" : "离线"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .onAppear { check() }
        .onTapGesture { check() }
    }

    private func check() {
        online = nil
        Task {
            let base = apiBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let url = URL(string: "\(base)/agent/health") else {
                await MainActor.run { online = false }
                return
            }
            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = 4
                let (_, resp) = try await URLSession.shared.data(for: req)
                await MainActor.run { online = (resp as? HTTPURLResponse)?.statusCode == 200 }
            } catch {
                await MainActor.run { online = false }
            }
        }
    }
}

// MARK: - 确认状态（ComputerControlPanel 专用，避免与 MacAgentSection 冲突）
struct ConfirmPanelState: Identifiable {
    let id = UUID()
    let message: String
    let onConfirm: () -> Void
}
