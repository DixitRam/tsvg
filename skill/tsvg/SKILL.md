---
name: tsvg
description: Make a TSVG video (Timeseries Scalable Vector Graphics, .tsvg/.tsvgz) instead of a video-like HTML page or an MP4. Use it when you need to show, explain, demo or walk through something as a video (tutorials, QA walkthroughs, release notes, explainers), when one video must come in several languages, audio mixes, themes or portrait/landscape, or when the user mentions TSVG.
---

# TSVG: write a video as a document

A TSVG video is one XML file. The engine draws every frame live, so you write it like HTML and it plays like a real video: timeline, chapters, ±10 s, captions, sharp zoom, and viewer options (language, audio mix, theme, layout). Don't make video-like HTML pages; make a `.tsvg`.

- Repo: `~/Dev/PROJECTS/TSVG` (github.com/Panth977/tsvg). Spec: `spec/index.html`. Full example: `examples/demo/demo.tsvg`. Read the example before your first video.
- CLI: `node ~/Dev/PROJECTS/TSVG/cli/tsvg.mjs <cmd>` (below: `tsvg`).

## Workflow
1. **Write** `work/<name>/<name>.tsvg`. Plan scenes first: one idea per scene, 5–12 s each, a `<say>` line per scene.
2. **Validate**: `tsvg validate x.tsvg`. Fix every ERROR. Warnings about missing clips go away after bake.
3. **Look**: `tsvg render x.tsvg -t <sec> -o /tmp/f.png [--layout portrait] [--lang gu]`. Open the PNG and check it, at least once per scene and in each layout. Fix overlaps, text overflow and empty frames.
4. **Bake voices**: `tsvg bake x.tsvg`. English uses local Kokoro; Gujarati and other Indian languages use Sarvam and need `SARVAM_API_KEY` (in `~/Dev/PROJECTS/Manager/packages/voice/sarvam/.env`; source it, never print it). Bake warns when a line overruns its scene; lengthen `dur` or shorten the line, then bake again (only changed lines are re-recorded).
5. **Pack**: `tsvg pack x.tsvg -o x.tsvgz` (the package includes `index.html`, so anyone can unzip it and open that page in a browser). To share outside TaskManager as one file that plays anywhere: `tsvg pack x.tsvg --html x.html`. This is the file to attach or share. TaskManager plays `.tsvgz` attachments inline.
6. **MP4 only if asked** (WhatsApp/YouTube): `tsvg export x.tsvg --lang en --layout landscape --captions -o x.mp4`.
7. **Test the engine** (only when you change engine code): `npm test` in the repo.

## Cheat sheet
```xml
<tsvg version="0.1" title="@title" font="Inter, Noto Sans Gujarati">
  <layouts><layout id="landscape" w="1920" h="1080"/><layout id="portrait" w="1080" h="1920"/></layouts>
  <options>
    <option id="lang" default="en"><choice id="en" label="English" tts="kokoro:af_heart"/><choice id="gu" label="ગુજરાતી" tts="sarvam:shubh"/></option>
    <option id="mix" default="full"><choice id="full" label="Full"/><choice id="speech" label="Speech only"/></option>
    <option id="theme" default="dark"><choice id="dark"/><choice id="light"/></option>
  </options>
  <mixes><mix id="full" voice="1" music="0.35" sfx="0.7"/><mix id="speech" voice="1" music="0" sfx="0"/></mixes>
  <themes><theme id="dark" bg="#0e1117" fg="#eef1f7" muted="#7d879a" panel="#1a1f2b" accent="#7aa2ff"/>
          <theme id="light" bg="#f6f3ec" fg="#1b1e26" muted="#6b7280" panel="#ffffff" accent="#2f5bea"/></themes>
  <strings><s id="title" en="Hello" gu="નમસ્તે"/><s id="vo1" en="…" gu="…"/></strings>
  <defs>
    <linear id="ink" x1="0" y1="0" x2="600" y2="0"><stop at="0" color="$accent"/><stop at="1" color="#ff6b9a"/></linear>
    <clip id="c"><circle r="200"/></clip>
    <mask id="wipe"><rect y="-100" h="200" w="=900*ease(T/1.5,'io')" fill="#000"/></mask>
  </defs>
  <assets><asset id="shot" src="images/shot.png"/><font family="Inter" src="fonts/Inter.ttf"/></assets>
  <timeline>
    <scene id="s1" dur="7" chapter="@title">
      <say at="0.5" text="@vo1"/>
      <text x="=W/2" y="=H/2" y.portrait="=H/2-200" size="120" weight="800" align="center" text="@title" fill="url(#ink)">
        <anim prop="opacity" from="0" to="1" dur="0.6"/>
        <anim prop="scale" from="0.9" to="1" dur="0.9" ease="back"/>
      </text>
      <image src="shot" x="=W/2" y="=H/2+120" ax="0.5" w="1200" h="675" r="24" shadow="0 20 40 #0008" at="1.5">
        <anim prop="opacity" from="0" to="1" dur="0.5"/>
      </image>
    </scene>
  </timeline>
</tsvg>
```
- Values: literal · `$token` (theme) · `@string` (current language) · `=expr` (each frame) · `"{expr}"` templates.
- Variants: `attr.portrait`, `attr.gu`, `attr.light`. The first tag that matches wins, in the order layout, then options. Use them for every position that differs between portrait and landscape.
- Nodes: `rect circle ellipse line path text image group use`. Common attributes: `fill stroke sw opacity rot scale shadow clip mask at dur when only`.
- Expression variables: `t T p W H portrait lang theme mix dur sdur`. Functions: `sin cos lerp clamp ease(k,'out') smooth fract fmt …`.
- 0.2: `repeat="n" as="i"` on any node (grids, bars, particles; `i` and `i_n` in expressions) · `<data id="x" v="1,2,3"/>` in defs + `data('x', i)`, `count('x')` · `blur="8"` · `rand(seed)`, `noise(x)` (deterministic) · morph: `<keys prop="d" v="0: M…; 2: M…"/>` with the same path commands interpolates point by point.
- 0.2.2: `s('id')` (a string inside expressions) · `arc="1"` on circle (open arc ring) · `dash="24 16"` · `sx`/`sy` (card flips) · numeric text keeps its zeros (`text="01"`) · `\=` escapes a literal leading `=`.
- Anim: `<anim prop from to at dur ease/>` (times relative to the node's `at`); `<keys prop v="0:0; 1:100"/>`; eases `linear in out io back elastic step`.

## Styles
`~/Dev/PROJECTS/TSVG/examples/styles/` has a one-minute template per explainer style (product walkthrough, collage, math, whiteboard, data story, kinetic type, social short…), with the catalog in `catalog/*.json`. Pick the closest style, copy its file next to your work, and change the content.

## Rules of thumb
- Design for both layouts: landscape 1920×1080, portrait 1080×1920. Keep 80 units of margin. Body text ≥ 40, headings 80–150.
- One `<say>` per scene; keep scene `dur` ≥ the longest language's clip plus 1 s. Gujarati usually runs 10–30 % longer.
- Captions come from `text`. Use `speak="@x_say"` when pronunciation must differ (e.g. "T. S. V. G.").
- Every user-visible string goes in `<strings>` with every language. Validate warns about missing ones.
- Raster screenshots are fine (`<image>`): put them in `images/` and frame them with `r` + `shadow`.
- No HTML, no scripts: a TSVG is data. If you need logic, use an expression or a `<fn>`.
