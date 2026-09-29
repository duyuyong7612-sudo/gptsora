// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-67fc207cae59ee3b99e21bca854ecd0f8057fd92aa5f55860f9649e665644eb1"
// Source-SHA256: "2faf20bb838c14543ec9b4575a8c2cf71f78fc17ae39e0d9349bece47081e417"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI
import Foundation
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import CoreImage
import Combine

// =======================================================
// HomeAutomationModule_VoiceOnly_Standalone.swift
//
// ✅ 商用对齐版（前后端对齐 + 家居控制专用助手）
// - 绑定端点：POST {apiBase}/home/gateway_profile
// - Realtime 输出：HOME_CMD: {"cmd":"light_on|light_off|light_toggle"}
// - App 解析 HOME_CMD 后调用：POST {apiBase}/home/dispatch
//
// ✅ 对齐后端修复（你这版最关键的坑都补齐）
// 1) apiBase / gatewayBaseURL：自动补 http:// + 去尾斜杠（防拼接错误/URL 无效）
// 2) 默认示例端口改为 8008（你说“8008也行”）
// 3) display_name 为空兜底为 “我的灯”（避免后端 home prompt 设备名空）
// 4) HOME_CMD 正则改为非贪婪（避免多行吞掉）
// 5) 所有请求 URL 统一通过 makeURL(base,path) 构造（避免双斜杠）
// =======================================================


// MARK: - Haptics

enum HAGatewayHaptics {
    static func light() {
        let gen = UIImpactFeedbackGenerator(style: .light)
        gen.prepare()
        gen.impactOccurred()
    }
}

// MARK: - URL Normalize (关键：用户经常漏写 http:// 或多写 /)

enum HAURLTools {

    /// "YOUR_LAN_IP:8008" -> "http://YOUR_LAN_IP:8008"
    /// "http://x:8008/"     -> "http://x:8008"
    static func normalizeBase(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return s }

        let lower = s.lowercased()
        if !(lower.hasPrefix("http://") || lower.hasPrefix("https://")) {
            s = "http://" + s
        }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func makeURL(base: String, path: String) -> URL? {
        let b = normalizeBase(base)
        guard !b.isEmpty else { return nil }
        let p = path.hasPrefix("/") ? path : "/" + path
        return URL(string: b + p)
    }
}

// MARK: - Stable Client ID

enum HAClientIdentity {
    private static let k = "ha_client_id_v1"

    static func getOrCreate() -> String {
        if let v = UserDefaults.standard.string(forKey: k), !v.isEmpty { return v }
        let v = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        UserDefaults.standard.set(v, forKey: k)
        return v
    }
}

// MARK: - Stores

struct HAGatewayConfig: Codable, Equatable {
    var apiBase: String
    var gatewayBaseURL: String
    var gatewayToken: String?
    var clientId: String
}

struct HADeviceProfile: Codable, Equatable {
    var displayName: String
    var profileJSON: String
    var profileMediaURL: String?
    var updatedAt: TimeInterval
}

enum HAHomeStore {
    private static let kConfig = "ha_home_gateway_config_v3"
    private static let kProfile = "ha_home_device_profile_v3"

    static func loadConfig() -> HAGatewayConfig {
        if let data = UserDefaults.standard.data(forKey: kConfig),
           var v = try? JSONDecoder().decode(HAGatewayConfig.self, from: data) {
            v.apiBase = HAURLTools.normalizeBase(v.apiBase)
            v.gatewayBaseURL = HAURLTools.normalizeBase(v.gatewayBaseURL)
            if v.clientId.isEmpty { v.clientId = HAClientIdentity.getOrCreate() }
            return v
        }
        return HAGatewayConfig(
            // ✅ 单一入口地址：统一从 AppConfig.API 读取公网后端
            apiBase: AppConfig.API.apiBase,
            gatewayBaseURL: "http://YOUR_LAN_IP:8008",
            gatewayToken: nil,
            clientId: HAClientIdentity.getOrCreate()
        )
    }

