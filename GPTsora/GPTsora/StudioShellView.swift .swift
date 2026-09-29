// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-da62b87d504392a3c943b16f314f03344f711a038043c5ffc9e42d599a3944c4"
// Source-SHA256: "3fb506af2e7bc9db7deb10fb78a655be7e30dcbe27ebe21bbec3e2354d54af28"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI

struct StudioShellView: View {

    @Binding var libraryPlayURL: URL?
    let onClose: () -> Void

    private enum Tab: String, CaseIterable {
        case generate = "生成"
        case library  = "作品"
        case remix    = "二次生成"
    }

    @State private var tab: Tab = .generate

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.opacity(0.92).ignoresSafeArea()

                VStack(spacing: 0) {
                    topBar
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 10)

                    Picker("", selection: $tab) {
                        ForEach(Tab.allCases, id: \.self) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)

                    Divider().opacity(0.2)

                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                Haptics.heavy()
                onClose()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))
                    .padding(8)
                    .background(Color.white.opacity(0.10))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            Text("工作台")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white.opacity(0.95))

            Spacer()

            Color.clear.frame(width: 36, height: 36)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .generate:
            // ✅ 你的原“生成大页”不动：仍然用 ContentView
            ContentView(libraryPlayURL: $libraryPlayURL)

        case .library:
            // ✅ 你的作品页（通常是这个签名：VideoLibraryView { url in ... }）
            VideoLibraryView { url in
                libraryPlayURL = url
                tab = .generate
            }

        case .remix:
            // ✅ 二次生成页
            RemixComposerView()
        }
    }
}

