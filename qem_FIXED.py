# =========================
# Quantum Mouse Engine (QEM v1.1 upgraded — FIXED)
# =========================
# v1.1 改进:
#   - propose_candidates 不再调 locate_target_with_bbox(省 5-10 秒)
#   - dock_icon click_point 从 h*0.55 改成 h*0.48(修偏低 bug)
#   - local_observation_refine 加 dock_icon 专用小步约束(±10/±6 px, 不超 bbox)
#   - ground_candidate 对大面积 bbox 降权(area > 40000 -> visual_score 上限 0.45)
# 修复 13 处 SyntaxError(全部缺乘号 *)

# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-17f92ba9b875dc583062feda53c9bb74859bc738db0226eace6e5f289f609a06"
# Source-SHA256: "ea0f8eda439630ddc5beca8bf57e82c87d401ad38a3b907cbd5712aa2879ffa1"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
QEM_MAX_CANDIDATES = 4
QEM_COLLAPSE_THRESHOLD = 0.78
QEM_DIRECT_COMMIT_THRESHOLD = 0.88
QEM_MOVE_STEP_PX = 72
QEM_LOCAL_CROP_SIZE = 280
QEM_MAX_TICKS = 6
QEM_MIN_CLICK_VERIFY_SUCCESS = 0.55


@dataclass
class QuantumCandidate:
    cid: str
    bbox_abs: Dict[str, int]
    click_point_abs: Dict[str, int]
    target_type: str = "unknown"
    source: str = ""

    visual_score: float = 0.0
    memory_score: float = 0.0
    geometry_score: float = 0.0
    intent_score: float = 0.0

    posterior: float = 0.0
    rank_hint: int = 0
    debug: Dict[str, Any] = field(default_factory=dict)


@dataclass
class QuantumMouseState:
    target: str
    region_hint: str
    cursor: Dict[str, int]

    candidates: List[QuantumCandidate] = field(default_factory=list)

    tick: int = 0
    collapsed: bool = False
    chosen_cid: Optional[str] = None
    collapse_confidence: float = 0.0
    action_mode: str = "observe"
    logs: List[Dict[str, Any]] = field(default_factory=list)
    started_at: float = field(default_factory=time.time)


GROUND_TARGET_PROMPT_QEM = """You are looking at a screenshot crop that may contain the target.

Return strict JSON:
{
  "target_visible": true | false,
  "target_type": "icon" | "button" | "menu_item" | "text_field" | "tab" | "list_item" | "window_control" | "dock_icon" | "menubar_item" | "unknown",
  "bbox": {"x": integer, "y": integer, "w": integer, "h": integer} | null,
  "click_point": {"x": integer, "y": integer} | null,
  "confidence": 0.0-1.0,
  "reason": "short"
}

Rules:
- bbox must tightly wrap the clickable target itself.
- click_point must be the best single point to click.
- Coordinates are in THIS image pixel space.
- If target is not visible, set target_visible=false and bbox/click_point=null.
- JSON only.
"""


DELTA_REFINE_PROMPT_QEM = """You see a zoomed screenshot around the target.

The current cursor position is marked by a GREEN crosshair.

Return strict JSON:
{
  "on_target": true | false,
  "delta": {"dx": integer, "dy": integer},
  "confidence": 0.0-1.0,
  "reason": "short"
}

Rules:
- dx,dy mean how many pixels the cursor should move FROM CURRENT POSITION to reach the ideal click point.
- If already correct, return dx=0 and dy=0.
- Keep dx,dy small and realistic for this crop.
- JSON only.
"""


def _qem_clamp(v: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, v))


def _qem_center_of_bbox(b: Dict[str, int]) -> Dict[str, int]:
    return {
        "x": int(b["x"] + b["w"] / 2),
        "y": int(b["y"] + b["h"] / 2),
    }


def _qem_dist(ax: float, ay: float, bx: float, by: float) -> float:
    return math.hypot(ax - bx, ay - by)


def choose_region_hint_qem(target: str) -> str:
    if is_dock_target(target):
        return "dock"
    if is_menubar_target(target):
        return "menubar"
    return "full"


def get_region_rect_qem(region_hint: str) -> Tuple[float, float, float, float]:
    sw, sh = get_screen_size()
    if region_hint == "dock":
        return get_dock_band_rect(sw, sh)
    if region_hint == "menubar":
        return get_menubar_band_rect(sw, sh)
    return (0.0, 0.0, float(sw), float(sh))


def load_click_priors_qem() -> dict:
    m = load_memory()
    if not isinstance(m, dict):
        return {}
    priors = m.get("_click_priors")
    if not isinstance(priors, dict):
        priors = {}
    return priors


def save_click_priors_qem(priors: dict):
    m = load_memory()
    if not isinstance(m, dict):
        m = {}
    m["_click_priors"] = priors
    save_memory(m)


