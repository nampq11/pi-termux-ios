// test-manifests.mjs — a runtime entry importing a file its manifest doesn't
// ship crashes on the device (and on provisioned remote hosts) with nothing
// but ERR_MODULE_MODULE_NOT_FOUND; the manifests must cover the whole static
// import closure. The packaging scripts run the same check at build time
// (check_import_closures in scripts/payload_common.py).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { REMOTE_FILES } from './remote-provision.mjs';

const ROOT = path.dirname(fileURLToPath(import.meta.url));
// Static relative imports only: dynamic import() and bare (node_modules)
// specifiers are deliberately out of scope.
const RELATIVE_IMPORT = /\bfrom\s+['"](\.[^'"]+)['"]|\bimport\s+['"](\.[^'"]+)['"]/g;

function importClosure(entry) {
  const seen = new Set();
  const stack = [entry];
  while (stack.length) {
    const name = stack.pop();
    if (seen.has(name)) continue;
    seen.add(name);
    let text;
    try {
      text = readFileSync(path.join(ROOT, name), 'utf8');
    } catch {
      continue; // reported as missing by the manifest membership assertion
    }
    for (const m of text.matchAll(RELATIVE_IMPORT)) {
      const spec = m[1] || m[2];
      stack.push(path.posix.normalize(path.posix.join(path.posix.dirname(name), spec)));
    }
  }
  seen.delete(entry);
  return seen;
}

test('server.mjs import closure is covered by the payload manifest', () => {
  const py = readFileSync(path.join(ROOT, '..', 'scripts', 'payload_common.py'), 'utf8');
  const block = /FILES = \[([^\]]*)\]/s.exec(py)?.[1];
  assert.ok(block, 'FILES list not found in scripts/payload_common.py');
  const files = new Set([...block.matchAll(/'([^']+)'/g)].map((m) => m[1]));
  const missing = [...importClosure('server.mjs')].filter((f) => !files.has(f));
  assert.deepEqual(missing, []);
});

test('pi-serverd.mjs import closure is covered by the remote manifest', () => {
  const missing = [...importClosure('pi-serverd.mjs')].filter((f) => !REMOTE_FILES.includes(f));
  assert.deepEqual(missing, []);
});

test('env-server.mjs stays dependency-free', () => {
  assert.deepEqual([...importClosure('env-server.mjs')], []);
});
