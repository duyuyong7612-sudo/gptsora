// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-c4526d08079ef075f22e4b245f35100b8bd1409c40d39535499d46c85c9f7eca"
// Source-SHA256: "8117e66a5f0e4b5cda19bc3d6a6e93cc85e5cd12f9a6d5f86a31c018edda09cf"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI
import Combine
import Network

// MARK: - 屏幕流显示视图
// 接收 Mac 推来的实时屏幕画面
// 两种模式：
//   1. MJPEG HTTP 直连（局域网，低延迟）
//   2. WebSocket 中继（通过后端，支持远程）
//
// 智能路由：
//   - 先快速探测局域网 Mac 是否可达（300ms 超时）
//   - 可达 → MJPEG 直连（秒开）
//   - 不可达 → 直接 WebSocket 中继（不卡 3 秒）

struct ScreenStreamView: View {

    let userKey: String
    let backendURL: String   // "https://your-backend.example.com"

    @StateObject private var vm: ScreenStreamVM

    init(
        userKey: String,
        backendURL: String = "https://your-backend.example.com"
    ) {
        self.userKey    = userKey
        self.backendURL = backendURL
        _vm = StateObject(wrappedValue: ScreenStreamVM(
            userKey:    userKey,
            backendURL: backendURL
        ))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let img = vm.currentFrame {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .ignoresSafeArea()
                    .scaleEffect(vm.scale)
                    .gesture(MagnificationGesture()
                        .onChanged { v in vm.scale = max(1, min(4, v)) }
                        .onEnded   { _ in
                            withAnimation(.spring()) { vm.scale = 1.0 }
                        }
                    )
            } else {
                VStack(spacing: 16) {
                    if vm.macOnline {
                        ProgressView()
                            .tint(.white)
                        Text("正在接收画面...")
                            .foregroundStyle(.white.opacity(0.7))
                    } else {
                        Image(systemName: "display.slash")
                            .font(.system(size: 48))
                            .foregroundStyle(.white.opacity(0.4))
                        Text("Mac 未连接")
                            .foregroundStyle(.white.opacity(0.6))
                        Text("在 Mac 上运行 adu_screen_streamer.py")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.4))

                        // 显示当前连接模式
                        if !vm.currentMode.isEmpty {
                            Text(vm.currentMode)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.3))
                        }
                    }
                }
            }

            // 顶部状态栏
            VStack {
                HStack {
                    // 状态指示
                    HStack(spacing: 6) {
                        Circle()
                            .fill(vm.macOnline ? .green : .red)
                            .frame(width: 8, height: 8)
                        Text(vm.macOnline ? "实时" : "离线")
                            .font(.caption.bold())
                            .foregroundStyle(.white)

                        if vm.fps > 0 {
                            Text("\(vm.fps, specifier: "%.1f")fps")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                        }

                        // 连接模式徽章
                        if !vm.currentMode.isEmpty {
                            Text(vm.currentMode)
                                .font(.caption2.bold())
                                .foregroundStyle(.white.opacity(0.8))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(vm.currentMode == "局域网" ? .blue.opacity(0.6) : .orange.opacity(0.6))
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.5))
                    .clipShape(Capsule())

                    Spacer()

                    // 截图按钮
                    Button {
                        vm.saveSnapshot()
                    } label: {
                        Image(systemName: "camera.fill")
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                }
                .padding()

                Spacer()

                // 底部工具栏
                HStack(spacing: 20) {
                    // 质量选择
                    Menu {
                        Button("低质量 (省流量)") { vm.setQuality(.low) }
                        Button("标准质量")        { vm.setQuality(.medium) }
                        Button("高质量")          { vm.setQuality(.high) }
                    } label: {
                        Label("质量", systemImage: "dial.medium")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.5))
                            .clipShape(Capsule())
                    }

                    Spacer()

                    // 延迟显示
                    if vm.latencyMs > 0 {
                        Text("延迟 \(vm.latencyMs)ms")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .padding()
            }
        }
        .onAppear  { vm.start() }
        .onDisappear { vm.stop() }
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle("Mac 屏幕")
    }
}


// MARK: - ViewModel

enum StreamQuality { case low, medium, high }

@MainActor
class ScreenStreamVM: NSObject, ObservableObject, URLSessionDataDelegate {

    @Published var currentFrame: UIImage? = nil
    @Published var macOnline:    Bool = false
    @Published var fps:          Double = 0
    @Published var latencyMs:    Int = 0
    @Published var scale:        CGFloat = 1.0
    @Published var currentMode:  String = ""   // "局域网" | "云端"

