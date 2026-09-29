// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-295d3b0745392cb315aec396d82e2c8fc4ec1d57470e5f5251d2c2679e141092"
// Source-SHA256: "aff626abad23e97b5ce5ff05584efeb2de4f1b443b165144e63777b866525c9b"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation
import Combine
import UIKit

// MARK: - Job State

enum VideoJobState: String {
    case queued
    case running
    case done
    case failed
    case cancelled
}

// MARK: - Job Kind

enum VideoJobKind: String {
    case generate
    case remix
}

// MARK: - Job Model

struct VideoJob: Identifiable, Equatable {
    let id: UUID
    let kind: VideoJobKind

    /// ✅ 干净 prompt
    /// - generate: 用户原始 prompt
    /// - remix:    用户 instruction
    let prompt: String

    let createdAt: Date

    var progress: Int
    var state: VideoJobState

    var resultURL: URL?
    var errorText: String?
    var isConsumed: Bool

    var imageFileURL: URL?
    var videoFileURL: URL?

    var backendJobId: String?
    var openaiVideoId: String?
    var remixedFromVideoId: String?
    var baseVideoId: String?
}

// MARK: - Remix Backend (专用二次生成通道)

private enum RemixBackend {
    /// ✅ 统一入口：永远跟随 AppConfig.API（本地/公网只改 AppConfig 一处）
    static var apiBase: String { AppConfig.API.apiBase }

    static var remixStartURL: URL { AppConfig.API.resolve("/video/remix") }
    static func statusURL(jobId: String) -> URL { AppConfig.API.resolve("/video/status/\(jobId)") }

    static func absolutizeIfNeeded(_ maybeURL: String) -> URL? {
        let s = maybeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if s.hasPrefix("http://") || s.hasPrefix("https://") { return URL(string: s) }
        if s.hasPrefix("/") { return AppConfig.API.resolve(s) }
        return AppConfig.API.resolve("/" + s)
    }
}

// MARK: - Manager

@MainActor
final class VideoJobManager: ObservableObject {

    static let shared = VideoJobManager()

    @Published private(set) var jobs: [VideoJob] = []
    @Published var lastCompletedJob: VideoJob?
    @Published var lastFailedJob: VideoJob?

    private var workerTask: Task<Void, Never>? = nil


    private init() {
        // Best-effort recovery: if the app was closed / user left while a video was generating,
        // the backend can still finish later. On next launch, pull any completed videos
        // persisted server-side and save them into the local video library.
        Task { [weak self] in
            await self?.syncMissedVideosFromBackend()
        }
    }

    private let confirmPrimary = "客户己确定"
    private let confirmCompat  = "客户已确定"

    var hudJob: VideoJob? {
        if let active = jobs.first(where: { $0.state == .queued || $0.state == .running }) { return active }
        if let done = jobs.first(where: { $0.state == .done && !$0.isConsumed }) { return done }
        if let failed = jobs.first(where: { $0.state == .failed && !$0.isConsumed }) { return failed }
        return nil
    }

    // MARK: - Public API

    func enqueue(prompt: String, imageFileURL: URL?, videoFileURL: URL?) {
        let job = VideoJob(
            id: UUID(),
            kind: .generate,
            prompt: prompt,
            createdAt: Date(),
            progress: 0,
            state: .queued,
            resultURL: nil,
            errorText: nil,
            isConsumed: false,
            imageFileURL: imageFileURL,
            videoFileURL: videoFileURL,
            backendJobId: nil,
            openaiVideoId: nil,
            remixedFromVideoId: nil,
            baseVideoId: nil
        )
        jobs.insert(job, at: 0)
        startWorkerIfNeeded()
    }

    func enqueueRemix(baseVideoId: String, instruction: String) {
        let base = baseVideoId.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !t.isEmpty else { return }

        let job = VideoJob(
            id: UUID(),
            kind: .remix,
            prompt: t,
            createdAt: Date(),
            progress: 0,
            state: .queued,
            resultURL: nil,
            errorText: nil,
            isConsumed: false,
            imageFileURL: nil,
            videoFileURL: nil,
            backendJobId: nil,
            openaiVideoId: nil,
            remixedFromVideoId: nil,
            baseVideoId: base
        )

        jobs.insert(job, at: 0)
        startWorkerIfNeeded()
    }

    func markConsumed(_ jobId: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        jobs[i].isConsumed = true
    }

    func clearFinished() {
        jobs.removeAll { $0.state == .done || $0.state == .failed || $0.state == .cancelled }
    }

