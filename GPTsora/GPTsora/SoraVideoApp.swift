
// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-14965565659880908c3bfc77cdbba41cee140f51373c79a5b7024dbc07731653"
// Source-SHA256: "e9db87d80fd7c2ad52718f2ec0b19e5a2a5b78f195ba524d61e209ec97ce4fa4"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI

@main
struct SoraVideoApp: App {

    @StateObject private var authManager = AuthManager()

    init() {
        // 当前先保持你现有本地调试逻辑，后续上架前再一起切正式域名
        AppConfig.API.resetOverride()
        AppConfig.API.forceLocalDebug()
        AppConfig.API.assertLocalOnly()
        AppConfig.API.debugPrint()
    }

    var body: some Scene {
        WindowGroup {
            AppLaunchRootView()
                .environmentObject(authManager)
                .task {
                    AppConfig.API.assertLocalOnly()

                    await authManager.refreshBillingMe()

                    IAPManager.shared.userIdProvider = { authManager.currentUserId }
                    IAPManager.shared.tokenProvider = { authManager.accessToken }
                    IAPManager.shared.start()
                    await IAPManager.shared.loadProducts()
                    await IAPManager.shared.refreshEntitlements()
                }
                .onChange(of: authManager.isProUser) { isPro in
                    if isPro {
                        authManager.showAuthSheet = false
                    }
                }
                .onReceive(IAPManager.shared.$hasActiveSubscription) { isPro in
                    if isPro {
                        authManager.showAuthSheet = false
                    }
                }
                .sheet(isPresented: $authManager.showAuthSheet, onDismiss: {
                    Task { await authManager.refreshBillingMe() }
                }) {
                    AuthRootView()
                        .environmentObject(authManager)
                        .presentationDragIndicator(.visible)
                }
        }
    }
}

private struct AppLaunchRootView: View {
    @AppStorage("chatagi.portal.hasSeen") private var hasSeenPortal = false
    @State private var showMain = false
    @State private var bootElapsedSec: Int = 0
    @State private var bootTimer: Timer? = nil

    var body: some View {
        // ✅ ZStack 兜底层永远在底 —— 任何一种"前台 View 渲染空"的场景
        //    (iOS 升级后 HomeChatView body 失败、网络阻塞、状态异常)用户都不会看到
        //    一整块白屏:BootShell 始终在,6 秒后还会出"强制进入主页 / 回到门户"应急 UI。
        ZStack {
            // ─── 底层:始终可见的启动 / 应急壳层 ───
            BootShell(
                elapsedSec: bootElapsedSec,
                onForceEnterMain: {
                    hasSeenPortal = true
                    withAnimation(.easeInOut(duration: 0.25)) {
                        showMain = true
                    }
                },
                onResetToPortal: {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        hasSeenPortal = false
                        showMain = false
                    }
                }
            )

            // ─── 上层:实际内容(正常时盖住 BootShell)───
            Group {
                if showMain {
                    HomeChatView()
                        .transition(.opacity)
                } else {
                    WelcomePage {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            hasSeenPortal = true
                            showMain = true
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
        .onAppear {
            // 首次启动：直接显示太阳系门户
            // 老用户已看过：也直接进入主页（保持原有体验）
            showMain = hasSeenPortal
            startBootTimer()
        }
        // ✅ 监听"返回太阳系"通知，从主页可随时回退
        .onReceive(NotificationCenter.default.publisher(for: .returnToPortal)) { _ in
            withAnimation(.easeInOut(duration: 0.35)) {
                showMain = false
            }
        }
        .onDisappear { bootTimer?.invalidate() }
    }

    private func startBootTimer() {
        bootTimer?.invalidate()
        bootElapsedSec = 0
        // 每秒 tick,30 秒后停掉避免后台耗电。BootShell 在 6 秒后出应急 UI。
        bootTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            DispatchQueue.main.async {
                bootElapsedSec += 1
                if bootElapsedSec > 30 {
                    bootTimer?.invalidate()
                    bootTimer = nil
                }
            }
        }
    }
}

// MARK: - BootShell
// 永远在 ZStack 底层。正常情况下被 HomeChatView / WelcomePage 完全覆盖,用户看不见。
// 一旦前台 View 渲染失败(iOS 升级后兼容问题 / SwiftUI 异常 / 等),用户至少能看到
// "ChatAGI 正在启动…" + 6 秒后的应急按钮(强制进主页 / 回门户),不再是一片白。
private struct BootShell: View {
    let elapsedSec: Int
    let onForceEnterMain: () -> Void
    let onResetToPortal: () -> Void

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            VStack(spacing: 18) {
                Spacer(minLength: 60)
                Text("ChatAGI")
                    .font(.system(size: 30, weight: .light, design: .serif))
                    .foregroundColor(.black.opacity(0.55))
                ProgressView()
                    .scaleEffect(0.8)
                    .tint(.black.opacity(0.5))
                Text("正在启动…")
                    .font(.system(size: 13))
                    .foregroundColor(.gray)
                Spacer()
                // ─── 6 秒后出应急 UI(只在前台 View 没盖住 BootShell 时才会被看到)───
                if elapsedSec >= 6 {
                    VStack(spacing: 12) {
                        Text("如果长时间停留,请尝试")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                        Button(action: onForceEnterMain) {
                            Text("强制进入主页")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 22)
                                .padding(.vertical, 10)
                                .background(Color.black)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        Button(action: onResetToPortal) {
                            Text("回到太阳系门户")
                                .font(.system(size: 13))
                                .foregroundColor(.black.opacity(0.65))
                        }
                        .buttonStyle(.plain)
                        Text("(若仍白屏:杀掉 App 重开;检查 Wi-Fi 与后端可达)")
                            .font(.system(size: 10))
                            .foregroundColor(.gray.opacity(0.6))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 44)
                    .transition(.opacity)
                }
            }
        }
    }
}

// ✅ 全局通知名：任何 View 都可以发起"回到太阳系"
extension Notification.Name {
    static let returnToPortal = Notification.Name("chatagi.returnToPortal")
}


