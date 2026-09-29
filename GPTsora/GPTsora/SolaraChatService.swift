//
//  SolaraChatService.swift
//  GPTsora
//
//  ✅ 商用级（最高标准）网络层：
//  - 纯文本：/solara/chat（JSON，一次性）
//  - 图片+文本：/solara/photo（multipart，一次性）
//  - ✅ 真流式：/solara/chat_stream（SSE：event-stream，边收边出）
//  - ✅ 支持取消：停止生成（cancel stream task）
//  - ✅ 断尾修复：连接结束强制 flush 最后一个 frame
//  - ✅ session_id 线程安全（多处调用不会乱）
//  - ✅ 更强容错：服务端错误 body 解析、超时配置、弱网 waitsForConnectivity
//

// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-ce294bf8c19a754b526daa19a9a329f71a06238e800eecc16e5f2057c86c9afe"
// Source-SHA256: "64de1e14f74543f476ec6a8d98baf3fb0a674ead8c183909683d4eb6c2f7b39f"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation
import UIKit

// MARK: - 一条聊天消息（统一给整个 App 用）

struct SolaraChatMessage: Identifiable {
    enum Role { case user, assistant }

    let id = UUID()
    let role: Role
    var text: String
    var images: [UIImage]

    init(role: Role, text: String, images: [UIImage] = []) {
        self.role = role
        self.text = text
        self.images = images
    }
}

// MARK: - 网络服务（Singleton）

final class SolaraChatService {

    static let shared = SolaraChatService()
    private init() {
        // ✅ 商用级 URLSession 配置（弱网稳 + 超时合理）
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForRequest = 120         // 单次请求最长等待（可按你模型速度调）
        cfg.timeoutIntervalForResource = 300        // 整体资源最长（长输出更稳）
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.httpMaximumConnectionsPerHost = 6

        self.session = URLSession(configuration: cfg)
    }

    private let session: URLSession

    // ✅ 状态线程安全
    private let stateQueue = DispatchQueue(label: "solara.chat.service.state")
    private var _currentSessionID: String?
    private var _activeStreamTask: Task<Void, Never>?

    /// 当前会话 id（由后端返回，用于多轮对话）
    private func getSessionID() -> String? {
        stateQueue.sync { _currentSessionID }
    }

    private func setSessionID(_ sid: String?) {
        stateQueue.sync { _currentSessionID = sid }
    }

    /// 取消当前流式任务（停止生成）
    func cancelActiveStream() {
        let task: Task<Void, Never>? = stateQueue.sync {
            let t = _activeStreamTask
            _activeStreamTask = nil
            return t
        }
        task?.cancel()
    }

    // MARK: - Endpoints

    /// 文本聊天：FastAPI /solara/chat（JSON）
    private let chatURL: URL = {
        AppConfig.baseURL.appendingPathComponent("solara/chat")
    }()

    /// ✅ 流式文本：FastAPI /solara/chat_stream（SSE）
    /// 你需要后端实现：返回 Content-Type: text/event-stream
    /// 并发送：event: session/delta/done + data: ...
    private let chatStreamURL: URL = {
        AppConfig.baseURL.appendingPathComponent("solara/chat_stream")
    }()

    /// 照片 + 文本：FastAPI /solara/photo（multipart）
    private let photoURL: URL = {
        AppConfig.baseURL.appendingPathComponent("solara/photo")
    }()

    // MARK: - 公共入口：一次性（非流式）

    /// 发送文本 + 可选图片，返回助手回复文本（一次性）
    func send(text: String, images: [UIImage] = []) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty && images.isEmpty {
            throw NSError(
                domain: "SolaraChatService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "请输入内容或选择一张图片"]
            )
        }

