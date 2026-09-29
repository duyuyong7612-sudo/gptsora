// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-04ca702eafd814cc8d699376224032534674653aa415873be5fa298827dbac28"
// Source-SHA256: "3fa143b90ef1d212535b67615a45c8db70f886caed155d2db66e089134523dc7"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation
import AVFoundation
import Combine

/// TTS 切片队列 + streaming 播放（AVQueuePlayer）
///
/// 同步策略：
/// - 播报未开始：不放行文字（由 FixedRateTextRevealer.gate 控制）
/// - 播报开始：定期回调“当前已播到的全局字符位置”，用于限制文字显示不超过语音进度
public final class GlobalSpeechPlayer: NSObject, ObservableObject {
    @Published public private(set) var isSpeaking: Bool = false
    @Published public private(set) var hasStartedAudioForCurrentResponse: Bool = false

    public var onFirstAudioStarted: (() -> Void)?
    public var onSpokenCharIndex: ((Int) -> Void)?
    public var onAllAudioFinished: (() -> Void)?

    private let player = AVQueuePlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    private var ttsClient: OpenAITTSClient?
    private var ttsModel: String = ""
    private var ttsVoice: String = ""
    private var ttsSpeed: Double = 1.0
    private var ttsFormat: String = "mp3"

    /// Prepared audio files waiting to be enqueued, keyed by seq.
    private var pendingAudioBySeq: [Int: URL] = [:]

    /// Slice metadata keyed by seq (needed to compute global char index).
    private var sliceBySeq: [Int: TTSSlicer.Slice] = [:]

    /// Current item -> slice mapping.
    private var sliceByItemID: [ObjectIdentifier: TTSSlicer.Slice] = [:]

    /// Next seq expected to enqueue (strictly increasing).
    private var nextEnqueueSeq: Int = 0

    /// Set true when no more slices will come.
    private var isFinalized: Bool = false

    /// When a slice's TTS fails, we store this special URL to indicate "skip but advance seq".
    private static let failedMarkerURL = URL(fileURLWithPath: "/dev/null")

