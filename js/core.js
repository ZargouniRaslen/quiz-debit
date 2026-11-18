'use strict';
const $ = (s, r = document) => r.querySelector(s), app = $('#app');
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const fmt = ms => { const s = Math.ceil(Math.max(0, ms) / 1000); return String(s / 60 | 0).padStart(2, '0') + ':' + String(s % 60).padStart(2, '0'); };
const fmtS = ms => (ms / 1000).toFixed(1).replace('.', ',') + ' s';
const sb = supabase.createClient(CONFIG.SUPABASE_URL, CONFIG.SUPABASE_ANON_KEY);
const COLS = [
  { n: 'Rouge', c: '#E21B3C', s: '<polygon points="12,3 22,21 2,21"/>' },
  { n: 'Bleu', c: '#1368CE', s: '<polygon points="12,2 22,12 12,22 2,12"/>' },
  { n: 'Jaune', c: '#D89E00', s: '<circle cx="12" cy="12" r="10"/>' },
  { n: 'Vert', c: '#26890C', s: '<rect x="3" y="3" width="18" height="18" rx="1"/>' }];
const shape = i => `<svg class="shp" viewBox="0 0 24 24" fill="#fff" aria-hidden="true">${COLS[i].s}</svg>`;
const STATUS_FR = { lobby: 'Salle d’attente', question: 'En cours', results: 'Résultats', scores: 'Classement', finished: 'Terminée' };
function asJson(v) { if (typeof v === 'string') { try { return JSON.parse(v); } catch (e) { return v; } } return v; }
function asArr(v) { v = asJson(v); return Array.isArray(v) ? v : []; }
function screen(html) { app.innerHTML = html; app.style.animation = 'none'; void app.offsetWidth; app.style.animation = ''; scrollTo(0, 0); }
function toast(t, action) {
  const e = document.createElement('div'); e.className = 'toast'; e.append(document.createTextNode(t));
  if (action) { const b = document.createElement('button'); b.textContent = action.label; b.onclick = () => { action.fn(); e.remove(); }; e.append(b); }
  document.body.append(e); setTimeout(() => e.remove(), action ? 6000 : 3200);
}
function modal(html) { const m = document.createElement('div'); m.className = 'modal'; m.innerHTML = `<div>${html}</div>`; document.body.append(m); return m; }
function confirmBox(msg, ok = 'Confirmer') {
  return new Promise(res => {
    const m = modal(`<p>${esc(msg)}</p><div class="row"><button class="btn" id="y">${ok}</button><button class="ghost" id="n">Annuler</button></div>`);
    m.onclick = e => { if (e.target.id === 'y' || e.target.id === 'n' || e.target === m) { m.remove(); res(e.target.id === 'y'); } };
  });
}
async function rpc(fn, args = {}) { const { data, error } = await sb.rpc(fn, args); if (error) throw new Error(error.message || 'network'); return asJson(data); }
const has = (e, c) => String(e && e.message || e).includes(c);

const cleanups = [];
function onLeave(f) { cleanups.push(f); }
function runCleanups() { while (cleanups.length) { try { cleanups.pop()(); } catch (e) {} } }

let clockOff = 0;
const sync = st => { if (st && st.now) clockOff = Date.parse(st.now) - Date.now(); };
const srvNow = () => Date.now() + clockOff;

/* boucle d'état : Broadcast + polling, avec file d'attente si une requête est déjà en cours */
function live(sessionId, fetchState, onState, pollMs) {
  let stop = false, busy = false, pending = false, last = 0, tmr = null;
  const refresh = async () => {
    if (stop) return;
    if (busy) { pending = true; return; }
    busy = true;
    try { const st = await fetchState(); if (!stop) { sync(st); onState(st); } }
    catch (e) { if (!stop) onState(null, e); }
    finally { busy = false; if (pending && !stop) { pending = false; refresh(); } }
  };
  const deb = () => { const d = Date.now() - last; if (d > 280) { last = Date.now(); refresh(); } else if (!tmr) tmr = setTimeout(() => { tmr = null; last = Date.now(); refresh(); }, 280 - d); };
  const ch = sb.channel('s:' + sessionId, { config: { broadcast: { self: false } } }).on('broadcast', { event: 'tick' }, deb).subscribe();
  const iv = setInterval(refresh, pollMs);
  onLeave(() => { stop = true; clearInterval(iv); if (tmr) clearTimeout(tmr); sb.removeChannel(ch); });
  refresh();
  return { refresh, tick: () => ch.send({ type: 'broadcast', event: 'tick' }) };
}
