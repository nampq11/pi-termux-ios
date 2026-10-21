// Minimal HTTP+SSE bridge: web UI <-> pi-durable Harness (crash-safe, SQLite storage).
// Env: HOME (set by app), PI_PORT (default 0=ephemeral, port written to
// $HOME/.pi-mobile/port), PI_WORKDIR (agent cwd), PI_SHELL (bash path),
// PI_REMOTES (JSON: {"name": {"url": "http://host:port", "token": "..."}}, merged
// over $HOME/.pi-mobile/remotes.json) — a conversation whose cwd is
// "remote:<name>:/path" runs its tools on that host.
//
// This file is the composition root and dispatcher: it boots the shared state,
// then hands each request to the route groups from bridge/routes/ in a fixed
// order (spaces before the readiness gate, accounts after it). No router
// abstraction — plain ifs all the way down.
import http from 'node:http';
import { MobileSpaces } from './spaces-mobile.mjs';
import { WebSocketServer } from 'ws';
import { existsSync, mkdirSync, unlinkSync } from 'node:fs';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { BACKGROUND_CONTEXT } from '@earendil-works/chord/context';
import { NodeExecutionEnv } from '@earendil-works/pi-durable/env/node';
import { RemoteExecutionEnv } from './remote-env.mjs';
import { parseSshTarget, sshHostFingerprint } from './remote-client.mjs';
import { createRemoteState } from './remote-state.mjs';
import { setSshBackend } from './ssh-transport.mjs';
import { jsSshBackend } from './ssh-js-backend.mjs';
import { acquireOwnerLock, readJson, writeFileAtomic } from './fileio.mjs';
import { importLegacySessions } from './session-ops.mjs';
import {
  createCredentialStore, createModelCatalog, ensureModel, openHarness, pickModel, sessionStore, Subagent,
} from './common.mjs';
import { createTokenAuth, createStaticServer, hostAllowed, json, readBody } from './bridge/http.mjs';
import { createSseHub } from './bridge/sse.mjs';
import { createPtyHandler } from './bridge/pty.mjs';
import { createSystemRoutes } from './bridge/routes/system.mjs';
import { createSessionRoutes } from './bridge/routes/sessions.mjs';
import { createSshRoutes } from './bridge/routes/ssh.mjs';
import { createRemoteRoutes } from './bridge/routes/remote.mjs';
import { createAccountRoutes } from './bridge/routes/accounts.mjs';

const ctx = BACKGROUND_CONTEXT;
const ROOT = path.dirname(fileURLToPath(import.meta.url));
const HOME_DIR = process.env.HOME || ROOT;
const WORKDIR = process.env.PI_WORKDIR || HOME_DIR;
const PREFIX = process.env.PREFIX || '';
const AGENT_DIR = path.join(HOME_DIR, '.pi', 'agent');
const AUTH_PATH = path.join(AGENT_DIR, 'auth.json');
const STATE_DIR = path.join(HOME_DIR, '.pi-mobile');
// iOS runs this script inside the app process (no child processes, the engine
// cannot restart, and process.exit would kill the whole app). Fatal boot
// errors are reported through this file; the Swift shell polls it.
const IOS = process.env.PI_PLATFORM === 'ios';
// iOS denies exec(): reach SSH hosts through the pure-JS client instead of
// the OpenSSH binary every other platform uses.
if (IOS) setSshBackend(jsSshBackend);
const FATAL_FILE = path.join(STATE_DIR, 'fatal');
const PORT_FILE = path.join(STATE_DIR, 'port');
if (IOS) {
  // last-resort guard before anything else runs: an uncaught exception during
  // module init would kill the whole app (the engine runs in-process and
  // cannot restart). Report via the fatal file; the app shell shows it.
  process.on('uncaughtException', (error) => {
    console.error('uncaughtException:', error?.stack || error);
    try {
      mkdirSync(STATE_DIR, { recursive: true });
      try { unlinkSync(PORT_FILE); } catch {}
      writeFileAtomic(FATAL_FILE, String(error?.message || error));
    } catch {}
  });
}
const mobileSpaces = new MobileSpaces(path.join(STATE_DIR, 'space-profile.json'));
const TOKEN_FILE = path.join(STATE_DIR, 'token');
const LEGACY_SESSIONS_FILE = path.join(STATE_DIR, 'sessions.json');
const DEVICE_ID_FILE = path.join(STATE_DIR, 'device-id');
const CLIENTS_FILE = path.join(STATE_DIR, 'clients.json');
const TRUST_FILE = path.join(STATE_DIR, 'trusted-hosts.json');
async function trustStatus(target) {
  parseSshTarget(target);
  const fingerprint = await sshHostFingerprint(target, PREFIX);
  if (!fingerprint) throw new Error('SSH host fingerprint not available: cannot transfer credentials');
  return { fingerprint, trusted: readJson(TRUST_FILE, {})[target] === fingerprint };
}
async function assertTrusted(target) {
  if (!(await trustStatus(target)).trusted) throw Object.assign(new Error('confirm the SSH host fingerprint before copying credentials'), { status: 403 });
}
const PUBLIC = path.join(ROOT, 'public');
const REMOTES = {
  ...readJson(path.join(STATE_DIR, 'remotes.json'), {}),
  ...JSON.parse(process.env.PI_REMOTES || '{}'),
};

