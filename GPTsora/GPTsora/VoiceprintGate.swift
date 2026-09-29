// VoiceprintGate.swift
// ChatAGI-阿杜 声纹门控 v3 — 旁听式注册
// ────────────────────────────────────────────────
// 设计原则：绝不干扰正常通话！
//
// 阶段 1（前 10 轮）：
//   音频正常发送，声纹模块只是"旁听"——
//   在后台异步提取每轮语音的 embedding，存入候选池。
//   攒够 10 个候选后，选出最一致的 4 个作为主人基盘。
//
// 阶段 2（注册完成后）：
//   启用门控，非主人声音被拦截。
//
// 关键：observe() 只旁听不拦截，shouldAllow() 才做拦截判断。
// ────────────────────────────────────────────────

// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-2b1d01cfa308d8c453ede12ea160b885ea1e8036203fcbdc9ebdbc4f40798b77"
// Source-SHA256: "c0ed10142c204eb88cf0c2934c582a7542dcafc0a5ee9593c39409405b8aa75e"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation
import Accelerate

final class VoiceprintGate {

    static let shared = VoiceprintGate()

    // MARK: - 配置

    var normalThreshold: Float = 0.72
    var playbackThreshold: Float = 0.82
    var isPlaybackActive: Bool = false

    /// 注册需要采集的轮数（每轮 = 一段完整说话）
    private let enrollmentRoundsNeeded = 10
    /// 从候选中选出的基盘数
    private let baseEmbeddingCount = 4
    /// 候选间最低一致性
    private let enrollmentConsensusThreshold: Float = 0.55

    private let sampleRate: Float = 16000

    // MARK: - 状态

    /// 主人声纹基盘（注册完成后有值）
    private var ownerEmbeddings: [[Float]] = []

    /// 是否已注册
    var isRegistered: Bool { !ownerEmbeddings.isEmpty }

    /// 是否正在旁听采集阶段
    private(set) var isEnrolling: Bool = false

    /// 注册候选池
    private var enrollmentCandidates: [[Float]] = []

    /// 旁听用 utterance 累积
    private var utteranceBuffer: [Float] = []
    private var utteranceActive: Bool = false
    private var utteranceSilenceFrames: Int = 0
    private let utteranceSilenceToCommit = 25   // ~500ms
    private let utteranceMinSamples = 12800     // 0.8s
    private let utteranceMaxSamples = 48000     // 3s

    /// 门控用音频累积
    private var gateBuffer: [Float] = []
    private let gateLock = NSLock()
    private let gateMinDuration: Float = 0.8    // 800ms 才做一次匹配
    private var lastMatchResult: Bool = true
    private var lastMatchTime: Date = .distantPast
    private let matchCacheDuration: TimeInterval = 1.5

    /// MFCC 参数
    private let numMFCCs = 20
    private let fftSize = 512
    private let hopSize = 160
    private let numMelBands = 40

    // MARK: - 回调

    var onEnrollmentProgress: ((Int, Int) -> Void)?
    var onEnrollmentComplete: ((Bool) -> Void)?

    // MARK: - Init

    private init() { loadOwnerEmbeddings() }

    // MARK: - 公开 API

    /// 开始旁听式注册（通话开始时调用）
    func startAutoEnrollment() {
        guard !isRegistered else { return }
        isEnrolling = true
        enrollmentCandidates.removeAll()
        utteranceBuffer.removeAll()
        utteranceActive = false
        print("[Voiceprint] 🎙️ 开始旁听注册（需 \(enrollmentRoundsNeeded) 轮，不影响通话）")
    }

    /// 旁听音频帧 — 只采集不拦截，绝不影响通话
    /// 在 installTap 回调里调用，放在 sendClientEvent 之后或并行
    func observe(pcm16Data: Data, rms: Float) {
        guard isEnrolling else { return }

        let samples = pcm16ToFloat(pcm16Data)
        let vadThreshold: Float = 0.012

        if rms > vadThreshold {
            utteranceSilenceFrames = 0
            if !utteranceActive {
                utteranceActive = true
                utteranceBuffer.removeAll()
            }
            if utteranceBuffer.count < utteranceMaxSamples {
                utteranceBuffer.append(contentsOf: samples)
            }
        } else if utteranceActive {
            utteranceBuffer.append(contentsOf: samples)
            utteranceSilenceFrames += 1
            if utteranceSilenceFrames >= utteranceSilenceToCommit {
                utteranceActive = false
                utteranceSilenceFrames = 0
                if utteranceBuffer.count >= utteranceMinSamples {
                    commitEnrollmentUtterance()
                } else {
                    utteranceBuffer.removeAll()
                }
            }
        }
    }