    func retry(_ jobId: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        jobs[i].state = .queued
        jobs[i].progress = 0
        jobs[i].errorText = nil
        jobs[i].isConsumed = false

        jobs[i].resultURL = nil
        jobs[i].backendJobId = nil
        jobs[i].openaiVideoId = nil
        jobs[i].remixedFromVideoId = nil

        startWorkerIfNeeded()
    }

    // MARK: - Worker Control

    private func startWorkerIfNeeded() {
        guard workerTask == nil else { return }

        workerTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.workerLoop()
        }
    }

    private func stopWorkerIfIdle() {
        let hasQueued = jobs.contains { $0.state == .queued }
        if !hasQueued { workerTask = nil }
    }

    // MARK: - Worker Loop

    private func workerLoop() async {
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "solara.video.job")
        defer { UIApplication.shared.endBackgroundTask(bgTask) }

        while true {

            guard let job = jobs.first(where: { $0.state == .queued }) else {
                stopWorkerIfIdle()
                return
            }

            guard let idx = jobs.firstIndex(where: { $0.id == job.id }) else { continue }

            jobs[idx].state = .running
            jobs[idx].progress = 1
            jobs[idx].errorText = nil

            do {
                var lastProgress = 0
                var lastUpdate = Date.distantPast

                switch job.kind {

                // ✅ 普通生成：保持你原逻辑
                case .generate:
                    let result = try await SoraVideoService.shared.startAndWaitEx(
                        prompt: job.prompt,
                        imageFileURL: job.imageFileURL,
                        videoFileURL: job.videoFileURL,
                        audioFileURL: nil,
                        pollStep: 2.0,
                        timeoutSeconds: 1200
                    ) { p in
                        Task { @MainActor in
                            guard let i = self.jobs.firstIndex(where: { $0.id == job.id }),
                                  self.jobs[i].state == .running else { return }

                            let now = Date()
                            if p != lastProgress && now.timeIntervalSince(lastUpdate) > 0.15 {
                                self.jobs[i].progress = min(100, max(0, p))
                                lastProgress = p
                                lastUpdate = now
                            }
                        }
                    }

                    let stableURL = SolaraFileUtils.persistToDocumentsIfNeeded(result.localURL)

                    jobs[idx].state = .done
                    jobs[idx].progress = 100
                    jobs[idx].resultURL = stableURL
                    jobs[idx].backendJobId = result.jobId
                    jobs[idx].openaiVideoId = result.openaiVideoId
                    jobs[idx].remixedFromVideoId = result.remixedFromVideoId

                    lastCompletedJob = jobs[idx]

                    VideoLibraryStore.shared.addVideo(
                        fileURL: stableURL,
                        prompt: jobs[idx].prompt,
                        openaiVideoId: jobs[idx].openaiVideoId,
                        remixedFromVideoId: jobs[idx].remixedFromVideoId
                    )

                // ✅ 二次生成：走 /video/remix 专用通道（关键修复）
                case .remix:
                    let base = (job.baseVideoId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let inst = job.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !base.isEmpty else {
                        throw NSError(domain: "VideoJobManager", code: -2,
                                      userInfo: [NSLocalizedDescriptionKey: "missing baseVideoId"])
                    }

                    let lang = Self.detectUserLanguage(inst)

                    let result = try await Self.startAndWaitRemixJob(
                        baseVideoId: base,
                        instruction: inst,
                        userLanguage: lang,
                        confirmPrimary: confirmPrimary,
                        confirmCompat: confirmCompat,
                        pollStep: 2.0,
                        timeoutSeconds: 1800
                    ) { p in
                        Task { @MainActor in
                            guard let i = self.jobs.firstIndex(where: { $0.id == job.id }),
                                  self.jobs[i].state == .running else { return }

                            let now = Date()
                            if p != lastProgress && now.timeIntervalSince(lastUpdate) > 0.15 {
                                self.jobs[i].progress = min(100, max(0, p))
                                lastProgress = p
                                lastUpdate = now
                            }
                        }
                    }

                    let stableURL = SolaraFileUtils.persistToDocumentsIfNeeded(result.localURL)

                    jobs[idx].state = .done
                    jobs[idx].progress = 100
                    jobs[idx].resultURL = stableURL
                    jobs[idx].backendJobId = result.jobId
                    jobs[idx].openaiVideoId = result.openaiVideoId
                    jobs[idx].baseVideoId = base

                    let remixedFrom = result.remixedFromVideoId ?? base
                    jobs[idx].remixedFromVideoId = remixedFrom

                    lastCompletedJob = jobs[idx]

                    VideoLibraryStore.shared.addVideo(
                        fileURL: stableURL,
                        prompt: jobs[idx].prompt, // ✅ 仍然只存“干净 instruction”
                        openaiVideoId: jobs[idx].openaiVideoId,
                        remixedFromVideoId: jobs[idx].remixedFromVideoId
                    )
                }

            } catch {
                jobs[idx].state = .failed
                jobs[idx].errorText = UserErrorMessage.from(error)
                lastFailedJob = jobs[idx]
            }
        }
    }
}

