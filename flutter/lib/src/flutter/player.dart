// TsvgPlayer: a video player for TSVG documents with controls modelled on
// native mobile players (same interaction model as web/tsvg-player.js): tap
// shows the controls (centre ∓10 · play/pause · ±10), double-tap a side skips,
// scrubber with chapter ticks and frame previews, volume / mute (a master gain
// on the document mix), captions from <say> lines, a settings menu (speed,
// captions, every <option>, layout), fullscreen, pinch / wheel zoom that
// re-renders sharp. Mouse: click plays / pauses, double-click is fullscreen.
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

  /// The viewer's volume (0–1) and mute: a master gain on top of the document mix.
  double volume = 1;
  bool muted = false;

  /// The master gain the audio runs at (0 when muted).
  double get gain => muted ? 0 : volume;

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
    _audio!.setMaster(gain);
    await _audio!.setRate(rate);
    await _audio!.prepare(audioPlan(d, options));
    _syncLines();
  }

  Future<void> play() async {
    final d = doc;
    if (d == null || playing) return;
    if (t >= d.duration - 0.05) t = 0;
    playing = true;
    notifyListeners();
    // like the web player: load the clips first, then start the clock and the audio together
    try {
      await _ensureAudio();
    } catch (e) {
      debugPrint('tsvg audio: $e');
    }
    if (!playing) return;
    _ticker ??= Ticker(_onTick, debugLabel: 'tsvg');
    _last = Duration.zero;
    if (!_ticker!.isActive) _ticker!.start();
    await _resyncAudio();
  }

  void pause() {
    if (!playing) return;
    playing = false;
    _ticker?.stop();
    _audio?.stop();
    notifyListeners();
  }

  void toggle() => playing ? pause() : play();

  /// Hard re-sync of every clip to the playhead (play, seek, option change).
  Future<void> _resyncAudio() async {
    await _audio?.sync(t, playing: playing);
  }

  /// Drift / start statistics of the audio engine (null before audio loads).
  TsvgAudioStats? get audioStats => _audio?.stats;

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
    if (prev != t) _audio?.update(t);
    if (t >= d.duration) {
      t = d.duration;
      pause();
      return;
    }
    notifyListeners();
  }

  /// Playback speed. Speed is the player's (TSVG 0.2): the timeline and every
  /// audio clip run at [r], pitch preserved where the platform allows.
  void setRate(double r) {
    rate = r;
    unawaited(_audio?.setRate(r));
    notifyListeners();
  }

  /// Sets the volume (clamped to 0–1); a volume above 0 unmutes.
  void setVolume(double v) {
    volume = v.clamp(0.0, 1.0).toDouble();
    if (volume > 0) muted = false;
    _audio?.setMaster(gain);
    notifyListeners();
  }

  /// Mutes / unmutes (unmuting at volume 0 restores half volume).
  void toggleMute() {
    muted = !muted;
    if (!muted && volume == 0) volume = 0.5;
    _audio?.setMaster(gain);
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

const Color _accent = Color(0xffff2d48);

/// Double-tap window; a single tap on a side waits this long before toggling the controls.
const Duration _doubleTap = Duration(milliseconds: 300);
const List<double> _speeds = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2];

String _rateStr(double r) => r == r.roundToDouble() ? r.toInt().toString() : r.toString();

/// A TSVG video player with controls modelled on native mobile players
/// (and kept in step with the web player, web/tsvg-player.js):
///
/// * Touch: a tap shows / hides the controls (never pauses), a double-tap on
///   the left / right side skips ∓10 s, pinch zooms (re-rendered, sharp), a drag
///   pans while zoomed.
/// * Mouse: a click plays / pauses, a double-click toggles fullscreen, moving
///   over the player shows the controls; the wheel zooms.
/// * The controls show while paused and hide 3 s after the last interaction
///   while playing. Settings menu: speed, captions, every document option, layout.
class TsvgPlayer extends StatefulWidget {
  const TsvgPlayer({
    super.key,
    this.source,
    this.controller,
    this.autoplay = false,
    this.options,
    this.onOptions,
    this.allowFullscreen = true,
    this.controls = true,
  }) : assert(source != null || controller != null);

  /// What to play (ignored when [controller] is already loaded).
  final TsvgSource? source;
  final TsvgPlayerController? controller;
  final bool autoplay;

  /// Initial option values (e.g. {'lang': 'gu'}).
  final Map<String, String>? options;
  final void Function(Map<String, String> options)? onOptions;
  final bool allowFullscreen;

  /// false draws frames only: no controls, captions, gestures or keys (posters, thumbnails).
  final bool controls;

