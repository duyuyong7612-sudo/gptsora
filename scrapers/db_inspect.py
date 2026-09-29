# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-1df0b3aa263ad928f83b713d164d57340f0bfc68f6d10499608d62fd1aba33ca"
# Source-SHA256: "56c63f7e8731226f8b01752bcacdaf4cc1118828e6f28c30411196199b7798c4"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
inspect.py — 数据库观察工具

用法:
  python3 inspect.py           # 显示统计 + 最新 10 条
  python3 inspect.py 30        # 显示统计 + 最新 30 条
  python3 inspect.py runs      # 显示最近的 scraping_runs
"""

from __future__ import annotations

import sys
from db import db_connect, count_jobs, get_recent_jobs, init_db


def show_recent(limit: int = 10):
    with db_connect() as conn:
        stats = count_jobs(conn)
        print("📊 Statistics:")
        for k, v in stats.items():
            print(f"  {k:30s} = {v}")
        print()

        recent = get_recent_jobs(conn, limit=limit)
        print(f"📰 Most recent {len(recent)} jobs:")
        print("-" * 80)
        for j in recent:
            print(f"[{j['source']}/{j['category']}/{j['sub_category']}] {j['title']}")
            if j["phone"]:
                print(f"   📞 {j['phone']}")
            if j["wechat"]:
                print(f"   💬 微信: {j['wechat']}")
            if j["salary_text"]:
                print(f"   💰 {j['salary_text']}")
            if j["packaged"]:
                print(f"   🏠 包食宿")
            print(f"   🔗 {j['source_url']}")
            print(f"   🕒 scraped {j['scraped_at']}")
            if j["body"]:
                snippet = j["body"][:120].replace("\n", " ")
                print(f"   📝 {snippet}...")
            print()


def show_runs(limit: int = 10):
    with db_connect() as conn:
        cur = conn.execute(
            "SELECT * FROM scraping_runs ORDER BY started_at DESC LIMIT ?",
            (limit,),
        )
        rows = cur.fetchall()
        print(f"🏃 Last {len(rows)} scraping runs:")
        print("-" * 80)
        for r in rows:
            print(f"#{r['id']}  [{r['source']}]  {r['status']}")
            print(f"  started: {r['started_at']}")
            print(f"  finished: {r['finished_at']}")
            print(f"  new={r['new_count']} updated={r['updated_count']} "
                  f"skipped={r['skipped_count']} errors={r['error_count']}")
            if r["error_message"]:
                print(f"  ⚠️  error: {r['error_message']}")
            if r["note"]:
                print(f"  📝 note: {r['note']}")
            print()


if __name__ == "__main__":
    init_db()

    arg = sys.argv[1] if len(sys.argv) > 1 else "10"

    if arg == "runs":
        show_runs()
    else:
        try:
            n = int(arg)
        except ValueError:
            n = 10
        show_recent(n)
