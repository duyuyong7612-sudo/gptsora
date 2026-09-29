// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-c02023bedfb421414c9a2ef6e2b58e618b137f0c370b32c28602577ef10cd57e"
// Source-SHA256: "dc99c55317bc4f1cbec5f95ee06ce1f9bc429bbda9fc2b764214d7bacf323991"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
const $ = (id) => document.getElementById(id);

const ui = {
  backend: $("backend"),
  connect: $("connect"),
  disconnect: $("disconnect"),
  interrupt: $("interrupt"),
  finish: $("finish"),
  dot: $("dot"),
  status: $("status"),
  meter: $("meter"),
  round: $("round"),
  route: $("route"),
  first: $("first"),
  total: $("total"),
  subtitle: $("subtitle"),
  assistant: $("assistant"),
  diagnostic: $("diagnostic"),
  events: $("events"),
};

window.__aduWebrtcClientLoaded = true;

const params = new URLSearchParams(location.search);
ui.backend.value = (params.get("backend") || params.get("api") || location.origin).replace(/\/+$/, "");

let pc = null;
let dc = null;
let ws = null;
let mediaStream = null;
let audioContext = null;
let captureNode = null;
let sourceNode = null;
let sendBuffer = [];
let playingContext = null;
let audioQueue = Promise.resolve();
let usingFallback = false;
let transportMode = "webrtc";
let legacyVoiceActive = false;
let legacyLastVoice = 0;
let legacySpeechStartedAt = 0;
let legacyCommitTimer = null;
let legacyVoiceNoticeShown = false;

const LEGACY_START_RMS = 0.0025;
const LEGACY_KEEP_RMS = 0.0012;
const LEGACY_SILENCE_COMMIT_MS = 650;
const LEGACY_MAX_UTTERANCE_MS = 4000;

function setStatus(text, mode = "") {
  ui.status.textContent = text;
  ui.dot.className = `dot ${mode}`.trim();
}

function diagnose(text) {
  if (ui.diagnostic) ui.diagnostic.textContent = text || "";
}

function setButtons(on) {
  ui.connect.disabled = on;
  ui.disconnect.disabled = !on;
  ui.interrupt.disabled = !on;
  ui.finish.disabled = !on;
}

function log(type, text) {
  const row = document.createElement("div");
  row.className = "event";
  const code = document.createElement("code");
  code.textContent = type;
  const body = document.createElement("div");
  body.textContent = text;
  row.append(code, body);
  ui.events.prepend(row);
  while (ui.events.children.length > 120) ui.events.lastElementChild.remove();
}

function sendJson(obj) {
  if (dc && dc.readyState === "open") dc.send(JSON.stringify(obj));
  else if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj));
}

function bytesToB64(buffer) {
  const bytes = new Uint8Array(buffer);
  let binary = "";
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  return btoa(binary);
}

function sendAudioBuffer(buffer, rms) {
  const dataChannelOpen = dc && dc.readyState === "open";
  const webSocketOpen = ws && ws.readyState === WebSocket.OPEN;
  if (!dataChannelOpen && !webSocketOpen) return;
  if (transportMode === "legacy-voice-ws") {
    const now = performance.now();
    if (rms > LEGACY_START_RMS) {
      if (!legacyVoiceActive) {
        diagnose("听到麦克风了，停顿一下会自动提交。");
        log("mic", `voice detected rms=${rms.toFixed(4)}`);
        legacySpeechStartedAt = now;
      }
      legacyVoiceActive = true;
      legacyLastVoice = now;
      legacyVoiceNoticeShown = true;
      setStatus("正在听", "on");
    } else if (legacyVoiceActive && rms > LEGACY_KEEP_RMS) {
      legacyLastVoice = now;
    }
    if (!legacyVoiceActive) return;
    ws.send(JSON.stringify({ type: "input_audio_buffer.append", audio: bytesToB64(buffer) }));
    const shouldCommitByMaxTime = legacySpeechStartedAt && now - legacySpeechStartedAt >= LEGACY_MAX_UTTERANCE_MS;
    if (shouldCommitByMaxTime) {
      commitLegacyVoice("到达最长录音时间，已自动提交。");
      return;
    }
    clearTimeout(legacyCommitTimer);
    legacyCommitTimer = setTimeout(() => {
      if (legacyVoiceActive && performance.now() - legacyLastVoice >= LEGACY_SILENCE_COMMIT_MS) {
        commitLegacyVoice("已提交语音，正在识别。");
      }
    }, LEGACY_SILENCE_COMMIT_MS + 80);
    return;
  }
  if (dataChannelOpen) dc.send(buffer);
  else ws.send(buffer);
}

