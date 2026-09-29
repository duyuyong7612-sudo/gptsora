// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-8efac0c5989050ef6bcf2c893da033c745c6c382bbd11e2d2b3bdc9f015c3fae"
// Source-SHA256: "30d57ad59e9655b3a8b8a6a864c3fb42fd0f051efd63bd2ff4765c24afae4384"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation
import Combine
import AVFoundation

/// 播放本地音频（用于录音回放等）
@MainActor
public final class GlobalAudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {

    public static let shared = GlobalAudioPlayer()

    @Published public private(set) var isPlaying: Bool = false
    @Published public private(set) var currentURL: URL? = nil

    private var player: AVAudioPlayer?

    private override init() {
        super.init()
    }

    public func play(fileURL: URL) {
        stop()

        do {
            try configureAudioSessionForPlayback()
            let p = try AVAudioPlayer(contentsOf: fileURL)
            p.delegate = self
            p.prepareToPlay()
            p.play()

            player = p
            currentURL = fileURL
            isPlaying = true
        } catch {
            isPlaying = false
            currentURL = nil
        }
    }

    public func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        currentURL = nil
    }

    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
        }
    }

    private func configureAudioSessionForPlayback() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.duckOthers])
        try session.setActive(true, options: [])
    }
}

