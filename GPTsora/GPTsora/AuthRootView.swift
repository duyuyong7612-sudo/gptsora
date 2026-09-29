// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-f73d864a2c2a2a015a7fca4315bd4ae495a462c70f0c064da748a2f225ed64e2"
// Source-SHA256: "715a478de1d0f600bd81db61561efc50938c354aacd931ca6606237152f1b6f2"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI
import UIKit
import AuthenticationServices

/// Auth / Paywall entry (Commercial-grade, Unlocked)
/// ✅ Apple sign-in（后端 /auth/apple 返回 access_token）
/// ✅ StoreKit2: single weekly Pro subscription + restore
/// ✅ V1 单套餐：ChatAGI Pro，$4.99/week，Product ID: solara_pro_weekly_799
/// ✅ 解禁：不做门禁拦截，右上角 X 永远可关闭
struct AuthRootView: View {

    @EnvironmentObject var authManager: AuthManager
    @Environment(\.dismiss) private var dismiss

    // shared
    @ObservedObject private var iap = IAPManager.shared

    @State private var isBusy = false
    @State private var banner: Banner?
    @AppStorage("chatagi.paywall_reason") private var paywallReasonRaw: String = "generic"

    // ✅ 防止 onAppear 重复触发（商用品质必须）
    @State private var didAppear = false

    // ✅ Banner auto clear：可取消，避免 asyncAfter 堆积
    @State private var bannerTask: Task<Void, Never>?

    // ✅ dismiss 延迟任务：可取消（避免重复 dismiss 抖动）
    @State private var dismissTask: Task<Void, Never>?

    private var isLoggedIn: Bool { authManager.isAuthenticated }
    private var isPro: Bool { authManager.hasActiveSubscription || iap.hasActiveSubscription }

    private var isWorking: Bool { isBusy || iap.isPurchasing || iap.isLoadingProducts }
    private var actionsDisabled: Bool { isBusy || iap.isPurchasing }

    // ✅ 上架第一阶段先隐藏 video packs，只打通 Pro 订阅闭环。
    private var showVideoPacks: Bool { false }

    var body: some View {
        ZStack {
            background

            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    topBar
                    header

                    if let banner {
                        BannerView(banner: banner)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    // 官方 IAP 流程：不要求先登录，直接展示订阅；Apple 登录只用于跨设备同步。
                    if !isPro {
                        paywallSection
                        optionalSignInSection
                    } else {
                        proSection
                    }

                    footerLinks
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 22)
            }
        }
        .onAppear {
            guard !didAppear else { return }
            didAppear = true

            // 1) identity（不给门禁，只用于归属/校验/发货）
            iap.userIdProvider = { authManager.currentUserId }
            // iap.tokenProvider = { authManager.accessToken } // 若你开放读取 token，可开启

            // 2) start txn listener（必须幂等）
            iap.start()

            // 3) warm load products（避免 “Product not loaded”）
            Task {
                await iap.loadProducts(force: true)
                await iap.refreshEntitlements()
            }

            // 4) 若已是 Pro，轻量自动关闭（不强制）
            if authManager.hasActiveSubscription {
                dismissSoon()
            }
        }
        .onChange(of: authManager.hasActiveSubscription) { v in
            if v { dismissSoon() }
        }
        .onChange(of: iap.hasActiveSubscription) { v in
            if v { dismissSoon() }
        }
        .onChange(of: iap.lastError) { newValue in
            guard let newValue, !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let mapped = mapIAPErrorToBanner(newValue)
            showBanner(mapped.0, mapped.1)
        }
    }
}

// MARK: - UI building blocks

private extension AuthRootView {

    var background: some View {
        LinearGradient(
            colors: [
                Color(red: 0.10, green: 0.18, blue: 0.38),
                Color(red: 0.04, green: 0.09, blue: 0.22)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    var topBar: some View {
        HStack {
            Button {
                heavyTap()
                dismiss() // ✅ 解禁：永远允许关闭
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(10)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Circle())
            }

            Spacer()

            if iap.isLoadingProducts {
                HStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text("Connecting App Store…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.10))
                .clipShape(Capsule())
            }
        }
        .padding(.top, 16)
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isPro ? "You're ChatAGI Pro ✅" : paywallTitle)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.white)

            Text(isPro
                 ? "Your ChatAGI Pro subscription is active on this device."
                 : paywallSubtitle)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.86))
                .lineSpacing(3)

