// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-4bcd6053c683fea6ad0ebe4bf4458d1612966bfb3c68cf2b2c1d2cc3f9e404f0"
// Source-SHA256: "a3bf2a2f1cf09c6340f15d3860e36e435d13278c0624f862cbc90bad55101a66"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI

// MARK: - 自动化编程面板
// 嵌在 ComputerControlHomeView 的截图区下方,让用户在同一个页面里
// 选项目 + 写任务 + 调后端 /api/adu/codex/run。
//
// 安全约束(重复说一遍,以免代码后面被改飘):
//   - App 里没有任何 OpenAI / Anthropic key
//   - 不直接调用 Codex CLI / shell / git
//   - 不自动 git commit / push,不删除文件,不改 .env
//   - needs_user_confirmation=true 时只展示 blocked_terms 和原因,绝不"自动继续执行"

struct EngineeringAgentPanel: View {
    let apiBase: String
    @Binding var project: ProjectChoice
    @Binding var taskText: String
    // ✅ V2 统一上下文 —— 写 Codex / Health 摘要(不写完整 stdout/stderr,那些只留在本地 lastRun)。
    @ObservedObject var aduContext: AduContextStore

    enum ProjectChoice: String, CaseIterable, Identifiable {
        case gptsora       = "GPTsora"
        case backend       = "Backend"
        case littleBeijing = "Little Beijing"
        case chatagiSite   = "ChatAGI Site"

        var id: String { rawValue }

        var path: String {
            switch self {
            case .gptsora:       return "~/Desktop/GPTsora"
            case .backend:       return "~/Desktop/backend"
            case .littleBeijing: return "~/Desktop/little-beijing-edge-box"
            case .chatagiSite:   return "~/Desktop/chatagi-site"
            }
        }

        // 后端 registry 标准 id —— /api/adu/codex/run 优先用这个查路径。
        // path 字段保留只作为本地展示和兼容,不再发到后端。
        var projectId: String {
            switch self {
            case .gptsora:       return "gptsora"
            case .backend:       return "backend"
            case .littleBeijing: return "little_beijing"
            case .chatagiSite:   return "chatagi_site"
            }
        }
    }

    enum RunStatus: String {
        case idle, running, success, failed, needsConfirmation
    }

    @State private var timeout: Int = 900
    @State private var status: RunStatus = .idle
    @State private var lastRun: CodexRunResult? = nil
    @State private var lastHealth: CodexHealthResult? = nil
    @State private var healthChecking: Bool = false
    // ✅ V3.1 短暂提示:写完 Evolution Memory 后挂 5 秒,然后自动收掉。
    @State private var memoryStatusLine: String? = nil

    private let quickTasks: [(String, String)] = [
        ("只读扫描",
         "只读扫描当前工程结构，不改文件，并总结入口文件和构建方式。"),
        ("查 Swift 编译错误",
         "请只读分析当前工程,找出可能的 Swift 编译错误或类型推断问题,列出文件名和原因,但不要修改文件。"),
        ("修最近构建错误",
         "请定位最近一次构建失败的 Swift 错误,提出修复方案和最小 diff(只列出方案,不要直接写文件)。"),
        ("新增小功能",
         "请提议一个最小可用的新功能:列出要新增的文件和入口,但不要直接创建文件,只输出方案。"),
        ("总结修改文件",
         "请只读列出最近修改过的源码文件,按目录归类,简要说明每个文件的作用。"),
    ]

