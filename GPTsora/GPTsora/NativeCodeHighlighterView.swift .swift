// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-492b2948fa963b49bed32a52d58f2634da825e4277c87c6c2921d71681d24e87"
// Source-SHA256: "f10a5a5e3cfd06d32beedfa8b93442c46b1b5c0661ad2770d62b6e39b2872341"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI
import UIKit

struct NativeCodeHighlighterView: UIViewRepresentable {
    let code: String
    let language: String
    @Binding var dynamicHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(dynamicHeight: $dynamicHeight)
    }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = false
        tv.backgroundColor = UIColor(white: 0.96, alpha: 1.0)
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        tv.textContainer.lineFragmentPadding = 0
        tv.layer.cornerRadius = 12
        tv.clipsToBounds = true
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.apply(code: code, language: language, to: uiView)
    }

    final class Coordinator {
        @Binding var dynamicHeight: CGFloat

        private var lastHash: Int = 0
        private var work: Task<Void, Never>? = nil

        init(dynamicHeight: Binding<CGFloat>) {
            _dynamicHeight = dynamicHeight
        }

        func apply(code: String, language: String, to tv: UITextView) {
            let h = (code + "||" + language).hashValue
            if h == lastHash { return }
            lastHash = h

            work?.cancel()

            // ✅ debounce + 后台高亮（商用级：不让主线程发烫）
            work = Task.detached(priority: .userInitiated) { [weak tv] in
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms 合并抖动
                if Task.isCancelled { return }

                let attr = SyntaxHighlighter.highlight(code: code, language: language)

                await MainActor.run {
                    guard let tv else { return }
                    tv.attributedText = attr

                    let targetW = tv.bounds.width > 1 ? tv.bounds.width : UIScreen.main.bounds.width - 56
                    let size = tv.sizeThatFits(CGSize(width: targetW, height: .greatestFiniteMagnitude))
                    let newH = max(44, size.height)

                    if abs(newH - self.dynamicHeight) > 1 {
                        self.dynamicHeight = newH
                    }
                }
            }
        }
    }
}

enum SyntaxHighlighter {
    static func highlight(code: String, language: String) -> NSAttributedString {
        let font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let base: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.label
        ]

        let s = NSMutableAttributedString(string: code, attributes: base)

        // 极轻量 token（够商用：不卡、不热）
        let keywords: [String]
        if language.lowercased().contains("swift") {
            keywords = ["func","let","var","if","else","for","while","return","class","struct","enum","import","protocol","extension","guard","try","catch","throw","async","await"]
        } else if language.lowercased().contains("json") {
            keywords = []
        } else {
            keywords = ["function","const","let","var","if","else","for","while","return","class","import"]
        }

        for kw in keywords {
            apply(pattern: "\\b\(NSRegularExpression.escapedPattern(for: kw))\\b",
                  color: UIColor.systemBlue,
                  in: s)
        }

        // strings
        apply(pattern: "\"(\\\\.|[^\"])*\"",
              color: UIColor.systemRed,
              in: s)

        // comments
        apply(pattern: "//.*?$",
              color: UIColor.systemGreen,
              in: s,
              options: [.anchorsMatchLines])

        return s
    }

    private static func apply(pattern: String,
                              color: UIColor,
                              in s: NSMutableAttributedString,
                              options: NSRegularExpression.Options = []) {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return }
        let ns = s.string as NSString
        let range = NSRange(location: 0, length: ns.length)
        re.enumerateMatches(in: s.string, options: [], range: range) { m, _, _ in
            guard let r = m?.range else { return }
            s.addAttribute(.foregroundColor, value: color, range: r)
        }
    }
}

