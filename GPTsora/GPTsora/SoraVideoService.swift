// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-aa66157f3b30d6e209ae7720d5eb48131100a25a794bae314921c536233c7ad7"
// Source-SHA256: "b25c5c4d50a7e079a50edc8fd7107d0c6e74816eb549730fa84bcba09593b23b"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Job / Status（和后端 /video /video/status 对齐 + 扩展 openaiVideoId）

struct SoraJob {
    let id: String                 // 你后端的 job_id（队列任务 ID）
    let statusURL: URL

    /// ✅ OpenAI Video ID（video_xxx）——用于回放绑定 & remix 输入
    let openaiVideoId: String?
    let remixedFromVideoId: String?
}

struct SoraJobStatus {
    let status: String        // running / in_progress / done / completed / failed / cancelled
    let progress: Int?        // 0~100
    let url: String?          // 你的后端可能给 stream url / cdn url
    let error: String?

    /// ✅ 由状态接口返回（server authoritative）
    let openaiVideoId: String?
    let remixedFromVideoId: String?

    var isDone: Bool {
        let s = status.lowercased()
        return s == "done" || s == "completed" || s == "succeeded" || s == "success"
    }

    var isRunning: Bool {
        let s = status.lowercased()
        return s == "running" || s == "in_progress" || s == "processing" || s == "queued"
    }

    var isFailed: Bool {
        let s = status.lowercased()
        return s == "failed" || s == "cancelled" || s == "canceled" || s == "error"
    }

    static func from(json: [String: Any]) -> SoraJobStatus {
        let rawStatus =
            (json["status"] as? String) ??
            (json["state"] as? String) ??
            ((json["object"] as? String) == "error" ? "failed" : "unknown")

        let progress: Int? = {
            if let p = json["progress"] as? NSNumber { return p.intValue }
            if let p = json["progress"] as? Int { return p }
            if let p = json["percentage"] as? NSNumber { return p.intValue }
            if let p = json["percentage"] as? Int { return p }
            return nil
        }()

        // 兼容多种结构拿 url
        var url: String?
        if let s = json["url"] as? String { url = s }
        if url == nil, let s = json["video_url"] as? String { url = s }
        if url == nil, let output = json["output"] as? [String: Any],
           let s = output["url"] as? String { url = s }
        if url == nil, let assets = json["assets"] as? [String: Any],
           let s = assets["video"] as? String { url = s }
        if url == nil, let data = json["data"] as? [[String: Any]],
           let first = data.first,
           let s = first["url"] as? String { url = s }

        let error: String? = {
            if let errStr = json["error"] as? String { return errStr }
            if let err = json["error"] { return String(describing: err) }
            return nil
        }()

        // ✅ 只信“明确字段”，不要把 job_id / uuid 当 openai video id
        let openaiVideoId: String? = {
            if let s = json["openai_video_id"] as? String { return s }
            if let s = json["openaiVideoId"] as? String { return s }
            if let s = json["video_id"] as? String { return s }
            if let s = json["videoId"] as? String { return s }
            if let s = json["openai_id"] as? String { return s }
            return nil
        }()

        let remixedFrom: String? = {
            if let s = json["remixed_from_video_id"] as? String { return s }
            if let s = json["remixedFromVideoId"] as? String { return s }
            if let s = json["remix_base_video_id"] as? String { return s }
            return nil
        }()

        return SoraJobStatus(
            status: rawStatus,
            progress: progress,
            url: url,
            error: error,
            openaiVideoId: openaiVideoId,
            remixedFromVideoId: remixedFrom
        )
    }
}

// MARK: - 最终结果（给 VideoJobManager / VideoLibraryStore 落库）

struct SoraVideoResult {
    let localURL: URL
    let jobId: String
    let openaiVideoId: String?
    let remixedFromVideoId: String?
    let finalRemoteURL: URL?
}

// MARK: - Errors（更可控、更可读）

enum SoraVideoServiceError: LocalizedError {
    case missingOrInvalidConfirmToken
    case remixRequestMissingBaseVideoId
    case remixRequestMissingInstruction
    case invalidRemoteURL(String)
    case httpError(Int, String)
    case invalidResponse(String)
    case statusTimeout
    case remixRouteNotFound

