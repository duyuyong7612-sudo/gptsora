// AduVoiceService.swift
// 纯音频端到端：录音 → 后端 → RunPod A100 → 播放
// 使用方法：在 HomeChatView 里调用 AduVoiceService.shared.sendAndPlay()

// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-d20c47f8f9286807f63568bf9d55a543dae9c274adddd96eeb9172621576c50f"
// Source-SHA256: "397894510450baed4776d5a088a56ef364129b8550ff6210e3f6dc4354fd9969"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation
import AVFoundation
import Combine

@MainActor
final class AduVoiceService: NSObject, ObservableObject {
    static let shared = AduVoiceService()

    @Published var isRecording = false
    @Published var isProcessing = false
    @Published var errorMsg: String?

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var recordingURL: URL?

    // ── 录音 ──────────────────────────────────────────
    func startRecording() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
        try? session.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("adu_input_\(UUID().uuidString).m4a")
        recordingURL = url

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]

        recorder = try? AVAudioRecorder(url: url, settings: settings)
        recorder?.record()
        isRecording = true
    }

    func stopRecordingAndSend(apiBase: String) {
        recorder?.stop()
        isRecording = false

        guard let url = recordingURL else { return }

        isProcessing = true
        errorMsg = nil

        Task {
            do {
                let wavData = try await sendToAduBridge(apiBase: apiBase, audioURL: url)
                await playAudio(data: wavData)
            } catch {
                errorMsg = error.localizedDescription
            }
            isProcessing = false
        }
    }

    // ── 发送到后端 /adu_voice ──────────────────────────
    private func sendToAduBridge(apiBase: String, audioURL: URL) async throws -> Data {
        let url = URL(string: "\(apiBase)/adu_voice")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // 加 user_key（和其他接口保持一致）
        if let userKey = UserDefaults.standard.string(forKey: "user_key") {
            request.setValue(userKey, forHTTPHeaderField: "X-User-Key")
        }

        let audioData = try Data(contentsOf: audioURL)
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"input.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "AduVoice", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "bridge error"])
        }
        return data
    }

    // ── 播放返回的音频 ──────────────────────────────────
    private func playAudio(data: Data) async {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("adu_reply_\(UUID().uuidString).wav")
        try? data.write(to: tmpURL)

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback)
        try? session.setActive(true)

        player = try? AVAudioPlayer(contentsOf: tmpURL)
        player?.play()
    }
}

