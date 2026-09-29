# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-fb0047272fabcdd9c029a7aa3841f796e1ba2caaa79401a0849c0203eade31d7"
# Source-SHA256: "7e04298d6907bc4bc1def8d56e25f1d0eb3a6e1ee6d4416230fcbe8d6fc44986"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
import os, sys, subprocess, tempfile
os.environ["KMP_DUPLICATE_LIB_OK"] = "TRUE"
sys.path.insert(0, "~/Desktop/chatterbox/src")

import torch
import torchaudio
from adu_voice_bridge import build_bridge

print("加载桥接模型...")
cb = build_bridge()

# 录5秒音频
out_wav = tempfile.mktemp(suffix=".wav")
print("🎙️ 说话...")
subprocess.run(["rec", "-r", "16000", "-c", "1", "-b", "16", out_wav, "trim", "0", "5"])

# 音频 → speech tokens
wav, sr = torchaudio.load(out_wav)
if sr != 16000:
    wav = torchaudio.functional.resample(wav, sr, 16000)

print("编码中...")
with torch.no_grad():
    s3 = cb.s3gen.tokenizer
    tokens, lengths = s3(wav)
    input_tokens = tokens[0, :lengths[0]]
    print(f"输入tokens: {input_tokens.shape}")

    # speech_emb → Qwen3 → speech_head → 生成回复tokens
    embeds = cb.t3.speech_emb(input_tokens.unsqueeze(0))
    out = cb.t3.tfmr(inputs_embeds=embeds, return_dict=True)
    logits = cb.t3.speech_head(out.last_hidden_state)
    reply_tokens = logits.argmax(dim=-1)
    print(f"回复tokens: {reply_tokens.shape}")

    # 解码 → 声音
    print("解码中...")
    ref_dict = cb.s3gen.embed_ref(wav, 16000, cb.device)
    wav_out, _ = cb.s3gen.inference(reply_tokens, ref_dict=ref_dict)
    torchaudio.save("/tmp/reply.wav", wav_out.cpu(), 24000)

print("播放回复...")
subprocess.run(["afplay", "/tmp/reply.wav"])