    var errorDescription: String? {
        switch self {
        case .missingOrInvalidConfirmToken:
            return "未收到最终确认口令（客户已确定），为防误触发已阻止生成。"
        case .remixRequestMissingBaseVideoId:
            return "Remix 请求缺少 base_video_id。"
        case .remixRequestMissingInstruction:
            return "Remix 请求缺少 user_instruction。"
        case .invalidRemoteURL(let s):
            return "无效的视频下载地址：\(s)"
        case .httpError(let code, let body):
            return "网络错误 HTTP \(code)：\(body)"
        case .invalidResponse(let body):
            return "后端返回格式不正确：\(body)"
        case .statusTimeout:
            return "生成超时（status timeout）"
        case .remixRouteNotFound:
            return "后端未实现 /video/remix（404）"
        }
    }
}

// MARK: - Sora 服务封装（上架冲刺：上传不吃内存，轮询不抖）

final class SoraVideoService {
    static let shared = SoraVideoService()

    // ✅ 统一“最终确认口令”（前端只在用户最后确认后才发送）
    // 建议后端也做严格等值校验，杜绝语义误判
    static let confirmTokenPrimary = "客户已确定"

    private let session: URLSession
    private let baseURL: URL

    init(session: URLSession = .shared) {
        if session === URLSession.shared {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 600
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.waitsForConnectivity = true
            self.session = URLSession(configuration: config)
        } else {
            self.session = session
        }
        self.baseURL = AppConfig.baseURL
    }

    // MARK: - 兼容老接口：一步到位：创建 Job + 轮询 + 下载到本地（旧签名不改）
    @discardableResult
    func startAndWait(
        prompt: String,
        imageFileURL: URL? = nil,
        videoFileURL: URL? = nil,
        audioFileURL: URL? = nil,
        pollStep: TimeInterval = 2.0,
        timeoutSeconds: TimeInterval = 600.0,
        onProgress: ((Int) -> Void)? = nil
    ) async throws -> URL {
        let r = try await startAndWaitEx(
            prompt: prompt,
            imageFileURL: imageFileURL,
            videoFileURL: videoFileURL,
            audioFileURL: audioFileURL,
            userConfirmText: nil,
            pollStep: pollStep,
            timeoutSeconds: timeoutSeconds,
            onProgress: onProgress
        )
        return r.localURL
    }

    // MARK: - ✅ 新接口：返回 openaiVideoId（用于回放绑定/二次生成）
    // ✅ 升级：若 prompt 含 [REMIX_REQUEST] -> 自动走 /video/remix 且强制确认口令
    @discardableResult
    func startAndWaitEx(
        prompt: String,
        imageFileURL: URL? = nil,
        videoFileURL: URL? = nil,
        audioFileURL: URL? = nil,
        userConfirmText: String? = nil,
        pollStep: TimeInterval = 2.0,
        timeoutSeconds: TimeInterval = 600.0,
        onProgress: ((Int) -> Void)? = nil
    ) async throws -> SoraVideoResult {

        try Task.checkCancellation()

        // ✅ Remix 自动识别：只要 prompt 里含 REMIX_REQUEST，就严格走 /video/remix
        if let remix = parseRemixRequest(from: prompt) {
            let confirm = remix.userConfirmText ?? userConfirmText
            let confirmed = try requireConfirmed(confirm)

            let job = try await createRemixJob(
                baseVideoId: remix.baseVideoId,
                userInstruction: remix.userInstruction,
                userConfirmText: confirmed
            )

            try Task.checkCancellation()

            let status = try await waitForStatusDone(
                jobId: job.id,
                statusURL: job.statusURL,
                interval: max(0.8, pollStep),
                maxSeconds: timeoutSeconds,
                onProgress: onProgress
            )

            try Task.checkCancellation()

            if status.isFailed {
                throw NSError(domain: "SoraVideoService", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: status.error ?? "Sora job failed"])
            }

            let remoteUrlString: String = {
                if var u = status.url?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !u.isEmpty {
                    if !u.hasPrefix("http") { u = absoluteUrl(from: u) }
                    return u
                }
                return baseURL.appendingPathComponent("video/stream/\(job.id)").absoluteString
            }()

            guard let remoteURL = URL(string: remoteUrlString) else {
                throw SoraVideoServiceError.invalidRemoteURL(remoteUrlString)
            }

            let localURL = try await downloadVideo(from: remoteURL, jobId: job.id)

            let openaiId = extractVideoId(status.openaiVideoId ?? job.openaiVideoId)
            let remixedFrom = extractVideoId(status.remixedFromVideoId ?? job.remixedFromVideoId)

            return SoraVideoResult(
                localURL: localURL,
                jobId: job.id,
                openaiVideoId: openaiId,
                remixedFromVideoId: remixedFrom,
                finalRemoteURL: remoteURL
            )
        }

