// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-1882be4d283af4883cfd41effa5713455634e8e113f698413b883a14b39fef1d"
// Source-SHA256: "b2b37a3a28bb98a8a0e9170c7624aedcb9ed62184b3a51e16fea0eb57710fb73"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation
import Combine
import StoreKit

@MainActor
final class IAPManager: ObservableObject {
    static let shared = IAPManager()

    enum PID {
        static let proWeekly = "solara_pro_weekly_799"
        // V1 上架只开放 ChatAGI Pro 一个自动续订订阅。
        // 下面两个 legacy ID 暂时保留，避免旧 UI 代码引用时报错；不要加入 PID.all。
        static let video5    = "solara_video_pack_5"
        static let video10   = "solara_video_pack_10"

        // V1 单套餐：只向 StoreKit 请求 Pro Weekly，避免未配置 Video Pack 导致 Missing products。
        static let all: Set<String> = [proWeekly]
    }

    @Published private(set) var products: [String: Product] = [:]
    @Published private(set) var isLoadingProducts: Bool = false
    @Published private(set) var isPurchasing: Bool = false
    @Published private(set) var hasActiveSubscription: Bool = false

    /// UI 只需要监听这个：有值就提示；nil = 没事
    @Published var lastError: String?

    /// Optional: backend auth providers
    var tokenProvider: () -> String? = { nil }
    var userIdProvider: () -> String? = { nil }

    private var updatesTask: Task<Void, Never>?
    private var preloadTask: Task<Void, Never>?

    // ✅ pending ingest（避免“购买成功但后端失败 → 卡死/不finish/丢单”）
    private let pendingStore = PendingIngestStore()

    private init() {
        pendingStore.load()
    }

    // MARK: - Public lifecycle

    /// Call once at app launch (idempotent)
    func start() {
        if updatesTask != nil { return }

        // 1) transaction listener
        updatesTask = Task { [weak self] in
            await self?.listenForTransactions()
        }

        // 2) preload products
        preloadTask?.cancel()
        preloadTask = Task { [weak self] in
            guard let self else { return }
            await self.loadProducts(force: true)
            await self.refreshEntitlements()
        }

        // 3) flush pending when possible
        Task { [weak self] in
            await self?.flushPendingIngests()
        }
    }

    func stop() {
        preloadTask?.cancel()
        preloadTask = nil

        updatesTask?.cancel()
        updatesTask = nil
    }

    // MARK: - Local entitlement check

    /// 本机 StoreKit 订阅状态。官方 IAP 流程里，购买成功后先以 App Store 当前权益解锁，
    /// 后端同步失败不阻塞本机 Pro 使用。
    func refreshEntitlements() async {
        var active = false

        for await v in Transaction.currentEntitlements {
            if Task.isCancelled { return }
            do {
                let tx = try requireVerified(v)
                guard tx.productID == PID.proWeekly else { continue }
                if tx.revocationDate != nil { continue }
                if let exp = tx.expirationDate, exp <= Date() { continue }
                active = true
                break
            } catch {
                continue
            }
        }

        hasActiveSubscription = active
    }

    // MARK: - Products

    func loadProducts(force: Bool = false) async {
        if isLoadingProducts { return }
        if !force, !products.isEmpty { return }

        isLoadingProducts = true
        defer { isLoadingProducts = false }

        do {
            let ids = PID.all
            let list = try await Product.products(for: ids)

            let loadedIds = Set(list.map { $0.id })
            let missing = ids.subtracting(loadedIds)

            if !missing.isEmpty {
                // 不 fatal：上架期间常见是 App Store Connect 未同步
                lastError = "Missing products: \(Array(missing).sorted().joined(separator: ", "))"
            } else {
                // 只在“确实无异常时”清掉
                if lastError?.hasPrefix("Missing products:") == true { lastError = nil }
            }

            var map: [String: Product] = [:]
            for p in list { map[p.id] = p }
            products = map

        } catch {
            let msg = (error as NSError).localizedDescription
            lastError = "Load products failed: \(msg)"
        }
    }

