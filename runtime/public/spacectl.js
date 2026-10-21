// Runs, workers and operations through admin commands (docs/betrieb-und-mobile-steuerung.md §7.2 in pi-spaces).
// Every action keeps its command ID; polling runs only while the page is visible; data is rendered as text only.
import { initApi, postJson } from './api.js';
import { renderMenu } from './menu.js';
initApi(renderMenu());
const message = document.getElementById('ctl-message');
const el = (tag, text, cls) => { const e = document.createElement(tag); if (text !== undefined) e.textContent = text; if (cls) e.className = cls; return e; };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const FINAL = ['completed', 'failed', 'duplicate'];

// The bridge serves one space operation at a time; page calls queue up instead of failing with "in progress".
let queue = Promise.resolve();
function api(method, body = {}) { const next = queue.then(() => request(method, body)); queue = next.catch(() => {}); return next; }
async function request(method, body) {
  const reply = await postJson('/api/spaces/' + method, body);
  if (reply.error) throw new Error(reply.error); return reply;
}
/** Sends one admin command (or resends a known one) and waits for its result while the page is visible. */
async function command(kind, args = {}, commandId) {
  const buttons = [...document.querySelectorAll('button')]; buttons.forEach(b => b.disabled = true);
  message.textContent = 'Auftrag wird gesendet …';
  try {
    const sent = await api('admin', { kind, args, ...(commandId ? { commandId } : {}) });
    let result = sent.result, id = sent.operation.commandId;
    message.textContent = `Auftrag ${id} angenommen, Ergebnis ausstehend …`;
    for (let i = 0; !result && i < 30; i++) {
      if (document.visibilityState !== 'visible') { message.textContent = `Auftrag ${id} läuft auf dem Koordinator weiter; Ergebnis unter Vorgänge.`; return null; }
      await sleep(1000); result = (await api('result', { commandId: id })).result;
    }
    if (!result) { message.textContent = `Ausgang wird geprüft (${id}). Bitte nicht neu starten, sondern unter Vorgänge erneut abfragen.`; return null; }
    const failed = result.state !== 'completed' || result.result?.phase === 'failed';
    message.textContent = failed ? `Abgelehnt: ${result.error ?? result.result?.error ?? result.state}` : `Erledigt (${id})`;
    return failed ? null : result.result;
  } catch (error) { message.textContent = error.message; return null; }
  finally { buttons.forEach(b => b.disabled = false); }
}
const confirmDestructive = text => window.confirm(text);

