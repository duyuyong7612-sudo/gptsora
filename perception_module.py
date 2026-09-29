# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-575aeea34a85ac8e796aca6372ee622bb8d73fa72c755deaa06415b3c67a40ad"
# Source-SHA256: "a8586f1ee07cd79f228eb064945b033e25899b6f114a9bb559ade493959c8bd9"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
perception_module.py — 阿杜物理世界感知后端模块 v3
====================================================
★ v3 修复：同时兼容 camelCase 和 snake_case 字段名
  iOS 用 .convertToSnakeCase 编码，字段到后端变成 snake_case
  但旧代码只读 camelCase → 所有字段都是 None → 感知从未生效

使用方法（在 server_session.py 里）：
    from perception_module import enrich_perception_data, format_perception_context
    
    perception_data = await enrich_perception_data(perception_data)  # 补门牌号
    context = format_perception_context(perception_data)             # 转自然语言
"""

import os, json, logging, sqlite3, httpx
from datetime import datetime, timedelta
from typing import Optional, Dict, List
from contextlib import contextmanager

log = logging.getLogger("perception")

PERCEPTION_DB = os.getenv("PERCEPTION_DB", "perception.sqlite3")
GOOGLE_MAPS_API_KEY = os.getenv("GOOGLE_MAPS_API_KEY", "")


# ══════════════════════════════════════════════
# 兼容层：同时支持 camelCase / snake_case
# ══════════════════════════════════════════════

def _g(data: dict, camel: str, snake: str, default=None):
    """优先取 camelCase，fallback 到 snake_case"""
    v = data.get(camel)
    if v is None:
        v = data.get(snake)
    return v if v is not None else default


def _normalize(data: dict) -> dict:
    """把 iOS 传来的数据统一成 camelCase（内部统一格式）"""
    return {
        "timestamp":           _g(data, "timestamp", "timestamp", ""),
        "latitude":            _g(data, "latitude", "latitude", 0),
        "longitude":           _g(data, "longitude", "longitude", 0),
        "altitude":            _g(data, "altitude", "altitude", 0),
        "speed":               _g(data, "speed", "speed", 0),
        "horizontalAccuracy":  _g(data, "horizontalAccuracy", "horizontal_accuracy", 0),
        "country":             _g(data, "country", "country"),
        "city":                _g(data, "city", "city"),
        "district":            _g(data, "district", "district"),
        "street":              _g(data, "street", "street"),
        "streetNumber":        _g(data, "streetNumber", "street_number"),
        "poiName":             _g(data, "poiName", "poi_name"),
        "fullAddress":         _g(data, "fullAddress", "full_address"),
        "heading":             _g(data, "heading", "heading", -1),
        "headingDescription":  _g(data, "headingDescription", "heading_description", "未知"),
        "motionState":         _g(data, "motionState", "motion_state", "未知"),
        "sceneDescription":    _g(data, "sceneDescription", "scene_description"),
        "geocodeSource":       _g(data, "geocodeSource", "geocode_source"),
    }


# ── 数据库 ──

def _init_db():
    conn = sqlite3.connect(PERCEPTION_DB)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS world_memory (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id TEXT NOT NULL,
            timestamp TEXT NOT NULL,
            latitude REAL,
            longitude REAL,
            altitude REAL,
            speed REAL,
            country TEXT,
            city TEXT,
            district TEXT,
            street TEXT,
            street_number TEXT,
            poi_name TEXT,
            full_address TEXT,
            heading REAL,
            heading_desc TEXT,
            motion_state TEXT,
            scene_description TEXT,
            place_key TEXT,
            geocode_source TEXT,
            created_at TEXT DEFAULT (datetime('now'))
        )
    """)
    conn.execute("""
        CREATE INDEX IF NOT EXISTS idx_wm_user_time
        ON world_memory(user_id, timestamp DESC)
    """)
    conn.commit()
    conn.close()

_init_db()

@contextmanager
def _db():
    conn = sqlite3.connect(PERCEPTION_DB)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


# ══════════════════════════════════════════════
# 0. Google Geocoding 反向地理编码（后端 fallback）
# ══════════════════════════════════════════════

