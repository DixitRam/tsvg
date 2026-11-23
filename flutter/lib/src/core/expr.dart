// The TSVG expression language: a tiny, side-effect-free Pratt parser that
// compiles `=expr` attributes, `{expr}` templates and <fn> bodies to closures.
import 'dart:math' as math;

import 'color.dart';
import 'js.dart';

/// Evaluation environment of one node (see `makeEnv` in the reference).
class Env {
  Env({
    required this.doc,
    required this.opts,
    required this.theme,
    required this.tags,
    required this.fns,
    required this.vars,
  });

  /// The parsed document (typed as Object to keep this file free of model imports).
  final Object doc;
  final Map<String, String> opts;
  final Map<String, String> theme;
  final List<String> tags;
  final Map<String, UserFn> fns;
  final Map<String, Object?> vars;

  /// Same env with [vars] replaced.
  Env withVars(Map<String, Object?> v) =>
      Env(doc: doc, opts: opts, theme: theme, tags: tags, fns: fns, vars: v);
}

typedef Expr = Object? Function(Env env);
typedef UserFn = Object? Function(List<Object?> args, Env env);

const double _pi = math.pi;

typedef EaseFn = double Function(double k);

/// Easing curves (`ease(k, 'io')`, `<anim ease>` and `<keys ease>`).
final Map<String, EaseFn> ease = <String, EaseFn>{
  'linear': (k) => k,
  'in': (k) => k * k * k,
  'out': (k) => 1 - math.pow(1 - k, 3).toDouble(),
  'io': (k) => k < 0.5 ? 4 * k * k * k : 1 - math.pow(-2 * k + 2, 3).toDouble() / 2,
  'back': (k) {
    const c = 1.70158;
    return 1 + (c + 1) * math.pow(k - 1, 3).toDouble() + c * math.pow(k - 1, 2).toDouble();
  },
  'elastic': (k) => k == 0 || k == 1
      ? k
      : math.pow(2, -10 * k).toDouble() * math.sin((k * 10 - 0.75) * (2 * _pi / 3)) + 1,
  'step': (k) => k < 1 ? 0 : 1,
};

double _n(List<Object?> a, int i) => i < a.length ? toNum(a[i]) : double.nan;
Object? _a(List<Object?> a, int i) => i < a.length ? a[i] : null;

double _f1(List<Object?> a, double Function(double) f) => f(_n(a, 0));

/// Built-in functions. They take precedence over `<fn>` definitions.
final Map<String, Object? Function(List<Object?> a)> builtins = {
  'sin': (a) => _f1(a, math.sin),
  'cos': (a) => _f1(a, math.cos),
  'tan': (a) => _f1(a, math.tan),
  'abs': (a) => _f1(a, (x) => x.abs()),
  'sqrt': (a) => _f1(a, math.sqrt),
  'min': (a) => jsMin(a.map(toNum).toList()),
  'max': (a) => jsMax(a.map(toNum).toList()),
  'floor': (a) => _f1(a, (x) => x.isFinite ? x.floorToDouble() : x),
  'ceil': (a) => _f1(a, (x) => x.isFinite ? x.ceilToDouble() : x),
  'round': (a) => _f1(a, jsRound),
  'pow': (a) => jsPow(_n(a, 0), _n(a, 1)),
  'exp': (a) => _f1(a, math.exp),
  'log': (a) => _f1(a, math.log),
  'atan2': (a) => math.atan2(_n(a, 0), _n(a, 1)),
  'sign': (a) => _f1(a, (x) => x.isNaN ? x : (x > 0 ? 1.0 : (x < 0 ? -1.0 : x))),
  'clamp': (a) => jsMin([_n(a, 2), jsMax([_n(a, 1), _n(a, 0)])]),
  'lerp': (a) => _n(a, 0) + (_n(a, 1) - _n(a, 0)) * _n(a, 2),
  'step': (a) => _n(a, 1) < _n(a, 0) ? 0.0 : 1.0,
  'smooth': (a) {
    final k = jsMin([1, jsMax([0, (_n(a, 2) - _n(a, 0)) / (_n(a, 1) - _n(a, 0))])]);
    return k * k * (3 - 2 * k);
  },
  'fract': (a) => _f1(a, (x) => x - x.floorToDouble()),
  'ease': (a) {
    final f = ease[toStr(_a(a, 1))] ?? ease['linear']!;
    return f(jsMin([1, jsMax([0, _n(a, 0)])]));
  },
  'fmt': (a) {
    final d = _n(a, 1);
    return jsFixed(_n(a, 0), truthy(d) ? d.truncate() : 0);
  },
  'str': (a) => toStr(_a(a, 0)),
  'rgba': (a) =>
      'rgba(${numStr(jsRound(_n(a, 0)))},${numStr(jsRound(_n(a, 1)))},${numStr(jsRound(_n(a, 2)))},${_a(a, 3) == null ? '1' : toStr(a[3])})',
  'mix': (a) => lerpAny(_a(a, 0), _a(a, 1), _n(a, 2)),
};

