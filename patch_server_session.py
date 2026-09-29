#!/usr/bin/env python3
# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-b705aad2aa2953b451be95d079da02fdb28d2d198d44388075cd9554e5919366"
# Source-SHA256: "55a9c5ca39fbe0f4ae5509fbe603baf7e0a4a244472c2552b612bafd92f4076a"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
patch_server_session.py
========================
在 server_session.py 中替换旧的 WebSocket OpenClaw Bridge 为 HTTP 方式。

用法:
    cd ~/Desktop/backend/
    python3 patch_server_session.py

会自动备份原文件为 server_session.py.bak
"""

import re
import shutil
from pathlib import Path

FILE = Path("server_session.py")
if not FILE.exists():
    print("❌ 找不到 server_session.py，请在 backend 目录下运行")
    exit(1)

# 备份
shutil.copy2(FILE, FILE.with_suffix(".py.bak"))
print(f"✅ 已备份: {FILE.with_suffix('.py.bak')}")

code = FILE.read_text(encoding="utf-8")
changes = 0

# ──────────────────────────────────────────────────────
# 改动 1: 替换 import（第 54-56 行附近）
# 旧:  from openclaw_bridge import get_bridge, ensure_connected, OpenClawBridge
# 新:  from openclaw_http import call_openclaw, call_openclaw_stream, openclaw_health
# ──────────────────────────────────────────────────────

old_import = "from openclaw_bridge import get_bridge, ensure_connected, OpenClawBridge"
new_import = "from openclaw_http import call_openclaw, call_openclaw_stream, openclaw_health, extract_openclaw_text"

if old_import in code:
    code = code.replace(old_import, new_import)
    changes += 1
    print("✅ 改动 1: 替换 import")
else:
    print("⚠️ 改动 1: 未找到旧 import（可能已改过）")

# ──────────────────────────────────────────────────────
# 改动 2: 替换 lifespan 中的 OpenClaw 启动/关闭代码
# ──────────────────────────────────────────────────────

old_lifespan_start = '''    # ✅ OpenClaw: 启动时自动连接
    try:
        bridge = get_bridge()
        ok = await bridge.connect()
        if ok:
            log.info("[BOOT] ✅ OpenClaw connected: %s", bridge.ws_url)
        else:
            log.warning("[BOOT] ⚠️ OpenClaw not available (will retry on demand)")
    except Exception as e:
        log.warning("[BOOT] OpenClaw init failed: %s", e)'''

new_lifespan_start = '''    # ✅ OpenClaw: 检查 HTTP API 可用性
    try:
        _oc_health = await openclaw_health()
        if _oc_health.get("ok"):
            log.info("[BOOT] ✅ OpenClaw HTTP API available")
        else:
            log.warning("[BOOT] ⚠️ OpenClaw HTTP API not available: %s", _oc_health.get("status"))
    except Exception as e:
        log.warning("[BOOT] OpenClaw health check failed: %s", e)'''

if old_lifespan_start in code:
    code = code.replace(old_lifespan_start, new_lifespan_start)
    changes += 1
    print("✅ 改动 2: 替换 lifespan 启动代码")
else:
    print("⚠️ 改动 2: 未找到旧 lifespan 启动代码")

old_lifespan_stop = '''    # ✅ OpenClaw: 关闭时断开
    try:
        bridge = get_bridge()
        await bridge.disconnect()
    except Exception:
        pass'''

new_lifespan_stop = '''    # ✅ OpenClaw: HTTP 模式无需关闭连接
    pass'''

if old_lifespan_stop in code:
    code = code.replace(old_lifespan_stop, new_lifespan_stop)
    changes += 1
    print("✅ 改动 3: 替换 lifespan 关闭代码")
else:
    print("⚠️ 改动 3: 未找到旧 lifespan 关闭代码")

# ──────────────────────────────────────────────────────
# 改动 4: 替换 chat_prepare 中的项目上下文注入
# ──────────────────────────────────────────────────────

old_project_ctx = '''    # ✅ OpenClaw: 注入项目上下文（让 AI 理解用户的代码工程）
    try:
        bridge = get_bridge()
        if bridge.connected and bridge._project_cache:
            # 用最新的扫描结果
            latest_scan = list(bridge._project_cache.values())[-1] if bridge._project_cache else None
            if latest_scan:
                project_ctx = bridge.build_project_context(latest_scan)
                if project_ctx:
                    insert_at = 1 if messages and (messages[0].get("role") in ("system", "developer")) else 0
                    messages.insert(insert_at, {"role": "system", "content": project_ctx})
    except Exception as e:
        log.debug("[OpenClaw] project context injection skipped: %s", e)'''

new_project_ctx = '''    # ✅ OpenClaw: HTTP 模式 — 项目上下文由 Gateway Agent 自行管理
    # 如需注入项目上下文，在 OpenClaw Agent 的 system prompt 中配置'''

if old_project_ctx in code:
    code = code.replace(old_project_ctx, new_project_ctx)
    changes += 1
    print("✅ 改动 4: 替换项目上下文注入")
else:
    print("⚠️ 改动 4: 未找到旧项目上下文注入代码")

# ──────────────────────────────────────────────────────
# 写回
# ──────────────────────────────────────────────────────

FILE.write_text(code, encoding="utf-8")
print(f"\n✅ 完成! 共 {changes} 处改动")
print(f"   原文件备份: {FILE.with_suffix('.py.bak')}")
print(f"\n下一步:")
print(f"  1. 把 openclaw_http.py 放到同目录")
print(f"  2. 重启后端: python3 server_session.py")
print(f"  3. 测试: curl http://localhost:8000/agent/health")
