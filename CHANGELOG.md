# Changelog

## 0.10.0
- `tsvg watch <file>`: live preview that reloads on every save, keeps the position, shows errors with source lines.
- `tsvg edit <file>` and `editor/`: visual editor. Click to select, drag to move, edit attributes, component props and strings, save.
- Captions files: `TSVG.captions(doc, opts, 'vtt' | 'srt')`, `tsvg captions`, and packages carry `captions/<lang>.vtt`.
- Smaller packages by default. Fonts are subset to the characters the document can show, big JPEG/PNG become WebP, and duplicate files are stored once. Use `--full` to keep files as they are.
- Player: a Chapters menu.

## 0.9.0
- `filter="grayscale(1) sepia(.4) contrast(1.2) brightness(1.1) saturate(1.5) hue(30) invert(1) blur(4) opacity(.8)"` on any node.
- Skew with `skx` / `sky`.
- `tsvg:fx` library. Overlays: grain, vignette, scanlines, leak, flash. Wrappers: grade (named looks), glow, shake, beat.
- Beat grids: with `<music beats="id">`, `tsvg bake` / `make` writes `<data id>`. Use them with `since()`, `idx()` and `pulse()`.
- Ducking: `<mix duck="0.3">` lowers the music under every spoken line, in players and exports.
- In layouts, groups without `w`/`h` size to their children.

## 0.8.0
- The `<video>` node plays clips inside scenes: `start`, `rate`, `loop`, `vol`, `poster`. Clips seek with the timeline and play in sync at the player's speed. The player keeps one element per node, and exports are frame-exact.
- `tsvg pack` adds a poster frame and the clip length to every clip.

## 0.7.0
- `tsvg:charts` library: bars, hbars, line (with area), pie/donut with legend, ring, counter, spark.
- `tsvg:icons` library: 2,104 Lucide icons (ISC). `tsvg icons <word>` finds them by name or tag.
- For library authors:
  - `<dict>` and `%{d[k]}`
  - `%{p:sum}`
  - in `<each>`: `_prev`, `_next`, `_acc`
  - prop defaults may contain commas inside quotes
- `group`/`use` anchors (`ax ay`), `cap`, `nth()`, `commas()`.

## 0.6.0
- Rich text:
  - `rich="1"` markup: `**bold**` `*italic*` `` `code` `` `==highlight==` `[words]($accent)`
  - `ls` letter spacing
  - `split="word|char|line"` with `stagger`
  - `path="M…"` puts text on a curve
- Scene transitions: `<scene in="push 0.6 left">` (fade, slide, push, wipe, zoom, iris, blur), or `<timeline in>` for every scene.

## 0.5.0
- Auto layout with `<row>`, `<col>`, `<grid>`: gap, pad, align, justify, grow, and cards via fill, `r` and shadow.
- Auto timing: `dur="auto"` follows the narration in each language, says chain, `cue()` / `cueEnd()`, and `dur`/`start`/`at` variants. Players use per-option durations and chapters (`TSVG.forOptions`).

## 0.4.0
- Video libraries: `<import src="tsvg:report" as="r">` and components with props (`%{p}`, `<if>`, `<each>`, `<slot>`, language variants).
- Built-in libraries: `base`, `report`, `explainer`.
- Packages are flattened, so every player plays them. `tsvg lib` lists libraries.
- The report template is built on `tsvg:report`.
