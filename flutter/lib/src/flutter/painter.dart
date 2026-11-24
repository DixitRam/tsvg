// Flutter backend: draws resolved TSVG geometry on a dart:ui Canvas, plus a
// CustomPainter and an offscreen renderer.
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import '../core/canvas.dart';
import '../core/color.dart';
import '../core/model.dart';
import '../core/path_data.dart';
import '../core/render.dart';
import 'media.dart';

/// CSS generic / system family names → names Flutter can resolve.
const Map<String, List<String>> _familyAliases = {
  // Chrome (the reference) does not know ui-monospace and falls through to the next family
  'ui-monospace': [],
  'monospace': ['Menlo', 'SF Mono', 'Courier New', 'Roboto Mono', 'DejaVu Sans Mono', 'monospace'],
  'ui-serif': ['New York', 'Times New Roman', 'serif'],
  'serif': ['Times New Roman', 'Times', 'Noto Serif', 'serif'],
  'sans-serif': [],
  'system-ui': [],
  '-apple-system': [],
  'ui-sans-serif': [],
};

/// The reference engine's system stack after the document fonts.
const List<String> _systemStack = [
  'Noto Sans Gujarati',
  'Gujarati Sangam MN',
  'Apple Symbols',
  'Apple Color Emoji',
  'Noto Color Emoji',
];

ui.BlendMode? _blend(String? b) => switch (b) {
      null || 'source-over' || 'normal' => null,
      'multiply' => ui.BlendMode.multiply,
      'screen' => ui.BlendMode.screen,
      'overlay' => ui.BlendMode.overlay,
      'darken' => ui.BlendMode.darken,
      'lighten' => ui.BlendMode.lighten,
      'color-dodge' => ui.BlendMode.colorDodge,
      'color-burn' => ui.BlendMode.colorBurn,
      'hard-light' => ui.BlendMode.hardLight,
      'soft-light' => ui.BlendMode.softLight,
      'difference' => ui.BlendMode.difference,
      'exclusion' => ui.BlendMode.exclusion,
      'hue' => ui.BlendMode.hue,
      'saturation' => ui.BlendMode.saturation,
      'color' => ui.BlendMode.color,
      'luminosity' => ui.BlendMode.luminosity,
      'lighter' || 'plus' => ui.BlendMode.plus,
      'copy' => ui.BlendMode.src,
      'xor' => ui.BlendMode.xor,
      'source-in' => ui.BlendMode.srcIn,
      'source-out' => ui.BlendMode.srcOut,
      'source-atop' => ui.BlendMode.srcATop,
      'destination-over' => ui.BlendMode.dstOver,
      'destination-in' => ui.BlendMode.dstIn,
      'destination-out' => ui.BlendMode.dstOut,
      'destination-atop' => ui.BlendMode.dstATop,
      _ => null,
    };

ui.Color _color(Rgba c, [double alpha = 1]) => ui.Color(c.withOpacity(alpha).argb);

final Map<String, ui.Path> _pathCache = {};

ui.Path _buildPath(List<PathCmd> cmds) {
  final p = ui.Path();
  for (final c in cmds) {
    switch (c) {
      case MoveTo():
        p.moveTo(c.x, c.y);
      case LineTo():
        p.lineTo(c.x, c.y);
      case CubicTo():
        p.cubicTo(c.x1, c.y1, c.x2, c.y2, c.x, c.y);
      case QuadTo():
        p.quadraticBezierTo(c.x1, c.y1, c.x, c.y);
      case ArcTo():
        if (c.rx == 0 || c.ry == 0) {
          p.lineTo(c.x, c.y);
        } else {
          p.arcToPoint(Offset(c.x, c.y),
              radius: Radius.elliptical(c.rx, c.ry), rotation: c.rotation, largeArc: c.largeArc, clockwise: c.sweep);
        }
      case ClosePath():
        p.close();
    }
  }
  return p;
}

