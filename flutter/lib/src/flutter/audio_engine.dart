// Audio for the player: one audioplayers instance per clip of the audio plan,
// gains per bus from the mix.
//
// Speed belongs to the player (TSVG 0.2): every clip plays at the player's
// rate (audioplayers setPlaybackRate; pitch is preserved on Android M+, Apple
// and web, see README). The timeline is the master clock. [update] runs every
// frame: clips that should sound and do not are started from the right offset,
// clips starting within [lookahead] are primed and started by a timer at the
// exact moment, and a running clip whose reported position drifts more than
// [maxDrift] from the timeline is seeked back (like syncAudio in tsvg-player.js).
import 'dart:async';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../core/audio.dart';
import '../core/model.dart';
import '../core/source.dart';
import 'clip_source_web.dart' if (dart.library.io) 'clip_source_io.dart';

String _mime(String p) {
  final e = p.split('.').last.toLowerCase();
  return const {
        'ogg': 'audio/ogg',
        'opus': 'audio/ogg',
        'mp3': 'audio/mpeg',
        'm4a': 'audio/mp4',
        'aac': 'audio/aac',
        'wav': 'audio/wav',
        'flac': 'audio/flac',
      }[e] ??
      'application/octet-stream';
}

final Stopwatch _clock = Stopwatch()..start();
double _now() => _clock.elapsedMicroseconds / 1e6;

class _Clip {
  _Clip(this.spec, this.path, this.player);
  final TsvgAudio spec;
  final String path;
  final AudioPlayer player;
  double? duration; // seconds, once known
  bool ready = false;
  bool running = false; // started (or starting) and not paused
  bool finished = false; // played to its end since the last start
  Timer? timer; // scheduled start
  double pos = 0; // last reported position (s)
  double posAt = -1; // wall clock of that report
  double settleUntil = 0; // ignore drift until (seek / start latency)
  double lastPosAt = -1; // report already used for drift
  final List<double> drifts = []; // last few drift samples (s of media)
  int learn = 0;
  double lastResync = -10; // wall clock of the last drift resync
  double? tol; // this clip's current drift tolerance (backs off on platforms that keep drifting) // after settling, learn the latency of: 1 = seek+play, 2 = scheduled resume
  final List<StreamSubscription<Object?>> subs = [];
}

/// Drift statistics (for logs and tests).
class TsvgAudioStats {
  int starts = 0, scheduled = 0, resyncs = 0;
  double maxDrift = 0;
  @override
  String toString() => 'starts=$starts scheduled=$scheduled resyncs=$resyncs maxDrift=${maxDrift.toStringAsFixed(3)}s';
}

class TsvgAudioEngine {
  TsvgAudioEngine(this.doc, this.source);
  final TsvgDoc doc;
  final TsvgSource source;

  /// Log starts, resyncs and errors with debugPrint.
  static bool log = false;

  /// Resync a running clip when |audio − timeline| exceeds this (seconds of media).
  double maxDrift = 0.15;

  /// Clips starting within this many timeline seconds are primed and started by a timer.
  double lookahead = 0.4;

  final Map<String, _Clip> _clips = {};
  final Map<String, Uint8List?> _bytes = {};
  Map<String, double> _mix = const {};
  final TsvgAudioStats stats = TsvgAudioStats();

  /// Problems (missing files, codecs the platform cannot decode, …).
  final List<String> errors = [];

  /// Known clip durations by package path (used to time captions).
  final Map<String, double> durations = {};

  bool _disposed = false;
  double _rate = 1;
  double get rate => _rate;
  int _gen = 0; // bumps on every hard sync / stop: stale async starts give up

  // learned platform latencies (wall seconds): a seek-and-play lands this late,
  // a resume() sounds this late. Starts and resyncs aim ahead by them.
  double _seekLead = 0.05, _resumeLead = 0.02;

  // the timeline clock as of the last update
  double _t = 0, _tAt = 0;
  bool _playing = false;
  double _timelineNow() => _playing ? _t + (_now() - _tAt) * _rate : _t;

  String _key(TsvgAudio a) => '${a.bus}|${a.src}|${a.start}';

  void _log(String m) {
    if (log) debugPrint('tsvg audio: $m');
  }

  /// Prepares players for [plan] (new clips load, unused ones are released).
  Future<void> prepare(AudioPlan plan) async {
    _mix = plan.mix;
    final wanted = <String>{};
    final loads = <Future<void>>[];
    for (final c in plan.clips) {
      final path = assetPath(doc, c.src);
      if (path == null) continue;
      final key = _key(c);
      wanted.add(key);
      if (_clips.containsKey(key)) continue;
      final clip = _Clip(c, path, AudioPlayer());
      _clips[key] = clip;
      loads.add(_load(clip));
    }
    for (final k in _clips.keys.where((k) => !wanted.contains(k)).toList()) {
      _release(_clips.remove(k)!);
    }
    await Future.wait(loads);
    applyMix(_mix);
  }

