// Real-behavior tests for the USTAR writer: the archive must extract with an
// actual tar binary (the remote host runs `tar xzf -`), be deterministic
// (staged twice for the same tree -> identical bytes), and refuse anything
// the remote payload never contains (symlinks, long names).
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildUstar } from './ustar.mjs';

function makeTree() {
  const src = mkdtempSync(join(tmpdir(), 'ustar-src-'));
  mkdirSync(join(src, 'lib'));
  writeFileSync(join(src, 'a.mjs'), 'export const a = 1;\n');
  writeFileSync(join(src, 'lib', 'b.json'), '{"b":1}\n');
  writeFileSync(join(src, 'lib', 'run.sh'), '#!/bin/sh\n', { mode: 0o755 });
  return src;
}

test('archives extract with the system tar, preserving structure, content and the exec bit', () => {
  const src = makeTree();
  const out = mkdtempSync(join(tmpdir(), 'ustar-out-'));
  try {
    const archive = join(out, 'payload.tar');
    writeFileSync(archive, buildUstar(src, ['a.mjs', 'lib']));
    execFileSync('tar', ['xf', 'payload.tar'], { cwd: out });
    assert.equal(readFileSync(join(out, 'a.mjs'), 'utf8'), 'export const a = 1;\n');
    assert.equal(readFileSync(join(out, 'lib', 'b.json'), 'utf8'), '{"b":1}\n');
    assert.equal(statSync(join(out, 'lib', 'run.sh')).mode & 0o111, 0o111);
    assert.equal(statSync(join(out, 'lib')).mode & 0o777, 0o755);
    assert.deepEqual(readdirSync(out).sort(), ['a.mjs', 'lib', 'payload.tar']);
  } finally {
    rmSync(src, { recursive: true, force: true });
    rmSync(out, { recursive: true, force: true });
  }
});

test('the same tree archives to identical bytes (sorted, zeroed metadata)', () => {
  const src = makeTree();
  try {
    // entry order follows the names argument (like tar's argv); directory
    // contents are walked sorted. Determinism is per identical input.
    assert.ok(buildUstar(src, ['a.mjs', 'lib']).equals(buildUstar(src, ['a.mjs', 'lib'])));
  } finally { rmSync(src, { recursive: true, force: true }); }
});

test('non-regular files and over-long names are refused, not silently mangled', () => {
  const src = makeTree();
  try {
    symlinkSync('a.mjs', join(src, 'link'));
    assert.throws(() => buildUstar(src, ['link']), /non-regular/);
    const long = join(src, 'x'.repeat(101));
    writeFileSync(long, 'x');
    assert.throws(() => buildUstar(src, ['x'.repeat(101)]), /too long/);
  } finally { rmSync(src, { recursive: true, force: true }); }
});
