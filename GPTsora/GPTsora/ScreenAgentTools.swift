// ScreenAgentTools.swift
// 阿杜 屏幕共享 Agent · 完整工具集 v2(13 个工具)
//
// 优先级从高到低:
//   ⭐⭐⭐ 主动视觉    glance / watch / pause
//   ⭐⭐⭐ 杀招       click_by_title / ax_tree
//   ⭐⭐  鼠标键盘    click / key / paste / scroll / drag
//   ⭐   万能钥匙    shell / applescript
//        交互       ask_user / report_done

// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-ab9e928e7afd3744e3167ec8671c33cad97cad61d002807fbe10231fdedc32d5"
// Source-SHA256: "9c3a74f2b367bc66d9dad27c1832804fd108248f2cbfc86564190e60a92e6762"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation

enum ScreenAgentTools {

    static func qwenToolDefinitions() -> [[String: Any]] {
        return [
            tool(name: "mac_screen_glance",
                 desc: "立刻看一眼用户的电脑屏幕。⭐ 关键工具!任务开始时必须先 glance,执行点击/快捷键后再 glance 确认效果。延迟 1 秒,token 消耗低。"),

            tool(name: "mac_screen_watch",
                 desc: "开启持续观察电脑屏幕。用于:等加载、看视频、盯下载进度、协作编程。完成后记得 mac_screen_pause 节省 token。",
                 props: ["fps": ["type": "number", "description": "0.5 慢 / 1.0 标准 / 2.0 快"]],
                 required: ["fps"]),

            tool(name: "mac_screen_pause",
                 desc: "暂停持续观察,节省成本。任务完成或不需要持续看时调用。"),

            tool(name: "mac_click_by_title",
                 desc: "⭐ 最强工具!按元素文字直接点击,不用看坐标。系统通过 macOS Accessibility API 精确定位按钮/链接/菜单项/联系人,精度 99%、延迟 50ms、零视觉 token 成本。优先用这个,不要用 mac_click 猜坐标。例:点登录 → mac_click_by_title('登录');给信玉发消息 → mac_click_by_title('信玉')。",
                 props: [
                    "title": ["type": "string", "description": "元素显示的文字,精确匹配优先,模糊匹配兜底"],
                    "double": ["type": "boolean", "description": "是否双击,默认 false"]
                 ],
                 required: ["title"]),

            tool(name: "mac_ax_tree",
                 desc: "⭐ 拿当前前台 App 的完整 Accessibility 元素树(JSON)。用于:复杂界面找不到 click_by_title 时,先看树搞清楚有哪些元素。比看屏幕图准确 10 倍。",
                 props: ["max_depth": ["type": "integer", "description": "递归深度,默认 6,复杂界面给 8"]]),

            tool(name: "mac_click",
                 desc: "在屏幕指定坐标点击。⚠️ 只在 mac_click_by_title 找不到元素时才用!坐标系:左上角 (0,0),屏幕宽度 1280。",
                 props: [
                    "x": ["type": "integer"],
                    "y": ["type": "integer"],
                    "button": ["type": "string", "enum": ["left", "right"]],
                    "double": ["type": "boolean"]
                 ],
                 required: ["x", "y"]),

            tool(name: "mac_key",
                 desc: "按 Mac 键盘快捷键。常用: cmd-f / cmd-v / cmd-s / enter / esc / cmd-tab / cmd-space(Spotlight) / cmd-l(地址栏) / cmd-w。",
                 props: ["name": ["type": "string"]],
                 required: ["name"]),

            tool(name: "mac_paste",
                 desc: "把文本写入剪贴板并自动 Cmd+V 粘贴。⚠️ 中文输入必须用这个,绝对不要 keystroke。",
                 props: ["text": ["type": "string"]],
                 required: ["text"]),

            tool(name: "mac_scroll",
                 desc: "滚动鼠标滚轮。dy 负值向下滚,正值向上。一次 -300 大约一页。",
                 props: ["dy": ["type": "integer"]],
                 required: ["dy"]),

            tool(name: "mac_drag",
                 desc: "鼠标拖拽。从 (x1,y1) 拖到 (x2,y2)。",
                 props: [
                    "x1": ["type": "integer"], "y1": ["type": "integer"],
                    "x2": ["type": "integer"], "y2": ["type": "integer"]
                 ],
                 required: ["x1","y1","x2","y2"]),

            tool(name: "mac_shell",
                 desc: "在 Mac 执行 zsh 命令。用于:文件操作(ls/find/cp/mv)、读文件(cat)、Git、Python、curl、xcodebuild、grep。命令在 Terminal 执行,效果会显示在屏幕上,执行后调 mac_screen_glance 看结果。",
                 props: ["command": ["type": "string"]],
                 required: ["command"]),

            tool(name: "mac_applescript",
                 desc: "执行 AppleScript 控制任何 Mac 应用(Safari/Mail/日历/Spotify/Finder/微信/系统设置...)。中文输入禁止 keystroke,改用 mac_paste。",
                 props: ["script": ["type": "string"]],
                 required: ["script"]),

            tool(name: "ask_user",
                 desc: "需要用户确认或决策时调用。例:删除前确认 / 多个匹配让用户选 / 关键操作前。AI 会暂停等待用户回答。",
                 props: ["question": ["type": "string", "description": "中文问题,简短清晰"]],
                 required: ["question"]),

            tool(name: "report_done",
                 desc: "任务完成时调用,用一句话总结。例:'已经给张三发了消息:晚饭一起吃'",
                 props: ["summary": ["type": "string"]],
                 required: ["summary"])
        ]
    }

