// test-server-sessions.mjs — session lifecycle over the real HTTP bridge that
// the iOS app and the web sessions page use: new, rename, list, fork, select,
// delete (inactive, root, and active). Boots server.mjs in a temp HOME with
// the scripted faux model (PI_TEST_FAUX=1) — no network, no model API calls.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';

const root = path.dirname(fileURLToPath(import.meta.url));

async function call(port, token, method, p, body) {
  const r = await fetch(`http://127.0.0.1:${port}${p}`, {
    method,
    headers: { 'content-type': 'application/json', 'x-token': token },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: r.status, data: await r.json() };
}

async function withServer(fn) {
  const home = mkdtempSync(path.join(tmpdir(), 'pi-mobile-sess-'));
  mkdirSync(path.join(home, 'work'), { recursive: true });
  const child = spawn(process.execPath, ['server.mjs'], {
    cwd: root,
    env: { ...process.env, HOME: home, PI_WORKDIR: path.join(home, 'work'), PI_TEST_FAUX: '1' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const logs = [];
  child.stdout.on('data', (d) => logs.push(String(d)));
  child.stderr.on('data', (d) => logs.push(String(d)));
  try {
    const portFile = path.join(home, '.pi-mobile', 'port');
    const tokenFile = path.join(home, '.pi-mobile', 'token');
    let port = 0;
    let token = '';
    for (let i = 0; i < 300 && !port; i++) {
      await sleep(200);
      try {
        port = Number(readFileSync(portFile, 'utf8').trim());
        token = readFileSync(tokenFile, 'utf8').trim();
      } catch {}
    }
    assert.ok(port, `server must write the port file; boot log: ${logs.join('')}`);
    return await fn((method, p, body) => call(port, token, method, p, body));
  } finally {
    child.kill('SIGTERM');
    await sleep(300);
    try { child.kill('SIGKILL'); } catch {}
    rmSync(home, { recursive: true, force: true });
  }
}

test('rename persists in the session list', async () => {
  await withServer(async (call) => {
    const root0 = await call('GET', '/api/sessions');
    assert.equal(root0.status, 200);
    const rootId = String(root0.data.activeId);
    assert.ok(rootId, 'boot must leave a root session active');

    const created = await call('POST', '/api/sessions/new', { name: 'alpha' });
    assert.equal(created.status, 200);
    const alphaId = String(created.data.activeId);
    assert.notEqual(alphaId, rootId);

    const renamed = await call('POST', '/api/sessions/rename', { id: alphaId, name: 'beta' });
    assert.equal(renamed.status, 200, `rename: ${JSON.stringify(renamed.data)}`);
    const list = await call('GET', '/api/sessions');
    const alpha = list.data.sessions.find((s) => String(s.id) === alphaId);
    assert.equal(alpha?.name, 'beta', 'renamed name must show up in the list');
  });
});

test('rename root session works', async () => {
  await withServer(async (call) => {
    const root0 = await call('GET', '/api/sessions');
    const rootId = String(root0.data.activeId);
    const renamed = await call('POST', '/api/sessions/rename', { id: rootId, name: 'home base' });
    assert.equal(renamed.status, 200, `rename root: ${JSON.stringify(renamed.data)}`);
    const list = await call('GET', '/api/sessions');
    const rootEntry = list.data.sessions.find((s) => String(s.id) === rootId);
    assert.equal(rootEntry?.name, 'home base');
  });
});

test('delete removes an inactive session from the list', async () => {
  await withServer(async (call) => {
    const root0 = await call('GET', '/api/sessions');
    const rootId = String(root0.data.activeId);
    const created = await call('POST', '/api/sessions/new', { name: 'doomed' });
    const doomedId = String(created.data.activeId);

    // switch back to root so `doomed` is inactive
    const sel = await call('POST', '/api/sessions/select', { id: rootId });
    assert.equal(sel.status, 200);

    const del = await call('POST', '/api/sessions/delete', { id: doomedId });
    assert.equal(del.status, 200, `delete: ${JSON.stringify(del.data)}`);
    const list = await call('GET', '/api/sessions');
    assert.ok(!list.data.sessions.some((s) => String(s.id) === doomedId), 'deleted session must vanish from the list');
  });
});

test('delete the root session while another is active', async () => {
  await withServer(async (call) => {
    const root0 = await call('GET', '/api/sessions');
    const rootId = String(root0.data.activeId);
    const created = await call('POST', '/api/sessions/new', { name: 'survivor' });
    const survivorId = String(created.data.activeId);

    const del = await call('POST', '/api/sessions/delete', { id: rootId });
    assert.equal(del.status, 200, `delete root: ${JSON.stringify(del.data)}`);
    const list = await call('GET', '/api/sessions');
    assert.ok(!list.data.sessions.some((s) => String(s.id) === rootId), 'deleted root must vanish from the list');
    assert.equal(String(list.data.activeId), survivorId, 'active session must survive the root deletion');
  });
});

test('delete the active session falls back to the Main session', async () => {
  await withServer(async (call) => {
    const root0 = await call('GET', '/api/sessions');
    const rootId = String(root0.data.activeId);
    const created = await call('POST', '/api/sessions/new', { name: 'temp' });
    const tempId = String(created.data.activeId);

    const del = await call('POST', '/api/sessions/delete', { id: tempId });
    assert.equal(del.status, 200, `delete active: ${JSON.stringify(del.data)}`);
    const list = await call('GET', '/api/sessions');
    assert.ok(!list.data.sessions.some((s) => String(s.id) === tempId), 'deleted session must vanish');
    assert.equal(String(list.data.activeId), rootId, 'chat page must land back on Main');
    const rootEntry = list.data.sessions.find((s) => String(s.id) === rootId);
    assert.ok(rootEntry, 'Main must remain in the list');
  });
});

test('fork then delete the fork', async () => {
  await withServer(async (call) => {
    const created = await call('POST', '/api/sessions/new', { name: 'tofork' });
    const srcId = String(created.data.activeId);
    // fork needs at least one entry in the source conversation
    const prompt = await call('POST', '/api/prompt', { message: 'hello' });
    assert.equal(prompt.status, 200);
    const forked = await call('POST', '/api/sessions/fork', { id: srcId });
    assert.equal(forked.status, 200, `fork: ${JSON.stringify(forked.data)}`);
    const forkId = String(forked.data.activeId);

    const sel = await call('POST', '/api/sessions/select', { id: srcId });
    assert.equal(sel.status, 200);
    const del = await call('POST', '/api/sessions/delete', { id: forkId });
    assert.equal(del.status, 200, `delete fork: ${JSON.stringify(del.data)}`);
  });
});

test('unknown session ids are rejected', async () => {
  await withServer(async (call) => {
    const renamed = await call('POST', '/api/sessions/rename', { id: 999999, name: 'x' });
    assert.equal(renamed.status, 404);
    const del = await call('POST', '/api/sessions/delete', { id: 999999 });
    assert.equal(del.status, 404);
    const sel = await call('POST', '/api/sessions/select', { id: 999999 });
    assert.equal(sel.status, 404);
  });
});

test('deleting the active Main keeps it listed and active', async () => {
  await withServer(async (call) => {
    const root0 = await call('GET', '/api/sessions');
    const rootId = String(root0.data.activeId);
    const del = await call('POST', '/api/sessions/delete', { id: rootId });
    assert.equal(del.status, 200, `delete active main: ${JSON.stringify(del.data)}`);
    const list = await call('GET', '/api/sessions');
    const main = list.data.sessions.find((s) => String(s.id) === rootId);
    assert.ok(main, 'Main must stay listed after being deleted while active');
    assert.equal(String(list.data.activeId), rootId);
  });
});

test('renaming with an empty name clears the custom name', async () => {
  await withServer(async (call) => {
    const created = await call('POST', '/api/sessions/new', { name: 'named' });
    const id = String(created.data.activeId);
    const root0 = await call('GET', '/api/sessions');
    const rootId = String(root0.data.activeId);
    await call('POST', '/api/sessions/select', { id: rootId });
    const cleared = await call('POST', '/api/sessions/rename', { id, name: '' });
    assert.equal(cleared.status, 200);
    const list = await call('GET', '/api/sessions');
    const entry = list.data.sessions.find((s) => String(s.id) === id);
    assert.ok(!entry?.name, `name must be cleared, got ${JSON.stringify(entry)}`);
  });
});
