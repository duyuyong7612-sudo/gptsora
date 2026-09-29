# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-db70d9e5eeb33edda5c636dd79c238d23ea24cdb28a2867530a467ed8a3f39ec"
# Source-SHA256: "e926585e2b58ddec5d1d81ca932f7029a2818153ced62bdc3869ad6f3fc4858e"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""Polar 收款接入（2026-09-08）。

Polar 是 Merchant of Record：结账、试用、续费、退款都在 Polar 侧完成，本模块只做两件事：

1. 接收 Polar Webhook（Standard Webhooks 签名，2026-09-08 起 Polar 新端点统一用它），
   把订阅事件折算成「这个用户现在应该是什么套餐」；
2. 通过 ``set_entitlement_writer`` 注入的回调，把结果写进仓库已有的套餐存储
   （server_session.py 里接线到 billing.py 的写入出口），本模块自己不落库。

路由（挂在 app 根下，无全局前缀）：
    GET  /billing/polar/health   → JSON，只报配置状态，不含任何密钥
    POST /billing/polar/webhook  → Polar 事件入口；GET 该路径由 FastAPI 返回 405

环境变量（全部可选，缺失时对应功能自动降级；绝不硬编码）：
    POLAR_WEBHOOK_SECRET      Polar 后台该 endpoint 的 secret（``whsec_`` 开头的 Standard Webhooks 密钥，
                              也兼容旧格式的原始字符串）
    POLAR_PRODUCT_ID_PRO      对应 pro 套餐的 Polar product id，多个用逗号分隔
    POLAR_PRODUCT_ID_ULTRA    对应 ultra 套餐的 Polar product id，多个用逗号分隔
    POLAR_ACCESS_TOKEN        预留：需要主动向 Polar 拉取时使用（本模块当前不主动调用 Polar，不装 polar-sdk）
    POLAR_WEBHOOK_TOLERANCE_S 签名时间戳容差秒数，默认 300

用户身份（user_key）取值顺序：customer.external_id → metadata.user_key/user_id/client_id →
customer.email（小写）。前端发起 Polar 结账时把账号 id 放进 ``external_customer_id`` 或 metadata，
写入的套餐才会落到同一个用户上。
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import hmac
import json
import logging
import os
import threading
import time
from collections import OrderedDict
from datetime import datetime, timezone
from typing import Any, Awaitable, Callable, Dict, Optional, Tuple

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

log = logging.getLogger("polar_billing")

router = APIRouter(prefix="/billing/polar", tags=["billing-polar"])

PLAN_FREE = "free"
PLAN_PRO = "pro"
PLAN_ULTRA = "ultra"

# 写入回调：async def writer(user_key: str, plan: str, status: str, raw: dict) -> Any
EntitlementWriter = Callable[[str, str, str, Dict[str, Any]], Awaitable[Any]]
_writer: Optional[EntitlementWriter] = None


def set_entitlement_writer(writer: EntitlementWriter) -> None:
    """由 server_session.py 注入：把 (user_key, plan, status, raw) 写进已有的套餐存储。"""
    global _writer
    _writer = writer


# -----------------------------
# 配置
# -----------------------------
def _env(name: str) -> str:
    return (os.environ.get(name) or "").strip()


def _env_ids(name: str) -> set[str]:
    return {x.strip() for x in _env(name).split(",") if x.strip()}


def _tolerance_s() -> int:
    try:
        return int(_env("POLAR_WEBHOOK_TOLERANCE_S") or "300")
    except ValueError:
        return 300


def _plan_for_product(product: Dict[str, Any]) -> str:
    """Polar product → 本仓库套餐。先按环境变量里的 product id 精确匹配，再按名称启发。"""
    pid = str((product or {}).get("id") or "").strip()
    if pid and pid in _env_ids("POLAR_PRODUCT_ID_ULTRA"):
        return PLAN_ULTRA
    if pid and pid in _env_ids("POLAR_PRODUCT_ID_PRO"):
        return PLAN_PRO
    name = str((product or {}).get("name") or "").lower()
    meta = (product or {}).get("metadata") if isinstance((product or {}).get("metadata"), dict) else {}
    hinted = str(meta.get("plan") or "").lower()
    if hinted in (PLAN_PRO, PLAN_ULTRA):
        return hinted
    if "ultra" in name:
        return PLAN_ULTRA
    if "pro" in name:
        return PLAN_PRO
    return ""


