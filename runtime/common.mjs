// common.mjs — shared pieces of server.mjs (phone bridge) and pi-serverd.mjs
// (remote session daemon): credential store, harness setup, durable session
// registry and request helpers. File primitives live in fileio.mjs.
import { statSync } from 'node:fs';
import { Type } from '@earendil-works/pi-ai';
import { createModels } from '@earendil-works/pi-ai/models';
import { builtinProviders } from '@earendil-works/pi-ai/providers/all';
import {
  AssistantEntry, configure, createRegistry, defineDoc, defineExtension, defineTool,
  Harness,
} from '@earendil-works/pi-durable';
import { CodingTools } from '@earendil-works/pi-durable/tools';
import { openNodeSqliteStorage } from '@earendil-works/pi-durable/storage/sqlite/node';
import { readJson, withFileLock, writeFileAtomic } from './fileio.mjs';

// --- credentials: ~/.pi/agent/auth.json (pi CLI format) -------------------------

export function createCredentialStore(authPath) {
  let cache = null;
  let cacheMtime = -1;
  const read = () => {
    let mtime = -1;
    try { mtime = statSync(authPath).mtimeMs; } catch { cache = {}; cacheMtime = -1; return cache; }
    if (cache && mtime === cacheMtime) return cache;
    cache = readJson(authPath, {});
    cacheMtime = mtime;
    return cache;
  };
  // Re-read inside the lock: a concurrent OAuth refresh (rotating refresh
  // token) must not be overwritten by a stale copy.
  const update = (fn) => withFileLock(authPath, async () => {
    const data = readJson(authPath, {});
    const result = await fn(data);
    writeFileAtomic(authPath, JSON.stringify(data, null, 2));
    cache = null;
    return result;
  });
  return {
    readAll: () => read(),
    read: async (providerId) => read()[providerId],
    list: async () => Object.entries(read()).map(([providerId, c]) => ({ providerId, type: c?.type })),
    modify: (providerId, fn) => update(async (data) => {
      const next = await fn(data[providerId]);
      if (next === undefined) delete data[providerId]; else data[providerId] = next;
      return next;
    }),
    delete: (providerId) => update(async (data) => { delete data[providerId]; }),
  };
}

export async function createModelCatalog(credentials) {
  const models = createModels({ credentials });
  for (const p of builtinProviders()) models.setProvider(p);
  if (process.env.PI_TEST_FAUX) await installTestFaux(models);
  return models;
}

// Test hook only (PI_TEST_FAUX=1): a scripted model, no network. Echoes the
// last user message; "!bash <cmd>" / "!sub <task>" request a tool call first.
async function installTestFaux(models) {
  const { fauxProvider, fauxAssistantMessage, fauxToolCall } = await import('@earendil-works/pi-ai/providers/faux');
  const faux = fauxProvider();
  models.setProvider(faux.provider);
  const textOf = (m) => (typeof m?.content === 'string' ? m.content
    : (m?.content ?? []).filter((c) => c.type === 'text').map((c) => c.text).join(''));
  const respond = (context) => {
    faux.appendResponses([respond]);
    const last = context.messages[context.messages.length - 1];
    if (last?.role === 'toolResult') return fauxAssistantMessage(`tool said: ${textOf(last).slice(0, 200)}`);
    const text = textOf([...context.messages].reverse().find((m) => m.role === 'user'));
    const cmd = /^!(bash|sub) (.+)$/s.exec(text);
    if (cmd?.[1] === 'bash') return fauxAssistantMessage(fauxToolCall('bash', { command: cmd[2] }), { stopReason: 'toolUse' });
    if (cmd?.[1] === 'sub') return fauxAssistantMessage(fauxToolCall('subagent', { task: cmd[2] }), { stopReason: 'toolUse' });
    return fauxAssistantMessage(`echo: ${text}`);
  };
  faux.setResponses([respond]);
}

export async function pickModel(models) {
  const provider = process.env.PI_PROVIDER;
  const modelId = process.env.PI_MODEL;
  if (provider && modelId) return { provider, modelId };
  try {
    const m = (await models.getAvailable())[0];
    if (m) return { provider: m.provider, modelId: m.id };
  } catch (e) { console.error('pickModel:', e?.message || e); }
  return undefined;
}

// --- view helpers ------------------------------------------------------------------
// viewState().value is { conversation, entries, docs }; agent choices live in
// docs['pi.agent'], the running work in docs['pi.live'] (`run` while busy).

export const agentOf = (view) => view?.value?.docs?.['pi.agent'] ?? {};
export const isBusy = (view) => Boolean(view?.value?.docs?.['pi.live']?.run);

/** Give a conversation without a model the current default (or fixes an uncredentialed model). */
export async function ensureModel(conv, models, ctx) {
  const view = await conv.viewState(ctx);
  try {
    const current = agentOf(view).model;
    const available = await models.getAvailable().catch(() => []);
    if (current && available.some(m => m.provider === current.provider && m.id === current.modelId)) {
      return current;
    }
    const m = (await pickModel(models)) || (available[0] ? { provider: available[0].provider, modelId: available[0].id } : undefined);
    if (m) await conv.configure({ model: m }, ctx);
    return m;
  } finally { view.dispose?.(); }
}

// --- subagent extension (pi-durable README pattern) ------------------------------

