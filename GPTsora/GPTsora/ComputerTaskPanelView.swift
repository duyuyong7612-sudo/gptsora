// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-467b35dc4479b6bfccbd14e64e03b501db9bbb2d1a8d5ad16ff4d4842a0a9bf6"
// Source-SHA256: "7b583ab7a0c5c7a749de14b0abd43efc5c7a909297656057c6c18ed078478a30"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI
import Combine

struct ComputerTaskPanelView: View {
    @StateObject private var client: ComputerTaskCenterClient
    @State private var draft: String = ""
    @State private var confirmTaskId: String? = nil

    init(apiBase: String, clientId: String) {
        _client = StateObject(
            wrappedValue: ComputerTaskCenterClient(
                apiBase: apiBase,
                clientId: clientId
            )
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                VStack(spacing: 10) {
                    TextField("输入电脑任务，例如：打开微信并查看最新消息", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Button("提交任务") {
                            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { return }

                            Task {
                                do {
                                    let res = try await client.submitTask(text)
                                    draft = ""

                                    if res.need_confirm {
                                        confirmTaskId = res.task_id
                                        _ = try? await client.fetchTask(res.task_id)
                                    } else {
                                        await client.pollTask(res.task_id)
                                    }
                                } catch {
                                    client.errorText = error.localizedDescription
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)

                        Button("刷新") {
                            Task { await client.refreshTasks() }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding()

                if let active = client.activeTask {
                    GroupBox("当前任务") {
                        VStack(alignment: .leading, spacing: 8) {
                            row("任务", active.text)
                            row("状态", active.status)
                            row("风险", active.risk_level)

                            if !active.result.isEmpty {
                                row("结果", active.result)
                            }

                            if !active.error.isEmpty {
                                row("错误", active.error)
                            }

                            if !active.logs.isEmpty {
                                Divider()
                                Text("日志")
                                    .font(.headline)

                                ScrollView {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ForEach(active.logs, id: \.self) { line in
                                            Text(line)
                                                .font(.caption.monospaced())
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                }
                                .frame(maxHeight: 140)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal)
                }

                List(client.tasks) { task in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(task.text)
                                .font(.headline)
                                .lineLimit(2)

                            Spacer()

                            Text(task.status)
                                .font(.caption.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(statusColor(task.status).opacity(0.15))
                                .foregroundColor(statusColor(task.status))
                                .clipShape(Capsule())
                        }

                        HStack {
                            Text(task.risk_level)
                            Text("·")
                            Text(task.execution_mode)
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)

                        if !task.result.isEmpty {
                            Text(task.result)
                                .font(.subheadline)
                                .lineLimit(3)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Task {
                            _ = try? await client.fetchTask(task.task_id)
                        }
                    }
                }
                .listStyle(.plain)

                if !client.errorText.isEmpty {
                    Text(client.errorText)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .padding(.horizontal)
                }
            }
            .navigationTitle("任务中心")
            .task {
                await client.refreshTasks()
            }
            .alert("确认执行该任务？", isPresented: Binding(
                get: { confirmTaskId != nil },
                set: { if !$0 { confirmTaskId = nil } }
            )) {
                Button("取消", role: .cancel) {
                    if let id = confirmTaskId {
                        Task {
                            try? await client.confirmTask(id, approved: false)
                            await client.refreshTasks()
                            confirmTaskId = nil
                        }
                    }
                }

                Button("确认") {
                    if let id = confirmTaskId {
                        Task {
                            try? await client.confirmTask(id, approved: true)
                            confirmTaskId = nil
                            await client.pollTask(id)
                        }
                    }
                }
            } message: {
                Text("这是中高风险电脑操作，确认后才会执行。")
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)

            Text(value)
                .font(.body)
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "done":
            return .green
        case "running":
            return .blue
        case "pending_confirm":
            return .orange
        case "error", "cancelled":
            return .red
        default:
            return .gray
        }
    }
}
