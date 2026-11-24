// Unit tests for the engine's non-visual parts (libraries / components). Run: node tests/unit.mjs
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
const require = createRequire(import.meta.url);
const T = require('../web/tsvg-core.js');
const ROOT = fileURLToPath(new URL('..', import.meta.url));
let failed = 0, n = 0;
const ok = (c, msg) => { n++; if (!c) { failed++; console.log('FAIL ' + msg); } };
const eq = (a, b, msg) => ok(JSON.stringify(a) === JSON.stringify(b), msg + ': got ' + JSON.stringify(a) + ', want ' + JSON.stringify(b));
const o = { base: pathToFileURL(ROOT + 'tests/x.tsvg').href, libBase: pathToFileURL(ROOT + 'libs/').href, fetchText: async (u) => readFileSync(fileURLToPath(u), 'utf8') };

// local components: props, defaults, variants, if/else, each with fields, slots
{
  const x = `<tsvg><defs><component id="card" props="title, sub=hello, items?, kind=a">
    <group><text text="%{title}"/><if test="%{sub}"><text text="S:%{sub}"/></if>
    <if test="%{kind} == b"><rect/><else><circle/></else></if>
    <each items="%{items}" as="it"><text y="=%{it_i}*10" text="%{it.0}/%{it.1}/%{it_1}/%{it_n}"/></each><slot/><slot name="end"/></group></component></defs>
    <timeline><scene id="a" dur="2"><card title="Hi" title.gu="Kem" items="a::b | c"><line slot="end"/><ellipse/></card></scene></timeline></tsvg>`;
  const f = T.flatten(x); eq(f.errors, [], 'no errors');
  const g = f.root.children.find((c) => c.name === 'timeline').children[0].children[0];
  eq(g.children.map((c) => c.name), ['text', 'text', 'circle', 'text', 'text', 'ellipse', 'line'], 'body order with slots');
  eq([g.children[0].attrs.text, g.children[0].attrs['text.gu']], ['Hi', 'Kem'], 'prop + variant');
  eq(g.children[3].attrs.text, 'a/b/1/2', 'each fields'); eq(g.children[4].attrs.text, 'c//2/2', 'missing field is empty');
  const d = T.parse(x); eq(d.scenes[0].nodes[0].children.length, 7, 'parse expands local components');
  eq(T.flatten(x.replace('sub=hello', 'sub=a == b')).root.children[1].children[0].children[0].children[1].attrs.text, 'S:a == b', 'if: == inside a prop value is text, not a comparison');
  const bad = T.flatten(x.replace('title="Hi"', 'titel="Hi"')).errors;
  ok(bad.some((e) => /unknown prop "titel" \(did you mean "title"\?\)/.test(e)), 'unknown prop with hint');
  ok(bad.some((e) => /missing prop "title"/.test(e)), 'missing prop');
  eq(T.flatten('<tsvg><defs><component id="c" props="a"><text text="%{a|b}"/></component></defs><timeline><scene dur="1"><c a=""/></scene></timeline></tsvg>').errors.length, 1, '%{a|b} needs b');
  const h = T.flatten('<tsvg><defs><component id="c" props="a, b=x"><say id="%{a#}" text="%{a|b}"/></component></defs><timeline><scene dur="1"><c a=""/><c a="hey"/></scene></timeline></tsvg>');
  const says = h.root.children[1].children[0].children; eq(says.map((s) => s.attrs.text), ['x', 'hey'], 'fallback %{a|b}'); ok(/^h[0-9a-z]+$/.test(says[1].attrs.id), 'hash %{a#}');
}
// libraries: namespacing, alias refs, head merge, params, pruning, lib files
{
  const x = `<tsvg title="t"><import src="tsvg:report" as="r" key="K-1"/><themes><theme id="dark" accent="#f00"/></themes>
    <timeline><r:title title="Hello" say="Hi there."/><r:list title="L" items="a | b :: c" kind="step"/></timeline></tsvg>`;
  const libs = await T.loadLibs(x, o); eq(Object.keys(libs).length, 2, 'report + base loaded');
  const f = T.flatten(x, libs, o); eq(f.errors, [], 'lib errors');
  const d = T.parse(f.xml);
  eq(d.scenes.length, 2, 'two scenes'); eq(d.themes.dark.accent, '#f00', 'doc token wins'); eq(d.themes.dark.bg, '#0d1016', 'lib token fills in');
  ok(d.themes.light && d.themes.light.bg, 'lib theme added'); eq(d.layouts.map((l) => l.id), ['landscape', 'portrait'], 'lib layouts');
  ok(d.symbols.base__tick && d.gradients.base__ink, 'namespaced defs'); ok(!d.fonts.some((f) => f.family === 'Noto Sans Gujarati'), 'gu font pruned without gu');
  ok(d.fonts.some((f) => f.family === 'Inter'), 'Inter kept'); ok(!d.assets.base__whoosh && d.assets.base__pad, 'unused sfx pruned, music kept');
  ok(f.files['lib/_shared/fonts/Inter.ttf'], 'lib file mapped'); ok(f.xml.includes('K-1'), 'param flows into the base overlay');
  ok(f.lineMap.some((l) => l === 2), 'line map points at source lines');
  const v = T.validate(x, Object.assign({ libs }, o)); ok(v.ok, 'validate with libs: ' + v.errors[0]);
  const e = T.flatten(x.replace('<r:list', '<r:lst'), libs, o).errors; ok(e.some((m) => /unknown component <r:lst>.*did you mean "list"/.test(m)), 'unknown component hint');
  ok(T.flatten(x.replace('key="K-1"', 'kye="K-1"'), libs, o).errors.some((m) => /no param "kye"/.test(m)), 'unknown param');
  const gu = x.replace('<themes>', '<options><option id="lang" default="en"><choice id="en"/><choice id="gu"/></option></options><themes>');
  ok(T.parse(T.flatten(gu, libs, o).xml).fonts.some((f) => f.family === 'Noto Sans Gujarati'), 'gu font kept with a gu choice');
}
// auto timing: scene length follows the narration per language; chained says; cue(); variants
{
  const x = `<tsvg><options><option id="lang" default="en"><choice id="en"/><choice id="gu"/></option></options>
    <timeline><scene id="a" dur="auto" pad="1" min="2"><say id="v1" text="one"/><say id="v2" text="two"/><rect at="=cue('v2')" w="=cueEnd(0)"/></scene>
    <scene id="b" dur="3" dur.gu="5" chapter="B"><sfx at="1" at.gu="2" src="a/b.m4a"/></scene></timeline>
    <voices><voice say="v1" lang="en" src="v/1.m4a" dur="2"/><voice say="v2" lang="en" src="v/2.m4a" dur="1"/><voice say="v1" lang="gu" src="v/3.m4a" dur="4"/><voice say="v2" lang="gu" src="v/4.m4a" dur="3"/></voices></tsvg>`;
  const d = T.parse(x); const en = T.forOptions(d, { lang: 'en' }), gu = T.forOptions(d, { lang: 'gu' });
  eq(en.scenes.map((s) => [+s.start.toFixed(2), +s.dur.toFixed(2)]), [[0, 4.7], [4.7, 3]], 'en timing: 0.4 + 2 + 0.3 + 1 + pad 1');
  eq(gu.scenes.map((s) => [+s.start.toFixed(2), +s.dur.toFixed(2)]), [[0, 8.7], [8.7, 5]], 'gu timing');
  eq([+en.duration.toFixed(2), +gu.duration.toFixed(2)], [7.7, 13.7], 'durations per language');
  eq(gu.chapters[0].t, 8.7, 'chapter follows'); eq(T.sayLines(d, { lang: 'gu' }).map((l) => +l.start.toFixed(2)), [0.4, 4.7], 'say starts chained');
  eq(T.audioPlan(d, { lang: 'gu' }).clips.find((c) => c.bus === 'sfx').start, 10.7, 'sfx at.gu');
  ok(T.forOptions(d, { lang: 'gu' }) === gu, 'views cached'); ok(T.parse('<tsvg><timeline><scene dur="2"/></timeline></tsvg>').timed === false, 'plain docs untouched');
  let rect = null; const ctx = { save() {}, restore() {}, translate() {}, fill() {}, stroke() {}, fillRect() {}, rotate() {}, scale() {}, getTransform: () => ({ a: 1, b: 0, c: 0, d: 1 }), setLineDash() {}, clip() {}, globalAlpha: 1 };
  ok(T.validate(x).ok, 'validate auto: ' + T.validate(x).errors[0]);
}
// rich text markup, transitions lint
{
  const d = T.parse('<tsvg><timeline in="fade"><scene dur="2"><text rich="1" text="a"/></scene><scene dur="2" in="zom 0.5"><text split="wrd" text="b"/></scene></timeline></tsvg>');
  eq(d.scenes.map((s) => s.trans), ['fade', 'zom 0.5'], 'scene transitions (timeline default)');
  const v = T.validate('<tsvg><timeline><scene dur="2"/><scene dur="2" in="zom 0.5"><text split="wrd" text="b"/></scene></timeline></tsvg>');
  ok(v.warnings.some((w) => /unknown transition "zom".*did you mean "zoom"/.test(w)), 'transition lint'); ok(v.warnings.some((w) => /split="wrd"/.test(w)), 'split lint');
}
// every built-in library example checks clean
for (const f of ['examples/libs/report.tsvg', 'examples/libs/explainer.tsvg', 'templates/report.tsvg']) {
  const x = readFileSync(ROOT + f, 'utf8'); const oo = Object.assign({}, o, { base: pathToFileURL(ROOT + f).href });
  const libs = await T.loadLibs(x, oo); const v = T.validate(x, Object.assign({ libs }, oo)); ok(v.ok, f + ': ' + v.errors[0]);
}
console.log(`${failed ? 'FAIL' : 'ok  '} unit · ${n - failed}/${n}`); process.exit(failed ? 1 : 0);
