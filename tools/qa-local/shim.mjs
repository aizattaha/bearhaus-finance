// bh-local: a small PostgREST + GoTrue look-alike over the local Postgres copy of the BearHaus
// schema, so the real app + desk can be exercised end to end (RLS, triggers, RPCs, sign-up,
// onboarding) without reaching Supabase. Only the subset supabase-js v2 uses in this app.
import http from 'http';
import fs from 'fs';
import path from 'path';
import crypto from 'crypto';
import pg from 'pg';

const PORT = +(process.env.PORT || 54321);
const REPO = process.env.REPO || '/home/claude/bearhaus-finance';
const HERE = path.dirname(new URL(import.meta.url).pathname);
const pool = new pg.Pool({ host: '/tmp', port: 55432, user: 'bh', database: 'bh', max: 8 });

// ── schema metadata (FKs + PKs) for embeds ──────────────────────────────
let META = { fks: [], pk: {} };
async function loadMeta(){
  const c = await pool.connect();
  try {
    const fks = await c.query(`select tc.table_name as t, kcu.column_name as col, ccu.table_name as ft, ccu.column_name as fcol, tc.constraint_name as name
      from information_schema.table_constraints tc
      join information_schema.key_column_usage kcu on kcu.constraint_name = tc.constraint_name and kcu.table_schema = tc.table_schema
      join information_schema.constraint_column_usage ccu on ccu.constraint_name = tc.constraint_name and ccu.table_schema = tc.table_schema
      where tc.constraint_type = 'FOREIGN KEY' and tc.table_schema = 'public'`);
    const pks = await c.query(`select tc.table_name as t, kcu.column_name as col from information_schema.table_constraints tc
      join information_schema.key_column_usage kcu on kcu.constraint_name = tc.constraint_name and kcu.table_schema = tc.table_schema
      where tc.constraint_type = 'PRIMARY KEY' and tc.table_schema = 'public'`);
    const fns = await c.query(`select p.proname, p.proretset, t.typname, t.typtype, p.proargnames from pg_proc p join pg_namespace n on n.oid = p.pronamespace join pg_type t on t.oid = p.prorettype where n.nspname = 'public'`);
    META = { fks: fks.rows, pk: Object.fromEntries(pks.rows.map(r => [r.t, r.col])), fns: Object.fromEntries(fns.rows.map(r => [r.proname, r])) };
  } finally { c.release(); }
}

