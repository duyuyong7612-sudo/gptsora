//
//  VideoLibraryView.swift
//  SoraApp
//
//  旗舰商用级：抖音式竖滑连播（上划下一个、秒播、不卡）
//  ✅ 修复：AudioSession -50（playback 不使用 defaultToSpeaker）
//  ✅ 修复：保存到相册闪退（tmp 文件先复制到 Documents/exports 再保存）
//  ✅ 修复：无法播放（播放入口统一走稳定 URL + 文件存在校验）
//
//  ✅ Upgrade: Library Remix (Front-end)
//  - 顶部右侧提示：二次生成 · 点击视频
//  - 点击视频：直接进入 Remix（新页 RemixComposerView）
//  - 播放入口：... 菜单里的「播放」
//  - 每次 Remix 必带 openaiVideoId（baseVideoId）
//  - 新页自动带入：稳定文件URL + baseVideoId（不再出现空BaseID）
//

// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-6a9b29af45b809b2d5bbe615199dd43de6630ee4e5418f397ad9775f5a901715"
// Source-SHA256: "81b6dfe6e705e1914d0f288216e34d4f06d6b6d4ced76a1bfaaabc6792f1eab0"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI
import AVFoundation
import UIKit
import Combine

struct VideoLibraryView: View {

    @ObservedObject private var store = VideoLibraryStore.shared

    /// 外部保留：如果你还想由外层播放，可切换
    let onPlay: (URL) -> Void

    @State private var saveAlertMessage: String?
    @State private var showSaveAlert = false

    @State private var showFeedPlayer = false
    @State private var feedStartIndex: Int = 0

    // ✅ NEW: Remix Composer (new page)
    @State private var showRemixComposer = false
    @State private var remixInitialBase: RemixBaseVideo? = nil   // ✅ 带入新页：fileURL + openaiVideoId

