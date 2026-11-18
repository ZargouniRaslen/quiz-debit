'use strict';
const LSP = 'qz_live_player';
const ERR = { unknown_code: 'Code inconnu.', already_started: 'Ce quiz a déjà commencé.', name_required: 'Renseignez vos noms.', binome_incomplete: 'Renseignez vos noms.', name_taken: 'Ce nom est déjà pris dans cette partie.' };

function home() {
  let kind = 'solo';
  screen(`<section class="home"><p class="eyebrow">Quiz en direct</p><h1>Quiz <em>Débitmètres</em></h1><p class="sub">Entrez le code affiché par l'animateur</p>
  <form id="f" class="panel" autocomplete="off">
    <label><span>Code de la partie</span><input id="code" class="code" maxlength="4" autocapitalize="characters" inputmode="text" required></label>
    <div class="seg" id="seg"><i></i><button type="button" data-k="solo" class="on">Seul</button><button type="button" data-k="binome">Binôme</button></div>
    <label><span>Nom et prénom</span><input id="n1" maxlength="60" required></label>
    <label id="w2" hidden><span>Nom et prénom du binôme</span><input id="n2" maxlength="60"></label>
    <p class="err" id="err" aria-live="polite"></p><button class="btn" id="go">Rejoindre</button></form>
  <p class="foot"><a href="#/admin">Espace animateur</a></p></section>`);
  const code = $('#code'); code.oninput = () => code.value = code.value.toUpperCase().replace(/[^A-Z]/g, '');
  const jm = /^#\/join\/([A-Za-z]{4})/.exec(location.hash);
  if (jm) { code.value = jm[1].toUpperCase(); $('#n1').focus(); }
  const seg = $('#seg');
  seg.onclick = e => { const b = e.target.closest('button'); if (!b) return; kind = b.dataset.k; seg.dataset.k = kind; seg.querySelectorAll('button').forEach(x => x.classList.toggle('on', x === b)); $('#w2').hidden = kind === 'solo'; };
  $('#f').onsubmit = async e => {
    e.preventDefault(); $('#err').textContent = ''; $('#go').disabled = true;
    try {
      const r = await rpc('join_session', { p_code: code.value, p_kind: kind, p_name1: $('#n1').value, p_name2: kind === 'binome' ? $('#n2').value : null });
      localStorage.setItem(LSP, JSON.stringify({ player_id: r.player_id, session_id: r.session_id }));
      const jc = sb.channel('s:' + r.session_id, { config: { broadcast: { self: false } } });
      jc.subscribe(s => { if (s === 'SUBSCRIBED') { jc.send({ type: 'broadcast', event: 'tick' }); setTimeout(() => sb.removeChannel(jc), 800); } });
      location.hash = '#/play';
    } catch (er) { const k = Object.keys(ERR).find(k => has(er, k)); $('#err').textContent = ERR[k] || 'Erreur de connexion.'; $('#go').disabled = false; }
  };
}

