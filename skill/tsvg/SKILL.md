---
name: tsvg
description: Make every video report as a TSVG (Timeseries Scalable Vector Graphics, .tsvgz), never an mp4 or a video-like HTML page. Use whenever you report to Panth (done, rework, progress, explanation), explain or demo something as a video, or the user mentions TSVG. Three commands: tsvg new → edit → tsvg make; no rendering, no encoding.
---

# TSVG: video reports without rendering

A TSVG video is one XML file. The player draws it live, with timeline, captions, chapters, options and sharp zoom, so there is **nothing to render or encode**. TaskManager plays `.tsvgz` attachments inline. Never render mp4s for reports.

`tsvg` is on PATH (`~/.local/bin/tsvg` → `~/Dev/PROJECTS/TSVG/cli/tsvg.mjs`).

## The whole workflow (about 1 minute of tool time)
```sh
tsvg new /tmp/<KEY>-report                 # report template on the tsvg:report library + a screenshot slot
#   edit /tmp/<KEY>-report/<KEY>-report.tsvg: only the props of its 5 lines (title/sub, list items, shot, checks, open; say = narration)
#   optional: replace images/screenshot.jpg with your screenshot and set box="x y w h" (fractions of the image)
tsvg check /tmp/<KEY>-report/<KEY>-report.tsvg     # compiler: errors with line numbers + "did you mean"; off-frame / overlapping text
tsvg make  /tmp/<KEY>-report/<KEY>-report.tsvg     # check → bake voices (Kokoro) → check → contact sheets → pack .tsvgz
#   LOOK at the printed *.preview-*.png (one image shows every scene + its narration, per layout); fix and make again if needed
node ~/Dev/PROJECTS/TaskManager/workspaces/ws.mjs upload <workspace> <KEY> /tmp/<KEY>-report/<KEY>-report.tsvgz   # → file id
#   post the thread message with attachments: [id]
```
- The template is library-based: `<import src="tsvg:report" as="r" key="KEY"/>` then one `<r:…/>` per scene. **Write props, not shapes.** More scene types: `tsvg lib report` (`stat`, `compare`, `code`, `list kind="step|no"`); explainers: `tsvg lib explainer` (`title point chapter steps stat quote picture versus outro`).
- Lists: `items="a | b :: detail | c"`. Scenes last as long as their `say` (dur="auto"); set `dur` only to force a length.
- `make` stops on errors. Fix what `check` prints (file:line), and run it again.
- Warnings matter too: text running off the frame, overlapping text, or a narration line longer than its scene. Fix them.
- Read the preview PNGs with your image tool before posting. Don't render single frames one by one.
- Want a different look? `tsvg styles` lists 60 hand-written style templates; `tsvg new <dir> --style <id>`. The old strings-based report: `--template report-classic`.
- To share as one file that plays anywhere without a player: `tsvg pack x.tsvg --html x.html`. Every `.tsvgz` also contains `index.html`.

## Writing the document
- Values: literal · `$token` (theme) · `@string` (current language) · `=expr` (each frame) · `"{expr}"` templates · `\` escapes a leading `=`.
- Variants: `attr.portrait`, `attr.light`, `attr.gu`: the first matching tag wins (layout first, then options). Give every position that differs in portrait its own variant.
- Nodes: `rect circle ellipse line path text image group use`. Common attributes: `fill stroke sw opacity rot scale sx sy shadow clip mask blur dash at dur when only repeat/as`.
- Expression variables: `t T p W H portrait lang theme mix dur sdur`. Functions: `sin cos lerp clamp ease(k,'out') smooth fract fmt s('id') data('id',i) count('id') rand noise mix`.
- Animation: `<anim prop from to at dur ease/>` (times relative to the node's `at`), `<keys prop v="0:0; 1:100"/>`; eases are `linear in out io back elastic step`. Path `d` keys morph.
- Text: `size` ≥ 34 for body, 64–110 for headings. Use `maxw` to wrap. `y` is the vertical centre of the block.
- Layout without numbers: `<row>`, `<col>`, `<grid cols="3">` place their children (`gap pad align justify`, `grow="1"`, `fill r shadow` = a card). Use them instead of computing x/y.
- Timing without numbers: `<scene dur="auto">` lasts as long as its narration in each language (+`pad`, ≥`min`); says without `at` follow each other; `at="=cue('v2')"` starts a node with that line.
- Narration: one `<say at text="@voN"/>` per scene (or `dur="auto"`). Fixed `dur` ≥ clip length + 1 s (check warns otherwise). Use `speak="@x_say"` when the pronunciation must differ (e.g. "T. S. V. G.").
- Gujarati: add `<choice id="gu" tts="sarvam:shubh"/>` and `gu="…"` on every string. make bakes it with Sarvam (`SARVAM_API_KEY` from `~/Dev/PROJECTS/Manager/packages/voice/sarvam/.env`; source it, never print it).
- Your own reusable parts: `<defs><component id="card" props="title, sub=''">…%{title}…</component></defs>` then `<card title="…"/>`; or a library file (spec §13).
- Spec: `~/Dev/PROJECTS/TSVG/spec/index.html` · examples: `~/Dev/PROJECTS/TSVG/examples/` · gallery: panth977.github.io/tsvg/gallery
