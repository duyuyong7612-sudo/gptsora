# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-7c5eaa0b79bc1ab27f2c7984d521db192a47aa9dbeeabbefa714fcf936906294"
# Source-SHA256: "9117b714f93dcd7ce50211d45e1eab9b33254aa250ead7553c991841c86ed60d"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""FastAPI router for adu_code_agent.

To wire into the running ChatAGI backend (`~/Desktop/backend/server_session.py`):

    from adu_code_agent.routes import router as code_agent_router
    app.include_router(code_agent_router, prefix="/api")

If FastAPI is not installed, `router` will be None and FASTAPI_OK is False.
"""
from __future__ import annotations

from typing import Any, Dict, List, Optional

try:
    from fastapi import APIRouter
    from pydantic import BaseModel
    FASTAPI_OK = True
except Exception:  # pragma: no cover
    FASTAPI_OK = False

from . import fs_tools, shell_tools, loop, config


router = None


if FASTAPI_OK:
    router = APIRouter(prefix="/code-agent", tags=["code-agent"])

    @router.get("/info")
    def info():
        return {
            "ok": True,
            "service": "adu_code_agent",
            "allow_paths": [str(p) for p in config.ALLOW_PATHS],
            "read_also_ok": [str(p) for p in config.READ_ALSO_OK],
            "default_excludes": config.DEFAULT_EXCLUDES,
        }

    class ListReq(BaseModel):
        root_dir: str
        include: Optional[List[str]] = None
        exclude: Optional[List[str]] = None
        max_depth: int = 8

    @router.post("/list_files")
    def list_files(req: ListReq):
        return fs_tools.list_files(req.root_dir, req.include, req.exclude, req.max_depth)

    class ReadReq(BaseModel):
        path: str
        start: int = 1
        end: Optional[int] = None
        max_lines: int = 400

    @router.post("/read_file")
    def read_file(req: ReadReq):
        return fs_tools.read_file(req.path, req.start, req.end, req.max_lines)

    class SearchReq(BaseModel):
        root_dir: str
        query: str
        include: Optional[List[str]] = None
        exclude: Optional[List[str]] = None
        case_sensitive: bool = False
        max_results: int = 500
        context: int = 0
        explicitly_allow_secrets: bool = False

    @router.post("/search_text")
    def search_text(req: SearchReq):
        return fs_tools.search_text(
            req.root_dir, req.query, req.include, req.exclude,
            req.case_sensitive, req.max_results, req.context,
            req.explicitly_allow_secrets,
        )

    class WriteReq(BaseModel):
        path: str
        content: str
        allow_write: bool = False

    @router.post("/write_file")
    def write_file(req: WriteReq):
        return fs_tools.write_file(req.path, req.content, req.allow_write)

    class PatchReq(BaseModel):
        path: str
        search: Optional[str] = None
        replace: Optional[str] = None
        patch: Optional[str] = None
        allow_write: bool = False

    @router.post("/patch_file")
    def patch_file(req: PatchReq):
        return fs_tools.patch_file(
            req.path, search=req.search, replace=req.replace,
            patch=req.patch, allow_write=req.allow_write,
        )

    class RunReq(BaseModel):
        cmd: str
        cwd: Optional[str] = None
        timeout: float = 60.0
        env: Optional[Dict[str, str]] = None

    @router.post("/run_command")
    def run_command(req: RunReq):
        return shell_tools.run_command(
            req.cmd, cwd=req.cwd, timeout_seconds=req.timeout, env_extra=req.env,
        )

    class PortReq(BaseModel):
        port: int

    @router.post("/check_port")
    def check_port(req: PortReq):
        return shell_tools.check_port(req.port)

    class KillReq(BaseModel):
        pid: Optional[int] = None
        port: Optional[int] = None
        allow_kill: bool = False
        signal: str = "TERM"

    @router.post("/kill_process")
    def kill_process(req: KillReq):
        return shell_tools.kill_process(
            pid=req.pid, port=req.port,
            allow_kill=req.allow_kill, signal_name=req.signal,
        )

    class LoopReq(BaseModel):
        goal: str
        actions: List[Dict[str, Any]]
        allow_write: bool = False
        allow_kill: bool = False
        max_iterations: int = 5

    @router.post("/loop")
    def loop_run(req: LoopReq):
        L = loop.AgentLoop(
            req.goal,
            allow_write=req.allow_write,
            allow_kill=req.allow_kill,
            max_iterations=req.max_iterations,
        )
        return L.run_script(req.actions)
