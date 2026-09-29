// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-da8e1652725e555fd21c21fb982823f760bbf95abb782607567e137a2b648021"
// Source-SHA256: "d03e8a33069c1fd18416edce5d5c6a941530c5c5dfd3e82a53d601ce0ea9398d"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation

enum HomeControlConfig {
    // ✅ 1) 你的 /session（签发 realtime 临时 key + url）
    /// ✅ /session (ephemeral key + realtime url) — unified via AppConfig
    static var sessionURL: URL { AppConfig.API.resolve("/session") }
    /// Back-compat string form
    static var sessionEndpoint: String { sessionURL.absoluteString }

    // ✅ 2) 优先尝试 JSON dispatch（如果你已有这个）

    /// ✅ JSON dispatch endpoint (optional) — unified via AppConfig
    static var dispatchJSONURL: URL { AppConfig.API.resolve("/home/dispatch") }
    /// Back-compat string form
    static var dispatchJSONEndpoint: String { dispatchJSONURL.absoluteString }

    // ✅ 3) 如果 JSON dispatch 不存在/404，就 fallback 到树莓派 REST
    static let piRestBase = "http://YOUR_LAN_IP:8000"   // 例：/light/on

    // ✅ 4) 默认设备
    static let defaultDeviceId = "200"

    // ✅ 5) 家居工作定义（前端写死）
    static let homeInstructions = """
你是“家居控制专用语音助手”。你的唯一任务：把用户语音意图转换为可执行命令。

【输出协议（必须严格遵守）】
1) 你每次回复只能输出一行，且必须以 HOME_CMD: 开头，后面跟 JSON。
2) JSON 固定结构：
{"cmd":"light_on|light_off|light_toggle|ask_clarify","device_id":"\(defaultDeviceId)","confidence":0.0-1.0,"reason":"一句话原因"}
3) 除这一行外，禁止输出任何其他文字（不聊天、不解释、不寒暄）。
4) 默认 device_id="\(defaultDeviceId)"，除非用户明确指定其他设备。
5) 若不确定用户意图，输出 cmd="ask_clarify"，reason 写你要问的一句话。
"""
}