function commitLegacyVoice(message) {
  if (!legacyVoiceActive || !ws || ws.readyState !== WebSocket.OPEN) return;
  legacyVoiceActive = false;
  legacySpeechStartedAt = 0;
  clearTimeout(legacyCommitTimer);
  ws.send(JSON.stringify({ type: "input_audio_buffer.commit" }));
  diagnose(message || "已提交语音，正在识别。");
  log("commit", "audio submitted");
  setStatus("正在识别", "busy");
}

function floatToPcm16(samples) {
  const out = new Int16Array(samples.length);
  for (let i = 0; i < samples.length; i++) {
    const s = Math.max(-1, Math.min(1, samples[i]));
    out[i] = s < 0 ? s * 0x8000 : s * 0x7fff;
  }
  return out;
}

function downsample(input, inputRate, outputRate = 16000) {
  if (inputRate === outputRate) return input;
  const ratio = inputRate / outputRate;
  const length = Math.floor(input.length / ratio);
  const out = new Float32Array(length);
  for (let i = 0; i < length; i++) {
    const start = Math.floor(i * ratio);
    const end = Math.min(input.length, Math.floor((i + 1) * ratio));
    let sum = 0;
    for (let j = start; j < end; j++) sum += input[j];
    out[i] = sum / Math.max(1, end - start);
  }
  return out;
}

async function startCapture() {
  mediaStream = await navigator.mediaDevices.getUserMedia({
    audio: { echoCancellation: true, noiseSuppression: false, autoGainControl: true, channelCount: 1 },
  });
  audioContext = new (window.AudioContext || window.webkitAudioContext)();
  sourceNode = audioContext.createMediaStreamSource(mediaStream);
  captureNode = audioContext.createScriptProcessor(2048, 1, 1);
  captureNode.onaudioprocess = (ev) => {
    const input = ev.inputBuffer.getChannelData(0);
    const samples = downsample(input, audioContext.sampleRate, 16000);
    let rms = 0;
    for (let i = 0; i < samples.length; i++) rms += samples[i] * samples[i];
    rms = Math.sqrt(rms / Math.max(1, samples.length));
    ui.meter.style.setProperty("--level", String(Math.min(1, rms * 40)));
    if (transportMode === "legacy-voice-ws" && !legacyVoiceNoticeShown && rms > LEGACY_START_RMS) {
      legacyVoiceNoticeShown = true;
      log("mic", `input active rms=${rms.toFixed(4)}`);
    }
    sendBuffer.push(...floatToPcm16(samples));
    while (sendBuffer.length >= 2048) {
      const chunk = new Int16Array(sendBuffer.slice(0, 2048));
      sendBuffer = sendBuffer.slice(2048);
      sendAudioBuffer(chunk.buffer, rms);
    }
  };
  sourceNode.connect(captureNode);
  captureNode.connect(audioContext.destination);
}

function stopCapture() {
  try { captureNode && captureNode.disconnect(); } catch {}
  try { sourceNode && sourceNode.disconnect(); } catch {}
  try { mediaStream && mediaStream.getTracks().forEach((track) => track.stop()); } catch {}
  try { audioContext && audioContext.close(); } catch {}
  captureNode = null;
  sourceNode = null;
  mediaStream = null;
  audioContext = null;
  sendBuffer = [];
  ui.meter.style.setProperty("--level", "0");
}

function b64ToBytes(b64) {
  const raw = atob(b64 || "");
  const bytes = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
  return bytes;
}

async function playPcm(bytes, sampleRate = 24000) {
  if (!playingContext || playingContext.state === "closed") {
    playingContext = new (window.AudioContext || window.webkitAudioContext)({ sampleRate });
  }
  if (playingContext.state === "suspended") await playingContext.resume();
  const pcm = new Int16Array(bytes.buffer, bytes.byteOffset, Math.floor(bytes.byteLength / 2));
  const buf = playingContext.createBuffer(1, pcm.length, sampleRate);
  const out = buf.getChannelData(0);
  for (let i = 0; i < pcm.length; i++) out[i] = Math.max(-1, Math.min(1, pcm[i] / 32768));
  const src = playingContext.createBufferSource();
  src.buffer = buf;
  src.connect(playingContext.destination);
  await new Promise((resolve) => {
    src.onended = resolve;
    src.start();
  });
}

