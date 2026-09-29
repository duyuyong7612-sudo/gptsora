# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-b6be612e047d991214036ad1bd073a102be744998249878f0bf73c11d7c429f1"
# Source-SHA256: "567f206a86f2f6340327337723bbbdf86e9abd9aecab2c7d1ce2c8106370b6f0"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
import httpx, os

VOICE_ID = "S3tR01w5Puw28vWc105Z"  # 你的克隆声音
API_KEY  = os.getenv("ELEVENLABS_API_KEY", "")

def tts_to_file(text: str, out_path: str):
    r = httpx.post(
        f"https://api.elevenlabs.io/v1/text-to-speech/{VOICE_ID}",
        headers={"xi-api-key": API_KEY},
        json={"text": text, "model_id": "eleven_multilingual_v2"},
        timeout=30.0
    )
    with open(out_path, "wb") as f:
        f.write(r.content)
