//
//  HexapodRobotService.swift
//  阿杜六足机器人 v1 后端客户端
//
//  统一调用 ChatAGI 后端 (AppConfig.API.apiBase) 的机器人接口：
//    GET  /api/adu/robot/hexapod/status
//    POST /api/adu/robot/hexapod/command
//    POST /api/adu/robot/hexapod/plan
//  后端再转发到 8081 六足底层桥。先不做录音/实时语音/Wi-Fi。
//

// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-c3336657378572cbf55fdca8d634a70f9bf68e3e530875a8ffa831ca948cd2ce"
// Source-SHA256: "98e75d93959def457a4aa742b057ee6e68159e15f18a425f7bdfcb7bba6e6028"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation
import SwiftUI
import Combine

// MARK: - Models

struct HexapodAction: Codable, Identifiable {
    var id = UUID()
    var cmd: String
    var duration_ms: Int?
    enum CodingKeys: String, CodingKey { case cmd, duration_ms }
}

typealias HexAction = HexapodAction

struct HexapodScene: Codable {
    var caption: String?
    var objects: [String]?
    var vision_decision: String?
    var person_visible: Bool?
    var person_position: String?
    var obstacle_front: Bool?
    var door_visible: Bool?
    var floor_unclear: Bool?
    var free_space: String?
    var confidence: Double?
}

struct HexapodPerceptionRequest: Codable {
    var goal: String
    var transcript: String
    var scene: HexapodScene
    var execute: Bool
}

typealias HexapodPerceptionTickRequest = HexapodPerceptionRequest

struct HexapodPerceptionResponse: Codable {
    var ok: Bool
    var skill_id: String?
    var actions: [HexapodAction]?
    var after_action_say: String?
    var executed: Bool?
    var continue_loop: Bool?
    var next_tick_after_ms: Int?
    var error: String?
}

struct HexResponse: Codable {
    let ok: Bool?
    let skill_id: String?
    let source: String?
    let text: String?
    let say: String?
    let after_action_say: String?
    let actions: [HexapodAction]?
    let need_confirm: Bool?
    let executed: Bool?
    let plan_only: Bool?
    let message: String?
    let cmd: String?
    let continue_loop: Bool?
    let next_tick_after_ms: Int?
}

struct HexLowlevel: Codable {
    let ok: Bool?
    let dry_run: Bool?
    let transport_default: String?
    let serial_connected: Bool?
    let port: String?
}

struct HexStatus: Codable {
    let ok: Bool?
    let mode: String?
    let lowlevel_reachable: Bool?
    let lowlevel: HexLowlevel?
}

// MARK: - Service

@MainActor
final class HexapodRobotService: ObservableObject {
    @Published var connected: Bool = false
    @Published var transport: String = "—"
    @Published var dryRun: Bool? = nil
    @Published var statusLine: String = "未连接"

    private var base: String { AppConfig.API.apiBase }

    /// GET /status —— 刷新连接状态 / transport / dry_run
    func refreshStatus() async {
        do {
            let s: HexStatus = try await getJSON(path: "/api/adu/robot/hexapod/status")
            connected = (s.lowlevel_reachable ?? false)
            transport = s.lowlevel?.transport_default ?? "—"
            dryRun = s.lowlevel?.dry_run
            let dr = dryRun.map { $0 ? "dry_run" : "real" } ?? "?"
            statusLine = connected ? "已连接 · \(transport) · \(dr)"
                                   : "后端可达，但底层 8081 未就绪"
        } catch {
            connected = false
            transport = "—"
            dryRun = nil
            statusLine = "无法连接后端：\(error.localizedDescription)"
        }
    }

    /// POST /command —— 单原语 / BOOT_STAND / STOP
    func command(_ cmd: String) async -> HexResponse? {
        try? await postJSON(path: "/api/adu/robot/hexapod/command", body: ["cmd": cmd])
    }

    /// POST /plan —— execute=false 预览(plan_only)，execute=true 执行
    func plan(text: String, execute: Bool) async throws -> HexResponse {
        try await postJSON(path: "/api/adu/robot/hexapod/plan",
                           body: ["text": text, "plan_only": !execute, "execute": execute])
    }

    /// POST /perception_tick —— 视觉场景 + transcript → 动作预览/执行。
    func sendPerceptionTick(goal: String, transcript: String, scene: HexapodScene, execute: Bool) async throws -> HexapodPerceptionResponse {
        let req = HexapodPerceptionRequest(
            goal: goal,
            transcript: transcript,
            scene: scene,
            execute: execute
        )
        return try await postCodableJSON(path: "/api/adu/robot/hexapod/perception_tick", body: req)
    }

    func sendAutonomousTick(goal: String, transcript: String, scene: HexapodScene, execute: Bool) async throws -> HexapodPerceptionResponse {
        let req = HexapodPerceptionRequest(
            goal: goal,
            transcript: transcript,
            scene: scene,
            execute: execute
        )
        return try await postCodableJSON(path: "/api/adu/robot/hexapod/autonomous_tick", body: req)
    }

    func sendStop() async throws {
        _ = try await postJSON(path: "/api/adu/robot/hexapod/command", body: ["cmd": "STOP"])
    }

    func getStatus() async throws -> HexStatus {
        try await getJSON(path: "/api/adu/robot/hexapod/status")
    }

    // MARK: - HTTP helpers

    private func getJSON<T: Decodable>(path: String) async throws -> T {
        guard let url = URL(string: base + path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func postJSON(path: String, body: [String: Any]) async throws -> HexResponse {
        guard let url = URL(string: base + path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(HexResponse.self, from: data)
    }

    private func postJSON<T: Encodable>(path: String, body: T) async throws -> HexResponse {
        guard let url = URL(string: base + path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        req.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(HexResponse.self, from: data)
    }

    private func postCodableJSON<T: Encodable, R: Decodable>(path: String, body: T) async throws -> R {
        guard let url = URL(string: base + path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        req.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(R.self, from: data)
    }
}
