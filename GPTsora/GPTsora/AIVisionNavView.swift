// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-e1036040a58727c1942f9fb9e90afeb553f269f7d99385b3ff246adb2c3cb64a"
// Source-SHA256: "c39ba7970c64449892e9607673031671fd56d6b26a22d199fd8035e9fe834167"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI
import Combine
import MapKit
import CoreLocation
@preconcurrency import AVFoundation
import Speech

// MARK: - LocationProvider
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var coordinate: CLLocationCoordinate2D? = nil
    @Published var latestLocation: CLLocation? = nil
    @Published var permissionMessage: String? = nil
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        manager.pausesLocationUpdatesAutomatically = false
    }

    func start() {
        let status = manager.authorizationStatus
        print("[Perception] location auth=\(AduPerceptionManager.describeAuth(status))")
        if status == .notDetermined {
            print("[Perception] request location permission")
            manager.requestWhenInUseAuthorization()
            return
        }
        if status == .denied || status == .restricted {
            permissionMessage = "定位权限未开启，请到设置中允许定位。"
            return
        }
        permissionMessage = nil
        manager.startUpdatingLocation()
    }

    func forceRefresh() {
        manager.stopUpdatingLocation()
        manager.startUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last,
              loc.horizontalAccuracy >= 0,
              loc.horizontalAccuracy < 200 else { return }
        DispatchQueue.main.async {
            self.coordinate = loc.coordinate
            self.latestLocation = loc
            self.permissionMessage = nil
            print("[Perception] location OK lat=\(String(format: "%.6f", loc.coordinate.latitude)) lon=\(String(format: "%.6f", loc.coordinate.longitude)) accuracy=\(String(format:"%.1f", loc.horizontalAccuracy))")
        }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let e = error as NSError
        if e.domain == kCLErrorDomain {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.manager.startUpdatingLocation()
            }
        }
    }
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        print("[Perception] location auth=\(AduPerceptionManager.describeAuth(status))")
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            permissionMessage = nil
            manager.startUpdatingLocation()
        } else if status == .denied || status == .restricted {
            permissionMessage = "定位权限未开启，请到设置中允许定位。"
        }
    }
}

// MARK: - TransportMode
enum TransportMode: CaseIterable, Identifiable {
    case driving, transit, cycling, walking
    var id: Self { self }

    var title: String {
        switch self {
        case .driving: return "驾车"
        case .transit: return "公交"
        case .cycling: return "骑行"
        case .walking: return "步行"
        }
    }
    var icon: String {
        switch self {
        case .driving: return "car.fill"
        case .transit: return "bus.fill"
        case .cycling: return "bicycle"
        case .walking: return "figure.walk"
        }
    }
    var mkType: MKDirectionsTransportType {
        switch self {
        case .driving: return .automobile
        case .transit: return .transit
        case .cycling: return .walking   // MK 无骑行，用步行路线+速度修正
        case .walking: return .walking
        }
    }
    // 骑行用步行路线，时间除以3（步行5km/h → 骑行15km/h）
    var timeFactor: Double {
        self == .cycling ? 1.0/3.0 : 1.0
    }
    var defaultSpeedMps: Double {
        switch self {
        case .driving: return 13.9   // 50 km/h
        case .transit: return 8.3    // 30 km/h
        case .cycling: return 4.2    // 15 km/h
        case .walking: return 1.4    //  5 km/h
        }
    }
}

// MARK: - RouteOption
struct RouteOption: Identifiable {
    let id = UUID()
    let mode: TransportMode
    let route: MKRoute
    let timeString: String
    let distanceString: String
    let etaString: String
    var isAlternate: Bool = false   // 备选路线标记
    var routeName: String = ""      // 路线名称（如"经 14号高速"）
}

// MARK: - AnnounceType
enum AnnounceType { case arrive, far, near, offroute, speed, reroute }

// MARK: - NavViewModel
@MainActor
final class NavViewModel: ObservableObject {

