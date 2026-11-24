// TSVG visual editor (editor/index.html). With `tsvg edit` it saves to disk; elsewhere (GitHub Pages) it is
// read-only and Save downloads the .tsvg. Every edit rewrites the source text (only the attribute that changed)
// and re-renders; the source text is the single state, so undo/redo are snapshots of it.
(function () {
  'use strict';
  const L$ = TSVGLive; const { esc, fmtT, attrOf } = L$;
  const $ = (id) => document.getElementById(id);
  window.TSVG_LIB_BASE = new URL('../libs/', location.href).href; // tsvg:<lib> imports resolve to this repo's libs/
  const docUrl = new URL(L$.params.get('doc') || '../examples/libs/report.tsvg', location.href).href;
  const fileName = decodeURIComponent(docUrl.split('/').pop().split('?')[0]);
  const frame = $('frame'), box = $('box'), hitEl = $('hit'), selbox = $('selbox'), srcTa = $('src');
  const player = new TSVGPlayer(frame, { base: docUrl, controls: false });
  frame.appendChild(hitEl); frame.appendChild(selbox); // above the player element

  // ───────── state ─────────
  let src = '', sc = null, built = null, live = null, files = null, savedSrc = '', layoutId = null;
  let selKey = null; const undo = [], redo = []; let lastEdit = { key: null, at: 0 };
  let validation = { errors: [], warnings: [] };
  $('name').textContent = fileName; document.title = fileName + ' · TSVG editor';

  // ───────── source edits ─────────
  // apply a new source text. coalesce: edits with the same key within 1.5 s are one undo step (typing, dragging)
  function apply(next, { coalesce = null, from = null } = {}) {
    if (next === src) return;
    const now = performance.now();
    if (!(coalesce && lastEdit.key === coalesce && now - lastEdit.at < 1500)) { undo.push({ src, sel: selKey }); if (undo.length > 300) undo.shift(); }
    lastEdit = { key: coalesce, at: now }; redo.length = 0;
    setSrc(next, from);
  }
  function setSrc(next, from) {
    src = next; sc = L$.scan(src);
    if (from !== 'source') { const st = srcTa.scrollTop; srcTa.value = src; srcTa.scrollTop = st; }
    $('dirty').classList.toggle('on', src !== savedSrc);
    $('undo').disabled = !undo.length; $('redo').disabled = !redo.length;
    rebuild(from);
  }
  function undoRedo(back) {
    const from = back ? undo : redo, to = back ? redo : undo; if (!from.length) return;
    const s = from.pop(); to.push({ src, sel: selKey }); selKey = s.sel; lastEdit = { key: null, at: 0 }; setSrc(s.src, 'undo');
  }
  const selEl = () => (sc ? L$.find(sc, selKey) : null);
  function editAttr(name, value, coalesce) { const el = selEl(); if (!el) return; apply(value == null ? L$.removeAttr(src, el, name) : L$.setAttr(src, el, name, value), { coalesce, from: 'inspector' }); }

  // ───────── build + render ─────────
  let building = false, pending = null, valTimer = null;
  async function rebuild(from) {
    if (building) { pending = from || pending || 'x'; return; } building = true;
    try {
      let b;
      try { b = await L$.build(src, docUrl); }
      catch (e) { showRenderError(e.all || [L$.fixLines(e.message)]); return; }
      let parsed = true; try { TSVG.parse(b.xml); } catch (e) { parsed = false; showRenderError([e.message]); }
      if (!parsed) return;
      built = b; Object.assign(player.files, b.files);
      try { await player.load(b.xml); } catch (e) { showRenderError([e.message]); return; }
      if (!layoutId || !player.doc.layouts.some((l) => l.id === layoutId)) layoutId = player.doc.layouts[0].id;
      player.layoutPref = layoutId; fit(); player.draw();
      showRenderError(player.err ? [player.err.message] : []);
      bar(); strip();
      if (from !== 'inspector' || !$('pane-inspector').contains(document.activeElement)) inspector();
      if (!$('pane-strings').contains(document.activeElement)) strings();
      updateBox(); hover();
    } finally {
      building = false;
      if (pending) { const p = pending; pending = null; rebuild(p); }
      clearTimeout(valTimer); valTimer = setTimeout(check, 350);
    }
  }
  function showRenderError(list) { const r = $('rerr'); r.textContent = list.slice(0, 6).join('\n'); r.classList.toggle('on', list.length > 0); }
  function check() {
    const has = files ? { has: (p) => files.has(p) || (built && p in built.files) || /^lib\//.test(p) } : undefined;
    let r; try { r = TSVG.validate(src, { libs: built && built.libs, base: docUrl, files: has }); } catch (e) { r = { errors: [e.message], warnings: [] }; }
    validation = r;
    const line = (m) => { const k = /^(?:XML )?line (\d+)/.exec(m); return k ? +k[1] : null; };
    $('pane-checks').innerHTML = (r.errors.length || r.warnings.length ? '' : `<div class="ok">ok · ${(+r.stats.duration).toFixed(1)}s · ${r.stats.scenes} scenes · ${r.stats.variants} variants</div>`) +
      r.errors.map((m) => `<div class="err" ${line(m) ? `data-line="${line(m)}"` : ''}>${esc(m)}</div>`).join('') + r.warnings.map((m) => `<div class="warn" ${line(m) ? `data-line="${line(m)}"` : ''}>${esc(m)}</div>`).join('');
    $('nchk').textContent = r.errors.length || r.warnings.length ? (r.errors.length + r.warnings.length) : '';
    $('nchk').style.color = r.errors.length ? 'var(--bad)' : r.warnings.length ? 'var(--warm)' : '';
    const il = $('issueline'); il.className = 'issueline ' + (r.errors.length ? 'err' : r.warnings.length ? 'warn' : '');
    il.textContent = r.errors.length ? `✕ ${r.errors.length} error${r.errors.length > 1 ? 's' : ''} · ${r.errors[0]}` : r.warnings.length ? `! ${r.warnings.length} warning${r.warnings.length > 1 ? 's' : ''} · ${r.warnings[0]}` : r.stats ? `✓ checks pass · ${(+r.stats.duration).toFixed(1)}s · ${r.stats.variants} variants` : '';
  }
  $('pane-checks').addEventListener('click', (e) => { const d = e.target.closest('[data-line]'); if (!d) return; const el = sc.els.find((x) => x.line === +d.dataset.line); if (el) { select(el); tab('inspector'); } });
  $('issueline').onclick = () => tab('checks');

  // ───────── stage ─────────
  const layout = () => (player.doc ? player.doc.layouts.find((l) => l.id === layoutId) || player.doc.layouts[0] : null);
  function fit() {
    const L = layout(); if (!L) return; const k = Math.min(box.clientWidth / L.w, box.clientHeight / L.h);
    const w = Math.floor(L.w * k) + 'px', h = Math.floor(L.h * k) + 'px';
    if (frame.style.width !== w || frame.style.height !== h) { frame.style.width = w; frame.style.height = h; }
  }
  new ResizeObserver(() => { fit(); player.draw(); updateBox(); }).observe(box);
  function bar() {
    const d = player.doc;
    $('layouts').innerHTML = d.layouts.length > 1 ? d.layouts.map((l) => `<button data-l="${esc(l.id)}" class="${l.id === layoutId ? 'on' : ''}" title="${l.w}×${l.h}">${esc(l.id)}</button>`).join('') : `<span class="muted">${esc(d.layouts[0].id)} ${d.layouts[0].w}×${d.layouts[0].h}</span>`;
    $('layouts').querySelectorAll('button').forEach((b) => b.onclick = () => { layoutId = b.dataset.l; player.layoutPref = layoutId; fit(); player.draw(); bar(); updateBox(); });
    const str = (v) => { try { return v && v[0] === '@' ? String(TSVG.value(v, TSVG.makeEnv(d, player.opts, d.layouts[0], 0), d)) : v; } catch { return v; } };
    $('options').innerHTML = d.options.map((o) => `<label class="muted">${esc(str(o.label) || o.id)} <select data-o="${esc(o.id)}">${o.choices.map((c) => `<option value="${esc(c.id)}" ${player.opts[o.id] === c.id ? 'selected' : ''}>${esc(str(c.label) || c.id)}</option>`).join('')}</select></label>`).join('');
    $('options').querySelectorAll('select').forEach((s) => s.onchange = () => { player.opts[s.dataset.o] = s.value; player.syncLines(); player.t = Math.min(player.t, player.tl.duration); player.draw(); strip(); updateBox(); });
  }
  // timeline strip: scenes as blocks
  function sceneEls() { // flattened scene → its source element (a <scene> or the component use that made it)
    return player.tl.scenes.map((s) => { const l = built && built.srcLine(s.line); return l ? sc.els.find((e) => e.line === l && (e.name === 'scene' || e.name.includes(':'))) || sc.els.find((e) => e.line === l) : null; });
  }
  function strip() {
    const tl = player.tl, d = tl.duration || 1; const env = TSVG.makeEnv(player.doc, player.opts, layout(), 0); const se = sceneEls(); const el = selEl();
    $('strip').innerHTML = tl.scenes.map((s, i) => {
      const ch = tl.chapters.find((c) => Math.abs(c.t - s.start) < 1e-6); let label = ''; try { label = ch ? String(TSVG.value(ch.label, env, player.doc)) : ''; } catch {}
      const src = se[i]; const has = el && src && el.start >= src.start && el.start < (src.end || src.openEnd);
      return `<div class="sc${has ? ' has' : ''}" data-i="${i}" style="left:calc(${(s.start / d) * 100}% + 1px);width:calc(${(s.dur / d) * 100}% - 2px)" title="${esc(s.id)} · ${fmtT(s.start)} – ${fmtT(s.start + s.dur)}${src ? ' · line ' + src.line : ''}">${esc(label || (src && src.name !== 'scene' ? '<' + src.name + '>' : s.id))}<small>${fmtT(s.start)} · ${s.dur.toFixed(1)}s</small></div>`;
    }).join('') + '<div class="head" id="head"></div>';
    tick(true);
  }
  {
    const st = $('strip'); let drag = false;
    const at = (e) => { const r = st.getBoundingClientRect(); return Math.max(0, Math.min(1, (e.clientX - r.left) / r.width)) * player.tl.duration; };
    st.addEventListener('pointerdown', (e) => { if (!player.doc) return; drag = true; st.setPointerCapture(e.pointerId); if (player.playing) player.pause(); player.seek(at(e)); updateBox(); });
    st.addEventListener('pointermove', (e) => { if (drag) { player.seek(at(e)); updateBoxSoon(); } });
    st.addEventListener('pointerup', () => { drag = false; updateBox(); });
    st.addEventListener('dblclick', (e) => { const b = e.target.closest('.sc'); if (!b) return; const el = sceneEls()[+b.dataset.i]; if (el) select(el); });
  }
  let curScene = -2, wasPlaying = false;
  function tick(force) {
    if (!player.doc) return;
    const tl = player.tl; $('time').textContent = fmtT(player.t) + ' / ' + fmtT(tl.duration);
    const h = $('head'); if (h) h.style.left = (player.t / (tl.duration || 1)) * 100 + '%';
    const i = tl.scenes.findIndex((s) => player.t >= s.start - 1e-6 && player.t < s.start + s.dur);
    if (i !== curScene || force) { curScene = i; $('strip').querySelectorAll('.sc').forEach((b) => b.classList.toggle('cur', +b.dataset.i === i)); }
    if (player.playing !== wasPlaying || force) { wasPlaying = player.playing; $('play').textContent = player.playing ? '❚❚ Pause' : '▶ Play'; if (!player.playing) updateBox(); }
  }
  (function loop() { tick(); if (player.playing) updateBoxSoon(); requestAnimationFrame(loop); })();
  const seekScene = (dir) => { const s = player.tl.scenes; let i = s.findIndex((x) => player.t >= x.start - 1e-6 && player.t < x.start + x.dur); i = Math.max(0, Math.min(s.length - 1, (i < 0 ? s.length : i) + dir)); player.seek(s[i].start + Math.min(1, s[i].dur * 0.5)); updateBox(); };
  $('play').onclick = () => { player.toggle(); };
  $('prev').onclick = () => seekScene(-1); $('next').onclick = () => seekScene(1);

  // ───────── selection ─────────
  // which source element drew a flattened node: its mapped line, then the element on that line that matches it best
  function elementFor(node) {
    const line = built && built.srcLine(node.line); if (!line) return null;
    const cands = sc.els.filter((e) => e.line === line); if (!cands.length) return null;
    const comp = cands.find((e) => e.name.includes(':') || (sc.els.some((c) => c.name === 'component' && (attrOf(c, 'id') || {}).value === e.name)));
    if (built.flat && comp && node.type !== comp.name) return comp;
    const score = (e) => (e.name === node.type ? 100 : 0) + e.attrs.filter((a) => node.a && node.a[a.name] === a.value).length - e.attrs.filter((a) => node.a && node.a[a.name] != null && node.a[a.name] !== a.value).length * 2;
    return cands.slice().sort((a, b) => score(b) - score(a))[0];
  }
  function sameEl(node, el) { // does this flattened node belong to source element el?
    const line = built && built.srcLine(node.line); if (!line) return false;
    if (line < el.line || line > (el.endLine || el.line)) return false;
    if (line !== el.line || el.endLine > el.line) return true;
    const others = sc.els.filter((e) => e.line === line && e !== el && !(e.start > el.start && e.start < el.end));
    return !others.length || elementFor(node) === el;
  }
  function select(el) {
    selKey = el ? L$.keyOf(el, sc) : null; inspector(); updateBox(); strip(); hover();
  }
  let boxT = null;
  function updateBoxSoon() { if (!boxT) boxT = setTimeout(() => { boxT = null; updateBox(); }, 180); }
  function updateBox() {
    const el = selEl(); if (!el || !player.doc || ['tsvg', 'timeline'].includes(el.name)) { selbox.style.display = 'none'; return; }
    const b = L$.bounds(player, (n) => sameEl(n, el)); if (!b) { selbox.style.display = 'none'; return; }
    const v = L$.view(player); const pad = 3;
    Object.assign(selbox.style, { display: 'block', left: v.ox + b.x * v.s - pad + 'px', top: v.oy + b.y * v.s - pad + 'px', width: b.w * v.s + pad * 2 + 'px', height: b.h * v.s + pad * 2 + 'px' });
    selbox.classList.toggle('below', v.oy + b.y * v.s < 24);
    selbox.firstChild.textContent = '<' + el.name + '> line ' + el.line;
  }

  // ───────── moving ─────────
  const NUM = /^\s*-?\d+(\.\d+)?\s*$/;
  // { keys, vals } when the element can move by dragging, else { why }
  function movable(el) {
    if (!el) return { why: '' };
    const p = el.parent;
    if (p && ['row', 'col', 'grid'].includes(p.name)) return { why: `placed by its <${p.name}> (line ${p.line}): move the container instead` };
    let keys = el.name === 'line' ? ['x1', 'y1', 'x2', 'y2'] : ['x', 'y'];
    const info = isComp(el) ? L$.componentInfo(sc, el, built && built.libs, docUrl) : null;
    if (isComp(el)) {
      const names = info ? info.props.map((p) => p.name) : [];
      keys = keys.filter((k) => names.includes(k) || attrOf(el, k));
      if (!keys.length) return { why: `<${el.name}> has no x / y props: the component places itself` };
    } else if (['scene', 'tsvg', 'timeline', 'say', 'anim', 'keys', 'sfx', 'layouts', 'layout', 'strings', 's', 'assets', 'asset', 'defs', 'import', 'option', 'options', 'choice', 'theme', 'themes', 'voices', 'voice', 'music', 'mix', 'mixes', 'font'].includes(el.name) || el.parent && ['defs', 'head'].includes(el.parent.name)) return { why: `<${el.name}> is not drawn at a position` };
    const L = layout(); const cur = new Set([L && L.id, ...Object.values(player.opts || {})].filter(Boolean));
    const vals = {};
    for (const k of keys) {
      const a = attrOf(el, k);
      if (a && !NUM.test(a.value)) return { why: `${k}="${a.value}" is an expression: edit it in the field below` };
      const v = el.attrs.find((x) => x.name.startsWith(k + '.') && cur.has(x.name.slice(k.length + 1)));
      if (v) return { why: `${v.name}="${v.value}" applies in this ${L && v.name.endsWith(L.id) ? 'layout' : 'variant'}: edit the variant in the field below` };
      const an = el.children.find((c) => (c.name === 'anim' || c.name === 'keys') && (attrOf(c, 'prop') || {}).value === k);
      if (an) return { why: `${k} is animated by <${an.name} prop="${k}"> (line ${an.line}): edit its values instead` };
      let base = 0;
      if (!a && info) { const pr = info.props.find((x) => x.name === k); const d = pr && pr.dflt != null ? String(pr.dflt) : '';
        if (d && !NUM.test(d)) return { why: `${k} is not set and its default "${d}" is an expression: set ${k} below first` }; base = d ? +d : 0; }
      vals[k] = a ? +a.value : base;
    }
    return { keys, vals };
  }
  function moveBy(el, dx, dy, base) { // base: values at drag start
    const m = movable(el); if (!m.keys) return;
    let s = src;
    for (const k of m.keys) {
      const d = /^x/.test(k) ? dx : dy; const v = Math.round((base ? base[k] : m.vals[k]) + d);
      const e = L$.find(L$.scan(s), selKey); s = L$.setAttr(s, e, k, String(v));
    }
    apply(s, { coalesce: 'move:' + JSON.stringify(selKey), from: 'move' });
  }
  const isComp = (el) => el.name.includes(':') || sc.els.some((c) => c.name === 'component' && (attrOf(c, 'id') || {}).value === el.name);
  function hover() { const m = movable(selEl()); hitEl.classList.toggle('movable', !!m.keys); }

  // canvas: click selects the topmost node under the pointer, drag moves it
  let drag = null;
  const layoutPt = (e) => { const r = player.el.getBoundingClientRect(); const v = L$.view(player); return { x: (e.clientX - r.left - v.ox) / v.s, y: (e.clientY - r.top - v.oy) / v.s, v }; };
  hitEl.addEventListener('pointerdown', (e) => {
    if (!player.doc || e.button !== 0) return; hitEl.focus();
    if (player.playing) player.pause();
    const p = layoutPt(e); const hit = L$.hitTest(player, p.x, p.y, p.v.s * (window.devicePixelRatio || 1));
    let el = hit ? elementFor(hit.node) : null;
    if (hit && !el) toast('drawn by a library (backdrop / overlay): nothing to edit in this document');
    // clicking inside the current selection keeps it (so a component or group can be dragged by any part)
    const cur = selEl(); if (cur && hit && sameEl(hit.node, cur)) el = cur;
    if (el !== cur) select(el); else if (!el) select(null);
    if (!el) return;
    const m = movable(el);
    drag = { x0: e.clientX, y0: e.clientY, s: p.v.s, k: isComp(el) ? 1 : (hit ? hit.k : 1), base: m.vals, ok: !!m.keys, moved: false, why: m.why };
    hitEl.setPointerCapture(e.pointerId);
  });
  hitEl.addEventListener('pointermove', (e) => {
    if (!drag) return; const dx = e.clientX - drag.x0, dy = e.clientY - drag.y0;
    if (!drag.moved && Math.abs(dx) + Math.abs(dy) < 4) return;
    if (!drag.ok) { if (!drag.moved && drag.why) toast('not moved: ' + drag.why); drag.moved = true; return; }
    drag.moved = true; const k = drag.s * drag.k;
    if (drag.raf) return; drag.raf = requestAnimationFrame(() => { if (!drag) return; drag.raf = 0; moveBy(selEl(), dx / k, dy / k, drag.base); });
  });
  const endDrag = () => { if (drag && drag.raf) cancelAnimationFrame(drag.raf); if (drag && drag.moved && drag.ok) lastEdit = { key: null, at: 0 }; drag = null; };
  hitEl.addEventListener('pointerup', (e) => { if (drag && drag.moved && drag.ok) { const dx = e.clientX - drag.x0, dy = e.clientY - drag.y0, k = drag.s * drag.k; moveBy(selEl(), dx / k, dy / k, drag.base); } endDrag(); });
  hitEl.addEventListener('pointercancel', endDrag);

  // ───────── inspector ─────────
  function inspector() {
    const pane = $('pane-inspector'); const el = selEl();
    if (!el) {
      pane.innerHTML = `<div class="empty"><p>Click anything on the canvas to select the element that draws it. Drag to move it (plain <code>x</code>/<code>y</code> numbers only).</p>
        <p><kbd>space</kbd> play · <kbd>[</kbd> <kbd>]</kbd> scenes · <kbd>←</kbd> <kbd>→</kbd> nudge (<kbd>⇧</kbd> ×10) · <kbd>esc</kbd> deselect · <kbd>⌘Z</kbd> undo · <kbd>⇧⌘Z</kbd> redo · <kbd>⌘S</kbd> save · <kbd>alt 1–4</kbd> tabs</p>
        <p>Double-click a scene in the strip to select it.</p></div>`;
      return;
    }
    const chain = []; for (let p = el; p && p.name !== '#root'; p = p.parent) chain.unshift(p);
    const info = isComp(el) ? L$.componentInfo(sc, el, built && built.libs, docUrl) : null;
    const m = movable(el);
    let h = `<div class="crumbs">${chain.map((p, i) => `<a data-up="${chain.length - 1 - i}" title="line ${p.line}">${esc(p.name)}${(attrOf(p, 'id') ? '#' + esc(attrOf(p, 'id').value) : '')}</a>`).join('<span>›</span>')}</div>`;
    h += `<div class="el-head"><code>&lt;${esc(el.name)}&gt;</code><span class="muted">line ${el.line}${info ? ' · ' + esc(info.lib) : ''}</span></div>`;
    if (info && info.doc) h += `<p class="doc">${esc(info.doc)}</p>`;
    if (m.keys) h += `<div class="note ok">Drag on the canvas or use the arrow keys to move (${m.keys.join(', ')}).</div>`;
    else if (m.why && !['scene', 'tsvg', 'timeline'].includes(el.name)) h += `<div class="note">Not movable: ${esc(m.why)}.</div>`;
    const rows = []; const seen = new Set();
    if (info) for (const p of info.props) { const a = attrOf(el, p.name); seen.add(p.name); rows.push({ name: p.name, value: a ? a.value : null, prop: p }); }
    for (const a of el.attrs) if (!seen.has(a.name)) rows.push({ name: a.name, value: a.value, prop: null, extra: !!info });
    h += `<div class="fields">` + rows.map(field).join('') + `</div>`;
    h += `<div class="add"><input type="text" id="addname" placeholder="attribute" style="max-width:120px"><input type="text" id="addval" placeholder="value"><button id="addbtn">Add</button></div>`;
    const kids = el.children.filter((c) => !['#text'].includes(c.name));
    if (kids.length) h += `<h4>Children</h4><div class="crumbs" style="flex-direction:column">${kids.slice(0, 60).map((c) => `<a data-child="${c.idx}">&lt;${esc(c.name)}${attrOf(c, 'id') ? ' id="' + esc(attrOf(c, 'id').value) + '"' : attrOf(c, 'text') ? ' text="' + esc(attrOf(c, 'text').value.slice(0, 30)) + '"' : ''}&gt; <span class="muted">line ${c.line}</span></a>`).join('')}</div>`;
    pane.innerHTML = h;
    pane.querySelectorAll('[data-up]').forEach((a) => a.onclick = () => { let p = el; for (let i = +a.dataset.up; i > 0; i--) p = p.parent; select(p); });
    pane.querySelectorAll('[data-child]').forEach((a) => a.onclick = () => select(sc.els[+a.dataset.child]));
    pane.querySelectorAll('[data-attr]').forEach((inp) => {
      const name = inp.dataset.attr;
      inp.addEventListener('input', () => {
        let v = inp.value; if (inp.type === 'color') { const t = pane.querySelector(`input[type=text][data-attr="${CSS.escape(name)}"]`); const old = t ? t.value : ''; v = v + (old.length === 9 ? old.slice(7) : ''); if (t) t.value = v; }
        else { const c = pane.querySelector(`input[type=color][data-attr="${CSS.escape(name)}"]`); if (c && /^#[0-9a-f]{3,8}$/i.test(v)) c.value = hex6(v); }
        if (v === '' && inp.dataset.unset === '1') return;
        editAttr(name, v, 'attr:' + name + ':' + JSON.stringify(selKey));
        const lab = pane.querySelector(`label[data-for="${CSS.escape(name)}"]`); if (lab) lab.classList.remove('unset');
      });
    });
    pane.querySelectorAll('[data-del]').forEach((b) => b.onclick = () => { editAttr(b.dataset.del, null); inspector(); });
    const add = () => { const n = $('addname').value.trim(), v = $('addval').value; if (!/^[A-Za-z_][\w:.-]*$/.test(n)) return toast('attribute names are letters, digits, - _ . :'); if (attrOf(el, n)) return toast(n + ' is already set'); editAttr(n, v); inspector(); };
    $('addbtn').onclick = add; $('addval').onkeydown = (e) => { if (e.key === 'Enter') add(); };
  }
  const hex6 = (v) => { v = v.slice(1); if (v.length <= 4) v = v.slice(0, 3).split('').map((c) => c + c).join(''); return '#' + v.slice(0, 6).toLowerCase(); };
  function field(r) {
    const v = r.value, set = v != null, p = r.prop; const n = esc(r.name);
    const ph = p ? (p.required ? 'required' : p.dflt != null && p.dflt !== '' ? 'default: ' + p.dflt : 'not set') : '';
    let ctl;
    if (set && /^#[0-9a-f]{3,8}$/i.test(v.trim())) ctl = `<input type="color" data-attr="${n}" value="${hex6(v.trim())}" aria-label="${n} colour"><input type="text" data-attr="${n}" value="${esc(v)}">`;
    else if (set && NUM.test(v)) ctl = `<input type="number" data-attr="${n}" value="${esc(v.trim())}" step="${/\./.test(v) ? 'any' : '1'}">`;
    else if ((set && (v.length > 48 || v.includes('\n'))) || (!set && p && /items|code|text|say|before|after/.test(r.name))) ctl = `<textarea class="v" data-attr="${n}" ${set ? '' : 'data-unset="1"'} placeholder="${esc(ph)}" rows="${Math.min(6, Math.max(2, Math.ceil(((v || '').length) / 42)))}">${esc(v || '')}</textarea>`;
    else ctl = `<input type="text" data-attr="${n}" ${set ? `value="${esc(v)}"` : 'data-unset="1"'} placeholder="${esc(ph)}">`;
    const doc = p && p.doc ? `<small>${esc(p.doc)}</small>` : r.extra ? '<small>variant / not a declared prop</small>' : '';
    return `<label data-for="${n}" class="${set ? '' : 'unset'} ${p && p.required ? 'req' : ''}" title="${n}">${n}</label><div class="ctl"><div>${ctl}</div>${doc}</div>` +
      (set ? `<button class="x" data-del="${n}" title="remove ${n}">×</button>` : '<span></span>');
  }

  // ───────── strings ─────────
  function strings() {
    const pane = $('pane-strings'); const block = sc && sc.els.find((e) => e.name === 'strings' && e.parent && e.parent.name === 'tsvg');
    const ss = block ? block.children.filter((c) => c.name === 's') : [];
    $('nstr').textContent = ss.length || '';
    if (!ss.length) { pane.innerHTML = '<p class="empty">This document has no <code>&lt;strings&gt;</code>. Add <code>&lt;strings&gt;&lt;s id="title" en="…"/&gt;&lt;/strings&gt;</code> in the Source tab and use it as <code>text="@title"</code>.</p>'; return; }
    const langOpt = sc.els.find((e) => e.name === 'option' && (attrOf(e, 'id') || {}).value === 'lang');
    const langs = []; if (langOpt) for (const c of langOpt.children) if (c.name === 'choice' && attrOf(c, 'id')) langs.push(attrOf(c, 'id').value);
    for (const s of ss) for (const a of s.attrs) if (a.name !== 'id' && !langs.includes(a.name)) langs.push(a.name);
    pane.innerHTML = `<table class="str"><thead><tr><th>id</th>${langs.map((l) => `<th>${esc(l)}</th>`).join('')}</tr></thead><tbody>` +
      ss.map((s) => `<tr><td title="line ${s.line}">@${esc((attrOf(s, 'id') || {}).value || '?')}</td>${langs.map((l) => { const a = attrOf(s, l); return `<td><textarea class="v" data-s="${s.idx}" data-l="${esc(l)}" placeholder="${a ? '' : 'missing'}" rows="1">${esc(a ? a.value : '')}</textarea></td>`; }).join('')}</tr>`).join('') + '</tbody></table>';
    const grow = (ta) => { ta.style.height = 'auto'; ta.style.height = Math.min(160, ta.scrollHeight + 2) + 'px'; };
    pane.querySelectorAll('textarea[data-s]').forEach(grow);
    pane.querySelectorAll('textarea[data-s]').forEach((ta) => ta.addEventListener('input', () => {
      grow(ta);
      const s0 = sc.els[+ta.dataset.s]; if (!s0) return; const key = L$.keyOf(s0, sc);
      apply(L$.setAttr(src, s0, ta.dataset.l, ta.value), { coalesce: 'str:' + JSON.stringify(key) + ta.dataset.l, from: 'strings' });
    }));
  }

  // ───────── source panel ─────────
  let srcTimer = null;
  srcTa.addEventListener('input', () => { clearTimeout(srcTimer); srcTimer = setTimeout(() => apply(srcTa.value, { coalesce: 'source', from: 'source' }), 300); });
  srcTa.addEventListener('keydown', (e) => { if (e.key === 'Tab') { e.preventDefault(); document.execCommand('insertText', false, '  '); } });
  function revealInSource(el) { // put the caret on the selected element when the Source tab opens
    if (!el) return; srcTa.focus(); srcTa.setSelectionRange(el.start, el.start);
    const lh = parseFloat(getComputedStyle(srcTa).lineHeight) || 18; srcTa.scrollTop = Math.max(0, (el.line - 5) * lh);
  }

  // ───────── tabs, save, keys ─────────
  function tab(name) {
    document.querySelectorAll('.tabs button').forEach((b) => b.classList.toggle('on', b.dataset.tab === name));
    document.querySelectorAll('.pane').forEach((p) => p.classList.toggle('on', p.id === 'pane-' + name));
    if (name === 'strings') $('pane-strings').querySelectorAll('textarea[data-s]').forEach((ta) => { ta.style.height = 'auto'; ta.style.height = Math.min(160, ta.scrollHeight + 2) + 'px'; });
    if (name === 'source') { if (srcTa.value !== src) srcTa.value = src; revealInSource(selEl()); }
  }
  document.querySelectorAll('.tabs button').forEach((b) => b.onclick = () => tab(b.dataset.tab));
  let toastT; function toast(m) { const t = $('toast'); t.textContent = m; t.classList.add('on'); clearTimeout(toastT); toastT = setTimeout(() => t.classList.remove('on'), 2600); }
  async function save() {
    clearTimeout(srcTimer); if (srcTa.value !== src && document.activeElement === srcTa) apply(srcTa.value, { from: 'source' });
    if (live && live.mode === 'edit') {
      try {
        const r = await fetch('/__live/save', { method: 'POST', headers: { 'content-type': 'text/plain;charset=utf-8', 'x-tsvg-live': '1' }, body: src });
        if (!r.ok) throw new Error(await r.text());
        savedSrc = src; $('dirty').classList.remove('on'); $('ext').classList.remove('on'); toast('saved ' + fileName); $('status').textContent = 'saved ' + new Date().toLocaleTimeString();
      } catch (e) { toast('save failed: ' + e.message); }
    } else {
      const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([src], { type: 'application/xml' })); a.download = fileName; a.click(); setTimeout(() => URL.revokeObjectURL(a.href), 1000);
      savedSrc = src; $('dirty').classList.remove('on'); toast('downloaded ' + fileName);
    }
  }
  $('save').onclick = save; $('undo').onclick = () => undoRedo(true); $('redo').onclick = () => undoRedo(false);
  window.addEventListener('beforeunload', (e) => { if (src !== savedSrc) { e.preventDefault(); e.returnValue = ''; } });
  document.addEventListener('keydown', (e) => {
    const mod = e.metaKey || e.ctrlKey; const k = e.key.toLowerCase();
    if (mod && k === 's') { e.preventDefault(); save(); return; }
    if (mod && k === 'z') { e.preventDefault(); clearTimeout(srcTimer); if (document.activeElement === srcTa && srcTa.value !== src) apply(srcTa.value, { from: 'source' }); undoRedo(!e.shiftKey); return; }
    if (mod && k === 'y') { e.preventDefault(); undoRedo(false); return; }
    if (e.altKey && /^Digit[1-4]$/.test(e.code)) { e.preventDefault(); tab(['inspector', 'strings', 'source', 'checks'][+e.code.slice(5) - 1]); return; }
    const typing = e.target.closest && e.target.closest('input,textarea,select');
    if (typing) { if (e.key === 'Escape') e.target.blur(); return; }
    if (e.key === ' ' || k === 'k') { e.preventDefault(); player.toggle(); }
    else if (e.key === '[' || e.key === ']') seekScene(e.key === ']' ? 1 : -1);
    else if (e.key === 'Escape') select(null);
    else if (e.key.startsWith('Arrow')) {
      const el = selEl(); const m = movable(el); const step = e.shiftKey ? 10 : 1;
      if (el && m.keys) { e.preventDefault(); const d = { ArrowLeft: [-step, 0], ArrowRight: [step, 0], ArrowUp: [0, -step], ArrowDown: [0, step] }[e.key]; moveBy(el, d[0], d[1]); }
      else if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') { e.preventDefault(); player.seek(player.t + (e.key === 'ArrowLeft' ? -1 : 1) * (e.shiftKey ? 0.1 : 1)); updateBox(); }
    }
  });

  // ───────── boot ─────────
  let extSrc = null;
  $('extload').onclick = () => { if (extSrc != null) { apply(extSrc, { from: 'disk' }); savedSrc = extSrc; $('dirty').classList.toggle('on', src !== savedSrc); $('ext').classList.remove('on'); } };
  async function fetchDoc() { const r = await fetch(docUrl, { cache: 'no-store' }); if (!r.ok) throw new Error('HTTP ' + r.status + ' for ' + docUrl); return r.text(); }
  (async function boot() {
    live = await L$.liveInfo();
    $('mode').textContent = live ? (live.mode === 'edit' ? 'live · saves to disk' : 'watch · read-only') : 'read-only · save downloads';
    $('mode').classList.toggle('live', !!live && live.mode === 'edit');
    $('save').textContent = live && live.mode === 'edit' ? 'Save' : 'Download';
    if (live) {
      files = await L$.liveFiles();
      L$.events(async (ev) => {
        if (ev.lib) { L$.textCache.clear(); rebuild('disk'); return; }
        const t = await fetchDoc().catch(() => null); if (t == null || t === src || t === savedSrc) return;
        if (src === savedSrc) { apply(t, { from: 'disk' }); savedSrc = t; $('dirty').classList.remove('on'); toast('reloaded from disk'); }
        else { extSrc = t; $('ext').classList.add('on'); }
      });
    }
    try { savedSrc = await fetchDoc(); } catch (e) { showRenderError([e.message]); return; }
    src = savedSrc; sc = L$.scan(src); srcTa.value = src; $('undo').disabled = $('redo').disabled = true;
    await rebuild('boot');
    if (player.doc) { const s = player.tl.scenes[0]; if (s) player.seek(Math.min(s.start + s.dur * 0.6, s.start + 3)); updateBox(); }
  })();
  window.__editor = { player, get src() { return src; }, get sel() { return selEl(); }, select, apply, save, get validation() { return validation; }, view: () => L$.view(player) }; // for tests
})();
