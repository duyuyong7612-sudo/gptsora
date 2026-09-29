//
//  1ContentView.swift  (BILLING SUBMODULE / SINGLE SOURCE)
//  ✅ Billing 子模块：Server authoritative（升级版）
//  ✅ 修复“状态忽真忽假/已订阅仍402”的关键：
//     - 始终携带稳定 guest user_id（即使有 Bearer token）
//     - 后端可用 provided user_id 做 guest→authed 合并
//  ✅ 统一：所有接口返回 billing_snapshot（store 单一真相源）
//

// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-5611ed5d24c2a3828a3e9f11253f6ecb97239ffd1b4a90e0bf396a1768beb04e"
// Source-SHA256: "58175f3a79e5747984d200313722f00e5ad8cf8ed49441ecf3fe4c4722274ca3"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation
import Combine
import SwiftUI

// =====================================================
// Config / Auth
// =====================================================

enum SolaraServerConfig {
    static func apiBaseURL() -> URL? {
        let keys = ["API_BASE_URL", "SERVER_BASE_URL", "BASE_URL", "SOLARA_API_BASE_URL"]
        for k in keys {
            if let v = Bundle.main.object(forInfoDictionaryKey: k) as? String {
                let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty { continue }
                let normalized = t.hasSuffix("/") ? String(t.dropLast()) : t
                if let url = URL(string: normalized) { return url }
            }
        }
        return nil
    }

    /// RevenueCat Entitlement Identifier（订阅）——仍保留，但 Paywall 侧不要死依赖它
    static let proEntitlementId: String = "Solara AI Pro"
}

enum SolaraAuthToken {
    static func currentBearerToken() -> String? {
        let candidates = ["access_token", "ACCESS_TOKEN", "solara_access_token", "SOLARA_ACCESS_TOKEN"]
        for k in candidates {
            if let v = UserDefaults.standard.string(forKey: k) {
                var t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty { continue }

                // ✅ 兼容：如果有人误存成 "Bearer xxx"，这里剥掉 Bearer
                if t.lowercased().hasPrefix("bearer ") {
                    t = String(t.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if !t.isEmpty { return t }
            }
        }
        return nil
    }
}

enum SolaraGuestUser {
    private static let key = "solara_guest_user_id_v1"

    static var userId: String {
        if let v = UserDefaults.standard.string(forKey: key) {
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        let newId = "guest:\(UUID().uuidString.lowercased())"
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }
}

// =====================================================
// DTOs
// =====================================================

struct SolaraBillingMeResponse: Codable {
    let ok: Bool
    let billing: SolaraBillingSnapshot
}

struct SolaraBillingSnapshot: Codable {
    let tier: String
    let authed: Bool
    let userId: String
    let isPro: Bool
    let proUntil: Int

    let weekResetAt: Int
    let voiceWeeklyCapSec: Int
    let voiceWeeklyUsedSec: Int
    let voiceRemainingSec: Int

    let videoCredits: Int

    let canVoice: Bool
    let canVideo: Bool

    let policy: Policy
    let serverNowMs: Int64

    struct Policy: Codable {
        let videoRequirePro: Bool
        let voiceStartMinSec: Int
        let videoConsumePerGen: Int
        // 后端可能额外返回 voicePingGraceSec 等字段；Codable 会自动忽略未知字段
    }
}

struct SolaraVoiceStartResponse: Codable {
    let ok: Bool
    let callId: String
    let hardStopAtMs: Int64?
    let billing: SolaraBillingSnapshot
}

struct SolaraVoicePingResponse: Codable {
    let ok: Bool
    let callId: String?
    let remainingSec: Int?
    let hardStopAtMs: Int64?
    let billing: SolaraBillingSnapshot
}

struct SolaraVoiceEndResponse: Codable {
    let ok: Bool
    let chargedSec: Int?
    let billing: SolaraBillingSnapshot
}

struct SolaraBillingIngestResponse: Codable {
    let ok: Bool
    let skipped: Bool?
    let productId: String?
    let txId: String?
    let billing: SolaraBillingSnapshot
}

struct SolaraVideoConsumeResponse: Codable {
    let ok: Bool
    let consumeId: String?
    let skipped: Bool?
    let billing: SolaraBillingSnapshot
}

struct SolaraVideoRefundResponse: Codable {
    let ok: Bool
    let skipped: Bool?
    let billing: SolaraBillingSnapshot
}

struct SolaraBillingErrorPayload: Codable {
    let ok: Bool?
    let error: String?
    let action: String?
    let billing: SolaraBillingSnapshot?
}

struct SolaraBillingHTTPError: Error {
    let status: Int
    let payload: SolaraBillingErrorPayload?
}

// =====================================================
// API
// =====================================================

enum SolaraBillingAPI {

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    private static func makeURL(path: String, query: [URLQueryItem] = []) -> URL? {
        guard let base = SolaraServerConfig.apiBaseURL(),
              var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }

        let p = path.hasPrefix("/") ? path : "/" + path

        // base 可自带 path，例如 https://xx.com/api
        let basePath = comps.path
        if basePath.isEmpty || basePath == "/" {
            comps.path = p
        } else {
            let trimmed = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
            comps.path = trimmed + p
        }

        if !query.isEmpty { comps.queryItems = query }
        return comps.url
    }

    private static func makeRequest(
        url: URL,
        method: String,
        body: [String: Any]? = nil,
        idempotencyKey: String? = nil
    ) throws -> URLRequest {

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // ✅ 统一 request-id，便于后端日志串联（后端会用 x-request-id）
        req.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-Id")

        // ✅ 即使 authed，也把当前稳定 guest id 带上，让后端可做 guest→authed 合并
        req.setValue(SolaraGuestUser.userId, forHTTPHeaderField: "X-Client-Guest-Id")

        if let token = SolaraAuthToken.currentBearerToken() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let idempotencyKey, !idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            req.setValue(idempotencyKey, forHTTPHeaderField: "X-Idempotency-Key")
        }

        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        }
        return req
    }