    @Published var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437),
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
    )
    @Published var destinationCoord: CLLocationCoordinate2D? = nil
    @Published var destinationName: String? = nil
    // ✅ 只保留目的地选择状态；路线/导航全部交给 Apple Maps 官方系统
    @Published var hasSelectedDestination: Bool = false
    @Published var route: MKRoute? = nil
    @Published var selectedMode: TransportMode = .driving
    @Published var routeOptions: [RouteOption] = []
    @Published var isLoadingRoutes: Bool = false
    @Published var showModeSelector: Bool = false
    @Published var isNavigating: Bool = false
    @Published var currentStepIndex: Int = 0
    @Published var searchResults: [MKMapItem] = []
    @Published var autoFillSearch: String = ""
    @Published var etaString: String = "--:--"
    @Published var remainingDistanceString: String = "--"
    @Published var remainingTimeString: String = "--"
    @Published var isSpeaking: Bool = true
    @Published var isListening: Bool = false
    @Published var isWakeWordActive: Bool = false   // 唤醒词"阿杜"监听中
    @Published var isRealtimeActive: Bool = false   // Realtime 对话进行中
    @Published var statusMessage: String = ""
    @Published var userHeading: CLLocationDirection = 0  // ✅ 车头朝向（地图旋转用）

    // 唤醒词检测专用识别器（持续后台运行）
    private let wakeRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var wakeRequest: SFSpeechAudioBufferRecognitionRequest? = nil
    private var wakeTask: SFSpeechRecognitionTask? = nil
    private let wakeAudioEngine = AVAudioEngine()
    private var wakeRestartTimer: Timer? = nil
    private var realtimeSessionTimer: Timer? = nil     // Realtime 超时自动关闭
    private var realtimeConnectCancellable: AnyCancellable? = nil  // 等待连接成功再注入上下文

    let locationProvider = LocationProvider()
    private var locationCancellable: AnyCancellable? = nil
    private var cancellables = Set<AnyCancellable>()
    private var hasInitialLocation = false
    private var pendingDestinationItem: MKMapItem? = nil

    let synthesizer = AVSpeechSynthesizer()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest? = nil
    private var recognitionTask: SFSpeechRecognitionTask? = nil
    private let audioEngine = AVAudioEngine()
    private var stepTimer: Timer? = nil

    var userLocation: CLLocationCoordinate2D? { locationProvider.coordinate }
    var currentStep: MKRoute.Step? {
        guard let r = route, currentStepIndex < r.steps.count else { return nil }
        return r.steps[currentStepIndex]
    }
    var nextStep: MKRoute.Step? {
        guard let r = route, currentStepIndex + 1 < r.steps.count else { return nil }
        return r.steps[currentStepIndex + 1]
    }

    init() {
        locationCancellable = locationProvider.$latestLocation
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] loc in
                guard let self = self else { return }
                if !self.hasInitialLocation {
                    self.hasInitialLocation = true
                    self.region = MKCoordinateRegion(
                        center: loc.coordinate,
                        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                    )
                }
                if self.isNavigating { self.updateNavigationProgress(location: loc) }
            }
        locationProvider.$permissionMessage
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                self?.statusMessage = message
            }
            .store(in: &cancellables)
        // ✅ 导航页打开时自动启动唤醒词监听
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.startWakeWordListening()
        }
    }

    func requestLocation() { locationProvider.start() }

    func recenterOnUser() {
        guard let loc = userLocation else { return }
        withAnimation {
            region = MKCoordinateRegion(center: loc,
                                        span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008))
        }
    }

    // MARK: - Search
    func searchDestination(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        statusMessage = "搜索中：\(q)"
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = q
        Task {
            do {
                let resp = try await MKLocalSearch(request: req).start()
                self.searchResults = Array(resp.mapItems.prefix(5))
                self.statusMessage = "找到 \(self.searchResults.count) 个结果"
                if self.searchResults.count == 1, let first = self.searchResults.first {
                    self.selectDestination(first)
                }
            } catch {
                self.searchResults = []
                self.statusMessage = "搜索失败：\(error.localizedDescription)"
            }
        }
    }

    func selectDestination(_ item: MKMapItem) {
        searchResults = []
        destinationCoord = item.placemark.coordinate
        destinationName = item.name
        pendingDestinationItem = item
        hasSelectedDestination = true

        // ✅ 彻底移除 App 内自研导航：不再计算路线、不再展示路线选择、不再进入内部导航状态。
        // 点击“开始导航”时，直接把目的地交给 Apple Maps 官方导航系统。
        route = nil
        routeOptions = []
        isLoadingRoutes = false
        showModeSelector = false
        isNavigating = false
        statusMessage = "已选择目的地，点开始导航打开苹果官方导航"
    }

    // MARK: - Load all transport routes in parallel
    private func loadAllRoutes(to item: MKMapItem) async {
        if userLocation == nil {
            statusMessage = "正在获取您的位置…"
            locationProvider.forceRefresh()
            for _ in 0..<24 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if userLocation != nil { break }
            }
        }
        guard let startCoord = userLocation else {
            statusMessage = "⚠️ 无法获取位置，请开启定位后重试"
            return
        }

        isLoadingRoutes = true
        statusMessage = "正在计算各出行方式时间…"

        // ✅ Keep map at user location - don't zoom to route yet
        region = MKCoordinateRegion(center: startCoord,
                                    span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05))

        var opts: [RouteOption] = []

        // ✅ Driving: request up to 3 alternate routes
        if let driveRoutes = await fetchMultipleRoutes(from: startCoord, to: item, mode: .driving) {
            for (i, r) in driveRoutes.enumerated() {
                let secs = r.expectedTravelTime
                let dist = r.distance
                let distStr = dist < 1000 ? String(format: "%.0f米", dist) : String(format: "%.1f公里", dist/1000)
                let timeStr = formatTime(secs)
                let eta = Date().addingTimeInterval(secs)
                let f = DateFormatter(); f.dateFormat = "HH:mm"
                let routeName = r.name.isEmpty ? (i == 0 ? "最快路线" : "备选路线 \(i)") : r.name
                var opt = RouteOption(mode: .driving, route: r,
                                      timeString: timeStr, distanceString: distStr,
                                      etaString: f.string(from: eta))
                opt.isAlternate = i > 0
                opt.routeName = routeName
                opts.append(opt)
            }
        }

        // ✅ Transit, cycling, walking: single route each
        await withTaskGroup(of: RouteOption?.self) { group in
            for mode in [TransportMode.transit, .cycling, .walking] {
                group.addTask { await self.fetchRoute(from: startCoord, to: item, mode: mode) }
            }
            for await opt in group {
                if let opt = opt { opts.append(opt) }
            }
        }

        // ✅ Sort: driving alternatives first, then transit, cycling, walking
        opts.sort {
            if $0.mode == $1.mode {
                return !$0.isAlternate && $1.isAlternate  // main before alternate
            }
            let order: [TransportMode] = [.driving, .transit, .cycling, .walking]
            return (order.firstIndex(of: $0.mode) ?? 9) < (order.firstIndex(of: $1.mode) ?? 9)
        }
        routeOptions = opts
        isLoadingRoutes = false

        // Default to fastest driving
        if let driveOpt = opts.first(where: { $0.mode == .driving && !$0.isAlternate }) {
            selectedMode = .driving
            route = driveOpt.route
            applyETA(opt: driveOpt)
            // ✅ Show route on map BUT keep map visible (don't jump to blank)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.region = driveOpt.route.polyline.boundingMapRect.toNavRegion()
            }
        }
        showModeSelector = true
        statusMessage = ""
        speakDirect("已计算路线，请选择出行方式")
    }

    /// Fetch up to 3 alternate routes for a mode
    private func fetchMultipleRoutes(from start: CLLocationCoordinate2D,
                                      to item: MKMapItem,
                                      mode: TransportMode) async -> [MKRoute]? {
        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
        req.destination = item
        req.transportType = mode.mkType
        req.requestsAlternateRoutes = true
        do {
            let resp = try await MKDirections(request: req).calculate()
            return resp.routes.isEmpty ? nil : Array(resp.routes.prefix(3))
        } catch { return nil }
    }

    private func fetchRoute(from start: CLLocationCoordinate2D,
                            to item: MKMapItem,
                            mode: TransportMode) async -> RouteOption? {
        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
        req.destination = item
        req.transportType = mode.mkType
        do {
            let resp = try await MKDirections(request: req).calculate()
            guard let r = resp.routes.first else { return nil }
            let secs = r.expectedTravelTime * mode.timeFactor
            let dist = r.distance
            let distStr = dist < 1000 ? String(format: "%.0f米", dist) : String(format: "%.1f公里", dist/1000)
            let timeStr = formatTime(secs)
            let eta = Date().addingTimeInterval(secs)
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            return RouteOption(mode: mode, route: r,
                               timeString: timeStr, distanceString: distStr,
                               etaString: f.string(from: eta))
        } catch { return nil }
    }

    func selectMode(_ opt: RouteOption) {
        selectedMode = opt.mode
        route = opt.route
        applyETA(opt: opt)
        withAnimation { region = opt.route.polyline.boundingMapRect.toNavRegion() }
        showModeSelector = false
        let name = opt.routeName.isEmpty ? opt.mode.title : "\(opt.mode.title)（\(opt.routeName)）"
        speakDirect("已选\(name)，全程\(opt.distanceString)，预计\(opt.timeString)")
    }

    private func applyETA(opt: RouteOption) {
        remainingDistanceString = opt.distanceString
        remainingTimeString = opt.timeString
        etaString = opt.etaString
    }

    // MARK: - Navigation
    /// ✅ 直接调用苹果原生 Maps 导航系统。
    /// 这里不再启动 App 内自研导航/播报/路线推进逻辑，避免伪导航或路线不同步。
    /// 用户点击“开始导航”后会跳转到 Apple Maps，由系统地图负责真实路线、转向、路况和导航。
    func startNavigation() {
        guard let destItem = pendingDestinationItem else {
            statusMessage = "请先搜索目的地"
            return
        }

        // 停掉本 App 内部导航状态，只把路线交给 Apple Maps。
        isNavigating = false
        stepTimer?.invalidate()
        stepTimer = nil
        route = nil
        routeOptions = []
        isLoadingRoutes = false
        showModeSelector = false
        statusMessage = "正在打开苹果官方导航…"

        let destination = MKMapItem(placemark: destItem.placemark)
        destination.name = destItem.name ?? destinationName ?? "目的地"

        var launchOptions: [String: Any] = [
            MKLaunchOptionsDirectionsModeKey: appleMapsDirectionsMode()
        ]

        if let coord = userLocation {
            let source = MKMapItem(placemark: MKPlacemark(coordinate: coord))
            source.name = "当前位置"
            MKMapItem.openMaps(with: [source, destination], launchOptions: launchOptions)
        } else {
            // 没拿到定位时，也直接打开 Apple Maps，让系统自己使用当前位置。
            destination.openInMaps(launchOptions: launchOptions)
        }

        speakDirect("正在打开苹果官方导航")
    }

    private func appleMapsDirectionsMode() -> String {
        switch selectedMode {
        case .driving:
            return MKLaunchOptionsDirectionsModeDriving
        case .transit:
            return MKLaunchOptionsDirectionsModeTransit
        case .walking:
            return MKLaunchOptionsDirectionsModeWalking
        case .cycling:
            // MapKit 公共 launchOptions 没有稳定的骑行常量；先用步行模式打开 Apple Maps，用户可在系统地图里切换骑行/驾车。
            return MKLaunchOptionsDirectionsModeWalking
        }
    }

    func stopNavigation() {
        isNavigating = false
        stepTimer?.invalidate(); stepTimer = nil
        announcedFar.removeAll()
        announcedNear.removeAll()
        announcedArrive = false
        statusMessage = ""
        speakDirect("导航已结束")
    }

    /// ✅ Find step whose polyline start is closest to user
    private func nearestStepIndex(in route: MKRoute, from coord: CLLocationCoordinate2D) -> Int {
        let user = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        var best = 0; var bestDist = Double.greatestFiniteMagnitude
        for (i, step) in route.steps.enumerated() {
            let pt = CLLocation(latitude: step.polyline.coordinate.latitude,
                                longitude: step.polyline.coordinate.longitude)
            let d = user.distance(from: pt)
            if d < bestDist { bestDist = d; best = i }
        }
        return best
    }

    // MARK: - AI Voice Announcement State
    private var announcedFar: Set<Int> = []    // 500m warning sent
    private var announcedNear: Set<Int> = []   // 100m warning sent
    private var announcedArrive = false
    private var lastOffRouteCheck: TimeInterval = 0
    private var lastSpeedWarning: TimeInterval = 0
    private var lastAITime: TimeInterval = 0
    private var isGeneratingVoice = false

    // MARK: - Navigation Progress (called every GPS update)
    private func checkStepProgress() {
        guard let r = route, let userLoc = userLocation else { return }
        let user = CLLocation(latitude: userLoc.latitude, longitude: userLoc.longitude)
        let now = Date().timeIntervalSince1970

        // 1. 到达目的地
        if !announcedArrive, let lastStep = r.steps.last {
            let dest = CLLocation(latitude: lastStep.polyline.coordinate.latitude,
                                  longitude: lastStep.polyline.coordinate.longitude)
            if user.distance(from: dest) < 50 {
                announcedArrive = true
                aiAnnounce(.arrive, instruction: destinationName ?? "目的地", distM: 0, speedKmh: 0)
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.stopNavigation() }
                return
            }
        }

        // 2. 步骤推进
        for (i, step) in r.steps.enumerated() where i > currentStepIndex {
            let pt = CLLocation(latitude: step.polyline.coordinate.latitude,
                                longitude: step.polyline.coordinate.longitude)
            if user.distance(from: pt) < 40 { currentStepIndex = i; break }
        }

        // 3. 预告下一步骤：500m + 100m
        let nextIdx = currentStepIndex + 1
        if nextIdx < r.steps.count {
            let nextStep = r.steps[nextIdx]
            let nextPt = CLLocation(latitude: nextStep.polyline.coordinate.latitude,
                                    longitude: nextStep.polyline.coordinate.longitude)
            let dist = user.distance(from: nextPt)
            let spd = (locationProvider.latestLocation?.speed ?? 0) * 3.6

            if dist < 550 && dist > 150 && !announcedFar.contains(nextIdx) {
                announcedFar.insert(nextIdx)
                aiAnnounce(.far, instruction: nextStep.instructions, distM: dist, speedKmh: spd)
            }
            if dist < 120 && !announcedNear.contains(nextIdx) {
                announcedNear.insert(nextIdx)
                aiAnnounce(.near, instruction: nextStep.instructions, distM: dist, speedKmh: spd)
            }
        }

        // 4. 偏离路线检测（每8秒一次）
        if now - lastOffRouteCheck > 8 { lastOffRouteCheck = now; checkOffRoute(user: user, route: r) }

        // 5. 超速检测（每15秒一次）
        if let loc = locationProvider.latestLocation, now - lastSpeedWarning > 15 {
            checkSpeedWarning(location: loc, step: r.steps[currentStepIndex])
        }
    }

    // MARK: - AI 真人播报核心（Claude Haiku 驱动）

    private func aiAnnounce(_ type: AnnounceType, instruction: String, distM: Double, speedKmh: Double) {
        guard isSpeaking, !isGeneratingVoice else { return }
        let now = Date().timeIntervalSince1970
        guard now - lastAITime > 3.5 else { return }
        isGeneratingVoice = true
        lastAITime = now

        let dest = destinationName ?? "目的地"
        let remainD = remainingDistanceString
        let remainT = remainingTimeString
        let mode = selectedMode.title
        let clean = cleanInstruction(instruction)

        let prompt: String
        switch type {
        case .arrive:
            prompt = "你是导航助手小雅，声音温暖亲切。用一句话播报已到达目的地\(clean)，口语化，温暖愉快，带祝福，不超过18字。只输出播报内容。"
        case .far:
            let distStr = distM < 1000 ? String(format: "%.0f米", distM) : String(format: "%.1f公里", distM/1000)
            prompt = "你是导航助手小雅。当前\(mode)，前方\(distStr)需要\(clean)，目的地\(dest)还有\(remainD)约\(remainT)。用一句自然口语播报，不超过25字，像高德真人导航员。只输出播报内容。"
        case .near:
            prompt = "你是导航助手小雅。驾驶员马上就要\(clean)了，距离不足100米。用一句紧凑提醒，不超过12字，口语化，有紧迫感。只输出播报内容。"
        case .offroute:
            prompt = "你是导航助手小雅。用户偏离路线，帮他重新规划。用一句安抚语气提醒，不超过15字，口语化。只输出播报内容。"
        case .speed:
            let spdStr = String(format: "%.0f", speedKmh)
            prompt = "你是导航助手小雅。用户当前时速\(spdStr)公里超速了。用一句关怀语气提醒，不超过12字，温和不生硬。只输出播报内容。"
        case .reroute:
            prompt = "你是导航助手小雅。路线已重新规划完成。用一句简洁提醒，不超过15字，口语化。只输出播报内容。"
        }

        Task {
            let text = await generateAIVoice(prompt: prompt, fallbackType: type,
                                              instruction: clean, distM: distM, speedKmh: speedKmh)
            await MainActor.run {
                self.isGeneratingVoice = false
                self.speakDirect(text)
            }
        }
    }

    private func generateAIVoice(prompt: String, fallbackType: AnnounceType,
                                   instruction: String, distM: Double, speedKmh: Double) async -> String {
        // 方案1: 后端代理（生产推荐，不暴露 API key）
        let proxyURL = URL(string: "\(AppConfig.API.apiBase)/nav/voice")!
        var proxyReq = URLRequest(url: proxyURL, timeoutInterval: 3.5)
        proxyReq.httpMethod = "POST"
        proxyReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        proxyReq.httpBody = try? JSONSerialization.data(withJSONObject: ["prompt": prompt])
        if let (data, resp) = try? await URLSession.shared.data(for: proxyReq),
           let http = resp as? HTTPURLResponse, http.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = json["text"] as? String, !text.isEmpty {
            return String(text.prefix(45))
        }

        // 方案2: 直接调 Claude Haiku（< 0.5秒，超低成本）
        // 配置方式：在 Info.plist 添加 ANTHROPIC_API_KEY，或从 Keychain 读取
        let claudeURL = URL(string: "https://api.anthropic.com/v1/messages")!
        var claudeReq = URLRequest(url: claudeURL, timeoutInterval: 5)
        claudeReq.httpMethod = "POST"
        claudeReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        claudeReq.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if let key = Bundle.main.infoDictionary?["ANTHROPIC_API_KEY"] as? String {
            claudeReq.setValue(key, forHTTPHeaderField: "x-api-key")
        }
        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 80,
            "system": "你是导航助手小雅。只输出播报内容，不加任何解释。语言简洁自然，口语化。",
            "messages": [["role": "user", "content": prompt]]
        ]
        claudeReq.httpBody = try? JSONSerialization.data(withJSONObject: body)
        if let (data, _) = try? await URLSession.shared.data(for: claudeReq),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let content = (json["content"] as? [[String: Any]])?.first,
           let text = content["text"] as? String, !text.isEmpty {
            let firstSentence = text.components(separatedBy: CharacterSet(charactersIn: "。！？\n")).first ?? text
            return String(firstSentence.trimmingCharacters(in: .whitespaces).prefix(45))
        }

        // 方案3: 本地模板 fallback
        return templateFallback(fallbackType, instruction: instruction, distM: distM, speedKmh: speedKmh)
    }

    private func templateFallback(_ type: AnnounceType, instruction: String,
                                   distM: Double, speedKmh: Double) -> String {
        switch type {
        case .arrive:   return "您已到达\(instruction)，导航结束，一路辛苦了"
        case .far:
            let d = distM < 1000 ? String(format: "%.0f米", distM) : String(format: "%.1f公里", distM/1000)
            return "前方\(d)，\(instruction)"
        case .near:     return "注意，马上\(instruction)，请准备好"
        case .offroute: return "已偏离路线，正在重新规划，请稍候"
        case .speed:    return String(format: "注意车速，时速%.0f公里，请安全驾驶", speedKmh)
        case .reroute:  return "路线已更新，请按新路线行驶"
        }
    }

    private func checkOffRoute(user: CLLocation, route: MKRoute) {
        var minDist = Double.greatestFiniteMagnitude
        let points = route.polyline.points()
        let count = route.polyline.pointCount
        for i in stride(from: 0, to: count, by: max(1, count / 30)) {
            let coord = points[i].coordinate
            let pt = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
            let d = user.distance(from: pt)
            if d < minDist { minDist = d }
        }
        guard minDist > 80 else { return }
        aiAnnounce(.offroute, instruction: "偏离路线", distM: minDist, speedKmh: 0)
        guard let destItem = pendingDestinationItem, let coord = userLocation else { return }
        Task {
            guard let opt = await fetchRoute(from: coord, to: destItem, mode: selectedMode) else { return }
            self.route = opt.route
            self.applyETA(opt: opt)
            self.currentStepIndex = self.nearestStepIndex(in: opt.route, from: coord)
            self.announcedFar.removeAll()
            self.announcedNear.removeAll()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.aiAnnounce(.reroute, instruction: "", distM: 0, speedKmh: 0)
            }
        }
    }

    private func checkSpeedWarning(location: CLLocation, step: MKRoute.Step) {
        guard location.speed > 0 else { return }
        let speedKmh = location.speed * 3.6
        let limitKmh: Double = step.distance > 500 ? 100.0 : 50.0
        guard speedKmh > limitKmh * 1.2 else { return }
        lastSpeedWarning = Date().timeIntervalSince1970
        aiAnnounce(.speed, instruction: "超速", distM: 0, speedKmh: speedKmh)
    }

    private func cleanInstruction(_ text: String) -> String {
        var t = text
        for prefix in ["Turn ", "Head ", "Continue ", "Proceed ", "Go "] {
            if t.hasPrefix(prefix) { t = String(t.dropFirst(prefix.count)) }
        }
        return t.isEmpty ? text : t
    }


    private func updateNavigationProgress(location: CLLocation) {
        guard let r = route else { return }
        // ✅ 更新车头朝向（速度>0.5m/s时才更新，避免静止时抖动）
        if location.speed > 0.5, location.course >= 0 {
            userHeading = location.course
        }
        let traveled = r.steps.prefix(currentStepIndex + 1).reduce(0.0) { $0 + $1.distance }
        let remaining = max(0, r.distance - traveled)
        let speed = location.speed > 0.5 ? location.speed : selectedMode.defaultSpeedMps
        let secs = remaining / speed
        remainingDistanceString = remaining < 1000
            ? String(format: "%.0f米", remaining)
            : String(format: "%.1f公里", remaining / 1000)
        remainingTimeString = formatTime(secs)
        let eta = Date().addingTimeInterval(secs)
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        etaString = f.string(from: eta)

        // ✅ Also run step/voice checks on each location update
        checkStepProgress()
    }

    private func formatTime(_ s: TimeInterval) -> String {
        let m = Int(s) / 60
        return m < 60 ? "\(m)分钟" : "\(m/60)小时\(m%60)分"
    }

    func formatDistance(_ m: CLLocationDistance) -> String {
        m < 1000 ? String(format: "%.0f米后", m) : String(format: "%.1f公里后", m/1000)
    }

    // MARK: - TTS
    func toggleSpeak() { isSpeaking.toggle() }

    func speakDirect(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: text)
        // ✅ 优先用 Tingting（macOS/iOS 内置高质量普通话），fallback 到 zh-CN
        if let voice = AVSpeechSynthesisVoice(identifier: "com.apple.voice.enhanced.zh-CN.Tingting")
                    ?? AVSpeechSynthesisVoice(identifier: "com.apple.ttsbundle.Tingting-compact")
                    ?? AVSpeechSynthesisVoice(language: "zh-CN") {
            u.voice = voice
        }
        u.rate = 0.52          // 稍快，导航节奏感
        u.pitchMultiplier = 1.08
        u.volume = 1.0
        // ✅ 导航播报用 AVAudioSession 混音（不打断音乐）
        try? AVAudioSession.sharedInstance().setCategory(
            .playback, mode: .voicePrompt,
            options: [.duckOthers, .allowBluetoothA2DP]
        )
        try? AVAudioSession.sharedInstance().setActive(true)
        synthesizer.speak(u)
    }

    func speak(_ text: String) {
        guard isSpeaking else { return }
        speakDirect(text)
    }

    // MARK: - Voice Input（修复：重置 AudioSession，避免被 HomeChatView 占用）
    func toggleVoiceInput() {
        isListening ? stopListening() : startListening()
    }

    private func startListening() {
        // ✅ 先请求语音识别权限
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                switch status {
                case .authorized:
                    Task { @MainActor [weak self] in self?.beginCapture() }
                case .denied, .restricted:
                    Task { @MainActor [weak self] in
                        self?.statusMessage = "语音识别权限被拒绝，请在设置中开启"
                        self?.speakDirect("请在设置中开启语音识别权限")
                    }
                default:
                    Task { @MainActor [weak self] in
                        self?.statusMessage = "语音识别不可用"
                    }
                }
            }
        }
    }

    private func beginCapture() {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            statusMessage = "语音识别不可用，请检查网络"
            return
        }

        // ✅ 修复：强制重置 AudioSession，防止被其他模块占用
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            try session.setCategory(.playAndRecord,
                                     mode: .measurement,
                                     options: [.duckOthers, .allowBluetoothA2DP])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            statusMessage = "音频初始化失败：\(error.localizedDescription)"
            return
        }

        // ✅ 清理上一次残留
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionTask?.cancel()
        recognitionTask = nil

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let req = recognitionRequest else { return }
        req.shouldReportPartialResults = true

        let node = audioEngine.inputNode
        recognitionTask = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if let r = result {
                    let text = r.bestTranscription.formattedString
                    self.autoFillSearch = text
                    self.statusMessage = "识别中：\(text)"
                    if r.isFinal {
                        self.stopListening()
                        // ✅ 去掉"去"、"前往"等前缀词，直接用地名
                        let cleaned = text
                            .replacingOccurrences(of: "去", with: "")
                            .replacingOccurrences(of: "前往", with: "")
                            .replacingOccurrences(of: "导航到", with: "")
                            .replacingOccurrences(of: "带我去", with: "")
                            .trimmingCharacters(in: .whitespaces)
                        self.searchDestination(cleaned)
                        // 等搜索结果，1.5秒后自动选第一个
                        try? await Task.sleep(nanoseconds: 1_800_000_000)
                        if let first = self.searchResults.first {
                            self.selectDestination(first)
                        }
                    }
                }
                if let err = error {
                    // ✅ 忽略 kAFAssistantErrorDomain 1110（正常结束）
                    let nsErr = err as NSError
                    if !(nsErr.domain == "kAFAssistantErrorDomain" && nsErr.code == 1110) {
                        self.statusMessage = "识别错误：\(err.localizedDescription)"
                    }
                    self.stopListening()
                }
            }
        }

        // ✅ 用硬件原生输入格式，避免 "HW format and tap format not match" crash
        let fmt = node.inputFormat(forBus: 0)
        node.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, _ in
            self?.recognitionRequest?.append(buf)
        }
        do {
            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
            statusMessage = "请说出目的地..."
            speakDirect("请说出目的地")
        } catch {
            statusMessage = "麦克风启动失败：\(error.localizedDescription)"
            stopListening()
        }
    }

    private func stopListening() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.reset()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isListening = false
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
    }

    // MARK: - 唤醒词"阿杜"系统
    func startWakeWordListening() {
        guard !isWakeWordActive else { return }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard status == .authorized else { return }
            Task { @MainActor [weak self] in
                self?.beginWakeWordCapture()
            }
        }
    }

    func stopWakeWordListening() {
        isWakeWordActive = false
        wakeRestartTimer?.invalidate()
        wakeRestartTimer = nil
        if wakeAudioEngine.isRunning {
            wakeAudioEngine.stop()
            wakeAudioEngine.inputNode.removeTap(onBus: 0)
        }
        wakeRequest?.endAudio()
        wakeTask?.cancel()
        wakeRequest = nil
        wakeTask = nil
    }

    private func beginWakeWordCapture() {
        guard let recognizer = wakeRecognizer, recognizer.isAvailable else { return }

        // ✅ 每次都重建 engine，避免旧 tap 残留导致 format mismatch crash
        wakeRestartTimer?.invalidate(); wakeRestartTimer = nil
        wakeTask?.cancel();            wakeTask = nil
        wakeRequest?.endAudio();       wakeRequest = nil

        if wakeAudioEngine.isRunning {
            wakeAudioEngine.stop()
        }
        // ✅ 关键：先 removeTap 再 reset，防止 "tap format not match" crash
        wakeAudioEngine.inputNode.removeTap(onBus: 0)
        wakeAudioEngine.reset()

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.duckOthers, .allowBluetoothA2DP, .mixWithOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch { return }

        wakeRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let req = wakeRequest else { return }
        req.shouldReportPartialResults = true
        req.taskHint = .dictation

        wakeTask = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let r = result {
                    let text = r.bestTranscription.formattedString.lowercased()
                    if text.contains("阿杜") || text.contains("adu") || text.contains("a du") {
                        self.onWakeWordDetected()
                        return
                    }
                    if r.isFinal {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            if self.isWakeWordActive { self.beginWakeWordCapture() }
                        }
                    }
                }
                if let err = error {
                    let code = (err as NSError).code
                    // code 203 = recognition canceled (正常), 1110 = no speech — 都直接重启
                    let delay: Double = (code == 203 || code == 1110) ? 0.1 : 1.0
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        if self.isWakeWordActive { self.beginWakeWordCapture() }
                    }
                }
            }
        }

        let node = wakeAudioEngine.inputNode
        // ✅ 用硬件原生输入格式，彻底避免 "HW format and tap format not match"
        let hwFmt = node.inputFormat(forBus: 0)
        node.installTap(onBus: 0, bufferSize: 4096, format: hwFmt) { [weak self] buf, _ in
            self?.wakeRequest?.append(buf)
        }

        do {
            wakeAudioEngine.prepare()
            try wakeAudioEngine.start()
            isWakeWordActive = true
        } catch {
            isWakeWordActive = false
            return
        }

        // 28秒自动重启（iOS SFSpeech 上限约60秒）
        wakeRestartTimer = Timer.scheduledTimer(withTimeInterval: 28, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isWakeWordActive else { return }
                self.beginWakeWordCapture()
            }
        }
    }

    // MARK: - 唤醒成功 → 接入 Realtime
    func onWakeWordDetected() {
        guard !isRealtimeActive else { return }

        stopWakeWordListening()
        isRealtimeActive = true
        speakDirect("在的")

        // 20秒无操作自动关闭
        realtimeSessionTimer?.invalidate()
        realtimeSessionTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.deactivateRealtime() }
        }

        activateRealtime()
    }

    // MARK: - 导航上下文（作为 JSON 传给后端 /session 的 nav_context 字段）
    private func buildNavContext() -> [String: Any] {
        var ctx: [String: Any] = [
            "mode": "nav",
            "is_navigating": isNavigating,
            "transport": selectedMode.title
        ]
        if let dest = destinationName { ctx["destination"] = dest }
        if isNavigating {
            ctx["remaining_distance"] = remainingDistanceString
            ctx["remaining_time"] = remainingTimeString
            ctx["eta"] = etaString
            if let step = currentStep { ctx["current_step"] = step.instructions }
            if let next = nextStep    { ctx["next_step"] = next.instructions }
        }
        return ctx
    }

    // MARK: - 真正接入 RealtimeBridge
    private func activateRealtime() {
        let lane  = RealtimeFastLane.shared
        let bridge = lane.bridge

        // ✅ 1. 设置 profile = "nav"，后端 /session 会加载导航专用助手配置
        bridge.configure(
            apiBase: AppConfig.API.apiBase,
            profile: "nav",
            clientId: nil   // 复用已有 clientId
        )

        // ✅ 2. 把导航实时状态序列化成 JSON 存入 haSessionProfile metadata
        //    后端可从 session request body 里读取 nav_context
        if let navJSON = try? JSONSerialization.data(withJSONObject: buildNavContext()),
           let navStr  = String(data: navJSON, encoding: .utf8) {
            // 通过 sessionProfile 附带上下文（格式：nav|{json}）
            bridge.sessionProfile = "nav|\(navStr)"
        }

        // ✅ 3. 监听连接成功 → 注入导航上下文（阿杜才能知道路况）
        realtimeConnectCancellable = bridge.$isConnected
            .filter { $0 }           // 等 isConnected 变为 true
            .first()                 // 只触发一次
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.injectNavContextToRealtime()
            }

        // ✅ 4. 监听 Realtime 回调 — 用户说话 / 助手回复
        bridge.onUserTranscript = { [weak self] text in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.statusMessage = "你：\(text)"
                // 重置超时计时器（用户还在说话）
                self.realtimeSessionTimer?.invalidate()
                self.realtimeSessionTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.deactivateRealtime() }
                }
            }
        }

        bridge.onAssistantPartial = { [weak self] text in
            Task { @MainActor [weak self] in
                self?.statusMessage = "阿杜：\(text)"
            }
        }

        bridge.onAssistantFinal = { [weak self] text in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.statusMessage = "阿杜：\(text)"
                // ✅ 检测导航指令：用户说"换条路"/"重新规划"
                self.handleNavCommand(from: text)
            }
        }

        bridge.onError = { [weak self] err in
            Task { @MainActor [weak self] in self?.handleRealtimeError(err) }
        }

        // ✅ 4. 建立连接（复用已有 WebRTC，秒连）
        lane.ensureConnected(apiBase: AppConfig.API.apiBase)
        statusMessage = "阿杜已激活，请说话"
    }

    // ✅ 解析助手回复里的导航指令
    private func handleNavCommand(from text: String) {
        let t = text.lowercased()
        // 用户说"换条路"/"备选路线"/"重新规划"
        if t.contains("换条") || t.contains("备选") || t.contains("重新规划") || t.contains("另一条") {
            if let dest = pendingDestinationItem, let coord = userLocation {
                Task {
                    speakDirect("好的，正在为您寻找备选路线")
                    if let opt = await fetchRoute(from: coord, to: dest, mode: selectedMode) {
                        self.route = opt.route
                        self.applyETA(opt: opt)
                        self.currentStepIndex = self.nearestStepIndex(in: opt.route, from: coord)
                        self.announcedFar.removeAll()
                        self.announcedNear.removeAll()
                    }
                }
            }
        }
        // 用户说"取消导航"/"结束"
        if t.contains("取消导航") || t.contains("结束导航") || t.contains("停止导航") {
            stopNavigation()
        }
        // 用户说"还有多久"/"还有多远" → 助手已通过 Realtime 回答，这里只更新状态栏
    }

    func deactivateRealtime() {
        guard isRealtimeActive else { return }
        realtimeSessionTimer?.invalidate()
        realtimeSessionTimer = nil

        // 清除回调，避免断开后还触发
        let bridge = RealtimeFastLane.shared.bridge
        bridge.onUserTranscript   = nil
        bridge.onAssistantPartial = nil
        bridge.onAssistantFinal   = nil

        RealtimeFastLane.shared.stop()
        isRealtimeActive = false
        statusMessage = isNavigating ? "导航中" : ""
        speakDirect("好的，拜拜")

        // 恢复唤醒词监听
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.startWakeWordListening()
        }
    }

    // MARK: - 导航上下文注入（连接成功后告知阿杜当前路况）
    private func injectNavContextToRealtime() {
        guard isRealtimeActive else { return }
        let ctx = buildNavContextString()
        // 通过后端 /nav/context 接口注入，或直接用 Claude Haiku 生成开场白
        Task {
            let greeting = await generateNavGreeting(ctx: ctx)
            DispatchQueue.main.async {
                self.statusMessage = greeting
                self.speakDirect(greeting)
            }
        }
    }

    // 把导航状态格式化成自然语言字符串
    private func buildNavContextString() -> String {
        guard isNavigating else {
            return "未在导航中，可帮用户搜索目的地"
        }
        var parts: [String] = []
        if let dest = destinationName { parts.append("目的地：\(dest)") }
        parts.append("剩余：\(remainingDistanceString)，约\(remainingTimeString)")
        if let step = currentStep, !step.instructions.isEmpty {
            parts.append("当前：\(step.instructions)")
        }
        return parts.joined(separator: "，")
    }

    // 连接成功后播报一句简短的开场白，让用户知道阿杜已就绪且了解路况
    private func generateNavGreeting(ctx: String) async -> String {
        let prompt = "你是导航助手阿杜，刚刚被用户唤醒。根据当前导航信息，用一句10字以内的口语问候，让用户知道你准备好了。导航信息：\(ctx)。只输出那一句话。"
        let claudeURL = URL(string: "https://api.anthropic.com/v1/messages")!
        var req = URLRequest(url: claudeURL, timeoutInterval: 4)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if let key = Bundle.main.infoDictionary?["ANTHROPIC_API_KEY"] as? String {
            req.setValue(key, forHTTPHeaderField: "x-api-key")
        }
        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 40,
            "messages": [["role": "user", "content": prompt]]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        if let (data, _) = try? await URLSession.shared.data(for: req),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let content = (json["content"] as? [[String: Any]])?.first,
           let text = content["text"] as? String, !text.isEmpty {
            return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30))
        }
        // fallback
        if isNavigating {
            return "在的，还有\(remainingDistanceString)"
        }
        return "在的，需要帮忙吗"
    }

    private func handleRealtimeError(_ err: String) {
        let t = err.lowercased()
        if t.contains("cancellation failed") || t.contains("no active response") { return }
        statusMessage = "连接中断，重新监听唤醒词"
        isRealtimeActive = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.startWakeWordListening()
        }
    }
}

