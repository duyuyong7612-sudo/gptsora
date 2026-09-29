//
//  ComputerBodyDebugView.swift
//  GPTsora
//
//  ChatAGI Computer Body Gateway V2 — 高级调试面板。
//  直接调用后端 /api/brain/computer/body/{port}/{action},以及 /api/brain/dev/run、
//  /api/brain/self-upgrade/start。普通聊天仍走 dev/run 或 computer/agent/loop;
//  这个面板是给开发者看身体端口原始返回用的。
//
//  自包含:不依赖其它大文件的私有类型,只用 AppConfig.API.apiBase + URLSession。
//

// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-1243424833fdb0cfd7db4c82a0d54b3d3ea3805db24a657530426041943c3b7e"
// Source-SHA256: "fcee61f62423c647ef67de56303928fdeeb959e2d7f5c207e925521f3e1c6f25"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI
import UIKit
import PhotosUI

/// 小入口组件:把电脑身体调试入口从 Homechatview 的大 ViewBuilder 里拆出来,
/// 避免 SwiftUI 类型检查超时(compiler unable to type-check in reasonable time)。
struct ComputerBodyEntryButton: View {
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Image(systemName: "cpu")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.black.opacity(0.75))
                .frame(width: 40, height: 40)
                .background(Color(.systemGray5))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

struct ComputerBodyDebugView: View {
    var onClose: (() -> Void)? = nil

    @State private var apiBase: String = AppConfig.API.apiBase
    @State private var output: String = "就绪。点击上方按钮调用电脑身体端口。"
    @State private var screenshot: UIImage? = nil
    @State private var busy = false

