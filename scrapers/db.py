# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-afa68a53d02937c05af53934a7de0fc973c94071a9db1dab5d2d331ddff3a404"
# Source-SHA256: "92b3345b5461631fcc4c1c75c63b66806702fbbb889718e183918532ba8e3ee9"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
db.py — SQLite 数据库初始化与 CRUD

设计原则:
1) 单文件 SQLite,放在 ~/Desktop/backend/data/jobs.db
2) 用裸 sqlite3,不引入 SQLAlchemy(零依赖,启动快)
3) 用 source + source_id 做唯一约束(重复爬不入库,只更新 updated_at)
4) 所有时间用 UTC ISO8601 字符串存储

schema 完全对应规划文档:
  jobs: 主表,5 类业务全用这一张
  scraping_runs: 爬虫运行日志,排查问题
"""

from __future__ import annotations

import os
import sqlite3
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional

# -----------------------------------------------------------------------------
# 路径配置
# -----------------------------------------------------------------------------

# 默认位置:scrapers 目录的上一级 backend/data/jobs.db
# 实际部署时由 runner.py 通过环境变量覆盖
DEFAULT_DB_DIR = Path(__file__).resolve().parent.parent / "data"
DEFAULT_DB_PATH = DEFAULT_DB_DIR / "jobs.db"


def get_db_path() -> Path:
    """允许通过 HUARENAI_DB_PATH 环境变量覆盖默认位置"""
    env = os.environ.get("HUARENAI_DB_PATH")
    if env:
        return Path(env).expanduser().resolve()
    return DEFAULT_DB_PATH


# -----------------------------------------------------------------------------
# 时间工具
# -----------------------------------------------------------------------------

def now_iso() -> str:
    """当前 UTC 时间,ISO8601 字符串"""
    return datetime.now(timezone.utc).isoformat()


# -----------------------------------------------------------------------------
# Schema
# -----------------------------------------------------------------------------

SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS jobs (
    id              TEXT PRIMARY KEY,
    source          TEXT NOT NULL,
    source_id       TEXT NOT NULL,
    source_url      TEXT NOT NULL,

    -- 业务分类(我们自己的归类)
    category        TEXT,            -- "找工" / "招人" / "生意买卖" / "租房" / "二手"
    sub_category    TEXT,            -- "炒锅" / "前台" / 站点版块原名等

    -- 内容字段
    title           TEXT NOT NULL,
    body            TEXT,            -- 帖子正文纯文本(摘要,< 2000 字符)

    -- 解析出来的结构化字段(尽力而为,有就填)
    city            TEXT,
    area            TEXT,
    salary_text     TEXT,            -- 原文 "$1500/周"
    salary_min      INTEGER,
    salary_max      INTEGER,
    salary_unit     TEXT,            -- "hour/week/month/nego"
    work_type       TEXT,            -- "fulltime/parttime/temp"
    packaged        INTEGER,         -- 包食宿: 0/1/NULL
    phone           TEXT,
    wechat          TEXT,
    contact_name    TEXT,

    -- 时间
    posted_at       TEXT,            -- 原帖发布时间(ISO8601)
    updated_at_src  TEXT,            -- 原帖更新时间(ISO8601)
    scraped_at      TEXT NOT NULL,   -- 我们抓到的时间

    -- 状态
    is_active       INTEGER DEFAULT 1,
    raw_text        TEXT,            -- 原始 HTML 片段(留备查/调试),最多 5000 字符

    UNIQUE(source, source_id)
);

CREATE INDEX IF NOT EXISTS idx_jobs_category ON jobs(category, sub_category);
CREATE INDEX IF NOT EXISTS idx_jobs_city ON jobs(city, area);
CREATE INDEX IF NOT EXISTS idx_jobs_posted ON jobs(posted_at DESC);
CREATE INDEX IF NOT EXISTS idx_jobs_scraped ON jobs(scraped_at DESC);
CREATE INDEX IF NOT EXISTS idx_jobs_source ON jobs(source, source_id);


CREATE TABLE IF NOT EXISTS scraping_runs (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    source          TEXT NOT NULL,
    started_at      TEXT NOT NULL,
    finished_at     TEXT,
    status          TEXT,            -- "running/success/partial/failed"
    new_count       INTEGER DEFAULT 0,
    updated_count   INTEGER DEFAULT 0,
    skipped_count   INTEGER DEFAULT 0,
    error_count     INTEGER DEFAULT 0,
    error_message   TEXT,
    note            TEXT             -- 这次运行的概要描述
);

CREATE INDEX IF NOT EXISTS idx_runs_started ON scraping_runs(started_at DESC);
"""


