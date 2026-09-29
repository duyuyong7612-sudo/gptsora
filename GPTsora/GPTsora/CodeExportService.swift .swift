// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-d829347efa768e492763a7f5f6489f2c9926535d39938b961f61cdf14a1ebd35"
// Source-SHA256: "5b5f4ed168b4c99663bbad8a44192129511963896d9402763d3938db8bfcb37e"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation

enum CodeExportService {
    static let fm = FileManager.default

    static func makeSafeFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let parts = name.components(separatedBy: invalid)
        let joined = parts.joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? "code.txt" : joined
    }

    static func temporaryRootDirectory() throws -> URL {
        let root = fm.temporaryDirectory.appendingPathComponent("GeneratedCodeExports", isDirectory: true)
        if !fm.fileExists(atPath: root.path) {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }

    static func createCleanDirectory(named name: String) throws -> URL {
        let root = try temporaryRootDirectory()
        let dir = root.appendingPathComponent(name, isDirectory: true)

        if fm.fileExists(atPath: dir.path) {
            try fm.removeItem(at: dir)
        }

        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func writeSingleFile(_ file: GeneratedCodeFile) throws -> URL {
        let root = try createCleanDirectory(named: UUID().uuidString)
        let safeName = makeSafeFileName(file.fileName)
        let fileURL = root.appendingPathComponent(safeName, isDirectory: false)

        guard let data = file.content.data(using: .utf8) else {
            throw NSError(
                domain: "CodeExportService",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "文件内容无法编码为 UTF-8"]
            )
        }

        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    static func writeFilesDirectory(_ files: [GeneratedCodeFile], directoryName: String? = nil) throws -> URL {
        let folderName = makeSafeFileName(directoryName ?? "code-package-\(timestampString())")
        let dir = try createCleanDirectory(named: folderName)

        for file in files {
            let safeName = makeSafeFileName(file.fileName)
            let fileURL = dir.appendingPathComponent(safeName, isDirectory: false)

            guard let data = file.content.data(using: .utf8) else {
                throw NSError(
                    domain: "CodeExportService",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "文件 \(file.fileName) 无法编码为 UTF-8"]
                )
            }

            try data.write(to: fileURL, options: .atomic)
        }

        return dir
    }

    static func zipFiles(_ files: [GeneratedCodeFile], zipName: String? = nil) throws -> URL {
        return try exportPackageDirectory(files, packageName: zipName)
    }

    static func exportPackageDirectory(_ files: [GeneratedCodeFile], packageName: String? = nil) throws -> URL {
        guard !files.isEmpty else {
            throw NSError(
                domain: "CodeExportService",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "没有可导出的文件"]
            )
        }

        let folderName = makeSafeFileName(packageName ?? "code-package-\(timestampString())")
        return try writeFilesDirectory(files, directoryName: folderName)
    }

    private static func timestampString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