class _Tok {
  _Tok(this.t, this.v);
  final String t; // num | id | str | op
  final Object v;
  String get s => v is double ? numStr(v as double) : v as String;
}

final RegExp _ws = RegExp(r'\s');
final RegExp _numStart = RegExp(r'[0-9.]');
final RegExp _numRe = RegExp(r'[0-9]*\.?[0-9]+(e[-+]?[0-9]+)?', caseSensitive: false);
final RegExp _idStart = RegExp(r'[A-Za-z_$]');
final RegExp _idRe = RegExp(r'\$?[A-Za-z_][A-Za-z0-9_]*');
const Set<String> _two = {'==', '!=', '<=', '>=', '&&', '||'};
const String _ops = '+-*/%^<>!?:(),';

List<_Tok> _tokenize(String src) {
  final out = <_Tok>[];
  var i = 0;
  while (i < src.length) {
    final c = src[i];
    if (_ws.hasMatch(c)) {
      i++;
      continue;
    }
    if (_numStart.hasMatch(c)) {
      final m = _numRe.matchAsPrefix(src, i);
      if (m == null) throw TsvgError('bad number in $src');
      out.add(_Tok('num', double.parse(m[0]!)));
      i = m.end;
      continue;
    }
    if (_idStart.hasMatch(c)) {
      final m = _idRe.matchAsPrefix(src, i);
      if (m == null) throw TsvgError("bad character '$c' in $src");
      out.add(_Tok('id', m[0]!));
      i = m.end;
      continue;
    }
    if (c == "'" || c == '"') {
      final j = src.indexOf(c, i + 1);
      if (j < 0) throw TsvgError('unclosed string in $src');
      out.add(_Tok('str', src.substring(i + 1, j)));
      i = j + 1;
      continue;
    }
    final two = src.length >= i + 2 ? src.substring(i, i + 2) : '';
    if (_two.contains(two)) {
      out.add(_Tok('op', two));
      i += 2;
      continue;
    }
    if (_ops.contains(c)) {
      out.add(_Tok('op', c));
      i++;
      continue;
    }
    throw TsvgError("bad character '$c' in $src");
  }
  return out;
}

const Map<String, int> _bp = {
  '?': 1, '||': 2, '&&': 3, '==': 4, '!=': 4, '<': 5, '>': 5, '<=': 5, '>=': 5, //
  '+': 6, '-': 6, '*': 7, '/': 7, '%': 7, '^': 8,
};

Object? _bin(String op, Object? x, Object? y) {
  switch (op) {
    case '+':
      return jsAdd(x, y);
    case '-':
      return toNum(x) - toNum(y);
    case '*':
      return toNum(x) * toNum(y);
    case '/':
      return toNum(x) / toNum(y);
    case '%':
      final a = toNum(x), b = toNum(y);
      return jsRem(jsRem(a, b) + b, b);
    case '^':
      return jsPow(toNum(x), toNum(y));
    case '==':
      return jsLooseEq(x, y) ? 1.0 : 0.0;
    case '!=':
      return jsLooseEq(x, y) ? 0.0 : 1.0;
    case '<':
      final c = jsCompare(x, y);
      return c != null && c < 0 ? 1.0 : 0.0;
    case '>':
      final c = jsCompare(x, y);
      return c != null && c > 0 ? 1.0 : 0.0;
    case '<=':
      final c = jsCompare(x, y);
      return c != null && c <= 0 ? 1.0 : 0.0;
    case '>=':
      final c = jsCompare(x, y);
      return c != null && c >= 0 ? 1.0 : 0.0;
  }
  throw TsvgError('bad operator $op');
}