    func displayPrice(_ productId: String) -> String {
        products[productId]?.displayPrice ?? "--"
    }

    func isLoaded(_ productId: String) -> Bool {
        products[productId] != nil
    }

    // MARK: - Purchase

    /// 返回值含义：是否“完成了一次 StoreKit 购买流程（success）”
    /// - 注意：即使 backend ingest 失败，也会返回 true（但会保留 pending 重试）
    func purchase(productId: String) async -> Bool {
        if products.isEmpty {
            await loadProducts(force: true)
        }

        guard let product = products[productId] else {
            lastError = "Product not loaded: \(productId)"
            return false
        }

        isPurchasing = true
        defer { isPurchasing = false }

        do {
            let result = try await product.purchase()

            switch result {
            case .success(let verification):
                let tx = try requireVerified(verification)

                // ✅ 先记录 pending（防崩溃丢单）
                let payload = PendingIngestPayload.from(tx: tx)
                pendingStore.upsert(payload)

                // ✅ best-effort ingest（失败不阻塞 finish）
                do {
                    try await ingestToBackend(payload: payload)
                    pendingStore.remove(txId: payload.txId)
                    lastError = nil
                } catch {
                    // 这里不要当“购买失败”处理；是“同步失败”
                    let ns = error as NSError
                    if ns.code == PendingIngestPayload.missingAuthCode {
                        lastError = "Purchase completed. Please sign in to sync entitlement."
                    } else {
                        lastError = "Purchase completed, but sync failed. Please try again."
                    }
                }

                // ✅ 永远 finish，避免交易卡死/反复 updates
                await tx.finish()
                await refreshEntitlements()

                return true

            case .userCancelled:
                // ✅ 取消不算失败，不提示红色
                lastError = nil
                return false

            case .pending:
                // pending 不是失败，给个温和提示（UI 你可以映射成 info）
                lastError = "Purchase pending…"
                return false

            @unknown default:
                lastError = "Unknown purchase state"
                return false
            }

        } catch {
            let msg = (error as NSError).localizedDescription
            lastError = "Purchase failed: \(msg)"
            return false
        }
    }

    // MARK: - Restore

    /// Restore entitlements (subscriptions / non-consumables).
    /// NOTE: We do NOT finish() currentEntitlements.
    func restore() async {
        isPurchasing = true
        defer { isPurchasing = false }

        lastError = nil
        var didAny = false

        do {
            for await v in Transaction.currentEntitlements {
                if Task.isCancelled { return }
                let tx = try requireVerified(v)

                let payload = PendingIngestPayload.from(tx: tx)
                pendingStore.upsert(payload)

                do {
                    try await ingestToBackend(payload: payload)
                    pendingStore.remove(txId: payload.txId)
                    didAny = true
                } catch {
                    let ns = error as NSError
                    if ns.code == PendingIngestPayload.missingAuthCode {
                        lastError = "Please sign in before restoring purchases."
                    } else {
                        lastError = "Restore sync failed. Please try again."
                    }
                    // 恢复流程遇到错误就停（避免刷屏）
                    break
                }
            }
        } catch {
            let msg = (error as NSError).localizedDescription
            lastError = "Restore failed: \(msg)"
        }

        // ✅ 没有可恢复内容：不当成错误（避免 UI 红/黄条）
        if !didAny, lastError == nil {
            lastError = nil
        }

        await refreshEntitlements()
    }

    // MARK: - Pending ingest retry (public)