function renderOperations(list) {
  const root = document.getElementById('operations'); root.replaceChildren();
  if (!list.length) root.append(el('p', 'Keine Vorgänge auf diesem Gerät.', 'key-empty'));
  for (const op of list) {
    const card = el('div', undefined, 'card');
    card.append(el('div', `${op.kind} · ${op.state}`), el('small', `${op.commandId} · ${new Date(op.at).toLocaleString()}`));
    if (op.result?.error || op.result?.result?.error) card.append(el('div', op.result.error ?? op.result.result.error));
    if (!FINAL.includes(op.state)) {
      const again = el('button', 'Gleichen Auftrag erneut senden');
      again.addEventListener('click', () => command(op.kind, op.args, op.commandId).then(load.operations));
      card.append(again);
    }
    root.append(card);
  }
}
function runCard(run) {
  const card = el('div', undefined, 'card');
  card.append(el('div', `${run.runId} · ${run.state} · Revision ${run.revision}`), el('small', `Members: ${run.members.join(', ')}`));
  if (run.pending) card.append(el('small', `Offen: ${run.pending.kind} r${run.pending.revision}; bestätigt ${run.pending.applied.length}/${run.members.length}${run.pending.missing.length ? ', fehlend: ' + run.pending.missing.join(', ') : ''}`));
  if (run.recovery) card.append(el('small', `Recovery ${run.recovery.id}: ${run.recovery.stage}${run.recovery.abandoned ? `, geparkt: ${run.recovery.abandoned.kind} r${run.recovery.abandoned.revision}` : ''}`));
  const actions = [];
  if (run.state === 'running') actions.push(['Pausieren', 'pauseRun']);
  if (run.state === 'paused') actions.push(['Fortsetzen', 'resumeRun']);
  if (['running', 'paused', 'preparing'].includes(run.state)) actions.push(['Lauf stoppen', 'stopRun', true]); // other states finish their transition first
  if (run.state === 'pauseIncomplete' || run.state === 'pausing' || run.state === 'resuming') actions.push(['Status abfragen', 'runStatus']);
  const exp = el('button', 'Ergebnis ansehen');
  exp.addEventListener('click', async () => {
    const r = await command('exportRun', { runId: run.runId }); if (!r) return;
    const box = el('small', `${r.complete ? 'Vollständig' : 'TEILRESULTAT'}: ${r.found}/${r.expected} Teile${r.missing.length ? ', fehlend z. B. ' + r.missing.slice(0, 3).join(', ') : ''} · ${JSON.stringify(r.summary)} · Manifest ${r.manifestHash.slice(0, 12)}… · Ergebnis ${r.resultHash.slice(0, 12)}…`);
    card.append(box);
  });
  card.append(exp);
  if (run.state === 'running' || run.state === 'paused') {
    const plan = el('button', run.state === 'running' ? 'Pause planen' : 'Fortsetzen planen');
    plan.addEventListener('click', async () => {
      const when = window.prompt('Zeitpunkt (JJJJ-MM-TT HH:MM, lokale Zeit)'); if (!when) return;
      const at = new Date(when.replace(' ', 'T')).getTime(); if (!Number.isFinite(at)) { message.textContent = 'Ungültiger Zeitpunkt'; return; }
      const r = await command('scheduleRun', { runId: run.runId, kind: run.state === 'running' ? 'pause' : 'resume', at });
      if (r) message.textContent = `Geplant: ${r.schedules.map(s => `${s.kind} ${new Date(s.at).toLocaleString()}`).join(', ')}`;
    });
    card.append(plan);
  }
  for (const [label, kind, destructive] of actions) {
    const b = el('button', label);
    b.addEventListener('click', async () => {
      if (destructive) {
        // Plan preview first: the coordinator says whether the stop is accepted now and with which revision.
        const preview = await command(kind, { runId: run.runId, dryRun: true });
        if (!preview) return;
        if (!preview.allowed) { message.textContent = `Nicht möglich: ${preview.reason}`; return; }
        if (!confirmDestructive(`Lauf ${run.runId} mit Revision ${preview.revision} endgültig stoppen? Er kann nicht wieder gestartet werden.`)) return;
      }
      await command(kind, { runId: run.runId }); load.runs();
    });
    card.append(b);
  }
  if (run.state === 'needsReview' && run.recovery?.viewHash) {
    card.append(el('small', `Geprüfter Stand ${run.recovery.viewHash.slice(0, 12)}…: ${Object.entries(run.recovery.views ?? {}).map(([m, v]) => `${m}: ${v.gate?.state ?? 'fehlt'}${v.fence ? ' (offen ' + v.fence.kind + ')' : ''}${v.stopped ? ', gestoppt' : ''}`).join('; ')}`));
    for (const [label, decision] of [['Als pausiert festlegen', 'pause'], ['Endgültig stoppen', 'stop'], ['Fortsetzen (nach Pause-Barriere)', 'resume']]) {
      const b = el('button', label);
      b.addEventListener('click', async () => { if (!confirmDestructive(`Recovery-Entscheidung "${decision}" für ${run.runId} an den geprüften Stand binden?`)) return; await command('resolveRunRecovery', { runId: run.runId, expectedViewHash: run.recovery.viewHash, decision }); load.runs(); });
      card.append(b);
    }
  }
  return card;
}
function renderWorkers(data) {
  const root = document.getElementById('workers'); root.replaceChildren();
  if (!data.assignments.length) root.append(el('p', 'Keine Zuweisungen.', 'key-empty'));
  for (const a of data.assignments) {
    const applied = data.applied?.[a.hostId], state = applied?.workers?.assignments?.[a.assignmentId];
    const card = el('div', undefined, 'card');
    card.append(el('div', `${a.assignmentId} · ${a.kind} · gewünscht ${a.count}`), el('small', `Host ${a.hostId} · Space ${a.targetSpace}${a.runId ? ' · Lauf ' + a.runId : ''} · Generation ${a.generation}`));
    card.append(el('small', applied ? `Gemeldet ${new Date(applied.at).toLocaleTimeString()}: aktiv ${state?.active ?? 0}, beendend ${state?.stopping ?? 0}, Tasks ${state?.tasks ?? 0}${state?.rejected ? ', abgelehnt: ' + state.rejected : ''}${applied.workers.generation < a.generation ? ' (Änderung noch nicht übernommen)' : ''}` : 'Kein Bericht des Hosts; „offline“ beweist nicht, dass Worker beendet sind.'));
    root.append(card);
  }
}
function renderAlerts(list) {
  const root = document.getElementById('alerts'); root.replaceChildren();
  if (!list.length) root.append(el('p', 'Keine Hinweise. Das ist kein Beweis, dass alles läuft: offline gemeldete Hosts erscheinen erst nach Ablauf ihres Heartbeats.', 'key-empty'));
  for (const a of list) { const card = el('div', undefined, 'card'); card.append(el('div', `${a.severity === 'critical' ? 'Kritisch' : 'Hinweis'} · ${a.source} · ${a.subject}`), el('small', a.message)); root.append(card); }
}
function renderAudit(list) {
  const root = document.getElementById('audit'); root.replaceChildren();
  for (const r of list) { const card = el('div', undefined, 'card'); card.append(el('div', `${r.kind} · ${r.state} · ${r.requestedBy}`), el('small', `${new Date(r.at).toLocaleString()} · ${r.commandId}${r.error ? ' · ' + r.error : ''}`)); root.append(card); }
}
const load = {
  async alerts() { const list = await command('listAlerts'); if (list) renderAlerts(list); },
  async audit() { const list = await command('auditLog', { limit: 50 }); if (list) renderAudit(list); },
  async operations() { try { renderOperations((await api('operations')).operations); } catch (e) { message.textContent = e.message; } },
  async runs() { const runs = await command('listRuns', { limit: 50 }); if (runs) { const root = document.getElementById('runs'); root.replaceChildren(...(runs.length ? runs.map(runCard) : [el('p', 'Keine Läufe.', 'key-empty')])); } },
  async workers() { const data = await command('listWorkers'); if (data) renderWorkers(data); },
};
for (const b of document.querySelectorAll('[data-load]')) b.addEventListener('click', () => load[b.dataset.load]());
document.getElementById('sieve').addEventListener('submit', async event => {
  event.preventDefault(); const f = Object.fromEntries(new FormData(event.target));
  const config = { runId: f.runId, start: Number(f.start), end: Number(f.end), blockSize: Number(f.blockSize) };
  const members = f.members.split(',').map(s => s.trim()).filter(Boolean);
  if (await command('startRun', { runId: f.runId, kind: 'sieve', config, members })) load.runs();
});
document.getElementById('setworkers').addEventListener('submit', async event => {
  event.preventDefault(); const f = Object.fromEntries(new FormData(event.target));
  if (Number(f.count) === 0 && !confirmDestructive(`Alle Worker von ${f.assignmentId} nach ihrem laufenden Task stoppen?`)) return;
  if (await command('setWorkers', { assignmentId: f.assignmentId, hostId: f.hostId, kind: f.kind, targetSpace: f.targetSpace, count: Number(f.count), ...(f.runId ? { runId: f.runId } : {}) })) load.workers();
});
document.getElementById('space-create').addEventListener('submit', async event => {
  event.preventDefault(); const f = Object.fromEntries(new FormData(event.target));
  const r = await command('createSpace', { hostId: f.hostId, alias: f.alias });
  if (r) message.textContent = `${r.existed ? 'Wiederverwendet' : 'Angelegt'}: ${r.alias} = ${r.spaceId}`;
});
document.getElementById('space-change').addEventListener('submit', async event => {
  event.preventDefault(); const kind = event.submitter?.value, f = Object.fromEntries(new FormData(event.target));
  if (kind === 'deleteSpace' && !confirmDestructive(`Space ${f.spaceId} löschen? Nur ein archivierter, leerer Space ohne Mitgliedschaft wird gelöscht; die ID bleibt reserviert.`)) return;
  const r = await command(kind, { hostId: f.hostId, spaceId: f.spaceId });
  if (r) message.textContent = `${r.alias}: ${r.state}`;
});
document.getElementById('deployment').addEventListener('submit', async event => {
  event.preventDefault(); const kind = event.submitter?.value, root = document.getElementById('deployment-result'); root.replaceChildren();
  let config; try { config = JSON.parse(new FormData(event.target).get('config')); } catch { message.textContent = 'Config ist kein gültiges JSON'; return; }
  const r = await command(kind, kind === 'planDeployment' ? { config } : { deployment: config.deployment }); if (!r) return;
  if (kind === 'planDeployment') { root.append(el('div', r.ready ? 'Plan bereit' : 'Plan blockiert', 'card')); for (const s of r.steps) root.append(el('small', `${s.status} · ${s.key} · ${s.detail}`)); }
  else root.append(el('pre', JSON.stringify(r, null, 2)));
});
load.operations();
