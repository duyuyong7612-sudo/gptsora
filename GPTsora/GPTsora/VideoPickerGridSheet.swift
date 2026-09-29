// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-32d8e67bcf087142c87e8c1c8dacbcda5d35d6adb15eb2d86c8aaaaa2bc0537c"
// Source-SHA256: "39bab1bdc9ec743474911ba053f43cedb2315b1e6bf1e0b6ef8645436499c0ce"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI

struct VideoPickerGridSheet: View {

    // 你后续替换成“从 MyCreations 数据源读列表”
    @State private var items: [RemixBaseVideo] = []

    let onPick: (RemixBaseVideo) -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Text("选择基视频")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)

                    Spacer()

                    Button("关闭") { onClose() }
                        .foregroundColor(.white.opacity(0.85))
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

                ScrollView {
                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10),
                    ], spacing: 10) {
                        ForEach(items) { v in
                            VideoTile(v: v)
                                .onTapGesture {
                                    guard v.canRemix else {
                                        // ✅ 缺 BaseID：拦截（这里你可以换成你项目 Toast）
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        return
                                    }
                                    onPick(v)
                                }
                                .overlay(alignment: .topLeading) {
                                    if v.canRemix {
                                        Text("Remix")
                                            .font(.system(size: 11, weight: .semibold))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 5)
                                            .background(Color.white.opacity(0.14))
                                            .foregroundColor(.white)
                                            .clipShape(Capsule())
                                            .padding(8)
                                    }
                                }
                                .overlay(alignment: .bottomLeading) {
                                    Text(v.title)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                        .padding(8)
                                }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
        }
        .onAppear {
            // TODO: 替换为你真实数据源（MyCreationsStore / VideoLibraryStore）
            // items = store.videos.map { ... }
        }
    }
}

private struct VideoTile: View {
    let v: RemixBaseVideo
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.08))
            if let url = v.thumbURL {
                AsyncImage(url: url) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.06)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                Color.white.opacity(0.06).clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
        .frame(height: 150)
        .opacity(v.canRemix ? 1.0 : 0.55) // 缺ID略灰
    }
}