    /// 在「登录成功/拿到 user_id 或 token」后，建议调用一次：
    /// Task { await IAPManager.shared.flushPendingIngests() }
    func flushPendingIngests() async {
        // 没有 auth 就别刷（避免打后端）
        guard PendingIngestPayload.hasAuth(tokenProvider: tokenProvider, userIdProvider: userIdProvider) else { return }

        let items = pendingStore.itemsSnapshot()
        guard !items.isEmpty else { return }

        for p in items {
            if Task.isCancelled { return }
            do {
                try await ingestToBackend(payload: p)
                pendingStore.remove(txId: p.txId)
            } catch {
                // 如果又失败，先停（避免后台死循环）
                break
            }
        }
    }

    // MARK: - Transactions listener

    private func listenForTransactions() async {
        for await v in Transaction.updates {
            if Task.isCancelled { return }
            do {
                let tx = try requireVerified(v)

                // ✅ best-effort ingest + 永远 finish
                let payload = PendingIngestPayload.from(tx: tx)
                pendingStore.upsert(payload)

                do {
                    try await ingestToBackend(payload: payload)
                    pendingStore.remove(txId: payload.txId)
                } catch {
                    // 监听器里不要刷 UI 错误（上架冲刺：避免误报/打扰）
                }

                await tx.finish()
                await refreshEntitlements()
            } catch {
                // verification error：也不刷 UI
            }
        }
    }

    // MARK: - Backend ingest

    private func ingestToBackend(payload: PendingIngestPayload) async throws {
        let url = AppConfig.baseURL.appendingPathComponent("billing/ingest")

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        var body: [String: Any] = [
            "product_id": payload.productId,
            "tx_id": payload.txId
        ]
        if let expires = payload.expiresMs {
            body["expires_ms"] = expires
        }

        if let token = tokenProvider(), !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else if let uid = userIdProvider(), !uid.isEmpty {
            body["user_id"] = uid
        } else {
            throw PendingIngestPayload.missingAuthError()
        }

        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let s = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "IAP",
                code: (resp as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "billing/ingest failed: \(s)"]
            )
        }
    }

    private func requireVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let signed):
            return signed
        case .unverified(_, let error):
            throw error
        }
    }
}

// MARK: - Pending ingest payload + store

private struct PendingIngestPayload: Codable, Hashable {
    static let missingAuthCode: Int = -10

    let txId: String
    let productId: String
    let expiresMs: Int?

    static func from(tx: Transaction) -> PendingIngestPayload {
        let expMs: Int?
        if let exp = tx.expirationDate {
            expMs = Int(exp.timeIntervalSince1970 * 1000)
        } else {
            expMs = nil
        }
        return PendingIngestPayload(
            txId: String(tx.id),
            productId: tx.productID,
            expiresMs: expMs
        )
    }

    static func hasAuth(tokenProvider: () -> String?, userIdProvider: () -> String?) -> Bool {
        if let t = tokenProvider(), !t.isEmpty { return true }
        if let u = userIdProvider(), !u.isEmpty { return true }
        return false
    }

    static func missingAuthError() -> NSError {
        NSError(
            domain: "IAP",
            code: missingAuthCode,
            userInfo: [NSLocalizedDescriptionKey: "Missing auth (no token/user_id). Please sign in first."]
        )
    }
}

private final class PendingIngestStore {
    private let key = "solara_iap_pending_ingest_v1"
    private var items: [PendingIngestPayload] = []

    func load() {
        let ud = UserDefaults.standard
        guard let data = ud.data(forKey: key) else { return }
        if let arr = try? JSONDecoder().decode([PendingIngestPayload].self, from: data) {
            items = arr
        }
    }

    func persist() {
        let ud = UserDefaults.standard
        if let data = try? JSONEncoder().encode(items) {
            ud.set(data, forKey: key)
        }
    }

    func upsert(_ p: PendingIngestPayload) {
        if let idx = items.firstIndex(where: { $0.txId == p.txId }) {
            items[idx] = p
        } else {
            items.append(p)
        }
        persist()
    }

    func remove(txId: String) {
        items.removeAll { $0.txId == txId }
        persist()
    }

    func itemsSnapshot() -> [PendingIngestPayload] {
        items
    }
}





