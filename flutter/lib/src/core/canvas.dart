// The drawing backend interface. The core walks the document and resolves
// every value; a backend only draws resolved geometry. The Flutter backend
// draws on a dart:ui Canvas; the validator uses a recording no-op backend.
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
class EllipseShape extends TsvgShape {
  const EllipseShape(this.cx, this.cy, this.rx, this.ry, {this.start, this.sweep});
  final double cx, cy, rx, ry;
  final double? start, sweep;
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

/// Canvas2D state that applies to every draw call: globalAlpha,
/// globalCompositeOperation and the shadow.
class DrawState {
  const DrawState({this.alpha = 1, this.blend, this.shadow});
  final double alpha;
  final String? blend;
  final ShadowSpec? shadow;
  static const DrawState plain = DrawState();
  DrawState copyWith({double? alpha, String? blend, ShadowSpec? shadow, bool noShadow = false}) =>
      DrawState(alpha: alpha ?? this.alpha, blend: blend ?? this.blend, shadow: noShadow ? null : (shadow ?? this.shadow));
}

class StrokeSpec {
  const StrokeSpec(this.width, {this.roundCap = true, this.roundJoin = true, this.trim});
  final double width;
  final bool roundCap, roundJoin;

  /// Path reveal (`draw`): stroke only the first [trim] × total length of each subpath.
  final double? trim;
}

class FontSpec {
  const FontSpec(this.families, this.size, this.weight, this.italic);
  final List<String> families;
  final double size;
  final double weight;
  final bool italic;
  String get key => '${families.join(',')}|$size|$weight|$italic';
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
  void scale(double s);

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

  /// Natural size of an image, or null when it is not (yet) loaded.
  ImageSize? imageSize(String ref);
  void image(String ref, double x, double y, double w, double h, DrawState st);

  /// Masks: [beginLayer] … node … [beginMask] … mask shapes … [restore] [restore].
  bool get supportsMasks => true;
  void beginLayer();
  void beginMask();
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
  void scale(double s) {}
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
