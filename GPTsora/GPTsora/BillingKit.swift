//
//  BillingKit.swift  (PAYMENT MODULE) ✅ PRODUCTION-GRADE (CLOSED LOOP)
//  ✅ 目标：订阅/视频包闭环稳定（不再“点几次又回订阅/已订阅不续接”）
//  ✅ 不改 RealtimeQuickService.swift：用 VoiceBillingGuard 子模块做 ping/end
//
//  ✅ 核心点：
//  1) RevenueCat 身份对齐：每次门禁/Paywall 前 ensureUserIdAligned()
//  2) 门禁 402：先 silent syncPurchases -> ingest -> refresh -> retry startVoice（含短延迟传播）
//  3) 通话扣秒：VoiceBillingGuard 每 25s ping；402 自动挂断 + end 结算
//

// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-a9f47ed39b895e79cf468a0069aec64bb30b8249dbb6e24f13eaea526edf1f13"
// Source-SHA256: "82556ac05199805144bb615ba4116405777988facb352c32be0612f9822ea195"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation
import SwiftUI
import Combine
import RevenueCat

// =====================================================
// MARK: - Voice billing guard (no changes to RealtimeQuickService)
// =====================================================
@MainActor
final class VoiceBillingGuard {
    static let shared = VoiceBillingGuard()
    private init() {}

    private let billing = SolaraBillingStore.shared

    private var callId: String?
    private var pingTask: Task<Void, Never>?
    private var isEnding = false

    /// 外部传入：当后端 402(action=hangup) 时怎么挂断通话
    private var hangupRealtime: (() -> Void)?

    /// 建议 25s 一次（20~30 秒都行）
    private let pingIntervalSec: UInt64 = 25

    /// ✅ 入口：拿到 callId 后调用
    func begin(callId: String, hangupRealtime: @escaping () -> Void) {
        // 同一通话已经在跑 guard，就不要重复 begin
        if self.callId == callId, pingTask != nil { return }

        self.callId = callId
        self.hangupRealtime = hangupRealtime
        self.isEnding = false

        stopPingTask()

        // ✅ 用 Task 循环替代 DispatchSourceTimer：生产更稳、Actor 更干净
        pingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: pingIntervalSec * 1_000_000_000)
                if Task.isCancelled { return }
                await self.pingOnce()
            }
        }
    }

    /// ✅ 出口：通话断开/手动挂断时调用
    func end() {
        guard !isEnding else { return }
        isEnding = true

        stopPingTask()

        let id = callId
        callId = nil
        hangupRealtime = nil

        guard let callId = id, !callId.isEmpty else { return }

        Task { @MainActor in
            await billing.endVoice(callId: callId) // ✅ 最终结算扣秒（后端在 end 时落账）
        }
    }

    private func stopPingTask() {
        pingTask?.cancel()
        pingTask = nil
    }

    private func pingOnce() async {
        guard let callId, !callId.isEmpty else { return }
        if isEnding { return }

        do {
            _ = try await billing.pingVoice(callId: callId) // ✅ 通话中校验/硬停
        } catch let e as SolaraBillingHTTPError {
            if e.status == 402 {
                // 用量耗尽/撤销：强制挂断 + 结算
                hangupRealtime?()
                end()
            }
        } catch {
            // 网络抖动不致命：下次继续 ping
        }
    }
}

// =====================================================
// MARK: - RevenueCat Bootstrap / Identity (single place)
// =====================================================
private enum RC {
    private static var didConfigure = false
    private static let lastUidKey = "rc_last_app_user_id_v1"

    static func revenueCatAPIKey() -> String? {
        let keys = ["REVENUECAT_API_KEY", "RevenueCatAPIKey", "REVENUECAT_PUBLIC_SDK_KEY", "RevenueCatPublicSDKKey"]
        for k in keys {
            if let v = Bundle.main.object(forInfoDictionaryKey: k) as? String {
                let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
        }
        return nil
    }

    /// ✅ 稳定 uid：优先 JWT sub（若你已登录），否则 guest id（UserDefaults 持久化）
    static func stableUserId() -> String {
        if let token = SolaraAuthToken.currentBearerToken(),
           let sub = decodeJWTSub(token),
           !sub.isEmpty {
            return sub
        }
        return SolaraGuestUser.userId
    }

    /// ✅ 一次性配置（不 async，避免到处 await）
    static func configureIfNeeded() -> String? {
        if didConfigure { return nil }
        guard let apiKey = revenueCatAPIKey(),
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Missing REVENUECAT_API_KEY in Info.plist"
        }

        Purchases.logLevel = .info
        Purchases.configure(withAPIKey: apiKey)

        // 第一次就 logIn 到稳定 uid（避免一直用匿名）
        let uid = stableUserId()
        Purchases.shared.logIn(uid) { _, _, _ in
            // ignore
        }

        UserDefaults.standard.set(uid, forKey: lastUidKey)
        didConfigure = true
        return nil
    }

