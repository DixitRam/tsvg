// Audio for the player: one audioplayers instance per clip of the audio plan,
// gains per bus from the mix. Simple and correct at 1×: every seek / play /
// option change re-syncs all clips to the timeline; clips that start later are
// started by [tick] as the playhead crosses them.
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

class _Clip {
  _Clip(this.spec, this.path, this.player);
  final TsvgAudio spec;
  final String path;
  final AudioPlayer player;
  double? duration; // seconds, once known
  bool ready = false;
  bool running = false;
}

class TsvgAudioEngine {
  TsvgAudioEngine(this.doc, this.source);
  final TsvgDoc doc;
  final TsvgSource source;

  final Map<String, _Clip> _clips = {};
  final Map<String, Uint8List?> _bytes = {};
  Map<String, double> _mix = const {};

  /// Problems (missing files, codecs the platform cannot decode, …).
  final List<String> errors = [];

  /// Known clip durations by package path (used to time captions).
  final Map<String, double> durations = {};

  bool _disposed = false;

  String _key(TsvgAudio a) => '${a.bus}|${a.src}|${a.start}';

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
      final c = _clips.remove(k)!;
      unawaited(c.player.dispose());
    }
    await Future.wait(loads);
    applyMix(_mix);
  }

  Future<void> _load(_Clip c) async {
    try {
      final bytes = _bytes.containsKey(c.path) ? _bytes[c.path] : (_bytes[c.path] = await source.read(c.path));
      if (bytes == null) {
        errors.add('audio ${c.path}: not found');
        return;
      }
      await c.player.setReleaseMode(c.spec.loop ? ReleaseMode.loop : ReleaseMode.stop);
      await c.player.setSource(await clipSource(bytes, c.path, _mime(c.path)));
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

  bool _activeAt(_Clip c, double t) {
    if (t < c.spec.start) return false;
    if (c.spec.loop) return true;
    final d = c.duration;
    return d == null || t < c.spec.start + d;
  }

  Future<void> _startAt(_Clip c, double t) async {
    if (!c.ready || _disposed) return;
    var off = math.max(0.0, t - c.spec.start);
    if (c.spec.loop && c.duration != null && c.duration! > 0) off = off % c.duration!;
    c.running = true;
    try {
      await c.player.seek(Duration(microseconds: (off * 1e6).round()));
      if (c.running && !_disposed) await c.player.resume();
    } catch (e) {
      debugPrint('tsvg audio ${c.path}: $e');
    }
  }

  /// Stops everything, then (when [playing]) starts every clip that should be
  /// sounding at [t] from the right offset.
  Future<void> sync(double t, {required bool playing}) async {
    stop();
    if (!playing) return;
    await Future.wait([
      for (final c in _clips.values)
        if (_activeAt(c, t)) _startAt(c, t),
    ]);
  }

  /// Starts clips whose start time the playhead crossed in (prev, now].
  void tick(double prev, double now) {
    for (final c in _clips.values) {
      if (!c.running && prev < c.spec.start && c.spec.start <= now) unawaited(_startAt(c, now));
    }
  }

  void stop() {
    for (final c in _clips.values) {
      if (c.running) {
        c.running = false;
        unawaited(c.player.pause().catchError((_) {}));
      }
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    for (final c in _clips.values) {
      await c.player.dispose();
    }
    _clips.clear();
  }
}
