// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-3ca8ac78358731707b586534a64456b2d084efe541b7516bfca33d0a3b23ffa5"
// Source-SHA256: "55740fc9ce4113a4bde9fda1f9dfd606299c0c8432d0583bfc9ea0461879bfc0"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation
import Combine

@MainActor
final class AuthManager: ObservableObject {

    // MARK: - Public State

    @Published private(set) var isAuthenticated = false
    @Published private(set) var hasActiveSubscription = false   // 仅用于展示
    @Published private(set) var currentUserId: String?
    @Published private(set) var currentEmail: String?

    @Published private(set) var videoCredits: Int = 0
    @Published private(set) var voiceRemainingSec: Int = 0

    // UI 控制：是否展示登录页（不再作为 Gate）
    @Published var showAuthSheet = false

    // 后端 JWT
    private(set) var accessToken: String?

    // 防止并发刷新
    private var isRefreshingBilling = false

    // MARK: - Init

    init() {
        KeychainStore.loadToken { [weak self] token in
            guard let self else { return }
            guard let token else { return }

            self.accessToken = token
            self.isAuthenticated = true

            Task { await self.refreshBillingMe() }
        }
    }

    // MARK: - Sign In (Apple)

    func signInWithApple(identityToken: String) async throws {
        let url = AppConfig.baseURL.appendingPathComponent("auth/apple")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(
            withJSONObject: ["identity_token": identityToken]
        )

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw UserErrorMessage.from(
                NSError(domain: "Auth", code: -1)
            )
        }

        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let token = obj?["access_token"] as? String
        let uid = obj?["user_id"] as? String
        let email = obj?["email"] as? String

        guard let token, !token.isEmpty else {
            throw UserErrorMessage.from(
                NSError(domain: "Auth", code: -2)
            )
        }

        KeychainStore.saveToken(token)

        self.accessToken = token
        self.isAuthenticated = true
        self.currentUserId = uid
        self.currentEmail = email

        await refreshBillingMe()
        showAuthSheet = false
    }

    // MARK: - Billing (仅同步状态，不做门禁)

    func refreshBillingMe() async {
        guard isAuthenticated else { return }
        guard !isRefreshingBilling else { return }
        isRefreshingBilling = true
        defer { isRefreshingBilling = false }

        do {
            var req = try authorizedRequest(
                path: "billing/me",
                method: "GET"
            )

            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return }

            if http.statusCode == 401 {
                signOut()
                return
            }

            guard (200...299).contains(http.statusCode) else { return }

            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            hasActiveSubscription =
                (obj?["is_pro"] as? Bool) ?? false
            videoCredits =
                (obj?["video_credits"] as? Int) ?? 0
            voiceRemainingSec =
                (obj?["voice_remaining_sec"] as? Int) ?? 0

            if let uid = obj?["user_id"] as? String {
                currentUserId = uid
            }

        } catch {
            // 网络失败不影响使用体验
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
        req.setValue(
            "Bearer \(token)",
            forHTTPHeaderField: "Authorization"
        )
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

