// Collect examples/styles/catalog/*.json → examples/styles/catalog.json, and write the style table into README.md
// between <!-- styles:start --> and <!-- styles:end -->.
import { readFileSync, writeFileSync, readdirSync, existsSync } from 'node:fs';
const root = new URL('..', import.meta.url).pathname;
const dir = root + 'examples/styles/';
const items = readdirSync(dir + 'catalog').filter((f) => f.endsWith('.json')).map((f) => JSON.parse(readFileSync(dir + 'catalog/' + f, 'utf8')))
  .filter((c) => existsSync(dir + c.id + '.tsvg'))
  .sort((a, b) => (a.category || '').localeCompare(b.category || '') || a.title.localeCompare(b.title));
writeFileSync(dir + 'catalog.json', JSON.stringify(items, null, 1));
const PAGES = 'https://panth977.github.io/tsvg';
const cats = [...new Set(items.map((c) => c.category))];
let md = `**${items.length} styles**, each a ~1-minute TSVG video with narration. ▶ [Open the gallery](${PAGES}/gallery/) to play any of them in the browser (click a thumbnail).\n\n`;
for (const cat of cats) {
  const list = items.filter((c) => c.category === cat);
  md += `#### ${cat}\n\n<table><tr>\n`;
  list.forEach((c, i) => {
    if (i && i % 4 === 0) md += '</tr><tr>\n';
    md += `<td width="25%" valign="top"><a href="${PAGES}/gallery/#${c.id}"><img src="examples/styles/thumbs/${c.id}.png" alt="${c.title}"></a><br><b>${c.title}</b><br><sub>${c.summary} · ${Math.round(c.duration)} s · <a href="examples/styles/${c.id}.tsvg">source</a></sub></td>\n`;
  });
  md += '</tr></table>\n\n';
}
const readme = readFileSync(root + 'README.md', 'utf8');
const out = readme.replace(/<!-- styles:start -->[\s\S]*<!-- styles:end -->/, `<!-- styles:start -->\n${md}<!-- styles:end -->`);
writeFileSync(root + 'README.md', out);
console.log(`${items.length} styles · ${cats.length} categories`);
