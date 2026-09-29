#!/usr/bin/env python3
# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-c1ee71a3bd204e0b6dd65d76400a225f466eac80e2d79f478a9e1e7271bdf455"
# Source-SHA256: "33525e390bda0c84c0bd6d62d31238b1e800f76c9dbbd68ef4093f272cc2c351"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
import time
import json
import requests

BASE_URL = "http://127.0.0.1:8000"

def headers(device_id: str):
    return {
        "Content-Type": "application/json",
        "X-Device-ID": device_id,
        "X-Client-Device-ID": device_id,
        "X-ChatAGI-Device-ID": device_id,
    }

def post(path, device_id, payload):
    r = requests.post(
        BASE_URL + path,
        headers=headers(device_id),
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        timeout=20,
    )
    print(f"POST {path} {r.status_code} {r.text[:500]}")
    r.raise_for_status()
    return r.json()

def get_context(device_id, query):
    r = requests.get(
        BASE_URL + "/memory/context",
        headers=headers(device_id),
        params={"q": query},
        timeout=20,
    )
    print(f"GET  /memory/context {r.status_code} user={device_id}")
    print(r.text[:800])
    r.raise_for_status()
    return r.json()

def memory_payload_text(obj):
    """
    只检查真正的记忆字段，不检查 URL、query、打印日志。
    """
    parts = [
        obj.get("facts_text") or "",
        obj.get("timeline_text") or "",
        obj.get("semantic_text") or "",
        obj.get("recent_text") or "",
        obj.get("full_prompt") or "",
    ]
    return "\n".join(parts)

def main():
    marker = str(int(time.time() * 1000))
    device_a = f"guest_A_{marker}"
    device_b = f"guest_B_{marker}"

    fact = f"隔离测试A喜欢黑咖啡 {marker}"
    vector = f"隔离测试A的向量记忆：黑咖啡 {marker}"
    query = f"黑咖啡 {marker}"

    post("/memory/facts/add", device_a, {
        "content": fact,
        "tags": "memory_isolation_test",
        "importance": 5,
    })

    post("/memory/add", device_a, {
        "text": vector,
    })

    ctx_a = get_context(device_a, query)
    ctx_b = get_context(device_b, query)

    text_a = memory_payload_text(ctx_a)
    text_b = memory_payload_text(ctx_b)

    if marker not in text_a:
        print("\n❌ Memory isolation FAIL: User A cannot retrieve its own memory")
        raise SystemExit(1)

    if marker in text_b or "隔离测试A" in text_b or "黑咖啡" in text_b:
        print("\n❌ Memory isolation FAIL: User B can see User A memory")
        print("B memory fields:")
        print(text_b)
        raise SystemExit(1)

    if ctx_a.get("user_key") == ctx_b.get("user_key"):
        print("\n❌ Memory isolation FAIL: A and B have same user_key")
        raise SystemExit(1)

    print("\n✅ Memory isolation PASS")
    print(f"A user_key: {ctx_a.get('user_key')}")
    print(f"B user_key: {ctx_b.get('user_key')}")

if __name__ == "__main__":
    main()