// MARK: - AIVisionNavView
struct AIVisionNavView: View {

    @StateObject private var vm = NavViewModel()
    @State private var showSearchBar = false
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    @State private var showVisionCamera: Bool = false

    var body: some View {
        ZStack(alignment: .bottom) {
            MapViewRepresentable(
                region: $vm.region,
                route: vm.route,
                routeID: vm.route.map { ObjectIdentifier($0) },
                userLocation: vm.userLocation,
                destination: vm.destinationCoord,
                isNavigating: vm.isNavigating,
                userHeading: vm.userHeading    // ✅ 传入车头朝向
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer()
            }

            // 状态提示条
            if !vm.statusMessage.isEmpty && !vm.isNavigating {
                VStack {
                    Spacer()
                    Text(vm.statusMessage)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Color.black.opacity(0.65), in: Capsule())
                        .padding(.bottom, 170)
                        .transition(.opacity)
                }
                .animation(.easeInOut(duration: 0.3), value: vm.statusMessage)
            }

            // ✅ 自研导航 UI 已移除：不再显示内部转向卡片 / 内部路线选择卡。
            // 本页只负责：搜索目的地 + AI视觉识别；真正导航交给 Apple Maps 官方系统。
            bottomPanel
        }
        .ignoresSafeArea(edges: .bottom)
        .onAppear { vm.requestLocation() }
        .onChange(of: vm.autoFillSearch) { _, q in if !q.isEmpty { searchText = q } }
        .fullScreenCover(isPresented: $showVisionCamera) {
            AIVisionCameraView(onDismiss: { showVisionCamera = false })
        }
        .animation(.spring(response: 0.4), value: vm.showModeSelector)
    }

    // MARK: - Mode Selector Panel
    private var modeSelectorPanel: some View {
        VStack(spacing: 0) {
            // Drag handle
            Capsule()
                .fill(Color(.systemGray4))
                .frame(width: 36, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 6)

            // Destination header
            if let name = vm.destinationName {
                HStack(spacing: 10) {
                    Image(systemName: "mappin.circle.fill")
                        .foregroundColor(Color(hex: "#00E5FF"))
                        .font(.system(size: 18))
                    Text("前往 \(name)")
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    Button {
                        withAnimation { vm.showModeSelector = false }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 20))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }

            Divider()

            if vm.isLoadingRoutes {
                HStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: Color(hex: "#00E5FF")))
                    Text("正在计算各出行方式时间…")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 28)
            } else {
                // ✅ Group rows by mode, with dividers between groups
                let modes: [TransportMode] = [.driving, .transit, .cycling, .walking]
                VStack(spacing: 0) {
                    ForEach(Array(modes.enumerated()), id: \.offset) { modeIdx, mode in
                        let modeOpts = vm.routeOptions.filter { $0.mode == mode }
                        if !modeOpts.isEmpty {
                            ForEach(modeOpts) { opt in
                                modeRow(opt: opt)
                            }
                        } else {
                            // ✅ Fallback row for modes with no routes (e.g. transit unavailable)
                            unavailableRow(mode: mode)
                        }
                        if modeIdx < modes.count - 1 {
                            Divider().padding(.leading, 60)
                        }
                    }
                }
                .padding(.top, 4)

                // Start button
                Button { vm.startNavigation() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                            .font(.system(size: 20))
                        Text("开始\(vm.selectedMode.title)导航")
                            .font(.system(size: 16, weight: .bold))
                    }
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Color(hex: "#00E5FF"), in: RoundedRectangle(cornerRadius: 16))
                    .shadow(color: Color(hex: "#00E5FF").opacity(0.4), radius: 10, y: 4)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)
            }
        }
        .padding(.bottom, 30)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 20, y: -4)
    }

    private func modeRow(opt: RouteOption) -> some View {
        let isSelected = vm.selectedMode == opt.mode && vm.route.map { ObjectIdentifier($0) } == ObjectIdentifier(opt.route)
        return Button { vm.selectMode(opt) } label: {
            HStack(spacing: 14) {
                // Mode icon (only show for first row of each mode)
                ZStack {
                    Circle()
                        .fill(isSelected ? Color(hex: "#00E5FF") : Color(.systemGray5))
                        .frame(width: 42, height: 42)
                    Image(systemName: opt.mode.icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(isSelected ? .black : .secondary)
                }

                // Mode title + route name + distance
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(opt.mode.title)
                            .font(.system(size: 15, weight: isSelected ? .bold : .regular))
                            .foregroundColor(.primary)
                        if opt.isAlternate {
                            Text("备选")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color(.systemGray5), in: Capsule())
                        }
                    }
                    Text(opt.routeName.isEmpty ? opt.distanceString : "\(opt.routeName) · \(opt.distanceString)")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Time + ETA
                VStack(alignment: .trailing, spacing: 2) {
                    Text(opt.timeString)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(isSelected ? Color(hex: "#00E5FF") : .primary)
                    Text(opt.etaString + " 到达")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Color(hex: "#00E5FF"))
                        .font(.system(size: 18))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(isSelected ? Color(hex: "#00E5FF").opacity(0.06) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private func unavailableRow(mode: TransportMode) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color(.systemGray6)).frame(width: 42, height: 42)
                Image(systemName: mode.icon)
                    .font(.system(size: 18)).foregroundColor(Color(.systemGray3))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(mode.title)
                    .font(.system(size: 15)).foregroundColor(Color(.systemGray3))
                Text("此路段暂无\(mode.title)路线")
                    .font(.system(size: 12)).foregroundColor(Color(.systemGray4))
            }
            Spacer()
            Text("暂无")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color(.systemGray4))
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    // MARK: Top Bar
    private var topBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                if showSearchBar {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                        TextField("搜索目的地，如：洛杉矶机场", text: $searchText)
                            .focused($searchFocused)
                            .font(.system(size: 16))
                            .submitLabel(.search)
                            .onSubmit { vm.searchDestination(searchText) }
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))

                    Button {
                        showSearchBar = false; searchFocused = false; vm.searchResults = []
                    } label: {
                        Text("取消").font(.system(size: 15)).foregroundColor(.primary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(vm.isNavigating ? "导航中" : "AI 视觉导航")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                        Text(vm.destinationName.map { "前往 \($0)" } ?? "语音说出或搜索目的地")
                            .font(.system(size: 12)).foregroundColor(.secondary)
                    }
                    Spacer()
                    iconBtn("magnifyingglass") { showSearchBar = true; searchFocused = true }
                    iconBtn("location.fill") { vm.recenterOnUser() }
                }
            }
            .padding(.horizontal, 16).padding(.top, 58).padding(.bottom, 4)

            if !vm.searchResults.isEmpty {
                searchResultsList.padding(.horizontal, 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.spring(response: 0.3), value: showSearchBar)
        .animation(.spring(response: 0.3), value: vm.searchResults.isEmpty)
    }

    private var searchResultsList: some View {
        VStack(spacing: 0) {
            ForEach(Array(vm.searchResults.enumerated()), id: \.offset) { index, item in
                Button {
                    vm.selectDestination(item)
                    showSearchBar = false
                    searchText = item.name ?? ""
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 24)).foregroundColor(.red)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name ?? "未知地点")
                                .font(.system(size: 15, weight: .medium)).foregroundColor(.primary)
                            Text(item.placemark.title ?? "")
                                .font(.system(size: 12)).foregroundColor(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }
                if index < vm.searchResults.count - 1 { Divider().padding(.leading, 54) }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.1), radius: 12, y: 4)
    }

    private func stepCard(step: MKRoute.Step) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                // ✅ 大转向箭头区域
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(hex: "#00E5FF"))
                        .frame(width: 64, height: 64)
                        .shadow(color: Color(hex: "#00E5FF").opacity(0.45), radius: 10, y: 4)
                    Image(systemName: directionIcon(for: step.instructions))
                        .font(.system(size: 30, weight: .black))
                        .foregroundColor(.black)
                }

                // ✅ 指令文字 + 距离
                VStack(alignment: .leading, spacing: 4) {
                    Text(step.instructions)
                        .font(.system(size: 17, weight: .bold))
                        .lineLimit(2)
                        .foregroundColor(.primary)
                    HStack(spacing: 6) {
                        Image(systemName: "ruler")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                        Text(vm.formatDistance(step.distance))
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // ✅ 下一步骤预览（右侧竖排）
                if let next = vm.nextStep {
                    VStack(spacing: 3) {
                        Text("然后").font(.system(size: 10)).foregroundColor(.secondary)
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(.systemGray5))
                                .frame(width: 36, height: 36)
                            Image(systemName: directionIcon(for: next.instructions))
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.primary)
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            // ✅ 步骤进度条（显示当前步骤在全程的位置）
            if let route = vm.route {
                let totalSteps = route.steps.count
                let progress = totalSteps > 1
                    ? Double(vm.currentStepIndex) / Double(totalSteps - 1)
                    : 1.0
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(.systemGray5)).frame(height: 3)
                        Capsule()
                            .fill(Color(hex: "#00E5FF"))
                            .frame(width: geo.size.width * progress, height: 3)
                    }
                }
                .frame(height: 3)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 16)
        .shadow(color: .black.opacity(0.12), radius: 14, y: 5)
    }

    // MARK: Bottom Panel (during navigation or idle)
    private var bottomPanel: some View {
        VStack(spacing: 0) {
            if vm.isNavigating {
                HStack(spacing: 0) {
                    etaItem(value: vm.etaString, label: "预计到达")
                    Divider().frame(height: 36)
                    etaItem(value: vm.remainingDistanceString, label: "剩余距离")
                    Divider().frame(height: 36)
                    etaItem(value: vm.remainingTimeString, label: "剩余时间")
                }
                .padding(.vertical, 12)
                .background(Color(.systemBackground).opacity(0.96))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // AI 视觉入口（非导航时显示）
            if !vm.isNavigating {
                Button { showVisionCamera = true } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(LinearGradient(colors: [Color(hex: "#00E5FF"), Color(hex: "#0091EA")],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 36, height: 36)
                            Image(systemName: "eye.fill")
                                .font(.system(size: 16, weight: .semibold)).foregroundColor(.black)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text("AI 视觉识别").font(.system(size: 14, weight: .semibold)).foregroundColor(.primary)
                            Text("实时摄像头场景分析 · 智能播报")
                                .font(.system(size: 11)).foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold)).foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(Color(.systemBackground).opacity(0.95))
                    .overlay(Rectangle().fill(Color(hex: "#00E5FF").opacity(0.15))
                        .frame(width: 3).frame(maxHeight: .infinity), alignment: .leading)
                }
                .buttonStyle(.plain)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // ✅ 唤醒词"阿杜"状态栏 — 整条可点击，永远显示
            Button {
                if vm.isRealtimeActive {
                    vm.deactivateRealtime()
                } else {
                    vm.onWakeWordDetected()
                }
            } label: {
                HStack(spacing: 10) {
                    // 状态指示点
                    ZStack {
                        Circle()
                            .fill(vm.isRealtimeActive ? Color(hex: "#FF3B30") : Color(hex: "#00E5FF"))
                            .frame(width: 8, height: 8)
                        if vm.isRealtimeActive {
                            Circle()
                                .stroke(Color(hex: "#FF3B30").opacity(0.35), lineWidth: 5)
                                .frame(width: 20, height: 20)
                                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                                           value: vm.isRealtimeActive)
                        } else {
                            Circle()
                                .fill(Color(hex: "#00E5FF").opacity(0.2))
                                .frame(width: 16, height: 16)
                                .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                                           value: vm.isWakeWordActive)
                        }
                    }

                    Text(vm.isRealtimeActive
                         ? "阿杜正在聆听，点此结束"
                         : (vm.isWakeWordActive ? "说「阿杜」唤醒 · 或点击" : "点击唤醒阿杜"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(vm.isRealtimeActive ? Color(hex: "#FF3B30") : Color(hex: "#00E5FF"))

                    Spacer()

                    Image(systemName: vm.isRealtimeActive ? "waveform.circle.fill"
                                     : (vm.isWakeWordActive ? "mic.fill" : "mic.circle"))
                        .font(.system(size: 15))
                        .foregroundColor(vm.isRealtimeActive ? Color(hex: "#FF3B30")
                                         : (vm.isWakeWordActive ? Color(hex: "#00E5FF") : .secondary))
                }
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(vm.isRealtimeActive
                    ? Color(hex: "#FF3B30").opacity(0.07)
                    : Color(hex: "#00E5FF").opacity(0.06))
                .contentShape(Rectangle())   // ✅ 整行都可点击
            }
            .buttonStyle(.plain)

            HStack(spacing: 0) {
                actionItem(
                    icon: vm.isListening ? "waveform.circle.fill" : "mic.circle.fill",
                    label: vm.isListening ? "听取中" : "语音输入",
                    color: vm.isListening ? Color(hex: "#FF3B30") : .primary,
                    bgColor: vm.isListening ? Color(hex: "#FF3B30").opacity(0.12) : Color(.systemGray5)
                ) { vm.toggleVoiceInput() }

                VStack(spacing: 6) {
                    Button {
                        vm.isNavigating ? vm.stopNavigation() : vm.startNavigation()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(vm.isNavigating
                                      ? Color(hex: "#FF3B30")
                                      : (vm.hasSelectedDestination ? Color(hex: "#00E5FF") : Color(.systemGray4)))
                                .frame(width: 72, height: 72)
                                .shadow(color: (!vm.isNavigating && vm.hasSelectedDestination
                                                ? Color(hex: "#00E5FF") : .clear).opacity(0.5),
                                        radius: 14, y: 4)
                            Image(systemName: vm.isNavigating ? "stop.fill" : "arrow.triangle.turn.up.right.circle.fill")
                                .font(.system(size: vm.isNavigating ? 22 : 28))
                                .foregroundColor((vm.hasSelectedDestination || vm.isNavigating) ? .black : .secondary)
                        }
                    }
                    .disabled(!vm.hasSelectedDestination && !vm.isNavigating)
                    .scaleEffect(vm.isNavigating ? 0.96 : 1.0)
                    .animation(.spring(response: 0.25), value: vm.isNavigating)

                    Text(vm.isNavigating ? "结束导航" : "开始导航")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(vm.isNavigating ? Color(hex: "#FF3B30") : .secondary)
                }
                .frame(maxWidth: .infinity)

                actionItem(
                    icon: vm.isSpeaking ? "speaker.wave.3.fill" : "speaker.slash.fill",
                    label: vm.isSpeaking ? "播报开" : "播报关",
                    color: vm.isSpeaking ? Color(hex: "#00E5FF") : .secondary,
                    bgColor: vm.isSpeaking ? Color(hex: "#00E5FF").opacity(0.12) : Color(.systemGray5)
                ) { vm.toggleSpeak() }
            }
            .padding(.horizontal, 20).padding(.vertical, 16).padding(.bottom, 22)
            .background(.regularMaterial)
        }
        .animation(.spring(response: 0.35), value: vm.isNavigating)
    }

    private func etaItem(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 20, weight: .bold, design: .rounded))
            Text(label).font(.system(size: 11)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func actionItem(icon: String, label: String, color: Color, bgColor: Color, action: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().fill(bgColor).frame(width: 52, height: 52)
                Image(systemName: icon).font(.system(size: 24)).foregroundColor(color)
            }
            Text(label).font(.system(size: 11)).foregroundColor(color)
        }
        .onTapGesture(perform: action)
        .frame(maxWidth: .infinity)
    }

    private func iconBtn(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium)).foregroundColor(.primary)
                .frame(width: 36, height: 36)
                .background(.regularMaterial, in: Circle())
        }
    }

    private func directionIcon(for instruction: String) -> String {
        let i = instruction.lowercased()
        // 目的地 / 到达
        if i.contains("目的地") || i.contains("arrive") || i.contains("到达") || i.contains("终点") {
            return "mappin.circle.fill"
        }
        // 掉头
        if i.contains("掉头") || i.contains("u-turn") || i.contains("uturn") {
            return "arrow.uturn.left"
        }
        // 环岛
        if i.contains("环岛") || i.contains("roundabout") || i.contains("rotary") {
            return "arrow.clockwise.circle.fill"
        }
        // 高速 / 匝道
        if i.contains("匝道") || i.contains("ramp") || i.contains("出口") || i.contains("exit") {
            return "road.lanes"
        }
        // 左转系列
        if i.contains("稍向左") || i.contains("slight left") || i.contains("keep left") {
            return "arrow.up.left"
        }
        if i.contains("向左") || i.contains("左转") || i.contains("turn left") || i.contains(" left") {
            return "arrow.turn.up.left"
        }
        // 右转系列
        if i.contains("稍向右") || i.contains("slight right") || i.contains("keep right") {
            return "arrow.up.right"
        }
        if i.contains("向右") || i.contains("右转") || i.contains("turn right") || i.contains(" right") {
            return "arrow.turn.up.right"
        }
        // 直行 / 继续
        if i.contains("直行") || i.contains("continue") || i.contains("straight") || i.contains("proceed") {
            return "arrow.up"
        }
        return "arrow.up"
    }
}

