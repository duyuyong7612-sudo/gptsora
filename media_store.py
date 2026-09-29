# media_store.py
# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-d7ea8299e49ffbf88cf962669bc2a84a9c08e7c63113e000a7c185f77f147bfe"
# Source-SHA256: "7a96f19037f28061ff6e233182487aab1f8e0b8745ffea9dc596488054621a16"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
import os, time, uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Optional, Dict

MEDIA_DIR = Path(os.getenv("MEDIA_DIR", "./_media")).resolve()
MEDIA_DIR.mkdir(parents=True, exist_ok=True)

MEDIA_TTL_S = int(os.getenv("MEDIA_TTL_S", "7200"))

@dataclass
class MediaMeta:
    id: str
    path: Path
    mime: str
    created_at: float

class MediaStore:
    def __init__(self):
        self._db: Dict[str, MediaMeta] = {}

    def put_bytes(self, data: bytes, mime: str, ext: str) -> MediaMeta:
        mid = f"media_{uuid.uuid4().hex[:18]}"
        p = MEDIA_DIR / f"{mid}.{ext}"
        p.write_bytes(data)
        meta = MediaMeta(id=mid, path=p, mime=mime, created_at=time.time())
        self._db[mid] = meta
        return meta

    def get(self, mid: str) -> Optional[MediaMeta]:
        meta = self._db.get(mid)
        if not meta:
            return None
        if time.time() - meta.created_at > MEDIA_TTL_S:
            try:
                meta.path.unlink(missing_ok=True)
            except Exception:
                pass
            self._db.pop(mid, None)
            return None
        return meta

store = MediaStore()
