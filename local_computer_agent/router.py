# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-46b26870d7a97329852e9166d7c922c24805e0e6a3380d84047c12e94030ddb3"
# Source-SHA256: "8b4d563a339d2f1ee6db85d6967169daeb44eaf713cf5f366050a1a5b18f26c5"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
from __future__ import annotations

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from .executor import LocalComputerAgent
from .registry import get_registry

router = APIRouter(prefix='/computer-agent', tags=['computer-agent'])
_agent = LocalComputerAgent()


class ExecuteRequest(BaseModel):
    goal: str = Field(..., min_length=1)
    target: str = Field('', min_length=0)


@router.get('/health')
async def health():
    reg = get_registry()
    return {
        'ok': True,
        'source': 'local',
        'platform': reg.data.get('system', {}).get('platform'),
        'apps_count': len(reg.data.get('apps') or {}),
        'workspace_aliases_count': len(reg.data.get('workspace_aliases') or {}),
    }


@router.post('/probe')
async def probe():
    reg = get_registry()
    data = reg.probe_and_persist()
    return {'ok': True, 'source': 'local', 'registry': data}

@router.get('/registry')
async def registry():
    reg = get_registry()
    return {'ok': True, 'source': 'local', 'registry': reg.data}


@router.post('/execute')
async def execute(body: ExecuteRequest):
    try:
        result = await _agent.execute(body.goal, body.target)
        return result
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