    private let userKey:    String
    private let backendURL: String

    // WebSocket（通过后端中继）
    private var wsTask:   URLSessionWebSocketTask?
    private var wsSession: URLSession?
    private var reconnectAttempts: Int = 0

    // MJPEG（局域网直连）
    private var mjpegTask:    URLSessionDataTask?
    private var mjpegSession: URLSession?
    private var mjpegBuffer:  Data = Data()
    private var useMJPEG:     Bool = false

    // 局域网地址（Mac 的本地 IP）— 不随公网部署改变
    private let mjpegURL: String = "http://YOUR_LAN_IP:7788/stream"
    private let mjpegProbeURL: String = "http://YOUR_LAN_IP:7788/health"

    // 帧率统计
    private var frameCount:  Int = 0
    private var fpsTimer:    Timer?
    private var lastFrameTS: Date = Date()

    // 停止标志（避免 onDisappear 后还重连）
    private var stopped: Bool = false

    init(userKey: String, backendURL: String) {
        self.userKey    = userKey
        self.backendURL = backendURL
        super.init()
    }

    // ═══════════════════════════════════════════
    // 启停
    // ═══════════════════════════════════════════

    func start() {
        stopped = false
        reconnectAttempts = 0

        // 智能路由：先快速探测局域网，不行就直接走 WebSocket
        Task { [weak self] in
            guard let self else { return }
            let localReachable = await self.probeLocalMac()
            await MainActor.run {
                if self.stopped { return }
                if localReachable {
                    self.currentMode = "局域网"
                    self.tryMJPEG()
                } else {
                    self.currentMode = "云端"
                    self.connectWebSocket()
                }
                self.startFPSTimer()
            }
        }
    }

    func stop() {
        stopped = true
        wsTask?.cancel()
        mjpegTask?.cancel()
        fpsTimer?.invalidate()
        fpsTimer = nil
    }

    // ═══════════════════════════════════════════
    // 局域网探测（300ms 超时）
    // ═══════════════════════════════════════════

