# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-31ede2c4167e429bf24c2b3baac80e11a13d219e32ac7eb9bca489adc4271c69"
# Source-SHA256: "309208fdec648840db945c671d2914c5ae0bfe340104b06d2056409dc0e3a231"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
import os, sys, json, time
import torch, torchaudio
sys.path.insert(0, "~/Desktop/chatterbox/src")
os.environ["KMP_DUPLICATE_LIB_OK"] = "TRUE"

import httpx
from dotenv import load_dotenv
load_dotenv("~/Desktop/backend/.env")
DEEPSEEK_KEY = os.getenv("DEEPSEEK_API_KEY", "")

ADU_SYSTEM = "你是阿杜，一个AGI智能体。回复简洁有力，像真人说话，不超过20字。"
TOPICS = ["你好","现在几点","今天天气怎么样","你是谁","你能做什么","我很累","帮我想个计划","最近有什么AI新闻","你在做什么","给我讲个笑话","今天有什么任务","我想休息一下","帮我提醒一件事","你有什么能力","我们聊聊天","今天心情不好","帮我分析一下","最近怎么样","你觉得我该怎么做","给我一些建议"]

def gen_reply(user_text):
    r = httpx.post("https://api.deepseek.com/chat/completions",
        headers={"Authorization": f"Bearer {DEEPSEEK_KEY}"},
        json={"model":"deepseek-chat","messages":[{"role":"system","content":ADU_SYSTEM},{"role":"user","content":user_text}],"max_tokens":40},
        timeout=30.0)
    return r.json()["choices"][0]["message"]["content"].strip()

def text_to_tokens(text, tts, s3):
    with torch.no_grad():
        wav = tts.generate(text)  # [1, T] @ 24kHz
        wav_16k = torchaudio.functional.resample(wav, 24000, 16000)
        tokens, lengths = s3(wav_16k)
    return tokens[0, :lengths[0]].tolist()

def main():
    from chatterbox.tts_turbo import ChatterboxTurboTTS
    print("加载模型...")
    cb = ChatterboxTurboTTS.from_pretrained("cpu")
    s3 = cb.s3gen.tokenizer

    data = json.load(open("train_data.json")) if os.path.exists("train_data.json") else []
    print(f"已有{len(data)}条，继续...")
    topics = TOPICS * 50
    for i, user_text in enumerate(topics[len(data):], start=len(data)):
        print(f"[{i+1}/1000] {user_text}", end=" ... ")
        try:
            adu_text = gen_reply(user_text)
            print(f"阿杜：{adu_text}")
            user_tokens = text_to_tokens(user_text, cb, s3)
            adu_tokens = text_to_tokens(adu_text, cb, s3)
            data.append({"user_text":user_text,"adu_text":adu_text,"user_tokens":user_tokens,"adu_tokens":adu_tokens})
            if (i+1) % 20 == 0:
                json.dump(data, open("train_data.json","w"), ensure_ascii=False)
                print(f"  ✅ 已保存{len(data)}条")
            time.sleep(0.2)
        except Exception as e:
            print(f"  ❌ {e}")
    json.dump(data, open("train_data.json","w"), ensure_ascii=False)
    print(f"完成！共{len(data)}条")

if __name__ == "__main__":
    main()
