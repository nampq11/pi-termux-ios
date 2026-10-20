// SSH Unix-socket bridge. Private sockets keep other phone apps out of the
// unauthenticated pi-server protocol; SSH authenticates the remote peer.
import { chmodSync, existsSync, mkdirSync, unlinkSync } from 'node:fs';
import { sshBackend, withDeadline, sshBaseOptions } from './ssh-transport.mjs';

export { withDeadline, sshBaseOptions } from './ssh-transport.mjs';
import { setTimeout as sleep } from 'node:timers/promises';
import os from 'node:os';
import crypto from 'node:crypto';
import path from 'node:path';
import { Client } from '@earendil-works/pi-client';
import { createUnixTransportFactory } from '@earendil-works/pi-client/unix';

const strictJson = (args) => JSON.parse(JSON.stringify(args ?? []));

/** Reject SSH options and anything requiring shell quoting. */
export function parseSshTarget(value) {
  const target = String(value || '').trim();
  const match = /^([A-Za-z0-9_][A-Za-z0-9_.-]*@)?([A-Za-z0-9_][A-Za-z0-9_.-]*)(?::(\d{1,5}))?$/.exec(target);
  if (!match) throw new Error('invalid SSH target (expected user@host[:port])');
  const port = match[3] ? Number(match[3]) : undefined;
  if (port !== undefined && (port < 1 || port > 65535)) throw new Error('invalid SSH target port');
  return { host: `${match[1] ?? ''}${match[2]}`, port };
}

export async function sshHostFingerprint(ssh, prefix = '', options = {}) {
  const { host, port } = parseSshTarget(ssh);
  const home = process.env.HOME || '/tmp';
  return sshBackend().fingerprint({ prefix, home, host, port, timeoutMs: options.timeoutMs, signal: options.signal });
}