    /// 门控判断 — 只在注册完成后才实际拦截
    func shouldAllow(pcm16Data: Data) -> Bool {
        // 未注册 or 还在注册中 → 全部放行
        guard isRegistered, !isEnrolling else { return true }

        // 缓存命中
        if Date().timeIntervalSince(lastMatchTime) < matchCacheDuration {
            return lastMatchResult
        }

        let samples = pcm16ToFloat(pcm16Data)
        gateLock.lock()
        gateBuffer.append(contentsOf: samples)
        let minSamples = Int(sampleRate * gateMinDuration)
        guard gateBuffer.count >= minSamples else {
            gateLock.unlock()
            return lastMatchResult
        }
        let utt = Array(gateBuffer.suffix(minSamples))
        gateBuffer.removeAll()
        gateLock.unlock()

        guard let emb = extractEmbedding(from: utt) else { return lastMatchResult }
        let best = ownerEmbeddings.map { cosineSimilarity($0, emb) }.max() ?? 0
        let thr = isPlaybackActive ? playbackThreshold : normalThreshold
        let ok = best >= thr
        lastMatchResult = ok
        lastMatchTime = Date()
        if !ok {
            print("[Voiceprint] 🚫 拒绝（\(String(format: "%.3f", best)) < \(String(format: "%.2f", thr))）")
        }
        return ok
    }

    /// 手动注册（兼容）
    @discardableResult
    func registerOwner(pcm16Data: Data) -> Bool {
        let samples = pcm16ToFloat(pcm16Data)
        guard samples.count >= Int(sampleRate * 2),
              let emb = extractEmbedding(from: samples) else { return false }
        ownerEmbeddings = Array(repeating: emb, count: baseEmbeddingCount)
        saveOwnerEmbeddings()
        isEnrolling = false
        print("[Voiceprint] ✅ 手动注册成功")
        return true
    }

    func clearOwner() {
        ownerEmbeddings.removeAll()
        enrollmentCandidates.removeAll()
        UserDefaults.standard.removeObject(forKey: "adu_voiceprint_v2")
        isEnrolling = false
        resetBuffer()
        print("[Voiceprint] 🗑️ 已清除声纹")
    }

    func resetBuffer() {
        gateLock.lock()
        gateBuffer.removeAll()
        utteranceBuffer.removeAll()
        utteranceActive = false
        utteranceSilenceFrames = 0
        lastMatchResult = true
        lastMatchTime = .distantPast
        gateLock.unlock()
    }

    // MARK: - 注册内部

    private func commitEnrollmentUtterance() {
        let samples = Array(utteranceBuffer)
        utteranceBuffer.removeAll()
        // ✅ 后台提取 embedding，不阻塞通话音频链路
        DispatchQueue.global(qos: .utility).async {
            guard let emb = self.extractEmbedding(from: samples) else { return }
            self.enrollmentCandidates.append(emb)
            let cur = self.enrollmentCandidates.count
            print("[Voiceprint] 🎙️ 旁听采集 \(cur)/\(self.enrollmentRoundsNeeded)")
            DispatchQueue.main.async { self.onEnrollmentProgress?(cur, self.enrollmentRoundsNeeded) }
            if cur >= self.enrollmentRoundsNeeded { self.finalizeEnrollment() }
        }
    }

