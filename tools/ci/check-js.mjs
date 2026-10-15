// Syntax-check every script the two pages run: app/common.js plus each inline <script> block in
// app/index.html and desktop/index.html. No build step and no dependencies: Node compiles each block
// with vm.Script and reports the first syntax error with its line number in the HTML file.
// Usage: node tools/ci/check-js.mjs
import { readFileSync } from 'node:fs';
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
}
console.log(failed ? '✗ JavaScript syntax check failed' : '✓ JavaScript syntax check passed');
process.exit(failed ? 1 : 0);