// MARK: - MapViewRepresentable
struct MapViewRepresentable: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion
    var route: MKRoute?
    var routeID: ObjectIdentifier?
    var userLocation: CLLocationCoordinate2D?
    var destination: CLLocationCoordinate2D?
    var isNavigating: Bool = false
    var userHeading: CLLocationDirection = 0   // ✅ 车头朝向（degrees）

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsCompass = true
        map.showsScale = true
        map.pointOfInterestFilter = .includingAll
        map.setRegion(region, animated: false)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        map.removeOverlays(map.overlays)
        if let route = route {
            let outlinePolyline = NavOutlinePolyline(points: route.polyline.points(),
                                                      count: route.polyline.pointCount)
            map.addOverlay(outlinePolyline, level: .aboveRoads)
            map.addOverlay(route.polyline, level: .aboveRoads)
            if context.coordinator.lastRouteID != routeID {
                context.coordinator.lastRouteID = routeID
                if !isNavigating {
                    let padding = UIEdgeInsets(top: 80, left: 40, bottom: 220, right: 40)
                    map.setVisibleMapRect(route.polyline.boundingMapRect,
                                          edgePadding: padding, animated: true)
                }
            }
        }

        map.removeAnnotations(map.annotations.filter { !($0 is MKUserLocation) })
        if let dest = destination {
            let a = MKPointAnnotation()
            a.coordinate = dest; a.title = "目的地"
            map.addAnnotation(a)
        }

        // ✅ Navigation mode: 3D follow-cam aligned to heading
        if isNavigating, let loc = userLocation {
            // 停用系统跟踪，改用手动 MKMapCamera（支持真实 heading 旋转）
            if map.userTrackingMode != .none { map.userTrackingMode = .none }
            let camera = MKMapCamera(
                lookingAtCenter: loc,
                fromDistance: 350,          // 街道级别高度
                pitch: 45,                  // ✅ 3D 倾斜视角
                heading: userHeading        // ✅ 车头朝向
            )
            UIView.animate(withDuration: 0.4, delay: 0,
                           options: [.curveEaseInOut, .allowUserInteraction]) {
                map.camera = camera
            }
        } else if route == nil {
            map.userTrackingMode = .none
            map.setRegion(region, animated: true)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var lastRouteID: ObjectIdentifier? = nil

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let outline = overlay as? NavOutlinePolyline {
                let r = MKPolylineRenderer(polyline: outline)
                r.strokeColor = UIColor.white.withAlphaComponent(0.9)
                r.lineWidth = 12; r.lineCap = .round; r.lineJoin = .round
                return r
            }
            if let poly = overlay as? MKPolyline {
                let r = MKPolylineRenderer(polyline: poly)
                r.strokeColor = UIColor(red: 0, green: 0.898, blue: 1, alpha: 1)
                r.lineWidth = 7; r.lineCap = .round; r.lineJoin = .round
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard !(annotation is MKUserLocation) else { return nil }
            let v = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "dest")
            v.markerTintColor = UIColor(red: 0, green: 0.898, blue: 1, alpha: 1)
            v.glyphImage = UIImage(systemName: "flag.checkered")
            return v
        }
    }
}