        // ✅ 普通 create：走 /video（可选携带 user_confirm_text，未来后端强校验可直接启用）
        let job = try await createVideoJob(
            prompt: prompt,
            imageFileURL: imageFileURL,
            videoFileURL: videoFileURL,
            audioFileURL: audioFileURL,
            userConfirmText: userConfirmText
        )

        try Task.checkCancellation()

        let status = try await waitForStatusDone(
            jobId: job.id,
            statusURL: job.statusURL,
            interval: max(0.8, pollStep),
            maxSeconds: timeoutSeconds,
            onProgress: onProgress
        )

        try Task.checkCancellation()

        if status.isFailed {
            throw NSError(domain: "SoraVideoService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: status.error ?? "Sora job failed"])
        }

        let remoteUrlString: String = {
            if var u = status.url?.trimmingCharacters(in: .whitespacesAndNewlines),
               !u.isEmpty {
                if !u.hasPrefix("http") { u = absoluteUrl(from: u) }
                return u
            }
            return baseURL.appendingPathComponent("video/stream/\(job.id)").absoluteString
        }()

        guard let remoteURL = URL(string: remoteUrlString) else {
            throw SoraVideoServiceError.invalidRemoteURL(remoteUrlString)
        }

        let localURL = try await downloadVideo(from: remoteURL, jobId: job.id)

        let openaiId = extractVideoId(status.openaiVideoId ?? job.openaiVideoId)
        let remixedFrom = extractVideoId(status.remixedFromVideoId ?? job.remixedFromVideoId)

        return SoraVideoResult(
            localURL: localURL,
            jobId: job.id,
            openaiVideoId: openaiId,
            remixedFromVideoId: remixedFrom,
            finalRemoteURL: remoteURL
        )
    }

