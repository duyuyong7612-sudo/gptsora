# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-11482a27b8417c5566f7afcc2b06225a62f1ccad097ab8e39d1665850c44e61d"
# Source-SHA256: "77201028640a52b87188fe2b9997faa21881725702daabd19575059dc2f5cd9d"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
session.py — 会话状态管理
每个用户一个 Session，管理状态机
"""

import asyncio
import uuid
from dataclasses import dataclass, field
from typing import Optional
from protocol import SessionMode


@dataclass
class Session:
    id: str = field(default_factory=lambda: uuid.uuid4().hex)
    mode: SessionMode = SessionMode.IDLE
    user_id: str = "adu_system"

    # 音频缓冲
    audio_buffer: bytes = b""

    # 任务句柄
    llm_task: Optional[asyncio.Task] = None
    tts_task: Optional[asyncio.Task] = None

    # 控制
    interrupted: bool = False
    playback_seq: int = 0

    # WebSocket
    websocket: Optional[object] = None

    def reset(self):
        self.audio_buffer = b""
        self.interrupted = False

    def cancel_tasks(self):
        if self.llm_task and not self.llm_task.done():
            self.llm_task.cancel()
        if self.tts_task and not self.tts_task.done():
            self.tts_task.cancel()
        self.llm_task = None
        self.tts_task = None


class SessionManager:
    def __init__(self):
        self._sessions: dict[str, Session] = {}

    def create(self, user_id: str = "adu_system") -> Session:
        s = Session(user_id=user_id)
        self._sessions[s.id] = s
        return s

    def get(self, session_id: str) -> Optional[Session]:
        return self._sessions.get(session_id)

    def remove(self, session_id: str):
        self._sessions.pop(session_id, None)
