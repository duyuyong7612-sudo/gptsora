// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-0a00c093ff2d58287acc56f05564fdd97ba3fd82bd23a547aa89cbe6bf90b382"
// Source-SHA256: "e8e8fd2ed291323dc7a6ba994cb81e80edfbbd572056fd1bc7de84834202e004"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI

struct CodeHighlighterView: View {
    let code: String
    let language: String
    @Binding var dynamicHeight: CGFloat

    init(
        code: String,
        language: String = "plaintext",
        dynamicHeight: Binding<CGFloat>
    ) {
        self.code = code
        self.language = language
        self._dynamicHeight = dynamicHeight
    }

    private var normalizedCode: String {
        code.replacingOccurrences(of: "\r\n", with: "\n")
    }

    private var lines: [String] {
        normalizedCode.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private var lineCount: Int {
        max(lines.count, 1)
    }

    private var lineNumberColumn: String {
        (1...lineCount).map { String($0) }.joined(separator: "\n")
    }

    private var measuredHeight: CGFloat {
        let lineHeight: CGFloat = 19
        let verticalPadding: CGFloat = 28
        return max(CGFloat(lineCount) * lineHeight + verticalPadding, 56)
    }

    var body: some View {
        let displayCode = normalizedCode.isEmpty ? " " : normalizedCode

        HStack(alignment: .top, spacing: 0) {
            Text(lineNumberColumn)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
                .lineSpacing(3)
                .padding(.leading, 12)
                .padding(.trailing, 10)
                .padding(.vertical, 14)
                .frame(minWidth: 40, alignment: .trailing)
                .textSelection(.disabled)

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1)

            Text(displayCode)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundColor(.primary)
                .multilineTextAlignment(.leading)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: measuredHeight, alignment: .topLeading)
        .background(Color(uiColor: .tertiarySystemBackground))
        .onAppear {
            dynamicHeight = measuredHeight
        }
        .onChange(of: code) { _ in
            dynamicHeight = measuredHeight
        }
    }
}