await mkdir(STATE_DIR, { recursive: true });
// pi-durable allows one storage owner: stop an orphaned predecessor first
const releaseLock = await acquireOwnerLock(path.join(STATE_DIR, 'server.lock'), 'server.mjs');

// --- credentials / models ---------------------------------------------------------

const credentialStore = createCredentialStore(AUTH_PATH);
const models = await createModelCatalog(credentialStore);

// --- execution environment ---------------------------------------------------------

function envFor({ cwd } = {}) {
  const dir = cwd ?? WORKDIR;
  const m = /^remote:([^:]+):(.+)$/.exec(dir);
  if (m) {
    const remote = REMOTES[m[1]];
    if (!remote) throw new Error(`unknown remote "${m[1]}" (configure ${path.join(STATE_DIR, 'remotes.json')})`);
    return new RemoteExecutionEnv({ cwd: m[2], baseUrl: remote.url, token: remote.token });
  }
  const prefix = PREFIX;
  const bash = prefix && existsSync(path.join(prefix, 'bin/bash'))
    ? path.join(prefix, 'bin/bash') : undefined;
  const shellEnv = prefix
    ? { ...process.env, PATH: `${prefix}/bin:/system/bin:${process.env.PATH || ''}` }
    : undefined;
  return new NodeExecutionEnv({ cwd: dir, shellPath: process.env.PI_SHELL || bash, shellEnv });
}

// --- harness + durable session registry ---------------------------------------------

const harness = await openHarness({ dbPath: path.join(STATE_DIR, 'harness.sqlite'), models, env: envFor, extensions: [Subagent] }, ctx);
const sessions = sessionStore(harness, ctx);
let active = null; // the conversation the chat page shows

// one watchEvents stream per (re)connecting client: snapshot plus deltas
const sseHub = createSseHub({ harness, sessions, ctx, getActive: () => active });

async function initHarness() {
  const root = await harness.root(ctx, { agent: { model: await pickModel(models) } });
  await importLegacySessions(sessions, LEGACY_SESSIONS_FILE);
  await sessions.register(root.id, { name: 'Main' });
  // reopen the session that was active before the restart
  const remembered = await sessions.activeId();
  const conv = (remembered && (await sessions.get(remembered)) && await harness.conversation(Number(remembered), ctx)) || root;
  await activate(conv, { persist: false });
  await ensureModel(active, models, ctx);
  harness.resume(); // continue runs the last process left unfinished
}

async function activate(conversation, { persist = true } = {}) {
  active = conversation;
  if (persist) await sessions.setActive(conversation.id);
  for (const client of sseHub.clients) await sseHub.attach(client);
}

// --- auth ---------------------------------------------------------------------------

const token = existsSync(TOKEN_FILE)
  ? (await readFile(TOKEN_FILE, 'utf8')).trim()
  : await (async () => {
      const t = crypto.randomBytes(24).toString('base64url');
      await writeFile(TOKEN_FILE, t, { mode: 0o600 });
      return t;
    })();
const authed = createTokenAuth(token);
const serveStatic = createStaticServer({ publicDir: PUBLIC, injectIosHtmlFlag: IOS });

// --- remote pi-server attach state ------------------------------------------------------
// pi-client never reconnects on its own: a lost tunnel is rebuilt here with
// backoff and the last session is attached again. Prompts carry a requestId,
// so a retried prompt is never answered twice.

const remoteState = createRemoteState({
  prefix: PREFIX, stateDir: STATE_DIR, authFile: AUTH_PATH, assertTrusted,
});

// --- API -----------------------------------------------------------------------------