function stopPlayback() {
  try { playingContext && playingContext.close(); } catch {}
  playingContext = null;
  audioQueue = Promise.resolve();
}

function handleEvent(ev) {
  if (!ev || !ev.type) return;
  if (ev.r != null) ui.round.textContent = ev.r;
  if (ev.type === "session.created") {
    log("session", ev.session_id || "created");
    if (transportMode === "legacy-voice-ws") {
      diagnose("语音会话已创建，请靠近麦克风直接说一句。");
    }
    return;
  }
  if (ev.type === "conversation.item.input_audio_transcription.completed") {
    ui.subtitle.textContent = ev.transcript || "";
    log("transcript", ev.transcript || "");
    setStatus("正在想", "busy");
    return;
  }
  if (ev.type === "response.audio.delta") {
    const bytes = b64ToBytes(ev.delta);
    audioQueue = audioQueue.then(() => playPcm(bytes, 24000)).catch((err) => log("audio_error", String(err)));
    setStatus("正在说", "busy");
    return;
  }
  if (ev.type === "response.audio.done" || ev.type === "response.done") {
    setStatus("已连接", "on");
    return;
  }
  if (ev.type === "state") {
    const label = { listening: "正在听", transcribing: "正在识别", thinking: "正在想", speaking: "正在说" }[ev.value] || ev.value;
    setStatus(label, ev.value === "listening" ? "on" : "busy");
    return;
  }
  if (ev.type === "level") {
    ui.meter.style.setProperty("--level", String(Math.min(1, Number(ev.rms || 0) * 18)));
    return;
  }
  if (ev.type === "transcript" || ev.type === "round") {
    ui.subtitle.textContent = ev.text || "";
    if (ev.type === "round") ui.assistant.textContent = "";
    log(ev.type, ev.text || "");
    return;
  }
  if (ev.type === "delta") {
    ui.assistant.textContent += ev.text || "";
    return;
  }
  if (ev.type === "audio") {
    const bytes = b64ToBytes(ev.b64);
    audioQueue = audioQueue.then(() => playPcm(bytes, Number(ev.sample_rate || 24000))).catch((err) => log("audio_error", String(err)));
    if (ev.first_ms != null) ui.first.textContent = `${Math.round(ev.first_ms)}ms`;
    return;
  }
  if (ev.type === "bargein") {
    stopPlayback();
    log("bargein", `round=${ev.r || "-"}`);
    return;
  }
  if (ev.type === "timing") {
    ui.route.textContent = ev.route || "-";
    if (ev.first_audio_ms != null) ui.first.textContent = `${Math.round(ev.first_audio_ms)}ms`;
    if (ev.total_ms != null) ui.total.textContent = `${Math.round(ev.total_ms)}ms`;
    log("timing", JSON.stringify(ev));
    setStatus("已连接", "on");
    return;
  }
  if (ev.type === "error") {
    log("error", ev.detail || JSON.stringify(ev));
    setStatus("出错", "");
    return;
  }
  log(ev.type, ev.text || ev.detail || JSON.stringify(ev));
}

async function connect() {
  const backend = ui.backend.value.trim().replace(/\/+$/, "");
  if (!backend) return;
  diagnose("");
  setButtons(true);
  setStatus("连接中", "busy");
  try {
    usingFallback = false;
    pc = new RTCPeerConnection({ iceServers: [{ urls: "stun:stun.l.google.com:19302" }] });
    dc = pc.createDataChannel("voice", { ordered: true });
    dc.binaryType = "arraybuffer";
    dc.onmessage = (event) => {
      if (typeof event.data === "string") {
        try { handleEvent(JSON.parse(event.data)); } catch { log("message", event.data); }
      }
    };
    dc.onopen = async () => {
      setStatus("已连接", "on");
      diagnose("已建立 WebRTC 通道，正在打开麦克风。");
      await startCapture();
      diagnose("麦克风已连接，可以直接说话。");
    };
    dc.onclose = () => disconnect();
    pc.onconnectionstatechange = () => {
      if (!usingFallback && ["failed", "disconnected", "closed"].includes(pc.connectionState)) {
        connectWebSocketFallback(backend, `WebRTC ${pc.connectionState}`);
      }
    };
    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    const resp = await fetch(`${backend}/rtc/offer`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(pc.localDescription),
    });
    const answer = await resp.json();
    if (!answer.ok) throw new Error(answer.error || "rtc offer failed");
    await pc.setRemoteDescription({ type: answer.type, sdp: answer.sdp });
    setTimeout(() => {
      if (!usingFallback && (!dc || dc.readyState !== "open")) {
        connectWebSocketFallback(backend, "WebRTC 连接超时，切到 WebSocket");
      }
    }, 8000);
  } catch (err) {
    await connectWebSocketFallback(backend, String(err && err.message || err));
  }
}

