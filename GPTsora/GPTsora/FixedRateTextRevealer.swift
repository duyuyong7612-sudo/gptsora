// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-f6b9721733451c3b9de1ef21801836b1c35d9a1246e785dec944ad26b7ef94b5"
// Source-SHA256: "1eefc00afc1ade1aba192f0535b2b863797c9ceb8943de3a4be871b7e1b44f91"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation
import Combine

/// SSE Buffer + NSTimer 定频显示
/// - 收到 delta 先写入 buffer
/// - 用 Timer 按固定频率/固定字符数“吐出”到 revealedText
/// - 支持「播报开始才放行文字」：gate 关闭时只缓冲不显示
/// - 支持音频同步上限（audioCap）：永远不显示超过音频已播到的位置
///
/// 备注：为了避免 MainActor 隔离导致的 stop() 调用报错，这里不把整个类标 @MainActor；
/// 内部统一在 main queue 修改状态与驱动 Timer。
public final class FixedRateTextRevealer: ObservableObject {
    @Published public private(set) var revealedText: String = ""
    @Published public private(set) var isRunning: Bool = false

    /// 外部想在每次 revealedText 更新时同步写回 ChatMessage，可用这个回调。
    public var onUpdate: ((String) -> Void)?

    private var buffer: String = ""
    private var timer: Timer?

    private var interval: TimeInterval
    private var charsPerTick: Int

    private var gateOpen: Bool = false

    /// 音频同步上限：最多显示到这个字符数（从 0 开始计数，基于 message 全文）。
    /// - 默认 Int.max（不限制）
    private var audioCap: Int = .max

    public init(fps: Double = 30, charsPerSecond: Double = 60) {
        let safeFps = max(5, min(60, fps))
        self.interval = 1.0 / safeFps
        self.charsPerTick = max(1, Int(round(charsPerSecond / safeFps)))
    }

    // MARK: - Public API

    public func setRate(fps: Double, charsPerSecond: Double) {
        onMain {
            let safeFps = max(5, min(60, fps))
            self.interval = 1.0 / safeFps
            self.charsPerTick = max(1, Int(round(charsPerSecond / safeFps)))
            if self.isRunning {
                self.restartTimer()
            }
        }
    }

    public func append(_ delta: String) {
        guard !delta.isEmpty else { return }
        onMain {
            self.buffer.append(delta)
            self.startIfNeeded()
        }
    }

    /// 设置音频同步上限（已经播到的字符位置）
    public func setAudioCap(_ cap: Int) {
        onMain {
            self.audioCap = max(0, cap)
        }
    }

    /// 播报开始才放行文字
    public func openGate() {
        onMain {
            self.gateOpen = true
            self.startIfNeeded()
        }
    }

    public func closeGate() {
        onMain { self.gateOpen = false }
    }

    /// 兜底：避免音频迟迟不来导致 UI 卡死
    public func openGateAfterTimeout(_ seconds: TimeInterval) {
        guard seconds > 0 else { openGate(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            if !self.gateOpen {
                self.openGate()
            }
        }
    }

    /// 停止定频吐字。flushAll=true 会立刻把 buffer 全部补齐到 revealedText。
    public func stop(flushAll: Bool) {
        onMain {
            self.timer?.invalidate()
            self.timer = nil
            self.isRunning = false
            if flushAll {
                self.revealedText.append(self.buffer)
                self.buffer.removeAll(keepingCapacity: true)
                self.onUpdate?(self.revealedText)
            }
        }
    }

    /// 强制补齐（不改变 gate 状态）
    public func forceRevealAll() {
        onMain {
            self.revealedText.append(self.buffer)
            self.buffer.removeAll(keepingCapacity: true)
            self.onUpdate?(self.revealedText)
        }
    }

    /// 清空所有状态（用于开始新一轮对话）
    public func reset() {
        onMain {
            self.timer?.invalidate()
            self.timer = nil
            self.isRunning = false
            self.buffer.removeAll(keepingCapacity: false)
            self.revealedText.removeAll(keepingCapacity: false)
            self.gateOpen = false
            self.audioCap = .max
            self.onUpdate?(self.revealedText)
        }
    }

    // MARK: - Internals

    private func startIfNeeded() {
        guard !isRunning else { return }
        // gate 关着时，不启动 Timer，避免空转；等 openGate 再启动
        guard gateOpen else { return }
        guard !buffer.isEmpty else { return }

        isRunning = true
        restartTimer()
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func tick() {
        // gate 关着：只缓冲
        guard gateOpen else { return }

        let already = revealedText.count
        let capRemain = max(0, audioCap - already)
        if capRemain == 0 { return } // 不能超过音频已播到的位置

        guard !buffer.isEmpty else {
            stop(flushAll: false)
            return
        }

        let canTake = min(charsPerTick, capRemain, buffer.count)
        if canTake <= 0 { return }

        let idx = buffer.index(buffer.startIndex, offsetBy: canTake)
        let chunk = String(buffer[..<idx])
        buffer.removeSubrange(buffer.startIndex..<idx)
        revealedText.append(chunk)
        onUpdate?(revealedText)

        if buffer.isEmpty {
            stop(flushAll: false)
        }
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}