// MARK: - ✅ Remix network (专用通道：/video/remix + /video/status/{id})

extension VideoJobManager {

    struct RemixResult {
        let localURL: URL
        let jobId: String
        let openaiVideoId: String?
        let remixedFromVideoId: String?
    }

    nonisolated static func startAndWaitRemixJob(
        baseVideoId: String,
        instruction: String,
        userLanguage: String,
        confirmPrimary: String,
        confirmCompat: String,
        pollStep: TimeInterval,
        timeoutSeconds: TimeInterval,
        progress: @escaping (Int) -> Void
    ) async throws -> RemixResult {

        let jobId = try await startRemixJob(
            baseVideoId: baseVideoId,
            instruction: instruction,
            userLanguage: userLanguage,
            confirmPrimary: confirmPrimary,
            confirmCompat: confirmCompat
        )

        let deadline = Date().addingTimeInterval(timeoutSeconds)

        while true {
            if Date() > deadline {
                throw NSError(domain: "VideoJobManager", code: -408,
                              userInfo: [NSLocalizedDescriptionKey: "remix timeout"])
            }

            let st = try await fetchRemixStatus(jobId: jobId)
            if let p = st.progress { progress(p) }

            if st.state == "done" || st.state == "succeeded" || st.state == "success" {
                guard let urlStr = st.resultURLString,
                      let remoteURL = RemixBackend.absolutizeIfNeeded(urlStr) else {
                    throw NSError(domain: "VideoJobManager", code: -3,
                                  userInfo: [NSLocalizedDescriptionKey: "missing result_url"])
                }

                let local = try await VideoJobManager.downloadToTemp(remoteURL: remoteURL)

                return RemixResult(
                    localURL: local,
                    jobId: jobId,
                    openaiVideoId: st.openaiVideoId,
                    remixedFromVideoId: st.remixedFromVideoId
                )
            }

            if st.state == "failed" || st.state == "error" {
                let msg = st.errorMessage ?? "remix failed"
                throw NSError(domain: "VideoJobManager", code: -4,
                              userInfo: [NSLocalizedDescriptionKey: msg])
            }

            try await Task.sleep(nanoseconds: UInt64(max(0.3, pollStep) * 1_000_000_000))
        }
    }