// ── tiny JWT ────────────────────────────────────────────────────────────
const b64u = s => Buffer.from(s).toString('base64').replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');
const makeJwt = user => b64u(JSON.stringify({ alg: 'HS256', typ: 'JWT' })) + '.' + b64u(JSON.stringify({ sub: user.id, email: user.email, role: 'authenticated', aud: 'authenticated', exp: Math.floor(Date.now() / 1000) + 365 * 86400 })) + '.' + b64u('local');
const readJwt = tok => { try { return JSON.parse(Buffer.from(tok.split('.')[1].replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString()); } catch (e) { return null; } };
const refreshTokens = new Map();  // refresh_token -> user id
const sessionFor = user => { const rt = crypto.randomUUID(); refreshTokens.set(rt, user.id); return { access_token: makeJwt(user), token_type: 'bearer', expires_in: 365 * 86400, expires_at: Math.floor(Date.now() / 1000) + 365 * 86400, refresh_token: rt, user: userJson(user) }; };
const userJson = u => ({ id: u.id, aud: 'authenticated', role: 'authenticated', email: u.email, email_confirmed_at: u.created_at, app_metadata: { provider: 'email', providers: ['email'] }, user_metadata: {}, created_at: u.created_at, updated_at: u.created_at });

// ── PostgREST query translation ─────────────────────────────────────────
const q = s => '"' + String(s).replace(/"/g, '""') + '"';
const OPS = { eq: '=', neq: '<>', gt: '>', gte: '>=', lt: '<', lte: '<=', like: 'LIKE', ilike: 'ILIKE' };
// split on commas at depth 0, honouring double quotes
function splitTop(s, sep = ','){
  const out = []; let cur = '', depth = 0, inq = false;
  for (let i = 0; i < s.length; i++) { const ch = s[i]; if (ch === '"') inq = !inq; if (!inq) { if (ch === '(') depth++; if (ch === ')') depth--; if (ch === sep && depth === 0) { out.push(cur); cur = ''; continue; } } cur += ch; }
  out.push(cur); return out.map(x => x.trim()).filter(x => x !== '');
}
const unq = v => (v.length >= 2 && v[0] === '"' && v[v.length - 1] === '"') ? v.slice(1, -1).replace(/\\"/g, '"') : v;
// parse "select" into a tree: { cols: [{name, alias}], embeds: [{name, alias, inner, hint, sel}] }
function parseSelect(sel){
  const node = { cols: [], embeds: [] };
  if (!sel || sel.trim() === '') sel = '*';
  for (const part of splitTop(sel)) {
    const m = part.match(/^(?:([\w ]+):)?([\w ]+?)(!inner|!left)?(?:!([\w]+))?\((.*)\)$/s);
    if (m) node.embeds.push({ alias: (m[1] || m[2]).trim(), name: m[2].trim(), inner: m[3] === '!inner', hint: m[4] || null, sel: parseSelect(m[5]) });
    else { const cm = part.match(/^(?:([\w ]+):)?([\w*]+)(?:::\w+)?$/); if (!cm) throw new Error('bad select: ' + part); node.cols.push({ alias: (cm[1] || cm[2]).trim(), name: cm[2].trim() }); }
  }
  return node;
}
// relationship between base table t and embed name r
function relation(t, r, hint){
  let f = META.fks.find(x => x.t === t && x.ft === r && (!hint || x.col === hint || x.name === hint));
  if (f) return { kind: 'one', local: f.col, foreign: f.fcol, table: r };
  f = META.fks.find(x => x.t === r && x.ft === t && (!hint || x.col === hint || x.name === hint));
  if (f) return { kind: 'many', local: f.fcol, foreign: f.col, table: r };
  return null;
}
// build a condition from (col, opExpr, value); returns SQL using params array
function cond(alias, col, opExpr, val, params){
  let neg = false; let op = opExpr;
  if (op.startsWith('not.')) { neg = true; op = op.slice(4); }
  let sql;
  const c = alias + '.' + q(col);
  if (op === 'is') { const v = String(val).toLowerCase(); sql = v === 'null' ? c + ' IS NULL' : c + ' IS ' + (v === 'true' ? 'TRUE' : 'FALSE'); }
  else if (op === 'in') { const inner = String(val).replace(/^\(/, '').replace(/\)$/, ''); const vals = splitTop(inner).map(unq); if (!vals.length) sql = 'FALSE'; else { const ps = vals.map(v => { params.push(v); return '$' + params.length; }); sql = c + ' IN (' + ps.join(',') + ')'; } }
  else if (OPS[op]) { params.push(unq(String(val))); sql = c + ' ' + OPS[op] + ' $' + params.length; }
  else if (op === 'cs') { params.push(unq(String(val))); sql = c + ' @> $' + params.length; }
  else if (op === 'fts' || op === 'plfts') { params.push(unq(String(val))); sql = 'to_tsvector(' + c + ') @@ plainto_tsquery($' + params.length + ')'; }
  else throw new Error('unsupported operator ' + opExpr);
  return neg ? 'NOT (' + sql + ')' : sql;
}
// logic tree "and(a.eq.1,or(b.is.null,c.gt.2))"
function logic(alias, expr, params, kind){
  const parts = splitTop(expr.replace(/^\((.*)\)$/s, '$1'));
  const out = parts.map(p => {
    let m = p.match(/^(not\.)?(and|or)(\(.*\))$/s);
    if (m) { const inner = logic(alias, m[3], params, m[2]); return (m[1] ? 'NOT ' : '') + inner; }
    m = p.match(/^([\w.]+?)\.(not\.)?(\w+)\.(.*)$/s);
    if (!m) throw new Error('bad logic: ' + p);
    if (m[1].includes('.')) throw new Error('embedded filter inside or() not supported: ' + p);
    return cond(alias, m[1], (m[2] || '') + m[3], m[4], params);
  });
  return '(' + out.join(kind === 'or' ? ' OR ' : ' AND ') + ')';
}
// one SELECT (or embedded sub-select). filters: Map of key -> [values]
function buildSelect(table, alias, selNode, filters, params, opts = {}){
  const parts = [];
  if (!selNode.cols.length && !selNode.embeds.length) parts.push(alias + '.*');
  for (const c of selNode.cols) parts.push(c.name === '*' ? alias + '.*' : alias + '.' + q(c.name) + (c.alias !== c.name ? ' AS ' + q(c.alias) : ''));
  const where = [];
  const innerExists = [];
  let n = 0;
  for (const e of selNode.embeds) {
    const rel = relation(table, e.name, e.hint);
    if (!rel) throw new Error('no relationship ' + table + ' -> ' + e.name);
    const sub = 'e' + (++n) + '_' + alias;
    const subFilters = new Map();
    for (const [k, vs] of filters) if (k.startsWith(e.alias + '.') || k.startsWith(e.name + '.')) subFilters.set(k.slice(k.indexOf('.') + 1), vs);
    const inner = buildSelect(rel.table, sub, e.sel, subFilters, params, { embedded: true });
    const join = sub + '.' + q(rel.foreign) + ' = ' + alias + '.' + q(rel.local);
    const body = 'SELECT ' + inner.select + ' FROM ' + q(rel.table) + ' ' + sub + ' WHERE ' + join + (inner.where ? ' AND ' + inner.where : '');
    if (rel.kind === 'one') parts.push('(SELECT row_to_json(x) FROM (' + body + ' LIMIT 1) x) AS ' + q(e.alias));
    else parts.push('(SELECT coalesce(json_agg(x), \'[]\'::json) FROM (' + body + ') x) AS ' + q(e.alias));
    if (e.inner || subFilters.size) innerExists.push('EXISTS (' + body + ')');
  }
  for (const [k, vs] of filters) {
    if (k.includes('.')) continue;   // embedded filter, handled above
    for (const v of vs) {
      if (k === 'or') where.push(logic(alias, v, params, 'or'));
      else if (k === 'and') where.push(logic(alias, v, params, 'and'));
      else if (k === 'not.or') where.push('NOT ' + logic(alias, v, params, 'or'));
      else if (k === 'not.and') where.push('NOT ' + logic(alias, v, params, 'and'));
      else { const m = String(v).match(/^(not\.)?(\w+)\.(.*)$/s); if (!m) throw new Error('bad filter ' + k + '=' + v); where.push(cond(alias, k, (m[1] || '') + m[2], m[3], params)); }
    }
  }
  where.push(...innerExists);
  return { select: parts.join(', '), where: where.join(' AND ') };
}
function orderSql(alias, order){
  if (!order) return '';
  return ' ORDER BY ' + splitTop(order).map(o => { const [col, ...rest] = o.split('.'); const r = rest.join('.'); return alias + '.' + q(col) + (/desc/.test(r) ? ' DESC' : ' ASC') + (/nullsfirst/.test(r) ? ' NULLS FIRST' : /nullslast/.test(r) ? ' NULLS LAST' : ''); }).join(', ');
}
const RESERVED = new Set(['select', 'order', 'limit', 'offset', 'on_conflict', 'columns']);
function filtersFrom(url){
  const f = new Map();
  for (const [k, v] of url.searchParams) { if (RESERVED.has(k)) continue; if (!f.has(k)) f.set(k, []); f.get(k).push(v); }
  return f;
}

// ── request handling ────────────────────────────────────────────────────
async function withDb(claims, fn){
  const c = await pool.connect();
  try {
    await c.query('BEGIN');
    await c.query('SET LOCAL ROLE ' + (claims ? 'authenticated' : 'anon'));
    await c.query("SELECT set_config('request.jwt.claim.sub', $1, true), set_config('request.jwt.claims', $2, true), set_config('request.jwt.claim.role', $3, true)", [claims ? claims.sub : '', JSON.stringify(claims || {}), claims ? 'authenticated' : 'anon']);
    const out = await fn(c);
    await c.query('COMMIT');
    return out;
  } catch (e) { try { await c.query('ROLLBACK'); } catch (_) {} throw e; }
  finally { c.release(); }
}
const send = (res, status, body, headers = {}) => { const h = Object.assign({ 'Content-Type': 'application/json; charset=utf-8', 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': '*', 'Access-Control-Allow-Methods': 'GET,POST,PATCH,PUT,DELETE,OPTIONS', 'Access-Control-Expose-Headers': '*' }, headers); res.writeHead(status, h); res.end(body === undefined ? '' : JSON.stringify(body)); };
const pgError = e => ({ code: e.code || 'PGRST000', message: e.message, details: e.detail || null, hint: e.hint || null });
const statusFor = e => e.code === '42501' ? 403 : e.code === '23505' ? 409 : e.code === '42P01' ? 404 : e.code === 'P0001' ? 400 : 400;
const readBody = req => new Promise(r => { let b = ''; req.on('data', d => b += d); req.on('end', () => r(b)); });
const LOG = [];
function log(entry){ LOG.push(entry); if (LOG.length > 2000) LOG.shift(); }

async function handleRest(req, res, url, claims){
  const m = url.pathname.match(/^\/rest\/v1\/(rpc\/)?([\w]+)$/);
  if (!m) return send(res, 404, { message: 'not found' });
  const prefer = String(req.headers['prefer'] || '');
  const accept = String(req.headers['accept'] || '');
  const wantObject = accept.includes('vnd.pgrst.object');
  const wantRep = prefer.includes('return=representation');
  const bodyText = ['POST', 'PATCH', 'PUT'].includes(req.method) ? await readBody(req) : '';
  const body = bodyText ? JSON.parse(bodyText) : null;
  const t0 = Date.now();
  try {
    if (m[1]) {   // rpc
      const fn = m[2]; const meta = META.fns[fn];
      if (!meta) return send(res, 404, { code: 'PGRST202', message: 'Could not find the function public.' + fn });
      const args = body || {}; const names = Object.keys(args);
      const params = names.map(k => args[k] === null ? null : (typeof args[k] === 'object' ? (Array.isArray(args[k]) && args[k].every(x => typeof x !== 'object') ? args[k] : JSON.stringify(args[k])) : args[k]));
      const call = q(fn) + '(' + names.map((k, i) => q(k) + ' := $' + (i + 1) + (Array.isArray(args[k]) && args[k].every(x => typeof x !== 'object') ? (args[k].every(x => typeof x === 'string' && /^[0-9a-f-]{36}$/.test(x)) ? '::uuid[]' : '::text[]') : (args[k] !== null && typeof args[k] === 'object' ? '::jsonb' : ''))).join(', ') + ')';
      const out = await withDb(claims, async c => {
        if (meta.proretset || meta.typtype === 'c') { const r = await c.query('SELECT coalesce(json_agg(row_to_json(x)), \'[]\'::json) AS j FROM ' + call + ' x', params); return r.rows[0].j; }
        if (meta.typname === 'void') { await c.query('SELECT ' + call, params); return null; }
        const r = await c.query('SELECT to_json(' + call + ') AS j', params); return r.rows[0].j;
      });
      log({ t: Date.now(), ms: Date.now() - t0, m: 'RPC', fn, args, ok: true });
      return send(res, 200, out === undefined ? null : out);
    }
    const table = m[2];
    const filters = filtersFrom(url);
    const selNode = parseSelect(url.searchParams.get('select') || '*');
    const limit = url.searchParams.get('limit'); const offset = url.searchParams.get('offset');
    const rangeHdr = String(req.headers['range'] || '').match(/^(\d+)-(\d+)?$/);
    const lim = limit != null ? +limit : (rangeHdr && rangeHdr[2] ? (+rangeHdr[2] - +rangeHdr[1] + 1) : null);
    const off = offset != null ? +offset : (rangeHdr ? +rangeHdr[1] : 0);
    const runSelect = async (c, extraWhere, extraParams) => {
      const params = extraParams ? extraParams.slice() : [];
      const b = buildSelect(table, 't', selNode, filters, params);
      const where = [b.where, extraWhere].filter(Boolean).join(' AND ');
      const sql = 'SELECT coalesce(json_agg(row_to_json(r)), \'[]\'::json) AS j FROM (SELECT ' + b.select + ' FROM ' + q(table) + ' t' + (where ? ' WHERE ' + where : '') + orderSql('t', url.searchParams.get('order')) + (lim != null ? ' LIMIT ' + lim : '') + (off ? ' OFFSET ' + off : '') + ') r';
      const r = await c.query(sql, params); return r.rows[0].j;
    };
    const finish = (rows, status) => {
      log({ t: Date.now(), ms: Date.now() - t0, m: req.method, table, n: rows ? rows.length : 0, qs: url.search });
      if (wantObject) {
        if (!rows || rows.length !== 1) return send(res, 406, { code: 'PGRST116', message: 'JSON object requested, multiple (or no) rows returned', details: 'The result contains ' + (rows ? rows.length : 0) + ' rows', hint: null });
        return send(res, status || 200, rows[0], { 'Content-Range': '0-0/*' });
      }
      return send(res, status || 200, rows, { 'Content-Range': (rows && rows.length ? off + '-' + (off + rows.length - 1) : '*') + '/*' });
    };
    if (req.method === 'GET' || req.method === 'HEAD') {
      const rows = await withDb(claims, c => runSelect(c));
      return finish(rows);
    }
    if (req.method === 'POST') {
      const rowsIn = Array.isArray(body) ? body : [body];
      if (!rowsIn.length) return finish([], 201);
      const cols = [...new Set(rowsIn.flatMap(r => Object.keys(r)))];
      const prim = v => Array.isArray(v) && v.every(x => x === null || typeof x !== 'object');
      const params = []; const tuples = rowsIn.map(r => '(' + cols.map(cn => { const v = r[cn]; params.push(v === undefined ? null : (v !== null && typeof v === 'object' && !prim(v) ? JSON.stringify(v) : v)); return '$' + params.length; }).join(',') + ')');
      let sql = 'INSERT INTO ' + q(table) + ' (' + cols.map(q).join(',') + ') VALUES ' + tuples.join(',');
      if (prefer.includes('resolution=merge-duplicates')) { const oc = url.searchParams.get('on_conflict') || META.pk[table]; sql += ' ON CONFLICT (' + oc.split(',').map(q).join(',') + ') DO UPDATE SET ' + cols.filter(cn => !oc.split(',').includes(cn)).map(cn => q(cn) + ' = EXCLUDED.' + q(cn)).join(', '); }
      else if (prefer.includes('resolution=ignore-duplicates')) sql += ' ON CONFLICT DO NOTHING';
      const pk = META.pk[table];
      const out = await withDb(claims, async c => {
        const r = await c.query(sql + (pk ? ' RETURNING ' + q(pk) : ''), params);
        if (!wantRep) return null;
        const ids = r.rows.map(x => x[pk]);
        if (!ids.length) return [];
        return runSelect(c, 't.' + q(pk) + ' = ANY($1)', [ids]);
      });
      if (!wantRep) { log({ t: Date.now(), m: 'POST', table, n: rowsIn.length }); return send(res, 201, undefined); }
      return finish(out, 201);
    }
    if (req.method === 'PATCH' || req.method === 'DELETE') {
      const params = []; const b = buildSelect(table, 't', parseSelect('*'), filters, params);
      if (!b.where) return send(res, 400, { message: 'refusing to ' + req.method + ' without a filter' });
      const pk = META.pk[table];
      let sql;
      if (req.method === 'PATCH') {
        const sets = Object.keys(body || {}).map(cn => { const v = body[cn]; params.push(v !== null && typeof v === 'object' && !(Array.isArray(v) && v.every(x => x === null || typeof x !== 'object')) ? JSON.stringify(v) : v); return q(cn) + ' = $' + params.length; });
        if (!sets.length) return finish([], 204);
        sql = 'UPDATE ' + q(table) + ' t SET ' + sets.join(', ') + ' WHERE ' + b.where;
      } else sql = 'DELETE FROM ' + q(table) + ' t WHERE ' + b.where;
      const out = await withDb(claims, async c => {
        const r = await c.query(sql + (pk ? ' RETURNING t.' + q(pk) : ''), params);
        if (!wantRep) return { n: r.rowCount };
        const ids = r.rows.map(x => x[pk]);
        if (req.method === 'DELETE') return r.rows;   // can't re-select deleted rows; return ids
        return runSelect(c, 't.' + q(pk) + ' = ANY($1)', [ids]);
      });
      if (!wantRep) { log({ t: Date.now(), m: req.method, table, n: out.n, qs: url.search }); return send(res, 204, undefined); }
      return finish(out, 200);
    }
    return send(res, 405, { message: 'method not allowed' });
  } catch (e) {
    log({ t: Date.now(), m: req.method, path: url.pathname, qs: url.search, error: e.message, code: e.code });
    return send(res, statusFor(e), pgError(e));
  }
}

async function handleAuth(req, res, url, claims){
  const p = url.pathname.replace(/^\/auth\/v1/, '');
  const bodyText = ['POST', 'PUT'].includes(req.method) ? await readBody(req) : '';
  const body = bodyText ? JSON.parse(bodyText) : {};
  const c = await pool.connect();
  try {
    if (p === '/signup' && req.method === 'POST') {
      const email = String(body.email || '').trim().toLowerCase(), password = String(body.password || '');
      if (!email || password.length < 6) return send(res, 422, { code: 422, error_code: 'weak_password', msg: 'Password should be at least 6 characters' });
      const ex = await c.query('SELECT 1 FROM auth.users WHERE email = $1', [email]);
      if (ex.rowCount) return send(res, 422, { code: 422, error_code: 'user_already_exists', msg: 'User already registered' });
      const r = await c.query('INSERT INTO auth.users (email, password) VALUES ($1, $2) RETURNING id, email, created_at', [email, password]);
      log({ t: Date.now(), m: 'AUTH', what: 'signup', email });
      return send(res, 200, sessionFor(r.rows[0]));
    }
    if (p === '/token' && req.method === 'POST') {
      const grant = url.searchParams.get('grant_type');
      if (grant === 'password') {
        const r = await c.query('SELECT id, email, created_at FROM auth.users WHERE email = $1 AND password = $2', [String(body.email || '').trim().toLowerCase(), String(body.password || '')]);
        if (!r.rowCount) return send(res, 400, { code: 400, error_code: 'invalid_credentials', msg: 'Invalid login credentials', error: 'invalid_grant', error_description: 'Invalid login credentials' });
        log({ t: Date.now(), m: 'AUTH', what: 'signin', email: r.rows[0].email });
        return send(res, 200, sessionFor(r.rows[0]));
      }
      if (grant === 'refresh_token') {
        const uid = refreshTokens.get(body.refresh_token);
        if (!uid) return send(res, 400, { code: 400, error_code: 'refresh_token_not_found', msg: 'Invalid Refresh Token', error: 'invalid_grant', error_description: 'Invalid Refresh Token' });
        const r = await c.query('SELECT id, email, created_at FROM auth.users WHERE id = $1', [uid]);
        return send(res, 200, sessionFor(r.rows[0]));
      }
      return send(res, 400, { msg: 'unsupported grant' });
    }
    if (p === '/user') {
      if (!claims) return send(res, 401, { code: 401, error_code: 'no_authorization', msg: 'missing token' });
      if (req.method === 'PUT') { if (body.password) await c.query('UPDATE auth.users SET password = $1 WHERE id = $2', [body.password, claims.sub]); }
      const r = await c.query('SELECT id, email, created_at FROM auth.users WHERE id = $1', [claims.sub]);
      if (!r.rowCount) return send(res, 401, { code: 401, error_code: 'user_not_found', msg: 'user not found' });
      return send(res, 200, userJson(r.rows[0]));
    }
    if (p === '/logout') return send(res, 204, undefined);
    if (p === '/recover') { log({ t: Date.now(), m: 'AUTH', what: 'recover', email: body.email }); return send(res, 200, {}); }
    if (p === '/settings') return send(res, 200, { external: { email: true }, disable_signup: false, mailer_autoconfirm: true });
    return send(res, 404, { msg: 'not found ' + p });
  } finally { c.release(); }
}

// ── static: app + desk patched to talk to this shim ─────────────────────
function patched(file){
  let h = fs.readFileSync(path.join(REPO, file), 'utf8');
  h = h.replace(/const SUPABASE_URL = '[^']+';/, "const SUPABASE_URL = 'http://127.0.0.1:" + PORT + "';")
       .replace(/<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/@supabase\/supabase-js@2"><\/script>/, '<script src="/vendor/supabase.js"></script>')
       .replace(/<link[^>]*fonts\.g(oogleapis|static)[^>]*>\s*/g, '')
       .replace(/<link rel="manifest"[^>]*>/, '')
       .replace(/navigator\.serviceWorker\.register\([^)]*\)/g, 'Promise.resolve()');
  return h;
}
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'application/javascript', '.png': 'image/png', '.json': 'application/json', '.webmanifest': 'application/manifest+json', '.css': 'text/css' };
function handleStatic(req, res, url){
  let p = url.pathname;
  if (p === '/app' || p === '/desktop') { res.writeHead(302, { Location: p + '/' }); return res.end(); }
  if (p === '/' ) { res.writeHead(200, { 'Content-Type': 'text/html' }); return res.end('<p style="font-family:sans-serif">bh-local · <a href="/app/">app</a> · <a href="/desktop/">desk</a> · <a href="/__log">log</a></p>'); }
  if (p === '/app/' || p === '/app/index.html') { res.writeHead(200, { 'Content-Type': MIME['.html'], 'Cache-Control': 'no-store' }); return res.end(patched('app/index.html')); }
  if (p === '/desktop/' || p === '/desktop/index.html') { res.writeHead(200, { 'Content-Type': MIME['.html'], 'Cache-Control': 'no-store' }); return res.end(patched('desktop/index.html')); }
  if (p === '/vendor/supabase.js') { res.writeHead(200, { 'Content-Type': MIME['.js'] }); return res.end(fs.readFileSync(path.join(HERE, 'node_modules/@supabase/supabase-js/dist/umd/supabase.js'))); }
  if (p === '/__log') { res.writeHead(200, { 'Content-Type': 'application/json' }); return res.end(JSON.stringify(LOG.slice(-300), null, 1)); }
  if (p === '/__reset-log') { LOG.length = 0; return send(res, 200, { ok: true }); }
  const safe = path.normalize(p).replace(/^(\.\.[\/\\])+/, '');
  const f = path.join(REPO, safe);
  if (f.startsWith(REPO) && fs.existsSync(f) && fs.statSync(f).isFile()) { res.writeHead(200, { 'Content-Type': MIME[path.extname(f)] || 'application/octet-stream' }); return res.end(fs.readFileSync(f)); }
  res.writeHead(404); res.end('not found');
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1:' + PORT);
  if (req.method === 'OPTIONS') return send(res, 204, undefined);
  const auth = String(req.headers['authorization'] || '');
  const tok = auth.startsWith('Bearer ') ? auth.slice(7) : null;
  let claims = tok ? readJwt(tok) : null;
  if (tok && !claims && !/^sb_publishable_/.test(tok) && url.pathname.startsWith('/rest/')) return send(res, 401, { message: 'JWSError: invalid token', code: 'PGRST301' });
  if (claims && claims.role !== 'authenticated') claims = null;   // the anon key is also sent as a bearer when signed out
  try {
    if (url.pathname.startsWith('/rest/v1/')) return await handleRest(req, res, url, claims);
    if (url.pathname.startsWith('/auth/v1/')) return await handleAuth(req, res, url, claims);
    return handleStatic(req, res, url);
  } catch (e) { console.error(e); return send(res, 500, { message: e.message }); }
});
await loadMeta();
server.listen(PORT, '127.0.0.1', () => console.log('bh-local on http://127.0.0.1:' + PORT + ' (app: /app/ · desk: /desktop/)'));