ui.Path shapeToPath(TsvgShape s) {
  switch (s) {
    case RectShape():
      final r = Rect.fromPoints(Offset(s.x, s.y), Offset(s.x + s.w, s.y + s.h));
      final p = ui.Path();
      if (s.r > 0) {
        p.addRRect(RRect.fromRectAndRadius(r, Radius.circular(s.r)));
      } else {
        p.addRect(r);
      }
      return p;
    case EllipseShape():
      final r = Rect.fromCenter(center: Offset(s.cx, s.cy), width: s.rx * 2, height: s.ry * 2);
      final p = ui.Path();
      if (s.sweep == null) {
        p.addOval(r);
      } else if (s.open) {
        if (s.sweep! > 0) p.arcTo(r, s.start!, s.sweep!, true);
      } else {
        p.moveTo(s.cx, s.cy);
        if (s.sweep! > 0) p.arcTo(r, s.start!, s.sweep!, false);
        p.close();
      }
      return p;
    case LineShape():
      return ui.Path()
        ..moveTo(s.x1, s.y1)
        ..lineTo(s.x2, s.y2);
    case PathShape():
      if (_pathCache.length > 1000) _pathCache.clear();
      final base = _pathCache[s.d] ??= _buildPath(s.cmds);
      return (s.dx == 0 && s.dy == 0) ? base : base.shift(Offset(s.dx, s.dy));
  }
}

/// Like Canvas2D setLineDash([L*k, L+1]): the first k × total length of each subpath.
ui.Path _trim(ui.Path p, double k) {
  final metrics = p.computeMetrics().toList();
  final total = metrics.fold<double>(0, (s, m) => s + m.length);
  final len = total * k;
  final out = ui.Path();
  for (final m in metrics) {
    out.addPath(m.extractPath(0, math.min(len, m.length)), Offset.zero);
  }
  return out;
}

/// Canvas2D setLineDash: on/off lengths, the pattern restarts on every subpath.
ui.Path _dash(ui.Path p, List<double> dash) {
  final total = dash.fold<double>(0, (a, b) => a + b);
  if (!(total > 0)) return p;
  final out = ui.Path();
  for (final m in p.computeMetrics()) {
    var d = 0.0, i = 0;
    while (d < m.length) {
      final len = dash[i % dash.length];
      if (i.isEven && len > 0) out.addPath(m.extractPath(d, math.min(d + len, m.length)), Offset.zero);
      d += len;
      i++;
      if (i > 1000000) break;
    }
  }
  return out;
}

/// [TsvgCanvas] over a dart:ui [Canvas].
class FlutterTsvgCanvas extends TsvgCanvas {
  FlutterTsvgCanvas(this.canvas, [this.media]);
  final Canvas canvas;
  final TsvgMedia? media;

  static final Map<String, double> _widths = {};
  // per font: distance from the line top to where the "middle" baseline anchor sits
  static final Map<String, double> _middles = {};

  @override
  void save() => canvas.save();
  @override
  void restore() => canvas.restore();
  @override
  void translate(double dx, double dy) => canvas.translate(dx, dy);
  @override
  void rotate(double radians) => canvas.rotate(radians);
  @override
  void scale(double sx, [double? sy]) => canvas.scale(sx, sy ?? sx);

  @override
  double get deviceScale {
    final m = canvas.getTransform();
    return math.sqrt((m[0] * m[5] - m[1] * m[4]).abs());
  }

