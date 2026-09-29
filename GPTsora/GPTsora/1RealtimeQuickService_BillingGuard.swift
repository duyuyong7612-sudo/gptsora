//
//  1RealtimeQuickService_BillingGuard.swift
//  ✅ Billing guard for RealtimeQuickService (no changes to RealtimeQuickService.swift)
//  - ping /billing/voice/ping every 25s
//  - 402 => hangup realtime + /billing/voice/end
//  - 防重复：402/手动 end 只会执行一次
//  - 防丢结算：begin(newCallId) 时会先结算旧 callId（如果存在且不同）
//

// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-1ee8b8774a3cdbdc8db4f6e7a0ca2639523354be0a8f76563557d7079bc442d1"
// Source-SHA256: "3f6bd13df314de2024f1212473a9312c60a97474a67797eee1e933a23bdd3c4a"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation

@MainActor
final class VoiceBillingGuard {
    static let shared = VoiceBillingGuard()
    private init() {}

    private let billing = SolaraBillingStore.shared

    private var callId: String?
    private var timer: DispatchSourceTimer?
    private var isEnding = false

    /// 外部传入：当后端 402(action=hangup/open_paywall) 时怎么挂断通话
    /// ⚠️ 这个闭包应当是“真正挂断 WebRTC 的入口”（例如 RealtimeQuickService.shared.stopCall()）
    private var hangupRealtime: (() -> Void)?

    /// 建议 25s 一次（20~30 秒都行）
    private let pingIntervalSec: Int = 25

    deinit { stopTimer() }

    /// ✅ 入口：拿到 callId 后调用
    /// - 如果旧 callId 存在且不同：会先结算旧 callId，避免漏扣/漏结算
    func begin(callId newCallId: String, hangupRealtime: @escaping () -> Void) {
        let newId = newCallId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newId.isEmpty else { return }

        // 如果已经在守护同一个 callId 且定时器还在，就不重复开
        if self.callId == newId, timer != nil { return }

        // 如果切换了 callId，先把旧的结算掉（防丢结算）
        if let old = self.callId, !old.isEmpty, old != newId, !isEnding {
            // 先停止旧 timer
            stopTimer()
            // 结算旧 call（不 hangup，hangup 交给上层去做；这里主要防“丢账”）
            Task { @MainActor in
                await self.billing.endVoice(callId: old)
            }
        }

        self.callId = newId
        self.hangupRealtime = hangupRealtime
        self.isEnding = false

        restartTimer()
    }

    /// ✅ 出口：通话断开/手动挂断时调用（幂等）
    func end() {
        if isEnding { return }
        isEnding = true

        stopTimer()

        let id = callId
        callId = nil
        hangupRealtime = nil

        guard let cid = id, !cid.isEmpty else { return }

        Task { @MainActor in
            await self.billing.endVoice(callId: cid)
        }
    }

    // MARK: - Timer

    private func restartTimer() {
        stopTimer()

        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(
            deadline: .now() + .seconds(pingIntervalSec),
            repeating: .seconds(pingIntervalSec),
            leeway: .seconds(3)
        )

        t.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.pingOnce()
            }
        }

        self.timer = t
        t.resume()
    }

    private func stopTimer() {
        if let t = timer {
            // 先清 handler 再 cancel，避免偶发崩
            t.setEventHandler {}
            t.cancel()
        }
        timer = nil
    }

    // MARK: - Ping

    private func pingOnce() async {
        guard let cid = callId, !cid.isEmpty else { return }
        if isEnding { return }

        do {
            _ = try await billing.pingVoice(callId: cid)

        } catch let e as SolaraBillingHTTPError {
            // 402：服务端裁决必须挂断（额度不足/不允许/策略）
            if e.status == 402 {
                if isEnding { return }
                isEnding = true

                stopTimer()

                // 先挂断 realtime（避免继续占用通话）
                hangupRealtime?()

                // 再结算 end（server 会 skip 重复 call_id）
                await billing.endVoice(callId: cid)

                // 清理本地状态
                callId = nil
                hangupRealtime = nil
            }

        } catch {
            // 网络抖动：忽略（下一轮继续 ping）
        }
    }
}