  void _release(_Clip c) {
    c.timer?.cancel();
    for (final s in c.subs) {
      unawaited(s.cancel());
    }
    unawaited(c.player.dispose());
  }

  Future<void> _load(_Clip c) async {
    try {
      final bytes = _bytes.containsKey(c.path) ? _bytes[c.path] : (_bytes[c.path] = await source.read(c.path));
      if (bytes == null) {
        errors.add('audio ${c.path}: not found');
        return;
      }
      double? p0, w0; // (log only) measures the clip's real speed over ≥ 3 s
      c.subs.add(c.player.onPositionChanged.listen((d) {
        c.pos = d.inMicroseconds / 1e6;
        c.posAt = _now();
        if (!log) return;
        if (!c.running || c.posAt < c.settleUntil || (p0 != null && c.pos < p0!)) {
          p0 = null;
        } else if (p0 == null) {
          p0 = c.pos;
          w0 = c.posAt;
        } else if (c.posAt - w0! > 3) {
          _log('${c.path} plays at ${((c.pos - p0!) / (c.posAt - w0!)).toStringAsFixed(3)}× (player rate $_rate)');
          p0 = null;
        }
      }, onError: (Object e) => _log('${c.path}: $e')));
      c.subs.add(c.player.onPlayerComplete.listen((_) {
        c.running = false;
        c.finished = true;
      }, onError: (Object e) => _log('${c.path}: $e')));
      await c.player.setReleaseMode(c.spec.loop ? ReleaseMode.loop : ReleaseMode.stop);
      await c.player.setSource(await clipSource(bytes, c.path, _mime(c.path)));
      await c.player.setPlaybackRate(_rate);
      final d = await c.player.getDuration();
      if (d != null && d > Duration.zero) {
        c.duration = d.inMicroseconds / 1e6;
        durations[c.path] = c.duration!;
      }
      c.ready = true;
    } catch (e) {
      errors.add('audio ${c.path}: $e');
      debugPrint('tsvg audio ${c.path}: $e');
    }
  }

  void applyMix(Map<String, double> mix) {
    _mix = mix;
    for (final c in _clips.values) {
      final g = (mix[c.spec.bus] ?? 1) * c.spec.vol;
      unawaited(c.player.setVolume(g.clamp(0.0, 1.0)).catchError((_) {}));
    }
  }

  /// The player's speed: every clip plays at [r] (pitch preserved where the
  /// platform supports it). Running clips keep going; drift is fixed by [update].
  Future<void> setRate(double r) async {
    if (r == _rate) return;
    _t = _timelineNow();
    _tAt = _now();
    _rate = r;
    for (final c in _clips.values) {
      // scheduled starts were timed for the old rate
      if (c.timer != null) {
        c.timer!.cancel();
        c.timer = null;
      }
      c.settleUntil = _now() + 0.3;
      c.drifts.clear();
    }
    await Future.wait([
      for (final c in _clips.values)
        if (c.ready) c.player.setPlaybackRate(r).catchError((Object e) => _log('rate ${c.path}: $e')),
    ]);
    _log('rate $r');
  }

  /// Where clip [c] should be at timeline time [t] (null = silent).
  double? _localAt(_Clip c, double t) {
    var local = t - c.spec.start;
    if (local < 0) return null;
    final d = c.duration;
    if (c.spec.loop) return d != null && d > 0 ? local % d : local;
    if (d != null && local >= d - 0.02) return null;
    return local;
  }

  Future<void> _startAt(_Clip c, double? local, int gen) async {
    if (!c.ready || _disposed) return;
    c.running = true;
    c.finished = false;
    c.settleUntil = _now() + 0.5;
    c.drifts.clear();
    stats.starts++;
    try {
      var off = (local ?? 0) + _seekLead * _rate;
      final d = c.duration;
      if (c.spec.loop && d != null && d > 0) off %= d;
      c.learn = 1;
      await c.player.seek(Duration(microseconds: (off * 1e6).round()));
      if (gen != _gen || !c.running || _disposed) return;
      await c.player.resume();
      _log('start ${c.path} at ${off.toStringAsFixed(2)}s rate $_rate');
    } catch (e) {
      debugPrint('tsvg audio ${c.path}: $e');
    }
  }

