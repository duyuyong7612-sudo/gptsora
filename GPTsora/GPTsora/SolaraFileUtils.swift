// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-1cd72debe9234b094d62fa6a3ea3be53769544c13f34e072f2c7871f1ae1ff00"
// Source-SHA256: "9a60c593d9a18a36d5f3d1f77fe0ca15c7b1f3a2de70fec788a76b94c3462936"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation

enum SolaraFileUtils {

    static func persistToDocumentsIfNeeded(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }

        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        if url.path.hasPrefix(docs.path) { return url }

        do {
            let dir = docs.appendingPathComponent("solara_generated", isDirectory: true)
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }

            let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
            let dest = dir.appendingPathComponent("solara_\(UUID().uuidString).\(ext)")
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: url, to: dest)
            return dest
        } catch {
            print("persistToDocumentsIfNeeded failed:", error)
            return url
        }
    }
}
