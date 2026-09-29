//
//  2ContentView.swift  (SUBMODULE 2)
//  ✅ RealtimeVoiceClient + RealtimeGateController (Realtime ONLY)
//  ✅ Bus ONLY: Realtime -> SoraIntentBus.emit(prompt)
//  ❌ No Paywall / No RevenueCat / No billing.startVoice/endVoice here
//  ✅ Main module (ContentView) is the ONLY consumer that triggers submit/enqueue
//

// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-bbd113c7f053812ff64d06773797fb33cf80e1cfaeae5f9f4c9cb0453edb13cf"
// Source-SHA256: "00909d3c2bc96ad5ead37f2de1c33796d17a5bc60ce94ebddf664f8c25d77299"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation
import SwiftUI
import Combine

// =====================================================
// MARK: - Sora intent bus (Realtime -> Main ContentView)
// =====================================================
final class SoraIntentBus {
    static let shared = SoraIntentBus()
    private init() {}

    fileprivate let subject = PassthroughSubject<String, Never>()
    var publisher: AnyPublisher<String, Never> { subject.eraseToAnyPublisher() }

    func emit(_ prompt: String) {
        let t = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        subject.send(t)
    }
}

// =====================================================
// MARK: - Realtime client wrapper
// =====================================================
enum RealtimeStopReason: Equatable {
    case user
    case remote
    case error(String)
}

final class RealtimeVoiceClient: NSObject, RealtimeQuickServiceDelegate {
    static let shared = RealtimeVoiceClient()

    private enum InternalState {
        case idle
        case starting
        case running
        case stopping
    }

    private let q = DispatchQueue(label: "solara.realtime.voiceclient.serial")
    private var state: InternalState = .idle
    private var stopRequested: Bool = false

    var onTranscript: ((String) -> Void)?
    var onDidStop: ((RealtimeStopReason) -> Void)?
    var onDidConnect: (() -> Void)?
    var onStatus: ((String) -> Void)?
    var onSoraIntent: ((String, String) -> Void)?

    private override init() {
        super.init()
        RealtimeQuickService.shared.delegate = self
    }

    func start() {
        q.async {
            guard self.state == .idle else { return }
            self.state = .starting
            self.stopRequested = false

            DispatchQueue.main.async {
                RealtimeQuickService.shared.delegate = self
                RealtimeQuickService.shared.startCall()
            }
        }
    }

    func stop() {
        q.async {
            guard self.state == .starting || self.state == .running else { return }
            self.stopRequested = true
            self.state = .stopping

            DispatchQueue.main.async {
                RealtimeQuickService.shared.stopCall()
            }
        }
    }

    // MARK: - Delegate
    func realtimeServiceDidConnect(_ svc: RealtimeQuickService) {
        q.async { self.state = .running }
        DispatchQueue.main.async { self.onDidConnect?() }
    }

    func realtimeServiceDidDisconnect(_ svc: RealtimeQuickService) {
        q.async {
            let reason: RealtimeStopReason = self.stopRequested ? .user : .remote
            self.stopRequested = false
            self.state = .idle
            DispatchQueue.main.async { self.onDidStop?(reason) }
        }
    }

    func realtimeService(_ svc: RealtimeQuickService, didUpdateStatus text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        DispatchQueue.main.async { self.onStatus?(t) }
    }

    func realtimeService(_ svc: RealtimeQuickService, didUpdateTranscript text: String) {
        DispatchQueue.main.async { self.onTranscript?(text) }
    }

    func realtimeService(_ svc: RealtimeQuickService, didFailWith error: Error) {
        q.async {
            self.stopRequested = false
            self.state = .idle
            let msg = (error as NSError).localizedDescription
            DispatchQueue.main.async { self.onDidStop?(.error(msg)) }
        }
    }

    func realtimeService(_ svc: RealtimeQuickService,
                         didTriggerSoraWithUserPrompt userPrompt: String,
                         assistantSummary: String) {
        DispatchQueue.main.async {
            self.onSoraIntent?(userPrompt, assistantSummary)
        }
    }
}

// =====================================================
// MARK: - Realtime controller (Realtime state only)
// =====================================================
@MainActor
final class RealtimeGateController: ObservableObject {
    static let shared = RealtimeGateController()

