# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-24815ffd672dc8bed2d7d83af4eaa2ba7f82e879812f8026cc507da425effbec"
# Source-SHA256: "346db0c1feaaf042987208e919dea86784322d076678ab278542f57c74175c35"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
import os
import sys
import tempfile
import subprocess

os.environ["KMP_DUPLICATE_LIB_OK"] = "TRUE"
sys.path.insert(0, "~/Desktop/chatterbox/src")

def load_models():
    print("正在加载模型...")
    from adapters.whisper_adapter import WhisperAdapter
    asr = WhisperAdapter()
    from adapters.qwen3_adapter import Qwen3Adapter
    llm = Qwen3Adapter()
    print("✅ 三段全部加载完成")
    return asr, llm

def run_pipeline(audio_path, asr, llm):
    print(f"\n{'='*40}")
    print("🎤 识别中...")
    user_text = asr.transcribe(audio_path)
    print(f"用户说：{user_text}")
    if not user_text:
        print("没有识别到内容")
        return None
    print("🧠 思考中...")
    reply_text = llm.reply(user_text)
    print(f"阿杜说：{reply_text}")
    print("🔊 合成中...")
    from adapters.elevenlabs_adapter import tts_to_file
    out_path = tempfile.mktemp(suffix=".mp3")
    tts_to_file(reply_text, out_path)
    return out_path

def play_audio(path):
    subprocess.run(["ffplay", "-nodisp", "-autoexit", path])

def record_audio(duration=5):
    out = tempfile.mktemp(suffix=".wav")
    print(f"🎙️ 开始录音 {duration} 秒...")
    subprocess.run(["rec", "-r", "16000", "-c", "1", "-b", "16",
                    out, "trim", "0", str(duration)])
    return out

def main():
    asr, llm = load_models()
    print("\n阿杜实时语音系统已就绪")
    while True:
        cmd = input("\n按 Enter 开始说话，q 退出：").strip()
        if cmd.lower() == "q":
            break
        audio = record_audio(5)
        out = run_pipeline(audio, asr, llm)
        if out:
            play_audio(out)

if __name__ == "__main__":
    main()
