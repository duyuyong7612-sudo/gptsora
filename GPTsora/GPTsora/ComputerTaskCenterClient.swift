// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-426171f085ebe5b4da01f9cb6ae39a228e08c83477ae062f32db009a372b5f02"
// Source-SHA256: "6ba5877729ec323c170bdc0f1bb4dc2bddfa88c708e867978c7044c001cee1b8"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation
import Combine

struct ComputerTaskDTO: Codable, Identifiable {
    let task_id: String
    let user_id: String
    let text: String
    let source: String
    let status: String
    let risk_level: String
    let execution_mode: String
    let need_confirm: Bool
    let result: String
    let error: String
    let logs: [String]
    let created_at: Double
    let updated_at: Double
    let raw: [String: String]?

    var id: String { task_id }
}

struct ComputerTaskCreateResponse: Codable {
    let ok: Bool
    let task_id: String
    let status: String
    let need_confirm: Bool
    let risk_level: String
    let execution_mode: String
}

struct ComputerTaskGetResponse: Codable {
    let ok: Bool
    let task: ComputerTaskDTO
}

struct ComputerTaskListResponse: Codable {
    let ok: Bool
    let tasks: [ComputerTaskDTO]
}

@MainActor
final class ComputerTaskCenterClient: ObservableObject {
    @Published var tasks: [ComputerTaskDTO] = []
    @Published var activeTask: ComputerTaskDTO? = nil
    @Published var isLoading: Bool = false
    @Published var errorText: String = ""

    let apiBase: String
    let clientId: String

    init(apiBase: String, clientId: String) {
        self.apiBase = apiBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.clientId = clientId
    }

    func submitTask(_ text: String, source: String = "chat") async throws -> ComputerTaskCreateResponse {
        let url = URL(string: "\(apiBase)/computer/task")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(clientId, forHTTPHeaderField: "X-Client-ID")

        let payload: [String: Any] = [
            "text": text,
            "source": source,
            "client_id": clientId
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(
                domain: "ComputerTaskCenter",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No response"]
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "ComputerTaskCenter",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: raw]
            )
        }

        return try JSONDecoder().decode(ComputerTaskCreateResponse.self, from: data)
    }

    func confirmTask(_ id: String, approved: Bool) async throws {
        let url = URL(string: "\(apiBase)/computer/task/\(id)/confirm")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = ["approved": approved]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(
                domain: "ComputerTaskCenter",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "confirmTask failed"]
            )
        }
    }

    func fetchTask(_ id: String) async throws -> ComputerTaskDTO {
        let url = URL(string: "\(apiBase)/computer/task/\(id)")!
        let (data, resp) = try await URLSession.shared.data(from: url)

        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(
                domain: "ComputerTaskCenter",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "fetchTask failed"]
            )
        }

        let result = try JSONDecoder().decode(ComputerTaskGetResponse.self, from: data)
        activeTask = result.task
        return result.task
    }

    func refreshTasks() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let escaped = clientId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? clientId
            let url = URL(string: "\(apiBase)/computer/tasks?user_id=\(escaped)")!
            let (data, resp) = try await URLSession.shared.data(from: url)

            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw NSError(
                    domain: "ComputerTaskCenter",
                    code: -4,
                    userInfo: [NSLocalizedDescriptionKey: "refreshTasks failed"]
                )
            }

            let result = try JSONDecoder().decode(ComputerTaskListResponse.self, from: data)
            tasks = result.tasks
        } catch {
            errorText = error.localizedDescription
        }
    }

    func pollTask(_ id: String, interval: UInt64 = 1_000_000_000) async {
        while true {
            do {
                let task = try await fetchTask(id)
                await refreshTasks()

                if ["done", "error", "cancelled"].contains(task.status) {
                    break
                }
            } catch {
                errorText = error.localizedDescription
                break
            }

            try? await Task.sleep(nanoseconds: interval)
        }
    }
}
