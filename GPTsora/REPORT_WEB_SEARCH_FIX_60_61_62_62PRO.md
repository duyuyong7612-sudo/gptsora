# REPORT_WEB_SEARCH_FIX_60_61_62_62PRO

## 结论

本次已完成 iOS 前端最小修复：四个套餐的 `/chat/prepare` 请求都会携带统一联网搜索字段，并在命中“今天/现在/最新/价格/天气/新闻/查一下/搜索/联网/current/latest/today/now”等搜索意图时显式 `force_web_search=true`。

后端 `~/Desktop/backend/server_session.py` 已审计，但当前会话沙箱只允许写 `~/Desktop/GPTsora`，写入 backend 被拒绝。因此后端强制真实搜索、缺 key 明确报错、`[WebSearch]` 日志增强尚未落盘。

## 当前联网搜索链路

- App 文本聊天主链路：`POST /chat/prepare` -> `GET /chat/events/{chat_id}`。
- 前端来源展示：`GPTsora/GPT5ChatService+Streaming.swift` 已解析 SSE `solara.sources`，Home/Job 两个聊天界面会把 sources 渲染成来源条。
- 后端主链路：`server_session.py` 的 `chat_prepare()` 做 plan/model/provider 路由，`_spawn_chat_worker()` 流式调用 provider。
- 后端搜索能力：
  - `CHAT_WEB_PROVIDER=openai` 时，OpenAI Responses API tools 里加入 `{"type":"web_search"}`。
  - `CHAT_WEB_PROVIDER=serper...` 时，`_serper_web_search()` 会预取结果、注入 prompt，并通过 `solara.sources` 发给前端。

## 修复前问题

- 前端主聊天 payload 没有显式 `search_enabled / use_web_search / web_search_enabled`。
- 旧逻辑主要依赖后端 smart router 自动判断，套餐侧没有统一显式搜索 intent。
- 如果后端搜索配置缺失，现有 worker 可能触发普通模型 fallback，存在“离线回答实时问题”的风险。
- 后端缺少要求中的统一日志：`[WebSearch] plan=... enabled=true query=...`、`results_count`、`provider`。

## 修复后前端路由

四个套餐文本聊天均为：

- 6.0 Guest / 机器人 6.0：`POST /chat/prepare`，`plan=guest`，默认模型 `qwen3.6-plus`。
- 6.1 ChatAGI Pro / 机器人 6.1：`POST /chat/prepare`，`plan=pro`，默认模型 `claude-opus-4-7`。
- 6.2 Ultra / 机器人 6.2：`POST /chat/prepare`，`plan=ultra`，默认模型 `claude-opus-4-8`。
- 6.2 Pro Coder / 机器人 6.2 Pro：`POST /chat/prepare`，`plan=coder`，默认模型 `gpt-5.5-pro`。

所有 `/chat/prepare` payload 现在包含：

- `allow_web=true`
- `search_enabled=<intent>`
- `use_web_search=<intent>`
- `web_search_enabled=<intent>`
- `enable_web_search=<intent>`
- `force_web_search=<intent>`

`<intent>` 由本地关键词判断；普通本地问题为 `false`，实时/搜索类问题为 `true`。

## 搜索 Provider

后端当前设计 provider：

- 默认：`CHAT_WEB_PROVIDER=openai`，使用 OpenAI Responses API 内置 web_search 工具。
- 可选：`CHAT_WEB_PROVIDER=serper...`，使用 Serper API，环境变量 `SERPER_API_KEY`。

## 需要环境变量 / API Key

- OpenAI 内置搜索：`OPENAI_API_KEY` 或 `SORA_API_KEY`，`CHAT_WEB_PROVIDER=openai`，`CHAT_ENABLE_WEB_SEARCH=1`。
- Serper 搜索：`SERPER_API_KEY`，`CHAT_WEB_PROVIDER=serper`。
- 可选模型：`OPENAI_WEB_SEARCH_MODEL` / `WEB_SEARCH_MODEL`。

缺配置时，后端应返回：`联网搜索暂不可用：缺少搜索 API 配置`，不能让模型假装搜索。

## 修改文件列表

- `GPTsora/Homechatview.swift`
- `GPTsora/JobAssistantView.swift`
- `GPTsora/GPT5ChatService+Streaming.swift`
- `scripts/test_web_search_60_61_62_62pro.sh`
- `REPORT_WEB_SEARCH_FIX_60_61_62_62PRO.md`

未修改：

- `GPTsora/RealtimeAVService.swift`
- `~/Desktop/backend/server_session.py`（沙箱拒绝写入）
- RunPod 8006 实时语音后端
- 电脑控制 / 机器人 hexapod 后端

## 后端仍需落盘的最小修复

在 `server_session.py` 中补：

- plan 搜索深度：guest=3、pro=5、ultra=8、coder=10。
- `_extract_allow_web()` 增加 `search_enabled / use_web_search / web_search_enabled` aliases。
- 当 route_decision `need_web=true` 时打印：
  - `[WebSearch] plan=6.0 enabled=true query=...`
  - `[WebSearch] plan=6.1 enabled=true query=...`
  - `[WebSearch] plan=6.2 enabled=true query=...`
  - `[WebSearch] plan=6.2pro enabled=true query=...`
  - `[WebSearch] results_count=...`
  - `[WebSearch] provider=...`
- 若搜索 provider 缺 key 或禁用，SSE 返回明确 error：`联网搜索暂不可用：缺少搜索 API 配置`。
- 搜索失败时不能 fallback 到普通模型生成“看起来查过”的回答。

## curl 测试命令

运行：

```bash
BASE_URL=http://YOUR_LAN_IP:8000 ./scripts/test_web_search_60_61_62_62pro.sh
```

单条示例：

```bash
curl -sS -X POST http://YOUR_LAN_IP:8000/chat/prepare \
  -H 'Content-Type: application/json' \
  -H 'X-ChatAGI-Plan: coder' \
  -d '{"plan":"coder","model":"gpt-5.5-pro","messages":[{"role":"user","content":"搜索 OpenAI Realtime API response.output_audio.delta 文档"}],"allow_web":true,"search_enabled":true,"use_web_search":true,"web_search_enabled":true,"enable_web_search":true,"force_web_search":true,"stream":true}'
```

## App 真机测试步骤

1. 选择 Guest，发送“今天 OpenAI 有什么新消息”。
2. 选择 ChatAGI Pro，发送“查一下 RunPod A100 当前价格”。
3. 选择 Ultra，发送“最新 Gemini Live 有什么能力”。
4. 选择 Coder，发送“搜索 OpenAI Realtime API response.output_audio.delta 文档”。
5. 确认气泡下方出现来源条，或后端明确返回“联网搜索暂不可用：缺少搜索 API 配置”。
6. 发送“你是谁”“帮我写一段自我介绍”等普通问题，确认不会强制搜索。

## 实时语音确认

本次没有修改 `RealtimeAVService.swift`，没有修改 `AppConfig.Realtime.nativeRealtimeWSURLString`，没有修改 6.1 实时语音链路：

`ws://YOUR_LAN_IP:8006/v1/realtime?mode=audio`

也没有修改 `result.audio_data` / `response.output_audio.delta` 播放逻辑。

## 验证结果

- 静态搜索确认三个前端入口已带搜索字段。
- `xcodebuild -list -project GPTsora.xcodeproj` 未通过，原因是沙箱不能写 `~/.cache/clang` / SwiftPM diagnostics，且 CoreSimulatorService 不可用。