    /// ✅ 每次门禁/Paywall 前对齐（用户从 guest->apple:sub 时会变）
    static func ensureUserIdAligned() async {
        _ = configureIfNeeded()

        let uid = stableUserId()
        let last = UserDefaults.standard.string(forKey: lastUidKey) ?? ""
        guard uid != last else { return }

        do {
            _ = try await Purchases.shared.logInAsync(uid)
            UserDefaults.standard.set(uid, forKey: lastUidKey)
        } catch {
            print("[RC] logInAsync failed:", (error as NSError).localizedDescription)
        }
    }

    /// ✅ 找任意 active entitlement（不死盯 entitlementId）
    static func bestActiveEntitlement(ci: CustomerInfo) -> (productId: String, expiresMs: Int64?)? {
        let active = Array(ci.entitlements.active.values)
        guard let first = active.first else { return nil }
        let pid = first.productIdentifier
        let ms: Int64? = {
            guard let exp = first.expirationDate else { return nil }
            return Int64(exp.timeIntervalSince1970 * 1000)
        }()
        return (pid, ms)
    }

    private static func decodeJWTSub(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        let payload = String(parts[1])

        func b64urlDecode(_ s: String) -> Data? {
            var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            let pad = (4 - (t.count % 4)) % 4
            if pad > 0 { t += String(repeating: "=", count: pad) }
            return Data(base64Encoded: t)
        }

        guard let data = b64urlDecode(payload) else { return nil }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return (obj["sub"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// =====================================================
// MARK: - Paywall Center (single source of truth)
// =====================================================
@MainActor
final class SolaraPaywallCenter: ObservableObject {
    static let shared = SolaraPaywallCenter()
    private init() {}

    @Published var showPaywall: Bool = false
    @Published var offeringId: String? = nil   // nil=订阅(current), "video"=视频包

    private let billing = SolaraBillingStore.shared

    private var pendingStartVoice: Bool = false
    private var pendingVoiceConnect: (() -> Void)?
    private var pendingVoiceHangup: (() -> Void)?
    private var activeCallId: String?

    private var isStartingVoice = false

    func openSubscriptionPaywall(
        pendingStartVoice: Bool = false,
        connectRealtime: (() -> Void)? = nil,
        hangupRealtime: (() -> Void)? = nil
    ) {
        self.pendingStartVoice = pendingStartVoice
        self.pendingVoiceConnect = connectRealtime
        self.pendingVoiceHangup = hangupRealtime
        self.offeringId = nil
        self.showPaywall = true
    }

    func openVideoPaywall() {
        self.offeringId = "video"
        self.showPaywall = true
    }

    // -----------------------------------------------------
    // MARK: Voice gate (核心闭环)
    // -----------------------------------------------------

    /// ✅ Voice gate：成功就回调 connectRealtime；扣秒守卫用 hangupRealtime
    ///
    /// 商用关键：
    /// - 不只看 billing.canVoice（快照可能落后 webhook/ingest）
    /// - 以 startVoice 的返回为准
    /// - 402 时做 silentRecover + 短延迟 + refresh + 重试 startVoice
    func requestStartVoice(
        connectRealtime: @escaping () -> Void,
        hangupRealtime: @escaping () -> Void
    ) {
        guard !isStartingVoice else { return }
        isStartingVoice = true

        Task { @MainActor in
            defer { self.isStartingVoice = false }

            await RC.ensureUserIdAligned()

            // 先刷新一次快照（用于 UI/提示，不作为唯一门禁依据）
            await billing.refreshMe()

            // 1) 直接尝试 startVoice（权威门禁）
            let first = await startVoiceAndMaybeConnect(connectRealtime: connectRealtime, hangupRealtime: hangupRealtime)
            if first == .success { return }
            if first == .non402Failure { return } // 非 402 的失败：先不弹 paywall（避免误导）

            // 2) 402：做 silent recover（syncPurchases -> ingest -> refresh）
            let recovered = await silentRecoverSubscriptionToServer()

            if recovered {
                // 给后端 ingest/刷新一点传播时间（你日志里就是“先 false 后 true”）
                try? await Task.sleep(nanoseconds: 350_000_000)
                await billing.refreshMe()

                // 重试 startVoice（最多 2 次，避免用户一直点）
                for backoffNs in [0, 800_000_000] {
                    if backoffNs > 0 { try? await Task.sleep(nanoseconds: UInt64(backoffNs)) }
                    let again = await startVoiceAndMaybeConnect(connectRealtime: connectRealtime, hangupRealtime: hangupRealtime)
                    if again == .success { return }
                    if again == .non402Failure { return }
                }
            }

            // 3) 最后才弹订阅 paywall，并设置 pending（闭环）
            openSubscriptionPaywall(
                pendingStartVoice: true,
                connectRealtime: connectRealtime,
                hangupRealtime: hangupRealtime
            )
        }
    }

    private enum StartVoiceAttempt {
        case success
        case denied402
        case non402Failure
    }

    /// ✅ 尝试 startVoice；成功则 begin guard + connectRealtime
    private func startVoiceAndMaybeConnect(
        connectRealtime: @escaping () -> Void,
        hangupRealtime: @escaping () -> Void
    ) async -> StartVoiceAttempt {
        do {
            let resp = try await billing.startVoice()
            self.activeCallId = resp.callId

            VoiceBillingGuard.shared.begin(callId: resp.callId, hangupRealtime: hangupRealtime)
            connectRealtime()
            return .success
        } catch let e as SolaraBillingHTTPError {
            if e.status == 402 {
                return .denied402
            } else {
                print("[Pay] startVoice http=\(e.status) err=\(e.payload?.error ?? "")")
                return .non402Failure
            }
        } catch {
            print("[Pay] startVoice error=\(error)")
            return .non402Failure
        }
    }

    /// ✅ silent recover：把 RevenueCat 的“已激活权益”推到你后端（ingest），并刷新快照
    /// 返回是否“看起来能 voice”（仅作参考，真正以 startVoice 为准）
    private func silentRecoverSubscriptionToServer() async -> Bool {
        do {
            _ = RC.configureIfNeeded()

            // ✅ syncPurchases 最关键：强制 RC 拉苹果侧最新收据
            let ci = try await Purchases.shared.syncPurchasesAsync()

            guard let (pid, expMs) = RC.bestActiveEntitlement(ci: ci) else {
                return false
            }

            // txId 不一定要是苹果原始 tx（RC/后端闭环用稳定串即可去重）
            let txId = "rc_sync:\(ci.originalAppUserId):\(pid):\(expMs ?? 0)"

            try await billing.ingestPurchase(productId: pid, txId: txId, expiresMs: expMs)
            await billing.refreshMe()
            return billing.canVoice
        } catch {
            print("[Pay] silentRecover failed:", (error as NSError).localizedDescription)
            return false
        }
    }

    // -----------------------------------------------------
    // MARK: Voice end
    // -----------------------------------------------------

    func endVoiceIfNeeded() {
        activeCallId = nil
        VoiceBillingGuard.shared.end()
    }

    // -----------------------------------------------------
    // MARK: Paywall lifecycle
    // -----------------------------------------------------

    func onPaywallDismissed() {
        Task { @MainActor in
            await billing.refreshMe()
            await resumePendingIfPossible()
        }
    }

    func onIngestSucceededAndDismiss() {
        showPaywall = false
        onPaywallDismissed()
    }

    /// ✅ Paywall 关闭后：如果当时是“要语音但被拦”，这里自动续接
    private func resumePendingIfPossible() async {
        guard pendingStartVoice else { return }
        guard let connect = pendingVoiceConnect else { return }
        guard let hangup = pendingVoiceHangup else { return }

        // 先清 pending，避免循环弹窗
        pendingStartVoice = false
        pendingVoiceConnect = nil
        pendingVoiceHangup = nil

        await RC.ensureUserIdAligned()
        await billing.refreshMe()

        let r = await startVoiceAndMaybeConnect(connectRealtime: connect, hangupRealtime: hangup)
        if r == .success { return }

        // 仍 402：再弹一次订阅 paywall（说明 ingest/权益还没到）
        if r == .denied402 {
            openSubscriptionPaywall(pendingStartVoice: true, connectRealtime: connect, hangupRealtime: hangup)
        }
    }
}

// =====================================================
// MARK: - PaywallView (RevenueCat) + server ingest
// =====================================================
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss

    let offeringId: String?   // nil=订阅(current), "video"=视频包

    @State private var didStart = false
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var offering: Offering?
    @State private var purchasingPackageId: String?

    private var titleText: String { offeringId == "video" ? "Video Packs" : "Pro" }
    private var headerText: String { offeringId == "video" ? "Buy Video Credits" : "Upgrade to Pro" }

    var body: some View {
        NavigationView {
            VStack(spacing: 14) {

                if isLoading {
                    ProgressView("Loading…").padding(.top, 18)
                }

                if let t = errorText, !t.isEmpty {
                    Text(t)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.red)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 14)
                }

                if let offering {
                    ScrollView {
                        VStack(spacing: 10) {
                            Text(headerText)
                                .font(.system(size: 18, weight: .bold))
                                .padding(.top, 10)

                            ForEach(Array(offering.availablePackages.enumerated()), id: \.offset) { _, pkg in
                                Button { buy(pkg) } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(pkg.storeProduct.localizedTitle)
                                                .font(.system(size: 15, weight: .semibold))
                                            Text(pkg.storeProduct.localizedDescription)
                                                .font(.system(size: 12))
                                                .foregroundColor(.secondary)
                                                .lineLimit(2)
                                        }
                                        Spacer()
                                        Text(pkg.storeProduct.rcLocalizedPriceString)
                                            .font(.system(size: 14, weight: .bold))
                                    }
                                    .padding(12)
                                    .background(Color.black.opacity(0.06))
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .disabled(purchasingPackageId != nil)
                                .opacity(purchasingPackageId == nil ? 1.0 : 0.7)
                            }

                            if offeringId != "video" {
                                Button("Restore Purchases") { restoreAndIngest() }
                                    .font(.system(size: 14, weight: .semibold))
                                    .padding(.top, 10)
                            }

                            Text("Note: Sandbox will NOT charge real money.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .padding(.top, 4)
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 18)
                    }
                } else if !isLoading {
                    Text("No offering found.\nCheck RevenueCat Offering mapping.")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 20)
                }

                Spacer(minLength: 0)
            }
            .navigationTitle(titleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        SolaraPaywallCenter.shared.showPaywall = false
                        SolaraPaywallCenter.shared.onPaywallDismissed()
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            if didStart { return }
            didStart = true
            bootstrapAndLoad()
        }
    }

