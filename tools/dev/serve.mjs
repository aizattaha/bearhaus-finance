// Local dev server (v2 sprint 1): serves the repo as GitHub Pages would, with app/common.js pointed at a
// LOCAL Supabase stack instead of production. No dependencies.
//   SUPABASE_URL=http://127.0.0.1:55321 SUPABASE_ANON_KEY=<from `supabase status`> node tools/dev/serve.mjs [port]
// then open http://127.0.0.1:8790/app/ and /desktop/. See tools/dev/README.md.
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = fileURLToPath(new URL('../..', import.meta.url));
const PORT = Number(process.argv[2] || process.env.PORT || 8790);
const URL_ = process.env.SUPABASE_URL, KEY = process.env.SUPABASE_ANON_KEY;
if (!URL_ || !KEY) { console.error('set SUPABASE_URL and SUPABASE_ANON_KEY (from `supabase status`)'); process.exit(1); }
if (/supabase\.co/.test(URL_)) { console.error('refusing to serve against a hosted project — this server is for the local stack only'); process.exit(1); }
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css', '.json': 'application/json', '.webmanifest': 'application/manifest+json', '.png': 'image/png', '.svg': 'image/svg+xml', '.ico': 'image/x-icon' };

createServer(async (req, res) => {
  let p = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  if (p.endsWith('/')) p += 'index.html';
  const file = normalize(join(ROOT, p));
  if (!file.startsWith(ROOT) || /\/\.(git|github)\//.test(file)) { res.writeHead(403); return res.end(); }
  try {
    let body = await readFile(file);
    if (p === '/app/common.js') {
      body = body.toString()
        .replace(/const SUPABASE_URL = '[^']+';/, `const SUPABASE_URL = '${URL_}';`)
        .replace(/const SUPABASE_KEY = '[^']+';/, `const SUPABASE_KEY = '${KEY}';`);
    }
    res.writeHead(200, { 'Content-Type': MIME[extname(file)] || 'application/octet-stream', 'Cache-Control': 'no-store' });
    res.end(body);
  } catch { res.writeHead(404); res.end('not found'); }
}).listen(PORT, '127.0.0.1', () => console.log(`BearHaus (local stack ${URL_}) → http://127.0.0.1:${PORT}/app/ · /desktop/`));
