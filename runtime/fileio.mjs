// fileio.mjs — crash-safe file primitives shared by every runtime entry
// point: atomic writes, JSON reads, a cross-process advisory lock, and the
// single-owner lock that keeps pi-durable storage exclusive.
import {
  closeSync, mkdirSync, openSync, readFileSync, renameSync, statSync,
  unlinkSync, writeFileSync, writeSync,
} from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// --- files ---------------------------------------------------------------------

/** Write via temp file + rename so a crash never leaves a truncated file. */
export function writeFileAtomic(file, data, mode = 0o600) {
  mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.${crypto.randomBytes(4).toString('hex')}.tmp`;
  writeFileSync(tmp, data, { mode });
  renameSync(tmp, file);
}

export function readJson(file, fallback) {
  try { return JSON.parse(readFileSync(file, 'utf8')); } catch { return fallback; }
}

/** Cross-process advisory lock (O_EXCL lock file, stale after `staleMs`). */
export async function withFileLock(file, fn, { staleMs = 10_000, timeoutMs = 15_000 } = {}) {
  const lock = `${file}.lock`;
  const deadline = Date.now() + timeoutMs;
  mkdirSync(path.dirname(file), { recursive: true });
  for (;;) {
    try {
      const fd = openSync(lock, 'wx', 0o600);
      writeSync(fd, String(process.pid));
      closeSync(fd);
      break;
    } catch (e) {
      if (e.code !== 'EEXIST') throw e;
      try { if (Date.now() - statSync(lock).mtimeMs > staleMs) unlinkSync(lock); } catch {}
      if (Date.now() > deadline) throw new Error(`lock timeout: ${lock}`);
      await sleep(50);
    }
  }
  try { return await fn(); } finally { try { unlinkSync(lock); } catch {} }
}

// --- single storage owner --------------------------------------------------------

function pidAlive(pid) {
  try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; }
}
function pidRuns(pid, script) {
  try { return readFileSync(`/proc/${pid}/cmdline`, 'utf8').includes(script); } catch { return false; }
}

/**
 * pi-durable has no cross-process locking: one process may own a storage.
 * Take `lockFile`; a still running predecessor of the same script (for example
 * an orphan left by a killed app process) is asked to stop, then killed.
 */
export async function acquireOwnerLock(lockFile, script) {
  mkdirSync(path.dirname(lockFile), { recursive: true });
  const old = Number(readJson(lockFile, {})?.pid ?? readFileSafe(lockFile));
  if (old && old !== process.pid && pidAlive(old) && pidRuns(old, script)) {
    console.error(`owner lock: stopping previous ${script} pid ${old}`);
    try { process.kill(old, 'SIGTERM'); } catch {}
    for (let i = 0; i < 100 && pidAlive(old); i++) await sleep(100);
    if (pidAlive(old)) { try { process.kill(old, 'SIGKILL'); } catch {} await sleep(200); }
  }
  writeFileAtomic(lockFile, JSON.stringify({ pid: process.pid, started: new Date().toISOString() }));
  return () => {
    try { if (readJson(lockFile, {})?.pid === process.pid) unlinkSync(lockFile); } catch {}
  };
}
function readFileSafe(f) { try { return readFileSync(f, 'utf8').trim(); } catch { return ''; } }