    static func saveConfig(_ v: HAGatewayConfig) {
        if let data = try? JSONEncoder().encode(v) {
            UserDefaults.standard.set(data, forKey: kConfig)
        }
    }

    static func loadProfile() -> HADeviceProfile {
        if let data = UserDefaults.standard.data(forKey: kProfile),
           let v = try? JSONDecoder().decode(HADeviceProfile.self, from: data) {
            return v
        }
        return HADeviceProfile(
            displayName: "",
            profileJSON: "",
            profileMediaURL: nil,
            updatedAt: Date().timeIntervalSince1970
        )
    }

    static func saveProfile(_ v: HADeviceProfile) {
        if let data = try? JSONEncoder().encode(v) {
            UserDefaults.standard.set(data, forKey: kProfile)
        }
    }

    static func clearProfile() {
        UserDefaults.standard.removeObject(forKey: kProfile)
    }
}

// MARK: - Upload service

struct HAUploadedMedia: Codable {
    let id: String?
    let mime: String?
    let url: String?
}

final class HAMediaUploadService {
    func uploadImage(apiBase: String, data: Data) async throws -> HAUploadedMedia {
        guard let url = HAURLTools.makeURL(base: apiBase, path: "/upload/image") else {
            throw NSError(domain: "HAMediaUploadService", code: -2, userInfo: [NSLocalizedDescriptionKey: "apiBase 无效"])
        }
        return try await uploadMultipart(url: url, fieldName: "file", fileName: "home_profile.jpg", mime: "image/jpeg", data: data)
    }

    private func uploadMultipart(
        url: URL,
        fieldName: String,
        fileName: String,
        mime: String,
        data: Data
    ) async throws -> HAUploadedMedia {

        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: \(mime)\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")

        let (respData, resp) = try await URLSession.shared.upload(for: req, from: body)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "HAMediaUploadService", code: -1, userInfo: [NSLocalizedDescriptionKey: "upload 无响应"])
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: respData, encoding: .utf8) ?? ""
            throw NSError(domain: "HAMediaUploadService", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "upload 失败 \(http.statusCode): \(bodyText)"])
        }

        return (try? JSONDecoder().decode(HAUploadedMedia.self, from: respData))
        ?? HAUploadedMedia(id: nil, mime: nil, url: nil)
    }
}

// MARK: - QR decode

enum HAQRDecoder {
    static func decode(from image: UIImage) -> String? {
        guard let ci = CIImage(image: image) else { return nil }
        let context = CIContext(options: nil)
        let detector = CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: context,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )
        let feats = detector?.features(in: ci) ?? []
        for f in feats {
            if let qr = f as? CIQRCodeFeature, let s = qr.messageString, !s.isEmpty {
                return s
            }
        }
        return nil
    }
}

// MARK: - Profile parsing

struct HAParsedProfile {
    var gatewayURL: String?
    var token: String?
    var profileJSON: String?
}

enum HAProfileParser {
    static func parse(scannedText: String) -> HAParsedProfile {
        let raw = scannedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return HAParsedProfile(gatewayURL: nil, token: nil, profileJSON: nil) }

