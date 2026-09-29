# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-c5b7becf0a3d490375561795a582fcb511bef491728593d7457c52f5cca6fb2d"
# Source-SHA256: "28103b28820a4c96828cafcf89e652537934a9a530890e7eea108b76a5d30cb0"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
import os
os.environ["KMP_DUPLICATE_LIB_OK"] = "TRUE"

class WhisperAdapter:
    def __init__(self):
        from faster_whisper import WhisperModel
        self.model = WhisperModel("base", device="cpu")
        print("✅ ASR 就绪")

    def transcribe(self, audio_path: str) -> str:
        segments, _ = self.model.transcribe(audio_path, language="zh")
        return "".join(s.text for s in segments).strip()

    def transcribe_bytes(self, pcm_bytes: bytes, sample_rate=16000) -> str:
        import tempfile, wave, os
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
            tmp = f.name
        with wave.open(tmp, "wb") as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(sample_rate)
            wf.writeframes(pcm_bytes)
        text = self.transcribe(tmp)
        os.unlink(tmp)
        return text
