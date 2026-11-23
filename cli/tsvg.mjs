#!/usr/bin/env node
// tsvg — command line tools for TSVG (Timeseries Scalable Vector Graphics).
//   tsvg validate <file.tsvg|.tsvgz>             static checks + dry run of every variant
//   tsvg info     <file>                         duration, options, chapters, voices
//   tsvg pack     <file.tsvg> [-o out.tsvgz]     zip the document with every file it references
//   tsvg unpack   <file.tsvgz> [-o dir]
//   tsvg bake     <file.tsvg> [--tts gu=sarvam:shubh] [--only en,gu] [--force]
//                                                record every <say> line per language, write <voices>
//   tsvg render   <file> -t 3.5 [-o frame.png] [--width 960] [--layout portrait] [--lang gu …]
//   tsvg export   <file> [-o out.mp4] [--fps 30] [--width 1920] [--layout …] [--lang …] [--mix …] [--captions]
//   tsvg test     [--update]                     golden frames (tests/cases.json)
//   tsvg serve    [dir] [--port 4380]            static server for the spec + playground
import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync, statSync, rmSync, unlinkSync } from 'node:fs';
import { dirname, join, resolve, relative, extname, basename } from 'node:path';
import { createHash } from 'node:crypto';
import { spawn, spawnSync } from 'node:child_process';
import { deflateRawSync, inflateRawSync } from 'node:zlib';
import { createServer } from 'node:http';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const require = createRequire(import.meta.url);
const TSVG = require(join(ROOT, 'web/tsvg-core.js'));
const Zip = require(join(ROOT, 'web/tsvg-zip.js'));

// ───────── args ─────────
const argv = process.argv.slice(2);
const cmd = argv.shift();
const flags = {}; const pos = [];
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a.startsWith('--')) { const k = a.slice(2); const v = argv[i + 1] && !argv[i + 1].startsWith('-') ? argv[++i] : true; (flags[k] = flags[k] || []).push(v); }
  else if (a === '-o' || a === '-t') flags[a.slice(1)] = [argv[++i]];
  else pos.push(a);
}
const flag = (k, d) => (flags[k] ? flags[k][flags[k].length - 1] : d);
const die = (m) => { console.error('tsvg: ' + m); process.exit(1); };

// ───────── sources: a .tsvg file next to its files, or a .tsvgz package ─────────
async function openSource(file) {
  if (!file) die('missing file');
  const abs = resolve(file); if (!existsSync(abs)) die('no such file: ' + file);
  const bytes = readFileSync(abs);
  if (Zip.isZip(bytes)) {
    const files = await Zip.read(bytes, { inflateRaw: (b) => new Uint8Array(inflateRawSync(b)) });
    return { kind: 'zip', path: abs, xml: Zip.text(files.get(Zip.MAIN)), get: (p) => (files.has(p) ? Buffer.from(files.get(p)) : null), has: (p) => files.has(p), list: () => [...files.keys()] };
  }
  const dir = dirname(abs);
  return { kind: 'file', path: abs, dir, xml: bytes.toString('utf8'), get: (p) => (existsSync(join(dir, p)) ? readFileSync(join(dir, p)) : null), has: (p) => existsSync(join(dir, p)) && statSync(join(dir, p)).isFile() };
}
function referenced(doc) {
  const s = new Set();
  const add = (r) => { const p = TSVG.assetPath(doc, r); if (p && !/^(https?|data):/.test(p)) s.add(p); };
  for (const a of Object.values(doc.assets)) add(a.src);
  for (const f of doc.fonts) add(f.src);
  for (const v of Object.values(doc.voices)) add(v.src);
  for (const a of doc.audio) add(a.src);
  for (const say of doc.says) for (const [k, v] of Object.entries(say.raw)) if (k.startsWith('src.')) add(v);
  return [...s];
}
const optsFromFlags = (doc) => { const o = TSVG.defaults(doc); for (const op of doc.options) if (flags[op.id]) o[op.id] = flag(op.id); return o; };
const layoutOf = (doc) => { const id = flag('layout'); const L = id ? doc.layouts.find((l) => l.id === id) : doc.layouts[0]; if (!L) die('no layout ' + id + ' (have ' + doc.layouts.map((l) => l.id).join(', ') + ')'); return L; };

