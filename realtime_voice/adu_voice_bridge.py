# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-72c52e6ae307c14d114e9b415c27e213b3dfd2b0ebe87a40809cef3f7efcf3df"
# Source-SHA256: "48013234b91b68c7ec82c8eda07a86b153264099548bf5517bb246c06ce981f3"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
import os, sys
os.environ["KMP_DUPLICATE_LIB_OK"] = "TRUE"
sys.path.insert(0, "~/Desktop/chatterbox/src")

import torch
from transformers import AutoModelForCausalLM

def build_bridge():
    from chatterbox.tts_turbo import ChatterboxTurboTTS

    print("加载 Chatterbox...")
    cb = ChatterboxTurboTTS.from_pretrained("cpu")

    print("加载 Qwen3...")
    qwen = AutoModelForCausalLM.from_pretrained(
        "~/Desktop/Qwen3-0.6B",
        torch_dtype=torch.float32  # ← 统一float32
    )

    # 替换tfmr
    cb.t3.tfmr = qwen.model
    print("✅ 桥接完成")
    return cb

def test_bridge():
    cb = build_bridge()

    test_tokens = torch.randint(0, 6563, (1, 10))
    embeds = cb.t3.speech_emb(test_tokens)
    print(f"Embedding: {embeds.shape} {embeds.dtype}")

    out = cb.t3.tfmr(inputs_embeds=embeds, return_dict=True)
    hidden = out.last_hidden_state
    print(f"Qwen3输出: {hidden.shape}")

    logits = cb.t3.speech_head(hidden)
    next_token = logits[:, -1, :].argmax(dim=-1)
    print(f"预测token: {next_token.item()}")
    print("✅ 桥接测试通过！")

if __name__ == "__main__":
    test_bridge()
