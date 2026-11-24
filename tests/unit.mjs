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
// every built-in library example checks clean
for (const f of ['examples/libs/report.tsvg', 'examples/libs/explainer.tsvg', 'templates/report.tsvg']) {
  const x = readFileSync(ROOT + f, 'utf8'); const oo = Object.assign({}, o, { base: pathToFileURL(ROOT + f).href });
  const libs = await T.loadLibs(x, oo); const v = T.validate(x, Object.assign({ libs }, oo)); ok(v.ok, f + ': ' + v.errors[0]);
}
console.log(`${failed ? 'FAIL' : 'ok  '} unit · ${n - failed}/${n}`); process.exit(failed ? 1 : 0);
