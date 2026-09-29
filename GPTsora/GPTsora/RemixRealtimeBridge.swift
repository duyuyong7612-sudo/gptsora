// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-8287b4fee32dae870b1cfac7dd5c5a70dafaf2ebf3cf701c29a041ae57d5a367"
// Source-SHA256: "2ee6f363a89a1dd413d6db671d2735626610c71ce1ce86ff64f0cc2ee46a0c76"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation

/// 目标：
/// - profile="remix" 启动 Realtime（走你现有 RealtimeQuickService）
/// - onUserTranscriptDelta：把用户说话转写 delta 追加到输入框
/// - onRemixTrigger：当助手输出 “RMX: ...” 这一行时触发（二次生成全自动）
///
/// 说明：
/// 你只要在 RealtimeQuickService 里拿到 assistant final text（或 output_text.final）
/// 然后检测 "RMX:" 单行，把后面的英文丢给 onRemixTrigger 即可。
final class RemixRealtimeBridge {

    private var hasTriggered = false
    private var dedupHash: String = ""

    func start(profile: String,
               onUserTranscriptDelta: @escaping (String) -> Void,
               onRemixTrigger: @escaping (String) -> Void,
               onReady: @escaping () -> Void,
               onStopped: @escaping () -> Void,
               onError: @escaping (String) -> Void) {

        hasTriggered = false
        dedupHash = ""

        // TODO: 在这里接你现有 RealtimeQuickService：
        // 1) startCall(profile:"remix")
        // 2) user transcript delta -> onUserTranscriptDelta(delta)
        // 3) assistant final text -> parseRMX(text) -> onRemixTrigger(instructionEN)
        //
        // 现在先直接回调 ready（占位，避免UI卡死）
        onReady()

        // 示例：你拿到 assistant final text 时调用：
        // handleAssistantFinalText(finalText, onRemixTrigger)
    }

    func stop() {
        // TODO: 调用 RealtimeQuickService.stop()
    }

    // 你把 finalText 丢进来，它会稳定解析并只触发一次
    func handleAssistantFinalText(_ finalText: String, onRemixTrigger: @escaping (String) -> Void) {
        guard !hasTriggered else { return }
        let instruction = parseRMX(finalText)
        guard !instruction.isEmpty else { return }

        // 去重：避免重复触发
        let h = sha1(instruction)
        if h == dedupHash { return }
        dedupHash = h

        hasTriggered = true
        onRemixTrigger(instruction)
    }

    private func parseRMX(_ s: String) -> String {
        // 只认单行 RMX:
        // RMX: <english instruction>
        let lines = s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        for ln in lines {
            if ln.uppercased().hasPrefix("RMX:") {
                return ln.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return ""
    }

    private func sha1(_ s: String) -> String {
        // 简化哈希（非加密用途，够去重）
        return String(s.hashValue)
    }
}

