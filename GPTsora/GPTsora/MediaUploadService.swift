// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-9700fae3a55d8d71c33d8c3752dcdeb262eacc066c1972642b6ef6cc0488de4f"
// Source-SHA256: "baec3df8aa3e8a1dae98bd53d25cc9ae110d3626e1c5a2b442a20c116dd3471b"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation

struct UploadedMedia: Codable {
    let id: String
    let mime: String?
    let url: String?
}

final class MediaUploadService {

    func uploadImage(apiBase: String, data: Data) async throws -> UploadedMedia {
        let url = URL(string: apiBase + "/upload/image")!
        return try await uploadMultipart(url: url, fieldName: "file", fileName: "photo.jpg", mime: "image/jpeg", data: data)
    }

    func uploadAudio(apiBase: String, fileURL: URL) async throws -> UploadedMedia {
        let url = URL(string: apiBase + "/upload/audio")!
        let data = try Data(contentsOf: fileURL)
        return try await uploadMultipart(url: url, fieldName: "file", fileName: "voice.m4a", mime: "audio/mp4", data: data)
    }

    private func uploadMultipart(
        url: URL,
        fieldName: String,
        fileName: String,
        mime: String,
        data: Data
    ) async throws -> UploadedMedia {

        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: \(mime)\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")

        let (respData, resp) = try await URLSession.shared.upload(for: req, from: body)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "MediaUploadService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "upload 无响应"])
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: respData, encoding: .utf8) ?? ""
            throw NSError(domain: "MediaUploadService", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "upload 失败 \(http.statusCode): \(bodyText)"])
        }

        return try JSONDecoder().decode(UploadedMedia.self, from: respData)
    }
}

