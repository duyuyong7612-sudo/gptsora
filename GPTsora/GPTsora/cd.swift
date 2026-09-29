// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-f421bdb070e6782ed935e0ccf3d818abee44ab09cda79537d459d77639c15155"
// Source-SHA256: "0436d25b37b2b5c7413ba603783aaf230942b7c175fd9232c398a6fc56460194"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI
import AVFoundation
import UIKit
import WebKit

// MARK: - AudioNoteRecorder
// 改进点：
// - 可配置参数（采样间隔/波形窗口/最长与最短时长/静音自动停录）
// - 录音文件统一落在 Caches/VoiceNotes
// - 背景任务保护（App 进后台时尽量保持）
// - 更稳健的音频会话配置与通知处理
// - 自动静音停录（可选）
// - 最小时长过滤（短于阈值自动丢弃，不占用缓存）
// - 最长时长自动停止
// - 便捷工具：清理旧文件、当前文件大小、当前URL查询等
// - 不破坏原有 API：stopAndMarkPending / stagePendingForUpload / finalize / restore / clear / cancel

@MainActor
final class AudioNoteRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {

    struct Config {
        var sampleInterval: TimeInterval = 0.06
        var waveCount: Int = 32

        // 录制最长时长（秒）。<= 0 表示不限时（不建议真正不限）
        var maxDuration: TimeInterval = 60.0

        // 小于该时长自动丢弃（避免误触产生很多极短无效文件）
        var minKeepDuration: TimeInterval = 0.5

        // 静音自动停录（当已超过 minKeepDuration 后）
        var enableSilenceAutoStop: Bool = true
        // 静音阈值（dB，-60~0，越小越“静”）
        var silenceDBThreshold: Float = -45.0
        // 静音持续时间窗口（秒）
        var silenceWindow: TimeInterval = 1.5

        // 低通平滑时间常数（秒），越大越平滑
        var smoothingTimeConstant: TimeInterval = 0.15
    }

    @Published private(set) var isRecording: Bool = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var waveformSamples: [CGFloat] = Array(repeating: 0.12, count: 32)

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var smoothLevel: CGFloat = 0.12

    private(set) var pendingFileURL: URL? = nil
    private(set) var pendingDuration: TimeInterval = 0
    var hasPendingNote: Bool { pendingFileURL != nil }

    private(set) var stagedFileURL: URL? = nil
    private(set) var stagedDuration: TimeInterval = 0

    private var observers: [NSObjectProtocol] = []

    // 背景任务保护
    private var bgTaskID: UIBackgroundTaskIdentifier = .invalid

    // 配置
    private var config: Config

    // 静音检测
    private var continuousSilenceStart: Date?

    var durationText: String {
        let t: TimeInterval
        if isRecording { t = duration }
        else if hasPendingNote { t = pendingDuration }
        else { t = stagedDuration }
        let sec = Int(t.rounded())
        return String(format: "%02d:%02d", sec / 60, sec % 60)
    }

    // MARK: - Init / Deinit

    init(config: Config = Config()) {
        self.config = config
        super.init()
        observeNotifications()
    }

    deinit {
        timer?.invalidate()
        timer = nil
        for ob in observers {
            NotificationCenter.default.removeObserver(ob)
        }
        observers.removeAll()
        endBackgroundTaskIfNeeded()
    }

    // MARK: - Public Controls

    func start() async throws {
        if isRecording { return }

        let ok = await requestPermission()
        if !ok {
            throw NSError(domain: "AudioNoteRecorder", code: -10,
                          userInfo: [NSLocalizedDescriptionKey: "麦克风未授权"])
        }

        try prepareSession()

        let url = try makeNewRecordingURL()
        let rec = try makeRecorder(url: url)
        recorder = rec

        let success: Bool
        if config.maxDuration > 0 {
            success = rec.record(forDuration: config.maxDuration)
        } else {
            success = rec.record()
        }
        if !success {
            recorder = nil
            throw NSError(domain: "AudioNoteRecorder", code: -11,
                          userInfo: [NSLocalizedDescriptionKey: "录音启动失败"])
        }

        // 状态复位
        isRecording = true
        duration = 0
        smoothLevel = 0.12
        waveformSamples = Array(repeating: 0.12, count: config.waveCount)
        continuousSilenceStart = nil

        // 定时器
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: config.sampleInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let t = timer {
            RunLoop.main.add(t, forMode: .common)
        }

        beginBackgroundTaskIfNeeded()
        HomeHaptics.light()
    }

    func stopAndMarkPending() {
        guard isRecording else { return }
        recorder?.stop() // 如果是系统自动停，重复 stop 也安全
        finalizeToPending()
    }

    func stagePendingForUpload() -> (url: URL, duration: TimeInterval)? {
        guard let url = pendingFileURL else { return nil }
        stagedFileURL = url
        stagedDuration = pendingDuration
        pendingFileURL = nil
        pendingDuration = 0
        return (url, stagedDuration)
    }

    func finalizeStaged(deleteFile: Bool) {
        if deleteFile, let url = stagedFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        stagedFileURL = nil
        stagedDuration = 0
    }