  @override
  State<TsvgPlayer> createState() => _TsvgPlayerState();
}

class _MenuRow {
  _MenuRow(this.id, this.label, this.cur, this.choices, this.val);
  final String id, label, cur, val;
  final List<(String, String)> choices;
}

class _TsvgPlayerState extends State<TsvgPlayer> {
  late TsvgPlayerController c;
  bool _ownController = false;
  final FocusNode _focus = FocusNode(debugLabel: 'tsvg player');

  // controls overlay
  bool _shown = true;
  Timer? _hideTimer;
  bool _wasPlaying = false;
  bool _dragging = false;
  bool _menu = false;
  String? _menuSub;
  bool _volHover = false;

  // ripple after a skip: 0 = left, 1 = right
  int _ripple = -1;
  Timer? _rippleTimer;

  // surface gestures
  Size _size = Size.zero;
  final Map<int, Offset> _pts = {};
  ({double z0, double d0, Offset focal0, Offset pan0})? _pinch;
  ({Offset start, Offset pan0, bool moved, PointerDeviceKind kind})? _drag;
  Timer? _tapTimer, _dblWindow;
  double _lastX = -1;

  // scrub preview
  double? _hoverT;

  bool get _inFullscreen => ModalRoute.of(context)?.settings.name == 'tsvg-fullscreen';

  @override
  void initState() {
    super.initState();
    _ownController = widget.controller == null;
    c = widget.controller ?? TsvgPlayerController(options: widget.options);
    if (widget.onOptions != null) c.onOptions = widget.onOptions;
    c.addListener(_changed);
    _wasPlaying = c.playing;
    if (!c.ready && widget.source != null) {
      c.load(widget.source!).then((_) {
        if (widget.autoplay && mounted) c.play();
      });
    } else if (widget.autoplay) {
      c.play();
    }
    _show(true);
  }

  @override
  void didUpdateWidget(TsvgPlayer old) {
    super.didUpdateWidget(old);
    if (widget.source != null && widget.source != old.source) c.load(widget.source!);
  }

  void _changed() {
    if (!mounted) return;
    if (c.playing != _wasPlaying) {
      _wasPlaying = c.playing;
      // paused (or ended): controls stay up; started: they hide 3 s later
      _show(true);
    }
    setState(() {});
  }

  @override
  void dispose() {
    c.removeListener(_changed);
    if (_ownController) c.dispose();
    for (final t in [_hideTimer, _rippleTimer, _tapTimer, _dblWindow]) {
      t?.cancel();
    }
    _focus.dispose();
    super.dispose();
  }

