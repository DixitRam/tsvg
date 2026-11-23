// TSVG document model and parser (port of `parse` in tsvg-core.js).
import 'expr.dart';
import 'js.dart';
import 'xml.dart';

const String tsvgVersion = '0.1';

class TsvgLayout {
  const TsvgLayout(this.id, this.w, this.h);
  final String id;
  final double w, h;
  bool get portrait => h > w;
  @override
  String toString() => '$id ${numStr(w)}×${numStr(h)}';
}

class TsvgChoice {
  const TsvgChoice(this.id, this.label, this.attrs);
  final String id, label;
  final Map<String, String> attrs;
}

class TsvgOption {
  const TsvgOption(this.id, this.label, this.defaultValue, this.choices);
  final String id, label;
  final String? defaultValue;
  final List<TsvgChoice> choices;
}

class TsvgFont {
  const TsvgFont({required this.id, required this.family, required this.src, this.weight = '1 1000', this.style = 'normal'});
  final String? id;
  final String family;
  final String? src;
  final String weight, style;
}

class TsvgAsset {
  const TsvgAsset(this.src, this.type);
  final String? src;
  final String type; // image | audio | font
}

class TsvgVoice {
  const TsvgVoice({required this.src, this.dur = 0, this.hash = '', this.engine = ''});
  final String? src;
  final double dur;
  final String hash, engine;
}

/// A clip on an audio bus (from `<music>`, `<sfx>` or a baked `<say>`).
class TsvgAudio {
  TsvgAudio({required this.bus, required this.src, required this.start, this.loop = false, this.vol = 1, this.when});
  final String bus;
  final String? src;
  final double start;
  final bool loop;
  final double vol;
  final String? when;
  TsvgAudio copy() => TsvgAudio(bus: bus, src: src, start: start, loop: loop, vol: vol, when: when);
  @override
  String toString() => 'TsvgAudio($bus $src @$start${loop ? ' loop' : ''} vol=$vol)';
}

class TsvgSay {
  const TsvgSay({required this.key, required this.start, required this.raw, this.scene});
  final String key;
  final double start;
  final Map<String, String> raw;
  final String? scene;
}

class TsvgChapter {
  const TsvgChapter(this.t, this.label);
  final double t;
  final String label;
}

class TsvgKey {
  const TsvgKey(this.at, this.v);
  final double at;
  final String v;
}

/// `<anim>` (attrs in [a]) or `<keys>` (frames in [keys]).
class TsvgAnim {
  TsvgAnim.anim(this.prop, this.a)
      : keys = null,
        ease = null;
  TsvgAnim.keys(this.prop, this.keys, this.ease) : a = const {};
  final String? prop;
  final Map<String, String> a;
  final List<TsvgKey>? keys;
  final String? ease;
}

/// A drawable node: rect, circle, ellipse, line, path, text, image, group, use.
class TsvgNode {
  TsvgNode(this.type, this.a, {this.line = 0});
  final String type;
  final Map<String, String> a;
  final List<TsvgAnim> anims = [];
  List<TsvgNode> children = [];
  final int line;

  /// Shallow copy with different attributes (used by masks).
  TsvgNode withAttrs(Map<String, String> attrs) {
    final n = TsvgNode(type, attrs, line: line);
    n.anims.addAll(anims);
    n.children = children;
    return n;
  }
}

class TsvgGradient {
  const TsvgGradient(this.type, this.a, this.stops);
  final String type; // linear | radial
  final Map<String, String> a;
  final List<Map<String, String>> stops;
}

class TsvgScene {
  const TsvgScene(this.id, this.start, this.dur, this.nodes);
  final String? id;
  final double start, dur;
  final List<TsvgNode> nodes;
}

class TsvgFnSrc {
  const TsvgFnSrc(this.args, this.src);
  final List<String> args;
  final String src;
}

class TsvgDoc {
  String version = tsvgVersion;
  String title = '';
  String font = '';
  final List<TsvgLayout> layouts = [];
  final List<TsvgOption> options = [];
  final Map<String, Map<String, double>> mixes = {};
  final Map<String, Map<String, String>> themes = {};
  final Map<String, Map<String, String>> strings = {};
  final Map<String, UserFn> fns = {};
  final Map<String, TsvgFnSrc> fnSrc = {};
  final Map<String, List<TsvgNode>> symbols = {};
  final Map<String, TsvgGradient> gradients = {};
  final Map<String, List<TsvgNode>> clips = {};
  final Map<String, List<TsvgNode>> masks = {};
  final Map<String, TsvgAsset> assets = {};
  final List<TsvgFont> fonts = [];
  final List<TsvgScene> scenes = [];
  List<TsvgNode> backdrop = [];
  List<TsvgNode> overlay = [];
  final List<TsvgAudio> audio = [];
  final List<TsvgSay> says = [];
  final Map<String, TsvgVoice> voices = {}; // key: "say|lang"
  final List<TsvgChapter> chapters = [];
  double duration = 0;
  final List<String> warnings = [];

