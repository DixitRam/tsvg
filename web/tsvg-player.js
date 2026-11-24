// TSVG web player: the reference engine for browsers.
// The .tsvg document carries no HTML/JS; this file is the engine that plays it:
// canvas renderer, video controls modelled on native players (tap shows controls,
// centre play/pause and ±10 s, double-tap sides to skip, scrubber with chapters
// and previews, volume, settings menu with speed / captions / document options,
// fullscreen, sharp zoom) and a WebAudio mixer with voice / music / sfx buses.
// The UI lives in a shadow root, so host-page CSS can't break it and it can't leak out.
(function (root) {
  'use strict';
  const TSVG = root.TSVG;
  const fmtT = (s) => { s = Math.max(0, s); const m = Math.floor(s / 60); return m + ':' + String(Math.floor(s % 60)).padStart(2, '0'); };
  const SPEEDS = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2];

  // icons (24×24, currentColor)
  const I = {
    play: '<path d="M8 5.5v13l11-6.5z"/>',
    pause: '<path d="M7 5h3.5v14H7zM13.5 5H17v14h-3.5z"/>',
    replay: '<path d="M12 5V2L7 6l5 4V7a6 6 0 1 1-6 6H4a8 8 0 1 0 8-8z"/>',
    back: '<path d="M11.5 5V2l-5 4 5 4V7a6 6 0 1 1-6 6h-2a8 8 0 1 0 8-8z"/><text x="12" y="16.2" font-size="6.6" font-weight="700" text-anchor="middle" font-family="system-ui,sans-serif">10</text>',
    fwd: '<path d="M12.5 5V2l5 4-5 4V7a6 6 0 1 0 6 6h2a8 8 0 1 1-8-8z"/><text x="12" y="16.2" font-size="6.6" font-weight="700" text-anchor="middle" font-family="system-ui,sans-serif">10</text>',
    vol: '<path d="M4 9.5h3.5L12 5.5v13l-4.5-4H4z"/><path d="M15.5 8.5a5 5 0 0 1 0 7M18 6a8.5 8.5 0 0 1 0 12" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>',
    volLow: '<path d="M4 9.5h3.5L12 5.5v13l-4.5-4H4z"/><path d="M15.5 8.5a5 5 0 0 1 0 7" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>',
    mute: '<path d="M4 9.5h3.5L12 5.5v13l-4.5-4H4z"/><path d="M15.5 9.5l5 5m0-5l-5 5" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>',
    cc: '<rect x="3" y="5.5" width="18" height="13" rx="2.5" fill="none" stroke="currentColor" stroke-width="1.8"/><text x="12" y="15" font-size="7" font-weight="800" text-anchor="middle" font-family="system-ui,sans-serif">CC</text>',
    gear: '<path d="M12 8.5a3.5 3.5 0 1 0 0 7 3.5 3.5 0 0 0 0-7zm8.2 4.6l1.8 1.4-1.8 3.1-2.1-.8a7.5 7.5 0 0 1-1.7 1l-.3 2.2h-3.6l-.3-2.2a7.5 7.5 0 0 1-1.7-1l-2.1.8L4.6 14.5l1.8-1.4a7.7 7.7 0 0 1 0-2.2L4.6 9.5l1.8-3.1 2.1.8a7.5 7.5 0 0 1 1.7-1l.3-2.2h3.6l.3 2.2a7.5 7.5 0 0 1 1.7 1l2.1-.8 1.8 3.1-1.8 1.4a7.7 7.7 0 0 1 0 2.2z"/>',
    full: '<path d="M4 9V4h5M15 4h5v5M20 15v5h-5M9 20H4v-5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>',
    exitFull: '<path d="M9 4v5H4M20 9h-5V4M15 20v-5h5M4 15h5v5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>',
    chevron: '<path d="M9 6l6 6-6 6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>',
    left: '<path d="M15 6l-6 6 6 6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>',
    check: '<path d="M5 12.5l4.5 4.5L19 7.5" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/>',
  };
  const svg = (name, cls) => `<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"${cls ? ` class="${cls}"` : ''}>${I[name]}</svg>`;
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

  // host element only (zero specificity: any page rule wins); everything else is inside the shadow root
  const HOST_CSS = ':where(.tsvgp){display:block;position:relative;width:100%;height:100%;background:#000;overflow:hidden;border-radius:12px;outline:none}' +
    '.tsvgp.tsvgp-pfs{position:fixed!important;inset:0!important;width:100vw!important;height:100vh!important;z-index:2147483647!important;border-radius:0!important}';
  const CSS = `
  :host{-webkit-tap-highlight-color:transparent}
  .p{position:absolute;inset:0;color:#fff;font:14px/1.3 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;user-select:none;-webkit-user-select:none;overflow:hidden}
  canvas.main{position:absolute;inset:0;width:100%;height:100%;display:block;touch-action:none;cursor:default}
  .zoomed canvas.main{cursor:grab}
  button{all:unset;box-sizing:border-box;display:inline-flex;align-items:center;justify-content:center;cursor:pointer;color:#fff;border-radius:50%;flex:none}
  button:focus-visible{outline:2px solid #fff8;outline-offset:2px}
  svg{width:24px;height:24px;display:block}
  .ctl{position:absolute;inset:0;opacity:0;visibility:hidden;transition:opacity .2s,visibility 0s .2s;pointer-events:none}
  .show .ctl{opacity:1;visibility:visible;transition:opacity .15s}
  .show .ctl .hit{pointer-events:auto}
  .scrim{position:absolute;inset:0;background:linear-gradient(#0007,transparent 22%,transparent 62%,#000b)}
  .narrow .scrim{background:#0008}
  .mid{position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);display:flex;align-items:center;gap:clamp(18px,8vw,64px)}
  .mid button{width:56px;height:56px;background:#000a}
  .mid button svg{width:30px;height:30px}
  .mid [data-a=play]{width:72px;height:72px}
  .mid [data-a=play] svg{width:40px;height:40px}
  .wide .mid [data-a=back],.wide .mid [data-a=fwd]{display:none}
  .wide.playing .mid{display:none}
  .bottom{position:absolute;left:0;right:0;bottom:0;padding:0 12px 6px}
  .track{position:relative;height:28px;cursor:pointer;touch-action:none}
  .rail,.fill{position:absolute;left:0;top:12px;height:4px;border-radius:2px;transition:height .12s,top .12s}
  .rail{right:0;background:#ffffff40}
  .fill{background:#ff2d48}
  .track:hover .rail,.track:hover .fill,.drag .rail,.drag .fill{top:11px;height:6px}
  .tick{position:absolute;top:10px;width:3px;height:8px;margin-left:-1px;background:#000b;border-radius:1px}
  .knob{position:absolute;top:7px;width:14px;height:14px;margin-left:-7px;background:#ff2d48;border-radius:50%;transform:scale(.85);transition:transform .12s}
  .track:hover .knob,.drag .knob{transform:scale(1.15)}
  .tip{position:absolute;bottom:30px;transform:translateX(-50%);display:none;text-align:center;pointer-events:none}
  .tip canvas{display:block;border:2px solid #fff;border-radius:8px;background:#000}
  .tip span{display:inline-block;margin-top:5px;padding:2px 7px;background:#000c;border-radius:5px;font-size:12px;font-variant-numeric:tabular-nums;white-space:nowrap}
  .row{display:flex;align-items:center;gap:2px;height:40px}
  .row button{width:40px;height:40px;border-radius:8px}
  .row button:hover{background:#ffffff1f}
  .time{font-variant-numeric:tabular-nums;font-size:13px;margin:0 8px;white-space:nowrap}
  .chap{opacity:.8;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;min-width:0;flex:1;font-size:13px}
  .chap:empty{visibility:hidden}
  .vol{display:flex;align-items:center}
  .vol input{width:0;opacity:0;transition:width .15s,opacity .15s;margin:0;accent-color:#fff;height:4px;cursor:pointer}
  .vol:hover input,.vol:focus-within input{width:72px;opacity:1;margin:0 6px 0 2px}
  [data-a=rate]{font-size:13px;font-weight:600;width:auto!important;padding:0 8px;border-radius:8px}
  .cc-on [data-a=cc]{box-shadow:inset 0 -3px 0 -1px #ff2d48}
  .narrow .wideonly,.wideonly.hidden{display:none!important}
  .wide .narrowonly{display:none!important}
  .cc{position:absolute;left:50%;bottom:var(--ccb,16px);transform:translateX(-50%);width:max-content;max-width:86%;text-align:center;pointer-events:none;font-size:var(--ccs,16px);transition:bottom .2s}
  .show .cc{--ccb:var(--ccb-show,80px)}
  .short.show .cc{display:none}
  .cc span{background:#000c;padding:2px 8px;border-radius:4px;line-height:1.55;box-decoration-break:clone;-webkit-box-decoration-break:clone}
  .ripple{position:absolute;top:0;bottom:0;width:34%;display:flex;align-items:center;justify-content:center;gap:8px;font-weight:600;font-size:13px;opacity:0;transition:opacity .35s;pointer-events:none;background:radial-gradient(circle at var(--rx) 50%,#ffffff26 0,#ffffff12 45%,transparent 70%)}
  .ripple.l{left:0;--rx:0%} .ripple.r{right:0;--rx:100%}
  .ripple.on{opacity:1;transition:none}
  .zoomtag{position:absolute;top:10px;left:10px;background:#000b;padding:4px 10px;border-radius:14px;font-size:12px;display:none;pointer-events:auto;cursor:pointer}
  .zoomed .zoomtag{display:block}
  .menu{position:absolute;right:12px;bottom:56px;background:#1c1c1ef5;border-radius:12px;min-width:250px;max-width:calc(100% - 24px);max-height:calc(100% - 72px);overflow:auto;box-shadow:0 10px 40px #000a;display:none;padding:6px 0;pointer-events:auto;backdrop-filter:blur(6px);-webkit-backdrop-filter:blur(6px)}
  .menu.open{display:block}
  .narrow .menu{left:0;right:0;bottom:0;max-width:none;max-height:calc(100% - 8px);border-radius:16px 16px 0 0;padding:6px 0 14px}
  .narrow .menu:before{content:"";display:block;width:36px;height:4px;border-radius:2px;background:#fff5;margin:4px auto 6px}
  .menu .item{display:flex;align-items:center;gap:12px;width:100%;padding:0 14px;height:44px;border-radius:0;font-size:14px;text-align:left;justify-content:flex-start}
  .menu .item:hover{background:#ffffff14}
  .menu .item .k{flex:1}
  .menu .item .v{opacity:.7;font-size:13px}
  .menu .item svg{width:20px;height:20px;opacity:.8}
  .menu .head{font-weight:600;border-bottom:1px solid #ffffff1a;margin-bottom:4px}
  .menu .item .ck{width:20px;display:inline-flex}
  .menu .item:not(.on) .ck svg{visibility:hidden}
  .menu-bg{position:absolute;inset:0;display:none;pointer-events:auto}
  .menu-open .menu-bg{display:block}
  .narrow.menu-open .menu-bg{background:#0006}
  .err{position:absolute;left:12px;top:12px;right:12px;color:#ff6b6b;font:13px ui-monospace,monospace;pointer-events:none}`;

  class Player {
    // files: { path → URL } (e.g. blob URLs from a .tsvgz); base: URL the relative paths resolve against;
    // controls: false draws frames only (posters, thumbnails)
    constructor(host, { files = {}, base, onOptions, controls = true } = {}) {
      if (!document.getElementById('tsvgp-css')) { const st = document.createElement('style'); st.id = 'tsvgp-css'; st.textContent = HOST_CSS; document.head.appendChild(st); }
      this.host = host; this.files = files; this.base = base || (typeof location !== 'undefined' ? location.href : ''); this.onOptions = onOptions;
      this.t = 0; this.rate = 1; this.playing = false; this.cc = true; this.layoutPref = 'auto'; this.volume = 1; this.muted = false; this.controls = controls;
      this.zoom = 1; this.panX = 0; this.panY = 0; this.images = {}; this.loadedFonts = new Set(); this.lines = [];
      this.el = document.createElement('div'); this.el.className = 'tsvgp'; this.el.tabIndex = 0;
      this.el.setAttribute('role', 'region'); this.el.setAttribute('aria-label', 'Video player');
      const sr = this.el.attachShadow({ mode: 'open' });
      sr.innerHTML = `<style>${CSS}</style><div class="p">
        <canvas class="main"></canvas>
        <div class="cc"></div>
        <div class="ripple l">${svg('back')}<span>10 s</span></div><div class="ripple r"><span>10 s</span>${svg('fwd')}</div>
        <div class="menu-bg"></div>
        <div class="ctl">
          <div class="scrim"></div>
          <div class="mid">
            <button class="hit" data-a="back" aria-label="Back 10 seconds">${svg('back')}</button>
            <button class="hit" data-a="play" aria-label="Play">${svg('play')}</button>
            <button class="hit" data-a="fwd" aria-label="Forward 10 seconds">${svg('fwd')}</button>
          </div>
          <div class="bottom hit">
            <div class="track" role="slider" aria-label="Seek" tabindex="0"><div class="rail"></div><div class="fill"></div><div class="ticks"></div><div class="knob"></div><div class="tip"><canvas></canvas><span></span></div></div>
            <div class="row">
              <button class="wideonly" data-a="play2" aria-label="Play">${svg('play')}</button>
              <div class="vol"><button data-a="mute" aria-label="Mute (m)">${svg('vol')}</button><input class="wideonly" type="range" min="0" max="1" step="0.05" value="1" aria-label="Volume"></div>
              <span class="time"></span><span class="chap"></span>
              <button data-a="cc" aria-label="Captions (c)">${svg('cc')}</button>
              <button class="wideonly" data-a="rate" aria-label="Playback speed">1×</button>
              <button data-a="menu" aria-label="Settings">${svg('gear')}</button>
              <button data-a="fs" aria-label="Fullscreen (f)">${svg('full')}</button>
            </div>
          </div>
        </div>
        <div class="zoomtag" title="Reset zoom"></div>
        <div class="menu" role="menu"></div>
        <div class="err"></div>
      </div>`;
      host.appendChild(this.el);
      this.sr = sr; this.p = sr.querySelector('.p');
      this.q = (s) => sr.querySelector(s);
      this.canvas = this.q('canvas.main'); this.ctx = this.canvas.getContext('2d');
      if (!controls) { this.q('.ctl').remove(); this.q('.cc').remove(); this.q('.menu').remove(); }
      else this.wire();
      this.showControls(true);
      new ResizeObserver(() => this.draw()).observe(this.el);
    }

    url(path) { return this.files[path] || new URL(path, this.base).href; }
    async load(xml) {
      const doc = TSVG.parse(xml);
      this.doc = doc; this.opts = Object.assign(TSVG.defaults(doc), this.keepOpts(doc));
      for (const [id, a] of Object.entries(doc.assets)) {
        if (a.type !== 'image') continue;
        if (!this.images[a.src]) { const im = new Image(); im.onload = () => this.draw(); im.src = this.url(a.src); this.images[a.src] = im; }
        this.images[id] = this.images[a.src];
      }
      this.syncLines();
      await Promise.race([this.loadFonts(), new Promise((r) => setTimeout(r, 3000))]);
      this.t = Math.min(this.t, doc.duration);
      this.buildTicks(); this.syncLines(); this.renderMenu(); this.draw();
      if (this.playing) this.ensureAudio().then(() => this.syncAudio(true));
      return doc;
    }
    // .tsvgz bytes (or a URL to .tsvg / .tsvgz)
    async loadPackage(bytes) {
      const files = await root.TSVGZip.read(bytes);
      for (const u of Object.values(this.files)) if (String(u).startsWith('blob:')) URL.revokeObjectURL(u);
      this.files = {}; this.images = {}; this.loadedFonts = new Set(); if (this.clipEls) { for (const ce of this.clipEls.values()) ce.el.pause(); this.clipEls.clear(); }
      for (const [path, data] of files) if (path !== root.TSVGZip.MAIN) this.files[path] = URL.createObjectURL(new Blob([data], { type: mimeOf(path) }));
      return this.load(root.TSVGZip.text(files.get(root.TSVGZip.MAIN)));
    }
    async open(url) {
      const r = await fetch(url); if (!r.ok) throw new Error('fetch ' + url + ': ' + r.status);
      const b = new Uint8Array(await r.arrayBuffer());
      if (root.TSVGZip && root.TSVGZip.isZip(b)) return this.loadPackage(b);
      this.base = new URL(url, this.base).href; return this.load(new TextDecoder().decode(b));
    }
    async loadFonts() {
      if (typeof FontFace === 'undefined') return;
      await Promise.all(this.doc.fonts.map(async (f) => {
        const key = f.family + '|' + f.weight + '|' + f.style + '|' + f.src; if (this.loadedFonts.has(key)) return;
        try { const ff = new FontFace(f.family, 'url(' + JSON.stringify(this.url(f.src)) + ')', { weight: f.weight, style: f.style }); await ff.load(); document.fonts.add(ff); this.loadedFonts.add(key); }
        catch (e) { console.warn('font', f.family, e); }
      }));
    }
    keepOpts(doc) { const o = {}; if (this.opts) for (const op of doc.options) if (this.opts[op.id] && op.choices.some((c) => c.id === this.opts[op.id])) o[op.id] = this.opts[op.id]; return o; }

    // ── audio ──
    // One <audio> element per clip, routed through WebAudio bus gains (voice / music / sfx / custom) into a
    // master gain (the volume control). Speed belongs to the player, like any video: every element plays
    // at the player's rate, pitch preserved.
    async ensureAudio() {
      const AC = root.AudioContext || root.webkitAudioContext;
      if (!this.ac && AC) { this.ac = new AC(); this.master = this.ac.createGain(); this.master.connect(this.ac.destination); this.buses = {}; }
      if (this.ac && this.ac.state === 'suspended') await this.ac.resume().catch(() => {});
      this.buildClips(); this.applyMix();
    }
    bus(name) { if (!this.buses[name]) { const g = this.ac.createGain(); g.connect(this.master); this.buses[name] = g; } return this.buses[name]; }
    buildClips() {
      const want = new Map();
      for (const c of TSVG.audioPlan(this.doc, this.opts).clips) { const path = TSVG.assetPath(this.doc, c.src); if (path) want.set(c.bus + '|' + path + '|' + c.start, Object.assign({}, c, { path })); }
      this.clipEls = this.clipEls || new Map();
      for (const [k, ce] of this.clipEls) if (!want.has(k)) { ce.el.pause(); this.clipEls.delete(k); }
      for (const [k, c] of want) {
        if (this.clipEls.has(k)) continue;
        const url = this.url(c.path); const el = new Audio();
        el.preload = 'auto'; el.loop = !!c.loop; el.preservesPitch = el.mozPreservesPitch = el.webkitPreservesPitch = true;
        const local = /^(blob|data):/.test(url) || new URL(url, location.href).origin === location.origin;
        el.src = url;
        const ce = { el, clip: c, gain: null };
        // cross-origin media without CORS would play silent through WebAudio: keep those on element volume
        if (this.ac && local) { try { const src = this.ac.createMediaElementSource(el); const g = this.ac.createGain(); g.gain.value = c.vol == null ? 1 : c.vol; src.connect(g); g.connect(this.bus(c.bus)); ce.gain = g; } catch (e) {} }
        el.addEventListener('loadedmetadata', () => this.syncLines());
        // when the duration is unknown (streams, servers without ranges), 'ended' tells us where the clip stops
        el.addEventListener('ended', () => { if (!c.loop) ce.endedAt = c.start + el.currentTime; });
        this.clipEls.set(k, ce);
      }
    }
    applyMix() {
      const out = this.muted ? 0 : this.volume;
      if (this.master) this.master.gain.setTargetAtTime(out, this.ac.currentTime, 0.03);
      if (!this.clipEls) return;
      const mix = (this.doc && this.doc.mixes[this.opts.mix]) || {};
      const gainOf = (b) => (mix[b] == null ? 1 : mix[b]);
      if (this.ac) for (const b in this.buses) this.buses[b].gain.setTargetAtTime(gainOf(b), this.ac.currentTime, 0.05);
      for (const ce of this.clipEls.values()) if (!ce.gain) ce.el.volume = Math.min(1, Math.max(0, (ce.clip.vol == null ? 1 : ce.clip.vol) * gainOf(ce.clip.bus) * out));
    }
    // keep every element where the timeline says it should be; called each frame while playing
    syncAudio(force) {
      if (!this.clipEls) return;
      for (const ce of this.clipEls.values()) {
        const el = ce.el, c = ce.clip, d = el.duration, known = isFinite(d) && d > 0;
        let local = this.t - c.start; if (c.loop && known && local >= 0) local %= d;
        const active = this.playing && local >= 0 && (c.loop || (known ? local < d - 0.02 : !(ce.endedAt != null && this.t >= ce.endedAt - 0.02)));
        if (!active) { if (!el.paused) el.pause(); continue; }
        if (el.playbackRate !== this.rate) el.playbackRate = this.rate;
        if (el.paused) { try { el.currentTime = local; } catch (e) {} el.play().catch(() => {}); }
        else if (force || Math.abs(el.currentTime - local) > 0.2) el.currentTime = local;
      }
    }
    stopAudio() { this.syncAudio(); if (root.speechSynthesis) speechSynthesis.cancel(); }
    // spoken lines without a baked clip use on-device TTS when a voice exists for the language
    ttsCross(prev, now) {
      if (!root.speechSynthesis || this.muted) return;
      const mix = this.doc.mixes[this.opts.mix]; if (mix && mix.voice === 0) return;
      for (const l of this.lines) if (!l.clip && prev < l.start && l.start <= now) {
        const v = speechSynthesis.getVoices().find((v) => v.lang.toLowerCase().startsWith(l.lang)); if (!v) continue;
        const u = new SpeechSynthesisUtterance(l.text); u.voice = v; u.lang = v.lang; u.rate = this.rate; u.volume = this.volume; speechSynthesis.speak(u);
      }
    }
    setVolume(v) { this.volume = Math.min(1, Math.max(0, v)); if (this.volume > 0) this.muted = false; this.applyMix(); this.ui(); }
    toggleMute() { this.muted = !this.muted; if (!this.muted && this.volume === 0) this.volume = 0.5; this.applyMix(); this.ui(); }

    // ── transport ──
    async play() {
      if (this.t >= this.doc.duration - 0.05) this.t = 0;
      this.playing = true; this.p.classList.add('playing'); await this.ensureAudio();
      this.clock = performance.now(); this.syncAudio(true); this.loop(); this.ui(); this.showControls(false);
    }
    pause() { this.playing = false; this.p.classList.remove('playing'); this.stopAudio(); this.ui(); this.showControls(true); }
    toggle() { this.playing ? this.pause() : this.play(); }
    seek(t) { this.t = Math.min(this.doc.duration, Math.max(0, t)); if (this.playing) { this.clock = performance.now(); this.syncAudio(true); } this.draw(); }
    setRate(r) { this.rate = +r; this.syncAudio(true); this.ui(); }
    loop() {
      if (!this.playing) return;
      const now = performance.now(); const prev = this.t;
      this.t += ((now - this.clock) / 1000) * this.rate; this.clock = now;
      this.ttsCross(prev, this.t); this.syncAudio();
      if (this.t >= this.doc.duration) { this.t = this.doc.duration; this.draw(); return this.pause(); }
      this.draw(); requestAnimationFrame(() => this.loop());
    }

    layout() {
      const L = this.doc.layouts; const want = this.layoutPref;
      if (want !== 'auto') return L.find((l) => l.id === want) || L[0];
      const r = this.el.clientWidth / Math.max(1, this.el.clientHeight);
      return L.slice().sort((a, b) => Math.abs(Math.log(a.w / a.h / r)) - Math.abs(Math.log(b.w / b.h / r)))[0];
    }
    syncLines() {
      this.lines = TSVG.sayLines(this.doc, this.opts);
      for (const l of this.lines) { const ce = l.clip && this.clipEls && [...this.clipEls.values()].find((x) => x.clip.path === TSVG.assetPath(this.doc, l.clip)); if (ce && isFinite(ce.el.duration)) l.dur = ce.el.duration + 0.3; }
    }

    draw() {
      if (!this.doc) return;
      const dpr = root.devicePixelRatio || 1; const W = this.el.clientWidth, H = this.el.clientHeight;
      if (this.canvas.width !== Math.round(W * dpr) || this.canvas.height !== Math.round(H * dpr)) { this.canvas.width = Math.round(W * dpr); this.canvas.height = Math.round(H * dpr); }
      const L = this.layout(); const ctx = this.ctx;
      ctx.setTransform(1, 0, 0, 1, 0, 0); ctx.fillStyle = '#000'; ctx.fillRect(0, 0, this.canvas.width, this.canvas.height);
      const s = Math.min(W / L.w, H / L.h) * dpr * this.zoom;
      const ox = (W * dpr - L.w * s) / 2 + this.panX * dpr, oy = (H * dpr - L.h * s) / 2 + this.panY * dpr;
      ctx.setTransform(s, 0, 0, s, ox, oy);
      ctx.save(); ctx.beginPath(); ctx.rect(0, 0, L.w, L.h); ctx.clip();
      try { TSVG.renderFrame(ctx, this.doc, this.t, this.opts, L, this.images); this.err = null; } catch (e) { this.err = e; console.error(e); }
      ctx.restore();
      this.q('.err').textContent = this.err ? 'render error: ' + this.err.message : '';
      const narrow = W < 600;
      this.p.classList.toggle('narrow', narrow); this.p.classList.toggle('wide', !narrow); this.p.classList.toggle('short', H < 340);
      this.p.style.setProperty('--ccs', Math.max(12, Math.min(22, W * 0.024)) + 'px');
      this.p.style.setProperty('--ccb-show', (narrow ? 84 : 78) + 'px');
      this.p.classList.toggle('zoomed', this.zoom > 1.01);
      this.ui();
    }
    thumb(t) {
      const c = this.q('.tip canvas'); const L = this.layout(); const w = L.w > L.h ? 176 : 96; const h = Math.round((w * L.h) / L.w);
      c.width = w * 2; c.height = h * 2; c.style.width = w + 'px'; c.style.height = h + 'px';
      const ctx = c.getContext('2d'); ctx.setTransform((w * 2) / L.w, 0, 0, (w * 2) / L.w, 0, 0);
      try { TSVG.renderFrame(ctx, this.doc, t, this.opts, L, this.images); } catch (e) {}
    }

    ui() {
      if (!this.doc || !this.controls) return;
      const d = this.doc.duration, k = d ? this.t / d : 0, ended = !this.playing && this.t >= d - 0.05;
      this.q('.fill').style.width = k * 100 + '%'; this.q('.knob').style.left = k * 100 + '%';
      this.q('.track').setAttribute('aria-valuenow', Math.round(this.t)); this.q('.track').setAttribute('aria-valuemax', Math.round(d));
      this.q('.time').textContent = fmtT(this.t) + ' / ' + fmtT(d);
      const icon = this.playing ? 'pause' : ended ? 'replay' : 'play'; const label = this.playing ? 'Pause' : ended ? 'Replay' : 'Play';
      for (const b of this.sr.querySelectorAll('[data-a=play],[data-a=play2]')) { if (b.dataset.icon !== icon) { b.innerHTML = svg(icon); b.dataset.icon = icon; } b.setAttribute('aria-label', label); b.dataset.state = this.playing ? 'playing' : 'paused'; }
      this.q('[data-a=rate]').textContent = (this.rate === 1 ? '1' : String(this.rate)) + '×';
      this.p.classList.toggle('cc-on', this.cc);
      const vi = this.muted || this.volume === 0 ? 'mute' : this.volume < 0.5 ? 'volLow' : 'vol';
      const mb = this.q('[data-a=mute]'); if (mb.dataset.icon !== vi) { mb.innerHTML = svg(vi); mb.dataset.icon = vi; }
      mb.setAttribute('aria-label', this.muted ? 'Unmute (m)' : 'Mute (m)');
      const vr = this.q('.vol input'); if (this.sr.activeElement !== vr) vr.value = this.muted ? 0 : this.volume;
      const fsOn = !!(document.fullscreenElement || document.webkitFullscreenElement) || this.el.classList.contains('tsvgp-pfs');
      const fb = this.q('[data-a=fs]'); const fi = fsOn ? 'exitFull' : 'full'; if (fb.dataset.icon !== fi) { fb.innerHTML = svg(fi); fb.dataset.icon = fi; }
      const ch = this.doc.chapters.filter((c) => c.t <= this.t + 1e-6).pop();
      this.q('.chap').textContent = ch ? '· ' + this.str(ch.label) : '';
      const line = this.cc && this.lines.find((l) => this.t >= l.start && this.t < l.start + l.dur);
      const cc = this.q('.cc'); const want = line ? line.text : '';
      if (cc.dataset.text !== want) { cc.dataset.text = want; cc.innerHTML = want ? '<span></span>' : ''; if (want) cc.firstChild.textContent = want; }
      this.q('.zoomtag').textContent = 'Zoom ' + this.zoom.toFixed(1) + '× · tap to reset';
    }
    str(v) { return v && v[0] === '@' ? TSVG.value(v, TSVG.makeEnv(this.doc, this.opts, this.doc.layouts[0], 0), this.doc) : v; }

    // controls overlay: shown while paused; while playing, shown on demand and hidden after a few seconds
    showControls(on) {
      if (!this.controls) return;
      clearTimeout(this._hide);
      const keep = !this.playing || this.p.classList.contains('menu-open') || this._dragging;
      if (on || keep) {
        this.p.classList.add('show');
        if (this.playing && !keep) this._hide = setTimeout(() => this.showControls(false), 3000);
      } else this.p.classList.remove('show');
    }

    buildTicks() { if (this.controls) this.q('.ticks').innerHTML = this.doc.chapters.filter((c) => c.t > 0).map((c) => `<div class="tick" style="left:${(c.t / this.doc.duration) * 100}%"></div>`).join(''); }

    // settings menu: a list of rows (Speed ›, Captions, each document option ›, Layout ›), each opening a submenu
    menuRows() {
      const rows = [{ id: '__rate', label: 'Playback speed', cur: this.rate === 1 ? 'Normal' : this.rate + '×', choices: SPEEDS.map((r) => ({ id: String(r), label: r === 1 ? 'Normal' : r + '×' })), val: String(this.rate) },
        { id: '__cc', label: 'Captions', cur: this.cc ? 'On' : 'Off', choices: [{ id: 'on', label: 'On' }, { id: 'off', label: 'Off' }], val: this.cc ? 'on' : 'off' }];
      for (const o of this.doc.options) { const c = o.choices.find((x) => x.id === this.opts[o.id]); rows.push({ id: o.id, label: this.str(o.label), cur: c ? this.str(c.label) : this.opts[o.id], choices: o.choices.map((x) => ({ id: x.id, label: this.str(x.label) })), val: this.opts[o.id] }); }
      if (this.doc.layouts.length > 1) rows.push({ id: '__layout', label: 'Layout', cur: this.layoutPref === 'auto' ? 'Auto' : this.layoutPref, choices: [{ id: 'auto', label: 'Auto (fit screen)' }].concat(this.doc.layouts.map((l) => ({ id: l.id, label: l.id + ' · ' + l.w + '×' + l.h }))), val: this.layoutPref });
      return rows;
    }
    renderMenu() {
      if (!this.controls || !this.doc) return;
      const m = this.q('.menu'); const rows = this.menuRows(); const sub = this.menuSub && rows.find((r) => r.id === this.menuSub);
      if (!sub) m.innerHTML = rows.map((r) => `<button class="item" role="menuitem" data-row="${esc(r.id)}"><span class="k">${esc(r.label)}</span><span class="v">${esc(r.cur)}</span>${svg('chevron')}</button>`).join('');
      else m.innerHTML = `<button class="item head" data-back="1">${svg('left')}<span class="k">${esc(sub.label)}</span></button>` +
        sub.choices.map((c) => `<button class="item${c.id === sub.val ? ' on' : ''}" role="menuitemradio" aria-checked="${c.id === sub.val}" data-g="${esc(sub.id)}" data-c="${esc(c.id)}"><span class="ck">${svg('check')}</span><span class="k">${esc(c.label)}</span></button>`).join('');
    }
    openMenu(sub) { this.menuSub = sub || null; this.menuDirect = !!sub; this.renderMenu(); this.q('.menu').classList.add('open'); this.p.classList.add('menu-open'); this.showControls(true); }
    closeMenu() { this.q('.menu').classList.remove('open'); this.p.classList.remove('menu-open'); this.menuSub = null; this.showControls(true); }
    setOption(g, c) {
      if (g === '__layout') { this.layoutPref = c; this.zoom = 1; this.panX = this.panY = 0; }
      else if (g === '__rate') { this.setRate(+c); }
      else if (g === '__cc') { this.cc = c === 'on'; }
      else { this.opts[g] = c; this.syncLines(); if (g === 'mix') this.applyMix(); if (this.playing) this.ensureAudio().then(() => this.syncAudio(true)); }
      if (this.onOptions) this.onOptions(this.opts);
      this.renderMenu(); this.draw();
    }
    // zoom keeping the point (mx, my) — relative to the player centre — fixed on screen
    zoomAt(z, mx = 0, my = 0) {
      z = Math.min(12, Math.max(1, z)); const k = z / this.zoom;
      this.panX = mx - (mx - this.panX) * k; this.panY = my - (my - this.panY) * k; this.zoom = z;
      if (z === 1) this.panX = this.panY = 0; this.draw();
    }
    ripple(side) { const f = this.q('.ripple.' + side); f.classList.add('on'); clearTimeout(f._t); f._t = setTimeout(() => f.classList.remove('on'), 500); }
    fullscreen() {
      const doc = document, el = this.el;
      if (doc.fullscreenElement || doc.webkitFullscreenElement) return (doc.exitFullscreen || doc.webkitExitFullscreen).call(doc);
      if (el.classList.contains('tsvgp-pfs')) { el.classList.remove('tsvgp-pfs'); return this.draw(); }
      const req = el.requestFullscreen || el.webkitRequestFullscreen;
      if (req) { const r = req.call(el); if (r && r.catch) r.catch(() => { el.classList.add('tsvgp-pfs'); this.draw(); }); }
      else { el.classList.add('tsvgp-pfs'); this.draw(); } // iPhone Safari: no element fullscreen, fill the viewport instead
    }

    wire() {
      const act = {
        play: () => this.toggle(), play2: () => this.toggle(),
        back: () => { this.seek(this.t - 10); this.ripple('l'); }, fwd: () => { this.seek(this.t + 10); this.ripple('r'); },
        cc: () => { this.cc = !this.cc; this.renderMenu(); this.ui(); },
        rate: () => this.openMenu('__rate'), menu: () => (this.p.classList.contains('menu-open') ? this.closeMenu() : this.openMenu()),
        fs: () => this.fullscreen(), mute: () => this.toggleMute(),
      };
      this.sr.querySelectorAll('[data-a]').forEach((b) => b.addEventListener('click', (e) => { e.stopPropagation(); act[b.dataset.a](); this.showControls(true); }));
      const vr = this.q('.vol input');
      vr.addEventListener('input', (e) => { e.stopPropagation(); this.setVolume(+vr.value); this.showControls(true); });
      vr.addEventListener('pointerdown', (e) => e.stopPropagation());
      // menu
      const menu = this.q('.menu');
      menu.addEventListener('click', (e) => {
        e.stopPropagation(); const b = e.target.closest('button'); if (!b) return;
        if (b.dataset.back) { this.menuSub = null; this.renderMenu(); }
        else if (b.dataset.row) { this.menuSub = b.dataset.row; this.menuDirect = false; this.renderMenu(); }
        else if (b.dataset.g) { this.setOption(b.dataset.g, b.dataset.c); this.menuSub = null; this.renderMenu(); if (this.menuDirect || this.p.classList.contains('narrow')) this.closeMenu(); }
      });
      this.q('.menu-bg').addEventListener('pointerdown', (e) => { e.stopPropagation(); e.preventDefault(); this.closeMenu(); });
      // scrubber: drag (mouse or touch) with a live preview frame; hover previews too
      const track = this.q('.track'); const tip = this.q('.tip');
      const at = (e) => { const r = track.getBoundingClientRect(); return Math.min(1, Math.max(0, (e.clientX - r.left) / r.width)) * this.doc.duration; };
      const preview = (t) => {
        const r = track.getBoundingClientRect(); tip.style.display = 'block'; this.thumb(t);
        const half = (tip.offsetWidth || 180) / 2; tip.style.left = Math.min(r.width - half, Math.max(half, (t / this.doc.duration) * r.width)) + 'px';
        const ch = this.doc.chapters.filter((c) => c.t <= t).pop(); tip.querySelector('span').textContent = fmtT(t) + (ch ? ' · ' + this.str(ch.label) : '');
      };
      track.addEventListener('pointerdown', (e) => { e.stopPropagation(); this._dragging = true; this.p.classList.add('drag'); track.setPointerCapture(e.pointerId); this.seek(at(e)); preview(at(e)); this.showControls(true); });
      track.addEventListener('pointermove', (e) => { const t = at(e); if (this._dragging) this.seek(t); if (this._dragging || e.pointerType === 'mouse') preview(t); });
      const end = () => { if (!this._dragging) return; this._dragging = false; this.p.classList.remove('drag'); tip.style.display = 'none'; this.showControls(true); };
      track.addEventListener('pointerup', end); track.addEventListener('pointercancel', end);
      track.addEventListener('pointerleave', () => { if (!this._dragging) tip.style.display = 'none'; });
      track.addEventListener('keydown', (e) => { if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') { e.preventDefault(); e.stopPropagation(); this.seek(this.t + (e.key === 'ArrowLeft' ? -5 : 5)); } });
      // the video surface. Touch: tap shows/hides the controls, double-tap a side skips 10 s.
      // Mouse: click plays/pauses, double-click toggles fullscreen, moving shows the controls.
      // Wheel / pinch zooms (re-rendered, never blurry); drag pans while zoomed.
      const surface = this.p; let lastTap = 0, lastX = 0, pan = null, pinch = null; const pts = new Map();
      const inUi = (e) => e.composedPath().some((n) => n.classList && (n.classList.contains('hit') || n.classList.contains('menu') || n.classList.contains('zoomtag')));
      surface.addEventListener('pointerdown', (e) => {
        if (inUi(e)) return;
        pts.set(e.pointerId, e);
        if (pts.size === 2) { const [a, b] = [...pts.values()]; pinch = { d: Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY), z: this.zoom }; pan = null; }
        else pan = { x: e.clientX, y: e.clientY, px: this.panX, py: this.panY, moved: false, type: e.pointerType };
      });
      surface.addEventListener('pointermove', (e) => {
        if (e.pointerType === 'mouse' && !pts.size) { this.showControls(true); return; }
        if (!pts.has(e.pointerId)) return; pts.set(e.pointerId, e);
        if (pinch && pts.size === 2) { const [a, b] = [...pts.values()]; this.zoom = Math.min(12, Math.max(1, (pinch.z * Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY)) / pinch.d)); if (this.zoom === 1) this.panX = this.panY = 0; this.draw(); return; }
        if (pan) { const dx = e.clientX - pan.x, dy = e.clientY - pan.y; if (Math.abs(dx) + Math.abs(dy) > 6) pan.moved = true; if (this.zoom > 1 && pan.moved) { this.panX = pan.px + dx; this.panY = pan.py + dy; this.draw(); } }
      });
      const up = (e) => {
        if (!pts.has(e.pointerId)) return; pts.delete(e.pointerId);
        if (pinch) { if (!pts.size) pinch = null; return; }
        if (!pan || pan.moved || e.type === 'pointercancel') { pan = null; return; }
        const r = this.el.getBoundingClientRect(); const x = (e.clientX - r.left) / r.width; const now = performance.now(); const type = pan.type; pan = null;
        if (type === 'mouse') { // click = play/pause, double-click = fullscreen
          if (now - lastTap < 300) { clearTimeout(this._tap); act.fs(); lastTap = 0; return; }
          lastTap = now; clearTimeout(this._tap);
          this._tap = setTimeout(() => { if (this.p.classList.contains('menu-open')) this.closeMenu(); else { this.toggle(); this.showControls(true); } }, 220);
          return;
        }
        // touch / pen
        const side = x < 0.35 ? 'l' : x > 0.65 ? 'r' : '';
        if (side && now - lastTap < 320 && Math.abs(x - lastX) < 0.25) { clearTimeout(this._tap); side === 'l' ? act.back() : act.fwd(); lastTap = now; lastX = x; return; }
        lastTap = now; lastX = x; clearTimeout(this._tap);
        this._tap = setTimeout(() => {
          if (this.p.classList.contains('menu-open')) return this.closeMenu();
          if (this.p.classList.contains('show') && this.playing) this.showControls(false); else this.showControls(true);
        }, side ? 300 : 0);
      };
      surface.addEventListener('pointerup', up); surface.addEventListener('pointercancel', up);
      surface.addEventListener('pointerleave', (e) => { if (e.pointerType === 'mouse' && this.playing && !this.p.classList.contains('menu-open')) { clearTimeout(this._hide); this._hide = setTimeout(() => this.showControls(false), 600); } });
      this.canvas.addEventListener('wheel', (e) => {
        if (!e.ctrlKey && Math.abs(e.deltaY) < 1) return;
        e.preventDefault(); const r = this.el.getBoundingClientRect();
        this.zoomAt(this.zoom * Math.exp(-e.deltaY / 400), e.clientX - r.left - r.width / 2, e.clientY - r.top - r.height / 2);
      }, { passive: false });
      this.q('.zoomtag').addEventListener('click', (e) => { e.stopPropagation(); this.zoomAt(1); });
      for (const ev of ['fullscreenchange', 'webkitfullscreenchange']) document.addEventListener(ev, () => this.draw());
      this.el.addEventListener('keydown', (e) => {
        if (e.key === 'Escape' && this.p.classList.contains('menu-open')) { e.preventDefault(); e.stopPropagation(); return this.closeMenu(); }
        if (e.key === 'Escape' && this.el.classList.contains('tsvgp-pfs')) { e.preventDefault(); return this.fullscreen(); }
        const k = { ' ': 'play', k: 'play', j: 'back', ArrowLeft: 'back', l: 'fwd', ArrowRight: 'fwd', c: 'cc', f: 'fs', m: 'mute' }[e.key];
        if (k) { e.preventDefault(); act[k](); this.showControls(true); }
        else if (e.key === 'ArrowUp' || e.key === 'ArrowDown') { e.preventDefault(); this.setVolume((this.muted ? 0 : this.volume) + (e.key === 'ArrowUp' ? 0.1 : -0.1)); this.showControls(true); }
        else if (e.key === '>' || e.key === '<') { const i = SPEEDS.indexOf(this.rate); const n = SPEEDS[Math.min(SPEEDS.length - 1, Math.max(0, (i < 0 ? 3 : i) + (e.key === '>' ? 1 : -1)))]; this.setRate(n); this.renderMenu(); }
        else if (/^[0-9]$/.test(e.key)) this.seek((this.doc.duration * +e.key) / 10);
      });
    }
  }
  function mimeOf(p) {
    const e = (p.split('.').pop() || '').toLowerCase();
    return { ogg: 'audio/ogg', opus: 'audio/ogg', mp3: 'audio/mpeg', m4a: 'audio/mp4', wav: 'audio/wav', png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', webp: 'image/webp', svg: 'image/svg+xml', gif: 'image/gif', ttf: 'font/ttf', otf: 'font/otf', woff: 'font/woff', woff2: 'font/woff2' }[e] || 'application/octet-stream';
  }
  root.TSVGPlayer = Player;
})(typeof window !== "undefined" ? window : globalThis);
