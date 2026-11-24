// Value resolution and the frame walker (port of the "value resolution" and
// "rendering" sections of tsvg-core.js). A frame is a pure function of
// (time, options, layout): renderFrame always issues the same draw calls.
import 'dart:math' as math;

import 'canvas.dart';
import 'color.dart';
import 'expr.dart';
import 'js.dart';
import 'model.dart';
import 'path_data.dart';

final RegExp _numeric = RegExp(r'^-?[0-9]*\.?[0-9]+$');
final RegExp _token = RegExp(r'^\$[A-Za-z_]\w*$');
final RegExp _tpl = RegExp(r'\{([^}]+)\}');
final RegExp _url = RegExp(r'^url\(#([\w-]+)\)$');

/// Environment for (doc, options, layout, t).
Env makeEnv(TsvgDoc doc, Map<String, String> opts, TsvgLayout layout, double t) {
  final theme = doc.themes[opts['theme']] ?? (doc.themes.isNotEmpty ? doc.themes.values.first : const <String, String>{});
  final tags = <String>[layout.id, for (final o in doc.options) if ((opts[o.id] ?? '').isNotEmpty) opts[o.id]!];
  return Env(
    doc: doc,
    opts: opts,
    theme: theme,
    tags: tags,
    fns: doc.fns,
    vars: <String, Object?>{
      't': t,
      'T': t,
      'T0': 0.0,
      'p': 0.0,
      'W': layout.w,
      'H': layout.h,
      'dur': doc.duration,
      'portrait': layout.h > layout.w ? 1.0 : 0.0,
      'layout': layout.id,
    },
  );
}

TsvgDoc _doc(Env env) => env.doc as TsvgDoc;

/// `@id` → the string in the current language (falls back to en, then the first).
String strOf(TsvgDoc doc, String id, Env env) {
  final s = doc.strings[id];
  if (s == null) throw TsvgError('unknown string @$id');
  final lang = env.opts['lang'];
  final v = (lang != null ? s[lang] : null) ?? s['en'] ?? (s.isNotEmpty ? s.values.first : null);
  if (v == null) throw TsvgError('string @$id has no text');
  return template(v, env);
}

/// `{expr}` templates.
String template(String s, Env env) =>
    !s.contains('{') ? s : s.replaceAllMapped(_tpl, (m) => toStr(compiled(m[1]!)(env)));

