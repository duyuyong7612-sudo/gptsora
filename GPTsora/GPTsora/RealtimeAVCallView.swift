
// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-760014cb12b1189bb098d2afb797e3f812dc61c344e3d61b57d738fd24afe2b2"
// Source-SHA256: "ce1cade133bd4e0b4a7f052b0104f594ed43dd4e193e7d12e57d57e4d3f9be3c"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI
import AVFoundation
import Combine
import UIKit
import CoreImage
import ImageIO

struct RealtimeAVCallView: View {

    let apiBase: String
    @ObservedObject var rt: RealtimeBridge
    @Binding var messages: [ChatMessage]
    let onClose: () -> Void

    init(
        apiBase: String = AppConfig.API.apiBase,
        rt: RealtimeBridge,
        messages: Binding<[ChatMessage]> = .constant([]),
        onClose: @escaping () -> Void
    ) {
        self.apiBase = apiBase
        self.rt = rt
        self._messages = messages
        self.onClose = onClose
    }

    @StateObject private var camera = CameraStreamer()
    @State private var isSendingFrames = true

    // 三档：你要更实时就选 turbo（4fps）
    private enum VideoPreset: String, CaseIterable {
        case eco = "省电"
        case balanced = "均衡"
        case turbo = "极速"

        var fps: Double {
            switch self {
            case .eco: return 1.0
            case .balanced: return 2.0
            case .turbo: return 4.0
            }
        }

        var maxDimension: CGFloat {
            switch self {
            case .eco: return 384
            case .balanced: return 512
            case .turbo: return 640
            }
        }

        var jpegQuality: CGFloat {
            switch self {
            case .eco: return 0.45
            case .balanced: return 0.55
            case .turbo: return 0.62
            }
        }
    }

    @State private var preset: VideoPreset = .balanced

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if camera.isRunning {
                CameraPreview(session: camera.session)
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 10) {
                    Text(camera.permissionGranted ? "摄像头启动中…" : "摄像头权限未开启")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)

