//  VideoLibraryStore.swift
//  SoraApp
//
//  Production-grade optimizations:
//  1) All disk I/O runs on ioQueue; UI updates only on main thread
//  2) addVideo no longer “skips when isWriting” — it queues to avoid lost saves
//  3) Persist encoding/writing runs on ioQueue to reduce main-thread jitter
//  4) loadFromDiskAsync decodes off-main and publishes once on main
//
//  ✅ Upgrade for Remix binding:
//  - SavedVideo now stores openaiVideoId (video_xxx) and remixedFromVideoId
//  - addVideo supports optional openaiVideoId (keeps old signature for compatibility)
//  - dedupe prefers openaiVideoId match (strongest identity)
//

// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-5a05d3de78205f282f28a04dde8b51b66626452ec128e60d9856158d3407ba98"
// Source-SHA256: "f2be7908411a518bcc92e14daee57b5a4ab9a03431543a57780b482b5503c940"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation
import Combine

// MARK: - Single video metadata

struct SavedVideo: Identifiable, Codable, Equatable {
    let id: UUID
    let fileName: String
    let prompt: String
    let createdAt: Date

    // ✅ NEW: binding to OpenAI video id (for remix input)
    let openaiVideoId: String?          // e.g. "video_..."
    let remixedFromVideoId: String?     // e.g. "video_..." (base id if this is a remix)

    /// Display title (fallback if prompt is empty)
    var displayTitle: String {
        let t = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Untitled Video" : t
    }
}

// MARK: - Video Library (sandbox storage)

final class VideoLibraryStore: ObservableObject {

    static let shared = VideoLibraryStore()

    @Published private(set) var videos: [SavedVideo] = []

    private let fileManager = FileManager.default
    private let userDefaultsKey = "saved_videos_v1"

    /// All disk I/O runs on this queue to avoid blocking the main thread (utility is sufficient)
    private let ioQueue = DispatchQueue(label: "com.soraapp.videoLibrary.io", qos: .utility)

    /// Access only on ioQueue
    private var isWriting = false

    /// Production fix: serialize concurrent adds via a queue (never drop a save request)
    private struct PendingAdd: Equatable {
        let fileURL: URL
        let prompt: String
        let openaiVideoId: String?
        let remixedFromVideoId: String?
    }
    private var pendingAdds: [PendingAdd] = []

    private init() {
        loadFromDiskAsync()
    }

    // MARK: - Sandbox path: Documents/video_library

    private var libraryDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("video_library", isDirectory: true)

