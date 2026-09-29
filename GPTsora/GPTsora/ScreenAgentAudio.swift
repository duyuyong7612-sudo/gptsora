// ScreenAgentAudio.swift
// 阿杜 屏幕共享 Agent · 音频管理
//
// 职责:
//   1. 麦克风录音(VoiceProcessingIO 自带 AEC,跟扬声器外放不冲突)
//   2. 录音 PCM16 24kHz 转 base64 → 回调出去
//   3. 收 PCM24 → 队列播放
//
// 关键点:
//   - 用 AVAudioEngine + voiceProcessingEnabled 实现回声消除
//   - 录音格式: PCM 16-bit, 24kHz, 单声道(Qwen 标准)
//   - 播放格式: PCM 24-bit, 24kHz, 单声道(Qwen 输出)

// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-c1b7d12c6a844602c8d02c888a23390094cdbc3a7b29743554f32a9de2e3b48d"
// Source-SHA256: "bfcfabdbeff0cb3c0a6447c07a31ffa9a77b22f821f9bff97bfc7660620c2cf6"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation
import AVFoundation

@MainActor
final class ScreenAgentAudio: NSObject {

    // MARK: 公开

    /// 麦克风采到的 base64(PCM16, 24kHz, mono)
    var onMicData: ((String) -> Void)?

    private(set) var isMicRunning = false
    private(set) var isMuted = false

