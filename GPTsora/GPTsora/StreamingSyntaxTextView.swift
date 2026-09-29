// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-d905b7cbe0d28f4a967a87b31f7d6f0c34becf2932ebdd9ee0342e597caf77f8"
// Source-SHA256: "6ac22b6514440dbe9bd38297718504e111f73747a338b3ef071a5c2725d9cf2b"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI
import UIKit

// =======================================================
// StreamingSyntaxTextView.swift
// ✅ TextKit 增量渲染：append delta -> 只对新增附近做高亮
// ✅ SwiftUI 只传 "TypingFeed(seq, delta, resetText)"，不传全文，避免重排
// =======================================================

struct TypingFeed: Equatable {
    var seq: Int = 0              // 每次有新 delta 就 +1
    var delta: String = ""        // 本次新增文本
    var resetText: String? = nil  // 需要清空/重置时用（一次性）
}

// MARK: - Auto sizing UITextView
final class AutoSizingStreamingTextView: UITextView {

    var onHeightChange: ((CGFloat) -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = contentSize.height
        onHeightChange?(max(24, h))
    }
}

// MARK: - TextStorage (incremental highlight around edited range)
final class StreamingHighlightTextStorage: NSTextStorage {

    private let backing = NSMutableAttributedString()
    private var isApplying = false

