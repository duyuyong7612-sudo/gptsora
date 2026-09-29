// VoiceCloneView.swift
// 用户录制声音 → 上传 → 阿杜用你的声音说话
// 设计：沉浸式录音体验，像录制一份给未来的礼物

// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-78974aa07f1c34a8927feb0af1d2ea62eb7e1c61066b3b6cb901400ebcb6af18"
// Source-SHA256: "f9af11c139dd532a32d691255e3d3b65f06db6facc51cc32201a1051cb27ed33"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI
import AVFoundation
import Combine

// MARK: - 录音管理器

class VoiceRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {

    @Published var isRecording = false
    @Published var recordingTime: TimeInterval = 0
    @Published var audioLevel: Float = 0      // 0.0 ~ 1.0 音量可视化
    @Published var recordingURL: URL?
    @Published var error: String?

    private var recorder: AVAudioRecorder?
    private var timer: AnyCancellable?
    private let targetDuration: TimeInterval = 30  // 30秒目标

    var progress: Double {
        min(recordingTime / targetDuration, 1.0)
    }

    var timeString: String {
        let s = Int(recordingTime)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    func requestPermission(completion: @escaping (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    func startRecording() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.record, mode: .default)
        try? session.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice_sample_\(Date().timeIntervalSince1970).m4a")

        let settings: [String: Any] = [
            AVFormatIDKey:            Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey:          44100,
            AVNumberOfChannelsKey:    1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.delegate = self
            recorder?.isMeteringEnabled = true
            recorder?.record()

            recordingURL = url
            isRecording = true
            recordingTime = 0

            // 计时 + 音量更新
            timer = Timer.publish(every: 0.1, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in
                    guard let self else { return }
                    self.recordingTime += 0.1
                    self.recorder?.updateMeters()
                    let power = self.recorder?.averagePower(forChannel: 0) ?? -60
                    // 把 dB 值 (-60 ~ 0) 转成 0~1
                    self.audioLevel = max(0, min(1, (power + 60) / 60))

                    // 超过60秒自动停止
                    if self.recordingTime >= 60 { self.stopRecording() }
                }
        } catch {
            self.error = "无法开始录音: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        recorder?.stop()
        timer?.cancel()
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    func reset() {
        recorder?.stop()
        timer?.cancel()
        isRecording = false
        recordingTime = 0
        audioLevel = 0
        recordingURL = nil
        error = nil
    }
}

// MARK: - 上传管理器

class VoiceCloneUploader: ObservableObject {

    @Published var uploadStatus: UploadStatus = .idle
    @Published var clonedVoiceId: String?

    enum UploadStatus {
        case idle
        case uploading
        case success(String)  // voice_id
        case failed(String)
    }

    private let backendURL = AppConfig.API.apiBase

    func upload(audioURL: URL, userId: String, voiceName: String) async {
        await MainActor.run { uploadStatus = .uploading }

        guard let url = URL(string: "\(backendURL)/voice/clone") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")

        var body = Data()

        // user_id
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"user_id\"\r\n\r\n")
        body.append("\(userId)\r\n")

        // voice_name
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"voice_name\"\r\n\r\n")
        body.append("\(voiceName)\r\n")

        // audio file
        if let audioData = try? Data(contentsOf: audioURL) {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"voice.m4a\"\r\n")
            body.append("Content-Type: audio/m4a\r\n\r\n")
            body.append(audioData)
            body.append("\r\n")
        }
        body.append("--\(boundary)--\r\n")

        request.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            if status == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let voiceId = json["voice_id"] as? String {
                await MainActor.run {
                    clonedVoiceId = voiceId
                    uploadStatus = .success(voiceId)
                }
            } else {
                await MainActor.run {
                    uploadStatus = .failed("上传失败，请重试")
                }
            }
        } catch {
            await MainActor.run {
                uploadStatus = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - 主界面

struct VoiceCloneView: View {

    @StateObject private var recorder  = VoiceRecorder()
    @StateObject private var uploader  = VoiceCloneUploader()
    @State private var phase: Phase    = .intro
    @State private var hasPermission   = false
    @State private var voiceName       = "我的声音"
    @Environment(\.dismiss) private var dismiss

    enum Phase {
        case intro       // 介绍页
        case recording   // 录音中
        case preview     // 录完预览
        case uploading   // 上传中
        case done        // 完成
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch phase {
            case .intro:    introView
            case .recording: recordingView
            case .preview:  previewView
            case .uploading: uploadingView
            case .done:     doneView
            }
        }
        .onAppear {
            recorder.requestPermission { granted in
                hasPermission = granted
            }
        }
    }

    // MARK: 介绍页

    var introView: some View {
        VStack(spacing: 32) {
            Spacer()

            VStack(spacing: 16) {
                Text("🎙️")
                    .font(.system(size: 64))

                Text("录制你的声音")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.white)

                Text("阿杜将用你的声音说话\n就像另一个你真的在说话")
                    .font(.system(size: 16))
                    .foregroundColor(Color(hex: "888888"))
                    .multilineTextAlignment(.center)
                    .lineSpacing(6)
            }

            // 说明卡片
            VStack(alignment: .leading, spacing: 14) {
                TipRow(icon: "clock", text: "录制30秒以上效果最好")
                TipRow(icon: "mic.fill", text: "找安静的地方，自然说话")
                TipRow(icon: "text.bubble", text: "可以念文章、聊天、随便说")
                TipRow(icon: "lock.fill", text: "声音数据仅用于你的阿杜")
            }
            .padding(20)
            .background(Color(hex: "111111"))
            .cornerRadius(16)
            .padding(.horizontal, 24)

            Spacer()

            // 开始按钮
            Button(action: {
                guard hasPermission else { return }
                recorder.startRecording()
                withAnimation { phase = .recording }
            }) {
                HStack(spacing: 10) {
                    Image(systemName: "mic.fill")
                    Text("开始录音")
                        .fontWeight(.semibold)
                }
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(Color.white)
                .cornerRadius(14)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
            .disabled(!hasPermission)
        }
    }

    // MARK: 录音界面

    var recordingView: some View {
        VStack(spacing: 0) {
            Spacer()

            // 音量可视化
            WaveformView(level: recorder.audioLevel)
                .frame(height: 120)
                .padding(.horizontal, 40)

            Spacer().frame(height: 40)

            // 时间
            Text(recorder.timeString)
                .font(.system(size: 64, weight: .thin, design: .monospaced))
                .foregroundColor(.white)

            // 进度条
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(hex: "222222"))
                        .frame(height: 4)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(hex: "00FF87"))
                        .frame(width: geo.size.width * recorder.progress, height: 4)
                        .animation(.linear(duration: 0.1), value: recorder.progress)
                }
            }
            .frame(height: 4)
            .padding(.horizontal, 40)
            .padding(.top, 16)