        if !fileManager.fileExists(atPath: dir.path) {
            do {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                print("❌ Failed to create video_library directory: \(error)")
            }
        }
        return dir
    }

    // MARK: - Public: meta lookup (for playback binding)

    func meta(forFileName fileName: String) -> SavedVideo? {
        videos.first(where: { $0.fileName == fileName })
    }

    // MARK: - Core: Save video (full de-dupe + background I/O)

    /// ✅ Backward-compatible API (old call sites keep working)
    func addVideo(fileURL: URL, prompt: String) {
        addVideo(fileURL: fileURL, prompt: prompt, openaiVideoId: nil, remixedFromVideoId: nil)
    }

    /// ✅ New API: store openaiVideoId/remixedFromVideoId for remix binding
    func addVideo(
        fileURL: URL,
        prompt: String,
        openaiVideoId: String?,
        remixedFromVideoId: String? = nil
    ) {
        let p = prompt
        let oid = openaiVideoId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rid = remixedFromVideoId?.trimmingCharacters(in: .whitespacesAndNewlines)

        ioQueue.async { [weak self] in
            guard let self else { return }

            let task = PendingAdd(fileURL: fileURL, prompt: p, openaiVideoId: oid, remixedFromVideoId: rid)

            // If writing, enqueue (never drop)
            if self.isWriting {
                let alreadyQueued = self.pendingAdds.contains(task)
                if !alreadyQueued {
                    self.pendingAdds.append(task)
                } else {
                    print("⚠️ addVideo() already queued, skipping duplicate enqueue")
                }
                return
            }

            self.isWriting = true
            self.drainAddQueue(startingWith: task)
        }
    }

    /// ioQueue only: drain all pending tasks
    private func drainAddQueue(startingWith first: PendingAdd) {
        var current: PendingAdd? = first

        while let task = current {
            addVideoOnceOnIOQueue(
                fileURL: task.fileURL,
                prompt: task.prompt,
                openaiVideoId: task.openaiVideoId,
                remixedFromVideoId: task.remixedFromVideoId
            )

            if pendingAdds.isEmpty {
                current = nil
            } else {
                current = pendingAdds.removeFirst()
            }
        }

        isWriting = false
    }

    /// The actual write; ioQueue only
    private func addVideoOnceOnIOQueue(
        fileURL: URL,
        prompt: String,
        openaiVideoId: String?,
        remixedFromVideoId: String?
    ) {

        let baseDir = libraryDirectory

        // Try getting file size once (used by multiple checks)
        let newSize: Int? = try? fileSize(fileURL)

        // Snapshot current list from main thread (avoid touching @Published on ioQueue)
        let currentVideos: [SavedVideo] = DispatchQueue.main.sync { self.videos }

        // ================================
        // ① De-dup (avoid duplicates completely)
        // ================================

        // A0. Strongest dedupe: openaiVideoId match
        if let oid = openaiVideoId, !oid.isEmpty {
            if currentVideos.contains(where: { ($0.openaiVideoId ?? "") == oid }) {
                print("⚠️ Duplicate video detected (openaiVideoId match). Skipping: \(oid)")
                return
            }
        }

        // A. If the file is already inside video_library and metadata exists -> saved before
        if fileURL.deletingLastPathComponent() == baseDir {
            let name = fileURL.lastPathComponent
            if currentVideos.contains(where: { $0.fileName == name }) {
                print("⚠️ Video already exists (same directory + name). Skipping: \(name)")
                return
            }
        }

        // B. Full scan: fileSize + prompt match => treat as same video, skip
        if let newSize = newSize {
            for v in currentVideos {
                let oldURL = baseDir.appendingPathComponent(v.fileName)
                if let oldSize = try? fileSize(oldURL),
                   abs(oldSize - newSize) < 50,
                   prompt == v.prompt {
                    print("⚠️ Duplicate video detected (size + prompt). Skipping")
                    return
                }
            }
        }

        // ================================
        // ② Write flow (still on ioQueue)
        // ================================

        let fileName = UUID().uuidString + ".mp4"
        let targetURL = baseDir.appendingPathComponent(fileName)

        do {
            if fileManager.fileExists(atPath: targetURL.path) {
                try fileManager.removeItem(at: targetURL)
            }

            try fileManager.copyItem(at: fileURL, to: targetURL)

            let item = SavedVideo(
                id: UUID(),
                fileName: fileName,
                prompt: prompt,
                createdAt: Date(),
                openaiVideoId: (openaiVideoId?.isEmpty == true ? nil : openaiVideoId),
                remixedFromVideoId: (remixedFromVideoId?.isEmpty == true ? nil : remixedFromVideoId)
            )

            // UI update on main thread only
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.videos.insert(item, at: 0) // newest first
                let snapshot = self.videos
                self.persistAsync(snapshot: snapshot)
                print("✅ Saved video into library: \(targetURL.path)")
            }

        } catch {
            print("❌ Failed to save video: \(error)")
        }
    }

    // MARK: - Utility: file size (safe on ioQueue)

    private func fileSize(_ url: URL) throws -> Int {
        let attr = try fileManager.attributesOfItem(atPath: url.path)
        return (attr[.size] as? Int) ?? 0
    }

    // MARK: - Public: URL + delete

    func url(for video: SavedVideo) -> URL {
        libraryDirectory.appendingPathComponent(video.fileName)
    }

    func delete(_ video: SavedVideo) {

        // 1) Delete file on disk (ioQueue)
        let videoPath = url(for: video).path
        ioQueue.async { [weak self] in
            guard let self else { return }
            if self.fileManager.fileExists(atPath: videoPath) {
                do {
                    try self.fileManager.removeItem(atPath: videoPath)
                } catch {
                    print("❌ Failed to delete file: \(error)")
                }
            }
        }

        // 2) Update memory list on main thread + persist async
        if let idx = videos.firstIndex(of: video) {
            videos.remove(at: idx)
            let snapshot = videos
            persistAsync(snapshot: snapshot)
        }
    }

    // MARK: - Persist (async)

    private func persistAsync(snapshot: [SavedVideo]) {
        ioQueue.async { [userDefaultsKey] in
            do {
                let data = try JSONEncoder().encode(snapshot)
                UserDefaults.standard.set(data, forKey: userDefaultsKey)
            } catch {
                print("❌ Failed to persist video list: \(error)")
            }
        }
    }

    // MARK: - Load (decode off-main + publish once)

    private func loadFromDiskAsync() {
        ioQueue.async { [weak self] in
            guard let self else { return }

            guard let data = UserDefaults.standard.data(forKey: self.userDefaultsKey) else {
                DispatchQueue.main.async { self.videos = [] }
                return
            }

            do {
                var list = try JSONDecoder().decode([SavedVideo].self, from: data)
                let baseDir = self.libraryDirectory

                // ① Filter out missing files
                list = list.filter { v in
                    let p = baseDir.appendingPathComponent(v.fileName).path
                    return self.fileManager.fileExists(atPath: p)
                }

                // ② Dedup by fileName (keep newest by createdAt)
                var seenFile = Set<String>()
                var deduped: [SavedVideo] = []

                for v in list.sorted(by: { $0.createdAt > $1.createdAt }) {
                    if !seenFile.contains(v.fileName) {
                        deduped.append(v)
                        seenFile.insert(v.fileName)
                    }
                }

                // ③ Extra dedup by openaiVideoId (keep newest)
                var seenOpenAI = Set<String>()
                var finalList: [SavedVideo] = []
                for v in deduped.sorted(by: { $0.createdAt > $1.createdAt }) {
                    if let oid = v.openaiVideoId, !oid.isEmpty {
                        if seenOpenAI.contains(oid) { continue }
                        seenOpenAI.insert(oid)
                    }
                    finalList.append(v)
                }

                DispatchQueue.main.async {
                    self.videos = finalList
                }

            } catch {
                print("❌ Failed to load video list: \(error)")
                DispatchQueue.main.async { self.videos = [] }
            }
        }
    }
}