# -----------------------------------------------------------------------------
# 连接 / 初始化
# -----------------------------------------------------------------------------

def init_db(db_path: Optional[Path] = None) -> Path:
    """创建数据库(如不存在)和表结构。返回最终用的路径。"""
    p = db_path or get_db_path()
    p.parent.mkdir(parents=True, exist_ok=True)

    with sqlite3.connect(str(p)) as conn:
        conn.executescript(SCHEMA_SQL)
        conn.commit()

    return p


@contextmanager
def db_connect(db_path: Optional[Path] = None):
    """上下文管理器:打开连接,row_factory 设为 dict,自动 close"""
    p = db_path or get_db_path()
    conn = sqlite3.connect(str(p), timeout=30)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
    finally:
        conn.close()


# -----------------------------------------------------------------------------
# jobs 表 CRUD
# -----------------------------------------------------------------------------

JOB_COLUMNS = [
    "id", "source", "source_id", "source_url",
    "category", "sub_category",
    "title", "body",
    "city", "area",
    "salary_text", "salary_min", "salary_max", "salary_unit",
    "work_type", "packaged",
    "phone", "wechat", "contact_name",
    "posted_at", "updated_at_src", "scraped_at",
    "is_active", "raw_text",
]


def make_job_id(source: str, source_id: str) -> str:
    """统一的 PK 生成:source:source_id"""
    return f"{source}:{source_id}"


def upsert_job(conn: sqlite3.Connection, job: Dict[str, Any]) -> str:
    """
    Upsert 一条 job 记录。
    - 如果 (source, source_id) 已存在 → 更新现有记录(保留原 scraped_at,仅更新内容)
    - 否则 → 插入
    返回这条记录的状态: "new" / "updated" / "skipped"
    """
    source = job["source"]
    source_id = job["source_id"]
    job_id = make_job_id(source, source_id)
    job["id"] = job_id
    job["scraped_at"] = job.get("scraped_at") or now_iso()
    job["is_active"] = job.get("is_active", 1)

    # 检查是否已存在
    cur = conn.execute(
        "SELECT id, title, body FROM jobs WHERE source = ? AND source_id = ?",
        (source, source_id),
    )
    existing = cur.fetchone()

    if existing is None:
        # INSERT
        cols = [c for c in JOB_COLUMNS if c in job]
        placeholders = ",".join(["?"] * len(cols))
        col_str = ",".join(cols)
        values = [job.get(c) for c in cols]

        conn.execute(
            f"INSERT INTO jobs ({col_str}) VALUES ({placeholders})",
            values,
        )
        return "new"

    # 已存在 — 如果内容没变化,只更新 scraped_at;否则全量更新
    if existing["title"] == job.get("title") and (existing["body"] or "") == (job.get("body") or ""):
        conn.execute(
            "UPDATE jobs SET scraped_at = ? WHERE source = ? AND source_id = ?",
            (job["scraped_at"], source, source_id),
        )
        return "skipped"

    # 内容变了,更新
    cols = [c for c in JOB_COLUMNS if c in job and c not in ("id", "source", "source_id")]
    set_clause = ",".join(f"{c} = ?" for c in cols)
    values = [job.get(c) for c in cols]
    values += [source, source_id]

    conn.execute(
        f"UPDATE jobs SET {set_clause} WHERE source = ? AND source_id = ?",
        values,
    )
    return "updated"


