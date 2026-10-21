// bridge/http.mjs — the HTTP vocabulary shared by server.mjs and its route
// modules: JSON responses, body reading, string coercion, the bridge-token
// check, the DNS-rebinding guard, and static file serving for the WebView UI.
import { createReadStream, readFileSync, statSync } from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const MIME = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css',
  '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png',
};

export function json(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body), 'cache-control': 'no-store' });
  res.end(body);
}

const MAX_BODY = 1024 * 1024;
export async function readBody(req) {
  const chunks = [];
  let size = 0;
  for await (const c of req) {
    size += c.length;
    if (size > MAX_BODY) throw Object.assign(new Error('body too large'), { status: 413 });
    chunks.push(c);
  }
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}'); } catch { return {}; }
}

export const str = (v, max = 200) => String(v ?? '').slice(0, max);

/** Timing-safe check of the bridge token (x-token header or ?token=). */
export function createTokenAuth(token) {
  const tokenBuf = Buffer.from(token);
  return function authed(req) {
    const url = new URL(req.url, 'http://localhost');
    const given = String(req.headers['x-token'] || url.searchParams.get('token') || '');
    const buf = Buffer.from(given);
    return buf.length === tokenBuf.length && crypto.timingSafeEqual(buf, tokenBuf);
  };
}

/** DNS-rebinding guard: only the loopback names the WebView uses. */
export function hostAllowed(req, port) {
  const h = String(req.headers.host || '');
  return h === `127.0.0.1:${port}` || h === `localhost:${port}`;
}

/** Serve the WebView UI; unknown paths fall back to index.html (SPA routing). */
export function createStaticServer({ publicDir, injectIosHtmlFlag }) {
  return function serveStatic(res, pathname) {
    let rel;
    try { rel = decodeURIComponent(pathname === '/' ? '/index.html' : pathname); } catch { res.writeHead(400); return res.end(); }
    let filePath = path.resolve(publicDir, `.${rel}`);
    if (filePath !== publicDir && !filePath.startsWith(publicDir + path.sep)) { res.writeHead(403); return res.end(); }
    let st = null;
    try { st = statSync(filePath); } catch {}
    if (!st?.isFile()) { filePath = path.join(publicDir, 'index.html'); }
    res.writeHead(200, { 'content-type': MIME[path.extname(filePath)] || 'application/octet-stream' });
    if (injectIosHtmlFlag && path.extname(filePath) === '.html') {
      // menu.js uses this flag to hide pages that need child processes
      // (ssh, PTY), which the in-process iOS engine cannot provide
      const html = readFileSync(filePath, 'utf8').replace('</head>', '<script>window.PI_MOBILE_IOS=1</script></head>');
      return res.end(html);
    }
    const stream = createReadStream(filePath);
    stream.on('error', () => { try { res.destroy(); } catch {} });
    stream.pipe(res);
  };
}
