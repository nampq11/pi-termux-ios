// The updater must refuse to spawn npm on iOS instead of dying mid-install:
// exec() is denied there, so the npm child would only surface an EPERM after
// the UI has already committed to an update. The refusal must leave the
// updater idle, not "running".
import test from 'node:test';
import assert from 'node:assert/strict';
import { createSystemRoutes } from './bridge/routes/system.mjs';

function callRoute(routes, routePath, method) {
  return new Promise((resolve) => {
    const res = {
      code: 0,
      writeHead(code) { this.code = code; },
      end(body) { this.body = JSON.parse(body); resolve(this); },
    };
    routes({ method }, res, new URL(`http://x${routePath}`), routePath, {});
  });
}

test('POST /api/pi-update refuses on iOS without spawning npm', async () => {
  const routes = createSystemRoutes({ root: process.cwd(), prefix: '', homeDir: process.env.HOME, ios: true });
  const r = await callRoute(routes, '/api/pi-update', 'POST');
  assert.equal(r.code, 200);
  assert.equal(r.body.started, false);
  assert.match(r.body.error, /app release/);
  const status = await callRoute(routes, '/api/pi-update-status', 'GET');
  assert.equal(status.body.running, false);
});
