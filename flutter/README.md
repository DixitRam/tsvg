# tsvg (Flutter / Dart engine)

A native engine for **TSVG 0.1** (Timeseries Scalable Vector Graphics). It ports
the reference engine in `../web/tsvg-core.js`: each frame is a pure function of
`(time, options, layout)`, so seeking, ±10 s skips and scrub previews cost nothing,
and zoom re-renders the vectors sharp.

```
lib/
  tsvg_core.dart        pure Dart (no Flutter): parser, expressions, model, frame walker, audio plan, zip, validate
  tsvg.dart             everything + Flutter renderer, media loading, TsvgPlayer
  tsvg_io.dart          dart:io helper (openTsvgFile), not for web
  src/core/             js.dart (JS value semantics) xml.dart expr.dart color.dart model.dart
                        path_data.dart canvas.dart (backend interface) render.dart audio.dart source.dart validate.dart
  src/flutter/          painter.dart (Canvas backend, CustomPainter, offscreen render) media.dart (fonts, images)
                        player.dart (controller + widget) audio_engine.dart loader.dart
example/                app that plays assets/demo.tsvgz (macOS + web)
test/                   core_test (unit + cross-check against the JS engine), player_test, golden_test (vs web goldens)
```

## Usage

```dart
import 'package:tsvg/tsvg.dart';

// a .tsvgz in the asset bundle (or a .tsvg next to its files in assets/)
final source = await openTsvgAsset('assets/demo.tsvgz');

// a ready-made player
TsvgPlayer(source: source, autoplay: true, options: {'lang': 'gu'}, onOptions: print);

// or keep the state yourself (shared with the fullscreen route automatically)
final c = TsvgPlayerController(options: {'theme': 'light'});
await c.load(source);
TsvgPlayer(controller: c);
c.play(); c.seek(12); c.skip(-10); c.setOption('mix', 'speech'); c.setLayout('portrait'); c.zoomAt(3);
```

Only the frame, with no controls:

```dart
final doc = parseTsvg(source.xml);
final media = await TsvgMedia.load(doc, source);   // registers <font>s via FontLoader, decodes images
CustomPaint(painter: TsvgFramePainter(doc: doc, media: media, layout: doc.layout('landscape'),
    t: 3.5, options: defaultOptions(doc), zoom: 1));
final png = await renderTsvgPng(doc: doc, media: media, layout: doc.layouts.first, t: 3.5,
    options: {...defaultOptions(doc), 'lang': 'gu'}, width: 960);
```

Pure Dart (server, CLI, tests):

```dart
import 'package:tsvg/tsvg_core.dart';
final doc = parseTsvg(xml);
sayLines(doc, opts);        // captions + clips for an option set
audioPlan(doc, opts);       // bus gains + clips
validate(xml, has: (p) => files.containsKey(p));   // same checks + dry run as the reference
packageSource(zipBytes);    // .tsvgz → TsvgSource; writeZip(files) to make one
renderFrame(myCanvas, doc, t, opts, layout);       // any backend implementing TsvgCanvas
```

On dart:io platforms `openTsvgFile(path)` (from `package:tsvg/tsvg_io.dart`) opens a
`.tsvg` next to its files or a `.tsvgz`.

## Supported (same behaviour as tsvg-core.js)

- **Attributes**: `literal`, numbers, `$token`, `@string` (per `lang`, falls back to `en`, then the first),
  `=expr`, `{expr}` templates; variants `name.<tag>` with tags = layout id, then each option value in
  declared order.
- **Expressions**: the full operator set and precedence, JS value semantics (string `+`, loose `==`, floored `%`,
  `Math.round`), every built-in (`sin … atan2 sign clamp lerp step smooth fract ease fmt str rgba mix`),
  `PI/true/false`, variables `t T T0 p W H dur sdur portrait layout`, options, `<fn>` user functions.
  A test runs the same expressions plus `sayLines`/`audioPlan` for all 12 option sets through the JS engine
  under node and requires identical results.
- **Timeline**: scenes (start/dur, cursor), chapters, the last scene holds its final frame, `<backdrop>`/`<overlay>`.
- **Animation**: `<anim>` (`at/dur/from/to/ease`, later anims win, a not-yet-started first anim shows `from`)
  and `<keys>`; colour and number interpolation; `T0` inheritance from the nearest ancestor with `at`.
- **Visibility**: `at`, `dur`, `when`, `only`.
- **Shapes**: rect (`ax/ay`, `r`), circle/ellipse (incl. `from/to` pie slices), line (`draw`), path
  (full SVG path data incl. arcs; `draw` reveals the first k×length of each subpath like Canvas2D dashes),
  text, image, group, use/symbols; `rot`, `scale`, `opacity`, `blend` (all Canvas2D composite modes).
