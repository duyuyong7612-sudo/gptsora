// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-32915d18eda247b5a14f91454ab099a78fd03dc4c1e7481f0d6384b3c93f0706"
// Source-SHA256: "60f26b83ab0e62d0201582b4b6816e85c742ac52ba8e38d5702d6a360b790541"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI
import AVFoundation
import UIKit
import Combine

// MARK: - Demo model (auto-discover *demo_sample* files)
// ✅ 用 fileName 作为稳定 id，避免每次 reload 产生新 UUID 导致误判“数据变了”

struct DemoVideo: Identifiable, Equatable {
    let id: String
    let fileName: String   // without extension

    init(fileName: String) {
        self.fileName = fileName
        self.id = fileName
    }

    func url() -> URL? {
        Bundle.main.url(forResource: fileName, withExtension: "mp4")
        ?? Bundle.main.url(forResource: fileName, withExtension: "mov")
    }

    static func loadFromBundle() -> [DemoVideo] {
        let mp4 = Bundle.main.urls(forResourcesWithExtension: "mp4", subdirectory: nil) ?? []
        let mov = Bundle.main.urls(forResourcesWithExtension: "mov", subdirectory: nil) ?? []
        let urls = mp4 + mov

        var items: [(n: Int, name: String)] = []
        items.reserveCapacity(urls.count)

        for u in urls {
            let name = u.deletingPathExtension().lastPathComponent
            if name.contains("demo_sample"),
               let n = extractLeadingNumber(from: name) {
                items.append((n, name))
            }
        }

        let unique = Dictionary(grouping: items, by: { $0.name })
            .compactMap { $0.value.first }
            .sorted { $0.n < $1.n }

        if unique.isEmpty {
            let fallback = [
                "2demo_sample","4demo_sample","6demo_sample","7demo_sample","8demo_sample",
                "9demo_sample","10demo_sample","11demo_sample","13demo_sample",
                "14demo_sample","16demo_sample","17demo_sample","18demo_sample",
                "19demo_sample","20demo_sample","21demo_sample","22demo_sample"
            ]
            return fallback.map { DemoVideo(fileName: $0) }
        }

        return unique.map { DemoVideo(fileName: $0.name) }
    }

    private static func extractLeadingNumber(from s: String) -> Int? {
        var digits = ""
        for ch in s {
            if ch.isNumber { digits.append(ch) } else { break }
        }
        return digits.isEmpty ? nil : Int(digits)
    }
}

// MARK: - Demo Sample Page (pro-grade feed)

struct DemoSamplePage: View {

    @Binding var currentPage: Int

    init(currentPage: Binding<Int>) {
        self._currentPage = currentPage
    }

    @State private var demos: [DemoVideo] = []
    @State private var index: Int = 0

    // ✅ 关键修复：不要用 shared，避免 RootPagerView/VideoLibraryView 抢 stopAll
    @StateObject private var playback = DemoFeedPlaybackManager()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if demos.isEmpty {
                Color.black.onAppear {
                    demos = DemoVideo.loadFromBundle()
                    index = 0
                }
            } else {
                DemoVerticalVideoFeed(
                    demos: demos,
                    index: $index,
                    urlFor: { $0.url() },
                    playback: playback
                )
                .ignoresSafeArea()

                overlayUI
            }
        }
        .statusBarHidden(true)
        .onAppear {
            DemoVideoAudioSession.activatePlayback()
            playback.setMuted(false)
            playback.setRandomLoopEnabled(true)
        }
        .onDisappear {
            playback.pauseAll()
            playback.onRequestNext = nil
        }
    }

    private var overlayUI: some View {
        VStack {
            HStack {
                Button {
                    withAnimation { currentPage = max(0, currentPage - 1) }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(10)
                        .background(Color.black.opacity(0.35))
                        .clipShape(Circle())
                }

                Spacer()

                Text("\(min(index + 1, demos.count))/\(demos.count)")
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
        }
    }
}

// ======================================================================
// MARK: - Vertical feed (UICollectionView paging)
// ======================================================================

private struct DemoVerticalVideoFeed: UIViewControllerRepresentable {
    var demos: [DemoVideo]
    @Binding var index: Int
    let urlFor: (DemoVideo) -> URL?
    let playback: DemoFeedPlaybackManager

