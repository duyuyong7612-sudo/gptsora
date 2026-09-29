// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-af099cf52672992122da649bcee5292fca1383dd893a75c0689f005fb81171d1"
// Source-SHA256: "ba75dbd4b0eeefcd4864a8fee9237b02d7e6165ab7f69f7aee626afbda6cf3b0"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI
import UIKit

enum AssistantMessageSegment: Hashable {
    case markdown(String)
    case code(language: String?, fileName: String?, code: String, isClosed: Bool)
}

enum AssistantMessageParser {
    static func parse(_ text: String, allowUnclosedCodeFence: Bool = true) -> [AssistantMessageSegment] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var result: [AssistantMessageSegment] = []
        var markdownBuffer: [String] = []
        var codeBuffer: [String] = []

        var inCodeBlock = false
        var currentLanguage: String?
        var currentFileName: String?

        func flushMarkdown() {
            guard !markdownBuffer.isEmpty else { return }
            let text = markdownBuffer.joined(separator: "\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(.markdown(text))
            }
            markdownBuffer.removeAll(keepingCapacity: true)
        }

        func flushCode(isClosed: Bool) {
            let code = codeBuffer.joined(separator: "\n")
            result.append(.code(language: currentLanguage, fileName: currentFileName, code: code, isClosed: isClosed))
            codeBuffer.removeAll(keepingCapacity: true)
        }

        for line in lines {
            if let header = fenceHeader(from: line) {
                if inCodeBlock {
                    flushCode(isClosed: true)
                    inCodeBlock = false
                    currentLanguage = nil
                    currentFileName = nil
                } else {
                    flushMarkdown()
                    inCodeBlock = true
                    let meta = parseFenceMeta(header)
                    currentLanguage = meta.language
                    currentFileName = meta.fileName
                }
                continue
            }

            if inCodeBlock {
                codeBuffer.append(line)
            } else {
                markdownBuffer.append(line)
            }
        }

        if inCodeBlock {
            if allowUnclosedCodeFence {
                flushCode(isClosed: false)
            } else {
                markdownBuffer.append(contentsOf: codeBuffer)
            }
        }

        flushMarkdown()
        return mergeAdjacentMarkdown(result)
    }

    private static func fenceHeader(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("```") else { return nil }
        return String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
    }

    private static func parseFenceMeta(_ raw: String) -> (language: String?, fileName: String?) {
        guard !raw.isEmpty else {
            return (nil, nil)
        }

        let tokens = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        var language: String?
        var fileName: String?

        for (index, token) in tokens.enumerated() {
            let lower = token.lowercased()

            if lower.hasPrefix("filename=") || lower.hasPrefix("file=") || lower.hasPrefix("path=") {
                let value = token.split(separator: "=", maxSplits: 1).last.map(String.init) ?? ""
                let cleaned = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !cleaned.isEmpty {
                    fileName = cleaned
                }
                continue
            }

            if token.contains("/") || token.contains("\\") || looksLikeFileName(token) {
                fileName = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                continue
            }

            if index == 0 && language == nil {
                language = normalizeLanguage(token)
            }
        }

        if language == nil, let fileName {
            language = inferLanguage(from: fileName)
        }

        return (language, fileName)
    }

    private static func mergeAdjacentMarkdown(_ items: [AssistantMessageSegment]) -> [AssistantMessageSegment] {
        var merged: [AssistantMessageSegment] = []

        for item in items {
            switch item {
            case .markdown(let text):
                if case .markdown(let lastText)? = merged.last {
                    merged.removeLast()
                    let combined = lastText + "\n" + text
                    merged.append(.markdown(combined))
                } else {
                    merged.append(item)
                }
            case .code:
                merged.append(item)
            }
        }

        return merged
    }

    private static func looksLikeFileName(_ token: String) -> Bool {
        let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard cleaned.contains(".") else { return false }
        let ext = (cleaned as NSString).pathExtension.lowercased()
        return !ext.isEmpty
    }

    private static func normalizeLanguage(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch value {
        case "objective-c", "objc":
            return "objective-c"
        case "js":
            return "javascript"
        case "ts":
            return "typescript"
        case "py":
            return "python"
        case "rb":
            return "ruby"
        case "yml":
            return "yaml"
        case "sh", "zsh":
            return "bash"
        default:
            return value
        }
    }

    private static func inferLanguage(from fileName: String) -> String? {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "py": return "python"
        case "js": return "javascript"
        case "ts": return "typescript"
        case "tsx": return "tsx"
        case "jsx": return "jsx"
        case "java": return "java"
        case "kt": return "kotlin"
        case "go": return "go"
        case "rs": return "rust"
        case "cpp", "cc", "cxx": return "cpp"
        case "c": return "c"
        case "h": return "c"
        case "m": return "objective-c"
        case "mm": return "objective-c++"
        case "json": return "json"
        case "yaml", "yml": return "yaml"
        case "xml": return "xml"
        case "html": return "html"
        case "css": return "css"
        case "sql": return "sql"
        case "sh": return "bash"
        case "md": return "markdown"
        default: return nil
        }
    }
}