        if images.isEmpty {
            return try await sendTextOnly(trimmed)
        } else {
            // 目前后端只接收单张 image_file，这里用第一张
            return try await sendPhotoWithNote(note: trimmed, image: images[0])
        }
    }

    // MARK: - ✅ 公共入口：流式（SSE）

    enum StreamEvent {
        case session(String)      // session_id
        case delta(String)        // 增量文本
        case done                 // 完成
        case error(String)        // 错误（不会 throw，直接事件回调）
    }

    /// ✅ 真流式发送（SSE）
    /// - 说明：
    ///   - 只对“纯文本”走真 SSE：/solara/chat_stream
    ///   - 如果带图片：暂时自动回退到一次性 /solara/photo（再把整段当成一个 delta 发出）
    /// - 返回：Task 句柄，UI 可保存并随时 cancel（实现“停止生成”）
    @discardableResult
    func sendStream(
        text: String,
        images: [UIImage] = [],
        cancelPrevious: Bool = true,
        onEvent: @escaping (StreamEvent) -> Void
    ) -> Task<Void, Never> {

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 既无文本又无图
        if trimmed.isEmpty && images.isEmpty {
            let t = Task { @MainActor in
                onEvent(.error("请输入内容或选择一张图片"))
                onEvent(.done)
            }
            return t
        }

        if cancelPrevious {
            cancelActiveStream()
        }

        // ✅ 若带图：先用一次性 photo 走通（后续你如果要真流式图文，再加 /solara/photo_stream）
        if !images.isEmpty {
            let task = Task {
                do {
                    let reply = try await self.send(text: trimmed, images: images)
                    await MainActor.run {
                        onEvent(.delta(reply))
                        onEvent(.done)
                    }
                } catch {
                    await MainActor.run {
                        onEvent(.error(error.localizedDescription))
                        onEvent(.done)
                    }
                }
            }
            stateQueue.sync { _activeStreamTask = task }
            return task
        }

        // ✅ 纯文本：走 SSE
        let task = Task {
            await self._runSSEStream(text: trimmed, onEvent: onEvent)
        }
        stateQueue.sync { _activeStreamTask = task }
        return task
    }

    // MARK: - 纯文本 -> /solara/chat（一次性 JSON）

    private func sendTextOnly(_ text: String) async throws -> String {
        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var payload: [String: Any] = ["text": text]
        if let sid = getSessionID(), !sid.isEmpty {
            payload["session_id"] = sid
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "SolaraChatService", code: -1000,
                          userInfo: [NSLocalizedDescriptionKey: "网络响应无效"])
        }

        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "SolaraChatService",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "服务器返回错误：\(http.statusCode)\n\(body.prefix(800))"]
            )
        }

        // 期待: { "ok": true, "reply": "...", "session_id": "xxx" }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let sid = json["session_id"] as? String, !sid.isEmpty {
                setSessionID(sid)
            }

            if let ok = json["ok"] as? Bool, !ok {
                let err = (json["error"] as? String) ?? "未知错误"
                throw NSError(domain: "SolaraChatService", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: err])
            }

            if let reply = json["reply"] as? String { return reply }
            if let reply = json["text"] as? String { return reply }
        }

        return String(data: data, encoding: .utf8) ?? "（服务器没有返回可读文本）"
    }

    // MARK: - 图片 + 说明 -> /solara/photo（一次性 multipart）

    private func sendPhotoWithNote(note: String, image: UIImage) async throws -> String {
        var request = URLRequest(url: photoURL)
        request.httpMethod = "POST"

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")

        // ✅ 商用：图片先修正方向 + 限边压缩，避免超大图导致慢/失败
        let jpegData = try prepareUploadJPEG(image, maxDimension: 1280, quality: 0.82)

        var body = Data()

        // 1) session_id（可为空）
        if let sid = getSessionID(), !sid.isEmpty {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"session_id\"\r\n\r\n")
            body.append(sid)
            body.append("\r\n")
        }

        // 2) note
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"note\"\r\n\r\n")
        body.append(note)
        body.append("\r\n")

        // 3) image_file
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"image_file\"; filename=\"upload.jpg\"\r\n")
        body.append("Content-Type: image/jpeg\r\n\r\n")
        body.append(jpegData)
        body.append("\r\n")

        // 结束边界
        body.append("--\(boundary)--\r\n")

        request.httpBody = body

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "SolaraChatService", code: -1000,
                          userInfo: [NSLocalizedDescriptionKey: "网络响应无效"])
        }

        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "SolaraChatService",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "服务器返回错误：\(http.statusCode)\n\(bodyText.prefix(800))"]
            )
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let sid = json["session_id"] as? String, !sid.isEmpty {
                setSessionID(sid)
            }

            if let ok = json["ok"] as? Bool, !ok {
                let err = (json["error"] as? String) ?? "未知错误"
                throw NSError(domain: "SolaraChatService", code: -4,
                              userInfo: [NSLocalizedDescriptionKey: err])
            }

            if let reply = json["reply"] as? String { return reply }
            if let reply = json["text"] as? String { return reply }
        }

        return String(data: data, encoding: .utf8) ?? "（服务器没有返回可读文本）"
    }

    // MARK: - ✅ SSE 实现（核心）

    private func _runSSEStream(
        text: String,
        onEvent: @escaping (StreamEvent) -> Void
    ) async {

        do {
            var request = URLRequest(url: chatStreamURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

            var payload: [String: Any] = ["text": text]
            if let sid = getSessionID(), !sid.isEmpty {
                payload["session_id"] = sid
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

            let (bytes, response) = try await session.bytes(for: request)

            guard let http = response as? HTTPURLResponse else {
                await MainActor.run {
                    onEvent(.error("网络响应无效"))
                    onEvent(.done)
                }
                return
            }

            guard (200..<300).contains(http.statusCode) else {
                // 尝试读一点错误文本（最多 2KB）
                var errText = ""
                do {
                    for try await line in bytes.lines {
                        errText += line + "\n"
                        if errText.count >= 2048 { break }
                    }
                } catch { /* ignore */ }

                await MainActor.run {
                    onEvent(.error("服务器返回错误：\(http.statusCode)\n\(errText.prefix(800))"))
                    onEvent(.done)
                }
                return
            }

            // SSE frame state
            var currentEvent: String? = nil
            var dataLines: [String] = []

            // ✅ flush：空行代表一个 frame 结束
            @Sendable func flushFrame() async {
                guard currentEvent != nil || !dataLines.isEmpty else { return }

                let ev = (currentEvent ?? "message").trimmingCharacters(in: .whitespacesAndNewlines)
                let data = dataLines.joined(separator: "\n")

                currentEvent = nil
                dataLines.removeAll(keepingCapacity: true)

                if data.isEmpty { return }

                // ✅ DONE 兼容：event=done 或 data=[DONE]
                if ev == "done" || data == "[DONE]" {
                    await MainActor.run { onEvent(.done) }
                    return
                }

                // ✅ session：data 是 JSON {"session_id":"..."}
                if ev == "session" {
                    if let sid = parseSessionId(from: data), !sid.isEmpty {
                        setSessionID(sid)
                        await MainActor.run { onEvent(.session(sid)) }
                    }
                    return
                }

                // ✅ delta：data 可能是纯文本，也可能是 JSON（更强容错）
if ev == "delta" || ev == "message" || ev == "text" {
    if let (sidMaybe, deltaMaybe, isDone) = parseDeltaPayload(from: data) {
        if let sid = sidMaybe, !sid.isEmpty {
            setSessionID(sid)
            await MainActor.run { onEvent(.session(sid)) }
        }
        if let delta = deltaMaybe, !delta.isEmpty {
            await MainActor.run { onEvent(.delta(delta)) }
        }
        if isDone == true {
            await MainActor.run { onEvent(.done) }
        }
        return
    } else {
        // ✅ 如果 data 是 JSON 但没有 delta（例如 {"chat_id":...,"tts_url":...}），不要把 JSON 原样显示到 UI
        if data.first == "{",
           let d = data.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {

            // error
            if let err = (obj["error"] as? String) ?? (obj["message"] as? String),
               !err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await MainActor.run { onEvent(.error(err)) }
                await MainActor.run { onEvent(.done) }
                return
            }

            // session id (optional)
            if let sid = (obj["session_id"] as? String) ?? (obj["sid"] as? String),
               !sid.isEmpty {
                setSessionID(sid)
                await MainActor.run { onEvent(.session(sid)) }
            }

            // delta (if present)
            if let delta = (obj["delta"] as? String) ?? (obj["content_delta"] as? String),
               !delta.isEmpty {
                await MainActor.run { onEvent(.delta(delta)) }
                return
            }

            // final text
            if let text = (obj["text"] as? String) ?? (obj["reply"] as? String) ?? (obj["output_text"] as? String),
               !text.isEmpty {
                await MainActor.run { onEvent(.delta(text)) }
                await MainActor.run { onEvent(.done) }
                return
            }

            // done flag
            if let done = obj["done"] as? Bool, done == true {
                await MainActor.run { onEvent(.done) }
                return
            }

            // control/meta JSON (chat_id/tts_url/tts_id/model/...) -> ignore
            return
        }

        // 纯文本
        await MainActor.run { onEvent(.delta(data)) }
        return
    }
}

                // 其它 event：当作 delta 兜底
                await MainActor.run { onEvent(.delta(data)) }
            }

            // ✅ 逐行读取（iOS 会处理 UTF-8 拆包，不会丢字）
            for try await line in bytes.lines {
                try Task.checkCancellation()

                // ✅ sanitize (strip BOM / trim) to make NDJSON detection reliable
                let rawLine = line.replacingOccurrences(of: "\u{FEFF}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)

// ✅ NDJSON compatibility (newline-delimited JSON without SSE framing)
if rawLine.first == "{" {
    if let d = rawLine.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {

        if let sid = (obj["session_id"] as? String) ?? (obj["sid"] as? String),
           !sid.isEmpty {
            setSessionID(sid)
            await MainActor.run { onEvent(.session(sid)) }
        }

        if let delta = (obj["delta"] as? String) ?? (obj["content_delta"] as? String),
           !delta.isEmpty {
            await MainActor.run { onEvent(.delta(delta)) }
        } else if let text = (obj["text"] as? String) ?? (obj["reply"] as? String) ?? (obj["output_text"] as? String),
                  !text.isEmpty {
            // treat as final text
            await MainActor.run { onEvent(.delta(text)) }
            await MainActor.run { onEvent(.done) }
            return
        }

        if let done = obj["done"] as? Bool, done == true {
            await MainActor.run { onEvent(.done) }
            return
        }

        if let err = (obj["error"] as? String) ?? (obj["message"] as? String), !err.isEmpty {
            await MainActor.run { onEvent(.error(err)) }
            await MainActor.run { onEvent(.done) }
            return
        }

        continue
    }
}

                // 空行：frame 结束
                if rawLine.isEmpty {
                    await flushFrame()
                    continue
                }

                // 忽略注释行
                if rawLine.hasPrefix(":") { continue }

                if rawLine.hasPrefix("event:") {
                    currentEvent = rawLine.dropPrefix("event:").trimmed
                    continue
                }

                if rawLine.hasPrefix("data:") {
                    let v = rawLine.dropPrefix("data:").dropLeadingSpace
                    dataLines.append(v)
                    continue
                }

                // 兼容：后端没按 SSE 标准写字段，直接输出裸行
                dataLines.append(rawLine)
            }

            // ✅ 连接结束：强制 flush（修复断尾）
            await flushFrame()

            // 若后端没显式 done，仍然保证回调 done（避免 UI 卡在“生成中”）
            await MainActor.run { onEvent(.done) }

        } catch is CancellationError {
            // 用户主动停止：不当成错误
            await MainActor.run { onEvent(.done) }
        } catch {
            await MainActor.run {
                onEvent(.error(error.localizedDescription))
                onEvent(.done)
            }
        }
    }

    // MARK: - 解析 SSE payload（更强容错）

    /// 解析 session_id（data 可能是 JSON，也可能是纯文本 sid）
    private func parseSessionId(from data: String) -> String? {
        // JSON: {"session_id":"xxx"}
        if let d = data.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            if let sid = obj["session_id"] as? String { return sid }
            if let sid = obj["sid"] as? String { return sid }
        }

        // 纯文本：sid_xxx
        if data.lowercased().hasPrefix("sid") { return data }
        return nil
    }

    /// 解析 delta JSON 的更强容错：
    /// 可能格式：
    /// 1) {"delta":"..."}
    /// 2) {"text":"..."}
    /// 3) {"reply":"..."}
    /// 4) {"session_id":"...","delta":"...","done":false}
    /// 返回：(session_id?, deltaText?, done?)
    private func parseDeltaPayload(from data: String) -> (String?, String?, Bool?)? {
        guard data.first == "{", let d = data.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }

        let sid = (obj["session_id"] as? String) ?? (obj["sid"] as? String)
        let delta = (obj["delta"] as? String) ?? (obj["text"] as? String) ?? (obj["reply"] as? String)
        let done = obj["done"] as? Bool

        // 如果什么都没有，就不认为是 delta json
        if sid == nil && delta == nil && done == nil { return nil }
        return (sid, delta, done)
    }

    // MARK: - 图片压缩（商用级）

    private func prepareUploadJPEG(_ image: UIImage, maxDimension: CGFloat, quality: CGFloat) throws -> Data {
        let fixed = image.fixedOrientation()

        let resized = fixed.resized(maxDimension: maxDimension)
        guard let jpeg = resized.jpegData(compressionQuality: quality) else {
            throw NSError(domain: "SolaraChatService", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "图片编码失败"])
        }
        return jpeg
    }
}

// MARK: - Data append

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) { append(data) }
    }
}

// MARK: - String helpers

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    func dropPrefix(_ prefix: String) -> String {
        guard hasPrefix(prefix) else { return self }
        return String(dropFirst(prefix.count))
    }

    var dropLeadingSpace: String {
        if hasPrefix(" ") { return String(dropFirst()) }
        return self
    }
}

// MARK: - UIImage helpers（方向修正 + 缩放）

private extension UIImage {

    /// 修正图片方向（避免某些设备上传后旋转）
    func fixedOrientation() -> UIImage {
        if imageOrientation == .up { return self }

        UIGraphicsBeginImageContextWithOptions(size, false, scale)
        defer { UIGraphicsEndImageContext() }

        draw(in: CGRect(origin: .zero, size: size))
        return UIGraphicsGetImageFromCurrentImageContext() ?? self
    }

    /// 限边缩放（最长边不超过 maxDimension）
    func resized(maxDimension: CGFloat) -> UIImage {
        let w = size.width
        let h = size.height
        let maxSide = max(w, h)

        guard maxSide > maxDimension, maxSide > 0 else { return self }

        let ratio = maxDimension / maxSide
        let newSize = CGSize(width: floor(w * ratio), height: floor(h * ratio))

        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            self.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}






