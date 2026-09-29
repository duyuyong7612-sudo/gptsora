// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-a34105d22bcc073893c9fbdc100bf4ebdf35929fa8eeae1f526bd542b519b312"
// Source-SHA256: "c81acab4ba94d3dbb8d2007f748bead9367167d298741483cb4c6152d6ea46f1"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation
import AVFoundation
import Combine

/// Minimal audio recorder used by the chat UI.
/// If you already have your own recorder, you can delete this file.
public final class AudioNoteRecorder: NSObject, ObservableObject {
    @Published public private(set) var isRecording: Bool = false
    @Published public private(set) var lastRecordingURL: URL?

    private var recorder: AVAudioRecorder?

    public func start() throws {
        if isRecording { return }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("note_\(UUID().uuidString).m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]

        let rec = try AVAudioRecorder(url: url, settings: settings)
        rec.isMeteringEnabled = true
        rec.prepareToRecord()
        rec.record()

        recorder = rec
        isRecording = true
        lastRecordingURL = nil
    }

    public func stop() {
        guard isRecording else { return }
        recorder?.stop()
        lastRecordingURL = recorder?.url
        recorder = nil
        isRecording = false
    }
}