async def google_reverse_geocode(lat: float, lng: float) -> Optional[Dict]:
    """调用 Google Geocoding API 反向地理编码，返回门牌号+地址"""
    if not GOOGLE_MAPS_API_KEY:
        log.warning("[Perception] GOOGLE_MAPS_API_KEY 未配置")
        return None

    url = (
        f"https://maps.googleapis.com/maps/api/geocode/json"
        f"?latlng={lat},{lng}"
        f"&key={GOOGLE_MAPS_API_KEY}"
        f"&language=en"
        f"&result_type=street_address"
    )

    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get(url)
            data = resp.json()

        if data.get("status") != "OK" or not data.get("results"):
            log.warning("[Perception] Google: status=%s", data.get("status"))
            return None

        first = data["results"][0]
        result = {"formatted_address": first.get("formatted_address")}

        for comp in first.get("address_components", []):
            types = comp.get("types", [])
            name = comp.get("long_name", "")
            if "street_number" in types:
                result["street_number"] = name
            elif "route" in types:
                result["route"] = name

        log.info("[Perception] Google✅: #%s %s → %s",
                 result.get("street_number", "?"),
                 result.get("route", "?"),
                 result.get("formatted_address", "?"))
        return result

    except Exception as e:
        log.error("[Perception] Google请求失败: %s", e)
        return None


# ══════════════════════════════════════════════
# 1. ★ 感知数据增强（标准化 + Google fallback）★
# ══════════════════════════════════════════════

async def enrich_perception_data(data: dict) -> dict:
    """
    ★ 核心函数 ★
    1. 统一字段名（兼容 iOS snake_case）
    2. 检查门牌号，缺则调 Google Geocoding 补充
    """
    # Step 1: 统一格式
    d = _normalize(data)

    lat = d.get("latitude", 0)
    lng = d.get("longitude", 0)
    street_number = (d.get("streetNumber") or "").strip()

    log.info("[Perception] 收到感知: lat=%.6f lng=%.6f city=%s street=%s number=%s addr=%s",
             lat, lng,
             d.get("city", "?"), d.get("street", "?"),
             street_number or "无", d.get("fullAddress", "?"))

    # Step 2: 已有门牌号
    if street_number:
        d["geocodeSource"] = "Apple"
        return d

    # Step 3: 没有门牌号 → Google fallback
    if lat and lng:
        log.info("[Perception] Apple无门牌号 → Google fallback")
        google = await google_reverse_geocode(lat, lng)

        if google and google.get("street_number"):
            d["streetNumber"] = google["street_number"]
            d["geocodeSource"] = "Google"

            if not (d.get("street") or "").strip():
                d["street"] = google.get("route", "")

            if google.get("formatted_address"):
                d["fullAddress"] = google["formatted_address"]

            log.info("[Perception] ✅ Google补充: #%s → %s",
                     google["street_number"],
                     google.get("formatted_address", ""))
        else:
            d["geocodeSource"] = "none"
            log.info("[Perception] Google也无门牌号")
    else:
        d["geocodeSource"] = "none"

    return d


# ══════════════════════════════════════════════
# 2. 感知 JSON → 自然语言上下文（注入 LLM system prompt）
# ══════════════════════════════════════════════

