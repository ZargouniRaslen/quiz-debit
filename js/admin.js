'use strict';
let ME = null;
async function adminGuard() {
  const { data } = await sb.auth.getSession();
  if (!data.session) return false;
  ME = data.session.user;
  try { return await rpc('is_admin'); } catch (e) { return false; }
}
const adminHead = () => `<header class="ahead"><a class="brand" href="#/admin/dashboard">Quiz Débitmètres</a><a href="#/admin/dashboard">Tableau de bord</a><span>${esc(displayId(ME?.email))}</span><button class="ghost sm" id="lo">Déconnexion</button></header>`;
const bindLogout = () => { const b = $('#lo'); if (b) b.onclick = async () => { await sb.auth.signOut(); location.hash = '#/admin'; }; };

/* Comptes internes : identifiant + mot de passe (aucun e-mail réel).
   L'identifiant est transformé en "identifiant@quiz.local" pour Supabase Auth.
   Dans Supabase : Authentication > Providers > Email > désactiver "Confirm email". */
function toAuthEmail(id) {
  const s = String(id || '').trim().toLowerCase();
  if (!s) return '';
  if (s.includes('@')) return s;           // déjà une adresse (compat)
  return s.replace(/[^a-z0-9._+-]/g, '') + '@quiz.local';
}
function displayId(email) {
  if (!email) return '';
  return email.endsWith('@quiz.local') ? email.slice(0, -'@quiz.local'.length) : email;
}
function authScreen() {
  let tab = 'in';
  const draw = () => {
    screen(`<section class="home"><p class="eyebrow">Espace animateur</p><h1>${tab === 'up' ? 'Créer un compte' : 'Connexion'}</h1>
    <div class="tabs"><button class="${tab === 'in' ? 'on' : ''}" data-t="in">Connexion</button><button class="${tab === 'up' ? 'on' : ''}" data-t="up">Créer un compte</button></div>
    <form id="f" class="panel">
      <label><span>Identifiant</span><input id="em" type="text" autocomplete="username" required maxlength="60" placeholder="ex. animateur"></label>
      <label><span>Mot de passe</span><input id="pw" type="password" minlength="6" autocomplete="current-password" required></label>
      <p class="err" id="err" aria-live="polite"></p>
      <button class="btn">Valider</button>
    </form>
    <p class="foot"><a href="#/">← Accueil joueurs</a></p></section>`);
    document.querySelectorAll('.tabs button').forEach(b => b.onclick = () => { tab = b.dataset.t; draw(); });
    $('#f').onsubmit = async e => {
      e.preventDefault();
      const err = m => { $('#err').textContent = m; };
      const raw = $('#em').value;
      const email = toAuthEmail(raw);
      if (!email || email === '@quiz.local') return err('Choisissez un identifiant.');
      const cred = { email, password: $('#pw').value };
      try {
        if (tab === 'in') {
          const { error } = await sb.auth.signInWithPassword(cred);
          if (error) {
            const m = (error.message || '').toLowerCase();
            if (m.includes('rate limit')) return err('Trop d\'essais. Réessayez dans quelques minutes.');
            return err('Identifiant ou mot de passe incorrect.');
          }
        } else {
          const { data, error } = await sb.auth.signUp(cred);
          if (error) {
            const m = (error.message || '').toLowerCase();
            if (m.includes('rate limit')) return err('Trop de créations. Réessayez plus tard ou connectez-vous.');
            if (m.includes('already') || m.includes('registered')) return err('Cet identifiant existe déjà. Connectez-vous.');
            return err(error.message);
          }
          if (!data.session) {
            // Confirm email encore activé côté Supabase
            return err('Compte créé, mais la session n\'est pas ouverte. Dans Supabase : Authentication → Providers → Email → désactivez « Confirm email », puis reconnectez-vous.');
          }
        }
        route();
      } catch (er) { err('Erreur : ' + er.message); }
    };
  };
  draw();
}

