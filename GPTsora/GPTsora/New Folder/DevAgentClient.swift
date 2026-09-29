// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-42804160437a7e652db68b13f529e98311aa852cb541f390a4eb192ef1cf8ebd"
// Source-SHA256: "8f6919b00d88cab382cd424f977a067c4b14f1480ed1b12ebf31c6973ee06406"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation
import Combine

// Dev Agent V1 — 只读 Claude Code 客户端
// App → backend /api/brain/dev_agent/* → local-agent :4317 /dev_agent/* → claude CLI → ~/Desktop/GPTsora

struct DevAgentHealth: Codable {
    let ok: Bool
    let claude_installed: Bool?
    let claude_version: String?
    let claude_bin: String?
    let project_dir: String?
    let project_exists: Bool?
    let timeout_sec: Double?
    let max_turns: String?
}

struct DevAgentResponse: Codable {
    let ok: Bool
    let project: String?
    let mode: String?
    let output: String
    let elapsed_ms: Int?
    let error: String?
}

@MainActor
final class DevAgentClient: ObservableObject {
    let backendBase: String

    /// V1 阶段只允许这个项目；后端硬校验。
    private let project: String = "GPTsora"

    init(backendBase: String) {
        self.backendBase = backendBase
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    func health() async -> DevAgentHealth? {
        guard let url = URL(string: "\(backendBase)/api/brain/dev_agent/health") else { return nil }
        var req = AccountManager.makeAuthorizedRequest(url)
        req.timeoutInterval = 8
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return try JSONDecoder().decode(DevAgentHealth.self, from: data)
        } catch {
            return nil
        }
    }

    /// 提问。后端会自动加安全前缀，并跑 claude -p --permission-mode plan --max-turns 3。
    func ask(prompt: String, timeoutMs: Int = 100_000) async throws -> DevAgentResponse {
        guard let url = URL(string: "\(backendBase)/api/brain/dev_agent/ask") else {
            throw NSError(domain: "DevAgent", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "URL 无效"])
        }
        var req = AccountManager.makeAuthorizedRequest(url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = TimeInterval(timeoutMs / 1000) + 15

        let payload: [String: Any] = [
            "project": project,
            "prompt": prompt,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "DevAgent", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "无响应"])
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "DevAgent", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) \(body)"])
        }
        return try JSONDecoder().decode(DevAgentResponse.self, from: data)
    }
}