def remember_click_profile_qem(target: str,
                               region_hint: str,
                               target_type: str,
                               bbox_abs: Dict[str, int],
                               click_point_abs: Dict[str, int],
                               success: bool):
    if not target or not success:
        return

    sw, sh = get_screen_size()
    if sw <= 0 or sh <= 0:
        return

    key = _canonical_key(target)
    priors = load_click_priors_qem()
    arr = priors.get(key, [])

    entry = {
        "region_hint": region_hint,
        "target_type": target_type,
        "bbox_norm": [
            round(bbox_abs["x"] / sw, 6),
            round(bbox_abs["y"] / sh, 6),
            round(bbox_abs["w"] / sw, 6),
            round(bbox_abs["h"] / sh, 6),
        ],
        "click_norm": [
            round(click_point_abs["x"] / sw, 6),
            round(click_point_abs["y"] / sh, 6),
        ],
        "screen_w": sw,
        "screen_h": sh,
        "retina_scale": round(_scale(), 3),
        "last_success": _dt.datetime.now().isoformat(timespec="seconds"),
        "count": 1,
    }

    merged = False
    for old in arr:
        if old.get("region_hint") == region_hint and old.get("target_type") == target_type:
            old["bbox_norm"] = entry["bbox_norm"]
            old["click_norm"] = entry["click_norm"]
            old["screen_w"] = sw
            old["screen_h"] = sh
            old["retina_scale"] = entry["retina_scale"]
            old["last_success"] = entry["last_success"]
            old["count"] = int(old.get("count", 0)) + 1
            merged = True
            break

    if not merged:
        arr.append(entry)

    arr = sorted(arr, key=lambda x: int(x.get("count", 0)), reverse=True)[:8]
    priors[key] = arr
    save_click_priors_qem(priors)


def get_click_prior_candidates_qem(target: str, region_hint: str) -> List[Dict[str, Any]]:
    key = _canonical_key(target)
    priors = load_click_priors_qem()
    arr = priors.get(key, [])
    if not arr:
        return []

    sw, sh = get_screen_size()
    out = []
    for i, p in enumerate(arr):
        if p.get("region_hint") != region_hint:
            continue
        bbox_norm = p.get("bbox_norm") or []
        click_norm = p.get("click_norm") or []
        if len(bbox_norm) != 4 or len(click_norm) != 2:
            continue

        bx = int(bbox_norm[0] * sw)
        by = int(bbox_norm[1] * sh)
        bw = max(1, int(bbox_norm[2] * sw))
        bh = max(1, int(bbox_norm[3] * sh))
        cx = int(click_norm[0] * sw)
        cy = int(click_norm[1] * sh)

        out.append({
            "bbox_abs": {"x": bx, "y": by, "w": bw, "h": bh},
            "click_point_abs": {"x": cx, "y": cy},
            "target_type": p.get("target_type", "unknown"),
            "score": min(0.98, 0.72 + 0.04 * int(p.get("count", 1))),
            "source": "memory_prior",
            "rank_hint": i + 1,
        })
    return out


def _extract_click_point_from_text(text: str) -> Dict[str, Any]:
    raw = _extract_json_from_text(text)
    cp = raw.get("click_point")
    bbox = raw.get("bbox")
    out = {
        "target_visible": bool(raw.get("target_visible", False)),
        "target_type": str(raw.get("target_type") or "unknown").strip(),
        "confidence": float(raw.get("confidence") or 0.0),
        "reason": str(raw.get("reason") or "").strip(),
        "bbox": None,
        "click_point": None,
    }

    if isinstance(bbox, dict):
        try:
            out["bbox"] = {
                "x": int(bbox.get("x", 0)),
                "y": int(bbox.get("y", 0)),
                "w": int(bbox.get("w", 0)),
                "h": int(bbox.get("h", 0)),
            }
        except Exception:
            out["bbox"] = None

    if isinstance(cp, dict):
        try:
            out["click_point"] = {
                "x": int(cp.get("x", 0)),
                "y": int(cp.get("y", 0)),
            }
        except Exception:
            out["click_point"] = None

    return out


def _extract_delta_refine_from_text(text: str) -> Dict[str, Any]:
    raw = _extract_json_from_text(text)
    d = raw.get("delta") or {}
    try:
        dx = int(d.get("dx", 0))
        dy = int(d.get("dy", 0))
    except Exception:
        dx, dy = 0, 0
    return {
        "on_target": bool(raw.get("on_target", False)),
        "delta": {"dx": dx, "dy": dy},
        "confidence": float(raw.get("confidence") or 0.0),
        "reason": str(raw.get("reason") or "").strip(),
    }