    nonisolated static func startRemixJob(
        baseVideoId: String,
        instruction: String,
        userLanguage: String,
        confirmPrimary: String,
        confirmCompat: String
    ) async throws -> String {

        let payload: [String: Any] = [
            "base_video_id": baseVideoId,
            "instruction": instruction,
            "user_instruction": instruction,
            "user_language": userLanguage,
            "user_confirm_text": confirmPrimary,
            "confirm_text": confirmPrimary,
            "confirm_primary": confirmPrimary,
            "confirm_compat": confirmCompat
        ]

        var req = URLRequest(url: RemixBackend.remixStartURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 25
        req.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "VideoJobManager", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "remix start failed \(code): \(body)"])
        }

        let dict = try jsonDict(data)

        if let jid = extractString(dict, ["job_id", "id", "backend_job_id"]) {
            return jid
        }
        if let dataObj = dict["data"] as? [String: Any],
           let jid = extractString(dataObj, ["job_id", "id"]) {
            return jid
        }

        throw NSError(domain: "VideoJobManager", code: -5,
                      userInfo: [NSLocalizedDescriptionKey: "missing job_id in remix start response"])
    }

    struct RemixStatus {
        let state: String
        let progress: Int?
        let resultURLString: String?
        let openaiVideoId: String?
        let remixedFromVideoId: String?
        let errorMessage: String?
    }

    nonisolated static func fetchRemixStatus(jobId: String) async throws -> RemixStatus {
        var req = URLRequest(url: RemixBackend.statusURL(jobId: jobId))
        req.httpMethod = "GET"
        req.timeoutInterval = 20

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "VideoJobManager", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "status failed \(code): \(body)"])
        }

        let dict = try jsonDict(data)

        let state = (extractString(dict, ["state", "status"]) ?? "running").lowercased()
        let p = extractInt(dict, ["progress", "pct", "percent", "percentage"])
        let resultURL = extractString(dict, ["result_url", "url", "download_url", "file_url"])
        let openaiId = extractString(dict, ["openai_video_id", "video_id", "openaiId", "openai_id"])
        let remixedFrom = extractString(dict, ["remixed_from_video_id", "remixedFromVideoId", "base_video_id"])

        let errMsg: String? = {
            if let e = dict["error"] as? String { return e }
            if let e = dict["message"] as? String { return e }
            if let e = dict["detail"] as? String { return e }
            if let e = dict["error"] as? [String: Any],
               let m = e["message"] as? String { return m }
            return nil
        }()

        return RemixStatus(
            state: state,
            progress: p,
            resultURLString: resultURL,
            openaiVideoId: openaiId,
            remixedFromVideoId: remixedFrom,
            errorMessage: errMsg
        )
    }

    nonisolated static func downloadToTemp(remoteURL: URL) async throws -> URL {
        let (tmp, resp) = try await URLSession.shared.download(from: remoteURL)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            throw NSError(domain: "VideoJobManager", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "download failed \(code)"])
        }

        let ext = remoteURL.pathExtension.isEmpty ? "mp4" : remoteURL.pathExtension
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("solara_remix_\(UUID().uuidString).\(ext)")

        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    nonisolated static func jsonDict(_ data: Data) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: data, options: [])
        if let d = obj as? [String: Any] { return d }
        throw NSError(domain: "VideoJobManager", code: -6,
                      userInfo: [NSLocalizedDescriptionKey: "invalid json"])
    }

    nonisolated static func extractString(_ dict: [String: Any], _ keys: [String]) -> String? {
        for k in keys {
            if let s = dict[k] as? String, !s.isEmpty { return s }
        }
        return nil
    }

    nonisolated static func extractInt(_ dict: [String: Any], _ keys: [String]) -> Int? {
        for k in keys {
            if let n = dict[k] as? Int { return n }
            if let d = dict[k] as? Double { return Int(d) }
            if let s = dict[k] as? String, let n = Int(s) { return n }
        }
        return nil
    }

    nonisolated static func detectUserLanguage(_ s: String) -> String {
        if s.range(of: #"[\u4E00-\u9FFF]"#, options: .regularExpression) != nil { return "zh" }
        if s.range(of: #"[\u3040-\u30FF]"#, options: .regularExpression) != nil { return "ja" }
        if s.range(of: #"[\uAC00-\uD7AF]"#, options: .regularExpression) != nil { return "ko" }
        return "en"
    }
}



extension VideoJobManager {
    /// Best-effort recovery: fetch completed videos persisted server-side (e.g. if the
    /// app was closed while a job was still generating) and download any missing ones
    /// into the local `VideoLibraryStore`.
    func syncMissedVideosFromBackend(limit: Int = 20, maxAutoDownload: Int = 3) async {
        guard limit > 0, maxAutoDownload > 0 else { return }

        guard var comps = URLComponents(url: AppConfig.API.resolve("/v1/me/videos"), resolvingAgainstBaseURL: false) else { return }
        comps.queryItems = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: "0")
        ]
        guard let url = comps.url else { return }

        do {
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return
            }

            let dict = try Self.jsonDict(data)
            guard (dict["ok"] as? Bool) == true else { return }
            guard let items = dict["items"] as? [[String: Any]] else { return }

            let existing = Set(VideoLibraryStore.shared.videos.compactMap { $0.openaiVideoId })
            var downloaded = 0

            for item in items {
                guard downloaded < maxAutoDownload else { break }
                guard let vid = item["video_id"] as? String, !vid.isEmpty else { continue }
                if existing.contains(vid) { continue }

                guard let streamPath = item["stream_url"] as? String, !streamPath.isEmpty else { continue }
                let full = streamPath.hasPrefix("http") ? streamPath : AppConfig.API.resolve(streamPath).absoluteString
                guard let streamURL = URL(string: full) else { continue }

                let prompt = (item["caption"] as? String) ?? ""
                let tmpURL = try await VideoJobManager.downloadToTemp(remoteURL: streamURL)

                VideoLibraryStore.shared.addVideo(
                    fileURL: tmpURL,
                    prompt: prompt,
                    openaiVideoId: vid,
                    remixedFromVideoId: item["remixed_from_video_id"] as? String
                )

                downloaded += 1
            }
        } catch {
            // Swallow errors; this is best-effort.
        }
    }
}