            HStack(spacing: 10) {
                FeatureChip(text: "AI Chat", icon: "message.fill")
                FeatureChip(text: "Memory", icon: "brain.head.profile")
                FeatureChip(text: "Voice/Video", icon: "waveform")
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Sections

private extension AuthRootView {

    var signInSection: some View {
        VStack(spacing: 12) {
            SectionHeader(title: "Get Started")

            AppleContinueButton(isEnabled: !actionsDisabled) { tokenStr in
                Task { await appleLoginFlow(identityToken: tokenStr) }
            } onError: { err in
                Task { @MainActor in
                    if let e = err as? ASAuthorizationError, e.code == .canceled {
                        showBanner(.info, "Sign-in cancelled.")
                    } else {
                        showBanner(.error, "Apple sign-in failed. \(err.localizedDescription)")
                    }
                }
            }
            .frame(height: 50)
            .clipShape(Capsule())
            .disabled(actionsDisabled)

            Button {
                heavyTap()
                Task { await handleRestore() }
            } label: {
                Text("Restore Purchases")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
            }
            .disabled(actionsDisabled)

            HintText("Tip: Use the Apple ID that you used for App Store purchases.")
        }
        .padding(.top, 6)
    }

    var optionalSignInSection: some View {
        VStack(spacing: 10) {
            if !isLoggedIn {
                SectionHeader(title: "Sync Account (Optional)")

                AppleContinueButton(isEnabled: !actionsDisabled) { tokenStr in
                    Task { await appleLoginFlow(identityToken: tokenStr) }
                } onError: { err in
                    Task { @MainActor in
                        if let e = err as? ASAuthorizationError, e.code == .canceled {
                            showBanner(.info, "Sign-in cancelled.")
                        } else {
                            showBanner(.error, "Apple sign-in failed. \(err.localizedDescription)")
                        }
                    }
                }
                .frame(height: 48)
                .clipShape(Capsule())
                .disabled(actionsDisabled)

                HintText("Optional: sign in to sync purchases across devices. You can subscribe without signing in.")
            }
        }
        .padding(.top, 2)
    }

    var paywallSection: some View {
        VStack(spacing: 14) {

            // ===== Pro section =====
            VStack(spacing: 12) {
                SectionHeader(title: "ChatAGI Pro")

                PlanCard(
                    badge: "Only Plan",
                    badgeIcon: "sparkles",
                    title: "ChatAGI Pro",
                    subtitle: "$4.99/week • Voice, video, memory, web search",
                    price: priceText(IAPManager.PID.proWeekly, placeholder: "$4.99"),
                    note: "Weekly auto-renewable. Cancel anytime in App Store settings."
                )

                PrimaryCTA(
                    title: iap.isLoadingProducts ? "Loading…" : "Continue with Pro",
                    subtitle: "$4.99/week",
                    isLoading: isWorking
                ) {
                    heavyTap()
                    Task { await buy(productId: IAPManager.PID.proWeekly, afterSuccessDismissIfPro: true) }
                }
                .disabled(actionsDisabled || iap.isLoadingProducts)
            }

            if showVideoPacks {
            // ===== Credits section =====
                VStack(spacing: 12) {
                SectionHeader(title: "Video Credits")

                PlanCard(
                    badge: "One-time",
                    badgeIcon: "ticket.fill",
                    title: "Video Pack (5)",
                    subtitle: "Add 5 video credits",
                    price: priceText(IAPManager.PID.video5, placeholder: "--"),
                    note: "Non-refundable once consumed."
                )

                SecondaryCTA(title: iap.isLoadingProducts ? "Loading…" : "Buy 5 credits", isLoading: isWorking) {
                    heavyTap()
                    Task { await buy(productId: IAPManager.PID.video5, afterSuccessDismissIfPro: false) }
                }
                .disabled(actionsDisabled || iap.isLoadingProducts)

                PlanCard(
                    badge: "One-time",
                    badgeIcon: "ticket.fill",
                    title: "Video Pack (10)",
                    subtitle: "Add 10 video credits",
                    price: priceText(IAPManager.PID.video10, placeholder: "--"),
                    note: "Non-refundable once consumed."
                )

                SecondaryCTA(title: iap.isLoadingProducts ? "Loading…" : "Buy 10 credits", isLoading: isWorking) {
                    heavyTap()
                    Task { await buy(productId: IAPManager.PID.video10, afterSuccessDismissIfPro: false) }
                }
                .disabled(actionsDisabled || iap.isLoadingProducts)
            }

            }

            // ===== Restore + Manage =====
            VStack(spacing: 10) {
                Button {
                    heavyTap()
                    Task { await handleRestore() }
                } label: {
                    Text("Restore Purchases")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.92))
                }
                .disabled(actionsDisabled)

                HStack(spacing: 14) {
                    Link("Manage Subscription", destination: kManageSubsURL)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))

                    Link("App Store Account", destination: kAccountURL)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                }
                .padding(.top, 2)
            }
            .padding(.top, 4)
        }
        .padding(.top, 6)
    }

    var proSection: some View {
        VStack(spacing: 14) {
            SectionHeader(title: "ChatAGI Pro Active ✅")

            HintText(showVideoPacks
                     ? "You already have ChatAGI Pro. Extra video credits are hidden in V1."
                     : "You already have ChatAGI Pro active on this device.")

            if showVideoPacks {

                PlanCard(
                badge: "One-time",
                badgeIcon: "ticket.fill",
                title: "Video Pack (5)",
                subtitle: "Add 5 video credits",
                price: priceText(IAPManager.PID.video5, placeholder: "--"),
                note: "Non-refundable once consumed."
            )

            SecondaryCTA(title: iap.isLoadingProducts ? "Loading…" : "Buy 5 credits", isLoading: isWorking) {
                heavyTap()
                Task { await buy(productId: IAPManager.PID.video5, afterSuccessDismissIfPro: false) }
            }
            .disabled(actionsDisabled || iap.isLoadingProducts)

            PlanCard(
                badge: "One-time",
                badgeIcon: "ticket.fill",
                title: "Video Pack (10)",
                subtitle: "Add 10 video credits",
                price: priceText(IAPManager.PID.video10, placeholder: "--"),
                note: "Non-refundable once consumed."
            )

            SecondaryCTA(title: iap.isLoadingProducts ? "Loading…" : "Buy 10 credits", isLoading: isWorking) {
                heavyTap()
                Task { await buy(productId: IAPManager.PID.video10, afterSuccessDismissIfPro: false) }
            }
            .disabled(actionsDisabled || iap.isLoadingProducts)

            }

            PrimaryCTA(title: "Done", subtitle: nil, isLoading: false) {
                heavyTap()
                dismiss()
            }
        }
        .padding(.top, 6)
    }

    var footerLinks: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                Link("Terms", destination: kTermsURL)
                Link("Privacy", destination: kPrivacyURL)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white.opacity(0.85))

            Text("ChatAGI Pro is $4.99/week and auto-renews unless canceled at least 24 hours before the end of the current period. You can manage or cancel in App Store settings.")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.68))
                .multilineTextAlignment(.center)
        }
        .padding(.top, 10)
    }
}

