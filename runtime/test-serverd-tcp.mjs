// test-serverd-tcp.mjs — the pi-serverd loopback TCP listener speaks the same
// pi-server protocol as the unix transport, so pure-JS SSH clients (iOS) can
// forwardOut into it.
//
// tcp-listener protocol: real Server + ProtocolTestClient over a raw TCP
// socket — framing, handshake, request/response.
// openTcpTunnel end-to-end: the full iOS attach path minus the phone — the js
// backend bridges a local unix socket over ssh2 direct-tcpip (real sshd) into
// the TCP listener; pi-client then talks the real protocol through it.
//
// The sshd suites need a local sshd and edit ~/.ssh/authorized_keys: they are
// skipped unless PI_SERVERD_TCP_TESTS=1. The two tcp-listener protocol tests
// have no such requirement and always run.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { execSync } from 'node:child_process';
import net from 'node:net';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync, appendFileSync, readFileSync, existsSync, unlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createTcpListener } from './serverd-tcp.mjs';
import { createTestServer, TestServerHost, ProtocolTestClient } from '@earendil-works/pi-server/testing';
import { jsSshBackend } from './ssh-js-backend.mjs';

const TCP_SKIP = process.env.PI_SERVERD_TCP_TESTS
  ? false
  : 'set PI_SERVERD_TCP_TESTS=1 (needs a local sshd; edits ~/.ssh/authorized_keys)';
import { Client } from '@earendil-works/pi-client';
import { createUnixTransportFactory } from '@earendil-works/pi-client/unix';

/** System sshd on this host; the generated key is authorized with a marker
 * line that finally() strips again — same pattern as the backend spikes. */
async function withAuthorizedKey(fn) {
  const home = mkdtempSync(path.join(tmpdir(), 'tcp-listener-'));
  const user = process.env.USER;
  mkdirSync(path.join(home, '.ssh'), { mode: 0o700 });
  execSync(`ssh-keygen -t ed25519 -N '' -f ${home}/.ssh/id_ed25519 -C serverd-tcp-test -q`);
  const pub = readFileSync(path.join(home, '.ssh/id_ed25519.pub'), 'utf8').trim();
  const marker = 'serverd-tcp-test-marker';
  const akPath = path.join(process.env.HOME, '.ssh/authorized_keys');
  appendFileSync(akPath, `\n${pub} ${marker}\n`);
  try {
    return await fn({ home, user, target: `${user}@127.0.0.1` });
  } finally {
    writeFileSync(akPath, readFileSync(akPath, 'utf8').split('\n').filter((l) => !l.includes(marker)).join('\n'));
    rmSync(home, { recursive: true, force: true });
  }
}

/** Server with only the TCP listener bound to an OS-assigned port. */
async function withTcpServer(fn) {
  const listener = createTcpListener({ port: 0 });
  const { server, host } = createTestServer({ listeners: [listener] });
  // The default test services only implement attach/detach; these tests probe
  // transport, so answer every server-level call with a canned payload.
  const calls = [];
  host.serverServices = {
    attachClient: () => ({
      invokeService: async (call) => { calls.push(call); return { ok: true, sessions: [{ id: 'via-tcp' }] }; },
      release() {},
    }),
  };
  await server.start();
  try {
    return await fn({ host, calls, port: listener.boundPort, serverId: '00000000-0000-4000-8000-000000000001' });
  } finally {
    await server.close().catch(() => {});
  }
}

test('tcp listener speaks the pi-server protocol end to end', async () => {
  await withTcpServer(async ({ calls, port, serverId }) => {
    const socket = net.connect({ host: '127.0.0.1', port });
    await once(socket, 'connect');
    const client = new ProtocolTestClient({
      send: (chunk) => new Promise((resolve, reject) => socket.write(chunk, (e) => (e ? reject(e) : resolve()))),
      sendFragmented: async (chunk, splitAt) => {
        await new Promise((resolve) => socket.write(chunk.subarray(0, splitAt), resolve));
        await new Promise((resolve) => socket.write(chunk.subarray(splitAt), resolve));
      },
      close: async () => {
        if (socket.destroyed) return;
        const closed = once(socket, 'close');
        socket.destroy();
        await closed;
      },
    });
    socket.on('data', (chunk) => client.receive(new Uint8Array(chunk.buffer, chunk.byteOffset, chunk.byteLength)));
    socket.once('close', () => client.markClosed());
    const hello = await client.hello();
    assert.ok(hello, 'handshake must answer');
    const response = await client.requestService({ serverId }, { serviceId: 'pi.session-management', member: 'list', args: [] });
    assert.deepEqual(response.result, { ok: true, sessions: [{ id: 'via-tcp' }] });
    assert.equal(calls.at(-1)?.member, 'list');
    await client.close();
  });
});

test('tcp listener refuses duplicate bind and exposes its bound port', async () => {
  const listener = createTcpListener({ port: 0 });
  await listener.start(() => ({ onData() {}, onClose() {}, onError() {} }));
  const bound = listener.boundPort;
  assert.ok(bound > 0);
  const dup = createTcpListener({ port: bound });
  await assert.rejects(() => dup.start(() => ({})));
  await listener.close();
  assert.equal(listener.boundPort, undefined);
});

test('openTcpTunnel bridges a local unix socket to the remote pi-serverd over sshd', { skip: TCP_SKIP }, async () => {
  await withAuthorizedKey(async ({ home, target }) => {
    await withTcpServer(async ({ port, serverId }) => {
      const localSock = path.join(home, 'attach.sock');
      const tunnel = jsSshBackend.openTcpTunnel({
        home, host: target, port: 22,
        localPath: localSock, remoteHost: '127.0.0.1', remotePort: port,
      });
      try {
        while (!existsSync(localSock)) await new Promise((r) => setTimeout(r, 50));
        const client = await Client.connect({
          serverId,
          transportFactory: createUnixTransportFactory({ path: localSock }),
        });
        try {
          const list = await client.request({ serverId }, { serviceId: 'sessions', member: 'list', args: [] });
          assert.deepEqual(list, { ok: true, sessions: [{ id: 'via-tcp' }] });
        } finally {
          await client.dispose();
        }
      } finally {
        tunnel.kill();
        await new Promise((r) => setTimeout(r, 100));
        try { unlinkSync(localSock); } catch {}
      }
    });
  });
});

test('openTcpTunnel surfaces teardown as proc exit', { skip: TCP_SKIP }, async () => {
  await withAuthorizedKey(async ({ home, target }) => {
    const dying = path.join(home, 'dying.sock');
    const tunnel = jsSshBackend.openTcpTunnel({
      home, host: target, port: 22,
      localPath: dying, remoteHost: '127.0.0.1', remotePort: 1,
    });
    const exitCode = await new Promise(async (resolve) => {
      tunnel.proc.on('exit', (code) => resolve(code));
      while (!existsSync(dying)) await new Promise((r) => setTimeout(r, 50));
      // kill() is how remote-client tears the tunnel down
      tunnel.kill();
    });
    assert.equal(exitCode, 1);
  });
});
