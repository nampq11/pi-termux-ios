// bridge/routes/accounts.mjs — provider credentials: OAuth device logins
// (their event/prompt pumps), raw API keys, and the provider listing. These
// routes must answer while the harness is still booting — server.mjs's
// readiness gate exempts them.
import { readFileSync } from 'node:fs';
import crypto from 'node:crypto';
import { json, str } from '../http.mjs';
import { ensureModel } from '../../common.mjs';
import { writeFileAtomic } from '../../fileio.mjs';

export function createAccountRoutes(deps) {
  const { ctx, models, credentialStore, deviceIdFile } = deps;

  const oauthLogins = new Map();
  function deviceId() {
    try { return readFileSync(deviceIdFile, 'utf8').trim(); } catch {}
    const id = crypto.randomUUID();
    writeFileAtomic(deviceIdFile, id);
    return id;
  }
  async function giveActiveSessionAModel() {
    const active = deps.active;
    if (active) { try { await ensureModel(active, models, ctx); } catch {} }
  }
  function startOAuthLogin(providerId) {
    const provider = models.getProvider(providerId);
    if (!provider?.auth.oauth) throw new Error(`${providerId} does not support OAuth login`);
    const id = crypto.randomUUID();
    const login = { id, events: [], prompt: null, done: false, error: null, credential: null };
    oauthLogins.set(id, login);
    const interaction = {
      signal: new AbortController().signal,
      notify: (event) => login.events.push(event),
      prompt: (prompt) => new Promise((resolve, reject) => {
        login.prompt = { id: crypto.randomUUID(), prompt, resolve, reject };
      }),
    };
    models.login(providerId, 'oauth', interaction, { getDeviceId: deviceId })
      .then(async (credential) => {
        login.credential = credential;
        login.done = true;
        try { await models.refresh({ providers: [providerId] }); } catch {}
        await giveActiveSessionAModel();
      })
      .catch((error) => { login.error = String(error?.message || error); login.done = true; })
      .finally(() => setTimeout(() => oauthLogins.delete(id), 10 * 60_000).unref());
    return login;
  }

  return async function accountRoutes(req, res, url, p, body) {
    if (p === '/api/oauth/providers' && req.method === 'GET') {
      json(res, 200, { providers: models.getProviders()
        .filter((provider) => Boolean(provider.auth.oauth))
        .map((provider) => ({ id: provider.id, name: provider.name, label: provider.auth.oauth?.loginLabel || provider.auth.oauth?.name })) });
      return true;
    }
    if (p === '/api/oauth/start' && req.method === 'POST') {
      const login = startOAuthLogin(str(body.provider));
      json(res, 200, { id: login.id });
      return true;
    }
    if (p === '/api/oauth/status' && req.method === 'GET') {
      const login = oauthLogins.get(url.searchParams.get('id'));
      if (!login) { json(res, 404, { error: 'unknown login' }); return true; }
      const prompt = login.prompt?.prompt;
      json(res, 200, {
        events: login.events.splice(0), done: login.done, error: login.error,
        prompt: prompt ? { id: login.prompt.id, type: prompt.type, message: prompt.message,
          placeholder: prompt.placeholder, options: prompt.options } : null,
      });
      return true;
    }
    if (p === '/api/oauth/respond' && req.method === 'POST') {
      const login = oauthLogins.get(str(body.id));
      if (!login?.prompt || login.prompt.id !== body.promptId) { json(res, 400, { error: 'no matching prompt' }); return true; }
      const pending = login.prompt;
      login.prompt = null;
      pending.resolve(String(body.value ?? ''));
      json(res, 200, { ok: true });
      return true;
    }
    if (p === '/api/auth' && req.method === 'POST') {
      if (!body.provider) { json(res, 400, { error: 'provider required' }); return true; }
      const provider = str(body.provider);
      if (body.delete) {
        await credentialStore.delete(provider);
        json(res, 200, { ok: true });
        return true;
      }
      if (!body.key) { json(res, 400, { error: 'key required' }); return true; }
      const key = String(body.key).trim();
      await credentialStore.modify(provider, async () => ({ type: 'api_key', key }));
      try { await models.refresh(); } catch {}
      await giveActiveSessionAModel();
      json(res, 200, { ok: true });
      return true;
    }
    if (p === '/api/providers' && req.method === 'GET') {
      json(res, 200, {
        providers: Object.entries(credentialStore.readAll()).map(([provider, c]) => ({
          provider,
          type: c?.type ?? 'api_key',
          keyHint: c?.key ? `…${String(c.key).slice(-4)}` : null,
        })),
      });
      return true;
    }
    return false;
  };
}
