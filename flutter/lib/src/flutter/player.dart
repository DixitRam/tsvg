// TsvgPlayer: a video player for TSVG documents — play/pause, timeline with
// chapter ticks and scrub previews, ±10 s (buttons, keys, double-tap on the
// sides), speed, captions from <say> lines, an options panel (every <option>
// plus layout), pinch / wheel zoom that re-renders sharp, audio buses.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../core/audio.dart';
import '../core/model.dart';
import '../core/render.dart';
import '../core/source.dart';
import 'audio_engine.dart';
import 'media.dart';
import 'painter.dart';

String _fmtT(double s) {
  s = math.max(0, s);
  final m = s ~/ 60;
  return '$m:${(s % 60).floor().toString().padLeft(2, '0')}';
}

/// Playback state of one document. Owns the clock (a [Ticker]) and the audio,
/// so it can be shared by several [TsvgPlayer] widgets (e.g. a fullscreen route).
class TsvgPlayerController extends ChangeNotifier {
  TsvgPlayerController({Map<String, String>? options, this.enableAudio = true}) : _initialOptions = options;

  final Map<String, String>? _initialOptions;

  /// Set false to never touch audio (tests, silent previews).
  final bool enableAudio;

  TsvgSource? source;
  TsvgDoc? doc;
  TsvgMedia? media;
  Object? loadError;

  double t = 0;
  bool playing = false;
  double rate = 1;
  bool captions = true;

  /// 'auto' or a layout id.
  String layoutPref = 'auto';
  Map<String, String> options = const {};
  List<SayLine> lines = const [];

  double zoom = 1;
  Offset pan = Offset.zero;

  TsvgAudioEngine? _audio;
  Ticker? _ticker;
  Duration _last = Duration.zero;

  /// Called whenever the viewer changes an option.
  void Function(Map<String, String> options)? onOptions;

  bool get ready => doc != null;
  double get duration => doc?.duration ?? 0;
  List<String> get audioErrors => _audio?.errors ?? const [];

  /// Loads a document and its fonts / images.
  Future<void> load(TsvgSource src) async {
    pause();
    try {
      final d = parseTsvg(src.xml);
      final m = await TsvgMedia.load(d, src);
      media?.dispose();
      await _audio?.dispose();
      _audio = null;
      source = src;
      doc = d;
      media = m;
      m.addListener(notifyListeners);
      final keep = <String, String>{
        for (final o in d.options)
          if (options[o.id] != null && o.choices.any((c) => c.id == options[o.id])) o.id: options[o.id]!,
      };
      options = {...defaultOptions(d), ...?_initialOptions, ...keep};
      t = math.min(t, d.duration);
      loadError = null;
      _syncLines();
    } catch (e) {
      loadError = e;
    }
    notifyListeners();
  }

  void _syncLines() {
    final d = doc;
    if (d == null) return;
    lines = sayLines(d, options);
    final a = _audio;
    if (a != null) {
      for (final l in lines) {
        final dur = l.clip == null ? null : a.durations[assetPath(d, l.clip)];
        if (dur != null) l.dur = dur + 0.3;
      }
    }
  }

  Future<void> _ensureAudio() async {
    final d = doc, s = source;
    if (!enableAudio || d == null || s == null) return;
    _audio ??= TsvgAudioEngine(d, s);
    await _audio!.prepare(audioPlan(d, options));
    _syncLines();
  }

  Future<void> play() async {
    final d = doc;
    if (d == null || playing) return;
    if (t >= d.duration - 0.05) t = 0;
    playing = true;
    notifyListeners();
    _ticker ??= Ticker(_onTick, debugLabel: 'tsvg');
    _last = Duration.zero;
    if (!_ticker!.isActive) _ticker!.start();
    try {
      await _ensureAudio();
    } catch (e) {
      debugPrint('tsvg audio: $e');
    }
    if (playing) await _resyncAudio();
  }

  void pause() {
    if (!playing) return;
    playing = false;
    _ticker?.stop();
    _audio?.stop();
    notifyListeners();
  }

  void toggle() => playing ? pause() : play();