            Text(recorder.progress >= 1.0 ? "已达到推荐时长 ✓" : "推荐录制30秒以上")
                .font(.system(size: 13))
                .foregroundColor(recorder.progress >= 1.0
                                 ? Color(hex: "00FF87")
                                 : Color(hex: "666666"))
                .padding(.top, 8)

            Spacer()

            // 停止按钮
            Button(action: {
                recorder.stopRecording()
                withAnimation { phase = .preview }
            }) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.3), lineWidth: 2)
                        .frame(width: 80, height: 80)

                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white)
                        .frame(width: 28, height: 28)
                }
            }
            .padding(.bottom, 60)
        }
    }

    // MARK: 预览页

    var previewView: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(Color(hex: "00FF87"))

            VStack(spacing: 8) {
                Text("录制完成")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)

                Text("已录制 \(Int(recorder.recordingTime)) 秒")
                    .font(.system(size: 15))
                    .foregroundColor(Color(hex: "888888"))
            }

            // 声音名称
            VStack(alignment: .leading, spacing: 8) {
                Text("给这个声音起个名字")
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "666666"))

                TextField("", text: $voiceName)
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .padding(12)
                    .background(Color(hex: "111111"))
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(hex: "222222"), lineWidth: 1)
                    )
            }
            .padding(.horizontal, 32)

            Spacer()

            VStack(spacing: 12) {
                // 上传按钮
                Button(action: {
                    guard let url = recorder.recordingURL else { return }
                    withAnimation { phase = .uploading }
                    Task {
                        await uploader.upload(
                            audioURL: url,
                            userId: "adu_system",
                            voiceName: voiceName
                        )
                        await MainActor.run {
                            withAnimation { phase = .done }
                        }
                    }
                }) {
                    Text("让阿杜学习我的声音")
                        .fontWeight(.semibold)
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(Color.white)
                        .cornerRadius(14)
                }

                // 重录按钮
                Button(action: {
                    recorder.reset()
                    withAnimation { phase = .recording }
                    recorder.startRecording()
                }) {
                    Text("重新录制")
                        .foregroundColor(Color(hex: "666666"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }

    // MARK: 上传中

    var uploadingView: some View {
        VStack(spacing: 24) {
            Spacer()

            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(1.5)

            Text("阿杜正在学习你的声音...")
                .font(.system(size: 17))
                .foregroundColor(.white)

            Text("通常需要10-30秒")
                .font(.system(size: 14))
                .foregroundColor(Color(hex: "666666"))

            Spacer()
        }
    }

    // MARK: 完成

    var doneView: some View {
        VStack(spacing: 32) {
            Spacer()

            Text("🎉")
                .font(.system(size: 80))

            VStack(spacing: 12) {
                Text("声音克隆完成")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.white)

                Text("从现在开始\n阿杜会用你的声音说话")
                    .font(.system(size: 16))
                    .foregroundColor(Color(hex: "888888"))
                    .multilineTextAlignment(.center)
                    .lineSpacing(6)
            }

            // 测试播放提示
            Text("去跟阿杜说句话，听听他的声音变了没有")
                .font(.system(size: 14))
                .foregroundColor(Color(hex: "00FF87"))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()

            Button(action: { dismiss() }) {
                Text("完成")
                    .fontWeight(.semibold)
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(Color.white)
                    .cornerRadius(14)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }
}

// MARK: - 子组件

struct TipRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(Color(hex: "00FF87"))
                .frame(width: 20)
            Text(text)
                .font(.system(size: 14))
                .foregroundColor(Color(hex: "AAAAAA"))
        }
    }
}

struct WaveformView: View {
    let level: Float
    private let barCount = 40

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { i in
                WaveBar(index: i, level: level, total: barCount)
            }
        }
    }
}

struct WaveBar: View {
    let index: Int
    let level: Float
    let total: Int

    private var height: CGFloat {
        let center = Double(total) / 2
        let dist   = abs(Double(index) - center) / center
        let base   = CGFloat(1.0 - dist * 0.6)
        let noise  = CGFloat.random(in: 0.8...1.2)
        return base * CGFloat(max(0.05, level)) * 80 * noise
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color(hex: "00FF87"))
            .frame(width: 3, height: max(4, height))
            .animation(.easeInOut(duration: 0.1), value: level)
    }
}

// MARK: - Data 扩展

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}

// MARK: - Color 扩展（如项目已有请删除）
// extension Color { init(hex: String) { ... } }

// MARK: - Preview

struct VoiceCloneView_Previews: PreviewProvider {
    static var previews: some View {
        VoiceCloneView()
            .preferredColorScheme(.dark)
    }
}


