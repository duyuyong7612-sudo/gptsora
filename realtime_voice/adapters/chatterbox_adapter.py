# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-8a10307005d9655a8f68b59f66222acb99531c1681c2f7bb3ea0c0f2a5a285ec"
# Source-SHA256: "f82c9c7b963527f85ac76dc9c7bd1935c99d7585f509b205d1f909d4fa1b48ef"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
import os, sys
os.environ["KMP_DUPLICATE_LIB_OK"] = "TRUE"
sys.path.insert(0, "~/Desktop/chatterbox/src")

class ChatterboxAdapter:
    def __init__(self, voice_sample_path=None):
        from chatterbox.tts_turbo import ChatterboxTurboTTS
        self.model = ChatterboxTurboTTS.from_pretrained("cpu")
        print("✅ TTS 就绪")

    def synthesize_to_file(self, text: str, out_path: str):
        import torchaudio
        wav = self.model.generate(text)
        torchaudio.save(out_path, wav, 24000)
        return out_path