// ───────── commands ─────────
const cmds = {
  async validate() {
    const src = await openSource(pos[0]);
    const r = TSVG.validate(src.xml, { files: { has: src.has } });
    for (const w of r.warnings) console.log('warn  ' + w);
    for (const e of r.errors) console.log('ERROR ' + e);
    if (r.stats) console.log(`${r.ok ? 'ok' : 'FAILED'} · ${r.stats.duration}s · ${r.stats.scenes} scenes · ${r.stats.variants} variants · ${r.errors.length} errors · ${r.warnings.length} warnings`);
    process.exit(r.ok ? 0 : 1);
  },
  async info() {
    const src = await openSource(pos[0]); const doc = TSVG.parse(src.xml);
    const env = TSVG.makeEnv(doc, TSVG.defaults(doc), doc.layouts[0], 0);
    console.log(`TSVG ${doc.version} · ${doc.duration}s · ${src.kind}`);
    console.log('layouts:  ' + doc.layouts.map((l) => `${l.id} ${l.w}×${l.h}`).join(', '));
    for (const o of doc.options) console.log(`option ${o.id}: ` + o.choices.map((c) => (c.id === o.default ? '*' : '') + c.id).join(' '));
    console.log('chapters: ' + doc.chapters.map((c) => `${c.t}s ${TSVG.value(c.label, env, doc)}`).join(' · '));
    const langs = (doc.options.find((o) => o.id === 'lang') || { choices: [{ id: 'en' }] }).choices.map((c) => c.id);
    for (const l of langs) { const lines = TSVG.sayLines(doc, Object.assign(TSVG.defaults(doc), { lang: l })); console.log(`voice ${l}: ${lines.filter((x) => x.clip).length}/${lines.length} lines recorded`); }
  },
  async pack() {
    const src = await openSource(pos[0]); if (src.kind !== 'file') die('pack takes a .tsvg file');
    const doc = TSVG.parse(src.xml);
    const r = TSVG.validate(src.xml, { files: { has: src.has } }); if (!r.ok) { r.errors.forEach((e) => console.error('ERROR ' + e)); die('fix errors before packing'); }
    const entries = [{ path: Zip.MAIN, data: src.xml }];
    for (const p of referenced(doc)) entries.push({ path: p, data: new Uint8Array(src.get(p)) });
    const out = flag('o', src.path.replace(/\.tsvg$/, '') + '.tsvgz'); mkdirSync(dirname(resolve(out)), { recursive: true });
    const bytes = Zip.write(entries, { deflateRaw: (b) => new Uint8Array(deflateRawSync(b, { level: 9 })) });
    writeFileSync(out, bytes); console.log(`${out} · ${entries.length} files · ${(bytes.length / 1024).toFixed(0)} KB`);
  },
  async unpack() {
    const src = await openSource(pos[0]); if (src.kind !== 'zip') die('unpack takes a .tsvgz');
    const out = resolve(flag('o', src.path.replace(/\.tsvgz$/, '')));
    for (const p of src.list()) { if (p.includes('..')) die('unsafe path in package: ' + p); const f = join(out, p); mkdirSync(dirname(f), { recursive: true }); writeFileSync(f, src.get(p)); }
    console.log(out);
  },
  bake, render, export: exportMp4, test, serve,
};

