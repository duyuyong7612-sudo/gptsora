// AduPerceptionBootstrap.swift
// 在 App 启动时调用一次，请求定位权限并做第一次感知读取
// 放到 SoraVideoApp.swift 的 init() 或 HomeChatView.onAppear 里调用

// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-15c28b397aa3aa40e6f237522111be97c8853bac75df744d7a87bec0a6da023e"
// Source-SHA256: "de3a76f4d5486fb2bce4c2b65c89fe06b3b89839d8c1e7cf1cee15ba5cdcdb51"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation

enum AduPerceptionBootstrap {
    
    /// 调用一次即可：请求权限 + 第一次读取（后续每次发消息前会自动带最新数据）
    static func setup() {
        let mgr = AduPerceptionManager.shared
        mgr.requestPermissionIfNeeded()

        // 进入感知/视觉/导航入口即触发一次读取；若权限尚未决定，readOnce 会等待授权回调继续。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            mgr.readOnce { snapshot in
                if let s = snapshot {
                    print("[Perception] ✅ 首次读取成功: \(s.fullAddress ?? "坐标") 朝\(s.headingDescription)")
                } else {
                    print("[Perception] ⚠️ 首次读取无数据 \(mgr.locationPermissionMessage ?? "")")
                }
            }
        }
    }
}