  Future<void> _resyncAudio() async {
    // pitch-correct speed change is out of scope (same as the web player)
    await _audio?.sync(t, playing: playing && rate == 1);
  }

  void seek(double to) {
    final d = doc;
    if (d == null) return;
    t = to.clamp(0.0, d.duration).toDouble();
    if (playing) unawaited(_resyncAudio());
    notifyListeners();
  }

  void skip(double s) => seek(t + s);

  void _onTick(Duration elapsed) {
    final d = doc;
    if (d == null || !playing) return;
    final dt = _last == Duration.zero ? 0.0 : (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    final prev = t;
    t += dt * rate;
    if (rate == 1) _audio?.tick(prev, t);
    if (t >= d.duration) {
      t = d.duration;
      pause();
      return;
    }
    notifyListeners();
  }

  void setRate(double r) {
    rate = r;
    if (playing) unawaited(_resyncAudio());
    notifyListeners();
  }

  void setOption(String id, String value) {
    options = {...options, id: value};
    _syncLines();
    if (id == 'mix') _audio?.applyMix(doc!.mixes[value] ?? const {'voice': 1, 'music': 1, 'sfx': 1});
    if (playing) {
      unawaited(_ensureAudio().then((_) => _resyncAudio()));
    }
    onOptions?.call(options);
    notifyListeners();
  }

  void setLayout(String pref) {
    layoutPref = pref;
    resetZoom();
  }

  void setCaptions(bool on) {
    captions = on;
    notifyListeners();
  }

  /// Zoom to [z], keeping [focus] (relative to the player centre) fixed on screen.
  void zoomAt(double z, [Offset focus = Offset.zero]) {
    z = z.clamp(1.0, 12.0);
    final k = z / zoom;
    pan = focus - (focus - pan) * k;
    zoom = z;
    if (z == 1) pan = Offset.zero;
    notifyListeners();
  }

  void setView(double z, Offset p) {
    zoom = z.clamp(1.0, 12.0);
    pan = zoom == 1 ? Offset.zero : p;
    notifyListeners();
  }

  void resetZoom() => setView(1, Offset.zero);

  /// The layout for a viewport of [size] ('auto' = closest aspect ratio).
  TsvgLayout layoutFor(Size size) {
    final d = doc!;
    if (layoutPref != 'auto') return d.layout(layoutPref);
    final r = size.width / math.max(1, size.height);
    final ls = d.layouts.toList()
      ..sort((a, b) => (math.log(a.w / a.h / r)).abs().compareTo((math.log(b.w / b.h / r)).abs()));
    return ls.first;
  }

  String label(String v) {
    final d = doc;
    if (d == null) return v;
    try {
      return labelOf(d, v, options);
    } catch (_) {
      return v;
    }
  }

  TsvgChapter? chapterAt(double at) {
    TsvgChapter? c;
    for (final ch in doc?.chapters ?? const <TsvgChapter>[]) {
      if (ch.t <= at + 1e-6) c = ch;
    }
    return c;
  }

  SayLine? get currentLine {
    if (!captions) return null;
    for (final l in lines) {
      if (t >= l.start && t < l.start + l.dur) return l;
    }
    return null;
  }

  @override
  void dispose() {
    _ticker?.dispose();
    unawaited(_audio?.dispose());
    media?.dispose();
    super.dispose();
  }
}

const Color _accent = Color(0xffff4d5a);

/// A TSVG video player.
class TsvgPlayer extends StatefulWidget {
  const TsvgPlayer({
    super.key,
    this.source,
    this.controller,
    this.autoplay = false,
    this.options,
    this.onOptions,
    this.allowFullscreen = true,
  }) : assert(source != null || controller != null);

  /// What to play (ignored when [controller] is already loaded).
  final TsvgSource? source;
  final TsvgPlayerController? controller;
  final bool autoplay;

  /// Initial option values (e.g. {'lang': 'gu'}).
  final Map<String, String>? options;
  final void Function(Map<String, String> options)? onOptions;
  final bool allowFullscreen;

