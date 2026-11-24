// The drawing backend interface. The core walks the document and resolves
// every value; a backend only draws resolved geometry. The Flutter backend
// draws on a dart:ui Canvas; the validator uses a recording no-op backend.
import 'dart:math' as math;

import 'color.dart';
import 'path_data.dart';

/// Geometry in the current user space.
sealed class TsvgShape {
  const TsvgShape();
}

class RectShape extends TsvgShape {
  const RectShape(this.x, this.y, this.w, this.h, [this.r = 0]);
  final double x, y, w, h, r;
}

/// Full ellipse, or a pie slice (centre → arc → centre) when [sweep] is set.
/// Angles are radians, 0 = +x axis, clockwise (canvas convention).
/// With [open] (0.2.2 `arc="1"`) the slice is just the arc, no lines to the centre.
class EllipseShape extends TsvgShape {
  const EllipseShape(this.cx, this.cy, this.rx, this.ry, {this.start, this.sweep, this.open = false});
  final double cx, cy, rx, ry;
  final double? start, sweep;
  final bool open;
}

class LineShape extends TsvgShape {
  const LineShape(this.x1, this.y1, this.x2, this.y2);
  final double x1, y1, x2, y2;
}

/// SVG path data translated by (dx, dy).
class PathShape extends TsvgShape {
  const PathShape(this.d, this.cmds, {this.dx = 0, this.dy = 0});
  final String d;
  final List<PathCmd> cmds;
  final double dx, dy;
}

class GradientStop {
  const GradientStop(this.at, this.color);
  final double at;
  final Rgba color;
}

/// A resolved fill/stroke paint.
sealed class TsvgPaint {
  const TsvgPaint();
}

class SolidPaint extends TsvgPaint {
  const SolidPaint(this.color);
  final Rgba color;
}

class LinearPaint extends TsvgPaint {
  const LinearPaint(this.x1, this.y1, this.x2, this.y2, this.stops);
  final double x1, y1, x2, y2;
  final List<GradientStop> stops;
}

/// Two-point radial gradient: focal (fx, fy) radius 0 → centre (x, y) radius r.
class RadialPaint extends TsvgPaint {
  const RadialPaint(this.fx, this.fy, this.x, this.y, this.r, this.stops);
  final double fx, fy, x, y, r;
  final List<GradientStop> stops;
}

/// `shadow="dx dy blur color"` in user units (the backend maps offsets to
/// device space like Canvas2D does).
class ShadowSpec {
  const ShadowSpec(this.dx, this.dy, this.blur, this.color);
  final double dx, dy, blur;
  final Rgba color;
}

/// One CSS filter function (0.9 `filter`, Canvas2D `ctx.filter`): grayscale,
/// sepia, contrast, brightness, saturate, hue-rotate (degrees), invert, opacity
/// (amounts) or blur (standard deviation in device pixels).
class FilterOp {
  const FilterOp(this.name, this.v);
  final String name;
  final double v;
  @override
  String toString() => '$name($v)';
}

/// The CSS Filter Effects colour matrix of a colour filter function: 5×4,
/// row-major (r g b a offset per output channel), offsets in 0–1 units, on
/// unpremultiplied sRGB. Null for blur (not a colour filter) and unknown names.
List<double>? filterMatrix(String name, double v) {
  double c01(double x) => x.isNaN ? 0 : math.max(0.0, math.min(1.0, x));
  switch (name) {
    case 'grayscale':
      final s = 1 - c01(v);
      return [
        0.2126 + 0.7874 * s, 0.7152 - 0.7152 * s, 0.0722 - 0.0722 * s, 0, 0, //
        0.2126 - 0.2126 * s, 0.7152 + 0.2848 * s, 0.0722 - 0.0722 * s, 0, 0,
        0.2126 - 0.2126 * s, 0.7152 - 0.7152 * s, 0.0722 + 0.9278 * s, 0, 0,
        0, 0, 0, 1, 0,
      ];
    case 'sepia':
      final s = 1 - c01(v);
      return [
        0.393 + 0.607 * s, 0.769 - 0.769 * s, 0.189 - 0.189 * s, 0, 0, //
        0.349 - 0.349 * s, 0.686 + 0.314 * s, 0.168 - 0.168 * s, 0, 0,
        0.272 - 0.272 * s, 0.534 - 0.534 * s, 0.131 + 0.869 * s, 0, 0,
        0, 0, 0, 1, 0,
      ];
    case 'saturate':
      final s = math.max(0.0, v);
      return [
        0.213 + 0.787 * s, 0.715 - 0.715 * s, 0.072 - 0.072 * s, 0, 0, //
        0.213 - 0.213 * s, 0.715 + 0.285 * s, 0.072 - 0.072 * s, 0, 0,
        0.213 - 0.213 * s, 0.715 - 0.715 * s, 0.072 + 0.928 * s, 0, 0,
        0, 0, 0, 1, 0,
      ];
    case 'hue-rotate':
      final a = v * math.pi / 180, cs = math.cos(a), sn = math.sin(a);
      return [
        0.213 + cs * 0.787 - sn * 0.213, 0.715 - cs * 0.715 - sn * 0.715, 0.072 - cs * 0.072 + sn * 0.928, 0, 0, //
        0.213 - cs * 0.213 + sn * 0.143, 0.715 + cs * 0.285 + sn * 0.140, 0.072 - cs * 0.072 - sn * 0.283, 0, 0,
        0.213 - cs * 0.213 - sn * 0.787, 0.715 - cs * 0.715 + sn * 0.715, 0.072 + cs * 0.928 + sn * 0.072, 0, 0,
        0, 0, 0, 1, 0,
      ];
    case 'invert':
      final a = c01(v), d = 1 - 2 * a;
      return [d, 0, 0, 0, a, 0, d, 0, 0, a, 0, 0, d, 0, a, 0, 0, 0, 1, 0];
    case 'brightness':
      final a = math.max(0.0, v);
      return [a, 0, 0, 0, 0, 0, a, 0, 0, 0, 0, 0, a, 0, 0, 0, 0, 0, 1, 0];
    case 'contrast':
      final a = math.max(0.0, v), o = 0.5 - 0.5 * a;
      return [a, 0, 0, 0, o, 0, a, 0, 0, o, 0, 0, a, 0, o, 0, 0, 0, 1, 0];
    case 'opacity':
      final a = c01(v);
      return [1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, a, 0];
  }
  return null;
}