        if raw.first == "{" {
            if let data = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

                let gateway = (obj["gateway"] as? String)
                ?? (obj["gateway_url"] as? String)
                ?? (obj["gatewayBaseURL"] as? String)
                ?? (obj["gateway_base_url"] as? String)
                ?? (obj["pi_base_url"] as? String)

                let token = (obj["token"] as? String) ?? (obj["gateway_token"] as? String) ?? (obj["bearer"] as? String)
                let pretty = prettyJSONString(obj) ?? raw

                return HAParsedProfile(
                    gatewayURL: gateway?.trimmingCharacters(in: .whitespacesAndNewlines),
                    token: token?.trimmingCharacters(in: .whitespacesAndNewlines),
                    profileJSON: pretty
                )
            }
        }

        if raw.lowercased().hasPrefix("http://") || raw.lowercased().hasPrefix("https://") {
            return HAParsedProfile(gatewayURL: raw, token: nil, profileJSON: nil)
        }

        // 纯文本：当作 profile text
        return HAParsedProfile(gatewayURL: nil, token: nil, profileJSON: raw)
    }

    private static func prettyJSONString(_ obj: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(obj) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - HOME_CMD parsing

enum HAHomeCommand {
    static func extractCmd(from assistantText: String) -> String? {
        let t = assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }

        let lines = t.components(separatedBy: .newlines)
        for ln in lines {
            let s = ln.trimmingCharacters(in: .whitespacesAndNewlines)
            guard s.lowercased().hasPrefix("home_cmd:") else { continue }
            let payload = s.dropFirst("HOME_CMD:".count).trimmingCharacters(in: .whitespacesAndNewlines)

            if payload.first == "{",
               let data = payload.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let cmd = obj["cmd"] as? String {
                return cmd.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !payload.isEmpty { return String(payload) }
        }

        // ✅ 非贪婪：避免吞掉后续内容
        if let r = try? NSRegularExpression(pattern: "HOME_CMD:\\s*(\\{.*?\\})", options: [.caseInsensitive]) {
            let ns = t as NSString
            let range = NSRange(location: 0, length: ns.length)
            if let m = r.firstMatch(in: t, options: [], range: range),
               m.numberOfRanges >= 2 {
                let jsonStr = ns.substring(with: m.range(at: 1))
                if let data = jsonStr.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let cmd = obj["cmd"] as? String {
                    return cmd.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        return nil
    }

    static func stripHomeCmdLines(from assistantText: String) -> String {
        let lines = assistantText.components(separatedBy: .newlines)
        let kept = lines.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("home_cmd:")
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - ViewModel

@MainActor
final class HAVoiceHomeVM: ObservableObject {

    static func defaultPiLightProfile(gateway: String) -> String {
        let g = HAURLTools.normalizeBase(gateway)
        return """
        {
          "device": "pi_light",
          "gateway": "\(g)",
          "commands": [
            { "name": "light_on", "method": "POST", "path": "/light/on" },
            { "name": "light_off", "method": "POST", "path": "/light/off" },
            { "name": "light_toggle", "method": "POST", "path": "/light/toggle" }
          ],
          "examples": ["打开灯", "关灯", "切换灯"]
        }
        """
    }

    @Published var config: HAGatewayConfig = HAHomeStore.loadConfig()
    @Published var profile: HADeviceProfile = HAHomeStore.loadProfile()

    @Published var isBinding: Bool = false
    @Published var toast: String? = nil
    @Published var lastBindResult: String = ""
    @Published var lastUser: String = ""
    @Published var lastAssistant: String = ""
    @Published var lastScannedText: String = ""

    private let uploader = HAMediaUploadService()

    func saveConfig(apiBase: String, gatewayBaseURL: String, token: String?) {
        let v = HAGatewayConfig(
            apiBase: HAURLTools.normalizeBase(apiBase),
            gatewayBaseURL: HAURLTools.normalizeBase(gatewayBaseURL),
            gatewayToken: token,
            clientId: config.clientId.isEmpty ? HAClientIdentity.getOrCreate() : config.clientId
        )
        config = v
        HAHomeStore.saveConfig(v)
    }

    func saveProfile(displayName: String, jsonOrText: String, mediaURL: String?) {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let v = HADeviceProfile(
            displayName: name,
            profileJSON: jsonOrText,
            profileMediaURL: (mediaURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true) ? nil : mediaURL,
            updatedAt: Date().timeIntervalSince1970
        )
        profile = v
        HAHomeStore.saveProfile(v)
    }

    func clearProfile() {
        HAHomeStore.clearProfile()
        profile = HAHomeStore.loadProfile()
    }

    func uploadProfileImageToBackend(_ image: UIImage) async -> String? {
        guard let jpeg = image.jpegData(compressionQuality: 0.82) else {
            toast = "图片压缩失败"
            return nil
        }
        let apiBase = HAURLTools.normalizeBase(config.apiBase)
        guard apiBase.hasPrefix("http") else {
            toast = "后端 apiBase 无效"
            return nil
        }
        do {
            let up = try await uploader.uploadImage(apiBase: apiBase, data: jpeg)
            guard let u = up.url, !u.isEmpty else {
                toast = "上传成功但缺少 url"
                return nil
            }
            return resolveMediaURL(apiBase: apiBase, urlString: u)
        } catch {
            toast = "上传失败：\(error.localizedDescription)"
            return nil
        }
    }

    func bindToBackend() async {
        let apiBase = HAURLTools.normalizeBase(config.apiBase)
        guard let url = HAURLTools.makeURL(base: apiBase, path: "/home/gateway_profile") else {
            toast = "后端地址无效"
            return
        }

        var gw = HAURLTools.normalizeBase(config.gatewayBaseURL)
        let token = config.gatewayToken?.trimmingCharacters(in: .whitespacesAndNewlines)

        var json = profile.profileJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        let media = profile.profileMediaURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        var displayName = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)

        if displayName.isEmpty { displayName = "我的灯" }

        if gw.isEmpty, let extracted = extractGatewayFromProfileJSON(json), !extracted.isEmpty {
            gw = HAURLTools.normalizeBase(extracted)
        }
        guard !gw.isEmpty else {
            toast = "缺少网关地址（请扫码或填入）"
            return
        }
        if json.isEmpty { json = HAVoiceHomeVM.defaultPiLightProfile(gateway: gw) }

        isBinding = true
        defer { isBinding = false }

        var payload: [String: Any] = [
            "client_id": config.clientId,
            "display_name": displayName,
            "gateway_base_url": gw,
            "gateway_url": gw,
            "gateway": gw,
            "gatewayBaseURL": gw,
            "pi_base_url": gw,
            "profile_json": json,
            "profileJSON": json,
            "profile": json
        ]

        if let t = token, !t.isEmpty {
            payload["gateway_token"] = t
            payload["token"] = t
        }
        if let m = media, !m.isEmpty {
            payload["profile_media_url"] = m
            payload["profileMediaURL"] = m
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload, options: [])

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            if (200..<300).contains(code) {
                toast = "已绑定到 Realtime"
                lastBindResult = "✅ 绑定成功 \(code)"
            } else {
                toast = "绑定失败 \(code)"
                lastBindResult = "❌ 绑定失败 \(code) \(body)"
            }
        } catch {
            toast = "绑定失败：\(error.localizedDescription)"
            lastBindResult = "❌ 绑定失败：\(error.localizedDescription)"
        }
    }

    func dispatchHomeCommand(_ cmd: String) async {
        let apiBase = HAURLTools.normalizeBase(config.apiBase)
        guard let url = HAURLTools.makeURL(base: apiBase, path: "/home/dispatch") else {
            toast = "后端地址无效"
            return
        }

        let cleanCmd = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanCmd.isEmpty else { return }

        let payload: [String: Any] = [
            "client_id": config.clientId,
            "cmd": cleanCmd
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload, options: [])

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""

            if (200..<300).contains(code) {
                toast = "已执行：\(cleanCmd)"
                lastBindResult = "✅ 执行成功 \(code) \(cleanCmd)"
            } else {
                toast = "执行失败 \(code)"
                lastBindResult = "❌ 执行失败 \(code) \(body)"
            }
        } catch {
            toast = "执行失败：\(error.localizedDescription)"
            lastBindResult = "❌ 执行失败：\(error.localizedDescription)"
        }
    }

    private func resolveMediaURL(apiBase: String, urlString: String) -> String {
        let base = HAURLTools.normalizeBase(apiBase)
        let s = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if let u = URL(string: s), u.scheme != nil { return s }
        if s.hasPrefix("/") { return base + s }
        return base + "/" + s
    }

    private func extractGatewayFromProfileJSON(_ json: String) -> String? {
        let t = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.first == "{" else { return nil }
        guard let data = t.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let g = (obj["gateway"] as? String)
        ?? (obj["gateway_url"] as? String)
        ?? (obj["gatewayBaseURL"] as? String)
        ?? (obj["gateway_base_url"] as? String)
        ?? (obj["pi_base_url"] as? String)
        ?? (obj["base_url"] as? String)
        return g?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Main view

struct HAHomeVoiceControlView: View {

    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = HAVoiceHomeVM()
    @StateObject private var rt = RealtimeBridge(service: RealtimeAVService.shared)

    @State private var showBindSheet = false
    @State private var isListening = false

    @State private var desiredListening = false
    @State private var reconnectTask: Task<Void, Never>? = nil
    @State private var reconnectAttempts = 0

    // ✅ 关键修复：把 partial/final 全部累积，避免 HOME_CMD 出现在 partial 却在 final 消失
    @State private var assistantBuffer: String = ""

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                Divider().opacity(0.12)
                Spacer()

                VStack(spacing: 14) {
                    Text("纯语音控制")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundColor(.white)

                    Text(isListening ? "正在聆听…" : "点击波纹键开始")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.65))

                    waveButton

                    // ✅ 新增：手动测试按钮（直接走 /home/dispatch）
                    HStack(spacing: 10) {
                        Button { HAGatewayHaptics.light(); Task { await vm.dispatchHomeCommand("light_on") } } label: {
                            testChip("开灯", icon: "lightbulb.fill")
                        }
                        Button { HAGatewayHaptics.light(); Task { await vm.dispatchHomeCommand("light_off") } } label: {
                            testChip("关灯", icon: "lightbulb.slash.fill")
                        }
                        Button { HAGatewayHaptics.light(); Task { await vm.dispatchHomeCommand("light_toggle") } } label: {
                            testChip("切换", icon: "arrow.2.circlepath")
                        }
                    }
                    .padding(.top, 2)

                    if !vm.lastBindResult.isEmpty {
                        Text(vm.lastBindResult)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.75))
                            .padding(.top, 2)
                    }

                    if !vm.lastUser.isEmpty || !vm.lastAssistant.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            if !vm.lastUser.isEmpty {
                                Text("你：\(vm.lastUser)")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.80))
                            }
                            if !vm.lastAssistant.isEmpty {
                                Text("助手：\(vm.lastAssistant)")
                                    .font(.system(size: 14))
                                    .foregroundColor(.white.opacity(0.68))
                                    .lineLimit(6)
                            }
                        }
                        .padding(12)
                        .background(Color.white.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(0.10), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                    }

                    Text("先扫码绑定设备，再开麦。说：打开灯 / 关灯 / 切换灯")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                        .padding(.top, 6)
                }

                Spacer()
            }
        }
        .onAppear {
            rt.configure(apiBase: vm.config.apiBase, profile: "home", clientId: vm.config.clientId)

            rt.onUserTranscript = { vm.lastUser = $0 }

            // ✅ 关键修复：partial 也进 buffer（HOME_CMD 可能在 partial）
            rt.onAssistantPartial = { partial in
                // 累积：如果 partial 是“整段覆盖”，就替换；如果是“增量”，就追加
                if partial.count >= assistantBuffer.count, partial.hasPrefix(assistantBuffer) {
                    assistantBuffer = partial
                } else if partial.count <= 120 {
                    assistantBuffer += partial
                } else {
                    assistantBuffer = partial
                }

                let cleaned = HAHomeCommand.stripHomeCmdLines(from: assistantBuffer)
                vm.lastAssistant = cleaned.isEmpty ? assistantBuffer : cleaned
            }

            // ✅ final：用“累积全文”抽 HOME_CMD（避免漏触发）
            rt.onAssistantFinal = { final in
                let merged: String
                if assistantBuffer.isEmpty {
                    merged = final
                } else if final.count >= assistantBuffer.count, final.hasPrefix(assistantBuffer) {
                    merged = final
                } else if assistantBuffer.count >= final.count, assistantBuffer.hasPrefix(final) {
                    merged = assistantBuffer
                } else {
                    merged = assistantBuffer + "\n" + final
                }

                assistantBuffer = "" // 清空，准备下一轮

                let cleaned = HAHomeCommand.stripHomeCmdLines(from: merged)
                vm.lastAssistant = cleaned.isEmpty ? merged : cleaned

                // ✅ 抽取 HOME_CMD 并 dispatch
                if let cmd = HAHomeCommand.extractCmd(from: merged) {
                    HAGatewayHaptics.light()
                    Task { @MainActor in
                        await vm.dispatchHomeCommand(cmd)
                    }
                }
            }

            rt.onError = { handleRealtimeError($0) }
        }
        .onDisappear { stopVoice() }
        .sheet(isPresented: $showBindSheet) { HADeviceBindSheet(vm: vm) }
        .overlay(alignment: .top) { toastView }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .foregroundColor(.white.opacity(0.92))
                    .padding(10)
                    .background(Color.white.opacity(0.10))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Text("家居控制")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)

            Spacer()

            Button {
                HAGatewayHaptics.light()
                showBindSheet = true
            } label: {
                Image(systemName: "qrcode.viewfinder")
                    .foregroundColor(.white.opacity(0.90))
                    .padding(10)
                    .background(Color.white.opacity(0.10))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Color.black)
    }

    private var waveButton: some View {
        Button {
            HAGatewayHaptics.light()
            if isListening { stopVoice() }
            else { Task { @MainActor in await startVoice() } }
        } label: {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(isListening ? 0.16 : 0.10))
                    .frame(width: 118, height: 118)
                    .overlay(Circle().stroke(Color.white.opacity(isListening ? 0.22 : 0.14), lineWidth: 1))

                Circle()
                    .fill(Color.black)
                    .frame(width: 90, height: 90)
                    .overlay(Circle().stroke(Color.white.opacity(0.10), lineWidth: 1))

                Image(systemName: isListening ? "stop.fill" : "waveform")
                    .font(.system(size: 28, weight: .heavy))
                    .foregroundColor(.white)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isListening ? 1.02 : 1.0)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: isListening)
    }

    private func testChip(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(title)
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundColor(.white.opacity(0.92))
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color.white.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @MainActor
    private func startVoice() async {
        desiredListening = true
        reconnectAttempts = 0
        reconnectTask?.cancel()
        reconnectTask = nil

        await vm.bindToBackend()

        // ✅ 强制 home profile + 绑定一致的 client_id
        rt.configure(apiBase: vm.config.apiBase, profile: "home", clientId: vm.config.clientId)
        rt.startHomeAudio(clientId: vm.config.clientId)
        isListening = true
    }

    @MainActor
    private func stopVoice() {
        desiredListening = false
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempts = 0

        rt.stop()
        isListening = false
        assistantBuffer = ""
    }

    @MainActor
    private func handleRealtimeError(_ err: String) {
        let t = err.lowercased()
        if t.contains("cancellation failed") || t.contains("no active response found") { return }
        vm.toast = "Realtime 错误：\(err)"
        guard desiredListening else { return }
        if isTransportFatal(t) { scheduleReconnect() }
    }

    private func isTransportFatal(_ t: String) -> Bool {
        t.contains("webrtc") || t.contains("ice") || t.contains("peerconnection") || t.contains("datachannel")
        || t.contains("disconnected") || t.contains("connection lost") || t.contains("closed") || t.contains("network") || t.contains("socket")
    }

    @MainActor
    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectAttempts += 1
        if reconnectAttempts > 4 {
            vm.toast = "连接多次失败，已停止（请再点一次波纹键）"
            stopVoice()
            return
        }

        let base: Double = 0.25
        let delay = min(base * pow(2.0, Double(reconnectAttempts - 1)), 2.0)
        let ns = UInt64(delay * 1_000_000_000)

        reconnectTask = Task { @MainActor in
            rt.stop()
            try? await Task.sleep(nanoseconds: ns)
            guard desiredListening else { return }
            rt.configure(apiBase: vm.config.apiBase, profile: "home", clientId: vm.config.clientId)
            rt.startHomeAudio(clientId: vm.config.clientId)
            isListening = true
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let t = vm.toast {
            Text(t)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(Color.black.opacity(0.72))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.15), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.top, 10)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                        withAnimation(.easeOut(duration: 0.18)) { vm.toast = nil }
                    }
                }
        }
    }
}