def get_recent_jobs(
    conn: sqlite3.Connection,
    category: Optional[str] = None,
    days: int = 7,
    limit: int = 20,
) -> List[Dict[str, Any]]:
    """按发布时间倒序拿最近 N 条记录"""
    sql = "SELECT * FROM jobs WHERE is_active = 1"
    params: List[Any] = []

    if category:
        sql += " AND category = ?"
        params.append(category)

    sql += " ORDER BY posted_at DESC NULLS LAST, scraped_at DESC LIMIT ?"
    params.append(limit)

    cur = conn.execute(sql, params)
    return [dict(r) for r in cur.fetchall()]


def count_jobs(conn: sqlite3.Connection) -> Dict[str, int]:
    """统计:总数 + 按 source 分组 + 按 category 分组"""
    out: Dict[str, int] = {"total": 0}

    cur = conn.execute("SELECT COUNT(*) AS c FROM jobs WHERE is_active = 1")
    out["total"] = cur.fetchone()["c"]

    cur = conn.execute("SELECT source, COUNT(*) AS c FROM jobs WHERE is_active = 1 GROUP BY source")
    for row in cur.fetchall():
        out[f"source:{row['source']}"] = row["c"]

    cur = conn.execute(
        "SELECT category, COUNT(*) AS c FROM jobs WHERE is_active = 1 GROUP BY category"
    )
    for row in cur.fetchall():
        if row["category"]:
            out[f"category:{row['category']}"] = row["c"]

    return out


# -----------------------------------------------------------------------------
# scraping_runs 表 CRUD
# -----------------------------------------------------------------------------

def start_run(conn: sqlite3.Connection, source: str, note: str = "") -> int:
    """开启一次抓取记录,返回 run_id"""
    cur = conn.execute(
        """
        INSERT INTO scraping_runs (source, started_at, status, note)
        VALUES (?, ?, 'running', ?)
        """,
        (source, now_iso(), note),
    )
    conn.commit()
    return cur.lastrowid


def finish_run(
    conn: sqlite3.Connection,
    run_id: int,
    status: str,
    new_count: int = 0,
    updated_count: int = 0,
    skipped_count: int = 0,
    error_count: int = 0,
    error_message: Optional[str] = None,
):
    conn.execute(
        """
        UPDATE scraping_runs
        SET finished_at = ?, status = ?, new_count = ?, updated_count = ?,
            skipped_count = ?, error_count = ?, error_message = ?
        WHERE id = ?
        """,
        (
            now_iso(), status, new_count, updated_count,
            skipped_count, error_count, error_message, run_id,
        ),
    )
    conn.commit()


# -----------------------------------------------------------------------------
# Self test (python db.py 直接跑)
# -----------------------------------------------------------------------------

if __name__ == "__main__":
    p = init_db()
    print(f"✅ Database initialized at: {p}")

    # 测试插入一条
    with db_connect(p) as conn:
        result = upsert_job(conn, {
            "source": "_test_",
            "source_id": "1",
            "source_url": "https://example.com/1",
            "title": "测试招聘",
            "body": "这是一条测试",
            "category": "找工",
            "scraped_at": now_iso(),
        })
        conn.commit()
        print(f"upsert result: {result}")

        # 再插一次,应该是 skipped
        result2 = upsert_job(conn, {
            "source": "_test_",
            "source_id": "1",
            "source_url": "https://example.com/1",
            "title": "测试招聘",
            "body": "这是一条测试",
            "category": "找工",
            "scraped_at": now_iso(),
        })
        conn.commit()
        print(f"upsert (again) result: {result2}")

        # 修改内容,应该是 updated
        result3 = upsert_job(conn, {
            "source": "_test_",
            "source_id": "1",
            "source_url": "https://example.com/1",
            "title": "测试招聘(改过)",
            "body": "新内容",
            "category": "找工",
            "scraped_at": now_iso(),
        })
        conn.commit()
        print(f"upsert (changed) result: {result3}")

        # 清理测试数据
        conn.execute("DELETE FROM jobs WHERE source = '_test_'")
        conn.commit()
        print("test rows cleaned up")

        # 统计
        print(f"counts: {count_jobs(conn)}")
