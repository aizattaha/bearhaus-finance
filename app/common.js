// BearHaus — helpers shared by the phone app (app/index.html) and the Desk (desktop/index.html).
// Plain script, no build step: both pages load it with a <script src> before their own code.
// Anything here is global on purpose; keep it to pure helpers, constants and the sign-in/device-memory rules
// both pages must share.

// ── never inside another site's frame (clickjacking). The Desk frames the phone's add form: same site, allowed.
try { if (window.top !== window.self && window.top.location.origin !== location.origin) throw 0; } catch (e) { location.replace('about:blank'); }

// ── connection ────────────────────────────────────────────────────────────
const SUPABASE_URL = 'https://diqaezhdxloqhglndqrq.supabase.co';
const SUPABASE_KEY = 'sb_publishable_K-fUtwnuZAJLTNquqDN87Q_yBkEEGhZ';   // publishable (anon) key — RLS does the protecting
const sb = typeof supabase !== 'undefined' ? supabase.createClient(SUPABASE_URL, SUPABASE_KEY) : null;

// ── what this device remembers (v2 sprint 3) ──────────────────────────────
// Everything the apps keep in localStorage belongs to ONE login: keys are 'bh:<user id>:<name>'. Nothing is
// read until the app knows who signed in (store.use), and signing in as someone else forgets the last login's
// keys. store.clear() is the one way to forget; endSession() — every sign-out, expiry and removed login — uses it.
// Two keys belong to the device, not a login: the sign-up code typed before a login exists, and the keyboard height.
const DEVICE_KEYS = ['bh-invite', 'bh-kb'];
// last-used picks (ids and labels, never amounts) that versions before sprint 3 kept under one global key
const LEGACY_PICK = /^bh-(trip|fund|fundexp|incfund|payer|cur|paycard|paycard-fund|purged|last-backup|tut-done|acat-group-\w+|swap-[\w-]+)$/;
const store = {
  uid: null,
  key(name){ return 'bh:' + this.uid + ':' + name; },
  get(name){ if (!this.uid) return null; try { return localStorage.getItem(this.key(name)); } catch (e) { return null; } },
  set(name, v){ if (!this.uid) return; try { localStorage.setItem(this.key(name), v); } catch (e) {} },
  remove(name){ if (!this.uid) return; try { localStorage.removeItem(this.key(name)); } catch (e) {} },
  json(name){ try { return JSON.parse(this.get(name)); } catch (e) { return null; } },
  // signed in as uid: keep this login's keys and drop everyone else's. An older version's picks come along only
  // when its cached household says this same login wrote them; its cached numbers never do (they are refetched).
  use(uid){
    if (!uid) return;
    const carry = [];
    try {
      const old = JSON.parse(localStorage.getItem('bh-ctx') || 'null');
      const same = !!(old && old.me && old.me.user_id === uid);
      Object.keys(localStorage).forEach(k => {
        if (k.startsWith('bh:' + uid + ':') || DEVICE_KEYS.includes(k) || !(k.startsWith('bh:') || k.startsWith('bh-'))) return;
        if (same && LEGACY_PICK.test(k)) carry.push([k.slice(3), localStorage.getItem(k)]);
        localStorage.removeItem(k);
      });
    } catch (e) {}
    this.uid = uid;
    carry.forEach(([name, v]) => { if (this.get(name) == null) this.set(name, v); });
  },
  // forget every login's cached numbers and picks on this device (the device's own two keys stay)
  clear(){
    try { Object.keys(localStorage).forEach(k => { if ((k.startsWith('bh:') || k.startsWith('bh-')) && !DEVICE_KEYS.includes(k)) localStorage.removeItem(k); }); } catch (e) {}
  },
};
// a login is stored on this device (supabase-js keeps it as sb-<project>-auth-token)
const hasStoredLogin = () => { try { return Object.keys(localStorage).some(k => /^sb-.*-auth-token/.test(k)); } catch (e) { return false; } };
// The one way out — the sign-out button, a login that expired or was revoked, a sign-out in another tab. Signs
// out on the server when it can (on this device even when it can't), forgets every cached number, and reloads
// so nothing stays in memory either. `note` is shown on the sign-in card after the reload.
async function endSession(note){
  if (endSession.busy) return;
  endSession.busy = true;
  if (sb) await Promise.race([sb.auth.signOut().catch(() => {}), new Promise(r => setTimeout(r, 4000))]);
  try { Object.keys(localStorage).forEach(k => { if (/^sb-.*-auth-token/.test(k)) localStorage.removeItem(k); }); } catch (e) {}
  store.clear();
  try { localStorage.removeItem('bh-invite'); if (note) sessionStorage.setItem('bh-note', note); } catch (e) {}
  location.reload();
}
// the sign-in card's one-off message from endSession (read once)
function takeSignInNote(){ try { const n = sessionStorage.getItem('bh-note'); sessionStorage.removeItem('bh-note'); return n || ''; } catch (e) { return ''; } }

// ── DOM ───────────────────────────────────────────────────────────────────
const $ = id => document.getElementById(id);
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