    // Prose style
    var proseAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 17),
        .foregroundColor: UIColor.label
    ]

    // Code style
    var codeBaseAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.monospacedSystemFont(ofSize: 15, weight: .regular),
        .foregroundColor: UIColor.label
    ]

    // Very light tokenizer rules (你可以继续扩展)
    private lazy var rules: [(NSRegularExpression, [NSAttributedString.Key: Any])] = {
        func r(_ pattern: String, _ color: UIColor, options: NSRegularExpression.Options = []) -> (NSRegularExpression, [NSAttributedString.Key: Any]) {
            (try! NSRegularExpression(pattern: pattern, options: options), [.foregroundColor: color])
        }
        return [
            r(#"\b(let|var|func|class|struct|enum|if|else|for|while|return|import|final|private|public|guard|switch|case|break|continue|try|catch|throw|async|await)\b"#, .systemBlue),
            r(#"\b\d+(\.\d+)?\b"#, .systemOrange),
            r(#""([^"\\]|\\.)*""#, .systemGreen),
            r(#"//.*$"#, .systemGray, options: [.anchorsMatchLines]),
            r(#"/\*[\s\S]*?\*/"#, .systemGray)
        ]
    }()

    override var string: String { backing.string }

    override func attributes(at location: Int, effectiveRange range: NSRangePointer?) -> [NSAttributedString.Key : Any] {
        backing.attributes(at: location, effectiveRange: range)
    }

    override func replaceCharacters(in range: NSRange, with str: String) {
        beginEditing()
        backing.replaceCharacters(in: range, with: str)
        edited([.editedCharacters, .editedAttributes], range: range, changeInLength: (str as NSString).length - range.length)
        endEditing()
    }

    override func setAttributes(_ attrs: [NSAttributedString.Key : Any]?, range: NSRange) {
        beginEditing()
        backing.setAttributes(attrs, range: range)
        edited(.editedAttributes, range: range, changeInLength: 0)
        endEditing()
    }

    private func countFences(in s: String) -> Int {
        // 统计 ``` 出现次数（简单够用）
        var count = 0
        var i = s.startIndex
        while let r = s.range(of: "```", range: i..<s.endIndex) {
            count += 1
            i = r.upperBound
        }
        return count
    }

    override func processEditing() {
        super.processEditing()
        guard !isApplying else { return }
        isApplying = true
        defer { isApplying = false }

        let ns = backing.string as NSString
        let edited = self.editedRange
        if edited.location == NSNotFound { return }

        // 只重算：编辑所在段落 + 一点 margin
        var target = ns.paragraphRange(for: edited)
        let margin = 256
        let start = max(0, target.location - margin)
        let end = min(ns.length, target.location + target.length + margin)
        target = NSRange(location: start, length: max(0, end - start))

        // 判断 target 起点是否在 code fence 内：
        // 向前看一小段（最多 4000 chars），统计 ``` 奇偶
        let lookback = 4000
        let lbStart = max(0, target.location - lookback)
        let lbRange = NSRange(location: lbStart, length: target.location - lbStart)
        let lbStr = lbRange.length > 0 ? ns.substring(with: lbRange) : ""
        var inCode = (countFences(in: lbStr) % 2 == 1)

        // 先按 prose 铺底（target）
        backing.setAttributes(proseAttrs, range: target)

        // 在 target 内，遇到 fence 切换 code/prose；code 段再应用规则
        let sub = ns.substring(with: target)
        let subNS = sub as NSString

        // 找 fence
        let fenceRe = try! NSRegularExpression(pattern: "```", options: [])
        var fenceMatches: [NSTextCheckingResult] = []
        fenceRe.enumerateMatches(in: sub, options: [], range: NSRange(location: 0, length: subNS.length)) { m, _, _ in
            if let m { fenceMatches.append(m) }
        }

        // 将 target 切片：按 fence 分段
        var cursor = 0
        func applyCode(in localRange: NSRange) {
            guard localRange.length > 0 else { return }
            let global = NSRange(location: target.location + localRange.location, length: localRange.length)
            backing.addAttributes(codeBaseAttrs, range: global)

            // 对这段应用 token 规则
            let piece = subNS.substring(with: localRange)
            let pieceNS = piece as NSString
            let pieceRange = NSRange(location: 0, length: pieceNS.length)
            for (re, attrs) in rules {
                re.enumerateMatches(in: piece, options: [], range: pieceRange) { m, _, _ in
                    guard let m else { return }
                    let r = NSRange(location: global.location + m.range.location, length: m.range.length)
                    backing.addAttributes(attrs, range: r)
                }
            }
        }

        for m in fenceMatches {
            let seg = NSRange(location: cursor, length: max(0, m.range.location - cursor))
            if inCode {
                applyCode(in: seg)
            }
            // fence 自己淡化
            let fenceGlobal = NSRange(location: target.location + m.range.location, length: m.range.length)
            backing.addAttributes([.foregroundColor: UIColor.systemGray], range: fenceGlobal)

            inCode.toggle()
            cursor = m.range.location + m.range.length
        }

        // 最后一段
        let tail = NSRange(location: cursor, length: max(0, subNS.length - cursor))
        if inCode { applyCode(in: tail) }

        edited(.editedAttributes, range: target, changeInLength: 0)
    }
}

// MARK: - UIKit view that supports appendDelta
final class StreamingSyntaxTextView: AutoSizingStreamingTextView {

    private let storage = StreamingHighlightTextStorage()
    private let lm = NSLayoutManager()
    private let tc = NSTextContainer(size: .zero)

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        tc.widthTracksTextView = true
        tc.heightTracksTextView = false
        storage.addLayoutManager(lm)
        lm.addTextContainer(tc)
        super.init(frame: frame, textContainer: tc)

        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        backgroundColor = .clear
        textContainerInset = .zero
        self.textContainer.lineFragmentPadding = 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func resetAllText(_ s: String) {
        storage.replaceCharacters(in: NSRange(location: 0, length: (storage.string as NSString).length), with: s)
    }

    func appendDelta(_ s: String) {
        guard !s.isEmpty else { return }
        let len = (storage.string as NSString).length
        storage.replaceCharacters(in: NSRange(location: len, length: 0), with: s)
    }
}

// MARK: - SwiftUI wrapper
struct StreamingSyntaxTextViewBox: UIViewRepresentable {

    let feed: TypingFeed
    @Binding var dynamicHeight: CGFloat

    final class Coordinator {
        var lastSeq: Int = -1
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> StreamingSyntaxTextView {
        let v = StreamingSyntaxTextView()
        v.onHeightChange = { h in
            DispatchQueue.main.async {
                self.dynamicHeight = max(24, h)
            }
        }
        return v
    }

    func updateUIView(_ uiView: StreamingSyntaxTextView, context: Context) {
        // 防止 SwiftUI 重绘时重复 append
        guard feed.seq != context.coordinator.lastSeq else { return }
        context.coordinator.lastSeq = feed.seq

        if let r = feed.resetText {
            uiView.resetAllText(r)
        } else {
            uiView.appendDelta(feed.delta)
        }
    }
}

