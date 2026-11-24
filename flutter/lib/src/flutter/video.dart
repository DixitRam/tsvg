// <video> clips in the player (port of makeVideo in web/tsvg-player.js): one
// VideoPlayerController per clip node, kept in sync with the timeline, shown
// as overlays over the painted frame.
//
// The painter only draws a clip's poster (or a grey box); TsvgPlayer asks the
// frame which <video> nodes are visible (collectTsvgVideos: their clip time,
// box and full canvas transform) and puts a VideoPlayer widget on each one,
// transformed by that matrix, clipped to the corner radius and faded by the
// node's opacity.
//
// Limitation: the overlays sit above the whole painted frame, so shapes drawn
// after a clip in the same frame (captions on a clip, a card over it) appear
// under the video instead of over it; clip="url(#…)" and masks on a clip are
// not applied to the overlay (rounded corners and opacity are).
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import '../core/source.dart';
import 'painter.dart';
import 'video_source_web.dart' if (dart.library.io) 'video_source_io.dart';

class _Clip {
  _Clip(this.path);
  final String path;
  VideoPlayerController? ctl;
  bool ready = false, failed = false, disposed = false, seeking = false;
  double target = 0; // clip time the frame wants (s)
  double speed = -1, volume = -1; // last applied
}

/// The clips of one document. [sync] once per built frame.
class TsvgVideoClips extends ChangeNotifier {
  TsvgVideoClips(this.source);
  final TsvgSource source;
  final Map<String, _Clip> _clips = {};
  bool _disposed = false;

  /// Errors while opening clips (the poster stays up).
  final List<String> errors = [];

  /// Keeps every clip in [draws] in sync with the frame and pauses the rest
  /// (web: seek when paused if |drift| > 0.03 s; when playing, play at clip
  /// rate × player speed and re-seek if drift > 0.3 s; clips not drawn pause).
  void sync(List<TsvgVideoDraw> draws, {required bool playing, required double speed, required double gain}) {
    final used = <_Clip>{};
    for (final d in draws) {
      final r = d.req;
      final clip = _clips.putIfAbsent('${r.key}|${r.path}', () => _open(r.path));
      used.add(clip);
      clip.target = math.max(0, r.ct);
      final ctl = clip.ctl;
      if (!clip.ready || ctl == null) continue;
      final vol = r.vol > 0 ? math.min(1.0, math.max(0.0, r.vol * gain)) : 0.0;
      if (vol != clip.volume) {
        clip.volume = vol;
        ctl.setVolume(vol);
      }
      final sp = math.max(0.0625, (r.rate > 0 ? r.rate : 1) * speed);
      if (sp != clip.speed) {
        clip.speed = sp;
        ctl.setPlaybackSpeed(sp);
      }
      final v = ctl.value;
      final drift = v.position.inMicroseconds / 1e6 - clip.target;
      if (playing) {
        // value.position refreshes every 100 ms while playing: allow for that staleness
        if (!v.isPlaying) {
          ctl.seekTo(_dur(clip.target));
          ctl.play();
        } else if (drift.abs() > 0.3 + 0.1 * sp) {
          ctl.seekTo(_dur(clip.target));
        }
      } else {
        if (v.isPlaying) ctl.pause();
        if (drift.abs() > 0.03) _seek(clip);
      }
    }
    for (final c in _clips.values) {
      if (!used.contains(c) && c.ready && (c.ctl?.value.isPlaying ?? false)) c.ctl!.pause();
    }
  }

  /// The controller showing a drawn clip, once it can show frames.
  VideoPlayerController? controllerFor(TsvgVideoDraw d) {
    final c = _clips['${d.req.key}|${d.req.path}'];
    return c != null && c.ready ? c.ctl : null;
  }

  static Duration _dur(double s) => Duration(microseconds: (s * 1e6).round());

  // paused: one seek at a time, then catch up with the latest target
  Future<void> _seek(_Clip c) async {
    if (c.seeking) return;
    c.seeking = true;
    try {
      while (!c.disposed) {
        final want = c.target;
        await c.ctl!.seekTo(_dur(want));
        if (c.disposed || c.ctl!.value.isPlaying || (c.target - want).abs() <= 0.03) break;
      }
    } catch (_) {
    } finally {
      c.seeking = false;
    }
  }

  _Clip _open(String path) {
    final c = _Clip(path);
    () async {
      try {
        final bytes = await source.read(path);
        if (bytes == null) throw StateError('$path not found');
        if (c.disposed) return;
        final ctl = videoController(bytes, path);
        c.ctl = ctl;
        await ctl.initialize();
        if (c.disposed) {
          await ctl.dispose();
          return;
        }
        await ctl.setVolume(0); // muted until a frame says vol > 0
        c.volume = 0;
        c.ready = true;
        if (!_disposed) notifyListeners(); // the next frame seeks it and shows it
      } catch (e) {
        c.failed = true;
        errors.add('video $path: $e');
      }
    }();
    return c;
  }

  /// The overlays for [draws]: a [VideoPlayer] per ready clip, placed by its
  /// canvas transform, clipped to [frame] (the letterboxed picture) and to the
  /// clip's rounded box, faded by its opacity. Ignores pointers.
  Widget overlay(List<TsvgVideoDraw> draws, Rect frame) {
    final kids = <Widget>[];
    for (final d in draws) {
      final ctl = controllerFor(d);
      if (ctl == null || !(d.alpha > 0)) continue;
      final r = d.req;
      final size = ctl.value.size;
      if (size.isEmpty || r.w <= 0 || r.h <= 0) continue;
      final m = Matrix4.fromFloat64List(d.transform)..multiply(Matrix4.translationValues(r.x, r.y, 0));
      Widget v = SizedBox(
        width: r.w,
        height: r.h,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(r.r),
          child: FittedBox(
            fit: switch (r.fit) { 'contain' => BoxFit.contain, 'fill' => BoxFit.fill, _ => BoxFit.cover },
            clipBehavior: Clip.hardEdge,
            child: SizedBox(width: size.width, height: size.height, child: VideoPlayer(ctl)),
          ),
        ),
      );
      if (d.alpha < 1) v = Opacity(opacity: d.alpha, child: v);
      kids.add(Positioned(left: 0, top: 0, child: Transform(transform: m, child: v)));
    }
    if (kids.isEmpty) return const SizedBox.shrink();
    return IgnorePointer(
      child: ClipRect(clipper: _RectClipper(frame), child: Stack(clipBehavior: Clip.none, children: kids)),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    for (final c in _clips.values) {
      c.disposed = true;
      c.ctl?.dispose();
    }
    _clips.clear();
    super.dispose();
  }
}

class _RectClipper extends CustomClipper<Rect> {
  _RectClipper(this.rect);
  final Rect rect;
  @override
  Rect getClip(Size size) => rect;
  @override
  bool shouldReclip(_RectClipper old) => old.rect != rect;
}
