# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-0a84911b2a3342daf63be5b197809697471291f9a6d4a323ee4e0d133825553c"
# Source-SHA256: "45673797de5ac4438e6dfbde65b113d31adf68f5222cf08faa8efd0d4245c355"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
adu_voice_clone.py — 用户声音克隆模块
用 httpx 直接调用 ElevenLabs，绕过 SDK 的 base_url 问题
"""

import os
import sqlite3
import logging
import httpx
import subprocess
from pathlib import Path
from datetime import datetime, timezone

from fastapi import APIRouter, UploadFile, File, Form, HTTPException
from fastapi.responses import StreamingResponse

log = logging.getLogger("adu_voice")

ELEVENLABS_API_KEY = os.getenv("ELEVENLABS_API_KEY", "")
DB_PATH            = os.getenv("TASK_DB_PATH", "./adu_tasks.db")
UPLOAD_DIR         = Path(os.getenv("VOICE_UPLOAD_DIR", "./voice_samples"))
UPLOAD_DIR.mkdir(exist_ok=True)

DEFAULT_VOICE_ID = os.getenv("DEFAULT_VOICE_ID", "EXAVITQu4vr4xnSDxMaL")
DEFAULT_MODEL    = "eleven_multilingual_v2"
ELEVENLABS_BASE  = "https://api.elevenlabs.io"

router = APIRouter(prefix="", tags=["voice-clone"])


def init_voice_db():
    conn = sqlite3.connect(DB_PATH)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS user_voices (
            user_id      TEXT PRIMARY KEY,
            voice_id     TEXT,
            voice_name   TEXT,
            status       TEXT DEFAULT 'none',
            sample_path  TEXT,
            created_at   TEXT,
            updated_at   TEXT
        )
    """)
    conn.commit()
    conn.close()

init_voice_db()


def get_user_voice_id(user_id: str) -> str:
    conn = sqlite3.connect(DB_PATH)
    cur = conn.execute(
        "SELECT voice_id, status FROM user_voices WHERE user_id = ?", (user_id,)
    )
    row = cur.fetchone()
    conn.close()
    if row and row[1] == "ready" and row[0]:
        return row[0]
    return DEFAULT_VOICE_ID


def save_voice_record(user_id, voice_id, voice_name, status, sample_path=""):
    conn = sqlite3.connect(DB_PATH)
    now = datetime.now(timezone.utc).isoformat()
    conn.execute("""
        INSERT OR REPLACE INTO user_voices
        (user_id, voice_id, voice_name, status, sample_path, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
    """, (user_id, voice_id, voice_name, status, sample_path, now, now))
    conn.commit()
    conn.close()


def convert_to_mp3(input_path: Path) -> Path:
    output_path = input_path.with_suffix(".mp3")
    try:
        subprocess.run([
            "ffmpeg", "-y", "-i", str(input_path),
            "-acodec", "libmp3lame", "-ar", "44100", str(output_path)
        ], capture_output=True, timeout=30)
        if output_path.exists() and output_path.stat().st_size > 1000:
            return output_path
    except Exception as e:
        log.warning(f"[VoiceClone] ffmpeg失败: {e}")
    return input_path


async def elevenlabs_clone_voice(audio_path: Path, name: str) -> str:
    if not ELEVENLABS_API_KEY:
        raise HTTPException(500, "ELEVENLABS_API_KEY 未配置")
    mp3_path = convert_to_mp3(audio_path)
    with open(mp3_path, "rb") as f:
        audio_data = f.read()
    async with httpx.AsyncClient(timeout=60.0) as client:
        r = await client.post(
            f"{ELEVENLABS_BASE}/v1/voices/add",
            headers={"xi-api-key": ELEVENLABS_API_KEY},
            data={"name": name},
            files={"files": ("voice.mp3", audio_data, "audio/mpeg")},
        )
    if r.status_code == 200:
        return r.json()["voice_id"]
    raise HTTPException(500, f"ElevenLabs克隆失败: {r.text[:200]}")


async def elevenlabs_tts(text: str, voice_id: str) -> bytes:
    if not ELEVENLABS_API_KEY:
        raise HTTPException(500, "ELEVENLABS_API_KEY 未配置")
    async with httpx.AsyncClient(timeout=60.0) as client:
        r = await client.post(
            f"{ELEVENLABS_BASE}/v1/text-to-speech/{voice_id}",
            headers={"xi-api-key": ELEVENLABS_API_KEY, "Content-Type": "application/json"},
            json={"text": text, "model_id": DEFAULT_MODEL, "output_format": "mp3_44100_128"},
        )
    if r.status_code == 200:
        return r.content
    raise HTTPException(500, f"TTS失败: {r.text[:200]}")


@router.post("/voice/clone")
async def clone_voice(
    user_id: str = Form(...),
    voice_name: str = Form("我的声音"),
    audio: UploadFile = File(...)
):
    ext = (audio.filename or "audio.m4a").split(".")[-1]
    sample_path = UPLOAD_DIR / f"{user_id}_{datetime.now().strftime('%Y%m%d_%H%M%S')}.{ext}"
    content = await audio.read()
    with open(sample_path, "wb") as f:
        f.write(content)
    log.info(f"[VoiceClone] 收到录音: {user_id} {len(content)/1024:.1f}KB")
    save_voice_record(user_id, "", voice_name, "processing", str(sample_path))
    try:
        voice_id = await elevenlabs_clone_voice(sample_path, voice_name)
        save_voice_record(user_id, voice_id, voice_name, "ready", str(sample_path))
        log.info(f"[VoiceClone] ✅ {user_id} → {voice_id}")
        return {"status": "ready", "voice_id": voice_id, "message": "声音克隆成功，阿杜会用你的声音说话了"}
    except Exception as e:
        save_voice_record(user_id, "", voice_name, "failed", str(sample_path))
        raise HTTPException(500, str(e))


@router.get("/voice/status/{user_id}")
async def get_voice_status(user_id: str):
    conn = sqlite3.connect(DB_PATH)
    cur = conn.execute(
        "SELECT voice_id, voice_name, status, created_at FROM user_voices WHERE user_id = ?",
        (user_id,)
    )
    row = cur.fetchone()
    conn.close()
    if not row:
        return {"status": "none"}
    return {"status": row[2], "voice_id": row[0], "voice_name": row[1], "created_at": row[3]}


@router.post("/voice/tts")
async def text_to_speech(body: dict):
    user_id = body.get("user_id", "adu_system")
    text = body.get("text", "")
    if not text:
        raise HTTPException(400, "text不能为空")
    voice_id = get_user_voice_id(user_id)
    audio_bytes = await elevenlabs_tts(text, voice_id)
    return StreamingResponse(iter([audio_bytes]), media_type="audio/mpeg",
                             headers={"X-Voice-Id": voice_id})


@router.get("/voice/test/{user_id}")
async def test_voice(user_id: str):
    voice_id = get_user_voice_id(user_id)
    text = "你好，我是阿杜。我是你的数字分身，我会用你的声音，替你工作，永远陪在你身边。"
    audio_bytes = await elevenlabs_tts(text, voice_id)
    return StreamingResponse(iter([audio_bytes]), media_type="audio/mpeg")


@router.delete("/voice/{user_id}")
async def delete_voice(user_id: str):
    conn = sqlite3.connect(DB_PATH)
    conn.execute("DELETE FROM user_voices WHERE user_id = ?", (user_id,))
    conn.commit()
    conn.close()
    return {"status": "deleted"}

