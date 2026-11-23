// Colours: the reference's parseColor / lerpAny / withAlpha (used for
// animation and gradient stops) plus a full CSS colour parser for painting.
import 'dart:math' as math;

import 'js.dart';

final RegExp _hex6 = RegExp(r'^#([0-9a-f]{6})([0-9a-f]{2})?$', caseSensitive: false);
final RegExp _hex3 = RegExp(r'^#([0-9a-f]{3})([0-9a-f])?$', caseSensitive: false);
final RegExp _rgbFn = RegExp(r'^rgba?\(([^)]+)\)$');

/// The reference `parseColor`: #rgb, #rgba, #rrggbb, #rrggbbaa, rgb(), rgba().
/// Returns [r, g, b, a] (a in 0..1) or null. Only these forms animate.
List<double>? parseColor(Object? c) {
  if (c is! String) return null;
  var m = _hex6.firstMatch(c);
  if (m != null) {
    final n = int.parse(m[1]!, radix: 16);
    return [
      (n >> 16).toDouble(),
      ((n >> 8) & 255).toDouble(),
      (n & 255).toDouble(),
      m[2] != null ? int.parse(m[2]!, radix: 16) / 255 : 1.0,
    ];
  }
  m = _hex3.firstMatch(c);
  if (m != null) {
    final h = m[1]!;
    return [
      for (var i = 0; i < 3; i++) int.parse(h[i] + h[i], radix: 16).toDouble(),
      m[2] != null ? int.parse(m[2]! + m[2]!, radix: 16) / 255 : 1.0,
    ];
  }
  m = _rgbFn.firstMatch(c);
  if (m != null) {
    final p = m[1]!.split(',').map(toNum).toList();
    return [p[0], p.length > 1 ? p[1] : double.nan, p.length > 2 ? p[2] : double.nan, p.length > 3 ? p[3] : 1.0];
  }
  return null;
}

String _alphaStr(double a) => numStr(double.parse(jsFixed(a, 3)));

/// Interpolates numbers or colours; anything else switches at the end.
Object? lerpAny(Object? a, Object? b, double k) {
  if (a is num && b is num) return a + (b - a) * k;
  final ca = parseColor(a), cb = parseColor(b);
  if (ca != null && cb != null) {
    final rgb = [for (var i = 0; i < 3; i++) numStr(jsRound(ca[i] + (cb[i] - ca[i]) * k))];
    return 'rgba(${rgb.join(',')},${_alphaStr(ca[3] + (cb[3] - ca[3]) * k)})';
  }
  return k < 1 ? a : b;
}

/// Multiplies a colour's alpha (used for gradient stop opacity).
String withAlpha(String c, double a) {
  final p = parseColor(c);
  if (p == null || a >= 1) return c;
  return 'rgba(${numStr(p[0])},${numStr(p[1])},${numStr(p[2])},${_alphaStr(p[3] * a)})';
}

/// A resolved straight-alpha colour: r, g, b in 0..255, a in 0..1.
class Rgba {
  const Rgba(this.r, this.g, this.b, this.a);
  final double r, g, b, a;
  static const Rgba black = Rgba(0, 0, 0, 1);
  static const Rgba transparent = Rgba(0, 0, 0, 0);
  Rgba withOpacity(double k) => Rgba(r, g, b, a * k);

  /// 0xAARRGGBB.
  int get argb {
    int c(double v) => v.isNaN ? 0 : v.round().clamp(0, 255);
    final al = a.isNaN ? 0 : (a.clamp(0.0, 1.0) * 255).round();
    return (al << 24) | (c(r) << 16) | (c(g) << 8) | c(b);
  }

  @override
  bool operator ==(Object other) =>
      other is Rgba && other.r == r && other.g == g && other.b == b && other.a == a;
  @override
  int get hashCode => Object.hash(r, g, b, a);
  @override
  String toString() => 'Rgba($r,$g,$b,$a)';
}

final Map<String, Rgba?> _cssCache = {};

/// Any CSS colour a Canvas2D `fillStyle` accepts that TSVG documents use:
/// hex, rgb()/rgba() (comma or space syntax, %), hsl()/hsla(), named colours,
/// `transparent`. Returns null when the string is not a colour.
Rgba? cssColor(String s) {
  if (_cssCache.containsKey(s)) return _cssCache[s];
  if (_cssCache.length > 4000) _cssCache.clear();
  return _cssCache[s] = _cssColor(s.trim().toLowerCase());
}

final RegExp _fnRe = RegExp(r'^(rgba?|hsla?)\(([^)]*)\)$');

