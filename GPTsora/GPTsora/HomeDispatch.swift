// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-a133d6beef6a0d8d2b81bc1210fc797de3f14b810fe3e04ceac0f574580bd76d"
// Source-SHA256: "b313c88dc1fb91ba15aa839ed7f3e073e4321e83395791571b90e33736f306e6"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation

enum HomeDispatch {

    // ✅ 对外：执行 cmd
    static func run(cmd: String, deviceId: String) async throws -> String {
        // 先试 JSON /home/dispatch
        do {
            let r = try await dispatchJSON(cmd: cmd, deviceId: deviceId)
            return r
        } catch {
            // JSON 不通就试 REST /light/on/off/toggle
            let r = try await dispatchPiREST(cmd: cmd)
            return r
        }
    }

    // MARK: - JSON dispatch (POST /home/dispatch {device_id, cmd})
    private static func dispatchJSON(cmd: String, deviceId: String) async throws -> String {
        guard let url = URL(string: HomeControlConfig.dispatchJSONEndpoint) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "device_id": deviceId,
            "cmd": cmd
        ])

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(data: data, encoding: .utf8) ?? ""

        // 2xx OK，否则认为 JSON 路径不可用 -> throw 给 fallback
        guard (200..<300).contains(code) else {
            // 常见：404/405/422/500 都 fallback
            throw NSError(domain: "HomeDispatch.JSON", code: code, userInfo: [NSLocalizedDescriptionKey: body])
        }
        return "JSON OK (\(code)): \(body)"
    }

    // MARK: - Pi REST dispatch (POST /light/on|off|toggle)
    private static func dispatchPiREST(cmd: String) async throws -> String {
        let path: String
        switch cmd {
        case "light_on": path = "/light/on"
        case "light_off": path = "/light/off"
        case "light_toggle": path = "/light/toggle"
        default:
            // ask_clarify 或未知命令：不打硬件
            return "REST SKIP: cmd=\(cmd)"
        }

        guard let url = URL(string: HomeControlConfig.piRestBase + path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(code) else {
            throw NSError(domain: "HomeDispatch.REST", code: code, userInfo: [NSLocalizedDescriptionKey: body])
        }
        return "REST OK (\(code)): \(body)"
    }
}