  /// Canvas2D `filter = blur(σ px)` applies per draw call, before compositing:
  /// draw into a layer blurred by σ (device px), composite it with the blend mode.
  void _blurred(DrawState st, void Function(DrawState st) draw) {
    if (!(st.blur > 0)) return draw(st);
    // saveLayer image filters are scaled by the current transform, so convert
    // device pixels back to user units
    final k = deviceScale;
    final sigma = k > 0 ? st.blur / k : st.blur;
    final lp = ui.Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.decal);
    final bm = _blend(st.blend);
    if (bm != null) lp.blendMode = bm;
    canvas.saveLayer(null, lp);
    draw(DrawState(alpha: st.alpha, shadow: st.shadow));
    canvas.restore();
  }

  @override
  void clip(List<TsvgShape> shapes) {
    final p = ui.Path();
    for (final s in shapes) {
      p.addPath(shapeToPath(s), Offset.zero);
    }
    canvas.clipPath(p);
  }

  /// Builds a paint; gradients are shifted by (-ox, -oy) (text is drawn translated).
  ui.Paint? _paint(TsvgPaint p, DrawState st, {double ox = 0, double oy = 0}) {
    final paint = ui.Paint()..isAntiAlias = true;
    final bm = _blend(st.blend);
    if (bm != null) paint.blendMode = bm;
    switch (p) {
      case SolidPaint():
        paint.color = _color(p.color, st.alpha);
      case LinearPaint():
        if (p.stops.isEmpty || (p.x1 == p.x2 && p.y1 == p.y2)) return null;
        if (p.stops.length == 1) {
          paint.color = _color(p.stops.first.color, st.alpha);
        } else {
          paint.shader = ui.Gradient.linear(
            Offset(p.x1 - ox, p.y1 - oy),
            Offset(p.x2 - ox, p.y2 - oy),
            [for (final s in p.stops) _color(s.color, st.alpha)],
            [for (final s in p.stops) s.at],
          );
        }
      case RadialPaint():
        if (p.stops.isEmpty || !(p.r > 0)) return null;
        if (p.stops.length == 1) {
          paint.color = _color(p.stops.first.color, st.alpha);
        } else {
          final focal = (p.fx != p.x || p.fy != p.y) ? Offset(p.fx - ox, p.fy - oy) : null;
          paint.shader = ui.Gradient.radial(
            Offset(p.x - ox, p.y - oy),
            p.r,
            [for (final s in p.stops) _color(s.color, st.alpha)],
            [for (final s in p.stops) s.at],
            TileMode.clamp,
            null,
            focal,
          );
        }
    }
    return paint;
  }

  /// Canvas2D shadows: offset in device space, blur sigma = blur / 2.
  void _shadow(DrawState st, ui.Paint base, void Function(ui.Paint p) draw) {
    final sh = st.shadow;
    if (sh == null || sh.color.a <= 0 || !(sh.blur > 0 || sh.dx != 0 || sh.dy != 0)) return;
    if (sh.dx.isNaN || sh.dy.isNaN || sh.blur.isNaN) return;
    final m = canvas.getTransform();
    final a = m[0], b = m[1], c = m[4], d = m[5];
    final det = a * d - b * c;
    if (det == 0) return;
    final k = math.sqrt(det.abs());
    final X = sh.dx * k, Y = sh.dy * k;
    final lx = (d * X - c * Y) / det, ly = (-b * X + a * Y) / det;
    final sp = ui.Paint()
      ..isAntiAlias = true
      ..style = base.style
      ..strokeWidth = base.strokeWidth
      ..strokeCap = base.strokeCap
      ..strokeJoin = base.strokeJoin
      ..color = base.color
      ..shader = base.shader
      ..blendMode = base.blendMode
      ..colorFilter = ui.ColorFilter.mode(_color(sh.color), ui.BlendMode.srcIn);
    if (sh.blur > 0) sp.maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, sh.blur / 2);
    canvas.save();
    canvas.translate(lx, ly);
    draw(sp);
    canvas.restore();
  }

  @override
  void fill(TsvgShape shape, TsvgPaint paint, DrawState st) => _blurred(st, (st) => _fill(shape, paint, st));

  void _fill(TsvgShape shape, TsvgPaint paint, DrawState st) {
    if (shape is LineShape) return;
    final p = _paint(paint, st);
    if (p == null) return;
    final path = shapeToPath(shape);
    _shadow(st, p, (sp) => canvas.drawPath(path, sp));
    canvas.drawPath(path, p);
  }

  @override
  void stroke(TsvgShape shape, TsvgPaint paint, StrokeSpec spec, DrawState st) =>
      _blurred(st, (st) => _stroke(shape, paint, spec, st));

  void _stroke(TsvgShape shape, TsvgPaint paint, StrokeSpec spec, DrawState st) {
    final p = _paint(paint, st);
    if (p == null || !(spec.width > 0)) return;
    p
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = spec.width
      ..strokeCap = switch (spec.cap) {
        'butt' => ui.StrokeCap.butt,
        'square' => ui.StrokeCap.square,
        'round' => ui.StrokeCap.round,
        _ => spec.roundCap ? ui.StrokeCap.round : ui.StrokeCap.butt,
      }
      ..strokeJoin = spec.roundJoin ? ui.StrokeJoin.round : ui.StrokeJoin.miter;
    var path = shapeToPath(shape);
    if (spec.trim != null) {
      path = _trim(path, spec.trim!); // `draw` replaces the line dash, as in the reference
    } else if (st.dash != null) {
      path = _dash(path, st.dash!);
    }
    _shadow(st, p, (sp) => canvas.drawPath(path, sp));
    canvas.drawPath(path, p);
  }

  static List<String> _fallbacks(FontSpec f) {
    final out = <String>[];
    void add(String s) {
      if (!out.contains(s)) out.add(s);
    }

    for (final fam in f.families) {
      final alias = _familyAliases[fam];
      if (alias != null) {
        alias.forEach(add);
      } else {
        add(fam);
      }
    }
    _systemStack.forEach(add);
    return out;
  }

  static TextStyle _style(FontSpec f, ui.Paint? fg) {
    final fams = _fallbacks(f);
    final w = f.weight.clamp(1, 1000).toDouble();
    return TextStyle(
      fontFamily: fams.isEmpty ? null : fams.first,
      fontFamilyFallback: fams.length > 1 ? fams.sublist(1) : null,
      fontSize: f.size,
      fontWeight: FontWeight.values[((w / 100).round() - 1).clamp(0, 8)],
      // like CSS font-optical-sizing: auto (opsz = size in px) and the requested weight
      fontVariations: [ui.FontVariation('wght', w), ui.FontVariation('opsz', f.size)],
      fontStyle: f.italic ? FontStyle.italic : FontStyle.normal,
      letterSpacing: f.ls != 0 ? f.ls : null,
      foreground: fg,
      color: fg == null ? const Color(0xff000000) : null,
    );
  }

  static StrutStyle _strut(FontSpec f) {
    final fams = _fallbacks(f);
    return StrutStyle(
      fontFamily: fams.isEmpty ? null : fams.first,
      fontFamilyFallback: fams.length > 1 ? fams.sublist(1) : null,
      fontSize: f.size,
      forceStrutHeight: true,
    );
  }

  static TextPainter _layout(String text, FontSpec f, ui.Paint? fg) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: _style(f, fg)),
      textDirection: TextDirection.ltr,
      strutStyle: _strut(f),
    )..layout();
    return tp;
  }

  void _measure(String text, FontSpec f) {
    final key = '${f.key}|$text';
    if (_widths.containsKey(key)) return;
    if (_widths.length > 5000) {
      _widths.clear();
      _middles.clear();
    }
    final tp = _layout(text, f, null);
    _widths[key] = tp.width;
    // Canvas2D textBaseline "middle" = middle of the em box, whose ascent and
    // descent are the font ascent and descent normalised to sum to 1 em.
    final asc = tp.computeDistanceToActualBaseline(TextBaseline.alphabetic);
    final desc = tp.height - asc;
    _middles[f.key] = asc - (asc + desc > 0 ? f.size * (asc - desc) / (asc + desc) / 2 : 0);
    tp.dispose();
  }

  @override
  double measureText(String text, FontSpec font) {
    if (!(font.size > 0)) return 0;
    _measure(text, font);
    return _widths['${font.key}|$text']!;
  }

  @override
  void text(String text, double x, double y, FontSpec font, String align, TsvgPaint? fill, TsvgPaint? stroke,
          double strokeWidth, DrawState st) =>
      _blurred(st, (st) => _text(text, x, y, font, align, fill, stroke, strokeWidth, st));

  void _text(String text, double x, double y, FontSpec font, String align, TsvgPaint? fill, TsvgPaint? stroke,
      double strokeWidth, DrawState st) {
    if (text.isEmpty || !(font.size > 0)) return;
    if (fill == null && stroke == null) return;
    _measure(text, font);
    final w = _widths['${font.key}|$text']!;
    final mid = _middles[font.key]!;
    final dx = switch (align) { 'center' => x - w / 2, 'right' || 'end' => x - w, _ => x };
    final dy = y - mid;
    canvas.save();
    canvas.translate(dx, dy);
    void draw(ui.Paint p) {
      final tp = _layout(text, font, p);
      tp.paint(canvas, Offset.zero);
      tp.dispose();
    }

    ui.Paint? sp;
    if (stroke != null && strokeWidth > 0) {
      sp = _paint(stroke, st, ox: dx, oy: dy);
      sp
        ?..style = ui.PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeJoin = ui.StrokeJoin.round;
    }
    final fp = fill != null ? _paint(fill, st, ox: dx, oy: dy) : null;
    if (sp != null) {
      _shadow(st, sp, draw);
      draw(sp);
    }
    if (fp != null) {
      _shadow(st, fp, draw);
      draw(fp);
    }
    canvas.restore();
  }

  static final Map<String, _Sampler> _samplers = {};

  @override
  PathSampler? pathSampler(String d) {
    if (_samplers.length > 200) _samplers.clear();
    return _samplers[d] ??= _Sampler(shapeToPath(PathShape(d, parsePathData(d))));
  }

  @override
  ImageSize? imageSize(String ref) {
    final img = media?.image(ref);
    return img == null ? null : ImageSize(img.width.toDouble(), img.height.toDouble());
  }

  @override
  void image(String ref, double x, double y, double w, double h, DrawState st) =>
      _blurred(st, (st) => _image(ref, x, y, w, h, st));

  void _image(String ref, double x, double y, double w, double h, DrawState st) {
    final img = media?.image(ref);
    if (img == null) return;
    final dst = Rect.fromLTWH(x, y, w, h);
    final p = ui.Paint()
      ..isAntiAlias = true
      ..filterQuality = FilterQuality.medium
      ..color = _color(Rgba.black, st.alpha);
    final bm = _blend(st.blend);
    if (bm != null) p.blendMode = bm;
    // shadow of the image's box (opaque images)
    _shadow(st, ui.Paint()..color = _color(Rgba.black, st.alpha), (sp) => canvas.drawRect(dst, sp));
    canvas.drawImageRect(img, Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()), dst, p);
  }

  @override
  void beginLayer() => canvas.saveLayer(null, ui.Paint());
  @override
  void beginMask() => canvas.saveLayer(null, ui.Paint()..blendMode = ui.BlendMode.dstIn);
}

