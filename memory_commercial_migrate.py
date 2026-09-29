# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-6af009ab60e09da149e4f9c8a1ce7461c6a7d4167f87d125d1bb7fe1786e65ee"
# Source-SHA256: "303df62b35d78939326944ff817eb20fc507d8a3d80c6b1395d66b26390d55fb"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
Optional SQLite migration for commercial memory metadata columns.
Run from backend directory:
  python memory_commercial_migrate.py

This does NOT change current queries. It only prepares columns for future cloud/Postgres migration.
"""

import os
import sqlite3
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
DB_PATH = Path(os.getenv("MEM_DB_PATH") or (BASE_DIR / "data" / "memory.sqlite3"))

TABLES = ["memory_items", "memory_facts", "memory_timeline", "memory_episodes"]
COLUMNS = [
    ("tenant_id", "TEXT DEFAULT ''"),
    ("account_user_id", "TEXT DEFAULT ''"),
    ("project_id", "TEXT DEFAULT 'default'"),
    ("identity_type", "TEXT DEFAULT ''"),
]


def has_table(con, table: str) -> bool:
    row = con.execute("SELECT name FROM sqlite_master WHERE type='table' AND name=?", (table,)).fetchone()
    return bool(row)


def has_column(con, table: str, column: str) -> bool:
    rows = con.execute(f"PRAGMA table_info({table})").fetchall()
    return any(str(r[1]) == column for r in rows)


def main() -> None:
    print(f"DB: {DB_PATH}")
    if not DB_PATH.exists():
        raise SystemExit(f"DB not found: {DB_PATH}")
    con = sqlite3.connect(str(DB_PATH))
    try:
        for table in TABLES:
            if not has_table(con, table):
                print(f"skip missing table: {table}")
                continue
            for col, ddl in COLUMNS:
                if not has_column(con, table, col):
                    print(f"ALTER {table} ADD {col}")
                    con.execute(f"ALTER TABLE {table} ADD COLUMN {col} {ddl}")
            if has_column(con, table, "tenant_id") and has_column(con, table, "account_user_id"):
                try:
                    con.execute(f"CREATE INDEX IF NOT EXISTS idx_{table}_tenant_user ON {table}(tenant_id, account_user_id)")
                except Exception as e:
                    print(f"index warning {table}: {e}")
        con.commit()
    finally:
        con.close()
    print("OK")


if __name__ == "__main__":
    main()
