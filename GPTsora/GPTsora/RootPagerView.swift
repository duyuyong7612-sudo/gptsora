// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-e17aa6ae8552fc71bbb05d51bb7ecc3ee120954cf68d48c05851f9c5a7d21e68"
// Source-SHA256: "e18806986b753cc0b483d9680d6c486c9a6ab6e089098e1b7413ab589b3a7451"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI

/// 0 = 欢迎页 (WelcomePage)
/// 1 = 产品介绍页 (AboutSoraView)
/// 2 = 示例专页 (DemoSamplePage)
/// 3 = 主功能页（ContentView）
/// 4 = 视频保存页 (VideoLibraryView)
struct RootPagerView: View {

    // ✅ 新增：从外部指定打开时的起始页（默认 0 不破坏旧行为）
    @State private var currentPage: Int
    @State private var libraryPlayURL: URL? = nil

    private let demoTag = 2

    // ✅ 新增 init：用 startIndex 初始化 TabView 的 selection
    init(startIndex: Int = 0) {
        let clamped = max(0, min(4, startIndex)) // 防越界
        _currentPage = State(initialValue: clamped)
    }

    var body: some View {
        TabView(selection: $currentPage) {

            WelcomePage(currentPage: $currentPage)
                .tag(0)

            AboutSoraView()
                .tag(1)

            // ✅ 对齐：DemoSamplePage 只收 1 个参数
            DemoSamplePage(currentPage: $currentPage)
                .tag(demoTag)

            ContentView(libraryPlayURL: $libraryPlayURL)
                .tag(3)

            VideoLibraryView(onPlay: { url in
                libraryPlayURL = url
                currentPage = 3
            })
            .tag(4)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))

        // ✅ 大厂级关键：离开 Demo 页就立刻停，防止后台播放导致卡顿/串音
        .onChange(of: currentPage) { newPage in
            if newPage != demoTag {
                DemoFeedPlaybackManager.shared.stopAll()
            }
        }
    }
}