// MARK: - Bind sheet (扫码 → 地址 + 名字 → 保存)

struct HADeviceBindSheet: View {

    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vm: HAVoiceHomeVM

    @State private var pickedPhotoItems: [PhotosPickerItem] = []
    @State private var pickedUIImage: UIImage? = nil
    @State private var showFileImporter = false

    @State private var isUploading = false
    @State private var showAdvanced = false

    @State private var apiBase: String = ""
    @State private var gatewayURL: String = ""
    @State private var token: String = ""
    @State private var displayName: String = ""
    @State private var profileJSON: String = ""
    @State private var mediaURL: String = ""

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Capsule().fill(Color.white.opacity(0.25)).frame(width: 44, height: 5).frame(maxWidth: .infinity, alignment: .center).padding(.top, 10)

                    Text("扫码绑定设备")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)

                    section("导入方式（推荐扫码）")
                    HStack(spacing: 10) {
                        PhotosPicker(selection: $pickedPhotoItems, maxSelectionCount: 1, matching: .images, photoLibrary: .shared()) {
                            chip("选择二维码/参数照片", icon: "qrcode")
                        }
                        Button {
                            HAGatewayHaptics.light()
                            showFileImporter = true
                        } label: {
                            chip("选择 JSON/文本文件", icon: "doc.text")
                        }
                        .buttonStyle(.plain)
                    }

                    if let img = pickedUIImage {
                        section("照片预览（可选上传）")
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                        Button {
                            Task { @MainActor in await uploadPhoto() }
                        } label: {
                            chip(isUploading ? "上传中…" : "上传照片到后端（可选）", icon: "arrow.up.circle")
                        }
                        .disabled(isUploading)
                        .buttonStyle(.plain)
                    }

                    section("绑定信息（扫码后自动填）")
                    field("后端 apiBase（例如 http://YOUR_LAN_IP:8008）", text: $apiBase, keyboard: .URL)

                    HStack(spacing: 10) {
                        field("网关地址（例如 http://YOUR_LAN_IP:8008）", text: $gatewayURL, keyboard: .URL)
                        field("设备名（自定义）", text: $displayName, keyboard: .default)
                    }

                    Button {
                        HAGatewayHaptics.light()
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                            showAdvanced.toggle()
                        }
                    } label: {
                        chip(showAdvanced ? "收起高级" : "展开高级", icon: "slider.horizontal.3")
                    }
                    .buttonStyle(.plain)

                    if showAdvanced {
                        section("网关 Token（可选）")
                        field("Bearer token（可空）", text: $token, keyboard: .default)

                        section("设备参数（JSON / 文本）")
                        TextEditor(text: $profileJSON)
                            .font(.system(size: 13, weight: .regular, design: .monospaced))
                            .foregroundColor(.white.opacity(0.92))
                            .scrollContentBackground(.hidden)
                            .padding(12)
                            .background(Color.white.opacity(0.08))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .frame(minHeight: 170)

                        section("（可选）参数图片 URL（上传后自动填）")
                        field("http(s)://...", text: $mediaURL, keyboard: .URL)
                    }

                    Button {
                        HAGatewayHaptics.light()
                        if gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            gatewayURL = "http://YOUR_LAN_IP:8008"
                        }
                        profileJSON = HAVoiceHomeVM.defaultPiLightProfile(gateway: gatewayURL)
                        vm.toast = "已填入树莓派灯控模板"
                    } label: {
                        chip("一键填入「树莓派灯控」模板（兜底）", icon: "lightbulb.fill")
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 12) {
                        Button {
                            HAGatewayHaptics.light()
                            dismiss()
                        } label: {
                            Text("取消")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.white.opacity(0.10))
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }

                        Button {
                            HAGatewayHaptics.light()
                            saveAll()
                            dismiss()
                        } label: {
                            Text("保存")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                    .padding(.top, 6)

                    Button {
                        HAGatewayHaptics.light()
                        Task { @MainActor in
                            saveAll()
                            await vm.bindToBackend()
                        }
                    } label: {
                        Text("立即测试绑定（可选）")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white.opacity(0.92))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)

                    Spacer(minLength: 20)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 22)
            }
        }
        .onAppear {
            apiBase = vm.config.apiBase
            gatewayURL = vm.config.gatewayBaseURL
            token = vm.config.gatewayToken ?? ""
            displayName = vm.profile.displayName
            profileJSON = vm.profile.profileJSON
            mediaURL = vm.profile.profileMediaURL ?? ""

            if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                displayName = "我的灯"
            }
        }
        .onChange(of: pickedPhotoItems) { items in
            guard let item = items.first else { return }
            Task { @MainActor in
                await loadPhoto(item)
                pickedPhotoItems = []
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.json, .plainText]) { res in
            switch res {
            case .success(let url):
                loadFile(url)
            case .failure:
                break
            }
        }
        .presentationDetents([.large])
    }

    private func section(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white.opacity(0.75))
    }

    private func field(_ ph: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        TextField(ph, text: text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .keyboardType(keyboard)
            .foregroundColor(.white)
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .background(Color.white.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func chip(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            if icon == "arrow.up.circle" && isUploading {
                ProgressView().scaleEffect(0.9)
            } else {
                Image(systemName: icon)
            }
            Text(title)
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundColor(.white.opacity(0.92))
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color.white.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @MainActor
    private func saveAll() {
        let api = HAURLTools.normalizeBase(apiBase)
        let gw = HAURLTools.normalizeBase(gatewayURL)
        let tk = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let json = profileJSON
        let mu = mediaURL.trimmingCharacters(in: .whitespacesAndNewlines)

        vm.saveConfig(apiBase: api.isEmpty ? vm.config.apiBase : api,
                      gatewayBaseURL: gw.isEmpty ? vm.config.gatewayBaseURL : gw,
                      token: tk.isEmpty ? nil : tk)

        vm.saveProfile(displayName: name.isEmpty ? "我的灯" : name, jsonOrText: json, mediaURL: mu.isEmpty ? nil : mu)
        vm.toast = "已保存"
    }

    @MainActor
    private func loadPhoto(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let ui = UIImage(data: data) else {
                vm.toast = "读取图片失败"
                return
            }
            pickedUIImage = ui

            if let decoded = HAQRDecoder.decode(from: ui) {
                applyScannedText(decoded)
                vm.toast = "已识别二维码并填入"
            } else {
                vm.toast = "未识别到二维码（你仍可选择上传图片）"
            }
        } catch {
            vm.toast = "读取失败：\(error.localizedDescription)"
        }
    }

    private func loadFile(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let s = String(data: data, encoding: .utf8) ?? ""
            if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                applyScannedText(s)
                vm.toast = "已导入文件并填入"
            } else {
                vm.toast = "文件为空"
            }
        } catch {
            vm.toast = "读取失败：\(error.localizedDescription)"
        }
    }

    private func applyScannedText(_ text: String) {
        let parsed = HAProfileParser.parse(scannedText: text)
        vm.lastScannedText = text

        if let g = parsed.gatewayURL, !g.isEmpty {
            gatewayURL = HAURLTools.normalizeBase(g)
        }

        if let t = parsed.token, !t.isEmpty {
            token = t
        }

        if let pj = parsed.profileJSON, !pj.isEmpty {
            profileJSON = pj
        } else if profileJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            profileJSON = HAVoiceHomeVM.defaultPiLightProfile(gateway: gatewayURL)
        }

        if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            displayName = "我的灯"
        }
    }

    @MainActor
    private func uploadPhoto() async {
        guard let img = pickedUIImage else { return }
        isUploading = true
        defer { isUploading = false }

        // 保存当前配置
        vm.saveConfig(apiBase: apiBase, gatewayBaseURL: gatewayURL, token: token.isEmpty ? nil : token)

        if let url = await vm.uploadProfileImageToBackend(img) {
            mediaURL = url
            vm.toast = "已上传照片"
        }
    }
}