// MARK: - Helpers (logic)

private extension AuthRootView {

    var paywallTitle: String {
        switch paywallReasonRaw {
        case "textLimit":
            return "You've reached 5 free messages"
        case "plusLimit":
            return "You've used 3 free uploads"
        case "voiceLocked":
            return "Voice is a Pro feature"
        default:
            return "Upgrade to ChatAGI Pro"
        }
    }

    var paywallSubtitle: String {
        switch paywallReasonRaw {
        case "textLimit":
            return "Upgrade to ChatAGI Pro for $4.99/week to continue chatting with advanced AI features."
        case "plusLimit":
            return "Upgrade to ChatAGI Pro for image/file understanding, memory, web search, and more."
        case "voiceLocked":
            return "Upgrade to ChatAGI Pro for real-time voice and video conversation with weekly limits."
        default:
            return "Unlock advanced AI chat, image and file understanding, long-term memory, web search, and real-time voice/video conversation."
        }
    }

    func priceText(_ pid: String, placeholder: String) -> String {
        let p = iap.displayPrice(pid)
        return p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? placeholder : p
    }

    func heavyTap() {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }

    /// ✅ Banner：可取消，避免堆积
    @MainActor
    func showBanner(_ kind: Banner.Kind, _ message: String) {
        bannerTask?.cancel()
        bannerTask = nil

        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
            banner = Banner(kind: kind, message: message)
        }

        bannerTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            withAnimation(.easeOut(duration: 0.2)) {
                banner = nil
            }
        }
    }

    /// ✅ IAP 错误映射：取消不红
    func mapIAPErrorToBanner(_ raw: String) -> (Banner.Kind, String) {
        let s = raw.lowercased()

        if s.contains("request canceled") || s.contains("cancelled") || s.contains("canceled") {
            return (.info, "Purchase cancelled.")
        }
        if s.contains("missing auth") || s.contains("sign in first") {
            return (.warn, "Please sign in before purchasing.")
        }
        if s.contains("not allowed") || s.contains("payment not allowed") {
            return (.warn, "In-app purchases are not allowed on this device. Check Screen Time restrictions.")
        }
        if s.contains("network") || s.contains("connect") {
            return (.warn, "Couldn’t connect to the App Store. Please try again.")
        }
        return (.warn, raw)
    }

    func dismissSoon() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000) // 0.05s
            dismiss()
        }
    }

    func appleLoginFlow(identityToken: String) async {
        await MainActor.run {
            isBusy = true
            banner = nil
        }
        defer { Task { @MainActor in isBusy = false } }

        do {
            try await authManager.signInWithApple(identityToken: identityToken)
            await authManager.refreshBillingMe()
            await MainActor.run { showBanner(.success, "Signed in.") }

            // safer: reload products
            await iap.loadProducts(force: true)

            if authManager.hasActiveSubscription {
                await MainActor.run { dismissSoon() }
            }
        } catch {
            await MainActor.run { showBanner(.error, error.localizedDescription) }
        }
    }

    func buy(productId: String, afterSuccessDismissIfPro: Bool) async {
        await MainActor.run {
            isBusy = true
            banner = nil
        }
        defer { Task { @MainActor in isBusy = false } }

        if iap.products[productId] == nil {
            await iap.loadProducts(force: true)
        }

        let ok = await iap.purchase(productId: productId)
        if ok {
            await iap.refreshEntitlements()
            await authManager.refreshBillingMe()
            await MainActor.run { showBanner(.success, "Purchase completed.") }

            if afterSuccessDismissIfPro, authManager.hasActiveSubscription {
                await MainActor.run { dismissSoon() }
            }
        } else {
            if let e = iap.lastError, !e.isEmpty {
                let mapped = mapIAPErrorToBanner(e)
                await MainActor.run { showBanner(mapped.0, mapped.1) }
            }
        }
    }

    func handleRestore() async {
        await MainActor.run {
            isBusy = true
            banner = nil
        }
        defer { Task { @MainActor in isBusy = false } }

        await iap.restore()
        await iap.refreshEntitlements()
        await authManager.refreshBillingMe()

        if let e = iap.lastError, !e.isEmpty {
            let mapped = mapIAPErrorToBanner(e)
            await MainActor.run { showBanner(mapped.0, mapped.1) }
        } else {
            await MainActor.run { showBanner(.success, "Restored.") }
            if authManager.hasActiveSubscription {
                await MainActor.run { dismissSoon() }
            }
        }
    }
}

// MARK: - UI Components

private struct SectionHeader: View {
    let title: String
    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))
            Spacer()
        }
        .padding(.top, 6)
    }
}

