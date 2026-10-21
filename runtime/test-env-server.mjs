// test-env-server.mjs — RemoteExecutionEnv against the real env-server.mjs
// over HTTP: text reads through the windowed `readlines` op (including files
// larger than one window), strict-LF line semantics shared with the local
// env, and the whole-file fallback for old env-servers without the op.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import { RemoteExecutionEnv } from './remote-env.mjs';

const root = path.dirname(fileURLToPath(import.meta.url));
const TOKEN = 'test-token-0123456789abcdef';

async function withEnvServer(fn) {
  const dir = mkdtempSync(path.join(tmpdir(), 'pi-env-server-'));
  const child = spawn(process.execPath, ['env-server.mjs'], {
    cwd: root,
    env: { ...process.env, PI_REMOTE_TOKEN: TOKEN, PI_REMOTE_PORT: '0' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const logs = [];
  child.stdout.on('data', (d) => logs.push(String(d)));
  child.stderr.on('data', (d) => logs.push(String(d)));
  try {
    let port = 0;
    for (let i = 0; i < 100 && !port; i++) {
      await sleep(100);
      port = Number(/env-server on 127\.0\.0\.1:(\d+)/.exec(logs.join(''))?.[1]);
    }
    assert.ok(port, `env-server must announce its port; log: ${logs.join('')}`);
    const env = new RemoteExecutionEnv({ cwd: dir, baseUrl: `http://127.0.0.1:${port}`, token: TOKEN });
    return await fn(env, dir);
  } finally {
    child.kill('SIGTERM');
    await sleep(200);
    try { child.kill('SIGKILL'); } catch {}
    rmSync(dir, { recursive: true, force: true });
  }
}

/** A minimal /fs-only server with no `readlines` op — an old env-server. */
async function withLegacyEnvServer(fn) {
  const dir = mkdtempSync(path.join(tmpdir(), 'pi-env-legacy-'));
  const reads = [];
  const server = http.createServer(async (req, res) => {
    const chunks = [];
    for await (const c of req) chunks.push(c);
    const body = JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}');
    if (body.op === 'read') {
      reads.push(body.path);
      const contentB64 = (await import('node:fs')).readFileSync(body.path).toString('base64');
      res.writeHead(200, { 'content-type': 'application/json' });
      return res.end(JSON.stringify({ contentB64 }));
    }
    res.writeHead(400, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: { code: 'invalid', message: `unknown op ${body.op}` } }));
  });
  try {
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    const port = server.address().port;
    const env = new RemoteExecutionEnv({ cwd: dir, baseUrl: `http://127.0.0.1:${port}`, token: TOKEN });
    return await fn(env, dir, reads);
  } finally {
    server.close();
    rmSync(dir, { recursive: true, force: true });
  }
}

async function readAllLines(env, p) {
  const opened = await env.openTextLineReader(p);
  assert.ok(opened.ok, `openTextLineReader failed: ${JSON.stringify(opened.error)}`);
  const lines = [];
  for (;;) {
    const line = await opened.value.readLine();
    assert.ok(line.ok, `readLine failed: ${JSON.stringify(line.error)}`);
    if (line.value === undefined) return lines;
    lines.push(line.value);
  }
}

test('readTextLines returns whole-file lines without a phantom trailing empty line', async () => {
  await withEnvServer(async (env, dir) => {
    writeFileSync(path.join(dir, 'notes.txt'), 'alpha\nbeta\ngamma\n');
    const all = await env.readTextLines('notes.txt');
    assert.deepEqual(all.value, ['alpha', 'beta', 'gamma']);

    writeFileSync(path.join(dir, 'partial.txt'), 'one\ntwo');
    const partial = await env.readTextLines('partial.txt');
    assert.deepEqual(partial.value, ['one', 'two']);
  });
});

test('readTextLines maxLines fetches only the prefix window', async () => {
  await withEnvServer(async (env, dir) => {
    const lines = Array.from({ length: 2500 }, (_, i) => `line-${i}`);
    writeFileSync(path.join(dir, 'big.txt'), `${lines.join('\n')}\n`);
    assert.deepEqual((await env.readTextLines('big.txt', { maxLines: 3 })).value, ['line-0', 'line-1', 'line-2']);
    assert.deepEqual((await env.readTextLines('big.txt', { maxLines: 0 })).value, []);
    const many = await env.readTextLines('big.txt', { maxLines: 2500 });
    assert.deepEqual(many.value, lines);
  });
});

test('openTextLineReader pages through files larger than one window', async () => {
  await withEnvServer(async (env, dir) => {
    const lines = Array.from({ length: 2500 }, (_, i) => `row-${i}`);
    writeFileSync(path.join(dir, 'wide.txt'), `${lines.join('\n')}\n`);
    const got = await readAllLines(env, 'wide.txt');
    assert.equal(got.length, 2500);
    assert.deepEqual(got.slice(0, 2), [{ text: 'row-0', terminated: true }, { text: 'row-1', terminated: true }]);
    assert.deepEqual(got.at(-1), { text: 'row-2499', terminated: true });

    // final line without a trailing newline reports terminated: false
    writeFileSync(path.join(dir, 'tail.txt'), 'a\nb');
    const tail = await readAllLines(env, 'tail.txt');
    assert.deepEqual(tail, [{ text: 'a', terminated: true }, { text: 'b', terminated: false }]);
  });
});

test('old env-servers without readlines fall back to whole-file reads', async () => {
  await withLegacyEnvServer(async (env, dir, reads) => {
    writeFileSync(path.join(dir, 'legacy.txt'), 'x\ny\nz\n');
    const prefix = await env.readTextLines('legacy.txt', { maxLines: 2 });
    assert.ok(prefix.ok, `readTextLines must fall back, got ${JSON.stringify(prefix.error)}`);
    assert.deepEqual(prefix.value, ['x', 'y']);
    const lines = await readAllLines(env, 'legacy.txt');
    assert.deepEqual(lines.map((l) => l.text), ['x', 'y', 'z']);
    assert.deepEqual(lines.at(-1), { text: 'z', terminated: true });
    assert.equal(reads.length, 2, 'each fallback read must be one whole-file request');
  });
});

test('exec streams command output and exit code', async () => {
  await withEnvServer(async (env) => {
    const out = [];
    const r = await env.exec('printf hello; printf world', { onOutput: (t) => out.push(t) });
    assert.ok(r.ok);
    assert.equal(r.value.exitCode, 0);
    assert.equal(out.join(''), 'helloworld');
  });
});
