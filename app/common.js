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