    private func bootstrapAndLoad() {
        isLoading = true
        errorText = nil
        offering = nil

        if let e = RC.configureIfNeeded() {
            isLoading = false
            errorText = e
            return
        }

        Task { @MainActor in
            await RC.ensureUserIdAligned()
            loadOffering()
        }
    }

    private func loadOffering() {
        Purchases.shared.getOfferings { offerings, error in
            DispatchQueue.main.async {
                self.isLoading = false

                if let error {
                    self.errorText = error.localizedDescription
                    return
                }

                if let id = self.offeringId, let o = offerings?.all[id] {
                    self.offering = o
                    return
                }

                if self.offeringId == nil, let cur = offerings?.current {
                    self.offering = cur
                    return
                }

                self.errorText = "Offering not found: \(self.offeringId ?? "current")"
            }
        }
    }

    private func buy(_ pkg: Package) {
        errorText = nil
        purchasingPackageId = pkg.identifier
        isLoading = true

        Purchases.shared.purchase(package: pkg) { transaction, customerInfo, error, userCancelled in
            DispatchQueue.main.async {
                self.isLoading = false
                self.purchasingPackageId = nil

                if userCancelled { return }

                if let error {
                    if isAlreadyOwnedError(error) {
                        self.restoreAndIngest()
                        return
                    }
                    self.errorText = error.localizedDescription
                    return
                }

                Task { @MainActor in
                    do {
                        let productId = transaction?.productIdentifier ?? pkg.storeProduct.productIdentifier
                        let txId = transaction?.transactionIdentifier ?? "rc:\(UUID().uuidString)"

                        let expiresMs: Int64? = {
                            guard self.offeringId != "video" else { return nil }
                            guard let ci = customerInfo else { return nil }
                            return RC.bestActiveEntitlement(ci: ci)?.expiresMs
                        }()

                        try await SolaraBillingStore.shared.ingestPurchase(productId: productId, txId: txId, expiresMs: expiresMs)
                        await SolaraBillingStore.shared.refreshMe()

                        SolaraPaywallCenter.shared.onIngestSucceededAndDismiss()
                        dismiss()
                    } catch {
                        self.errorText = "Server ingest failed: \((error as NSError).localizedDescription)"
                    }
                }
            }
        }
    }

