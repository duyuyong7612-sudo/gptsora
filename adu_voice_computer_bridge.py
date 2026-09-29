# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-2a04c1141ed5f96848d66d9c35311962b3674444a93e084f4aacd89a93b3f6d5"
# Source-SHA256: "0a67e5f1f22e8a3775f08322e8451878bb48eb0e8b240e1e0fb5cdbde7282402"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
adu_voice_computer_bridge.py
============================
本地唯一电脑代理链：

网页 ChatAGI-阿杜 / 手机 APP
    ↓
电脑总代理（本文件）
    ↓
本地执行器（local_computer_agent）
    ↓
结果回网页 / APP

说明：
- 不再使用 OpenClaw 运行时
- 不再并行 OpenClaw + 协同助手
- 后续可在本文件里加“动作后截图验证”
"""

from __future__ import annotations

import asyncio
import logging
import os
import time
from typing import Dict, Optional

import httpx
from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

from local_computer_agent.executor import LocalComputerAgent
from local_computer_agent.registry import get_registry

logger = logging.getLogger('voice_computer')
DEEPSEEK_KEY = os.getenv('DEEPSEEK_API_KEY', '')

PLANNER_SYSTEM = """你是电脑总代理的轻量规划器。
任务：从用户的话里抽出一个最核心的动作。
只输出 JSON：
{
  "goal": "open_app | open_path | read_file",
  "target": "真正要打开的 app 名、目录名或文件路径",
  "reason": "简短原因"
}
要求：
- 如果用户说的是“打开 backend目录 / 打开 GPTsora 工程”，优先输出 open_path
- 如果用户说的是“打开微信 / 打开 Xcode”，输出 open_app
- 如果用户说的是“读取某个文件”，输出 read_file
- 不要输出 markdown
"""


class LocalPlanner:
    async def plan(self, instruction: str) -> Dict:
        quick = self.quick_plan(instruction)
        if quick:
            return quick
        if not DEEPSEEK_KEY:
            return {'goal': 'open_path', 'target': instruction, 'reason': 'no_model_fallback'}
        try:
            async with httpx.AsyncClient(timeout=10) as client:
                resp = await client.post(
                    'https://api.deepseek.com/v1/chat/completions',
                    headers={'Authorization': f'Bearer {DEEPSEEK_KEY}'},
                    json={
                        'model': 'deepseek-chat',
                        'messages': [
                            {'role': 'system', 'content': PLANNER_SYSTEM},
                            {'role': 'user', 'content': instruction},
                        ],
                        'temperature': 0.0,
                        'max_tokens': 120,
                    },
                )
            raw = resp.json()['choices'][0]['message']['content'].strip()
            raw = raw.replace('```json', '').replace('```', '').strip()
            import json
            data = json.loads(raw)
            if isinstance(data, dict) and data.get('target'):
                return data
        except Exception as e:
            logger.warning('[Planner] model parse failed: %s', e)
        return {'goal': 'open_path', 'target': instruction, 'reason': 'planner_fallback'}

    def quick_plan(self, instruction: str) -> Optional[Dict]:
        i = (instruction or '').strip()
        il = i.lower()
        reg = get_registry()
        # path/project/workspace hints
        if any(k in i or k in il for k in ['目录', '文件夹', '工程', '项目', 'workspace', 'backend', 'frontend', 'gptsora']):
            target = i.replace('打开', '').replace('启动', '').replace('进入', '').strip()
            return {'goal': 'open_path', 'target': reg.normalize_target(target), 'reason': 'quick_path'}
        # file read
        if any(k in i or k in il for k in ['读取', '查看']) and any(ext in il for ext in ['.py', '.swift', '.js', '.ts', '.json', '.md']):
            return {'goal': 'read_file', 'target': i, 'reason': 'quick_read'}
        # app open
        if any(k in i or k in il for k in ['微信', 'wechat', 'xcode', 'finder', 'terminal', 'safari', '浏览器']):
            target = i.replace('打开', '').replace('启动', '').strip()
            return {'goal': 'open_app', 'target': reg.normalize_target(target), 'reason': 'quick_app'}
        return None


class VoiceComputerBridge:
    def __init__(self):
        self.planner = LocalPlanner()
        self.agent = LocalComputerAgent()

    async def handle(self, voice_instruction: str) -> Dict:
        logger.info('[VoiceBridge] instruction=%s', voice_instruction)
        t0 = time.time()
        plan = await self.planner.plan(voice_instruction)
        goal = str(plan.get('goal') or 'open_path')
        target = str(plan.get('target') or voice_instruction)

        if goal == 'open_app':
            exec_goal = f'打开应用 {target}'
        elif goal == 'read_file':
            exec_goal = f'读取文件 {target}'
        else:
            exec_goal = f'打开目录 {target}'

        result = await self.agent.execute(exec_goal, target)
        success = bool(result.get('ok'))
        elapsed = round(time.time() - t0, 1)

        summary_lines = [
            f'📋 {voice_instruction}',
            f'🧠 规划: {goal} → {target}',
            f'⚙️ 来源: {result.get("source", "local")}',
        ]
        if success:
            summary_lines.append(f'✅ 执行成功: {result.get("stage", "done")}')
        else:
            summary_lines.append(f'❌ 执行失败: {result.get("error", "unknown_error")}')
        summary_lines.append(f'⏱️ {elapsed}s')

        return {
            'success': success,
            'instruction': voice_instruction,
            'plan': plan,
            'result': result,
            'summary': '\n'.join(summary_lines),
            'elapsed': elapsed,
            'source': 'local',
        }


router = APIRouter(prefix='/voice', tags=['voice-computer'])
_bridge = VoiceComputerBridge()
voice_bridge = _bridge


@router.post('/computer')
async def voice_computer(request: Request):
    body = await request.json()
    instruction = body.get('instruction', '')
    if not instruction:
        return JSONResponse({'ok': False, 'error': 'missing instruction'}, status_code=400)
    result = await _bridge.handle(instruction)
    return {'ok': True, **result}