/// Compiles an expression to a closure. Throws [TsvgError] on syntax errors;
/// unknown names and functions fail when evaluated.
Expr compileExpr(String src) {
  final toks = _tokenize(src);
  var p = 0;
  _Tok? peek() => p < toks.length ? toks[p] : null;
  _Tok? next() => p < toks.length ? toks[p++] : null;
  void expect(String v) {
    final k = next();
    if (k == null || k.v != v) throw TsvgError("expected '$v' in $src");
  }

  late Expr Function(int rbp) expr;

  Expr prefix() {
    final k = next();
    if (k == null) throw TsvgError('unexpected end of $src');
    if (k.t == 'num' || k.t == 'str') {
      final v = k.v;
      return (_) => v;
    }
    if (k.t == 'op' && k.v == '(') {
      final e = expr(0);
      expect(')');
      return e;
    }
    if (k.t == 'op' && k.v == '-') {
      final e = expr(9);
      return (env) => -toNum(e(env));
    }
    if (k.t == 'op' && k.v == '!') {
      final e = expr(9);
      return (env) => truthy(e(env)) ? 0.0 : 1.0;
    }
    if (k.t == 'id') {
      final name = k.v as String;
      if (peek() != null && peek()!.v == '(') {
        next();
        final args = <Expr>[];
        if (peek() != null && peek()!.v != ')') {
          do {
            args.add(expr(0));
          } while (peek() != null && peek()!.v == ',' && next() != null);
        }
        expect(')');
        final builtin = builtins[name];
        return (env) {
          final vals = [for (final a in args) a(env)];
          if (builtin != null) return builtin(vals);
          final f = env.fns[name];
          if (f == null) throw TsvgError('unknown function $name()');
          return f(vals, env);
        };
      }
      if (name == 'PI') return (_) => _pi;
      if (name == 'true') return (_) => 1.0;
      if (name == 'false') return (_) => 0.0;
      return (env) => lookup(env, name);
    }
    throw TsvgError("unexpected '${k.s}' in $src");
  }

  expr = (int rbp) {
    var left = prefix();
    for (;;) {
      final k = peek();
      if (k == null || k.t != 'op' || !_bp.containsKey(k.v) || _bp[k.v]! <= rbp) break;
      next();
      final op = k.v as String;
      if (op == '?') {
        final a = expr(0);
        expect(':');
        final b = expr(0);
        final c = left;
        left = (env) => truthy(c(env)) ? a(env) : b(env);
        continue;
      }
      final right = expr(op == '^' ? _bp[op]! - 1 : _bp[op]!);
      final l = left;
      if (op == '&&') {
        left = (e) => truthy(l(e)) && truthy(right(e)) ? 1.0 : 0.0;
      } else if (op == '||') {
        left = (e) => truthy(l(e)) || truthy(right(e)) ? 1.0 : 0.0;
      } else {
        left = (e) => _bin(op, l(e), right(e));
      }
    }
    return left;
  };

  final e = expr(0);
  if (p < toks.length) throw TsvgError("unexpected '${toks[p].s}' in $src");
  return e;
}

final Map<String, Expr> _cache = <String, Expr>{};

/// Compiled (and cached) expression.
Expr compiled(String src) => _cache[src] ??= compileExpr(src);

/// Resolves a name: `$token` from the theme, then vars, then options.
Object? lookup(Env env, String name) {
  if (name.startsWith(r'$')) {
    final key = name.substring(1);
    if (!env.theme.containsKey(key)) throw TsvgError('unknown theme token $name');
    return env.theme[key];
  }
  if (env.vars.containsKey(name)) return env.vars[name];
  if (env.opts.containsKey(name)) return env.opts[name];
  throw TsvgError('unknown variable $name');
}