- **Paint**: colours (hex/rgb/rgba/hsl/named), `url(#id)` linear and radial gradients in the node's user
  space (stop `opacity`, focal point), `clip="url(#id)"` (union of rect/circle/ellipse/path),
  `mask="url(#id)"` (alpha mask via `saveLayer` + `BlendMode.dstIn`, drawn in the node's space,
  translated by x/y for group/use/path), `shadow="dx dy blur color"` (Canvas2D semantics: device-space
  offset, sigma = blur/2, inherited by children, dropped on the stroke when a fill exists).
- **Text**: font family lists (`font` attr or the document `font`), weight on the variable font's `wght` axis,
  `opsz` = size (as Chrome's `font-optical-sizing: auto`), italic, `align`, `maxw` word wrap with the same
  greedy algorithm, `lh`, `reveal` (by code point), stroke + fill, gradients on text, Canvas2D
  `textBaseline = middle` (em-box middle). `<font>` assets are registered with `FontLoader`.
- **Images**: `fit` cover/contain/fill, rounded `r`, placeholder box while loading.
- **Audio plan**: `<music>`, `<sfx>`, `<say>` with `<voices>` (`say|lang`), `src.<lang>`, `speak`, `when`, `<mix>` bus gains.
- **Packages**: `.tsvgz` read/write (package:archive).
- **validate()**: the reference's static checks, overlap/past-end warnings, and the dry run of every layout × option set.

## Player

Play/pause, timeline with chapter ticks, tap/drag to scrub, hover/drag shows a live frame preview with time and
chapter, ±10 s buttons, double-tap on the left/right 30 % to skip (double-tap in the middle resets zoom),
speed 0.5–2×, captions from the say lines (timed by the real clip length + 0.3 s once audio is loaded, like
the web player), an options panel (every `<option>`, layout auto/portrait/landscape, speed, captions),
pinch zoom (1–12×, keeps the focal point), pan when zoomed, mouse-wheel / trackpad zoom, fullscreen route,
keyboard: space/k, j/←, l/→, c, f, 0–9. Controls auto-hide after 2.5 s while playing.

**Audio** (audioplayers): one player per clip in the audio plan, volume = clip `vol` × mix gain of its bus.
Play, seek, skip, option and mix changes re-sync every clip to the playhead (loops start at `offset % length`);
clips starting later are started when the playhead crosses them. Checked in headless Chrome by instrumenting
`HTMLMediaElement.play`: music joins at the right offset, `vo3` and the 4 blips fire at their times, and a −10 s
seek restarts `vo2` at +0.43 s and the music at 7.83 s. On macOS (this machine) all 13 Ogg clips load with the
right durations and reach the `playing` state.

## Known gaps

- **Audio is approximate**: timing comes from separate platform players, so expect tens of ms of drift; no
  sample-accurate scheduling, no pitch-corrected speed (audio is muted at any speed other than 1×, like the web
  player); no on-device TTS for lines without a recorded clip (they still get captions).
- **Ogg/Opus on Apple platforms** goes through AVPlayer. It worked on this macOS; older macOS / iOS versions
  may not decode Ogg. Ship m4a/mp3 clips for those if needed (decode errors are listed in the options panel).
- **Shadows** of images use the image's box (fine for opaque images); shadow blur under non-uniform scale is
  approximated by the uniform scale.
- **Fonts**: families resolve through Flutter's font system. `ui-monospace` is skipped exactly as Chrome does
  (Menlo/next family is used). Glyphs missing from every listed and bundled font fall back to the platform
  (no fallback at all in `flutter test`, where only loaded fonts exist). Two documents that register
  different files under the same family name share the first one (Flutter fonts are process-global).
- Path data errors stop parsing at the bad command (like browsers) without reporting it.
- No MP4 export from Flutter (use the CLI); no scrub-preview thumbnail strip caching (previews are drawn live).

## Conformance vs the web goldens

`flutter test test/golden_test.dart` renders the 10 cases from `../tests/cases.json` (same t, options, layout,
480 px width) with the real Inter + Noto Sans Gujarati fonts, writes `test/out/<case>.png`,
`<case>.diff.png` and `report.md`, and compares them with the headless-Chrome goldens in `../tests/golden`.
A pixel is "off" when any channel differs by more than 40/255 (same rule as the web harness); the budget is
2 % of pixels per case. The test also loads macOS Menlo and Apple Symbols / Apple Color Emoji when they exist,
because Chrome used them for the monospace line and the ♫ 🗣 ⚙ glyphs.

## Commands

```
flutter analyze
flutter test                 # core, player and golden tests
cd example && flutter run -d macos      # or: flutter build web && serve build/web  (?lang=gu&theme=light&t=30&autoplay=1)
```
