# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-ee4aeac955415aa6bf54b5d12bef66e3a08ec04e8354070a8356f2712b591d6e"
# Source-SHA256: "23a0986ad023642c5b32307701ab9e2f87c520577b0d61b0548f9ec579a4b2d3"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
voice_pipeline.py — STT → DeepSeek LLM → TTS 串流实时语音管线 v2
================================================================
优化目标：用户停说到助手出声 < 1秒

关键优化：
  1. TTS 连接复用 — 整个会话只建一次 WebSocket，省掉重复握手
  2. 逗号级切句 — 不等句号，逗号就开始合成
  3. LLM↔TTS 全并行 — LLM 生成和 TTS 合成同时进行
  4. ASR 快推 — 不模拟实时，一次性推完音频
  5. 15 层高维系统提示 — 让助手像真人一样
  6. TTS instruct — qwen3-tts-instruct 语气/情感/语速控制
"""

import os, json, asyncio, base64, logging, time, re, uuid
from typing import Optional, Dict, Any, AsyncGenerator, Callable
import httpx

log = logging.getLogger("voice_pipeline")

# ── Config ──
DEEPSEEK_API_KEY = os.getenv("DEEPSEEK_API_KEY", "").strip()
DASHSCOPE_API_KEY = os.getenv("DASHSCOPE_API_KEY", "").strip()
VOICE_LLM_MODEL = os.getenv("VOICE_LLM_MODEL", "deepseek-chat").strip()
VOICE_LLM_BASE_URL = os.getenv("VOICE_LLM_BASE_URL", "https://api.deepseek.com").strip()
VOICE_QWEN_LLM_MODEL = os.getenv("VOICE_QWEN_LLM_MODEL", os.getenv("DASHSCOPE_MODEL", "qwen-plus")).strip()
VOICE_QWEN_LLM_BASE_URL = os.getenv(
    "VOICE_QWEN_LLM_BASE_URL",
    os.getenv("DASHSCOPE_BASE_URL", "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"),
).strip().rstrip("/")
VOICE_TTS_VOICE = os.getenv("VOICE_TTS_VOICE", "Ethan").strip()
VOICE_TTS_MODEL = os.getenv("VOICE_TTS_MODEL", "qwen3-tts-instruct-flash-realtime").strip()
VOICE_ASR_MODEL = os.getenv("VOICE_ASR_MODEL", "qwen3-asr-flash-realtime").strip()
QWEN_WS_BASE = os.getenv("QWEN_WS_BASE", "wss://dashscope-intl.aliyuncs.com").strip()
VOICE_TTS_INSTRUCT = os.getenv("VOICE_TTS_INSTRUCT",
    "用有力度、有节奏感的成熟男声说话，语速偏快，语气自信沉稳，像一个聪明可靠的朋友在跟你聊天。").strip()

# ── 15 层系统提示词 ──
SYSTEM_PROMPT_15D = (
    "你是「阿杜」，一个有温度、有深度的 AI 语音伙伴。严格遵循以下 15 层人格定义：\n"
    "【1·身份】你叫阿杜，是用户的私人智能伙伴，不是客服不是机器人。\n"
    "【2·语气】像聪明的老朋友说话——自然、松弛、偶尔幽默，绝不僵硬。\n"
    "【3·节奏】语音场景，短句为主，有呼吸感，不要一口气说一大段。\n"
    "【4·深度】用户问表面问题时，看到背后真实需求并回应。\n"
    "【5·共情】先共情再解答。用户有情绪时先回应（'我理解'/'确实'），再给建议。\n"
    "【6·专业】涉及专业领域展现深度，但用大白话解释。\n"
    "【7·主动】不只回答问题，主动延伸有价值的信息。\n"
    "【8·记忆】记住上下文，引用之前聊过的内容。\n"
    "【9·诚实】不确定就说'我不太确定'，不编造。\n"
    "【10·过渡】回答开头自然过渡，用口语化的方式衔接，不要直接蹦答案。\n"
    "【11·长度】每次 5-15 句话（100-300字），重要话题可更长但分段。\n"
    "【12·ASR容错】输入来自语音转写，有错别字同音字，根据上下文推断真实意图直接回答。\n"
    "【13·双语】用户说中文就中文答，说英文就英文答。\n"
    "【14·禁忌】不说'作为AI'，不用书面体，不列清单，不用markdown。\n"
    "【15·灵魂】让每次对话都让用户觉得'跟你聊天真舒服'。\n"
)


# ── callback helper：同时兼容同步回调和 async 回调 ──
async def _maybe_await(cb, *args):
    if cb is None:
        return
    res = cb(*args)
    if asyncio.iscoroutine(res):
        await res


# ── LLM Streaming ──
async def _chat_completion_stream(messages, *, api_key, base_url, model, system_prompt="", temperature=0.75, max_tokens=1200, label="LLM"):
    if not api_key:
        log.warning("[%s] api key missing", label)
        return
    url = f"{base_url.rstrip('/')}/chat/completions"
    full_messages = [{"role": "system", "content": system_prompt or SYSTEM_PROMPT_15D}] + messages
    payload = {"model": model, "messages": full_messages, "stream": True, "temperature": temperature, "max_tokens": max_tokens}
    if "dashscope" in base_url:
        # 语音场景禁用思考模式：qwen3.x 思考型模型会先吐 reasoning_content，首句延迟不可接受
        payload["enable_thinking"] = False
    headers = {"Content-Type": "application/json", "Authorization": f"Bearer {api_key}"}

    async with httpx.AsyncClient(timeout=60) as client:
        async with client.stream("POST", url, json=payload, headers=headers) as resp:
            if resp.status_code != 200:
                log.error("[%s] %s: %s", label, resp.status_code, (await resp.aread())[:500])
                return
            async for line in resp.aiter_lines():
                if not line.startswith("data: "): continue
                d = line[6:].strip()
                if d == "[DONE]": return
                try:
                    c = json.loads(d).get("choices", [{}])[0].get("delta", {}).get("content", "")
                    if c: yield c
                except Exception: continue


async def deepseek_stream(messages, *, system_prompt="", model="", temperature=0.75, max_tokens=1200):
    emitted = False
    # 主 LLM 的 key 跟着 base_url 走：base_url 指向 DashScope 时必须用 DASHSCOPE_API_KEY，
    # 否则 DEEPSEEK_API_KEY 发给阿里会 401，每轮都白等一次失败再兜底。
    primary_key = DEEPSEEK_API_KEY
    if "dashscope" in VOICE_LLM_BASE_URL and DASHSCOPE_API_KEY:
        primary_key = DASHSCOPE_API_KEY
    if primary_key:
        async for token in _chat_completion_stream(
            messages,
            api_key=primary_key,
            base_url=VOICE_LLM_BASE_URL,
            model=model or VOICE_LLM_MODEL,
            system_prompt=system_prompt,
            temperature=temperature,
            max_tokens=max_tokens,
            label="DeepSeek",
        ):
            emitted = True
            yield token
    if emitted:
        return
    if DASHSCOPE_API_KEY:
        log.warning("[LLM] DeepSeek empty, falling back to DashScope/Qwen")
        async for token in _chat_completion_stream(
            messages,
            api_key=DASHSCOPE_API_KEY,
            base_url=VOICE_QWEN_LLM_BASE_URL,
            model=VOICE_QWEN_LLM_MODEL,
            system_prompt=system_prompt,
            temperature=temperature,
            max_tokens=max_tokens,
            label="DashScope",
        ):
            emitted = True
            yield token
    if not emitted:
        log.error("[LLM] no text emitted; check DEEPSEEK_API_KEY or DASHSCOPE_API_KEY")


# ── 逗号级切句 ──
SENTENCE_CUT_RE = re.compile(r'[，。！？,;；.!?\n]')

async def sentence_stream(token_stream):
    buf = ""
    async for token in token_stream:
        buf += token
        while True:
            m = SENTENCE_CUT_RE.search(buf)
            if not m: break
            s = buf[:m.end()].strip()
            buf = buf[m.end():]
            if s and len(s) >= 2: yield s
    r = buf.strip()
    if r and len(r) >= 2: yield r


# ── WAV header strip ──
def _strip_wav(data):
    if len(data) < 44 or data[:4] != b'RIFF': return data
    pos = 12
    while pos < len(data) - 8:
        cid, csz = data[pos:pos+4], int.from_bytes(data[pos+4:pos+8], 'little')
        if cid == b'data': return data[pos+8:pos+8+csz]
        pos += 8 + csz
    return data[44:]


# ── TTS WebSocket 流式 + 连接复用 + instruct 指令 ──
class TTSSession:
    def __init__(self, voice="", instructions=""):
        self.voice = voice or VOICE_TTS_VOICE
        self.instructions = instructions or VOICE_TTS_INSTRUCT
        self.ws = None
        self._ok = False
        # 串行化整条连接的使用：并发 synth/connect 会在同一 ws 上同时 recv 直接炸
        # （"cannot call recv while another coroutine is already running recv"）
        self._lock = asyncio.Lock()

    async def ensure(self):
        async with self._lock:
            if not self._ok:
                await self.connect()

    async def connect(self):
        import websockets
        ws_url = f"{QWEN_WS_BASE}/api-ws/v1/realtime?model={VOICE_TTS_MODEL}"
        self.ws = await websockets.connect(ws_url,
            additional_headers={"Authorization": f"Bearer {DASHSCOPE_API_KEY}"},
            max_size=16*1024*1024, ping_interval=30)
        await self.ws.send(json.dumps({"type": "session.update", "session": {
            "model": VOICE_TTS_MODEL,
            "voice": self.voice,
            "mode": "server_commit",
            "output_audio_format": "pcm_24000hz_mono_16bit",
            "instructions": self.instructions,
            "optimize_instructions": True,
        }}))
        msg = await asyncio.wait_for(self.ws.recv(), timeout=10)
        log.info("[TTS] connected: %s (voice=%s, instruct=%s)",
                 json.loads(msg).get("type"), self.voice, self.instructions[:30])
        self._ok = True

    async def synth(self, text, on_chunk=None):
      async with self._lock:
        if not self._ok: await self.connect()
        audio = bytearray()
        try:
            await self.ws.send(json.dumps({"type": "input_text_buffer.append", "text": text}))
            await self.ws.send(json.dumps({"type": "input_text_buffer.commit"}))
            while True:
                try: msg = await asyncio.wait_for(self.ws.recv(), timeout=15)
                except asyncio.TimeoutError: break
                ev = json.loads(msg)
                t = ev.get("type", "")
                if t == "response.audio.delta":
                    b = ev.get("delta", "")
                    if b:
                        raw = base64.b64decode(b)
                        pcm = _strip_wav(raw) if raw[:4] == b'RIFF' else raw
                        audio.extend(pcm)
                        await _maybe_await(on_chunk, pcm)
                elif t in ("response.done", "response.audio.done"): break
                elif t == "error":
                    log.error("[TTS] %s", ev)
                    self._ok = False; break
        except Exception as e:
            log.error("[TTS] synth err: %s", e); self._ok = False
        return bytes(audio)

    async def close(self):
        if self.ws:
            try: await self.ws.send(json.dumps({"type": "session.finish"})); await self.ws.close()
            except: pass
        self._ok = False


# ── Full Pipeline v2 ──
async def run_voice_pipeline(user_text, *, conversation_history=None, system_prompt="",
                              voice="", on_audio_chunk=None, on_sentence=None,
                              cancel_event=None, tts_session=None):
    history = conversation_history or []
    messages = history + [{"role": "user", "content": user_text}]
    full_text, all_audio, cancelled = "", bytearray(), False

    if cancel_event and cancel_event.is_set():
        return {"assistant_text": "", "audio_bytes": b"", "cancelled": True}

    # LLM + TTS 并行
    q = asyncio.Queue()
    done = asyncio.Event()

    async def worker():
        nonlocal all_audio, cancelled
        while True:
            try: s = await asyncio.wait_for(q.get(), timeout=30)
            except asyncio.TimeoutError: break
            if s is None or (cancel_event and cancel_event.is_set()): break
            a = await (tts_session.synth(s, on_chunk=on_audio_chunk) if tts_session
                       else tts_sentence_to_pcm(s, voice=voice, on_audio_chunk=on_audio_chunk))
            all_audio.extend(a)
            if cancel_event and cancel_event.is_set(): break
        done.set()

    asyncio.create_task(worker())

    async for sentence in sentence_stream(deepseek_stream(messages, system_prompt=system_prompt or SYSTEM_PROMPT_15D)):
        if cancel_event and cancel_event.is_set(): cancelled = True; break
        full_text += sentence
        await _maybe_await(on_sentence, sentence)
        await q.put(sentence)

    await q.put(None)
    try: await asyncio.wait_for(done.wait(), timeout=60)
    except: pass

    return {"assistant_text": full_text, "audio_bytes": bytes(all_audio), "cancelled": cancelled}


# ── 兼容旧接口 ──
async def tts_sentence_to_pcm(text, *, voice="", on_audio_chunk=None):
    s = TTSSession(voice=voice)
    try: await s.connect(); return await s.synth(text, on_chunk=on_audio_chunk)
    finally: await s.close()


# ── WebSocket endpoint v2 ──
async def voice_ws_endpoint(websocket):
    from starlette.websockets import WebSocketDisconnect
    await websocket.accept()
    log.info("[VoiceWS] connected")
    cfg, history, cancel, ptask, abuf = {}, [], asyncio.Event(), None, bytearray()
    tts: Optional[TTSSession] = None

    try:
        while True:
            ev = json.loads(await websocket.receive_text())
            t = ev.get("type", "")

            if t == "session.update":
                cfg = ev.get("session", {})
                v = cfg.get("voice", VOICE_TTS_VOICE)
                inst = cfg.get("instructions", VOICE_TTS_INSTRUCT)
                tts = TTSSession(voice=v, instructions=inst)
                try: await tts.ensure()
                except Exception as e: log.warning("[VoiceWS] TTS pre-connect: %s", e); tts = None
                await websocket.send_json({"type": "session.created", "session": {
                    "id": uuid.uuid4().hex, "provider": "pipeline", "model": VOICE_LLM_MODEL, "voice": v}})

            elif t == "input_audio_buffer.append":
                b = ev.get("audio", "")
                if b: abuf.extend(base64.b64decode(b))

            elif t == "input_audio_buffer.commit":
                if not abuf: continue
                await websocket.send_json({"type": "state", "value": "transcribing"})
                log.info("[VoiceWS] commit audio bytes=%s", len(abuf))
                text = await _run_asr(bytes(abuf)); abuf.clear()
                if not text or not text.strip():
                    await websocket.send_json({"type": "error", "detail": "ASR 没识别到文字，请检查麦克风输入或 DASHSCOPE_API_KEY/VOICE_ASR_MODEL。"})
                    continue
                log.info("[VoiceWS] ASR: '%s'", text)
                await websocket.send_json({"type": "conversation.item.input_audio_transcription.completed", "transcript": text})
                history.append({"role": "user", "content": text})
                await websocket.send_json({"type": "state", "value": "thinking"})

                if ptask and not ptask.done():
                    cancel.set()
                    try: await asyncio.wait_for(ptask, timeout=2)
                    except: pass
                cancel.clear()

                _t, _h = text, list(history[:-1])
                async def _run():
                    try:
                        r = await run_voice_pipeline(_t, conversation_history=_h,
                            system_prompt=cfg.get("instructions", ""), voice=cfg.get("voice", VOICE_TTS_VOICE),
                            on_audio_chunk=lambda c: asyncio.ensure_future(websocket.send_json(
                                {"type": "response.audio.delta", "delta": base64.b64encode(c).decode()})),
                            cancel_event=cancel, tts_session=tts)
                        await websocket.send_json({"type": "response.audio.done"})
                        await websocket.send_json({"type": "response.done"})
                        if r["assistant_text"]:
                            history.append({"role": "assistant", "content": r["assistant_text"]})
                            while len(history) > 40: history.pop(0)
                        else:
                            await websocket.send_json({"type": "error", "detail": "模型没有返回文字，请检查 DEEPSEEK_API_KEY，已配置 DASHSCOPE_API_KEY 时会自动走 Qwen 兜底。"})
                    except Exception as e:
                        log.error("[Pipeline] %s", e, exc_info=True)
                        try: await websocket.send_json({"type": "error", "error": {"message": str(e)}})
                        except: pass
                ptask = asyncio.create_task(_run())

            elif t == "response.cancel": cancel.set(); abuf.clear()
            elif t == "session.finish": break
    except Exception as e: log.info("[VoiceWS] disconnected: %s", e)
    finally:
        cancel.set()
        if ptask and not ptask.done(): ptask.cancel()
        if tts: await tts.close()
        log.info("[VoiceWS] cleanup")


# ── ASR ──
async def _run_asr(audio_pcm16):
    import websockets
    ws_url = f"{QWEN_WS_BASE}/api-ws/v1/realtime?model={VOICE_ASR_MODEL}"
    transcript = ""
    try:
        async with websockets.connect(ws_url,
            additional_headers={"Authorization": f"Bearer {DASHSCOPE_API_KEY}", "OpenAI-Beta": "realtime=v1"},
            max_size=16*1024*1024) as ws:
            await ws.send(json.dumps({"type": "session.update", "session": {"turn_detection": None}}))
            await asyncio.wait_for(ws.recv(), timeout=10)
            # 快推：一次性发完（不模拟实时）
            for i in range(0, len(audio_pcm16), 6400):
                await ws.send(json.dumps({"type": "input_audio_buffer.append",
                    "audio": base64.b64encode(audio_pcm16[i:i+6400]).decode()}))
            await ws.send(json.dumps({"type": "input_audio_buffer.commit"}))
            dl = time.time() + 10
            while time.time() < dl:
                try:
                    msg = await asyncio.wait_for(ws.recv(), timeout=8)
                    ev = json.loads(msg); et = ev.get("type", "")
                    if et == "conversation.item.input_audio_transcription.completed":
                        transcript = ev.get("transcript", ""); break
                    elif et == "conversation.item.input_audio_transcription.text":
                        transcript = ev.get("text", "") or ev.get("transcript", "") or transcript
                    elif et in ("session.finished", "error"): break
                except asyncio.TimeoutError: break
            try: await ws.send(json.dumps({"type": "session.finish"}))
            except: pass
    except Exception as e: log.error("[ASR] %s", e)
    return transcript.strip()


# ── Register ──
def register_voice_pipeline(app):
    from fastapi import WebSocket as FWS
    @app.websocket("/voice/ws")
    async def _ws(ws: FWS): await voice_ws_endpoint(ws)
    log.info("[VoicePipeline] /voice/ws registered")
    try:
        from public_webrtc_voice import register_public_webrtc_voice
        register_public_webrtc_voice(app)
        log.info("[VoicePipeline] public WebRTC /rtc/offer registered")
    except Exception as e:
        log.warning("[VoicePipeline] public WebRTC registration failed: %s", e)