// ── money ─────────────────────────────────────────────────────────────────
const CURSYM = { AUD:'A$', SGD:'S$', IDR:'Rp', JPY:'¥', CNY:'CN¥', KRW:'₩', THB:'฿', MYR:'RM',
                 VND:'₫', EUR:'€', GBP:'£', USD:'US$', NZD:'NZ$', TWD:'NT$', HKD:'HK$', INR:'₹',
                 PHP:'₱', CHF:'CHF ', CAD:'C$', AED:'AED ', BND:'B$', LKR:'Rs ', SEK:'kr ',
                 NOK:'kr ', DKK:'kr ', TRY:'₺', ZAR:'R ', BRL:'R$', MXN:'MX$' };
// country → its everyday currency; feeds signup, Settings' "+ new country" and trips
const COUNTRY_CUR = { AU:'AUD', SG:'SGD', MY:'MYR', ID:'IDR', TH:'THB', VN:'VND', PH:'PHP', JP:'JPY',
  KR:'KRW', CN:'CNY', TW:'TWD', HK:'HKD', IN:'INR', LK:'LKR', BN:'BND', NZ:'NZD', US:'USD', CA:'CAD',
  GB:'GBP', IE:'EUR', FR:'EUR', DE:'EUR', ES:'EUR', IT:'EUR', NL:'EUR', PT:'EUR', CH:'CHF',
  SE:'SEK', NO:'NOK', DK:'DKK', AE:'AED', TR:'TRY', ZA:'ZAR', BR:'BRL', MX:'MXN' };
const ZERO_DEC = { JPY:1, KRW:1, IDR:1, VND:1, HUF:1, CLP:1, ISK:1, UGX:1, TWD:1 };
// −A$1,234.50 · Rp185,000 · ¥3,200 — the sign travels with the number, zero-decimal currencies show none
function fmtMoney(v, cur){
  const sym = CURSYM[cur] || (cur ? String(cur).replace(/[^A-Za-z]/g, '').slice(0, 5) + ' ' : 'A$');
  const n = Number(v) || 0, d = ZERO_DEC[cur] ? 0 : 2;
  return (n < 0 ? '−' : '') + sym + Math.abs(n).toLocaleString('en-AU', {minimumFractionDigits:d, maximumFractionDigits:d});
}
const curLabel = c => CURSYM[c] || String(c || '').replace(/[^A-Za-z]/g, '').slice(0, 5);

// ── countries ─────────────────────────────────────────────────────────────
// 'SG' -> 🇸🇬
const flagOf = cc => /^[A-Z]{2}$/.test(cc || '') ? String.fromCodePoint(...[...cc].map(c => 0x1F1A5 + c.charCodeAt(0))) : '';
const COUNTRY_NAME = { AU:'Australia', SG:'Singapore', MY:'Malaysia', ID:'Indonesia', TH:'Thailand', VN:'Vietnam',
  PH:'Philippines', JP:'Japan', KR:'South Korea', CN:'China', TW:'Taiwan', HK:'Hong Kong', IN:'India', LK:'Sri Lanka',
  BN:'Brunei', NZ:'New Zealand', US:'United States', CA:'Canada', GB:'United Kingdom', IE:'Ireland', FR:'France',
  DE:'Germany', ES:'Spain', IT:'Italy', NL:'Netherlands', PT:'Portugal', CH:'Switzerland', SE:'Sweden', NO:'Norway',
  DK:'Denmark', AE:'UAE', TR:'Türkiye', ZA:'South Africa', BR:'Brazil', MX:'Mexico' };
const countryTitle = cc => (flagOf(cc) ? flagOf(cc) + ' ' : '') + (COUNTRY_NAME[cc] || cc || 'Other');

// ── dates (ISO yyyy-mm-dd strings, local time) ────────────────────────────
const isoDate = d => d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
const todayIso = () => isoDate(new Date());
const addDays = (iso, n) => { const d = new Date(iso + 'T00:00:00'); d.setDate(d.getDate() + n); return isoDate(d); };
const curMonthIso = () => { const n = new Date(); return isoDate(new Date(n.getFullYear(), n.getMonth(), 1)); };
const addMonths = (iso, n) => { const d = new Date(iso + 'T00:00:00'); return isoDate(new Date(d.getFullYear(), d.getMonth() + n, 1)); };
const fmtD  = iso => new Date(iso + 'T00:00:00').toLocaleDateString('en-AU', {day:'numeric', month:'short', year:'numeric'});
const fmtDs = iso => new Date(iso + 'T00:00:00').toLocaleDateString('en-AU', {day:'numeric', month:'short'});