def format_perception_context(data: dict) -> Optional[str]:
    """
    把 PerceptionSnapshot 转成 LLM 自然语言。
    ★ 调用前先 enrich_perception_data() ★
    """
    lat = data.get("latitude", 0)
    lng = data.get("longitude", 0)
    if not lat and not lng:
        return None

    parts = []

    poi_name = (data.get("poiName") or "").strip()
    full_addr = (data.get("fullAddress") or "").strip()
    street_number = (data.get("streetNumber") or "").strip()
    street = (data.get("street") or "").strip()
    city = (data.get("city") or "").strip()

    # 构建最精确的位置描述
    best_address = ""

    if full_addr and street_number:
        best_address = full_addr
    elif poi_name and any(c.isdigit() for c in poi_name):
        best_address = poi_name
        if city and city not in poi_name:
            best_address = f"{city} {poi_name}"
    elif full_addr:
        best_address = full_addr
    elif street_number and street:
        best_address = f"{street_number} {street}, {city}".strip(", ")
    elif street:
        best_address = f"{city} {street}".strip()
    elif city:
        best_address = city

    if best_address:
        parts.append(f"你（阿杜）当前精确位置：{best_address}")
    else:
        parts.append(f"你当前GPS坐标：{lat:.6f}, {lng:.6f}")

    if poi_name and poi_name != best_address and not any(c.isdigit() for c in poi_name):
        parts.append(f"附近地标：{poi_name}")

    accuracy = data.get("horizontalAccuracy", 0)
    if accuracy and accuracy > 0:
        parts.append(f"定位精度：{accuracy:.0f}米")

    alt = data.get("altitude", 0)
    if alt and alt > 10:
        parts.append(f"海拔：{int(alt)}米")

    heading = data.get("heading", -1)
    heading_desc = data.get("headingDescription", "未知")
    if heading is not None and heading >= 0:
        parts.append(f"面朝方向：{heading_desc}（{int(heading)}°）")

    motion = data.get("motionState", "未知")
    if motion and motion != "未知":
        parts.append(f"运动状态：{motion}")

    speed = data.get("speed", 0)
    if speed and speed > 1:
        kmh = speed * 3.6
        parts.append(f"移动速度：{kmh:.0f} km/h")

    if not parts:
        return None

    return (
        "[阿杜物理世界感知 — 以下是你此刻对物理世界的感知，请自然地用在回答中]\n"
        + "\n".join(parts)
        + "\n[注意：用自然口语表达位置信息，不要原样输出上面的格式]"
    )


# ══════════════════════════════════════════════
# 3. 存储到世界记忆
# ══════════════════════════════════════════════

def store_to_world_memory(user_id: str, data: dict) -> bool:
    """每次感知成功后调用，存一条记录。data 已被 enrich 统一为 camelCase。"""
    try:
        place_key = _make_place_key(data)
        with _db() as conn:
            conn.execute("""
                INSERT INTO world_memory
                (user_id, timestamp, latitude, longitude, altitude, speed,
                 country, city, district, street, street_number,
                 poi_name, full_address, heading, heading_desc,
                 motion_state, scene_description, place_key, geocode_source)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, (
                user_id,
                data.get("timestamp", datetime.utcnow().isoformat()),
                data.get("latitude"), data.get("longitude"),
                data.get("altitude", 0), data.get("speed", 0),
                data.get("country"), data.get("city"),
                data.get("district"), data.get("street"),
                data.get("streetNumber"),
                data.get("poiName"), data.get("fullAddress"),
                data.get("heading", -1),
                data.get("headingDescription", "未知"),
                data.get("motionState", "未知"),
                data.get("sceneDescription"),
                place_key,
                data.get("geocodeSource"),
            ))
        return True
    except Exception as e:
        log.error("[WorldMemory] store error: %s", e)
        return False


def get_places_visited(user_id: str, days: int = 30, limit: int = 20) -> List[dict]:
    """查询去过的地方（去重聚合）"""
    since = (datetime.utcnow() - timedelta(days=days)).isoformat()
    with _db() as conn:
        rows = conn.execute("""
            SELECT place_key, city, street, poi_name, full_address,
                   MIN(timestamp) as first_visit,
                   MAX(timestamp) as last_visit,
                   COUNT(*) as visit_count
            FROM world_memory
            WHERE user_id=? AND timestamp>=? AND place_key IS NOT NULL
            GROUP BY place_key
            ORDER BY last_visit DESC LIMIT ?
        """, (user_id, since, limit)).fetchall()
        return [dict(r) for r in rows]


def _make_place_key(data: dict) -> Optional[str]:
    city = data.get("city") or ""
    street = data.get("street") or ""
    if city or street:
        district = data.get("district") or ""
        return f"{city}:{district}:{street}".strip(":")
    lat = data.get("latitude", 0)
    lng = data.get("longitude", 0)
    if lat and lng:
        return f"grid:{lat:.3f}:{lng:.3f}"
    return None


# ══════════════════════════════════════════════
# 4. FastAPI 路由
# ══════════════════════════════════════════════

def register_perception_routes(app):
    from fastapi import Request
    from fastapi.responses import JSONResponse

    @app.get("/perception/memory")
    async def perception_memory(request: Request):
        """查询去过的地方"""
        user_id = request.query_params.get("user_id", "anonymous")
        days = int(request.query_params.get("days", "30"))
        places = get_places_visited(user_id, days=days)
        return JSONResponse({"places": places, "count": len(places)})

    log.info("[Perception] /perception/memory registered")

