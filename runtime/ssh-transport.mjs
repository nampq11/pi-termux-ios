// The one place that knows how to reach an SSH host. Callers pass structured
// options; a backend renders them. Two backends:
//   - spawn: the OpenSSH binary (Linux dev). Argv is identical to the
//     pre-transport code — the provisioning tests stub bin/ssh via the prefix
//     and match the remote command as the last argv element.
//   - js: a pure-JS ssh2 client (iOS denies exec; registered at startup).
import { spawn } from 'node:child_process';

/** Bound operations even when the underlying peer never answers. */
export async function withDeadline(operation, { timeoutMs = 15_000, signal } = {}) {
  const timerController = new AbortController();
  const timer = setTimeout(() => timerController.abort(new Error(`remote timeout after ${timeoutMs / 1000}s`)), timeoutMs);
  const bounded = signal ? AbortSignal.any([signal, timerController.signal]) : timerController.signal;
  let onAbort;
  try {
    bounded.throwIfAborted();
    const cancelled = new Promise((_, reject) => {
      onAbort = () => reject(bounded.reason);
      bounded.addEventListener('abort', onAbort, { once: true });
    });
    return await Promise.race([operation(bounded), cancelled]);
  } finally {
    clearTimeout(timer);
    if (onAbort) bounded.removeEventListener('abort', onAbort);
  }
}

export function sshBaseOptions(home, port) {
  return ['-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=accept-new',
    '-o', `UserKnownHostsFile=${home}/.ssh/known_hosts`, '-i', `${home}/.ssh/id_ed25519`,
    '-o', 'ConnectTimeout=15', '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=3',
    ...(port ? ['-p', String(port)] : [])];
}

/** Shared run() output accounting for both backends: 32 KiB stdout/stderr
 * tails (don't keep unlimited npm output) and newline-split onLine callbacks
 * sharing one line buffer, with an 8 KiB flush for newline-less floods. */
export function sshOutputCapture(onLine) {
  let out = '', err = '', lineBuffer = '';
  const emit = (v) => {
    lineBuffer += String(v);
    let i;
    while ((i = lineBuffer.indexOf('\n')) >= 0) {
      const line = lineBuffer.slice(0, i); lineBuffer = lineBuffer.slice(i + 1);
      if (line.trim()) onLine?.(line.trimEnd());
    }
    if (lineBuffer.length > 8192) { onLine?.(lineBuffer.slice(-8192)); lineBuffer = ''; }
  };
  return {
    stdout: (d) => { out = (out + d).slice(-32_768); emit(d); },
    stderr: (d) => { err = (err + d).slice(-32_768); emit(d); },
    result: () => ({ out: out.trim(), err: err.trim() }),
  };
}

/** run() adapter shared by both backends: resolves the trimmed stdout or
 * rejects on failure. Use as an object member (`runStrict: sshRunStrict`) so
 * `this.run` binds to the backend. */
export async function sshRunStrict(context) {
  const r = await this.run(context);
  if (r.code !== 0) throw new Error(`ssh command failed (${r.code}): ${r.err || 'no stderr'}`);
  return r.out;
}

/** Capture a local helper binary (ssh-keygen), not a remote command. */
function captureLocal(command, args, options) {
  return withDeadline((signal) => new Promise((resolve, reject) => {
    const c = spawn(command, args, { env: process.env });
    let out = '', err = '';
    const abort = () => { c.kill('SIGKILL'); reject(signal.reason); };
    signal.addEventListener('abort', abort, { once: true });
    c.stdout.on('data', (d) => { out = (out + d).slice(-32_768); });
    c.stderr.on('data', (d) => { err = (err + d).slice(-32_768); });
    c.on('error', reject);
    c.on('close', (code) => {
      signal.removeEventListener('abort', abort);
      code === 0 ? resolve(out.trim()) : reject(new Error(`ssh command failed (${code}): ${err.trim() || 'no stderr'}`));
    });
    c.stdin.end();
  }), options);
}

