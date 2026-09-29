// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-a1087f10890de6fa3ef2b811667f560c14e55c816ad6bc2cba159aba4ecca523"
// Source-SHA256: "32d6b66ccae5f94c96edd840931183ee6e50f5cde8ec4b9e0de0c9beb356c335"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation

// =======================================================
// GPT5ChatService+Streaming.swift
// ✅ Client for: POST /chat/prepare  +  GET /chat/events/{chat_id} (SSE)
// ✅ FIX: Don't rely on bytes.lines (can stall if no '\n' flush). Use byte parser.
// ✅ ADD: Photo upload helper: POST /upload -> ChatAttachment
// =======================================================

extension GPT5ChatService {

    struct StreamPrepareResult: Sendable {
        let chatId: String
        let userTranscript: String?
        let ttsURL: URL?
        let conversationId: String?
        let conversationTitle: String?
    }

    enum StreamEvent: Sendable {
        case delta(String)
        case final(String, String?, URL?)
        case sources([WebSource])
        case thinking(String)       // 推理模型等待中：进度文字（计时轮播）
        case reasoningDelta(String) // 推理模型：实时推理摘要文字
        case reasoningDone          // 推理完成，即将输出正式回复
        case done
        case error(String)
    }

    /// 透传给 SSE 调试日志的上下文（不影响请求本身）。
    struct StreamDebugInfo: Sendable {
        let plan: String
        let model: String
        let thinking: Bool
    }

