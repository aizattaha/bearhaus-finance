# Vendored libraries (v2 sprint 3)

Both pages load supabase-js from this folder, not from a CDN, so a new release can't reach production
untested and a CDN outage can't stop the app from starting. Still no build step: the file is the
published UMD bundle, byte for byte.

| File | Version | Source | Checks |
|---|---|---|---|
| `supabase-js-2.117.3.min.js` | 2.117.3 (7 Oct 2026) | `dist/umd/supabase.js` from the npm tarball `@supabase/supabase-js@2.117.3` | tarball `sha512-K+f8PimXDunPWQ63CKRXaF5pbVPJxmfw5ryAnh0s9S9PkwcuqBjiSpIaqpF7KLDljeYwXIL85ST8QxaO0+XuvA==` (npm's published integrity); file sha256 `d6a5c4414a5d4ce646d9c1de223aa7067d3ff664c15394ffeb7fcffc763354a3` (same as jsDelivr's copy) |
| `LICENSE-supabase-js.txt` | — | the package's MIT licence | — |

The `<script>` tags carry `integrity="sha384-…"`, so the browser refuses the file if it ever changes.
`tools/ci/check-js.mjs` fails if a page loads a script from another site, if a local script is missing,
or if its integrity hash doesn't match the file.

## Upgrading (a deliberate change, tested like any other)
1. Pick a 2.x release that has been out for at least a week: `npm view @supabase/supabase-js time --json`.
2. Download the tarball into an empty scratch folder and check it against npm's integrity:
   `curl -sO https://registry.npmjs.org/@supabase/supabase-js/-/supabase-js-2.X.Y.tgz`,
   `echo "sha512-$(openssl dgst -sha512 -binary supabase-js-2.X.Y.tgz | base64)"` must equal
   `npm view @supabase/supabase-js@2.X.Y dist.integrity`.
3. `tar -xzf` it, copy `package/dist/umd/supabase.js` here as `supabase-js-2.X.Y.min.js`, delete the old file.
4. New hash: `echo "sha384-$(openssl dgst -sha384 -binary app/vendor/supabase-js-2.X.Y.min.js | base64)"`;
   put the file name and hash in both `app/index.html` and `desktop/index.html`, and update this table.
5. `node tools/ci/check-js.mjs`, then the browser check on the local stack (sign in, a save, sign out).
