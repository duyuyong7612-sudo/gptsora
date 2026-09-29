// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-5140ac7b3c9a6ce187030a497b38760addf63bb73963bcb6544ae9ae0c95675f"
// Source-SHA256: "ff120ff2fe59ecb581d3508990fd0c6a02cd6c8e1e9790cab433a66bfc00150b"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI

struct AduCodexRunDebugPanel: View {
    @State private var apiBase: String
    @State private var requestBody: String
    @State private var running = false
    @State private var statusText = "未请求"
    @State private var responseText = ""
    @State private var elapsedText = ""

    private let endpointPath = "/api/adu/codex/run"

    init(apiBase: String) {
        _apiBase = State(initialValue: apiBase)
        _requestBody = State(initialValue: AduCodexRunDebugPanel.defaultBody)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            endpointCard
            requestEditor
            actionRow
            responseCard
        }
        .padding(12)
        .background(Color(.systemBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Adu Codex Run", systemImage: "terminal")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Text(statusText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(statusText.hasPrefix("2") ? .green : .secondary)
        }
    }

    private var endpointCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("后端地址")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("http://host:8000", text: $apiBase)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 13, design: .monospaced))
                .textFieldStyle(.roundedBorder)

            Text(endpointURLString)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }

    private var requestEditor: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("JSON 请求体")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    requestBody = Self.defaultBody
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(running)
            }

            TextEditor(text: $requestBody)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 150)
                .padding(8)
                .scrollContentBackground(.hidden)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                Task { await runCodex() }
            } label: {
                HStack(spacing: 6) {
                    if running { ProgressView().scaleEffect(0.8) }
                    Image(systemName: "paperplane.fill")
                    Text(running ? "运行中" : "发送")
                        .font(.system(size: 14, weight: .semibold))
                }
                .frame(minWidth: 92)
            }
            .buttonStyle(.borderedProminent)
            .disabled(running || requestBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if !elapsedText.isEmpty {
                Text(elapsedText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                responseText = ""
                statusText = "未请求"
                elapsedText = ""
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(running)
        }
    }

    private var responseCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("原始响应")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(responseText.isEmpty ? "等待响应..." : responseText)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(responseText.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120, maxHeight: 280)
            .padding(10)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var endpointURLString: String {
        normalizedBase + endpointPath
    }

    private var normalizedBase: String {
        var base = apiBase.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }

    private func runCodex() async {
        let rawBody = requestBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: endpointURLString) else {
            statusText = "URL 无效"
            responseText = endpointURLString
            return
        }
        guard let bodyData = rawBody.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: bodyData)) != nil else {
            statusText = "JSON 无效"
            responseText = rawBody
            return
        }

        running = true
        statusText = "请求中"
        responseText = ""
        elapsedText = ""
        let startedAt = Date()

        do {
            var req = AccountManager.makeAuthorizedRequest(url)
            req.httpMethod = "POST"
            req.timeoutInterval = 180
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("ios_codex_debug_panel", forHTTPHeaderField: "X-Client-ID")
            req.httpBody = bodyData

            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            statusText = code > 0 ? "HTTP \(code)" : "无状态码"
            elapsedText = String(format: "%.1fs", Date().timeIntervalSince(startedAt))
            responseText = prettyResponse(from: data)
        } catch {
            statusText = "请求失败"
            elapsedText = String(format: "%.1fs", Date().timeIntervalSince(startedAt))
            responseText = error.localizedDescription
        }

        running = false
    }

    private func prettyResponse(from data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: pretty, encoding: .utf8) {
            return text
        }
        return String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
    }

    private static let defaultBody = """
    {
      "prompt": "请只读取项目结构，回复当前 App 入口文件和 HomeChatView 的作用。"
    }
    """
}