/// Applies a [filterMatrix] to an unpremultiplied colour (channels 0–1), clamped like Skia.
List<double> applyFilterMatrix(List<double> m, double r, double g, double b, double a) => [
      for (var i = 0; i < 4; i++)
        math.max(0.0, math.min(1.0, m[i * 5] * r + m[i * 5 + 1] * g + m[i * 5 + 2] * b + m[i * 5 + 3] * a + m[i * 5 + 4])),
    ];

/// Canvas2D state that applies to every draw call: globalAlpha,
/// globalCompositeOperation, the shadow and the filter.
class DrawState {
  const DrawState({this.alpha = 1, this.blend, this.shadow, this.filters = const [], this.dash});
  final double alpha;
  final String? blend;
  final ShadowSpec? shadow;

  /// Canvas2D `ctx.filter` (blur, 0.9 `filter`), fixed when a node set it, in
  /// the order CSS applies them: the node's own blur, its filter functions,
  /// then what it inherited. Blur radii are in device pixels. Empty = none.
  final List<FilterOp> filters;

  /// Canvas2D line dash (`dash="a b …"`, 0.2.2), already normalised: even
  /// length, all finite and ≥ 0, not all zero. Null = solid.
  final List<double>? dash;
  static const DrawState plain = DrawState();
  DrawState copyWith({double? alpha, String? blend, ShadowSpec? shadow, bool noShadow = false, List<FilterOp>? filters, List<double>? dash}) =>
      DrawState(
          alpha: alpha ?? this.alpha,
          blend: blend ?? this.blend,
          shadow: noShadow ? null : (shadow ?? this.shadow),
          filters: filters ?? this.filters,
          dash: dash ?? this.dash);
}

class StrokeSpec {
  const StrokeSpec(this.width, {this.roundCap = true, this.roundJoin = true, this.trim, this.cap});
  final double width;
  final bool roundCap, roundJoin;

  /// Line cap from the `cap` attribute ('round', 'butt', 'square'); null = [roundCap].
  final String? cap;

  /// Path reveal (`draw`): stroke only the first [trim] × total length of each subpath.
  final double? trim;
}

class FontSpec {
  const FontSpec(this.families, this.size, this.weight, this.italic, {this.ls = 0});
  final List<String> families;
  final double size;
  final double weight;
  final bool italic;

  /// Letter spacing in layout units (Canvas2D `letterSpacing`, 0.6): added after
  /// every character and included in measured widths.
  final double ls;
  String get key => '${families.join(',')}|$size|$weight|$italic|$ls';
}

/// A point on a path at some distance along it, with the tangent angle (radians).
class PathPoint {
  const PathPoint(this.x, this.y, this.a);
  final double x, y, a;
}

/// Samples a path by length (SVG getTotalLength / getPointAtLength).
abstract class PathSampler {
  double get length;

  /// The point at distance [s] (clamped to the path), angle from the next half unit.
  PathPoint at(double s);
}

class ImageSize {
  const ImageSize(this.width, this.height);
  final double width, height;
}