    func makeCoordinator() -> Coordinator { Coordinator(index: $index) }

    func makeUIViewController(context: Context) -> DemoVerticalFeedViewController {
        let vc = DemoVerticalFeedViewController(
            demos: demos,
            initialIndex: index,
            urlFor: urlFor,
            playback: playback
        )
        vc.onIndexChanged = { context.coordinator.setIndex($0) }
        return vc
    }

    func updateUIViewController(_ uiViewController: DemoVerticalFeedViewController, context: Context) {
        uiViewController.update(
            demos: demos,
            urlFor: urlFor,
            playback: playback,
            desiredIndex: index
        )
        uiViewController.onIndexChanged = { context.coordinator.setIndex($0) }
    }

    final class Coordinator: NSObject {
        private var index: Binding<Int>
        init(index: Binding<Int>) { self.index = index }
        func setIndex(_ newIndex: Int) {
            DispatchQueue.main.async {
                if self.index.wrappedValue != newIndex {
                    self.index.wrappedValue = newIndex
                }
            }
        }
    }
}
// MARK: - UIKit VC

private final class DemoVerticalFeedViewController: UIViewController {

    var demos: [DemoVideo]
    var urlFor: (DemoVideo) -> URL?
    var playback: DemoFeedPlaybackManager

    var onIndexChanged: ((Int) -> Void)?

    private var collectionView: UICollectionView!
    private var currentIndex: Int
    private var didInitialStart = false

    private var pendingActivationIndex: Int?
    private var pendingActivationRetries: Int = 0
    private var isUserInteracting = false

    init(
        demos: [DemoVideo],
        initialIndex: Int,
        urlFor: @escaping (DemoVideo) -> URL?,
        playback: DemoFeedPlaybackManager
    ) {
        self.demos = demos
        self.currentIndex = max(0, min(initialIndex, max(0, demos.count - 1)))
        self.urlFor = urlFor
        self.playback = playback
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0

        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.backgroundColor = .black
        cv.isPagingEnabled = true
        cv.decelerationRate = .fast
        cv.showsVerticalScrollIndicator = false
        cv.showsHorizontalScrollIndicator = false
        cv.alwaysBounceVertical = false
        cv.contentInsetAdjustmentBehavior = .never

        cv.dataSource = self
        cv.delegate = self
        cv.prefetchDataSource = self
        cv.register(DemoVideoFeedCell.self, forCellWithReuseIdentifier: DemoVideoFeedCell.reuseId)

        view.addSubview(cv)
        collectionView = cv

        // ✅ 随机循环：播放结束 -> 随机跳下一条（不在用户拖动时触发）
        playback.onRequestNext = { [weak self] in
            guard let self else { return }
            guard self.isViewLoaded, self.view.window != nil else { return }
            guard !self.isUserInteracting else { return }
            self.advanceToRandomNext()
        }

        playback.prewarm(demos: demos, index: currentIndex, urlFor: urlFor)
        DemoThumbCache.shared.prefetch(urls: DemoThumbCache.prefetchURLs(demos: demos, center: currentIndex, radius: 2, urlFor: urlFor))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        collectionView.frame = view.bounds

        if let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout {
            let size = view.bounds.size
            if layout.itemSize != size {
                layout.itemSize = size
                layout.invalidateLayout()
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // ✅ 只在第一次出现时 reload，避免反复清空 cell 造成黑屏
        if !didInitialStart {
            didInitialStart = true
            collectionView.reloadData()
            collectionView.layoutIfNeeded()
        } else {
            collectionView.layoutIfNeeded()
        }

        scrollTo(index: currentIndex, animated: false)
        collectionView.layoutIfNeeded()

        // ✅ 首屏直接激活（内部会自动重试直到拿到 cell）
        activate(index: currentIndex)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        playback.pauseAll()
        playback.onRequestNext = nil
    }

    func update(
        demos: [DemoVideo],
        urlFor: @escaping (DemoVideo) -> URL?,
        playback: DemoFeedPlaybackManager,
        desiredIndex: Int
    ) {
        let oldIds = self.demos.map(\.id)
        let newIds = demos.map(\.id)
        let demosChanged = oldIds != newIds

        self.demos = demos
        self.urlFor = urlFor
        self.playback = playback

        guard collectionView != nil else { return }

        let clamped = max(0, min(desiredIndex, max(0, demos.count - 1)))

        if demosChanged {
            collectionView.reloadData()
            collectionView.layoutIfNeeded()

            currentIndex = clamped
            scrollTo(index: clamped, animated: false)
            collectionView.layoutIfNeeded()

            self.playback.prewarm(demos: demos, index: clamped, urlFor: urlFor)
            DemoThumbCache.shared.prefetch(urls: DemoThumbCache.prefetchURLs(demos: demos, center: clamped, radius: 2, urlFor: urlFor))

            activate(index: clamped)
            return
        }

        if clamped != currentIndex {
            currentIndex = clamped
            scrollTo(index: clamped, animated: false)
            collectionView.layoutIfNeeded()
            activate(index: clamped)
            return
        }

        // ✅ demos没变 + index没变：不要 reload
    }

    private func scrollTo(index: Int, animated: Bool) {
        guard demos.indices.contains(index) else { return }
        collectionView.scrollToItem(at: IndexPath(item: index, section: 0), at: .top, animated: animated)
    }

    private func visibleIndex() -> Int {
        let h = max(1, collectionView.bounds.height)
        let y = collectionView.contentOffset.y
        return max(0, min(Int(round(y / h)), max(0, demos.count - 1)))
    }

    private func activate(index: Int) {
        guard !demos.isEmpty else { return }
        let idx = max(0, min(index, max(0, demos.count - 1)))
        currentIndex = idx
        onIndexChanged?(idx)

        DemoThumbCache.shared.prefetch(urls: DemoThumbCache.prefetchURLs(demos: demos, center: idx, radius: 2, urlFor: urlFor))
        playback.prewarm(demos: demos, index: idx, urlFor: urlFor)

        let demo = demos[idx]
        let u = urlFor(demo)
        let player = playback.player(for: demo, url: u)

        let ip = IndexPath(item: idx, section: 0)

        // ✅ 必须先绑到 cell.layer 再 activate 开播
        if let cell = collectionView.cellForItem(at: ip) as? DemoVideoFeedCell {
            cell.set(url: u, player: player)
            pendingActivationIndex = nil
            pendingActivationRetries = 0
            playback.activate(demos: demos, index: idx, urlFor: urlFor)
            return
        }

        // 首屏 cell 还没出现：自动重试
        pendingActivationIndex = idx
        pendingActivationRetries += 1

        if pendingActivationRetries <= 10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else { return }
                guard self.pendingActivationIndex == idx else { return }
                self.collectionView.layoutIfNeeded()
                self.activate(index: idx)
            }
        }
    }