    func restoreStagedToPending() {
        guard pendingFileURL == nil else { return }
        pendingFileURL = stagedFileURL
        pendingDuration = stagedDuration
        stagedFileURL = nil
        stagedDuration = 0
    }

    func clearPending() {
        if let url = pendingFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        pendingFileURL = nil
        pendingDuration = 0
    }

    func cancel() {
        if isRecording {
            recorder?.stop()
            finalizeToPending() // 先转为 pending，再丢弃
        }
        if let url = recorder?.url {
            try? FileManager.default.removeItem(at: url)
        }
        recorder = nil
        duration = 0

        clearPending()
        stagedFileURL = nil
        stagedDuration = 0

        endBackgroundTaskIfNeeded()
    }

    // 查询当前（录制中/待发/已暂存）的文件URL（便于调试或预览）
    func currentNoteURL() -> URL? {
        if isRecording { return recorder?.url }
        if let p = pendingFileURL { return p }
        return stagedFileURL
    }

    // 当前文件大小（字节）
    func currentFileSize() -> Int64 {
        guard let url = currentNoteURL() else { return 0 }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // 手动清理过旧文件（默认清理 7 天前）
    func cleanupOldVoiceNotes(olderThan days: Int = 7) {
        let dir = voiceNotesDirectory()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return }
        let threshold = Date().addingTimeInterval(-TimeInterval(days) * 24 * 3600)
        for f in files {
            if let vals = try? f.resourceValues(forKeys: [.contentModificationDateKey]),
               let d = vals.contentModificationDate, d < threshold {
                try? fm.removeItem(at: f)
            }
        }
    }

    // MARK: - Timer Tick

    private func tick() {
        guard isRecording, let r = recorder else { return }
        duration = r.currentTime

        r.updateMeters()
        let db = r.averagePower(forChannel: 0)
        let level = normalizePower(db)

        // 平滑：根据时间常数与采样间隔，推导 alpha
        let dt = config.sampleInterval
        let tau = max(0.01, config.smoothingTimeConstant)
        let alpha = CGFloat(dt / (tau + dt)) // 0~1
        smoothLevel = smoothLevel * (1 - alpha) + level * alpha
        pushWaveSample(smoothLevel)

        // 静音自动停录
        if config.enableSilenceAutoStop,
           duration >= config.minKeepDuration {
            if db <= config.silenceDBThreshold {
                if continuousSilenceStart == nil {
                    continuousSilenceStart = Date()
                } else if let start = continuousSilenceStart,
                          Date().timeIntervalSince(start) >= config.silenceWindow {
                    stopAndMarkPending()
                }
            } else {
                continuousSilenceStart = nil
            }
        }
    }

    // MARK: - AVAudioRecorderDelegate

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        // 系统回调的结束（如超时停止/外部打断停止等）
        if isRecording {
            finalizeToPending()
        }
        if !flag {
            // 编码失败时也保持 pending，以便外层决定是否重试/删除
        }
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        if isRecording {
            finalizeToPending()
        }
    }

    // MARK: - Notifications

    private func observeNotifications() {
        let center = NotificationCenter.default

        let ob1 = center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            self?.handleInterruption(note)
        }
        observers.append(ob1)

        let ob2 = center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            self?.handleRouteChange(note)
        }
        observers.append(ob2)

        let ob3 = center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.beginBackgroundTaskIfNeeded()
        }
        observers.append(ob3)

        let ob4 = center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.endBackgroundTaskIfNeeded()
        }
        observers.append(ob4)
    }

    private func handleInterruption(_ notification: Notification) {
        guard isRecording else { return }
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        if type == .began {
            stopAndMarkPending()
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard isRecording else { return }
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        if reason == .oldDeviceUnavailable {
            // 如耳机被拔出，停止并保留
            stopAndMarkPending()
        }
    }

    // MARK: - Session / Recorder

    private func prepareSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
        try session.setActive(true, options: [])
    }

    private func makeRecorder(url: URL) throws -> AVAudioRecorder {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let rec = try AVAudioRecorder(url: url, settings: settings)
        rec.delegate = self
        rec.isMeteringEnabled = true
        rec.prepareToRecord()
        return rec
    }

    private func makeNewRecordingURL() throws -> URL {
        let dir = voiceNotesDirectory()
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("voice_note_\(UUID().uuidString).m4a")
    }

    private func voiceNotesDirectory() -> URL {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return cacheDir.appendingPathComponent("VoiceNotes", isDirectory: true)
    }

    // MARK: - State finalize

    private func finalizeToPending() {
        timer?.invalidate(); timer = nil
        isRecording = false
        continuousSilenceStart = nil

        let fileURL = recorder?.url
        let dur = duration

        recorder = nil
        duration = 0

        // 最小时长过滤（防止短按）
        if dur < config.minKeepDuration, let url = fileURL {
            try? FileManager.default.removeItem(at: url)
            pendingFileURL = nil
            pendingDuration = 0
            endBackgroundTaskIfNeeded()
            return
        }

        pendingFileURL = fileURL
        pendingDuration = dur
        endBackgroundTaskIfNeeded()
    }

    // MARK: - Background Task

    private func beginBackgroundTaskIfNeeded() {
        guard isRecording, bgTaskID == .invalid else { return }
        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "AudioNoteRecording") { [weak self] in
            // 到期回调：尽快停止并标记
            self?.stopAndMarkPending()
            self?.endBackgroundTaskIfNeeded()
        }
    }

    private func endBackgroundTaskIfNeeded() {
        if bgTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(bgTaskID)
            bgTaskID = .invalid
        }
    }

    // MARK: - Helpers

    private func normalizePower(_ db: Float) -> CGFloat {
        let clamped = max(-60, min(0, db))
        let linear = pow(10, clamped / 20)
        return CGFloat(max(0.08, min(1.0, linear)))
    }

    private func pushWaveSample(_ v: CGFloat) {
        var s = waveformSamples
        s.append(v)
        if s.count > config.waveCount { s.removeFirst(s.count - config.waveCount) }
        waveformSamples = s
    }

    private func requestPermission() async -> Bool {
        let perm = AVAudioSession.sharedInstance().recordPermission
        switch perm {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { cont in
                AVAudioSession.sharedInstance().requestRecordPermission { ok in
                    cont.resume(returning: ok)
                }
            }
        @unknown default:
            return false
        }
    }
}