export const spawnSshBackend = {
  name: 'spawn',

  /** Run `command` on `host` via the OpenSSH binary. Same process semantics as
   * the original sshRun: bounded, tail-trimmed output, line callbacks, and an
   * early stdin EPIPE must not crash the caller with an unhandled event. */
  run({ prefix = '', home, host, port, command, stdin, onLine, timeoutMs = 60_000, signal }) {
    return withDeadline((bounded) => new Promise((resolve, reject) => {
      const c = spawn(`${prefix}/bin/ssh`, [...sshBaseOptions(home, port), '--', host, command], { env: process.env });
      const capture = sshOutputCapture(onLine);
      let done = false;
      c.stdout.on('data', capture.stdout);
      c.stderr.on('data', capture.stderr);
      const abort = () => { c.kill('SIGKILL'); finish(bounded.reason); };
      const finish = (e, code) => {
        if (done) return;
        done = true;
        bounded.removeEventListener('abort', abort);
        if (e) reject(e); else resolve({ code, ...capture.result() });
      };
      bounded.addEventListener('abort', abort, { once: true });
      c.on('error', finish);
      // Early SSH failure during upload must not crash the bridge with EPIPE.
      c.stdin.on('error', (e) => { c.kill('SIGKILL'); finish(e); });
      c.on('close', (code) => finish(null, code));
      if (stdin !== undefined) c.stdin.end(stdin); else c.stdin.end();
    }), { timeoutMs, signal });
  },

  /** Like run(), but resolves the trimmed stdout or rejects on failure. */
  runStrict: sshRunStrict,

  /** SHA256:… host-key fingerprint from the known_hosts file, or null. */
  async fingerprint({ prefix = '', home, host, port, timeoutMs, signal }) {
    const bare = host.replace(/^.*@/, '');
    try {
      const out = await captureLocal(`${prefix}/bin/ssh-keygen`, ['-l', '-F', port ? `[${bare}]:${port}` : bare,
        '-f', `${home}/.ssh/known_hosts`], { timeoutMs, signal });
      return /(SHA256:\S+)/.exec(out)?.[1] ?? null;
    } catch (e) {
      if (signal?.aborted) throw e;
      return null;
    }
  },

  /** Generate an ed25519 keypair at `<dir>/id_ed25519` (no passphrase). */
  generateKey({ prefix = '', dir, comment = 'pi-mobile' }) {
    return new Promise((resolve) => {
      const kg = spawn(`${prefix}/bin/ssh-keygen`, ['-t', 'ed25519', '-N', '', '-f', `${dir}/id_ed25519`, '-C', comment], { env: process.env });
      kg.on('exit', (c) => resolve(c));
      kg.on('error', () => resolve(-1));
    });
  },

  /** Open the persistent `ssh -N -L <local unix socket>:<remote unix socket>`
   * tunnel (OpenSSH streamlocal forwarding). Returns a thin handle; the caller
   * owns waiting for the socket path and all retry/teardown policy. */
  openStreamlocalTunnel({ prefix = '', home, host, port, localPath, remotePath }) {
    const t = spawn(`${prefix}/bin/ssh`, ['-N', ...sshBaseOptions(home, port), '-o', 'ExitOnForwardFailure=yes',
      '-o', 'StreamLocalBindUnlink=yes', '-o', 'StreamLocalBindMask=0177',
      '-L', `${localPath}:${remotePath}`, '--', host], { env: process.env });
    return {
      proc: t,
      kill: () => { try { t.kill('SIGKILL'); } catch {} },
    };
  },
};

let override = null;
/** Test/JS-backend injection point: an object with the spawnSshBackend shape. */
export function setSshBackend(backend) { override = backend; }

export function sshBackend() {
  if (override) return override;
  if (process.env.PI_PLATFORM === 'ios') throw new Error('no JS SSH backend registered for iOS');
  return spawnSshBackend;
}
