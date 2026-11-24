// TSVG document model and parser (port of `parse` in tsvg-core.js).
import 'dart:math' as math;

import 'expr.dart';
import 'js.dart';
import 'render.dart' show strOf, makeEnv, value, pick, defaultOptions;
import 'xml.dart';

const String tsvgVersion = '0.2.2';

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
  const TsvgAsset(this.src, this.type, {this.poster, this.dur});
  final String? src;
  final String type; // image | audio | font | video

  /// `<video>` clips: a poster frame (jpg path) and the clip length in seconds
  /// (`tsvg pack` adds both).
  final String? poster;
  final double? dur;
}

class TsvgVoice {
  const TsvgVoice({required this.src, this.dur = 0, this.hash = '', this.engine = ''});
  final String? src;
  final double dur;
  final String hash, engine;
}

/// A clip on an audio bus (from `<music>`, `<sfx>` or a baked `<say>`).
class TsvgAudio {
  TsvgAudio({required this.bus, required this.src, required this.start, this.loop = false, this.vol = 1, this.when, this.beats});
  final String bus;
  final String? src;
  final double start;
  final bool loop;
  final double vol;
  final String? when;

  /// `<music beats="id">` (0.9): the `<data id>` holding the music's beat grid (written by tsvg bake).
  final String? beats;
  TsvgAudio copy() => TsvgAudio(bus: bus, src: src, start: start, loop: loop, vol: vol, when: when, beats: beats);
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

/// A drawable node: rect, circle, ellipse, line, path, text, image, video, group, use.
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

class TsvgScene implements TsvgCueHost {
  const TsvgScene(this.id, this.start, this.dur, this.nodes, {this.cues = const {}, this.line = 0, this.trans});
  @override
  final String? id;
  final double start, dur;
  final List<TsvgNode> nodes;

  /// Enabled `<say>` lines by key and by index ("0", "1", …), scene-relative.
  @override
  final Map<String, TsvgCue> cues;
  final int line;

  /// The incoming transition as written (`in="push 0.6 left io"`, or the
  /// timeline's `in` default), 0.6; see [transitionOf].
  final String? trans;
}

/// A `<say>` as written (its time is laid out by [timing]).
class TsvgSaySrc {
  const TsvgSaySrc(this.key, this.raw, this.scene);
  final String key;
  final Map<String, String> raw;
  final String? scene;
}

/// A `<scene>` as written: attributes, nodes, its says and sfx.
class TsvgSceneSrc {
  TsvgSceneSrc(this.id, this.a, this.nodes, this.line);
  final String? id;
  final Map<String, String> a;
  final List<TsvgNode> nodes;
  final int line;
  final List<TsvgSaySrc> says = [];
  final List<Map<String, String>> sfx = [];
}

/// The timeline laid out for one option set.
class TsvgTiming {
  const TsvgTiming(this.scenes, this.says, this.audio, this.chapters, this.duration);
  final List<TsvgScene> scenes;
  final List<TsvgSay> says;
  final List<TsvgAudio> audio;
  final List<TsvgChapter> chapters;
  final double duration;
}

class TsvgFnSrc {
  const TsvgFnSrc(this.args, this.src);
  final List<String> args;
  final String src;
}

class TsvgDoc implements TsvgDataHost {
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

  /// `<data id v>` lists (0.2): numbers stay numbers (double), the rest are strings.
  @override
  final Map<String, List<Object>> data = {};

  /// Image aspect ratios (width / height) by asset id and path, filled in by the media loader.
  @override
  final Map<String, double> aspects = {};

  @override
  String stringOf(String id, Env env) => strOf(this, id, env);
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

  /// The timeline as written; [timing] lays it out for one option set (0.5).
  final List<TsvgSceneSrc> sceneSrc = [];

  /// `<music>` clips (the audio before scene sfx are added).
  final List<TsvgAudio> music = [];

  /// True when the timing depends on the options (`dur="auto"`, `dur.gu`, `at.gu`…).
  bool timed = false;

  /// The root `duration` attribute, as written.
  String? rootDuration;

