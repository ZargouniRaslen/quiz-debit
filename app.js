'use strict';
let lastHash = location.hash;
async function route() {
  if (window.__dirty && window.__dirty() && lastHash !== location.hash && !confirm('Quitter sans enregistrer ?')) { history.replaceState(null, '', lastHash); return; }
  lastHash = location.hash; runCleanups(); app.onclick = null;
  const h = location.hash.replace(/^#/, '') || '/', p = h.split('/').filter(Boolean);
  if (p[0] !== 'admin') {
    if (p[0] === 'play') return play();
    if (localStorage.getItem(LSP) && p.length === 0 && !sessionStorage.getItem('qz_home')) { sessionStorage.setItem('qz_home', '1'); location.hash = '#/play'; return; }
    return home();
  }
  const ok = await adminGuard();
  if (!ok) return authScreen();
  if (!p[1]) return (location.hash = '#/admin/dashboard');
  if (p[1] === 'dashboard') return dashboard();
  if (p[1] === 'quiz') return editor(p[2] === 'new' ? null : p[2]);
  if (p[1] === 'host') return host(p[2]);
  if (p[1] === 'report') return report(p[2]);
  location.hash = '#/admin/dashboard';
}
addEventListener('hashchange', route);
route();