    private func restoreAndIngest() {
        errorText = nil
        isLoading = true

        Purchases.shared.restorePurchases { customerInfo, error in
            DispatchQueue.main.async {
                self.isLoading = false
                if let error {
                    self.errorText = error.localizedDescription
                    return
                }

                Task { @MainActor in
                    do {
                        guard let ci = customerInfo else {
                            SolaraPaywallCenter.shared.showPaywall = false
                            SolaraPaywallCenter.shared.onPaywallDismissed()
                            dismiss()
                            return
                        }

                        guard let (productId, expiresMs) = RC.bestActiveEntitlement(ci: ci) else {
                            SolaraPaywallCenter.shared.showPaywall = false
                            SolaraPaywallCenter.shared.onPaywallDismissed()
                            dismiss()
                            return
                        }

                        let stableTx = "restore:\(ci.originalAppUserId):\(productId)"
                        try await SolaraBillingStore.shared.ingestPurchase(productId: productId, txId: stableTx, expiresMs: expiresMs)
                        await SolaraBillingStore.shared.refreshMe()

                        SolaraPaywallCenter.shared.onIngestSucceededAndDismiss()
                        dismiss()
                    } catch {
                        self.errorText = "Server ingest failed: \((error as NSError).localizedDescription)"
                    }
                }
            }
        }
    }