    // MARK: 私有

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                             sampleRate: 24000,
                                             channels: 1,
                                             interleaved: true)!

    // 播放
    private let playerNode = AVAudioPlayerNode()
    private let playerEngine = AVAudioEngine()
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                           sampleRate: 24000,
                                           channels: 1,
                                           interleaved: true)!
    private let playbackQueue = DispatchQueue(label: "screenagent.playback", qos: .userInteractive)

    // MARK: 生命周期

    override init() {
        super.init()
        // ⚠️ 修复闪退:init 里不再立刻配置 AVAudioSession 和启动 playerEngine
        // 因为此时主路径 Realtime 可能占着 AudioSession,会冲突
        // 改成:startMic() / playPCM24() 时惰性配置
    }

    /// 惰性配置 AVAudioSession。多次调用幂等。
    private var audioSessionConfigured = false
    private func ensureAudioSession() {
        guard !audioSessionConfigured else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            // 先让出(如果别的 Realtime 占着)
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            try session.setCategory(.playAndRecord,
                                    mode: .voiceChat,        // 回声消除关键
                                    options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: [.notifyOthersOnDeactivation])
            audioSessionConfigured = true
            print("[ScreenAgentAudio] audio session configured")
        } catch {
            print("[ScreenAgentAudio] session setup err: \(error)")
        }
    }

    // MARK: 录音

    func startMic() {
        guard !isMicRunning else { return }
        ensureAudioSession()
        setupPlayerIfNeeded()
        isMicRunning = true

        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)

        // 启用回声消除(系统级 AEC)
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            print("[ScreenAgentAudio] AEC enable err: \(error)")
        }

        converter = AVAudioConverter(from: inFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 2400, format: inFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.processInputBuffer(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
            print("[ScreenAgentAudio] mic started (in: \(inFormat.sampleRate)Hz → out: 24kHz)")
        } catch {
            print("[ScreenAgentAudio] engine start err: \(error)")
        }
    }

    private func processInputBuffer(_ buffer: AVAudioPCMBuffer) {
        guard !isMuted else { return }
        guard let converter else { return }

        let outCapacity = AVAudioFrameCount(targetFormat.sampleRate / 10)  // 100ms
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                                frameCapacity: outCapacity) else { return }

        var error: NSError?
        var fed = false
        converter.convert(to: outBuffer, error: &error) { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }

        if let e = error {
            print("[ScreenAgentAudio] convert err: \(e)")
            return
        }

        guard outBuffer.frameLength > 0,
              let i16 = outBuffer.int16ChannelData?[0] else { return }

        let byteCount = Int(outBuffer.frameLength) * 2
        let data = Data(bytes: i16, count: byteCount)
        let b64 = data.base64EncodedString()

        DispatchQueue.main.async { [weak self] in
            self?.onMicData?(b64)
        }
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        print("[ScreenAgentAudio] muted = \(muted)")
    }

    func stopMic() {
        guard isMicRunning else { return }
        isMicRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        print("[ScreenAgentAudio] mic stopped")
    }

    // MARK: 播放

    private var playerConfigured = false
    private func setupPlayerIfNeeded() {
        guard !playerConfigured else { return }
        
        playerEngine.attach(playerNode)
        
        // ⚠️ 修复 -10868 闪退:
        // 不能硬塞 24kHz Int16 给 mainMixerNode,它在 voiceChat 模式下是 48kHz Float32。
        // 解决方案:用 mixer 的实际输出格式 connect,playerNode 内部会自动转换。
        let mixerFormat = playerEngine.mainMixerNode.outputFormat(forBus: 0)
        print("[ScreenAgentAudio] mixer format: sr=\(mixerFormat.sampleRate) ch=\(mixerFormat.channelCount) common=\(mixerFormat.commonFormat.rawValue)")
        
        playerEngine.connect(playerNode,
                             to: playerEngine.mainMixerNode,
                             format: mixerFormat)
        do {
            try playerEngine.start()
            playerNode.play()
            playerConfigured = true
            print("[ScreenAgentAudio] player engine started")
        } catch {
            print("[ScreenAgentAudio] player engine start err: \(error)")
        }
    }

    /// Qwen 返回的是 PCM 16-bit signed @ 24kHz mono
    /// (协议名 pcm24 容易让人以为 24-bit,实际是 24kHz 16-bit)
    /// 由于 player node 现在按 mixer 格式连接(通常 48kHz Float32),
    /// 我们需要在喂 buffer 前转换格式。
    
    private var playbackConverter: AVAudioConverter?
    
    private func makePlayerOutputBuffer(from inputBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let outputFormat = playerEngine.mainMixerNode.outputFormat(forBus: 0)
        
        // 输入和输出格式一致,直接返回
        if inputBuffer.format.isEqual(outputFormat) {
            return inputBuffer
        }
        
        // 创建转换器(只创建一次)
        if playbackConverter == nil {
            playbackConverter = AVAudioConverter(from: inputBuffer.format, to: outputFormat)
        }
        guard let converter = playbackConverter else { return nil }
        
        // 计算输出帧数
        let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let outFrameCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio + 16)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                                frameCapacity: outFrameCapacity) else { return nil }
        
        var error: NSError?
        var fed = false
        converter.convert(to: outBuffer, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return inputBuffer
        }
        if let e = error {
            print("[ScreenAgentAudio] playback convert err: \(e)")
            return nil
        }
        return outBuffer
    }
    
    func playPCM24(_ pcm: Data) {
        setupPlayerIfNeeded()
        playbackQueue.async { [weak self] in
            guard let self else { return }
            let frameCount = AVAudioFrameCount(pcm.count / 2)
            guard frameCount > 0 else { return }
            
            // 1. 创建 24kHz Int16 输入 buffer
            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: self.playFormat,
                                                      frameCapacity: frameCount) else { return }
            inputBuffer.frameLength = frameCount

            pcm.withUnsafeBytes { src in
                guard let s = src.bindMemory(to: Int16.self).baseAddress,
                      let dst = inputBuffer.int16ChannelData?[0] else { return }
                memcpy(dst, s, pcm.count)
            }

            // 2. 转换为 mixer 期望的格式(48kHz Float32 之类)
            guard let outBuffer = self.makePlayerOutputBuffer(from: inputBuffer) else { return }

            // 3. 发给 player node
            self.playerNode.scheduleBuffer(outBuffer, completionHandler: nil)
        }
    }

    func stopPlayback() {
        playerNode.stop()
        playerNode.play()  // 立即恢复就绪
    }

    // MARK: 总停

    func stopAll() {
        stopMic()
        playerNode.stop()
        playerEngine.stop()
        playerConfigured = false
        audioSessionConfigured = false
        playbackConverter = nil

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            print("[ScreenAgentAudio] session deactivate err: \(error)")
        }
    }
}


