# REPORT_WEB_SEARCH_RECOVERY_FIX

## 结论

本次定位到的旧链路不是一个新搜索系统，而是现有 `/chat/prepare` / `/chat` 普通聊天链路里的 OpenAI Responses API built-in `web_search`：

- App 普通聊天发送到 `/chat/prepare`。
- 前端 payload 已带 `plan`、`model`、`allow_web=true`，并在命中搜索意图时带：
  - `search_enabled`
  - `use_web_search`
  - `web_search_enabled`
  - `enable_web_search`
  - `force_web_search`
- 后端 `server_session.py` 通过 `_smart_router_decision()` 判断 `openai_web_search`。
- 后端 `_route_provider()` 应在联网意图确认后走 OpenAI。
- OpenAI 调用点是 `_stream_openai_events()` / `_openai_responses_create_nonstream()`，工具为 `{"type": "web_search"}`，include 为 `web_search_call.action.sources`。
- SSE sources 通过 `sources` / `solara.sources` 推给 iOS UI。

## 现在断在哪

受当前沙箱限制，`~/Desktop/backend/server_session.py` 位于可写根之外，本次无法直接落盘修改该文件。已确认 `apply_patch` 被拒绝：

`writing outside of the project; rejected by user approval settings`

代码层面定位到的主要断点：

1. `_route_provider()` 当前先判断 Claude 模型：
   `if _is_claude_model(model): return "anthropic", "explicit_claude_model"`

   这会让 6.1 / 6.2 的联网请求优先走 Anthropic，而不是恢复到原注释描述的 OpenAI built-in `web_search` 链路。

2. `_smart_router_force_web_from_body()` 没兼容旧/现有前端字段：
   `search_enabled` / `use_web_search` / `web_search_enabled`

   如果某些入口只传这些字段而没有 `force_web_search`，后端可能只把 `allow_web` 当“许可”，再被普通路由降回 normal chat。

3. `_extract_allow_web()` 没兼容 `allow_web_first`。

4. 后端日志当前主要是 `[chat-route] ...`，没有用户要求的：
   `[WebSearch] enabled=true plan=... provider=... results_count=...`

5. 缺搜索 API key 时，目前 OpenAI header 处可能抛 `missing OPENAI_API_KEY / SORA_API_KEY`，不是明确的：
   `联网搜索暂不可用：缺少搜索 API 配置`

## 需要应用的最小后端补丁

目标文件：`~/Desktop/backend/server_session.py`

### 1. 字段兼容

在 `_extract_allow_web()` 的 body flags 里加入：

```python
"allow_web_first", "allowWebFirst"
```

在 `_smart_router_force_web_from_body()` 的 true-only 强制联网字段里加入：

```python
"search_enabled", "searchEnabled",
"use_web_search", "useWebSearch",
"web_search_enabled", "webSearchEnabled",
```

### 2. 恢复 OpenAI web_search 主链路

在 `_route_provider()` 中，把：

```python
if allow_web:
    return "openai", "smart_router_decision:web_search"
```

移动到 Claude 固定路由之前。含义：只有 `_smart_router_decision()` 已确认本轮 `need_web=true` 时，四个套餐都进入 OpenAI built-in web_search；普通非搜索聊天仍按原模型路由，不影响 6.1 实时语音。

### 3. 缺 key 明确返回

在 `/chat` 和 `/chat/prepare` 中，`route_decision` 后、`_ensure_provider_available()` 前检查：

```python
if allow_web:
    if CHAT_WEB_PROVIDER.startswith("serper") and not SERPER_API_KEY:
        return JSONResponse({"ok": False, "error": "联网搜索暂不可用：缺少搜索 API 配置"}, status_code=503)
    if not CHAT_WEB_PROVIDER.startswith("serper") and not OPENAI_API_KEY:
        return JSONResponse({"ok": False, "error": "联网搜索暂不可用：缺少搜索 API 配置"}, status_code=503)
```

### 4. WebSearch 日志

在 `/chat`、`/chat/prepare` 路由确认后打印：

```python
log.info("[WebSearch] enabled=%s plan=%s provider=%s results_count=%s route=%s",
         bool(allow_web), plan, CHAT_WEB_PROVIDER, 0, route_decision.get("route"))
```

在 worker `_push_sources()` 成功合并 sources 后打印：

```python
log.info("[WebSearch] enabled=true plan=%s provider=%s results_count=%s",
         plan, CHAT_WEB_PROVIDER, len(web_sources))
```