// MARK: - NavOutlinePolyline (白色底线，用于路线轮廓)
final class NavOutlinePolyline: MKPolyline {}

// MARK: - Extensions
extension MKMapRect {
    func toNavRegion() -> MKCoordinateRegion {
        var r = MKCoordinateRegion(self)
        r.span.latitudeDelta  = max(r.span.latitudeDelta  * 1.25, 0.005)
        r.span.longitudeDelta = max(r.span.longitudeDelta * 1.25, 0.005)
        return r
    }
}

extension Color {
    init(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if h.hasPrefix("#") { h.removeFirst() }
        var rgb: UInt64 = 0
        Scanner(string: h).scanHexInt64(&rgb)
        self.init(
            red:   Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8)  & 0xFF) / 255,
            blue:  Double( rgb        & 0xFF) / 255
        )
    }
}


// MARK: ═══════════════════════════════════════════════════════════════
// MARK: - AIVisionCameraView（AI 视觉摄像头识别页）
// 从导航页点击「AI 视觉识别」按钮进入，全屏 fullScreenCover 呈现
// 下滑或点左上角「关闭」返回导航页
// ═══════════════════════════════════════════════════════════════════

struct AIVisionCameraView: View {

    let onDismiss: () -> Void

    @StateObject private var vm = VisionNavViewModel()
    @State private var torchOn: Bool = false
    @State private var capturedImage: UIImage? = nil
    @State private var showDetailSheet: Bool = false
    @State private var cornerScale: CGFloat = 0.92
    @State private var cornerOpacity: Double = 0.5
    @State private var scanLineY: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 相机预览
            CameraPreviewView(session: vm.session)
                .ignoresSafeArea()
                .overlay(scannerOverlay)