    private func advanceToRandomNext() {
        guard demos.count >= 1 else { return }

        let next: Int
        if demos.count == 1 {
            next = 0
        } else {
            var r = currentIndex
            for _ in 0..<10 {
                let t = Int.random(in: 0..<demos.count)
                if t != currentIndex { r = t; break }
            }
            next = (r == currentIndex) ? ((currentIndex + 1) % demos.count) : r
        }

        currentIndex = next
        onIndexChanged?(next)

        pendingActivationIndex = next
        pendingActivationRetries = 0

        scrollTo(index: next, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.activate(index: next)
        }
    }
}

extension DemoVerticalFeedViewController: UICollectionViewDataSource, UICollectionViewDelegate, UIScrollViewDelegate {

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        demos.count
    }

    func collectionView(_ collectionView: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: DemoVideoFeedCell.reuseId,
            for: indexPath
        ) as! DemoVideoFeedCell
        cell.set(url: nil, player: nil)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView,
                        willDisplay cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        guard let cell = cell as? DemoVideoFeedCell,
              demos.indices.contains(indexPath.item) else { return }

        let demo = demos[indexPath.item]
        let u = urlFor(demo)
        let p = playback.player(for: demo, url: u)

        cell.set(url: u, player: p)

        // 如果 pending，补一次开播
        if pendingActivationIndex == indexPath.item {
            pendingActivationIndex = nil
            pendingActivationRetries = 0
            playback.activate(demos: demos, index: indexPath.item, urlFor: urlFor)
        }
    }

    func collectionView(_ collectionView: UICollectionView,
                        didEndDisplaying cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        (cell as? DemoVideoFeedCell)?.set(url: nil, player: nil)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isUserInteracting = true
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        isUserInteracting = false
        activate(index: visibleIndex())
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            isUserInteracting = false
            activate(index: visibleIndex())
        }
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView,
                                   withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        let h = max(1, collectionView.bounds.height)
        let targetY = targetContentOffset.pointee.y
        let target = max(0, min(Int(round(targetY / h)), max(0, demos.count - 1)))
        playback.prewarm(demos: demos, index: target, urlFor: urlFor)
        DemoThumbCache.shared.prefetch(urls: DemoThumbCache.prefetchURLs(demos: demos, center: target, radius: 2, urlFor: urlFor))
    }
}

