// tsvg live server: `tsvg watch` (live preview that reloads on every save) and `tsvg edit` (visual editor).
//   startLive({ file, port, mode: 'watch' | 'edit', root, host }) → Promise<{ url, server, close() }>
// Serves:
//   /                     → redirect to the page (editor/watch.html or editor/index.html) for the document
//   /editor/ /web/ /libs/ → this repo's pages, engine and libraries (tsvg:<lib> imports resolve to /libs/)
//   /doc/<path>           → the document and the files next to it (images, voice, clips) with HTTP ranges
//   /__live/info          → { mode, name } ;  /__live/files → paths next to the document (for "file not in package" checks)
//   /__live/events        → server-sent events: `change` when the document or a local .tsvgl it imports is saved
//   POST /__live/save     → edit mode only: writes the request body to the document (that one file, nothing else)
// Node built-ins only. Binds 127.0.0.1 by default.
import { createServer } from 'node:http';
import { readFileSync, writeFileSync, existsSync, statSync, createReadStream, watch, readdirSync, renameSync } from 'node:fs';
import { dirname, join, resolve, extname, basename, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const TYPES = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.mjs': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.webp': 'image/webp', '.gif': 'image/gif',
  '.ogg': 'audio/ogg', '.opus': 'audio/ogg', '.m4a': 'audio/mp4', '.mp3': 'audio/mpeg', '.wav': 'audio/wav',
  '.mp4': 'video/mp4', '.m4v': 'video/mp4', '.webm': 'video/webm', '.mov': 'video/quicktime',
  '.ttf': 'font/ttf', '.otf': 'font/otf', '.woff': 'font/woff', '.woff2': 'font/woff2',
  '.tsvg': 'application/xml; charset=utf-8', '.tsvgl': 'application/xml; charset=utf-8', '.tsvgz': 'application/zip', '.txt': 'text/plain; charset=utf-8',
};
const REPO_DIRS = ['editor', 'web', 'libs'];