  /// `<timeline in="…">`: the default transition for every scene (0.6).
  String? timelineIn;

  /// [forOptions] cache: option values → timed view.
  final Map<String, TsvgDoc> views = {};

  TsvgLayout layout(String? id) => layouts.firstWhere((l) => l.id == id, orElse: () => layouts.first);
}

/// The document as timed for one option set: shares everything with [base]
/// except the scenes, says, audio, chapters and duration.
class _TsvgView extends TsvgDoc {
  _TsvgView(this.base, this.tm);
  final TsvgDoc base;
  final TsvgTiming tm;
  @override
  List<TsvgScene> get scenes => tm.scenes;
  @override
  List<TsvgSay> get says => tm.says;
  @override
  List<TsvgAudio> get audio => tm.audio;
  @override
  List<TsvgChapter> get chapters => tm.chapters;
  @override
  double get duration => tm.duration;
  @override
  bool get timed => false;
  @override
  String get version => base.version;
  @override
  String get title => base.title;
  @override
  String get font => base.font;
  @override
  List<TsvgLayout> get layouts => base.layouts;
  @override
  List<TsvgOption> get options => base.options;
  @override
  Map<String, Map<String, double>> get mixes => base.mixes;
  @override
  Map<String, Map<String, String>> get themes => base.themes;
  @override
  Map<String, Map<String, String>> get strings => base.strings;
  @override
  Map<String, UserFn> get fns => base.fns;
  @override
  Map<String, TsvgFnSrc> get fnSrc => base.fnSrc;
  @override
  Map<String, List<Object>> get data => base.data;
  @override
  Map<String, double> get aspects => base.aspects;
  @override
  Map<String, List<TsvgNode>> get symbols => base.symbols;
  @override
  Map<String, TsvgGradient> get gradients => base.gradients;
  @override
  Map<String, List<TsvgNode>> get clips => base.clips;
  @override
  Map<String, List<TsvgNode>> get masks => base.masks;
  @override
  Map<String, TsvgAsset> get assets => base.assets;
  @override
  List<TsvgFont> get fonts => base.fonts;
  @override
  List<TsvgNode> get backdrop => base.backdrop;
  @override
  List<TsvgNode> get overlay => base.overlay;
  @override
  Map<String, TsvgVoice> get voices => base.voices;
  @override
  List<String> get warnings => base.warnings;
  @override
  List<TsvgSceneSrc> get sceneSrc => base.sceneSrc;
  @override
  List<TsvgAudio> get music => base.music;
  @override
  String? get rootDuration => base.rootDuration;
  @override
  String? get timelineIn => base.timelineIn;
}

/// The document as timed for [opts] (the document itself when its timing does
/// not depend on the options). Views are cached per option values.
TsvgDoc forOptions(TsvgDoc doc, Map<String, String> opts) {
  if (!doc.timed) return doc;
  final key = doc.options.map((o) => opts[o.id] ?? '').join('|');
  return doc.views[key] ??= _TsvgView(doc, timing(doc, {...defaultOptions(doc), ...opts}));
}

/// Length of a say line: the baked voice for [lang], else `dur`, else ~0.42 s a word (min 1.5).
double lineDur(TsvgDoc doc, String key, Map<String, String> raw, String? lang, Env env) {
  final baked = doc.voices['$key|${toStr(lang)}'];
  if (baked != null && baked.dur > 0) return baked.dur;
  final d = raw['dur'];
  if (d != null && d.isNotEmpty) return toNum(d);
  var text = '';
  try {
    text = toStr(value(raw['text'], env, doc));
  } catch (_) {}
  return math.max(1.5, text.split(RegExp(r'\s+')).length * 0.42);
}

double _ms(double v) => jsRound(v * 1000) / 1000;

/// Scene starts/lengths, say and sfx times for one option set. `dur="auto"`: the
/// scene lasts as long as its narration (+ pad, at least min); a `<say>` without
/// `at` in such a scene follows the previous one (+ gap). Variants (`dur.gu`,
/// `at.gu`) and values (`=expr`) work too.
TsvgTiming timing(TsvgDoc doc, Map<String, String> opts) {
  final env = makeEnv(doc, opts, doc.layouts.first, 0);
  Object? num(Map<String, String> a, String k, Object? d) {
    final raw = pick(a, k, env);
    if (raw == null) return d;
    try {
      return value(raw, env, doc);
    } on TsvgError catch (e) {
      throw TsvgError('$k="$raw": ${e.message}');
    }
  }

  final scenes = <TsvgScene>[], says = <TsvgSay>[], audio = [...doc.music], chapters = <TsvgChapter>[];
  var cursor = 0.0, duration = 0.0;
  for (final s in doc.sceneSrc) {
    final start = toNum(num(s.a, 'start', cursor));
    final rawDur = num(s.a, 'dur', null);
    final auto = rawDur == 'auto';
    final gap = toNum(num(s.a, 'gap', 0.3));
    final cues = <String, TsvgCue>{};
    double? prevEnd;
    var last = 0.0, i = 0;
    for (final x in s.says) {
      final w = x.raw['when'];
      final on = w == null || w.isEmpty || truthy(compiled(w.startsWith('=') ? w.substring(1) : w)(env));
      final explicit = pick(x.raw, 'at', env);
      final at = explicit != null ? toNum(value(explicit, env, doc)) : (auto ? (prevEnd == null ? 0.4 : prevEnd + gap) : 0.0);
      final d = lineDur(doc, x.key, x.raw, opts['lang'], env);
      says.add(TsvgSay(key: x.key, start: start + at, raw: x.raw, scene: s.id));
      if (on) {
        cues[x.key] = cues['$i'] = TsvgCue(at, at + d);
        i++;
        prevEnd = at + d;
        last = math.max(last, at + d);
      }
    }
    final double dur;
    if (auto) {
      dur = _ms(math.max(toNum(num(s.a, 'min', 2.0)), last + toNum(num(s.a, 'pad', 0.8))));
    } else {
      dur = toNum(rawDur);
      if (!(dur > 0)) throw TsvgError('<scene id="${s.id}"> needs dur > 0 (or dur="auto")');
    }
    for (final f in s.sfx) {
      audio.add(TsvgAudio(
        bus: _or(f['bus'], 'sfx'),
        src: f['src'],
        start: start + toNum(num(f, 'at', 0.0)),
        vol: _plus(_or(f['vol'], '1')),
        when: f['when'],
      ));
    }
    scenes.add(TsvgScene(s.id, start, dur, s.nodes, cues: cues, line: s.line, trans: pick(s.a, 'in', env) ?? doc.timelineIn));
    final chapter = s.a['chapter'];
    if (chapter != null && chapter.isNotEmpty) chapters.add(TsvgChapter(start, chapter));
    cursor = _ms(start + dur);
    duration = math.max(duration, cursor);
  }
  final rd = doc.rootDuration;
  if (rd != null && rd.isNotEmpty) duration = _plus(rd);
  return TsvgTiming(scenes, says, audio, chapters, duration);
}

const Set<String> shapeTypes = {'rect', 'circle', 'ellipse', 'line', 'path', 'text', 'image', 'video', 'group', 'use', 'row', 'col', 'grid'};

/// Auto layout containers (0.5).
const Set<String> layoutTypes = {'row', 'col', 'grid'};
final RegExp _audioExt = RegExp(r'\.(ogg|opus|mp3|m4a|wav|aac|flac)$', caseSensitive: false);
final RegExp _fontExt = RegExp(r'\.(ttf|otf|woff2?)$', caseSensitive: false);
final RegExp _videoExt = RegExp(r'\.(mp4|webm|mov|m4v)$', caseSensitive: false);

String guessType(String? src) => _audioExt.hasMatch(src ?? '')
    ? 'audio'
    : (_fontExt.hasMatch(src ?? '') ? 'font' : (_videoExt.hasMatch(src ?? '') ? 'video' : 'image'));

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
      // <image src="path.png"> / <video src="clip.mp4"> need no <asset> (0.4)
      final isrc = c.attrs['src'];
      if ((c.name == 'image' || c.name == 'video') && isrc != null && !doc.assets.containsKey(isrc) && RegExp(r'[/.]').hasMatch(isrc)) {
        doc.assets[isrc] = TsvgAsset(isrc, c.name, poster: c.name == 'video' ? c.attrs['poster'] : null);
      }
      for (final k in c.children) {
        if (k.name == 'anim') {
          node.anims.add(TsvgAnim.anim(k.attrs['prop'], k.attrs));
        } else if (k.name == 'keys') {
          final v = k.attrs['v'];
          node.anims.add(TsvgAnim.keys(k.attrs['prop'], parseKeys(v != null && v.isNotEmpty ? v : k.text), k.attrs['ease'] ?? 'io'));
        }
      }
      if (c.name == 'group' || layoutTypes.contains(c.name)) node.children = buildNodes(c);
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
      } else if (d.name == 'data') {
        doc.data[id] = [
          for (final x in (d.attrs['v'] ?? d.text).split(RegExp(r'[,\n]')).map((x) => x.trim()))
            if (x.isNotEmpty) _numericRe.hasMatch(x) ? double.parse(x) : x.replaceAll(RegExp(r'''^['"]|['"]$'''), ''),
        ];
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
      doc.assets[a.attrs['id'] ?? 'undefined'] = TsvgAsset(a.attrs['src'], _or(a.attrs['type'], guessType(a.attrs['src'])),
          poster: a.attrs['poster'], dur: a.attrs['dur'] != null ? toNum(a.attrs['dur']) : null);
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
      beats: m.attrs['beats'],
    ));
  }
  final bd = one('backdrop');
  if (bd != null) doc.backdrop = buildNodes(bd);
  final ov = one('overlay');
  if (ov != null) doc.overlay = buildNodes(ov);
  // the timeline is kept as written; timing() lays it out for one option set (scene lengths may follow the narration)
  var sayN = 0;
  for (final sc in kids(one('timeline') ?? r, 'scene')) {
    final src = TsvgSceneSrc(sc.attrs['id'], sc.attrs, buildNodes(sc), sc.line);
    walk(sc, (el) {
      if (el.name == 'say') {
        final text = el.attrs['text'];
        final idAttr = el.attrs['id'];
        final key = idAttr != null && idAttr.isNotEmpty
            ? idAttr
            : (text != null && text.startsWith('@') ? text.substring(1) : 'say$sayN');
        src.says.add(TsvgSaySrc(key, el.attrs, sc.attrs['id']));
        sayN++;
      }
      if (el.name == 'sfx') src.sfx.add(el.attrs);
    });
    doc.sceneSrc.add(src);
  }
  doc.music.addAll(doc.audio);
  for (final m in doc.music) {
    final b = m.beats;
    if (b != null && b.isNotEmpty && !doc.data.containsKey(b)) doc.data[b] = []; // until tsvg bake writes the grid
  }
  doc.timelineIn = one('timeline')?.attrs['in']; // default transition for every scene
  bool varied(Map<String, String> a, List<String> names) =>
      a.keys.any((k) => names.contains(k.split('.').first) && k.contains('.'));
  doc.timed = doc.sceneSrc.any((s) =>
      s.a['dur'] == 'auto' ||
      varied(s.a, ['dur', 'start']) ||
      s.says.any((x) => varied(x.raw, ['at'])) ||
      s.sfx.any((x) => varied(x, ['at'])));
  doc.rootDuration = r.attrs['duration'];
  final tm = timing(doc, defaultOptions(doc));
  doc.audio
    ..clear()
    ..addAll(tm.audio);
  doc.scenes.addAll(tm.scenes);
  doc.says.addAll(tm.says);
  doc.chapters.addAll(tm.chapters);
  doc.duration = tm.duration;
  return doc;
}

final RegExp _numericRe = RegExp(r'^-?[0-9]*\.?[0-9]+$');

/// JS `a || b` for optional attribute strings.
String _or(String? a, String b) => a == null || a.isEmpty ? b : a;
