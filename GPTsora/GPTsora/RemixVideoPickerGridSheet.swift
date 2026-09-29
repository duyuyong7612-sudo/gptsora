// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-4b13827943f00211a356c7b076c6372383a388d080bf47320bf2bb23c8bf3733"
// Source-SHA256: "79180523d2844218f5d41d51928218e18d7cfa6edf21ff662027def0283b921c"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI
import AVFoundation
import UIKit

struct RemixVideoPickerGridSheet: View {

    @ObservedObject private var store = VideoLibraryStore.shared

    let onPick: (RemixBaseVideo) -> Void
    let onClose: () -> Void

    @State private var toast: String?
    @State private var showToast: Bool = false
    @State private var toastTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {

                HStack {
                    Text("选择基视频")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)

                    Spacer()

                    Button("关闭") {
                        remixHaptic()
                        onClose()
                    }
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

                        ForEach(store.videos) { v in
                            let fileURL = store.url(for: v)
                            let openaiId = bestEffortExtractOpenAIVideoId(from: v) ?? ""
                            let canRemix = openaiId.hasPrefix("video_") && openaiId.count > 12

                            ZStack {
                                RemixVideoThumbView(fileURL: fileURL)
                                    .scaledToFill()
                                    .frame(height: 150)
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 16))

                                RoundedRectangle(cornerRadius: 16)
                                    .fill(Color.white.opacity(canRemix ? 0.00 : 0.12))

                                VStack {
                                    HStack {
                                        if canRemix {
                                            Text("Remix")
                                                .font(.system(size: 11, weight: .semibold))
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 5)
                                                .background(Color.white.opacity(0.14))
                                                .foregroundColor(.white)
                                                .clipShape(Capsule())
                                        } else {
                                            Text("No ID")
                                                .font(.system(size: 11, weight: .semibold))
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 5)
                                                .background(Color.white.opacity(0.12))
                                                .foregroundColor(.white.opacity(0.75))
                                                .clipShape(Capsule())
                                        }
                                        Spacer()
                                    }
                                    .padding(8)

                                    Spacer()

                                    HStack {
                                        Text(v.displayTitle)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(.white)
                                            .lineLimit(1)
                                        Spacer()
                                    }
                                    .padding(8)
                                }
                            }
                            .opacity(canRemix ? 1.0 : 0.55)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                remixHaptic()
                                guard canRemix else {
                                    showToastNow("该视频缺少 Base ID，无法二次生成")
                                    return
                                }

                                onPick(
                                    RemixBaseVideo(
                                        id: v.id,
                                        fileURL: fileURL,
                                        prompt: v.prompt,
                                        openaiVideoId: openaiId
                                    )
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }

            if showToast, let t = toast {
                VStack {
                    Text(t)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.14))
                        .clipShape(Capsule())
                        .padding(.top, 12)
                    Spacer()
                }
                .transition(.opacity)
            }
        }
    }

    private func showToastNow(_ text: String) {
        toastTask?.cancel()
        toastTask = nil
        toast = text
        withAnimation(.easeOut(duration: 0.18)) { showToast = true }
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if Task.isCancelled { return }
            withAnimation(.easeOut(duration: 0.18)) { showToast = false }
        }
    }

    // ✅ 复用 ContentView 的 best-effort 提取逻辑（就地一份，避免跨文件依赖）
    private func bestEffortExtractOpenAIVideoId(from obj: Any) -> String? {
        let candidates = [
            "openaiVideoId", "openAIVideoId", "videoId", "remoteVideoId", "resultVideoId",
            "openai_id", "openaiId", "remoteId", "originVideoId", "sourceVideoId",
            "video_id", "id"
        ]

        let m = Mirror(reflecting: obj)
        for c in candidates {
            if let v = mirrorFindString(m, key: c), isLikelyVideoId(v) { return v }
        }

        for child in m.children {
            let mm = Mirror(reflecting: child.value)
            for c in candidates {
                if let v = mirrorFindString(mm, key: c), isLikelyVideoId(v) { return v }
            }
        }
        return nil
    }

    private func mirrorFindString(_ mirror: Mirror, key: String) -> String? {
        for child in mirror.children {
            guard let label = child.label else { continue }
            if label == key {
                if let s = child.value as? String { return s }
                if let s = child.value as? String? { return s }
            }
        }
        return nil
    }

    private func isLikelyVideoId(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("video_") && t.count > 12
    }
}

// MARK: - Local Haptics (avoid dependency on ContentView's Haptics)
fileprivate func remixHaptic() {
    let gen = UIImpactFeedbackGenerator(style: .heavy)
    gen.prepare()
    gen.impactOccurred()
}

// MARK: - Local thumbnail view + cache (NOT shared)
private struct RemixVideoThumbView: View {
    let fileURL: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable()
            } else {
                Color.white.opacity(0.06)
                    .overlay(
                        Image(systemName: "video.fill")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundColor(.white.opacity(0.65))
                    )
            }
        }
        .task(id: fileURL) {
            if let cached = RemixVideoThumbCache.shared.get(fileURL) {
                image = cached
                return
            }
            image = await RemixVideoThumbCache.shared.make(fileURL)
        }
    }
}

private final class RemixVideoThumbCache {
    static let shared = RemixVideoThumbCache()
    private let cache = NSCache<NSString, UIImage>()

    func get(_ url: URL) -> UIImage? {
        cache.object(forKey: url.path as NSString)
    }

    func make(_ url: URL) async -> UIImage? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let asset = AVAsset(url: url)
                let gen = AVAssetImageGenerator(asset: asset)
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: 640, height: 640)

                do {
                    let cg = try gen.copyCGImage(at: CMTime(seconds: 0, preferredTimescale: 600), actualTime: nil)
                    let ui = UIImage(cgImage: cg)
                    self.cache.setObject(ui, forKey: url.path as NSString)
                    cont.resume(returning: ui)
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
    }
}