Serper 预取成功后也应按实际 `len(web_results)` 打印。

## 四个套餐如何传 search flag

当前前端已确认：

- `GPTsora/Homechatview.swift`
  - `prepareChat(...)` payload 包含 `plan: selectedPlan.rawValue`
  - `allowWeb: true`
  - `searchEnabled/useWebSearch/webSearchEnabled/enableWebSearch/forceWebSearch`
  - `searchEnabled` 来自 `shouldEnableWebSearchForQuery(t)`

- `GPTsora/JobAssistantView.swift`
  - 同样通过 `prepareChat(...)` 发送 `plan`、`model`、`allowWeb=true` 和 search flags。

四个套餐对应：

- Guest / 机器人 6.0：`plan=guest`
- ChatAGI Pro / 机器人 6.1：`plan=pro`
- Ultra / 机器人 6.2：`plan=ultra`
- Coder / 机器人 6.2 Pro：`plan=coder`

## Provider

当前 `.env` 检查结果：

- `OPENAI_API_KEY`: present
- `CHAT_ENABLE_WEB_SEARCH`: present
- `CHAT_WEB_PROVIDER`: present
- `TAVILY_API_KEY`: missing
- `SERPER_API_KEY`: missing
- `BRAVE_API_KEY`: missing
- `BING_API_KEY`: missing

当前后端代码默认和注释都指向 OpenAI built-in `web_search`。因此恢复目标 provider 是 OpenAI，不需要 Tavily/Serper/Brave/Bing，除非 `CHAT_WEB_PROVIDER` 被显式改成对应 provider。

## 测试命令

替换 `BASE` 为 AppConfig 当前后端：`http://YOUR_LAN_IP:8000`。

```bash
BASE="http://YOUR_LAN_IP:8000"

curl -sS "$BASE/debug/web_provider"

curl -sS "$BASE/chat/prepare" \
  -H 'Content-Type: application/json' \
  -H 'X-ChatAGI-Plan: guest' \
  -d '{"plan":"guest","model":"qwen3.6-plus","messages":[{"role":"user","content":"查一下今天 OpenAI 最新消息"}],"allow_web":true,"search_enabled":true,"use_web_search":true,"web_search_enabled":true,"enable_web_search":true,"force_web_search":true}'

curl -sS "$BASE/chat/prepare" \
  -H 'Content-Type: application/json' \
  -H 'X-ChatAGI-Plan: pro' \
  -d '{"plan":"pro","model":"claude-opus-4-7","messages":[{"role":"user","content":"查一下 RunPod A100 当前价格"}],"allow_web":true,"search_enabled":true,"use_web_search":true,"web_search_enabled":true,"enable_web_search":true,"force_web_search":true}'

curl -sS "$BASE/chat/prepare" \
  -H 'Content-Type: application/json' \
  -H 'X-ChatAGI-Plan: ultra' \
  -d '{"plan":"ultra","model":"claude-opus-4-8","messages":[{"role":"user","content":"最新 Gemini Live 有什么能力"}],"allow_web":true,"search_enabled":true,"use_web_search":true,"web_search_enabled":true,"enable_web_search":true,"force_web_search":true}'

curl -sS "$BASE/chat/prepare" \
  -H 'Content-Type: application/json' \
  -H 'X-ChatAGI-Plan: coder' \
  -d '{"plan":"coder","model":"gpt-5.5-pro","messages":[{"role":"user","content":"搜索 OpenAI Realtime API response.output_audio.delta 文档"}],"allow_web":true,"search_enabled":true,"use_web_search":true,"web_search_enabled":true,"enable_web_search":true,"force_web_search":true}'
```

预期：

- 后端日志出现 `[WebSearch] enabled=true plan=... provider=... results_count=...`
- 有 OpenAI key 时，SSE 后续应出现 `solara.sources`，最终 `results_count > 0`。
- 缺 key 时，HTTP 503 返回：`联网搜索暂不可用：缺少搜索 API 配置`。

## 未修改确认

本次未修改以下内容：

- `GPTsora/RealtimeAVService.swift`
- 6.1 黑色实时语音按钮
- `ws://YOUR_LAN_IP:8006/v1/realtime?mode=audio`
- RunPod / MiniCPM / 8006 实时语音链路
- hexapod 机器人后端
- 电脑控制
- 模型选择 UI 文案
- 普通非搜索聊天行为