    @Published private(set) var isConnecting: Bool = false
    @Published private(set) var isRunning: Bool = false
    @Published var transcript: String = ""
    @Published var hint: String = ""
    var onUserFinalTranscript: ((String) -> Void)?

    private enum Phase {
        case idle
        case connecting
        case live
        case stopping
    }

    private var phase: Phase = .idle
    private var didSetup = false
    private let client = RealtimeVoiceClient.shared

    private var pendingConnectAfterStop: Bool = false

    private let transcriptSubject = PassthroughSubject<String, Never>()
    private var cancellables: Set<AnyCancellable> = []

    func setupOnceIfNeeded() {
        guard !didSetup else { return }
        didSetup = true

        // 0) 高频 transcript：限频 + 去重 + 限长（商用不卡顿关键）
        transcriptSubject
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .removeDuplicates()
            .throttle(for: .milliseconds(120), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] text in
                guard let self else { return }
                guard !text.isEmpty else { return }
                self.hint = ""
                self.transcript = self.clampTranscript(text)
            }
            .store(in: &cancellables)

        // 1) transcript
        client.onTranscript = { [weak self] text in
            if text.hasPrefix("[U]") {
                let userText = String(text.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !userText.isEmpty {
                    Task { @MainActor in
                        self?.onUserFinalTranscript?(userText)
                    }
                }
            }
            self?.transcriptSubject.send(text)
        }

        // 2) status
        client.onStatus = { [weak self] status in
            guard let self else { return }
            // 只有在没有字幕时才显示 status，避免抢占
            if self.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.hint = status
            }
        }

        // 3) connect
        client.onDidConnect = { [weak self] in
            guard let self else { return }
            self.phase = .live
            self.isConnecting = false
            self.isRunning = true
            if self.hint.isEmpty { self.hint = "Connected" }
        }

        // 4) stop (user/remote/error)
        client.onDidStop = { [weak self] reason in
            guard let self else { return }

            self.phase = .idle
            self.isConnecting = false
            self.isRunning = false

            switch reason {
            case .user:
                self.hint = ""
            case .remote:
                self.hint = "Disconnected"
            case .error(let msg):
                self.hint = msg.isEmpty ? "Voice error" : msg
            }

            // 停止期间用户点过“开始”，这里自动续上（避免竞态导致 UI 回跳）
            if self.pendingConnectAfterStop {
                self.pendingConnectAfterStop = false
                Task { @MainActor in
                    self.connect()
                }
            }
        }

        // 5) ✅ Sora intent: Realtime -> Bus (Main module consumes)
        client.onSoraIntent = { userPrompt, assistantSummary in
            let finalPrompt = assistantSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? userPrompt
            : assistantSummary
            SoraIntentBus.shared.emit(finalPrompt)
        }
    }

    // MARK: - Public controls (no billing here)
    func connect() {
        setupOnceIfNeeded()

        switch phase {
        case .idle:
            phase = .connecting
            isConnecting = true
            isRunning = false
            hint = "Connecting…"
            transcript = ""
            client.start()

        case .stopping:
            // ✅ stop 过程中点开始：排队，等 stop 结束自动 connect
            pendingConnectAfterStop = true
            hint = "Stopping…"
            return

        case .connecting, .live:
            return
        }
    }

    func disconnect() {
        pendingConnectAfterStop = false

        switch phase {
        case .idle:
            isConnecting = false
            isRunning = false
            return
        case .stopping:
            return
        case .connecting, .live:
            phase = .stopping
            isConnecting = false
            // 这里不强行清 transcript，让用户看到最后字幕/更稳定
            hint = "Disconnecting…"
            client.stop()
        }
    }

    func toggle() {
        if isConnecting || isRunning { disconnect() }
        else { connect() }
    }

    private func clampTranscript(_ s: String) -> String {
        // ✅ 防止超长文本导致 SwiftUI layout & diff 变慢
        let maxChars = 700
        guard s.count > maxChars else { return s }
        let idx = s.index(s.endIndex, offsetBy: -maxChars)
        return "…" + String(s[idx...])
    }
}
