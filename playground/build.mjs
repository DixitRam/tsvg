// Build dist/playground.html: one self-contained file (engine inlined + a .tsvgz as base64).
//   node playground/build.mjs [package.tsvgz]   (default: packs examples/demo/demo.tsvg first)
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
const root = new URL('..', import.meta.url).pathname;
let pkg = process.argv[2];
if (!pkg) { pkg = root + 'dist/demo.tsvgz'; mkdirSync(root + 'dist', { recursive: true }); execFileSync('node', [root + 'cli/tsvg.mjs', 'pack', root + 'examples/demo/demo.tsvg', '-o', pkg], { stdio: 'inherit' }); }
let html = readFileSync(root + 'playground/index.html', 'utf8');
for (const f of ['tsvg-core.js', 'tsvg-zip.js', 'tsvg-player.js'])
  html = html.replace(`<script src="../web/${f}"></script>`, () => '<script>' + readFileSync(root + 'web/' + f, 'utf8').replace(/<\/script/g, '<\\/script') + '</script>');
html = html.replace('<script>\nconst frame', () => '<script>window.TSVG_EMBED = "' + readFileSync(pkg).toString('base64') + '";</script>\n<script>\nconst frame');
html = html.replace('href="../spec/"', 'href="https://github.com/Panth977/tsvg/blob/main/spec/index.html"');
writeFileSync(root + 'dist/playground.html', html);
console.log('dist/playground.html', (html.length / 1024 / 1024).toFixed(2) + ' MB');
