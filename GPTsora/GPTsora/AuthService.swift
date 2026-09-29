// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-8a2a60e4dc2f97668713312d5a3cc78cfea3c0d0f6b13d556982a743d1d2f06c"
// Source-SHA256: "cae27f9336a7466c1eaa796842365fb748894828325a8eeed53d56e3890c7407"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation
import Combine
import Security

// MARK: - Keychain Store (non-blocking)

private enum KeychainStore {

    private static let service = "com.solara.gptsora"
    private static let account = "access_token"

    // Save (background)
    static func saveToken(_ token: String) {
        guard let data = token.data(using: .utf8) else { return }

        DispatchQueue.global(qos: .utility).async {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]

            let update: [String: Any] = [
                kSecValueData as String: data
            ]

            let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            if status == errSecItemNotFound {
                var add = query
                add[kSecValueData as String] = data
                add[kSecAttrAccessible as String] =
                    kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                SecItemAdd(add as CFDictionary, nil)
            }
        }
    }

    // Load (async)
    static func loadToken() async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne
                ]

                var item: AnyObject?
                let status = SecItemCopyMatching(query as CFDictionary, &item)

                guard status == errSecSuccess,
                      let data = item as? Data,
                      let token = String(data: data, encoding: .utf8),
                      !token.isEmpty else {
                    cont.resume(returning: nil)
                    return
                }

                cont.resume(returning: token)
            }
        }
    }

    // Clear (background)
    static func clearToken() {
        DispatchQueue.global(qos: .utility).async {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            SecItemDelete(query as CFDictionary)
        }
    }
}

// MARK: - AuthManager (Unlocked, Production-grade)

@MainActor
final class AuthManager: ObservableObject {

    // MARK: - Public State

    @Published private(set) var isAuthenticated = false
    @Published private(set) var hasActiveSubscription = false   // 仅展示
    @Published private(set) var currentUserId: String?
    @Published private(set) var currentEmail: String?

    @Published private(set) var videoCredits: Int = 0
    @Published private(set) var voiceRemainingSec: Int = 0

    // UI 主动控制
    @Published var showAuthSheet = false

    /// 兼容字段（不再用于门禁）
    var isProUser: Bool { isAuthenticated && hasActiveSubscription }

    // JWT
    private(set) var accessToken: String?

    // MARK: - Internals

    private var isRefreshingBilling = false
    private var lastBillingRefreshAt: Date = .distantPast
    private let billingMinInterval: TimeInterval = 2.0

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        return URLSession(configuration: cfg)
    }()

    // MARK: - Init

    init() {
        Task {
            if let token = await KeychainStore.loadToken() {
                self.accessToken = token
                self.isAuthenticated = true
                await self.refreshBillingMe(force: true)
            }
        }
    }

    // MARK: - Apple Sign In

    func signInWithApple(identityToken: String) async throws {
        let url = AppConfig.baseURL.appendingPathComponent("auth/apple")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(
            withJSONObject: ["identity_token": identityToken]
        )

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw NSError(domain: "Auth", code: -1)
        }

        struct Resp: Decodable {
            let ok: Bool?
            let user_id: String?
            let access_token: String?
            let email: String?
        }

        let obj = try JSONDecoder().decode(Resp.self, from: data)
        guard obj.ok == true,
              let token = obj.access_token,
              !token.isEmpty else {
            throw NSError(domain: "Auth", code: -2)
        }

        KeychainStore.saveToken(token)

        accessToken = token
        isAuthenticated = true
        currentUserId = obj.user_id
        currentEmail = obj.email

        await refreshBillingMe(force: true)
        showAuthSheet = false
    }

    // MARK: - Billing (no gating)

    func refreshBillingMe(force: Bool = false) async {
        guard isAuthenticated, let _ = accessToken else { return }
        guard !isRefreshingBilling else { return }

        let now = Date()
        if !force && now.timeIntervalSince(lastBillingRefreshAt) < billingMinInterval {
            return
        }

        isRefreshingBilling = true
        lastBillingRefreshAt = now
        defer { isRefreshingBilling = false }

        do {
            let req = try authorizedRequest(
                path: "billing/me",
                method: "GET"
            )

            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return }

            if http.statusCode == 401 {
                signOut()
                return
            }

            guard (200...299).contains(http.statusCode) else { return }

            struct Billing: Decodable {
                let is_pro: Bool?
                let video_credits: Int?
                let voice_remaining_sec: Int?
                let user_id: String?
            }

            let obj = try JSONDecoder().decode(Billing.self, from: data)

            hasActiveSubscription = obj.is_pro ?? false
            videoCredits = obj.video_credits ?? 0
            voiceRemainingSec = obj.voice_remaining_sec ?? 0
            if let uid = obj.user_id { currentUserId = uid }

        } catch {
            // 网络异常不影响使用体验
        }
    }

    // MARK: - HTTP Helper

    private func authorizedRequest(
        path: String,
        method: String
    ) throws -> URLRequest {
        guard let token = accessToken else {
            throw NSError(domain: "Auth", code: -10)
        }
        let url = AppConfig.baseURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    // MARK: - Sign Out

    func signOut() {
        KeychainStore.clearToken()

        accessToken = nil
        isAuthenticated = false
        hasActiveSubscription = false
        currentUserId = nil
        currentEmail = nil
        videoCredits = 0
        voiceRemainingSec = 0

        showAuthSheet = false
    }
}