  // ── controls visibility (web: showControls) ──
  void _show(bool on) {
    if (!widget.controls) return;
    _hideTimer?.cancel();
    final keep = !c.playing || _menu || _dragging;
    final next = on || keep;
    if (next && c.playing && !keep) {
      _hideTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) _show(false);
      });
    }
    if (next != _shown && mounted) setState(() => _shown = next);
  }

  void _openMenu([String? sub]) {
    setState(() {
      _menu = true;
      _menuSub = sub;
    });
    _show(true);
  }

  void _closeMenu() {
    setState(() {
      _menu = false;
      _menuSub = null;
    });
    _show(true);
  }

  void _skip(int dir) {
    c.skip(dir * 10.0);
    _rippleTimer?.cancel();
    setState(() => _ripple = dir < 0 ? 0 : 1);
    _rippleTimer = Timer(const Duration(milliseconds: 500), () {
      if (mounted) setState(() => _ripple = -1);
    });
  }

  void _stepRate(int dir) {
    final i = _speeds.indexOf(c.rate);
    c.setRate(_speeds[((i < 0 ? 3 : i) + dir).clamp(0, _speeds.length - 1)]);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final ch = e.character;
    if (k == LogicalKeyboardKey.escape) {
      if (_menu) {
        _closeMenu();
      } else if (_inFullscreen) {
        _fullscreen();
      } else {
        return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.keyK) {
      if (e is KeyDownEvent) c.toggle();
    } else if (k == LogicalKeyboardKey.keyJ || k == LogicalKeyboardKey.arrowLeft) {
      _skip(-1);
    } else if (k == LogicalKeyboardKey.keyL || k == LogicalKeyboardKey.arrowRight) {
      _skip(1);
    } else if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
      c.setVolume((c.muted ? 0 : c.volume) + (k == LogicalKeyboardKey.arrowUp ? 0.1 : -0.1));
    } else if (k == LogicalKeyboardKey.keyM) {
      if (e is KeyDownEvent) c.toggleMute();
    } else if (k == LogicalKeyboardKey.keyC) {
      if (e is KeyDownEvent) c.setCaptions(!c.captions);
    } else if (k == LogicalKeyboardKey.keyF) {
      if (e is KeyDownEvent) _fullscreen();
    } else if (ch == '>' || ch == '<') {
      _stepRate(ch == '>' ? 1 : -1);
    } else if (ch != null && RegExp(r'^[0-9]$').hasMatch(ch)) {
      c.seek(c.duration * int.parse(ch) / 10);
    } else {
      return KeyEventResult.ignored;
    }
    _show(true);
    return KeyEventResult.handled;
  }

  // fullscreen = a black route holding a player on the same controller (+ immersive mode on phones)
  void _fullscreen() {
    if (!widget.allowFullscreen) return;
    final nav = Navigator.maybeOf(context);
    if (nav == null) return;
    if (_inFullscreen) {
      nav.pop();
      return;
    }
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky).catchError((_) {}));
    nav
        .push(
          PageRouteBuilder<void>(
            settings: const RouteSettings(name: 'tsvg-fullscreen'),
            transitionDuration: const Duration(milliseconds: 150),
            reverseTransitionDuration: const Duration(milliseconds: 150),
            pageBuilder: (_, _, _) => ColoredBox(
              color: Colors.black,
              child: TsvgPlayer(controller: c, allowFullscreen: true),
            ),
            transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
          ),
        )
        .then((_) => SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge).catchError((_) {}));
  }

  // ── the video surface (web: wire() surface handlers) ──
  Offset _fromCentre(Offset local) => local - Offset(_size.width / 2, _size.height / 2);

  void _onDown(PointerDownEvent e) {
    _focus.requestFocus();
    if (e.kind == PointerDeviceKind.mouse && e.buttons != kPrimaryMouseButton) return;
    _pts[e.pointer] = e.localPosition;
    if (_pts.length == 2) {
      final ps = _pts.values.toList();
      _pinch = (
        z0: c.zoom,
        d0: math.max(1.0, (ps[0] - ps[1]).distance),
        focal0: _fromCentre((ps[0] + ps[1]) / 2),
        pan0: c.pan,
      );
      _drag = null;
    } else if (_pts.length == 1) {
      _drag = (start: e.localPosition, pan0: c.pan, moved: false, kind: e.kind);
    }
  }

  void _onMove(PointerMoveEvent e) {
    if (!_pts.containsKey(e.pointer)) return;
    _pts[e.pointer] = e.localPosition;
    final p = _pinch;
    if (p != null && _pts.length == 2) {
      final ps = _pts.values.toList();
      final z = (p.z0 * (ps[0] - ps[1]).distance / p.d0).clamp(1.0, 12.0);
      final f = _fromCentre((ps[0] + ps[1]) / 2);
      // keep the content under the first focal point under the current one
      c.setView(z, f - (p.focal0 - p.pan0) * (z / p.z0));
      return;
    }
    final d = _drag;
    if (d == null) return;
    final delta = e.localPosition - d.start;
    final moved = d.moved || delta.dx.abs() + delta.dy.abs() > 6;
    if (moved != d.moved) _drag = (start: d.start, pan0: d.pan0, moved: moved, kind: d.kind);
    if (c.zoom > 1.01 && moved) c.setView(c.zoom, d.pan0 + delta);
  }

  void _onUp(PointerEvent e, {bool cancel = false}) {
    if (_pts.remove(e.pointer) == null) return;
    if (_pinch != null) {
      if (_pts.isEmpty) _pinch = null;
      return;
    }
    final d = _drag;
    _drag = null;
    if (d == null || d.moved || cancel) return;
    final x = e.localPosition.dx / math.max(1, _size.width);
    final dbl = _dblWindow?.isActive ?? false;
    _dblWindow?.cancel();
    _tapTimer?.cancel();
    if (d.kind == PointerDeviceKind.mouse) {
      // click = play / pause, double-click = fullscreen
      if (dbl) {
        _dblWindow = null;
        _fullscreen();
        return;
      }
      _dblWindow = Timer(const Duration(milliseconds: 300), () {});
      _tapTimer = Timer(const Duration(milliseconds: 220), () {
        if (!mounted) return;
        if (_menu) {
          _closeMenu();
        } else {
          c.toggle();
          _show(true);
        }
      });
      return;
    }
    // touch / pen: tap = show / hide controls; double-tap a side = ∓10 s
    final side = x < 0.35 ? 0 : (x > 0.65 ? 1 : -1);
    if (side >= 0 && dbl && (x - _lastX).abs() < 0.25) {
      _skip(side == 0 ? -1 : 1);
      _lastX = x;
      _dblWindow = Timer(_doubleTap, () {});
      return;
    }
    _lastX = x;
    _dblWindow = Timer(_doubleTap, () {});
    void tap() {
      if (!mounted) return;
      if (_menu) return _closeMenu();
      _show(!(_shown && c.playing));
    }

    if (side >= 0) {
      _tapTimer = Timer(_doubleTap, tap); // same length as the window: a skip never follows a toggle
    } else {
      tap();
    }
  }

  void _onWheel(PointerSignalEvent e) {
    if (e is PointerScrollEvent) {
      if (e.scrollDelta.dy.abs() < 1) return;
      c.zoomAt(c.zoom * math.exp(-e.scrollDelta.dy / 400), _fromCentre(e.localPosition));
    } else if (e is PointerScaleEvent) {
      c.zoomAt(c.zoom * e.scale, _fromCentre(e.localPosition));
    }
  }

  @override
  Widget build(BuildContext context) {
    final body = LayoutBuilder(
      builder: (context, box) {
        _size = box.biggest;
        if (c.loadError != null) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Cannot open: ${c.loadError}', style: const TextStyle(color: Color(0xffff6b6b))),
            ),
          );
        }
        if (!c.ready) return const Center(child: CircularProgressIndicator(color: _accent));
        return widget.controls ? _stage(context, box.biggest) : _frame(box.biggest);
      },
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(_inFullscreen ? 0 : 12),
      child: ColoredBox(
        color: Colors.black,
        child: Material(
          type: MaterialType.transparency,
          child: DefaultTextStyle(
            style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.3),
            child: !widget.controls
                ? body
                : Focus(
                    focusNode: _focus,
                    autofocus: true,
                    onKeyEvent: _onKey,
                    child: MouseRegion(
                      // mouse only: touch on web also produces (synthesized) hover events
                      onHover: (e) {
                        if (e.kind == PointerDeviceKind.mouse) _show(true);
                      },
                      onExit: (e) {
                        if (e.kind == PointerDeviceKind.mouse && c.playing && !_menu) {
                          _hideTimer?.cancel();
                          _hideTimer = Timer(const Duration(milliseconds: 600), () {
                            if (mounted) _show(false);
                          });
                        }
                      },
                      child: body,
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _frame(Size size) => RepaintBoundary(
    child: CustomPaint(
      size: size,
      painter: TsvgFramePainter(
        doc: c.doc!,
        layout: c.layoutFor(size),
        t: c.t,
        options: c.options,
        media: c.media,
        zoom: c.zoom,
        pan: c.pan,
      ),
    ),
  );

  Widget _stage(BuildContext context, Size size) {
    final doc = c.doc!;
    final layout = c.layoutFor(size);
    final narrow = size.width < 600;
    final short = size.height < 340;
    final line = c.currentLine;
    final ccSize = (size.width * 0.024).clamp(12.0, 22.0);
    final shown = _shown || _menu || _dragging || !c.playing;
    final ended = !c.playing && c.t >= c.duration - 0.05;
    final playIcon = c.playing ? Icons.pause_rounded : (ended ? Icons.replay_rounded : Icons.play_arrow_rounded);
    final playTip = c.playing ? 'Pause (k)' : (ended ? 'Replay' : 'Play (k)');
    final showMid = narrow || !c.playing;
    final gap = (size.width * 0.08).clamp(18.0, 64.0);

    return Stack(
      children: [
        // the picture + gestures
        Positioned.fill(
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerSignal: _onWheel,
            onPointerDown: _onDown,
            onPointerMove: _onMove,
            onPointerUp: _onUp,
            onPointerCancel: (e) => _onUp(e, cancel: true),
            child: MouseRegion(
              cursor: c.zoom > 1.01 ? SystemMouseCursors.grab : MouseCursor.defer,
              child: _frame(size),
            ),
          ),
        ),
        // the controls overlay
        Positioned.fill(
          child: IgnorePointer(
            ignoring: !shown,
            child: AnimatedOpacity(
              key: const ValueKey('tsvg-controls'),
              opacity: shown ? 1 : 0,
              duration: Duration(milliseconds: shown ? 150 : 200),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: narrow
                            ? const BoxDecoration(color: Color(0x88000000))
                            : const BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [Color(0x77000000), Color(0x00000000), Color(0x00000000), Color(0xbb000000)],
                                  stops: [0, 0.22, 0.62, 1],
                                ),
                              ),
                      ),
                    ),
                  ),
                  if (showMid)
                    Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (narrow)
                            _midBtn(
                              Icons.replay_10_rounded,
                              'Back 10 seconds (j)',
                              56,
                              30,
                              () => _skip(-1),
                              key: const ValueKey('tsvg-back'),
                            ),
                          if (narrow) SizedBox(width: gap),
                          _midBtn(playIcon, playTip, 72, 40, c.toggle, key: const ValueKey('tsvg-play')),
                          if (narrow) SizedBox(width: gap),
                          if (narrow)
                            _midBtn(
                              Icons.forward_10_rounded,
                              'Forward 10 seconds (l)',
                              56,
                              30,
                              () => _skip(1),
                              key: const ValueKey('tsvg-fwd'),
                            ),
                        ],
                      ),
                    ),
                  Positioned(left: 0, right: 0, bottom: 0, child: _bottom(layout, narrow, playIcon, playTip)),
                ],
              ),
            ),
          ),
        ),
        // captions (hidden behind the controls on short players, where they'd hit the centre buttons)
        if (line != null && !(short && shown))
          AnimatedPositioned(
            duration: const Duration(milliseconds: 200),
            left: size.width * 0.07,
            right: size.width * 0.07,
            bottom: shown ? (narrow ? 84 : 78) : 16,
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
                      height: 1.55,
                      color: Colors.white,
                      fontFamilyFallback: [for (final f in doc.fonts) f.family],
                    ),
                  ),
                ),
              ),
            ),
          ),
        // double-tap ripples
        for (final i in [0, 1])
          Positioned(
            left: i == 0 ? 0 : null,
            right: i == 1 ? 0 : null,
            top: 0,
            bottom: 0,
            width: size.width * 0.34,
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _ripple == i ? 1 : 0,
                duration: Duration(milliseconds: _ripple == i ? 0 : 350),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment(i == 0 ? -1 : 1, 0),
                      radius: 1.1,
                      colors: const [Color(0x26ffffff), Color(0x12ffffff), Color(0x00ffffff)],
                      stops: const [0, 0.45, 0.7],
                    ),
                  ),
                  // below the centre buttons while the controls are up
                  child: Align(
                    alignment: Alignment(0, shown ? 0.42 : 0),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (i == 0) const Icon(Icons.replay_10_rounded, color: Colors.white, size: 26),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 8),
                          child: Text('10 s', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                        ),
                        if (i == 1) const Icon(Icons.forward_10_rounded, color: Colors.white, size: 26),
                      ],
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
            child: GestureDetector(
              onTap: c.resetZoom,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(color: const Color(0xbb000000), borderRadius: BorderRadius.circular(14)),
                  child: Text(
                    'Zoom ${c.zoom.toStringAsFixed(1)}× · tap to reset',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ),
          ),
        if (_menu)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (_) => _closeMenu(),
              child: ColoredBox(color: narrow ? const Color(0x66000000) : const Color(0x00000000)),
            ),
          ),
        if (_menu)
          if (narrow)
            Positioned(left: 0, right: 0, bottom: 0, child: _menuPanel(size, narrow))
          else
            Positioned(right: 12, bottom: 56, child: _menuPanel(size, narrow)),
      ],
    );
  }

  Widget _midBtn(IconData icon, String tip, double d, double iconSize, VoidCallback onTap, {Key? key}) => Tooltip(
    message: tip,
    child: Material(
      key: key,
      color: const Color(0xaa000000),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          onTap();
          _show(true);
        },
        child: SizedBox(
          width: d,
          height: d,
          child: Icon(icon, size: iconSize, color: Colors.white),
        ),
      ),
    ),
  );

  Widget _btn(Widget child, String tip, VoidCallback onTap, {Key? key, double? width}) => Tooltip(
    message: tip,
    child: InkWell(
      key: key,
      borderRadius: BorderRadius.circular(8),
      hoverColor: const Color(0x1fffffff),
      onTap: () {
        onTap();
        _show(true);
      },
      child: SizedBox(
        width: width ?? 40,
        height: 40,
        child: Center(child: child),
      ),
    ),
  );

  Widget _bottom(TsvgLayout layout, bool narrow, IconData playIcon, String playTip) {
    final ch = c.chapterAt(c.t);
    const ic = Colors.white;
    final volIcon = c.gain == 0
        ? Icons.volume_off_rounded
        : (c.volume < 0.5 ? Icons.volume_down_rounded : Icons.volume_up_rounded);
    final volOpen = !narrow && (_volHover || _dragging);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Timeline(
            controller: c,
            layout: layout,
            hoverT: _hoverT,
            onHover: (t) => setState(() => _hoverT = t),
            onDrag: (on) {
              _dragging = on;
              _show(true);
            },
          ),
          SizedBox(
            height: 40,
            child: Row(
              children: [
                if (!narrow) _btn(Icon(playIcon, color: ic), playTip, c.toggle, key: const ValueKey('tsvg-play2')),
                MouseRegion(
                  onEnter: (_) => setState(() => _volHover = true),
                  onExit: (_) => setState(() => _volHover = false),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _btn(
                        Icon(volIcon, color: ic),
                        c.muted ? 'Unmute (m)' : 'Mute (m)',
                        c.toggleMute,
                        key: const ValueKey('tsvg-mute'),
                      ),
                      if (!narrow)
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          width: volOpen ? 84 : 0,
                          child: volOpen
                              ? SliderTheme(
                                  data: const SliderThemeData(
                                    trackHeight: 3,
                                    activeTrackColor: Colors.white,
                                    inactiveTrackColor: Color(0x55ffffff),
                                    thumbColor: Colors.white,
                                    overlayShape: RoundSliderOverlayShape(overlayRadius: 12),
                                    thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
                                    padding: EdgeInsets.symmetric(horizontal: 8),
                                  ),
                                  child: Slider(
                                    key: const ValueKey('tsvg-volume'),
                                    value: c.gain,
                                    onChanged: (v) {
                                      c.setVolume(v);
                                      _show(true);
                                    },
                                    semanticFormatterCallback: (v) => 'Volume ${(v * 100).round()}%',
                                  ),
                                )
                              : null,
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    '${_fmtT(c.t)} / ${_fmtT(c.duration)}',
                    style: const TextStyle(fontSize: 13, fontFeatures: [FontFeature.tabularFigures()]),
                  ),
                ),
                Expanded(
                  child: Text(
                    ch != null ? '· ${c.label(ch.label)}' : '',
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    softWrap: false,
                    style: const TextStyle(fontSize: 13, color: Color(0xccffffff)),
                  ),
                ),
                _btn(
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(c.captions ? Icons.closed_caption_rounded : Icons.closed_caption_off_outlined, color: ic),
                      Container(
                        width: 18,
                        height: 2,
                        color: c.captions ? _accent : Colors.transparent,
                        margin: const EdgeInsets.only(top: 1),
                      ),
                    ],
                  ),
                  c.captions ? 'Captions off (c)' : 'Captions on (c)',
                  () => c.setCaptions(!c.captions),
                  key: const ValueKey('tsvg-cc'),
                ),
                if (!narrow)
                  _btn(
                    Text('${_rateStr(c.rate)}×', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    'Playback speed',
                    () => _openMenu('__rate'),
                    key: const ValueKey('tsvg-rate'),
                    width: 48,
                  ),
                _btn(
                  const Icon(Icons.settings_rounded, color: ic),
                  'Settings',
                  () => _menu ? _closeMenu() : _openMenu(),
                  key: const ValueKey('tsvg-settings'),
                ),
                if (widget.allowFullscreen)
                  _btn(
                    Icon(_inFullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded, color: ic, size: 26),
                    _inFullscreen ? 'Exit fullscreen (f)' : 'Fullscreen (f)',
                    _fullscreen,
                    key: const ValueKey('tsvg-fullscreen'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── settings menu (web: menuRows / renderMenu) ──
  List<_MenuRow> _menuRows() {
    final doc = c.doc!;
    return [
      _MenuRow('__rate', 'Playback speed', c.rate == 1 ? 'Normal' : '${_rateStr(c.rate)}×', [
        for (final r in _speeds) ('$r', r == 1 ? 'Normal' : '${_rateStr(r)}×'),
      ], '${c.rate}'),
      _MenuRow('__cc', 'Captions', c.captions ? 'On' : 'Off', const [
        ('on', 'On'),
        ('off', 'Off'),
      ], c.captions ? 'on' : 'off'),
      for (final o in doc.options)
        _MenuRow(
          o.id,
          c.label(o.label),
          c.label(o.choices.where((x) => x.id == c.options[o.id]).firstOrNull?.label ?? c.options[o.id] ?? ''),
          [for (final x in o.choices) (x.id, c.label(x.label))],
          c.options[o.id] ?? '',
        ),
      if (doc.layouts.length > 1)
        _MenuRow('__layout', 'Layout', c.layoutPref == 'auto' ? 'Auto' : c.layoutPref, [
          ('auto', 'Auto (fit screen)'),
          for (final l in doc.layouts) (l.id, '${l.id} · ${l.w.round()}×${l.h.round()}'),
        ], c.layoutPref),
    ];
  }

  void _pick(String row, String v, bool narrow) {
    switch (row) {
      case '__rate':
        c.setRate(double.parse(v));
      case '__cc':
        c.setCaptions(v == 'on');
      case '__layout':
        c.setLayout(v);
      default:
        c.setOption(row, v);
    }
    if (narrow) {
      _closeMenu();
    } else {
      setState(() => _menuSub = null);
    }
  }

  Widget _menuPanel(Size size, bool narrow) {
    final fonts = [for (final f in c.doc!.fonts) f.family];
    final rows = _menuRows();
    final sub = _menuSub == null ? null : rows.where((r) => r.id == _menuSub).firstOrNull;

    Widget item({required List<Widget> children, required VoidCallback onTap, Key? key, bool head = false}) => InkWell(
      key: key,
      onTap: onTap,
      hoverColor: const Color(0x14ffffff),
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: head
            ? const BoxDecoration(
                border: Border(bottom: BorderSide(color: Color(0x1affffff))),
              )
            : null,
        child: Row(children: children),
      ),
    );
    TextStyle ts([double fs = 14, FontWeight? w, Color? col]) =>
        TextStyle(fontSize: fs, fontWeight: w, color: col, fontFamilyFallback: fonts);

    final List<Widget> children = sub == null
        ? [
            for (final r in rows)
              item(
                key: ValueKey('tsvg-menu-${r.id}'),
                onTap: () => setState(() => _menuSub = r.id),
                children: [
                  Expanded(
                    child: Text(r.label, style: ts(), overflow: TextOverflow.ellipsis),
                  ),
                  const SizedBox(width: 12),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: narrow ? size.width * 0.5 : 140),
                    child: Text(r.cur, style: ts(13, null, const Color(0xb3ffffff)), overflow: TextOverflow.ellipsis),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.chevron_right_rounded, size: 20, color: Color(0xccffffff)),
                ],
              ),
          ]
        : [
            item(
              head: true,
              onTap: () => setState(() => _menuSub = null),
              children: [
                const Icon(Icons.chevron_left_rounded, size: 22, color: Color(0xccffffff)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(sub.label, style: ts(14, FontWeight.w600), overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
            for (final (id, label) in sub.choices)
              item(
                key: ValueKey('tsvg-choice-${sub.id}-$id'),
                onTap: () => _pick(sub.id, id, narrow),
                children: [
                  SizedBox(
                    width: 20,
                    child: id == sub.val ? const Icon(Icons.check_rounded, size: 20, color: Colors.white) : null,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(label, style: ts(), overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
          ];
    if (sub == null && c.audioErrors.isNotEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
          child: Text(
            'Audio: ${c.audioErrors.length} clip(s) could not load on this platform',
            style: const TextStyle(fontSize: 11, color: Color(0x99ffffff)),
          ),
        ),
      );
    }

    final list = ListView(shrinkWrap: true, padding: EdgeInsets.zero, children: children);
    return GestureDetector(
      // taps inside the menu must not reach the backdrop
      onTapDown: (_) {},
      child: Container(
        constraints: narrow
            ? BoxConstraints(maxHeight: size.height - 8)
            : BoxConstraints(
                minWidth: 250,
                maxWidth: math.max(250, math.min(320, size.width - 24)),
                maxHeight: size.height - 72,
              ),
        width: narrow ? null : 280,
        padding: EdgeInsets.fromLTRB(0, narrow ? 4 : 6, 0, narrow ? 14 : 6),
        decoration: BoxDecoration(
          color: const Color(0xf51c1c1e),
          borderRadius: narrow ? const BorderRadius.vertical(top: Radius.circular(16)) : BorderRadius.circular(12),
          boxShadow: const [BoxShadow(color: Color(0xaa000000), blurRadius: 40, offset: Offset(0, 10))],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (narrow)
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.fromLTRB(0, 4, 0, 6),
                decoration: BoxDecoration(color: const Color(0x55ffffff), borderRadius: BorderRadius.circular(2)),
              ),
            Flexible(child: list),
          ],
        ),
      ),
    );
  }
}

/// Progress rail with chapter ticks; drag / tap to seek with a live preview
/// frame (thumbnail + time · chapter); mouse hover previews too.
class _Timeline extends StatefulWidget {
  const _Timeline({
    required this.controller,
    required this.layout,
    required this.onHover,
    required this.hoverT,
    required this.onDrag,
  });
  final TsvgPlayerController controller;
  final TsvgLayout layout;
  final void Function(double? t) onHover;
  final double? hoverT;
  final void Function(bool dragging) onDrag;

  @override
  State<_Timeline> createState() => _TimelineState();
}

class _TimelineState extends State<_Timeline> {
  bool _hover = false, _drag = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final d = c.duration;
    final hoverT = widget.hoverT;
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
        double at(double x) => (x / w).clamp(0.0, 1.0) * d;
        final k = d > 0 ? c.t / d : 0.0;
        final tw = widget.layout.w > widget.layout.h ? 176.0 : 96.0;
        final th = (tw * widget.layout.h / widget.layout.w).roundToDouble();
        final big = _hover || _drag;
        final railTop = big ? 11.0 : 12.0, railH = big ? 6.0 : 4.0;
        void start(Offset p) {
          setState(() => _drag = true);
          widget.onDrag(true);
          c.seek(at(p.dx));
          widget.onHover(at(p.dx));
        }

        void end() {
          if (!_drag) return;
          setState(() => _drag = false);
          widget.onHover(null);
          widget.onDrag(false);
        }

        final chap = hoverT == null ? null : c.chapterAt(hoverT);
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onHover: (e) {
            if (e.kind == PointerDeviceKind.mouse) widget.onHover(at(e.localPosition.dx));
          },
          onExit: (_) {
            setState(() => _hover = false);
            if (!_drag) widget.onHover(null);
          },
          child: Semantics(
            slider: true,
            label: 'Seek',
            value: _fmtT(c.t),
            child: GestureDetector(
              key: const ValueKey('tsvg-track'),
              behavior: HitTestBehavior.opaque,
              onTapDown: (e) => start(e.localPosition),
              onTapUp: (_) => end(),
              onTapCancel: () {},
              onHorizontalDragStart: (e) => start(e.localPosition),
              onHorizontalDragUpdate: (e) {
                final t = at(e.localPosition.dx);
                c.seek(t);
                widget.onHover(t);
              },
              onHorizontalDragEnd: (_) => end(),
              onHorizontalDragCancel: end,
              child: SizedBox(
                height: 28,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned(left: 0, right: 0, top: railTop, height: railH, child: _rail(const Color(0x40ffffff))),
                    Positioned(left: 0, width: w * k, top: railTop, height: railH, child: _rail(_accent)),
                    for (final ch in c.doc!.chapters.where((ch) => ch.t > 0))
                      Positioned(
                        left: w * ch.t / d - 1,
                        top: 10,
                        width: 3,
                        height: 8,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: const Color(0xbb000000),
                            borderRadius: BorderRadius.circular(1),
                          ),
                        ),
                      ),
                    Positioned(
                      left: w * k - 7,
                      top: 7,
                      width: 14,
                      height: 14,
                      child: AnimatedScale(
                        scale: big ? 1.15 : 0.85,
                        duration: const Duration(milliseconds: 120),
                        child: const DecoratedBox(
                          decoration: BoxDecoration(color: _accent, shape: BoxShape.circle),
                        ),
                      ),
                    ),
                    if (hoverT != null)
                      Positioned(
                        left: (w * hoverT / d - (tw + 4) / 2).clamp(0.0, math.max(0.0, w - tw - 4)),
                        bottom: 30,
                        child: IgnorePointer(
                          child: SizedBox(
                            width: tw + 4,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: tw + 4,
                                  height: th + 4,
                                  decoration: BoxDecoration(
                                    border: Border.all(color: Colors.white, width: 2),
                                    borderRadius: BorderRadius.circular(8),
                                    color: Colors.black,
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(6),
                                    // scrub previews are free: a frame is a pure function of time
                                    child: CustomPaint(
                                      size: Size(tw, th),
                                      painter: TsvgFramePainter(
                                        doc: c.doc!,
                                        layout: widget.layout,
                                        t: hoverT,
                                        options: c.options,
                                        media: c.media,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 5),
                                SizedBox(
                                  height: 20,
                                  child: OverflowBox(
                                    maxWidth: 400,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: const Color(0xcc000000),
                                        borderRadius: BorderRadius.circular(5),
                                      ),
                                      child: Text(
                                        _fmtT(hoverT) + (chap != null ? ' · ${c.label(chap.label)}' : ''),
                                        maxLines: 1,
                                        softWrap: false,
                                        style: const TextStyle(
                                          fontSize: 12,
                                          fontFeatures: [FontFeature.tabularFigures()],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _rail(Color col) => DecoratedBox(
    decoration: BoxDecoration(color: col, borderRadius: BorderRadius.circular(3)),
  );
}