    private func isAlreadyOwnedError(_ error: Error) -> Bool {
        let s = (error as NSError).localizedDescription.lowercased()
        if s.contains("already") && (s.contains("purchased") || s.contains("subscribed") || s.contains("owned")) { return true }
        if s.contains("已") && (s.contains("购买") || s.contains("订阅") || s.contains("拥有")) { return true }
        return false
    }
}

// =====================================================
// MARK: - RevenueCat Async Helpers (fix explicit self)
// =====================================================
private extension Purchases {

    func customerInfoAsync() async throws -> CustomerInfo {
        try await withCheckedThrowingContinuation { cont in
            self.getCustomerInfo { info, error in
                if let error { cont.resume(throwing: error); return }
                if let info { cont.resume(returning: info); return }
                cont.resume(throwing: NSError(domain: "RC", code: -1,
                                              userInfo: [NSLocalizedDescriptionKey: "Missing customerInfo"]))
            }
        }
    }

    func syncPurchasesAsync() async throws -> CustomerInfo {
        try await withCheckedThrowingContinuation { cont in
            self.syncPurchases { info, error in
                if let error { cont.resume(throwing: error); return }
                if let info { cont.resume(returning: info); return }

                // ✅ 显式 self
                self.getCustomerInfo { info2, error2 in
                    if let error2 { cont.resume(throwing: error2); return }
                    if let info2 { cont.resume(returning: info2); return }
                    cont.resume(throwing: NSError(domain: "RC", code: -2,
                                                  userInfo: [NSLocalizedDescriptionKey: "syncPurchases returned nil"]))
                }
            }
        }
    }

    func logInAsync(_ appUserID: String) async throws -> CustomerInfo {
        try await withCheckedThrowingContinuation { cont in
            self.logIn(appUserID) { info, _, error in
                if let error { cont.resume(throwing: error); return }
                if let info { cont.resume(returning: info); return }
                cont.resume(throwing: NSError(domain: "RC", code: -3,
                                              userInfo: [NSLocalizedDescriptionKey: "logIn returned nil"]))
            }
        }
    }
}

private extension StoreProduct {
    var rcLocalizedPriceString: String {
        if let formatter = self.priceFormatter {
            let number = NSDecimalNumber(decimal: self.price)
            return formatter.string(from: number) ?? "\(number)"
        }
        return "\(NSDecimalNumber(decimal: self.price))"
    }
}

