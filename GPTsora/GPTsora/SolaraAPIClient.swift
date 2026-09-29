// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-3591cf8980f5c3a7e4c0ec6f4bba77ca3c664786b132f75955cd5f480e25a57c"
// Source-SHA256: "4ccfcc2412e8b1494b772ca5e47dd4cb89463ebf76d51cbedd9d34e61c701e5f"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation

// MARK: - Client Identity (stable x-client-id)
/// Stable per-install client id used by backend for billing/credits gating.
/// Keep this consistent across ALL requests.
final class ClientIdentity {
    static let shared = ClientIdentity()

    private let key = "solara.client_id.v1"
    private var cached: String?

    private init() {}

    var clientId: String {
        if let c = cached { return c }

        // ✅ 一次性迁移：优先用旧 solara.client_id（HomeChatView 用的 key），
        // 保证和历史记忆对上，迁移完后统一存到 solara.client_id.v1
        let legacyKey = "solara.client_id"
        if let v = UserDefaults.standard.string(forKey: key), !v.isEmpty {
            cached = v
            // 同步写入旧 key，保证 HomeChatView 也读到同一个值
            UserDefaults.standard.set(v, forKey: legacyKey)
            print("🔑 ClientIdentity(v1):", v)
            return v
        }
        // v1 没有 -> 看旧 key 有没有
        if let v = UserDefaults.standard.string(forKey: legacyKey), !v.isEmpty {
            // 迁移：把旧 key 的值升级写入 v1
            UserDefaults.standard.set(v, forKey: key)
            cached = v
            print("🔑 ClientIdentity migrated from legacy:", v)
            return v
        }
        // 都没有 -> 新建
        let v = UUID().uuidString.lowercased()
        UserDefaults.standard.set(v, forKey: key)
        UserDefaults.standard.set(v, forKey: legacyKey)
        cached = v
        print("🔑 ClientIdentity created:", v)
        return v
    }
}

// MARK: - Errors

enum SolaraAPIError: LocalizedError {
    case badURL(String)
    case http(Int, String)
    case decode(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .badURL(let s): return "URL 无效：\(s)"
        case .http(let code, let body): return "后端错误 \(code)：\(body)"
        case .decode(let s): return "解析失败：\(s)"
        case .emptyResponse: return "后端返回为空"
        }
    }
}

// MARK: - Client

