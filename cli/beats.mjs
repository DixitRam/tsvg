// Beat / onset times of an audio file (for <music beats="id">): spectral-flux onsets on a mono 22 kHz decode,
// adaptive threshold, then snapped to the dominant inter-onset period so the list is a steady beat grid.
import { spawnSync } from 'node:child_process';
export function detectBeats(file, { min = 0.25 } = {}) {
  const sr = 22050, hop = 256, win = 1024;
  const r = spawnSync('ffmpeg', ['-loglevel', 'error', '-i', file, '-ac', '1', '-ar', String(sr), '-f', 'f32le', '-'], { maxBuffer: 1 << 28 });
  if (r.status !== 0) throw new Error('ffmpeg could not decode ' + file);
  const x = new Float32Array(r.stdout.buffer, r.stdout.byteOffset, r.stdout.length / 4);
  // band energies per frame (cheap: 8 bands from a running filter bank of differences) → flux
  const frames = Math.max(0, Math.floor((x.length - win) / hop));
  const flux = new Float32Array(frames); let prev = new Float32Array(8);
  for (let f = 0; f < frames; f++) {
    const e = new Float32Array(8); const o = f * hop;
    for (let i = 0; i < win; i++) { const v = x[o + i], d = i ? v - x[o + i - 1] : 0; const b = Math.min(7, Math.floor((Math.abs(d) / (Math.abs(v) + 1e-6)) * 2)); e[b] += v * v; }
    let s = 0; for (let b = 0; b < 8; b++) { const l = Math.log1p(e[b] * 100); s += Math.max(0, l - prev[b]); prev[b] = l; } prev = prev.map((_, b) => Math.log1p(e[b] * 100));
    flux[f] = s;
  }
  // adaptive threshold: local mean + 1.4·std over ±0.4 s; peaks at least `min` apart
  const span = Math.round((0.4 * sr) / hop); const onsets = [];
  for (let f = 1; f < frames - 1; f++) {
    let m = 0, n = 0; for (let k = Math.max(0, f - span); k < Math.min(frames, f + span); k++) { m += flux[k]; n++; } m /= n;
    let v = 0; for (let k = Math.max(0, f - span); k < Math.min(frames, f + span); k++) v += (flux[k] - m) ** 2; const sd = Math.sqrt(v / n);
    if (flux[f] > m + 1.4 * sd && flux[f] >= flux[f - 1] && flux[f] > flux[f + 1]) { const t = (f * hop) / sr; if (!onsets.length || t - onsets[onsets.length - 1] >= min) onsets.push(t); }
  }
  if (onsets.length < 4) return onsets.map((t) => +t.toFixed(3));
  // dominant period: histogram of inter-onset gaps (0.25–1.5 s), 10 ms bins
  const hist = new Map(); for (let i = 1; i < onsets.length; i++) for (let j = i; j < Math.min(onsets.length, i + 4); j++) { const g = onsets[j] - onsets[i - 1]; if (g >= 0.25 && g <= 1.5) { const b = Math.round(g * 100); hist.set(b, (hist.get(b) || 0) + 1); } }
  let best = 0, bv = 0; for (const [b, v] of hist) { const w = v + (hist.get(b - 1) || 0) * 0.5 + (hist.get(b + 1) || 0) * 0.5; if (w > bv) { bv = w; best = b; } }
  const P = best / 100; const dur = x.length / sr;
  // phase: the offset that lines the grid up with the most onsets
  let phase = 0, score = -1; for (let k = 0; k < 50; k++) { const ph = (P * k) / 50; let sc = 0; for (const t of onsets) { const d = Math.abs(((t - ph) / P) - Math.round((t - ph) / P)) * P; if (d < 0.05) sc++; } if (sc > score) { score = sc; phase = ph; } }
  const grid = []; for (let t = phase; t < dur; t += P) grid.push(+t.toFixed(3));
  return grid;
}
