// JavaScript value semantics used by the TSVG expression language.
//
// The reference engine is JavaScript, so expression values are JS values:
// numbers (doubles), strings and `undefined` (here: null). These helpers
// reproduce the coercions the reference relies on (unary +, String(),
// truthiness, loose ==, mixed + and comparisons).
import 'dart:math' as math;

/// Error raised by the parser, the expression language or the renderer.
class TsvgError implements Exception {
  TsvgError(this.message);
  final String message;
  @override
  String toString() => message;
}

final RegExp _jsNum = RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$');
final RegExp _jsHex = RegExp(r'^0[xX][0-9a-fA-F]+$');

/// JS `Number(v)` / unary `+v`.
double toNum(Object? v) {
  if (v == null) return double.nan;
  if (v is double) return v;
  if (v is num) return v.toDouble();
  if (v is bool) return v ? 1 : 0;
  final s = v.toString().trim();
  if (s.isEmpty) return 0;
  if (_jsNum.hasMatch(s)) return double.parse(s);
  if (_jsHex.hasMatch(s)) return int.parse(s.substring(2), radix: 16).toDouble();
  if (s == 'Infinity' || s == '+Infinity') return double.infinity;
  if (s == '-Infinity') return double.negativeInfinity;
  return double.nan;
}

/// JS `String(v)`.
String toStr(Object? v) {
  if (v == null) return 'undefined';
  if (v is String) return v;
  if (v is bool) return v ? 'true' : 'false';
  if (v is num) return numStr(v.toDouble());
  return v.toString();
}

/// JS number → string (integers without ".0", like JS).
String numStr(double d) {
  if (d.isNaN) return 'NaN';
  if (d.isInfinite) return d > 0 ? 'Infinity' : '-Infinity';
  if (d == d.truncateToDouble() && d.abs() < 1e21) return d.toInt().toString();
  var s = d.toString();
  // Dart prints 1e-7 as "1e-7" and 1.5e21 as "1.5e+21", like JS.
  return s;
}

/// JS truthiness.
bool truthy(Object? v) {
  if (v == null) return false;
  if (v is num) return v != 0 && !v.isNaN;
  if (v is String) return v.isNotEmpty;
  if (v is bool) return v;
  return true;
}

/// JS `x + y`.
Object jsAdd(Object? x, Object? y) {
  if (x is String || y is String) return toStr(x) + toStr(y);
  return toNum(x) + toNum(y);
}

/// JS loose `x == y` for the value kinds the language produces.
bool jsLooseEq(Object? x, Object? y) {
  if (x == null || y == null) return x == null && y == null;
  if (x is String && y is String) return x == y;
  final a = toNum(x), b = toNum(y);
  return a == b; // NaN != NaN
}

/// JS relational comparison: strings compare as strings, else as numbers.
/// Returns null when the comparison is undefined (NaN involved).
int? jsCompare(Object? x, Object? y) {
  if (x is String && y is String) return x.compareTo(y);
  final a = toNum(x), b = toNum(y);
  if (a.isNaN || b.isNaN) return null;
  return a < b ? -1 : (a > b ? 1 : 0);
}

/// JS `%` (truncated remainder).
double jsRem(double x, double y) {
  if (y == 0 || x.isNaN || y.isNaN || x.isInfinite) return double.nan;
  if (y.isInfinite) return x;
  return x.remainder(y);
}

/// JS `Math.round` (rounds .5 up).
double jsRound(double x) => x.isFinite ? (x + 0.5).floorToDouble() : x;

/// JS `Number.prototype.toFixed`.
String jsFixed(double n, int digits) {
  if (n.isNaN) return 'NaN';
  if (n.abs() >= 1e21) return numStr(n);
  return n.toStringAsFixed(digits.clamp(0, 100));
}

double jsPow(double a, double b) => math.pow(a, b).toDouble();

double jsMin(List<double> xs) {
  var m = double.infinity;
  for (final x in xs) {
    if (x.isNaN) return double.nan;
    if (x < m) m = x;
  }
  return m;
}

double jsMax(List<double> xs) {
  var m = double.negativeInfinity;
  for (final x in xs) {
    if (x.isNaN) return double.nan;
    if (x > m) m = x;
  }
  return m;
}