abstract class TsvgCanvas {
  void save();
  void restore();
  void translate(double dx, double dy);
  void rotate(double radians);
  /// Scale by [sx] horizontally and [sy] (default [sx]) vertically.
  void scale(double sx, [double? sy]);

  /// Canvas2D `transform(1, ky, kx, 1, 0, 0)` (0.9 `skx` / `sky`): x' = x + kx·y, y' = ky·x + y.
  void skew(double kx, double ky);

  /// sqrt(|det|) of the current user → device transform (how many device
  /// pixels one layout unit covers). Used to fix `blur` in device pixels.
  double get deviceScale => 1;

  /// Intersect the clip with the union of [shapes].
  void clip(List<TsvgShape> shapes);
  void fill(TsvgShape shape, TsvgPaint paint, DrawState st);
  void stroke(TsvgShape shape, TsvgPaint paint, StrokeSpec spec, DrawState st);

  /// Advance width of a single line.
  double measureText(String text, FontSpec font);

  /// One line of text, vertically centred on [y] (Canvas2D textBaseline
  /// "middle"); [align] is left | center | right | start | end.
  void text(String text, double x, double y, FontSpec font, String align, TsvgPaint? fill, TsvgPaint? stroke,
      double strokeWidth, DrawState st);

  /// Length sampler for SVG path data (text on a path, 0.6); null when the
  /// backend cannot measure paths.
  PathSampler? pathSampler(String d) => null;

  /// Natural size of an image, or null when it is not (yet) loaded.
  ImageSize? imageSize(String ref);
  void image(String ref, double x, double y, double w, double h, DrawState st);

  /// A `<video>` clip node about to be drawn at [req] (web: the media layer's
  /// `frame(ct, rate, vol, node)`). Returns an image ref holding the clip's
  /// picture at `req.ct`, or null when none is ready (the core then draws the
  /// poster, else a grey box). Backends that play clips elsewhere (the Flutter
  /// player overlays) record the request here.
  String? videoFrame(VideoRequest req) => null;

  /// Masks: [beginLayer] … node … [beginMask] … mask shapes … [restore] [restore].
  bool get supportsMasks => true;
  void beginLayer();
  void beginMask();
}

/// One `<video>` node as drawn in a frame: which clip, where in it, and its box
/// in the current user space (x, y, w, h, corner radius r) under [st].
class VideoRequest {
  const VideoRequest({
    required this.src,
    required this.path,
    required this.ct,
    required this.rate,
    required this.vol,
    required this.key,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.r,
    required this.fit,
    required this.st,
  });

  /// The node's src (asset id or path) and the file path it resolves to.
  final String src, path;

  /// Clip time (s), clip rate, clip volume (0 = muted).
  final double ct, rate, vol;

  /// One clip per node (web: node line + start + rate): two nodes may show the same file at different times.
  final String key;
  final double x, y, w, h, r;
  final String fit;
  final DrawState st;
}

/// Clip time of a `<video>` node: `start + max(0, t − t0)·rate` (t = scene
/// time T, t0 = the node's `at`, T0); wraps at
/// [len] when [loop], else clamps to `len − 0.04` (when the length is known).
double clipTime({required double start, required double rate, required double t, required double t0, required double len, required bool loop}) {
  var ct = start + math.max(0.0, t - t0) * rate;
  if (loop && len > 0) {
    ct = ct.remainder(len); // JS %: keeps the dividend's sign
  } else if (len > 0) {
    ct = math.min(ct, len - 0.04);
  }
  return ct;
}

/// No-op backend for dry runs (the validator).
class RecordingCanvas extends TsvgCanvas {
  int draws = 0;
  @override
  bool get supportsMasks => false;
  @override
  void save() {}
  @override
  void restore() {}
  @override
  void translate(double dx, double dy) {}
  @override
  void rotate(double radians) {}
  @override
  void scale(double sx, [double? sy]) {}
  @override
  void skew(double kx, double ky) {}
  @override
  void clip(List<TsvgShape> shapes) {}
  @override
  void fill(TsvgShape shape, TsvgPaint paint, DrawState st) => draws++;
  @override
  void stroke(TsvgShape shape, TsvgPaint paint, StrokeSpec spec, DrawState st) => draws++;
  @override
  double measureText(String text, FontSpec font) => text.length * 10.0;
  @override
  void text(String text, double x, double y, FontSpec font, String align, TsvgPaint? fill, TsvgPaint? stroke,
          double strokeWidth, DrawState st) =>
      draws++;
  @override
  ImageSize? imageSize(String ref) => null;
  @override
  void image(String ref, double x, double y, double w, double h, DrawState st) => draws++;
  @override
  void beginLayer() {}
  @override
  void beginMask() {}
}
