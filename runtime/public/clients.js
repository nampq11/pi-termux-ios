import { authUrl, getJson, initApi, postJson } from './api.js';
import { API } from './constants.js';
import { renderMenu } from './menu.js';

initApi(renderMenu());
const list = document.getElementById('client-list');
const msg = document.getElementById('msg');
const addForm = document.getElementById('add-form');
document.getElementById('add-toggle')?.addEventListener('click', () => {
  addForm.classList.toggle('hidden');
});

// --- ssh key ----------------------------------------------------------------

async function loadKey() {
  const j = await getJson(API.sshkey);
  document.getElementById('sshkey-status').textContent = j.exists
    ? 'key exists (ed25519)'
    : 'no key yet';
  const pub = document.getElementById('sshkey-pub');
  if (j.pubkey) { pub.textContent = j.pubkey; pub.classList.remove('hidden'); }
  document.getElementById('sshkey-gen').classList.toggle('hidden', !!j.exists);
}
document.getElementById('sshkey-gen').addEventListener('click', async () => {
  msg.textContent = 'generating…';
  const j = await postJson(API.sshkey, {});
  msg.textContent = j.ok ? 'key generated' : 'error generating key';
  loadKey();
});

// --- hosts -------------------------------------------------------------------

async function load() {
  const j = await getJson(API.clients);
  list.innerHTML = '';
  if (!j.clients?.length) {
    list.innerHTML = '<div class="key-empty">no hosts yet — add one below</div>';
    return;
  }
  for (const c of j.clients) {
    const row = document.createElement('div');
    row.className = 'key-row';
    const name = document.createElement('span');
    name.className = 'key-name';
    name.textContent = c.name;
    const tgt = document.createElement('span');
    tgt.className = 'key-hint';
    tgt.textContent = c.target;

    const go = document.createElement('button');
    go.textContent = '▸_';
    go.title = 'connect (pi cli)';
    go.addEventListener('click', () => {
      location.href = authUrl('/terminal.html', { ssh: c.target });
    });

    const copy = document.createElement('button');
    copy.textContent = '⇧key';
    copy.title = 'copy ssh key (ssh-copy-id)';
    copy.addEventListener('click', () => {
      location.href = authUrl('/terminal.html', { ssh: c.target, sshop: 'copyid' });
    });

    const del = document.createElement('button');
    del.textContent = '✕';
    del.className = 'key-del';
    del.addEventListener('click', async () => {
      await postJson(API.clients, { delete: c.name });
      load();
    });

    row.append(name, tgt, go, copy, del);
    list.appendChild(row);
  }
}

document.getElementById('add-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const name = document.getElementById('add-name').value.trim();
  const target = document.getElementById('add-target').value.trim();
  if (!target) return;
  const j = await postJson(API.clients, { name, target });
  if (!j.ok) { msg.textContent = `error: ${j.error}`; return; }
  msg.textContent = 'added';
  document.getElementById('add-name').value = '';
  document.getElementById('add-target').value = '';
  load();
  addForm.classList.add('hidden');
  // auto-flow: ensure key exists, then offer interactive ssh-copy-id
  const k = await getJson(API.sshkey);
  if (!k.exists) await postJson(API.sshkey, {});
  location.href = authUrl('/terminal.html', { ssh: target, sshop: 'copyid' });
});

loadKey();
load();