    private let uiGray = Color(red: 240/255, green: 240/255, blue: 240/255)
    private let timeoutOptions = [180, 300, 600, 900, 1500, 3000]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            projectPicker
            quickTasksRow
            taskField
            timeoutAndControlRow
            statusRow
            // ✅ V3.1 evolution memory 的一行提示(5 秒后自动消失)。
            if let line = memoryStatusLine, !line.isEmpty {
                Text(line)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.black.opacity(0.7))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(white: 0.94))
                    .clipShape(Capsule())
            }
            if let r = lastRun {
                runResultPanel(r)
            }
        }
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal, 12)
    }

    // MARK: - 子视图

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.black.opacity(0.78))
            VStack(alignment: .leading, spacing: 1) {
                Text("自动化编程")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.black)
                Text("用 Codex 跑工程、修代码、创建新功能")
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
            }
            Spacer()
            healthChip
        }
    }

    private var healthChip: some View {
        Group {
            if healthChecking {
                ProgressView().scaleEffect(0.7)
            } else if let h = lastHealth {
                let (label, color) = healthLabel(h)
                HStack(spacing: 4) {
                    Circle().fill(color).frame(width: 7, height: 7)
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.black.opacity(0.65))
                        .lineLimit(1)
                }
            } else {
                Text("未检测")
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
            }
        }
    }

    private func healthLabel(_ h: CodexHealthResult) -> (String, Color) {
        // 网络失败 / 后端 error → 红
        if !h.ok {
            return (h.error ?? "unreachable", .red)
        }
        // ok=true 即 "Codex CLI 可用"。version 后端已经带 "codex-cli " 前缀
        // (例如 "codex-cli 0.133.0"),原样显示更清楚;没有 version 时显示 "codex ok"。
        if let v = h.codexVersion?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
            return (v, .green)
        }
        return ("codex ok", .green)
    }

    private var projectPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("项目")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                // ✅ V3:阿杜自动选择工程时,planner 会把 project_id 写进 timeline。
                //    这里据此显示"阿杜自动选择"小徽章;用户改 Picker 后徽章自然消失。
                if let aduPid = aduSuggestedProjectId,
                   aduPid == project.projectId {
                    Text("阿杜自动选择")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.78))
                        .clipShape(Capsule())
                }
                Spacer(minLength: 0)
            }
            Picker("", selection: $project) {
                ForEach(ProjectChoice.allCases) { p in
                    Text(p.rawValue).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .disabled(status == .running)
        }
    }

    // 从 timeline 反查"最近一次 planner 推断出的 project_id"。
    // 不直接读 lastPlannerDecisionLine 是因为里面是混合文本,这里读 metadata 更稳。
    private var aduSuggestedProjectId: String? {
        for e in aduContext.events.reversed() where e.source == .planner {
            if let pid = e.metadata["project_id"], !pid.isEmpty { return pid }
        }
        return nil
    }

    private var quickTasksRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(quickTasks, id: \.0) { (label, text) in
                    Button {
                        taskText = text
                    } label: {
                        Text(label)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.black.opacity(0.78))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(uiGray)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(status == .running)
                }
            }
        }
    }

    private var taskField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("任务描述")
                .font(.system(size: 12))
                .foregroundColor(.gray)
            TextEditor(text: $taskText)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 92, maxHeight: 140)
                .padding(8)
                .background(uiGray)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .disabled(status == .running)
        }
    }

    private var timeoutAndControlRow: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(timeoutOptions, id: \.self) { v in
                    Button("\(v) 秒") { timeout = v }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("\(timeout) 秒")
                        .font(.system(size: 13))
                        .foregroundColor(.black)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(.gray)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(uiGray)
                .clipShape(Capsule())
            }
            .disabled(status == .running)

            Button { checkHealth() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "stethoscope")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Health")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.black.opacity(0.82))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(uiGray)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(healthChecking || status == .running)

            Spacer()

            Button { runCodex() } label: {
                HStack(spacing: 6) {
                    if status == .running {
                        ProgressView().tint(.white).scaleEffect(0.8)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    Text(status == .running ? "Running…" : "Run Codex")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.black)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(status == .running ||
                      taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            statusBadge
            Spacer()
            if let r = lastRun {
                if let ec = r.exitCode {
                    Text("exit=\(ec)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.gray)
                }
                if let d = r.durationSec {
                    Text(String(format: "%.1fs", d))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.gray)
                }
                if r.httpStatus > 0 {
                    Text("HTTP \(r.httpStatus)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.gray)
                }
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        let (text, color): (String, Color) = {
            switch status {
            case .idle:              return ("idle", .gray)
            case .running:           return ("running", .orange)
            case .success:           return ("success", .green)
            case .failed:            return ("failed", .red)
            case .needsConfirmation: return ("needs confirmation", .orange)
            }
        }()
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(color)
        }
    }

    @ViewBuilder
    private func runResultPanel(_ r: CodexRunResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if r.needsUserConfirmation {
                confirmationBlock(r)
            }
            if let m = r.message, !m.isEmpty {
                outputBlock(title: "message", text: m,
                            color: r.ok ? .black.opacity(0.78) : .red)
            }
            if let e = r.error, !e.isEmpty {
                outputBlock(title: "error", text: e, color: .red)
            }
            if !r.stdout.isEmpty {
                outputBlock(title: "stdout", text: r.stdout,
                            color: .black.opacity(0.78))
            }
            if !r.stderr.isEmpty {
                outputBlock(title: "stderr", text: r.stderr,
                            color: .red.opacity(0.78))
            }
        }
    }

    @ViewBuilder
    private func confirmationBlock(_ r: CodexRunResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("需要二次确认 — 已停止,未执行")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.orange)
            }
            if !r.riskReason.isEmpty {
                Text(r.riskReason)
                    .font(.system(size: 12))
                    .foregroundColor(.black.opacity(0.72))
            }
            if !r.blockedTerms.isEmpty {
                Text("blocked terms: " + r.blockedTerms.joined(separator: ", "))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.red.opacity(0.78))
            }
            Text("App 不会自动继续。请在 Mac 端用人工流程确认后再操作。")
                .font(.system(size: 11))
                .foregroundColor(.gray)
        }
        .padding(10)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func outputBlock(title: String, text: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.gray)
            ScrollView(.vertical, showsIndicators: true) {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(color)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 200)
            .background(uiGray)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    // MARK: - 行为

    private func checkHealth() {
        guard !healthChecking else { return }
        healthChecking = true
        Task {
            let h = await CodexAgentClient.health(apiBase: apiBase)
            await MainActor.run {
                lastHealth = h
                healthChecking = false
                // ✅ V2 写入统一上下文 —— Health 简短状态。
                let line: String
                if h.ok {
                    if let v = h.codexVersion, !v.isEmpty {
                        line = "backend ok / codex-cli \(v)"
                    } else {
                        line = "backend ok / codex ok"
                    }
                } else {
                    line = h.error ?? "unreachable"
                }
                aduContext.appendHealth(ok: h.ok, line: line, version: h.codexVersion, error: h.error)
            }
        }
    }

    private func runCodex() {
        let task = taskText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty, status != .running else { return }
        status = .running
        lastRun = nil
        let selfUpgradeRun = aduContext.pendingSelfUpgradeAttachment
        // ✅ V2 写入统一上下文 —— Codex 任务开始(只写"开始 + 摘要",不写完整 prompt)。
        aduContext.appendCodexStarted(
            task: task, projectId: project.projectId, projectDir: project.path, timeout: timeout
        )
        if let attached = selfUpgradeRun,
           let sid = attached.sessionId, !sid.isEmpty {
            aduContext.markSelfUpgradeRunning(
                sessionId: sid,
                upgradeId: attached.upgradeId,
                title: attached.title
            )
        }
        Task {
            if let attached = selfUpgradeRun,
               let sid = attached.sessionId, !sid.isEmpty {
                let stageRes = await AduSelfUpgradeClient.updateStage(
                    apiBase: apiBase,
                    sessionId: sid,
                    stage: "running",
                    message: "自我升级任务正在执行"
                )
                if !stageRes.ok {
                    await MainActor.run {
                        aduContext.appendSystem(
                            "self_upgrade running 上报失败:\(stageRes.errorMessage ?? "?") (session=\(sid), upgrade=\(attached.upgradeId))",
                            kind: .tool_error
                        )
                    }
                }
            }
            let r = await CodexAgentClient.run(
                apiBase: apiBase,
                task: task,
                projectDir: project.path,
                timeout: timeout,
                projectId: project.projectId
            )
            await MainActor.run {
                lastRun = r
                if r.needsUserConfirmation {
                    status = .needsConfirmation
                    // 需要用户确认 → 视为"被风控拦截",写 confirmation_required。
                    aduContext.appendCodexFailure(
                        error: "needs_user_confirmation",
                        message: r.message,
                        blockedTerms: r.blockedTerms,
                        needsConfirmation: true,
                        httpStatus: r.httpStatus,
                        projectId: r.projectId ?? project.projectId
                    )
                } else if r.ok {
                    status = .success
                    // 摘要:不放 stdout/stderr,只放 exit_code / duration / 项目。完整日志仍在卡片里。
                    let head = (r.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let summaryLine = head.isEmpty ? nil : String(head.prefix(160))
                    aduContext.appendCodexSuccess(
                        exitCode: r.exitCode,
                        durationSec: r.durationSec,
                        projectId: r.projectId ?? project.projectId,
                        summaryLine: summaryLine
                    )
                } else {
                    status = .failed
                    aduContext.appendCodexFailure(
                        error: r.error,
                        message: r.message,
                        blockedTerms: r.blockedTerms,
                        needsConfirmation: false,
                        httpStatus: r.httpStatus,
                        projectId: r.projectId ?? project.projectId
                    )
                }

                // ✅ V3.1 evolution memory:任务来自 self-upgrade 推荐项时,落一条经验。
                //    consume() 立即把 attachment 摘走 —— 后续 run 不会重复写。
                if let attached = aduContext.consumeSelfUpgradeAttachment() {
                    writeEvolutionMemory(for: attached, result: r, taskHead: String(task.prefix(120)))
                }
            }
        }
    }

    // ─── V3.1/V2 evolution memory 写入(摘要,不带 stdout / stderr / 凭据)──
    //
    // 分支:
    //   - attachment.sessionId != nil  → POST /api/adu/self/sessions/{id}/codex-result
    //                                    (后端自己写 memory,带 session/upgrade/stage tag)
    //   - attachment.sessionId == nil  → 旧路径,POST /api/adu/self/evolution-memory 直接写
    //
    // 两条路径都"绝不发 stdout/stderr/凭据"。
    private func writeEvolutionMemory(for attachment: PendingSelfUpgradeAttachment,
                                      result r: CodexRunResult,
                                      taskHead: String) {
        // V2 闭环路径
        if let sid = attachment.sessionId, !sid.isEmpty {
            reportCodexResultViaSession(sessionId: sid, attachment: attachment, result: r, taskHead: taskHead)
            return
        }
        // ↓ legacy 路径,保留以防 sessionId 因任何原因丢了
        let succeeded = r.ok && !r.needsUserConfirmation
        let exitStr = r.exitCode.map { "exit=\($0)" } ?? "exit=?"
        let durStr  = r.durationSec.map { String(format: "用时 %.1f 秒", $0) } ?? ""
        let where_  = attachment.projectId ?? (r.projectId ?? "?")

        let problem = "self-upgrade · \(attachment.title)"
        let verification = attachment.verificationCommand ?? ""

        let event: AduEvolutionMemoryEvent
        if succeeded {
            // 成功 —— 不写 stdout;只写"exit/duration/project"和一句 lesson。
            let fix = "Codex 完成 (\(exitStr)\(durStr.isEmpty ? "" : ", " + durStr)) project=\(where_)"
            let lesson = "推荐项『\(attachment.title)』通过 Codex 成功执行;以后类似升级可继续沿用 plan_only→Run 流程。"
            event = AduEvolutionMemoryEvent(
                source: "self_upgrade",
                problem: problem,
                rootCause: "",
                fix: fix,
                verification: verification,
                cost: durStr,
                risk: attachment.riskLevel,
                lesson: lesson,
                tags: ["self_upgrade", attachment.upgradeId, attachment.projectId ?? "no_project"]
            )
        } else {
            // 失败 / needs_user_confirmation —— 只写错误摘要 + blocked_terms。
            var errParts: [String] = []
            if let e = r.error, !e.isEmpty { errParts.append(e) }
            if r.needsUserConfirmation { errParts.append("needs_user_confirmation") }
            if !r.blockedTerms.isEmpty { errParts.append("blocked: " + r.blockedTerms.joined(separator: ",")) }
            if errParts.isEmpty, r.httpStatus > 0 { errParts.append("HTTP \(r.httpStatus)") }
            let errSummary = errParts.joined(separator: " | ")
            let lesson = "推荐项『\(attachment.title)』在 Codex 执行时失败:\(errSummary)。下次先按 dry_run 或更小范围再试。"
            event = AduEvolutionMemoryEvent(
                source: "self_upgrade",
                problem: problem,
                rootCause: errSummary,
                fix: "",
                verification: verification,
                cost: "",
                risk: attachment.riskLevel,
                lesson: lesson,
                tags: ["self_upgrade", "failed", attachment.upgradeId, attachment.projectId ?? "no_project"]
            )
        }

        Task { @MainActor in
            let res = await AduEvolutionMemoryClient.write(apiBase: apiBase, event: event)
            if res.ok {
                aduContext.appendSystem(
                    "已写入 Evolution Memory:\(attachment.title) (\(succeeded ? "成功" : "失败"))",
                    kind: .assistant_summary
                )
                memoryStatusLine = succeeded ? "已写入 Evolution Memory(成功)" : "已写入 Evolution Memory(失败摘要)"
            } else {
                // 写失败不影响 UI 主流;只在 timeline 留一条 tool_error。
                aduContext.appendSystem(
                    "memory write failed:\(res.errorMessage ?? "unknown")",
                    kind: .tool_error
                )
                memoryStatusLine = "Evolution Memory 写入失败,不影响本次 Codex 结果。"
            }
            // 5 秒后自动收掉这行小字(避免长期占位)。
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            memoryStatusLine = nil
        }
    }

    // ─── V2 闭环:走 /sessions/{id}/codex-result(后端写 memory + 算 next_recommendation)──
    private func reportCodexResultViaSession(sessionId: String,
                                             attachment: PendingSelfUpgradeAttachment,
                                             result r: CodexRunResult,
                                             taskHead: String) {
        // 永远不带 stdout / stderr;summary 只取后端友好摘要(我们的 r.message 已经是摘要)。
        let payload = AduSelfUpgradeCodexResultPayload(
            ok: r.ok,
            exitCode: r.exitCode,
            duration: r.durationSec,
            summary: (r.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ? nil : String((r.message ?? "").prefix(400)),
            needsUserConfirmation: r.needsUserConfirmation,
            blockedTerms: r.blockedTerms,
            error: r.error,
            httpStatus: r.httpStatus > 0 ? r.httpStatus : nil
        )
        Task { @MainActor in
            let res = await AduSelfUpgradeClient.reportCodexResult(
                apiBase: apiBase, sessionId: sessionId, payload: payload
            )
            let succeeded = r.ok && !r.needsUserConfirmation
            if res.ok, res.memoryWritten {
                aduContext.setSelfUpgradeReport(
                    nextRecommendation: res.nextRecommendation,
                    verificationSteps: res.verificationRecommendedSteps
                )
                let nextHint = res.nextRecommendationTitle.map { "下次建议: \($0)" } ?? "无后续推荐"
                aduContext.appendSystem(
                    "已完成本轮自我升级记录,已写入 Evolution Memory(session=\(sessionId), upgrade=\(attachment.upgradeId), \(res.verificationOutcome ?? (succeeded ? "ok" : "failed")))。\(nextHint)",
                    kind: .assistant_summary
                )
                memoryStatusLine = "已完成本轮自我升级记录,已写入 Evolution Memory。"
            } else if res.ok && !res.memoryWritten {
                aduContext.setSelfUpgradeReport(
                    nextRecommendation: res.nextRecommendation,
                    verificationSteps: res.verificationRecommendedSteps
                )
                aduContext.appendSystem(
                    "session 已记录但 Evolution Memory 写入失败:\(res.memoryError ?? "未知") (session=\(sessionId))",
                    kind: .tool_error
                )
                memoryStatusLine = "session 已记录,但 Evolution Memory 写入失败(不影响本次结果)。"
            } else {
                aduContext.appendSystem(
                    "session codex-result 上报失败:\(res.errorMessage ?? "未知") (session=\(sessionId)) — 已退回 legacy 直接写 memory",
                    kind: .tool_error
                )
                // 兜底:直接走 legacy 路径再写一次
                writeEvolutionMemoryLegacy(for: attachment, result: r, taskHead: taskHead)
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            memoryStatusLine = nil
        }
    }

    // legacy 直接写 evolution-memory 的版本 —— 仅作 session 路径失败时兜底使用。
    private func writeEvolutionMemoryLegacy(for attachment: PendingSelfUpgradeAttachment,
                                            result r: CodexRunResult,
                                            taskHead: String) {
        // 复用主 writeEvolutionMemory 但强行抹掉 sessionId,避免无限递归
        let stripped = PendingSelfUpgradeAttachment(
            upgradeId: attachment.upgradeId,
            title: attachment.title,
            projectId: attachment.projectId,
            riskLevel: attachment.riskLevel,
            suggestedMode: attachment.suggestedMode,
            verificationCommand: attachment.verificationCommand,
            sessionId: nil,
            attachedAt: attachment.attachedAt
        )
        writeEvolutionMemory(for: stripped, result: r, taskHead: taskHead)
    }
}