  @override
  State<TsvgPlayer> createState() => _TsvgPlayerState();
}

class _TsvgPlayerState extends State<TsvgPlayer> {
  late TsvgPlayerController c;
  bool _ownController = false;
  bool _menu = false;
  bool _idle = false;
  Timer? _idleTimer;
  final FocusNode _focus = FocusNode(debugLabel: 'tsvg player');
  int _flash = -1; // 0 = back, 1 = forward
  Timer? _flashTimer;

  // gestures
  double _z0 = 1;
  Offset _pan0 = Offset.zero, _focal0 = Offset.zero;
  Size _size = Size.zero;

  // scrub preview
  double? _hoverT;

  @override
  void initState() {
    super.initState();
    _ownController = widget.controller == null;
    c = widget.controller ?? TsvgPlayerController(options: widget.options);
    c.onOptions = widget.onOptions;
    c.addListener(_changed);
    if (!c.ready && widget.source != null) {
      c.load(widget.source!).then((_) {
        if (widget.autoplay && mounted) c.play();
      });
    } else if (widget.autoplay) {
      c.play();
    }
    _wake();
  }

  @override
  void didUpdateWidget(TsvgPlayer old) {
    super.didUpdateWidget(old);
    if (widget.source != null && widget.source != old.source) c.load(widget.source!);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    c.removeListener(_changed);
    if (_ownController) c.dispose();
    _idleTimer?.cancel();
    _flashTimer?.cancel();
    _focus.dispose();
    super.dispose();
  }

