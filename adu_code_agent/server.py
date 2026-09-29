# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-189ac7d72f8a48650aa9cdca4774cd0aca615643c084c0f4dc053afe665430a5"
# Source-SHA256: "34b5c72a827c06376021e8a6d3a31c162605623474e6bd8029f4d00576146154"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""Standalone FastAPI app for adu_code_agent.

Use this to run the code agent on its own port (default 4380) WITHOUT
touching the live ChatAGI 8000 backend:

    cd ~/Desktop/backend
    python -m adu_code_agent.server                # 127.0.0.1:4380
    python -m adu_code_agent.server --port 4381
"""
from __future__ import annotations

import argparse
import os
import sys

try:
    from fastapi import FastAPI
    import uvicorn
except Exception as e:  # pragma: no cover
    print(f"Need fastapi + uvicorn installed: {e}", file=sys.stderr)
    sys.exit(1)

from .routes import router, FASTAPI_OK
from . import config


def make_app() -> "FastAPI":
    if not FASTAPI_OK or router is None:
        raise RuntimeError("FastAPI router is not available")
    app = FastAPI(title="adu_code_agent", version="0.1.0")
    app.include_router(router, prefix="/api")

    @app.get("/health")
    def health():
        return {
            "ok": True,
            "service": "adu_code_agent",
            "allow_paths": [str(p) for p in config.ALLOW_PATHS],
        }
    return app


app = make_app()


def main() -> None:
    p = argparse.ArgumentParser(prog="adu_code_agent.server")
    p.add_argument("--host", default=os.getenv("ADU_CODE_AGENT_HOST", "127.0.0.1"))
    p.add_argument("--port", type=int, default=4380)
    args = p.parse_args()
    uvicorn.run(app, host=args.host, port=args.port, log_level="info")


if __name__ == "__main__":
    main()