/// SVG-style length sampling over every subpath of a path.
class _Sampler extends PathSampler {
  _Sampler(ui.Path p) : metrics = p.computeMetrics().toList() {
    length = metrics.fold(0.0, (a, m) => a + m.length);
  }
  final List<ui.PathMetric> metrics;
  @override
  late final double length;

  Offset _pos(double s) {
    s = math.max(0, math.min(length, s));
    for (final m in metrics) {
      if (s <= m.length || identical(m, metrics.last)) {
        return m.getTangentForOffset(math.min(s, m.length))?.position ?? Offset.zero;
      }
      s -= m.length;
    }
    return Offset.zero;
  }

  @override
  PathPoint at(double s) {
    final a = _pos(s), b = _pos(s + 0.5);
    final c = s + 0.5 > length ? _pos(s - 0.5) : null;
    final ang = c != null ? math.atan2(a.dy - c.dy, a.dx - c.dx) : math.atan2(b.dy - a.dy, b.dx - a.dx);
    return PathPoint(a.dx, a.dy, ang);
  }
}

/// Draws one frame into [size]: letterboxed on [background], scaled to fit,
/// then [zoom] around the centre and shifted by [pan] (logical pixels).
/// Everything is vector, so zoom stays sharp. Returns the error, if any.
Object? paintTsvgFrame(
  Canvas canvas,
  Size size, {
  required TsvgDoc doc,
  required TsvgLayout layout,
  required double t,
  required Map<String, String> options,
  TsvgMedia? media,
  double zoom = 1,
  Offset pan = Offset.zero,
  Color? background = const Color(0xff000000),
}) {
  if (background != null) canvas.drawRect(Offset.zero & size, ui.Paint()..color = background);
  final s = math.min(size.width / layout.w, size.height / layout.h) * zoom;
  final ox = (size.width - layout.w * s) / 2 + pan.dx, oy = (size.height - layout.h * s) / 2 + pan.dy;
  final count = canvas.getSaveCount();
  canvas.save();
  canvas.translate(ox, oy);
  canvas.scale(s, s);
  canvas.clipRect(Rect.fromLTWH(0, 0, layout.w, layout.h));
  Object? err;
  try {
    renderFrame(FlutterTsvgCanvas(canvas, media), doc, t, options, layout);
  } catch (e) {
    err = e;
  }
  canvas.restoreToCount(count);
  if (err != null) {
    final tp = TextPainter(
      text: TextSpan(text: 'render error: $err', style: const TextStyle(color: Color(0xffff4d5a), fontSize: 14)),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: math.max(10, size.width - 24));
    tp.paint(canvas, const Offset(12, 12));
    tp.dispose();
  }
  return err;
}

