// Inline player + demo + assets into one self-contained HTML (dist/report.html).
import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
const root = new URL('..', import.meta.url).pathname;
const rd = (p) => readFileSync(root + p, 'utf8');
const assets = {};
for (const f of readdirSync(root + 'examples/assets')) {
  const mime = f.endsWith('.ogg') ? 'audio/ogg' : f.endsWith('.png') ? 'image/png' : 'application/octet-stream';
  assets['assets/' + f] = `data:${mime};base64,` + readFileSync(root + 'examples/assets/' + f).toString('base64');
}
const esc = (s) => s.replace(/</g, '\\u003c');
let html = rd('tools/report.template.html')
  .replace('/*CORE*/', () => rd('player/vvf-core.js'))
  .replace('/*PLAYER*/', () => rd('player/vvf-player.js'))
  .replace('/*DEMO*/', () => JSON.stringify(rd('examples/demo.vvf.xml')).replace(/</g, '\\u003c'))
  .replace('/*ASSETS*/', () => esc(JSON.stringify(assets)));
writeFileSync(root + 'dist/report.html', html);
console.log('dist/report.html', (html.length / 1024).toFixed(0) + ' KB');