private struct FeatureChip: View {
    let text: String
    let icon: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
            Text(text)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundColor(.white.opacity(0.9))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.10))
        .clipShape(Capsule())
    }
}

private struct HintText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(.white.opacity(0.72))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
    }
}

private struct PlanCard: View {
    let badge: String
    let badgeIcon: String
    let title: String
    let subtitle: String
    let price: String
    let note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: badgeIcon)
                        .font(.system(size: 12, weight: .semibold))
                    Text(badge)
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(.white.opacity(0.92))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.12))
                .clipShape(Capsule())

                Spacer()

                Text(price)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
            }

            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)

            Text(subtitle)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(2)

            if let note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.68))
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct PrimaryCTA: View {
    let title: String
    let subtitle: String?
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isLoading { ProgressView().tint(.black) }
                VStack(spacing: 1) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11, weight: .medium))
                            .opacity(0.75)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Color.white)
            .foregroundColor(.black)
            .clipShape(Capsule())
        }
    }
}

private struct SecondaryCTA: View {
    let title: String
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isLoading { ProgressView().tint(.black) }
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Color.white.opacity(0.88))
            .foregroundColor(.black)
            .clipShape(Capsule())
        }
    }
}

private struct Banner: Equatable {
    enum Kind { case info, success, warn, error }
    let kind: Kind
    let message: String
}

private struct BannerView: View {
    let banner: Banner

    private var icon: String {
        switch banner.kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var bgOpacity: Double {
        switch banner.kind {
        case .info: return 0.14
        case .success: return 0.16
        case .warn: return 0.16
        case .error: return 0.18
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))

            Text(banner.message)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.92))
                .lineLimit(3)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(bgOpacity))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - UIKit Sign in with Apple Button (Fix 红：presentationAnchor 兜底)

private struct AppleContinueButton: UIViewRepresentable {
    let isEnabled: Bool
    let onToken: (String) -> Void
    let onError: (Error) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onToken: onToken, onError: onError)
    }

    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(type: .continue, style: .white)
        button.addTarget(context.coordinator, action: #selector(Coordinator.tap), for: .touchUpInside)
        return button
    }

    func updateUIView(_ uiView: ASAuthorizationAppleIDButton, context: Context) {
        uiView.isEnabled = isEnabled
        uiView.alpha = isEnabled ? 1.0 : 0.55
    }

    final class Coordinator: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {

        let onToken: (String) -> Void
        let onError: (Error) -> Void

        init(onToken: @escaping (String) -> Void, onError: @escaping (Error) -> Void) {
            self.onToken = onToken
            self.onError = onError
        }

        @objc func tap() {
            let provider = ASAuthorizationAppleIDProvider()
            let request = provider.createRequest()
            request.requestedScopes = [.fullName, .email]

            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }

        func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let windows = scenes.flatMap { $0.windows }
            if let key = windows.first(where: { $0.isKeyWindow }) {
                return key
            }
            // ✅ 兜底：不要用 ASPresentationAnchor()（容易报红）
            return windows.first ?? UIWindow(frame: .zero)
        }

        func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
            guard let cred = authorization.credential as? ASAuthorizationAppleIDCredential else {
                onError(NSError(domain: "AppleSignIn", code: -10, userInfo: [NSLocalizedDescriptionKey: "Apple credential missing"]))
                return
            }
            guard let tokenData = cred.identityToken,
                  let tokenStr = String(data: tokenData, encoding: .utf8),
                  !tokenStr.isEmpty else {
                onError(NSError(domain: "AppleSignIn", code: -11, userInfo: [NSLocalizedDescriptionKey: "Apple identityToken missing"]))
                return
            }
            onToken(tokenStr)
        }

        func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
            onError(error)
        }
    }
}

// MARK: - URLs (replace with your real ones)

private let kTermsURL   = URL(string: "https://your-domain.com/terms")!
private let kPrivacyURL = URL(string: "https://your-domain.com/privacy")!

// Apple pages (safe)
private let kManageSubsURL = URL(string: "https://apps.apple.com/account/subscriptions")!
private let kAccountURL    = URL(string: "https://apps.apple.com/account")!