  TsvgLayout layout(String? id) => layouts.firstWhere((l) => l.id == id, orElse: () => layouts.first);
}

const Set<String> shapeTypes = {'rect', 'circle', 'ellipse', 'line', 'path', 'text', 'image', 'group', 'use'};
final RegExp _audioExt = RegExp(r'\.(ogg|opus|mp3|m4a|wav|aac|flac)$', caseSensitive: false);
final RegExp _fontExt = RegExp(r'\.(ttf|otf|woff2?)$', caseSensitive: false);

String guessType(String? src) =>
    _audioExt.hasMatch(src ?? '') ? 'audio' : (_fontExt.hasMatch(src ?? '') ? 'font' : 'image');

List<TsvgKey> parseKeys(String s) => s
    .split(';')
    .map((x) => x.trim())
    .where((x) => x.isNotEmpty)
    .map((x) {
      final i = x.indexOf(':');
      final at = i < 0 ? x.substring(0, x.length - 1) : x.substring(0, i);
      return TsvgKey(toNum(at), x.substring(i + 1).trim());
    })
    .toList();

double _plus(String? s) => toNum(s);

/// Parses a TSVG document. Throws [TsvgError].
TsvgDoc parseTsvg(String xml) {
  final r = parseXml(xml);
  if (r.name != 'tsvg') throw TsvgError('root element must be <tsvg>, found <${r.name}>');
  List<XmlEl> kids(XmlEl el, [String? name]) =>
      el.children.where((c) => name == null || c.name == name).toList();
  XmlEl? one(String name) {
    for (final c in r.children) {
      if (c.name == name) return c;
    }
    return null;
  }

  final doc = TsvgDoc()
    ..version = r.attrs['version'] ?? tsvgVersion
    ..title = r.attrs['title'] ?? ''
    ..font = r.attrs['font'] ?? '';

  List<TsvgNode> buildNodes(XmlEl el) {
    final out = <TsvgNode>[];
    for (final c in el.children) {
      if (!shapeTypes.contains(c.name)) continue;
      final node = TsvgNode(c.name, c.attrs, line: c.line);
      for (final k in c.children) {
        if (k.name == 'anim') {
          node.anims.add(TsvgAnim.anim(k.attrs['prop'], k.attrs));
        } else if (k.name == 'keys') {
          final v = k.attrs['v'];
          node.anims.add(TsvgAnim.keys(k.attrs['prop'], parseKeys(v != null && v.isNotEmpty ? v : k.text), k.attrs['ease'] ?? 'io'));
        }
      }
      if (c.name == 'group') node.children = buildNodes(c);
      out.add(node);
    }
    return out;
  }

  void walk(XmlEl el, void Function(XmlEl) f) {
    for (final c in el.children) {
      f(c);
      walk(c, f);
    }
  }

  for (final l in kids(one('layouts') ?? r, 'layout')) {
    doc.layouts.add(TsvgLayout(l.attrs['id'] ?? '', _plus(l.attrs['w']), _plus(l.attrs['h'])));
  }
  if (doc.layouts.isEmpty) doc.layouts.add(const TsvgLayout('landscape', 1920, 1080));
  for (final o in kids(one('options') ?? r, 'option')) {
    final id = o.attrs['id'] ?? '';
    doc.options.add(TsvgOption(
      id,
      _or(o.attrs['label'], id),
      o.attrs['default'],
      [for (final c in kids(o, 'choice')) TsvgChoice(c.attrs['id'] ?? '', _or(c.attrs['label'], c.attrs['id'] ?? ''), c.attrs)],
    ));
  }
  for (final m in kids(one('mixes') ?? r, 'mix')) {
    doc.mixes[m.attrs['id'] ?? 'undefined'] = {
      for (final e in m.attrs.entries)
        if (e.key != 'id') e.key: _plus(e.value),
    };
  }
  for (final th in kids(one('themes') ?? r, 'theme')) {
    doc.themes[th.attrs['id'] ?? 'undefined'] = Map.of(th.attrs)..remove('id');
  }
  for (final s in kids(one('strings') ?? r, 's')) {
    doc.strings[s.attrs['id'] ?? 'undefined'] = Map.of(s.attrs)..remove('id');
  }
  final defs = one('defs');
  if (defs != null) {
    for (final d in defs.children) {
      final id = d.attrs['id'] ?? 'undefined';
      if (d.name == 'fn') {
        final args = (d.attrs['args'] ?? '').split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
        final src = d.text.trim();
        final body = compileExpr(src);
        doc.fnSrc[id] = TsvgFnSrc(args, src);
        doc.fns[id] = (vals, env) {
          final vars = Map<String, Object?>.of(env.vars);
          for (var i = 0; i < args.length; i++) {
            vars[args[i]] = i < vals.length ? vals[i] : null;
          }
          return body(env.withVars(vars));
        };
      } else if (d.name == 'symbol') {
        doc.symbols[id] = buildNodes(d);
      } else if (d.name == 'linear' || d.name == 'radial') {
        doc.gradients[id] = TsvgGradient(d.name, d.attrs, [for (final s in kids(d, 'stop')) s.attrs]);
      } else if (d.name == 'clip') {
        doc.clips[id] = buildNodes(d);
      } else if (d.name == 'mask') {
        doc.masks[id] = buildNodes(d);
      }
    }
  }
  for (final a in kids(one('assets') ?? r)) {
    if (a.name == 'font') {
      doc.fonts.add(TsvgFont(
        id: a.attrs['id'],
        family: _or(a.attrs['family'], a.attrs['id'] ?? ''),
        src: a.attrs['src'],
        weight: _or(a.attrs['weight'], '1 1000'),
        style: _or(a.attrs['style'], 'normal'),
      ));
    } else if (a.name == 'asset') {
      doc.assets[a.attrs['id'] ?? 'undefined'] = TsvgAsset(a.attrs['src'], _or(a.attrs['type'], guessType(a.attrs['src'])));
    }
  }
  for (final v in kids(one('voices') ?? r, 'voice')) {
    final dur = _plus(v.attrs['dur']);
    doc.voices['${v.attrs['say']}|${v.attrs['lang']}'] = TsvgVoice(
      src: v.attrs['src'],
      dur: truthy(dur) ? dur : 0,
      hash: v.attrs['hash'] ?? '',
      engine: v.attrs['engine'] ?? '',
    );
  }
  for (final m in kids(r, 'music')) {
    doc.audio.add(TsvgAudio(
      bus: _or(m.attrs['bus'], 'music'),
      src: m.attrs['src'],
      start: _plus(_or(m.attrs['start'], '0')),
      loop: m.attrs['loop'] == '1',
      vol: _plus(_or(m.attrs['vol'], '1')),
      when: m.attrs['when'],
    ));
  }
  final bd = one('backdrop');
  if (bd != null) doc.backdrop = buildNodes(bd);
  final ov = one('overlay');
  if (ov != null) doc.overlay = buildNodes(ov);
  var cursor = 0.0;
  for (final sc in kids(one('timeline') ?? r, 'scene')) {
    final start = sc.attrs['start'] != null ? _plus(sc.attrs['start']) : cursor;
    final dur = _plus(sc.attrs['dur']);
    if (!(dur > 0)) throw TsvgError('<scene id="${sc.attrs['id']}"> needs dur > 0');
    doc.scenes.add(TsvgScene(sc.attrs['id'], start, dur, buildNodes(sc)));
    final chapter = sc.attrs['chapter'];
    if (chapter != null && chapter.isNotEmpty) doc.chapters.add(TsvgChapter(start, chapter));
    walk(sc, (el) {
      if (el.name == 'say') {
        final text = el.attrs['text'];
        final idAttr = el.attrs['id'];
        final key = idAttr != null && idAttr.isNotEmpty
            ? idAttr
            : (text != null && text.startsWith('@') ? text.substring(1) : 'say${doc.says.length}');
        doc.says.add(TsvgSay(key: key, start: start + _plus(_or(el.attrs['at'], '0')), raw: el.attrs, scene: sc.attrs['id']));
      }
      if (el.name == 'sfx') {
        doc.audio.add(TsvgAudio(
          bus: _or(el.attrs['bus'], 'sfx'),
          src: el.attrs['src'],
          start: start + _plus(_or(el.attrs['at'], '0')),
          vol: _plus(_or(el.attrs['vol'], '1')),
          when: el.attrs['when'],
        ));
      }
    });
    cursor = start + dur;
    if (cursor > doc.duration) doc.duration = cursor;
  }
  final d = r.attrs['duration'];
  if (d != null && d.isNotEmpty) doc.duration = _plus(d);
  return doc;
}

/// JS `a || b` for optional attribute strings.
String _or(String? a, String b) => a == null || a.isEmpty ? b : a;
