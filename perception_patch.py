# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-07ccf62c0d4e23ce56f7bf8cd74d24a80d6b0eaa71b8c5725621ee3ddcd2c2b4"
# Source-SHA256: "1c72d777e4c3836a4d53e12de77fc3ff3d5b511761e8808ceba187578d2aee52"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
perception_patch.py — server_session.py 感知注入补丁
====================================================
说明：这不是独立运行的文件，是要加到 server_session.py 里的代码。
下面标注了每段代码插入的确切位置（行号基于当前 13630 行版本）。

设计：
  iOS 发 /chat 时，body 里带 "perception" 字段（GPS/朝向/地址等）
  后端收到后：
    1. 格式化为自然语言
    2. 作为 system message 注入（跟 memory 注入一样的模式）
    3. 存入 world_memory 数据库
  LLM 看到感知上下文后，就能自然地回答位置相关问题

总共改 server_session.py 3 处：
  A. 顶部 import 区加一行
  B. /chat handler 里提取 perception 数据 + 注入（在 ~8002 行附近）
  C. 底部加两个辅助函数
"""


# ══════════════════════════════════════════════
# A. 在 server_session.py 顶部 import 区加（约第 60-70 行附近）
# ══════════════════════════════════════════════

# --- 加这一行 ---
# from perception_module import format_perception_context, store_to_world_memory, register_perception_routes


# ══════════════════════════════════════════════
# B. 在 /chat handler 里，OpenClaw 注入之后（约第 8009 行之后）加感知注入
#    就在这段之后：
#      except Exception:
#          pass
#    和这段之前：
#      attachments: List[Dict[str, Any]] = []
# ══════════════════════════════════════════════

PERCEPTION_INJECTION_CODE = '''
    # ✅ 感知模块：注入物理世界感知上下文（位置/朝向/运动状态）
    _perception_data = body.get("perception")
    if isinstance(_perception_data, dict) and _perception_data.get("latitude"):
        try:
            from perception_module import format_perception_context, store_to_world_memory
            _perc_ctx = format_perception_context(_perception_data)
            if _perc_ctx:
                _ins = 1 if messages and (messages[0].get("role") in ("system", "developer")) else 0
                messages.insert(_ins, {"role": "system", "content": _perc_ctx})
                log.info("[Perception] context injected: %s", 
                         _perception_data.get("fullAddress") or f"{_perception_data.get('latitude'):.4f}")
            # 存入世界记忆
            store_to_world_memory(user_key or "anonymous", _perception_data)
        except Exception as _pe:
            log.warning("[Perception] injection failed: %s", _pe)
'''

# 插入位置示意（在 server_session.py 约第 8009-8011 行之间）：
#
#     except Exception:                        # <-- OpenClaw agent inject 的 except
#         pass                                 # <-- 第 8009 行
#
#     <<<< 在这里插入上面的感知注入代码 >>>>
#
#     attachments: List[Dict[str, Any]] = []   # <-- 第 8011 行


# ══════════════════════════════════════════════
# C. 在 app 注册路由的地方（约第 7860 行附近），加：
# ══════════════════════════════════════════════

# --- 加这两行 ---
# from perception_module import register_perception_routes
# register_perception_routes(app)


# ══════════════════════════════════════════════
# iOS 端改动：发 /chat 请求时附带 perception 字段
# ══════════════════════════════════════════════

IOS_SEND_CHAT_EXAMPLE = '''
// 在 SolaraAPIClient.swift 或你发 /chat 请求的地方，
// 发消息前先读一次传感器，把结果塞进 body：

func sendChat(messages: [[String: String]], completion: @escaping (String?) -> Void) {
    // 先读感知（异步，最多等 8 秒）
    AduPerceptionManager.shared.readOnce { snapshot in
        var body: [String: Any] = [
            "messages": messages,
            "model": currentModel,
        ]
        
        // 有感知数据就带上
        if let snapshot = snapshot {
            let encoder = JSONEncoder()
            if let data = try? encoder.encode(snapshot),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                body["perception"] = dict
            }
        }
        
        // 发请求
        self.postJSON(url: "/chat", body: body) { result in
            completion(result?["reply"] as? String)
        }
    }
}

// 或者更简单的方式 — 不等传感器，只在有缓存时附带：
func sendChatSimple(messages: [[String: String]]) {
    var body: [String: Any] = ["messages": messages]
    
    // 如果有最近 30 秒内的感知缓存，直接用
    if let snap = AduPerceptionManager.shared.lastSnapshot {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(snap),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            body["perception"] = dict
        }
    }
    
    postJSON(url: "/chat", body: body) { ... }
}
'''
