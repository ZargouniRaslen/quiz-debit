'use strict';
/* Cérémonie de remise des prix (écran animateur) : 3e → 2e → 1er avec animation simple */
function runCeremony(lb, onDone) {
  const top = [lb[2], lb[1], lb[0]].filter(Boolean); // 3rd, 2nd, 1st if present
  let step = 0;
  const medals = [
    { n: 3, cls: 'bronze', fr: 'Troisième place', color: '#CD7F32' },
    { n: 2, cls: 'silver', fr: 'Deuxième place', color: '#C0C0C0' },
    { n: 1, cls: 'gold', fr: 'Première place', color: '#FFD700' }
  ];
  const stage = document.createElement('div');
  stage.className = 'ceremony';
  document.body.append(stage);

  function info(r) {
    return `<div class="ci"><b>${esc(r.name)}</b><span>${r.points} pts · ${r.correct || 0} bonnes</span></div>`;
  }

  function show() {
    if (step >= top.length) {
      stage.classList.add('done');
      setTimeout(() => { stage.remove(); if (onDone) onDone(); }, 800);
      return;
    }
    const r = top[step];
    const m = medals[step];
    stage.innerHTML = `<div class="cer-card ${m.cls}"><div class="medal" style="background:${m.color}">${m.n}</div><p class="rk">${m.fr}</p>${info(r)}</div>`;
    stage.classList.remove('in'); void stage.offsetWidth; stage.classList.add('in');
    step++;
  }

  show();
  const ctl = {
    next() { show(); },
    skip() { stage.remove(); if (onDone) onDone(); }
  };
  return ctl;
}
