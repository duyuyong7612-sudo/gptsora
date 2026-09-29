// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-8c2ef19e6033a84730b1c935fb0de2cd53cf06f16957514ca48800f56e44f299"
// Source-SHA256: "347743c69cb7cec9128cc104240d9056b5a5ec0957133f83a94a4b54e9772e8d"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation

struct GeneratedCodeFile: Identifiable, Hashable {
    let id: UUID
    let fileName: String
    let language: String
    let content: String
    let isClosed: Bool

    init(
        id: UUID = UUID(),
        fileName: String,
        language: String,
        content: String,
        isClosed: Bool = true
    ) {
        self.id = id
        self.fileName = fileName
        self.language = language
        self.content = content
        self.isClosed = isClosed
    }

    var fileExtension: String {
        (fileName as NSString).pathExtension.lowercased()
    }

    var baseName: String {
        (fileName as NSString).lastPathComponent
    }

    var displayType: String {
        let ext = fileExtension
        if !ext.isEmpty {
            return ext.uppercased()
        }
        if !language.isEmpty {
            return language.uppercased()
        }
        return "CODE"
    }

    var mimeLikeType: String {
        switch fileExtension {
        case "swift": return "text/swift"
        case "py": return "text/x-python"
        case "js": return "text/javascript"
        case "ts": return "text/typescript"
        case "html": return "text/html"
        case "css": return "text/css"
        case "json": return "application/json"
        case "md": return "text/markdown"
        case "xml": return "application/xml"
        case "yaml", "yml": return "application/yaml"
        case "sh": return "application/x-sh"
        case "java": return "text/x-java-source"
        case "kt": return "text/x-kotlin"
        case "go": return "text/x-go"
        case "rs": return "text/x-rust"
        case "sql": return "application/sql"
        case "zip": return "application/zip"
        default: return "text/plain"
        }
    }
}