/// Resolves an attribute string: `=expr`, `@string`, `$token`, number, or template.
Object? value(String? raw, Env env, TsvgDoc doc) {
  if (raw == null) return null;
  if (raw.isEmpty) return '';
  final c = raw[0];
  if (c == r'\') return raw.substring(1); // escape (0.2.2): \=> is the literal text "=>"
  if (c == '=') return compiled(raw.substring(1))(env);
  if (c == '@') return strOf(doc, raw.substring(1), env);
  if (c == r'$' && _token.hasMatch(raw)) return lookup(env, raw);
  if (_numeric.hasMatch(raw)) return double.parse(raw);
  return template(raw, env);
}

/// Attribute variants: `x.portrait`, `size.gu`, `fill.light`… first matching tag wins.
String? pick(Map<String, String> a, String name, Env env) {
  for (final tag in env.tags) {
    final v = a['$name.$tag'];
    if (v != null) return v;
  }
  return a[name];
}

Object? attr(TsvgNode node, String name, Env env, TsvgDoc doc, [Object? dflt]) =>
    value(pick(node.a, name, env), env, doc) ?? dflt;

/// Property = base attribute, then `<anim>`/`<keys>` in document order.
Object? prop(TsvgNode node, String name, Env env, TsvgDoc doc, [Object? dflt]) {
  var v = attr(node, name, env, doc, dflt);
  var first = true;
  for (final an in node.anims) {
    if (an.prop != name) continue;
    final lt = toNum(env.vars['T']) - toNum(env.vars['T0']);
    final ks = an.keys;
    if (ks != null) {
      if (ks.isEmpty) {
        first = false;
        continue;
      }
      final e = ease[an.ease] ?? ease['io']!;
      if (lt <= ks.first.at) {
        v = value(ks.first.v, env, doc);
      } else if (lt >= ks.last.at) {
        v = value(ks.last.v, env, doc);
      } else {
        for (var i = 0; i < ks.length - 1; i++) {
          if (lt >= ks[i].at && lt < ks[i + 1].at) {
            v = lerpAny(value(ks[i].v, env, doc), value(ks[i + 1].v, env, doc), e((lt - ks[i].at) / (ks[i + 1].at - ks[i].at)));
            break;
          }
        }
      }
      first = false;
      continue;
    }
    final a = an.a;
    final atRaw = pick(a, 'at', env), durRaw = pick(a, 'dur', env);
    final at = toNum(value(atRaw == null || atRaw.isEmpty ? '0' : atRaw, env, doc));
    final dur = toNum(value(durRaw == null || durRaw.isEmpty ? '0.5' : durRaw, env, doc));
    final fromRaw = pick(a, 'from', env), toRaw = pick(a, 'to', env);
    final from = fromRaw != null ? value(fromRaw, env, doc) : v;
    final to = toRaw != null ? value(toRaw, env, doc) : v;
    if (lt < at) {
      if (first) v = from;
    } else {
      final k = dur > 0 ? math.min(1.0, (lt - at) / dur) : 1.0;
      v = lerpAny(from, to, (ease[a['ease']] ?? ease['out']!)(k));
    }
    first = false;
  }
  return v;
}

/// Visibility: `when`, `only`, `at`, `dur`.
bool visible(TsvgNode n, Env env) {
  final a = n.a;
  final w = pick(a, 'when', env);
  if (w != null && !truthy(compiled(w.startsWith('=') ? w.substring(1) : w)(env))) return false;
  final only = a['only'];
  if (only != null && only.isNotEmpty) {
    final want = only.split(RegExp(r'[ ,]+'));
    if (!want.any(env.tags.contains)) return false;
  }
  final T = toNum(env.vars['T']);
  final at = a['at'] != null ? toNum(value(pick(a, 'at', env), env, _doc(env))) : null;
  if (at != null && T < at) return false;
  if (a['dur'] != null && T > (truthy(at) ? at! : 0) + toNum(value(pick(a, 'dur', env), env, _doc(env)))) return false;
  return true;
}

/// fill/stroke paint: colour, `$token` value, or `url(#gradient)`.
TsvgPaint? paintOf(Object? v, Env env) {
  if (v == null || v == 'none') return null;
  final s = toStr(v);
  final m = _url.firstMatch(s);
  if (m == null) return SolidPaint(cssColor(s) ?? Rgba.black);
  final doc = _doc(env);
  final g = doc.gradients[m[1]];
  if (g == null) throw TsvgError('unknown gradient #${m[1]}');
  double n(String k, double d) {
    final r = pick(g.a, k, env);
    return r == null ? d : toNum(value(r, env, doc));
  }

  final stops = <GradientStop>[];
  for (final s in g.stops) {
    final atRaw = s['at'];
    final at = toNum(value(atRaw == null || atRaw.isEmpty ? '0' : atRaw, env, doc));
    final colRaw = s['color'];
    final col = toStr(value(colRaw == null || colRaw.isEmpty ? '#000' : colRaw, env, doc));
    final op = s['opacity'] != null ? toNum(value(s['opacity'], env, doc)) : 1.0;
    final c = cssColor(withAlpha(col, op));
    if (c == null) throw TsvgError("gradient #${m[1]}: bad stop colour '$col'");
    if (at.isNaN) throw TsvgError('gradient #${m[1]}: bad stop offset');
    stops.add(GradientStop(math.min(1.0, math.max(0.0, at)), c));
  }
  _stableSort(stops);
  if (g.type == 'linear') return LinearPaint(n('x1', 0), n('y1', 0), n('x2', 100), n('y2', 0), stops);
  final cx = n('x', 0), cy = n('y', 0);
  return RadialPaint(n('fx', cx), n('fy', cy), cx, cy, n('r', 100), stops);
}

void _stableSort(List<GradientStop> s) {
  for (var i = 1; i < s.length; i++) {
    final x = s[i];
    var j = i - 1;
    while (j >= 0 && s[j].at > x.at) {
      s[j + 1] = s[j];
      j--;
    }
    s[j + 1] = x;
  }
}

/// Geometry of a shape node for clip paths (null when the node has no area).
TsvgShape? shapePath(TsvgNode n, Env env) {
  final doc = _doc(env);
  double p(String k, double d) => toNum(prop(n, k, env, doc, d));
  switch (n.type) {
    case 'rect':
      final w = p('w', 100), h = p('h', 100), x = p('x', 0) - w * p('ax', 0), y = p('y', 0) - h * p('ay', 0), r = p('r', 0);
      return RectShape(x, y, w, h, r > 0 ? math.max(0, math.min(r, math.min(w / 2, h / 2))) : 0);
    case 'circle':
    case 'ellipse':
      final rx = toNum(prop(n, 'r', env, doc, prop(n, 'rx', env, doc, 50.0)));
      final ry = n.type == 'ellipse' ? toNum(prop(n, 'ry', env, doc, rx)) : rx;
      return EllipseShape(p('x', 0), p('y', 0), math.max(0, rx), math.max(0, ry));
    case 'path':
      final x = p('x', 0), y = p('y', 0);
      final d = toStr(prop(n, 'd', env, doc, ''));
      return PathShape(d, parsePathData(d), dx: x, dy: y);
  }
  return null;
}

/// `dash="a b …"` → the Canvas2D setLineDash list: null when invalid (ignored),
/// [] for solid (empty or all zeros), odd lists repeated.
List<double>? _dashOf(String s) {
  final t = s.trim();
  final parts = t.isEmpty ? <String>[] : t.split(RegExp(r'[\s,]+'));
  final v = [for (final x in parts) toNum(x)];
  if (v.any((x) => !x.isFinite || x < 0)) return null;
  if (v.every((x) => x == 0)) return const [];
  return v.length.isOdd ? [...v, ...v] : v;
}

ShadowSpec? _shadowOf(Object? raw, Env env, ShadowSpec? inherited) {
  if (raw == null || raw == 'none' || raw == '') return inherited;
  final parts = toStr(raw).trim().split(RegExp(r'\s+'));
  final c = parts.length > 3 && parts[3].isNotEmpty ? parts[3] : '#0008';
  final cs = c.startsWith(r'$') ? toStr(lookup(env, c)) : c;
  final col = cssColor(cs) ?? inherited?.color ?? Rgba.transparent;
  double num(int i) => i < parts.length ? toNum(parts[i]) : double.nan;
  final blur = parts.length > 2 && parts[2].isNotEmpty ? toNum(parts[2]) : 0.0;
  return ShadowSpec(num(0), num(1), blur, col);
}

FontSpec fontSpecOf(Object? font, TsvgDoc doc, double size, Object? weight, bool italic) {
  final f = truthy(font) ? toStr(font) : doc.font;
  final fams = f
      .split(',')
      .map((s) => s.trim().replaceAll(RegExp(r'''^['"]|['"]$'''), ''))
      .where((s) => s.isNotEmpty)
      .toList();
  double w;
  if (weight == 'bold') {
    w = 700;
  } else if (weight == 'normal') {
    w = 400;
  } else {
    w = toNum(weight);
    if (w.isNaN) w = 400;
  }
  return FontSpec(fams, size, w, italic);
}

/// Greedy word wrap at spaces (same algorithm as the reference).
List<String> wrapText(TsvgCanvas c, String txt, double maxw, FontSpec font) {
  final out = <String>[];
  for (final para in txt.split('\n')) {
    var line = '';
    for (final w in para.split(' ')) {
      final t = line.isNotEmpty ? '$line $w' : w;
      if (c.measureText(t, font) > maxw && line.isNotEmpty) {
        out.add(line);
        line = w;
      } else {
        line = t;
      }
    }
    out.add(line);
  }
  return out;
}

/// The text of a text node: a numeric literal renders exactly as written ("01"), 0.2.2.
String textOf(TsvgNode n, Env env) {
  final raw = pick(n.a, 'text', env);
  return raw != null && _numeric.hasMatch(raw) ? raw : toStr(value(raw, env, _doc(env)) ?? '');
}

/// A child placed by a `<row>`, `<col>` or `<grid>`: its box (w × h, origin
/// offset ox/oy inside the box) and its top-left corner (x, y) in the container.
class LayoutItem {
  LayoutItem(this.w, this.h, this.ox, this.oy);
  double w, h, ox, oy;
  late TsvgNode node;
  late Env env;
  double grow = 0;
  double x = 0, y = 0;
}

class LayoutResult {
  const LayoutResult(this.w, this.h, this.items);
  final double w, h;
  final List<LayoutItem> items;
}

const Set<String> _stretchable = {'rect', 'image', 'group', 'use', 'row', 'col', 'grid'};

/// Auto layout (0.5): `when=`/`only=` false takes a child out of the flow.
bool inFlow(TsvgNode n, Env env) {
  final w = pick(n.a, 'when', env);
  if (w != null && !truthy(compiled(w.startsWith('=') ? w.substring(1) : w)(env))) return false;
  final only = n.a['only'];
  if (only != null && only.isNotEmpty) {
    final want = only.split(RegExp(r'[ ,]+'));
    if (!want.any(env.tags.contains)) return false;
  }
  return true;
}

/// The layout box of a node: rect/image w×h (origin ax/ay), circle 2r, ellipse
/// 2rx×2ry, text measured (wrapped at maxw), containers their own size, the rest w×h (default 0).
LayoutItem boxOf(TsvgCanvas c, TsvgNode n, Env env) {
  final doc = _doc(env);
  double p(String k, double d) => toNum(prop(n, k, env, doc, d));
  switch (n.type) {
    case 'rect':
    case 'image':
      final w = p('w', 100), h = p('h', 100);
      return LayoutItem(w, h, w * p('ax', 0), h * p('ay', 0));
    case 'circle':
      final r = p('r', 50);
      return LayoutItem(2 * r, 2 * r, r, r);
    case 'ellipse':
      final rx = p('rx', 50), ry = toNum(prop(n, 'ry', env, doc, rx));
      return LayoutItem(2 * rx, 2 * ry, rx, ry);
    case 'text':
      final size = p('size', 48), lh = p('lh', 1.25), maxw = p('maxw', 0);
      final font = fontSpecOf(prop(n, 'font', env, doc, ''), doc, size, prop(n, 'weight', env, doc, 400.0), truthy(prop(n, 'italic', env, doc, 0.0)));
      final txt = textOf(n, env);
      final lines = maxw > 0 ? wrapText(c, txt, maxw, font) : txt.split('\n');
      final w = jsMax([0, for (final l in lines) c.measureText(l, font)]);
      final h = (lines.length - 1) * size * lh + size;
      final al = toStr(prop(n, 'align', env, doc, 'left'));
      return LayoutItem(w, h, al == 'center' ? w / 2 : (al == 'right' ? w : 0), h / 2);
    case 'row':
    case 'col':
    case 'grid':
      final l = arrange(c, n, env);
      return LayoutItem(l.w, l.h, l.w * p('ax', 0), l.h * p('ay', 0));
  }
  return LayoutItem(p('w', 0), p('h', 0), 0, 0);
}

/// Places the children of a `<row>`, `<col>` or `<grid>` (port of `arrange`).
LayoutResult arrange(TsvgCanvas c, TsvgNode n, Env env) {
  final doc = _doc(env);
  Object? pv(String k, [Object? d]) => prop(n, k, env, doc, d);
  final gap = toNum(pv('gap', 0.0)), pad = toNum(pv('pad', 0.0));
  final align = toStr(pv('align', 'start')), justify = toStr(pv('justify', 'start'));
  final items = <LayoutItem>[];
  for (final ch in n.children) {
    var reps = -1;
    if (ch.a['repeat'] != null) {
      final v = toNum(value(pick(ch.a, 'repeat', env), env, doc)).floorToDouble();
      reps = v.isNaN ? 0 : math.min(1000.0, math.max(0.0, v)).toInt();
    }
    final as = ch.a['as'] ?? 'i';
    final plain = reps < 0 ? ch : ch.withAttrs(Map.of(ch.a)..remove('repeat'));
    for (var k = 0; k < math.max(1, reps); k++) {
      if (reps == 0) break;
      final e = reps < 0
          ? env
          : env.withVars(Map<String, Object?>.of(env.vars)
            ..[as] = k.toDouble()
            ..['${as}_n'] = reps.toDouble());
      if (!inFlow(plain, e)) continue;
      final g = toNum(prop(plain, 'grow', e, doc, 0.0));
      items.add(boxOf(c, plain, e)
        ..node = plain
        ..env = e
        ..grow = g.isNaN ? 0 : g);
    }
  }
  final w0 = n.a['w'] != null ? toNum(pv('w')) : null, h0 = n.a['h'] != null ? toNum(pv('h')) : null;
  bool stretchable(LayoutItem it) => _stretchable.contains(it.node.type);
  void resize(LayoutItem it, String k, double v) {
    if (!stretchable(it)) return;
    if (k == 'w') {
      it.w = v;
      it.ox = v * toNum(prop(it.node, 'ax', it.env, doc, 0.0));
    } else {
      it.h = v;
      it.oy = v * toNum(prop(it.node, 'ay', it.env, doc, 0.0));
    }
    it.node = it.node.withAttrs({...it.node.a, k: numStr(v)});
  }

  double inAlign(String mode, double room, double size) => mode == 'center' ? (room - size) / 2 : (mode == 'end' ? room - size : 0);
  double W, H;
  if (n.type == 'grid') {
    final cf = toNum(pv('cols', 2.0));
    final cols = cf.isFinite ? math.max(1, cf.floor()) : 1;
    final rows = (items.length / cols).ceil();
    final cellW = w0 != null ? (w0 - 2 * pad - gap * (cols - 1)) / cols : jsMax([0, for (final it in items) it.w]);
    final rowH = <double>[
      for (var r = 0; r < rows; r++)
        h0 != null && items.isEmpty ? 0 : jsMax([0, for (final it in items.skip(r * cols).take(cols)) it.h]),
    ];
    if (h0 != null && rows > 0) {
      final each = (h0 - 2 * pad - gap * (rows - 1)) / rows;
      for (var r = 0; r < rows; r++) {
        rowH[r] = each;
      }
    }
    var top = pad;
    for (var r = 0; r < rows; r++) {
      for (var col = 0; col < cols; col++) {
        final i = r * cols + col;
        if (i >= items.length) break;
        final it = items[i];
        if (justify == 'stretch') resize(it, 'w', cellW);
        if (align == 'stretch') resize(it, 'h', rowH[r]);
        it.x = pad + col * (cellW + gap) + inAlign(justify, cellW, it.w);
        it.y = top + inAlign(align, rowH[r], it.h);
      }
      top += rowH[r] + gap;
    }
    W = w0 ?? 2 * pad + cols * cellW + gap * (cols - 1);
    H = h0 ?? 2 * pad + rowH.fold(0.0, (a, b) => a + b) + gap * math.max(0, rows - 1);
  } else {
    final row = n.type == 'row';
    double main(LayoutItem it) => row ? it.w : it.h;
    double cross(LayoutItem it) => row ? it.h : it.w;
    final mk = row ? 'w' : 'h', ck = row ? 'h' : 'w';
    final sumMain = items.fold(0.0, (a, it) => a + main(it)) + gap * math.max(0, items.length - 1);
    final maxCross = jsMax([0, for (final it in items) cross(it)]);
    W = w0 ?? (row ? sumMain + 2 * pad : maxCross + 2 * pad);
    H = h0 ?? (row ? maxCross + 2 * pad : sumMain + 2 * pad);
    final innerMain = (row ? W : H) - 2 * pad, innerCross = (row ? H : W) - 2 * pad;
    var free = innerMain - sumMain;
    final grows = items.fold(0.0, (a, it) => a + (stretchable(it) ? it.grow : 0));
    if (free > 0 && grows > 0) {
      for (final it in items) {
        if (truthy(it.grow) && stretchable(it)) resize(it, mk, main(it) + free * it.grow / grows);
      }
      free = 0;
    }
    var pos = pad, step = gap;
    if (justify == 'center') {
      pos += free / 2;
    } else if (justify == 'end') {
      pos += free;
    } else if (justify == 'between' && items.length > 1) {
      step += free / (items.length - 1);
    } else if (justify == 'around' && items.isNotEmpty) {
      step += free / items.length;
      pos += free / items.length / 2;
    }
    for (final it in items) {
      if (align == 'stretch') resize(it, ck, innerCross);
      final cp = pad + inAlign(align, innerCross, cross(it));
      if (row) {
        it.x = pos;
        it.y = cp;
      } else {
        it.x = cp;
        it.y = pos;
      }
      pos += main(it) + step;
    }
  }
  return LayoutResult(W, H, items);
}

class _Walker {
  _Walker(this.c, this.doc);
  final TsvgCanvas c;
  final TsvgDoc doc;

  void nodes(List<TsvgNode> ns, Env env, DrawState st) {
    for (final n in ns) {
      node(n, env, st);
    }
  }

  /// `repeat="n"` [`as="i"`] (0.2): the node n times with i = 0…n-1 and i_n = n.
  void node(TsvgNode n, Env parentEnv, DrawState parentSt) {
    final r = n.a['repeat'];
    if (r == null) return one(n, parentEnv, parentSt);
    final c = toNum(value(pick(n.a, 'repeat', parentEnv), parentEnv, doc));
    final count = c.isNaN ? 0 : math.min(10000.0, math.max(0.0, c.floorToDouble())).toInt();
    final as = n.a['as'] ?? 'i';
    for (var k = 0; k < count; k++) {
      final vars = Map<String, Object?>.of(parentEnv.vars)
        ..[as] = k.toDouble()
        ..['${as}_n'] = count.toDouble();
      one(n, parentEnv.withVars(vars), parentSt);
    }
  }

  void one(TsvgNode n, Env parentEnv, DrawState parentSt) {
    if (!visible(n, parentEnv)) return;
    final atRaw = n.a['at'];
    final env = parentEnv.withVars(Map<String, Object?>.of(parentEnv.vars)
      ..['T0'] = atRaw != null ? toNum(value(pick(n.a, 'at', parentEnv), parentEnv, doc)) : parentEnv.vars['T0']);
    final mask = pick(n.a, 'mask', env);
    if (mask != null && mask.isNotEmpty && c.supportsMasks) return masked(n, env, parentSt, mask);
    Object? p(String name, [Object? d]) => prop(n, name, env, doc, d);
    double pn(String name, double d) => toNum(p(name, d));
    final opacity = pn('opacity', 1);
    if (opacity <= 0) return;
    c.save();
    final blend = pick(n.a, 'blend', env);
    var st = parentSt.copyWith(
      alpha: opacity.isNaN ? parentSt.alpha : parentSt.alpha * math.min(1.0, opacity),
      blend: blend != null && blend.isNotEmpty ? blend : null,
    );
    final blur = pn('blur', 0);
    if (blur > 0) st = st.copyWith(blur: double.parse(jsFixed(blur * c.deviceScale, 2)));
    final rot = pn('rot', 0), scale = pn('scale', 1), sx = pn('sx', 1) * scale, sy = pn('sy', 1) * scale;
    final fillRaw = p('fill', n.type == 'text' ? (env.theme['fg'] ?? '#fff') : null);
    final strokeRaw = p('stroke');
    final sw = pn('sw', 0);
    st = st.copyWith(shadow: _shadowOf(p('shadow'), env, st.shadow));
    final dashRaw = p('dash');
    if (truthy(dashRaw) && dashRaw != 'none') {
      final d = _dashOf(toStr(dashRaw));
      // Canvas2D setLineDash: invalid lists are ignored, [] (or all zeros) = solid
      if (d != null) st = DrawState(alpha: st.alpha, blend: st.blend, shadow: st.shadow, blur: st.blur, dash: d.isEmpty ? null : d);
    }
    void pivot(double px, double py) {
      if (truthy(rot) || sx != 1 || sy != 1) {
        c.translate(px, py);
        if (truthy(rot)) c.rotate(rot * math.pi / 180);
        if (sx != 1 || sy != 1) c.scale(sx, sy);
        c.translate(-px, -py);
      }
    }

    void clipTo() {
      final cr = pick(n.a, 'clip', env);
      if (cr == null || cr.isEmpty) return;
      final m = _url.firstMatch(cr);
      final shapes = m != null ? doc.clips[m[1]] : null;
      if (shapes == null) throw TsvgError('unknown clip $cr');
      c.clip([for (final s in shapes) ?shapePath(s, env)]);
    }

    void paint(TsvgShape shape) {
      final f = paintOf(fillRaw, env);
      final s = sw > 0 ? paintOf(strokeRaw, env) : null;
      if (f != null) c.fill(shape, f, st);
      if (s != null) c.stroke(shape, s, StrokeSpec(sw), f != null ? st.copyWith(noShadow: true) : st);
    }

    switch (n.type) {
      case 'group':
      case 'use':
        c.translate(pn('x', 0), pn('y', 0));
        pivot(0, 0);
        clipTo();
        final List<TsvgNode> kids;
        if (n.type == 'use') {
          final sym = doc.symbols[n.a['ref']];
          if (sym == null) throw TsvgError('unknown symbol ${n.a['ref']}');
          kids = sym;
        } else {
          kids = n.children;
        }
        nodes(kids, env, st);
      case 'row':
      case 'col':
      case 'grid':
        final l = arrange(c, n, env);
        c.translate(pn('x', 0) - l.w * pn('ax', 0), pn('y', 0) - l.h * pn('ay', 0));
        pivot(l.w / 2, l.h / 2);
        clipTo();
        if ((truthy(fillRaw) && fillRaw != 'none') || (truthy(strokeRaw) && sw > 0)) {
          final r = pn('r', 0);
          paint(RectShape(0, 0, l.w, l.h, r > 0 ? math.max(0, math.min(r, math.min(l.w / 2, l.h / 2))) : 0));
        }
        // the card's shadow/dash are its own
        final kidSt = DrawState(alpha: st.alpha, blend: st.blend, blur: st.blur);
        for (final it in l.items) {
          c.save();
          c.translate(it.x + it.ox, it.y + it.oy);
          node(it.node, it.env, kidSt);
          c.restore();
        }
      case 'rect':
        final w = pn('w', 100), h = pn('h', 100), x = pn('x', 0) - w * pn('ax', 0), y = pn('y', 0) - h * pn('ay', 0), r = pn('r', 0);
        pivot(x + w / 2, y + h / 2);
        clipTo();
        paint(RectShape(x, y, w, h, r > 0 ? math.max(0, math.min(r, math.min(w / 2, h / 2))) : 0));
      case 'circle':
      case 'ellipse':
        final cx = pn('x', 0), cy = pn('y', 0);
        final rx = toNum(p('r', p('rx', 50.0)));
        final ry = n.type == 'ellipse' ? toNum(p('ry', rx)) : rx;
        final a0 = pn('from', 0), a1 = pn('to', 360);
        pivot(cx, cy);
        clipTo();
        final span = a1 - a0;
        if (span < 360) {
          final sweep = ((span % 360) + 360) % 360;
          // arc="1" (0.2.2): an open arc, no lines to the centre
          paint(EllipseShape(cx, cy, math.max(0, rx), math.max(0, ry),
              start: (a0 - 90) * math.pi / 180, sweep: sweep * math.pi / 180, open: truthy(p('arc', 0.0))));
        } else {
          paint(EllipseShape(cx, cy, math.max(0, rx), math.max(0, ry)));
        }
      case 'line':
        final x1 = pn('x1', 0), y1 = pn('y1', 0), x2 = pn('x2', 0), y2 = pn('y2', 0), draw = pn('draw', 1);
        final raw = truthy(strokeRaw) ? strokeRaw : (truthy(fillRaw) ? fillRaw : env.theme['fg']);
        final s = paintOf(raw, env);
        if (s != null) {
          c.stroke(LineShape(x1, y1, x1 + (x2 - x1) * draw, y1 + (y2 - y1) * draw), s,
              StrokeSpec(truthy(sw) ? sw : 4, roundJoin: false), st);
        }
      case 'path':
        final d = toStr(p('d', ''));
        final draw = pn('draw', 1);
        c.translate(pn('x', 0), pn('y', 0));
        pivot(0, 0);
        clipTo();
        final shape = PathShape(d, parsePathData(d));
        final f = draw >= 1 ? paintOf(fillRaw, env) : null;
        final s = sw > 0 ? paintOf(strokeRaw, env) : null;
        if (f != null) c.fill(shape, f, st);
        if (s != null && !(draw <= 0)) {
          c.stroke(shape, s, StrokeSpec(sw, trim: draw < 1 ? draw : null), f != null ? st.copyWith(noShadow: true) : st);
        }
      case 'text':
        var txt = textOf(n, env);
        final reveal = pn('reveal', 1);
        if (reveal < 1) {
          final cps = txt.runes.toList();
          final k = jsRound(cps.length * reveal);
          txt = String.fromCharCodes(cps.take(k.isNaN || k < 0 ? 0 : k.toInt()));
        }
        final size = pn('size', 48), x = pn('x', 0), y = pn('y', 0);
        final align = toStr(p('align', 'left')), maxw = pn('maxw', 0), lh = pn('lh', 1.25);
        final font = fontSpecOf(p('font', ''), doc, size, p('weight', 400.0), truthy(p('italic', 0.0)));
        final lines = maxw > 0 ? wrapText(c, txt, maxw, font) : txt.split('\n');
        pivot(x, y);
        clipTo();
        final y0 = y - (lines.length - 1) * size * lh / 2;
        final f = paintOf(fillRaw, env);
        final s = sw > 0 ? paintOf(strokeRaw, env) : null;
        for (var i = 0; i < lines.length; i++) {
          c.text(lines[i], x, y0 + i * size * lh, font, align, f, s, sw, st);
        }
      case 'image':
        final ref = n.a['src'] ?? '';
        final w = pn('w', 100), h = pn('h', 100), x = pn('x', 0) - w * pn('ax', 0), y = pn('y', 0) - h * pn('ay', 0), r = pn('r', 0);
        pivot(x + w / 2, y + h / 2);
        clipTo();
        if (r > 0) c.clip([RectShape(x, y, w, h, math.min(r, math.min(w.abs() / 2, h.abs() / 2)))]);
        final img = c.imageSize(ref);
        if (img != null) {
          final fit = toStr(p('fit', 'cover'));
          final iw = img.width, ih = img.height;
          if (fit == 'fill' || iw == 0) {
            c.image(ref, x, y, w, h, st);
          } else {
            final k = fit == 'contain' ? math.min(w / iw, h / ih) : math.max(w / iw, h / ih);
            final dw = iw * k, dh = ih * k;
            c.save();
            c.clip([RectShape(x, y, w, h)]);
            c.image(ref, x + (w - dw) / 2, y + (h - dh) / 2, dw, dh, st);
            c.restore();
          }
        } else {
          c.fill(RectShape(x, y, w, h), const SolidPaint(Rgba(0x88, 0x88, 0x88, 0x44 / 255)), st);
        }
    }
    c.restore();
  }

  /// mask="url(#m)": node into a layer, mask shapes on top with dst-in.
  void masked(TsvgNode n, Env env, DrawState parentSt, String maskRef) {
    final m = _url.firstMatch(maskRef);
    final shapes = m != null ? doc.masks[m[1]] : null;
    if (shapes == null) throw TsvgError('unknown mask $maskRef');
    final plainAttrs = <String, String>{
      for (final e in n.a.entries)
        if (e.key != 'mask' && e.key != 'repeat' && !e.key.startsWith('mask.')) e.key: e.value,
    };
    c.beginLayer();
    one(n.withAttrs(plainAttrs), env, DrawState(alpha: parentSt.alpha));
    c.beginMask();
    // the mask is drawn in the node's coordinate space (after its x/y for groups)
    if (n.type == 'group' || n.type == 'use' || n.type == 'path') {
      c.translate(toNum(prop(n, 'x', env, doc, 0.0)), toNum(prop(n, 'y', env, doc, 0.0)));
    }
    nodes(shapes, env, DrawState.plain);
    c.restore();
    c.restore();
  }
}

/// Draws the frame at time [t]. The canvas must already map layout units
/// (layout.w × layout.h) to the target.
void renderFrame(TsvgCanvas canvas, TsvgDoc doc, double t, Map<String, String> opts, TsvgLayout layout) {
  doc = forOptions(doc, opts);
  final env = makeEnv(doc, opts, layout, t);
  final w = _Walker(canvas, doc);
  canvas.save();
  try {
    final bg = paintOf(env.theme['bg'] ?? '#000', env);
    if (bg != null) canvas.fill(RectShape(0, 0, layout.w, layout.h), bg, DrawState.plain);
    w.nodes(doc.backdrop, env, DrawState.plain);
    final last = doc.scenes.isEmpty ? null : doc.scenes.last;
    for (final sc in doc.scenes) {
      final active = (t >= sc.start && t < sc.start + sc.dur) || (identical(sc, last) && t >= sc.start + sc.dur);
      if (!active) continue;
      final T = math.min(t, sc.start + sc.dur - 1e-6) - sc.start;
      final vars = Map<String, Object?>.of(env.vars)
        ..['T'] = T
        ..['p'] = T / sc.dur
        ..['sdur'] = sc.dur;
      w.nodes(sc.nodes, env.withScene(sc, vars), DrawState.plain);
    }
    w.nodes(doc.overlay, env, DrawState.plain);
  } finally {
    canvas.restore();
  }
}

/// Option defaults: each option's `default`, else its first choice.
Map<String, String> defaultOptions(TsvgDoc doc) => {
      for (final o in doc.options)
        if ((o.defaultValue ?? '').isNotEmpty || o.choices.isNotEmpty)
          o.id: (o.defaultValue ?? '').isNotEmpty ? o.defaultValue! : o.choices.first.id,
    };

/// Every combination of option choices.
List<Map<String, String>> optionCombos(TsvgDoc doc) {
  var out = <Map<String, String>>[{}];
  for (final o in doc.options) {
    out = [
      for (final c in out)
        for (final ch in o.choices) {...c, o.id: ch.id},
    ];
  }
  return out;
}

/// Resolves a label that may be an `@string` (chapters, option labels).
String labelOf(TsvgDoc doc, String v, Map<String, String> opts) =>
    v.startsWith('@') ? toStr(value(v, makeEnv(doc, opts, doc.layouts.first, 0), doc)) : v;