// Everything the route groups need. `active` is read through a getter because
// activate() rebinds it.
const deps = {
  ctx, root: ROOT, prefix: PREFIX, homeDir: HOME_DIR, workDir: WORKDIR, ios: IOS,
  harness, sessions, models, credentialStore, remotes: REMOTES, remoteState,
  authFile: AUTH_PATH, deviceIdFile: DEVICE_ID_FILE, clientsFile: CLIENTS_FILE, trustFile: TRUST_FILE,
  trustStatus, assertTrusted,
  get active() { return active; },
  activate,
};
// ordered dispatch: spaces before the readiness gate, accounts after it
const routeGroups = [
  createSystemRoutes(deps),
  createSessionRoutes(deps),
  createSshRoutes(deps),
  createRemoteRoutes(deps),
  createAccountRoutes(deps),
];

async function handleApi(req, res, url, p) {
  const body = req.method === 'POST' ? await readBody(req) : {};
  if (p.startsWith('/api/spaces/') && ['GET', 'POST'].includes(req.method)) {
    const method = p.slice('/api/spaces/'.length);
    if (req.method === 'GET' && method !== 'status') throw Object.assign(new Error('use POST'), { status: 405 });
    return json(res, 200, await mobileSpaces.call(method, body));
  }
  if (!active && !p.startsWith('/api/oauth') && p !== '/api/auth' && p !== '/api/providers') {
    throw Object.assign(new Error('harness not ready'), { status: 503 });
  }

  for (const routes of routeGroups) {
    if (await routes(req, res, url, p, body)) return;
  }
  return json(res, 404, { error: 'not found' });
}

let listenPort = 0;
const server = http.createServer(async (req, res) => {
  if (!hostAllowed(req, listenPort)) { res.writeHead(421); return res.end(); }
  const url = new URL(req.url, 'http://localhost');
  const p = url.pathname;

  if (p === '/api/events' && req.method === 'GET') {
    if (!authed(req)) return json(res, 401, { error: 'unauthorized' });
    res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache', connection: 'keep-alive' });
    res.write(`data: ${JSON.stringify({ type: 'bridge_connected' })}\n\n`);
    const client = { res, stream: null, closed: false };
    sseHub.clients.add(client);
    req.on('close', () => { sseHub.detach(client); });
    try { await sseHub.attach(client); } catch (e) { sseHub.write(client, { type: 'bridge_error', error: String(e?.message || e) }); }
    return;
  }

  if (p.startsWith('/api/')) {
    if (!authed(req)) return json(res, 401, { error: 'unauthorized' });
    try {
      return await handleApi(req, res, url, p);
    } catch (e) {
      if (res.headersSent) { try { res.end(); } catch {} return; }
      const httpCode = (Number.isInteger(e?.status) && e.status >= 100 && e.status <= 599) ? e.status : 500;
      return json(res, httpCode, { error: String(e?.message || e), reconnecting: e?.reconnecting || undefined });
    }
  }

  return serveStatic(res, p);
});

// --- interactive pi CLI over WebSocket + util-linux `script` pty -------------

const wss = new WebSocketServer({ noServer: true, maxPayload: 1024 * 1024 });
const startPty = createPtyHandler({ root: ROOT, prefix: PREFIX, workDir: WORKDIR });
server.on('upgrade', (req, socket, head) => {
  const url = new URL(req.url, 'http://localhost');
  if (url.pathname !== '/pty' || !hostAllowed(req, listenPort) || !authed(req)) { socket.destroy(); return; }
  wss.handleUpgrade(req, socket, head, (ws) => startPty(ws, url));
});

// --- start / stop ------------------------------------------------------------

await mkdir(WORKDIR, { recursive: true });
let bootFailed = false;
try {
  await initHarness();
} catch (e) {
  // a bridge without a harness is useless: exit so the supervisor restarts it with backoff
  console.error('initHarness:', e?.stack || e);
  try { await harness.close(ctx); } catch {}
  releaseLock();
  if (IOS) {
    // no supervisor and no restart on iOS: surface the error to the app shell
    try { writeFileAtomic(FATAL_FILE, String(e?.message || e)); } catch {}
    bootFailed = true;
  } else process.exit(1);
}
if (!bootFailed) server.listen(Number(process.env.PI_PORT || 0), '127.0.0.1', async () => {
  listenPort = server.address().port;
  writeFileAtomic(PORT_FILE, String(listenPort), 0o600);
  try { unlinkSync(FATAL_FILE); } catch {}
  console.log(`pi-mobile durable bridge on 127.0.0.1:${listenPort}`);
});

let stopping = false;
async function shutdown(signal) {
  if (stopping) return;
  stopping = true;
  console.log(`bridge: ${signal}, closing`);
  try { unlinkSync(PORT_FILE); } catch {}
  server.close();
  await sseHub.stopAll();
  await remoteState.disconnect();
  try { await harness.close(ctx); } catch (e) { console.error('harness.close:', e?.message || e); }
  releaseLock();
  process.exit(0);
}
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