    private static func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1

        if (200...299).contains(status) {
            return try decoder().decode(T.self, from: data)
        } else {
            let payload = try? decoder().decode(SolaraBillingErrorPayload.self, from: data)
            throw SolaraBillingHTTPError(status: status, payload: payload)
        }
    }

    // ✅ 关键：永远提供 stable user_id（让后端统一识别 + 可做合并）
    private static func stableUserIdForServer() -> String {
        return SolaraGuestUser.userId
    }

    // MARK: - GET /billing/me
    static func me() async throws -> SolaraBillingMeResponse {
        // ✅ 不管是否 authed，都把 guest user_id 作为 provided 传给后端（用于 merge）
        let q: [URLQueryItem] = [
            .init(name: "user_id", value: stableUserIdForServer())
        ]

        guard let url = makeURL(path: "/billing/me", query: q) else {
            throw NSError(domain: "Billing", code: -10,
                          userInfo: [NSLocalizedDescriptionKey: "Missing API_BASE_URL in Info.plist"])
        }
        let req = try makeRequest(url: url, method: "GET")
        return try await send(req)
    }

    // MARK: - POST /billing/voice/start
    static func voiceStart() async throws -> SolaraVoiceStartResponse {
        guard let url = makeURL(path: "/billing/voice/start") else {
            throw NSError(domain: "Billing", code: -10,
                          userInfo: [NSLocalizedDescriptionKey: "Missing API_BASE_URL in Info.plist"])
        }
        // ✅ 永远带 user_id（即使 authed）
        let body: [String: Any] = ["user_id": stableUserIdForServer()]
        let req = try makeRequest(url: url, method: "POST", body: body)
        return try await send(req)
    }

    // MARK: - POST /billing/voice/ping
    static func voicePing(callId: String) async throws -> SolaraVoicePingResponse {
        guard let url = makeURL(path: "/billing/voice/ping") else {
            throw NSError(domain: "Billing", code: -10,
                          userInfo: [NSLocalizedDescriptionKey: "Missing API_BASE_URL in Info.plist"])
        }
        let body: [String: Any] = ["user_id": stableUserIdForServer(), "call_id": callId]
        let req = try makeRequest(url: url, method: "POST", body: body)
        return try await send(req)
    }

    // MARK: - POST /billing/voice/end
    static func voiceEnd(callId: String) async throws -> SolaraVoiceEndResponse {
        guard let url = makeURL(path: "/billing/voice/end") else {
            throw NSError(domain: "Billing", code: -10,
                          userInfo: [NSLocalizedDescriptionKey: "Missing API_BASE_URL in Info.plist"])
        }
        let body: [String: Any] = ["user_id": stableUserIdForServer(), "call_id": callId]
        let req = try makeRequest(url: url, method: "POST", body: body)
        return try await send(req)
    }

    // MARK: - POST /billing/ingest
    static func ingest(productId: String, txId: String, expiresMs: Int64?) async throws -> SolaraBillingIngestResponse {
        guard let url = makeURL(path: "/billing/ingest") else {
            throw NSError(domain: "Billing", code: -10,
                          userInfo: [NSLocalizedDescriptionKey: "Missing API_BASE_URL in Info.plist"])
        }
        var body: [String: Any] = ["user_id": stableUserIdForServer(), "product_id": productId, "tx_id": txId]
        if let expiresMs { body["expires_ms"] = expiresMs }
        let req = try makeRequest(url: url, method: "POST", body: body, idempotencyKey: txId)
        return try await send(req)
    }

    // MARK: - POST /billing/video/consume
    static func videoConsume(amount: Int = 1, reason: String = "gen", idempotencyKey: String? = nil) async throws -> SolaraVideoConsumeResponse {
        guard let url = makeURL(path: "/billing/video/consume") else {
            throw NSError(domain: "Billing", code: -10,
                          userInfo: [NSLocalizedDescriptionKey: "Missing API_BASE_URL in Info.plist"])
        }
        let body: [String: Any] = ["user_id": stableUserIdForServer(), "amount": amount, "reason": reason]
        let req = try makeRequest(url: url, method: "POST", body: body, idempotencyKey: idempotencyKey)
        return try await send(req)
    }

    // MARK: - POST /billing/video/refund
    static func videoRefund(consumeId: String) async throws -> SolaraVideoRefundResponse {
        guard let url = makeURL(path: "/billing/video/refund") else {
            throw NSError(domain: "Billing", code: -10,
                          userInfo: [NSLocalizedDescriptionKey: "Missing API_BASE_URL in Info.plist"])
        }
        let body: [String: Any] = ["user_id": stableUserIdForServer(), "consume_id": consumeId]
        let req = try makeRequest(url: url, method: "POST", body: body)
        return try await send(req)
    }
}

