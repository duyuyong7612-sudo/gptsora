// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-612aa66ca5e8cab795146099a5d23a64e72dfcf0b2a111277a764a8020f6b7af"
// Source-SHA256: "58db3cf912d5e7640d9ae6258813d2cdc5cfed8f9d8f3de43ee74cbe3f545a10"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
export interface MicPcmChunk {
  audio: string;
  sampleRate: number;
  format: "pcm16";
  rms: number;
}

export interface MicPcmStream {
  stop: () => void;
}

export function floatTo16BitPCM(samples: Float32Array): Uint8Array {
  const bytes = new Uint8Array(samples.length * 2);
  const view = new DataView(bytes.buffer);
  for (let i = 0; i < samples.length; i += 1) {
    const sample = Math.max(-1, Math.min(1, samples[i] || 0));
    view.setInt16(i * 2, sample < 0 ? sample * 0x8000 : sample * 0x7fff, true);
  }
  return bytes;
}

export function pcm16ToBase64(pcm16: Uint8Array): string {
  let binary = "";
  const chunkSize = 0x8000;
  for (let i = 0; i < pcm16.length; i += chunkSize) {
    binary += String.fromCharCode(...pcm16.subarray(i, i + chunkSize));
  }
  return btoa(binary);
}

function resampleMono(input: Float32Array, inputRate: number, outputRate: number): Float32Array {
  if (inputRate === outputRate) return new Float32Array(input);
  const ratio = inputRate / outputRate;
  const out = new Float32Array(Math.max(1, Math.floor(input.length / ratio)));
  for (let i = 0; i < out.length; i += 1) {
    const pos = i * ratio;
    const left = Math.floor(pos);
    const right = Math.min(input.length - 1, left + 1);
    const frac = pos - left;
    out[i] = input[left] + (input[right] - input[left]) * frac;
  }
  return out;
}

export function createMicPcmStream(
  stream: MediaStream,
  onChunk: (chunk: MicPcmChunk) => void,
  options?: { sampleRate?: number; chunkMs?: number },
): MicPcmStream {
  const sampleRate = options?.sampleRate || 16000;
  const chunkSamples = Math.max(320, Math.round(sampleRate * ((options?.chunkMs || 250) / 1000)));
  const Ctor = window.AudioContext || (window as any).webkitAudioContext;
  if (!Ctor) throw new Error("当前浏览器不支持麦克风音频采集");

  const ctx = new Ctor();
  const source = ctx.createMediaStreamSource(stream);
  const processor = ctx.createScriptProcessor(4096, 1, 1);
  const zeroGain = ctx.createGain();
  const pending: number[] = [];
  zeroGain.gain.value = 0;

  processor.onaudioprocess = (event) => {
    const input = event.inputBuffer.getChannelData(0);
    const mono = resampleMono(input, ctx.sampleRate, sampleRate);
    let sum = 0;
    for (let i = 0; i < mono.length; i += 1) {
      const sample = mono[i] || 0;
      pending.push(sample);
      sum += sample * sample;
    }
    while (pending.length >= chunkSamples) {
      const samples = new Float32Array(pending.splice(0, chunkSamples));
      const audio = pcm16ToBase64(floatTo16BitPCM(samples));
      onChunk({
        audio,
        sampleRate,
        format: "pcm16",
        rms: Math.sqrt(sum / Math.max(1, mono.length)),
      });
    }
  };

  source.connect(processor);
  processor.connect(zeroGain);
  zeroGain.connect(ctx.destination);

  return {
    stop: () => {
      try { processor.disconnect(); } catch {}
      try { source.disconnect(); } catch {}
      try { zeroGain.disconnect(); } catch {}
      try { ctx.close(); } catch {}
    },
  };
}
