// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-1c994dd068443dfc0a3ec2638138b2ca6e15be8dba7a35bb106031362fe99c9d"
// Source-SHA256: "45122025a5aaf09161e32f4abccc4392c26f1f36f07540388a6b9f84328c73eb"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation

enum AppConfig {

    /// 后端 /agent、/api/computer 等受保护接口的令牌（请求头 X-Agent-Token）。
    /// 从 Info.plist 的 AGENT_API_TOKEN 读取；没配置时为空串，不发这个头（后端会返回 403）。
    /// 令牌只放在你自己的构建配置里，不要提交到仓库。
    static var agentToken: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "AGENT_API_TOKEN") as? String ?? ""
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 未展开的构建变量（如 "$(AGENT_API_TOKEN)"）视为没配置
        return token.hasPrefix("$(") ? "" : token
    }

    enum API {

        // ✅ Debug 默认走本地（你要换地址，只改这一行就够）
        private static let defaultLocalBaseURLString = "http://YOUR_LAN_IP:8000"
        // ✅ Release 默认走公网
        private static let defaultPublicBaseURLString = "https://your-backend.example.com"

        // ✅✅✅ 固定式：上架版 → 公网
        // 本地： "http://YOUR_LAN_IP:8000"
        // 公网： "https://your-backend.example.com"
        private static let fixedBaseURLString = "http://YOUR_LAN_IP:8000"

        static let ttsPlaybackRate: Float = 1.2

        /// UserDefaults key (runtime override) —— 固定式下不再使用，但保留兼容
        private static let kOverrideKey = "SOLARA_API_BASE"

        /// Info.plist key (static config) —— 固定式下不再使用，但保留兼容
        private static let kInfoKey = "SOLARA_API_BASE"

        /// ✅ 保留字段（兼容旧逻辑），但固定式下不会参与选择
        private static let FORCE_LOCAL_ONLY: Bool = false

        // ✅✅✅ 固定式：永远只返回 fixedBaseURLString
        private static var rawBaseURLString: String {
            return fixedBaseURLString
        }

        /// Normalized api base string
        static var apiBase: String {
            normalizeBase(rawBaseURLString)
        }

        /// ✅✅✅ 永不崩溃版 baseURL：解析失败直接回退到 fixedBaseURLString
        static var baseURL: URL {
            if let url = URL(string: apiBase) {
                return url
            }

            let fallback = normalizeBase(fixedBaseURLString)
            print("❌ Invalid API base:", apiBase, "fallback to:", fallback)
            return URL(string: fallback)!
        }

        // ✅ 用于自动发现后端真实路由
        static var openAPIURL: URL { resolve("/openapi.json") }
        static var healthURL: URL { resolve("/health") }

        // ✅ 标准路由
        static var chatURL: URL { resolve("/chat") }
        static var transcribeURL: URL { resolve("/transcribe") }
        static var sessionURL: URL { resolve("/session") }

        // ✅ 兼容旧实现
        static var uploadImageURL: URL { resolve("/upload/image") }
        static var uploadAudioURL: URL { resolve("/upload/audio") }

        /// Resolve a relative path ("/health") or absolute URL ("https://...") into URL
        static func resolve(_ pathOrURL: String) -> URL {
            let s = pathOrURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if let u = URL(string: s), u.scheme != nil { return u }
            let cleaned = s.hasPrefix("/") ? String(s.dropFirst()) : s
            return baseURL.appendingPathComponent(cleaned)
        }

        // MARK: - Debug switching helpers (保留但固定式下默认不用)

        /// ✅ 仍保留：你若想临时写覆盖，也可以用（可选）
        static func forceLocalDebug(_ localBase: String = defaultLocalBaseURLString) {
            UserDefaults.standard.set(localBase, forKey: kOverrideKey)
            print("ℹ️ forceLocalDebug saved:", localBase, "(note: fixedBaseURLString still takes effect unless you change code)")
        }

        /// ✅ 仍保留：你若想临时写覆盖，也可以用（可选）
        static func forcePublicDebug(_ publicBase: String = defaultPublicBaseURLString) {
            UserDefaults.standard.set(publicBase, forKey: kOverrideKey)
            print("ℹ️ forcePublicDebug saved:", publicBase, "(note: fixedBaseURLString still takes effect unless you change code)")
        }

        /// ✅ 仍保留
        static func resetOverride() {
            UserDefaults.standard.removeObject(forKey: kOverrideKey)
        }

        /// ✅ 打印当前配置，确认到底走哪
        static func debugPrint() {
            print("🌐 AppConfig.API.apiBase =", apiBase)
            print("🌐 healthURL =", healthURL.absoluteString)
            print("🌐 FIXED_BASE =", normalizeBase(fixedBaseURLString))
        }

        /// ✅ 兼容旧调用：固定式下不做任何限制
        static func assertLocalOnly() {
            // 固定式：你自己控制 fixedBaseURLString，这里不再断言
        }

        // MARK: - Normalization

        private static func normalizeBase(_ raw: String) -> String {
            var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)

            if s.isEmpty {
                s = fixedBaseURLString
            }

            // If missing scheme, default to https (safe)
            if !(s.lowercased().hasPrefix("http://") || s.lowercased().hasPrefix("https://")) {
                s = "https://" + s
            }

            while s.hasSuffix("/") { s.removeLast() }
            return s
        }
    }

    enum Realtime {
        static let defaultModel = "gpt-realtime-2"
        static let defaultVoice = "marin"
        static let chatAGINativeProvider = "chatagi_native_realtime"
        static let chatAGINativeModelDisplay = "机器人 6.1"
        static let chatAGINativeTitle = "ChatAGI 阿杜实时语音模型"
        static let chatAGINativeProtocol = "minicpm_native"

        private static let nativeWSURLKey = "CHATAGI_NATIVE_REALTIME_WS_URL"
        private static let legacyLocalNativeWSURL = "ws://127.0.0.1:8006/v1/realtime?mode=audio"
        private static let defaultNativeWSURL = "ws://YOUR_LAN_IP:8006/v1/realtime?mode=audio"

        static var nativeRealtimeWSURLString: String {
            get {
                let saved = UserDefaults.standard.string(forKey: nativeWSURLKey)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if saved == legacyLocalNativeWSURL {
                    UserDefaults.standard.set(defaultNativeWSURL, forKey: nativeWSURLKey)
                    return defaultNativeWSURL
                }
                return saved.isEmpty ? defaultNativeWSURL : saved
            }
            set {
                UserDefaults.standard.set(
                    newValue.trimmingCharacters(in: .whitespacesAndNewlines),
                    forKey: nativeWSURLKey
                )
            }
        }
    }
}

// MARK: - Legacy compatibility
extension AppConfig {
    static var baseURLString: String { API.apiBase }
    static var baseURL: URL { API.baseURL } // ✅ 不再用 URL(...)!
}
