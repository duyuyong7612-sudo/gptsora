# -*- coding: utf-8 -*-
# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-ee1aa1727122e18a6d5c036c659ac9dc6161e01cd68bca4390cb7f5b4f54584a"
# Source-SHA256: "b6478f04b9f61cffc761425a6941b84cda359421f669344a5436baaa7fdc8a50"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""Smoke tests for ChatAGI Memory Graph V2."""
from __future__ import annotations

import os
import tempfile
import time

from memory_module import MemoryConfig, MemoryEngine
from chatagi_memory_core import patch_memory_engine


def assert_true(cond, msg):
    if not cond:
        raise AssertionError(msg)


def _texts(items):
    return " ".join(str(x.get("content") or x.get("text") or x.get("id") or "") for x in items if isinstance(x, dict))


def main() -> None:
    db_path = os.path.join(tempfile.gettempdir(), f"chatagi_memory_graph_test_{int(time.time())}.sqlite3")
    engine = MemoryEngine(MemoryConfig(db_path=db_path, openai_api_key="", embed_provider="local", write_async=False))
    engine.init_db()
    patch_memory_engine(engine)

    user_a = "adu_graph_test_a"
    user_b = "adu_graph_test_b"

    # 1. 创建节点
    up = engine.graph_upsert(
        user_a,
        nodes=[
            {"id": "bug_swiftui_combine", "type": "bug", "text": "ObservableObject 报错: missing Combine import", "importance": 5},
            {"id": "fix_import_combine", "type": "fix", "text": "在 SwiftUI ObservableObject 文件顶部 import Combine", "importance": 5},
            {"id": "file_chat_view", "type": "file", "text": "~/Desktop/GPTsora/GPTsora/ChatView.swift", "importance": 4},
            {"id": "task_fix_swiftui", "type": "task", "text": "修复 SwiftUI ObservableObject 编译错误", "importance": 5},
        ],
        edges=[],
        metadata={"source": "test"},
    )
    assert_true(up.get("ok") and up.get("nodes_upserted") == 4, "node upsert failed")

    # 2. 创建边
    up = engine.graph_upsert(
        user_a,
        nodes=[],
        edges=[
            {"source_id": "bug_swiftui_combine", "target_id": "fix_import_combine", "relation": "fixed_by", "confidence": 0.95},
            {"source_id": "bug_swiftui_combine", "target_id": "file_chat_view", "relation": "occurred_in_file", "confidence": 0.9},
            {"source_id": "task_fix_swiftui", "target_id": "file_chat_view", "relation": "modified", "confidence": 0.92},
            {"source_id": "fix_import_combine", "target_id": "bug_swiftui_combine", "relation": "learned_from", "confidence": 0.85},
        ],
        metadata={"source": "test"},
    )
    assert_true(up.get("ok") and up.get("edges_upserted") == 4, "edge upsert failed")

    # 3. 查询某个 bug 的修复方案
    bug = engine.graph_query(user_a, query="ObservableObject 报错怎么修", k=10)
    bug_text = _texts(bug.get("paths", [])) + " " + _texts(bug.get("nodes", []))
    assert_true("import Combine" in bug_text or "fix_import_combine" in bug_text, "bug fix graph query failed")

    # 4. 查询某个文件发生过哪些错误
    file_q = engine.graph_query(user_a, query="ChatView.swift 发生过哪些错误", k=10)
    file_text = _texts(file_q.get("paths", [])) + " " + _texts(file_q.get("nodes", []))
    assert_true("ObservableObject" in file_text or "bug_swiftui_combine" in file_text, "file bug graph query failed")

    # 5. 查询某个任务修改了哪些文件
    task_q = engine.graph_query(user_a, query="修复 SwiftUI 任务修改了哪些文件", k=10)
    task_text = _texts(task_q.get("paths", [])) + " " + _texts(task_q.get("nodes", []))
    assert_true("ChatView.swift" in task_text or "file_chat_view" in task_text, "task modified files query failed")

    # 6. 查询最近 timeline 关联事件：episode 自动抽图
    ep = engine.write_memory(
        user_a,
        "episode",
        "任务: 修复 ObservableObject 报错。错误: ObservableObject missing Combine。修复: import Combine。结果: done。",
        {
            "goal": "修复 ObservableObject 报错",
            "status": "done",
            "result": "import Combine",
            "files_touched": ["~/Desktop/GPTsora/GPTsora/ChatView.swift"],
            "steps": [{"tool": "py_compile"}, {"tool": "xcodebuild"}],
            "trace_id": "trace-graph-test",
            "importance": 5,
        },
    )
    assert_true(ep.get("ok"), "episode write failed")
    graph_recent = engine.graph_query(user_a, query="最近 ObservableObject import Combine", k=10)
    assert_true(len(graph_recent.get("temporal", [])) >= 1, "temporal edges missing")

    # 7. user_key 隔离
    iso = engine.graph_query(user_b, query="ObservableObject import Combine ChatView.swift", k=10)
    iso_text = str(iso.get("paths", [])) + str(iso.get("nodes", [])) + str(iso.get("edges", []))
    assert_true("ObservableObject" not in iso_text and "ChatView.swift" not in iso_text, "graph user_key isolation failed")

    # 8. hybrid recall 是否返回 graph
    recall = engine.hybrid_recall(user_a, "上次 SwiftUI ObservableObject 那个错误怎么修", k=10)
    graph_hits = recall.get("graph") or []
    assert_true(len(graph_hits) >= 1, "hybrid recall graph bucket empty")
    assert_true("graph" in recall.get("scores", {}), "hybrid recall missing graph scores")

    print("OK test_memory_graph")
    print({
        "db_path": db_path,
        "nodes": len((engine.graph_query(user_a, query="", k=100).get("nodes") or [])),
        "edges": len((engine.graph_query(user_a, query="ObservableObject", k=100).get("edges") or [])),
        "graph_hits": len(graph_hits),
        "temporal_hits": len(graph_recent.get("temporal", [])),
    })


if __name__ == "__main__":
    main()
