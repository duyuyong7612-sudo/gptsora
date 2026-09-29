//
//  RealtimeCompanionBridge.swift
//  GPT Solara
//
//  把 RealtimeCompanionService 包一层，给 SwiftUI 用的 ObservableObject
//  專門對應「1號波紋鍵」——通用語音陪聊線
//

// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-2cebb3fa9097968735a45deb4f64341d8f83d95bc677e23b30b02323b92bab53"
// Source-SHA256: "951bc4ea2871b49f9d9a45e633fd5aff0d29ebe5fc64db430edd44075569c84d"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation
import Combine

final class RealtimeCompanionBridge: ObservableObject {

    /// 是否正在通話（用來驅動 1 號波紋鍵：通用陪聊語音）
    @Published var isCalling: Bool = false

    /// 最新一條助手文本（不帶 [A] 前綴）
    @Published var lastAssistantText: String = ""

    /// 狀態文字（可選，用於顯示“準備就緒 / 已連接 / 已掛斷 / 錯誤”等）
    @Published var statusText: String = "準備就緒"

    private let service = RealtimeCompanionService.shared

    init() {
        service.delegate = self
    }

    /// 確保 delegate 沒被別的地方搶走
    private func ensureDelegate() {
        if service.delegate !== self {
            service.delegate = self
        }
    }

    // MARK: - 對外控制（給 1號波紋鍵用）

    /// 點一下 = 立刻進入「通話中」狀態，並啟動底層連線
    func startCall() {
        ensureDelegate()
        DispatchQueue.main.async {
            self.isCalling = true
            self.statusText = "連接中…"
        }
        service.startCall()
    }

    /// 再點一下 = 立刻退出「通話中」，並讓底層掛斷
    func stopCall() {
        ensureDelegate()
        DispatchQueue.main.async {
            self.isCalling = false
            self.statusText = "已掛斷"
        }
        service.stopCall()
    }

    /// 1 號波紋鍵的切換邏輯：只看 isCalling，點了就接入 / 點了就退出
    func toggleCall() {
        ensureDelegate()

        if isCalling {
            stopCall()
        } else {
            startCall()
        }
    }
}

// MARK: - RealtimeCompanionServiceDelegate

extension RealtimeCompanionBridge: RealtimeCompanionServiceDelegate {

    func realtimeServiceDidConnect(_ svc: RealtimeCompanionService) {
        DispatchQueue.main.async {
            self.isCalling = true        // 再次確認 UI 狀態
            self.statusText = "已連接"
        }
    }

    func realtimeServiceDidDisconnect(_ svc: RealtimeCompanionService) {
        DispatchQueue.main.async {
            self.isCalling = false
            self.statusText = "已掛斷"
        }
    }

    func realtimeService(_ svc: RealtimeCompanionService, didUpdateStatus text: String) {
        DispatchQueue.main.async {
            self.statusText = text
        }
    }

    func realtimeService(_ svc: RealtimeCompanionService, didUpdateTranscript text: String) {
        // 只取助手的內容：[A] 開頭的是助手
        guard text.hasPrefix("[A]") else { return }
        let raw = String(text.dropFirst(3))
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        DispatchQueue.main.async {
            self.lastAssistantText = trimmed
        }
    }

    func realtimeService(_ svc: RealtimeCompanionService, didFailWith error: Error) {
        DispatchQueue.main.async {
            self.statusText = "錯誤：" + error.localizedDescription
            self.isCalling = false
        }
    }
}