async function connectWebSocketFallback(backend, reason = "") {
  if (usingFallback) return;
  usingFallback = true;
  try { if (dc) dc.onclose = null; } catch {}
  try { if (pc) pc.onconnectionstatechange = null; } catch {}
  try { dc && dc.close(); } catch {}
  try { pc && pc.close(); } catch {}
  dc = null;
  pc = null;
  const wsUrl = `${backend.replace(/^https:/, "wss:").replace(/^http:/, "ws:")}/rtc/ws`;
  transportMode = "rtc-ws";
  setStatus("连接中", "busy");
  diagnose(`WebRTC 不可用，正在切到 WebSocket 通道。${reason ? "原因：" + reason : ""}`);
  ws = new WebSocket(wsUrl);
  ws.binaryType = "arraybuffer";
  ws.onmessage = (event) => {
    if (typeof event.data === "string") {
      try { handleEvent(JSON.parse(event.data)); } catch { log("message", event.data); }
    }
  };
  ws.onopen = async () => {
    setStatus("已连接", "on");
    diagnose("已连接 WebSocket fallback，可以直接说话。");
    await startCapture();
  };
  ws.onerror = () => {
    log("connect_error", "rtc websocket fallback error");
    connectLegacyVoiceWsFallback(backend, "/rtc/ws 连接失败");
  };
  ws.onclose = () => {
    if (usingFallback) disconnect();
  };
}

async function connectLegacyVoiceWsFallback(backend, reason = "") {
  try { if (ws) ws.onclose = null; } catch {}
  try { ws && ws.close(); } catch {}
  const wsUrl = `${backend.replace(/^https:/, "wss:").replace(/^http:/, "ws:")}/voice/ws`;
  transportMode = "legacy-voice-ws";
  setStatus("连接中", "busy");
  diagnose(`正在切到已有 /voice/ws 语音通道。${reason ? "原因：" + reason : ""}`);
  ws = new WebSocket(wsUrl);
  ws.onmessage = (event) => {
    if (typeof event.data === "string") {
      try { handleEvent(JSON.parse(event.data)); } catch { log("message", event.data); }
    }
  };
  ws.onopen = async () => {
    setStatus("已连接", "on");
    diagnose("已连接 /voice/ws，可以直接说话。");
    ws.send(JSON.stringify({ type: "session.update", session: { voice: "Cherry" } }));
    await startCapture();
    log("mic", "microphone capture started");
  };
  ws.onerror = () => {
    diagnose("连接失败：WebRTC、/rtc/ws、/voice/ws 都没有连上。");
    log("connect_error", "legacy /voice/ws error");
  };
  ws.onclose = () => {
    disconnect();
  };
}

async function disconnect() {
  stopPlayback();
  stopCapture();
  try { if (dc) dc.onclose = null; } catch {}
  try { if (ws) ws.onclose = null; } catch {}
  try { if (pc) pc.onconnectionstatechange = null; } catch {}
  try { dc && dc.close(); } catch {}
  try { ws && ws.close(); } catch {}
  try { pc && pc.close(); } catch {}
  dc = null;
  ws = null;
  pc = null;
  usingFallback = false;
  transportMode = "webrtc";
  legacyVoiceActive = false;
  legacySpeechStartedAt = 0;
  legacyVoiceNoticeShown = false;
  clearTimeout(legacyCommitTimer);
  setButtons(false);
  setStatus("未连接", "");
}

ui.connect.addEventListener("click", connect);
ui.disconnect.addEventListener("click", disconnect);
ui.interrupt.addEventListener("click", () => {
  stopPlayback();
  sendJson({ type: "interrupt" });
});
ui.finish.addEventListener("click", () => {
  sendJson({ type: "session.finish" });
  disconnect();
});

setButtons(false);
setStatus("未连接", "");