/* ---------- Chargement des quiz : RPC d'abord, lecture directe en secours ---------- */
async function loadQuizzes() {
  try {
    const r = await rpc('list_my_quizzes');
    return { list: (r || []).map(q => ({ ...q, n: q.question_count || 0 })) };
  } catch (e1) {
    const { data, error } = await sb.from('quizzes').select('id,title,default_time_s,updated_at,quiz_questions(count)').order('updated_at', { ascending: false });
    if (error) return { list: [], error: error.message || e1.message };
    return { list: (data || []).map(q => ({ ...q, n: (q.quiz_questions && q.quiz_questions[0] && q.quiz_questions[0].count) || 0 })) };
  }
}
async function getQuiz(id) {
  try {
    const r = await rpc('get_quiz', { p_id: id });
    return r ? { z: { title: r.title, default_time_s: r.default_time_s }, qq: r.questions || [] } : null;
  } catch (e) {
    const [{ data: z }, { data: qq }] = await Promise.all([sb.from('quizzes').select('*').eq('id', id).single(), sb.from('quiz_questions').select('*').eq('quiz_id', id).order('pos')]);
    return z ? { z, qq: qq || [] } : null;
  }
}

/* ---------- Tableau de bord (réécrit : lignes en styles inline, indépendantes du CSS) ---------- */
const ZB = 'padding:10px 18px;border-radius:12px;font-weight:700;font:inherit;font-weight:700;cursor:pointer;text-decoration:none;display:inline-block;border:1px solid var(--gold-soft);';
const ZROW = 'display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap;margin:12px 0;padding:16px 18px;border-radius:18px;background:var(--card);color:var(--ink);border:1px solid var(--line);box-shadow:var(--sh);';
const zrow = (title, sub, actions) => `<div style="${ZROW}"><div style="min-width:0"><div style="font-weight:800;font-size:18px">${esc(title)}</div><div style="color:var(--mut);font-size:14px">${sub}</div></div><div style="display:flex;gap:8px;flex-wrap:wrap;align-items:center">${actions}</div></div>`;

async function dashboard() {
  screen(`<section class="adm">${adminHead()}<div class="load"><div class="spin"></div></div></section>`); bindLogout();
  const [qr, sessions, counts] = await Promise.all([loadQuizzes(), rpc('list_my_sessions').catch(() => null), rpc('quiz_counts').catch(() => null)]);
  const qs = qr.list, ss = sessions || [];
  let quizHtml;
  if (qr.error) quizHtml = `<p class="warn">Impossible de charger vos quiz : ${esc(qr.error)}<br><button class="ghost sm" id="rt" style="margin-top:8px">Réessayer</button></p>`;
  else if (qs.length) quizHtml = qs.map(q => zrow(q.title, `${q.n} question${q.n > 1 ? 's' : ''} · ${q.default_time_s} s par question`,
    `<button type="button" data-l="${q.id}" style="${ZB}background:var(--btn);color:var(--btn-fg)">Lancer</button><a href="#/admin/quiz/${q.id}" style="${ZB}background:var(--ghost);color:var(--ink)">Modifier</a><button type="button" data-d="${q.id}" aria-label="Supprimer" style="${ZB}background:var(--ghost);color:var(--bad)">🗑</button>`)).join('');
  else if (counts && counts.total > 0 && counts.mine === 0) quizHtml = `<p class="warn">La base contient ${counts.total} quiz, mais aucun n'appartient au compte <b>${esc(displayId(ME?.email))}</b>. Déconnectez-vous et reconnectez-vous avec le compte qui les a créés.</p>`;
  else quizHtml = `<p class="sub">Aucun quiz.</p><button class="btn inl" id="imp">✨ Importer le quiz « Débitmètres (exemple) » (10 questions)</button>`;
  const sessHtml = sessions === null ? '<p class="warn">Historique indisponible (erreur de chargement).</p>'
    : ss.length ? ss.map(s => zrow(s.title, `${new Date(s.created_at).toLocaleString('fr-FR')} · ${s.code} · ${s.players} joueur(s) · ${s.status}`,
      `<a href="#/admin/${s.status === 'finished' ? 'report' : 'host'}/${s.id}" style="${ZB}background:var(--ghost);color:var(--ink)">${s.status === 'finished' ? 'Résultats / PDF' : 'Reprendre'}</a>`)).join('')
    : '<p class="sub">Aucune session.</p>';
  screen(`<section class="adm">${adminHead()}<div class="row"><h2>Mes quiz</h2><a class="btn inl" href="#/admin/quiz/new">＋ Nouveau quiz</a></div>
  ${quizHtml}
  <h2>Historique des sessions</h2>${sessHtml}
  <p style="font-size:11px;opacity:.55;margin-top:24px">build dash-v7 · ${esc(displayId(ME?.email))} · ${qs.length} quiz</p></section>`);
  bindLogout();
  const rt = $('#rt'); if (rt) rt.onclick = dashboard;
  app.onclick = async e => {
    const l = e.target.closest('[data-l]'), d = e.target.closest('[data-d]');
    if (l) try { const r = await rpc('create_session', { p_quiz: l.dataset.l }); location.hash = '#/admin/host/' + r.session_id; } catch (er) { toast(has(er, 'need_') ? 'Le quiz doit contenir au moins une question' : 'Erreur'); }
    if (d && await confirmBox('Supprimer ce quiz ? Ses sessions et résultats seront aussi supprimés.', 'Supprimer')) { try { await rpc('delete_quiz', { p_id: d.dataset.d }); } catch (er) { toast('Suppression impossible'); } dashboard(); }
  };
  const imp = $('#imp'); if (imp) imp.onclick = async () => { imp.disabled = true; try { await rpc('import_legacy_questions'); dashboard(); } catch (er) { imp.disabled = false; toast('Import impossible : ' + er.message); } };
}