  void _wake() {
    _idleTimer?.cancel();
    if (_idle) setState(() => _idle = false);
    _idleTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted && c.playing && !_menu) setState(() => _idle = true);
    });
  }

  void _skip(int dir) {
    c.skip(dir * 10.0);
    _flashTimer?.cancel();
    setState(() => _flash = dir < 0 ? 0 : 1);
    _flashTimer = Timer(const Duration(milliseconds: 450), () {
      if (mounted) setState(() => _flash = -1);
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.keyK) {
      if (e is KeyDownEvent) c.toggle();
    } else if (k == LogicalKeyboardKey.keyJ || k == LogicalKeyboardKey.arrowLeft) {
      _skip(-1);
    } else if (k == LogicalKeyboardKey.keyL || k == LogicalKeyboardKey.arrowRight) {
      _skip(1);
    } else if (k == LogicalKeyboardKey.keyC) {
      c.setCaptions(!c.captions);
    } else if (k == LogicalKeyboardKey.keyF) {
      _fullscreen();
    } else if (k == LogicalKeyboardKey.escape && _menu) {
      setState(() => _menu = false);
    } else {
      final ch = e.character;
      if (ch != null && RegExp(r'^[0-9]$').hasMatch(ch)) {
        c.seek(c.duration * int.parse(ch) / 10);
      } else {
        return KeyEventResult.ignored;
      }
    }
    _wake();
    return KeyEventResult.handled;
  }

  void _fullscreen() {
    if (!widget.allowFullscreen) return;
    final nav = Navigator.maybeOf(context);
    if (nav == null) return;
    if (ModalRoute.of(context)?.settings.name == 'tsvg-fullscreen') {
      nav.pop();
      return;
    }
    nav.push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'tsvg-fullscreen'),
      builder: (_) => Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(child: TsvgPlayer(controller: c, allowFullscreen: true)),
      ),
    ));
  }

  // ── gestures on the picture ──
  Offset _fromCentre(Offset local) => local - Offset(_size.width / 2, _size.height / 2);

  void _onScaleStart(ScaleStartDetails d) {
    _z0 = c.zoom;
    _pan0 = c.pan;
    _focal0 = _fromCentre(d.localFocalPoint);
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final f = _fromCentre(d.localFocalPoint);
    if (d.pointerCount >= 2) {
      final z = (_z0 * d.scale).clamp(1.0, 12.0);
      final k = z / _z0;
      // keep the content under the initial focal point under the current focal point
      c.setView(z, f - (_focal0 - _pan0) * k);
    } else if (c.zoom > 1.01) {
      c.setView(c.zoom, _pan0 + (f - _focal0));
    }
  }

  void _onDoubleTapDown(TapDownDetails d) {
    final x = d.localPosition.dx / math.max(1, _size.width);
    if (x < 0.3) {
      _skip(-1);
    } else if (x > 0.7) {
      _skip(1);
    } else {
      c.resetZoom();
    }
  }

  void _onWheel(PointerSignalEvent e) {
    if (e is PointerScrollEvent) {
      c.zoomAt(c.zoom * math.exp(-e.scrollDelta.dy / 400), _fromCentre(e.localPosition));
    } else if (e is PointerScaleEvent) {
      c.zoomAt(c.zoom * e.scale, _fromCentre(e.localPosition));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: MouseRegion(
        onHover: (_) => _wake(),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: ColoredBox(
            color: Colors.black,
            child: DefaultTextStyle(
              style: const TextStyle(color: Colors.white, fontSize: 14),
              child: LayoutBuilder(builder: (context, box) {
                _size = box.biggest;
                if (c.loadError != null) {
                  return Center(
                      child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text('Cannot open: ${c.loadError}', style: const TextStyle(color: _accent))));
                }
                if (!c.ready) return const Center(child: CircularProgressIndicator(color: _accent));
                return _stage(context, box.biggest);
              }),
            ),
          ),
        ),
      ),
    );
  }

  Widget _stage(BuildContext context, Size size) {
    final doc = c.doc!;
    final layout = c.layoutFor(size);
    final line = c.currentLine;
    final ccSize = (size.width * 0.022).clamp(12.0, 20.0);
    final showBar = !_idle || !c.playing || _menu;
    return Stack(children: [
      Positioned.fill(
        child: Listener(
          onPointerSignal: _onWheel,
          onPointerDown: (_) => _wake(),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              _focus.requestFocus();
              if (_menu) {
                setState(() => _menu = false);
              } else {
                c.toggle();
              }
            },
            onDoubleTapDown: _onDoubleTapDown,
            onDoubleTap: () {},
            onScaleStart: _onScaleStart,
            onScaleUpdate: _onScaleUpdate,
            child: RepaintBoundary(
              child: CustomPaint(
                size: size,
                painter: TsvgFramePainter(
                  doc: doc,
                  layout: layout,
                  t: c.t,
                  options: c.options,
                  media: c.media,
                  zoom: c.zoom,
                  pan: c.pan,
                ),
              ),
            ),
          ),
        ),
      ),
      if (c.zoom > 1.01)
        Positioned(
          top: 10,
          left: 10,
          child: _pill('zoom ${c.zoom.toStringAsFixed(1)}× · still sharp · double-tap centre to reset', 12),
        ),
      if (!c.playing && c.zoom <= 1.01)
        IgnorePointer(
          child: Center(
            child: Container(
              width: 84,
              height: 84,
              decoration: const BoxDecoration(color: Color(0x99000000), shape: BoxShape.circle),
              child: const Icon(Icons.play_arrow_rounded, size: 52, color: Colors.white),
            ),
          ),
        ),
      for (final i in [0, 1])
        Positioned(
          left: i == 0 ? size.width * 0.12 : null,
          right: i == 1 ? size.width * 0.12 : null,
          top: size.height / 2 - 26,
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: _flash == i ? 1 : 0,
              duration: const Duration(milliseconds: 300),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                decoration: BoxDecoration(color: const Color(0x88000000), borderRadius: BorderRadius.circular(40)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(i == 0 ? Icons.replay_10_rounded : Icons.forward_10_rounded, color: Colors.white),
                  const SizedBox(width: 6),
                  Text(i == 0 ? '−10 s' : '+10 s', style: const TextStyle(fontSize: 18)),
                ]),
              ),
            ),
          ),
        ),
      if (line != null)
        Positioned(
          left: size.width * 0.14,
          right: size.width * 0.14,
          bottom: showBar ? 76 : 24,
          child: IgnorePointer(
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: const Color(0xcc000000), borderRadius: BorderRadius.circular(4)),
                child: Text(
                  line.text,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: ccSize,
                    height: 1.45,
                    color: Colors.white,
                    fontFamilyFallback: [for (final f in doc.fonts) f.family],
                  ),
                ),
              ),
            ),
          ),
        ),
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: IgnorePointer(
          ignoring: !showBar,
          child: AnimatedOpacity(opacity: showBar ? 1 : 0, duration: const Duration(milliseconds: 250), child: _bar(layout)),
        ),
      ),
      if (_menu) Positioned(right: 12, bottom: 64, top: 12, child: _menuPanel()),
    ]);
  }

  Widget _pill(String s, double fs) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: const Color(0xaa000000), borderRadius: BorderRadius.circular(6)),
        child: Text(s, style: TextStyle(fontSize: fs)),
      );

  Widget _btn(Widget child, String tip, VoidCallback onTap, {double opacity = 1}) => Tooltip(
        message: tip,
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () {
            onTap();
            _wake();
          },
          child: Opacity(
            opacity: opacity,
            child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6), child: child),
          ),
        ),
      );

  Widget _bar(TsvgLayout layout) {
    final ch = c.chapterAt(c.t);
    const ic = Colors.white;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 24, 14, 8),
      decoration: const BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x00000000), Color(0xcc000000)]),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        _Timeline(controller: c, layout: layout, onHover: (t) => setState(() => _hoverT = t), hoverT: _hoverT, onInteract: _wake),
        const SizedBox(height: 4),
        Row(children: [
          _btn(Icon(c.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: ic), 'Play / pause (k, space)', c.toggle),
          _btn(const Icon(Icons.replay_10_rounded, color: ic), 'Back 10 s (j, ←)', () => _skip(-1)),
          _btn(const Icon(Icons.forward_10_rounded, color: ic), 'Forward 10 s (l, →)', () => _skip(1)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text('${_fmtT(c.t)} / ${_fmtT(c.duration)}', style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
          ),
          Expanded(
            child: Text(ch != null ? '• ${c.label(ch.label)}' : '',
                overflow: TextOverflow.ellipsis, maxLines: 1, style: const TextStyle(color: Color(0xbfffffff))),
          ),
          _btn(const Text('CC', style: TextStyle(fontWeight: FontWeight.w700)), 'Captions (c)', () => c.setCaptions(!c.captions),
              opacity: c.captions ? 1 : 0.45),
          _btn(Text('${_rateStr(c.rate)}×'), 'Speed', () => c.setRate(switch (c.rate) { 0.5 => 1.0, 1.0 => 1.5, 1.5 => 2.0, _ => 0.5 })),
          _btn(const Icon(Icons.settings_rounded, color: ic), 'Options', () => setState(() => _menu = !_menu)),
          if (widget.allowFullscreen) _btn(const Icon(Icons.fullscreen_rounded, color: ic), 'Fullscreen (f)', _fullscreen),
        ]),
      ]),
    );
  }

  String _rateStr(double r) => r == r.roundToDouble() ? r.toInt().toString() : r.toString();

  Widget _menuPanel() {
    final doc = c.doc!;
    Widget group(String title, List<(String, String)> choices, String cur, void Function(String) pick) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
              child: Text(title.toUpperCase(),
                  style: const TextStyle(fontSize: 11, letterSpacing: 0.9, color: Color(0x99ffffff))),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Wrap(spacing: 4, runSpacing: 4, children: [
                for (final (id, label) in choices)
                  Material(
                    color: id == cur ? _accent : const Color(0x14ffffff),
                    borderRadius: BorderRadius.circular(6),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: () => setState(() => pick(id)),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                        child: Text(label,
                            style: TextStyle(fontSize: 13, fontFamilyFallback: [for (final f in doc.fonts) f.family])),
                      ),
                    ),
                  ),
              ]),
            ),
          ],
        );
    return Container(
      width: 250,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xf216181e),
        borderRadius: BorderRadius.circular(10),
        boxShadow: const [BoxShadow(color: Color(0x88000000), blurRadius: 30, offset: Offset(0, 8))],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: ListView(shrinkWrap: true, padding: EdgeInsets.zero, children: [
          for (final o in doc.options)
            group(c.label(o.label), [for (final ch in o.choices) (ch.id, c.label(ch.label))], c.options[o.id] ?? '',
                (v) => c.setOption(o.id, v)),
          group('Layout (player)', [
            ('auto', 'Auto (fit screen)'),
            for (final l in doc.layouts) (l.id, '${l.id} ${l.w.round()}×${l.h.round()}'),
          ], c.layoutPref, c.setLayout),
          group('Speed (player)', [for (final r in [0.5, 1.0, 1.5, 2.0]) ('$r', '${_rateStr(r)}×')], '${c.rate}',
              (v) => c.setRate(double.parse(v))),
          group('Captions (player)', [('on', 'On'), ('off', 'Off')], c.captions ? 'on' : 'off', (v) => c.setCaptions(v == 'on')),
          if (c.audioErrors.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text('Audio: ${c.audioErrors.length} clip(s) could not load on this platform',
                  style: const TextStyle(fontSize: 11, color: Color(0x99ffffff))),
            ),
        ]),
      ),
    );
  }
}

