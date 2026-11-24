// Merge vendor/edit-kit-catalog/{a,b,c}.json → vendor/edit-kit-catalog/catalog.json, check demo ids,
// and write the summary table into README.md between <!-- editkit:start --> and <!-- editkit:end -->.
import { readFileSync, writeFileSync, readdirSync, existsSync } from 'node:fs';
const root = new URL('..', import.meta.url).pathname;
const dir = root + 'vendor/edit-kit-catalog/';
const styles = new Set(JSON.parse(readFileSync(root + 'examples/styles/catalog.json', 'utf8')).map((c) => c.id));
let items = [];
for (const f of readdirSync(dir).filter((f) => /^[a-z]\.json$/.test(f)).sort()) items = items.concat(JSON.parse(readFileSync(dir + f, 'utf8')));
const seen = new Set(); items = items.filter((x) => (seen.has(x.id) ? false : seen.add(x.id)));
const demos = {}; for (const f of readdirSync(dir).filter((f) => /^demos-.*\.json$/.test(f))) Object.assign(demos, JSON.parse(readFileSync(dir + f, 'utf8')));
for (const x of items) { x.count = x.count || 1; if (demos[x.id] && existsSync(root + 'examples/kit/' + demos[x.id].reel + '.tsvg')) x.kit_demo = demos[x.id]; if (x.tsvg_demo && !styles.has(x.tsvg_demo)) { console.warn('unknown demo', x.id, x.tsvg_demo); x.tsvg_demo = null; } }
const order = { native: 0, partial: 1, no: 2, 'n/a': 3 };
items.sort((a, b) => a.skill.localeCompare(b.skill) || order[a.tsvg] - order[b.tsvg] || a.name.localeCompare(b.name));
writeFileSync(dir + 'catalog.json', JSON.stringify(items, null, 1));
const videos = items.filter((x) => x.tsvg !== 'n/a');
const sum = (k) => videos.filter((x) => x.tsvg === k).reduce((s, x) => s + x.count, 0);
const total = videos.reduce((s, x) => s + x.count, 0);
const withDemo = videos.filter((x) => x.tsvg_demo || x.kit_demo).reduce((s, x) => s + x.count, 0);
const skills = [...new Set(items.map((x) => x.skill))];
let md = `The [Edit Kit](vendor/edit-kit) (41 Claude Code video skills) can make **${total} kinds of video** across ${skills.length} skills (types, styles, recipes, transitions, effects). Rated against TSVG today:\n\n`;
md += `| ✅ native | ◐ partial | ✗ not yet | with a TSVG demo |\n|---|---|---|---|\n| **${sum('native')}** (${Math.round((100 * sum('native')) / total)}%) | **${sum('partial')}** (${Math.round((100 * sum('partial')) / total)}%) | **${sum('no')}** (${Math.round((100 * sum('no')) / total)}%) | ${withDemo} |\n\n`;
const reels = [...new Set(Object.values(demos).map((d) => d.reel))].sort();
if (reels.length) md += `Showcase reels (one chapter per entry): ${reels.map((r) => `[${r}](https://panth977.github.io/tsvg/gallery/#kit:${r})`).join(' · ')}\n\n`;
md += `▶ [Browse the whole catalogue](https://panth977.github.io/tsvg/gallery/edit-kit.html): every entry, why it is or isn't possible, and the TSVG demo to watch.\n\n`;
md += '| Skill | Kinds | ✅ | ◐ | ✗ |\n|---|---|---|---|---|\n';
for (const s of skills) { const v = videos.filter((x) => x.skill === s); if (!v.length) continue; const c = (k) => v.filter((x) => x.tsvg === k).reduce((a, x) => a + x.count, 0); md += `| \`${s}\` | ${v.reduce((a, x) => a + x.count, 0)} | ${c('native')} | ${c('partial')} | ${c('no')} |\n`; }
md += `\nTooling skills (no video of their own): ${items.filter((x) => x.tsvg === 'n/a').map((x) => '`' + x.skill + '`').filter((v, i, a) => a.indexOf(v) === i).join(', ')}.\n`;
const readme = readFileSync(root + 'README.md', 'utf8');
writeFileSync(root + 'README.md', readme.includes('<!-- editkit:start -->') ? readme.replace(/<!-- editkit:start -->[\s\S]*<!-- editkit:end -->/, `<!-- editkit:start -->\n${md}<!-- editkit:end -->`) : readme.replace('## Voices', `## What can TSVG make? (Edit Kit catalogue)\n\n<!-- editkit:start -->\n${md}<!-- editkit:end -->\n\n## Voices`));
console.log(`${items.length} entries · ${total} kinds · native ${sum('native')} · partial ${sum('partial')} · no ${sum('no')} · with demo ${withDemo}`);
