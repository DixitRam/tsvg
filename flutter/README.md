# tsvg (Flutter / Dart engine)

A native engine for **TSVG 0.2** (0.2.2: everything in the reference as of commit 9108ecc) (Timeseries Scalable Vector Graphics). It ports
the reference engine in `../web/tsvg-core.js`: each frame is a pure function of
`(time, options, layout)`, so seeking, ±10 s skips and scrub previews cost nothing,
and zoom re-renders the vectors sharp.

```
lib/
  tsvg_core.dart        pure Dart (no Flutter): parser, expressions, model, frame walker, audio plan, zip, validate
  tsvg.dart             everything + Flutter renderer, media loading, TsvgPlayer
  tsvg_io.dart          dart:io helper (openTsvgFile), not for web
  src/core/             js.dart (JS value semantics) sin.dart (fdlibm sin for rand/noise) xml.dart expr.dart color.dart model.dart
                        path_data.dart canvas.dart (backend interface) render.dart audio.dart source.dart validate.dart
  src/flutter/          painter.dart (Canvas backend, CustomPainter, offscreen render) media.dart (fonts, images)
                        player.dart (controller + widget) audio_engine.dart loader.dart
example/                app that plays assets/demo.tsvgz (macOS, web, Android, iOS)
test/                   core_test (unit + cross-check against the JS engine), player_test, golden_test (vs web goldens),
                        styles_smoke_test (the 60 examples/styles videos)
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
  `Math.round`), every built-in (`sin … atan2 sign clamp lerp step smooth fract ease fmt str rgba mix`,
  0.2: `data('id', i)` (index wraps), `count('id')`, `rand(seed)`, `noise(x)`; 0.2.2: `s('id')`),
  `PI/true/false`, variables `t T T0 p W H dur sdur portrait layout`, options, `<fn>` user functions.
  A test runs the same expressions plus `sayLines`/`audioPlan` for all 12 option sets through the JS engine
  under node and requires identical results.
- **Timeline**: scenes (start/dur, cursor), chapters, the last scene holds its final frame, `<backdrop>`/`<overlay>`.
- **Animation**: `<anim>` (`at/dur/from/to/ease`, later anims win, a not-yet-started first anim shows `from`)
  and `<keys>`; colour and number interpolation, and (0.2) string morph: two strings with the same skeleton
  interpolate number by number (path `d` keyframes); `T0` inheritance from the nearest ancestor with `at`.
- **0.2 / 0.2.2 nodes**: `repeat="n"` + `as="i"` on any node (`i`, `i_n`, nests, max 10 000; masks draw per copy),
  `<data id v>` in defs (numbers stay numbers), `blur` (Gaussian, layout units; see below), `arc="1"` open arcs,
  `dash="a b …"` (Canvas2D setLineDash rules: odd lists repeat, invalid lists ignored, restarts per subpath,
  replaced by path `draw`), `sx`/`sy` (× `scale`, same pivot), numeric `text` kept as written ("01"), and the
  `\` escape (`\=>` is the text "=>").
- **Visibility**: `at`, `dur`, `when`, `only`.
- **Shapes**: rect (`ax/ay`, `r`), circle/ellipse (incl. `from/to` pie slices), line (`draw`), path
  (full SVG path data incl. arcs; `draw` reveals the first k×length of each subpath like Canvas2D dashes),
  text, image, group, use/symbols; `rot`, `scale`, `opacity`, `blend` (all Canvas2D composite modes).
- **Paint**: colours (hex/rgb/rgba/hsl/named), `url(#id)` linear and radial gradients in the node's user
  space (stop `opacity`, focal point), `clip="url(#id)"` (union of rect/circle/ellipse/path),
  `mask="url(#id)"` (alpha mask via `saveLayer` + `BlendMode.dstIn`, drawn in the node's space,
  translated by x/y for group/use/path), `shadow="dx dy blur color"` (Canvas2D semantics: device-space
  offset, sigma = blur/2, inherited by children, dropped on the stroke when a fill exists).
- **Blur**: like the reference's `ctx.filter = blur(b·√|det| px)`: the device-pixel sigma is fixed where the node
  sets it (inherited by children), and every draw call is drawn into a `saveLayer` with `ImageFilter.blur`
  (decal edges) and composited with the node's blend mode. Skia scales saveLayer filters by the transform, so the
  sigma passed is the device sigma ÷ the current scale (the alternative, passing device pixels, is 3.18 % off on
  `feat-blur` vs 0.19 %).
- **rand / noise**: the reference formulas exactly, with sin from a pure-Dart port of fdlibm (`sin.dart`) so all
  Flutter platforms produce the same doubles (math.sin is the platform libm and differs in the last bit on ~3 % of
  inputs). JS engines disagree in the last bit too (Node 22 vs V8 14.7: 8 % of 300k inputs); this port matches
  Node 22 on 99.6 % (267/268 values in the reference test are bit-identical, the other is 1e-11 off).
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
**Speed is the player's** (0.2): the timeline and every clip run at the chosen rate (`setPlaybackRate` on every
player). The timeline is the master clock; each frame `TsvgAudioEngine.update`:
- starts clips that should sound and do not (seek to the offset + a learned seek latency, then resume);
- primes clips starting within 0.4 s (seek 0) and resumes them from a `Timer` at the exact moment, minus a learned
  resume latency;