extension DemoVerticalFeedViewController: UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let targets = indexPaths.map(\.item)
        playback.prewarm(demos: demos, indices: targets, urlFor: urlFor)
        let urls: [URL] = targets.compactMap { i in
            guard demos.indices.contains(i) else { return nil }
            return urlFor(demos[i])
        }
        DemoThumbCache.shared.prefetch(urls: urls)
    }
}
// ======================================================================
// MARK: - Cell (thumbnail always visible until AVPlayerLayer ready)
// ======================================================================

private final class DemoPlayerContainerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspectFill
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class DemoVideoFeedCell: UICollectionViewCell {
    static let reuseId = "DemoVideoFeedCell"

    private let thumbView = UIImageView()
    private let playerView = DemoPlayerContainerView()
    private let spinner = UIActivityIndicatorView(style: .large)

    private var itemStatusObs: NSKeyValueObservation?
    private var layerReadyObs: NSKeyValueObservation?
    private var bindToken = UUID()
    private var currentURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .black

        thumbView.contentMode = .scaleAspectFill
        thumbView.clipsToBounds = true
        thumbView.backgroundColor = .black

        contentView.addSubview(thumbView)
        contentView.addSubview(playerView)
        contentView.addSubview(spinner)

        thumbView.translatesAutoresizingMaskIntoConstraints = false
        playerView.translatesAutoresizingMaskIntoConstraints = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            thumbView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            thumbView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            thumbView.topAnchor.constraint(equalTo: contentView.topAnchor),
            thumbView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            playerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            spinner.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])

        spinner.hidesWhenStopped = true
        spinner.stopAnimating()

        thumbView.alpha = 1.0
        playerView.alpha = 0.0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        set(url: nil, player: nil)
    }

    func set(url: URL?, player: AVPlayer?) {
        let token = UUID()
        bindToken = token

        itemStatusObs = nil
        layerReadyObs = nil
        currentURL = url

        thumbView.alpha = 1.0
        playerView.alpha = 0.0

        if let url {
            DemoThumbCache.shared.thumbnail(for: url) { [weak self] img in
                guard let self else { return }
                guard self.bindToken == token, self.currentURL == url else { return }
                self.thumbView.image = img
            }
        } else {
            thumbView.image = nil
        }

        // ✅ 强制 layer 重新渲染，减少偶发首帧黑
        playerView.playerLayer.player = nil
        playerView.playerLayer.player = player
        playerView.playerLayer.setNeedsDisplay()
        playerView.playerLayer.backgroundColor = UIColor.black.cgColor

        guard let player, let item = player.currentItem else {
            spinner.stopAnimating()
            return
        }

        spinner.startAnimating()

        itemStatusObs = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            guard let self else { return }
            guard self.bindToken == token else { return }
            self.refreshPresentation(player: player)
        }

        layerReadyObs = playerView.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, _ in
            guard let self else { return }
            guard self.bindToken == token else { return }
            self.refreshPresentation(player: player)
        }

        refreshPresentation(player: player)
    }

    private func refreshPresentation(player: AVPlayer) {
        guard let item = player.currentItem else { return }
        let itemReady = (item.status == .readyToPlay)
        let layerReady = playerView.playerLayer.isReadyForDisplay

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if itemReady && layerReady {
                self.spinner.stopAnimating()
                if self.playerView.alpha < 1.0 {
                    UIView.animate(withDuration: 0.12, delay: 0, options: [.curveEaseOut]) {
                        self.playerView.alpha = 1.0
                        self.thumbView.alpha = 0.0
                    }
                }
            } else {
                self.thumbView.alpha = 1.0
                self.playerView.alpha = 0.0
                self.spinner.startAnimating()
            }
        }
    }
}

