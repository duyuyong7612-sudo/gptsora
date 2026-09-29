

// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-744c93fa2adb82d906bb13a5cb108d20a3528ccf2d39d365bf63e1a63c74ac32"
// Source-SHA256: "1e19122e896259bcdb337ba79ca14e6583fddd3b53bf271b5665e3ca6486c702"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation
import AVFoundation
import AudioToolbox

/// ✅ True streaming MP3 player (iOS版 `ffplay -i -`)
/// - URLSessionDataDelegate 收到 HTTP chunk -> AudioFileStreamParseBytes -> AudioQueue 播放
/// - 支持 chunked transfer（无 Content-Length）
/// - 关键点：
///   1) Accept-Encoding=identity（避免 gzip 把 mp3 变成压缩流）
///   2) 允许 `inPacketDescriptions == nil`（CBR 场景可不传 packet desc）
///   3) 释放 AudioQueueBuffer（避免长时间播放内存增长）
///
/// 用法：
///   let p = MP3StreamPlayer()
///   p.play(request: req)
///   p.stop()
final class MP3StreamPlayer: NSObject {

    // MARK: - Callbacks (optional, for debugging)
    enum State {
        case idle
        case connecting
        case playing
        case stopped
        case failed(String)
    }
    var onState: ((State) -> Void)?
    /// ✅ Real playback time (seconds) since AudioQueue start (best-effort).
    var onTime: ((TimeInterval) -> Void)?
    /// ✅ Fired when AudioQueue stops naturally (EOF reached).
    var onFinished: (() -> Void)?
    var onLog: ((String) -> Void)?

    private func log(_ s: String) {
        print(s)
        onLog?(s)
    }
    private func setState(_ s: State) {
        onState?(s)
    }

    // MARK: - Audio
    private var audioFileStream: AudioFileStreamID?
    private var audioQueue: AudioQueueRef?
    private var asbd = AudioStreamBasicDescription()
    private var timeline: AudioQueueTimelineRef?
    private var isRunningListenerInstalled: Bool = false
    private var timeTimer: DispatchSourceTimer?
    private var didStartPlayback: Bool = false
    private var isStopping: Bool = false

    // We accumulate raw bytes until enqueue threshold
    private var chunkData = Data()
    private var chunkPacketDescs: [AudioStreamPacketDescription] = []

    private enum PacketDescMode { case unknown, described, cbrNoDescs }
    private var descMode: PacketDescMode = .unknown

    private var startedQueue = false
    private var bufferedBytes: Int = 0

    // Tune for faster start (smaller => faster first sound, but more enqueue calls)
    private let enqueueThresholdBytes = 8 * 1024
    private let minStartBytes = 12 * 1024

    // MARK: - Networking
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var didLogNoDescOnce = false
    private var didStartAt: CFAbsoluteTime?
    private var firstAudioPacketAt: CFAbsoluteTime?
    // `isStopping` / `didStartPlayback` live in the audio section for shared access.

    // MARK: - Public

    func play(url: URL) {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        req.timeoutInterval = 600
        play(request: req)
    }

    func play(request: URLRequest) {
        stop() // stop previous if any

        isStopping = false
        didLogNoDescOnce = false
        didStartPlayback = false
        didStartAt = CFAbsoluteTimeGetCurrent()
        firstAudioPacketAt = nil

        bufferedBytes = 0
        startedQueue = false
        descMode = .unknown
        chunkData.removeAll(keepingCapacity: true)
        chunkPacketDescs.removeAll(keepingCapacity: true)

        configureAudioSession()

        // Open AudioFileStream for MP3
        let st = AudioFileStreamOpen(
            Unmanaged.passUnretained(self).toOpaque(),
            MP3StreamPlayer.propertyListenerProc,
            MP3StreamPlayer.packetsProc,
            kAudioFileMP3Type,
            &audioFileStream
        )
        guard st == noErr, audioFileStream != nil else {
            setState(.failed("AudioFileStreamOpen failed: \(st)"))
            log("[MP3StreamPlayer] AudioFileStreamOpen failed: \(st)")
            return
        }

        setState(.connecting)
        log("[MP3StreamPlayer] start request \(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "")")

        // URLSession streaming
        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 600
        cfg.timeoutIntervalForResource = 600
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        session = s
        task = s.dataTask(with: request)
        task?.resume()
    }

