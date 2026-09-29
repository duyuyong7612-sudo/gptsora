// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-8b130ed17629f9e30e484efdfc575086056223712401dd714d74ac2eddb724aa"
// Source-SHA256: "19e070e76bd19090c264bd6f77893f1c704a30b32d0856ff270c096ca771d509"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI

struct ProGateSheet: View {
    @EnvironmentObject var ent: EntitlementsStore

    let feature: LockedFeature
    let onSignInApple: () -> Void
    let onSignInGoogle: () -> Void
    let onSubscribe: () -> Void
    let onRestore: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(colors: [.blue.opacity(0.8), .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                HStack {
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .foregroundColor(.white.opacity(0.9))
                            .padding(10)
                            .background(.white.opacity(0.15))
                            .clipShape(Circle())
                    }
                }

                Text(ent.isLoggedIn ? "Upgrade to Solara Pro" : "Sign in to unlock")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.white)

                Text("Watching demos is free. Video generation, real-time voice, saving and sharing are locked until you sign in. Pro unlocks full access.")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)

                if ent.isLoggedIn {
                    // ✅ 已登录：显示 Pro 订阅
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Solara Pro")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                        Text("Unlimited generations • HD export • Priority queue")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.85))
                        Text("$6.99 / month")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                    Button(action: onSubscribe) {
                        Text("Continue • Subscribe to Pro")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .foregroundColor(.black)
                            .background(.white.opacity(0.95))
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }

                    Button(action: onRestore) {
                        Text("Restore Purchases")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white.opacity(0.9))
                    }
                    .padding(.top, 4)

                } else {
                    // ✅ 未登录：显示登录解封
                    Button(action: onSignInApple) {
                        Text("Continue with Apple")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .foregroundColor(.black)
                            .background(.white.opacity(0.95))
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }

                    Button(action: onSignInGoogle) {
                        Text("Continue with Google")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .foregroundColor(.white)
                            .background(.white.opacity(0.18))
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }

                Spacer(minLength: 10)

                Text("By continuing, you agree to our Terms of Service and Privacy Policy.")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.75))
                    .padding(.bottom, 12)
            }
            .padding(18)
        }
    }

    @Environment(\.dismiss) private var dismiss
}
