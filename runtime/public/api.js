// api.js — the one HTTP client for the bridge. A page binds its session token
// once (initApi(renderMenu())) and then sends every request through these
// helpers; no page hand-rolls fetch headers or token query strings.
let token = '';

/** Bind the client to this page's session token (renderMenu's return value). */
export function initApi(t) { token = t || ''; }

/** URL with the token attached as a query param — EventSource, links and plain
 * GETs use it because they cannot send headers. */
export function authUrl(path, params = {}) {
  return `${path}?${new URLSearchParams({ token, ...params })}`;
}

/** GET JSON. Network/parse failures resolve to { error } so pages can render
 * the failure inline instead of throwing. */
export async function getJson(path, params) {
  try {
    const r = await fetch(authUrl(path, params));
    return await r.json();
  } catch (e) { return { error: String(e?.message || e) }; }
}

/** POST JSON. Retries with the same body on reconnect-signalling 503s and
 * network failures — safe because retried calls carry a requestId or are
 * idempotent. */
export async function postJson(path, body, { retries = 0 } = {}) {
  for (let attempt = 0; ; attempt++) {
    try {
      const r = await fetch(path, {
        method: 'POST',
        headers: { 'content-type': 'application/json', 'x-token': token },
        body: JSON.stringify(body ?? {}),
      });
      const j = await r.json().catch(() => ({ error: `http ${r.status}` }));
      if ((r.status === 503 && j.reconnecting) && attempt < retries) {
        await new Promise((res) => setTimeout(res, 1500));
        continue;
      }
      return j;
    } catch (e) {
      if (attempt >= retries) return { error: String(e?.message || e) };
      await new Promise((res) => setTimeout(res, 800 * (attempt + 1)));
    }
  }
}