    // raw body action 输入
    @State private var rawPort = "screen"
    @State private var rawAction = "screenshot"
    @State private var rawPayload = "{}"
    // 通用文本输入(type / open_app / shell / dev goal)
    @State private var textInput = "Safari"
    @State private var goalInput = "查看当前电脑屏幕，然后检查后端 server_session.py 是否能 py_compile"
    // 视觉
    @State private var visionGoal = "看看当前电脑屏幕有什么，有没有报错"
    @State private var pickedItem: PhotosPickerItem? = nil

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    statusCard
                    visionCard
                    quickActions
                    rawActionCard
                    devBrainCard
                    outputCard
                }
                .padding(16)
            }
            .navigationTitle("电脑身体端口 V2")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { onClose?() }
                }
            }
        }
    }

    // MARK: cards

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("网关状态").font(.headline)
            HStack {
                debugButton("Health") { await call("GET", "/api/brain/computer/body/health", nil) }
                debugButton("Ports") { await call("GET", "/api/brain/computer/body/ports", nil) }
            }
            Text("Base: \(apiBase)").font(.caption).foregroundColor(.secondary)
        }
        .cardStyle()
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("快捷动作").font(.headline)
            HStack {
                debugButton("Screenshot") { await body("screen", "screenshot", [:]) }
                debugButton("FrontApp") { await call("POST", "/api/brain/computer/body/app/frontmost_app", [:]) }
                debugButton("Windows") { await body("screen", "windows", [:]) }
            }
            HStack {
                debugButton("Open Safari") { await body("app", "open_app", ["app": "Safari"]) }
                debugButton("Type") { await body("keyboard", "type", ["text": textInput]) }
                debugButton("Click") { await body("mouse", "click", [:]) }
            }
            HStack {
                debugButton("Shell pwd") { await body("shell", "run", ["cmd": "pwd"]) }
                debugButton("Shell rm -rf (blocked)") { await body("shell", "run", ["cmd": "rm -rf /tmp/x"]) }
            }
            TextField("type 文本 / open app 名", text: $textInput)
                .textFieldStyle(.roundedBorder).autocapitalization(.none)
        }
        .cardStyle()
    }

    private var rawActionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Raw Body Action").font(.headline)
            HStack {
                TextField("port", text: $rawPort).textFieldStyle(.roundedBorder).autocapitalization(.none)
                TextField("action", text: $rawAction).textFieldStyle(.roundedBorder).autocapitalization(.none)
            }
            TextField("payload JSON", text: $rawPayload).textFieldStyle(.roundedBorder).autocapitalization(.none)
            debugButton("调用 body/\(rawPort)/\(rawAction)") {
                let payload = (try? JSONSerialization.jsonObject(with: Data(rawPayload.utf8))) as? [String: Any] ?? [:]
                await body(rawPort, rawAction, payload)
            }
        }
        .cardStyle()
    }

    private var devBrainCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DevBrain / 自我升级").font(.headline)
            TextField("DevBrain 目标", text: $goalInput).textFieldStyle(.roundedBorder)
            HStack {
                debugButton("Run DevBrain") {
                    await call("POST", "/api/brain/dev/run", [
                        "goal": goalInput, "mode": "auto", "max_steps": 8,
                        "allow_write": false, "allow_tools": true, "return_trace": true
                    ])
                }
                debugButton("Self-Upgrade") {
                    await call("POST", "/api/brain/self-upgrade/start", [
                        "goal": "找出一个最有价值的低风险改进并完成验证",
                        "mode": "auto", "max_steps": 8, "allow_write": true
                    ])
                }
            }
            // ✅ 视觉驱动 DevBrain:看见→判断→执行→再看见→验证
            debugButton("👁 Vision DevBrain Test") {
                await call("POST", "/api/brain/dev/run", [
                    "goal": "观察当前电脑屏幕，判断是否有错误，并给出下一步",
                    "mode": "auto", "max_steps": 8,
                    "allow_write": false, "allow_tools": true, "return_trace": true,
                    "vision_driven": true, "observe_each_step": true, "visual_verify": true
                ])
            }
        }
        .cardStyle()
    }

    private var visionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("👁 视觉(阿杜看见)").font(.headline)
            TextField("视觉关注点", text: $visionGoal).textFieldStyle(.roundedBorder)
            HStack {
                debugButton("观察电脑屏幕") { await observeScreen() }
                PhotosPicker(selection: $pickedItem, matching: .images) {
                    Text("选图分析").font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(Color.purple.opacity(0.12)).cornerRadius(8)
                }
            }
        }
        .cardStyle()
        .onChange(of: pickedItem) { _ in Task { await analyzePickedImage() } }
    }

    private var outputCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("返回").font(.headline)
            if let img = screenshot {
                Image(uiImage: img).resizable().scaledToFit()
                    .frame(maxHeight: 220).cornerRadius(8)
            }
            if busy { ProgressView().padding(.vertical, 4) }
            Text(output).font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .cardStyle()
    }

    // MARK: helpers

    private func debugButton(_ title: String, _ action: @escaping () async -> Void) -> some View {
        Button {
            Task { busy = true; await action(); busy = false }
        } label: {
            Text(title).font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Color.blue.opacity(0.12)).cornerRadius(8)
        }
        .disabled(busy)
    }

    private func body(_ port: String, _ action: String, _ payload: [String: Any]) async {
        await call("POST", "/api/brain/computer/body/\(port)/\(action)", payload)
    }

    // MARK: 视觉

    private func observeScreen() async {
        busy = true
        await call("POST", "/api/brain/vision/observe", [
            "user_key": "adu", "source": "computer_screenshot",
            "goal": visionGoal, "write_memory": true
        ])
        busy = false
    }

    private func analyzePickedImage() async {
        guard let item = pickedItem else { return }
        busy = true
        defer { busy = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let img = UIImage(data: data),
                  let jpeg = img.jpegData(compressionQuality: 0.7) else {
                await MainActor.run { self.output = "图片读取失败" }
                return
            }
            await MainActor.run { self.screenshot = img }
            let b64 = jpeg.base64EncodedString()
            await call("POST", "/api/brain/vision/observe", [
                "user_key": "adu", "source": "image_upload",
                "image_b64": b64, "goal": visionGoal, "write_memory": true
            ])
        } catch {
            await MainActor.run { self.output = "图片分析失败: \(error.localizedDescription)" }
        }
    }

    private func call(_ method: String, _ path: String, _ payload: [String: Any]?) async {
        guard let url = URL(string: apiBase + path) else { output = "URL 无效"; return }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = (path.contains("/dev/") || path.contains("/self-upgrade/")) ? 600
            : (path.contains("/vision/") ? 120 : 90)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let payload, method == "POST" {
            req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            // 截图(body/screen/screenshot 或 dev/run 顶层 screenshot_b64)
            await MainActor.run {
                if let img = Self.extractImage(obj) { self.screenshot = img }
                self.output = "HTTP \(code)\n" + Self.pretty(data)
            }
        } catch {
            await MainActor.run { self.output = "请求失败: \(error.localizedDescription)" }
        }
    }

    private static func extractImage(_ obj: [String: Any]) -> UIImage? {
        if let b64 = obj["screenshot_b64"] as? String, let img = decodeB64(b64) { return img }
        if let r = obj["result"] as? [String: Any] {
            if let b64 = r["image_b64"] as? String, let img = decodeB64(b64) { return img }
            if let rr = r["result"] as? [String: Any], let b64 = rr["image_b64"] as? String,
               let img = decodeB64(b64) { return img }
        }
        return nil
    }

    private static func decodeB64(_ raw: String) -> UIImage? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let c = s.firstIndex(of: ","), s[..<c].contains("base64") { s = String(s[s.index(after: c)...]) }
        guard let d = Data(base64Encoded: s) else { return nil }
        return UIImage(data: d)
    }

    private static func pretty(_ data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]),
           var s = String(data: pretty, encoding: .utf8) {
            // 截断超长 base64
            if s.count > 4000 { s = String(s.prefix(4000)) + "\n…(截断)" }
            return s
        }
        return String(data: data.prefix(4000), encoding: .utf8) ?? "(无法解析)"
    }
}

private extension View {
    func cardStyle() -> some View {
        self.padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
    }
}
