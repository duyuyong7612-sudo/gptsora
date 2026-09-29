# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-faad2eb4415a1bac3aae72056104b7eda581340183590ca01b731f582c5456bc"
# Source-SHA256: "8e9240b6ba14846076759b02f1b19f2d35419035d969e1a404555764e2326daf"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
perception_integration.py — 感知模块集成指南
=============================================
展示如何把按需感知接入现有 ChatAGI 系统。

核心流程:
  用户说"你在哪" 
  → LLM 看到 tools 里有 get_perception，决定调用
  → 后端收到 tool_call，通过 WebSocket 让 iOS 读传感器
  → iOS 返回感知 JSON
  → 后端格式化为自然语言，作为 tool result 返回 LLM
  → 位置示例：城市A 示例街道A（完全虚构，不是个人轨迹）
  → 同时存入世界记忆
"""


# ══════════════════════════════════════════════
# 1. server_session.py — 注册 tool + 处理 tool_call
# ══════════════════════════════════════════════

"""
# 在 server_session.py 顶部:
from perception_module import (
    get_perception_tool_def,
    format_perception_context,
    store_to_world_memory,
    get_world_memory_context,
    register_perception_routes,
)

# 在 app 初始化后:
register_perception_routes(app)

# 在构建 LLM 请求的 tools 列表时，加入感知工具:
tools = [
    get_perception_tool_def(),
    # ... 其他工具
]

# 在处理 LLM 响应时，检测 tool_call:
for choice in response.choices:
    if choice.message.tool_calls:
        for tc in choice.message.tool_calls:
            if tc.function.name == "get_perception":
                # 方案 A: iOS 实时读取（通过 WebSocket 通知 iOS 端）
                # 方案 B: 用缓存的最近一次感知（如果 < 30 秒）
                # 详见下方
                pass
"""


# ══════════════════════════════════════════════
# 2. 两种获取感知数据的方案
# ══════════════════════════════════════════════

"""
【方案 A — 实时读取（推荐）】
后端通过 WebSocket 通知 iOS 端读传感器，等待返回。

后端侧:
  1. LLM 返回 tool_call: get_perception
  2. 后端通过 WebSocket 发 {"type": "perception.request", "call_id": "xxx"}
  3. iOS 收到后调用 AduPerceptionManager.readOnce()
  4. iOS 读完后发回 {"type": "perception.result", "call_id": "xxx", "data": {...}}
  5. 后端收到后:
     - context = format_perception_context(data)
     - store_to_world_memory(user_id, data)
     - 把 context 作为 tool result 发回 LLM 继续生成

iOS 侧 (在 WebSocket 消息处理里):
  case "perception.request":
      let callId = message["call_id"]
      AduPerceptionManager.shared.handlePerceptionToolCall { resultJSON in
          websocket.send(json: [
              "type": "perception.result",
              "call_id": callId,
              "data": resultJSON
          ])
      }


【方案 B — 缓存 + 定期上报（简单但精度低）】
iOS 每 30 秒读一次传感器，POST 到 /perception/store。
LLM tool_call 时，后端直接读最近一条。
缺点: 位置可能是 30 秒前的，在移动中不准。
"""


# ══════════════════════════════════════════════
# 3. voice_pipeline.py — 语音对话中的感知
# ══════════════════════════════════════════════

"""
语音场景比文字更需要感知，因为用户可能在走路/开车。

在 voice_pipeline.py 的 deepseek_stream() 调用时:
  1. 把 get_perception_tool_def() 加入 tools
  2. 检测 LLM 是否返回 tool_call
  3. 如果是 get_perception，走上面的方案 A 流程
  4. 拿到结果后，把 tool result 加入 messages，重新调 LLM

注意: 这会增加一轮 LLM 调用（第一轮决定调工具，第二轮生成回答），
延迟会增加 ~1-2 秒。可以优化：
  - 检测用户意图后直接并行读传感器（不等 LLM 决定）
  - 缓存最近 10 秒的感知数据
"""


# ══════════════════════════════════════════════
# 4. 世界记忆注入 system prompt
# ══════════════════════════════════════════════

"""
除了实时感知，还可以把"去过哪里"的记忆注入 system prompt。
这样用户问"我上周去了哪里"也能回答。

在构建 system prompt 时:
  world_ctx = get_world_memory_context(user_id)
  if world_ctx:
      system_prompt += "\\n\\n" + world_ctx

以下完全虚构的示例展示输出格式（不是个人轨迹）：
  [阿杜空间记忆 — 最近去过的地方]
  - 城市A 示例街道A（2次，最近2030-01-03）
  - 城市B 示例咖啡馆（1次，最近2030-01-02）
  - 城市C 示例广场（1次，最近2030-01-01）
"""


# ══════════════════════════════════════════════
# 5. Info.plist 权限
# ══════════════════════════════════════════════

"""
<key>NSLocationWhenInUseUsageDescription</key>
<string>阿杜需要知道你在哪，才能像真人一样感知周围环境</string>

<key>NSMotionUsageDescription</key>
<string>阿杜通过运动传感器判断你是在走路、开车还是静止</string>

<key>NSCameraUsageDescription</key>
<string>阿杜通过摄像头感知周围环境（拍照识别功能）</string>
"""


# ══════════════════════════════════════════════
# 6. .env 配置
# ══════════════════════════════════════════════

"""
PERCEPTION_DB=perception.sqlite3
"""


# ══════════════════════════════════════════════
# 7. 效果示例
# ══════════════════════════════════════════════

"""
--- 场景 1: 基础位置感知（虚构示例） ---
用户: 你知道我现在在哪吗？
[LLM → tool_call: get_perception → iOS 读传感器 → 返回]
阿杜: 传感器显示你在城市A的示例街道A附近，
      具体位置请以用户授权的实时数据为准。你面朝西北方向，
      当前运动传感器显示静止，无法据此判断是否在家。

--- 场景 2: 结合朝向 ---
用户: 我朝哪个方向？
[LLM → tool_call: get_perception]
阿杜: 你现在面朝东南方向，大概 135 度的样子。
      如果你想往城里走，需要转身朝西南方向。

--- 场景 3: 世界记忆 ---
用户: 我上周去了哪些地方？
[LLM 读 system prompt 里的空间记忆]
阿杜: 下面是虚构的格式示例：上周你主要活动在城市A，
      去过城市B的示例咖啡馆，
      周末的时候去了一趟城市C的示例广场。

--- 场景 4 (V2): 摄像头感知 ---
用户: 帮我看看周围都有什么
[LLM → tool_call: get_perception(include_camera=true) → 拍一帧 → VLM 分析]
阿杜: 我看到你面前是一条双车道的马路，右边有个加油站，
      对面是一排平层商铺，看起来是个小型商业区。
      天气看着还不错，晴天。
"""