    private func finalizeEnrollment() {
        let n = enrollmentCandidates.count
        guard n >= enrollmentRoundsNeeded else { return }

        // 两两相似度矩阵
        var sim = [[Float]](repeating: [Float](repeating: 0, count: n), count: n)
        for i in 0..<n {
            sim[i][i] = 1.0
            for j in (i+1)..<n {
                let s = cosineSimilarity(enrollmentCandidates[i], enrollmentCandidates[j])
                sim[i][j] = s; sim[j][i] = s
            }
        }

        // 平均一致性得分排序
        var scores: [(Int, Float)] = (0..<n).map { i in
            let avg = (0..<n).filter { $0 != i }.map { sim[i][$0] }.reduce(0, +) / Float(n - 1)
            return (i, avg)
        }
        scores.sort { $0.1 > $1.1 }
        let topIdx = scores.prefix(baseEmbeddingCount).map { $0.0 }

        // 检查选出的基盘互相似度
        var minSim: Float = 1.0
        for i in 0..<topIdx.count {
            for j in (i+1)..<topIdx.count {
                minSim = min(minSim, sim[topIdx[i]][topIdx[j]])
            }
        }

        if minSim < enrollmentConsensusThreshold {
            print("[Voiceprint] ❌ 注册失败：一致性太低（\(String(format: "%.3f", minSim))）")
            print("[Voiceprint]    将继续旁听采集...")
            // 不清空候选，保留最好的，丢掉最差的，继续攒
            let worstIdx = scores.last!.0
            enrollmentCandidates.remove(at: worstIdx)
            DispatchQueue.main.async { self.onEnrollmentComplete?(false) }
            return
        }

        ownerEmbeddings = topIdx.map { enrollmentCandidates[$0] }
        saveOwnerEmbeddings()
        enrollmentCandidates.removeAll()
        isEnrolling = false
        let scoreStrs = scores.prefix(baseEmbeddingCount).map { String(format: "%.3f", $0.1) }
        print("[Voiceprint] ✅ 自动注册成功！\(baseEmbeddingCount) 基盘，最低互似 \(String(format: "%.3f", minSim))")
        print("[Voiceprint]    得分: \(scoreStrs.joined(separator: ", "))")
        DispatchQueue.main.async { self.onEnrollmentComplete?(true) }
    }

    // MARK: - MFCC 特征提取

    private func extractEmbedding(from samples: [Float]) -> [Float]? {
        let nFrames = max(1, (samples.count - fftSize) / hopSize + 1)
        guard nFrames >= 2 else { return nil }
        let mel = createMelFilterbank(numFilters: numMelBands, fftSize: fftSize, sampleRate: sampleRate)
        var all: [[Float]] = []
        for fi in 0..<nFrames {
            let s = fi * hopSize
            var frame = Array(samples[s..<min(s + fftSize, samples.count)])
            if frame.count < fftSize { frame += [Float](repeating: 0, count: fftSize - frame.count) }
            applyHammingWindow(&frame)
            let pwr = computePowerSpectrum(frame)
            var ms = [Float](repeating: 0, count: numMelBands)
            for i in 0..<numMelBands {
                var v: Float = 0
                vDSP_dotpr(pwr, 1, mel[i], 1, &v, vDSP_Length(pwr.count))
                ms[i] = max(v, 1e-10)
            }
            var logIn = ms; var logOut = ms; var cnt = Int32(numMelBands)
            vvlogf(&logOut, &logIn, &cnt)
            all.append(dct(logOut, numCoeffs: numMFCCs))
        }
        guard !all.isEmpty else { return nil }
        var emb = [Float](repeating: 0, count: numMFCCs)
        for m in all { for i in 0..<numMFCCs { emb[i] += m[i] } }
        let fn = Float(all.count); for i in 0..<numMFCCs { emb[i] /= fn }
        var norm: Float = 0; vDSP_svesq(emb, 1, &norm, vDSP_Length(numMFCCs)); norm = sqrt(norm)
        if norm > 1e-8 { var sc = 1.0 / norm; vDSP_vsmul(emb, 1, &sc, &emb, 1, vDSP_Length(numMFCCs)) }
        return emb
    }

    // MARK: - DSP

    private func pcm16ToFloat(_ data: Data) -> [Float] {
        let c = data.count / 2; var o = [Float](repeating: 0, count: c)
        data.withUnsafeBytes { r in
            guard let p = r.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for i in 0..<c { o[i] = Float(p[i]) / 32768.0 }
        }; return o
    }

    private func applyHammingWindow(_ f: inout [Float]) {
        let n = f.count
        for i in 0..<n { f[i] *= 0.54 - 0.46 * cos(2.0 * .pi * Float(i) / Float(n - 1)) }
    }

