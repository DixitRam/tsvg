// Shared helpers for the TSVG live pages (editor/watch.html, editor/index.html). Global: TSVGLive.
//  - source scanning with byte offsets, attribute rewrites that keep the rest of the text byte-identical
//  - build(): libraries + flatten with a line map that tells the document's own elements from library ones
//  - hitTest(): topmost drawn node under a point (pixel probe per draw call), bounds(): what a source element paints
(function (root) {
  'use strict';
  const TSVG = root.TSVG;
  const OFF = 1000000; // source lines are shifted by OFF before flattening, so library elements (small lines) are told apart

  // ───────── source scanning ─────────
  const unent = (s) => s.replace(/&(#x[0-9a-f]+|#\d+|lt|gt|amp|quot|apos);/gi, (m, e) => (e[0] === '#' ? String.fromCodePoint(e[1] === 'x' || e[1] === 'X' ? parseInt(e.slice(2), 16) : +e.slice(1)) : { lt: '<', gt: '>', amp: '&', quot: '"', apos: "'" }[e.toLowerCase()]));
  const escAttr = (v, q) => String(v).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(q === "'" ? /'/g : /"/g, q === "'" ? '&apos;' : '&quot;').replace(/\n/g, '&#10;').replace(/\t/g, '&#9;');
  // every element with offsets: { name, start, openEnd, end, line, endLine, selfClose, attrs: [{ name, value, raw, nStart, vStart, vEnd, q }], parent, children, idx }
  function scan(src) {
    const starts = [0]; for (let i = 0; i < src.length; i++) if (src.charCodeAt(i) === 10) starts.push(i + 1);
    const lineAt = (i) => { let lo = 0, hi = starts.length - 1; while (lo < hi) { const m = (lo + hi + 1) >> 1; if (starts[m] <= i) lo = m; else hi = m - 1; } return lo + 1; };
    const els = []; const top = { name: '#root', children: [], attrs: [] }; const stack = [top]; let i = 0;
    while (i < src.length) {
      const lt = src.indexOf('<', i); if (lt < 0) break; i = lt;
      if (src.startsWith('<!--', i)) { const e = src.indexOf('-->', i); i = e < 0 ? src.length : e + 3; continue; }
      if (src.startsWith('<![CDATA[', i)) { const e = src.indexOf(']]>', i); i = e < 0 ? src.length : e + 3; continue; }
      if (src.startsWith('<?', i) || src.startsWith('<!', i)) { const e = src.indexOf('>', i); i = e < 0 ? src.length : e + 1; continue; }
      if (src.startsWith('</', i)) {
        const m = /^<\/([A-Za-z_][\w:.-]*)\s*>/.exec(src.slice(i, i + 200)); if (!m) { i += 2; continue; }
        const el = stack.length > 1 ? stack.pop() : null; if (el) { el.end = i + m[0].length; el.endLine = lineAt(i); }
        i += m[0].length; continue;
      }
      const m = /^<([A-Za-z_][\w:.-]*)/.exec(src.slice(i, i + 200)); if (!m) { i++; continue; }
      const el = { name: m[1], start: i, line: lineAt(i), attrs: [], children: [], parent: stack[stack.length - 1], idx: els.length };
      i += m[0].length;
      for (;;) {
        const ws = /^\s*/.exec(src.slice(i, i + 1000))[0]; i += ws.length;
        if (i >= src.length) break;
        if (src.startsWith('/>', i)) { i += 2; el.selfClose = true; el.openEnd = i; el.end = i; el.endLine = lineAt(i - 1); break; }
        if (src[i] === '>') { i++; el.openEnd = i; break; }
        const a = /^([A-Za-z_][\w:.-]*)\s*=\s*("([^"]*)"|'([^']*)')/.exec(src.slice(i, i + 200000));
        if (!a) { i++; continue; }
        const q = a[2][0]; const vStart = i + a[0].length - a[2].length + 1; const raw = a[3] != null ? a[3] : a[4];
        el.attrs.push({ name: a[1], raw, value: unent(raw), q, nStart: i, vStart, vEnd: vStart + raw.length });
        i += a[0].length;
      }
      el.parent.children.push(el); els.push(el);
      if (!el.selfClose && el.openEnd) stack.push(el);
    }
    return { els, root: top.children[0] || null, top };
  }
  const attrOf = (el, n) => el.attrs.find((a) => a.name === n);
  // rewrite one attribute (insert when missing); everything else stays byte-identical
  function setAttr(src, el, name, value) {
    const a = attrOf(el, name);
    if (a) return src.slice(0, a.vStart) + escAttr(value, a.q) + src.slice(a.vEnd);
    const last = el.attrs[el.attrs.length - 1]; const at = last ? last.vEnd + 1 : el.start + 1 + el.name.length;
    return src.slice(0, at) + ' ' + name + '="' + escAttr(value, '"') + '"' + src.slice(at);
  }
  function removeAttr(src, el, name) {
    const a = attrOf(el, name); if (!a) return src;
    let s = a.nStart; while (s > 0 && /[ \t]/.test(src[s - 1])) s--;
    if (s > 0 && /\n/.test(src[s - 1]) && !/^[ \t]*\/?>/.test(src.slice(a.vEnd + 1))) s = a.nStart; // attribute alone on its line: keep the indentation of the next
    return src.slice(0, s) + src.slice(a.vEnd + 1);
  }
  // a stable handle for an element across edits: line + tag + n-th on that line
  const keyOf = (el, sc) => ({ line: el.line, name: el.name, n: sc.els.filter((e) => e.line === el.line && e.name === el.name).indexOf(el) });
  const find = (sc, k) => (k ? sc.els.filter((e) => e.line === k.line && e.name === k.name)[k.n] || sc.els.find((e) => e.line === k.line && e.name === k.name) : null);

  // ───────── libraries / flatten ─────────
  const textCache = new Map();
  async function fetchText(u) {
    if (textCache.has(u)) return textCache.get(u);
    const p = fetch(u, { cache: 'no-store' }).then((r) => { if (!r.ok) throw new Error('HTTP ' + r.status); return r.text(); });
    textCache.set(u, p); p.catch(() => textCache.delete(u)); return p;
  }
  // { xml (what the player plays), files (lib assets: path → URL), libs, srcLine(flatLine) → source line or null (library) }
  async function build(src, base) {
    const out = { src, xml: src, files: {}, libs: null, srcLine: (l) => l, flat: null };
    if (!TSVG.needsLibs(src)) return out;
    const o = { base, fetchText };
    out.libs = await TSVG.loadLibs(src, o);
    const tree = TSVG.parseXML(src); (function off(e) { e.line += OFF; e.children.forEach(off); })(tree);
    const f = TSVG.flatten(tree, out.libs, o);
    if (f.errors.length) { const e = new Error(f.errors.map(fixLines).join('\n')); e.all = f.errors.map(fixLines); throw e; }
    out.xml = f.xml; out.files = f.files; out.flat = f;
    out.srcLine = (l) => { const s = f.lineMap[l]; return s >= OFF ? s - OFF : null; };
    return out;
  }
  const fixLines = (m) => m.replace(/\bline (\d{7,})\b/g, (x, n) => 'line ' + (+n - OFF));
  // the library a component use (<r:list>) comes from, and the component's props (name, required, dflt, doc)
  function componentInfo(sc, el, libs, base) {
    const i = el.name.indexOf(':');
    if (i < 0) { // the document's own <component> (in <defs> or at the top)
      const c = sc.els.find((e) => e.name === 'component' && (attrOf(e, 'id') || {}).value === el.name); if (!c) return null;
      return { lib: 'this document', doc: (attrOf(c, 'doc') || {}).value || '', props: ownProps(c) };
    }
    const alias = el.name.slice(0, i), id = el.name.slice(i + 1);
    const im = sc.els.find((e) => e.name === 'import' && (attrOf(e, 'as') || {}).value === alias); if (!im || !libs) return null;
    let url; try { url = TSVG.libUrl(attrOf(im, 'src').value, base, {}); } catch { return null; }
    const lib = libs[url]; if (!lib) return null;
    const d = TSVG.describeLib(lib); const c = d.components.find((x) => x.id === id); if (!c) return null;
    return { lib: d.name + ' ' + d.version, libDoc: d.doc, doc: c.doc, props: c.props };
  }
  function ownProps(c) { // same rules as the engine's propsOf
    const out = {}; const parts = []; let cur = '', q = null;
    for (const ch of (attrOf(c, 'props') || {}).value || '') { if (q) { if (ch === q) q = null; cur += ch; } else if (ch === "'" || ch === '"') { q = ch; cur += ch; } else if (ch === ',') { parts.push(cur); cur = ''; } else cur += ch; }
    parts.push(cur);
    for (const p of parts.map((x) => x.trim()).filter(Boolean)) { const m = /^([A-Za-z_][\w-]*)(\?)?(?:\s*=\s*(.*))?$/.exec(p); if (m) out[m[1]] = { name: m[1], required: !m[2] && m[3] == null, dflt: m[3] != null ? m[3].trim().replace(/^(['"])(.*)\1$/, '$2') : m[2] ? '' : null, doc: '' }; }
    for (const p of c.children.filter((x) => x.name === 'prop')) { const g = (n) => (attrOf(p, n) || {}).value; out[g('name')] = { name: g('name'), required: g('required') === '1' || (g('default') == null && g('optional') !== '1'), dflt: g('default') != null ? g('default') : g('optional') === '1' ? '' : null, doc: g('doc') || '' }; }
    return Object.values(out);
  }

  // ───────── drawing probes ─────────
  const PAINT = ['fill', 'stroke', 'fillRect', 'strokeRect', 'fillText', 'strokeText', 'drawImage', 'putImageData'];
  // the player's mapping from layout units to CSS pixels of its element
  function view(player) {
    const L = player.layout(); const W = player.el.clientWidth, H = player.el.clientHeight;
    const s = Math.min(W / L.w, H / L.h) * (player.zoom || 1);
    return { L, s, ox: (W - L.w * s) / 2 + (player.panX || 0), oy: (H - L.h * s) / 2 + (player.panY || 0) };
  }
  function render(player, ctx) {
    const L = player.layout(); player.thumbing = true; // never seek real <video> elements from a probe
    try { ctx.save(); ctx.beginPath(); ctx.rect(0, 0, L.w, L.h); ctx.clip(); ctx.__tsvgNode = null; TSVG.renderFrame(ctx, player.doc, player.t, player.opts, L, player.images); }
    catch (e) { /* the player shows render errors */ } finally { player.thumbing = false; ctx.restore(); }
  }
  let probe = null;
  // topmost drawn node at layout point (lx, ly): render the frame into a tiny canvas centred on the point and read the
  // pixels after every paint call; the last call that changed any pixel of the small window wins (so thin lines and
  // text between glyphs are easy to hit). Returns { node, k (local units per layout unit) } or null.
  function hitTest(player, lx, ly, pxPerUnit) {
    const N = 7, h = 3;
    if (!probe) { const c = document.createElement('canvas'); c.width = N; c.height = N; probe = c.getContext('2d', { willReadFrequently: true }); }
    const ctx = probe; ctx.setTransform(1, 0, 0, 1, 0, 0); ctx.globalAlpha = 1; ctx.globalCompositeOperation = 'source-over'; ctx.clearRect(0, 0, N, N);
    const s = Math.max(0.05, pxPerUnit || 1);
    ctx.setTransform(s, 0, 0, s, h - lx * s, h - ly * s);
    let prev = ctx.getImageData(0, 0, N, N).data; let top = null;
    const proto = CanvasRenderingContext2D.prototype;
    for (const m of PAINT) ctx[m] = function () {
      const r = proto[m].apply(this, arguments);
      const node = this.__tsvgNode; if (!node) { prev = this.getImageData(0, 0, N, N).data; return r; }
      const d = this.getImageData(0, 0, N, N).data;
      const diff = (i) => Math.abs(d[i] - prev[i]) + Math.abs(d[i + 1] - prev[i + 1]) + Math.abs(d[i + 2] - prev[i + 2]) + Math.abs(d[i + 3] - prev[i + 3]) > 6;
      const tf = this.getTransform(); const k = Math.sqrt(Math.abs(tf.a * tf.d - tf.b * tf.c)) / s || 1;
      for (let i = 0; i < d.length; i += 4) if (diff(i)) { top = { node, k }; break; }
      prev = d; return r;
    };
    try { render(player, ctx); } finally { for (const m of PAINT) delete ctx[m]; }
    return top;
  }
  // what the nodes matching pred(node) paint at the player's time: render twice (with and without them) and diff.
  // Returns { x, y, w, h } in layout units, or null when they paint nothing now.
  let bA = null, bB = null;
  function bounds(player, pred) {
    const L = player.layout(); const k = Math.min(1, 640 / Math.max(L.w, L.h)); const w = Math.round(L.w * k), hh = Math.round(L.h * k);
    const mk = () => { const c = document.createElement('canvas'); return c.getContext('2d', { willReadFrequently: true }); };
    if (!bA) { bA = mk(); bB = mk(); }
    const proto = CanvasRenderingContext2D.prototype; const out = [];
    for (const [ctx, skip] of [[bA, false], [bB, true]]) {
      ctx.canvas.width = w; ctx.canvas.height = hh; ctx.setTransform(k, 0, 0, k, 0, 0);
      if (skip) for (const m of PAINT) ctx[m] = function () { const n = this.__tsvgNode; if (n && pred(n)) return; return proto[m].apply(this, arguments); };
      try { render(player, ctx); } finally { for (const m of PAINT) delete ctx[m]; }
      out.push(ctx.getImageData(0, 0, w, hh).data);
    }
    const [a, b] = out; let x0 = w, y0 = hh, x1 = -1, y1 = -1;
    for (let y = 0; y < hh; y++) for (let x = 0; x < w; x++) {
      const i = (y * w + x) * 4;
      if (Math.abs(a[i] - b[i]) + Math.abs(a[i + 1] - b[i + 1]) + Math.abs(a[i + 2] - b[i + 2]) + Math.abs(a[i + 3] - b[i + 3]) > 10) { if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y; }
    }
    if (x1 < 0) return null;
    return { x: x0 / k, y: y0 / k, w: (x1 - x0 + 1) / k, h: (y1 - y0 + 1) / k };
  }

  // ───────── live server ─────────
  const params = new URLSearchParams(location.search);
  async function liveInfo() {
    if (!params.get('live')) return null;
    try { const r = await fetch('/__live/info', { cache: 'no-store' }); return r.ok ? await r.json() : null; } catch { return null; }
  }
  async function liveFiles() { try { const r = await fetch('/__live/files', { cache: 'no-store' }); return r.ok ? new Set(await r.json()) : null; } catch { return null; } }
  function events(onChange, onState) {
    const es = new EventSource('/__live/events');
    es.addEventListener('change', (e) => onChange(JSON.parse(e.data)));
    es.addEventListener('hello', () => onState && onState(true));
    es.onerror = () => onState && onState(false);
    return es;
  }
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
  const fmtT = (s) => { s = Math.max(0, s || 0); const m = Math.floor(s / 60); return m + ':' + (s % 60).toFixed(1).padStart(4, '0'); };

  root.TSVGLive = { OFF, unent, escAttr, scan, attrOf, setAttr, removeAttr, keyOf, find, fetchText, textCache, build, fixLines, componentInfo, view, hitTest, bounds, liveInfo, liveFiles, events, esc, fmtT, params };
})(window);