actor SolaraAPIClient {

    static let shared = SolaraAPIClient()

    struct Endpoints {
        var chat: URL
        var transcribe: URL
        var session: URL
        var uploadAudio: URL
        var uploadImage: URL
        var openapi: URL
        var health: URL

        static func defaults() -> Endpoints {
            .init(
                chat: AppConfig.API.chatURL,
                transcribe: AppConfig.API.transcribeURL,
                session: AppConfig.API.sessionURL,
                uploadAudio: AppConfig.API.uploadAudioURL,
                uploadImage: AppConfig.API.uploadImageURL,
                openapi: AppConfig.API.openAPIURL,
                health: AppConfig.API.healthURL
            )
        }
    }

    private let urlSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        return URLSession(configuration: cfg)
    }()

    private var endpoints: Endpoints = .defaults()
    private var lastBase: String = AppConfig.API.apiBase
    private var resolvedOnce: Bool = false

    // MARK: - Public APIs

    func chat(text: String) async throws -> String {
        try await ensureResolvedEndpoints()
        let body: [String: Any] = ["text": text]

        do {
            let data = try await postJSON(url: endpoints.chat, body: body)
            return try decodeTextLike(from: data)
        } catch let SolaraAPIError.http(code, _) where code == 404 {
            resolvedOnce = false
            try await ensureResolvedEndpoints(force: true)
            let data = try await postJSON(url: endpoints.chat, body: body)
            return try decodeTextLike(from: data)
        }
    }

    func transcribeAudio(fileURL: URL) async throws -> String {
        try await ensureResolvedEndpoints()

        do {
            let data = try await postMultipart(
                url: endpoints.transcribe,
                fileURL: fileURL,
                fieldName: "file",
                mimeType: "audio/m4a"
            )
            return try decodeTextLike(from: data)
        } catch let SolaraAPIError.http(code, _) where code == 404 {
            let data = try await postMultipart(
                url: endpoints.uploadAudio,
                fileURL: fileURL,
                fieldName: "file",
                mimeType: "audio/m4a"
            )
            return try decodeTextLike(from: data)
        }
    }

    func realtimeSession(payload: [String: Any] = [:]) async throws -> Data {
        try await ensureResolvedEndpoints()
        return try await postJSON(url: endpoints.session, body: payload)
    }

    func health() async -> String {
        do {
            try await ensureResolvedEndpoints()
            var req = URLRequest(url: endpoints.health)
            req.httpMethod = "GET"
            applyCommonHeaders(&req)
            logRequest(req)
            let (data, resp) = try await urlSession.data(for: req)
            if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                return String(data: data, encoding: .utf8) ?? "OK"
            }
            return "health 非 2xx"
        } catch {
            return "health 失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Endpoint Auto-Discovery

    private func ensureResolvedEndpoints(force: Bool = false) async throws {
        let currentBase = AppConfig.API.apiBase
        if currentBase != lastBase {
            lastBase = currentBase
            endpoints = .defaults()
            resolvedOnce = false
        }
        if resolvedOnce && !force { return }

        do {
            var req = URLRequest(url: endpoints.openapi)
            req.httpMethod = "GET"
            applyCommonHeaders(&req)
            logRequest(req)
            let (data, resp) = try await urlSession.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                resolvedOnce = true
                return
            }
            let paths = try extractOpenAPIPaths(from: data)

            if let p = pickPath(prefer: ["/chat"], suffix: "/chat", in: paths) {
                endpoints.chat = AppConfig.API.resolve(p)
            } else if let p = pickSuffix("/chat", in: paths) {
                endpoints.chat = AppConfig.API.resolve(p)
            }

            if let p = pickPath(prefer: ["/transcribe"], suffix: "/transcribe", in: paths) {
                endpoints.transcribe = AppConfig.API.resolve(p)
            } else if let p = pickSuffix("/transcribe", in: paths) {
                endpoints.transcribe = AppConfig.API.resolve(p)
            }

            if let p = pickPath(prefer: ["/session"], suffix: "/session", in: paths) {
                endpoints.session = AppConfig.API.resolve(p)
            } else if let p = pickSuffix("/session", in: paths) {
                endpoints.session = AppConfig.API.resolve(p)
            }

            if let p = pickSuffix("/upload/audio", in: paths) {
                endpoints.uploadAudio = AppConfig.API.resolve(p)
            }
            if let p = pickSuffix("/upload/image", in: paths) {
                endpoints.uploadImage = AppConfig.API.resolve(p)
            }

            resolvedOnce = true
        } catch {
            resolvedOnce = true
        }
    }

    private func extractOpenAPIPaths(from data: Data) throws -> [String] {
        let obj = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = obj as? [String: Any],
              let paths = dict["paths"] as? [String: Any] else {
            return []
        }
        return Array(paths.keys)
    }

    private func pickPath(prefer: [String], suffix: String, in paths: [String]) -> String? {
        for p in prefer where paths.contains(p) { return p }
        return pickSuffix(suffix, in: paths)
    }

    private func pickSuffix(_ suffix: String, in paths: [String]) -> String? {
        return paths.first(where: { $0.lowercased().hasSuffix(suffix.lowercased()) })
    }

    
    // MARK: - Debug Logging (single network exit)
    /// Print every outgoing request URL so we can verify the whole app uses ONE base.
    private func logRequest(_ req: URLRequest) {
        #if DEBUG
        let method = req.httpMethod ?? "?"
        let url = req.url?.absoluteString ?? "<nil>"
        let cid = ClientIdentity.shared.clientId
        print("🌐 [NET] \(method) \(url)  x-client-id=\(cid)")
        #endif
    }

// MARK: - HTTP Helpers

    private func applyCommonHeaders(_ req: inout URLRequest) {
        req.setValue(ClientIdentity.shared.clientId, forHTTPHeaderField: "x-client-id")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Solara-iOS", forHTTPHeaderField: "User-Agent")
        let agentToken = AppConfig.agentToken
        if !agentToken.isEmpty {
            req.setValue(agentToken, forHTTPHeaderField: "X-Agent-Token")
        }
    }

    private func postJSON(url: URL, body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        applyCommonHeaders(&req)
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        logRequest(req)
            let (data, resp) = try await urlSession.data(for: req)
        try ensure2xx(resp: resp, data: data)
        return data
    }

    private func postMultipart(url: URL,
                               fileURL: URL,
                               fieldName: String,
                               mimeType: String) async throws -> Data {

        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        applyCommonHeaders(&req)

        let filename = fileURL.lastPathComponent
        let fileData = try Data(contentsOf: fileURL)

        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        append("\r\n")
        append("--\(boundary)--\r\n")

        req.httpBody = body

        logRequest(req)
            let (data, resp) = try await urlSession.data(for: req)
        try ensure2xx(resp: resp, data: data)
        return data
    }

    private func ensure2xx(resp: URLResponse, data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        if (200...299).contains(http.statusCode) { return }
        let s = String(data: data, encoding: .utf8) ?? "<no body>"
        throw SolaraAPIError.http(http.statusCode, s)
    }

    private func decodeTextLike(from data: Data) throws -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data, options: []),
           let dict = obj as? [String: Any] {
            if let t = dict["text"] as? String, !t.isEmpty { return t }
            if let t = dict["reply"] as? String, !t.isEmpty { return t }
            if let t = dict["output_text"] as? String, !t.isEmpty { return t }
            if let t = dict["message"] as? String, !t.isEmpty { return t }
            if let d = dict["detail"] as? String, !d.isEmpty {
                throw SolaraAPIError.decode("detail: \(d)")
            }
        }
        let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if s.isEmpty { throw SolaraAPIError.emptyResponse }
        return s
    }
}