  /// Hard sync (play, seek, option change): stops everything, then starts every
  /// clip that should be sounding at [t] from the right offset.
  Future<void> sync(double t, {required bool playing}) async {
    stop();
    _t = t;
    _tAt = _now();
    _playing = playing;
    if (!playing) return;
    final gen = _gen;
    await Future.wait([
      for (final c in _clips.values)
        if (_localAt(c, t) != null) _startAt(c, _localAt(c, t), gen),
    ]);
    update(_timelineNow());
  }

  /// Called every frame while playing, with the timeline time.
  void update(double t) {
    if (_disposed) return;
    _t = t;
    _tAt = _now();
    _playing = true;
    final now = _tAt;
    for (final c in _clips.values) {
      if (!c.ready) continue;
      final local = _localAt(c, t);
      if (local == null) {
        if (c.running && !(c.spec.loop)) {
          // well before its start (a scheduled start fires up to the resume lead early): quiet
          if (t < c.spec.start - lookahead) {
            c.running = false;
            unawaited(c.player.pause().catchError((_) {}));
          }
        }
        // start ahead of time: prime at 0 and fire a timer at the exact moment
        final ahead = c.spec.start - t;
        if (!c.running && c.timer == null && ahead > 0 && ahead <= lookahead) {
          final gen = _gen;
          stats.scheduled++;
          unawaited(c.player.seek(Duration.zero).catchError((_) {}));
          c.timer = Timer(Duration(microseconds: (math.max(0.0, ahead / _rate - _resumeLead) * 1e6).round()), () {
            c.timer = null;
            if (gen != _gen || _disposed || !_playing) return;
            c.running = true;
            c.finished = false;
            c.settleUntil = _now() + 0.5;
            c.drifts.clear();
            c.learn = 2;
            stats.starts++;
            unawaited(c.player.resume().catchError((Object e) => _log('${c.path}: $e')));
            _log('start ${c.path} on time (scheduled) rate $_rate');
          });
        }
        continue;
      }
      if (!c.running) {
        if (c.timer != null || c.finished) continue;
        unawaited(_startAt(c, local, _gen));
        continue;
      }
      // drift: each new position report, advanced to now, against the timeline.
      // Reports are noisy on some platforms (Android MediaPlayer), so act on the
      // median of the last 5 reports, never on one.
      if (now < c.settleUntil || c.posAt < 0 || c.posAt == c.lastPosAt || now - c.posAt > 0.5) continue;
      c.lastPosAt = c.posAt;
      final d = c.duration;
      if (!c.spec.loop && d != null && c.pos >= d - 0.05) continue; // played out
      var drift = c.pos + (now - c.posAt) * _rate - local;
      if (c.spec.loop && d != null && d > 0) {
        drift %= d;
        if (drift > d / 2) drift -= d;
      }
      c.drifts.add(drift);
      if (c.drifts.length > 5) c.drifts.removeAt(0);
      if (c.drifts.length < 5) continue;
      final med = ([...c.drifts]..sort())[2];
      if (med.abs() > stats.maxDrift) stats.maxDrift = med.abs();
      // first settled measurement after a start / resync: learn the platform latency
      if (c.learn != 0) {
        if (c.learn == 1) _seekLead = (_seekLead - 0.7 * med / _rate).clamp(0.0, 1.0);
        if (c.learn == 2) _resumeLead = (_resumeLead - 0.7 * med / _rate).clamp(0.0, 0.5);
        _log('lead ${c.path}: drift ${med.toStringAsFixed(3)}s → seek lead ${_seekLead.toStringAsFixed(3)}s, '
            'resume lead ${_resumeLead.toStringAsFixed(3)}s');
        c.learn = 0;
      }
      if (med.abs() > (c.tol ?? maxDrift)) {
        // a clip that keeps drifting (e.g. an emulator's slow audio clock) would
        // otherwise be seeked every second: back off, up to 1 s, while it does
        c.tol = now - c.lastResync < 3 ? math.min(1.0, (c.tol ?? maxDrift) * 2) : maxDrift;
        c.lastResync = now;
        stats.resyncs++;
        c.settleUntil = now + 0.5;
        c.learn = 1;
        c.drifts.clear();
        final to = local + _seekLead * _rate;
        _log('resync ${c.path}: drift ${med.toStringAsFixed(3)}s → ${to.toStringAsFixed(2)}s');
        unawaited(c.player.seek(Duration(microseconds: (math.max(0, to) * 1e6).round())).catchError((_) {}));
      }
    }
  }

  void stop() {
    _gen++;
    _playing = false;
    for (final c in _clips.values) {
      c.timer?.cancel();
      c.timer = null;
      c.finished = false;
      if (c.running) {
        c.running = false;
        unawaited(c.player.pause().catchError((_) {}));
      }
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    stop();
    for (final c in _clips.values) {
      _release(c);
    }
    _clips.clear();
  }
}