function play() {
  let P = null; try { P = JSON.parse(localStorage.getItem(LSP) || 'null'); } catch (e) {}
  if (!P || !P.player_id) { location.hash = '#/'; return; }
  let key = '', st = null, raf = null, mine = null, locked = false;
  const L = live(P.session_id, () => rpc('player_state', { p_player: P.player_id }), (s, err) => {
    if (!s) {
      if (err && (has(err, 'not_found') || has(err, 'unknown'))) { localStorage.removeItem(LSP); location.hash = '#/'; }
      return;
    }
    st = s; const k = s.status + ':' + s.pos;
    if (k !== key) { key = k; mine = null; locked = false; render(); }
    else if (s.status === 'question') qDyn();
  }, 1200);
  onLeave(() => cancelAnimationFrame(raf));

  const choiceBtns = (locked, mine) => (st.question.options || []).map((o, i) =>
    `<button class="ans" data-i="${i}" style="background:${COLS[i].c}" ${locked ? 'disabled' : ''} ${mine === i ? 'data-mine' : ''}>${shape(i)}<span>${esc(o)}</span></button>`
  ).join('');

  function qDyn() {
    const n = srvNow(), lead = Date.parse(st.starts_at) - n, rem = Date.parse(st.ends_at) - n;
    const leadEl = $('#lead'), tm = $('#tm'), pg = $('#pg');
    if (!tm) return;
    const showLead = lead > 0;
    if (leadEl) leadEl.hidden = !showLead;
    if (showLead && leadEl) {
      const v = Math.max(1, Math.ceil(lead / 1000));
      if (leadEl.dataset.v !== String(v)) { leadEl.dataset.v = v; leadEl.innerHTML = `<small>Préparez-vous</small><b>${v}</b>`; }
    }
    tm.textContent = fmt(Math.max(0, rem));
    if (pg) { const total = Date.parse(st.ends_at) - Date.parse(st.starts_at); pg.style.width = Math.max(0, Math.min(100, (1 - rem / total) * 100)) + '%'; }
    /* early answers allowed during lead-in (Chine behaviour) */
    const canAnswer = !locked && rem > 0;
    document.querySelectorAll('.ans').forEach(b => { b.disabled = !canAnswer; });
  }

  function render() {
    cancelAnimationFrame(raf); const s = st;
    const h = t => screen(`<section class="pl">${t}</section>`);
    if (s.status === 'lobby') {
      h(`<p class="eyebrow">Salle d'attente</p><h2 class="giant">${esc(s.code)}</h2><p class="sub">En attente du démarrage…</p><p class="hint">${esc(s.player_name || '')}</p>`);
    } else if (s.status === 'question') {
      h(`<div class="qtop"><span>Question ${s.pos} / ${s.total}</span><span class="timer" id="tm"></span></div><div class="prog"><i id="pg"></i></div>
        <div id="lead" class="lead" hidden></div>
        <h2 class="qp">${esc(s.question.prompt)}</h2>
        <div class="grid n${s.question.options.length}" id="ch">${choiceBtns(locked, mine)}</div>
        <p class="hint" id="hint">${locked ? 'Réponse enregistrée' : 'Touchez pour répondre'}</p>`);
      $('#ch').onclick = async e => {
        const b = e.target.closest('[data-i]'); if (!b || locked) return;
        const i = +b.dataset.i;
        locked = true; mine = i; document.querySelectorAll('.ans').forEach(x => { x.disabled = true; x.toggleAttribute('data-mine', +x.dataset.i === i); });
        $('#hint').textContent = 'Réponse enregistrée';
        try { await rpc('submit_answer', { p_player: P.player_id, p_choice: i }); L.tick(); } catch (er) { locked = false; mine = null; toast('Envoi impossible'); render(); }
      };
      const loop = () => { qDyn(); raf = requestAnimationFrame(loop); }; loop();
    } else if (s.status === 'results') {
      const correct = s.question.correct, ok = mine === correct;
      h(`<p class="eyebrow">Question ${s.pos} / ${s.total}</p><h2>${ok ? 'Bonne réponse !' : (mine == null ? 'Temps écoulé' : 'Mauvaise réponse')}</h2>
        <div class="grid n${s.question.options.length} hb">${s.question.options.map((o, i) => `<div class="ans${i !== correct ? ' dim' : ' win'}" style="background:${COLS[i].c}">${shape(i)}<span>${esc(o)}</span></div>`).join('')}</div>
        ${s.question.explanation ? `<p class="expl">${esc(s.question.explanation)}</p>` : ''}
        <p class="sub">${s.my_points != null ? `+${s.my_points} pts` : ''} · Total : <b>${s.my_total || 0}</b></p>
        <p class="hint">En attente de la suite…</p>`);
    } else if (s.status === 'scores') {
      const lb = asArr(s.leaderboard), me = lb.find(r => r.id === P.player_id);
      const rankLine = (r, meId) => `<div class="rk${r.id === meId ? ' me' : ''}"><span class="rn">${r.rank}</span><span class="nm">${esc(r.name)}</span><span class="pts">${r.points} pts</span></div>`;
      const inTop = lb.slice(0, 8).some(r => r.id === P.player_id);
      h(`<p class="eyebrow">Question ${s.pos} / ${s.total}</p><h2>Classement</h2><div class="ranks">${lb.slice(0, 8).map(r => rankLine(r, P.player_id)).join('')}${!inTop && me ? '<div class="dots2">…</div>' + rankLine(me, P.player_id) : ''}</div><p class="hint">En attente de la suite…</p>`);
    } else if (s.status === 'finished') {
      const lb = asArr(s.leaderboard), me = lb.find(r => r.id === P.player_id);
      const rankLine = (r, meId) => `<div class="rk${r.id === meId ? ' me' : ''}"><span class="rn">${r.rank}</span><span class="nm">${esc(r.name)}</span><span class="pts">${r.points} pts</span></div>`;
      h(`<h2>Classement final</h2><div class="podium">${[1, 0, 2].map(i => lb[i] ? `<div class="pd p${i}"><span>${esc(lb[i].name)}</span><div>${lb[i].rank}</div><small>${lb[i].points} pts</small></div>` : '<div class="pd"></div>').join('')}</div>
        ${me ? `<p class="sub">Vous : <b>#${me.rank}</b> · ${me.points} pts</p>` : ''}
        <div class="ranks">${lb.map(r => rankLine(r, P.player_id)).join('')}</div><button class="btn" id="q">Quitter</button>`);
      $('#q').onclick = () => { localStorage.removeItem(LSP); location.hash = '#/'; };
    }
  }
}