// ======================================================================
// MARK: - Thumbnail cache
// ======================================================================

private final class DemoThumbCache {
    static let shared = DemoThumbCache()

    private let cache = NSCache<NSURL, UIImage>()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "solara.demo.thumb"
        q.qualityOfService = .userInitiated
        q.maxConcurrentOperationCount = 2
        return q
    }()

    private init() { cache.countLimit = 200 }

    static func prefetchURLs(
        demos: [DemoVideo],
        center: Int,
        radius: Int,
        urlFor: (DemoVideo) -> URL?
    ) -> [URL] {
        guard !demos.isEmpty else { return [] }
        let c = max(0, min(center, max(0, demos.count - 1)))
        var out: [URL] = []
        for i in (c - radius)...(c + radius) where demos.indices.contains(i) {
            if let u = urlFor(demos[i]) { out.append(u) }
        }
        return out
    }

    func prefetch(urls: [URL]) {
        for u in urls {
            let key = u as NSURL
            if cache.object(forKey: key) != nil { continue }
            queue.addOperation { [weak self] in
                guard let self else { return }
                if self.cache.object(forKey: key) != nil { return }
                let img = self.makeThumb(url: u)
                if let img { self.cache.setObject(img, forKey: key) }
            }
        }
    }

    func thumbnail(for url: URL, completion: @escaping (UIImage?) -> Void) {
        let key = url as NSURL
        if let img = cache.object(forKey: key) {
            DispatchQueue.main.async { completion(img) }
            return
        }

        queue.addOperation { [weak self] in
            guard let self else { return }
            if let cached = self.cache.object(forKey: key) {
                DispatchQueue.main.async { completion(cached) }
                return
            }

            let img = self.makeThumb(url: url)
            if let img { self.cache.setObject(img, forKey: key) }
            DispatchQueue.main.async { completion(img) }
        }
    }

    private func makeThumb(url: URL) -> UIImage? {
        let asset = AVAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 720, height: 720)

        let t = CMTime(seconds: 0.12, preferredTimescale: 600)
        if let cg = try? gen.copyCGImage(at: t, actualTime: nil) {
            return UIImage(cgImage: cg)
        }
        return nil
    }
}

// ======================================================================
// MARK: - Playback manager
// ======================================================================

final class DemoFeedPlaybackManager: ObservableObject {

    // 兼容你工程其它地方还在用 shared（不影响本页，因为本页用实例）
    static let shared = DemoFeedPlaybackManager()

    var onRequestNext: (() -> Void)?

    private var randomLoopEnabled: Bool = true
    func setRandomLoopEnabled(_ enabled: Bool) { randomLoopEnabled = enabled }

    private final class Entry {
        let player: AVPlayer
        let item: AVPlayerItem
        var endObserver: NSObjectProtocol?
        var readyObserver: NSKeyValueObservation?

        init(player: AVPlayer, item: AVPlayerItem, endObserver: NSObjectProtocol?) {
            self.player = player
            self.item = item
            self.endObserver = endObserver
        }
    }

    private var entries: [String: Entry] = [:]
    private var currentId: String?
    private var activationToken = UUID()
    private var muted: Bool = false

    private let keepRadius: Int = 2
    private let startAtSeconds: Double = 0.02

    // ✅ 允许实例化（不要 private init）
    init() {}

    func setMuted(_ muted: Bool) {
        self.muted = muted
        for (_, e) in entries {
            e.player.isMuted = muted
            e.player.volume = muted ? 0.0 : 1.0
        }
    }

    func pauseAll() {
        for (_, e) in entries { e.player.pause() }
    }

    func stopAll() {
        for id in Array(entries.keys) { remove(videoId: id) }
        currentId = nil
    }

    func player(for demo: DemoVideo, url: URL?) -> AVPlayer {
        if let e = entries[demo.id] { return e.player }
        _ = prepare(demo: demo, url: url)
        return entries[demo.id]!.player
    }