def apply_click_point_heuristics_qem(target_type: str,
                                     bbox_abs: Dict[str, int],
                                     click_point_abs: Dict[str, int]) -> Dict[str, int]:
    """根据 target_type 把 click_point 调整到该类型最适合点击的位置 (FIXED: * 补回)"""
    x, y, w, h = bbox_abs["x"], bbox_abs["y"], bbox_abs["w"], bbox_abs["h"]

    if target_type == "text_field":
        return {"x": int(x + max(8, w * 0.22)), "y": int(y + h * 0.5)}
    if target_type == "menu_item":
        return {"x": int(x + max(10, w * 0.30)), "y": int(y + h * 0.5)}
    if target_type == "tab":
        return {"x": int(x + w * 0.50), "y": int(y + h * 0.45)}
    if target_type == "dock_icon":
        return {"x": int(x + w * 0.50), "y": int(y + h * 0.48)}
    if target_type == "icon":
        return {"x": int(x + w * 0.50), "y": int(y + h * 0.52)}
    if target_type == "menubar_item":
        return {"x": int(x + w * 0.50), "y": int(y + h * 0.55)}
    return {
        "x": int(click_point_abs["x"]),
        "y": int(click_point_abs["y"]),
    }


def propose_candidates_qem(target: str,
                           region_hint: str,
                           max_candidates: int = QEM_MAX_CANDIDATES,
                           save_debug: bool = True) -> Dict[str, Any]:
    """v1.1: 不再调 locate_target_with_bbox,直接用 region 几何切候选(快 5-10 秒)"""
    debug_images = []
    candidates = []

    # 1) memory prior
    mem = get_click_prior_candidates_qem(target, region_hint)
    for x in mem[:max_candidates]:
        candidates.append(x)

    # 2) lightweight region candidate instead of heavy legacy locate_target_with_bbox
    try:
        rr = get_region_rect_qem(region_hint)
        rx, ry, rw, rh = rr

        if region_hint == "dock":
            dock_bbox = {
                "x": int(rx),
                "y": int(ry),
                "w": int(rw),
                "h": int(rh),
            }
            candidates.append({
                "bbox_abs": dock_bbox,
                "click_point_abs": _qem_center_of_bbox(dock_bbox),
                "target_type": "dock_icon",
                "score": 0.78,
                "source": "dock_band_candidate",
                "rank_hint": 1,
            })
        elif region_hint == "menubar":
            menu_bbox = {
                "x": int(rx),
                "y": int(ry),
                "w": int(rw),
                "h": int(rh),
            }
            candidates.append({
                "bbox_abs": menu_bbox,
                "click_point_abs": _qem_center_of_bbox(menu_bbox),
                "target_type": "menubar_item",
                "score": 0.74,
                "source": "menubar_band_candidate",
                "rank_hint": 1,
            })
        else:
            full_bbox = {
                "x": int(rx + rw * 0.10),
                "y": int(ry + rh * 0.10),
                "w": max(80, int(rw * 0.80)),
                "h": max(80, int(rh * 0.80)),
            }
            candidates.append({
                "bbox_abs": full_bbox,
                "click_point_abs": _qem_center_of_bbox(full_bbox),
                "target_type": "unknown",
                "score": 0.52,
                "source": "full_region_candidate",
                "rank_hint": 2,
            })
    except Exception as e:
        debug_images.append(f"region_candidate_error: {e}")

    # 3) weak fallback
    try:
        rr = get_region_rect_qem(region_hint)
        rx, ry, rw, rh = rr
        fallback_bbox = {
            "x": int(rx + rw * 0.15),
            "y": int(ry + rh * 0.15),
            "w": max(40, int(rw * 0.70)),
            "h": max(40, int(rh * 0.70)),
        }
        candidates.append({
            "bbox_abs": fallback_bbox,
            "click_point_abs": _qem_center_of_bbox(fallback_bbox),
            "target_type": "unknown",
            "score": 0.12,
            "source": "region_fallback",
            "rank_hint": 9,
        })
    except Exception:
        pass

    dedup = []
    seen = set()
    for c in candidates:
        b = c["bbox_abs"]
        key = (b["x"], b["y"], b["w"], b["h"], c.get("source", ""))
        if key in seen:
            continue
        seen.add(key)
        dedup.append(c)

    dedup = sorted(dedup, key=lambda x: float(x.get("score", 0.0)), reverse=True)[:max_candidates]

    return {
        "ok": True,
        "target": target,
        "region_hint": region_hint,
        "candidates": dedup,
        "debug_images": debug_images,
    }