/// A [CustomPainter] for one frame.
class TsvgFramePainter extends CustomPainter {
  TsvgFramePainter({
    required this.doc,
    required this.layout,
    required this.t,
    required this.options,
    this.media,
    this.zoom = 1,
    this.pan = Offset.zero,
    this.background = const Color(0xff000000),
    this.onError,
  }) : _mediaVersion = media?.version ?? 0;

  final TsvgDoc doc;
  final TsvgLayout layout;
  final double t;
  final Map<String, String> options;
  final TsvgMedia? media;
  final double zoom;
  final Offset pan;
  final Color? background;
  final void Function(Object error)? onError;

  @override
  void paint(Canvas canvas, Size size) {
    final err = paintTsvgFrame(canvas, size,
        doc: doc, layout: layout, t: t, options: options, media: media, zoom: zoom, pan: pan, background: background);
    if (err != null) onError?.call(err);
  }

  @override
  bool shouldRepaint(TsvgFramePainter old) =>
      old.doc != doc ||
      old.layout != layout ||
      old.t != t ||
      old.options != options ||
      old.media != media ||
      old.zoom != zoom ||
      old.pan != pan ||
      old.background != background ||
      (media?.version ?? 0) != old._mediaVersion;

  final int _mediaVersion;
}

/// Renders a frame offscreen at [width] pixels wide (height from the layout).
/// Throws the render error, if any.
Future<ui.Image> renderTsvgImage({
  required TsvgDoc doc,
  required TsvgLayout layout,
  required double t,
  required Map<String, String> options,
  TsvgMedia? media,
  int? width,
}) async {
  final w = width ?? layout.w.round();
  final h = (w * layout.h / layout.w).round();
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  canvas.scale(w / layout.w, w / layout.w);
  renderFrame(FlutterTsvgCanvas(canvas, media), doc, t, options, layout);
  final pic = rec.endRecording();
  final img = await pic.toImage(w, h);
  pic.dispose();
  return img;
}

/// PNG bytes of a rendered frame.
Future<Uint8List> renderTsvgPng({
  required TsvgDoc doc,
  required TsvgLayout layout,
  required double t,
  required Map<String, String> options,
  TsvgMedia? media,
  int? width,
}) async {
  final img = await renderTsvgImage(doc: doc, layout: layout, t: t, options: options, media: media, width: width);
  final bd = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return bd!.buffer.asUint8List();
}
