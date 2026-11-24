---
name: tsvg
description: Make every video report as a TSVG (Timeseries Scalable Vector Graphics, .tsvgz), never an mp4 or a video-like HTML page. Use whenever you report to Panth (done, rework, progress, explanation), explain or demo something as a video, or the user mentions TSVG. Three commands: tsvg new → edit → tsvg make; no rendering, no encoding.
---

# TSVG: video reports without rendering

A TSVG video is one XML file. The player draws it live, with timeline, captions, chapters, options and sharp zoom, so there is **nothing to render or encode**. TaskManager plays `.tsvgz` attachments inline. Never render mp4s for reports.

`tsvg` is on PATH (`~/.local/bin/tsvg` → `~/Dev/PROJECTS/TSVG/cli/tsvg.mjs`).

## The whole workflow (about 1 minute of tool time)
```sh
tsvg new /tmp/<KEY>-report                 # report template + its fonts/audio/screenshot, ready to edit
#   edit /tmp/<KEY>-report/<KEY>-report.tsvg: change the <strings> block (title, changes, verified, open, vo1…vo5)
#   optional: replace images/screenshot.jpg with your screenshot, and set the highlight box (data id="box")
tsvg check /tmp/<KEY>-report/<KEY>-report.tsvg     # compiler: errors with line numbers + "did you mean"; off-frame / overlapping text
tsvg make  /tmp/<KEY>-report/<KEY>-report.tsvg     # check → bake voices (Kokoro) → check → contact sheets → pack .tsvgz
#   LOOK at the printed *.preview-*.png (one image shows every scene + its narration, per layout); fix and make again if needed
node ~/Dev/PROJECTS/TaskManager/workspaces/ws.mjs upload <workspace> <KEY> /tmp/<KEY>-report/<KEY>-report.tsvgz   # → file id
#   post the thread message with attachments: [id]
```
- `make` stops on errors. Fix what `check` prints (file:line), and run it again.
- Warnings matter too: text running off the frame, overlapping text, or a narration line longer than its scene. Fix them.
- Read the preview PNGs with your image tool before posting. Don't render single frames one by one.
- Want a different look? Run `tsvg styles` to list the 60 style templates (product tour, code walkthrough, kanban status report, data story, whiteboard…), then `tsvg new <dir> --style <id>`.
- To share as one file that plays anywhere without a player: `tsvg pack x.tsvg --html x.html`. Every `.tsvgz` also contains `index.html`.

## Writing the document
- Values: literal · `$token` (theme) · `@string` (current language) · `=expr` (each frame) · `"{expr}"` templates · `\` escapes a leading `=`.
- Variants: `attr.portrait`, `attr.light`, `attr.gu`: the first matching tag wins (layout first, then options). Give every position that differs in portrait its own variant.
- Nodes: `rect circle ellipse line path text image group use`. Common attributes: `fill stroke sw opacity rot scale sx sy shadow clip mask blur dash at dur when only repeat/as`.
- Expression variables: `t T p W H portrait lang theme mix dur sdur`. Functions: `sin cos lerp clamp ease(k,'out') smooth fract fmt s('id') data('id',i) count('id') rand noise mix`.
- Animation: `<anim prop from to at dur ease/>` (times relative to the node's `at`), `<keys prop v="0:0; 1:100"/>`; eases are `linear in out io back elastic step`. Path `d` keys morph.
- Text: `size` ≥ 34 for body, 64–110 for headings. Use `maxw` to wrap. `y` is the vertical centre of the block.
- Narration: one `<say at text="@voN"/>` per scene. Scene `dur` ≥ clip length + 1 s (check warns otherwise). Use `speak="@x_say"` when the pronunciation must differ (e.g. "T. S. V. G.").
- Gujarati: add `<choice id="gu" tts="sarvam:shubh"/>` and `gu="…"` on every string. make bakes it with Sarvam (`SARVAM_API_KEY` from `~/Dev/PROJECTS/Manager/packages/voice/sarvam/.env`; source it, never print it).
- Spec: `~/Dev/PROJECTS/TSVG/spec/index.html` · examples: `~/Dev/PROJECTS/TSVG/examples/` · gallery: panth977.github.io/tsvg/gallery