// local libraries a document imports (relative paths / file paths, not tsvg: jsr: https:), recursively
function localImports(file, seen = new Set()) {
  if (seen.has(file) || !existsSync(file)) return seen;
  seen.add(file);
  let text = ''; try { text = readFileSync(file, 'utf8'); } catch { return seen; }
  for (const m of text.matchAll(/<import\b[^>]*?\bsrc\s*=\s*("([^"]*)"|'([^']*)')/g)) {
    const src = m[2] != null ? m[2] : m[3];
    if (!src || /^(tsvg|jsr|https?|data):/.test(src)) continue;
    localImports(resolve(dirname(file), src.replace(/^file:\/\//, '')), seen);
  }
  return seen;
}

// a file inside dir (or null): no '..' escapes, no symlink games via the resolved path prefix
function inside(dir, rel) {
  const p = resolve(dir, '.' + sep + rel);
  return p === dir || p.startsWith(dir + sep) ? p : null;
}

function sendFile(q, s, p) {
  let st; try { st = statSync(p); } catch { s.writeHead(404); return s.end('not found'); }
  if (st.isDirectory()) { const idx = join(p, 'index.html'); if (existsSync(idx)) return sendFile(q, s, idx); s.writeHead(404); return s.end('not found'); }
  const type = TYPES[extname(p).toLowerCase()] || 'application/octet-stream'; const size = st.size;
  const head = { 'content-type': type, 'accept-ranges': 'bytes', 'cache-control': 'no-store' };
  const m = /^bytes=(\d*)-(\d*)$/.exec(q.headers.range || ''); // video seeking (and Safari audio) needs ranges
  if (m && (m[1] || m[2])) {
    let a, b;
    if (m[1]) { a = +m[1]; b = m[2] ? Math.min(+m[2], size - 1) : size - 1; } else { a = Math.max(0, size - +m[2]); b = size - 1; }
    if (a >= size || a > b) { s.writeHead(416, { 'content-range': `bytes */${size}` }); return s.end(); }
    s.writeHead(206, Object.assign(head, { 'content-range': `bytes ${a}-${b}/${size}`, 'content-length': b - a + 1 }));
    if (q.method === 'HEAD') return s.end();
    return createReadStream(p, { start: a, end: b }).pipe(s);
  }
  s.writeHead(200, Object.assign(head, { 'content-length': size }));
  if (q.method === 'HEAD') return s.end();
  createReadStream(p).pipe(s);
}

function listFiles(dir, max = 5000) {
  const out = [];
  (function walk(d, rel) {
    let ents; try { ents = readdirSync(d, { withFileTypes: true }); } catch { return; }
    for (const e of ents) {
      if (out.length >= max) return;
      if (e.name.startsWith('.') || e.name === 'node_modules') continue;
      const r = rel ? rel + '/' + e.name : e.name;
      if (e.isDirectory()) walk(join(d, e.name), r); else if (e.isFile()) out.push(r);
    }
  })(dir, '');
  return out;
}

export async function startLive({ file, port, mode = 'watch', root, host = '127.0.0.1', log = console.log } = {}) {
  if (!file) throw new Error('startLive: file is required');
  if (mode !== 'watch' && mode !== 'edit') throw new Error('startLive: mode must be watch or edit');
  root = resolve(root || join(dirname(fileURLToPath(import.meta.url)), '..'));
  const doc = resolve(file); if (!existsSync(doc) || !statSync(doc).isFile()) throw new Error('no such file: ' + file);
  const docDir = dirname(doc), name = basename(doc);
  port = port == null ? (mode === 'edit' ? 4391 : 4390) : +port;
  const page = mode === 'edit' ? 'index.html' : 'watch.html';
  const pageUrl = `/editor/${page}?live=1&doc=${encodeURIComponent('/doc/' + name)}`;

  // ── watching: the document's directory and every local library's directory; editors often save by rename,
  // so watch directories (not the file inode) and filter by name.
  const clients = new Set(); const watchers = new Map(); let watched = new Set(); let timer = null; let version = 0;
  const broadcast = (ev, data) => { const msg = `event: ${ev}\ndata: ${JSON.stringify(data)}\n\n`; for (const c of clients) c.write(msg); };
  const refreshWatch = () => {
    watched = localImports(doc);
    for (const d of new Set([...watched].map((f) => dirname(f)))) {
      if (watchers.has(d)) continue;
      try {
        const w = watch(d, (type, fname) => {
          if (!fname) return; const f = join(d, fname.toString());
          if (!watched.has(f)) return;
          clearTimeout(timer); timer = setTimeout(() => { refreshWatch(); version++; broadcast('change', { version, file: relative(docDir, f) || name, lib: f !== doc }); }, 60);
        });
        w.on('error', () => {}); watchers.set(d, w);
      } catch {}
    }
  };
  refreshWatch();

  const server = createServer((q, s) => {
    let u; try { u = new URL(q.url, 'http://x'); } catch { s.writeHead(400); return s.end(); }
    const path = decodeURIComponent(u.pathname);
    if (path === '/' || path === '/index.html') { s.writeHead(302, { location: pageUrl }); return s.end(); }
    if (path === '/__live/info') { s.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' }); return s.end(JSON.stringify({ mode, name, doc: '/doc/' + name, version })); }
    if (path === '/__live/files') { s.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' }); return s.end(JSON.stringify(listFiles(docDir))); }
    if (path === '/__live/events') {
      s.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-store', connection: 'keep-alive' });
      s.write(`retry: 500\nevent: hello\ndata: ${JSON.stringify({ mode, name, version })}\n\n`);
      clients.add(s); const ping = setInterval(() => s.write(': ping\n\n'), 15000);
      q.on('close', () => { clearInterval(ping); clients.delete(s); });
      return;
    }
    if (path === '/__live/save') {
      if (q.method !== 'POST') { s.writeHead(405); return s.end(); }
      // only the editor page may save: a custom header forces a CORS preflight that this server never answers,
      // so other sites cannot post here; the Origin, when sent, must be this server
      const origin = q.headers.origin; const okOrigin = !origin || origin === `http://${q.headers.host}`;
      if (mode !== 'edit' || q.headers['x-tsvg-live'] !== '1' || !okOrigin) { s.writeHead(403, { 'content-type': 'text/plain' }); return s.end(mode !== 'edit' ? 'read-only (tsvg watch)' : 'forbidden'); }
      const chunks = []; let n = 0;
      q.on('data', (c) => { n += c.length; if (n > 50 * 1024 * 1024) { s.writeHead(413); s.end(); q.destroy(); } else chunks.push(c); });
      q.on('end', () => {
        if (s.writableEnded) return;
        try {
          const body = Buffer.concat(chunks);
          const tmp = join(docDir, '.' + name + '.tsvg-edit-' + process.pid); writeFileSync(tmp, body); renameSync(tmp, doc); // the document, nothing else
          s.writeHead(200, { 'content-type': 'application/json' }); s.end(JSON.stringify({ ok: true, bytes: body.length }));
          log(`saved ${doc} (${body.length} bytes)`);
        } catch (e) { s.writeHead(500, { 'content-type': 'text/plain' }); s.end(e.message); }
      });
      return;
    }
    if (q.method !== 'GET' && q.method !== 'HEAD') { s.writeHead(405); return s.end(); }
    if (path.startsWith('/doc/')) { const p = inside(docDir, path.slice(5)); if (!p) { s.writeHead(403); return s.end(); } return sendFile(q, s, p); }
    const top = path.split('/')[1];
    if (REPO_DIRS.includes(top)) { const p = inside(root, path.slice(1)); if (!p) { s.writeHead(403); return s.end(); } return sendFile(q, s, p); }
    s.writeHead(404); s.end('not found');
  });
  await new Promise((ok, no) => { server.once('error', no); server.listen(port, host, ok); });
  const url = `http://${host}:${server.address().port}${pageUrl}`;
  log(`tsvg ${mode}: ${url}\n  ${mode === 'edit' ? 'editing' : 'watching'} ${doc}${watched.size > 1 ? ` (+ ${watched.size - 1} local librar${watched.size === 2 ? 'y' : 'ies'})` : ''} · Ctrl+C to stop`);
  const close = () => new Promise((ok) => { for (const w of watchers.values()) w.close(); for (const c of clients) c.end(); server.close(() => ok()); });
  return { url, server, close, port: server.address().port };
}