            // 顶部
            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomPanel
            }

            // 识别框浮层
            if !vm.detections.isEmpty {
                DetectionOverlayView(detections: vm.detections)
                    .allowsHitTesting(false)
            }

            // 🚨 危险警告横幅（最高优先级）
            if let danger = vm.dangerAlert {
                VStack {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.black)
                        Text(danger)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.black)
                        Spacer()
                    }
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(Color(hex: "#FF3B30"))
                    .transition(.move(edge: .top).combined(with: .opacity))
                    Spacer()
                }
                .padding(.top, 120)
                .animation(.spring(response: 0.3), value: vm.dangerAlert)
            }

            // 🚗 限速牌识别徽章
            if let limit = vm.speedLimit {
                VStack {
                    HStack {
                        Spacer()
                        ZStack {
                            Circle().fill(.white).frame(width: 56, height: 56)
                                .overlay(Circle().stroke(Color.red, lineWidth: 4))
                            VStack(spacing: -2) {
                                Text("限速").font(.system(size: 9, weight: .bold)).foregroundColor(.black)
                                Text("\(limit)").font(.system(size: 20, weight: .black)).foregroundColor(.black)
                            }
                        }
                        .shadow(radius: 6)
                        .padding(.trailing, 20)
                    }
                    Spacer()
                }
                .padding(.top, 130)
            }

            // ⚠️ 偏离车道警告
            if vm.laneWarning {
                VStack {
                    Spacer()
                    Text("⚠️ 注意车道")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Color(hex: "#FF9F0A").opacity(0.9), in: Capsule())
                        .padding(.bottom, 200)
                }
            }

            // 无摄像头权限
            if vm.authStatus == .denied || vm.authStatus == .restricted {
                cameraPermissionOverlay
            }
        }
        .onAppear {
            vm.startSession()
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                cornerScale = 1.0
                cornerOpacity = 1.0
            }
        }
        .onDisappear { vm.stopSession() }
        .sheet(isPresented: $showDetailSheet) {
            if let img = capturedImage {
                VisionDetailSheet(image: img, sceneText: vm.sceneDescription, objects: vm.detections)
            }
        }
    }

    // MARK: - Scanner Overlay
    private var scannerOverlay: some View {
        GeometryReader { geo in
            let w = geo.size.width * 0.82
            let h = w * 1.18
            let x = (geo.size.width - w) / 2
            let y = (geo.size.height - h) / 2

            ZStack {
                Rectangle()
                    .fill(Color.black.opacity(0.45))
                    .mask(
                        Rectangle()
                            .overlay(
                                RoundedRectangle(cornerRadius: 20)
                                    .frame(width: w, height: h)
                                    .blendMode(.destinationOut)
                            )
                            .compositingGroup()
                    )

                cornerFrame(w: w, h: h)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    .scaleEffect(cornerScale)
                    .opacity(cornerOpacity)

                if vm.isAnalyzing {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [.clear, Color(hex: "#00E5FF").opacity(0.9), .clear],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: w, height: 2)
                        .position(x: x + w / 2, y: y + scanLineY)
                        .onAppear {
                            withAnimation(.linear(duration: 2.0).repeatForever(autoreverses: true)) {
                                scanLineY = h
                            }
                        }
                }

                VStack {
                    Spacer().frame(height: y + h + 16)
                    statusHint
                    Spacer()
                }
            }
        }
    }

    private func cornerFrame(w: CGFloat, h: CGFloat) -> some View {
        let len: CGFloat = 28; let thick: CGFloat = 3
        return ZStack {
            cornerL(len: len, thick: thick, rot: 0)
                .offset(x: -w/2 + len/2 - thick/2, y: -h/2 + len/2 - thick/2)
            cornerL(len: len, thick: thick, rot: 90)
                .offset(x:  w/2 - len/2 + thick/2, y: -h/2 + len/2 - thick/2)
            cornerL(len: len, thick: thick, rot: 270)
                .offset(x: -w/2 + len/2 - thick/2, y:  h/2 - len/2 + thick/2)
            cornerL(len: len, thick: thick, rot: 180)
                .offset(x:  w/2 - len/2 + thick/2, y:  h/2 - len/2 + thick/2)
        }
    }

    private func cornerL(len: CGFloat, thick: CGFloat, rot: Double) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color(hex: "#00E5FF")).frame(width: thick, height: len)
            Rectangle().fill(Color(hex: "#00E5FF")).frame(width: len, height: thick)
        }
        .rotationEffect(.degrees(rot))
    }

    private var statusHint: some View {
        HStack(spacing: 6) {
            if vm.isAnalyzing {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: Color(hex: "#00E5FF")))
                    .scaleEffect(0.7)
                Text("AI 识别中…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color(hex: "#00E5FF"))
            } else if !vm.sceneDescription.isEmpty {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(Color(hex: "#00E5FF")).font(.system(size: 13))
                Text("识别完成")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color(hex: "#00E5FF"))
            } else {
                Text("行驶中自动识别路况 · 每4秒分析")
                    .font(.system(size: 13)).foregroundColor(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
    }

    // MARK: - Top Bar
    private var topBar: some View {
        HStack(alignment: .center) {
            // 关闭按钮（返回导航页）
            Button(action: onDismiss) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                    Text("导航")
                        .font(.system(size: 15, weight: .medium))
                }
                .foregroundColor(.white.opacity(0.9))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.white.opacity(0.1), in: Capsule())
            }

            Spacer()

            VStack(alignment: .center, spacing: 2) {
                Text("AI 视觉识别")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("实时场景分析")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
            }

            Spacer()

            // 手电筒 + 翻转
            HStack(spacing: 10) {
                Button {
                    torchOn.toggle()
                    vm.toggleTorch(on: torchOn)
                } label: {
                    Image(systemName: torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(torchOn ? Color(hex: "#00E5FF") : .white.opacity(0.6))
                        .frame(width: 38, height: 38)
                        .background(.white.opacity(0.08), in: Circle())
                }
                Button { vm.flipCamera() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 38, height: 38)
                        .background(.white.opacity(0.08), in: Circle())
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 60)
        .padding(.bottom, 14)
    }

    // MARK: - Bottom Panel
    private var bottomPanel: some View {
        VStack(spacing: 0) {
            // 场景描述卡片
            if !vm.sceneDescription.isEmpty {
                sceneDescriptionCard
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // 🧠 视觉大脑：空间记忆 + 感知决策
            if vm.hasCognitiveSignal {
                visionBrainCard
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(spacing: 24) {
                // 行车记录
                navBtn(
                    icon: vm.isRecording ? "record.circle.fill" : "record.circle",
                    label: vm.isRecording ? "录制中" : "记录仪",
                    tint: vm.isRecording ? Color(hex: "#FF3B30") : nil
                ) {
                    if vm.isRecording { vm.stopRecording() } else { vm.startRecording() }
                }

                // 拍照主按钮
                Button {
                    vm.captureAndAnalyze(mode: .manual) { img in
                        capturedImage = img
                        if img != nil { showDetailSheet = true }
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [Color(hex: "#00E5FF"), Color(hex: "#0091EA")],
                                    center: .center, startRadius: 0, endRadius: 36
                                )
                            )
                            .frame(width: 72, height: 72)
                            .shadow(color: Color(hex: "#00E5FF").opacity(0.5), radius: 16, y: 4)
                        if vm.isAnalyzing {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(1.2)
                        } else {
                            Image(systemName: "viewfinder")
                                .font(.system(size: 28, weight: .medium))
                                .foregroundColor(.white)
                        }
                    }
                }
                .disabled(vm.isAnalyzing)
                .scaleEffect(vm.isAnalyzing ? 0.94 : 1.0)
                .animation(.spring(response: 0.25), value: vm.isAnalyzing)

                // 语音播报
                navBtn(
                    icon: vm.isSpeaking ? "speaker.wave.3.fill" : "speaker.wave.2",
                    label: vm.isSpeaking ? "播报中" : "播报",
                    tint: vm.isSpeaking ? Color(hex: "#00E5FF") : nil
                ) { vm.toggleSpeak() }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 20)
            .padding(.bottom, 28)
        }
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.85)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }

    private var sceneDescriptionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("场景描述", systemImage: "eye.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "#00E5FF"))
                Spacer()
                if vm.confidence > 0 {
                    Text(String(format: "%.0f%%", vm.confidence * 100))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.white.opacity(0.1), in: Capsule())
                }
            }
            Text(vm.sceneDescription)
                .font(.system(size: 15)).foregroundColor(.white.opacity(0.92))
                .lineSpacing(4).lineLimit(4)
            if !vm.detections.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(vm.detections.prefix(6)) { det in
                            HStack(spacing: 4) {
                                Circle().fill(det.color).frame(width: 7, height: 7)
                                Text(det.label)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.white.opacity(0.8))
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.white.opacity(0.08), in: Capsule())
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color(hex: "#00E5FF").opacity(0.2), lineWidth: 1)
                )
        )
        .padding(.horizontal, 16).padding(.bottom, 12)
    }

    private var visionBrainCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Color(hex: "#00E5FF"))
                Text("视觉大脑")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "#00E5FF"))
                Spacer()
                Text(vm.visualModeText)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.65))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.white.opacity(0.08), in: Capsule())
            }

            if !vm.visualDecisionText.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: vm.visualDecisionIcon)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(vm.visualDecisionColor)
                        .frame(width: 18)
                    Text(vm.visualDecisionText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.92))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
            }

            if !vm.spatialMemorySummary.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white.opacity(0.72))
                        .frame(width: 18)
                    Text(vm.spatialMemorySummary)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.72))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color(hex: "#00E5FF").opacity(0.22), lineWidth: 1)
                )
        )
        .padding(.horizontal, 16).padding(.bottom, 10)
    }

    private func navBtn(icon: String, label: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 22))
                    .foregroundColor(tint ?? .white.opacity(0.65))
                Text(label).font(.system(size: 11))
                    .foregroundColor(tint ?? .white.opacity(0.5))
            }
        }
    }

    private var cameraPermissionOverlay: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "camera.slash.fill")
                    .font(.system(size: 52)).foregroundColor(.white.opacity(0.4))
                Text("需要摄像头权限")
                    .font(.system(size: 18, weight: .semibold)).foregroundColor(.white)
                Text("请前往「设置」开启摄像头访问权限")
                    .font(.system(size: 14)).foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("打开设置")
                        .font(.system(size: 15, weight: .semibold)).foregroundColor(.black)
                        .padding(.horizontal, 28).padding(.vertical, 12)
                        .background(Color(hex: "#00E5FF"), in: Capsule())
                }
            }
            .padding(40)
        }
    }
}

// MARK: - Detection Overlay（识别框浮层）
struct DetectionOverlayView: View {
    let detections: [VisionDetection]
    var body: some View {
        GeometryReader { geo in
            ForEach(detections) { det in
                let r = det.normalizedRect
                let x = r.minX * geo.size.width
                let y = r.minY * geo.size.height
                let w = r.width  * geo.size.width
                let h = r.height * geo.size.height
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(det.color.opacity(0.85), lineWidth: 1.5)
                        .frame(width: w, height: h)
                    Text(det.label)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.black)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(det.color, in: RoundedRectangle(cornerRadius: 4))
                        .offset(y: -18)
                }
                .position(x: x + w / 2, y: y + h / 2)
            }
        }
    }
}