    private let columns: [GridItem] = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    /// 默认启用抖音式连播
    private let kUseInternalFeedPlayer = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {

                // 顶部标题栏
                HStack(spacing: 8) {
                    Image(systemName: "sparkles.tv.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white)

                    Text("My Creations")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white)

                    Spacer()

                    // ✅ 右上角提示（九宫格上方）
                    HStack(spacing: 6) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.9))
                        Text("二次生成 · 点击视频")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.92))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.10))
                    .clipShape(Capsule())
                }
                .padding(.top, 12)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                Divider().background(Color.white.opacity(0.15))

                if store.videos.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "film")
                            .font(.system(size: 40))
                            .foregroundColor(.white.opacity(0.7))
                        Text("还没有生成过视频")
                            .foregroundColor(.white)
                        Text("生成完成的视频会自动出现在这里")
                            .foregroundColor(.white.opacity(0.7))
                            .font(.system(size: 14))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(store.videos) { video in
                                VideoGridCell(
                                    video: video,
                                    url: store.url(for: video),
                                    onTap: { play(video) },              // ✅ 播放改到菜单里走
                                    onDelete: { delete(video) },
                                    onDownload: { download(video) },
                                    onRemix: { openRemix(for: video) }   // ✅ 点击格子进入 Remix 新页
                                )
                            }
                        }
                        .padding(2)
                    }
                }
            }
        }
        .alert("提示", isPresented: $showSaveAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text(saveAlertMessage ?? "")
        }
        .fullScreenCover(isPresented: $showFeedPlayer) {
            VideoFeedFullScreenPlayer(
                store: store,
                startIndex: feedStartIndex,
                isPresented: $showFeedPlayer
            )
        }

        // ✅ NEW: Remix 新页（半屏/可上拉）
        .sheet(isPresented: $showRemixComposer, onDismiss: {
            remixInitialBase = nil
        }) {
            if let base = remixInitialBase {
                if #available(iOS 16.0, *) {
                    RemixComposerView(initialBase: base)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                        .presentationCornerRadius(22)
                } else {
                    RemixComposerView(initialBase: base)
                }
            } else {
                Color.black.ignoresSafeArea()
            }
        }
    }

    // MARK: - Actions

    private func play(_ video: SavedVideo) {
        LibHaptics.medium() // ✅ 播放也有确感

        guard let idx = store.videos.firstIndex(of: video) else { return }

        let rawURL = store.url(for: video)
        guard FileManager.default.fileExists(atPath: rawURL.path) else {
            saveAlertMessage = "视频文件已不存在，请删除后重新生成。"
            showSaveAlert = true
            return
        }

        // ✅ 播放也走稳定文件（避免 tmp 被清理/被覆盖）
        let url = ensureStableLocalVideo(url: rawURL) ?? rawURL

        if kUseInternalFeedPlayer {
            feedStartIndex = idx
            showFeedPlayer = true
        } else {
            onPlay(url)
        }
    }

    private func delete(_ video: SavedVideo) {
        store.delete(video)
    }

    private func download(_ video: SavedVideo) {
        saveVideoToAlbum(url: store.url(for: video))
    }

    // ✅ 统一入口：打开 Remix 新页（必须拿到 openaiVideoId）
    private func openRemix(for video: SavedVideo) {
        LibHaptics.medium()

        let oid = (video.openaiVideoId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // ✅ 允许无 OpenAI video_id：走 video-to-video 的二次生成（不再拦截）

        let rawURL = store.url(for: video)
        guard FileManager.default.fileExists(atPath: rawURL.path) else {
            saveAlertMessage = "视频文件已不存在，请删除后重新生成。"
            showSaveAlert = true
            return
        }

        // ✅ 新页预览/后续操作也用稳定URL
        let stableURL = ensureStableLocalVideo(url: rawURL) ?? rawURL

        // ✅ 直接把“视频 + baseVideoId”带入新页预览框
        remixInitialBase = RemixBaseVideo(
            id: video.id,
            fileURL: stableURL,
            prompt: video.prompt,
            openaiVideoId: oid
        )

        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            showRemixComposer = true
        }
    }

    private func saveVideoToAlbum(url rawURL: URL) {
        guard FileManager.default.fileExists(atPath: rawURL.path) else {
            saveAlertMessage = "视频文件已不存在。"
            showSaveAlert = true
            return
        }

        // ✅ 保存前先复制成稳定文件（修复闪退）
        let url = ensureStableLocalVideo(url: rawURL) ?? rawURL

        PhotoSaveService.shared.saveVideoToAlbum(fileURL: url) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.saveAlertMessage = "已保存到相册。"
                case .failure:
                    self.saveAlertMessage = "保存到相册失败，请在「设置 - 隐私 - 照片」里允许本 App 访问相册。"
                }
                self.showSaveAlert = true
            }
        }
    }

    /// ✅ 把 tmp 文件复制到 Documents/exports，避免保存/分享/播放时文件消失或占用导致不稳定
    private func ensureStableLocalVideo(url: URL) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }

        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first
        if let docs, url.path.hasPrefix(docs.path) {
            return url
        }

        do {
            let exportsDir = (docs ?? fm.temporaryDirectory).appendingPathComponent("exports", isDirectory: true)
            if !fm.fileExists(atPath: exportsDir.path) {
                try fm.createDirectory(at: exportsDir, withIntermediateDirectories: true)
            }
            let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
            let dest = exportsDir.appendingPathComponent("export_\(UUID().uuidString).\(ext)")
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: url, to: dest)
            return dest
        } catch {
            print("ensureStableLocalVideo copy failed:", error)
            return nil
        }
    }
}

// MARK: - Grid cell

private struct VideoGridCell: View {

    let video: SavedVideo
    let url: URL
    let onTap: () -> Void          // ✅ 现在用于“播放”（放到菜单里）
    let onDelete: () -> Void
    let onDownload: () -> Void
    let onRemix: () -> Void        // ✅ 点击格子进入 Remix

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {

                // ✅ 主区域：点击进入 Remix（上浮 + 确感）
                Button {
                    onRemix()
                } label: {
                    // Thumbnail + title
                    ZStack(alignment: .bottomLeading) {
                        VideoThumbnailView(url: url)
                            .frame(width: geo.size.width, height: geo.size.width)
                            .clipped()

                        LinearGradient(
                            colors: [Color.black.opacity(0.6), .clear],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                        .frame(height: geo.size.width * 0.35)
                        .frame(maxHeight: .infinity, alignment: .bottom)

                        HStack(spacing: 6) {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 11, weight: .bold))
                            Text(video.displayTitle)
                                .font(.system(size: 11))
                                .lineLimit(1)
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.bottom, 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(VideoLiftPressStyle())
                .accessibilityLabel("二次生成：\(video.displayTitle)")

                // ✅ 右上角 ... 菜单（提供 播放 / Remix / 保存 / 删除）
                Menu {
                    Button {
                        onTap()
                    } label: {
                        Label("播放", systemImage: "play.fill")
                    }

                    Button {
                        onRemix()
                    } label: {
                        Label("二次生成（Remix）", systemImage: "wand.and.stars")
                    }

                    Button {
                        onDownload()
                    } label: {
                        Label("保存到相册", systemImage: "square.and.arrow.down")
                    }

                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white.opacity(0.9))
                        .frame(width: 28, height: 28)
                        .background(Color.black.opacity(0.35))
                        .clipShape(Circle())
                        .padding(6)
                }
                .buttonStyle(.plain)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// ✅ 视频模块“上浮”的按压样式：像前版一样按下抬起（不影响 Scroll）
private struct VideoLiftPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 1.04 : 1.0)
            .offset(y: configuration.isPressed ? -8 : 0)
            .shadow(
                color: Color.black.opacity(configuration.isPressed ? 0.40 : 0.18),
                radius: configuration.isPressed ? 18 : 10,
                x: 0,
                y: configuration.isPressed ? 14 : 8
            )
            .animation(.spring(response: 0.20, dampingFraction: 0.78), value: configuration.isPressed)
    }
}