    func stop() {
        isStopping = true
        setState(.stopped)

        stopTimeTimer()

        task?.cancel()
        task = nil

        session?.invalidateAndCancel()
        session = nil

        if let s = audioFileStream {
            AudioFileStreamClose(s)
            audioFileStream = nil
        }

        if let q = audioQueue {
            if isRunningListenerInstalled {
                AudioQueueRemovePropertyListener(q, kAudioQueueProperty_IsRunning, MP3StreamPlayer.isRunningProc, Unmanaged.passUnretained(self).toOpaque())
                isRunningListenerInstalled = false
            }
            if let tl = timeline {
                AudioQueueDisposeTimeline(q, tl)
                timeline = nil
            }
            AudioQueueStop(q, true)
            AudioQueueDispose(q, true)
            audioQueue = nil
        }

        // reset
        asbd = AudioStreamBasicDescription()
        bufferedBytes = 0
        startedQueue = false
        descMode = .unknown
        chunkData.removeAll(keepingCapacity: false)
        chunkPacketDescs.removeAll(keepingCapacity: false)

        DispatchQueue.main.async { [weak self] in
            self?.onTime?(0)
        }
    }

    // MARK: - Audio Session

    private func configureAudioSession() {
        // Keep it robust: play even when silent switch is on.
        let sess = AVAudioSession.sharedInstance()
        do {
            try sess.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .allowBluetooth, .allowAirPlay])
            try sess.setActive(true, options: [])
        } catch {
            log("[MP3StreamPlayer] AVAudioSession setup failed: \(error.localizedDescription)")
        }
    }

    // MARK: - AudioQueue / Enqueue

    private func ensureAudioQueue() -> Bool {
        if audioQueue != nil { return true }
        guard asbd.mFormatID != 0 else {
            // DataFormat not ready yet
            return false
        }

        var q: AudioQueueRef?
        let st = AudioQueueNewOutput(
            &asbd,
            MP3StreamPlayer.outputCallback,
            Unmanaged.passUnretained(self).toOpaque(),
            nil,
            nil,
            0,
            &q
        )
        guard st == noErr, let q2 = q else {
            log("[MP3StreamPlayer] AudioQueueNewOutput failed: \(st)")
            return false
        }
        audioQueue = q2

        // ✅ Timeline + running-state listener (for progress + natural-finish callback)
        var tl: AudioQueueTimelineRef?
        let tlStatus = AudioQueueCreateTimeline(q2, &tl)
        if tlStatus == noErr {
            timeline = tl
        }
        if !isRunningListenerInstalled {
            AudioQueueAddPropertyListener(q2, kAudioQueueProperty_IsRunning, MP3StreamPlayer.isRunningProc, Unmanaged.passUnretained(self).toOpaque())
            isRunningListenerInstalled = true
        }

        // Try set magic cookie if present (safe for MP3; required for some codecs)
        if let fs = audioFileStream {
            var cookieSize: UInt32 = 0
            var writable: DarwinBoolean = false
            let stInfo = AudioFileStreamGetPropertyInfo(fs, kAudioFileStreamProperty_MagicCookieData, &cookieSize, &writable)
            if stInfo == noErr, cookieSize > 0 {
                var cookie = Data(count: Int(cookieSize))
                let stGet = cookie.withUnsafeMutableBytes { buf -> OSStatus in
                    AudioFileStreamGetProperty(fs, kAudioFileStreamProperty_MagicCookieData, &cookieSize, buf.baseAddress!)
                }
                if stGet == noErr {
                    cookie.withUnsafeBytes { buf in
                        _ = AudioQueueSetProperty(q2, kAudioQueueProperty_MagicCookie, buf.baseAddress!, cookieSize)
                    }
                    log("[MP3StreamPlayer] set magic cookie (\(cookieSize) bytes)")
                }
            }
        }

        return true
    }

    private func maybeEnqueue(force: Bool = false) {
        guard !isStopping else { return }
        guard let q = audioQueue else { return }
        guard !chunkData.isEmpty else { return }

        // If we have packet descs, ensure they exist unless we are in CBR mode
        if descMode == .described && chunkPacketDescs.isEmpty { return }

        if !force {
            if chunkData.count < enqueueThresholdBytes && bufferedBytes < minStartBytes { return }
        }

        var buf: AudioQueueBufferRef?
        let cap = UInt32(chunkData.count)
        let st = AudioQueueAllocateBuffer(q, cap, &buf)
        guard st == noErr, let b = buf else {
            log("[MP3StreamPlayer] AudioQueueAllocateBuffer failed: \(st)")
            return
        }

        chunkData.withUnsafeBytes { src in
            memcpy(b.pointee.mAudioData, src.baseAddress!, chunkData.count)
        }
        b.pointee.mAudioDataByteSize = cap

        let enqStatus: OSStatus
        switch descMode {
        case .described:
            enqStatus = chunkPacketDescs.withUnsafeBufferPointer { descPtr in
                AudioQueueEnqueueBuffer(q, b, UInt32(chunkPacketDescs.count), descPtr.baseAddress)
            }
        case .cbrNoDescs, .unknown:
            // For CBR MP3, packet descriptions can be omitted.
            enqStatus = AudioQueueEnqueueBuffer(q, b, 0, nil)
        }

        if enqStatus != noErr {
            log("[MP3StreamPlayer] AudioQueueEnqueueBuffer failed: \(enqStatus)")
            // free buffer to avoid leak
            AudioQueueFreeBuffer(q, b)
            return
        }

        bufferedBytes += chunkData.count

        chunkData.removeAll(keepingCapacity: true)
        chunkPacketDescs.removeAll(keepingCapacity: true)

        if !startedQueue, bufferedBytes >= minStartBytes {
            startedQueue = true
            let stStart = AudioQueueStart(q, nil)
            if stStart == noErr {
                didStartPlayback = true
                setState(.playing)
                startTimeTimerIfNeeded()
                log("[MP3StreamPlayer] AudioQueueStart ✅ (buffered=\(bufferedBytes) bytes)")
            } else {
                log("[MP3StreamPlayer] AudioQueueStart failed: \(stStart)")
            }
        }
    }

    // MARK: - Progress / Finish detection

    private func startTimeTimerIfNeeded() {
        guard timeTimer == nil else { return }
        // Poll on main queue (UI-friendly). Low frequency is enough for karaoke.
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now(), repeating: 0.05)
        timer.setEventHandler { [weak self] in
            self?.pollTime()
        }
        timer.resume()
        timeTimer = timer
    }

    private func stopTimeTimer() {
        timeTimer?.cancel()
        timeTimer = nil
    }

    private func pollTime() {
        guard !isStopping else { return }
        guard let q = audioQueue else { return }
        guard asbd.mSampleRate > 0 else { return }

        var ts = AudioTimeStamp()
        let st = AudioQueueGetCurrentTime(q, timeline, &ts, nil)
        guard st == noErr else { return }

        let sec = ts.mSampleTime / asbd.mSampleRate
        guard sec.isFinite, sec >= 0 else { return }
        onTime?(sec)
    }

    private static let isRunningProc: AudioQueuePropertyListenerProc = { inUserData, inAQ, inID in
        guard let inUserData else { return }
        let selfRef = Unmanaged<MP3StreamPlayer>.fromOpaque(inUserData).takeUnretainedValue()
        selfRef.handleIsRunningChanged(inAQ)
    }

    private func handleIsRunningChanged(_ aq: AudioQueueRef) {
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let st = AudioQueueGetProperty(aq, kAudioQueueProperty_IsRunning, &running, &size)
        guard st == noErr else { return }

        // When queue stops naturally (EOF), notify.
        if running == 0 {
            // Stop polling timer.
            stopTimeTimer()

            // Avoid firing when user manually stopped.
            guard didStartPlayback, !isStopping else { return }
            setState(.stopped)
            DispatchQueue.main.async { [weak self] in
                self?.onFinished?()
            }
        }
    }

    // MARK: - AudioFileStream callbacks

    private static let propertyListenerProc: AudioFileStream_PropertyListenerProc = { inClientData, inStream, inPropertyID, ioFlags in
        let selfRef = Unmanaged<MP3StreamPlayer>.fromOpaque(inClientData).takeUnretainedValue()
        selfRef.handleProperty(inStream: inStream, prop: inPropertyID)
    }

    private static let packetsProc: AudioFileStream_PacketsProc = { inClientData, inNumberBytes, inNumberPackets, inInputData, inPacketDescriptions in
        let selfRef = Unmanaged<MP3StreamPlayer>.fromOpaque(inClientData).takeUnretainedValue()
        selfRef.handlePackets(
            numBytes: Int(inNumberBytes),
            numPackets: Int(inNumberPackets),
            inputData: inInputData,
            packetDescPtr: inPacketDescriptions
        )
    }

    private func handleProperty(inStream: AudioFileStreamID, prop: AudioFileStreamPropertyID) {
        guard !isStopping else { return }

        if prop == kAudioFileStreamProperty_DataFormat {
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let st = AudioFileStreamGetProperty(inStream, prop, &size, &asbd)
            guard st == noErr else {
                log("[MP3StreamPlayer] get DataFormat failed: \(st)")
                return
            }
            log("[MP3StreamPlayer] DataFormat: formatID=\(asbd.mFormatID) sr=\(asbd.mSampleRate) ch=\(asbd.mChannelsPerFrame)")
            _ = ensureAudioQueue()
        }

        if prop == kAudioFileStreamProperty_ReadyToProducePackets {
            log("[MP3StreamPlayer] ReadyToProducePackets")
            _ = ensureAudioQueue()
        }
    }

    private func handlePackets(
        numBytes: Int,
        numPackets: Int,
        inputData: UnsafeRawPointer,
        packetDescPtr: UnsafePointer<AudioStreamPacketDescription>?
    ) {
        guard !isStopping else { return }
        guard ensureAudioQueue() else { return }

        if firstAudioPacketAt == nil {
            firstAudioPacketAt = CFAbsoluteTimeGetCurrent()
            if let t0 = didStartAt, let t1 = firstAudioPacketAt {
                log(String(format: "[MP3StreamPlayer] TTFA≈%.3fs (first packets)", (t1 - t0)))
            }
        }

        if let pds = packetDescPtr, numPackets > 0 {
            if descMode != .described { descMode = .described }

            for i in 0..<numPackets {
                let pd = pds[i]
                let start = Int(pd.mStartOffset)
                let size = Int(pd.mDataByteSize)
                guard start >= 0, size > 0, (start + size) <= numBytes else { continue }

                let packetPtr = inputData.advanced(by: start)
                chunkData.append(packetPtr.assumingMemoryBound(to: UInt8.self), count: size)

                var desc = pd
                // IMPORTANT: desc.mStartOffset must be relative to the beginning of THIS enqueue buffer.
                desc.mStartOffset = Int64(chunkData.count - size)
                chunkPacketDescs.append(desc)
            }
        } else {
            // Some MP3 CBR streams may not provide packet descriptions; AudioQueue can often handle CBR without descs.
            if descMode == .unknown { descMode = .cbrNoDescs }
            if !didLogNoDescOnce {
                didLogNoDescOnce = true
                log("[MP3StreamPlayer] packetDescriptions=nil (fallback to CBR enqueue)")
            }
            chunkData.append(inputData.assumingMemoryBound(to: UInt8.self), count: numBytes)
        }

        maybeEnqueue()
    }

    private static let outputCallback: AudioQueueOutputCallback = { inUserData, inAQ, inBuffer in
        // Free buffer after it finishes (we allocate per enqueue).
        AudioQueueFreeBuffer(inAQ, inBuffer)
        _ = inUserData
    }
}

// MARK: - URLSessionDataDelegate
extension MP3StreamPlayer: URLSessionDataDelegate {

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !isStopping else { return }
        guard let s = audioFileStream else { return }

        // Parse MP3 bytes into packets
        let st = data.withUnsafeBytes { ptr -> OSStatus in
            AudioFileStreamParseBytes(s, UInt32(data.count), ptr.baseAddress!, [])
        }
        if st != noErr {
            log("[MP3StreamPlayer] AudioFileStreamParseBytes failed: \(st)")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if (error as NSError).code == NSURLErrorCancelled {
                log("[MP3StreamPlayer] stream cancelled")
                return
            }
            log("[MP3StreamPlayer] stream completed with error: \(error.localizedDescription)")
            setState(.failed(error.localizedDescription))
        } else {
            log("[MP3StreamPlayer] stream completed")
        }

        // flush remaining data if any
        maybeEnqueue(force: true)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            log("[MP3StreamPlayer] HTTP \(http.statusCode) contentType=\(http.value(forHTTPHeaderField: "Content-Type") ?? "-")")
        }
        completionHandler(.allow)
    }
}