// MARK: - Vision Detail Sheet
struct VisionDetailSheet: View {
    let image: UIImage
    let sceneText: String
    let objects: [VisionDetection]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Image(uiImage: image)
                        .resizable().scaledToFill()
                        .frame(maxWidth: .infinity).frame(height: 260)
                        .clipped().cornerRadius(16)
                    VStack(alignment: .leading, spacing: 8) {
                        Label("场景描述", systemImage: "doc.text.magnifyingglass")
                            .font(.system(size: 14, weight: .semibold)).foregroundColor(.secondary)
                        Text(sceneText.isEmpty ? "暂无描述" : sceneText)
                            .font(.system(size: 16)).foregroundColor(.primary).lineSpacing(5)
                    }
                    .padding(16)
                    .background(Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 14))
                    if !objects.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("识别物体", systemImage: "square.3.layers.3d.down.left")
                                .font(.system(size: 14, weight: .semibold)).foregroundColor(.secondary)
                            ForEach(objects) { obj in
                                HStack {
                                    Circle().fill(obj.color).frame(width: 10, height: 10)
                                    Text(obj.label).font(.system(size: 15))
                                    Spacer()
                                    Text(String(format: "%.0f%%", obj.confidence * 100))
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 6)
                                Divider()
                            }
                        }
                        .padding(16)
                        .background(Color(.secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 14))
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("识别详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: - VisionDetection Model
struct VisionDetection: Identifiable {
    let id = UUID()
    let label: String
    let confidence: Float
    let normalizedRect: CGRect
    let color: Color
}

// MARK: - Visual Cognition Models
struct SpatialMemoryObject: Identifiable {
    let id = UUID()
    var label: String
    var direction: String
    var risk: String
    var confidence: Float
    var lastSeenAt: Date
}

enum VisualDecisionLevel: String {
    case observing
    case safe
    case caution
    case danger

    var icon: String {
        switch self {
        case .observing: return "eye"
        case .safe: return "checkmark.shield.fill"
        case .caution: return "exclamationmark.triangle.fill"
        case .danger: return "bolt.trianglebadge.exclamationmark.fill"
        }
    }

    var color: Color {
        switch self {
        case .observing: return Color(hex: "#00E5FF")
        case .safe: return Color.green
        case .caution: return Color(hex: "#FF9F0A")
        case .danger: return Color(hex: "#FF3B30")
        }
    }
}

// MARK: - VisionNavViewModel
@MainActor
final class VisionNavViewModel: NSObject, ObservableObject {

    // MARK: - Camera Session
    // nonisolated(unsafe): AVCapture objects accessed from background queue
    nonisolated(unsafe) let session      = AVCaptureSession()
    nonisolated(unsafe) var photoOutput  = AVCapturePhotoOutput()
    nonisolated(unsafe) var movieOutput = AVCaptureMovieFileOutput()
    private var videoOutput              = AVCaptureVideoDataOutput()
    private var currentCameraPos: AVCaptureDevice.Position = .back

    // MARK: - Published State
    @Published var authStatus:        AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Published var isAnalyzing:       Bool    = false
    @Published var sceneDescription:  String  = ""
    @Published var detections:        [VisionDetection] = []
    @Published var confidence:        Float   = 0
    @Published var isSpeaking:        Bool    = false
    @Published var isRecording:       Bool    = false  // 行车记录仪

    // 危险警告（行人/障碍）
    @Published var dangerAlert:       String? = nil    // nil = 安全
    @Published var speedLimit:        Int?    = nil    // 识别到的限速值
    @Published var laneWarning:       Bool    = false  // 偏离车道

    // 🧠 视觉认知层：空间记忆 + 决策输出
    @Published var spatialMemory: [SpatialMemoryObject] = []
    @Published var visualDecisionLevel: VisualDecisionLevel = .observing
    @Published var visualDecisionText: String = "正在建立视觉空间模型…"
    @Published var visualModeText: String = "PERCEPTION"

    var hasCognitiveSignal: Bool {
        !visualDecisionText.isEmpty || !spatialMemory.isEmpty
    }

    var visualDecisionIcon: String { visualDecisionLevel.icon }
    var visualDecisionColor: Color { visualDecisionLevel.color }

    var spatialMemorySummary: String {
        let live = spatialMemory
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
            .prefix(4)
            .map { "\($0.direction)\($0.label)" }
        guard !live.isEmpty else { return "空间记忆正在初始化，等待稳定识别外部世界。" }
        return "空间记忆：" + live.joined(separator: "，")
    }

    // MARK: - Private
    private var lastAnalysisAt:    TimeInterval = 0
    private var analyzeInterval:   TimeInterval = 4.0   // 行驶中每4秒分析一帧
    private var analyzeTimer:      Timer?
    private var analyzeTask:       Task<Void, Never>?
    private let synthesizer        = AVSpeechSynthesizer()
    private var captureCompletion: ((UIImage?) -> Void)?

    // 行车记录
    private var recordingURL:      URL?

    // API Keys
    private var anthropicKey: String {
        Bundle.main.infoDictionary?["ANTHROPIC_API_KEY"] as? String ?? ""
    }
    private var openAIKey: String {
        Bundle.main.infoDictionary?["OPENAI_API_KEY"] as? String ?? ""
    }
    // TTS 音频队列
    private var ttsPlayer: AVAudioPlayer?
    private var ttsQueue: [(Data, Bool)] = []  // (audioData, isUrgent)
    private var ttsPlaying = false

    // MARK: - Session Start
    func startSession() {
        Task {
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            if status == .notDetermined {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                authStatus = granted ? .authorized : .denied
            } else {
                authStatus = status
            }
            guard authStatus == .authorized else { return }
            await configureSession(position: .back)
            startAutoAnalysis()
        }
    }

    func stopSession() {
        analyzeTimer?.invalidate(); analyzeTimer = nil
        analyzeTask?.cancel()
        if isRecording { stopRecording() }
        let s = session
        Task.detached { s.stopRunning() }
    }

    // MARK: - Configure Camera
    private func configureSession(position: AVCaptureDevice.Position) async {
        // AVCaptureSession must run on a background serial queue (not MainActor)
        // Use @unchecked Sendable box to pass AVCapture objects safely
        let s = self.session
        let photo = self.photoOutput
        let movie = self.movieOutput
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                s.beginConfiguration()
                s.sessionPreset = .hd1920x1080
                s.inputs.forEach  { s.removeInput($0) }
                s.outputs.forEach { s.removeOutput($0) }
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                           for: .video, position: position),
                      let input = try? AVCaptureDeviceInput(device: device),
                      s.canAddInput(input) else {
                    s.commitConfiguration(); cont.resume(); return
                }
                s.addInput(input)
                if s.canAddOutput(photo) { s.addOutput(photo) }
                if s.canAddOutput(movie) { s.addOutput(movie) }
                s.commitConfiguration()
                s.startRunning()
                cont.resume()
            }
        }
    }

    // MARK: - Auto Analysis Timer
    private func startAutoAnalysis() {
        analyzeTimer?.invalidate()

        // ✅ 视觉大脑启动后先尽快分析第一帧，避免 UI 长时间停留在“初始化”
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isAnalyzing, self.session.isRunning else { return }
                self.captureAndAnalyze(mode: .driving, completion: nil)
            }
        }

        // ✅ 持续感知：每 4 秒取一帧，形成短时空间记忆
        analyzeTimer = Timer.scheduledTimer(withTimeInterval: analyzeInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isAnalyzing, self.session.isRunning else { return }
                self.captureAndAnalyze(mode: .driving, completion: nil)
            }
        }
        if let t = analyzeTimer {
            RunLoop.main.add(t, forMode: .common)
        }
    }

    // MARK: - Capture & Analyze
    enum AnalyzeMode { case driving, manual, wakeword }

    func captureAndAnalyze(mode: AnalyzeMode = .manual, completion: ((UIImage?) -> Void)? = nil) {
        guard !isAnalyzing else { return }
        guard session.isRunning else { return }
        isAnalyzing = true
        captureCompletion = completion

        // 截取当前帧
        let settings = AVCapturePhotoSettings()
        settings.flashMode = .off
        photoOutput.capturePhoto(with: settings, delegate: PhotoDelegate { [weak self] image in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let img = image {
                    await self.analyzeFrame(img, mode: mode)
                    self.captureCompletion?(img)
                } else {
                    self.isAnalyzing = false
                    self.captureCompletion?(nil)
                }
                self.captureCompletion = nil
            }
        })
    }

    // MARK: - Claude Vision Analysis
    // MARK: - GPT-4o 流式视觉分析 + 并行 TTS
    private func analyzeFrame(_ image: UIImage, mode: AnalyzeMode) async {
        guard let jpegData = image.jpegData(compressionQuality: 0.55) else {
            isAnalyzing = false; return
        }
        let base64 = jpegData.base64EncodedString()

        // ✅ 接入实时视觉通道：如果语音/音视频大脑正在运行，把当前帧注入 RealtimeAVService。
        // 这样助手不只“听见”，也能持续“看见”外部世界。
        RealtimeAVService.shared.injectImageData(jpegData, mime: "image/jpeg")

        let systemPrompt = """
你是车载AI视觉助手，分析行车摄像头画面。用简洁中文口语回答，规则：
- 发现行人/障碍/危险：先说「注意，」开头，10字内
- 发现限速牌：说「限速X公里」
- 发现路口/转弯：说提示语
- 正常路况：5字内描述或不说话
- 最后一行固定输出JSON：{"danger":"危险描述或空","speed_limit":数字或null,"lane":true或false}
"""
        let userPrompt = mode == .driving
            ? "分析当前行车画面，先播报，再输出JSON。"
            : "详细描述这张行车画面的路况和安全情况，再输出JSON。"

        // 只发 base64 + mode 给后端，API Key 留在服务器
        let body: [String: Any] = [
            "base64": base64,
            "mode": mode == .driving ? "driving" : "manual"
        ]

        visualModeText = "PERCEPTION"
        visualDecisionLevel = .observing
        if sceneDescription.isEmpty {
            visualDecisionText = "正在读取摄像头画面，建立视觉空间模型…"
        }

        let ok = await streamVisionWithTTS(body: body, mode: mode)
        if !ok {
            await analyzeViaBackendFallback(body: body, mode: mode)
        }

        rebuildCognitiveStateFromCurrentScene(mode: mode)
        isAnalyzing = false
    }

    // MARK: - 流式接收 + 并行TTS（核心：收到第一句就开始合成）
    // 统一走后端 /vision/stream，无需在设备存 API Key
    @discardableResult
    private func streamVisionWithTTS(body: [String: Any], mode: AnalyzeMode) async -> Bool {
        return await streamViaBackend(body: body, mode: mode)
    }

    private func _streamDirectOpenAI(body: [String: Any], mode: AnalyzeMode) async {
        // 直连 OpenAI（仅当后端不可用时的内部备用，通常不调用）
        let key = openAIKey
        guard !key.isEmpty else { return }

        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!,
                             timeoutInterval: 12)
        req.httpMethod = "POST"
        req.setValue("application/json",  forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)",    forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        var accumulated = ""
        var spokenUpTo  = 0     // 已送TTS的字符位置
        var jsonBuffer  = ""
        var inJSON      = false

        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                sceneDescription = "GPT-4o 请求失败"
                return
            }

            for try await line in bytes.lines {
                guard line.hasPrefix("data: "),
                      line != "data: [DONE]" else { continue }
                let jsonStr = String(line.dropFirst(6))
                guard let d = jsonStr.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let choices = obj["choices"] as? [[String: Any]],
                      let delta = choices.first?["delta"] as? [String: Any],
                      let token = delta["content"] as? String else { continue }

                accumulated += token

                // 检测JSON开始
                if accumulated.contains("{\"danger") { inJSON = true }

                if !inJSON {
                    // ✅ 关键：每积累一个完整句子立即送TTS（不等全部完成）
                    let speakable = accumulated
                    let newChars = speakable.count - spokenUpTo
                    let isEndOfSentence = token.contains("，") || token.contains("。") || token.contains("！") || token.contains("\n")

                    if isEndOfSentence && newChars >= 4 {
                        let sentence = String(speakable.dropFirst(min(spokenUpTo, speakable.count)))
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !sentence.isEmpty {
                            let isUrgent = sentence.contains("注意") || sentence.contains("危险")
                            Task { await self.ttsSpeak(sentence, urgent: isUrgent) }
                        }
                        spokenUpTo = speakable.count
                    }
                } else {
                    jsonBuffer += token
                }

                // 实时更新UI文字
                let display = String(accumulated.prefix(100))
                await MainActor.run { self.sceneDescription = display }
            }
        } catch {
            sceneDescription = "流式请求中断"
            return
        }

        // 处理剩余文字（最后一句）
        if spokenUpTo < accumulated.count && !inJSON {
            let lastRaw = String(accumulated.dropFirst(min(spokenUpTo, accumulated.count)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let last = lastRaw.components(separatedBy: "{").first ?? ""
            if last.count >= 2 {
                let urgent = last.contains("注意") || last.contains("危险")
                Task { await self.ttsSpeak(last, urgent: urgent) }
            }
        }

        // 解析JSON尾部
        if !jsonBuffer.isEmpty { parseStreamJSON(jsonBuffer) }
    }

    // MARK: - 后端代理流式（当没有 OPENAI_API_KEY 时）
    @discardableResult
    private func streamViaBackend(body: [String: Any], mode: AnalyzeMode) async -> Bool {
        let backendURL = AppConfig.API.apiBase.trimmingCharacters(in: .init(charactersIn: "/"))
            + "/vision/stream"
        guard let url = URL(string: backendURL) else {
            sceneDescription = "后端地址无效"
            visualDecisionLevel = .caution
            visualDecisionText = "执行决策：视觉后端地址无效，等待重新配置。"
            return false
        }

        var req = URLRequest(url: url, timeoutInterval: 18)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        var accumulated = ""
        var spokenUpTo = 0
        var hasAnyToken = false
        var receivedDone = false

        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                sceneDescription = "视觉分析服务暂不可用"
                visualDecisionLevel = .caution
                visualModeText = "OFFLINE"
                visualDecisionText = "执行决策：视觉后端未返回成功，尝试备用分析。"
                return false
            }

            for try await line in bytes.lines {
                guard line.hasPrefix("data: ") else { continue }

                let js = String(line.dropFirst(6))
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if js == "[DONE]" {
                    receivedDone = true
                    break
                }

                // 后端错误事件
                if js.contains("\"error\"") && !js.contains("\"choices\"") {
                    visualDecisionLevel = .caution
                    visualModeText = "ERROR"
                    visualDecisionText = "执行决策：视觉模型返回错误，尝试备用分析。"
                    return false
                }

                guard let d = js.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let choices = obj["choices"] as? [[String: Any]],
                      let delta = choices.first?["delta"] as? [String: Any],
                      let token = delta["content"] as? String else { continue }

                hasAnyToken = true
                accumulated += token

                // 实时 UI：只显示 JSON 之前的自然语言
                let naturalText = extractNaturalTextBeforeJSON(accumulated)
                if !naturalText.isEmpty {
                    sceneDescription = String(naturalText.prefix(160))
                }

                // 每个完整短句立即播报
                let isEnd = token.contains("，") || token.contains("。") || token.contains("！") || token.contains("\\n")
                if isEnd && (accumulated.count - spokenUpTo) >= 4 {
                    let s = String(accumulated.dropFirst(min(spokenUpTo, accumulated.count)))
                        .components(separatedBy: "{")
                        .first?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !s.isEmpty {
                        Task { await self.ttsSpeak(s, urgent: s.contains("注意") || s.contains("危险")) }
                    }
                    spokenUpTo = accumulated.count
                }

                // 如果 JSON 已经完整，先解析一次，让视觉大脑尽早从“初始化”进入“决策”
                if let obj = extractFirstJSONObject(from: accumulated) {
                    applyVisionJSON(obj, mode: mode)
                } else {
                    rebuildCognitiveStateFromCurrentScene(mode: mode)
                }
            }

            if spokenUpTo < accumulated.count {
                let tail = String(accumulated.dropFirst(min(spokenUpTo, accumulated.count)))
                    .components(separatedBy: "{")
                    .first?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if tail.count >= 2 {
                    Task { await self.ttsSpeak(tail, urgent: tail.contains("注意") || tail.contains("危险")) }
                }
            }

            if let obj = extractFirstJSONObject(from: accumulated) {
                applyVisionJSON(obj, mode: mode)
            } else if !accumulated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sceneDescription = extractNaturalTextBeforeJSON(accumulated)
                rebuildCognitiveStateFromCurrentScene(mode: mode)
            }

            return hasAnyToken || receivedDone
        } catch {
            sceneDescription = "视觉网络中断，等待下一帧"
            visualDecisionLevel = .caution
            visualModeText = "RETRY"
            visualDecisionText = "执行决策：网络中断，保持本地观察并等待下一帧。"
            return false
        }
    }

    // MARK: - 非流式备用分析
    private func analyzeViaBackendFallback(body: [String: Any], mode: AnalyzeMode) async {
        let backendURL = AppConfig.API.apiBase.trimmingCharacters(in: .init(charactersIn: "/"))
            + "/vision/analyze"
        guard let url = URL(string: backendURL) else { return }

        var req = URLRequest(url: url, timeoutInterval: 18)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                if sceneDescription.isEmpty {
                    sceneDescription = "视觉后端暂不可用，下一帧继续重试"
                }
                rebuildCognitiveStateFromCurrentScene(mode: mode)
                return
            }

            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                rebuildCognitiveStateFromCurrentScene(mode: mode)
                return
            }

            if let text = obj["text"] as? String {
                if let j = extractFirstJSONObject(from: text) {
                    applyVisionJSON(j, mode: mode)
                } else {
                    sceneDescription = extractNaturalTextBeforeJSON(text)
                    rebuildCognitiveStateFromCurrentScene(mode: mode)
                }
            } else if let content = obj["content"] as? [[String: Any]],
                      let firstText = content.first?["text"] as? String {
                if let j = extractFirstJSONObject(from: firstText) {
                    applyVisionJSON(j, mode: mode)
                } else {
                    sceneDescription = extractNaturalTextBeforeJSON(firstText)
                    rebuildCognitiveStateFromCurrentScene(mode: mode)
                }
            } else {
                applyVisionJSON(obj, mode: mode)
            }
        } catch {
            if sceneDescription.isEmpty {
                sceneDescription = "视觉分析连接失败，等待下一帧"
            }
            rebuildCognitiveStateFromCurrentScene(mode: mode)
        }
    }

    // MARK: - Vision result parsing helpers
    private func extractNaturalTextBeforeJSON(_ raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let idx = cleaned.firstIndex(of: "{") else { return cleaned }
        return String(cleaned[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractFirstJSONObject(from raw: String) -> [String: Any]? {
        let cleaned = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")

        guard let start = cleaned.firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var escape = false
        var idx = start

        while idx < cleaned.endIndex {
            let ch = cleaned[idx]

            if inString {
                if escape {
                    escape = false
                } else if ch == "\\" {
                    escape = true
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                if ch == "\"" {
                    inString = true
                } else if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        let jsonString = String(cleaned[start...idx])
                        if let data = jsonString.data(using: .utf8),
                           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            return obj
                        }
                        return nil
                    }
                }
            }

            idx = cleaned.index(after: idx)
        }

        return nil
    }

    private func applyVisionJSON(_ obj: [String: Any], mode: AnalyzeMode) {
        let desc = (obj["desc"] as? String)
            ?? (obj["scene"] as? String)
            ?? (obj["summary"] as? String)
            ?? (obj["text"] as? String)
            ?? extractNaturalTextBeforeJSON(sceneDescription)

        let danger = (obj["danger"] as? String) ?? ""
        let decision = (obj["decision"] as? String) ?? ""
        let memory = (obj["memory"] as? String) ?? ""
        let speedLim = obj["speed_limit"] as? Int
        let laneWarn = (obj["lane"] as? Bool) ?? (obj["lane_warning"] as? Bool) ?? false

        if !desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sceneDescription = desc
        }
        speedLimit = speedLim
        laneWarning = laneWarn

        var newDetections: [VisionDetection] = []

        if let objects = obj["objects"] as? [[String: Any]] {
            for (i, item) in objects.prefix(8).enumerated() {
                let label = (item["label"] as? String)
                    ?? (item["name"] as? String)
                    ?? (item["object"] as? String)
                    ?? "目标"
                let risk = (item["risk"] as? String) ?? "caution"
                let conf = Float((item["confidence"] as? Double) ?? 0.82)
                let color: Color = risk == "danger" ? Color(hex: "#FF3B30")
                    : (risk == "safe" ? Color(hex: "#00E5FF") : Color(hex: "#FF9F0A"))

                newDetections.append(
                    VisionDetection(
                        label: label,
                        confidence: conf,
                        normalizedRect: CGRect(
                            x: 0.10 + Double(i % 4) * 0.18,
                            y: 0.22 + Double(i / 4) * 0.16,
                            width: 0.16,
                            height: 0.12
                        ),
                        color: color
                    )
                )
            }
        }

        if !newDetections.isEmpty {
            detections = newDetections
            confidence = newDetections.first?.confidence ?? 0.82
        }

        if !danger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            dangerAlert = danger
            visualDecisionLevel = .danger
            visualModeText = "DECISION"
            visualDecisionText = "执行决策：立即提醒，\(danger)"
            speakUrgent("注意，" + danger)
        } else {
            dangerAlert = nil
            if laneWarn || speedLim != nil {
                visualDecisionLevel = .caution
                visualModeText = "PERCEPTION"
            } else {
                visualDecisionLevel = .safe
                visualModeText = "MEMORY"
            }
            if !decision.isEmpty {
                visualDecisionText = "执行决策：" + decision
            }
        }

        if let objects = obj["objects"] as? [[String: Any]], !objects.isEmpty {
            let now = Date()
            for (i, item) in objects.prefix(8).enumerated() {
                let label = (item["label"] as? String)
                    ?? (item["name"] as? String)
                    ?? (item["object"] as? String)
                    ?? "目标"
                let direction = (item["direction"] as? String)
                    ?? (i == 0 ? "前方" : (i % 2 == 0 ? "左前方" : "右前方"))
                let risk = (item["risk"] as? String) ?? "caution"
                let conf = Float((item["confidence"] as? Double) ?? 0.82)

                let obj = SpatialMemoryObject(
                    label: label,
                    direction: direction,
                    risk: risk,
                    confidence: conf,
                    lastSeenAt: now
                )
                if let old = spatialMemory.firstIndex(where: { $0.label == obj.label && $0.direction == obj.direction }) {
                    spatialMemory[old] = obj
                } else {
                    spatialMemory.append(obj)
                }
            }
            spatialMemory = spatialMemory
                .filter { Date().timeIntervalSince($0.lastSeenAt) < 60 }
                .sorted { $0.lastSeenAt > $1.lastSeenAt }
                .prefix(12)
                .map { $0 }
        }

        if !memory.isEmpty && spatialMemory.isEmpty {
            visualDecisionText = visualDecisionText.isEmpty ? "执行决策：继续观察外部世界。" : visualDecisionText
        }

        RobotPerceptionStore.shared.update(
            sceneDescription: sceneDescription,
            objects: detections.map { $0.label },
            decision: decision.isEmpty ? visualDecisionText : decision,
            confidence: Double(confidence)
        )

        rebuildCognitiveStateFromCurrentScene(mode: mode)
    }

    // MARK: - OpenAI TTS（比AVSpeech自然，并行合成）
    private func ttsSpeak(_ text: String, urgent: Bool) async {
        guard isSpeaking || urgent else { return }

        // 危险警告直接用AVSpeech（最快，无需网络）
        if urgent {
            await MainActor.run {
                self.dangerAlert = text
                self.speakUrgent(text)
            }
            return
        }

        // 普通播报：后端 /vision/tts（OpenAI TTS-1，nova音色）
        let body: [String: Any] = [
            "model": "tts-1",          // tts-1 延迟最低，tts-1-hd 更好但慢
            "input": text,
            "voice": "nova",           // nova = 女声，接近中文TTS风格
            "speed": 1.1,
            "response_format": "mp3"
        ]

        // 走后端 /vision/tts 代理（不需要设备上有 OpenAI Key）
        let backendTTSURL = AppConfig.API.apiBase.trimmingCharacters(in: .init(charactersIn: "/"))
            + "/vision/tts"
        guard let ttsURL = URL(string: backendTTSURL) else {
            await MainActor.run { self.speakScene(text) }
            return
        }
        var req = URLRequest(url: ttsURL, timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (audioData, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else {
            // TTS失败fallback到本地AVSpeech
            await MainActor.run { self.speakScene(text) }
            return
        }

        await MainActor.run {
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback,
                    mode: .voicePrompt, options: [.duckOthers, .mixWithOthers])
                try AVAudioSession.sharedInstance().setActive(true)
                self.ttsPlayer = try AVAudioPlayer(data: audioData)
                self.ttsPlayer?.play()
            } catch {
                self.speakScene(text)
            }
        }
    }

    // MARK: - 解析流式JSON尾部
    private func parseStreamJSON(_ raw: String) {
        if let obj = extractFirstJSONObject(from: raw) {
            applyVisionJSON(obj, mode: .driving)
        }
    }

    // MARK: - Parse JSON result
    private func parseVisionResult(_ raw: String) {
        if let obj = extractFirstJSONObject(from: raw) {
            applyVisionJSON(obj, mode: .manual)
        } else {
            let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            sceneDescription = clean
            rebuildCognitiveStateFromCurrentScene(mode: .manual)
        }
    }

    // MARK: - Visual Cognition / Spatial Memory / Decision
    private func rebuildCognitiveStateFromCurrentScene(mode: AnalyzeMode) {
        let text = (sceneDescription + " " + detections.map { $0.label }.joined(separator: " ")).lowercased()
        let now = Date()

        var candidates: [(label: String, risk: String)] = []
        let objectRules: [(keys: [String], label: String, risk: String)] = [
            (["行人", "person", "pedestrian", "人"], "行人", "danger"),
            (["车辆", "车", "car", "vehicle", "truck"], "车辆", "caution"),
            (["路口", "intersection", "crosswalk", "斑马线"], "路口", "caution"),
            (["红灯", "绿灯", "信号灯", "traffic light"], "信号灯", "caution"),
            (["障碍", "施工", "cone", "路障", "obstacle"], "障碍物", "danger"),
            (["限速", "speed limit"], "限速牌", "caution"),
            (["车道", "lane"], "车道线", "safe")
        ]

        for rule in objectRules where rule.keys.contains(where: { text.contains($0.lowercased()) }) {
            candidates.append((rule.label, rule.risk))
        }
        for det in detections.prefix(6) {
            if !candidates.contains(where: { $0.label == det.label }) {
                candidates.append((det.label, det.label.contains("行人") || det.label.contains("障碍") ? "danger" : "caution"))
            }
        }

        // 现在没有深度传感器，先用画面语义构建“近前方/前方/侧方”的轻量空间记忆。
        let newObjects = candidates.prefix(6).enumerated().map { idx, c in
            SpatialMemoryObject(
                label: c.label,
                direction: idx == 0 ? "前方" : (idx % 2 == 0 ? "左前方" : "右前方"),
                risk: c.risk,
                confidence: detections.first(where: { $0.label == c.label })?.confidence ?? 0.78,
                lastSeenAt: now
            )
        }

        if !newObjects.isEmpty {
            // 合并同名对象，保留最近看到的位置，形成短时空间记忆。
            for obj in newObjects {
                if let i = spatialMemory.firstIndex(where: { $0.label == obj.label }) {
                    spatialMemory[i] = obj
                } else {
                    spatialMemory.append(obj)
                }
            }
            spatialMemory = spatialMemory
                .filter { now.timeIntervalSince($0.lastSeenAt) < 45 }
                .sorted { $0.lastSeenAt > $1.lastSeenAt }
                .prefix(10)
                .map { $0 }
        }

        let currentDangerText = dangerAlert ?? ""
        let hasDangerSignal = !currentDangerText.isEmpty
            || text.contains("注意")
            || spatialMemory.contains(where: { $0.risk == "danger" })

        if hasDangerSignal {
            visualDecisionLevel = .danger
            visualDecisionText = !currentDangerText.isEmpty
                ? "执行决策：立即提醒，\(currentDangerText)"
                : "执行决策：前方有高风险目标，立即提醒并持续观察。"
            visualModeText = "DECISION"
        } else if laneWarning || speedLimit != nil || spatialMemory.contains(where: { $0.risk == "caution" }) {
            visualDecisionLevel = .caution
            if let s = speedLimit {
                visualDecisionText = "执行决策：识别到限速 \(s)，提醒驾驶者控制速度。"
            } else if laneWarning {
                visualDecisionText = "执行决策：车道状态不稳定，提醒注意车道。"
            } else {
                visualDecisionText = "执行决策：保持观察，必要时低频播报路况。"
            }
            visualModeText = "PERCEPTION"
        } else if !sceneDescription.isEmpty {
            visualDecisionLevel = .safe
            visualDecisionText = "执行决策：当前无明显危险，继续构建外部世界模型。"
            visualModeText = "MEMORY"
        } else {
            visualDecisionLevel = .observing
            visualDecisionText = "正在建立视觉空间模型…"
            visualModeText = "PERCEPTION"
        }
    }

    // MARK: - TTS
    private func speakUrgent(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(identifier: "com.apple.voice.enhanced.zh-CN.Tingting")
               ?? AVSpeechSynthesisVoice(language: "zh-CN")
        u.rate       = 0.58
        u.pitchMultiplier = 1.15
        try? AVAudioSession.sharedInstance().setCategory(.playback,
             mode: .voicePrompt, options: [.duckOthers, .mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        synthesizer.speak(u)
    }

    func toggleSpeak() {
        if isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
            isSpeaking = false
        } else {
            isSpeaking = true
            if !sceneDescription.isEmpty { speakScene(sceneDescription) }
        }
    }

    private func speakScene(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(identifier: "com.apple.voice.enhanced.zh-CN.Tingting")
               ?? AVSpeechSynthesisVoice(language: "zh-CN")
        u.rate = 0.52
        synthesizer.speak(u)
    }

    // MARK: - Torch / Flip
    func toggleTorch(on: Bool) {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        try? device.lockForConfiguration()
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
    }

    func flipCamera() {
        currentCameraPos = (currentCameraPos == .back) ? .front : .back
        let pos = currentCameraPos
        Task { await configureSession(position: pos) }
    }

    // MARK: - 行车记录仪
    func startRecording() {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("dashcam_\(Date().timeIntervalSince1970).mov")
        recordingURL = url
        movieOutput.startRecording(to: url, recordingDelegate: RecordingDelegate())
        isRecording = true
    }

    func stopRecording() {
        movieOutput.stopRecording()
        isRecording = false
    }
}

// MARK: - Photo Capture Delegate
private class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    let completion: (UIImage?) -> Void
    init(completion: @escaping (UIImage?) -> Void) { self.completion = completion }
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let data = photo.fileDataRepresentation(), let img = UIImage(data: data) {
            completion(img)
        } else {
            completion(nil)
        }
    }
}

// MARK: - Recording Delegate
private class RecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL,
                    from connections: [AVCaptureConnection], error: Error?) {}
}

// MARK: - CameraPreviewView
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ uiView: PreviewUIView, context: Context) {}
    class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}