struct AssistantRichMessageView: View {
    let content: String

    private var segments: [AssistantMessageSegment] {
        AssistantMessageParser.parse(content, allowUnclosedCodeFence: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .markdown(let text):
                    MarkdownBlockView(markdown: text)

                case .code(let language, let fileName, let code, let isClosed):
                    CodeBlockCardView(
                        language: language,
                        fileName: fileName,
                        code: code,
                        isClosed: isClosed
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownBlockView: View {
    let markdown: String

    var body: some View {
        Group {
            if let attributed = try? AttributedString(
                markdown: markdown,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .full,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            ) {
                Text(attributed)
                    .font(.system(size: 16))
                    .foregroundStyle(.primary)
                    .lineSpacing(4)
                    .textSelection(.enabled)
            } else {
                Text(markdown)
                    .font(.system(size: 16))
                    .foregroundStyle(.primary)
                    .lineSpacing(4)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CodeBlockCardView: View {
    let language: String?
    let fileName: String?
    let code: String
    let isClosed: Bool

    @State private var copied = false
    @State private var wrapLines = false
    @State private var expanded = false

    private var allLines: [String] {
        code.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    private var shouldCollapse: Bool {
        allLines.count > 24
    }

    private var displayedCode: String {
        if expanded || !shouldCollapse {
            return code
        }
        return Array(allLines.prefix(20)).joined(separator: "\n")
    }

    private var displayLanguage: String {
        if let language, !language.isEmpty {
            return language.uppercased()
        }
        if let fileName, let inferred = AssistantMessageParser.parse("`\(fileName)\n`").compactMap({ segment -> String? in
            if case .code(let language, _, _, _) = segment {
                return language
            }
            return nil
        }).first {
            return inferred.uppercased()
        }
        return "CODE"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            divider
            codeBody

            if shouldCollapse {
                divider
                footer
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            CapsuleBadge(text: displayLanguage)

            if let fileName, !fileName.isEmpty {
                Text(fileName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if !isClosed {
                CapsuleBadge(text: "生成中")
            }

            Spacer()

            Button {
                wrapLines.toggle()
            } label: {
                Text(wrapLines ? "关闭换行" : "自动换行")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Button {
                UIPasteboard.general.string = code
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    copied = false
                }
            } label: {
                Text(copied ? "已复制" : "复制")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 1)
    }

    private var codeBody: some View {
        Group {
            if wrapLines {
                ScrollView(.vertical, showsIndicators: true) {
                    codeText(displayedCode)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    codeText(displayedCode)
                }
            }
        }
        .frame(minHeight: 56, maxHeight: shouldCollapse ? 360 : 460)
        .background(Color(uiColor: .tertiarySystemBackground))
    }

    private var footer: some View {
        HStack {
            Button {
                expanded.toggle()
            } label: {
                Text(expanded ? "收起" : "展开全部")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.accent)
            }
            .buttonStyle(.plain)

            Spacer()

            Text("\(allLines.count) 行")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func codeText(_ text: String) -> some View {
        Text(text.isEmpty ? " " : text)
            .font(.system(size: 13, weight: .regular, design: .monospaced))
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .lineSpacing(3)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: wrapLines ? .infinity : nil, alignment: .leading)
            .padding(14)
    }
}

private struct CapsuleBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.06))
            .clipShape(Capsule())
    }
}