    public init(config: OpenAIConfig? = nil) {
        super.init()

        if let config {
            self.ttsClient = OpenAITTSClient(config: config)
            self.ttsModel = config.ttsModel
            self.ttsVoice = config.ttsVoice
            self.ttsSpeed = config.ttsSpeed
            self.ttsFormat = config.ttsFormat
        }

        configureAudioSession()
        configurePlayer()
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    // MARK: - Public

    public func resetForNewResponse() {
        DispatchQueue.main.async {
            self.isFinalized = false
            self.hasStartedAudioForCurrentResponse = false
            self.isSpeaking = false
            self.pendingAudioBySeq.removeAll(keepingCapacity: true)
            self.sliceBySeq.removeAll(keepingCapacity: true)
            self.sliceByItemID.removeAll(keepingCapacity: true)
            self.nextEnqueueSeq = 0
            self.player.pause()
            self.player.removeAllItems()
        }
    }

    /// Enqueue one slice: async synthesize -> store -> enqueue in-order.
    public func enqueue(_ slice: TTSSlicer.Slice) {
        // Cache slice meta ASAP (must be available when audio is ready).
        DispatchQueue.main.async {
            self.sliceBySeq[slice.seq] = slice
        }

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                let url = try await self.prepareAudioFile(for: slice.text)
                await self.storePrepared(url: url, seq: slice.seq)
            } catch {
                await self.storePrepared(url: Self.failedMarkerURL, seq: slice.seq)
            }
        }
    }

    /// Call when no more slices will come.
    public func finalize() {
        DispatchQueue.main.async {
            self.isFinalized = true
            self.maybeEnqueueReadyItemsOnMain()
            self.maybeFinishIfDoneOnMain()
        }
    }

    // MARK: - Internals

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        } catch {
            // ignore
        }
    }

    private func configurePlayer() {
        player.actionAtItemEnd = .advance
        player.automaticallyWaitsToMinimizeStalling = true

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            self?.handleTickOnMain()
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.handleItemDidEndOnMain(note)
        }
    }

    private func handleTickOnMain() {
        if player.timeControlStatus == .playing {
            if !hasStartedAudioForCurrentResponse {
                hasStartedAudioForCurrentResponse = true
                onFirstAudioStarted?()
            }
            isSpeaking = true
        } else {
            isSpeaking = (player.currentItem != nil)
        }

        guard let item = player.currentItem else { return }
        let oid = ObjectIdentifier(item)
        guard let slice = sliceByItemID[oid] else { return }

        let dur = item.duration.seconds
        let cur = item.currentTime().seconds
        guard dur.isFinite, dur > 0 else { return }

        let r = max(0.0, min(1.0, cur / dur))
        let localChars = Int(Double(slice.text.count) * r)
        let globalIndex = slice.charStart + localChars
        onSpokenCharIndex?(globalIndex)
    }

    private func handleItemDidEndOnMain(_ note: Notification) {
        // 一段播完，队列会自动 advance；这里补做 enqueue/finish 检查
        maybeEnqueueReadyItemsOnMain()
        maybeFinishIfDoneOnMain()
    }

    @MainActor
    private func storePrepared(url: URL, seq: Int) {
        pendingAudioBySeq[seq] = url
        maybeEnqueueReadyItemsOnMain()
        maybeFinishIfDoneOnMain()
    }

    /// Enqueue prepared audio in strict seq order.
    private func maybeEnqueueReadyItemsOnMain() {
        while let url = pendingAudioBySeq[nextEnqueueSeq] {
            pendingAudioBySeq.removeValue(forKey: nextEnqueueSeq)
            let seq = nextEnqueueSeq
            nextEnqueueSeq += 1

            guard let slice = sliceBySeq[seq] else {
                // If meta missing, we can still enqueue audio, but we can't sync by char index.
                if url != Self.failedMarkerURL {
                    enqueueItem(url: url, slice: nil)
                }
                continue
            }

            if url == Self.failedMarkerURL {
                // TTS failed: treat this slice as instantly "spoken" so text doesn't freeze.
                onSpokenCharIndex?(slice.charEnd)
                continue
            }

            enqueueItem(url: url, slice: slice)
        }

        // If we have items queued but not playing, start playback.
        if !player.items().isEmpty && player.timeControlStatus != .playing {
            player.play()
        }
    }

    private func enqueueItem(url: URL, slice: TTSSlicer.Slice?) {
        let item = AVPlayerItem(url: url)

        if let slice {
            sliceByItemID[ObjectIdentifier(item)] = slice
        }

        // Append to the end of the queue
        if let last = player.items().last {
            player.insert(item, after: last)
        } else if let current = player.currentItem {
            player.insert(item, after: current)
        } else {
            player.insert(item, after: nil)
        }
    }

    private func prepareAudioFile(for text: String) async throws -> URL {
        guard let ttsClient else {
            throw NSError(domain: "GlobalSpeechPlayer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing OpenAIConfig for TTS"])
        }
        let req = OpenAITTSClient.Request(
            model: ttsModel,
            voice: ttsVoice,
            input: text,
            speed: ttsSpeed,
            format: ttsFormat
        )
        return try await ttsClient.synthesize(req)
    }

    private func maybeFinishIfDoneOnMain() {
        guard isFinalized else { return }

        let noPending = pendingAudioBySeq.isEmpty
        let nothingQueued = player.items().isEmpty
        let nothingPlaying = (player.currentItem == nil)

        if noPending && nothingQueued && nothingPlaying {
            isSpeaking = false
            onAllAudioFinished?()
        }
    }
}

/// Optional alias if old code still references `GlobalAudioPlayer`.
public typealias GlobalAudioPlayer = GlobalSpeechPlayer