/// Progress rail with chapter ticks, drag / tap to seek, hover / drag previews.
class _Timeline extends StatelessWidget {
  const _Timeline({required this.controller, required this.layout, required this.onHover, required this.hoverT, required this.onInteract});
  final TsvgPlayerController controller;
  final TsvgLayout layout;
  final void Function(double? t) onHover;
  final double? hoverT;
  final VoidCallback onInteract;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final d = c.duration;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      double at(double x) => (x / w).clamp(0.0, 1.0) * d;
      final k = d > 0 ? c.t / d : 0.0;
      final tw = layout.w > layout.h ? 176.0 : 90.0;
      final th = tw * layout.h / layout.w;
      return MouseRegion(
        onHover: (e) => onHover(at(e.localPosition.dx)),
        onExit: (_) => onHover(null),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (e) {
            c.seek(at(e.localPosition.dx));
            onInteract();
          },
          onHorizontalDragStart: (e) => onHover(at(e.localPosition.dx)),
          onHorizontalDragUpdate: (e) {
            final t = at(e.localPosition.dx);
            c.seek(t);
            onHover(t);
            onInteract();
          },
          onHorizontalDragEnd: (_) => onHover(null),
          child: SizedBox(
            height: 18,
            child: Stack(clipBehavior: Clip.none, children: [
              Positioned(left: 0, right: 0, top: 7, height: 4, child: _rail(const Color(0x38ffffff))),
              Positioned(left: 0, width: w * k, top: 7, height: 4, child: _rail(_accent)),
              for (final ch in c.doc!.chapters.where((ch) => ch.t > 0))
                Positioned(left: w * ch.t / d - 1, top: 5, width: 2, height: 8, child: const ColoredBox(color: Color(0xaa000000))),
              Positioned(
                left: w * k - 6,
                top: 3,
                width: 12,
                height: 12,
                child: const DecoratedBox(decoration: BoxDecoration(color: _accent, shape: BoxShape.circle)),
              ),
              if (hoverT != null)
                Positioned(
                  left: (w * hoverT! / d - tw / 2 - 2).clamp(0.0, math.max(0.0, w - tw - 4)),
                  bottom: 26,
                  child: IgnorePointer(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Container(
                        width: tw + 4,
                        height: th + 4,
                        decoration: BoxDecoration(
                            border: Border.all(color: Colors.white, width: 2), borderRadius: BorderRadius.circular(6), color: Colors.black),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          // scrub previews are free: a frame is a pure function of time
                          child: CustomPaint(
                            size: Size(tw, th),
                            painter: TsvgFramePainter(doc: c.doc!, layout: layout, t: hoverT!, options: c.options, media: c.media),
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(color: const Color(0xcc000000), borderRadius: BorderRadius.circular(4)),
                        child: Text(
                          _fmtT(hoverT!) + (c.chapterAt(hoverT!) != null ? ' · ${c.label(c.chapterAt(hoverT!)!.label)}' : ''),
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ]),
                  ),
                ),
            ]),
          ),
        ),
      );
    });
  }

  Widget _rail(Color col) => DecoratedBox(decoration: BoxDecoration(color: col, borderRadius: BorderRadius.circular(2)));
}