def ground_candidate_qem(target: str,
                         candidate_abs: Dict[str, int],
                         base_score: float = 0.0,
                         source: str = "",
                         rank_hint: int = 0,
                         save_debug: bool = True) -> Dict[str, Any]:
    """v1.1: 大面积 bbox 降权(area>40000 -> visual_score 上限 0.45)"""
    debug_images = []

    try:
        crop = capture_rect_pil(
            candidate_abs["x"], candidate_abs["y"],
            candidate_abs["w"], candidate_abs["h"]
        )
        if save_debug:
            debug_images.append(save_image(crop, f"{now_ts()}_qem_ground_candidate_raw.jpg"))

        iw, ih = crop.size
        jpeg = pil_to_jpeg_bytes(crop, max_dim=1400, quality=90)
        user_text = (
            f"TARGET: {normalize_visual_target(target)}\n\n"
            f"Image size: {iw}x{ih} pixels. "
            f"Find the target and return bbox + click_point + target_type."
        )

        ans = None
        try:
            text = _call_claude_vision(GROUND_TARGET_PROMPT_QEM, user_text, jpeg, max_tokens=320)
            ans = _extract_click_point_from_text(text)
        except Exception as e:
            ans = {
                "target_visible": True,
                "target_type": "unknown",
                "confidence": max(0.40, float(base_score)),
                "reason": f"ground_prompt_failed_fallback: {e}",
                "bbox": {"x": 0, "y": 0, "w": iw, "h": ih},
                "click_point": {"x": iw // 2, "y": ih // 2},
            }

        if not ans.get("target_visible"):
            return {
                "ok": False,
                "target_visible": False,
                "reason": ans.get("reason", "target_not_visible"),
                "source": source,
                "rank_hint": rank_hint,
                "debug_images": debug_images,
            }

        bbox_local = ans.get("bbox") or {"x": 0, "y": 0, "w": iw, "h": ih}
        cp_local = ans.get("click_point") or {"x": iw // 2, "y": ih // 2}

        bx = int(_qem_clamp(bbox_local["x"], 0, max(0, iw - 1)))
        by = int(_qem_clamp(bbox_local["y"], 0, max(0, ih - 1)))
        bw = int(_qem_clamp(bbox_local["w"], 1, max(1, iw - bx)))
        bh = int(_qem_clamp(bbox_local["h"], 1, max(1, ih - by)))

        cpx = int(_qem_clamp(cp_local["x"], 0, max(0, iw - 1)))
        cpy = int(_qem_clamp(cp_local["y"], 0, max(0, ih - 1)))

        sc = _scale()
        logical_x = candidate_abs["x"] + int(round(bx / sc))
        logical_y = candidate_abs["y"] + int(round(by / sc))
        logical_w = max(1, int(round(bw / sc)))
        logical_h = max(1, int(round(bh / sc)))
        click_abs = {
            "x": candidate_abs["x"] + int(round(cpx / sc)),
            "y": candidate_abs["y"] + int(round(cpy / sc)),
        }

        bbox_abs = {
            "x": logical_x,
            "y": logical_y,
            "w": logical_w,
            "h": logical_h,
        }

        click_abs = apply_click_point_heuristics_qem(
            ans.get("target_type", "unknown"),
            bbox_abs,
            click_abs,
        )

        if save_debug:
            try:
                full = capture_screen_pil()
                sc2 = _scale()
                bbox_phy = {
                    "x": int(bbox_abs["x"] * sc2),
                    "y": int(bbox_abs["y"] * sc2),
                    "w": int(bbox_abs["w"] * sc2),
                    "h": int(bbox_abs["h"] * sc2),
                }
                annotated = draw_bbox_rect(full, bbox_phy)
                debug_images.append(save_image(annotated, f"{now_ts()}_qem_ground_candidate_abs.jpg"))
            except Exception:
                pass

        # v1.1: 大面积 bbox 不可信 -> visual_score 上限
        vscore = max(float(base_score), float(ans.get("confidence", 0.0)))
        area = bbox_abs["w"] * bbox_abs["h"]
        if area > 40000:
            vscore = min(vscore, 0.45)

        return {
            "ok": True,
            "target_visible": True,
            "bbox_abs": bbox_abs,
            "click_point_abs": click_abs,
            "target_type": ans.get("target_type", "unknown"),
            "visual_score": vscore,
            "source": source,
            "rank_hint": rank_hint,
            "reason": ans.get("reason", ""),
            "debug_images": debug_images,
        }

    except Exception as e:
        return {
            "ok": False,
            "target_visible": False,
            "reason": f"ground_candidate_error: {e}",
            "source": source,
            "rank_hint": rank_hint,
            "debug_images": debug_images,
        }


def compute_geometry_score_qem(cursor: Dict[str, int],
                               click_point_abs: Dict[str, int],
                               screen_diag: float) -> float:
    d = _qem_dist(cursor["x"], cursor["y"], click_point_abs["x"], click_point_abs["y"])
    if screen_diag <= 1:
        return 0.5
    norm = d / screen_diag
    return _qem_clamp(1.0 - norm, 0.0, 1.0)


def compute_intent_score_qem(target: str, target_type: str, region_hint: str) -> float:
    low = (target or "").lower()

    if region_hint == "dock" and target_type in ("dock_icon", "icon", "unknown"):
        return 0.88
    if region_hint == "menubar" and target_type in ("menubar_item", "menu_item", "unknown"):
        return 0.86
    if ("input" in low or "search" in low or "输入" in target or "搜索" in target) and target_type == "text_field":
        return 0.92
    return 0.70


def compute_memory_score_qem(source: str, base_score: float) -> float:
    if str(source).startswith("memory_prior"):
        return max(0.75, base_score)
    return min(0.68, max(0.0, base_score))


def normalize_posteriors_qem(cands: List[QuantumCandidate]) -> List[QuantumCandidate]:
    total = sum(max(1e-6, c.posterior) for c in cands)
    if total <= 0:
        n = len(cands) or 1
        for c in cands:
            c.posterior = 1.0 / n
        return cands
    for c in cands:
        c.posterior = c.posterior / total
    return cands


def update_candidate_posteriors_qem(qs: QuantumMouseState) -> QuantumMouseState:
    sw, sh = get_screen_size()
    diag = math.hypot(sw, sh)

    for c in qs.candidates:
        c.geometry_score = compute_geometry_score_qem(qs.cursor, c.click_point_abs, diag)
        c.intent_score = compute_intent_score_qem(qs.target, c.target_type, qs.region_hint)
        c.memory_score = compute_memory_score_qem(c.source, c.memory_score or c.visual_score)

        c.posterior = (
            0.42 * float(c.visual_score) +
            0.22 * float(c.memory_score) +
            0.18 * float(c.geometry_score) +
            0.18 * float(c.intent_score)
        )

    qs.candidates = sorted(qs.candidates, key=lambda x: x.posterior, reverse=True)
    qs.candidates = normalize_posteriors_qem(qs.candidates)

    if qs.candidates:
        qs.chosen_cid = qs.candidates[0].cid
        qs.collapse_confidence = qs.candidates[0].posterior

    qs.logs.append({
        "stage": "posterior_update",
        "tick": qs.tick,
        "items": [
            {
                "cid": c.cid,
                "source": c.source,
                "visual_score": round(c.visual_score, 4),
                "memory_score": round(c.memory_score, 4),
                "geometry_score": round(c.geometry_score, 4),
                "intent_score": round(c.intent_score, 4),
                "posterior": round(c.posterior, 4),
                "click_point_abs": c.click_point_abs,
                "bbox_abs": c.bbox_abs,
                "target_type": c.target_type,
            }
            for c in qs.candidates
        ]
    })
    return qs


def compute_entangled_motion_vector_qem(qs: QuantumMouseState) -> Dict[str, Any]:
    if not qs.candidates:
        return {
            "dx": 0.0, "dy": 0.0,
            "target_x": qs.cursor["x"], "target_y": qs.cursor["y"],
            "mode": "none", "chosen_cid": None,
        }

    cx = qs.cursor["x"]
    cy = qs.cursor["y"]

    top = qs.candidates[0]
    if top.posterior >= QEM_DIRECT_COMMIT_THRESHOLD:
        tx = top.click_point_abs["x"]
        ty = top.click_point_abs["y"]
        return {
            "dx": float(tx - cx),
            "dy": float(ty - cy),
            "target_x": tx,
            "target_y": ty,
            "mode": "direct_commit",
            "chosen_cid": top.cid,
        }

    tx = 0.0
    ty = 0.0
    for c in qs.candidates:
        tx += c.posterior * c.click_point_abs["x"]
        ty += c.posterior * c.click_point_abs["y"]

    dx = tx - cx
    dy = ty - cy
    d = math.hypot(dx, dy)
    if d > QEM_MOVE_STEP_PX and d > 0:
        scale = QEM_MOVE_STEP_PX / d
        dx *= scale
        dy *= scale

    return {
        "dx": dx,
        "dy": dy,
        "target_x": tx,
        "target_y": ty,
        "mode": "entangled_centroid",
        "chosen_cid": top.cid if top else None,
    }


def move_by_entangled_vector_qem(qs: QuantumMouseState,
                                 vec: Dict[str, Any],
                                 duration: float = 0.10) -> QuantumMouseState:
    curx, cury = get_cursor_pos()
    sw, sh = get_screen_size()

    nx = int(_qem_clamp(curx + vec["dx"], 2, sw - 2))
    ny = int(_qem_clamp(cury + vec["dy"], 2, sh - 2))

    move_cursor_to(nx, ny, duration=duration)
    time.sleep(0.06)

    qs.cursor = {"x": nx, "y": ny}
    qs.logs.append({
        "stage": "entangled_move",
        "tick": qs.tick,
        "vector": {
            "dx": round(float(vec["dx"]), 2),
            "dy": round(float(vec["dy"]), 2),
            "mode": vec.get("mode"),
            "target_x": round(float(vec["target_x"]), 2),
            "target_y": round(float(vec["target_y"]), 2),
        },
        "cursor_after": qs.cursor,
    })
    return qs


def refine_click_delta_qem(target: str,
                           crop_rect: Dict[str, int],
                           save_debug: bool = True) -> Dict[str, Any]:
    """局部裁图,中心画绿十字,问 VLM dx/dy (FIXED: rr*2)"""
    debug_images = []
    try:
        crop = capture_rect_pil(
            crop_rect["x"], crop_rect["y"],
            crop_rect["w"], crop_rect["h"]
        )
        draw = ImageDraw.Draw(crop)
        cx = crop.size[0] // 2
        cy = crop.size[1] // 2
        rr = max(12, min(crop.size) // 10)
        draw.ellipse((cx - rr, cy - rr, cx + rr, cy + rr), outline=(0, 255, 80), width=4)
        draw.line((cx - rr * 2, cy, cx + rr * 2, cy), fill=(0, 255, 80), width=4)
        draw.line((cx, cy - rr * 2, cx, cy + rr * 2), fill=(0, 255, 80), width=4)

        if save_debug:
            debug_images.append(save_image(crop, f"{now_ts()}_qem_delta_refine.jpg"))

        jpeg = pil_to_jpeg_bytes(crop, max_dim=1000, quality=88)
        user_text = (
            f"TARGET: {normalize_visual_target(target)}\n\n"
            f"The cursor is the GREEN crosshair at the center of the image.\n"
            f"Return small dx/dy correction to reach the ideal click point."
        )
        text = _call_claude_vision(DELTA_REFINE_PROMPT_QEM, user_text, jpeg, max_tokens=220)
        ans = _extract_delta_refine_from_text(text)

        dx = int(_qem_clamp(ans["delta"]["dx"], -80, 80))
        dy = int(_qem_clamp(ans["delta"]["dy"], -80, 80))

        return {
            "ok": True,
            "on_target": ans.get("on_target", False),
            "delta": {"dx": dx, "dy": dy},
            "confidence": float(ans.get("confidence", 0.0)),
            "reason": ans.get("reason", ""),
            "debug_images": debug_images,
        }
    except Exception as e:
        return {
            "ok": False,
            "on_target": False,
            "delta": {"dx": 0, "dy": 0},
            "confidence": 0.0,
            "reason": f"delta_refine_error: {e}",
            "debug_images": debug_images,
        }


def local_observation_refine_qem(qs: QuantumMouseState,
                                 crop_size: int = QEM_LOCAL_CROP_SIZE,
                                 save_debug: bool = True) -> QuantumMouseState:
    """v1.1: dock_icon 用更小的 delta 限制(±10/±6 px),且不超 bbox"""
    if not qs.candidates:
        return qs

    top = qs.candidates[0]
    anchor = top.click_point_abs
    sw, sh = get_screen_size()

    half = crop_size // 2
    x = int(_qem_clamp(anchor["x"] - half, 0, max(0, sw - crop_size)))
    y = int(_qem_clamp(anchor["y"] - half, 0, max(0, sh - crop_size)))
    w = int(min(crop_size, sw - x))
    h = int(min(crop_size, sh - y))

    delta_res = refine_click_delta_qem(
        target=qs.target,
        crop_rect={"x": x, "y": y, "w": w, "h": h},
        save_debug=save_debug,
    )

    qs.logs.append({
        "stage": "local_observation",
        "tick": qs.tick,
        "anchor": anchor,
        "crop_rect": {"x": x, "y": y, "w": w, "h": h},
        "delta_refine": delta_res,
    })

    if delta_res.get("ok") and delta_res.get("confidence", 0.0) >= 0.55:
        dx = int(delta_res["delta"]["dx"])
        dy = int(delta_res["delta"]["dy"])

        # v1.1: dock_icon 用更小的 delta 上限
        if top.target_type == "dock_icon":
            dx = int(_qem_clamp(dx, -10, 10))
            dy = int(_qem_clamp(dy, -6, 6))

        new_x = top.click_point_abs["x"] + dx
        new_y = top.click_point_abs["y"] + dy

        bx = top.bbox_abs["x"]
        by = top.bbox_abs["y"]
        bw = top.bbox_abs["w"]
        bh = top.bbox_abs["h"]

        # v1.1: click_point 不能跑出 bbox 太远(小 bbox 4px / 大 bbox 10px)
        pad = 4 if max(bw, bh) <= 48 else 10

        top.click_point_abs = {
            "x": int(_qem_clamp(new_x, bx - pad, bx + bw + pad)),
            "y": int(_qem_clamp(new_y, by - pad, by + bh + pad)),
        }
        top.visual_score = min(0.98, max(top.visual_score, delta_res.get("confidence", 0.0)))

    return qs


def should_collapse_qem(qs: QuantumMouseState,
                        threshold: float = QEM_COLLAPSE_THRESHOLD) -> bool:
    if not qs.candidates:
        return False
    top = qs.candidates[0]
    return top.posterior >= threshold


def collapse_to_best_candidate_qem(qs: QuantumMouseState) -> Optional[QuantumCandidate]:
    if not qs.candidates:
        return None
    top = qs.candidates[0]
    qs.collapsed = True
    qs.chosen_cid = top.cid
    qs.collapse_confidence = top.posterior
    qs.action_mode = "collapsed_click"
    qs.logs.append({
        "stage": "collapse",
        "tick": qs.tick,
        "cid": top.cid,
        "posterior": round(top.posterior, 4),
        "click_point_abs": top.click_point_abs,
        "bbox_abs": top.bbox_abs,
        "target_type": top.target_type,
    })
    return top


def penalize_after_failed_click_qem(qs: QuantumMouseState, chosen_cid: str) -> QuantumMouseState:
    for c in qs.candidates:
        if c.cid == chosen_cid:
            c.posterior *= 0.25
            c.visual_score *= 0.65
        else:
            c.posterior *= 1.08
    qs.candidates = normalize_posteriors_qem(qs.candidates)
    qs.logs.append({
        "stage": "failed_click_reweight",
        "tick": qs.tick,
        "chosen_cid": chosen_cid,
        "posteriors": [{"cid": c.cid, "posterior": round(c.posterior, 4)} for c in qs.candidates],
    })
    return qs


def init_quantum_state_qem(target: str) -> QuantumMouseState:
    x, y = get_cursor_pos()
    region_hint = choose_region_hint_qem(target)
    qs = QuantumMouseState(
        target=target,
        region_hint=region_hint,
        cursor={"x": x, "y": y},
    )
    qs.logs.append({
        "stage": "init_quantum_state",
        "target": target,
        "region_hint": region_hint,
        "cursor": qs.cursor,
    })
    return qs


def attach_candidates_to_state_qem(qs: QuantumMouseState,
                                   proposed: Dict[str, Any],
                                   save_debug: bool = True) -> QuantumMouseState:
    items = proposed.get("candidates", [])
    qcs: List[QuantumCandidate] = []

    for i, item in enumerate(items):
        grounded = ground_candidate_qem(
            target=qs.target,
            candidate_abs=item["bbox_abs"],
            base_score=float(item.get("score", 0.0)),
            source=item.get("source", ""),
            rank_hint=int(item.get("rank_hint", i + 1)),
            save_debug=save_debug,
        )
        if not grounded.get("ok") or not grounded.get("target_visible"):
            continue

        qcs.append(QuantumCandidate(
            cid=f"cand_{i+1}",
            bbox_abs=grounded["bbox_abs"],
            click_point_abs=grounded["click_point_abs"],
            target_type=grounded.get("target_type", item.get("target_type", "unknown")),
            source=grounded.get("source", item.get("source", "")),
            visual_score=float(grounded.get("visual_score", item.get("score", 0.0))),
            memory_score=float(item.get("score", 0.0)) if str(item.get("source", "")).startswith("memory_prior") else 0.0,
            rank_hint=int(item.get("rank_hint", i + 1)),
            debug={"ground": grounded},
        ))

    qs.candidates = qcs[:QEM_MAX_CANDIDATES]
    qs.logs.append({
        "stage": "attach_candidates",
        "count": len(qs.candidates),
        "items": [
            {
                "cid": c.cid,
                "source": c.source,
                "bbox_abs": c.bbox_abs,
                "click_point_abs": c.click_point_abs,
                "target_type": c.target_type,
                "visual_score": c.visual_score,
            }
            for c in qs.candidates
        ]
    })
    return qs


def navigate_quantum(target: str,
                     do_click: bool = True,
                     save_debug: bool = True,
                     use_system_open: bool = True,
                     fallback_legacy: bool = True) -> Dict[str, Any]:
    t0 = time.time()
    logs: List[Dict[str, Any]] = []

    if use_system_open and ENABLE_SYSTEM_OPEN:
        sys_res = try_system_open(target)
        logs.append({"stage": "system_open", "data": sys_res})
        if sys_res.get("ok"):
            duration = round(time.time() - t0, 2)
            log_op({
                "target": target,
                "mode": "quantum_system_open",
                "success": True,
                "duration_s": duration,
                "active_app": sys_res.get("active_app"),
            })
            return {
                "ok": True,
                "mode": "quantum_system_open",
                "target": target,
                "stage_completed": "system_open",
                "method": sys_res.get("method"),
                "active_app": sys_res.get("active_app"),
                "duration_s": duration,
                "logs": logs,
            }

    qs = init_quantum_state_qem(target)

    proposed = propose_candidates_qem(
        target=target,
        region_hint=qs.region_hint,
        max_candidates=QEM_MAX_CANDIDATES,
        save_debug=save_debug,
    )
    qs.logs.append({"stage": "propose_candidates", "data": proposed})

    qs = attach_candidates_to_state_qem(qs, proposed, save_debug=save_debug)

    if not qs.candidates:
        if fallback_legacy:
            legacy = closed_loop_navigate(
                target=target,
                do_click=do_click,
                save_debug=save_debug,
                use_system_open=False,
                use_bbox=True,
            )
            legacy["logs"] = logs + qs.logs + legacy.get("logs", [])
            return legacy

        duration = round(time.time() - t0, 2)
        return {
            "ok": False,
            "mode": "quantum",
            "target": target,
            "reason": "no_candidates",
            "duration_s": duration,
            "logs": logs + qs.logs,
        }

    for tick in range(1, QEM_MAX_TICKS + 1):
        qs.tick = tick
        curx, cury = get_cursor_pos()
        qs.cursor = {"x": curx, "y": cury}

        qs = update_candidate_posteriors_qem(qs)

        if should_collapse_qem(qs):
            break

        vec = compute_entangled_motion_vector_qem(qs)
        qs = move_by_entangled_vector_qem(qs, vec, duration=0.10)
        qs = local_observation_refine_qem(qs, crop_size=QEM_LOCAL_CROP_SIZE, save_debug=save_debug)

    chosen = collapse_to_best_candidate_qem(qs)
    if not chosen:
        if fallback_legacy:
            legacy = closed_loop_navigate(
                target=target,
                do_click=do_click,
                save_debug=save_debug,
                use_system_open=False,
                use_bbox=True,
            )
            legacy["logs"] = logs + qs.logs + legacy.get("logs", [])
            return legacy

        duration = round(time.time() - t0, 2)
        return {
            "ok": False,
            "mode": "quantum",
            "target": target,
            "reason": "collapse_failed",
            "duration_s": duration,
            "logs": logs + qs.logs,
        }

    move_cursor_to(chosen.click_point_abs["x"], chosen.click_point_abs["y"], duration=0.12)
    time.sleep(0.08)

    click_report = None
    success = True

    if do_click:
        before = capture_screen_pil()
        before_jpeg = pil_to_jpeg_bytes(before, max_dim=1024, quality=82)

        click_mouse(button="left", clicks=1, interval=0.1)
        time.sleep(DEFAULT_CLICK_SETTLE)

        after = capture_screen_pil()
        after_jpeg = pil_to_jpeg_bytes(after, max_dim=1024, quality=82)

        verify = verify_after_click(before_jpeg, after_jpeg, target=target)
        click_report = {"clicked": True, "verify": verify}
        success = bool(verify.get("success", False))
        if not success:
            qs = penalize_after_failed_click_qem(qs, chosen.cid)

    if success:
        remember_click_profile_qem(
            target=target,
            region_hint=qs.region_hint,
            target_type=chosen.target_type,
            bbox_abs=chosen.bbox_abs,
            click_point_abs=chosen.click_point_abs,
            success=True,
        )

    duration = round(time.time() - t0, 2)

    log_op({
        "target": target,
        "mode": "quantum",
        "success": success,
        "region_hint": qs.region_hint,
        "chosen_cid": chosen.cid,
        "collapse_confidence": round(qs.collapse_confidence, 4),
        "click_point": chosen.click_point_abs,
        "duration_s": duration,
    })

    return {
        "ok": success,
        "mode": "quantum",
        "target": target,
        "region_hint": qs.region_hint,
        "chosen": {
            "cid": chosen.cid,
            "bbox_abs": chosen.bbox_abs,
            "click_point_abs": chosen.click_point_abs,
            "target_type": chosen.target_type,
            "posterior": round(chosen.posterior, 4),
            "source": chosen.source,
        },
        "collapse_confidence": round(qs.collapse_confidence, 4),
        "click": click_report,
        "duration_s": duration,
        "logs": logs + qs.logs,
    }


class NavigateQuantumRequest(BaseModel):
    target: str
    do_click: bool = True
    save_debug: bool = True
    use_system_open: bool = True
    fallback_legacy: bool = True


@app.post("/navigate_quantum")
def api_navigate_quantum(req: NavigateQuantumRequest):
    try:
        return navigate_quantum(
            target=req.target,
            do_click=req.do_click,
            save_debug=req.save_debug,
            use_system_open=req.use_system_open,
            fallback_legacy=req.fallback_legacy,
        )
    except Exception as e:
        return {"ok": False, "error": str(e), "traceback": traceback.format_exc()}