export const Subagent = defineExtension({
  name: 'subagent',
  tools: [
    defineTool({
      name: 'subagent',
      description: 'Delegate a self-contained task to a subagent conversation and return its final answer.',
      parameters: Type.Object({ task: Type.String() }),
      replay: 'safe', // a rerun after a crash finds the same child and submission
      execute: async (args, api, context) => {
        const childId = await api.commit(async (tx) => {
          const existing = (await tx.scanConversations({ ownerTaskId: api.taskId }, 1)).items[0];
          if (existing !== undefined) return existing.id;
          const created = await tx.createConversation({ ownership: { kind: 'task', taskId: api.taskId } });
          await configure(tx, created.id, { extensions: { remove: [Subagent] } });
          return created.id;
        }, context);
        await api.details({ conversationId: childId }, context); // lets the UI show the child
        const conv = await api.conversation(childId, context);
        if (!conv) return { content: [{ type: 'text', text: 'subagent conversation unavailable' }] };
        const settled = await (await conv.submit(
          { type: 'input', content: args.task, requestId: `subagent:${api.taskId}` }, context)).wait(context);
        let text = settled.status;
        if (settled.status === 'done' && settled.answer) {
          // the child handle has no commit(); read the answer entry through the tool's api
          const entry = await api.commit((tx) => tx.entry(AssistantEntry, settled.answer), context);
          const parts = entry?.model?.[0]?.content ?? [];
          text = Array.isArray(parts)
            ? parts.filter((c) => c?.type === 'text').map((c) => c.text).join('\n')
            : String(parts);
        }
        return { content: [{ type: 'text', text: text || settled.status }] };
      },
    }),
  ],
});

export const HARNESS_SETTINGS = {
  stream: { timeoutMs: 180_000 },
  retry: { maxRetries: 3 },
  compaction: { enabled: true, reserveTokens: 16384 },
};

// --- durable session registry ------------------------------------------------------
// Session metadata lives in a Session-scoped pi-durable document, written in the
// same commit that creates the conversation — no JSON side file that can be
// truncated or disagree with the transcripts.

export const SessionRegistry = defineDoc({
  kind: 'app.sessions',
  version: 1,
  scope: 'session',
  initial: () => ({ sessions: {}, activeId: null }),
});

export async function openHarness({ dbPath, models, env, extensions = [] }, ctx) {
  const registry = createRegistry();
  registry.install(CodingTools);
  for (const ext of extensions) registry.install(ext);
  const storage = await openNodeSqliteStorage(dbPath);
  const harness = await Harness.open(storage, { models, registry, env, settings: HARNESS_SETTINGS }, ctx);
  return harness;
}

// documents are strict JSON: no undefined values
const defined = (obj) => Object.fromEntries(Object.entries(obj ?? {}).filter(([, v]) => v !== undefined));

export function sessionStore(harness, ctx) {
  const registryOf = async () => (await harness.snapshot(SessionRegistry, ctx)) ?? { sessions: {}, activeId: null };
  // Session docs are edited through any conversation's commit; the root is stable.
  const commit = async (fn) => (await harness.root(ctx)).commit(async (tx) => fn(await tx.doc(SessionRegistry)), ctx);
  return {
    async list() {
      const reg = await registryOf();
      return Object.entries(reg.sessions)
        .map(([id, s]) => ({ id, ...s }))
        .sort((a, b) => String(b.created ?? '').localeCompare(String(a.created ?? '')));
    },
    async get(id) { return (await registryOf()).sessions[String(id)]; },
    async activeId() { return (await registryOf()).activeId; },
    setActive: (id) => commit((reg) => { reg.activeId = String(id); }),
    remove: (id) => commit((reg) => { delete reg.sessions[String(id)]; }),
    update: (id, patch) => commit((reg) => {
      const s = reg.sessions[String(id)];
      if (s) for (const [k, v] of Object.entries(patch)) { if (v === undefined) delete s[k]; else s[k] = v; }
    }),
    /** Register metadata for an existing conversation (root, migration). */
    register: (id, meta) => commit((reg) => {
      if (!reg.sessions[String(id)]) reg.sessions[String(id)] = { created: new Date().toISOString(), ...defined(meta) };
    }),
    /** Create a conversation and its registry entry in one commit. */
    async create(meta, { agent, fork } = {}) {
      const init = async (tx, id) => {
        const reg = await tx.doc(SessionRegistry);
        reg.sessions[String(id)] = { created: new Date().toISOString(), ...defined(meta) };
      };
      if (fork) return fork.conv.fork(fork.entryId, { ownership: { kind: 'ownerless' }, init }, ctx);
      return harness.createConversation({ ownership: { kind: 'ownerless' }, agent, init }, ctx);
    },
    /** One-time import of a legacy JSON registry ({id: meta} map). */
    async migrate(legacy) {
      const entries = Object.entries(legacy ?? {});
      if (!entries.length) return 0;
      await commit((reg) => {
        for (const [id, meta] of entries) {
          const { id: _ignored, conversationId: _c, ...rest } = meta ?? {};
          if (!reg.sessions[id]) reg.sessions[id] = defined(rest);
        }
      });
      return entries.length;
    },
  };
}

// --- request helpers ---------------------------------------------------------------

/** Accept a client-generated idempotency key (exactly-once submit). */
export function requestIdOf(value) {
  const id = typeof value === 'string' ? value.trim() : '';
  return /^[\w:.-]{8,128}$/.test(id) ? id : undefined;
}

export function whenBusyOf(value) {
  return value === 'steer' || value === 'reject' ? value : undefined;
}
