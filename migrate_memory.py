# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-84e7f84ae0c63464bf248fd541026c648f6f9ea9fd2af1745c72d986068913f0"
# Source-SHA256: "80e5123bb37525f31b85e25b0b805db685e4bfbf4169a0e129635d63dd11f9a1"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
import sqlite3, shutil, os, sys
from datetime import datetime

DB_PATH = os.path.expanduser("~/Desktop/backend/data/memory.sqlite3")

def is_uuid_like(s):
    s = s.lower().replace("-", "")
    return len(s) == 32 and all(c in "0123456789abcdef" for c in s)

primary = None
for i, a in enumerate(sys.argv):
    if a == "--primary" and i+1 < len(sys.argv):
        primary = sys.argv[i+1]

con = sqlite3.connect(DB_PATH)
rows = con.execute("SELECT user_key, COUNT(*) as cnt FROM memory_items GROUP BY user_key ORDER BY cnt DESC").fetchall()
print("\n=== 当前分布 ===")
for r in rows: print(f"  {r[0]}  —  {r[1]} 条")

all_keys = [r[0] for r in rows]
if not primary:
    uuid_rows = [r[0] for r in rows if is_uuid_like(r[0])]
    primary = uuid_rows[0]

others = [k for k in all_keys if k.lower() != primary.lower()]
print(f"\n主key: {primary}")
print(f"合并: {others}")

backup = DB_PATH + f".bak_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
shutil.copy2(DB_PATH, backup)
print(f"备份: {backup}")

merged = skipped = 0
for old_key in others:
    items = con.execute("SELECT id, text FROM memory_items WHERE user_key=?", (old_key,)).fetchall()
    for item in items:
        ex = con.execute("SELECT id FROM memory_items WHERE user_key=? AND text=?", (primary, item[1])).fetchone()
        if ex: skipped += 1; continue
        con.execute("UPDATE memory_items SET user_key=? WHERE id=?", (primary, item[0]))
        merged += 1
try:
    for old_key in others:
        con.execute("UPDATE memory_timeline SET user_key=? WHERE user_key=?", (primary, old_key))
except: pass

con.commit(); con.close()
print(f"\n✅ merged={merged} skipped={skipped}")
print(f"\n主key下总记忆条数：")
con2 = sqlite3.connect(DB_PATH)
cnt = con2.execute("SELECT COUNT(*) FROM memory_items WHERE user_key=?", (primary,)).fetchone()[0]
print(f"  {primary}: {cnt} 条")
