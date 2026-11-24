// dist/tsvg.js: the three engine files as one classic script (defines window.TSVG, TSVGZip, TSVGPlayer).
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
const root = new URL('..', import.meta.url).pathname;
const v = JSON.parse(readFileSync(root + 'deno.json', 'utf8')).version;
const pkg = /const PKG = '([^']+)'/.exec(readFileSync(root + 'web/tsvg-core.js', 'utf8'))[1];
if (pkg !== v) { console.error(`web/tsvg-core.js PKG ${pkg} != deno.json ${v}: bump both (tsvg:<lib> imports resolve to jsr.io/@panth977/tsvg/<PKG>/libs/)`); process.exit(1); }
const body = ['tsvg-core.js', 'tsvg-zip.js', 'tsvg-player.js'].map((f) => `// ── ${f} ──\n` + readFileSync(root + 'web/' + f, 'utf8')).join('\n');
mkdirSync(root + 'dist', { recursive: true });
writeFileSync(root + 'dist/tsvg.js', `/*! TSVG ${v} · Timeseries Scalable Vector Graphics · MIT · github.com/Panth977/tsvg */\n` + body);
console.log('dist/tsvg.js', v, (body.length / 1024).toFixed(0) + ' KB');