    // MARK: - ✅ Remix：创建 Remix Job（强制确认口令；优先 /video/remix）
    func createRemixJob(
        baseVideoId: String,
        userInstruction: String,
        userConfirmText: String
    ) async throws -> SoraJob {

        let baseId = extractVideoId(baseVideoId) ?? baseVideoId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseFinal = extractVideoId(baseId) else {
            throw SoraVideoServiceError.remixRequestMissingBaseVideoId
        }

        let inst = userInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if inst.isEmpty {
            throw SoraVideoServiceError.remixRequestMissingInstruction
        }

        // ✅ 必须确认（防误触发）
        _ = try requireConfirmed(userConfirmText)

        // 1) 走 /video/remix（推荐后端实现）
        do {
            var req = URLRequest(url: baseURL.appendingPathComponent("video/remix"))
            req.httpMethod = "POST"
            req.timeoutInterval = 30
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: Any] = [
                "base_video_id": baseFinal,
                "instruction": inst,
                "user_confirm_text": userConfirmText,
                "user_confirmed": true
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await session.data(for: req)
            let http = response as? HTTPURLResponse

            // /video/remix 还没实现 -> 走 fallback（仅 404）
            if let http, http.statusCode == 404 {
                throw SoraVideoServiceError.remixRouteNotFound
            }

            guard let http, http.statusCode < 400 else {
                let code = http?.statusCode ?? -1
                let text = String(data: data, encoding: .utf8) ?? ""
                throw SoraVideoServiceError.httpError(code, text)
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (json["ok"] as? Bool) == true,
                  let jobId = json["job_id"] as? String else {
                throw SoraVideoServiceError.invalidResponse(String(data: data, encoding: .utf8) ?? "")
            }

            let statusUrlString: String = {
                if let s = json["status_url"] as? String { return absoluteUrl(from: s) }
                return baseURL.appendingPathComponent("video/status/\(jobId)").absoluteString
            }()
            guard let statusURL = URL(string: statusUrlString) else {
                throw SoraVideoServiceError.invalidRemoteURL(statusUrlString)
            }

            let openaiId = extractVideoId((json["openai_video_id"] as? String) ?? (json["video_id"] as? String))
            let remixedFrom = extractVideoId((json["remixed_from_video_id"] as? String) ?? baseFinal) ?? baseFinal

            return SoraJob(id: jobId, statusURL: statusURL, openaiVideoId: openaiId, remixedFromVideoId: remixedFrom)

        } catch let e as SoraVideoServiceError {
            // 2) 仅当 route 不存在（404）才 fallback（避免把服务端错误“悄悄绕过”）
            if case .remixRouteNotFound = e {
                let structured =
                """
                [REMIX_REQUEST]
                base_video_id: \(baseFinal)
                user_instruction: \(inst)
                user_confirm_text: \(userConfirmText)
                rules:
                - convert to ONE concise English remix prompt
                - preserve subject & camera motion unless user explicitly requests changes
                - no extra explanation in output
                [/REMIX_REQUEST]
                """
                return try await createVideoJob(
                    prompt: structured,
                    imageFileURL: nil,
                    videoFileURL: nil,
                    audioFileURL: nil,
                    userConfirmText: userConfirmText
                )
            }
            throw e
        }
    }

    // MARK: - /video create job (multipart streaming)
    func createVideoJob(
        prompt: String,
        imageFileURL: URL? = nil,
        videoFileURL: URL? = nil,
        audioFileURL: URL? = nil,
        userConfirmText: String? = nil
    ) async throws -> SoraJob {

        var request = URLRequest(url: baseURL.appendingPathComponent("video"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // ✅ 落盘 multipart，避免大文件 Data(contentsOf:) 卡顿/爆内存
        let multipartFile = try makeMultipartFile(
            prompt: prompt,
            imageFileURL: imageFileURL,
            videoFileURL: videoFileURL,
            audioFileURL: audioFileURL,
            userConfirmText: userConfirmText,
            boundary: boundary
        )
        defer { try? FileManager.default.removeItem(at: multipartFile) }

        try Task.checkCancellation()

        let (data, response) = try await session.upload(for: request, fromFile: multipartFile)

        guard let http = response as? HTTPURLResponse, http.statusCode < 400 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let text = String(data: data, encoding: .utf8) ?? ""
            throw SoraVideoServiceError.httpError(code, text)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["ok"] as? Bool) == true,
              let jobId = json["job_id"] as? String else {
            throw SoraVideoServiceError.invalidResponse(String(data: data, encoding: .utf8) ?? "")
        }

        let statusUrlString: String = {
            if let s = json["status_url"] as? String { return absoluteUrl(from: s) }
            return baseURL.appendingPathComponent("video/status/\(jobId)").absoluteString
        }()
        guard let statusURL = URL(string: statusUrlString) else {
            throw SoraVideoServiceError.invalidRemoteURL(statusUrlString)
        }

        // ✅ 解析 openaiVideoId（如果后端已返回）
        let openaiId: String? = extractVideoId({
            if let s = json["openai_video_id"] as? String { return s }
            if let s = json["video_id"] as? String { return s }
            if let s = json["openaiVideoId"] as? String { return s }
            return nil
        }())
        let remixedFrom: String? = extractVideoId({
            if let s = json["remixed_from_video_id"] as? String { return s }
            if let s = json["remixedFromVideoId"] as? String { return s }
            if let s = json["remix_base_video_id"] as? String { return s }
            return nil
        }())

        return SoraJob(id: jobId, statusURL: statusURL, openaiVideoId: openaiId, remixedFromVideoId: remixedFrom)
    }

    // MARK: - poll status (returns rich status)
    func watchJob(
        jobId: String?,
        statusURL: URL?,
        interval: TimeInterval = 2.0,
        maxSeconds: TimeInterval = 600.0,
        onProgress: ((Int) -> Void)? = nil
    ) async throws -> SoraJobStatus {

        let pollURL: URL
        if let statusURL {
            pollURL = statusURL
        } else if let jobId {
            pollURL = baseURL.appendingPathComponent("video/status/\(jobId)")
        } else {
            throw NSError(domain: "SoraVideoService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "watchJob requires statusURL or jobId"])
        }

        var deadline = Date().addingTimeInterval(maxSeconds)
        var pseudoProgress = 0
        var finishingGraceUsed = false

        // ✅ transient retry
        var transientFails = 0

        while Date() < deadline {
            try Task.checkCancellation()

            do {
                var request = URLRequest(url: pollURL)
                request.httpMethod = "GET"
                request.timeoutInterval = 20
                request.setValue("application/json", forHTTPHeaderField: "Accept")

                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw NSError(domain: "SoraVideoService", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "Missing HTTPURLResponse"])
                }

                // 某些时候 status 会短暂 502/503（Render/边缘网络）
                if http.statusCode >= 500 && http.statusCode <= 504 {
                    transientFails += 1
                    if transientFails <= 5 {
                        try await Task.sleep(nanoseconds: UInt64(0.8 * 1_000_000_000))
                        continue
                    }
                }

                guard http.statusCode < 400 else {
                    let text = String(data: data, encoding: .utf8) ?? ""
                    throw SoraVideoServiceError.httpError(http.statusCode, text)
                }

                transientFails = 0

                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw SoraVideoServiceError.invalidResponse("Invalid status json")
                }

                if let ok = json["ok"] as? Bool, ok == false {
                    throw SoraVideoServiceError.invalidResponse("Sora status error: \(json)")
                }

                let status = SoraJobStatus.from(json: json)

                // progress 更新
                if let p = status.progress {
                    pseudoProgress = max(pseudoProgress, p)
                    onProgress?(max(0, min(100, p)))
                } else if status.isRunning {
                    pseudoProgress = min(95, pseudoProgress + 2)
                    onProgress?(pseudoProgress)
                }

                // ✅ 99% finishing grace：卡在 99 不要直接超时失败
                if let p = status.progress, p >= 99, !finishingGraceUsed, status.isRunning {
                    finishingGraceUsed = true
                    deadline = max(deadline, Date().addingTimeInterval(600)) // +10min
                }

                if status.isDone || status.isFailed {
                    return status
                }

            } catch {
                transientFails += 1
                // ✅ 允许少量临时错误继续（避免 99%阶段被误判失败）
                if transientFails <= 5 {
                    try await Task.sleep(nanoseconds: UInt64(0.9 * 1_000_000_000))
                    continue
                }
                throw error
            }

            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(max(0.8, interval) * 1_000_000_000))
        }