    private func probeLocalMac() async -> Bool {
        guard let url = URL(string: mjpegProbeURL) else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 0.3   // 300ms 超时
        req.httpMethod = "GET"

        do {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 0.3
            cfg.timeoutIntervalForResource = 0.5
            let s = URLSession(configuration: cfg)
            let (_, resp) = try await s.data(for: req)
            if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                return true
            }
        } catch {
            // 超时/不通 → 不在局域网
        }
        return false
    }

    // ═══════════════════════════════════════════
    // MJPEG 直连模式
    // ═══════════════════════════════════════════

    private func tryMJPEG() {
        guard let url = URL(string: mjpegURL) else { return }
        mjpegSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        mjpegTask = mjpegSession?.dataTask(with: url)
        mjpegTask?.resume()
        useMJPEG = true
        macOnline = true

        // 3秒后如果没收到帧（可能 streamer 没跑），切到云端
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            if self.stopped { return }
            if self.currentFrame == nil {
                self.mjpegTask?.cancel()
                self.useMJPEG = false
                self.currentMode = "云端"
                self.connectWebSocket()
            }
        }
    }

    // URLSessionDataDelegate — MJPEG 数据接收
    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        Task { @MainActor in
            self.mjpegBuffer.append(data)
            self.parseMJPEG()
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task { @MainActor in
            if self.useMJPEG && error != nil {
                self.macOnline = false
                self.useMJPEG = false
                self.currentMode = "云端"
                if !self.stopped {
                    self.connectWebSocket()
                }
            }
        }
    }

    private func parseMJPEG() {
        // MJPEG 边界：--frame\r\nContent-Type: image/jpeg\r\n\r\n{JPEG}\r\n
        let jpegStart = Data("\r\n\r\n".utf8)
        let jpegEnd   = Data("\r\n--frame".utf8)

        while true {
            guard let startRange = mjpegBuffer.range(of: jpegStart),
                  let endRange   = mjpegBuffer.range(of: jpegEnd, in: startRange.upperBound..<mjpegBuffer.endIndex)
            else { break }

            let jpegData = mjpegBuffer[startRange.upperBound..<endRange.lowerBound]
            if let img = UIImage(data: jpegData) {
                currentFrame = img
                updateFPS()
            }
            mjpegBuffer = Data(mjpegBuffer[endRange.lowerBound...])
        }

        // 防止缓冲区无限增长
        if mjpegBuffer.count > 5 * 1024 * 1024 {
            mjpegBuffer = Data()
        }
    }

    // ═══════════════════════════════════════════
    // WebSocket 中继模式（经过公网后端）
    // ═══════════════════════════════════════════

    private func connectWebSocket() {
        // https:// → wss://  /  http:// → ws://
        var wsBase = backendURL
        if wsBase.hasPrefix("https://") {
            wsBase = "wss://" + wsBase.dropFirst("https://".count)
        } else if wsBase.hasPrefix("http://") {
            wsBase = "ws://" + wsBase.dropFirst("http://".count)
        }
        let urlString = "\(wsBase)/ws/screen/subscribe/\(userKey)"
        guard let wsURL = URL(string: urlString) else {
            print("[ScreenStream] invalid ws URL: \(urlString)")
            return
        }

        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForRequest = 10
        wsSession = URLSession(configuration: cfg)
        wsTask = wsSession?.webSocketTask(with: wsURL)
        wsTask?.resume()

        // 可选：发个认证/标识消息
        let helloMsg: [String: Any] = [
            "type": "subscribe",
            "user_key": userKey,
            "client": "ios",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: helloMsg),
           let text = String(data: data, encoding: .utf8) {
            wsTask?.send(.string(text)) { _ in }
        }

        receiveWS()
    }

    private func receiveWS() {
        wsTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let msg):
                Task { @MainActor in
                    self.reconnectAttempts = 0   // 成功收到 → 重置
                    self.handleWSMessage(msg)
                }
                // 继续接收下一条
                Task { @MainActor in
                    if !self.stopped { self.receiveWS() }
                }
            case .failure(let err):
                Task { @MainActor in
                    self.macOnline = false
                    if self.stopped { return }

                    // 指数回退重连：1s, 2s, 4s, 8s, 最多 16s
                    self.reconnectAttempts = min(self.reconnectAttempts + 1, 5)
                    let delay = pow(2.0, Double(self.reconnectAttempts - 1))
                    print("[ScreenStream] WS error: \(err.localizedDescription), reconnect in \(delay)s")

                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    if !self.stopped {
                        self.connectWebSocket()
                    }
                }
            }
        }
    }

    private func handleWSMessage(_ msg: URLSessionWebSocketTask.Message) {
        switch msg {
        case .string(let text):
            guard let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }

            let type = json["type"] as? String ?? ""

            if type == "status" {
                macOnline = json["mac_online"] as? Bool ?? false
            } else if type == "frame" {
                if let b64 = json["data"] as? String,
                   let imgData = Data(base64Encoded: b64),
                   let img = UIImage(data: imgData) {
                    currentFrame = img
                    macOnline    = true
                    updateFPS()

                    // 计算延迟
                    if let ts = json["timestamp"] as? Double {
                        let lag = Date().timeIntervalSince1970 - ts
                        latencyMs = max(0, Int(lag * 1000))
                    }
                }
            } else if type == "error" {
                let reason = json["reason"] as? String ?? ""
                print("[ScreenStream] server error: \(reason)")
            }

        case .data(let data):
            // 直接二进制 JPEG
            if let img = UIImage(data: data) {
                currentFrame = img
                macOnline    = true
                updateFPS()
            }
        @unknown default:
            break
        }
    }

    // ═══════════════════════════════════════════
    // 工具方法
    // ═══════════════════════════════════════════

    private func startFPSTimer() {
        fpsTimer?.invalidate()
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.fps = Double(self.frameCount) / 2.0
                self.frameCount = 0
            }
        }
    }

    private func updateFPS() {
        frameCount += 1
        lastFrameTS = Date()
    }

    func setQuality(_ q: StreamQuality) {
        let quality: Int
        switch q {
        case .low:    quality = 30
        case .medium: quality = 60
        case .high:   quality = 85
        }
        let msg: [String: Any] = [
            "type": "control",
            "payload": ["quality": quality],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: msg),
           let text = String(data: data, encoding: .utf8) {
            wsTask?.send(.string(text)) { err in
                if let err = err {
                    print("[ScreenStream] setQuality failed: \(err.localizedDescription)")
                }
            }
        }
    }

    func saveSnapshot() {
        guard let img = currentFrame else { return }
        UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
    }
}


// MARK: - 预览
#Preview {
    NavigationStack {
        ScreenStreamView(
            userKey:    "preview-user",
            backendURL: "http://127.0.0.1:8000"
        )
    }
}

