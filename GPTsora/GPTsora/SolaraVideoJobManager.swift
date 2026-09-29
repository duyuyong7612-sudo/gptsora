// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-ad769220a32e1365f0fc1079657b0eccac9c962cfbbe9922557c5182681ceab0"
// Source-SHA256: "305e87275897cd5839debaf92bae4f8ae6f7e8c30c09688a28fe8faaccbb8693"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation
import Combine
import UIKit

enum SolaraJobState: String { case queued, running, done, failed, cancelled }

struct SolaraVideoJob: Identifiable, Equatable {
    let id: UUID
    let prompt: String
    let createdAt: Date

    var progress: Int
    var state: SolaraJobState
    var resultURL: URL?
    var errorText: String?
    var isConsumed: Bool

    var imageFileURL: URL?
    var videoFileURL: URL?
}

@MainActor
final class SolaraVideoJobManager: ObservableObject {

    static let shared = SolaraVideoJobManager()

    @Published var jobs: [SolaraVideoJob] = []
    @Published var lastCompletedJobId: UUID? = nil
    @Published var lastFailedJobId: UUID? = nil

    private var isWorkerRunning = false

    // ✅ 失败也要显示（不会消失）
    var hudJob: SolaraVideoJob? {
        if let active = jobs.first(where: { $0.state == .queued || $0.state == .running }) { return active }
        if let ready  = jobs.first(where: { $0.state == .done && $0.isConsumed == false }) { return ready }
        if let failed = jobs.first(where: { $0.state == .failed && $0.isConsumed == false }) { return failed }
        return nil
    }

    func enqueue(prompt: String, imageFileURL: URL?, videoFileURL: URL?) {
        let job = SolaraVideoJob(
            id: UUID(),
            prompt: prompt,
            createdAt: Date(),
            progress: 0,
            state: .queued,
            resultURL: nil,
            errorText: nil,
            isConsumed: false,
            imageFileURL: imageFileURL,
            videoFileURL: videoFileURL
        )
        jobs.insert(job, at: 0)
        runWorkerIfNeeded()
    }

    func markConsumed(_ id: UUID) {
        if let i = jobs.firstIndex(where: { $0.id == id }) {
            jobs[i].isConsumed = true
        }
    }

    func clearFinished() {
        jobs.removeAll { $0.state == .done || $0.state == .failed || $0.state == .cancelled }
    }

    func retry(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].state = .queued
        jobs[i].progress = 0
        jobs[i].errorText = nil
        jobs[i].isConsumed = false
        runWorkerIfNeeded()
    }

    private func runWorkerIfNeeded() {
        guard !isWorkerRunning else { return }
        isWorkerRunning = true

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            let bg = await MainActor.run {
                UIApplication.shared.beginBackgroundTask(withName: "solara_video_job")
            }

            defer {
                Task { @MainActor in
                    UIApplication.shared.endBackgroundTask(bg)
                    self.isWorkerRunning = false
                    self.runWorkerIfNeeded()
                }
            }

            while true {
                let next: SolaraVideoJob? = await MainActor.run {
                    self.jobs.first(where: { $0.state == .queued })
                }
                guard let job = next else { break }

                await MainActor.run {
                    if let idx = self.jobs.firstIndex(where: { $0.id == job.id }) {
                        self.jobs[idx].state = .running
                        self.jobs[idx].progress = 1
                        self.jobs[idx].errorText = nil
                    }
                }

                do {
                    let localURL = try await SoraVideoService.shared.startAndWait(
                        prompt: job.prompt,
                        imageFileURL: job.imageFileURL,
                        videoFileURL: job.videoFileURL,
                        audioFileURL: nil,
                        pollStep: 2.0,
                        timeoutSeconds: 600.0
                    ) { p in
                        Task { @MainActor in
                            if let idx = self.jobs.firstIndex(where: { $0.id == job.id }),
                               self.jobs[idx].state == .running {
                                self.jobs[idx].progress = max(0, min(100, p))
                            }
                        }
                    }

                    // ✅ 落盘到 Documents，避免重进丢失
                    let stableURL = SolaraFileUtils.persistToDocumentsIfNeeded(localURL)

                    await MainActor.run {
                        if let idx = self.jobs.firstIndex(where: { $0.id == job.id }) {
                            self.jobs[idx].state = .done
                            self.jobs[idx].progress = 100
                            self.jobs[idx].resultURL = stableURL
                            self.lastCompletedJobId = self.jobs[idx].id
                        }

                        // ✅ 写入保存区
                        VideoLibraryStore.shared.addVideo(fileURL: stableURL, prompt: job.prompt)
                    }

                } catch {
                    await MainActor.run {
                        if let idx = self.jobs.firstIndex(where: { $0.id == job.id }) {
                            self.jobs[idx].state = .failed
                            self.jobs[idx].errorText = error.localizedDescription
                            self.lastFailedJobId = self.jobs[idx].id
                        }
                    }
                }
            }
        }
    }
}