# -----------------------------
# Standard Webhooks 签名校验
# -----------------------------
def _candidate_keys(secret: str) -> list[bytes]:
    """Standard Webhooks 的 secret 是 ``whsec_`` + base64(key)。同时兼容 Polar 迁移前
    直接用原始字符串做 HMAC key 的旧端点。"""
    s = secret.strip()
    keys: list[bytes] = []
    body = s[6:] if s.startswith("whsec_") else s
    try:
        keys.append(base64.b64decode(body, validate=False))
    except (binascii.Error, ValueError):
        pass
    keys.append(s.encode("utf-8"))
    if body != s:
        keys.append(body.encode("utf-8"))
    return [k for k in keys if k]


def verify_signature(payload: bytes, headers: Dict[str, str], secret: str, tolerance_s: int = 300) -> bool:
    msg_id = headers.get("webhook-id", "")
    ts = headers.get("webhook-timestamp", "")
    sig_header = headers.get("webhook-signature", "")
    if not (msg_id and ts and sig_header and secret):
        return False
    try:
        if abs(int(time.time()) - int(ts)) > tolerance_s:
            return False
    except ValueError:
        return False
    signed = f"{msg_id}.{ts}.".encode("utf-8") + payload
    provided = []
    for part in sig_header.split():
        version, _, sig = part.partition(",")
        if version == "v1" and sig:
            provided.append(sig)
    if not provided:
        return False
    for key in _candidate_keys(secret):
        expected = base64.b64encode(hmac.new(key, signed, hashlib.sha256).digest()).decode("ascii")
        if any(hmac.compare_digest(expected, p) for p in provided):
            return True
    return False


# -----------------------------
# 事件去重（同一 webhook-id 重试不重复写）
# -----------------------------
_seen_lock = threading.Lock()
_seen: "OrderedDict[str, float]" = OrderedDict()
_SEEN_MAX = 2000


def _seen_before(msg_id: str) -> bool:
    if not msg_id:
        return False
    with _seen_lock:
        if msg_id in _seen:
            return True
        _seen[msg_id] = time.time()
        while len(_seen) > _SEEN_MAX:
            _seen.popitem(last=False)
        return False


# -----------------------------
# 事件 → 套餐结论
# -----------------------------
def _parse_ts(value: Any) -> Optional[int]:
    if not value:
        return None
    try:
        return int(datetime.fromisoformat(str(value).replace("Z", "+00:00")).astimezone(timezone.utc).timestamp())
    except Exception:
        return None


def _user_key_from(data: Dict[str, Any]) -> str:
    customer = data.get("customer") if isinstance(data.get("customer"), dict) else {}
    meta = data.get("metadata") if isinstance(data.get("metadata"), dict) else {}
    cmeta = customer.get("metadata") if isinstance(customer.get("metadata"), dict) else {}
    for candidate in (
        customer.get("external_id"),
        data.get("external_customer_id"),
        meta.get("user_key"), meta.get("user_id"), meta.get("client_id"),
        cmeta.get("user_key"), cmeta.get("user_id"),
        customer.get("email"), data.get("customer_email"),
    ):
        s = str(candidate or "").strip()
        if s:
            return s.lower() if "@" in s else s
    return ""


ACTIVE_STATUSES = {"active", "trialing"}
ENDED_STATUSES = {"canceled", "revoked", "unpaid", "incomplete_expired", "ended"}


