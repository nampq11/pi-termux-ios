import { authUrl, getJson, initApi, postJson } from './api.js';
import { wireComposer } from './composer.js';
import { API } from './constants.js';
import { renderMenu } from './menu.js';
import { Transcript, usageText } from './transcript.js';

initApi(renderMenu());

const chat = document.getElementById('chat');
const input = document.getElementById('input');
const statusEl = document.getElementById('status');
const sessionNameEl = document.getElementById('session-name');
const sessionLink = document.getElementById('session-link');
const usageEl = document.getElementById('session-usage');
const steerWrap = document.getElementById('steer-wrap');
const steerBox = document.getElementById('steer');
const modelSelect = document.getElementById('model-select');
const btnAbort   = document.getElementById('btn-abort');
const btnCompact = document.getElementById('btn-compact');
const btnNew     = document.getElementById('btn-new');

let busy = false;
let queued = 0;
let currentModel = null;

function status(t) { statusEl.textContent = t; }
function showBusy() {
  status(busy ? `running…${queued ? ` (${queued} queued)` : ''}` : 'idle');
  steerWrap.classList.toggle('hidden', !busy);
}

const transcript = new Transcript(chat, {
  onBusy: (b) => { busy = b; if (btnAbort) btnAbort.classList.toggle('hidden', !b); showBusy(); },
  onModel: (m) => { currentModel = m; syncModelSelect(); },
  onUsage: (u) => { usageEl.textContent = usageText(u); },
  onInbox: (items) => { queued = items.length; showBusy(); },
});

// --- events: every (re)connect gets a fresh snapshot of the current state ----

function connect() {
  const es = new EventSource(authUrl(API.events));
  es.onmessage = (e) => {
    let ev;
    try { ev = JSON.parse(e.data); } catch { return; }
    if (ev.type === 'bridge_snapshot') {
      sessionNameEl.textContent = ev.sessionName || 'Main';
      if (sessionLink) sessionLink.href = authUrl('sessions.html');
      transcript.renderSnapshot(ev.snapshot);
    } else if (ev.type === 'bridge_error') {
      transcript.sys(`error: ${ev.error}`);
    } else if (ev.type !== 'bridge_connected') {
      transcript.handleEvent(ev);
    }
  };
  es.onerror = () => status('reconnecting…');
}

// --- composer: requestId makes a retried prompt exactly-once ------------------

wireComposer({
  form: document.getElementById('composer'),
  input,
  transcript,
  steerBox,
  isBusy: () => busy,
  endpoint: API.prompt,
  retries: 3,
});

// --- model picker ------------------------------------------------------------

function syncModelSelect() {
  if (!currentModel) { modelSelect.value = ''; return; }
  const v = `${currentModel.provider}|${currentModel.modelId}`;
  if (![...modelSelect.options].some((o) => o.value === v)) {
    const o = document.createElement('option');
    o.value = v;
    o.textContent = `${currentModel.provider}/${currentModel.modelId}`;
    modelSelect.appendChild(o);
  }
  modelSelect.value = v;
}

async function refreshModels() {
  const j = await getJson(API.models);
  if (j.error) return; // keep the last known list; the SSE snapshot re-syncs the selection
  modelSelect.innerHTML = '<option value="">no model</option>';
  for (const m of j.models ?? []) {
    const o = document.createElement('option');
    o.value = `${m.provider}|${m.modelId}`;
    o.textContent = `${m.provider}/${m.modelId}`;
    modelSelect.appendChild(o);
  }
  syncModelSelect();
}

modelSelect.addEventListener('change', async () => {
  const [provider, modelId] = modelSelect.value.split('|');
  if (!modelId) return;
  const r = await postJson(API.model, { provider, modelId });
  if (!r.ok) transcript.sys(`error: ${r.error}`);
});

// ── Header action buttons ────────────────────────────────────────────────
if (btnAbort)   btnAbort.addEventListener('click',   () => postJson(API.abort));
if (btnCompact) btnCompact.addEventListener('click', async () => {
  const r = await postJson(API.compact, {});
  if (!r.ok && r.error) transcript.sys(`error: ${r.error}`);
});
if (btnNew) btnNew.addEventListener('click', async () => {
  const name = prompt('Session name (optional):') ?? null;
  if (name === null) return;
  const r = await postJson(API.sessionNew, { name });
  if (r.ok) location.href = authUrl('/');
  else transcript.sys(`error: ${r.error}`);
});

connect();
refreshModels();
