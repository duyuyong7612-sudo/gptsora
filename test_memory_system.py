# -*- coding: utf-8 -*-
# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-5bea5ced5fb8f1eacfaa36c722fba5fa38d2e72c35747039ea5558531c795267"
# Source-SHA256: "87272499d1f46e357cf0d7bb06d617dea3d43c5ac7c85b153f90009712c7d418"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""Smoke tests for ChatAGI Memory Core V2."""
from __future__ import annotations

import os
import tempfile
import time

from memory_module import MemoryConfig, MemoryEngine
from chatagi_memory_core import patch_memory_engine


def assert_true(cond, msg):
    if not cond:
        raise AssertionError(msg)


def main() -> None:
    db_path = os.path.join(tempfile.gettempdir(), f"chatagi_memory_system_test_{int(time.time())}.sqlite3")
    engine = MemoryEngine(MemoryConfig(db_path=db_path, openai_api_key="", embed_provider="local", write_async=False))
    engine.init_db()
    patch_memory_engine(engine)

    user_a = "adu_memory_test_a"
    user_b = "adu_memory_test_b"

    # 1. fact write
    r = engine.write_memory(user_a, "fact", "用户要求 SwiftUI 使用 ObservableObject 时必须 import Combine", {"source": "test", "importance": 5})
    assert_true(r.get("ok"), "fact write failed")

    # 2. fact recall/list
    facts = engine.facts_list(user_a, limit=10)
    assert_true(any("ObservableObject" in f.get("content", "") for f in facts), "fact list missing item")

    # 3. vector write
    engine.write_memory(user_a, "raw", "SwiftUI ObservableObject 报错时，通常是缺少 Combine import 或类型作用域不对", {"source": "test", "role": "user"})

    # 4. vector recall
    vec = engine.search_vectors(user_a, "ObservableObject Combine", k=5, min_score=0.01)
    assert_true(len(vec) >= 1, "vector recall empty")
    assert_true(float(vec[0].get("score", 0)) > 0, "vector score invalid")

    # 5. timeline write
    engine.write_memory(user_a, "timeline", "完成手机控制电脑 loop 接入", {"event_type": "test_event", "source": "test", "trace_id": "trace-memory-test"})

    # 6. timeline query
    timeline = engine.timeline_v2(user_a, limit=20)
    assert_true(any("手机控制电脑" in t.get("summary", "") for t in timeline), "timeline missing event")

    # 7. episode write
    ep = engine.write_memory(user_a, "episode", "目标: 打通手机控制电脑。过程: screenshot -> open_app WeChat -> screenshot。结果: done。", {"goal": "手机控制电脑", "status": "done", "result": "done", "steps": [{"action": "screenshot"}], "trace_id": "trace-memory-test"})
    assert_true(ep.get("ok"), "episode write failed")

    # 8. episode query
    episodes = engine.episode_list(user_a, limit=20)
    assert_true(any("手机控制电脑" in e.get("summary", "") or "手机控制电脑" in e.get("goal", "") for e in episodes), "episode list missing")

    # 9. procedure write
    pr = engine.write_memory(user_a, "procedural", "SwiftUI ObservableObject 编译失败时，先检查是否 import Combine，再检查 @StateObject/@ObservedObject 类型。", {"title": "Fix SwiftUI ObservableObject", "tags": "swiftui,procedure", "importance": 5})
    assert_true(pr.get("ok"), "procedure write failed")

    # 10. procedure query
    procedures = engine.procedures_list(user_a, limit=20)
    assert_true(any("ObservableObject" in p.get("content", "") for p in procedures), "procedure list missing")

    # 11. hybrid recall
    recall = engine.hybrid_recall(user_a, "SwiftUI ObservableObject 报错怎么修", k=10, include=["facts", "vector", "timeline", "episodes", "procedural"])
    assert_true(recall.get("ok"), "hybrid recall not ok")
    assert_true(len(recall.get("facts", [])) >= 1, "hybrid facts empty")
    assert_true(len(recall.get("vector", [])) >= 1, "hybrid vector empty")
    assert_true(len(recall.get("procedural", [])) >= 1, "hybrid procedural empty")

    # 12. consolidation dry_run
    dry = engine.consolidate_memory(user_a, scope="recent", dry_run=True)
    assert_true(dry.get("ok") and dry.get("dry_run"), "consolidation dry_run failed")

    # 13. consolidation apply
    applied = engine.consolidate_memory(user_a, scope="recent", dry_run=False)
    assert_true(applied.get("ok") and not applied.get("dry_run"), "consolidation apply failed")

    # 14. user isolation
    recall_b = engine.hybrid_recall(user_b, "ObservableObject Combine 手机控制电脑", k=10, include=["facts", "vector", "timeline", "episodes", "procedural"])
    leaked_parts = []
    for bucket in ["facts", "vector", "timeline", "episodic", "procedural", "working"]:
        leaked_parts.extend(recall_b.get(bucket, []))
    leaked_text = str(leaked_parts)
    assert_true("ObservableObject" not in leaked_text and "手机控制电脑" not in leaked_text, "user_key isolation failed")

    print("OK test_memory_system")
    print({
        "db_path": db_path,
        "fact_count": len(facts),
        "vector_hits": len(vec),
        "timeline_count": len(timeline),
        "episode_count": len(episodes),
        "procedure_count": len(procedures),
        "hybrid_counts": {k: len(recall.get(k, [])) for k in ["facts", "vector", "timeline", "episodic", "procedural", "working"]},
        "dry_trace": dry.get("trace_id"),
        "apply_trace": applied.get("trace_id"),
    })


if __name__ == "__main__":
    main()