    @discardableResult
    func prepare(demo: DemoVideo, url: URL?) -> AVPlayer {
        if let e = entries[demo.id] { return e.player }

        let item: AVPlayerItem
        if let url {
            let asset = AVURLAsset(url: url)
            item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = 0.45
        } else {
            item = AVPlayerItem(url: URL(fileURLWithPath: "/dev/null"))
        }

        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        player.isMuted = muted
        player.volume = muted ? 0.0 : 1.0
        player.automaticallyWaitsToMinimizeStalling = false

        let obs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            guard self.currentId == demo.id else { return }
            if self.randomLoopEnabled {
                self.onRequestNext?()
            } else {
                let start = CMTime(seconds: self.startAtSeconds, preferredTimescale: 600)
                player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                    player.playImmediately(atRate: 1.0)
                }
            }
        }

        entries[demo.id] = Entry(player: player, item: item, endObserver: obs)

        let start = CMTime(seconds: startAtSeconds, preferredTimescale: 600)
        player.pause()
        player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)

        return player
    }

    func prewarm(demos: [DemoVideo], index: Int, urlFor: (DemoVideo) -> URL?) {
        guard !demos.isEmpty else { return }
        let idx = max(0, min(index, max(0, demos.count - 1)))
        for i in (idx - keepRadius)...(idx + keepRadius) where demos.indices.contains(i) {
            let v = demos[i]
            _ = prepare(demo: v, url: urlFor(v))
        }
    }

    func prewarm(demos: [DemoVideo], indices: [Int], urlFor: (DemoVideo) -> URL?) {
        for i in indices where demos.indices.contains(i) {
            let v = demos[i]
            _ = prepare(demo: v, url: urlFor(v))
        }
    }

    func activate(demos: [DemoVideo], index: Int, urlFor: (DemoVideo) -> URL?) {
        guard !demos.isEmpty else { return }

        let idx = max(0, min(index, max(0, demos.count - 1)))
        let current = demos[idx]
        currentId = current.id

        let token = UUID()
        activationToken = token

        prewarm(demos: demos, index: idx, urlFor: urlFor)

        var keep: [DemoVideo] = []
        for i in (idx - keepRadius)...(idx + keepRadius) where demos.indices.contains(i) {
            keep.append(demos[i])
        }
        let keepIds = Set(keep.map { $0.id })

        for (id, e) in entries where id != current.id { e.player.pause() }

        let p = player(for: current, url: urlFor(current))
        startCurrentWhenReady(videoId: current.id, player: p, token: token)

        let removeIds = entries.keys.filter { !keepIds.contains($0) }
        for rid in removeIds { remove(videoId: rid) }
    }

    private func startCurrentWhenReady(videoId: String, player: AVPlayer, token: UUID) {
        guard let entry = entries[videoId] else { return }
        entry.readyObserver = nil

        let start = CMTime(seconds: startAtSeconds, preferredTimescale: 600)

        let tryStart: () -> Void = { [weak self] in
            guard let self else { return }
            guard self.activationToken == token else { return }
            guard self.currentId == videoId else { return }

            player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                guard let self else { return }
                guard self.activationToken == token, self.currentId == videoId else { return }
                player.playImmediately(atRate: 1.0)
            }
        }

        if entry.item.status == .readyToPlay {
            tryStart()
        } else {
            entry.readyObserver = entry.item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                guard let self else { return }
                guard self.activationToken == token, self.currentId == videoId else { return }
                if item.status == .readyToPlay {
                    self.entries[videoId]?.readyObserver = nil
                    tryStart()
                }
            }
        }
    }

    private func remove(videoId: String) {
        guard let entry = entries.removeValue(forKey: videoId) else { return }
        entry.readyObserver = nil
        entry.player.pause()
        entry.player.replaceCurrentItem(with: nil)
        if let obs = entry.endObserver { NotificationCenter.default.removeObserver(obs) }
        if currentId == videoId { currentId = nil }
    }
}

// MARK: - AudioSession

private enum DemoVideoAudioSession {
    static func activatePlayback() {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playback, mode: .moviePlayback)
            try s.setActive(true)
        } catch {
            print("DemoVideoAudioSession error:", error)
        }
    }
}

// MARK: - Safe subscript

private extension Array {
    subscript(safe idx: Int) -> Element? {
        guard idx >= 0, idx < count else { return nil }
        return self[idx]
    }
}