                    if let err = camera.lastError, !err.isEmpty {
                        Text(err)
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.78))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 18)
                    } else if !camera.permissionGranted {
                        Text("请在系统设置允许摄像头访问")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.75))
                    }
                }
            }

            VStack {
                topBar
                Spacer()
                transcriptOverlay
                bottomBar
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 16)
        }
        .task {
            rt.configure(apiBase: apiBase, clientId: ClientIdentity.shared.clientId)

            // ✅ 视频通话页对三档付费套餐开放：
            //    6.1(pro) → qwen（阿里官方 Omni Realtime，视频=图片帧 input_image_buffer.append）
            //    6.2(ultra) / 6.2 Pro(coder) → openai（GPT Realtime，视频=图片帧 conversation.item.create）
            //    provider 进页前已由 HomeChatView.configureRealtimeForCurrentPlan 设好；
            //    这里只在 provider 为空 / 残留自部署(qwen_selfhost/minicpm) 时按 plan 兜底纠正，
            //    绝不再一刀切强制 openai（否则 6.1 会被错误塞进 GPT Realtime）。
            let svc = RealtimeAVService.shared
            let _prov = (svc.preferredProvider ?? "").lowercased()
            if _prov != "openai" && _prov != "qwen" {
                let corrected = (svc.realtimePlan == "ultra" || svc.realtimePlan == "coder") ? "openai" : "qwen"
                print("[Realtime][CallView] WARN provider=\(svc.preferredProvider ?? "nil") plan=\(svc.realtimePlan ?? "nil") -> 兜底改为 \(corrected)")
                svc.preferredProvider = corrected
            }
            print("[Realtime][CallView] startAV plan=\(svc.realtimePlan ?? "nil") provider=\(svc.preferredProvider ?? "nil") want_video=true preset=\(preset.rawValue)")

            // 进入音视频页：建立 audio+events 通道（并允许注入图片帧）
            rt.startAV()
            rt.setImageStreamingEnabled(true)   // ✅ 确保图片流开启（service 内部图片 tick 随之启动）

            let ok = await camera.requestPermissionIfNeeded()
            guard ok else {
                print("[Realtime][CallView] camera permission not granted — 继续纯音频通话")
                return
            }

            // ✅ 帧注入不再以 rt.isConnected 为门：service 只缓存“最新帧”，真正发送由 service
            //    内部按 data channel(OpenAI) / WebSocket(Qwen) 是否就绪决定——未就绪时 droppable
            //    辅助帧自动丢弃、回合关键帧排队补发。之前 `guard rt.isConnected` 在 bridge 连接态
            //    发布稍慢/未随 AV 链路置位时会把所有帧丢光，导致三档（6.1/6.2/6.2pro）都没视频。
            camera.onJPEG = { data in
                guard isSendingFrames else { return }
                rt.sendCameraFrameJPEG(data)
            }

            applyPreset(preset)
        }
        .onChange(of: preset) { newValue in
            applyPreset(newValue)
        }
        .onDisappear {
            camera.stop()
            camera.onJPEG = nil
        }
    }

    private func applyPreset(_ p: VideoPreset) {
        // ✅ 同步告诉 service：图片流目标 fps（service 内部会做背压/丢帧）
        print("[OpenAIRealtime][CallView] camera frame preset=\(p) fps=\(p.fps) maxDim=\(Int(p.maxDimension)) q=\(p.jpegQuality)")
        rt.setImageStreamingFPS(p.fps)

        camera.start(
            position: .back,
            fps: p.fps,
            maxDimension: p.maxDimension,
            jpegQuality: p.jpegQuality
        )
    }

    private var topBar: some View {
        HStack {
            Button {
                HomeHaptics.light()
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            VStack(spacing: 2) {
                Text("音视频通话")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))
                Text(rt.isConnected ? "已连接" : "连接中…")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.75))
            }

            Spacer()

            Color.clear.frame(width: 40, height: 40)
        }
    }

    private var captionsTail: [ChatMessage] {
        let filtered = messages.filter { m in
            (m.role == .user || m.role == .assistant) &&
            !m.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return Array(filtered.suffix(4))
    }

    private var transcriptOverlay: some View {
        let tail = captionsTail

        return VStack(alignment: .leading, spacing: 8) {
            if !tail.isEmpty {
                ForEach(tail) { m in
                    Text((m.role == .user ? "你：" : "助手：") + m.text.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.92))
                        .lineLimit(m.role == .user ? 2 : 3)
                }
            } else {
                // fallback：如果父视图没传 messages，就用 Bridge 的临时字段
                if !rt.lastUser.isEmpty {
                    Text("你：\(rt.lastUser)")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.92))
                        .lineLimit(2)
                }
                if !rt.assistantLive.isEmpty {
                    Text("助手：\(rt.assistantLive)")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.92))
                        .lineLimit(3)
                }
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {

            Button {
                HomeHaptics.light()
                isSendingFrames.toggle()

                // 可选：完全停掉 service 的图片流（更省带宽）
                rt.setImageStreamingEnabled(isSendingFrames)
            } label: {
                Image(systemName: isSendingFrames ? "eye" : "eye.slash")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Button {
                HomeHaptics.light()
                camera.switchCamera()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Button {
                HomeHaptics.light()
                rt.toggleMute()
            } label: {
                Image(systemName: rt.isMuted ? "mic.slash" : "mic")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Button {
                HomeHaptics.light()
                rt.interruptResponse()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Menu {
                ForEach(VideoPreset.allCases, id: \.self) { p in
                    Button(p.rawValue) { preset = p }
                }
            } label: {
                Text(preset.rawValue)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(Color.white.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            Spacer()

            Button {
                HomeHaptics.light()
                rt.stop()
                onClose()
            } label: {
                Text("结束")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                    .background(Color(red: 0.0, green: 0.48, blue: 1.0))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - CameraStreamer (AVCapture -> JPEG)

final class CameraStreamer: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    @Published var permissionGranted: Bool = (AVCaptureDevice.authorizationStatus(for: .video) == .authorized)
    @Published var isRunning: Bool = false
    @Published var lastError: String? = nil

    let session = AVCaptureSession()

    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "camera.stream.queue", qos: .userInitiated)
    private let ciContext = CIContext()

    private var currentPosition: AVCaptureDevice.Position = .back

    private var lastSent: CFTimeInterval = 0
    private var minInterval: CFTimeInterval = 0.5

    private var cfgFPS: Double = 2.0
    private var cfgMaxDim: CGFloat = 512
    private var cfgJpegQ: CGFloat = 0.55

    var onJPEG: ((Data) -> Void)?

    func requestPermissionIfNeeded() async -> Bool {
        let st = AVCaptureDevice.authorizationStatus(for: .video)
        if st == .authorized {
            await MainActor.run { self.permissionGranted = true; self.lastError = nil }
            return true
        }
        if st == .denied || st == .restricted {
            await MainActor.run { self.permissionGranted = false; self.lastError = "摄像头权限被拒绝/受限" }
            return false
        }

        let ok = await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .video) { granted in
                cont.resume(returning: granted)
            }
        }
        await MainActor.run {
            self.permissionGranted = ok
            self.lastError = ok ? nil : "用户未授予摄像头权限"
        }
        return ok
    }

    func start(position: AVCaptureDevice.Position, fps: Double, maxDimension: CGFloat, jpegQuality: CGFloat) {
        currentPosition = position
        cfgFPS = fps
        cfgMaxDim = maxDimension
        cfgJpegQ = jpegQuality
        minInterval = fps <= 0 ? 0.5 : (1.0 / fps)

        lastError = nil

        queue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }

            self.session.beginConfiguration()
            self.session.sessionPreset = .vga640x480

            self.session.inputs.forEach { self.session.removeInput($0) }
            self.session.outputs.forEach { self.session.removeOutput($0) }

            guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
                self.session.commitConfiguration()
                DispatchQueue.main.async {
                    self.isRunning = false
                    self.lastError = "找不到摄像头设备"
                }
                return
            }

            do {
                try dev.lockForConfiguration()
                let target = max(10, min(30, Int32(max(12, fps * 3))))
                dev.activeVideoMinFrameDuration = CMTime(value: 1, timescale: target)
                dev.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: target)
                dev.unlockForConfiguration()
            } catch {}

            guard let input = try? AVCaptureDeviceInput(device: dev),
                  self.session.canAddInput(input) else {
                self.session.commitConfiguration()
                DispatchQueue.main.async {
                    self.isRunning = false
                    self.lastError = "无法创建摄像头输入（AVCaptureDeviceInput）"
                }
                return
            }
            self.session.addInput(input)

            self.output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            self.output.alwaysDiscardsLateVideoFrames = true
            self.output.setSampleBufferDelegate(self, queue: self.queue)

            guard self.session.canAddOutput(self.output) else {
                self.session.commitConfiguration()
                DispatchQueue.main.async {
                    self.isRunning = false
                    self.lastError = "无法添加摄像头输出（AVCaptureVideoDataOutput）"
                }
                return
            }
            self.session.addOutput(self.output)

            if let conn = self.output.connection(with: .video) {
                if conn.isVideoOrientationSupported { conn.videoOrientation = .portrait }
                if conn.isVideoMirroringSupported { conn.isVideoMirrored = (position == .front) }
            }

            self.session.commitConfiguration()
            self.session.startRunning()

            DispatchQueue.main.async {
                self.isRunning = self.session.isRunning
                if !self.session.isRunning {
                    self.lastError = "session.startRunning 失败（检查权限/Info.plist/真机相机）"
                }
            }
        }
    }

    func stop() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    func switchCamera() {
        let newPos: AVCaptureDevice.Position = (currentPosition == .back) ? .front : .back
        start(position: newPos, fps: cfgFPS, maxDimension: cfgMaxDim, jpegQuality: cfgJpegQ)
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {

        let now = CACurrentMediaTime()
        if now - lastSent < minInterval { return }
        lastSent = now

        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ci = CIImage(cvPixelBuffer: pb)

        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }
        let scaled = scaleCGImage(cg, maxDimension: cfgMaxDim)

        guard let jpeg = encodeJPEG(scaled, quality: cfgJpegQ) else { return }
        onJPEG?(jpeg)
    }

    private func scaleCGImage(_ img: CGImage, maxDimension: CGFloat) -> CGImage {
        let w = CGFloat(img.width)
        let h = CGFloat(img.height)
        let maxSide = max(w, h)
        guard maxSide > maxDimension else { return img }

        let s = maxDimension / maxSide
        let nw = max(1, Int(w * s))
        let nh = max(1, Int(h * s))

        let cs = img.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: nw,
            height: nh,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return img }

        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return ctx.makeImage() ?? img
    }

    private func encodeJPEG(_ img: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, img, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}

// MARK: - Preview（保证不黑屏）

// ✅ 修复：这里不能是 private，否则 makeUIView/updateUIView 的签名会暴露 private 类型
final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.videoGravity = .resizeAspectFill
        v.previewLayer.session = session
        if let conn = v.previewLayer.connection {
            if conn.isVideoOrientationSupported { conn.videoOrientation = .portrait }
        }
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.session = session
        if let conn = uiView.previewLayer.connection {
            if conn.isVideoOrientationSupported { conn.videoOrientation = .portrait }
        }
    }
}