// =====================================================
// Store (UI single truth)
// =====================================================

@MainActor
final class SolaraBillingStore: ObservableObject {
    static let shared = SolaraBillingStore()

    @Published private(set) var snapshot: SolaraBillingSnapshot?
    @Published private(set) var lastError: String?
    @Published private(set) var isRefreshing: Bool = false

    var isPro: Bool { snapshot?.isPro == true }
    var canVoice: Bool { snapshot?.canVoice == true }
    var voiceRemainingSec: Int { snapshot?.voiceRemainingSec ?? 0 }

    var canVideo: Bool { snapshot?.canVideo == true }
    var videoCredits: Int { snapshot?.videoCredits ?? 0 }

    func refreshMe() async {
        isRefreshing = true
        lastError = nil
        do {
            let resp = try await SolaraBillingAPI.me()
            snapshot = resp.billing
        } catch {
            lastError = (error as NSError).localizedDescription
        }
        isRefreshing = false
    }

    /// ✅ 语音 start：返回 callId（并更新 snapshot）
    func startVoice() async throws -> SolaraVoiceStartResponse {
        do {
            let resp = try await SolaraBillingAPI.voiceStart()
            snapshot = resp.billing
            return resp
        } catch let e as SolaraBillingHTTPError {
            if let b = e.payload?.billing { snapshot = b }
            throw e
        }
    }

    /// ✅ 语音 ping：正常返回 remaining；402(action=hangup) 由调用方处理（并且 snapshot 会更新）
    func pingVoice(callId: String) async throws -> SolaraVoicePingResponse {
        do {
            let resp = try await SolaraBillingAPI.voicePing(callId: callId)
            snapshot = resp.billing
            return resp
        } catch let e as SolaraBillingHTTPError {
            if let b = e.payload?.billing { snapshot = b }
            throw e
        }
    }

    /// ✅ 语音 end：结算扣时长
    func endVoice(callId: String) async {
        do {
            let resp = try await SolaraBillingAPI.voiceEnd(callId: callId)
            snapshot = resp.billing
        } catch {
            lastError = (error as NSError).localizedDescription
        }
    }

    /// ✅ 购买入账（订阅/视频包）
    func ingestPurchase(productId: String, txId: String, expiresMs: Int64?) async throws {
        let resp = try await SolaraBillingAPI.ingest(productId: productId, txId: txId, expiresMs: expiresMs)
        snapshot = resp.billing
    }

    /// ✅ 生成前扣费（返回 consumeId，幂等由 idempotencyKey 控制）
    func consumeVideo(amount: Int = 1, reason: String = "gen", idempotencyKey: String? = nil) async throws -> String {
        do {
            let resp = try await SolaraBillingAPI.videoConsume(amount: amount, reason: reason, idempotencyKey: idempotencyKey)
            snapshot = resp.billing
            return resp.consumeId ?? ""
        } catch let e as SolaraBillingHTTPError {
            if let b = e.payload?.billing { snapshot = b }
            throw e
        }
    }

    /// ✅ 生成失败补回
    func refundVideo(consumeId: String) async {
        do {
            let resp = try await SolaraBillingAPI.videoRefund(consumeId: consumeId)
            snapshot = resp.billing
        } catch {
            lastError = (error as NSError).localizedDescription
        }
    }
}

