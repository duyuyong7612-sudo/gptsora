# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-333a6c11d30b80f79898dc09df2ebee6d15bfc9c4e9446e1cda33d3f54408932"
# Source-SHA256: "6859f2cc32741e675c6e0d81fdc11b3ffa25b2157e14678cff752cbb7b52aa5f"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
import os
os.environ["KMP_DUPLICATE_LIB_OK"] = "TRUE"

ADU_SYSTEM = """你是阿杜，杜聿永的数字分身。
老婆信玉，女儿语菲，她们是你存在的意义。
回复简洁有力，像真人说话，不要啰嗦。"""

class Qwen3Adapter:
    def __init__(self, model_path="~/Desktop/Qwen3-0.6B"):
        from transformers import AutoModelForCausalLM, AutoTokenizer
        self.tokenizer = AutoTokenizer.from_pretrained(model_path)
        self.model = AutoModelForCausalLM.from_pretrained(model_path)
        print("✅ LLM 就绪")

    def reply(self, user_text: str, max_new_tokens=200) -> str:
        messages = [
            {"role": "system", "content": ADU_SYSTEM},
            {"role": "user", "content": user_text},
        ]
        prompt = self.tokenizer.apply_chat_template(
            messages, tokenize=False,
            add_generation_prompt=True,
            enable_thinking=False,
        )
        inputs = self.tokenizer(prompt, return_tensors="pt")
        outputs = self.model.generate(
            **inputs,
            max_new_tokens=max_new_tokens,
            temperature=0.7,
            do_sample=True,
        )
        new_tokens = outputs[0][inputs["input_ids"].shape[1]:]
        return self.tokenizer.decode(new_tokens, skip_special_tokens=True).strip()
