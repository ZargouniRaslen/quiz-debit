'use strict';
/* QR code de la salle d'attente : mène directement à la partie (#/join/CODE) */
function joinUrl(code) { return location.origin + location.pathname + '#/join/' + code; }
function qrSvg(text) {
  const q = qrcode(0, 'M'); q.addData(text); q.make();
  const n = q.getModuleCount(), m = 4; let d = '';
  for (let r = 0; r < n; r++) for (let c = 0; c < n; c++) if (q.isDark(r, c)) d += `M${c + m} ${r + m}h1v1h-1z`;
  const w = n + m * 2;
  return `<svg viewBox="0 0 ${w} ${w}" shape-rendering="crispEdges" role="img" aria-label="QR code pour rejoindre la partie"><rect width="${w}" height="${w}" fill="#fff"/><path d="${d}" fill="#1a1a1a"/></svg>`;
}
function qrBlock(code) {
  try { return `<figure class="qr">${qrSvg(joinUrl(code))}<figcaption>Scannez pour rejoindre</figcaption></figure>`; } catch (e) { return ''; }
}
function host(sid) {
  let cerCtl = null, key = '', st = null, raf = null, adv = false, prevCount = -1, prevRank = {};
  const step = async (from, pos) => { if (adv) return; adv = true; try { await rpc('host_advance', { p_session: sid, p_from: from, p_from_pos: pos }); L.tick(); L.refresh(); } catch (e) { toast(has(e, 'no_players') ? 'Aucun joueur' : 'Erreur'); } adv = false; };
  const L = live(sid, () => rpc('host_state', { p_session: sid }), (s, err) => {
    if (!s) { if (err && has(err, 'forbidden')) location.hash = '#/admin/dashboard'; return; }
    st = s; const k = s.status + ':' + s.pos;
    if (k !== key) { key = k; prevCount = -1; adv = false; render(); }
    else if (s.status === 'lobby') lobbyDyn(); else if (s.status === 'question') qDyn();
  }, 1000);
  onLeave(() => { cancelAnimationFrame(raf); document.onkeydown = null; });
  const blocks = (opts, correct, counts) => `<div class="grid n${opts.length} hb">${opts.map((o, i) => `<div class="ans${correct != null && i !== correct ? ' dim' : ''}" style="background:${COLS[i].c}">${shape(i)}<span>${esc(o)}</span>${counts ? `<em>${counts[i] || 0}</em>` : ''}</div>`).join('')}</div>`;
  const foot = () => `<footer class="hfoot">Code : <b>${st.code}</b> · Question ${st.pos} / ${st.total}</footer>`;
  document.onkeydown = e => { if ((e.code === 'Space' || e.key === 'ArrowRight') && st && ['lobby', 'results', 'scores'].includes(st.status)) { e.preventDefault(); step(st.status, st.pos); } else if ((e.code === 'Space' || e.key === 'ArrowRight') && st && st.status === 'finished' && cerCtl) { e.preventDefault(); cerCtl.next(); } };
  function lobbyDyn() {
    $('#pc').textContent = st.player_count + ' joueur' + (st.player_count > 1 ? 's' : ''); $('#go').disabled = !st.player_count;
    $('#chips').innerHTML = st.players.map(p => `<span class="chip">${esc(p.name)}<button data-k="${p.id}" aria-label="Retirer">✕</button></span>`).join('');
  }
  function qDyn() {
    if (st.answered_count !== prevCount) { const el = $('#ac'); el.textContent = `${st.answered_count} / ${st.player_count} ont répondu`; el.classList.remove('bump'); void el.offsetWidth; el.classList.add('bump'); prevCount = st.answered_count; }
    /* même si tout le monde a répondu, on attend la fin du compte à rebours (ou « Passer le temps ») */
  }
  function render() {
    cancelAnimationFrame(raf); const s = st;
    const H = t => screen(`<section class="host">${t}</section>`);
    if (s.status === 'lobby') {
      H(`<p class="eyebrow">Rejoignez sur ${esc(location.hostname || 'ce site')}</p><div class="jn"><div class="giant" aria-label="Code de la partie">${s.code}</div>${qrBlock(s.code)}</div><h2 id="pc"></h2><div id="chips" class="chips"></div>
        <button class="btn big" id="go">Démarrer</button> <button class="ghost" id="cx">Annuler la partie</button>`);
      lobbyDyn();
      $('#go').onclick = () => step('lobby', 0);
      $('#chips').onclick = async e => { const b = e.target.closest('[data-k]'); if (b) { await rpc('kick_player', { p_player: b.dataset.k }); L.refresh(); } };
      $('#cx').onclick = async () => { if (await confirmBox('Annuler la partie ?')) { await rpc('end_session', { p_session: sid }); location.hash = '#/admin/dashboard'; } };
    } else if (s.status === 'question') {
      H(`<div class="qtop"><span>Question ${s.pos} / ${s.total}</span><span class="timer big" id="tm"></span></div><div class="prog"><i id="pg"></i></div><div id="lead" class="lead" hidden></div>
        <h2 class="qp">${esc(s.question.prompt)}</h2>${blocks(s.question.options)}<div class="acnt" id="ac"></div><button class="ghost" id="sk">Passer le temps</button>${foot()}`);
      $('#sk').onclick = () => step('question', s.pos); qDyn();
      const total = Date.parse(s.ends_at) - Date.parse(s.starts_at);
      const loop = () => { const n = srvNow(), lead = Date.parse(s.starts_at) - n, rem = Date.parse(s.ends_at) - n;
        $('#lead').hidden = lead <= 0; $('#lead').innerHTML = `<small>Préparez-vous</small><b>${Math.ceil(lead / 1000)}</b>`;
        $('#tm').textContent = lead > 0 ? '' : Math.max(0, Math.ceil(rem / 1000)) + ' s'; $('#pg').style.width = lead > 0 ? '100%' : Math.max(0, rem / total * 100) + '%';
        if (lead <= 0 && rem <= 0) step('question', s.pos); raf = requestAnimationFrame(loop); }; loop();
    } else if (s.status === 'results') {
      const c = s.choice_counts || {}, mx = Math.max(1, ...Object.values(c)), R = s.results || [];
      H(`<h2 class="qp">${esc(s.question.prompt)}</h2>${blocks(s.question.options, s.correct, c)}
        <div class="bars">${s.question.options.map((o, i) => `<div class="br"><i style="background:${COLS[i].c};width:${(c[i] || 0) / mx * 100}%"></i><b>${c[i] || 0}</b></div>`).join('')}</div>
        ${s.explanation ? `<p class="expl">${esc(s.explanation)}</p>` : ''}
        <div class="ranks">${R.map((r, i) => `<div class="rank${r.is_correct ? '' : ' x'}"><b>${r.is_correct ? R.filter(x => x.is_correct).indexOf(r) + 1 : '–'}</b><span>${esc(r.name)} <small>${r.choice == null ? 'Sans réponse' : COLS[r.choice].n}</small></span><em>${r.is_correct ? fmtS(r.time_ms) + ' · ' : ''}+${r.points}</em></div>`).join('')}</div>
        <button class="btn big" id="nx">Continuer</button>${foot()}`);
      $('#nx').onclick = () => step('results', s.pos);
    } else if (s.status === 'scores') {
      H(`<h2>Classement</h2><div class="ranks">${s.leaderboard.slice(0, 10).map(r => { const d = prevRank[r.player_id] == null ? 0 : prevRank[r.player_id] - r.rank; return `<div class="rank"><b>${r.rank}</b><span>${esc(r.name)} ${d > 0 ? '<small class="up">▲' + d + '</small>' : d < 0 ? '<small class="dn">▼' + -d + '</small>' : ''}</span><em>${r.points} pts</em></div>`; }).join('')}</div><button class="btn big" id="nx">Continuer</button>${foot()}`);
      prevRank = Object.fromEntries(s.leaderboard.map(r => [r.player_id, r.rank]));
      $('#nx').onclick = () => step('scores', s.pos);
    } else if (s.status === 'finished') {
      const lb = s.leaderboard || [];
      H(`<h2>Classement final</h2><div id="cerhost"></div>
        <div id="finbody" hidden>
          <table class="tbl"><tr><th>Rang</th><th>Nom(s)</th><th>Points</th><th>Bonnes</th><th>Temps</th></tr>${lb.map(r => `<tr><td>${r.rank}</td><td>${esc(r.name)}</td><td>${r.points}</td><td>${r.correct} / ${s.total}</td><td>${fmt(r.time_ms)}</td></tr>`).join('')}</table>
          <a class="btn" href="#/admin/report/${sid}">Télécharger le PDF</a>
          <button class="ghost" id="rp">Rejouer la cérémonie</button>
          <a class="ghost" href="#/admin/dashboard">Retour au tableau de bord</a>
        </div>`);
      const showTable = () => { const fb = $('#finbody'); if (fb) fb.hidden = false; };
      cerCtl = runCeremony(lb, showTable);
      onLeave(() => { cerCtl = null; });
      const rp = $('#rp'); if (rp) rp.onclick = () => { $('#finbody').hidden = true; cerCtl = runCeremony(lb, showTable); };
    }
  }
}

