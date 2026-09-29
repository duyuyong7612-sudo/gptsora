
// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-909be3ab9836b39534b19c895f37f371f572d938edb2dc656df406d9002e3359"
// Source-SHA256: "ae04c2f7ea8b15a2514c120bc742465327eb3fb91afd1aba48c5c21e41d30965"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation

/// 把增量文本切成适合 TTS 的小段：
/// - 优先标点切片（更自然）
/// - 兜底：达到 maxChars 也强制切
/// - finalize 时吐出尾巴
public struct TTSSlicer {

    public struct Slice: Sendable, Equatable {
        public let id: Int

        /// 原始切片（用于字符映射/高亮）
        public let rawText: String

        /// 送给 TTS 的文本（通常会 trim 一下首尾空白）
        public let ttsText: String

        /// 该切片在“整段回复文本”中的字符区间（按 Character 计数）
        public let charRange: Range<Int>

        public let isFinal: Bool

        public init(id: Int, rawText: String, ttsText: String, charRange: Range<Int>, isFinal: Bool) {
            self.id = id
            self.rawText = rawText
            self.ttsText = ttsText
            self.charRange = charRange
            self.isFinal = isFinal
        }

        /// GlobalSpeechPlayer 直接用这个字段
        public var text: String { ttsText }
    }

    // MARK: - Tuning knobs

    public var minChars: Int = 24
    public var maxChars: Int = 140
    public var hardMaxChars: Int = 220

    public var preferredBoundaries: Set<Character> = ["。", "！", "？", "；", "：", ".", "!", "?", ";", ":"]
    public var secondaryBoundaries: Set<Character> = ["，", "、", ","]

    // MARK: - State

    private var buffer: String = ""
    private var emittedCharCount: Int = 0
    private var nextId: Int = 0

    public init() {}

    // MARK: - API (match GlobalSpeechPlayer)

    public mutating func add(_ delta: String) -> [Slice] {
        guard !delta.isEmpty else { return [] }
        buffer.append(delta)
        return emitAvailable(isFinal: false, flushAll: false)
    }

    public mutating func finalize() -> [Slice] {
        let out = emitAvailable(isFinal: true, flushAll: true)
        buffer = ""
        return out
    }

    // MARK: - Core slicing

    private mutating func emitAvailable(isFinal: Bool, flushAll: Bool) -> [Slice] {
        var out: [Slice] = []

        while true {
            let chars = Array(buffer)
            let n = chars.count
            if n == 0 { break }

            if n < minChars && !flushAll {
                break
            }

            let cut = chooseCutIndex(chars: chars, flushAll: flushAll)
            guard let cut else { break }

            let raw = String(chars[0..<cut])
            let tts = raw.trimmingCharacters(in: .whitespacesAndNewlines)

            let rawCount = raw.count
            let range = emittedCharCount..<(emittedCharCount + rawCount)
            emittedCharCount += rawCount

            buffer = String(chars[cut..<n])

            let slice = Slice(
                id: nextId,
                rawText: raw,
                ttsText: tts.isEmpty ? raw : tts,
                charRange: range,
                isFinal: isFinal && buffer.isEmpty
            )
            nextId += 1

            if !slice.ttsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append(slice)
            }

            if !flushAll { break }
        }

        return out
    }

    private func chooseCutIndex(chars: [Character], flushAll: Bool) -> Int? {
        let n = chars.count
        if n == 0 { return nil }

        let minCut = min(minChars, n)
        let softMax = min(maxChars, n)
        let hardMax = min(hardMaxChars, n)

        if n >= minChars {
            if let cut = lastBoundaryCut(in: chars, lower: minCut, upper: softMax, boundaries: preferredBoundaries) {
                return cut
            }
            if let cut = lastBoundaryCut(in: chars, lower: minCut, upper: softMax, boundaries: secondaryBoundaries) {
                return cut
            }
        }

        if n >= maxChars { return softMax }
        if n >= hardMaxChars { return hardMax }
        if flushAll { return n }

        return nil
    }

    private func lastBoundaryCut(in chars: [Character], lower: Int, upper: Int, boundaries: Set<Character>) -> Int? {
        guard upper > 0, upper <= chars.count else { return nil }
        guard lower >= 0, lower <= upper else { return nil }

        for i in stride(from: upper - 1, through: lower, by: -1) {
            if boundaries.contains(chars[i]) {
                return i + 1
            }
        }
        return nil
    }
}
