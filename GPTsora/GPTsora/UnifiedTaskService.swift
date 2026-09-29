//
//  UnifiedTaskService.swift
//  GPTsora
//
//  统一任务服务 (Unified Task Service)
//  -----------------------------------
//  所有输入源都通过这里进入后端的单一入口：
//      POST {apiBase}/api/adu/unified/input
//
//  设计原则（与后端 routers/unified_input.py 对齐）：
//  - 电脑控制：source=computer_button / surface=computer / intent_hint=computer_control
//    requires_computer=true —— 后端只会经 ComputerGateway -> local_agent:4317 执行。
//  - 自动化编程：source=coding_button / surface=coding / intent_hint=coding
//    requires_code_agent=true。编程任务如需操作电脑，仍由后端 ComputerGateway 处理，
//    前端不直连任何 ComputerService。
//  - 机器人：source=robot_button / surface=robot / intent_hint=robot —— 不直接控制电脑。
//  - 文本 / 录音 / 实时语音 / 图片 / 视频 都走同一个 sendUnified()。
//
//  注意：这是新增的统一封装，旧的 ComputerTaskCenterClient / 各 Service 暂不删除，
//  但新前端入口应只调用本服务。
//

// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-cac77bacf16e0cbdc4905f35de92aa3c8fdf741e985a109c6386b3232f7498c1"
// Source-SHA256: "a75cd5a0c8f95030ca92309f40b828cee8995db2f744f9385216b7cd06ed588f"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation

// MARK: - 结果模型

/// 统一返回：保留后端原始 JSON，便于上层按 route 处理。
public struct UnifiedResult {
    public let ok: Bool
    public let route: String          // chat | computer | coding | media | voice
    public let raw: [String: Any]     // 后端完整响应
    public let statusCode: Int
}

public enum UnifiedTaskError: Error {
    case badURL
    case transport(Error)
    case http(Int, String)
    case decode
}

// MARK: - 服务

public final class UnifiedTaskService {

    public static let shared = UnifiedTaskService()

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// 统一入口地址
    private var endpoint: URL? {
        URL(string: "\(AppConfig.API.apiBase)/api/adu/unified/input")
    }

    // MARK: - 高层便捷方法

    /// 普通文本聊天
    @discardableResult
    public func sendText(
        _ text: String,
        sessionId: String? = nil,
        userId: String? = nil
    ) async throws -> UnifiedResult {
        try await sendUnified(
            source: "text",
            surface: "home",
            text: text,
            intentHint: "chat",
            sessionId: sessionId,
            userId: userId
        )
    }

    /// 录音（客户端完成 STT 后传入文本；若仅有引用可传 mediaRefs）
    @discardableResult
    public func sendRecordedAudio(
        transcript: String,
        mediaRefs: [String] = [],
        sessionId: String? = nil,
        userId: String? = nil
    ) async throws -> UnifiedResult {
        try await sendUnified(
            source: "recorded_audio",
            surface: "voice",
            text: transcript,
            mediaRefs: mediaRefs,
            intentHint: "chat",
            sessionId: sessionId,
            userId: userId
        )
    }

    /// 实时语音事件（转写文本或事件摘要）
    @discardableResult
    public func sendRealtimeVoiceEvent(
        text: String,
        sessionId: String? = nil,
        userId: String? = nil
    ) async throws -> UnifiedResult {
        try await sendUnified(
            source: "realtime_voice",
            surface: "voice",
            text: text,
            intentHint: "chat",
            requiresRealtime: true,
            sessionId: sessionId,
            userId: userId
        )
    }

    /// 电脑控制（首页唯一“电脑控制”入口应调这里）
    /// - Parameters:
    ///   - text: 自然语言指令（只读动作如“截屏”可被识别）
    ///   - action: 显式动作 health/screenshot/click/type/paste/press/mouse_move/active_window
    ///   - payload: 动作参数（如 click 的 {"x":100,"y":200}）
    @discardableResult
    public func sendComputerModeCommand(
        text: String = "",
        source: String = "computer_button",
        action: String? = nil,
        payload: [String: Any]? = nil,
        requiresRealtime: Bool = false,
        sessionId: String? = nil,
        userId: String? = nil
    ) async throws -> UnifiedResult {
        try await sendUnified(
            source: source,
            surface: "computer",
            text: text,
            intentHint: "computer_control",
            requiresComputer: true,
            requiresRealtime: requiresRealtime,
            action: action,
            payload: payload,
            sessionId: sessionId,
            userId: userId
        )
    }

    /// 自动化编程任务
    @discardableResult
    public func sendCodingTask(
        _ task: String,
        projectId: String? = nil,
        projectDir: String? = nil,
        engine: String? = nil,
        model: String? = nil,
        sessionId: String? = nil,
        userId: String? = nil
    ) async throws -> UnifiedResult {
        try await sendUnified(
            source: "coding_button",
            surface: "coding",
            text: task,
            intentHint: "coding",
            requiresCodeAgent: true,
            projectId: projectId,
            projectDir: projectDir,
            engine: engine,
            model: model,
            sessionId: sessionId,
            userId: userId
        )
    }

    /// 图片/视频任务（先上传形成 mediaRefs，再走统一入口）
    @discardableResult
    public func sendMediaTask(
        text: String = "",
        mediaRefs: [String],
        isVideo: Bool = false,
        sessionId: String? = nil,
        userId: String? = nil
    ) async throws -> UnifiedResult {
        try await sendUnified(
            source: isVideo ? "video" : "image",
            surface: "media",
            text: text,
            mediaRefs: mediaRefs,
            intentHint: "chat",
            sessionId: sessionId,
            userId: userId
        )
    }

    // MARK: - 底层统一发送

    @discardableResult
    public func sendUnified(
        source: String,
        surface: String,
        text: String = "",
        mediaRefs: [String] = [],
        intentHint: String? = nil,
        requiresComputer: Bool = false,
        requiresCodeAgent: Bool = false,
        requiresRealtime: Bool = false,
        action: String? = nil,
        payload: [String: Any]? = nil,
        projectId: String? = nil,
        projectDir: String? = nil,
        engine: String? = nil,
        model: String? = nil,
        sessionId: String? = nil,
        userId: String? = nil
    ) async throws -> UnifiedResult {
        guard let url = endpoint else { throw UnifiedTaskError.badURL }

        var body: [String: Any] = [
            "source": source,
            "surface": surface,
            "text": text,
            "media_refs": mediaRefs,
            "requires_computer": requiresComputer,
            "requires_code_agent": requiresCodeAgent,
            "requires_realtime": requiresRealtime,
        ]
        if let intentHint { body["intent_hint"] = intentHint }
        if let action { body["action"] = action }
        if let payload { body["payload"] = payload }
        if let projectId { body["project_id"] = projectId }
        if let projectDir { body["project_dir"] = projectDir }
        if let engine { body["engine"] = engine }
        if let model { body["model"] = model }
        if let sessionId { body["session_id"] = sessionId }
        if let userId { body["user_id"] = userId }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let userId { req.setValue(userId, forHTTPHeaderField: "x-user-id") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw UnifiedTaskError.transport(error)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        if status >= 400 && json.isEmpty {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw UnifiedTaskError.http(status, bodyStr)
        }

        let ok = (json["ok"] as? Bool) ?? (status < 400)
        let route = (json["route"] as? String) ?? "chat"
        return UnifiedResult(ok: ok, route: route, raw: json, statusCode: status)
    }
}