def decide(event_type: str, data: Dict[str, Any]) -> Optional[Tuple[str, str, str, Dict[str, Any]]]:
    """返回 (user_key, plan, status, raw) 或 None（该事件不影响套餐）。

    plan ∈ {free, pro, ultra}；status ∈ {active, trialing, canceling, past_due, revoked}。
    * subscription.created/active/updated/cycled/uncanceled：按订阅状态给套餐；
    * subscription.canceled：Polar 语义是「到期后取消」，套餐保留到 current_period_end；
      若 ended_at 已到或状态已终止，则立即降为 free；
    * subscription.revoked：立即降为 free；
    * subscription.past_due：不动套餐，只透传状态（写入方可选择忽略）；
    * order.paid：续费成功的兜底（订阅字段带在 order.subscription 里）；
    * checkout.*、benefit_grant.*、customer.* 等：忽略。"""
    et = str(event_type or "")
    if et.startswith("order."):
        if et != "order.paid":
            return None
        sub = data.get("subscription") if isinstance(data.get("subscription"), dict) else None
        if not sub:
            return None
        merged = dict(sub)
        merged.setdefault("customer", data.get("customer"))
        merged.setdefault("product", data.get("product"))
        merged.setdefault("metadata", data.get("metadata"))
        data = merged
    elif not et.startswith("subscription."):
        return None

    user_key = _user_key_from(data)
    if not user_key:
        log.warning("[polar] %s 无法确定用户身份（缺 external_id/metadata/email），忽略", et)
        return None

    product = data.get("product") if isinstance(data.get("product"), dict) else {}
    plan = _plan_for_product(product)
    sub_status = str(data.get("status") or "").lower()
    period_end = _parse_ts(data.get("current_period_end"))
    ended_at = _parse_ts(data.get("ended_at"))
    now = int(time.time())

    raw = {
        "source": "polar",
        "event_type": et,
        "subscription_id": data.get("id"),
        "customer_id": (data.get("customer") or {}).get("id") if isinstance(data.get("customer"), dict) else data.get("customer_id"),
        "product_id": product.get("id"),
        "product_name": product.get("name"),
        "subscription_status": sub_status,
        "current_period_end": period_end,
        "ended_at": ended_at,
        "cancel_at_period_end": bool(data.get("cancel_at_period_end")),
        "trial_end": _parse_ts(data.get("trial_end")),
        # 吊销/降级时写入方需要知道这份订阅原来给的是哪一档，才能判断该不该降
        "plan_hint": plan or "",
    }

    if et == "subscription.revoked" or sub_status in ENDED_STATUSES and (ended_at is None or ended_at <= now):
        return user_key, PLAN_FREE, "revoked", raw
    if et == "subscription.past_due" or sub_status == "past_due":
        return user_key, plan or PLAN_FREE, "past_due", raw
    if not plan:
        log.warning("[polar] %s 无法映射套餐：product=%s name=%r，忽略", et, product.get("id"), product.get("name"))
        return None
    if et == "subscription.canceled" or data.get("cancel_at_period_end"):
        return user_key, plan, "canceling", raw
    if sub_status in ACTIVE_STATUSES or et in ("subscription.active", "subscription.cycled", "subscription.uncanceled", "order.paid"):
        return user_key, plan, "trialing" if sub_status == "trialing" else "active", raw
    if sub_status in ("incomplete",):
        return None
    return user_key, plan, sub_status or "active", raw


# -----------------------------
# 路由
# -----------------------------
@router.get("/health")
async def polar_health() -> Dict[str, Any]:
    return {
        "ok": True,
        "provider": "polar",
        "webhook_path": "/billing/polar/webhook",
        "signature": "standard-webhooks",
        "secret_configured": bool(_env("POLAR_WEBHOOK_SECRET")),
        "writer_configured": _writer is not None,
        "product_map": {
            "pro": len(_env_ids("POLAR_PRODUCT_ID_PRO")),
            "ultra": len(_env_ids("POLAR_PRODUCT_ID_ULTRA")),
        },
        "ts": int(time.time()),
    }


@router.post("/webhook")
async def polar_webhook(request: Request):
    secret = _env("POLAR_WEBHOOK_SECRET")
    if not secret:
        return JSONResponse(status_code=503, content={"ok": False, "error": "POLAR_WEBHOOK_SECRET not configured"})
    payload = await request.body()
    headers = {k.lower(): v for k, v in request.headers.items()}
    if not verify_signature(payload, headers, secret, _tolerance_s()):
        return JSONResponse(status_code=401, content={"ok": False, "error": "invalid signature"})
    try:
        event = json.loads(payload.decode("utf-8"))
    except Exception:
        return JSONResponse(status_code=400, content={"ok": False, "error": "invalid json"})
    if not isinstance(event, dict):
        return JSONResponse(status_code=400, content={"ok": False, "error": "invalid event"})

    msg_id = headers.get("webhook-id", "")
    et = str(event.get("type") or "")
    data = event.get("data") if isinstance(event.get("data"), dict) else {}
    if _seen_before(msg_id):
        return {"ok": True, "type": et, "duplicate": True}

    decision = decide(et, data)
    if decision is None:
        return {"ok": True, "type": et, "applied": False, "reason": "no entitlement change"}
    user_key, plan, status, raw = decision
    if _writer is None:
        log.error("[polar] 收到 %s 但未注入 entitlement writer，事件未写入", et)
        return JSONResponse(status_code=503, content={"ok": False, "type": et, "error": "entitlement writer not configured"})
    try:
        result = await _writer(user_key, plan, status, raw)
    except Exception as e:  # noqa: BLE001
        log.exception("[polar] 写入套餐失败 user=%s plan=%s status=%s", user_key, plan, status)
        return JSONResponse(status_code=500, content={"ok": False, "type": et, "error": f"entitlement write failed: {type(e).__name__}"})
    log.info("[polar] %s → user=%s plan=%s status=%s", et, user_key, plan, status)
    return {"ok": True, "type": et, "applied": True, "user_key": user_key, "plan": plan, "status": status,
            "result": result if isinstance(result, (dict, list, str, int, float, bool)) or result is None else str(result)}