    private static func tool(name: String, desc: String,
                             props: [String: Any] = [:],
                             required: [String] = []) -> [String: Any] {
        return [
            "type": "function",
            "name": name,
            "description": desc,
            "parameters": [
                "type": "object",
                "properties": props,
                "required": required
            ]
        ]
    }

    @MainActor
    static func dispatch(name: String, args: [String: Any],
                         session: ScreenAgentSession) -> [String: Any] {
        switch name {

        case "mac_screen_glance":
            session.glanceNow()
            return ["ok": true, "note": "已请求最新屏幕"]

        case "mac_screen_watch":
            let fps = (args["fps"] as? Double) ?? 1.0
            session.setStreamingFPS(fps)
            session.resumeStreaming()
            return ["ok": true, "note": "持续观察 \(fps) fps"]

        case "mac_screen_pause":
            session.pauseStreaming()
            return ["ok": true, "note": "已暂停"]

        case "mac_click_by_title":
            let title = (args["title"] as? String) ?? ""
            guard !title.isEmpty else { return ["ok": false, "error": "empty title"] }
            let dbl = (args["double"] as? Bool) ?? false
            session.sendControlToMac(op: "click_by_title",
                                     params: ["title": title, "double": dbl])
            return ["ok": true, "matched": title,
                    "hint": "已请求 Accessibility 精准点击。如回报 not found,可调 mac_ax_tree 看结构。"]

        case "mac_ax_tree":
            let maxDepth = (args["max_depth"] as? Int) ?? 6
            session.sendControlToMac(op: "ax_tree", params: ["max_depth": maxDepth])
            return ["ok": true,
                    "note": "已请求元素树。建议先 mac_screen_glance 看屏幕辅助决策。"]

        case "mac_click":
            let x = (args["x"] as? Int).map(Double.init) ?? 0
            let y = (args["y"] as? Int).map(Double.init) ?? 0
            var p: [String: Any] = ["x": x, "y": y]
            if let b = args["button"] as? String { p["button"] = b }
            if let d = args["double"] as? Bool { p["double"] = d }
            session.sendControlToMac(op: "click", params: p)
            return ["ok": true, "clicked_at": "(\(Int(x)),\(Int(y)))"]

        case "mac_key":
            let key = (args["name"] as? String) ?? ""
            guard !key.isEmpty else { return ["ok": false, "error": "empty key"] }
            session.sendControlToMac(op: "key", params: ["name": key])
            return ["ok": true, "pressed": key]

        case "mac_paste":
            let text = (args["text"] as? String) ?? ""
            guard !text.isEmpty else { return ["ok": false, "error": "empty text"] }
            session.sendControlToMac(op: "paste", params: ["text": text])
            return ["ok": true, "pasted_chars": text.count]

        case "mac_scroll":
            let dy = (args["dy"] as? Int) ?? 0
            session.sendControlToMac(op: "scroll", params: ["dy": dy])
            return ["ok": true]

        case "mac_drag":
            let x1 = (args["x1"] as? Int) ?? 0
            let y1 = (args["y1"] as? Int) ?? 0
            let x2 = (args["x2"] as? Int) ?? 0
            let y2 = (args["y2"] as? Int) ?? 0
            session.sendControlToMac(op: "drag",
                                     params: ["x1": x1, "y1": y1, "x2": x2, "y2": y2])
            return ["ok": true]

        case "mac_shell":
            let cmd = (args["command"] as? String) ?? ""
            guard !cmd.isEmpty else { return ["ok": false, "error": "empty command"] }
            session.sendControlToMac(op: "shell", params: ["command": cmd])
            return ["ok": true, "executing": cmd,
                    "hint": "命令已下发。建议下一步 mac_screen_glance 看 Terminal 输出。"]

        case "mac_applescript":
            let src = (args["script"] as? String) ?? ""
            guard !src.isEmpty else { return ["ok": false, "error": "empty script"] }
            session.sendControlToMac(op: "applescript", params: ["source": src])
            return ["ok": true, "executing": "applescript (\(src.count) chars)",
                    "hint": "已下发。建议 mac_screen_glance 看效果。"]

        case "ask_user":
            return ["ok": true,
                    "instruction": "已记录。请用语音读出问题等待用户回答。"]

        case "report_done":
            let s = (args["summary"] as? String) ?? "任务完成"
            print("[ScreenAgent] task done: \(s)")
            return ["ok": true]

        default:
            return ["ok": false, "error": "unknown tool: \(name)"]
        }
    }
}