// MARK: - Thumbnail (cache + limit concurrent)

private struct VideoThumbnailView: View {

    let url: URL
    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var token = UUID()

    var body: some View {
        ZStack {
            if let img = image {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                LinearGradient(
                    colors: [
                        Color(red: 0.05, green: 0.10, blue: 0.24),
                        Color(red: 0.10, green: 0.25, blue: 0.55)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "video.fill")
                    .foregroundColor(.white.opacity(0.7))
                    .font(.system(size: 22))
            }
        }
        .onAppear { generateThumbnailIfNeeded() }
    }

    private func generateThumbnailIfNeeded() {
        guard image == nil, !isLoading else { return }
        isLoading = true

        let currentToken = UUID()
        token = currentToken

        ThumbnailCache.shared.thumbnail(for: url) { img in
            guard self.token == currentToken else { return }
            self.image = img
            self.isLoading = false
        }
    }
}

private final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSURL, UIImage>()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.soraapp.thumbnail.gen"
        q.qualityOfService = .userInitiated
        q.maxConcurrentOperationCount = 2
        return q
    }()

    private init() { cache.countLimit = 260 }

    func thumbnail(for url: URL, completion: @escaping (UIImage?) -> Void) {
        let key = url as NSURL
        if let img = cache.object(forKey: key) {
            DispatchQueue.main.async { completion(img) }
            return
        }

        queue.addOperation { [weak self] in
            guard let self else { return }

            let asset = AVAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 720, height: 720)
            gen.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter  = CMTime(seconds: 0.25, preferredTimescale: 600)

            let t = CMTime(seconds: 0.5, preferredTimescale: 600)
            var img: UIImage?
            if let cg = try? gen.copyCGImage(at: t, actualTime: nil) {
                img = UIImage(cgImage: cg)
            }

            if let img { self.cache.setObject(img, forKey: key) }

            DispatchQueue.main.async { completion(img) }
        }
    }
}

// ======================================================================
// MARK: - Fullscreen TikTok-style feed（保持你原样不动）
// ======================================================================

private struct VideoFeedFullScreenPlayer: View {

    @ObservedObject var store: VideoLibraryStore
    let startIndex: Int
    @Binding var isPresented: Bool

    @State private var index: Int
    @StateObject private var playback = FeedPlaybackManager()

    @State private var toastText: String?
    @State private var showToast = false

    @State private var showDeleteConfirm = false

    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []

    init(store: VideoLibraryStore, startIndex: Int, isPresented: Binding<Bool>) {
        self.store = store
        self.startIndex = startIndex
        self._isPresented = isPresented
        self._index = State(initialValue: startIndex)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if store.videos.isEmpty {
                Color.black.onAppear { isPresented = false }
            } else {
                VerticalVideoPager(
                    videos: store.videos,
                    index: $index,
                    urlFor: { store.url(for: $0) },
                    playback: playback
                ) { newIndex in
                    index = newIndex
                    playback.activate(videos: store.videos, index: newIndex, urlFor: { store.url(for: $0) })
                }
                .ignoresSafeArea()

                overlayUI
            }

            if showToast, let t = toastText {
                LibToastHUD(text: t)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .zIndex(10)
            }
        }
        .statusBarHidden(true)
        .onAppear {
            LibVideoAudioSession.activatePlayback()

            let clamped = min(max(0, index), max(0, store.videos.count - 1))
            index = clamped
            playback.activate(videos: store.videos, index: clamped, urlFor: { store.url(for: $0) })
        }
        .onChange(of: store.videos) { newList in
            if newList.isEmpty { isPresented = false; return }
            if index >= newList.count { index = newList.count - 1 }
            playback.activate(videos: newList, index: index, urlFor: { store.url(for: $0) })
        }
        .onDisappear { playback.stopAll() }
        .confirmationDialog("删除该视频？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) { deleteCurrent() }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showShareSheet) {
            LibShareSheet(items: shareItems)
                .ignoresSafeArea()
        }
    }

    private var overlayUI: some View {
        let current = store.videos[safe: index]
        let currentURL = current.map { store.url(for: $0) }

        return VStack {
            HStack {
                Button {
                    LibHaptics.heavy()
                    isPresented = false
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(10)
                        .background(Color.black.opacity(0.35))
                        .clipShape(Circle())
                }

                Spacer()

                Text("\(index + 1)/\(store.videos.count)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.35))
                    .clipShape(Capsule())
            }
            .padding(.top, 12)
            .padding(.horizontal, 14)

            Spacer()

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(current?.displayTitle ?? "未命名视频")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(2)

                    if let v = current {
                        Text(v.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.75))
                    }
                }

                Spacer()

                VStack(spacing: 16) {
                    actionButton(systemName: "square.and.arrow.down") {
                        guard let url = currentURL else { return }
                        LibHaptics.heavy()
                        PhotoSaveService.shared.saveVideoToAlbum(fileURL: url) { result in
                            DispatchQueue.main.async {
                                switch result {
                                case .success: toast("已保存到相册")
                                case .failure: toast("保存失败：请允许相册权限")
                                }
                            }
                        }
                    }

                    actionButton(systemName: "square.and.arrow.up") {
                        guard let url = currentURL else { return }
                        LibHaptics.heavy()
                        shareItems = [url]
                        showShareSheet = true
                    }

                    actionButton(systemName: "trash") {
                        LibHaptics.heavy()
                        showDeleteConfirm = true
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 18)
        }
    }

    private func actionButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(Color.black.opacity(0.35))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func toast(_ text: String) {
        toastText = text
        withAnimation(.easeOut(duration: 0.18)) { showToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeOut(duration: 0.18)) { showToast = false }
        }
    }

    private func deleteCurrent() {
        guard let v = store.videos[safe: index] else { return }
        store.delete(v)
        playback.remove(videoId: v.id)
        toast("已删除")
    }
}

// MARK: - Vertical pager (UIPageViewController)

private struct VerticalVideoPager: UIViewControllerRepresentable {
    var videos: [SavedVideo]
    @Binding var index: Int
    let urlFor: (SavedVideo) -> URL
    let playback: FeedPlaybackManager
    let onIndexChanged: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = UIPageViewController(transitionStyle: .scroll,
                                       navigationOrientation: .vertical,
                                       options: nil)
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        pvc.view.backgroundColor = .black

        for v in pvc.view.subviews {
            if let scroll = v as? UIScrollView {
                scroll.decelerationRate = .fast
                scroll.showsVerticalScrollIndicator = false
                scroll.showsHorizontalScrollIndicator = false
                scroll.contentInsetAdjustmentBehavior = .never
            }
        }

        context.coordinator.update(parent: self)
        context.coordinator.pageVC = pvc

        let safeIndex = min(max(0, index), max(0, videos.count - 1))
        let vc = context.coordinator.makeVC(for: safeIndex)

        pvc.setViewControllers([vc], direction: .forward, animated: false)
        context.coordinator.currentVisibleId = vc.videoId

