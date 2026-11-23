// Unit tests for the pure-Dart core: expressions, XML, parser, value
// resolution, audio plan, zip, validate. The "reference" group evaluates the
// same inputs with web/tsvg-core.js under node and expects identical results
// (skipped when node is not installed).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsvg/tsvg_core.dart';
import 'package:tsvg/tsvg_io.dart';

final String repo = Directory.current.parent.path;
final String demoPath = '$repo/examples/demo/demo.tsvg';

TsvgDoc mini() => parseTsvg('''
<tsvg font="Inter">
  <layouts><layout id="landscape" w="1920" h="1080"/><layout id="portrait" w="1080" h="1920"/></layouts>
  <options>
    <option id="lang" default="en"><choice id="en"/><choice id="gu"/></option>
    <option id="theme"><choice id="dark"/><choice id="light"/></option>
  </options>
  <themes><theme id="dark" fg="#fff" bg="#000"/><theme id="light" fg="#000" bg="#fff"/></themes>
  <strings><s id="hi" en="Hello {W}" gu="Kem cho"/></strings>
  <defs><fn id="twice" args="x">x*2</fn></defs>
  <timeline>
    <scene id="a" dur="2" chapter="@hi"><rect x="10" x.portrait="20" x.gu="30" w="=W/2"/></scene>
    <scene id="b" dur="3"><say text="@hi" at="0.5"/><sfx src="a/b.ogg" at="1"/></scene>
  </timeline>
</tsvg>''');

Env envFor(TsvgDoc d, {Map<String, String>? opts, String layout = 'landscape', double t = 0}) =>
    makeEnv(d, {...defaultOptions(d), ...?opts}, d.layout(layout), t);

Object? ev(String src, [Env? env]) => compileExpr(src)(env ?? envFor(mini()));

