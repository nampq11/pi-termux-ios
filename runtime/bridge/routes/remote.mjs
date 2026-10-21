// bridge/routes/remote.mjs — attach to a pi-serverd on an SSH host: host-key
// trust, credential copy, the connect/probe/update handshake, and the proxied
// session operations over remoteState. reconnect/backoff policy lives in
// remote-state.mjs, not here.
import { existsSync } from 'node:fs';
import { json, str } from '../http.mjs';
import { requestIdOf, whenBusyOf } from '../../common.mjs';
import { copyAuthTo, probeRemote, runtimeHash, stopRemoteServer } from '../../remote-provision.mjs';
import { readJson, writeFileAtomic } from '../../fileio.mjs';

export function createRemoteRoutes(deps) {
  const { authPath, remoteState, trustFile, trustStatus, assertTrusted } = deps;
  const prefix = process.env.PREFIX || '';

  return async function remoteRoutes(req, res, url, p, body) {
    if (p === '/api/remote/trust-host' && req.method === 'POST') {
      const target = str(body.target);
      const { fingerprint } = await trustStatus(target);
      if (body.fingerprint !== fingerprint) { json(res, 409, { error: 'host fingerprint changed' }); return true; }
      writeFileAtomic(trustFile, JSON.stringify({ ...readJson(trustFile, {}), [target]: fingerprint }), 0o600);
      json(res, 200, { ok: true });
      return true;
    }
    if (p === '/api/remote/auth-status' && req.method === 'POST') {
      let info;
      try { info = await probeRemote({ ssh: str(body.target), prefix }); } catch (e) {
        // key login rejected (key not installed on the host) vs. other failures
        const loginFailed = /ssh login failed/.test(String(e?.message));
        json(res, 200, { ok: false, loginFailed, error: String(e?.message || e) });
        return true;
      }
      const trust = await trustStatus(str(body.target));
      json(res, 200, { ok: true, needsAuth: info.auth !== '1' && existsSync(authPath), ...trust });
      return true;
    }
    if (p === '/api/remote/copy-auth' && req.method === 'POST') {
      if (!existsSync(authPath)) { json(res, 400, { error: 'no auth.json on this device' }); return true; }
      await assertTrusted(str(body.target));
      const info = await probeRemote({ ssh: str(body.target), prefix });
      if (info.auth === '1') { json(res, 409, { error: 'auth.json already exists on host' }); return true; }
      await copyAuthTo({ ssh: str(body.target), prefix, authFile: authPath });
      json(res, 200, { ok: true });
      return true;
    }
    if (p === '/api/remote/connect' && req.method === 'POST') {
      const target = str(body.target);
      // Ask before anything sensitive happens on the host: copying auth.json, or restarting an outdated daemon.
      const askAuth = body.copyAuth === undefined && existsSync(authPath);
      const askUpdate = body.allowUpdate === undefined;
      if (askAuth || askUpdate) {
        let info;
        try { info = await probeRemote({ ssh: target, prefix }); } catch (e) {
          const msg = String(e?.message || e);
          json(res, 200, { ok: false, loginFailed: /ssh login failed/.test(msg), error: msg });
          return true;
        }
        if (askAuth && info.auth !== '1') {
          const trust = await trustStatus(target);
          if (!trust.trusted) { json(res, 200, { ok: false, needsTrust: true, target, ...trust }); return true; }
          json(res, 200, { ok: false, needsAuth: true, target });
          return true;
        }
        if (askUpdate && info.running === '1' && info.ver !== runtimeHash()) {
          json(res, 200, { ok: false, needsUpdate: true, target, installed: info.ver || null, available: runtimeHash() });
          return true;
        }
      }
      const remote = await remoteState.connect(target, { copyAuth: body.copyAuth === true, allowUpdate: body.allowUpdate === true });
      json(res, 200, { ok: true, serverId: remote.serverId, hostKey: remote.hostKey, sessions: await remote.list() });
      return true;
    }
    if (p === '/api/remote/status' && req.method === 'GET') {
      json(res, 200, { status: remoteState.status, error: remoteState.lastError, sessionId: remoteState.sessionId, log: remoteState.log, target: remoteState.remote?.target ?? null });
      return true;
    }
    if (p === '/api/remote/disconnect' && req.method === 'POST') {
      await remoteState.disconnect();
      json(res, 200, { ok: true });
      return true;
    }
    if (p === '/api/remote/stop' && req.method === 'POST') {
      const target = str(body.target);
      if (!target) { json(res, 400, { error: 'target required' }); return true; }
      await remoteState.disconnect();
      const stopped = await stopRemoteServer({ ssh: target, prefix });
      json(res, 200, { ok: true, stopped });
      return true;
    }
    if (p.startsWith('/api/remote/')) {
      const remote = remoteState.require();
      switch (`${req.method} ${p}`) {
        case 'GET /api/remote/sessions': json(res, 200, await remote.list()); return true;
        case 'GET /api/remote/models': json(res, 200, await remote.models()); return true;
        case 'POST /api/remote/model': {
          if (!body.provider || !body.modelId) { json(res, 400, { error: 'provider+modelId required' }); return true; }
          json(res, 200, await remote.request('configure', [{ model: { provider: str(body.provider), modelId: str(body.modelId) } }]));
          return true;
        }
        case 'POST /api/remote/create':
          json(res, 200, await remote.create({ name: str(body.name, 100) || undefined }));
          return true;
        case 'POST /api/remote/rename':
          json(res, 200, await remote.rename(str(body.id), str(body.name, 100)));
          return true;
        case 'POST /api/remote/delete': {
          if (str(body.id) === remoteState.sessionId) remoteState.sessionId = null;
          json(res, 200, await remote.delete(str(body.id)));
          return true;
        }
        case 'POST /api/remote/attach': {
          await remote.attach(str(body.id));
          remoteState.sessionId = str(body.id);
          json(res, 200, { ok: true, target: remote.client.attachment });
          return true;
        }
        case 'POST /api/remote/prompt':
          json(res, 200, await remote.request('prompt', [{
            message: String(body.message ?? ''), requestId: requestIdOf(body.requestId), whenBusy: whenBusyOf(body.whenBusy),
          }]));
          return true;
        case 'POST /api/remote/abort': json(res, 200, await remote.request('abort', [])); return true;
        case 'POST /api/remote/compact': json(res, 200, await remote.request('compact', [{}])); return true;
        case 'GET /api/remote/state': json(res, 200, await remote.request('state', [])); return true;
        case 'GET /api/remote/history': json(res, 200, await remote.request('history', [{ limit: 200 }])); return true;
        case 'GET /api/remote/events': {
          const after = Number(url.searchParams.get('after') ?? -1);
          const epoch = url.searchParams.get('epoch') || undefined;
          json(res, 200, await remote.request('events', [{ after, epoch }]));
          return true;
        }
        default: json(res, 404, { error: 'not found' }); return true;
      }
    }
    return false;
  };
}
