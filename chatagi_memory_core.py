# -*- coding: utf-8 -*-
# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-3a1123d3b817ec87a58f42199f45296020d81a6705ea84bd4af07b632529a2d6"
# Source-SHA256: "0a742c53366b4dfb8c7780dd808b6c37507dd5b2790011862f7acfac77c98146"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""ChatAGI five-layer memory core V2.

Compatibility layer for the existing MemoryEngine in memory_module.py.
It keeps the current SQLite database and old APIs, then adds:
- five-layer writes: working/raw, episodic, semantic/facts, timeline, procedural
- hybrid retrieval across keyword/vector/timeline/episode/facts/procedures/light relations
- deterministic consolidation V1 for raw -> episode -> semantic -> profile
- graph memory / temporal knowledge graph over nodes, edges, relations, events

No new heavy dependencies. Network is never required; embedding uses the existing
MemoryEngine fallback when OpenAI embeddings are unavailable.
"""
from __future__ import annotations

import hashlib
import json
import math
import re
import sqlite3
import time
import uuid
from array import array
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple

try:
    from memory_module import sanitize_user_key
except Exception:  # pragma: no cover
    def sanitize_user_key(key: str) -> str:
        return re.sub(r"[^a-zA-Z0-9_\-:.]", "_", (key or "default").strip() or "default")


GRAPH_NODE_TYPES = {
    "user", "project", "file", "function", "bug", "fix", "task", "episode",
    "fact", "procedure", "tool", "model", "event", "concept",
}

GRAPH_EDGE_TYPES = {
    "requires", "caused_by", "fixed_by", "happened_at", "belongs_to", "modified",
    "mentioned", "depends_on", "similar_to", "next_step", "learned_from",
    "used_tool", "occurred_in_file",
}


def _now() -> float:
    return time.time()


def _iso(ts: Optional[float] = None) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(float(ts or _now())))


def _date(ts: Optional[float] = None) -> str:
    return time.strftime("%Y-%m-%d", time.localtime(float(ts or _now())))


def _json(obj: Any) -> str:
    try:
        return json.dumps(obj, ensure_ascii=False, sort_keys=True, default=str)
    except Exception:
        return "{}"


def _loads(s: Any, default: Any = None) -> Any:
    if not s:
        return default
    try:
        return json.loads(str(s))
    except Exception:
        return default


def _short(text: Any, limit: int = 500) -> str:
    t = re.sub(r"\s+", " ", str(text or "").strip())
    return t if len(t) <= limit else t[:limit].rstrip() + "..."


def _tokens(text: str) -> List[str]:
    t = (text or "").lower()
    toks = re.findall(r"[a-z0-9_]{2,}|[\u4e00-\u9fff]", t)
    cjk = re.findall(r"[\u4e00-\u9fff]", t)
    if len(cjk) >= 2:
        toks.extend([cjk[i] + cjk[i + 1] for i in range(len(cjk) - 1)])
    return toks


def _slug(text: Any, prefix: str = "node") -> str:
    t = re.sub(r"[^a-zA-Z0-9_\-:.]+", "_", str(text or "").strip())
    t = re.sub(r"_+", "_", t).strip("_")[:96]
    if t:
        return t
    return f"{prefix}_{uuid.uuid4().hex[:12]}"


def _node_id(ntype: str, text: Any, given: Any = None) -> str:
    if given:
        return _slug(given, ntype)
    digest = hashlib.sha1(f"{ntype}:{str(text or '')}".encode("utf-8")).hexdigest()[:16]
    stem = _slug(str(text or "")[:48], ntype)
    return f"{ntype}_{stem[:40]}_{digest}" if stem else f"{ntype}_{digest}"


def _node_type(value: Any) -> str:
    typ = str(value or "concept").strip().lower()
    return typ if typ in GRAPH_NODE_TYPES else "concept"


def _edge_type(value: Any) -> str:
    rel = str(value or "mentioned").strip().lower()
    return rel if rel in GRAPH_EDGE_TYPES else "mentioned"


def _as_list(value: Any) -> List[Any]:
    if value is None:
        return []
    if isinstance(value, list):
        return value
    if isinstance(value, tuple):
        return list(value)
    return [value]


def _keyword_score(query: str, text: str) -> float:
    qs = set(_tokens(query))
    if not qs:
        return 0.0
    ts = set(_tokens(text))
    if not ts:
        return 0.0
    hit = len(qs & ts)
    return min(1.0, hit / max(1.0, math.sqrt(len(qs))))


def _recency_score(ts: float, half_life_days: float = 14.0) -> float:
    if not ts:
        return 0.25
    age_days = max(0.0, (_now() - float(ts)) / 86400.0)
    return float(0.5 ** (age_days / max(0.1, half_life_days)))


def _importance_score(v: Any) -> float:
    try:
        return max(0.0, min(float(v) / 5.0, 1.0))
    except Exception:
        return 0.5


def _pack(vec: Sequence[float]) -> bytes:
    return array("f", [float(x) for x in vec]).tobytes()


def _unpack(blob: bytes) -> array:
    a = array("f")
    a.frombytes(blob)
    return a


def _cos(a: array, b: array) -> float:
    if len(a) != len(b) or not a:
        return 0.0
    dot = sum(float(a[i]) * float(b[i]) for i in range(len(a)))
    na = math.sqrt(sum(float(x) * float(x) for x in a))
    nb = math.sqrt(sum(float(x) * float(x) for x in b))
    return float(dot / (na * nb + 1e-9))


def _conn(engine: Any) -> sqlite3.Connection:
    if hasattr(engine, "_conn"):
        return engine._conn()
    db_path = getattr(getattr(engine, "cfg", None), "db_path", "")
    con = sqlite3.connect(db_path, check_same_thread=False)
    con.execute("PRAGMA journal_mode=WAL;")
    con.execute("PRAGMA synchronous=NORMAL;")
    return con


def _embed(engine: Any, text: str) -> Optional[List[float]]:
    fn = getattr(engine, "_embed", None)
    if callable(fn):
        return fn(text)
    return None


def ensure_memory_v2_schema(engine: Any) -> Dict[str, Any]:
    with _conn(engine) as con:
        con.execute("""
        CREATE TABLE IF NOT EXISTS memory_raw (
          id TEXT PRIMARY KEY,
          user_key TEXT NOT NULL,
          content TEXT NOT NULL,
          role TEXT DEFAULT '',
          conversation_id TEXT DEFAULT '',
          trace_id TEXT DEFAULT '',
          metadata TEXT DEFAULT '{}',
          created_at REAL NOT NULL
        );
        """)
        con.execute("CREATE INDEX IF NOT EXISTS idx_memory_raw_user_time ON memory_raw(user_key, created_at DESC);")
        con.execute("CREATE INDEX IF NOT EXISTS idx_memory_raw_user_conv ON memory_raw(user_key, conversation_id, created_at DESC);")

        con.execute("""
        CREATE TABLE IF NOT EXISTS memory_procedures (
          id TEXT PRIMARY KEY,
          user_key TEXT NOT NULL,
          title TEXT DEFAULT '',
          content TEXT NOT NULL,
          tags TEXT DEFAULT '',
          success_count INTEGER DEFAULT 0,
          failure_count INTEGER DEFAULT 0,
          importance INTEGER DEFAULT 3,
          source TEXT DEFAULT '',
          trace_id TEXT DEFAULT '',
          metadata TEXT DEFAULT '{}',
          embedding BLOB,
          dim INTEGER DEFAULT 0,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          last_used_at REAL NOT NULL,
          hash TEXT NOT NULL,
          UNIQUE(user_key, hash)
        );
        """)
        con.execute("CREATE INDEX IF NOT EXISTS idx_memory_proc_user_time ON memory_procedures(user_key, updated_at DESC);")
        con.execute("CREATE INDEX IF NOT EXISTS idx_memory_proc_user_used ON memory_procedures(user_key, last_used_at DESC);")

        con.execute("""
        CREATE TABLE IF NOT EXISTS memory_relations (
          id TEXT PRIMARY KEY,
          user_key TEXT NOT NULL,
          subject TEXT NOT NULL,
          relation TEXT NOT NULL,
          object TEXT NOT NULL,
          source_type TEXT DEFAULT '',
          source_id TEXT DEFAULT '',
          weight REAL DEFAULT 1.0,
          metadata TEXT DEFAULT '{}',
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          UNIQUE(user_key, subject, relation, object, source_type, source_id)
        );
        """)
        con.execute("CREATE INDEX IF NOT EXISTS idx_memory_rel_user_subj ON memory_relations(user_key, subject);")
        con.execute("CREATE INDEX IF NOT EXISTS idx_memory_rel_user_obj ON memory_relations(user_key, object);")

        con.execute("""
        CREATE TABLE IF NOT EXISTS memory_nodes (
          id TEXT NOT NULL,
          user_key TEXT NOT NULL,
          type TEXT NOT NULL,
          text TEXT NOT NULL,
          aliases TEXT DEFAULT '[]',
          source_type TEXT DEFAULT '',
          source_id TEXT DEFAULT '',
          importance INTEGER DEFAULT 3,
          metadata TEXT DEFAULT '{}',
          embedding BLOB,
          dim INTEGER DEFAULT 0,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          PRIMARY KEY(user_key, id)
        );
        """)
        con.execute("CREATE INDEX IF NOT EXISTS idx_memory_nodes_user_type ON memory_nodes(user_key, type, updated_at DESC);")
        con.execute("CREATE INDEX IF NOT EXISTS idx_memory_nodes_user_text ON memory_nodes(user_key, text);")

        con.execute("""
        CREATE TABLE IF NOT EXISTS memory_edges (
          id TEXT PRIMARY KEY,
          user_key TEXT NOT NULL,
          source_id TEXT NOT NULL,
          target_id TEXT NOT NULL,
          relation TEXT NOT NULL,
          confidence REAL DEFAULT 0.8,
          timestamp REAL NOT NULL,
          valid_from REAL DEFAULT 0,
          valid_to REAL DEFAULT 0,
          source_type TEXT DEFAULT '',
          source_id_ref TEXT DEFAULT '',
          metadata TEXT DEFAULT '{}',
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          UNIQUE(user_key, source_id, target_id, relation)
        );
        """)
        con.execute("CREATE INDEX IF NOT EXISTS idx_memory_edges_user_src ON memory_edges(user_key, source_id, relation);")
        con.execute("CREATE INDEX IF NOT EXISTS idx_memory_edges_user_tgt ON memory_edges(user_key, target_id, relation);")
        con.execute("CREATE INDEX IF NOT EXISTS idx_memory_edges_user_time ON memory_edges(user_key, timestamp DESC);")

        con.execute("""
        CREATE TABLE IF NOT EXISTS temporal_edges (
          id TEXT PRIMARY KEY,
          user_key TEXT NOT NULL,
          source_id TEXT NOT NULL,
          target_id TEXT NOT NULL,
          relation TEXT NOT NULL,
          confidence REAL DEFAULT 0.8,
          timestamp REAL NOT NULL,
          occurred_at REAL NOT NULL,
          event_id TEXT DEFAULT '',
          metadata TEXT DEFAULT '{}',
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          UNIQUE(user_key, source_id, target_id, relation, occurred_at)
        );
        """)
        con.execute("CREATE INDEX IF NOT EXISTS idx_temporal_edges_user_time ON temporal_edges(user_key, occurred_at DESC);")
        con.execute("CREATE INDEX IF NOT EXISTS idx_temporal_edges_user_src ON temporal_edges(user_key, source_id, occurred_at DESC);")

        con.execute("""
        CREATE TABLE IF NOT EXISTS memory_consolidation_traces (
          id TEXT PRIMARY KEY,
          user_key TEXT NOT NULL,
          scope TEXT NOT NULL,
          dry_run INTEGER DEFAULT 0,
          input_counts TEXT DEFAULT '{}',
          output_counts TEXT DEFAULT '{}',
          result TEXT DEFAULT '{}',
          created_at REAL NOT NULL
        );
        """)
        con.execute("CREATE INDEX IF NOT EXISTS idx_memory_cons_user_time ON memory_consolidation_traces(user_key, created_at DESC);")

        # Repair/extend legacy tables idempotently.
        con.execute("""
        CREATE TABLE IF NOT EXISTS memory_timeline (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          user_key TEXT NOT NULL,
          summary TEXT NOT NULL,
          detail TEXT DEFAULT '',
          source TEXT DEFAULT '',
          event_type TEXT DEFAULT 'chat',
          created_at REAL NOT NULL,
          date_str TEXT NOT NULL
        );
        """)
        for table, col, ddl in [
            ("memory_timeline", "trace_id", "trace_id TEXT DEFAULT ''"),
            ("memory_timeline", "importance", "importance INTEGER DEFAULT 3"),
            ("memory_timeline", "metadata", "metadata TEXT DEFAULT '{}'"),
            ("memory_episodes", "goal", "goal TEXT DEFAULT ''"),
            ("memory_episodes", "result", "result TEXT DEFAULT ''"),
            ("memory_episodes", "status", "status TEXT DEFAULT 'done'"),
            ("memory_episodes", "trace_id", "trace_id TEXT DEFAULT ''"),
            ("memory_episodes", "steps_json", "steps_json TEXT DEFAULT '[]'"),
            ("memory_episodes", "importance", "importance INTEGER DEFAULT 3"),
        ]:
            try:
                cols = {r[1] for r in con.execute(f"PRAGMA table_info({table})").fetchall()}
                if col not in cols:
                    con.execute(f"ALTER TABLE {table} ADD COLUMN {ddl}")
            except Exception:
                pass
    return {"ok": True, "schema": "chatagi_memory_v2"}


def _relation_terms(text: str) -> List[str]:
    raw = re.findall(r"[A-Za-z][A-Za-z0-9_+.#-]{2,}|[\u4e00-\u9fff]{2,8}", text or "")
    stop = {"用户", "助手", "这个", "那个", "需要", "已经", "可以", "不能", "the", "and", "for", "with"}
    out: List[str] = []
    for t in raw:
        if t.lower() in stop or t in stop:
            continue
        if t not in out:
            out.append(t)
    return out[:10]


def _upsert_relations(engine: Any, user_key: str, content: str, source_type: str, source_id: str, metadata: Dict[str, Any]) -> None:
    terms = _relation_terms(content)
    if len(terms) < 2:
        return
    now = _now()
    with _conn(engine) as con:
        for a, b in zip(terms, terms[1:]):
            con.execute("""
            INSERT INTO memory_relations(id,user_key,subject,relation,object,source_type,source_id,weight,metadata,created_at,updated_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(user_key,subject,relation,object,source_type,source_id)
            DO UPDATE SET weight=memory_relations.weight+0.25, updated_at=excluded.updated_at
            """, (uuid.uuid4().hex, user_key, a, "related_to", b, source_type, source_id, 1.0, _json(metadata), now, now))


def graph_upsert(engine: Any, user_key: str, nodes: Optional[List[Dict[str, Any]]] = None,
                 edges: Optional[List[Dict[str, Any]]] = None, metadata: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """Upsert graph nodes/edges and mirror edges into legacy memory_relations."""
    ensure_memory_v2_schema(engine)
    u = sanitize_user_key(user_key)
    meta = metadata if isinstance(metadata, dict) else {}
    now = _now()
    node_count = 0
    edge_count = 0
    touched_nodes: List[str] = []
    touched_edges: List[str] = []

    with _conn(engine) as con:
        for raw in nodes or []:
            if not isinstance(raw, dict):
                continue
            typ = _node_type(raw.get("type"))
            text = _short(raw.get("text") or raw.get("content") or raw.get("label") or raw.get("id") or typ, 1200)
            nid = _node_id(typ, text, raw.get("id"))
            aliases = raw.get("aliases") if isinstance(raw.get("aliases"), list) else []
            nmeta = raw.get("metadata") if isinstance(raw.get("metadata"), dict) else {}
            full_meta = {**meta, **nmeta}
            emb = _embed(engine, f"{typ}: {text}") or []
            con.execute("""
            INSERT INTO memory_nodes(id,user_key,type,text,aliases,source_type,source_id,importance,metadata,embedding,dim,created_at,updated_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(user_key,id)
            DO UPDATE SET type=excluded.type, text=excluded.text, aliases=excluded.aliases,
                source_type=COALESCE(NULLIF(excluded.source_type,''), memory_nodes.source_type),
                source_id=COALESCE(NULLIF(excluded.source_id,''), memory_nodes.source_id),
                importance=MAX(memory_nodes.importance, excluded.importance),
                metadata=excluded.metadata, embedding=excluded.embedding, dim=excluded.dim, updated_at=excluded.updated_at
            """, (
                nid, u, typ, text, _json(aliases), str(raw.get("source_type") or meta.get("source_type") or ""),
                str(raw.get("source_id") or meta.get("source_id") or ""), int(raw.get("importance") or meta.get("importance") or 3),
                _json(full_meta), _pack(emb) if emb else None, len(emb), now, now,
            ))
            touched_nodes.append(nid)
            node_count += 1

        for raw in edges or []:
            if not isinstance(raw, dict):
                continue
            src = _slug(raw.get("source_id") or raw.get("source") or "")
            tgt = _slug(raw.get("target_id") or raw.get("target") or "")
            if not src or not tgt:
                continue
            rel = _edge_type(raw.get("relation"))
            confidence = max(0.0, min(float(raw.get("confidence") if raw.get("confidence") is not None else 0.8), 1.0))
            ts = float(raw.get("timestamp") or raw.get("occurred_at") or now)
            emeta = raw.get("metadata") if isinstance(raw.get("metadata"), dict) else {}
            full_meta = {**meta, **emeta}
            eid = str(raw.get("id") or hashlib.sha1(f"{u}:{src}:{rel}:{tgt}".encode("utf-8")).hexdigest())
            con.execute("""
            INSERT INTO memory_edges(id,user_key,source_id,target_id,relation,confidence,timestamp,valid_from,valid_to,source_type,source_id_ref,metadata,created_at,updated_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(user_key,source_id,target_id,relation)
            DO UPDATE SET confidence=MAX(memory_edges.confidence, excluded.confidence),
                timestamp=excluded.timestamp, valid_from=excluded.valid_from, valid_to=excluded.valid_to,
                metadata=excluded.metadata, updated_at=excluded.updated_at
            """, (
                eid, u, src, tgt, rel, confidence, ts, float(raw.get("valid_from") or 0), float(raw.get("valid_to") or 0),
                str(raw.get("source_type") or meta.get("source_type") or ""), str(raw.get("source_id_ref") or meta.get("source_id") or ""),
                _json(full_meta), now, now,
            ))
            if rel in {"happened_at", "occurred_in_file", "modified", "fixed_by", "caused_by", "learned_from", "next_step"}:
                tid = hashlib.sha1(f"{u}:{src}:{rel}:{tgt}:{ts}".encode("utf-8")).hexdigest()
                con.execute("""
                INSERT INTO temporal_edges(id,user_key,source_id,target_id,relation,confidence,timestamp,occurred_at,event_id,metadata,created_at,updated_at)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(user_key,source_id,target_id,relation,occurred_at)
                DO UPDATE SET confidence=MAX(temporal_edges.confidence, excluded.confidence), metadata=excluded.metadata, updated_at=excluded.updated_at
                """, (tid, u, src, tgt, rel, confidence, ts, ts, str(raw.get("event_id") or ""), _json(full_meta), now, now))
            # Keep old relation index hot for V1 compatibility.
            con.execute("""
            INSERT INTO memory_relations(id,user_key,subject,relation,object,source_type,source_id,weight,metadata,created_at,updated_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(user_key,subject,relation,object,source_type,source_id)
            DO UPDATE SET weight=MAX(memory_relations.weight, excluded.weight), updated_at=excluded.updated_at
            """, (uuid.uuid4().hex, u, src, rel, tgt, "graph", eid, confidence, _json(full_meta), now, now))
            touched_edges.append(eid)
            edge_count += 1

    return {"ok": True, "user_key": u, "nodes_upserted": node_count, "edges_upserted": edge_count, "node_ids": touched_nodes, "edge_ids": touched_edges}


def _graph_node(engine: Any, user_key: str, nid: str) -> Optional[Dict[str, Any]]:
    rows = _query_rows(engine, "SELECT id,type,text,aliases,source_type,source_id,importance,metadata,created_at,updated_at FROM memory_nodes WHERE user_key=? AND id=?", (sanitize_user_key(user_key), _slug(nid)))
    return dict(rows[0]) if rows else None


def graph_query(engine: Any, user_key: str, query: str = "", k: int = 10, *,
                node_id: str = "", relation: str = "", node_type: str = "") -> Dict[str, Any]:
    """Query graph nodes, adjacent edges and simple 1-hop paths."""
    ensure_memory_v2_schema(engine)
    u = sanitize_user_key(user_key)
    q = str(query or "").strip()
    k = max(1, min(int(k or 10), 100))
    like = f"%{q[:100]}%" if q else "%"
    seeds: List[Dict[str, Any]] = []

    if node_id:
        n = _graph_node(engine, u, node_id)
        if n:
            n["score"] = 1.0
            seeds.append(n)

    clauses = ["user_key=?"]
    args: List[Any] = [u]
    if node_type:
        clauses.append("type=?")
        args.append(_node_type(node_type))
    args.append(max(k * 6, 30))
    rows = _query_rows(engine, f"""
        SELECT id,type,text,aliases,source_type,source_id,importance,metadata,created_at,updated_at,embedding,dim
        FROM memory_nodes WHERE {' AND '.join(clauses)} ORDER BY updated_at DESC LIMIT ?
    """, args)
    qv = None
    emb = _embed(engine, q) if q else None
    if emb:
        qv = array("f", [float(x) for x in emb])
    for r in rows:
        d = dict(r)
        base = max(_keyword_score(q, d.get("text") or ""), _keyword_score(q, d.get("id") or ""))
        try:
            if qv is not None and d.get("embedding") and int(d.get("dim") or 0) > 0:
                vv = _unpack(d["embedding"])
                if len(vv) == int(d.get("dim") or 0):
                    base = max(base, _cos(qv, vv))
        except Exception:
            pass
        d.pop("embedding", None)
        d["score"] = base
        seeds.append(d)
    seed_ranked = _rank_items([n | {"content": f"{n.get('type')} {n.get('text')}"} for n in seeds], q, k)
    seed_ids = []
    for n in seed_ranked:
        nid = n.get("id")
        if nid and nid not in seed_ids:
            seed_ids.append(nid)

    edge_rows: List[sqlite3.Row] = []
    if seed_ids:
        placeholders = ",".join(["?"] * len(seed_ids))
        edge_args: List[Any] = [u, *seed_ids, *seed_ids]
        rel_clause = ""
        if relation:
            rel_clause = " AND relation=?"
            edge_args.append(_edge_type(relation))
        edge_args.append(max(k * 8, 40))
        edge_rows = _query_rows(engine, f"""
            SELECT * FROM memory_edges
            WHERE user_key=? AND (source_id IN ({placeholders}) OR target_id IN ({placeholders})){rel_clause}
            ORDER BY confidence DESC, timestamp DESC LIMIT ?
        """, edge_args)
    elif q:
        edge_rows = _query_rows(engine, """
            SELECT * FROM memory_edges
            WHERE user_key=? AND (source_id LIKE ? OR target_id LIKE ? OR relation LIKE ? OR metadata LIKE ?)
            ORDER BY confidence DESC, timestamp DESC LIMIT ?
        """, (u, like, like, like, like, max(k * 8, 40)))

    edges = [dict(r) for r in edge_rows]
    neighbor_ids: List[str] = []
    for e in edges:
        for nid in (e.get("source_id"), e.get("target_id")):
            if nid and nid not in seed_ids and nid not in neighbor_ids:
                neighbor_ids.append(nid)
    neighbors: List[Dict[str, Any]] = []
    if neighbor_ids:
        placeholders = ",".join(["?"] * len(neighbor_ids))
        nrows = _query_rows(engine, f"SELECT id,type,text,aliases,source_type,source_id,importance,metadata,created_at,updated_at FROM memory_nodes WHERE user_key=? AND id IN ({placeholders})", (u, *neighbor_ids))
        neighbors = [dict(r) for r in nrows]

    node_map = {n["id"]: n for n in [*seed_ranked, *neighbors] if n.get("id")}
    paths = []
    for e in edges[: max(k, 10)]:
        src = node_map.get(e.get("source_id"), {"id": e.get("source_id"), "text": e.get("source_id"), "type": "concept"})
        tgt = node_map.get(e.get("target_id"), {"id": e.get("target_id"), "text": e.get("target_id"), "type": "concept"})
        content = f"{src.get('text') or src.get('id')} -{e.get('relation')}-> {tgt.get('text') or tgt.get('id')}"
        score = 0.55 * float(e.get("confidence") or 0.0) + 0.25 * _recency_score(float(e.get("timestamp") or 0)) + 0.20 * max(_keyword_score(q, content), max(float(src.get("score") or 0), float(tgt.get("score") or 0)))
        paths.append({"type": "graph", "content": content, "score": round(min(1.0, score), 6), "edge": e, "source": src, "target": tgt})
    paths.sort(key=lambda x: float(x.get("score") or 0.0), reverse=True)

    temporal = _query_rows(engine, "SELECT * FROM temporal_edges WHERE user_key=? ORDER BY occurred_at DESC LIMIT ?", (u, max(k, 10)))
    return {
        "ok": True,
        "user_key": u,
        "query": q,
        "nodes": [n for n in seed_ranked if n.get("id")][:k],
        "neighbors": neighbors[: max(k, 10)],
        "edges": edges[: max(k * 3, 20)],
        "paths": paths[:k],
        "temporal": [dict(r) for r in temporal[:k]],
    }


def graph_from_episode(engine: Any, user_key: str, episode_id: str = "", content: str = "",
                       metadata: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """Extract task/file/bug/fix/tool/event relations from an episode-like record."""
    ensure_memory_v2_schema(engine)
    u = sanitize_user_key(user_key)
    meta = metadata if isinstance(metadata, dict) else {}
    text = str(content or meta.get("summary") or meta.get("content") or "")
    goal = str(meta.get("goal") or meta.get("title") or text[:120] or "memory episode")
    status = str(meta.get("status") or meta.get("result") or "done")
    trace_id = str(meta.get("trace_id") or episode_id or uuid.uuid4().hex[:12])
    ts = float(meta.get("timestamp") or meta.get("end_at") or _now())
    nodes: List[Dict[str, Any]] = []
    edges: List[Dict[str, Any]] = []

    episode_node = _node_id("episode", episode_id or goal, f"episode_{episode_id or trace_id}")
    task_node = _node_id("task", goal, f"task_{_slug(trace_id or goal)}")
    event_node = _node_id("event", f"{status} {goal}", f"event_{_slug(trace_id)}")
    nodes.extend([
        {"id": episode_node, "type": "episode", "text": text or goal, "importance": meta.get("importance", 4), "metadata": meta, "source_type": "episode", "source_id": episode_id},
        {"id": task_node, "type": "task", "text": goal, "importance": meta.get("importance", 4), "metadata": {"status": status, **meta}},
        {"id": event_node, "type": "event", "text": f"{status}: {goal}", "importance": meta.get("importance", 4), "metadata": {"trace_id": trace_id, **meta}},
    ])
    edges.extend([
        {"source_id": episode_node, "target_id": task_node, "relation": "belongs_to", "confidence": 0.95, "timestamp": ts, "event_id": event_node, "metadata": meta},
        {"source_id": episode_node, "target_id": event_node, "relation": "happened_at", "confidence": 0.95, "timestamp": ts, "event_id": event_node, "metadata": meta},
    ])

    files = [str(x) for x in _as_list(meta.get("files_touched") or meta.get("files") or meta.get("modified_files")) if str(x).strip()]
    for f in files:
        fn = _node_id("file", f, f"file_{_slug(f)}")
        nodes.append({"id": fn, "type": "file", "text": f, "importance": 4, "metadata": meta})
        edges.append({"source_id": task_node, "target_id": fn, "relation": "modified", "confidence": 0.9, "timestamp": ts, "event_id": event_node, "metadata": meta})

    tools = []
    for step in _as_list(meta.get("steps")):
        if isinstance(step, dict):
            tool = step.get("tool") or step.get("phase") or step.get("action")
            if tool:
                tools.append(str(tool))
    for tool in [*tools, *[str(x) for x in _as_list(meta.get("tools"))]]:
        tn = _node_id("tool", tool, f"tool_{_slug(tool)}")
        nodes.append({"id": tn, "type": "tool", "text": tool, "importance": 3, "metadata": meta})
        edges.append({"source_id": task_node, "target_id": tn, "relation": "used_tool", "confidence": 0.8, "timestamp": ts, "event_id": event_node, "metadata": meta})

    bug_texts: List[str] = []
    for key in ("error", "errors", "bug", "bugs", "failure", "failures"):
        val = meta.get(key)
        if isinstance(val, list):
            bug_texts.extend(str(x) for x in val if str(x).strip())
        elif val:
            bug_texts.append(str(val))
    if status not in ("done", "ok", "success", "succeeded"):
        bug_texts.append(f"{goal} failed with status {status}")
    bug_patterns = [
        r"(ObservableObject[^。.!?\n]{0,120})",
        r"(missing [A-Za-z0-9_+. -]{2,80})",
        r"(No module named [A-Za-z0-9_+. -]{2,80})",
        r"(ImportError[^。.!?\n]{0,120})",
        r"(SyntaxError[^。.!?\n]{0,120})",
        r"(TypeError[^。.!?\n]{0,120})",
        r"(AttributeError[^。.!?\n]{0,120})",
    ]
    for pat in bug_patterns:
        bug_texts.extend(re.findall(pat, text, flags=re.I))
    seen_bug = set()
    for bug in bug_texts[:8]:
        bug = _short(bug, 240)
        if bug in seen_bug:
            continue
        seen_bug.add(bug)
        bn = _node_id("bug", bug, f"bug_{hashlib.sha1(bug.encode('utf-8')).hexdigest()[:16]}")
        nodes.append({"id": bn, "type": "bug", "text": bug, "importance": 5, "metadata": meta})
        edges.append({"source_id": task_node, "target_id": bn, "relation": "caused_by", "confidence": 0.72, "timestamp": ts, "event_id": event_node, "metadata": meta})
        for f in files:
            fn = _node_id("file", f, f"file_{_slug(f)}")
            edges.append({"source_id": bn, "target_id": fn, "relation": "occurred_in_file", "confidence": 0.75, "timestamp": ts, "event_id": event_node, "metadata": meta})

    fix_texts: List[str] = []
    for key in ("fix", "fixes", "solution", "result", "verifications"):
        val = meta.get(key)
        if isinstance(val, dict):
            fix_texts.append(_json(val))
        elif isinstance(val, list):
            fix_texts.extend(str(x) for x in val if str(x).strip())
        elif val:
            fix_texts.append(str(val))
    if re.search(r"ObservableObject|Combine", text, re.I):
        fix_texts.append("SwiftUI ObservableObject 报错通常通过 import Combine 或补齐 ObservableObject 依赖修复")
    proc_node = ""
    if fix_texts:
        fix = _short("; ".join(fix_texts), 360)
        fix_node = _node_id("fix", fix, f"fix_{hashlib.sha1(fix.encode('utf-8')).hexdigest()[:16]}")
        nodes.append({"id": fix_node, "type": "fix", "text": fix, "importance": 5, "metadata": meta})
        if seen_bug:
            for bug in list(seen_bug)[:4]:
                bn = _node_id("bug", bug, f"bug_{hashlib.sha1(bug.encode('utf-8')).hexdigest()[:16]}")
                edges.append({"source_id": bn, "target_id": fix_node, "relation": "fixed_by", "confidence": 0.86, "timestamp": ts, "event_id": event_node, "metadata": meta})
        else:
            edges.append({"source_id": task_node, "target_id": fix_node, "relation": "fixed_by", "confidence": 0.7, "timestamp": ts, "event_id": event_node, "metadata": meta})
        proc_node = _node_id("procedure", fix, f"procedure_{hashlib.sha1(fix.encode('utf-8')).hexdigest()[:16]}")
        nodes.append({"id": proc_node, "type": "procedure", "text": fix, "importance": 4, "metadata": meta})
        edges.append({"source_id": fix_node, "target_id": proc_node, "relation": "learned_from", "confidence": 0.74, "timestamp": ts, "event_id": event_node, "metadata": meta})

    return graph_upsert(engine, u, nodes, edges, {"source_type": "episode", "source_id": episode_id, "trace_id": trace_id})


def memory_write(engine: Any, user_key: str, mtype: str, content: str, metadata: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    ensure_memory_v2_schema(engine)
    u = sanitize_user_key(user_key)
    typ = (mtype or "raw").strip().lower()
    meta = metadata if isinstance(metadata, dict) else {}
    text = str(content or "").strip()
    if not text:
        return {"ok": False, "error": "missing_content"}
    now = _now()
    trace_id = str(meta.get("trace_id") or "")
    conv_id = str(meta.get("conversation_id") or meta.get("conv_id") or "")
    source = str(meta.get("source") or typ)
    importance = int(meta.get("importance") or 3)

    # Always keep semantic vector for searchable long-term recall unless explicitly disabled.
    if typ not in ("working",) and hasattr(engine, "add_vector_sync"):
        try:
            engine.add_vector_sync(u, f"[{typ}] {text}")
        except Exception:
            try:
                engine.add_vector(u, f"[{typ}] {text}")
            except Exception:
                pass

    if typ in ("fact", "facts", "semantic"):
        if hasattr(engine, "facts_save"):
            engine.facts_save(u, text, tags=str(meta.get("tags") or typ), importance=importance)
        _upsert_relations(engine, u, text, "fact", hashlib.sha1(text.encode("utf-8")).hexdigest()[:16], meta)
        fid = _node_id("fact", text, meta.get("id"))
        graph_upsert(engine, u, [{"id": fid, "type": "fact", "text": text, "importance": importance, "metadata": meta}], [], {"source_type": "fact"})
        return {"ok": True, "type": "fact", "user_key": u}

    if typ in ("episode", "episodic"):
        title = str(meta.get("title") or meta.get("goal") or "")[:80]
        goal = str(meta.get("goal") or title or text[:120])
        result = str(meta.get("result") or meta.get("status") or "done")
        status = str(meta.get("status") or "done")
        steps = meta.get("steps") if isinstance(meta.get("steps"), list) else []
        eid = ""
        if hasattr(engine, "episode_save"):
            try:
                eid = engine.episode_save(
                    u, conv_id, text, start_at=float(meta.get("start_at") or now), end_at=float(meta.get("end_at") or now),
                    title=title, keywords=str(meta.get("keywords") or ""), source_meta=_json(meta)
                )
            except Exception:
                eid = ""
        if eid:
            try:
                with _conn(engine) as con:
                    con.execute("UPDATE memory_episodes SET goal=?, result=?, status=?, trace_id=?, steps_json=?, importance=? WHERE id=? AND user_key=?",
                                (goal, result, status, trace_id, _json(steps), importance, eid, u))
            except Exception:
                pass
        _upsert_relations(engine, u, f"{goal} {text} {result}", "episode", eid, meta)
        try:
            graph_from_episode(engine, u, eid, text, {**meta, "goal": goal, "result": result, "status": status, "steps": steps})
        except Exception:
            pass
        return {"ok": True, "type": "episode", "id": eid, "user_key": u}

    if typ in ("timeline", "event"):
        with _conn(engine) as con:
            con.execute("""
            INSERT INTO memory_timeline(user_key,summary,detail,source,event_type,created_at,date_str,trace_id,importance,metadata)
            VALUES(?,?,?,?,?,?,?,?,?,?)
            """, (u, _short(text, 500), str(meta.get("detail") or ""), source, str(meta.get("event_type") or "event"), now, _date(now), trace_id, importance, _json(meta)))
            event_id = str(con.execute("SELECT last_insert_rowid()").fetchone()[0])
        try:
            en = _node_id("event", text, f"event_{event_id}")
            graph_upsert(engine, u, [{"id": en, "type": "event", "text": text, "importance": importance, "metadata": {**meta, "timeline_id": event_id}}], [], {"source_type": "timeline", "source_id": event_id})
        except Exception:
            pass
        return {"ok": True, "type": "timeline", "user_key": u}

    if typ in ("procedural", "procedure", "skill", "recipe"):
        emb = _embed(engine, text) or []
        h = hashlib.sha1((text + _json(meta)).encode("utf-8")).hexdigest()
        title = str(meta.get("title") or text.split("\n", 1)[0])[:120]
        tags = str(meta.get("tags") or "procedural")
        with _conn(engine) as con:
            con.execute("""
            INSERT INTO memory_procedures(id,user_key,title,content,tags,success_count,failure_count,importance,source,trace_id,metadata,embedding,dim,created_at,updated_at,last_used_at,hash)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(user_key,hash)
            DO UPDATE SET title=excluded.title, content=excluded.content, tags=excluded.tags,
                importance=MAX(memory_procedures.importance, excluded.importance), updated_at=excluded.updated_at, last_used_at=excluded.last_used_at
            """, (uuid.uuid4().hex, u, title, text, tags, int(meta.get("success_count") or 0), int(meta.get("failure_count") or 0), importance,
                  source, trace_id, _json(meta), _pack(emb) if emb else None, len(emb), now, now, now, h))
        _upsert_relations(engine, u, text, "procedure", h[:16], meta)
        try:
            pn = _node_id("procedure", text, meta.get("id") or f"procedure_{h[:16]}")
            graph_upsert(engine, u, [{"id": pn, "type": "procedure", "text": text, "importance": importance, "metadata": meta}], [], {"source_type": "procedure", "source_id": h[:16]})
        except Exception:
            pass
        return {"ok": True, "type": "procedural", "user_key": u}

    # raw / working memory
    with _conn(engine) as con:
        con.execute("""
        INSERT INTO memory_raw(id,user_key,content,role,conversation_id,trace_id,metadata,created_at)
        VALUES(?,?,?,?,?,?,?,?)
        """, (uuid.uuid4().hex, u, text, str(meta.get("role") or typ), conv_id, trace_id, _json(meta), now))
        con.execute("DELETE FROM memory_raw WHERE id IN (SELECT id FROM memory_raw WHERE user_key=? ORDER BY created_at DESC LIMIT -1 OFFSET 500)", (u,))
    return {"ok": True, "type": "raw", "user_key": u}


def _query_rows(engine: Any, sql: str, args: Sequence[Any]) -> List[sqlite3.Row]:
    with _conn(engine) as con:
        con.row_factory = sqlite3.Row
        return list(con.execute(sql, tuple(args)).fetchall())


def _rank_items(items: List[Dict[str, Any]], query: str, k: int) -> List[Dict[str, Any]]:
    out = []
    seen = set()
    for it in items:
        text = str(it.get("content") or it.get("text") or it.get("summary") or "")
        ts = float(it.get("created_at") or it.get("updated_at") or it.get("last_used_at") or 0.0)
        imp = it.get("importance", 3)
        base = float(it.get("score") or 0.0)
        score = 0.45 * max(base, _keyword_score(query, text)) + 0.20 * _recency_score(ts) + 0.20 * _importance_score(imp) + 0.15
        it["score"] = round(min(score, 1.0), 6)
        key = (it.get("type"), text[:220])
        if key in seen:
            continue
        seen.add(key)
        out.append(it)
    out.sort(key=lambda x: float(x.get("score") or 0.0), reverse=True)
    return out[: max(1, int(k or 10))]


def _vector_recall(engine: Any, user_key: str, query: str, k: int) -> List[Dict[str, Any]]:
    try:
        hits = engine.search_vectors(user_key, query, k=k, min_score=0.12)
    except Exception:
        hits = []
    out = []
    for h in hits or []:
        out.append({"type": "vector", "id": h.get("id"), "content": h.get("text") or h.get("content") or "", "score": float(h.get("score") or 0.0)})
    return out


def hybrid_recall(engine: Any, user_key: str, query: str, k: int = 10, include: Optional[Iterable[str]] = None) -> Dict[str, Any]:
    ensure_memory_v2_schema(engine)
    u = sanitize_user_key(user_key)
    q = str(query or "").strip()
    inc = {str(x).lower() for x in (include or ["facts", "vector", "timeline", "episodes", "procedural", "working", "semantic", "graph"])}
    if "episode" in inc:
        inc.add("episodes")
    if "procedure" in inc:
        inc.add("procedural")

    result: Dict[str, Any] = {"working": [], "episodic": [], "semantic": [], "timeline": [], "procedural": [], "facts": [], "vector": [], "graph": [], "scores": {}}
    like = f"%{q[:80]}%" if q else "%"

    if "working" in inc or "raw" in inc:
        rows = _query_rows(engine, "SELECT id,content,role,conversation_id,trace_id,metadata,created_at FROM memory_raw WHERE user_key=? ORDER BY created_at DESC LIMIT ?", (u, max(k, 10)))
        result["working"] = _rank_items([{**dict(r), "type": "working"} for r in rows], q, k)

    if "facts" in inc or "semantic" in inc:
        try:
            rows = _query_rows(engine, "SELECT id,content,tags,importance,created_at FROM memory_facts WHERE user_key=? ORDER BY importance DESC, created_at DESC LIMIT ?", (u, max(k * 4, 20)))
            facts = [dict(r) | {"type": "fact"} for r in rows]
            result["facts"] = _rank_items(facts, q, k)
            result["semantic"] = result["facts"][:]
        except Exception:
            result["facts"] = []

    if "vector" in inc or "semantic" in inc:
        result["vector"] = _vector_recall(engine, u, q, k)

    if "timeline" in inc:
        rows = _query_rows(engine, """
            SELECT id,summary AS content,detail,source,event_type,created_at,date_str,trace_id,importance,metadata
            FROM memory_timeline WHERE user_key=? AND (?='' OR summary LIKE ? OR detail LIKE ? OR date_str LIKE ?)
            ORDER BY created_at DESC LIMIT ?
        """, (u, q, like, like, like, max(k * 4, 20)))
        result["timeline"] = _rank_items([dict(r) | {"type": "timeline"} for r in rows], q, k)

    if "episodes" in inc or "episodic" in inc:
        episodes: List[Dict[str, Any]] = []
        try:
            if q and hasattr(engine, "episode_search"):
                for h in engine.episode_search(u, q, k=k, min_score=0.05):
                    episodes.append({"type": "episode", "id": h.get("id"), "title": h.get("title", ""), "content": h.get("summary", ""), "summary": h.get("summary", ""), "score": h.get("score", 0), "updated_at": h.get("updated_at", 0)})
            if hasattr(engine, "episode_list"):
                for h in engine.episode_list(u, limit=max(k, 10)):
                    episodes.append({"type": "episode", "id": h.get("id"), "title": h.get("title", ""), "content": h.get("summary", ""), "summary": h.get("summary", ""), "updated_at": h.get("updated_at", 0), "importance": h.get("importance", 3)})
        except Exception:
            episodes = []
        result["episodic"] = _rank_items(episodes, q, k)

    if "procedural" in inc:
        rows = _query_rows(engine, """
            SELECT id,title,content,tags,success_count,failure_count,importance,source,trace_id,metadata,created_at,updated_at,last_used_at,embedding,dim
            FROM memory_procedures WHERE user_key=? ORDER BY last_used_at DESC LIMIT ?
        """, (u, max(k * 5, 40)))
        procs = []
        qv = None
        if q:
            emb = _embed(engine, q)
            qv = array("f", [float(x) for x in emb]) if emb else None
        touch_ids = []
        for r in rows:
            d = dict(r)
            base = _keyword_score(q, d.get("content") or "")
            try:
                if qv is not None and d.get("embedding") and int(d.get("dim") or 0) > 0:
                    vv = _unpack(d["embedding"])
                    if len(vv) == int(d.get("dim") or 0):
                        base = max(base, _cos(qv, vv))
            except Exception:
                pass
            d.pop("embedding", None)
            d["type"] = "procedural"
            d["score"] = base
            procs.append(d)
        result["procedural"] = _rank_items(procs, q, k)
        touch_ids = [p.get("id") for p in result["procedural"] if p.get("id")]
        if touch_ids:
            try:
                with _conn(engine) as con:
                    for pid in touch_ids:
                        con.execute("UPDATE memory_procedures SET last_used_at=? WHERE user_key=? AND id=?", (_now(), u, pid))
            except Exception:
                pass

    # Lightweight relation/graph recall folded into scores.
    rel_rows = []
    if q:
        rel_rows = _query_rows(engine, """
            SELECT subject,relation,object,source_type,source_id,weight,updated_at FROM memory_relations
            WHERE user_key=? AND (subject LIKE ? OR object LIKE ?) ORDER BY weight DESC, updated_at DESC LIMIT ?
        """, (u, like, like, max(k, 10)))
    result["relations"] = [dict(r) | {"type": "relation", "content": f"{r['subject']} -{r['relation']}-> {r['object']}", "score": min(1.0, float(r['weight'] or 1.0) / 5.0)} for r in rel_rows]

    if "graph" in inc:
        try:
            graph = graph_query(engine, u, q, k=k)
            result["graph"] = graph.get("paths") or []
            result["graph_nodes"] = graph.get("nodes") or []
        except Exception:
            result["graph"] = []
            result["graph_nodes"] = []

    for key in ["working", "episodic", "semantic", "timeline", "procedural", "facts", "vector", "graph", "relations"]:
        result["scores"][key] = [float(x.get("score") or 0.0) for x in result.get(key, [])]
    result["ok"] = True
    result["user_key"] = u
    result["query"] = q
    return result


def list_timeline(engine: Any, user_key: str, *, limit: int = 100, date: str = "", start: str = "", end: str = "") -> List[Dict[str, Any]]:
    ensure_memory_v2_schema(engine)
    u = sanitize_user_key(user_key)
    clauses = ["user_key=?"]
    args: List[Any] = [u]
    if date:
        clauses.append("date_str=?")
        args.append(date)
    if start:
        clauses.append("date_str>=?")
        args.append(start)
    if end:
        clauses.append("date_str<=?")
        args.append(end)
    args.append(max(1, min(int(limit or 100), 500)))
    rows = _query_rows(engine, f"SELECT * FROM memory_timeline WHERE {' AND '.join(clauses)} ORDER BY created_at DESC LIMIT ?", args)
    return [dict(r) for r in rows]


def list_procedures(engine: Any, user_key: str, *, limit: int = 100) -> List[Dict[str, Any]]:
    ensure_memory_v2_schema(engine)
    rows = _query_rows(engine, "SELECT id,title,content,tags,success_count,failure_count,importance,source,trace_id,metadata,created_at,updated_at,last_used_at FROM memory_procedures WHERE user_key=? ORDER BY importance DESC, updated_at DESC LIMIT ?", (sanitize_user_key(user_key), max(1, min(int(limit or 100), 500))))
    return [dict(r) for r in rows]


def debug_memory(engine: Any, user_key: str) -> Dict[str, Any]:
    ensure_memory_v2_schema(engine)
    u = sanitize_user_key(user_key)
    tables = ["memory_items", "memory_facts", "memory_timeline", "memory_episodes", "memory_raw", "memory_procedures", "memory_relations", "memory_nodes", "memory_edges", "temporal_edges", "memory_consolidation_traces"]
    counts: Dict[str, int] = {}
    latest: Dict[str, float] = {}
    with _conn(engine) as con:
        for t in tables:
            try:
                counts[t] = int(con.execute(f"SELECT COUNT(*) FROM {t} WHERE user_key=?", (u,)).fetchone()[0] or 0)
                col = "last_used_at" if t in ("memory_items", "memory_procedures") else ("updated_at" if t in ("memory_episodes", "memory_relations", "memory_nodes", "memory_edges", "temporal_edges") else "created_at")
                latest[t] = float(con.execute(f"SELECT MAX({col}) FROM {t} WHERE user_key=?", (u,)).fetchone()[0] or 0.0)
            except Exception:
                counts[t] = 0
                latest[t] = 0.0
    return {"ok": True, "user_key": u, "db_path": getattr(getattr(engine, "cfg", None), "db_path", ""), "counts": counts, "latest": latest, "layers": ["working", "episodic", "semantic", "timeline", "procedural"], "graph": {"node_types": sorted(GRAPH_NODE_TYPES), "edge_types": sorted(GRAPH_EDGE_TYPES)}}


def consolidate(engine: Any, user_key: str, scope: str = "recent", dry_run: bool = False) -> Dict[str, Any]:
    ensure_memory_v2_schema(engine)
    u = sanitize_user_key(user_key)
    sc = (scope or "recent").lower()
    trace_id = uuid.uuid4().hex
    outputs: Dict[str, Any] = {"episodes": [], "facts": [], "profile": [], "procedures": []}

    raw_rows = _query_rows(engine, "SELECT * FROM memory_raw WHERE user_key=? ORDER BY created_at DESC LIMIT ?", (u, 40 if sc == "recent" else 200))
    input_counts = {"raw": len(raw_rows)}
    if raw_rows:
        chronological = list(reversed(raw_rows[-12:] if sc == "recent" else raw_rows[:40]))
        joined = "\n".join(f"{r['role'] or 'raw'}: {r['content']}" for r in chronological)
        goal = _short(chronological[0]["content"], 120) if chronological else "recent memory"
        summary = _short("; ".join([str(r["content"]) for r in chronological]), 900)
        ep_meta = {"goal": goal, "status": "done", "result": "consolidated", "trace_id": trace_id, "source": "memory_consolidation", "steps": [{"role": r["role"], "content": _short(r["content"], 160)} for r in chronological]}
        outputs["episodes"].append({"content": summary, "metadata": ep_meta})

    # Extract simple durable semantic facts from raw/episodes.
    fact_patterns = [r"用户要求[^。.!?]{4,120}", r"必须[^。.!?]{4,120}", r"不要[^。.!?]{4,120}", r"偏好[^。.!?]{4,120}", r"ChatAGI[^。.!?]{4,160}"]
    pool = "\n".join(str(r["content"]) for r in raw_rows)
    for pat in fact_patterns:
        for m in re.findall(pat, pool):
            outputs["facts"].append({"content": _short(m, 240), "metadata": {"tags": "consolidated,semantic", "importance": 4, "trace_id": trace_id}})
    # Project profile when repeated themes appear.
    low = pool.lower()
    profile_bits = []
    for term in ["手机控制电脑", "braincore", "local-agent", "swiftui", "记忆", "memory", "computer control"]:
        if low.count(term.lower()) >= 2:
            profile_bits.append(term)
    if profile_bits:
        outputs["profile"].append({"content": "ChatAGI 当前长期项目画像包含: " + ", ".join(profile_bits), "metadata": {"tags": "profile,project", "importance": 5, "trace_id": trace_id}})

    if not dry_run:
        for ep in outputs["episodes"]:
            memory_write(engine, u, "episode", ep["content"], ep["metadata"])
        for f in outputs["facts"]:
            memory_write(engine, u, "fact", f["content"], f["metadata"])
        for pf in outputs["profile"]:
            memory_write(engine, u, "fact", pf["content"], pf["metadata"])
    output_counts = {k: len(v) for k, v in outputs.items()}
    with _conn(engine) as con:
        con.execute("INSERT INTO memory_consolidation_traces(id,user_key,scope,dry_run,input_counts,output_counts,result,created_at) VALUES(?,?,?,?,?,?,?,?)",
                    (trace_id, u, sc, 1 if dry_run else 0, _json(input_counts), _json(output_counts), _json(outputs), _now()))
    return {"ok": True, "trace_id": trace_id, "user_key": u, "scope": sc, "dry_run": bool(dry_run), "input_counts": input_counts, "output_counts": output_counts, "result": outputs}


def build_context_text(recall: Dict[str, Any], max_chars: int = 3600) -> str:
    labels = [("facts", "事实记忆"), ("procedural", "程序性记忆"), ("graph", "图记忆"), ("episodic", "事情线"), ("timeline", "时间线"), ("vector", "语义召回"), ("working", "工作记忆")]
    parts: List[str] = []
    budget = max_chars
    for key, title in labels:
        items = recall.get(key) or []
        if not items:
            continue
        lines = [f"【{title}】"]
        for it in items[:5]:
            text = _short(it.get("content") or it.get("summary") or it.get("text") or it.get("title") or "", 260)
            if not text:
                continue
            line = f"- {text}"
            if budget - len(line) < 60:
                break
            lines.append(line)
            budget -= len(line)
        if len(lines) > 1:
            parts.append("\n".join(lines))
    return "\n\n".join(parts).strip()




def _ensure_episode_methods(engine: Any) -> None:
    """Attach episode methods when older memory_module forgot monkey-patching."""
    if hasattr(engine, "episode_list") and hasattr(engine, "episode_save"):
        return

    def _episode_save(user_key: str, conversation_id: str, summary: str, *, start_at: float = 0.0, end_at: float = 0.0,
                      title: str = "", keywords: str = "", source_meta: str = "") -> str:
        ensure_memory_v2_schema(engine)
        u = sanitize_user_key(user_key)
        eid = uuid.uuid4().hex
        now = _now()
        emb = _embed(engine, (title + "\n" + summary).strip()) or []
        with _conn(engine) as con:
            con.execute("""
            INSERT INTO memory_episodes(id,user_key,conversation_id,title,summary,keywords,start_at,end_at,embedding,dim,source_meta,created_at,updated_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, (eid, u, conversation_id or "", title or "", summary, keywords or "", float(start_at or now), float(end_at or now), _pack(emb) if emb else None, len(emb), source_meta or "", now, now))
        return eid

    def _episode_list(user_key: str, limit: int = 20, conversation_id: str = "") -> List[Dict[str, Any]]:
        ensure_memory_v2_schema(engine)
        u = sanitize_user_key(user_key)
        args: List[Any] = [u]
        where = "user_key=?"
        if conversation_id:
            where += " AND conversation_id=?"
            args.append(conversation_id)
        args.append(max(1, min(int(limit or 20), 500)))
        rows = _query_rows(engine, f"SELECT * FROM memory_episodes WHERE {where} ORDER BY updated_at DESC LIMIT ?", args)
        out = []
        for r in rows:
            d = dict(r)
            d.pop("embedding", None)
            out.append(d)
        return out

    def _episode_search(user_key: str, query: str, *, conversation_id: str = "", k: int = 6, min_score: float = 0.05, candidate_limit: int = 400) -> List[Dict[str, Any]]:
        ensure_memory_v2_schema(engine)
        q = str(query or "")
        rows = _episode_list(user_key, limit=candidate_limit, conversation_id=conversation_id)
        items = []
        qv = None
        emb = _embed(engine, q)
        if emb:
            qv = array("f", [float(x) for x in emb])
        for r in rows:
            text = str(r.get("summary") or "")
            score = _keyword_score(q, text)
            try:
                if qv is not None and r.get("embedding") and int(r.get("dim") or 0) > 0:
                    vv = _unpack(r["embedding"])
                    if len(vv) == int(r.get("dim") or 0):
                        score = max(score, _cos(qv, vv))
            except Exception:
                pass
            if score >= min_score:
                items.append({**r, "score": score})
        items.sort(key=lambda x: float(x.get("score") or 0.0), reverse=True)
        return items[:max(1, int(k or 6))]

    setattr(engine, "episode_save", _episode_save)
    setattr(engine, "episode_list", _episode_list)
    setattr(engine, "episode_search", _episode_search)

def patch_memory_engine(engine: Any) -> Any:
    if engine is None:
        return None
    ensure_memory_v2_schema(engine)
    _ensure_episode_methods(engine)
    setattr(engine, "ensure_memory_v2_schema", lambda: ensure_memory_v2_schema(engine))
    setattr(engine, "write_memory", lambda user_key, type, content, metadata=None: memory_write(engine, user_key, type, content, metadata))
    setattr(engine, "hybrid_recall", lambda user_key, query, k=10, include=None: hybrid_recall(engine, user_key, query, k, include))
    setattr(engine, "consolidate_memory", lambda user_key, scope="recent", dry_run=False: consolidate(engine, user_key, scope, dry_run))
    setattr(engine, "timeline_v2", lambda user_key, **kw: list_timeline(engine, user_key, **kw))
    setattr(engine, "procedures_list", lambda user_key, **kw: list_procedures(engine, user_key, **kw))
    setattr(engine, "debug_memory_v2", lambda user_key: debug_memory(engine, user_key))
    setattr(engine, "hybrid_context_text", lambda user_key, query, k=10, include=None, max_chars=3600: build_context_text(hybrid_recall(engine, user_key, query, k, include), max_chars=max_chars))
    setattr(engine, "graph_upsert", lambda user_key, nodes=None, edges=None, metadata=None: graph_upsert(engine, user_key, nodes or [], edges or [], metadata or {}))
    setattr(engine, "graph_query", lambda user_key, query="", k=10, **kw: graph_query(engine, user_key, query, k, **kw))
    setattr(engine, "graph_from_episode", lambda user_key, episode_id="", content="", metadata=None: graph_from_episode(engine, user_key, episode_id, content, metadata or {}))
    return engine


__all__ = [
    "patch_memory_engine", "ensure_memory_v2_schema", "memory_write", "hybrid_recall", "consolidate",
    "list_timeline", "list_procedures", "debug_memory", "build_context_text",
    "graph_upsert", "graph_query", "graph_from_episode", "GRAPH_NODE_TYPES", "GRAPH_EDGE_TYPES",
]
