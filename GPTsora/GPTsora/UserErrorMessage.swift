// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-fbd5eec289735879e0dd7ec274ff4126eee02c45c2817526b7b2be1f8f329c6e"
// Source-SHA256: "e3cd948afd980aacea2120eed86e34319b527a4d18063b574df341cbed692b27"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation

enum UserErrorMessage {

    static func from(_ error: Error) -> String {

        // 0️⃣ 用户/系统主动取消（别当成错误）
        if error is CancellationError {
            return "已取消。"
        }

        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
            return "已取消。"
        }

        // 1️⃣ URL / 网络错误
        if let urlErr = error as? URLError {
            switch urlErr.code {
            case .notConnectedToInternet:
                return "网络未连接，请打开 Wi‑Fi 或蜂窝网络后再试。"
            case .timedOut:
                return "请求超时了，网络可能不稳定，请稍后重试。"
            case .cannotFindHost, .cannotConnectToHost:
                return "连接不上服务器，请检查后端是否在运行。"
            case .networkConnectionLost:
                return "网络连接中断了，请重试。"
            case .secureConnectionFailed:
                return "安全连接失败，请确认使用 https 或证书配置正确。"
            case .appTransportSecurityRequiresSecureConnection:
                return "iOS 拒绝不安全连接（ATS）。请改用 https 或配置例外。"
            default:
                return "网络请求失败，请检查网络后重试。"
            }
        }

        // 2️⃣ Photos 保存相关（配合 PhotoSaveService）
        if let photoErr = error as? PhotoSaveError {
            switch photoErr {
            case .noPermission:
                return "没有相册权限，请在系统设置中允许访问照片。"
            case .fileMissing:
                return "视频文件不存在，无法保存。"
            case .saveFailed:
                return "保存失败了，请稍后再试。"
            }
        }

        // 3️⃣ 原始文本（仅用于内部判断，不直接展示）
        let raw = (ns.userInfo[NSLocalizedDescriptionKey] as? String)
            ?? ns.localizedDescription
        let lower = raw.lowercased()

        // 4️⃣ Sora / OpenAI / 后端常见错误（全部翻成人话）
        if lower.contains("moderation_blocked") {
            return "这条内容触发了安全限制，换个描述或素材再试。"
        }
        if lower.contains("video_generation_failed")
            || lower.contains("internal error") {
            return "生成服务暂时异常（不是你的问题），请稍后重试。"
        }
        if lower.contains("job failed") || lower == "failed" {
            return "生成失败了，请重试；如果多次失败，换张图片或换句描述。"
        }
        if lower.contains("sora create failed") {
            return "提交生成任务失败，请稍后再试。"
        }
        if lower.contains("sora status error") {
            return "查询生成进度失败，请重试。"
        }
        if lower.contains("remote end closed connection")
            || lower.contains("connection aborted")
            || lower.contains("remotedisconnected") {
            return "服务连接被中断了，请重试。"
        }

        // 5️⃣ HTTP 常见状态（你后端现在会拼进字符串）
        if lower.contains("413") || lower.contains("payload too large") {
            return "文件太大了，请换小一点的图片或视频（建议最长边 ≤1280）。"
        }
        if lower.contains("422") {
            return "上传参数不正确，请重新选择素材再试。"
        }
        if lower.contains("401") || lower.contains("403") {
            return "服务鉴权失败，请检查后端密钥或权限配置。"
        }

        // 6️⃣ 最终兜底（永远不暴露英文）
        return "出错了，请重试。如果一直失败，换张图片或换句描述。"
    }
}

