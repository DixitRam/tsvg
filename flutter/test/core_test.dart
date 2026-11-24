// Unit tests for the pure-Dart core: expressions, XML, parser, value
// resolution, audio plan, zip, validate. The "reference" group evaluates the
// same inputs with web/tsvg-core.js under node and expects identical results
// (skipped when node is not installed).
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:tsvg/tsvg_core.dart';
import 'package:tsvg/tsvg_io.dart';
import 'package:tsvg/src/core/sin.dart' show fdlibmSin;

double fdlibmSinForTest(double x) => fdlibmSin(x);

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
    <scene id="b" dur="3"><say text="@hi" at="0.5"/><sfx src="a/b.m4a" at="1"/></scene>
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

  group('0.2', () {
    final f = parseTsvg('''
<tsvg version="0.2">
  <defs><data id="n" v="1, 2.5, -3, x, 'quoted'"/><data id="t">a
b,c</data></defs>
  <timeline><scene dur="1">
    <group repeat="3" as="col"><circle repeat="=col + 1" as="row" r="=row + col*10" fill="#fff"/></group>
    <rect repeat="20001" fill="#fff"/>
    <rect repeat="-2" fill="#fff"/>
    <path d="M 0 0 L 10 0 Z"><keys prop="d" ease="linear" v="0: M 0 0 L 10 0 Z; 1: M 2 4 L 20 -6.5 Z"/></path>
  </scene></timeline>
</tsvg>''');
    test('data and count', () {
      final env = envFor(f);
      expect(f.data['n'], [1.0, 2.5, -3.0, 'x', 'quoted']);
      expect(f.data['t'], ['a', 'b', 'c']);
      expect(ev("count('n')", env), 5);
      expect(ev("data('n', 1)", env), 2.5);
      expect(ev("data('n', 6.9)", env), 2.5);
      expect(ev("data('n', -1)", env), 'quoted');
      expect(() => ev("data('nope', 0)", env), throwsA(isA<TsvgError>()));
    });
    test('rand and noise', () {
      expect(ev('rand(1)'), 0.740084824198675);
      expect(ev('rand(0)'), ev("rand('x')"));
      expect(ev('noise(3)'), ev('rand(3)'));
      final a = ev('noise(3.5)') as double;
      final b = ((ev('rand(3)') as double) + (ev('rand(4)') as double)) / 2;
      expect(a, closeTo(b, 1e-15));
      // fdlibm sin agrees with the platform sin to an ulp or two
      for (var x = -50.0; x < 50; x += 0.731) {
        expect(fdlibmSinForTest(x), closeTo(math.sin(x), 4e-16));
      }
    });
    test('repeat draws n copies with nested vars, clamps to 0…10000', () {
      final rc = RecordingCanvas();
      renderFrame(rc, f, 0.5, defaultOptions(f), f.layouts.first);
      // bg + 1+2+3 circles + 10000 rects (clamped) + none for repeat=-2 (the path has no paint)
      expect(rc.draws, 1 + 6 + 10000);
    });
    test('0.2.2: s(), \\ escape', () {
      final d = mini();
      final env = envFor(d, opts: {'lang': 'gu'});
      expect(ev("s('hi') + '!'", env), 'Kem cho!');
      expect(ev("s('hi')", envFor(d)), 'Hello 1920');
      expect(value(r'\=> literal', env, d), '=> literal');
      expect(value(r'\@x', env, d), '@x');
      expect(() => ev("s('nope')", env), throwsA(isA<TsvgError>()));
    });
    test('string morph', () {
      expect(lerpAny('M 0 0 L 10 0 Z', 'M 2 4 L 20 -6.5 Z', 0.5), 'M 1 2 L 15 -3.25 Z');
      expect(lerpAny('a1b', 'a2', 0.5), 'a1b');
      expect(lerpAny('12px', '20px', 0.25), '14px');
      final path = f.scenes.first.nodes.last;
      final env = envFor(f, t: 0.5).withVars({...envFor(f).vars, 'T': 0.5});
      expect(prop(path, 'd', env, f), 'M 1 2 L 15 -3.25 Z');
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
      expect(lines.first.clip, 'voice/gu/vo1.62f1d9dfa4.m4a');
      expect(lines.first.dur, 5.61);
      final plan = audioPlan(demo, {...defaultOptions(demo), 'mix': 'speech'});
      expect(plan.mix, {'voice': 1, 'music': 0, 'sfx': 0});
      expect(plan.clips.where((c) => c.bus == 'voice').length, 6);
      expect(plan.clips.where((c) => c.bus == 'sfx').length, 6);
      expect(plan.clips.where((c) => c.loop).single.src, 'pad');
      expect(assetPath(demo, 'pad'), 'assets/pad.m4a');
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
      for (final p in ['fonts/Inter.ttf', 'images/fractal.jpg', 'assets/pad.m4a']) {
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

    test('0.2 functions and morph match the JS engine (features.tsvg)', () {
      final exprs = [
        "data('sales', 3)", "data('sales', -1)", "data('months', 9)", "count('months')", "data('sales', 2.9) * 8",
        'rand(1)', 'rand(0)', "rand('x')", 'rand(-7.25)', 'rand(123456.789)', 'rand(1e9)', 'noise(2.5)', 'noise(-3.7)',
        'noise(1000.123)', "mix('M 0 -220 L 60 -60 Z', 'M 0 -200 L 141 -141 Z', 0.37)", "mix('a1b', 'a2c', 0.5)",
        "mix('x 1e2 y', 'x 3e2 y', 0.5)", "mix('.5 1.', '1.5 2.', 0.25)",
        for (var i = 0; i < 200; i++) 'rand(${i * 0.37 - 30})',
        for (var i = 0; i < 50; i++) 'noise(${i * 1.37 - 20})',
      ];
      final path = '$repo/examples/features/features.tsvg';
      final doc = parseTsvg(File(path).readAsStringSync());
      final env = makeEnv(doc, defaultOptions(doc), doc.layouts.first, 0);
      final mine = [for (final x in exprs) compileExpr(x)(env)];
      const js = r'''
const fs = require('fs'); const T = require(process.argv[2]);
const doc = T.parse(fs.readFileSync(process.argv[3], 'utf8')); const exprs = JSON.parse(fs.readFileSync(process.argv[4], 'utf8'));
const env = T.makeEnv(doc, T.defaults(doc), doc.layouts[0], 0, null);
console.log(JSON.stringify(exprs.map((x) => T.compile(x)(env))));''';
      final dir = Directory.systemTemp.createTempSync('tsvg_ref');
      final script = File('${dir.path}/ref.cjs')..writeAsStringSync(js);
      final ex = File('${dir.path}/exprs.json')..writeAsStringSync(jsonEncode(exprs));
      final r = Process.runSync('node', [script.path, '$repo/web/tsvg-core.js', path, ex.path]);
      dir.deleteSync(recursive: true);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final ref = jsonDecode(r.stdout as String) as List;
      var exact = 0;
      for (var i = 0; i < exprs.length; i++) {
        final a = mine[i], b = ref[i];
        if (a is num && b is num) {
          if (a == b) exact++;
          // engines' Math.sin can differ in the last bit, which shows up ~1e-11 in rand()
          expect((a - b).abs(), lessThan(1e-9), reason: '${exprs[i]}: dart=$a js=$b');
        } else {
          expect(a, b, reason: exprs[i]);
          exact++;
        }
      }
      // ignore: avoid_print
      print('0.2 reference: $exact / ${exprs.length} bit-identical');
    }, skip: hasNode ? false : 'node not installed');
  });

  group('0.5 timing and layout', () {
    // same document and numbers as the "auto timing" block of tests/unit.mjs
    const x = '''<tsvg><options><option id="lang" default="en"><choice id="en"/><choice id="gu"/></option></options>
    <timeline><scene id="a" dur="auto" pad="1" min="2"><say id="v1" text="one"/><say id="v2" text="two"/><rect at="=cue('v2')" w="=cueEnd(0)"/></scene>
    <scene id="b" dur="3" dur.gu="5" chapter="B"><sfx at="1" at.gu="2" src="a/b.m4a"/></scene></timeline>
    <voices><voice say="v1" lang="en" src="v/1.m4a" dur="2"/><voice say="v2" lang="en" src="v/2.m4a" dur="1"/><voice say="v1" lang="gu" src="v/3.m4a" dur="4"/><voice say="v2" lang="gu" src="v/4.m4a" dur="3"/></voices></tsvg>''';
    double r2(double v) => double.parse(v.toStringAsFixed(2));
    test('auto timing', () {
      final d = parseTsvg(x);
      final en = forOptions(d, {'lang': 'en'}), gu = forOptions(d, {'lang': 'gu'});
      expect(en.scenes.map((s) => [r2(s.start), r2(s.dur)]), [[0, 4.7], [4.7, 3]], reason: 'en timing: 0.4 + 2 + 0.3 + 1 + pad 1');
      expect(gu.scenes.map((s) => [r2(s.start), r2(s.dur)]), [[0, 8.7], [8.7, 5]], reason: 'gu timing');
      expect([r2(en.duration), r2(gu.duration)], [7.7, 13.7], reason: 'durations per language');
      expect(gu.chapters.first.t, 8.7, reason: 'chapter follows');
      expect(sayLines(d, {'lang': 'gu'}).map((l) => r2(l.start)), [0.4, 4.7], reason: 'say starts chained');
      expect(audioPlan(d, {'lang': 'gu'}).clips.firstWhere((c) => c.bus == 'sfx').start, 10.7, reason: 'sfx at.gu');
      expect(identical(forOptions(d, {'lang': 'gu'}), gu), isTrue, reason: 'views cached');
      expect(parseTsvg('<tsvg><timeline><scene dur="2"/></timeline></tsvg>').timed, isFalse, reason: 'plain docs untouched');
      final v = validate(x);
      expect(v.ok, isTrue, reason: 'validate auto: ${v.errors.isEmpty ? '' : v.errors.first}');
    });
    test('cue() / cueEnd()', () {
      final d = parseTsvg(x);
      final en = forOptions(d, {'lang': 'en'});
      final sc = en.scenes.first;
      final env = makeEnv(en, {'lang': 'en'}, en.layouts.first, 0);
      final inScene = env.withScene(sc, env.vars);
      final rect = sc.nodes.single;
      expect(toNum(attr(rect, 'at', inScene, en)), closeTo(2.7, 1e-9));
      expect(toNum(attr(rect, 'w', inScene, en)), closeTo(2.4, 1e-9));
      expect(compileExpr("cueEnd('v2')")(inScene), closeTo(3.7, 1e-9));
      expect(() => compileExpr("cue('nope')")(inScene), throwsA(predicate((e) => '$e' == 'no <say> "nope" in scene a (cue takes a say id or 0, 1, …)')));
      expect(() => compileExpr('cue(0)')(env), throwsA(predicate((e) => '$e' == 'cue() works inside a scene')));
    });
    test('row: gap, pad, justify, align', () {
      LayoutResult lay(String justify) {
        final d = parseTsvg('<tsvg><timeline><scene dur="1"><row w="500" h="100" gap="10" pad="20" align="center" justify="$justify">'
            '<rect w="100" h="40"/><rect w="50" h="60" ax="0.5" ay="0.5"/><circle r="20"/><rect w="9" when="0"/></row></scene></timeline></tsvg>');
        final env = makeEnv(d, const {}, d.layouts.first, 0);
        return arrange(RecordingCanvas(), d.scenes.single.nodes.single, env);
      }

      final c = lay('center');
      expect([c.w, c.h], [500, 100]);
      expect(c.items.map((it) => [it.x, it.y, it.ox, it.oy]), [
        [145, 30, 0, 0],
        [255, 20, 25, 30],
        [315, 30, 20, 20],
      ]);
      expect(lay('between').items.map((it) => it.x), [20, 255, 440]);
      expect(lay('end').items.map((it) => it.x), [270, 380, 440]);
    });
  });

  group('0.6 rich text and transitions', () {
    List<List<Object?>> runs(String s, [bool on = true]) =>
        [for (final r in parseRich(s, on)) [r.t, if (r.b) 'b', if (r.i) 'i', if (r.code) 'code', if (r.hl) 'hl', if (r.c != null) r.c]];
    test('parseRich', () {
      expect(runs('a **b** c'), [['a '], ['b', 'b'], [' c']], reason: 'bold');
      expect(runs('*it* x'), [['it', 'i'], [' x']], reason: 'italic');
      expect(runs('**bold *both***'), [['bold ', 'b'], ['both', 'b', 'i']], reason: 'nested');
      expect(runs('call `f(*x*)` now'), [['call '], ['f(*x*)', 'code'], [' now']], reason: 'code is literal');
      expect(runs('==hi== there'), [['hi', 'hl'], [' there']], reason: 'highlight');
      expect(runs(r'[red]($accent) and [blue](#00f)'), [['red', r'$accent'], [' and '], ['blue', '#00f']], reason: 'colour spans');
      expect(runs(r'\*not\* \`x\` [y]'), [[r'*not* `x` [y]']], reason: 'escapes; [ without (…) is text');
      expect(runs('**a**', false), [['**a**']], reason: 'rich off: one plain run');
    });
    test('transitionOf', () {
      final d = parseTsvg('<tsvg><timeline in="fade"><scene dur="2"/><scene dur="2" in="push 0.7 up linear"/>'
          '<scene dur="2" in="none"/><scene dur="2" in="iris"/></timeline></tsvg>');
      expect(d.scenes.map((s) => s.trans), ['fade', 'push 0.7 up linear', 'none', 'iris'], reason: 'timeline default');
      final env = makeEnv(d, const {}, d.layouts.first, 0);
      final p = transitionOf(d.scenes[1], env)!;
      expect([p.kind, p.dur, p.dir, p.ease], ['push', 0.7, 'up', 'linear']);
      final i = transitionOf(d.scenes[3], env)!;
      expect([i.kind, i.dur, i.dir, i.ease], ['iris', 0.6, 'left', 'io'], reason: 'defaults');
      expect(transitionOf(d.scenes[2], env), isNull, reason: 'none');
      final plain = parseTsvg('<tsvg><timeline><scene dur="2"/><scene dur="2"/></timeline></tsvg>');
      expect(transitionOf(plain.scenes[1], env), isNull, reason: 'no transition');
    });
    test('rich layout wraps across pieces', () {
      final d = parseTsvg('<tsvg><timeline><scene dur="2"><text text="ab cd" ls="5" maxw="30"/></scene></timeline></tsvg>');
      final env = makeEnv(d, const {}, d.layouts.first, 0);
      final n = d.scenes.first.nodes.first;
      expect(isRich(n), isTrue);
      final b = boxOf(RecordingCanvas(), n, env);
      expect([b.w, b.h], [20, 48 * 1.25 + 48], reason: 'two lines of "ab" / "cd" (recording canvas: 10 per char)');
    });
  });

  group('0.7 charts additions', () {
    test('nth()', () {
      final d = parseTsvg('<tsvg><themes><theme id="dark" accent="#f80" fg="#fff"/></themes><timeline><scene dur="1"/></timeline></tsvg>');
      final env = envFor(d);
      expect(ev("nth('a | b | c', 1)", env), 'b');
      expect(ev("nth('a | b | c', 4.7)", env), 'b', reason: 'floor then wrap');
      expect(ev("nth('a | b | c', -1)", env), 'c', reason: 'negative wraps');
      expect(ev(r"nth('$accent, #f00', 0)", env), '#f80', reason: r'$token resolves');
      expect(ev(r"nth('$accent, #f00', 1)", env), '#f00');
      expect(ev("nth('10, 20.5, x', 1)", env), 20.5, reason: 'numeric items are numbers');
      expect(ev("nth('a, b | c', 0)", env), 'a, b', reason: '| wins over ,');
    });
    test('commas()', () {
      expect(ev('commas(12840)'), '12,840');
      expect(ev('commas(1234567.891, 1)'), '1,234,567.9');
      expect(ev('commas(999)'), '999');
      expect(ev('commas(-1234.5, 2)'), '-1,234.50');
    });
    test('group/use anchor places by ax/ay of w×h, pivot at the anchor', () {
      final d = parseTsvg('''<tsvg><defs><symbol id="s"><rect w="10" h="10"/></symbol></defs><timeline><scene dur="1">
        <group x="100" y="50" w="40" h="20" ax="0.5" ay="1" rot="90"><rect w="1" h="1"/></group>
        <use ref="s" x="100" y="50" w="40" h="20" ax="0.25"/>
        <group x="100" y="50" w="40" h="20"><rect w="1" h="1"/></group>
      </scene></timeline></tsvg>''');
      final rc = _TranslateLog();
      renderFrame(rc, d, 0.5, defaultOptions(d), d.layouts.first);
      // group: translate(x − w·ax, y − h·ay) then pivot translate(±anchor) around rotate
      expect(rc.log.sublist(0, 4), [[80.0, 30.0], [20.0, 20.0], 'rot', [-20.0, -20.0]]);
      expect(rc.log[4], [90.0, 50.0], reason: 'use: only ax given');
      expect(rc.log[5], [100.0, 50.0], reason: 'no anchor: unchanged');
      final env = makeEnv(d, const {}, d.layouts.first, 0);
      final b = boxOf(RecordingCanvas(), d.scenes.first.nodes.first, env);
      expect([b.w, b.h, b.ox, b.oy], [40, 20, 20, 20]);
      final plain = boxOf(RecordingCanvas(), d.scenes.first.nodes[2], env);
      expect([plain.ox, plain.oy], [0, 0]);
    });
  });

  group('0.8 video', () {
    test('clipTime: start, rate, at, loop wrap, clamp', () {
      double ct(double t, {double start = 0, double rate = 1, double t0 = 0, double len = 0, bool loop = false}) =>
          clipTime(start: start, rate: rate, t: t, t0: t0, len: len, loop: loop);
      expect(ct(3), 3);
      expect(ct(3, start: 2), 5);
      expect(ct(3, rate: 0.5), 1.5);
      expect(ct(3, start: 2, rate: 0.5), 3.5);
      expect(ct(3, t0: 1), 2, reason: 'counts from the node\'s at');
      expect(ct(0.5, t0: 1, start: 2), 2, reason: 'before at: start');
      expect(ct(9, len: 8, loop: true), closeTo(1, 1e-12), reason: 'loop wraps');
      expect(ct(17, start: 1, len: 8, loop: true), closeTo(2, 1e-12));
      expect(ct(9, len: 8), closeTo(7.96, 1e-12), reason: 'no loop: clamps to len − 0.04');
      expect(ct(3, len: 8), 3);
      expect(ct(20), 20, reason: 'unknown length: no clamp');
      expect(ct(20, loop: true), 20, reason: 'loop needs a length');
    });
    test('parse: video assets, posters, lengths, auto assets', () {
      final d = parseTsvg('''<tsvg><assets><asset id="a" src="c/a.mp4" poster="c/a.jpg" dur="8.5"/><asset id="m" src="b.MOV"/>
        <asset id="i" src="x.png"/></assets><timeline><scene dur="4"><video src="c/b.webm" poster="c/b.jpg"/><video src="a"/></scene></timeline></tsvg>''');
      expect([d.assets['a']!.type, d.assets['a']!.poster, d.assets['a']!.dur], ['video', 'c/a.jpg', 8.5]);
      expect(d.assets['m']!.type, 'video');
      expect(d.assets['i']!.type, 'image');
      expect([d.assets['c/b.webm']!.type, d.assets['c/b.webm']!.poster], ['video', 'c/b.jpg'], reason: 'auto-registered');
      expect(d.assets.containsKey('a'), isTrue);
      expect(d.scenes.first.nodes.map((n) => n.type), ['video', 'video']);
      expect(guessType('x.m4v'), 'video');
      expect(guessType('x.m4a'), 'audio');
    });
    test('render: clip time per node, layout box, poster or grey box', () {
      final d = parseTsvg('''<tsvg><assets><asset id="a" src="a.mp4" poster="a.jpg" dur="8"/></assets><timeline>
        <scene dur="20"><video src="a" at="2" start="1" rate="2" x="10" y="20" w="320" h="180" r="12" fit="contain" vol="0.5"/>
        <video src="a" loop="1"/>
        <video src="a"/><video src="b.mp4" cliplen="4" loop="1" w="200" h="100"/></scene></timeline></tsvg>''');
      final rc = _VideoLog({'a.jpg'});
      renderFrame(rc, d, 5, defaultOptions(d), d.layouts.first);
      expect([for (final r in rc.reqs) r.ct], [7, closeTo(5, 1e-12), 5, closeTo(1, 1e-12)]);
      final r0 = rc.reqs.first;
      expect([r0.x, r0.y, r0.w, r0.h, r0.r, r0.fit, r0.rate, r0.vol, r0.path], [10, 20, 320, 180, 12, 'contain', 2, 0.5, 'a.mp4']);
      expect(rc.reqs[1].key != rc.reqs[2].key, isTrue, reason: 'one clip per node (line|start|rate, as on the web)');
      expect([rc.reqs[2].w, rc.reqs[2].h], [1280, 720], reason: 'default 1280×720');
      expect(rc.images.where((i) => i == 'a.jpg').length, 3, reason: 'poster drawn while no frame');
      expect(rc.greys, 1, reason: 'no poster: grey box');
      renderFrame(rc..reqs.clear(), d, 12, defaultOptions(d), d.layouts.first);
      expect(rc.reqs[0].ct, closeTo(7.96, 1e-12), reason: 'clamped to the asset dur − 0.04');
      final env = makeEnv(d, const {}, d.layouts.first, 0);
      final b = boxOf(RecordingCanvas(), d.scenes.first.nodes[2], env);
      expect([b.w, b.h], [1280, 720]);
    });
  });
  group('0.9 effects and beats', () {
    const beatsDocXml = '''<tsvg><mixes><mix id="full" voice="1" music="0.5" duck="0.3"/><mix id="flat" music="1"/></mixes>
      <options><option id="mix" default="full"><choice id="full"/><choice id="flat"/></option></options>
      <music src="a.m4a" beats="b"/><music src="c.m4a" beats="e"/>
      <defs><data id="b" v="0.5, 1, 2"/></defs>
      <timeline><scene dur="6"><say text="Hi there" at="1" dur="2"/></scene></timeline></tsvg>''';
    final beatsDoc = parseTsvg(beatsDocXml);
    Object? bev(String src) => compileExpr(src)(envFor(beatsDoc));
    test('since / idx / pulse on a time list', () {
      expect([bev("idx(0.4, 'b')"), bev("idx(1, 'b')"), bev("idx(1.5, 'b')"), bev("idx(5, 'b')")], [0, 2, 2, 3]);
      expect(bev("since(0.4, 'b')"), 1e9, reason: 'before the first time');
      expect(bev("since(1.25, 'b')"), closeTo(0.25, 1e-12));
      expect(bev("since(2, 'b')"), 0);
      expect(bev("pulse(0.4, 'b', 0.5)"), 0);
      expect(bev("pulse(1, 'b', 0.5)"), 1, reason: 'on a beat');
      expect(bev("pulse(1.25, 'b', 0.5)"), closeTo(math.exp(-0.5), 1e-12));
      expect(bev("pulse(1.25, 'b')"), closeTo(math.exp(-1), 1e-12), reason: 'default decay 0.25');
      expect(bev("pulse(1.25, 'b', 0)"), closeTo(math.exp(-1), 1e-12), reason: 'decay ≤ 0 = 0.25');
      // <music beats="e"> without <data id="e">: an empty list until tsvg bake writes the grid
      expect(beatsDoc.data['e'], isEmpty);
      expect([bev("idx(3, 'e')"), bev("since(3, 'e')"), bev("pulse(3, 'e')")], [0, 1e9, 0]);
      expect(beatsDoc.audio.map((a) => a.beats), ['b', 'e']);
      expect(() => bev("idx(1, 'nope')"), throwsA(isA<TsvgError>()));
      expect(validate(beatsDocXml).warnings.any((w) => w.contains('no beat grid in <data id="e">')), isTrue);
    });
    test('duckAt: inside a line, ramps, no duck', () {
      final lines = [SayLine(key: 'l', start: 1, dur: 2, text: 'Hi', speak: 'Hi', clip: null, lang: null)];
      final o = {'mix': 'full'};
      expect(duckAt(beatsDoc, o, 2, lines), closeTo(0.3, 1e-12), reason: 'inside a line');
      expect(duckAt(beatsDoc, o, 0.9, lines), closeTo(1 - 0.7 * 0.6, 1e-12), reason: '0.1 s before: 60% into the ramp');
      expect(duckAt(beatsDoc, o, 3.1, lines), closeTo(1 - 0.7 * 0.6, 1e-12), reason: '0.1 s after');
      expect(duckAt(beatsDoc, o, 3.3, lines), 1, reason: 'after the ramp');
      expect(duckAt(beatsDoc, o, 0.5, lines), 1, reason: 'before the ramp');
      expect(duckAt(beatsDoc, {'mix': 'flat'}, 2, lines), 1, reason: 'no duck in the mix');
      expect(duckAt(beatsDoc, o, 2, [SayLine(key: 'x', start: 1, dur: 2, text: '', speak: '', clip: null, lang: null)]), 1,
          reason: 'a line with neither text nor clip does not duck');
      expect(duckAt(beatsDoc, o, 2), closeTo(0.3, 1e-12), reason: 'lines from the document');
    });
    test('filter matrices and parsing', () {
      final g = applyFilterMatrix(filterMatrix('grayscale', 1)!, 1, 0, 0, 1);
      expect(g, [closeTo(0.2126, 1e-9), closeTo(0.2126, 1e-9), closeTo(0.2126, 1e-9), 1]);
      expect(applyFilterMatrix(filterMatrix('grayscale', 0)!, 1, 0, 0, 1), [1, 0, 0, 1]);
      expect(applyFilterMatrix(filterMatrix('invert', 1)!, 1, 0.25, 0, 1), [0, 0.75, 1, 1]);
      expect(applyFilterMatrix(filterMatrix('contrast', 2)!, 0.75, 0.5, 0.25, 1), [1, 0.5, 0, 1]);
      expect(applyFilterMatrix(filterMatrix('opacity', 0.5)!, 1, 1, 1, 1), [1, 1, 1, 0.5]);
      final h = applyFilterMatrix(filterMatrix('hue-rotate', 360)!, 0.2, 0.4, 0.6, 1);
      expect(h, [closeTo(0.2, 1e-9), closeTo(0.4, 1e-9), closeTo(0.6, 1e-9), 1]);
      final ops = cssFilterOps('hue(30) blur(4px) grayscale(50%) drop-shadow(1px 2px red) sepia(.4)', 2)!;
      expect(ops.map((o) => '${o.name} ${o.v}'), ['hue-rotate 30.0', 'blur 8.0', 'grayscale 50.0', 'sepia 0.4']);
      expect(cssFilterOps('contrast(-1)', 1), isNull, reason: 'Canvas2D rejects the whole list');
      expect(cssFilterOps('hue-rotate(-20deg)', 1)!.single.v, -20);
    });
    test('filter: own blur, own functions, then inherited (group → children)', () {
      final d = parseTsvg('''<tsvg><timeline><scene dur="2">
        <group filter="grayscale(1)" blur="2"><rect w="1" h="1" fill="#f00" blur="1" filter="hue(90)"/><rect w="1" h="1" fill="#f00"/></group>
        <group filter="sepia(1)"><rect w="1" h="1" fill="#f00" filter="contrast(-1)"/></group>
        <rect w="1" h="1" fill="#f00" filter="none"/></scene></timeline></tsvg>''');
      final rc = _StateLog();
      renderFrame(rc, d, 0.5, defaultOptions(d), d.layouts.first);
      expect(rc.filters.skip(rc.filters.length - 4), [
        'blur(1.0) hue-rotate(90.0) blur(2.0) grayscale(1.0)',
        'blur(2.0) grayscale(1.0)',
        'sepia(1.0)',
        '',
      ]);
    });
    test('skew: after the rotation, before the scale, about the pivot', () {
      final d = parseTsvg('''<tsvg><timeline><scene dur="2"><rect w="100" h="100" rot="90" skx="45" sky="-45" sx="2"/>
        <rect w="10" h="10" sky="30"/></scene></timeline></tsvg>''');
      final rc = _TranslateLog();
      renderFrame(rc, d, 0.5, defaultOptions(d), d.layouts.first);
      expect(rc.log.sublist(0, 5), [[50.0, 50.0], 'rot', 'skew', 'scale', [-50.0, -50.0]]);
      expect(rc.skews[0][0], closeTo(1, 1e-12));
      expect(rc.skews[0][1], closeTo(-1, 1e-12));
      expect(rc.skews[1][0], 0);
      expect(rc.skews[1][1], closeTo(math.tan(math.pi / 6), 1e-12));
    });
    test('group auto-bounds: the union of its in-flow children', () {
      final d = parseTsvg('''<tsvg><defs><symbol id="s"><rect x="-10" y="-10" w="20" h="20"/></symbol></defs><timeline><scene dur="2">
        <group><rect x="10" y="20" w="30" h="40"/><circle r="5"/><rect x="500" w="1" h="1" when="0"/></group>
        <use ref="s"/><group/><group w="40"><rect w="100" h="100"/></group>
        <row><group><rect w="30" h="10" ax="0.5"/></group><rect w="5" h="5"/></row></scene></timeline></tsvg>''');
      final env = makeEnv(d, const {}, d.layouts.first, 0);
      List<double> box(int i) {
        final b = boxOf(RecordingCanvas(), d.scenes.first.nodes[i], env);
        return [b.w, b.h, b.ox, b.oy];
      }

      expect(box(0), [45, 65, 5, 5]);
      expect(box(1), [20, 20, 10, 10], reason: 'use: its symbol');
      expect(box(2), [0, 0, 0, 0], reason: 'empty');
      expect(box(3), [40, 0, 0, 0], reason: 'w or h given: its own box');
      final l = arrange(RecordingCanvas(), d.scenes.first.nodes[4], env);
      expect([l.w, l.h], [35, 10]);
      expect([l.items[0].x + l.items[0].ox, l.items[1].x], [15, 30], reason: 'the group is placed by its children');
    });
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

class _TranslateLog extends RecordingCanvas {
  final log = <Object>[];
  final skews = <List<double>>[];
  @override
  void translate(double dx, double dy) => log.add([dx, dy]);
  @override
  void rotate(double radians) => log.add('rot');
  @override
  void skew(double kx, double ky) {
    log.add('skew');
    skews.add([kx, ky]);
  }

  @override
  void scale(double sx, [double? sy]) => log.add('scale');
}

class _StateLog extends RecordingCanvas {
  final filters = <String>[];
  @override
  void fill(TsvgShape shape, TsvgPaint paint, DrawState st) => filters.add(st.filters.join(' '));
}

class _VideoLog extends RecordingCanvas {
  _VideoLog(this.posters);
  final Set<String> posters;
  final reqs = <VideoRequest>[];
  final images = <String>[];
  int greys = 0;
  @override
  String? videoFrame(VideoRequest req) {
    reqs.add(req);
    return null;
  }

  @override
  ImageSize? imageSize(String ref) => posters.contains(ref) ? const ImageSize(16, 9) : null;
  @override
  void image(String ref, double x, double y, double w, double h, DrawState st) => images.add(ref);
  @override
  void fill(TsvgShape shape, TsvgPaint paint, DrawState st) {
    if (paint is SolidPaint && shape is RectShape && paint.color.a < 0.5) greys++;
  }
}
