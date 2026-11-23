// SVG path data (`d`) → absolute commands. Pure Dart; the Flutter renderer
// turns them into a ui.Path. Like browsers, parsing stops at the first error
// and keeps what came before it.

sealed class PathCmd {
  const PathCmd();
}

class MoveTo extends PathCmd {
  const MoveTo(this.x, this.y);
  final double x, y;
}

class LineTo extends PathCmd {
  const LineTo(this.x, this.y);
  final double x, y;
}

class CubicTo extends PathCmd {
  const CubicTo(this.x1, this.y1, this.x2, this.y2, this.x, this.y);
  final double x1, y1, x2, y2, x, y;
}

class QuadTo extends PathCmd {
  const QuadTo(this.x1, this.y1, this.x, this.y);
  final double x1, y1, x, y;
}

/// SVG elliptical arc (endpoint parameterisation).
class ArcTo extends PathCmd {
  const ArcTo(this.rx, this.ry, this.rotation, this.largeArc, this.sweep, this.x, this.y);
  final double rx, ry, rotation;
  final bool largeArc, sweep;
  final double x, y;
}

class ClosePath extends PathCmd {
  const ClosePath();
}

final Map<String, List<PathCmd>> _cache = {};

/// Parsed (cached) path data.
List<PathCmd> parsePathData(String d) {
  final hit = _cache[d];
  if (hit != null) return hit;
  if (_cache.length > 2000) _cache.clear();
  return _cache[d] = _PathParser(d).parse();
}

class _PathParser {
  _PathParser(this.s);
  final String s;
  int i = 0;
  final List<PathCmd> out = [];

  bool _isWs(int c) => c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d || c == 0x0c;

  void _skip() {
    while (i < s.length && (_isWs(s.codeUnitAt(i)) || s[i] == ',')) {
      i++;
    }
  }

  bool _atNumber() {
    _skip();
    if (i >= s.length) return false;
    final c = s[i];
    return '0123456789.-+'.contains(c);
  }

  double? _num() {
    _skip();
    final start = i;
    if (i < s.length && (s[i] == '+' || s[i] == '-')) i++;
    var digits = 0;
    while (i < s.length && _digit(s.codeUnitAt(i))) {
      i++;
      digits++;
    }
    if (i < s.length && s[i] == '.') {
      i++;
      while (i < s.length && _digit(s.codeUnitAt(i))) {
        i++;
        digits++;
      }
    }
    if (digits == 0) {
      i = start;
      return null;
    }
    if (i < s.length && (s[i] == 'e' || s[i] == 'E')) {
      final save = i;
      i++;
      if (i < s.length && (s[i] == '+' || s[i] == '-')) i++;
      var ed = 0;
      while (i < s.length && _digit(s.codeUnitAt(i))) {
        i++;
        ed++;
      }
      if (ed == 0) i = save;
    }
    return double.tryParse(s.substring(start, i));
  }

  bool? _flag() {
    _skip();
    if (i >= s.length) return null;
    final c = s[i];
    if (c == '0' || c == '1') {
      i++;
      return c == '1';
    }
    return null;
  }

  bool _digit(int c) => c >= 0x30 && c <= 0x39;

