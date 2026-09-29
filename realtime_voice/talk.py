# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-92c14b273a9a26c2dad8e4673f47017ecf8af9f016925b5a3a929e5eabfd89fc"
# Source-SHA256: "c87dd9c4eaf375895310a51b3fa531b3406617abe7835f70b693876665b2172f"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
import os, sys, subprocess, tempfile, time
import torch
import torch.nn.functional as F
os.environ["KMP_DUPLICATE_LIB_OK"] = "TRUE"
sys.path.insert(0, "~/Desktop/chatterbox/src")

import torchaudio
from adu_voice_bridge import build_bridge

print("加载模型...")
cb = build_bridge()
print("\n✅ 开始对话")

# 截取3秒参考音频
REF_AUDIO = "~/Desktop/backend/voice_samples/adu_voice.mp3"

def load_ref(path, max_sec=3):
    wav, sr = torchaudio.load(path)
    if sr != 16000:
        wav = torchaudio.functional.resample(wav, sr, 16000)
    # 只取前3秒
    max_samples = max_sec * 16000
    wav = wav[:, :max_samples]
    return wav

ref_wav = load_ref(REF_AUDIO) if os.path.exists(REF_AUDIO) else None

round_num = 0
while True:
    cmd = input(f"\n[第{round_num+1}轮] 按Enter说话，q退出：").strip()
    if cmd.lower() == "q":
        break

    round_num += 1
    out_wav = tempfile.mktemp(suffix=".wav")
    subprocess.run(["rec", "-r", "16000", "-c", "1", "-b", "16",
                    out_wav, "trim", "0", "5"], capture_output=True)

    t0 = time.time()
    wav, sr = torchaudio.load(out_wav)
    if sr != 16000:
        wav = torchaudio.functional.resample(wav, sr, 16000)

    with torch.no_grad():
        tokens, lengths = cb.s3gen.tokenizer(wav)
        input_tokens = tokens[0, :lengths[0]]

        # 限制输入长度
        input_tokens = input_tokens[:50]

        embeds = cb.t3.speech_emb(input_tokens.unsqueeze(0))
        out = cb.t3.tfmr(inputs_embeds=embeds, return_dict=True)
        logits = cb.t3.speech_head(out.last_hidden_state)

        # 只取最后一个位置，生成固定20个token
        last_logit = logits[0, -1:, :]
        temperature = 0.8
        reply_tokens = []
        hidden = out.last_hidden_state

        for _ in range(20):  # 只生成20个token
            probs = F.softmax(hidden[0, -1, :] @ cb.t3.speech_head.weight.T / temperature, dim=-1)
            next_tok = torch.multinomial(probs, 1)
            reply_tokens.append(next_tok.item())
            next_emb = cb.t3.speech_emb(next_tok.unsqueeze(0))
            out2 = cb.t3.tfmr(inputs_embeds=next_emb, return_dict=True)
            hidden = out2.last_hidden_state

        reply_tokens = torch.tensor(reply_tokens).unsqueeze(0)

        # 用截断的参考音频
        r = ref_wav if ref_wav is not None else wav[:, :16000*3]
        ref_dict = cb.s3gen.embed_ref(r, 16000, cb.device)
        wav_out, _ = cb.s3gen.inference(reply_tokens, ref_dict=ref_dict)
        wav_out = wav_out / (wav_out.abs().max() + 1e-8)
        torchaudio.save("/tmp/reply.wav", wav_out.cpu(), 24000)

    print(f"⏱️ 延迟: {(time.time()-t0)*1000:.0f}ms")
    subprocess.run(["afplay", "/tmp/reply.wav"])
