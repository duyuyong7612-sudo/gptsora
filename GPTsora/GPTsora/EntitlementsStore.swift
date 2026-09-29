// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-c0393cf4f72576b3da06d9463de153eb1399143e6e3f48952c6b87f6cae190bb"
// Source-SHA256: "8b93a4afc39c531359841903496d71dc5a40ea236ea82f0af075fe0a16094854"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation
import Combine

struct BillingMe: Codable {
    let ok: Bool
    let user_id: String
    let is_pro: Bool
    let pro_until: Int
    let week_reset_at: Int
    let voice_remaining_sec: Int
    let video_credits: Int
}

enum LockedFeature {
    case videoGeneration
    case realtimeVoice
    case saveShare
}

enum GateResult {
    case allowed
    case needsLogin
    case needsPro
}

@MainActor
final class EntitlementsStore: ObservableObject {
    @Published var me: BillingMe?
    @Published var authToken: String? = nil   // ✅ 你登录成功后把 token 放这里（Keychain 更好）

    var isLoggedIn: Bool { authToken != nil }
    var isPro: Bool { me?.is_pro ?? false }

    // ✅ 最核心：决定是否放行
    func gate(_ feature: LockedFeature) -> GateResult {
        guard isLoggedIn else { return .needsLogin }
        if isPro { return .allowed }

        // 你现在想“登录解封”，但非 Pro 仍可能没额度
        switch feature {
        case .videoGeneration:
            return (me?.video_credits ?? 0) > 0 ? .allowed : .needsPro
        case .realtimeVoice:
            return (me?.voice_remaining_sec ?? 0) > 0 ? .allowed : .needsPro
        case .saveShare:
            return .needsPro
        }
    }

    func refresh(baseURL: URL) async {
        var req = URLRequest(url: baseURL.appendingPathComponent("/billing/me"))
        req.httpMethod = "GET"
        if let t = authToken, !t.isEmpty {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let decoded = try JSONDecoder().decode(BillingMe.self, from: data)
            self.me = decoded
        } catch {
            // 网络失败就保留旧值即可
        }
    }
}