        DispatchQueue.main.async { self.onIndexChanged(safeIndex) }
        return pvc
    }

    func updateUIViewController(_ uiViewController: UIPageViewController, context: Context) {
        context.coordinator.update(parent: self)
        guard !videos.isEmpty else { return }

        let desiredIndex = min(max(0, index), max(0, videos.count - 1))
        let desiredId = videos[desiredIndex].id

        let visibleId = (uiViewController.viewControllers?.first as? VideoPageHostViewController)?.videoId
        if visibleId != desiredId {
            let vc = context.coordinator.makeVC(for: desiredIndex)
            uiViewController.setViewControllers([vc], direction: .forward, animated: false)
            context.coordinator.currentVisibleId = desiredId
            DispatchQueue.main.async { self.onIndexChanged(desiredIndex) }
        }
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        private(set) var parent: VerticalVideoPager
        weak var pageVC: UIPageViewController?

        var currentVisibleId: UUID?
        private var vcCache: [UUID: VideoPageHostViewController] = [:]

        init(parent: VerticalVideoPager) { self.parent = parent }
        func update(parent: VerticalVideoPager) { self.parent = parent }

        private func index(of videoId: UUID) -> Int? {
            parent.videos.firstIndex(where: { $0.id == videoId })
        }

        func makeVC(for idx: Int) -> VideoPageHostViewController {
            let v = parent.videos[idx]
            let url = parent.urlFor(v)

            if let cached = vcCache[v.id] {
                cached.setPlayer(parent.playback.player(for: v, url: url))
                cached.setPlaceholderURL(url)
                return cached
            }

            let vc = VideoPageHostViewController(videoId: v.id)
            vc.setPlayer(parent.playback.player(for: v, url: url))
            vc.setPlaceholderURL(url)
            vcCache[v.id] = vc
            return vc
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerBefore vc: UIViewController) -> UIViewController? {
            guard let vc = vc as? VideoPageHostViewController,
                  let idx = index(of: vc.videoId) else { return nil }
            let prev = idx - 1
            guard prev >= 0 else { return nil }
            return makeVC(for: prev)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerAfter vc: UIViewController) -> UIViewController? {
            guard let vc = vc as? VideoPageHostViewController,
                  let idx = index(of: vc.videoId) else { return nil }
            let next = idx + 1
            guard next < parent.videos.count else { return nil }
            return makeVC(for: next)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController],
                                transitionCompleted completed: Bool) {
            guard completed,
                  let vc = pageViewController.viewControllers?.first as? VideoPageHostViewController,
                  let idx = index(of: vc.videoId) else { return }

            currentVisibleId = vc.videoId
            parent.onIndexChanged(idx)

            let keepIds: Set<UUID> = {
                var ids: [UUID] = []
                if let cur = parent.videos[safe: idx]?.id { ids.append(cur) }
                if let prev = parent.videos[safe: idx - 1]?.id { ids.append(prev) }
                if let next = parent.videos[safe: idx + 1]?.id { ids.append(next) }
                return Set(ids)
            }()
            vcCache = vcCache.filter { keepIds.contains($0.key) }
        }
    }
}

private final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

private final class VideoPageHostViewController: UIViewController {

    let videoId: UUID

    private let placeholder = UIImageView()
    private let playIcon = UIImageView()

    private var itemStatusObs: NSKeyValueObservation?
    private var timeControlObs: NSKeyValueObservation?

    private var placeholderURL: URL?

    init(videoId: UUID) {
        self.videoId = videoId
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let v = PlayerLayerView()
        v.backgroundColor = .black
        v.playerLayer.videoGravity = .resizeAspectFill
        self.view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        placeholder.contentMode = .scaleAspectFill
        placeholder.clipsToBounds = true
        placeholder.frame = view.bounds
        placeholder.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        placeholder.backgroundColor = .black
        view.addSubview(placeholder)

        playIcon.image = UIImage(systemName: "play.fill")
        playIcon.tintColor = UIColor.white.withAlphaComponent(0.9)
        playIcon.alpha = 0
        playIcon.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(playIcon)
        NSLayoutConstraint.activate([
            playIcon.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            playIcon.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            playIcon.widthAnchor.constraint(equalToConstant: 64),
            playIcon.heightAnchor.constraint(equalToConstant: 64)
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap))
        view.addGestureRecognizer(tap)
    }

    func setPlaceholderURL(_ url: URL) {
        placeholderURL = url
        ThumbnailCache.shared.thumbnail(for: url) { [weak self] img in
            guard let self else { return }
            guard self.placeholderURL == url else { return }
            self.placeholder.image = img
            self.placeholder.alpha = 1
        }
    }

    func setPlayer(_ player: AVPlayer) {
        let layerView = (view as? PlayerLayerView)
        layerView?.playerLayer.player = player

        itemStatusObs?.invalidate()
        timeControlObs?.invalidate()
        itemStatusObs = nil
        timeControlObs = nil

        if let item = player.currentItem {
            itemStatusObs = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard let self else { return }
                if item.status == .readyToPlay { self.hidePlaceholder() }
            }
        }