async function editor(id) {
  const MAX = 200; let uidc = 0;
  const blank = (fresh = true) => ({ k: ++uidc, prompt: '', options: ['', '', '', ''], n: 4, correct: 0, explanation: '', time_s: '', open: false, fresh });
  const Q = { title: '', def: 15, qs: Array.from({ length: 10 }, () => blank(false)) };
  let dirty = false, used = false;
  if (id) {
    const [full, ss] = await Promise.all([getQuiz(id), rpc('list_my_sessions').catch(() => [])]);
    if (!full) { toast('Quiz introuvable'); location.hash = '#/admin/dashboard'; return; }
    const z = full.z, qq = full.qq;
    Q.title = z.title; Q.def = z.default_time_s; used = ss.length > 0;
    Q.qs = (qq || []).map(q => ({ ...blank(false), prompt: q.prompt, options: [...q.options, '', ''].slice(0, 4), n: q.options.length, correct: q.correct, explanation: q.explanation, time_s: q.time_s ?? '' }));
    if (!Q.qs.length) Q.qs = [blank(false)];
  } else Q.qs[0].open = true;

  const idx = k => Q.qs.findIndex(q => q.k === k);
  const done = q => q.prompt.trim() && q.options.slice(0, q.n).every(o => o.trim());
  const cardOf = k => $(`.eq[data-k="${k}"]`);
  const grow = t => { t.style.height = 'auto'; t.style.height = t.scrollHeight + 'px'; };

  const cardHTML = (q, i) => `<article class="card eq${q.open ? ' open' : ''}${q.fresh ? ' new' : ''}${done(q) ? ' ok' : ''}" data-k="${q.k}">
    <header class="eqh" data-a="tg" tabindex="0"><span class="qn">${i + 1}</span><span class="qprev">${q.prompt.trim() ? esc(q.prompt) : '<em>Nouvelle question…</em>'}</span><span class="qstat" title="${done(q) ? 'Complète' : 'Incomplète'}"></span><span class="chev">▾</span></header>
    <div class="eqb"><div class="eqi">
      <textarea data-f="prompt" rows="2" placeholder="Votre question">${esc(q.prompt)}</textarea>
      <div class="seg2" role="group" aria-label="Nombre de réponses"><button type="button" data-n="3" class="${q.n === 3 ? 'on' : ''}">3 réponses</button><button type="button" data-n="4" class="${q.n === 4 ? 'on' : ''}">4 réponses</button></div>
      ${[0, 1, 2, 3].slice(0, q.n).map(c => `<div class="ch${q.correct === c ? ' good' : ''}" style="--c:${COLS[c].c}"><i style="background:${COLS[c].c}">${shape(c)}</i><input data-o="${c}" value="${esc(q.options[c])}" placeholder="Réponse ${COLS[c].n}"><label class="rad" title="Bonne réponse"><input type="radio" name="c${q.k}" data-c="${c}" ${q.correct === c ? 'checked' : ''}><span>✓</span></label></div>`).join('')}
      <input data-f="explanation" value="${esc(q.explanation)}" placeholder="Explication affichée après la réponse (optionnel)">
      <label class="tl">Temps (s) <input data-f="time_s" type="number" min="5" max="300" value="${q.time_s}" placeholder="${Q.def}"> <small class="eff">(effectif : ${q.time_s === '' ? Q.def : q.time_s} s)</small></label>
      <div class="qacts"><button type="button" class="ghost sm" data-a="up" title="Monter">↑</button><button type="button" class="ghost sm" data-a="dn" title="Descendre">↓</button><button type="button" class="ghost sm" data-a="cp">Dupliquer</button><button type="button" class="ghost sm danger" data-a="rm">Supprimer</button></div>
    </div></div></article>`;

  function status() {
    const bad = Q.qs.filter(q => !done(q)).length;
    $('#nav').innerHTML = Q.qs.map((q, i) => `<button type="button" data-g="${q.k}" class="${done(q) ? 'ok' : 'todo'}">${i + 1}</button>`).join('');
    $('#stat').innerHTML = `<b>${Q.qs.length}</b> question${Q.qs.length > 1 ? 's' : ''} · ${bad ? `<span class="todo">${bad} à compléter</span>` : '<span class="okc">tout est prêt ✓</span>'}${dirty ? ' · <span class="dot">● non enregistré</span>' : ''}`;
    const c = $('#cnt'); if (c && document.activeElement !== c) c.value = Q.qs.length;
    document.querySelectorAll('.eq').forEach(el => el.classList.toggle('ok', !!done(Q.qs[idx(+el.dataset.k)] || {})));
  }
  function redraw(opts = {}) {
    const y = scrollY;
    $('#list').innerHTML = Q.qs.map(cardHTML).join('') + `<button type="button" class="addq" data-a="add">＋ Ajouter une question</button>`;
    Q.qs.forEach(q => q.fresh = false);
    document.querySelectorAll('.eq.open textarea').forEach(grow);
    status(); if (!opts.keepScroll) scrollTo(0, y);
    if (opts.flash) { const el = cardOf(opts.flash); if (el) { el.classList.add('flash'); } }
  }
  function focusQ(k, scroll = true) {
    const el = cardOf(k); if (!el) return; el.classList.add('open');
    const t = el.querySelector('textarea'); grow(t);
    if (scroll) el.scrollIntoView({ behavior: 'smooth', block: 'start' });
    setTimeout(() => t.focus({ preventScroll: true }), 350);
  }
  async function setCount(n) {
    n = Math.max(1, Math.min(MAX, Math.round(+n) || Q.qs.length));
    if (n === Q.qs.length) { status(); return; }
    if (n < Q.qs.length) {
      const cut = Q.qs.slice(n);
      if (cut.some(q => q.prompt.trim() || q.options.some(o => o.trim())) && !await confirmBox(`Retirer ${cut.length} question(s) à la fin, dont certaines sont remplies ?`, 'Retirer')) { status(); return; }
      Q.qs.length = n;
    } else while (Q.qs.length < n) Q.qs.push(blank());
    dirty = true; redraw();
  }
  function remove(k) {
    const i = idx(k); if (Q.qs.length <= 1) return toast('Un quiz doit contenir au moins une question');
    const q = Q.qs[i], el = cardOf(k), go = () => { Q.qs.splice(i, 1); dirty = true; redraw(); };
    const filled = q.prompt.trim() || q.options.some(o => o.trim());
    if (el) { el.classList.add('bye'); setTimeout(go, 300); } else go();
    if (filled) toast(`Question ${i + 1} supprimée`, { label: 'Annuler', fn: () => { Q.qs.splice(Math.min(i, Q.qs.length), 0, q); dirty = true; redraw({ flash: q.k }); } });
  }

  screen(`<section class="adm ed">${adminHead()}<h2>${id ? 'Modifier le quiz' : 'Nouveau quiz'}</h2>${used ? '<p class="warn">Modifier ce quiz change aussi l\'affichage des anciens résultats ; dupliquez-le plutôt.</p>' : ''}
    <div class="panel setup"><label><span>Titre</span><input id="t" value="${esc(Q.title)}" maxlength="120" placeholder="Ex. Débitmètres à ultrasons"></label>
      <div class="two"><label><span>Durée par défaut (s)</span><input id="d" type="number" min="5" max="300" value="${Q.def}"></label>
      <div class="cntw"><span>Nombre de questions</span><div class="stepper"><button type="button" data-a="m" aria-label="Moins">−</button><input id="cnt" type="number" inputmode="numeric" min="1" max="${MAX}" value="${Q.qs.length}"><button type="button" data-a="p" aria-label="Plus">＋</button></div></div></div>
      <div class="presets">${[5, 10, 15, 20, 30, 50].map(n => `<button type="button" data-p="${n}">${n}</button>`).join('')}<small>Vous pourrez toujours en ajouter ou en retirer plus tard.</small></div></div>
    <div class="edlayout"><aside class="navw"><div class="navt">Questions</div><div id="nav" class="nav"></div><div class="navb"><button type="button" class="ghost sm" data-a="ex">Tout ouvrir</button><button type="button" class="ghost sm" data-a="co">Tout fermer</button></div></aside><div id="list" class="list"></div></div>
    <div class="savebar"><div id="stat" class="stat"></div><p class="err" id="err" aria-live="polite"></p><div class="sbb"><button type="button" class="ghost" data-a="add">＋ Question</button><button type="button" class="btn inl" id="sv">Enregistrer</button><button type="button" class="btn inl alt" id="sq">Terminer</button></div></div>
    <p class="edfoot">${id ? '<button class="ghost" id="dup" type="button">Dupliquer ce quiz</button> ' : ''}<a class="ghost" href="#/admin/dashboard">Annuler</a></p></section>`);
  bindLogout(); redraw({ keepScroll: true });

  async function save(leave) {
    const bad = (el, m) => { $('#err').textContent = m; if (el) { el.focus({ preventScroll: true }); el.scrollIntoView({ block: 'center', behavior: 'smooth' }); } };
    $('#err').textContent = '';
    if (!Q.title.trim()) return bad($('#t'), 'Titre requis');
    for (let i = 0; i < Q.qs.length; i++) {
      const q = Q.qs[i]; if (done(q)) continue;
      const el = cardOf(q.k); el.classList.add('open', 'shake'); setTimeout(() => el.classList.remove('shake'), 700);
      const t = el.querySelector('textarea'); grow(t);
      const empty = q.prompt.trim() ? [...el.querySelectorAll('[data-o]')].find((x, c) => c < q.n && !x.value.trim()) : t;
      return bad(empty, `Question ${i + 1} incomplète`);
    }
    const sv = $('#sv'), sq = $('#sq'); sv.disabled = sq.disabled = true;
    try {
      const nid = await rpc('save_quiz', { p_id: id || null, p_title: Q.title, p_default_time: Q.def, p_questions: Q.qs.map(q => ({ prompt: q.prompt, options: q.options.slice(0, q.n), correct: q.correct, explanation: q.explanation, time_s: q.time_s === '' ? null : +q.time_s })) });
      dirty = false; used = used; toast('Quiz enregistré ✓');
      if (leave) { location.hash = '#/admin/dashboard'; return; }
      if (!id) { id = nid; history.replaceState(null, '', '#/admin/quiz/' + nid); lastHash = location.hash; $('.adm h2').lastChild.textContent = ' Modifier le quiz'; }
      status();
    } catch (er) { const m = /invalid_question_(\d+)/.exec(er.message); $('#err').textContent = m ? `Question ${m[1]} incomplète` : has(er, 'need_') ? 'Ajoutez au moins une question' : 'Erreur : ' + er.message; }
    sv.disabled = sq.disabled = false;
  }

  app.oninput = e => {
    const t = e.target, c = t.closest('.eq');
    if (t.id === 'cnt') return;
    dirty = true;
    if (t.id === 't') Q.title = t.value;
    else if (t.id === 'd') { Q.def = +t.value || 15; document.querySelectorAll('.eq').forEach(el => { const q = Q.qs[idx(+el.dataset.k)]; el.querySelector('.eff').textContent = `(effectif : ${q.time_s === '' ? Q.def : q.time_s} s)`; el.querySelector('[data-f=time_s]').placeholder = Q.def; }); }
    else if (c) {
      const q = Q.qs[idx(+c.dataset.k)];
      if (t.dataset.f) {
        q[t.dataset.f] = t.value;
        if (t.dataset.f === 'prompt') { grow(t); c.querySelector('.qprev').innerHTML = t.value.trim() ? esc(t.value) : '<em>Nouvelle question…</em>'; }
        if (t.dataset.f === 'time_s') c.querySelector('.eff').textContent = `(effectif : ${q.time_s === '' ? Q.def : q.time_s} s)`;
      } else if (t.dataset.o) q.options[+t.dataset.o] = t.value;
      else if (t.dataset.c) { q.correct = +t.dataset.c; c.querySelectorAll('.ch').forEach((r, k) => r.classList.toggle('good', k === q.correct)); }
    }
    status();
  };
  app.onchange = e => { if (e.target.id === 'cnt') setCount(e.target.value); };
  app.onkeydown = e => {
    if (e.target.id === 'cnt' && e.key === 'Enter') { e.preventDefault(); setCount(e.target.value); }
    if (e.target.classList && e.target.classList.contains('eqh') && (e.key === 'Enter' || e.key === ' ')) { e.preventDefault(); e.target.click(); }
  };
  app.onclick = async e => {
    const T = e.target;
    if (T.id === 'sv') return save(false);
    if (T.id === 'sq') return save(true);
    if (T.id === 'dup') { id = null; used = false; dirty = true; Q.title += ' (copie)'; $('#t').value = Q.title; $('.adm h2').lastChild.textContent = ' Nouveau quiz'; status(); scrollTo({ top: 0, behavior: 'smooth' }); toast('Copie prête : enregistrez pour la créer'); T.remove(); return; }
    const p = T.closest('[data-p]'); if (p) return setCount(+p.dataset.p);
    const g = T.closest('[data-g]'); if (g) { const el = cardOf(+g.dataset.g); el.classList.add('open'); grow(el.querySelector('textarea')); el.scrollIntoView({ behavior: 'smooth', block: 'start' }); el.classList.add('flash'); setTimeout(() => el.classList.remove('flash'), 1200); return; }
    const n = T.closest('[data-n]');
    if (n) { const q = Q.qs[idx(+n.closest('.eq').dataset.k)]; q.n = +n.dataset.n; if (q.correct >= q.n) q.correct = 0; dirty = true; const k = q.k, y = scrollY; const el = cardOf(k); el.outerHTML = cardHTML(q, idx(k)); q.fresh = false; const ne = cardOf(k); ne.classList.remove('new'); grow(ne.querySelector('textarea')); status(); scrollTo(0, y); return; }
    const a = T.closest('[data-a]'); if (!a) return;
    const act = a.dataset.a, c = a.closest('.eq'), k = c ? +c.dataset.k : null;
    if (act === 'tg') { c.classList.toggle('open'); const q = Q.qs[idx(k)]; q.open = c.classList.contains('open'); if (q.open) grow(c.querySelector('textarea')); }
    else if (act === 'add') { const q = blank(); q.open = true; if (Q.qs.length >= MAX) return toast('Maximum ' + MAX + ' questions'); Q.qs.push(q); dirty = true; redraw(); focusQ(q.k); }
    else if (act === 'm') setCount(Q.qs.length - 1);
    else if (act === 'p') setCount(Q.qs.length + 1);
    else if (act === 'ex' || act === 'co') { Q.qs.forEach(q => q.open = act === 'ex'); document.querySelectorAll('.eq').forEach(el => { el.classList.toggle('open', act === 'ex'); if (act === 'ex') grow(el.querySelector('textarea')); }); }
    else if (act === 'rm') remove(k);
    else if (act === 'cp') { if (Q.qs.length >= MAX) return toast('Maximum ' + MAX + ' questions'); const i = idx(k), q = Q.qs[i], d = { ...blank(), prompt: q.prompt, options: [...q.options], n: q.n, correct: q.correct, explanation: q.explanation, time_s: q.time_s, open: true }; Q.qs.splice(i + 1, 0, d); dirty = true; redraw(); cardOf(d.k).scrollIntoView({ behavior: 'smooth', block: 'center' }); }
    else if (act === 'up' || act === 'dn') { const i = idx(k), j = act === 'up' ? i - 1 : i + 1; if (j < 0 || j >= Q.qs.length) return; [Q.qs[i], Q.qs[j]] = [Q.qs[j], Q.qs[i]]; dirty = true; redraw({ flash: k }); cardOf(k).scrollIntoView({ behavior: 'smooth', block: 'center' }); }
  };
  document.onkeydown = e => { if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 's') { e.preventDefault(); save(false); } };
  window.onbeforeunload = () => dirty || undefined;
  window.__dirty = () => dirty;
  onLeave(() => { window.onbeforeunload = null; window.__dirty = null; app.oninput = app.onchange = app.onkeydown = null; document.onkeydown = null; });
}