export async function attachRemote({ ssh, prefix = '', socketDir, serverId, remoteSock,
  signal, timeoutMs = 15_000, requestTimeoutMs = 35_000 }) {
  const { host: sshHost, port: sshPort } = parseSshTarget(ssh);
  const backend = sshBackend();
  const home = process.env.HOME || '/tmp';
  const lifetime = new AbortController();
  const alive = signal ? AbortSignal.any([signal, lifetime.signal]) : lifetime.signal;
  alive.throwIfAborted();
  const name = `${crypto.randomBytes(6).toString('hex')}.sock`;
  let dir = socketDir || path.join(home, '.pi-mobile', 'tunnels');
  if (Buffer.byteLength(path.join(dir, name)) > 100) dir = path.join(os.tmpdir(), `pi-tun-${process.getuid?.() ?? 'u'}`);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  chmodSync(dir, 0o700);
  const localSock = path.join(dir, name);
  const sshExec = (cmd) => backend.runStrict({ prefix, home, host: sshHost, port: sshPort, command: cmd, signal: alive, timeoutMs });
  const remotePath = remoteSock || `${await sshExec('echo $HOME')}/.pi-serverd/server.sock`;
  const sid = serverId || await sshExec('cat ~/.pi-serverd/server-id');
  // Pure-JS backends (iOS) cannot open streamlocal channels; they bridge the
  // local unix socket over direct-tcpip to pi-serverd's loopback TCP listener
  // instead. The listener publishes its port in server.tcp (0600) — missing
  // file means the remote daemon predates it, which the open() error explains.
  let remoteTcpPort = null;
  if (!remoteSock && typeof backend.openTcpTunnel === 'function') {
    const r = await backend.run({ prefix, home, host: sshHost, port: sshPort, command: 'cat ~/.pi-serverd/server.tcp 2>/dev/null', signal: alive, timeoutMs });
    const m = /^127\.0\.0\.1:(\d{1,5})$/.exec(r.out.trim());
    if (r.code === 0 && m) remoteTcpPort = Number(m[1]);
  }
  const hostKey = await sshHostFingerprint(ssh, prefix, { signal: alive, timeoutMs });

  let tunnel = null, client = null, opening = null;
  let closed = false, lostFired = false;
  const lostHandlers = new Set();
  const fireLost = (why) => {
    if (closed || alive.aborted || lostFired) return;
    lostFired = true;
    for (const h of lostHandlers) { try { h(why); } catch {} }
  };

  async function teardown() {
    const c = client, t = tunnel;
    client = null; tunnel = null;
    try { await c?.dispose(); } catch {}
    t?.kill();
    try { unlinkSync(localSock); } catch {}
  }

  async function open() {
    try {
      await withDeadline(async (bounded) => {
        try { unlinkSync(localSock); } catch {}
        const t = remoteTcpPort
          ? backend.openTcpTunnel({ prefix, home, host: sshHost, port: sshPort, localPath: localSock, remoteHost: '127.0.0.1', remotePort: remoteTcpPort })
          : backend.openStreamlocalTunnel({ prefix, home, host: sshHost, port: sshPort, localPath: localSock, remotePath });
        tunnel = t;
        let err = '', exited = null;
        const abortTunnel = () => t.kill();
        bounded.addEventListener('abort', abortTunnel, { once: true });
        t.proc.stderr.on('data', (d) => { err = (err + d).slice(-32_768); });
        t.proc.on('exit', (code) => { exited = code ?? -1; if (tunnel === t) fireLost(`ssh tunnel exited ${exited}`); });
        t.proc.on('error', (e) => { exited = -1; err += e.message; });
        try {
          while (!existsSync(localSock)) {
            bounded.throwIfAborted();
            if (exited !== null) throw new Error(`ssh tunnel exited ${exited}: ${err.trim()}`);
            await sleep(100, undefined, { signal: bounded });
          }
          let lastError;
          for (let i = 0; i < 20; i++) {
            bounded.throwIfAborted();
            const c = new Client({ serverId: sid, transportFactory: createUnixTransportFactory({ path: localSock }) });
            const abortClient = () => { void c.dispose(); };
            bounded.addEventListener('abort', abortClient, { once: true });
            try {
              await c.connect();
              bounded.throwIfAborted();
              c.onConnectionStateChange((change) => {
                if (client === c && change.state === 'disconnected') fireLost('connection closed');
              });
              client = c;
              lostFired = false;
              return;
            } catch (e) {
              await c.dispose();
              bounded.throwIfAborted();
              lastError = e;
            } finally { bounded.removeEventListener('abort', abortClient); }
            await sleep(150, undefined, { signal: bounded });
          }
          throw lastError ?? new Error('connect failed');
        } finally { bounded.removeEventListener('abort', abortTunnel); }
      }, { signal: alive, timeoutMs });
      alive.throwIfAborted();
    } catch (e) { await teardown(); throw e; }
  }

  const onAbort = () => { void teardown(); };
  alive.addEventListener('abort', onAbort, { once: true });
  try { await open(); } catch (e) { alive.removeEventListener('abort', onAbort); throw e; }

  const call = (target, serviceId, member, args) => withDeadline((bounded) => {
    if (closed || !client?.connected) throw new Error('disconnected');
    return client.request(target, { serviceId, member, args: strictJson(args) }, bounded);
  }, { signal: alive, timeoutMs: requestTimeoutMs });
  const serverCall = (member, args = []) => call({ serverId: sid }, 'sessions', member, args);

  return {
    get client() { return client; },
    serverId: sid, target: ssh, hostKey,
    get connected() { return !closed && !alive.aborted && Boolean(client?.connected) && !lostFired; },
    onLost(handler) { lostHandlers.add(handler); return () => lostHandlers.delete(handler); },
    list: () => serverCall('list'),
    models: () => serverCall('models'),
    create: (opts = {}) => serverCall('create', [opts]),
    delete: (id) => serverCall('delete', [id]),
    rename: (id, name) => serverCall('rename', [id, name]),
    attach: (id) => serverCall('attach', [id]),
    async request(member, args = []) {
      if (!client?.attachment) throw new Error('not attached');
      return call(client.attachment, 'chat', member, args);
    },
    async reconnect() {
      if (closed || alive.aborted) throw new Error('disconnected');
      if (!opening) {
        opening = (async () => { await teardown(); alive.throwIfAborted(); await open(); })();
      }
      const pending = opening;
      try { await pending; } finally { if (opening === pending) opening = null; }
    },
    async disconnect() {
      closed = true;
      lostHandlers.clear();
      lifetime.abort(new Error('disconnected'));
      try { await opening; } catch {}
      await teardown();
      alive.removeEventListener('abort', onAbort);
    },
  };
}
