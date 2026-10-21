// Real-behavior tests for the PTY-less key install: an in-process ssh2 server
// with password auth executes the received command via sh in a jailed HOME,
// the way a real host would. This is the wire flow the iOS app relies on.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdirSync, mkdtempSync, existsSync, readFileSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import SSH2 from 'ssh2';
import { jsSshBackend } from './ssh-js-backend.mjs';
import { installDeviceKey } from './ssh-copy-id.mjs';

const PASSWORD = 'hunter2';
const { Server } = SSH2;

/** A password-authenticating SSH "host" whose exec handler runs commands via
 * sh with HOME pointed at the jail. */
async function startHost(jail) {
  // the server host key is a real openssh-format keypair from the backend's
  // own generator — exactly the format ssh2 must parse on both sides
  const hostKeyDir = mkdtempSync(join(tmpdir(), 'copyid-hostkey-'));
  assert.equal(await jsSshBackend.generateKey({ dir: hostKeyDir, comment: 'test host key' }), 0);
  const hostKey = readFileSync(join(hostKeyDir, 'id_ed25519'), 'utf8');
  const server = new Server({ hostKeys: [hostKey] }, (client) => {
    client.on('error', () => {}); // aborted clients must not crash the test
    client.on('authentication', (ctx) => {
      if (ctx.method === 'password' && ctx.password === PASSWORD) ctx.accept();
      else ctx.reject(['password']);
    });
    client.on('session', (accept) => {
      const session = accept();
      session.on('exec', (acceptExec, _reject, info) => {
        const stream = acceptExec();
        const child = spawn('/bin/sh', ['-c', info.command], { env: { HOME: jail, PATH: '/usr/bin:/bin' } });
        child.stdout.on('data', (d) => stream.write(d));
        child.stderr.on('data', (d) => stream.stderr.write(d));
        child.on('error', (e) => { stream.stderr.write(String(e?.message || e)); stream.exit(127); stream.close(); });
        child.on('close', (code) => { stream.exit(code ?? 0); stream.close(); });
      });
    });
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return { server, port: server.address().port, hostKeyDir };
}

/** A device home with a freshly generated device key. */
async function makeDeviceHome() {
  const home = mkdtempSync(join(tmpdir(), 'copyid-home-'));
  mkdirSync(join(home, '.ssh'), { recursive: true });
  assert.equal(await jsSshBackend.generateKey({ dir: join(home, '.ssh'), comment: 'pi-mobile' }), 0);
  const pubkey = readFileSync(join(home, '.ssh', 'id_ed25519.pub'), 'utf8').trim();
  return { home, pubkey };
}

test('installs the device key idempotently and pins the host key on first connect', async () => {
  const { home, pubkey } = await makeDeviceHome();
  const jail = mkdtempSync(join(tmpdir(), 'copyid-jail-'));
  const host = await startHost(jail);
  try {
    const target = { home, host: 'user@127.0.0.1', port: host.port, password: PASSWORD, pubkey };
    assert.deepEqual(await installDeviceKey(target), { ok: true });
    // the second install must not duplicate the key line
    assert.deepEqual(await installDeviceKey(target), { ok: true });

    const keys = join(jail, '.ssh', 'authorized_keys');
    assert.equal(readFileSync(keys, 'utf8'), `${pubkey}\n`);
    assert.equal(statSync(join(jail, '.ssh')).mode & 0o777, 0o700);
    assert.equal(statSync(keys).mode & 0o777, 0o600);

    // accept-new trust: the [host]:port entry was stored on first connect
    const known = readFileSync(join(home, '.ssh', 'known_hosts'), 'utf8');
    assert.match(known, new RegExp(`^\\[127\\.0\\.0\\.1\\]:${host.port} ssh-ed25519 `, 'm'));
  } finally {
    host.server.close();
    for (const d of [home, jail, host.hostKeyDir]) rmSync(d, { recursive: true, force: true });
  }
});

test('a rejected password is reported as authFailed and never touches the host', async () => {
  const { home, pubkey } = await makeDeviceHome();
  const jail = mkdtempSync(join(tmpdir(), 'copyid-jail-'));
  const host = await startHost(jail);
  try {
    const r = await installDeviceKey({ home, host: 'user@127.0.0.1', port: host.port, password: 'wrong', pubkey });
    assert.equal(r.ok, false);
    assert.equal(r.authFailed, true);
    assert.equal(r.error, 'password rejected');
    assert.equal(existsSync(join(jail, '.ssh')), false);
  } finally {
    host.server.close();
    for (const d of [home, jail, host.hostKeyDir]) rmSync(d, { recursive: true, force: true });
  }
});