        throw SoraVideoServiceError.statusTimeout
    }

    // ✅ 新：等待 done/failed 并返回完整 status（含 openaiVideoId）
    func waitForStatusDone(
        jobId: String,
        statusURL: URL?,
        interval: TimeInterval = 2.0,
        maxSeconds: TimeInterval = 600.0,
        onProgress: ((Int) -> Void)? = nil
    ) async throws -> SoraJobStatus {
        return try await watchJob(
            jobId: jobId,
            statusURL: statusURL,
            interval: interval,
            maxSeconds: maxSeconds,
            onProgress: onProgress
        )
    }

    // MARK: - download
    private func downloadVideo(from remoteURL: URL, jobId: String) async throws -> URL {
        var request = URLRequest(url: remoteURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 180

        try Task.checkCancellation()

        let (tmpURL, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw SoraVideoServiceError.httpError(code, "Download failed")
        }

        let fm = FileManager.default
        let ext = remoteURL.pathExtension.isEmpty ? "mp4" : remoteURL.pathExtension
        let dest = fm.temporaryDirectory.appendingPathComponent("sora_output_\(jobId).\(ext)")

        try? fm.removeItem(at: dest)
        try fm.moveItem(at: tmpURL, to: dest)

        return dest
    }

    // MARK: - multipart file builder (streaming)
    private func makeMultipartFile(
        prompt: String,
        imageFileURL: URL?,
        videoFileURL: URL?,
        audioFileURL: URL?,
        userConfirmText: String?,
        boundary: String
    ) throws -> URL {

        let fm = FileManager.default
        let fileURL = fm.temporaryDirectory.appendingPathComponent("sora_multipart_\(UUID().uuidString).tmp")
        fm.createFile(atPath: fileURL.path, contents: nil)

        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }

        func write(_ s: String) {
            if let data = s.data(using: .utf8) { handle.write(data) }
        }

        func writeField(name: String, value: String) {
            write("--\(boundary)\r\n")
            write("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            write("\(value)\r\n")
        }

        func writeFile(fieldName: String, fileURL: URL, top: String) throws {
            let fileName = fileURL.lastPathComponent
            let ext = fileURL.pathExtension.lowercased()
            let mime = guessMediaType(top: top, ext: ext)

            write("--\(boundary)\r\n")
            write("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(fileName)\"\r\n")
            write("Content-Type: \(mime)\r\n\r\n")

            let reader = try FileHandle(forReadingFrom: fileURL)
            defer { try? reader.close() }

            while true {
                let chunk = try reader.read(upToCount: 64 * 1024) ?? Data()
                if chunk.isEmpty { break }
                handle.write(chunk)
            }

            write("\r\n")
        }

        writeField(name: "prompt", value: prompt)

        // ✅ 未来后端若对 create 也做确认闸，这里直接支持
        if let c = userConfirmText?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty {
            writeField(name: "user_confirm_text", value: c)
        }

        if let image = imageFileURL { try writeFile(fieldName: "image_file", fileURL: image, top: "image") }
        if let video = videoFileURL { try writeFile(fieldName: "video_file", fileURL: video, top: "video") }
        if let audio = audioFileURL { try writeFile(fieldName: "audio_file", fileURL: audio, top: "audio") }

        write("--\(boundary)--\r\n")
        return fileURL
    }

    // MARK: - utils
    private func guessMediaType(top: String, ext: String) -> String {
        let e = ext.lowercased()
        if top == "image" {
            switch e {
            case "jpg", "jpeg": return "image/jpeg"
            case "png": return "image/png"
            case "webp": return "image/webp"
            case "gif": return "image/gif"
            default: return "image/jpeg"
            }
        } else if top == "video" {
            switch e {
            case "mp4": return "video/mp4"
            case "mov": return "video/quicktime"
            case "webm": return "video/webm"
            default: return "video/mp4"
            }
        } else if top == "audio" {
            switch e {
            case "wav": return "audio/wav"
            case "mp3": return "audio/mpeg"
            case "m4a": return "audio/mp4"
            default: return "audio/mpeg"
            }
        }
        return "application/octet-stream"
    }

    private func absoluteUrl(from path: String) -> String {
        if path.hasPrefix("http://") || path.hasPrefix("https://") { return path }
        var p = path
        if p.hasPrefix("/") { p.removeFirst() }
        return baseURL.appendingPathComponent(p).absoluteString
    }

    // ✅ 严格提取 video_xxx；提取不到就 nil（防止把 job_id 当 openaiVideoId）
    private func extractVideoId(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        if let r = t.range(of: #"video_[A-Za-z0-9]+"#, options: .regularExpression) {
            return String(t[r])
        }
        return nil
    }

    // ✅ 强制确认（等值匹配，避免语义误判）
    private func requireConfirmed(_ userConfirmText: String?) throws -> String {
        let t = (userConfirmText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard t == Self.confirmTokenPrimary else {
            throw SoraVideoServiceError.missingOrInvalidConfirmToken
        }
        return t
    }

    // MARK: - Remix structured prompt parser（从 [REMIX_REQUEST] 中解析 base_video_id / user_instruction / user_confirm_text）

    private struct ParsedRemix {
        let baseVideoId: String
        let userInstruction: String
        let userConfirmText: String?
    }

    private func parseRemixRequest(from raw: String) -> ParsedRemix? {
        guard raw.contains("[REMIX_REQUEST]") else { return nil }

        let block: String = {
            if let a = raw.range(of: "[REMIX_REQUEST]") {
                let tail = raw[a.upperBound...]
                if let b = tail.range(of: "[/REMIX_REQUEST]") {
                    return String(tail[..<b.lowerBound])
                }
                return String(tail)
            }
            return raw
        }()

        func extractValue(_ key: String) -> String? {
            // key: xxx\n 直到下一行 key 或结束
            let pattern = #"(?im)^\s*\#(key)\s*:\s*(.+?)\s*$"#
            if let r = block.range(of: pattern, options: [.regularExpression]) {
                let line = String(block[r])
                if let idx = line.firstIndex(of: ":") {
                    return String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            return nil
        }

        let base = extractValue("base_video_id") ?? extractVideoId(block)
        let inst = extractValue("user_instruction")
        let confirm = extractValue("user_confirm_text")

        guard let baseFinal = extractVideoId(base) else { return nil }
        guard let instFinal = inst?.trimmingCharacters(in: .whitespacesAndNewlines), !instFinal.isEmpty else { return nil }

        return ParsedRemix(baseVideoId: baseFinal, userInstruction: instFinal, userConfirmText: confirm)
    }
}


