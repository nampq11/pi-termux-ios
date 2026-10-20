// Pure-JS SSH backend for iOS, where exec() is denied. Same contract as
// spawnSshBackend (see ssh-transport.mjs); registered via setSshBackend()
// when PI_PLATFORM=ios.
//
// Host-key trust mirrors `StrictHostKeyChecking=accept-new`: a first connect
// stores the key in known_hosts (plain entry, or [host]:port for non-22);
// a changed key refuses the connection. Hashed |1| entries are matched too,
// so files written by ssh-keygen/OpenSSH stay authoritative.
import crypto from 'node:crypto';
import { appendFileSync, existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs';
import net from 'node:net';
import { EventEmitter } from 'node:events';
import path from 'node:path';
import SSH2 from 'ssh2';
import { withDeadline } from './ssh-transport.mjs';

const { Client } = SSH2;

/** Host keys arrive as SSH wire blobs: u32 length + algorithm name + key data.
 * This is byte-for-byte what known_hosts stores, so the algorithm name reads
 * straight off the front of the buffer. */
function hostKeyType(keyBuffer) {
  const algLen = keyBuffer.readUInt32BE(0);
  return keyBuffer.toString('utf8', 4, 4 + algLen);
}

/** `host` or `[host]:port` — the known_hosts pattern for this target. */
function knownHostsPattern(host, port) {
  const bare = host.replace(/^.*@/, '');
  return port && port !== 22 ? `[${bare}]:${port}` : bare;
}

function sha256Fingerprint(keyBuffer) {
  return `SHA256:${crypto.createHash('sha256').update(keyBuffer).digest('base64').replace(/=+$/, '')}`;
}

/** Match one known_hosts host-field against the target (plain + hashed |1|). */
function fieldMatches(field, pattern) {
  return field.split(',').some((entry) => {
    if (entry === pattern) return true;
    if (entry.startsWith('|1|')) {
      const [, , salt, hash] = entry.split('|');
      const mac = crypto.createHmac('sha1', Buffer.from(salt, 'base64')).update(pattern).digest('base64');
      return mac === hash;
    }
    return false;
  });
}

function readKnownHosts(home) {
  const file = path.join(home, '.ssh', 'known_hosts');
  if (!existsSync(file)) return [];
  return readFileSync(file, 'utf8').split('\n')
    .filter((l) => l.trim() && !l.startsWith('#') && !l.startsWith('@'))
    .map((l) => l.trim().split(/\s+/))
    .filter((f) => f.length >= 3);
}

function storeHostKey(home, pattern, keyType, keyBuffer) {
  const dir = path.join(home, '.ssh');
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  appendFileSync(path.join(dir, 'known_hosts'), `${pattern} ${keyType} ${keyBuffer.toString('base64')}\n`, { mode: 0o600 });
}

function parseTarget(host) {
  const at = host.indexOf('@');
  const user = at >= 0 ? host.slice(0, at) : (process.env.USER || process.env.LOGNAME);
  if (!user) throw new Error('SSH target must include user@ — cannot infer a username on iOS');
  return { username: user, hostname: at >= 0 ? host.slice(at + 1) : host };
}

function connect({ host, port, home, signal }) {
  const { username, hostname } = parseTarget(host);
  const keyPath = path.join(home, '.ssh', 'id_ed25519');
  const privateKey = readFileSync(keyPath, 'utf8');
  const pattern = knownHostsPattern(host, port);
  return new Promise((resolve, reject) => {
    const conn = new Client();
    const fail = (e) => { try { conn.end(); } catch {} reject(e); };
    conn.on('error', fail);
    conn.on('ready', () => { conn.removeListener('error', fail); resolve(conn); });
    conn.connect({
      host: hostname,
      port: port || 22,
      username,
      privateKey,
      keepalive: { interval: 15, countMax: 3 },
      readyTimeout: 15_000,
      // accept-new: unknown host → store and accept; known-but-different → refuse
      hostVerifier: (keyBuffer, verify) => {
        try {
          const keyType = hostKeyType(keyBuffer);
          const stored = readKnownHosts(home).find((f) => fieldMatches(f[0], pattern) && f[1] === keyType);
          if (stored) return verify(stored[2] === keyBuffer.toString('base64'));
          storeHostKey(home, pattern, keyType, keyBuffer);
          verify(true);
        } catch (e) { verify(false); }
      },
    });
    if (signal) signal.addEventListener('abort', () => fail(signal.reason), { once: true });
  });
}

export const jsSshBackend = {
  name: 'js',

  /** Same process semantics as the spawn backend: bounded, tail-trimmed
   * output, line callbacks, and stdin write failures must not crash the
   * caller with an unhandled event. */
  run({ home, host, port, command, stdin, onLine, timeoutMs = 60_000, signal }) {
    return withDeadline((bounded) => new Promise((resolve, reject) => {
      let conn;
      let out = '', err = '', done = false, exitCode = null;
      const tail = (v, d) => (v + d).slice(-32_768); // don't keep unlimited npm output
      let lineBuffer = '';
      const emit = (v) => {
        lineBuffer += String(v);
        let i;
        while ((i = lineBuffer.indexOf('\n')) >= 0) {
          const line = lineBuffer.slice(0, i); lineBuffer = lineBuffer.slice(i + 1);
          if (line.trim()) onLine?.(line.trimEnd());
        }
        if (lineBuffer.length > 8192) { onLine?.(lineBuffer.slice(-8192)); lineBuffer = ''; }
      };
      const finish = (e, code) => {
        if (done) return;
        done = true;
        bounded.removeEventListener('abort', onAbort);
        try { conn?.end(); } catch {}
        if (e) reject(e); else resolve({ code, out: out.trim(), err: err.trim() });
      };
      const onAbort = () => finish(bounded.reason);
      bounded.addEventListener('abort', onAbort, { once: true });
      connect({ host, port, home, signal: bounded })
        .then((c) => {
          if (done) { c.end(); return; }
          conn = c;
          conn.exec(command, (execErr, stream) => {
            if (execErr) return finish(execErr);
            stream.on('data', (d) => { out = tail(out, d); emit(d); });
            stream.stderr.on('data', (d) => { err = tail(err, d); emit(d); });
            stream.on('exit', (code) => { exitCode = code; });
            // 'close' fires after streams drain — the ssh2 analog of spawn 'close'
            stream.on('close', () => finish(null, exitCode));
            // A command that exits before reading stdin surfaces here, like
            // the EPIPE path in the spawn backend.
            stream.on('error', (e) => finish(e));
            try {
              if (stdin !== undefined) stream.end(stdin); else stream.end();
            } catch (e) { finish(e); }
          });
        })
        .catch((e) => finish(e));
    }), { timeoutMs, signal });
  },

  async runStrict(context) {
    const r = await this.run(context);
    if (r.code !== 0) throw new Error(`ssh command failed (${r.code}): ${r.err || 'no stderr'}`);
    return r.out;
  },

  /** SHA256:… host-key fingerprint from the known_hosts file, or null. */
  async fingerprint({ home, host, port }) {
    const pattern = knownHostsPattern(host, port);
    for (const [field, keyType, key] of readKnownHosts(home)) {
      if (fieldMatches(field, pattern)) {
        try {
          void keyType;
          return sha256Fingerprint(Buffer.from(key, 'base64'));
        } catch { return null; }
      }
    }
    return null;
  },

  async generateKey({ dir, comment }) {
    return generateKeyPair({ dir, comment });
  },

  // ssh2 cannot open OpenSSH streamlocal (unix→unix) channels. iOS attach
  // uses openTcpTunnel against pi-serverd's loopback listener instead.
  async openStreamlocalTunnel() {
    throw new Error('unix-socket SSH tunnels are not supported on iOS; the remote pi-serverd must expose its loopback TCP listener (~/.pi-serverd/server.tcp missing)');
  },

  /** Local unix socket ⇄ ssh2 direct-tcpip bridge. Same thin-handle contract
   * as the spawn backend's openStreamlocalTunnel: the caller owns waiting for
   * the socket path (the listener binds asynchronously, like `ssh -N -L`),
   * retry policy, and teardown via kill(). A dropped SSH connection surfaces
   * as proc 'exit' (plus 'error' with the reason), matching process semantics. */
  openTcpTunnel({ home, host, port, localPath, remoteHost = '127.0.0.1', remotePort }) {
    const proc = new EventEmitter();
    proc.stderr = new EventEmitter();
    let server = null, dead = false;
    const sockets = new Set();
    const die = (e) => {
      if (dead) return;
      dead = true;
      if (e) proc.emit('error', e);
      proc.emit('exit', 1);
    };
    // Auth/trust identical to run(); the host key is already pinned by
    // provisioning. The bind delay and ssh2 handshake race out like
    // `ssh -N -L` does: the caller polls for the socket path, and each
    // accepted connection awaits SSH readiness before forwardOut.
    const ready = connect({ host, port, home });
    ready.catch(die);
    // the no-op catch: a handshake losing the race with kill() must not
    // surface as an unhandled rejection — die() already reported the exit
    ready.then((c) => c.on('close', () => die(new Error('ssh connection closed')))).catch(() => {});
    server = net.createServer((socket) => {
      sockets.add(socket);
      socket.once('close', () => sockets.delete(socket));
      ready.then((c) => {
        if (dead) { socket.destroy(); return; }
        c.forwardOut('127.0.0.1', 0, remoteHost, remotePort, (err, channel) => {
          if (err) { proc.stderr.emit('data', `forward failed: ${err.message}\n`); socket.destroy(); return; }
          socket.pipe(channel);
          channel.pipe(socket);
          const bye = () => { try { socket.destroy(); } catch {} try { channel.end(); } catch {} };
          socket.once('close', bye);
          channel.once('close', bye);
        });
      }).catch(() => socket.destroy());
    });
    server.on('error', die);
    // stale socket file would EADDRINUSE the async bind, exactly like ssh -L
    try { unlinkSync(localPath); } catch {}
    server.listen(localPath);
    return {
      proc,
      kill: () => {
        try { server?.close(); } catch {}
        for (const s of sockets) { try { s.destroy(); } catch {} }
        ready.then((c) => { try { c.end(); } catch {} }).catch(() => {});
        die();
      },
    };
  },
};
function withDeadlineJs(operation, options) { return withDeadline(operation, options); }

/** Write an ed25519 keypair in OpenSSH format without shelling out to
 * ssh-keygen. node:crypto gives the raw seed/public via JWK; the rest is the
 * openssh-key-v1 wire container, byte-compatible with what ssh-keygen -t
 * ed25519 writes (unencrypted): 0600 private PEM, 0644 public one-liner. */
function generateKeyPair({ dir, comment = 'pi-mobile' }) {
  try {
    const { privateKey } = crypto.generateKeyPairSync('ed25519');
    const jwk = privateKey.export({ format: 'jwk' }); // d = seed, x = public half
    const seed = Buffer.from(jwk.d, 'base64url');
    const pub = Buffer.from(jwk.x, 'base64url');
    if (seed.length !== 32 || pub.length !== 32) throw new Error('unexpected JWK key material');

    const u32 = (n) => { const b = Buffer.alloc(4); b.writeUInt32BE(n); return b; };
    const field = (b) => Buffer.concat([u32(b.length), b]);
    const pubBlob = Buffer.concat([field(Buffer.from('ssh-ed25519')), field(pub)]);
    const check = crypto.randomBytes(4);
    // OpenSSH stores the section as: public half (32B), then the private
    // ed25519_sk blob (64B = seed||public) — verified against ssh-keygen output
    const sk64 = Buffer.concat([seed, pub]);
    let section = Buffer.concat([check, check, field(Buffer.from('ssh-ed25519')), field(pub), field(sk64), field(Buffer.from(comment))]);
    section = Buffer.concat([section, Buffer.from(Array.from({ length: (8 - (section.length % 8)) % 8 }, (_, i) => i + 1))]);
    const body = Buffer.concat([
      Buffer.from('openssh-key-v1\0'), field(Buffer.from('none')), field(Buffer.from('none')),
      field(Buffer.alloc(0)), u32(1), field(pubBlob), field(section),
    ]);
    const pem = body.toString('base64').replace(/(.{1,70})/g, '$1\n');
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    writeFileSync(path.join(dir, 'id_ed25519'), `-----BEGIN OPENSSH PRIVATE KEY-----\n${pem}-----END OPENSSH PRIVATE KEY-----\n`, { mode: 0o600 });
    writeFileSync(path.join(dir, 'id_ed25519.pub'), `ssh-ed25519 ${pubBlob.toString('base64')} ${comment}\n`, { mode: 0o644 });
    return 0;
  } catch (e) {
    console.error('ssh key generation failed:', e?.message || e);
    return -1;
  }
}
