// dist/tsvg.js: the three engine files as one classic script (defines window.TSVG, TSVGZip, TSVGPlayer).
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
const root = new URL('..', import.meta.url).pathname;
const v = JSON.parse(readFileSync(root + 'deno.json', 'utf8')).version;
const body = ['tsvg-core.js', 'tsvg-zip.js', 'tsvg-player.js'].map((f) => `// ── ${f} ──\n` + readFileSync(root + 'web/' + f, 'utf8')).join('\n');
mkdirSync(root + 'dist', { recursive: true });
writeFileSync(root + 'dist/tsvg.js', `/*! TSVG ${v} · Timeseries Scalable Vector Graphics · MIT · github.com/Panth977/tsvg */\n` + body);
console.log('dist/tsvg.js', v, (body.length / 1024).toFixed(0) + ' KB');