Rgba? _cssColor(String s) {
  if (s.startsWith('#')) {
    final p = parseColor(s);
    return p == null ? null : Rgba(p[0], p[1], p[2], p[3]);
  }
  if (s == 'transparent') return Rgba.transparent;
  final named = _named[s];
  if (named != null) return Rgba(((named >> 16) & 255).toDouble(), ((named >> 8) & 255).toDouble(), (named & 255).toDouble(), 1);
  final m = _fnRe.firstMatch(s);
  if (m == null) return null;
  final parts = m[2]!.replaceAll('/', ' ').split(RegExp(r'[\s,]+')).where((x) => x.isNotEmpty).toList();
  if (parts.length < 3) return null;
  double comp(String x, double scale) {
    if (x.endsWith('%')) return toNum(x.substring(0, x.length - 1)) / 100 * scale;
    return toNum(x);
  }

  double alpha(int i) => parts.length > i ? comp(parts[i], 1).clamp(0.0, 1.0) : 1.0;
  if (m[1]!.startsWith('rgb')) {
    final r = comp(parts[0], 255), g = comp(parts[1], 255), b = comp(parts[2], 255);
    if (r.isNaN || g.isNaN || b.isNaN) return null;
    return Rgba(r.clamp(0, 255).toDouble(), g.clamp(0, 255).toDouble(), b.clamp(0, 255).toDouble(), alpha(3));
  }
  final h = toNum(parts[0].replaceAll('deg', '')), sat = comp(parts[1], 1), l = comp(parts[2], 1);
  if (h.isNaN || sat.isNaN || l.isNaN) return null;
  final rgb = _hsl(h, sat.clamp(0.0, 1.0), l.clamp(0.0, 1.0));
  return Rgba(rgb[0], rgb[1], rgb[2], alpha(3));
}

List<double> _hsl(double h, double s, double l) {
  h = ((h % 360) + 360) % 360 / 360;
  double f(double n) {
    final k = (n + h * 12) % 12;
    final a = s * math.min(l, 1 - l);
    return l - a * math.max(-1, math.min(math.min(k - 3, 9 - k), 1));
  }

  return [f(0) * 255, f(8) * 255, f(4) * 255];
}

final Map<String, int> _named = () {
  const src = 'aliceblue f0f8ff antiquewhite faebd7 aqua 00ffff aquamarine 7fffd4 azure f0ffff beige f5f5dc bisque ffe4c4 '
      'black 000000 blanchedalmond ffebcd blue 0000ff blueviolet 8a2be2 brown a52a2a burlywood deb887 cadetblue 5f9ea0 '
      'chartreuse 7fff00 chocolate d2691e coral ff7f50 cornflowerblue 6495ed cornsilk fff8dc crimson dc143c cyan 00ffff '
      'darkblue 00008b darkcyan 008b8b darkgoldenrod b8860b darkgray a9a9a9 darkgreen 006400 darkgrey a9a9a9 darkkhaki bdb76b '
      'darkmagenta 8b008b darkolivegreen 556b2f darkorange ff8c00 darkorchid 9932cc darkred 8b0000 darksalmon e9967a '
      'darkseagreen 8fbc8f darkslateblue 483d8b darkslategray 2f4f4f darkslategrey 2f4f4f darkturquoise 00ced1 '
      'darkviolet 9400d3 deeppink ff1493 deepskyblue 00bfff dimgray 696969 dimgrey 696969 dodgerblue 1e90ff firebrick b22222 '
      'floralwhite fffaf0 forestgreen 228b22 fuchsia ff00ff gainsboro dcdcdc ghostwhite f8f8ff gold ffd700 goldenrod daa520 '
      'gray 808080 green 008000 greenyellow adff2f grey 808080 honeydew f0fff0 hotpink ff69b4 indianred cd5c5c indigo 4b0082 '
      'ivory fffff0 khaki f0e68c lavender e6e6fa lavenderblush fff0f5 lawngreen 7cfc00 lemonchiffon fffacd lightblue add8e6 '
      'lightcoral f08080 lightcyan e0ffff lightgoldenrodyellow fafad2 lightgray d3d3d3 lightgreen 90ee90 lightgrey d3d3d3 '
      'lightpink ffb6c1 lightsalmon ffa07a lightseagreen 20b2aa lightskyblue 87cefa lightslategray 778899 lightslategrey 778899 '
      'lightsteelblue b0c4de lightyellow ffffe0 lime 00ff00 limegreen 32cd32 linen faf0e6 magenta ff00ff maroon 800000 '
      'mediumaquamarine 66cdaa mediumblue 0000cd mediumorchid ba55d3 mediumpurple 9370db mediumseagreen 3cb371 '
      'mediumslateblue 7b68ee mediumspringgreen 00fa9a mediumturquoise 48d1cc mediumvioletred c71585 midnightblue 191970 '
      'mintcream f5fffa mistyrose ffe4e1 moccasin ffe4b5 navajowhite ffdead navy 000080 oldlace fdf5e6 olive 808000 '
      'olivedrab 6b8e23 orange ffa500 orangered ff4500 orchid da70d6 palegoldenrod eee8aa palegreen 98fb98 paleturquoise afeeee '
      'palevioletred db7093 papayawhip ffefd5 peachpuff ffdab9 peru cd853f pink ffc0cb plum dda0dd powderblue b0e0e6 '
      'purple 800080 rebeccapurple 663399 red ff0000 rosybrown bc8f8f royalblue 4169e1 saddlebrown 8b4513 salmon fa8072 '
      'sandybrown f4a460 seagreen 2e8b57 seashell fff5ee sienna a0522d silver c0c0c0 skyblue 87ceeb slateblue 6a5acd '
      'slategray 708090 slategrey 708090 snow fffafa springgreen 00ff7f steelblue 4682b4 tan d2b48c teal 008080 thistle d8bfd8 '
      'tomato ff6347 turquoise 40e0d0 violet ee82ee wheat f5deb3 white ffffff whitesmoke f5f5f5 yellow ffff00 yellowgreen 9acd32';
  final parts = src.split(' ');
  return {for (var i = 0; i + 1 < parts.length; i += 2) parts[i]: int.parse(parts[i + 1], radix: 16)};
}();
