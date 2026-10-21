// Real-behavior tests for the SSH-channel pty (iOS terminal path): an
// in-process ssh2 server with pty/window-change/exec session handlers stands
// in for the host. The only stub is the WebSocket at the bridge boundary.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { EventEmitter } from 'node:events';
import { mkdirSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import SSH2 from 'ssh2';
import { jsSshBackend } from './ssh-js-backend.mjs';
import { setSshBackend } from './ssh-transport.mjs';
import { createPtyHandler } from './bridge/pty.mjs';

const { Server } = SSH2;

/** A stand-in host: accepts any auth, grants pty requests, records window
 * changes, and per exec either runs the received command via sh (real
 * behavior) or ignores it and runs `cat` (for commands the test must not
 * execute, like the pi installer script). */
async function startHost({ runReceived }) {
  const hostKeyDir = mkdtempSync(join(tmpdir(), 'shell-hostkey-'));
  assert.equal(await jsSshBackend.generateKey({ dir: hostKeyDir, comment: 'test host key' }), 0);
  const seen = { command: null, windows: [], clients: 0, clientCloses: 0 };
  const server = new Server({ hostKeys: [readFileSync(join(hostKeyDir, 'id_ed25519'), 'utf8')] }, (client) => {
    seen.clients += 1;
    client.on('close', () => { seen.clientCloses += 1; });
    client.on('error', () => {});
    client.on('authentication', (ctx) => ctx.accept());
    client.on('session', (accept) => {
      const session = accept();
      session.on('pty', (acceptPty) => acceptPty());
      // no accept() here: the client sends window-change with want_reply=0,
      // and a reply would be an unsolicited CHANNEL_SUCCESS that kills the
      // channel (real OpenSSH never replies to window-change either)
      session.on('window-change', (_acceptWin, _reject, info) => { seen.windows.push(info); });
      session.on('exec', (acceptExec, _reject, info) => {
        seen.command = info.command;
        const stream = acceptExec();
        const child = spawn('/bin/sh', ['-c', runReceived ? info.command : 'cat'], { env: { PATH: '/usr/bin:/bin' } });
        child.stdout.on('data', (d) => stream.write(d));
        child.stderr.on('data', (d) => stream.stderr.write(d));
        child.on('close', (code) => { stream.exit(code ?? 0); stream.close(); });
        stream.on('data', (d) => child.stdin.write(d));
        // a dropped channel must not leak the child: cat would hold its pipes
        // open and the test process would never exit
        stream.on('close', () => { try { child.kill('SIGKILL'); } catch {} });
      });
    });
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return { server, port: server.address().port, hostKeyDir, seen };
}

/** A device home with a generated keypair (the client authenticates with it). */
async function makeDeviceHome() {
  const home = mkdtempSync(join(tmpdir(), 'shell-home-'));
  mkdirSync(join(home, '.ssh'), { recursive: true });
  assert.equal(await jsSshBackend.generateKey({ dir: join(home, '.ssh'), comment: 'pi-mobile' }), 0);
  return home;
}

const waitFor = async (predicate, what, timeoutMs = 10_000) => {
  for (const deadline = Date.now() + timeoutMs; Date.now() < deadline;) {
    if (predicate()) return;
    await new Promise((r) => setTimeout(r, 50));
  }
  assert.fail(`timed out waiting for ${what}`);
};

function fakeWs() {
  const ws = new EventEmitter();
  ws.readyState = 1;
  ws.sent = [];
  ws.send = (d) => ws.sent.push(d);
  ws.close = (code, reason) => { ws.readyState = 3; ws.emit('close', code, reason); };
  return ws;
}

test('openShell carries stdin/stdout both ways and turns setWindow into window-change', async () => {
  const home = await makeDeviceHome();
  const host = await startHost({ runReceived: true });
  try {
    const { stream, kill } = await jsSshBackend.openShell({
      home, host: 'user@127.0.0.1', port: host.port,
      command: "printf 'READY\\n'; cat", cols: 80, rows: 24,
    });
    let out = '';
    let closed = false;
    stream.on('data', (d) => { out += d.toString(); });
    stream.on('close', () => { closed = true; });
    try {
      await waitFor(() => out.includes('READY'), 'the banner');
      stream.write('ping\n');
      await waitFor(() => out.includes('ping\n'), 'the echo round-trip');
      stream.setWindow(40, 100, 0, 0);
      await waitFor(() => host.seen.windows.some((w) => w.cols === 100 && w.rows === 40), 'the resize');
    } finally {
      kill();
    }
    await waitFor(() => closed, 'channel close after kill');
  } finally {
    host.server.close();
    for (const d of [home, host.hostKeyDir]) rmSync(d, { recursive: true, force: true });
  }
});

test('the pty handler bridges the WebSocket to the SSH channel on JS backends', async () => {
  setSshBackend(jsSshBackend); // this file's process: iOS selects the JS backend
  const home = await makeDeviceHome();
  const host = await startHost({ runReceived: false }); // the pi installer script must not run
  process.env.HOME = home; // the handler resolves the device key via $HOME
  const startPty = createPtyHandler({ root: process.cwd(), prefix: '', workDir: process.cwd() });
  const ws = fakeWs();
  try {
    startPty(ws, new URL(`ws://x/pty?token=t&cols=80&rows=24&ssh=${encodeURIComponent(`user@127.0.0.1:${host.port}`)}`));
    // the server's cat echoes input back; keystrokes sent before the SSH
    // handshake completes must survive the queue
    ws.emit('message', Buffer.from('early\n'));
    ws.emit('message', Buffer.from('\x01' + JSON.stringify({ resize: { cols: 100, rows: 40 } })));
    await waitFor(() => host.seen.command !== null, 'the exec');
    // remote bash session (remoteBash shape), not a plain shell
    assert.match(host.seen.command, /^bash -l -c /);
    await waitFor(() => ws.sent.some((d) => d.toString().includes('early\n')), 'the queued keystrokes echoed back');
    await waitFor(() => host.seen.windows.some((w) => w.cols === 100 && w.rows === 40), 'the resize control frame');
    ws.emit('message', Buffer.from('late\n'));
    await waitFor(() => ws.sent.some((d) => d.toString().includes('late\n')), 'post-handshake keystrokes');
    ws.close();
  } finally {
    if (ws.readyState === 1) ws.close(); // kill the ssh connection even when an assert threw
    host.server.close();
    for (const d of [home, host.hostKeyDir]) rmSync(d, { recursive: true, force: true });
  }
});

test('a WebSocket closing during the SSH handshake tears the connection down', async () => {
  setSshBackend(jsSshBackend);
  const home = await makeDeviceHome();
  const host = await startHost({ runReceived: false });
  process.env.HOME = home; // the handler resolves the device key via $HOME
  const startPty = createPtyHandler({ root: process.cwd(), prefix: '', workDir: process.cwd() });
  try {
    const ws = fakeWs();
    startPty(ws, new URL(`ws://x/pty?token=t&cols=80&rows=24&ssh=${encodeURIComponent(`user@127.0.0.1:${host.port}`)}`));
    ws.close(); // same tick: lands while openShell is still connecting
    await waitFor(() => host.seen.clients === 1, 'the connection to be made');
    await waitFor(() => host.seen.clientCloses === 1, 'the abandoned connection to be torn down');
  } finally {
    // a leaked client would otherwise keep the sockets (and the process) alive
    host.server.close();
    host.server.closeAllConnections?.();
    for (const d of [home, host.hostKeyDir]) rmSync(d, { recursive: true, force: true });
  }
});