- compares each running clip's reported position (advanced to now) with the timeline and seeks it back when the
  median of the last 5 reports is off by more than 0.15 s; a clip that keeps drifting backs off (×2, up to 1 s).
Play, seek, skip and option changes hard-sync every clip. `TsvgAudioEngine.log = true` prints starts, resyncs,
learned latencies, each clip's measured speed and `controller.audioStats` (the example: `--dart-define=TSVG_AUDIO_LOG=true`,
`TSVG_RATE=1.5`, `TSVG_AUTOPLAY=true`).

Pitch at speeds ≠ 1× (from the audioplayers 6.7 sources):
| platform | how the rate is applied | pitch |
|---|---|---|
| iOS / macOS | `AVPlayer.rate`, items use `audioTimePitchAlgorithm = .timeDomain` | preserved (time-domain stretch) |
| Android (API 23+) | `MediaPlayer.setPlaybackParams(params.setSpeed(r))`, pitch param left at 1.0 | preserved |
| Android < 23 | not supported by audioplayers (throws for r ≠ 1) | — |
| web | `HTMLAudioElement.playbackRate`, browsers default `preservesPitch = true` | preserved |
| Linux | GStreamer seek event with the rate | not verified (playbin may not insert scaletempo) |
| Windows | WinRT MediaPlayer `PlaybackRate` | not verified |

Measured (logs; nobody listened): at 1.5× on the iOS 18.1 simulator (m4a demo) every clip played at
1.497–1.500×, all 10 starts were scheduled or seeked on time, 0 resyncs, max drift 0.094 s (later drifts
≤ 0.02 s once latencies were learned). macOS 1.5×: clips at 1.500×, 2 resyncs in 30 s, max drift 0.19 s. Android
emulator (API 35, software GPU): voice clips play at 1.41–1.53×, and at 1× as well as 1.5× the reported positions
fall ~0.15–0.2 s behind about every second (the emulator's audio clock), so the engine resyncs often there; a real
device was not available.

## Mobile

The example builds and plays on an Android emulator (API 35, arm64, `flutter run --release`) and on the iOS 18.1
simulator (Xcode needs deployment target 15; the Podfile forces it for the pods). Screenshots of the playing video:
`test/out/mobile/android-emulator-api35.png`, `test/out/mobile/ios-sim-18.1.png` (not committed; test/out is ignored).
On iOS the simulator's unified log has the audio lines: `xcrun simctl spawn <udid> log show --predicate 'process == "Runner"'`.

## Known gaps

- **Audio is approximate**: separate platform players, kept within ~0.15 s of the timeline by resyncing (no
  sample-accurate mixing); no on-device TTS for lines without a recorded clip (they still get captions).
- **Ogg/Opus on iOS**: AVPlayer on the iOS 18.1 simulator fails every Ogg clip ("Failed to set playerItem");
  macOS plays them. Ship m4a/mp3 for iOS; `tsvg bake` writes AAC `.m4a` and the examples use it.
- **Blur** is per draw call (a layer each), so many blurred nodes cost layers; text strokes ignore `dash`.
- **Shadows** of images use the image's box (fine for opaque images); shadow blur under non-uniform scale is
  approximated by the uniform scale.
- **Fonts**: families resolve through Flutter's font system. `ui-monospace` is skipped exactly as Chrome does
  (Menlo/next family is used). Glyphs missing from every listed and bundled font fall back to the platform
  (no fallback at all in `flutter test`, where only loaded fonts exist). Two documents that register
  different files under the same family name share the first one (Flutter fonts are process-global).
- Path data errors stop parsing at the bad command (like browsers) without reporting it.
- No MP4 export from Flutter (use the CLI); no scrub-preview thumbnail strip caching (previews are drawn live).

## Conformance vs the web goldens

`flutter test test/golden_test.dart` renders the 17 cases from `../tests/cases.json` (same t, options, layout,
480 px width) with the real Inter + Noto Sans Gujarati fonts, writes `test/out/<case>.png`,
`<case>.diff.png` and `report.md`, and compares them with the headless-Chrome goldens in `../tests/golden`.
A pixel is "off" when any channel differs by more than 40/255 (same rule as the web harness); the budget is
2 % of pixels per case. The test also loads macOS Menlo and Apple Symbols / Apple Color Emoji when they exist,
because Chrome used them for the monospace line and the ♫ 🗣 ⚙ glyphs. All 17 pass (worst 1.01 %, see
`test/out/report.md`).

`flutter test test/styles_smoke_test.dart` validates and renders the 60 videos in `../examples/styles` at their
catalog `thumbT` in every layout (all render, none throw) and compares them with the web thumbnails (JPEG):
worst is retro-synthwave at 2.86 % pixels off (a ▶ glyph that `flutter test` has no font for).

## Commands

```
flutter analyze
flutter test                 # core, player and golden tests
cd example && flutter run -d macos      # or: flutter build web && serve build/web  (?lang=gu&theme=light&t=30&autoplay=1&rate=1.5)
cd example && flutter run -d <android emulator / iOS simulator>   # iOS deployment target 15 (current Xcode)
```
