// Syntax-check every script the two pages run: app/common.js plus each inline <script> block in
// app/index.html and desktop/index.html. No build step and no dependencies: Node compiles each block
// with vm.Script and reports the first syntax error with its line number in the HTML file.
// Since v2 sprint 3 it also keeps the client-security rules: each page carries a Content Security Policy,
// loads scripts only from this site (supabase-js is vendored in app/vendor/, see its README), and every
// integrity="sha384-…" matches the file it names.
// Usage: node tools/ci/check-js.mjs
import { readFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

let failed = false;
const check = (file, code, lineOffset) => {
  try { new vm.Script(code, { filename: file, lineOffset }); }
  catch (e) {
    failed = true;
    const m = /:(\d+)/.exec(e.stack || '');
    console.log(`✗ ${file}${m ? ':' + m[1] : ''} — ${e.message}`);
  }
};

check('app/common.js', readFileSync('app/common.js', 'utf8'), 0);
for (const file of ['app/index.html', 'desktop/index.html']) {
  const html = readFileSync(file, 'utf8');
  const re = /<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g;
  let m, n = 0;
  while ((m = re.exec(html))) {
    n++;
    const line = html.slice(0, m.index + m[0].indexOf('>') + 1).split('\n').length - 1;
    check(file, m[1], line);
  }
  if (!n) { failed = true; console.log(`✗ ${file} — no inline script found`); }
  // client security (v2 sprint 3)
  const csp = /<meta http-equiv="Content-Security-Policy" content="([^"]+)">/.exec(html);
  if (!csp) { failed = true; console.log(`✗ ${file} — no Content-Security-Policy meta tag`); }
  else if (!/connect-src [^;]*supabase\.co/.test(csp[1]) || /script-src [^;]*(https?:|\*)/.test(csp[1])) {
    failed = true; console.log(`✗ ${file} — the CSP must name the Supabase project in connect-src and allow no other site in script-src`);
  }
  const tag = /<script\b([^>]*)\bsrc="([^"]+)"([^>]*)>/g;
  while ((m = tag.exec(html))) {
    const src = m[2], attrs = m[1] + m[3];
    if (/^(https?:)?\/\//.test(src)) { failed = true; console.log(`✗ ${file} — loads a script from another site: ${src} (vendor it into app/vendor/)`); continue; }
    const local = join(dirname(file), src.split('?')[0]);
    if (!existsSync(local)) { failed = true; console.log(`✗ ${file} — script not found: ${src}`); continue; }
    const sri = /integrity="(sha384-[^"]+)"/.exec(attrs);
    if (sri) {
      const actual = 'sha384-' + createHash('sha384').update(readFileSync(local)).digest('base64');
      if (actual !== sri[1]) { failed = true; console.log(`✗ ${file} — integrity of ${src} doesn't match the file (${actual})`); }
    } else if (/\/vendor\//.test('/' + src)) { failed = true; console.log(`✗ ${file} — vendored ${src} has no integrity hash`); }
  }
}
console.log(failed ? '✗ JavaScript / client-security check failed' : '✓ JavaScript syntax check passed · CSP present · scripts local and pinned');
process.exit(failed ? 1 : 0);
