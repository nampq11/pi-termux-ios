import { authUrl, getJson, initApi, postJson } from './api.js';
import { API } from './constants.js';
import { renderMenu } from './menu.js';

initApi(renderMenu());
const list = document.getElementById('session-list');
const msg = document.getElementById('msg');

const goChat = (r) => { if (r.ok) location.href = authUrl('/'); else msg.textContent = `error: ${r.error}`; };

document.getElementById('new-session').addEventListener('click', async () => {
  const name = prompt('Session name (optional):', '') ?? null;
  if (name === null) return;
  goChat(await postJson(API.sessionNew, { name }));
});

function button(text, title, onClick, cls) {
  const b = document.createElement('button');
  b.textContent = text;
  b.title = title;
  if (cls) b.className = cls;
  b.addEventListener('click', onClick);
  return b;
}

async function load() {
  const data = await getJson(API.sessions);
  list.innerHTML = '';
  for (const session of data.sessions ?? []) {
    const label = session.name || `Session ${session.id}`;
    const row = document.createElement('div');
    row.className = 'key-row';
    const name = document.createElement('span');
    name.className = 'key-name';
    name.textContent = label;
    const hint = document.createElement('span');
    hint.className = 'key-hint';
    hint.textContent = session.id === data.activeId ? 'active' : `#${session.id}`;
    row.append(name, hint);
    if (session.id !== data.activeId) {
      row.append(button('open', 'Open this session', async () => goChat(await postJson(API.sessionSelect, { id: session.id }))));
    }
    row.append(button('⑂', 'Fork: new session continuing from this one', async () => goChat(await postJson(API.sessionFork, { id: session.id }))));
    row.append(button('✎', 'Rename', async () => {
      const next = prompt('Session name:', label);
      if (next === null) return;
      const r = await postJson(API.sessionRename, { id: session.id, name: next });
      if (r.ok) load(); else msg.textContent = `error: ${r.error}`;
    }));
    row.append(button('✕', 'Stop and remove from session list (transcript is kept)', async () => {
      if (!confirm(`Stop and remove ${label}?`)) return;
      const r = await postJson(API.sessionDelete, { id: session.id });
      if (r.ok) load(); else msg.textContent = `error: ${r.error}`;
    }, 'key-del'));
    list.append(row);
  }
  if (!list.children.length) list.innerHTML = '<div class="key-empty">no sessions</div>';
}

load();
