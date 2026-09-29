// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-ffaf3ada6b1aea6a736bafb3d2a31b9e462534f286b717b33a07d0c44b024c49"
// Source-SHA256: "19c8b6f0dad5c2376c24ebdf25a772c0cd3362e04f7ce9695eb7d0547be62188"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI

// MARK: - 工具调用结果
struct ToolResult {
    let ok: Bool
    let output: String
    let needsConfirm: Bool
    var confirmReason: String? = nil
    var blocked: Bool = false
}

// MARK: - 确认弹窗状态
struct ConfirmState: Identifiable {
    let id = UUID()
    let message: String
    let onConfirm: () -> Void
}

// MARK: - 电脑控制模块 v2
// 通过后端 /agent/* 接口控制笔记本
// 新增：
//   0️⃣ "控制" tab — 自然语言 → AI → 终端执行，快捷操作卡片
//   1️⃣ 项目树 tab
//   2️⃣ 命令 tab（raw terminal）
//   3️⃣ 编译/安装 tab

struct MacAgentSection: View {
    let apiBase: String

    // ── 控制 tab ──
    @State private var nlInput: String = ""
    @State private var nlRunning = false
    @State private var nlResult: String = ""
    @State private var nlHistory: [(cmd: String, output: String)] = []

    // ── 文件树 tab ──
    @State private var fileTree: [String] = []
    @State private var treeLoading = false
    @State private var treeError = ""
    @State private var treePathInput: String = "~/Desktop/GPTsora/GPTsora"

    // ── 命令 tab ──
    @State private var cmdInput = ""
    @State private var cmdOutput = ""
    @State private var cmdRunning = false

    // ── 编译 tab ──
    @State private var buildOutput = ""
    @State private var buildRunning = false
    @State private var buildSuccess: Bool? = nil

    // ── Mac 在线状态 ──
    @State private var macOnline: Bool? = nil
    @State private var statusChecked = false

    // ── 确认弹窗 ──
    @State private var confirmState: ConfirmState? = nil
    @State private var pendingConfirmCmd: String? = nil

    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            // ── 状态栏 ──
            statusBar