        timeControlObs = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            guard let self else { return }
            if p.timeControlStatus == .playing { self.hidePlaceholder() }
        }
    }

    private func hidePlaceholder() {
        guard placeholder.alpha > 0.01 else { return }
        UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut]) {
            self.placeholder.alpha = 0
        }
    }

    @objc private func onTap() {
        guard let player = (view as? PlayerLayerView)?.playerLayer.player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            showPlayIcon()
        } else {
            player.playImmediately(atRate: 1.0)
            hidePlayIcon()
        }
    }

    private func showPlayIcon() { UIView.animate(withDuration: 0.12) { self.playIcon.alpha = 1.0 } }
    private func hidePlayIcon() { UIView.animate(withDuration: 0.12) { self.playIcon.alpha = 0.0 } }
}

private final class FeedPlaybackManager: ObservableObject {

    let objectWillChange = ObservableObjectPublisher()

    private struct Entry {
        let player: AVPlayer
        let item: AVPlayerItem
        var endObserver: NSObjectProtocol?
    }

    private var entries: [UUID: Entry] = [:]
    private var currentId: UUID?

    func player(for video: SavedVideo, url: URL) -> AVPlayer {
        if let e = entries[video.id] { return e.player }

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 0.2

        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .pause

        let obs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            guard self.currentId == video.id else { return }
            player.seek(to: .zero) { _ in
                player.playImmediately(atRate: 1.0)
            }
        }

        entries[video.id] = Entry(player: player, item: item, endObserver: obs)
        return player
    }

    func activate(videos: [SavedVideo], index: Int, urlFor: (SavedVideo) -> URL) {
        guard !videos.isEmpty else { return }
        let idx = min(max(0, index), max(0, videos.count - 1))

        let current = videos[idx]
        currentId = current.id

        var keep: [SavedVideo] = [current]
        if let prev = videos[safe: idx - 1] { keep.append(prev) }
        if let next = videos[safe: idx + 1] { keep.append(next) }

        let keepIds = Set(keep.map { $0.id })

        for v in keep {
            let p = player(for: v, url: urlFor(v))
            if v.id != current.id {
                p.pause()
            }
        }

        for (id, e) in entries where id != current.id {
            e.player.pause()
        }

        if let entry = entries[current.id] {
            let tol = CMTime(seconds: 0.08, preferredTimescale: 600)
            entry.player.seek(to: .zero, toleranceBefore: tol, toleranceAfter: tol) { _ in
                entry.player.playImmediately(atRate: 1.0)
            }
        }

        let removeIds = entries.keys.filter { !keepIds.contains($0) }
        for rid in removeIds { remove(videoId: rid) }
    }

    func remove(videoId: UUID) {
        guard let entry = entries.removeValue(forKey: videoId) else { return }
        entry.player.pause()
        entry.player.replaceCurrentItem(with: nil)
        if let obs = entry.endObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if currentId == videoId { currentId = nil }
    }

    func stopAll() {
        for id in Array(entries.keys) { remove(videoId: id) }
        currentId = nil
    }
}

private struct LibShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct LibToastHUD: View {
    let text: String
    var body: some View {
        VStack {
            Text(text)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.65))
                .clipShape(Capsule())
                .padding(.top, 22)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

// ✅ Audio session (video) — 修复 -50：playback 不使用 defaultToSpeaker / overrideOutput
private enum LibVideoAudioSession {
    static func activatePlayback() {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playback, mode: .moviePlayback)
            try s.setActive(true)
        } catch {
            print("LibVideoAudioSession error:", error)
        }
    }
}

private enum LibHaptics {
    static func heavy() { impact(.heavy) }
    static func medium() { impact(.medium) }
    static func light() { impact(.light) }

    private static var lastFire: CFAbsoluteTime = 0
    private static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle,
                               minInterval: CFAbsoluteTime = 0.14) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastFire >= minInterval else { return }
        lastFire = now
        let gen = UIImpactFeedbackGenerator(style: style)
        gen.prepare()
        gen.impactOccurred()
    }
}

private extension Array {
    subscript(safe idx: Int) -> Element? {
        guard idx >= 0, idx < count else { return nil }
        return self[idx]
    }
}