// MARK: - Haptics

enum HomeHaptics {
    static func light() {
        let gen = UIImpactFeedbackGenerator(style: .light)
        gen.prepare()
        gen.impactOccurred()
    }
}
// MARK: - UIImage helpers (缩放+压缩)

private extension UIImage {
    func resizedJPEGData(maxDimension: CGFloat, quality: CGFloat) -> Data? {
        let w = size.width
        let h = size.height
        let maxSide = max(w, h)
        guard maxSide > maxDimension else {
            return jpegData(compressionQuality: quality)
        }
        let scale = maxDimension / maxSide
        let newSize = CGSize(width: w * scale, height: h * scale)

        UIGraphicsBeginImageContextWithOptions(newSize, true, 1.0)
        defer { UIGraphicsEndImageContext() }
        draw(in: CGRect(origin: .zero, size: newSize))
        let img = UIGraphicsGetImageFromCurrentImageContext()
        return img?.jpegData(compressionQuality: quality)
    }
}

// MARK: - OfflineCodeHighlighterView（保持原样）

struct OfflineCodeHighlighterView: UIViewRepresentable {
    let code: String
    let language: String
    @Binding var dynamicHeight: CGFloat

    private static let cached: (js: String, css: String)? = {
        guard
            let jsURL = Bundle.main.url(forResource: "highlight.min", withExtension: "js"),
            let cssURL = Bundle.main.url(forResource: "atom-one-light.min", withExtension: "css"),
            let jsData = try? Data(contentsOf: jsURL),
            let cssData = try? Data(contentsOf: cssURL),
            var js = String(data: jsData, encoding: .utf8),
            let css = String(data: cssData, encoding: .utf8)
        else { return nil }

        js = js.replacingOccurrences(of: "</script", with: "<\\/script")
        return (js: js, css: css)
    }()

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.navigationDelegate = context.coordinator
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        guard let cached = Self.cached else {
            web.loadHTMLString("<pre>Missing hljs assets</pre>", baseURL: nil)
            return
        }

        let escaped = htmlEscape(code)
        let lang = language.trimmingCharacters(in: .whitespacesAndNewlines)
        let langClass = lang.isEmpty ? "" : "language-\(lang)"

        let html = """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <style>
            body { margin: 0; background: transparent; }
            pre {
              margin: 0; padding: 12px;
              border-radius: 12px;
              background: #f6f8fa;
              overflow-x: auto;
              font-family: ui-monospace, Menlo, Monaco, Consolas, "Courier New", monospace;
              font-size: 13.5px; line-height: 1.45;
            }
          </style>
          <style>\(cached.css)</style>
          <script>\(cached.js)</script>
        </head>
        <body>
          <pre><code class="\(langClass)">\(escaped)</code></pre>
          <script>
            try {
              var el = document.querySelector('pre code');
              if (window.hljs && el) { hljs.highlightElement(el); }
            } catch(e) {}
          </script>
        </body>
        </html>
        """

        web.loadHTMLString(html, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(dynamicHeight: $dynamicHeight)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var dynamicHeight: CGFloat
        init(dynamicHeight: Binding<CGFloat>) { _dynamicHeight = dynamicHeight }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("document.body.scrollHeight") { [weak self] result, _ in
                guard let self else { return }
                if let h = result as? Double {
                    DispatchQueue.main.async { self.dynamicHeight = max(44, CGFloat(h)) }
                }
            }
        }
    }

    private func htmlEscape(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: "&", with: "&amp;")
        t = t.replacingOccurrences(of: "<", with: "&lt;")
        t = t.replacingOccurrences(of: ">", with: "&gt;")
        t = t.replacingOccurrences(of: "\"", with: "&quot;")
        return t
    }
}