  List<PathCmd> parse() {
    double cx = 0, cy = 0, sx = 0, sy = 0; // current point, subpath start
    double? lcx, lcy; // last cubic control (for S)
    double? lqx, lqy; // last quad control (for T)
    String? cmd;
    var first = true;
    while (true) {
      _skip();
      if (i >= s.length) break;
      final c = s[i];
      if (RegExp(r'[MmLlHhVvCcSsQqTtAaZz]').hasMatch(c)) {
        cmd = c;
        i++;
      } else if (cmd == null || !_atNumber() || cmd == 'Z' || cmd == 'z') {
        break; // error: stop here
      } else if (cmd == 'M') {
        cmd = 'L';
      } else if (cmd == 'm') {
        cmd = 'l';
      }
      if (first && cmd != 'M' && cmd != 'm') break;
      first = false;
      final rel = cmd.toLowerCase() == cmd;
      final up = cmd.toUpperCase();
      double ox() => rel ? cx : 0;
      double oy() => rel ? cy : 0;
      var ok = true;
      switch (up) {
        case 'Z':
          out.add(const ClosePath());
          cx = sx;
          cy = sy;
          lcx = lcy = lqx = lqy = null;
          continue;
        case 'M':
          final x = _num(), y = _num();
          if (x == null || y == null) {
            ok = false;
            break;
          }
          cx = x + ox();
          cy = y + oy();
          sx = cx;
          sy = cy;
          out.add(MoveTo(cx, cy));
          lcx = lcy = lqx = lqy = null;
        case 'L':
          final x = _num(), y = _num();
          if (x == null || y == null) {
            ok = false;
            break;
          }
          cx = x + ox();
          cy = y + oy();
          out.add(LineTo(cx, cy));
          lcx = lcy = lqx = lqy = null;
        case 'H':
          final x = _num();
          if (x == null) {
            ok = false;
            break;
          }
          cx = x + ox();
          out.add(LineTo(cx, cy));
          lcx = lcy = lqx = lqy = null;
        case 'V':
          final y = _num();
          if (y == null) {
            ok = false;
            break;
          }
          cy = y + oy();
          out.add(LineTo(cx, cy));
          lcx = lcy = lqx = lqy = null;
        case 'C':
          final v = [for (var k = 0; k < 6; k++) _num()];
          if (v.contains(null)) {
            ok = false;
            break;
          }
          final x1 = v[0]! + ox(), y1 = v[1]! + oy(), x2 = v[2]! + ox(), y2 = v[3]! + oy();
          cx = v[4]! + ox();
          cy = v[5]! + oy();
          out.add(CubicTo(x1, y1, x2, y2, cx, cy));
          lcx = x2;
          lcy = y2;
          lqx = lqy = null;
        case 'S':
          final v = [for (var k = 0; k < 4; k++) _num()];
          if (v.contains(null)) {
            ok = false;
            break;
          }
          final x1 = lcx != null ? 2 * cx - lcx : cx, y1 = lcy != null ? 2 * cy - lcy : cy;
          final x2 = v[0]! + ox(), y2 = v[1]! + oy();
          cx = v[2]! + ox();
          cy = v[3]! + oy();
          out.add(CubicTo(x1, y1, x2, y2, cx, cy));
          lcx = x2;
          lcy = y2;
          lqx = lqy = null;
        case 'Q':
          final v = [for (var k = 0; k < 4; k++) _num()];
          if (v.contains(null)) {
            ok = false;
            break;
          }
          final x1 = v[0]! + ox(), y1 = v[1]! + oy();
          cx = v[2]! + ox();
          cy = v[3]! + oy();
          out.add(QuadTo(x1, y1, cx, cy));
          lqx = x1;
          lqy = y1;
          lcx = lcy = null;
        case 'T':
          final v = [for (var k = 0; k < 2; k++) _num()];
          if (v.contains(null)) {
            ok = false;
            break;
          }
          final x1 = lqx != null ? 2 * cx - lqx : cx, y1 = lqy != null ? 2 * cy - lqy : cy;
          cx = v[0]! + ox();
          cy = v[1]! + oy();
          out.add(QuadTo(x1, y1, cx, cy));
          lqx = x1;
          lqy = y1;
          lcx = lcy = null;
        case 'A':
          final rx = _num(), ry = _num(), rot = _num();
          final large = _flag(), sweep = _flag();
          final x = _num(), y = _num();
          if (rx == null || ry == null || rot == null || large == null || sweep == null || x == null || y == null) {
            ok = false;
            break;
          }
          cx = x + ox();
          cy = y + oy();
          out.add(ArcTo(rx.abs(), ry.abs(), rot, large, sweep, cx, cy));
          lcx = lcy = lqx = lqy = null;
      }
      if (!ok) break;
    }
    return out;
  }
}
