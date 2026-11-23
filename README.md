# TSVG: Timeseries Scalable Vector Graphics

**A video format that is a document, not pixels.** A `.tsvg` file is XML: vector shapes, text, images and sound on a timeline, plus the options a viewer may choose. An engine draws every frame live, so the same small file:

- stays **sharp at any zoom** and any screen density,
- plays in **several languages, audio mixes, themes and layouts** (portrait/landscape). The demo is 24 videos in one 13 KB document,
- has **real video controls**: timeline with chapters, ±10 s, speed, captions, scrub previews,
- contains **no HTML and no JavaScript**, so native engines (web, Flutter, …) can play it safely,
- is **cheap to make and to change**. It is easy for people and AI agents to write, and editing a line changes the video. No re-encoding.

```xml
<tsvg version="0.1" title="@title">
  <layouts><layout id="landscape" w="1920" h="1080"/><layout id="portrait" w="1080" h="1920"/></layouts>
  <options><option id="lang" default="en"><choice id="en"/><choice id="gu" label="ગુજરાતી"/></option></options>
  <themes><theme id="dark" bg="#0e1117" fg="#eef1f7" accent="#7aa2ff"/></themes>
  <strings><s id="title" en="Hello" gu="નમસ્તે"/><s id="vo1" en="Hello, world." gu="નમસ્તે, દુનિયા."/></strings>
  <timeline>
    <scene id="intro" dur="5" chapter="@title">
      <say at="0.5" text="@vo1"/>
      <text x="=W/2" y="=H/2" size="160" size.portrait="120" weight="800" align="center" text="@title" fill="$accent">
        <anim prop="opacity" from="0" to="1" dur="0.8"/>
      </text>
    </scene>
  </timeline>
</tsvg>
```

## What's here

| Path | What |
| --- | --- |
| [`spec/index.html`](spec/index.html) | The specification (TSVG 0.1 draft) |
| [`web/`](web) | Reference engine: `tsvg-core.js` (parser, expression language, renderer, validator), `tsvg-player.js` (player with controls and an audio mixer), `tsvg-zip.js` (`.tsvgz` packages). No dependencies. |
| [`cli/tsvg.mjs`](cli/tsvg.mjs) | `validate`, `info`, `pack`, `unpack`, `bake` (TTS per language), `render` (PNG), `export` (MP4), `test` (golden frames), `serve` |
| [`flutter/`](flutter) | Flutter engine and player widget |
| [`playground/`](playground) | Edit a TSVG and watch it play |
| [`examples/demo/`](examples/demo) | The demo: 6 scenes, en + gu voices, gradients, masks, clip, shadow, fonts, a photo |
| [`skill/tsvg/SKILL.md`](skill/tsvg/SKILL.md) | Agent skill: how an AI agent writes, checks and ships a TSVG video |
| [`tests/`](tests) | Conformance cases and golden frames |

## Quick start

```sh
npm install                                   # playwright-core, for render/export/test (uses your installed Chrome)
node cli/tsvg.mjs serve .                     # http://127.0.0.1:4380/playground/ and /spec/
node cli/tsvg.mjs validate examples/demo/demo.tsvg
node cli/tsvg.mjs render examples/demo/demo.tsvg -t 30 --lang gu --layout portrait -o frame.png
node cli/tsvg.mjs pack examples/demo/demo.tsvg -o demo.tsvgz
node cli/tsvg.mjs export examples/demo/demo.tsvg --lang gu --layout portrait --captions -o demo.mp4
npm test
```

Install or load from a CDN ([JSR: @panth977/tsvg](https://jsr.io/@panth977/tsvg)):

```ts
import { TSVGPlayer, TSVG, TSVGZip } from "jsr:@panth977/tsvg";            // Deno / bundlers (npx jsr add @panth977/tsvg)
import { TSVGPlayer } from "https://esm.sh/jsr/@panth977/tsvg@0.2.0";     // any browser, no build
```
```html
<script src="https://jsr.io/@panth977/tsvg/0.2.0/dist/tsvg.js"></script>  <!-- classic script: window.TSVG, TSVGZip, TSVGPlayer -->
```

Embed the player:

```html
<script src="web/tsvg-core.js"></script><script src="web/tsvg-zip.js"></script><script src="web/tsvg-player.js"></script>
<div id="v" style="width:960px;aspect-ratio:16/9"></div>
<script>new TSVGPlayer(document.getElementById('v')).open('demo.tsvgz');</script>
```

## Voices

`tsvg bake` records every `<say>` line in every language and writes a `<voices>` table (with content hashes, so only changed lines are re-recorded):

- `kokoro:<voice>`: local, open source ([kokoro-onnx](https://github.com/thewh1teagle/kokoro-onnx)). Set `TSVG_PYTHON` to a Python with `kokoro-onnx` + `soundfile`, and `TSVG_KOKORO_DIR` to the model files.
- `sarvam:<speaker>` or `sarvam:<model>@<speaker>`: [Sarvam AI](https://www.sarvam.ai) for Indian languages. Needs `SARVAM_API_KEY`.

Choose per language with `tts="…"` on the `<choice>` or `--tts gu=sarvam:shubh`.

## Status

0.1 draft. The format may change until 1.0. Web engine, CLI and Flutter engine are working. See the spec's "Not in 0.1" section for what's missing.

## License

MIT. Demo fonts (Inter, Noto Sans Gujarati) are SIL OFL 1.1.