// ── the owner's setup list (Bundle C) ─────────────────────────────────────
// setup_todo() (SQL) works out each item from the data; this is what each one says on the phone's Home and the Desk
// Dashboard, which link it to their own screens. An item leaves the list when its job is done. A new feature that
// gives the owner a job adds an item here and in setup_todo — not a line in HANDOVER.
const nOf = (k, one, many) => k + ' ' + (k === 1 ? one : (many || one + 's'));
const listOf = a => { a = (a || []).filter(Boolean); return a.length <= 2 ? a.join(' and ') : a.slice(0, -1).join(', ') + ' and ' + a[a.length - 1]; };
const SETUP_TEXT = {
  me:           { icon: '👤', title: 'That’s me', cap: () => 'tell the app which person you are: Settings → People → that’s me' },
  defaults:     { icon: '⭐', title: 'Default cards', cap: i => 'no Daily card yet for ' + listOf(i.people) + ' — and pick where each card is offered (Daily · Trip · From a fund)' },
  closing_days: { icon: '📅', title: 'A closing day on every credit card', cap: i => listOf(i.cards) + ' — set it before ticking anything on the Desk' },
  old_refunds:  { icon: '↩️', title: 'Redo the old refunds', cap: i => nOf(i.n, 'old-style refund line') + ' — refund each purchase the new way (↩ Refund), then delete the old line' },
  sort:         { icon: '🧹', title: 'Sort fund spending', cap: i => nOf(i.n, 'row') + ' still to sort', desk: true },
  openings:     { icon: '🏁', title: 'What each card owed on the start date', cap: i => listOf(i.cards) + ' — Statements, the panel under the card', desk: true },
  statements:   { icon: '🧾', title: 'Close statements and record payments', desk: true,
                  cap: i => i.blocked ? 'set the closing days first, then close each statement since the start date'
                    : [i.to_close ? nOf(i.to_close, 'statement') + ' to close' : '', i.to_pay ? nOf(i.to_pay, 'closed statement') + ' to pay' : ''].filter(Boolean).join(' · ') },
  trips:        { icon: '✈️', title: 'Finish your trips', cap: i => [i.waiting ? nOf(i.waiting, 'card purchase') + ' waiting for what the card charged (Desk → Statements)' : '',
                                                               i.to_send ? nOf(i.to_send, 'line') + ' ready to send (Travel)' : ''].filter(Boolean).join(' · ') },
  invite:       { icon: '💌', title: 'Invite your partner', cap: i => nOf(i.n, 'person', 'people') + ' with no login of their own: Settings → People → invite to sign in' },
  signup_check: { icon: '🔐', title: 'Switch on the sign-up check', cap: () => 'one switch in Supabase, so only people you invite can sign up' },
};
// the sign-up check is switched on in Supabase's dashboard, not in the app: the steps, then a tick (setup_mark)
const SETUP_SIGNUP_STEPS = '<ol style="margin:6px 0 0 18px;padding:0;line-height:20px">'
  + '<li>On a computer, open <b>supabase.com/dashboard</b> and sign in (your password manager has it).</li>'
  + '<li>Open the <b>BearHaus</b> project → <b>Authentication</b> → <b>Hooks</b>.</li>'
  + '<li><b>Before User Created</b> → Add hook → <b>Postgres</b> → schema <b>public</b> → function <b>hook_before_user_created</b> → Create.</li>'
  + '<li>Come back here and tap <b>It’s on</b>.</li></ol>';

// ── numbers that explain themselves (Bundle C, CX-06) ─────────────────────
// the three fund numbers in one sentence each (both apps, tap/hover on "Available")
const MONEY_DEF = 'Available = what a fund has left to spend: money in, minus money moved out, minus the purchases counted against it. '
  + 'Owed on cards = charged to a credit card, not paid yet. In the bank = Available + owed on cards — what the bank should show. '
  + 'Paying a card moves the last two, never Available.';
// how one fund's Available is made, from fund_explain() (SQL: the parts add up to fund_money, tested fund by fund)
function explainHtml(x){
  if (!x || !x.month) return '';
  const c = x.currency, f = v => fmtMoney(Number(v) || 0, c), m = x.month, a = x.all;
  const mon = new Date(x.month_start + 'T00:00:00').toLocaleDateString('en-AU', { month: 'long' });
  return '<p class="cap"><b>How ' + esc(f(x.available)) + ' Available is made</b> — ' + esc(f(m.opening)) + ' at the start of ' + esc(mon)
    + ' + ' + esc(f(m.money_in)) + ' in − ' + esc(f(m.moved_out)) + ' moved out − ' + esc(f(m.purchases)) + ' purchases since'
    + ' (all time: ' + esc(f(a.money_in)) + ' in − ' + esc(f(a.moved_out)) + ' out − ' + esc(f(a.purchases)) + ' purchases)'
    + (Math.abs(Number(x.owed_on_cards)) >= 0.005 ? '. In the bank ' + esc(f(x.in_bank)) + ' = Available + ' + esc(f(x.owed_on_cards)) + ' still owed on cards' : '') + '.</p>';
}
// "checked to 2 Oct" for a fund or a card from money_checks(); null = not yet checked against a statement
function checkedHtml(entry){
  if (!entry) return '';
  if (entry.checked_to) return '<span class="cap">✓ checked against statements to ' + esc(fmtDs(entry.checked_to)) + '</span>';
  return '<span class="tag warn" title="' + esc('no closed statement yet for ' + listOf(entry.unchecked || [])) + '">not yet checked against statements</span>';
}