    private func shouldEnableWebSearchForQuery(_ text: String) -> Bool {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return false }
        let lower = raw.lowercased()
        let compact = lower.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        let keywords = [
            "今天", "今日", "现在", "目前", "当前", "最新", "刚刚", "最近", "这几天", "近几天",
            "价格", "天气", "新闻", "消息", "官网", "发布", "发生", "查一下", "查下", "搜一下",
            "搜索", "联网", "浏览", "全网", "current", "latest", "today", "now", "news", "price",
            "weather", "search", "browse", "look up", "official"
        ]
        return keywords.contains { lower.contains($0) || compact.contains($0) }
    }

    // =======================================================
    // ✅ Photo Upload Helper
    // - Keeps your existing streaming interface untouched.
    // - Upload first, then pass attachment.id into prepareStream(attachments:).
    // =======================================================
    func uploadImage(
        apiBase: String,
        data: Data,
        mime: String = "image/jpeg",
        filename: String = "image.jpg"
    ) async throws -> ChatAttachment {

        guard let url = URL(string: apiBase + "/upload") else {
            throw NSError(domain: "GPT5ChatService.Upload", code: -20,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid URL: \(apiBase)/upload"])
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 180

        let boundary = "----SolaraBoundary\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        req.httpBody = body

        let (respData, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "GPT5ChatService.Upload", code: -21,
                          userInfo: [NSLocalizedDescriptionKey: "No HTTP response"])
        }
        guard (200..<300).contains(http.statusCode) else {
            let raw = String(data: respData, encoding: .utf8) ?? ""
            throw NSError(domain: "GPT5ChatService.Upload", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "upload failed \(http.statusCode): \(raw)"])
        }

        guard
            let obj = (try? JSONSerialization.jsonObject(with: respData)) as? [String: Any]
        else {
            let raw = String(data: respData, encoding: .utf8) ?? ""
            throw NSError(domain: "GPT5ChatService.Upload", code: -22,
                          userInfo: [NSLocalizedDescriptionKey: "upload non-JSON: \(raw)"])
        }

        // backend common return shapes:
        // { "id":"file_xxx", "url":"/files/xxx" } OR { "file_id":"..." }
        let id =
            (obj["id"] as? String)
            ?? (obj["file_id"] as? String)
            ?? (obj["fileId"] as? String)
            ?? ""

        if id.isEmpty {
            throw NSError(domain: "GPT5ChatService.Upload", code: -23,
                          userInfo: [NSLocalizedDescriptionKey: "upload missing id"])
        }

        // backend common return shapes:
        // - {"url":"/files/xxx"} or {"file_url":"/uploads/xxx.jpg"}
        // - {"path":"/abs/path/to/uploads/photo_xxx.jpg"} (server filesystem path)
        let urlStrRaw =
            (obj["url"] as? String)
            ?? (obj["file_url"] as? String)
            ?? (obj["fileUrl"] as? String)
            ?? (obj["path"] as? String)
            ?? (obj["file_path"] as? String)
            ?? (obj["filePath"] as? String)

        let urlTrimmed = urlStrRaw?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalURLString: String? = {
            guard let s = urlTrimmed, !s.isEmpty else { return nil }

            // If server returns an absolute filesystem path, keep it as-is.
            // (Backend will resolve it to UPLOADS_DIR; iOS UI can still render from the local preview UIImage.)
            if s.hasPrefix("/") && s.contains("/uploads/") && !s.hasPrefix("/uploads/") {
                return s
            }

            // Normal web URL or relative API path
            return resolve(apiBase: apiBase, urlString: s)?.absoluteString
        }()

        // ✅ IMPORTANT:
        // keep your existing attachment contract: type + id (+ optional mime/url)
        return ChatAttachment(type: "image", id: id, mime: mime, url: finalURLString)
    }

    // =======================================================
    // POST {apiBase}/chat/prepare
    // =======================================================
    func prepareStream(
        apiBase: String,
        model: String,
        messages: [LLMMessage],
        attachments: [ChatAttachment] = [],
        conversationId: String? = nil,
        clientId: String? = nil
    ) async throws -> StreamPrepareResult {

        guard let url = URL(string: apiBase + "/chat/prepare") else {
            throw NSError(domain: "GPT5ChatService.Streaming", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid URL: \(apiBase)/chat/prepare"])
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        if let cid = clientId, !cid.isEmpty {
            req.setValue(cid, forHTTPHeaderField: "X-Client-ID")
        }

        var payload: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            // keep compatibility if server uses it
            "stream": true
        ]

        let lastUserText = messages.reversed().first(where: { $0.role == "user" })?.content ?? ""
        let searchEnabled = shouldEnableWebSearchForQuery(lastUserText)
        payload["allow_web"] = true
        payload["search_enabled"] = searchEnabled
        payload["use_web_search"] = searchEnabled
        payload["web_search_enabled"] = searchEnabled
        payload["enable_web_search"] = searchEnabled
        payload["force_web_search"] = searchEnabled

        if let cid = conversationId, !cid.isEmpty {
            payload["conversation_id"] = cid
        }

        if !attachments.isEmpty {
            payload["attachments"] = attachments.map { a in
                var d: [String: Any] = ["type": a.type, "id": a.id]
                if let m = a.mime { d["mime"] = m }
                if let u = a.url { d["url"] = u }
                return d
            }
        }

        req.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "GPT5ChatService.Streaming", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "No HTTP response"])
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "GPT5ChatService.Streaming", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "prepare failed \(http.statusCode): \(body)"])
        }

        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "GPT5ChatService.Streaming", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "prepare non-JSON: \(raw)"])
        }

        let chatId = (obj["chat_id"] as? String) ?? (obj["chatId"] as? String) ?? ""
        if chatId.isEmpty {
            throw NSError(domain: "GPT5ChatService.Streaming", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "prepare missing chat_id"])
        }

        let transcript = (obj["user_transcript"] as? String) ?? (obj["transcript"] as? String)

        let ttsString =
            (obj["tts_url"] as? String)
            ?? (obj["ttsUrl"] as? String)
            ?? (obj["audio_url"] as? String)
            ?? (obj["audioUrl"] as? String)
            ?? (obj["speech_url"] as? String)
            ?? (obj["speechUrl"] as? String)

        let ttsURL = resolve(apiBase: apiBase, urlString: ttsString)

        let convId = (obj["conversation_id"] as? String) ?? (obj["conversationId"] as? String)
        let convTitle = (obj["conversation_title"] as? String) ?? (obj["conversationTitle"] as? String)
        return StreamPrepareResult(chatId: chatId, userTranscript: transcript, ttsURL: ttsURL, conversationId: convId, conversationTitle: convTitle)
    }

    // =======================================================
    // GET {apiBase}/chat/events/{chat_id}  (SSE)
    // =======================================================
    func streamEvents(apiBase: String, chatId: String, debug: StreamDebugInfo? = nil) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            // ✅ 30 秒"无 token 兜底"看门狗 + 最近响应体（调试用）共享状态。
            //    keepalive 不刷新 lastToken；只有真正的文本/推理 token 才刷新。
            let watch = StreamWatch()
            let endpoint = "\(apiBase)/chat/events/\(chatId)"

            func dbg(_ tag: String, _ extra: String = "") {
                let d = debug
                print("[ChatSSE][\(tag)] chat_id=\(chatId) endpoint=\(endpoint) "
                    + "plan=\(d?.plan ?? "-") model=\(d?.model ?? "-") thinking=\(d?.thinking == true) "
                    + "http_status=\(watch.status) \(extra)")
            }

            let readingTask = Task {
                do {
                    guard let url = URL(string: endpoint) else {
                        throw NSError(domain: "GPT5ChatService.Streaming", code: -10,
                                      userInfo: [NSLocalizedDescriptionKey: "Invalid URL: \(endpoint)"])
                    }

                    var req = URLRequest(url: url)
                    req.httpMethod = "GET"
                    req.timeoutInterval = 0
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                    req.setValue("keep-alive", forHTTPHeaderField: "Connection")

                    if let cid = UserDefaults.standard.string(forKey: "solara.client_id"), !cid.isEmpty {
                        req.setValue(cid, forHTTPHeaderField: "X-Client-ID")
                    }

                    dbg("open")

                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    guard let http = resp as? HTTPURLResponse else {
                        throw NSError(domain: "GPT5ChatService.Streaming", code: -11,
                                      userInfo: [NSLocalizedDescriptionKey: "No HTTP response"])
                    }
                    watch.setStatus(http.statusCode)
                    dbg("response")
                    guard (200..<300).contains(http.statusCode) else {
                        // 读取一小段 body 作为真实后端错误内容
                        var errBody = ""
                        for try await b in bytes {
                            errBody.append(Character(UnicodeScalar(b)))
                            if errBody.utf8.count > 2000 { break }
                        }
                        watch.setBody(errBody)
                        dbg("http_error", "last_body=\(errBody)")
                        let msg = errBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "events failed: HTTP \(http.statusCode)"
                            : errBody.trimmingCharacters(in: .whitespacesAndNewlines)
                        throw NSError(domain: "GPT5ChatService.Streaming", code: http.statusCode,
                                      userInfo: [NSLocalizedDescriptionKey: msg])
                    }

                    // ✅ 连接成功，开始计时（连接建立耗时不计入 30 秒兜底）
                    watch.touchToken()

                    // SSE state
                    var dataLines: [String] = []
                    var lastMetaTtsURL: URL? = nil
                    var lastTranscript: String? = nil

                    // ✅ Accumulate assistant text from deltas as a robust fallback
                    var builtText = ""

                    func flushEvent() {
                        guard !dataLines.isEmpty else { return }
                        let payload = dataLines.joined(separator: "\n")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        dataLines.removeAll(keepingCapacity: true)

                        if payload.isEmpty { return }

                        // ✅ 记录最近一条原始响应体（调试 last response body）
                        watch.setBody(payload)

                        // SSE servers sometimes send "[DONE]" sentinel
                        if payload == "[DONE]" {
                            continuation.yield(.final(builtText, lastTranscript, lastMetaTtsURL))
                            continuation.yield(.done)
                            return
                        }

                        // Parse JSON event
                        guard
                            let objAny = try? JSONSerialization.jsonObject(with: Data(payload.utf8)),
                            let obj = objAny as? [String: Any]
                        else {
                            // Non-JSON: ignore
                            return
                        }

                        let type = (obj["type"] as? String) ?? ""

                        // ✅ web_search sources for UI
                        // Server should emit: {"type":"solara.sources","sources":[{"title":"...","url":"..."}, ...]}
                        if type == "solara.sources" {
                            if let arr = obj["sources"] as? [[String: Any]] {
                                let sources: [WebSource] = arr.compactMap { d in
                                    let url = (d["url"] as? String) ?? ""
                                    if url.isEmpty { return nil }
                                    let title = (d["title"] as? String) ?? url
                                    return WebSource(title: title, url: url)
                                }
                                if !sources.isEmpty {
                                    continuation.yield(.sources(sources))
                                }
                            }
                            return
                        }

                        // capture tts_url from meta
                        if type == "solara.meta" {
                            let ttsStr = (obj["tts_url"] as? String) ?? (obj["ttsUrl"] as? String)
                            if let u = resolve(apiBase: apiBase, urlString: ttsStr) {
                                lastMetaTtsURL = u
                            }
                            return
                        }

                        // capture transcript if server sends it
                        if let tr = (obj["user_transcript"] as? String) ?? (obj["transcript"] as? String) {
                            let t = tr.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !t.isEmpty { lastTranscript = t }
                        }

                        if type == "response.output_text.delta" {
                            if let d = obj["delta"] as? String, !d.isEmpty {
                                builtText += d
                                watch.touchToken()   // ✅ 真正的 token，刷新兜底计时
                                continuation.yield(.delta(d))
                            }
                            return
                        }

                        // Some servers send done with optional "text". If absent, fallback to builtText.
                        if type == "response.output_text.done" {
                            let full = (obj["text"] as? String) ?? builtText
                            continuation.yield(.final(full, lastTranscript, lastMetaTtsURL))
                            continuation.yield(.done)
                            return
                        }

                        // If server only sends response.completed, we still must emit final+done.
                        if type == "response.completed" {
                            continuation.yield(.final(builtText, lastTranscript, lastMetaTtsURL))
                            continuation.yield(.done)
                            return
                        }

                        if type == "error" {
                            let msg: String
                            if let err = obj["error"] as? [String: Any] {
                                msg = (err["message"] as? String) ?? "unknown_error"
                            } else if let m = obj["message"] as? String {
                                msg = m
                            } else if let e = obj["error"] as? String {
                                msg = e
                            } else {
                                msg = "unknown_error"
                            }
                            dbg("backend_error", "msg=\(msg) last_body=\(payload)")
                            continuation.yield(.error(msg))
                            return
                        }

                        // ✅ keepalive：推理进度心跳。注意：keepalive 不刷新兜底计时（不算 token）。
                        if type == "solara.keepalive" {
                            continuation.yield(.thinking("深度推理中…"))
                            return
                        }

                        // ✅ reasoning delta：推理模型实时推理内容（真实 token，刷新兜底计时）
                        if type == "solara.reasoning_delta" {
                            if let d = obj["delta"] as? String, !d.isEmpty {
                                watch.touchToken()
                                continuation.yield(.reasoningDelta(d))
                            }
                            return
                        }

                        // ✅ reasoning done：推理完成，正式回复即将开始
                        if type == "solara.reasoning_done" {
                            continuation.yield(.reasoningDone)
                            return
                        }

                        // Ignore other event types
                    }

                    // -------------------------------------------------------
                    // ✅ Robust SSE reader: read bytes and split lines ourselves
                    // -------------------------------------------------------
                    var lineBuf = Data()

                    func handleLine(_ line: String) {
                        if line.isEmpty {
                            // empty line = end of one SSE event
                            flushEvent()
                            return
                        }
                        if line.hasPrefix(":") {
                            // comment/ping
                            return
                        }
                        if line.hasPrefix("data:") {
                            let v = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            dataLines.append(String(v))
                            return
                        }
                        // ignore: event:, id:, retry:
                    }

                    for try await b in bytes {
                        if Task.isCancelled { break }

                        if b == 10 { // \n
                            var ld = lineBuf
                            lineBuf.removeAll(keepingCapacity: true)

                            // remove trailing \r if present
                            if ld.last == 13 { ld.removeLast() }

                            let line = String(data: ld, encoding: .utf8) ?? ""
                            handleLine(line)
                        } else {
                            lineBuf.append(b)

                            // safety: avoid unlimited growth in pathological cases
                            if lineBuf.count > 1_000_000 {
                                lineBuf.removeAll(keepingCapacity: true)
                            }
                        }
                    }

                    // flush any remaining buffered line & last event
                    if !lineBuf.isEmpty {
                        if lineBuf.last == 13 { lineBuf.removeLast() }
                        let line = String(data: lineBuf, encoding: .utf8) ?? ""
                        handleLine(line)
                        lineBuf.removeAll()
                    }
                    flushEvent()

                    // Ensure terminal signals are emitted
                    continuation.yield(.final(builtText, lastTranscript, lastMetaTtsURL))
                    continuation.yield(.done)
                    continuation.finish()

                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    dbg("stream_error", "error=\(error.localizedDescription) last_body=\(watch.lastBody)")
                    continuation.finish(throwing: error)
                }
            }

            // ✅ 30 秒无 token 兜底看门狗。
            //    keepalive 不刷新计时；只有真实 token（delta / reasoning_delta）才刷新。
            //    一旦 30 秒无 token：cancel 当前流并向 UI 抛出真实提示。
            let watchdog = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { break }
                    if watch.idleSeconds > 30 {
                        dbg("token_timeout", "idle=\(Int(watch.idleSeconds))s last_body=\(watch.lastBody)")
                        readingTask.cancel()
                        continuation.finish(throwing: NSError(
                            domain: "GPT5ChatService.Streaming", code: -30,
                            userInfo: [NSLocalizedDescriptionKey:
                                "回复中断：30 秒未收到任何新内容，已停止等待。请重试。"]))
                        break
                    }
                }
            }

            continuation.onTermination = { _ in
                readingTask.cancel()
                watchdog.cancel()
            }

            // readingTask 正常结束后停掉看门狗，避免空转。
            Task {
                _ = await readingTask.value
                watchdog.cancel()
            }
        }
    }

    // Resolve relative/absolute URL strings returned by backend.
    private func resolve(apiBase: String, urlString: String?) -> URL? {
        guard let s = urlString?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if let u = URL(string: s), u.scheme != nil { return u }
        if s.hasPrefix("/") { return URL(string: apiBase + s) }
        return URL(string: apiBase + "/" + s)
    }
}

// =======================================================
// ✅ SSE 看门狗共享状态（线程安全）
//   - lastToken：最近一次"真实 token"时间（keepalive 不刷新）
//   - lastBody：最近一条原始响应体（调试用）
//   - status：HTTP status（调试用）
// =======================================================
private nonisolated final class StreamWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var _lastToken = Date()
    private var _lastBody = ""
    private var _status = -1

    func touchToken() { lock.lock(); _lastToken = Date(); lock.unlock() }
    func setBody(_ s: String) { lock.lock(); _lastBody = s; lock.unlock() }
    func setStatus(_ s: Int) { lock.lock(); _status = s; lock.unlock() }

    var idleSeconds: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(_lastToken)
    }
    var lastBody: String { lock.lock(); defer { lock.unlock() }; return _lastBody }
    var status: Int { lock.lock(); defer { lock.unlock() }; return _status }
}