    private func computePowerSpectrum(_ frame: [Float]) -> [Float] {
        let n = frame.count, h = n / 2
        var rp = [Float](repeating: 0, count: h), ip = [Float](repeating: 0, count: h)
        var inp = frame
        rp.withUnsafeMutableBufferPointer { rb in
            ip.withUnsafeMutableBufferPointer { ib in
                var sc = DSPSplitComplex(realp: rb.baseAddress!, imagp: ib.baseAddress!)
                inp.withUnsafeBufferPointer { ib2 in
                    vDSP_ctoz(ib2.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: h) { $0 }, 2, &sc, 1, vDSP_Length(h))
                }
            }
        }
        let lg = vDSP_Length(log2(Float(n)))
        guard let fs = vDSP_create_fftsetup(lg, FFTRadix(kFFTRadix2)) else { return [Float](repeating: 0, count: h+1) }
        rp.withUnsafeMutableBufferPointer { rb in
            ip.withUnsafeMutableBufferPointer { ib in
                var sr = DSPSplitComplex(realp: rb.baseAddress!, imagp: ib.baseAddress!)
                vDSP_fft_zrip(fs, &sr, 1, lg, FFTDirection(kFFTDirection_Forward))
            }
        }
        vDSP_destroy_fftsetup(fs)
        var pw = [Float](repeating: 0, count: h+1)
        for i in 0..<h { pw[i] = rp[i]*rp[i] + ip[i]*ip[i] }
        return pw
    }

    private func createMelFilterbank(numFilters: Int, fftSize: Int, sampleRate: Float) -> [[Float]] {
        let hf = fftSize/2+1; let lo = hzToMel(0); let hi = hzToMel(sampleRate/2)
        let mp = (0...(numFilters+1)).map { lo + Float($0)*(hi-lo)/Float(numFilters+1) }
        let bp = mp.map { Int(floor(melToHz($0)*Float(fftSize)/sampleRate)) }
        return (0..<numFilters).map { i in
            var f = [Float](repeating: 0, count: hf)
            let l = bp[i], c = bp[i+1], r = bp[i+2]
            for j in l..<c where j < hf { f[j] = Float(j-l)/Float(max(1,c-l)) }
            for j in c..<r where j < hf { f[j] = Float(r-j)/Float(max(1,r-c)) }
            return f
        }
    }

    private func hzToMel(_ hz: Float) -> Float { 2595.0 * log10(1+hz/700) }
    private func melToHz(_ mel: Float) -> Float { 700*(pow(10, mel/2595)-1) }

    private func dct(_ input: [Float], numCoeffs: Int) -> [Float] {
        let n = input.count
        return (0..<numCoeffs).map { k in
            (0..<n).reduce(Float(0)) { $0 + input[$1] * cos(.pi*Float(k)*(Float($1)+0.5)/Float(n)) }
        }
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var d: Float = 0, na: Float = 0, nb: Float = 0
        vDSP_dotpr(a, 1, b, 1, &d, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &na, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &nb, vDSP_Length(b.count))
        let dn = sqrt(na)*sqrt(nb)
        return dn > 1e-8 ? d/dn : 0
    }

    // MARK: - 持久化

    private func saveOwnerEmbeddings() {
        UserDefaults.standard.set(try? JSONEncoder().encode(ownerEmbeddings), forKey: "adu_voiceprint_v2")
    }

    private func loadOwnerEmbeddings() {
        if let d = UserDefaults.standard.data(forKey: "adu_voiceprint_v2"),
           let e = try? JSONDecoder().decode([[Float]].self, from: d), !e.isEmpty {
            ownerEmbeddings = e
            print("[Voiceprint] ✅ 已加载声纹（\(e.count) 基盘）")
            return
        }
        if let d = UserDefaults.standard.data(forKey: "adu_voiceprint_owner") {
            let c = d.count / MemoryLayout<Float>.size; guard c > 0 else { return }
            var e = [Float](repeating: 0, count: c)
            _ = e.withUnsafeMutableBufferPointer { d.copyBytes(to: $0) }
            ownerEmbeddings = Array(repeating: e, count: baseEmbeddingCount)
            saveOwnerEmbeddings()
            UserDefaults.standard.removeObject(forKey: "adu_voiceprint_owner")
        }
    }
}

