#!/usr/bin/env bash
# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-c5e246e6a0d7f2fb0d3e38f50c297d123f1ffebf975cbcf18f593028de8417c3"
# Source-SHA256: "47a49d12f2ceec9468fdb733364c609d5c9aaf12bae9e4f2c8ff0afaef61e16f"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
set -euo pipefail

BASE_URL="${BASE_URL:-http://YOUR_LAN_IP:8000}"

post_chat_prepare() {
  local plan="$1"
  local model="$2"
  local text="$3"

  echo
  echo "== plan=${plan} model=${model}"
  curl -sS -X POST "${BASE_URL}/chat/prepare" \
    -H "Content-Type: application/json" \
    -H "X-ChatAGI-Plan: ${plan}" \
    -d "$(cat <<JSON
{
  "plan": "${plan}",
  "model": "${model}",
  "messages": [
    {"role": "user", "content": "${text}"}
  ],
  "allow_web": true,
  "search_enabled": true,
  "use_web_search": true,
  "web_search_enabled": true,
  "enable_web_search": true,
  "force_web_search": true,
  "stream": true
}
JSON
)" | python3 -m json.tool
}

post_chat_prepare "guest" "qwen3.6-plus" "今天 OpenAI 有什么新消息"
post_chat_prepare "pro" "claude-opus-4-7" "查一下 RunPod A100 当前价格"
post_chat_prepare "ultra" "claude-opus-4-8" "最新 Gemini Live 有什么能力"
post_chat_prepare "coder" "gpt-5.5-pro" "搜索 OpenAI Realtime API response.output_audio.delta 文档"

cat <<'EOF'

Expected backend log lines:
[WebSearch] plan=6.0 enabled=true query=...
[WebSearch] plan=6.1 enabled=true query=...
[WebSearch] plan=6.2 enabled=true query=...
[WebSearch] plan=6.2pro enabled=true query=...
[WebSearch] results_count=...
[WebSearch] provider=...

If search credentials are missing, the backend must return:
联网搜索暂不可用：缺少搜索 API 配置
EOF