// ───────── bake: record every <say> line per language ─────────
async function bake() {
  const src = await openSource(pos[0]); if (src.kind !== 'file') die('bake works on a .tsvg file (unpack a .tsvgz first)');
  const doc = TSVG.parse(src.xml);
  const langOpt = doc.options.find((o) => o.id === 'lang');
  let langs = langOpt ? langOpt.choices.map((c) => c.id) : ['en'];
  if (flag('only')) langs = String(flag('only')).split(',');
  const ttsFor = {};
  for (const l of langs) {
    const fromFlag = (flags.tts || []).map(String).find((x) => x.startsWith(l + '='));
    const choice = langOpt && langOpt.choices.find((c) => c.id === l);
    const fromDoc = choice && parseChoiceTts(src.xml, l);
    ttsFor[l] = (fromFlag && fromFlag.split('=')[1]) || fromDoc || (l === 'en' ? 'kokoro:af_heart' : 'sarvam:shubh');
  }
  const voices = Object.assign({}, doc.voices);
  const docName = basename(src.path).replace(/\.tsvg$/, ''); // clips live in voice/<doc>/<lang>/ so many documents can share a folder
  const jobs = [];
  for (const l of langs) {
    const [engine, voice] = ttsFor[l].split(':');
    for (const ln of TSVG.sayLines(doc, Object.assign(TSVG.defaults(doc), { lang: l }))) {
      const say = doc.says.find((s) => s.key === ln.key); if (say.raw['src.' + l]) continue; // hand-recorded clip wins
      const v = say.raw['voice.' + l] || say.raw.voice || voice;
      const hash = createHash('sha1').update(engine + '|' + v + '|' + ln.speak).digest('hex').slice(0, 10);
      const path = `voice/${docName}/${l}/${ln.key}.${hash}.ogg`; const k = ln.key + '|' + l;
      if (!flag('force') && voices[k] && voices[k].hash === hash && src.has(voices[k].src)) continue;
      jobs.push({ k, key: ln.key, lang: l, engine, voice: v, text: ln.speak, hash, path });
    }
  }
  console.log(`bake: ${jobs.length} line(s) to record · ${langs.map((l) => l + '=' + ttsFor[l]).join(' ')}`);
  const tmp = join(src.dir, '.tsvg-bake-' + basename(src.path) + '-' + process.pid); mkdirSync(tmp, { recursive: true }); // per run: bakes can run side by side
  const kok = jobs.filter((j) => j.engine === 'kokoro');
  if (kok.length) {
    const py = process.env.TSVG_PYTHON || join(process.env.HOME, '.cache/explainer-video/py/venv/bin/python');
    const input = kok.map((j, i) => ({ text: j.text, voice: j.voice, lang: j.lang === 'en' ? 'en-us' : j.lang, speed: 1, out: join(tmp, i + '.wav') }));
    const r = spawnSync(py, [join(ROOT, 'cli/tts_kokoro.py')], { input: JSON.stringify(input), encoding: 'utf8', maxBuffer: 1 << 26 });
    if (r.status !== 0) die('kokoro failed: ' + (r.stderr || '').split('\n').slice(-4).join(' '));
    kok.forEach((j, i) => (j.wav = input[i].out));
  }
  for (const j of jobs.filter((x) => x.engine === 'sarvam')) {
    const key = process.env.SARVAM_API_KEY; if (!key) die('SARVAM_API_KEY not set (needed for ' + j.lang + ')');
    const [model, speaker] = j.voice.includes('@') ? j.voice.split('@') : ['bulbul:v3', j.voice];
    const res = await fetch('https://api.sarvam.ai/text-to-speech', { method: 'POST', headers: { 'api-subscription-key': key, 'content-type': 'application/json' }, body: JSON.stringify({ text: j.text, target_language_code: j.lang + '-IN', speaker, model }) });
    if (!res.ok) die(`sarvam ${j.key} [${j.lang}]: HTTP ${res.status} ${(await res.text()).slice(0, 200)}`);
    const body = await res.json(); j.wav = join(tmp, j.lang + '-' + j.key + '.wav'); writeFileSync(j.wav, Buffer.from(body.audios.join(''), 'base64'));
    process.stdout.write('.');
  }
  for (const j of jobs.filter((x) => !['kokoro', 'sarvam'].includes(x.engine))) die('unknown TTS engine ' + j.engine + ' (kokoro | sarvam)');
  for (const j of jobs) {
    const out = join(src.dir, j.path); mkdirSync(dirname(out), { recursive: true });
    ff(['-i', j.wav, '-af', 'loudnorm=I=-16:TP=-1.5:LRA=11,aresample=48000', '-ac', '1', '-c:a', 'libopus', '-b:a', '32k', out]);
    voices[j.k] = { src: j.path, dur: probeDur(out), hash: j.hash, engine: j.engine + ':' + j.voice };
  }
  rmSync(tmp, { recursive: true, force: true });
  // drop entries for lines that no longer exist, delete files nobody references
  const live = new Set(doc.says.flatMap((s) => langs.map((l) => s.key + '|' + l)));
  for (const k of Object.keys(voices)) if (!live.has(k) && langs.includes(k.split('|')[1])) delete voices[k];
  const keep = new Set(Object.values(voices).map((v) => v.src));
  const vdir = join(src.dir, 'voice', docName); // only this document's folder is cleaned
  if (existsSync(vdir)) for (const l of readdirSync(vdir)) for (const f of readdirSync(join(vdir, l))) { const p = `voice/${docName}/${l}/${f}`; if (!keep.has(p)) unlinkSync(join(src.dir, p)); }
  const block = '<voices>\n' + Object.entries(voices).sort().map(([k, v]) => { const [say, lang] = k.split('|'); return `    <voice say="${say}" lang="${lang}" src="${v.src}" dur="${(+v.dur).toFixed(2)}" hash="${v.hash}" engine="${v.engine}"/>`; }).join('\n') + '\n  </voices>';
  let xml = src.xml;
  if (/<voices\b[\s\S]*?<\/voices>|<voices\s*\/>/.test(xml)) xml = xml.replace(/<voices\b[\s\S]*?<\/voices>|<voices\s*\/>/, block);
  else xml = xml.replace(/\n?<\/tsvg>\s*$/, '\n\n  <!-- written by `tsvg bake`: one recorded clip per <say> line and language -->\n  ' + block + '\n</tsvg>\n');
  writeFileSync(src.path, xml);
  if (jobs.length) console.log('');
  const r = TSVG.validate(xml, { files: { has: (p) => existsSync(join(src.dir, p)) } });
  for (const w of r.warnings.filter((w) => /overlaps|past the end/.test(w))) console.log('warn  ' + w);
  console.log(`bake: done · ${Object.keys(voices).length} clips in <voices>`);
}
function parseChoiceTts(xml, lang) { const m = new RegExp('<choice[^>]*\\bid="' + lang + '"[^>]*\\btts="([^"]+)"').exec(xml); return m && m[1]; }
function ff(args) { const r = spawnSync('ffmpeg', ['-loglevel', 'error', '-y', ...args], { encoding: 'utf8' }); if (r.status !== 0) die('ffmpeg: ' + r.stderr); }
function probeDur(f) { return +spawnSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', f], { encoding: 'utf8' }).stdout.trim(); }

// ───────── headless Chrome harness (render, export, test) ─────────
async function browser(src) {
  let chromium; try { ({ chromium } = await import('playwright-core')); } catch { die('npm install (playwright-core) first'); }
  const exe = process.env.TSVG_CHROME;
  const b = await chromium.launch(exe ? { executablePath: exe } : { channel: 'chrome' }).catch((e) => die('cannot start Chrome (' + e.message.split('\n')[0] + '); set TSVG_CHROME'));
  const page = await b.newPage();
  await page.route('http://tsvg.local/**', async (route) => {
    const p = decodeURIComponent(new URL(route.request().url()).pathname.slice(1));
    if (p === '__harness.html') return route.fulfill({ contentType: 'text/html', body: HARNESS });
    if (p.startsWith('__web/')) return route.fulfill({ contentType: 'text/javascript', body: readFileSync(join(ROOT, 'web', p.slice(6))) });
    if (p.startsWith('__file/')) { const f = resolve(p.slice(7)); return existsSync(f) ? route.fulfill({ body: readFileSync(f) }) : route.fulfill({ status: 404 }); }
    const data = src && src.get(p); if (!data) return route.fulfill({ status: 404, body: 'not found' });
    route.fulfill({ body: data });
  });
  await page.goto('http://tsvg.local/__harness.html');
  if (src) { const err = await page.evaluate((x) => window.setup(x), src.xml); if (err) die(err); }
  return { b, page };
}
const HARNESS = `<!doctype html><meta charset="utf-8"><body style="margin:0;background:#000">
<script src="/__web/tsvg-core.js"></script><script src="/__web/tsvg-zip.js"></script><script>
let doc, images = {}; const cv = document.createElement('canvas'); document.body.appendChild(cv);
window.setup = async (xml) => {
  try { doc = TSVG.parse(xml); } catch (e) { return e.message; }
  await Promise.all(doc.fonts.map(async (f) => { const ff = new FontFace(f.family, 'url(/' + f.src + ')', { weight: f.weight, style: f.style }); await ff.load(); document.fonts.add(ff); }));
  await Promise.all(Object.entries(doc.assets).filter(([, a]) => a.type === 'image').map(([id, a]) => new Promise((ok) => { const im = new Image(); im.onload = im.onerror = ok; im.src = '/' + a.src; images[id] = images[a.src] = im; })));
  await document.fonts.ready; return null;
};
window.meta = () => ({ duration: doc.duration, layouts: doc.layouts, defaults: TSVG.defaults(doc), plan: null });
window.frame = (t, opts, layoutId, width, type, q, cc) => {
  const L = doc.layouts.find((l) => l.id === layoutId) || doc.layouts[0];
  const w = Math.round(width || L.w), h = Math.round(w * L.h / L.w);
  if (cv.width !== w || cv.height !== h) { cv.width = w; cv.height = h; }
  const ctx = cv.getContext('2d'); ctx.setTransform(w / L.w, 0, 0, w / L.w, 0, 0);
  const o = Object.assign(TSVG.defaults(doc), opts);
  TSVG.renderFrame(ctx, doc, t, o, L, images);
  if (cc) burnCaption(ctx, t, o, L);
  return cv.toDataURL(type || 'image/png', q || 0.92);
};
// captions burned into exported video (--captions): same look as the web player
function burnCaption(ctx, t, o, L) {
  const ln = TSVG.sayLines(doc, o).find((l) => t >= l.start && t < l.start + l.dur + 0.3); if (!ln) return;
  const size = Math.round(Math.min(L.w, L.h) * 0.034), pad = size * 0.45, maxw = L.w * 0.8;
  ctx.save(); ctx.font = '500 ' + size + "px 'Inter', 'Noto Sans Gujarati', system-ui, sans-serif"; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
  const words = ln.text.split(' '); const lines = []; let cur = '';
  for (const w of words) { const tr = cur ? cur + ' ' + w : w; if (ctx.measureText(tr).width > maxw && cur) { lines.push(cur); cur = w; } else cur = tr; } lines.push(cur);
  const lh = size * 1.35; const y0 = L.h - L.h * 0.07 - (lines.length - 1) * lh;
  lines.forEach((s, i) => { const w = ctx.measureText(s).width + pad * 2; const y = y0 + i * lh; ctx.fillStyle = 'rgba(0,0,0,0.72)'; ctx.beginPath(); ctx.roundRect(L.w / 2 - w / 2, y - lh / 2, w, lh, size * 0.2); ctx.fill(); ctx.fillStyle = '#fff'; ctx.fillText(s, L.w / 2, y); });
  ctx.restore();
}
window.compare = async (a, b, tol) => {
  const load = (u) => new Promise((ok, no) => { const i = new Image(); i.onload = () => ok(i); i.onerror = no; i.src = u; });
  const [A, B] = await Promise.all([load(a), load(b)]);
  if (A.width !== B.width || A.height !== B.height) return { size: true, ratio: 1 };
  const get = (im) => { const c = document.createElement('canvas'); c.width = im.width; c.height = im.height; const x = c.getContext('2d'); x.drawImage(im, 0, 0); return [c, x, x.getImageData(0, 0, c.width, c.height)]; };
  const [, , da] = get(A); const [dc, dx, db] = get(B); const out = dx.createImageData(dc.width, dc.height); let bad = 0;
  for (let i = 0; i < da.data.length; i += 4) {
    const d = Math.max(Math.abs(da.data[i] - db.data[i]), Math.abs(da.data[i + 1] - db.data[i + 1]), Math.abs(da.data[i + 2] - db.data[i + 2]));
    const off = d > (tol || 40); if (off) bad++;
    out.data[i] = off ? 255 : db.data[i] * 0.3; out.data[i + 1] = off ? 0 : db.data[i + 1] * 0.3; out.data[i + 2] = off ? 80 : db.data[i + 2] * 0.3; out.data[i + 3] = 255;
  }
  dx.putImageData(out, 0, 0);
  return { ratio: bad / (da.data.length / 4), diff: dc.toDataURL('image/png') };
};
</script>`;
const fromDataURL = (u) => Buffer.from(u.slice(u.indexOf(',') + 1), 'base64');

async function render() {
  const src = await openSource(pos[0]); const doc = TSVG.parse(src.xml);
  const t = +flag('t', 0); const L = layoutOf(doc); const opts = optsFromFlags(doc);
  const { b, page } = await browser(src);
  const url = await page.evaluate(([t, o, l, w]) => window.frame(t, o, l, w), [t, opts, L.id, +flag('width', L.w)]).catch((e) => { b.close(); die('render t=' + t + ': ' + e.message.split('\n')[0].replace(/^page.evaluate: Error: /, '')); });
  const out = flag('o', 'frame.png'); writeFileSync(out, fromDataURL(url)); await b.close();
  console.log(out);
}

// ───────── export: frames from Chrome → ffmpeg, audio mixed from the plan ─────────
async function exportMp4() {
  const src = await openSource(pos[0]); const doc = TSVG.parse(src.xml);
  const L = layoutOf(doc); const opts = optsFromFlags(doc); const fps = +flag('fps', 30);
  const width = +flag('width', L.w) & ~1; const height = Math.round((width * L.h) / L.w) & ~1;
  const out = resolve(flag('o', basename(src.path).replace(/\.tsvgz?$/, '') + '-' + Object.values(opts).join('-') + '-' + L.id + '.mp4'));
  const tmp = join(dirname(out), '.tsvg-export-' + process.pid); mkdirSync(tmp, { recursive: true });
  const n = Math.ceil(doc.duration * fps); const video = join(tmp, 'video.mp4');
  console.log(`export: ${n} frames · ${width}×${height} @ ${fps} fps · ${JSON.stringify(opts)} · ${L.id}`);
  const { b, page } = await browser(src);
  const enc = spawn('ffmpeg', ['-loglevel', 'error', '-y', '-f', 'image2pipe', '-c:v', 'mjpeg', '-framerate', String(fps), '-i', '-', '-vf', `scale=${width}:${height}`, '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-preset', 'medium', '-crf', '18', '-movflags', '+faststart', video], { stdio: ['pipe', 'inherit', 'inherit'] });
  const done = new Promise((ok, no) => enc.on('close', (c) => (c === 0 ? ok() : no(new Error('ffmpeg exit ' + c)))));
  const t0 = Date.now();
  for (let i = 0; i < n; i++) {
    const url = await page.evaluate(([t, o, l, w, cc]) => window.frame(t, o, l, w, 'image/jpeg', 0.95, cc), [i / fps, opts, L.id, width, !!flag('captions')]);
    if (!enc.stdin.write(fromDataURL(url))) await new Promise((r) => enc.stdin.once('drain', r));
    if (i % fps === 0) process.stdout.write(`\r  ${Math.round((i / n) * 100)}%`);
  }
  enc.stdin.end(); await done; await b.close();
  process.stdout.write(`\r  frames in ${((Date.now() - t0) / 1000).toFixed(1)}s\n`);
  // audio
  const plan = TSVG.audioPlan(doc, opts); const inputs = []; const chains = [];
  plan.clips.forEach((c, i) => {
    const p = TSVG.assetPath(doc, c.src); const data = src.get(p); if (!data) { console.warn('  missing audio ' + p); return; }
    const gain = (plan.mix[c.bus] == null ? 1 : plan.mix[c.bus]) * (c.vol == null ? 1 : c.vol); if (gain <= 0) return;
    const f = join(tmp, 'a' + i + extname(p)); writeFileSync(f, data);
    if (c.loop) inputs.push('-stream_loop', '-1'); inputs.push('-i', f);
    const k = inputs.filter((x) => x === '-i').length; const ms = Math.round(c.start * 1000);
    chains.push(`[${k}:a]aresample=48000,aformat=channel_layouts=stereo,atrim=0:${doc.duration - c.start},adelay=${ms}:all=1,volume=${gain.toFixed(3)}[a${k}]`);
  });
  if (chains.length) {
    const labels = chains.map((c) => c.slice(c.lastIndexOf('['))).join('');
    const graph = chains.join(';') + `;${labels}amix=inputs=${chains.length}:normalize=0:duration=longest,atrim=0:${doc.duration},apad=whole_dur=${doc.duration}[out]`;
    ff(['-i', video, ...inputs, '-filter_complex', graph, '-map', '0:v', '-map', '[out]', '-c:v', 'copy', '-c:a', 'aac', '-b:a', '160k', '-shortest', out]);
  } else ff(['-i', video, '-c', 'copy', out]);
  rmSync(tmp, { recursive: true, force: true });
  console.log(`${out} · ${(statSync(out).size / 1024 / 1024).toFixed(1)} MB · ${chains.length} audio clips`);
}

// ───────── golden-frame tests ─────────
async function test() {
  const casesFile = join(ROOT, 'tests/cases.json'); const cases = JSON.parse(readFileSync(casesFile, 'utf8'));
  const update = !!flag('update'); const gdir = join(ROOT, 'tests/golden'); const odir = join(ROOT, 'tests/out');
  mkdirSync(gdir, { recursive: true }); rmSync(odir, { recursive: true, force: true }); mkdirSync(odir, { recursive: true });
  let failed = 0; const byFile = {};
  for (const c of cases) (byFile[c.file] = byFile[c.file] || []).push(c);
  // validation of every example first
  for (const f of Object.keys(byFile)) { const s = await openSource(join(ROOT, f)); const r = TSVG.validate(s.xml, { files: { has: s.has } }); console.log(`${r.ok ? 'ok  ' : 'FAIL'} validate ${f}${r.ok ? '' : ': ' + r.errors[0]}`); if (!r.ok) failed++; }
  for (const [f, list] of Object.entries(byFile)) {
    const src = await openSource(join(ROOT, f)); const { b, page } = await browser(src);
    for (const c of list) {
      const url = await page.evaluate(([t, o, l, w]) => window.frame(t, o, l, w), [c.t, c.opts || {}, c.layout, c.width || 480]);
      const gold = join(gdir, c.name + '.png');
      if (update || !existsSync(gold)) { writeFileSync(gold, fromDataURL(url)); console.log(`new  ${c.name}`); continue; }
      const r = await page.evaluate(([a, b]) => window.compare(a, b), ['data:image/png;base64,' + readFileSync(gold).toString('base64'), url]);
      const ok = !r.size && r.ratio <= (c.tolerance || 0.003);
      if (!ok) { failed++; writeFileSync(join(odir, c.name + '.png'), fromDataURL(url)); if (r.diff) writeFileSync(join(odir, c.name + '.diff.png'), fromDataURL(r.diff)); }
      console.log(`${ok ? 'ok  ' : 'FAIL'} ${c.name} · ${(r.ratio * 100).toFixed(2)}% pixels differ${r.size ? ' (size)' : ''}`);
    }
    await b.close();
  }
  // zip round trip
  {
    const s = await openSource(join(ROOT, Object.keys(byFile)[0]));
    if (s.kind === 'file') {
      const doc = TSVG.parse(s.xml); const entries = [{ path: Zip.MAIN, data: s.xml }, ...referenced(doc).map((p) => ({ path: p, data: new Uint8Array(s.get(p)) }))];
      const z = Zip.write(entries, { deflateRaw: (x) => new Uint8Array(deflateRawSync(x)) });
      const back = await Zip.read(z, { inflateRaw: (x) => new Uint8Array(inflateRawSync(x)) });
      const ok = entries.every((e) => Buffer.compare(Buffer.from(typeof e.data === 'string' ? Buffer.from(e.data) : e.data), Buffer.from(back.get(e.path))) === 0);
      console.log(`${ok ? 'ok  ' : 'FAIL'} zip round trip · ${entries.length} files`); if (!ok) failed++;
    }
  }
  console.log(failed ? `${failed} failed (see tests/out)` : 'all passed'); process.exit(failed ? 1 : 0);
}

function serve() {
  const dir = resolve(pos[0] || ROOT); const port = +flag('port', 4380);
  const types = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png', '.ogg': 'audio/ogg', '.ttf': 'font/ttf', '.tsvg': 'application/xml', '.tsvgz': 'application/zip', '.mp4': 'video/mp4' };
  createServer((q, s) => {
    let p = join(dir, decodeURIComponent(new URL(q.url, 'http://x').pathname)); if (!p.startsWith(dir)) { s.writeHead(403); return s.end(); }
    if (existsSync(p) && statSync(p).isDirectory()) p = join(p, 'index.html');
    if (!existsSync(p)) { s.writeHead(404); return s.end('not found'); }
    const body = readFileSync(p); const type = types[extname(p)] || 'application/octet-stream';
    const m = /^bytes=(\d*)-(\d*)$/.exec(q.headers.range || ''); // Safari needs ranges for media
    if (m) { const a = m[1] ? +m[1] : body.length - +m[2]; const b = m[1] && m[2] ? Math.min(+m[2], body.length - 1) : body.length - 1; s.writeHead(206, { 'content-type': type, 'accept-ranges': 'bytes', 'content-range': `bytes ${a}-${b}/${body.length}`, 'content-length': b - a + 1 }); return s.end(body.subarray(a, b + 1)); }
    s.writeHead(200, { 'content-type': type, 'accept-ranges': 'bytes', 'content-length': body.length }); s.end(body);
  }).listen(port, '127.0.0.1', () => console.log(`http://127.0.0.1:${port}/  (spec: /spec/  playground: /playground/)`));
}

if (!cmds[cmd]) { console.log(readFileSync(fileURLToPath(import.meta.url), 'utf8').split('\n').slice(1, 13).map((l) => l.replace(/^\/\/ ?/, '')).join('\n')); process.exit(cmd ? 1 : 0); }
await cmds[cmd]();
