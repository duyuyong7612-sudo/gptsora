// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-e5fcfdd4d6f419da30fea23bf052c19169daf4c7db1cef3af64ba0e12e590052"
// Source-SHA256: "e5ce7daa9aa701c1784a7383f74fe602d2f47174188a5d6b54df8e1033a45e30"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI

// Dev Agent V1 UI — 挂在 iPhoneAgentView 的 🧪 开发 tab
// 只读问答；禁止 Edit/Write/危险 Bash

struct DevAgentReadOnlyPanel: View {
    let apiBase: String

    @StateObject private var client: DevAgentClient
    @State private var prompt: String = "项目入口在哪里？HomeChatView 多大？"
    @State private var running: Bool = false
    @State private var lastResponse: DevAgentResponse? = nil
    @State private var lastError: String = ""
    @State private var history: [Item] = []
    @State private var health: DevAgentHealth? = nil
    @State private var checkingHealth: Bool = false

    init(apiBase: String) {
        self.apiBase = apiBase
        _client = StateObject(wrappedValue: DevAgentClient(backendBase: apiBase))
    }

    struct Item: Identifiable {
        let id = UUID()
        let prompt: String
        let response: DevAgentResponse?
        let error: String?
        let at: Date
    }

    private let presets: [String] = [
        "@main 在哪",
        "HomeChatView 主入口流程",
        "列出 ChatService 相关文件"
    ]

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                introCard
                inputCard
                if let r = lastResponse { resultCard(r) }
                if !lastError.isEmpty { errorCard }
                if !history.isEmpty { historySection }
            }
            .padding(14)
        }
        .task { await refreshHealth() }
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Label("Dev Agent · 只读 V1", systemImage: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            healthIndicator
            Button {
                Task { await refreshHealth() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
            }
            .disabled(checkingHealth)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.systemGray6))
    }

    private var healthIndicator: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(healthColor)
                .frame(width: 8, height: 8)
            Text(healthText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var healthColor: Color {
        if checkingHealth { return .gray }
        guard let h = health else { return .red }
        let installed = h.claude_installed ?? false
        let projectOK = h.project_exists ?? false
        return (h.ok && installed && projectOK) ? .green : .orange
    }

    private var healthText: String {
        if checkingHealth { return "检测中" }
        guard let h = health else { return "未连接" }
        if !h.ok { return "后端异常" }
        if h.claude_installed != true { return "Claude Code 未安装" }
        if h.project_exists != true { return "项目目录缺失" }
        return "claude " + (h.claude_version ?? "?")
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("只读分析模式")
                .font(.system(size: 13, weight: .semibold))
            Text("Claude Code 仅可读取 / 搜索代码，禁止 Edit / Write / 危险 Bash。每次调用是独立子进程，60s 超时。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("提问")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("问 Claude Code 关于项目的任何问题…", text: $prompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...6)
                .font(.system(size: 14))
                .autocorrectionDisabled()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(presets, id: \.self) { p in
                        Button {
                            prompt = p
                        } label: {
                            Text(p)
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color(.systemGray5))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack {
                Spacer()
                Button {
                    submit()
                } label: {
                    HStack(spacing: 6) {
                        if running { ProgressView().scaleEffect(0.8) }
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 22))
                        Text(running ? "分析中…" : "提问")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                }
                .disabled(running || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .buttonStyle(.plain)
            }
        }
    }

    private func resultCard(_ r: DevAgentResponse) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(r.ok ? .green : .red)
                Text(r.ok ? "完成" : "失败")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let ms = r.elapsed_ms {
                    Text("\(ms) ms")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            if !r.output.isEmpty {
                ScrollView {
                    Text(r.output)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 320)
                .padding(10)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if let err = r.error, !err.isEmpty {
                Text(err)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .background(Color(.systemBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var errorCard: some View {
        Text(lastError)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("历史（\(history.count)）")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(history.reversed().prefix(10)) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.prompt)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(2)
                    if let r = item.response {
                        Text(r.output.prefix(160))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    } else if let e = item.error {
                        Text(e)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func submit() {
        let q = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        running = true
        lastError = ""
        lastResponse = nil
        Task {
            do {
                let r = try await client.ask(prompt: q)
                lastResponse = r
                history.append(Item(prompt: q, response: r, error: nil, at: Date()))
            } catch {
                lastError = error.localizedDescription
                history.append(Item(prompt: q, response: nil, error: error.localizedDescription, at: Date()))
            }
            running = false
        }
    }

    private func refreshHealth() async {
        checkingHealth = true
        health = await client.health()
        checkingHealth = false
    }
}