const pdfTxt = s => String(s ?? '').replace(/’/g, "'").replace(/œ/g, 'oe').replace(/Œ/g, 'OE').replace(/…/g, '...').replace(/[✓✗]/g, '');
async function report(sid) {
  screen(`<section class="adm"><div class="load"><div class="spin"></div></div></section>`);
  let R; try { R = await rpc('session_report', { p_session: sid }); } catch (e) { toast('Erreur'); location.hash = '#/admin/dashboard'; return; }
  screen(`<section class="adm">${adminHead()}<h2>${esc(R.title)}</h2><p class="sub">Code ${R.session.code} · ${R.leaderboard.length} groupe(s)</p>
    <table class="tbl"><tr><th>Rang</th><th>Nom(s)</th><th>Bonnes</th><th>Temps</th><th>Points</th></tr>${R.leaderboard.map(r => `<tr><td>${r.rank}</td><td>${esc(r.name)}</td><td>${r.correct} / ${R.questions.length}</td><td>${fmt(r.time_ms)}</td><td>${r.points}</td></tr>`).join('')}</table>
    <label class="tl"><input type="checkbox" id="dt" checked> Inclure le détail par groupe</label><br><button class="btn" id="pdf">Télécharger le PDF</button> <button class="ghost" onclick="print()">Imprimer</button> <a class="ghost" href="#/admin/dashboard">Retour</a></section>`);
  bindLogout(); $('#pdf').onclick = () => makePdf(R, $('#dt').checked);
}
function makePdf(R, detail) {
  const doc = new jspdf.jsPDF({ unit: 'mm', format: 'a4' }), T = R.questions.length, d0 = new Date(R.session.created_at), date = d0.toLocaleDateString('fr-FR');
  const head = { fillColor: [15, 30, 43] };
  doc.setFontSize(18); doc.text(pdfTxt(R.title), 14, 20); doc.setFontSize(10);
  doc.text(`${date} - Code ${R.session.code} - ${R.leaderboard.length} groupe(s)`, 14, 27);
  doc.autoTable({ startY: 33, head: [['Rang', 'Nom(s)', `Bonnes reponses (x/${T})`, 'Temps total', 'Points']], headStyles: head,
    body: R.leaderboard.map(r => [r.rank, pdfTxt(r.name), `${r.correct}/${T}`, fmt(r.time_ms), r.points]), styles: { overflow: 'linebreak' } });
  if (detail) R.leaderboard.forEach(p => {
    doc.addPage(); doc.setFontSize(14); doc.text(`${p.rank}. ${pdfTxt(p.name)}`, 14, 20); doc.setFontSize(10);
    doc.text(`${p.points} points - ${p.correct}/${T} bonnes - ${fmt(p.time_ms)}`, 14, 27);
    const A = R.answers.filter(a => a.player_id === p.player_id);
    doc.autoTable({ startY: 33, head: [['Question', 'Reponse donnee', 'Resultat', 'Temps (s)', 'Points']], headStyles: head, styles: { overflow: 'linebreak' },
      body: R.questions.map(q => { const a = A.find(x => x.pos === q.pos) || {}; let t = pdfTxt(q.prompt); if (t.length > 60) t = t.slice(0, 57) + '...';
        return [`${q.pos}. ${t}`, a.choice == null ? '-' : COLS[a.choice].n, a.choice == null ? '-' : a.is_correct ? 'OK' : 'X', a.time_ms == null ? '-' : (a.time_ms / 1000).toFixed(1).replace('.', ','), a.points ?? 0]; }) });
  });
  const n = doc.getNumberOfPages(); for (let i = 1; i <= n; i++) { doc.setPage(i); doc.setFontSize(8); doc.text(`Page ${i} / ${n} - genere le ${new Date().toLocaleDateString('fr-FR')}`, 105, 290, { align: 'center' }); }
  doc.save(`resultats-${R.session.code}-${d0.toISOString().slice(0, 10)}.pdf`);
}