            // ── Tab picker ──
            Picker("", selection: $selectedTab) {
                Text("🎮 控制").tag(0)
                Text("📁 项目树").tag(1)
                Text("⌨️ 命令").tag(2)
                Text("🔨 编译").tag(3)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    switch selectedTab {
                    case 0: controlTab
                    case 1: fileTreeTab
                    case 2: commandTab
                    case 3: buildTab
                    default: EmptyView()
                    }
                }
                .padding(16)
            }
        }
        .onAppear { checkMacStatus() }
        // 确认弹窗
        .alert(item: $confirmState) { state in
            Alert(
                title: Text("⚠️ 需要确认"),
                message: Text(state.message),
                primaryButton: .destructive(Text("确认执行")) { state.onConfirm() },
                secondaryButton: .cancel(Text("取消"))
            )
        }
    }

    // MARK: - 状态栏
    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(macOnline == true ? Color.green : (macOnline == nil ? Color.gray : Color.red))
                .frame(width: 8, height: 8)
            Text(macOnline == true ? "电脑已连接" : (macOnline == nil ? "检测中…" : "电脑离线"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                checkMacStatus()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color(.systemGray6))
    }

    // MARK: - 🎮 控制 Tab（自然语言 + 快捷卡片）
    private var controlTab: some View {
        VStack(alignment: .leading, spacing: 16) {

            // ── 自然语言输入区 ──
            VStack(alignment: .leading, spacing: 8) {
                Text("告诉我你想对电脑做什么")
                    .font(.headline)

                HStack(alignment: .bottom, spacing: 8) {
                    TextField("例：打开计算器 / 查看磁盘空间 / 截个屏", text: $nlInput, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...3)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(size: 15))
                        .onSubmit { sendNLCommand() }

                    Button {
                        sendNLCommand()
                    } label: {
                        Group {
                            if nlRunning {
                                ProgressView().scaleEffect(0.8)
                            } else {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 28))
                            }
                        }
                    }
                    .disabled(nlRunning || nlInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }

                // 最近结果
                if !nlResult.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("结果")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(nlResult)
                            .font(.system(size: 13, design: .monospaced))
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.black.opacity(0.85))
                            .foregroundStyle(.green)
                            .cornerRadius(8)
                            .textSelection(.enabled)
                    }
                }
            }

            Divider()

            // ── 快捷操作卡片 ──
            Text("快速操作")
                .font(.headline)

            // 打开 App
            quickActionGroup(title: "📱 打开应用") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    quickActionCard("🧮", "计算器",    "open -a Calculator")
                    quickActionCard("📝", "备忘录",    "open -a Notes")
                    quickActionCard("📅", "日历",      "open -a Calendar")
                    quickActionCard("🌐", "Safari",    "open -a Safari")
                    quickActionCard("💬", "微信",      "open -a WeChat")
                    quickActionCard("📂", "Finder",    "open ~")
                    quickActionCard("⚙️", "系统设置",  "open -a 'System Settings'")
                    quickActionCard("🎵", "音乐",      "open -a Music")
                    quickActionCard("📺", "Xcode",     "open -a Xcode")
                }
            }

            // 系统信息
            quickActionGroup(title: "📊 系统状态") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    quickActionWideCard("💾 磁盘空间",   "df -h ~ | tail -1")
                    quickActionWideCard("🧠 内存状态",   "vm_stat | head -6")
                    quickActionWideCard("🔥 CPU 使用",   "top -l 1 -s 0 | head -12 | tail -6")
                    quickActionWideCard("🌐 网络接口",   "ifconfig | grep 'inet ' | grep -v 127")
                    quickActionWideCard("⚡️ 运行进程",   "ps aux | sort -k3 -rn | head -8")
                    quickActionWideCard("🔌 充电状态",   "pmset -g batt | head -3")
                }
            }

            // 文件操作
            quickActionGroup(title: "📁 文件操作") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    quickActionWideCard("🖥️ 桌面文件",   "ls -lh ~/Desktop | head -20")
                    quickActionWideCard("📦 下载目录",   "ls -lht ~/Downloads | head -10")
                    quickActionWideCard("🗂️ 项目列表",   "ls ~/Desktop | grep -E 'GPT|sora|backend|flutter'")
                    quickActionWideCard("📸 截图桌面",   "screencapture ~/Desktop/screenshot_$(date +%H%M%S).png && echo 已截图")
                }
            }

            // 历史记录
            if !nlHistory.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("历史记录（\(nlHistory.count)）")
                            .font(.headline)
                        Spacer()
                        Button("清除") { nlHistory.removeAll() }
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    ForEach(Array(nlHistory.reversed().prefix(5).enumerated()), id: \.0) { _, item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("▶ \(item.cmd)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(item.output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.green)
                                .lineLimit(3)
                        }
                        .padding(8)
                        .background(Color.black.opacity(0.8))
                        .cornerRadius(6)
                    }
                }
            }
        }
    }

    // MARK: - 文件树 tab
    var fileTreeTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("项目文件树")
                    .font(.headline)
                Spacer()
                Button {
                    loadFileTree()
                } label: {
                    if treeLoading {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(treeLoading)
            }

            // 路径输入
            HStack {
                TextField("路径", text: $treePathInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("加载") { loadFileTree() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }

            if !treeError.isEmpty {
                Text(treeError)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            if fileTree.isEmpty && !treeLoading {
                Button("加载项目树") { loadFileTree() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            } else {
                Text("\(fileTree.count) 个文件").font(.caption).foregroundStyle(.secondary)
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(fileTree, id: \.self) { file in
                        HStack(spacing: 6) {
                            Image(systemName: fileIcon(file))
                                .foregroundColor(fileColor(file))
                                .font(.system(size: 12))
                            Text(fileName(file))
                                .font(.system(size: 13, design: .monospaced))
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, 8)
                        .background(Color(.systemGray6))
                        .cornerRadius(6)
                        .onTapGesture {
                            // 读文件内容
                            let readCmd = "cat '\(file)' | head -50"
                            selectedTab = 2
                            cmdInput = readCmd
                            runCommand(readCmd)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 命令执行 tab
    var commandTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("终端命令")
                .font(.headline)

            // 常用命令快捷按钮
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                quickCmdBtn("📋 Swift文件", "ls ~/Desktop/GPTsora/GPTsora/ | grep .swift | head -20")
                quickCmdBtn("💾 磁盘空间", "df -h ~")
                quickCmdBtn("🔄 Git状态", "cd ~/Desktop/GPTsora && git status --short")
                quickCmdBtn("📦 Pod版本", "cd ~/Desktop/GPTsora && pod --version")
                quickCmdBtn("🍎 Xcode版本", "xcodebuild -version")
                quickCmdBtn("📊 内存使用", "vm_stat | head -5")
                quickCmdBtn("🌐 网络IP", "ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1")
                quickCmdBtn("📱 已连设备", "xcrun xctrace list devices 2>/dev/null | grep iPhone | grep -v Simulator")
            }

            // 自定义命令输入
            HStack {
                TextField("输入命令...", text: $cmdInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { runCommand(cmdInput) }

                Button {
                    runCommand(cmdInput)
                } label: {
                    if cmdRunning {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Image(systemName: "play.fill")
                    }
                }
                .disabled(cmdRunning || cmdInput.trimmingCharacters(in: .whitespaces).isEmpty)
                .buttonStyle(.borderedProminent)
            }

            if !cmdOutput.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("输出")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("清除") { cmdOutput = "" }
                            .font(.caption)
                        Button {
                            UIPasteboard.general.string = cmdOutput
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .font(.caption)
                    }
                    ScrollView {
                        Text(cmdOutput)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 400)
                    .background(Color.black.opacity(0.9))
                    .foregroundColor(.green)
                    .cornerRadius(8)
                    .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - 编译安装 tab
    var buildTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("编译并安装到 iPhone")
                .font(.headline)

            // 状态卡片
            if let success = buildSuccess {
                HStack {
                    Image(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(success ? .green : .red)
                        .font(.title2)
                    Text(success ? "BUILD SUCCEEDED ✅" : "BUILD FAILED ❌")
                        .font(.headline)
                        .foregroundColor(success ? .green : .red)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background((success ? Color.green : Color.red).opacity(0.1))
                .cornerRadius(12)
            }

            // 操作按钮
            VStack(spacing: 10) {
                Button {
                    buildProject()
                } label: {
                    HStack {
                        Image(systemName: "hammer.fill")
                        Text(buildRunning ? "编译中..." : "🔨 编译 GPT Solara")
                        if buildRunning { Spacer(); ProgressView().scaleEffect(0.8) }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent).disabled(buildRunning).tint(.blue)

                Button {
                    installToDevice()
                } label: {
                    HStack {
                        Image(systemName: "iphone.and.arrow.right")
                        Text(buildRunning ? "安装中..." : "📲 编译并安装到手机")
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent).disabled(buildRunning).tint(.green)
            }

            // 编译输出
            if !buildOutput.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("编译日志")
                            .font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Button("清除") { buildOutput = ""; buildSuccess = nil }
                            .font(.caption)
                    }
                    ScrollView {
                        Text(buildOutput)
                            .font(.system(size: 11, design: .monospaced))
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 350)
                    .background(Color.black.opacity(0.9))
                    .foregroundColor(buildSuccess == true ? .green : .orange)
                    .cornerRadius(8)
                }
            }
        }
    }

    // MARK: - Helper Views

    private func quickActionGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func quickActionCard(_ emoji: String, _ name: String, _ cmd: String) -> some View {
        Button {
            runQuickAction(cmd, label: name)
        } label: {
            VStack(spacing: 4) {
                Text(emoji).font(.title2)
                Text(name)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color(.systemGray5))
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
        .disabled(nlRunning || cmdRunning)
    }

    private func quickActionWideCard(_ title: String, _ cmd: String) -> some View {
        Button {
            runQuickAction(cmd, label: title)
        } label: {
            HStack {
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "play.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(.systemGray5))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .disabled(nlRunning || cmdRunning)
    }

    private func quickCmdBtn(_ label: String, _ cmd: String) -> some View {
        Button {
            cmdInput = cmd
            runCommand(cmd)
        } label: {
            Text(label)
                .font(.caption)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color(.systemGray5))
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 自然语言 → 命令执行（含安全确认）
    private func sendNLCommand() {
        let text = nlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let cmd = nlToCommand(text)
        nlInput = ""
        nlRunning = true
        nlResult = ""

        Task {
            let result = await callTool("exec", params: ["command": cmd, "timeout": 30])
            await MainActor.run {
                if result.needsConfirm, let reason = result.confirmReason {
                    nlRunning = false
                    nlResult = reason
                    // 弹确认框
                    confirmState = ConfirmState(message: reason) { [self] in
                        Task {
                            nlRunning = true
                            let confirmed = await callTool("exec", params: ["command": cmd, "timeout": 30], confirm: true)
                            await MainActor.run {
                                nlResult = confirmed.output.trimmingCharacters(in: .whitespacesAndNewlines)
                                nlHistory.append((cmd: text, output: nlResult))
                                if nlHistory.count > 20 { nlHistory.removeFirst() }
                                nlRunning = false
                            }
                        }
                    }
                } else if result.blocked {
                    nlResult = result.output
                    nlRunning = false
                } else {
                    nlResult = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    nlHistory.append((cmd: text, output: nlResult))
                    if nlHistory.count > 20 { nlHistory.removeFirst() }
                    nlRunning = false
                }
            }
        }
    }

    /// 自然语言 → shell 命令（本地规则映射）
    private func nlToCommand(_ text: String) -> String {
        let t = text.lowercased()

        // 打开应用
        if t.contains("打开") || t.contains("open") || t.contains("启动") {
            if t.contains("计算器") || t.contains("calculator") { return "open -a Calculator && echo 已打开计算器" }
            if t.contains("微信") || t.contains("wechat") { return "open -a WeChat && echo 已打开微信" }
            if t.contains("备忘") || t.contains("note") { return "open -a Notes && echo 已打开备忘录" }
            if t.contains("日历") || t.contains("calendar") { return "open -a Calendar && echo 已打开日历" }
            if t.contains("safari") || t.contains("浏览器") { return "open -a Safari && echo 已打开Safari" }
            if t.contains("xcode") { return "open -a Xcode && echo 已打开Xcode" }
            if t.contains("finder") || t.contains("文件") { return "open ~ && echo 已打开Finder" }
            if t.contains("系统") || t.contains("设置") { return "open -a 'System Settings' && echo 已打开系统设置" }
            if t.contains("终端") || t.contains("terminal") { return "open -a Terminal && echo 已打开终端" }
            if t.contains("音乐") || t.contains("music") { return "open -a Music && echo 已打开音乐" }
        }

        // 截图
        if t.contains("截图") || t.contains("screenshot") || t.contains("截屏") {
            return "screencapture ~/Desktop/screenshot_$(date +%H%M%S).png && echo 截图已保存到桌面"
        }

        // 系统信息
        if t.contains("磁盘") || t.contains("disk") || t.contains("空间") || t.contains("storage") {
            return "df -h ~ | tail -1 && du -sh ~/Desktop ~/Documents ~/Downloads 2>/dev/null"
        }
        if t.contains("内存") || t.contains("memory") || t.contains("ram") {
            return "vm_stat | head -8"
        }
        if t.contains("cpu") || t.contains("处理器") || t.contains("占用") {
            return "top -l 1 -s 0 | head -15"
        }
        if t.contains("网络") || t.contains("ip") || t.contains("network") {
            return "ifconfig | grep 'inet ' | grep -v 127.0.0.1"
        }
        if t.contains("电量") || t.contains("battery") || t.contains("充电") {
            return "pmset -g batt"
        }
        if t.contains("进程") || t.contains("process") || t.contains("pid") {
            return "ps aux | sort -k3 -rn | head -10"
        }

        // 文件操作
        if t.contains("桌面") || t.contains("desktop") {
            return "ls -lh ~/Desktop"
        }
        if t.contains("下载") || t.contains("download") {
            return "ls -lht ~/Downloads | head -15"
        }
        if (t.contains("列") || t.contains("ls") || t.contains("显示")) && t.contains("文件") {
            return "ls -lh ~/Desktop/GPTsora/GPTsora | grep .swift | head -20"
        }

        // 搜索代码
        if t.contains("搜索") || t.contains("search") || t.contains("查找") || t.contains("grep") {
            // 特殊处理：直接走 search_code 工具
            // 例："搜索 HomeChatView" → "SEARCH:HomeChatView"
            let parts = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            if parts.count >= 2 {
                let keyword = parts.dropFirst().joined(separator: " ")
                return "SEARCH:\(keyword)"  // 特殊标记，由 sendNLCommand 识别
            }
        }

        // 读取文件
        if t.contains("读取") || t.contains("打开文件") || t.contains("查看") && t.contains("文件") {
            if t.contains(".swift") || t.contains(".py") {
                // 提取文件名
                if let range = text.range(of: #"\S+\.(swift|py|json|md)"#, options: .regularExpression) {
                    let filename = String(text[range])
                    return "cat ~/Desktop/GPTsora/GPTsora/\(filename) 2>/dev/null || find ~/Desktop -name '\(filename)' | head -1 | xargs cat"
                }
            }
        }

        // Git 操作
        if t.contains("git") || t.contains("代码") || t.contains("提交") || t.contains("commit") {
            if t.contains("状态") || t.contains("status") { return "cd ~/Desktop/GPTsora && git status" }
            if t.contains("日志") || t.contains("log") { return "cd ~/Desktop/GPTsora && git log --oneline -10" }
            if t.contains("提交") || t.contains("commit") { return "cd ~/Desktop/GPTsora && git add -A && git status" }
        }

        // 关闭/退出
        if t.contains("关闭") || t.contains("退出") || t.contains("quit") || t.contains("kill") {
            if t.contains("微信") { return "osascript -e 'quit app \"WeChat\"' && echo 已关闭微信" }
            if t.contains("safari") { return "osascript -e 'quit app \"Safari\"' && echo 已关闭Safari" }
            if t.contains("xcode") { return "osascript -e 'quit app \"Xcode\"' && echo 已关闭Xcode" }
            if t.contains("计算器") { return "osascript -e 'quit app \"Calculator\"' && echo 已关闭计算器" }
        }

        // 音量
        if t.contains("音量") || t.contains("volume") {
            if t.contains("静音") || t.contains("mute") { return "osascript -e 'set volume output muted true' && echo 已静音" }
            if t.contains("50") { return "osascript -e 'set volume output volume 50' && echo 音量设为50" }
            return "osascript -e 'output volume of (get volume settings)'"
        }

        // 后端服务
        if t.contains("后端") || t.contains("backend") || t.contains("服务") || t.contains("server") {
            if t.contains("状态") || t.contains("运行") { return "ps aux | grep server_session | grep -v grep" }
            if t.contains("重启") { return "pkill -f server_session.py; sleep 1; cd ~/Desktop/backend && nohup python3 server_session.py &>/tmp/backend.log & echo 后端已重启" }
        }

        // 项目
        if t.contains("gptsora") || t.contains("项目") || t.contains("swift") {
            return "ls ~/Desktop/GPTsora/GPTsora/*.swift | wc -l && echo 个Swift文件"
        }

        // 默认：直接作为 shell 命令执行（允许高级用户直接输入命令）
        // 安全检查：过滤破坏性命令
        let dangerous = ["rm -rf", "sudo rm", "format", "mkfs", "> /dev/", "dd if"]
        for d in dangerous {
            if text.lowercased().contains(d) {
                return "echo '⚠️ 该命令被安全拦截：\(d)'"
            }
        }
        return text
    }

    // MARK: - 快速操作（直接执行，显示在 nlResult）
    private func runQuickAction(_ cmd: String, label: String) {
        nlRunning = true
        nlResult = ""
        Task {
            let output = await execCommand(cmd)
            await MainActor.run {
                nlResult = output.trimmingCharacters(in: .whitespacesAndNewlines)
                nlHistory.append((cmd: label, output: nlResult))
                if nlHistory.count > 20 { nlHistory.removeFirst() }
                nlRunning = false
                selectedTab = 0  // 跳到控制 tab 看结果
            }
        }
    }

    // MARK: - 后端状态检查
    private func checkMacStatus() {
        macOnline = nil
        Task {
            let base = apiBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let url = URL(string: "\(base)/agent/health") else {
                await MainActor.run { macOnline = false }
                return
            }
            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = 5
                let (_, resp) = try await URLSession.shared.data(for: req)
                let ok = (resp as? HTTPURLResponse)?.statusCode == 200
                await MainActor.run { macOnline = ok }
            } catch {
                await MainActor.run { macOnline = false }
            }
        }
    }

    // MARK: - 统一工具调用 /agent/tools（含安全层）

    /// 调用 /agent/tools 统一接口
    private func callTool(_ tool: String, params: [String: Any], confirm: Bool = false) async -> ToolResult {
        let base = apiBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/agent/tools") else {
            return ToolResult(ok: false, output: "❌ 无效的后端地址", needsConfirm: false)
        }
        do {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 180
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "tool": tool,
                "params": params,
                "confirm": confirm,
            ])
            let (data, _) = try await URLSession.shared.data(for: req)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let ok = json?["ok"] as? Bool ?? false
            let output = json?["output"] as? String ?? "(无输出)"
            let needsConfirm = json?["needs_confirm"] as? Bool ?? false
            let blocked = json?["blocked"] as? Bool ?? false
            let reason = json?["reason"] as? String
            return ToolResult(
                ok: ok,
                output: blocked ? (reason ?? output) : output,
                needsConfirm: needsConfirm,
                confirmReason: reason,
                blocked: blocked
            )
        } catch {
            return ToolResult(ok: false, output: "❌ \(error.localizedDescription)", needsConfirm: false)
        }
    }

    /// 通用命令执行（内部使用，走 /agent/tools exec）
    private func execCommand(_ cmd: String) async -> String {
        let result = await callTool("exec", params: ["command": cmd, "timeout": 30])
        return result.output
    }

    /// 读取文件
    func readFile(_ path: String, startLine: Int? = nil, endLine: Int? = nil) async -> ToolResult {
        var params: [String: Any] = ["path": path]
        if let s = startLine { params["start_line"] = s }
        if let e = endLine   { params["end_line"] = e }
        return await callTool("read_file", params: params)
    }

    /// 搜索代码
    func searchCode(_ keyword: String, path: String = "~/Desktop/GPTsora", ext: String = "") async -> ToolResult {
        return await callTool("search_code", params: ["keyword": keyword, "path": path, "ext": ext])
    }

    /// 写文件（需 confirm=true）
    func writeFile(_ path: String, content: String, confirm: Bool = false) async -> ToolResult {
        return await callTool("write_file", params: ["path": path, "content": content], confirm: confirm)
    }

    // MARK: - API Calls（原有方法）

    private func loadFileTree() {
        treeLoading = true
        treeError = ""
        Task {
            do {
                let base = apiBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let url = URL(string: "\(base)/agent/filetree")!
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.timeoutInterval = 20
                req.httpBody = try JSONSerialization.data(withJSONObject: [
                    "path": treePathInput,
                    "depth": 2,
                    "extensions": [".swift", ".py"]
                ])
                let (data, _) = try await URLSession.shared.data(for: req)
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let files = json?["files"] as? [String] ?? []
                await MainActor.run {
                    self.fileTree = files
                    self.treeLoading = false
                }
            } catch {
                await MainActor.run {
                    self.treeError = error.localizedDescription
                    self.treeLoading = false
                }
            }
        }
    }

    private func runCommand(_ cmd: String) {
        guard !cmd.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        cmdRunning = true
        Task {
            let output = await execCommand(cmd)
            await MainActor.run {
                self.cmdOutput = output
                self.cmdRunning = false
            }
        }
    }

    private func buildProject() {
        buildRunning = true; buildSuccess = nil; buildOutput = "编译中…\n"
        Task {
            do {
                let base = apiBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let url = URL(string: "\(base)/agent/build")!
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.timeoutInterval = 300
                req.httpBody = try JSONSerialization.data(withJSONObject: ["path": "~/Desktop/GPTsora", "scheme": "GPT Solara"])
                let (data, _) = try await URLSession.shared.data(for: req)
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let success = json?["success"] as? Bool ?? false
                let output = (json?["output"] as? String ?? "")
                let keyLines = output.components(separatedBy: "\n")
                    .filter { $0.contains("error:") || $0.contains("BUILD") || $0.contains("warning:") }
                    .prefix(50).joined(separator: "\n")
                await MainActor.run { self.buildSuccess = success; self.buildOutput = keyLines; self.buildRunning = false }
            } catch {
                await MainActor.run { self.buildOutput = "❌ \(error.localizedDescription)"; self.buildRunning = false }
            }
        }
    }

    private func installToDevice() {
        buildRunning = true; buildSuccess = nil; buildOutput = "编译并安装中…（最多5分钟）\n"
        Task {
            do {
                let base = apiBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let url = URL(string: "\(base)/agent/install")!
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.timeoutInterval = 360
                req.httpBody = try JSONSerialization.data(withJSONObject: ["path": "~/Desktop/GPTsora", "scheme": "GPT Solara"])
                let (data, _) = try await URLSession.shared.data(for: req)
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let success = json?["success"] as? Bool ?? false
                let output = (json?["build_output"] as? String ?? "") + (json?["install_output"] as? String ?? "")
                let keyLines = output.components(separatedBy: "\n")
                    .filter { $0.contains("error:") || $0.contains("BUILD") || $0.contains("install") || $0.contains("App installed") }
                    .prefix(50).joined(separator: "\n")
                await MainActor.run { self.buildSuccess = success; self.buildOutput = keyLines; self.buildRunning = false }
            } catch {
                await MainActor.run { self.buildOutput = "❌ \(error.localizedDescription)"; self.buildRunning = false }
            }
        }
    }

    // MARK: - File helpers
    private func fileName(_ path: String) -> String {
        let parts = path.components(separatedBy: "/")
        return parts.count >= 2 ? parts.suffix(2).joined(separator: "/") : (parts.last ?? path)
    }
    private func fileIcon(_ path: String) -> String {
        if path.hasSuffix(".swift") { return "swift" }
        if path.hasSuffix(".py") { return "chevron.left.forwardslash.chevron.right" }
        if path.hasSuffix(".json") { return "doc.text" }
        if path.hasSuffix(".xcodeproj") || path.hasSuffix(".xcworkspace") { return "hammer" }
        return "doc"
    }
    private func fileColor(_ path: String) -> Color {
        if path.hasSuffix(".swift") { return .orange }
        if path.hasSuffix(".py") { return .blue }
        if path.hasSuffix(".json") { return .green }
        return .secondary
    }
}