void main() {
  group('expressions', () {
    test('arithmetic and precedence', () {
      expect(ev('1 + 2 * 3'), 7);
      expect(ev('(1 + 2) * 3'), 9);
      expect(ev('2 ^ 3 ^ 2'), 512); // right associative
      expect(ev('-2 ^ 2'), 4); // unary minus binds tighter (like the reference)
      expect(ev('-7 % 3'), 2); // floored modulo
      expect(ev('7 % -3'), -2);
      expect(ev('1e3 + .5'), 1000.5);
    });
    test('comparison, logic, ternary', () {
      expect(ev('1 < 2'), 1);
      expect(ev('2 <= 1'), 0);
      expect(ev("'a' == 'a'"), 1);
      expect(ev("1 == '1'"), 1); // loose equality
      expect(ev('0 || 3'), 1);
      expect(ev('1 && 0'), 0);
      expect(ev('!0'), 1);
      expect(ev("1 ? 'y' : 'n'"), 'y');
      expect(ev("0 ? 'y' : 1 ? 'm' : 'n'"), 'm');
    });
    test('strings', () {
      expect(ev("'a' + 1"), 'a1');
      expect(ev("1.5 + 'x'"), '1.5x');
      expect(ev('str(2) + str(0.25)'), '20.25');
      expect(ev('fmt(3.14159, 2)'), '3.14');
      expect(ev('fmt(2.5)'), '3');
      expect(ev('rgba(10.4, 20.6, 30, 0.5)'), 'rgba(10,21,30,0.5)');
    });
    test('built-ins', () {
      expect(ev('min(3, 1, 2)'), 1);
      expect(ev('max(3, 1, 2)'), 3);
      expect(ev('clamp(5, 0, 2)'), 2);
      expect(ev('lerp(0, 10, 0.25)'), 2.5);
      expect(ev('step(0.5, 0.7)'), 1);
      expect(ev('smooth(0, 1, 0.5)'), 0.5);
      expect(ev('fract(2.75)'), 0.75);
      expect(ev('round(2.5)'), 3);
      expect(ev('round(-2.5)'), -2); // JS Math.round
      expect(ev('sign(-3)'), -1);
      expect(ev("ease(0.5, 'io')"), 0.5);
      expect(ev("ease(2, 'out')"), 1);
      expect(ev("mix('#000000', '#ffffff', 0.5)"), 'rgba(128,128,128,1)');
      expect(ev('mix(0, 10, 0.3)'), 3);
      expect((ev('PI') as double), closeTo(3.14159, 1e-5));
    });
    test('variables, theme tokens, options, user fns', () {
      final d = mini();
      final e = envFor(d, opts: {'lang': 'gu'}, layout: 'portrait', t: 1.5);
      expect(ev('W', e), 1080);
      expect(ev('portrait', e), 1);
      expect(ev('layout', e), 'portrait');
      expect(ev('lang', e), 'gu');
      expect(ev(r'$fg', e), '#fff');
      expect(ev('twice(t)', e), 3);
    });
    test('errors', () {
      expect(() => compileExpr('1 +'), throwsA(isA<TsvgError>()));
      expect(() => compileExpr('(1'), throwsA(isA<TsvgError>()));
      expect(() => compileExpr("'open"), throwsA(isA<TsvgError>()));
      expect(() => compileExpr('1 # 2'), throwsA(isA<TsvgError>()));
      expect(() => ev('nope'), throwsA(predicate((e) => '$e' == 'unknown variable nope')));
      expect(() => ev('nope(1)'), throwsA(predicate((e) => '$e' == 'unknown function nope()')));
      expect(() => ev(r'$nope'), throwsA(predicate((e) => '$e' == r'unknown theme token $nope')));
    });
  });

  group('xml', () {
    test('entities, CDATA, comments, declarations', () {
      final r = parseXml('<?xml version="1.0"?><!-- c --><a x="1 &amp; 2" y=\'&#65;&#x42;\'><b/>t&lt;<![CDATA[<raw>]]></a>');
      expect(r.name, 'a');
      expect(r.attrs, {'x': '1 & 2', 'y': 'AB'});
      expect(r.children.single.name, 'b');
      expect(r.text, 't<<raw>');
    });
    test('errors carry line numbers', () {
      expect(() => parseXml('<a>\n<b></a>'), throwsA(predicate((e) => '$e'.startsWith('XML line 2: expected </b>'))));
      expect(() => parseXml('<a x="1" x="2"/>'), throwsA(predicate((e) => '$e'.contains('duplicate attribute x'))));
      expect(() => parseXml('<a/><b/>'), throwsA(predicate((e) => '$e'.contains('exactly one root'))));
    });
  });

  group('document', () {
    test('mini document model', () {
      final d = mini();
      expect(d.layouts.map((l) => l.id), ['landscape', 'portrait']);
      expect(d.duration, 5);
      expect(d.scenes.map((s) => s.start), [0, 2]);
      expect(d.chapters.single.label, '@hi');
      expect(d.says.single.key, 'hi');
      expect(d.says.single.start, 2.5);
      expect(d.audio.single.start, 3);
      expect(defaultOptions(d), {'lang': 'en', 'theme': 'dark'});
      expect(optionCombos(d).length, 4);
      expect(labelOf(d, '@hi', {'lang': 'gu'}), 'Kem cho');
    });
    test('variants pick by layout, then options in declared order', () {
      final d = mini();
      final rect = d.scenes.first.nodes.single;
      expect(prop(rect, 'x', envFor(d), d), 10);
      expect(prop(rect, 'x', envFor(d, layout: 'portrait'), d), 20);
      expect(prop(rect, 'x', envFor(d, opts: {'lang': 'gu'}), d), 30);
      expect(prop(rect, 'x', envFor(d, opts: {'lang': 'gu'}, layout: 'portrait'), d), 20);
      expect(prop(rect, 'w', envFor(d), d), 960);
    });
    test('value forms', () {
      final d = mini();
      final e = envFor(d);
      expect(value('12.5', e, d), 12.5);
      expect(value('-3', e, d), -3);
      expect(value('=1+1', e, d), 2);
      expect(value('@hi', e, d), 'Hello 1920');
      expect(value(r'$fg', e, d), '#fff');
      expect(value('{W}x{H}', e, d), '1920x1080');
      expect(value('#0007', e, d), '#0007');
    });
    test('anim and keys, with T0 inheritance', () {
      final d = parseTsvg('''<tsvg><timeline><scene dur="10">
        <group at="2"><rect x="0"><anim prop="x" from="0" to="100" dur="1" ease="linear"/></rect></group>
        <rect x="5"><anim prop="x" to="50" at="1" dur="2" ease="linear"/><anim prop="x" to="0" at="5" dur="1" ease="linear"/></rect>
        <rect><keys prop="y" v="0: 0; 1: 10; 3: 30" ease="linear"/></rect>
      </scene></timeline></tsvg>''');
      double at(TsvgNode n, String p, double T, {double t0 = 0}) {
        final e = envFor(d, t: T);
        final vars = Map<String, Object?>.of(e.vars)
          ..['T'] = T
          ..['T0'] = t0;
        return toNum(prop(n, p, e.withVars(vars), d));
      }

      final inner = d.scenes.first.nodes[0].children.single;
      expect(at(inner, 'x', 2.5, t0: 2), 50); // T0 = group at → local 0.5
      final r2 = d.scenes.first.nodes[1];
      expect(at(r2, 'x', 0.5), 5); // before first anim: from = base
      expect(at(r2, 'x', 2), 27.5);
      expect(at(r2, 'x', 4), 50);
      expect(at(r2, 'x', 5.5), 25);
      final r3 = d.scenes.first.nodes[2];
      expect(at(r3, 'y', 2), 20);
      expect(at(r3, 'y', 9), 30);
    });
    test('visibility: at / dur / when / only', () {
      final d = parseTsvg('''<tsvg><options><option id="lang"><choice id="en"/><choice id="gu"/></option></options>
        <timeline><scene dur="9">
        <rect at="1" dur="2"/><rect when="lang == 'gu'"/><rect only="portrait"/>
      </scene></timeline></tsvg>''');
      final ns = d.scenes.first.nodes;
      Env e(double T, {String lang = 'en', String layout = 'landscape'}) {
        final x = envFor(d, opts: {'lang': lang}, layout: layout, t: T);
        return x.withVars(Map.of(x.vars)..['T'] = T);
      }

      expect(visible(ns[0], e(0.5)), isFalse);
      expect(visible(ns[0], e(2)), isTrue);
      expect(visible(ns[0], e(3.5)), isFalse);
      expect(visible(ns[1], e(0)), isFalse);
      expect(visible(ns[1], e(0, lang: 'gu')), isTrue);
      expect(visible(ns[2], e(0)), isFalse); // only="portrait" in landscape
    });
    test('path data', () {
      final c = parsePathData('M10 20 l5 5 H0 v-1 C1 2 3 4 5 6 S 7 8 9 10 Q1 1 2 2 T 4 4 A5 5 0 1 0 20 20 z M1-2.5.5');
      expect(c.whereType<MoveTo>().length, 2);
      expect((c[1] as LineTo).x, 15);
      expect(c.whereType<ArcTo>().single.largeArc, isTrue);
      final last = c.last as MoveTo; // "M1-2.5.5": moveTo(1, -2.5), then ".5" lacks a y → parsing stops
      expect([last.x, last.y], [1, -2.5]);
    });
  });

  group('demo', () {
    late TsvgDoc demo;
    setUpAll(() => demo = parseTsvg(File(demoPath).readAsStringSync()));
    test('structure', () {
      expect(demo.duration, 49);
      expect(demo.layouts.length, 2);
      expect(demo.chapters.map((c) => labelOf(demo, c.label, {'lang': 'en'})),
          ['Intro', 'Zoom', 'One file, many videos', 'Gradients, masks, shadows', 'Time is a function', 'Outro']);
      expect(demo.fonts.map((f) => f.family), ['Inter', 'Noto Sans Gujarati']);
      expect(demo.fonts.first.weight, '1 1000');
    });
    test('sayLines and audioPlan', () {
      final lines = sayLines(demo, {...defaultOptions(demo), 'lang': 'gu'});
      expect(lines.length, 6);
      expect(lines.first.clip, 'voice/gu/vo1.62f1d9dfa4.ogg');
      expect(lines.first.dur, 5.61);
      final plan = audioPlan(demo, {...defaultOptions(demo), 'mix': 'speech'});
      expect(plan.mix, {'voice': 1, 'music': 0, 'sfx': 0});
      expect(plan.clips.where((c) => c.bus == 'voice').length, 6);
      expect(plan.clips.where((c) => c.bus == 'sfx').length, 6);
      expect(plan.clips.where((c) => c.loop).single.src, 'pad');
      expect(assetPath(demo, 'pad'), 'assets/pad.ogg');
    });
    test('validate', () async {
      final src = await openTsvgFile(demoPath);
      final r = validate(src.xml, has: src.has);
      expect(r.errors, isEmpty);
      expect(r.ok, isTrue);
      expect(r.stats!['variants'], 24);
      final bad = validate('<tsvg><timeline><scene dur="1"><rect fill="url(#nope)"/></scene></timeline></tsvg>');
      expect(bad.ok, isFalse);
      expect(bad.errors.first, contains('unknown gradient #nope'));
    });
    test('zip round trip', () async {
      final src = await openTsvgFile(demoPath);
      final files = <String, List<int>>{tsvgMain: utf8.encode(src.xml)};
      for (final p in ['fonts/Inter.ttf', 'images/fractal.jpg', 'assets/pad.ogg']) {
        files[p] = (await src.read(p))!;
      }
      final z = writeZip(files);
      expect(isZip(z), isTrue);
      final back = packageSource(z);
      expect(back.xml, src.xml);
      for (final p in files.keys.where((k) => k != tsvgMain)) {
        expect(back.files[p], files[p]);
      }
    });
  });

  group('reference (node + web/tsvg-core.js)', () {
    final hasNode = Process.runSync('which', ['node']).exitCode == 0;
    test('expressions, sayLines and audioPlan match the JS engine', () async {
      const exprs = [
        '1 + 2 * 3', '2 ^ 3 ^ 2', '-7 % 3', "'a' + 1 + 2", '1 + 2 + \'a\'', "1 == '1'", "'b' < 'a'", 'round(-2.5)',
        'fmt(1.005, 2)', "mix('#ff0000', '#0000ff80', 0.3)", "mix('red', 'blue', 0.3)", "ease(0.3, 'back')",
        "ease(0.3, 'elastic')", 'smooth(0.2, 0.8, 0.5)', 'clamp(-1, 0, 1)', 'str(1/3)', 'str(1e21)', 'str(0.1+0.2)',
        'W/7', 'rgba(1,2,3)', '!1 + 1', 'max()', 'sqrt(-1)', 'theme + layout', 'twice(21)',
      ];
      final doc = parseTsvg(File(demoPath).readAsStringSync().replaceFirst('<defs>', '<defs><fn id="twice" args="x">x*2</fn>'));
      final dart = <String, Object?>{};
      final env = makeEnv(doc, defaultOptions(doc), doc.layouts.first, 0);
      for (final x in exprs) {
        final v = compileExpr(x)(env);
        dart[x] = v is double ? (v.isNaN ? 'NaN' : (v.isInfinite ? (v > 0 ? 'Infinity' : '-Infinity') : v)) : v;
      }
      for (final opts in optionCombos(doc)) {
        final o = {...defaultOptions(doc), ...opts};
        dart['lines ${jsonEncode(o)}'] = [
          for (final l in sayLines(doc, o)) [l.key, l.start, l.dur, l.text, l.speak, l.clip]
        ];
        final p = audioPlan(doc, o);
        dart['plan ${jsonEncode(o)}'] = [
          p.mix,
          [for (final c in p.clips) [c.bus, c.src, c.start, c.loop, c.vol]]
        ];
      }
      const js = r'''
const fs = require('fs'); const T = require(process.argv[2]);
let xml = fs.readFileSync(process.argv[3], 'utf8').replace('<defs>', '<defs><fn id="twice" args="x">x*2</fn>');
const doc = T.parse(xml); const exprs = JSON.parse(process.argv[4]); const out = {};
const env = T.makeEnv(doc, T.defaults(doc), doc.layouts[0], 0, null);
const norm = (v) => typeof v === 'number' && !isFinite(v) ? String(v) : v;
for (const x of exprs) out[x] = norm(T.compile(x)(env));
for (const opts of T.combos(doc)) {
  const o = Object.assign(T.defaults(doc), opts);
  out['lines ' + JSON.stringify(o)] = T.sayLines(doc, o).map((l) => [l.key, l.start, l.dur, l.text, l.speak, l.clip]);
  const p = T.audioPlan(doc, o);
  out['plan ' + JSON.stringify(o)] = [p.mix, p.clips.map((c) => [c.bus, c.src, c.start, !!c.loop, c.vol])];
}
console.log(JSON.stringify(out));''';
      final dir = Directory.systemTemp.createTempSync('tsvg_ref');
      final script = File('${dir.path}/ref.cjs')..writeAsStringSync(js);
      final r = Process.runSync('node', [script.path, '$repo/web/tsvg-core.js', demoPath, jsonEncode(exprs)]);
      dir.deleteSync(recursive: true);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final ref = jsonDecode(r.stdout as String) as Map<String, dynamic>;
      // normalise both sides through JSON (ints vs doubles)
      final mine = jsonDecode(jsonEncode(dart)) as Map<String, dynamic>;
      for (final k in ref.keys) {
        expect(_numEq(mine[k], ref[k]), isTrue, reason: '$k: dart=${jsonEncode(mine[k])} js=${jsonEncode(ref[k])}');
      }
      expect(mine.keys.toSet(), ref.keys.toSet());
    }, skip: hasNode ? false : 'node not installed');
  });
}

bool _numEq(Object? a, Object? b) {
  if (a is num && b is num) return a == b || (a - b).abs() < 1e-12;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_numEq(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    return a.keys.every((k) => _numEq(a[k], b[k]));
  }
  return a == b;
}
