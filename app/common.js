// BearHaus — helpers shared by the phone app (app/index.html) and the Desk (desktop/index.html).
// Plain script, no build step: both pages load it with a <script src> before their own code.
// Anything here is global on purpose; keep it to pure helpers and constants.

// ── connection ────────────────────────────────────────────────────────────
const SUPABASE_URL = 'https://diqaezhdxloqhglndqrq.supabase.co';
const SUPABASE_KEY = 'sb_publishable_K-fUtwnuZAJLTNquqDN87Q_yBkEEGhZ';   // publishable (anon) key — RLS does the protecting
const sb = typeof supabase !== 'undefined' ? supabase.createClient(SUPABASE_URL, SUPABASE_KEY) : null;

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
