// bridge/routes/sessions.mjs — local sessions and the active conversation:
// create/fork/select/rename/delete, prompt/abort/reset/compact, model choice,
// usage, and the state snapshot the chat page renders.
import { json, str } from '../http.mjs';
import { agentOf, ensureModel, isBusy, pickModel, requestIdOf, whenBusyOf } from '../../common.mjs';
import { deleteSession, renameSession, sessionName, unknownSession } from '../../session-ops.mjs';

export function createSessionRoutes(deps) {
  const { ctx, harness, sessions, models, workDir, remotes } = deps;

  async function activeState() {
    const active = deps.active;
    const view = active ? await active.viewState(ctx) : null;
    try {
      const meta = active ? await sessions.get(active.id) : null;
      return {
        model: agentOf(view).model ?? null,
        busy: isBusy(view),
        inbox: view?.value?.docs?.['pi.inbox'] ?? null,
        usage: view?.value?.docs?.['pi.usage'] ?? null,
        cwd: agentOf(view).cwd ?? workDir,
        sessionId: active ? String(active.id) : null,
        sessionName: meta?.name ?? 'Main',
        remotes: Object.keys(remotes),
      };
    } finally { view?.dispose?.(); }
  }

  async function currentModel(conv) {
    const view = await conv.viewState(ctx);
    try { return agentOf(view).model; } finally { view.dispose?.(); }
  }

  return async function sessionRoutes(req, res, url, p, body) {
    const active = deps.active;
    if (p === '/api/state') {
      json(res, 200, await activeState());
      return true;
    }

    // --- local sessions
    if (p === '/api/sessions' && req.method === 'GET') {
      json(res, 200, { activeId: active ? String(active.id) : null, sessions: await sessions.list() });
      return true;
    }
    if (p === '/api/sessions/new' && req.method === 'POST') {
      // a new session starts with the model the current one uses
      const conversation = await sessions.create(
        { name: sessionName(body.name) },
        { agent: { model: (await currentModel(active)) ?? await pickModel(models) } },
      );
      await deps.activate(conversation);
      json(res, 200, { ok: true, activeId: String(conversation.id) });
      return true;
    }
    if (p === '/api/sessions/fork' && req.method === 'POST') {
      // fork the given (or active) session at its newest entry
      const sourceId = str(body.id || active.id);
      if (!(await sessions.get(sourceId))) throw unknownSession(sourceId);
      const source = await harness.conversation(Number(sourceId), ctx);
      const newest = (await source.entries({}, 1, undefined, ctx)).items[0];
      if (!newest) { json(res, 400, { error: 'nothing to fork yet' }); return true; }
      const srcMeta = await sessions.get(sourceId);
      const fork = await sessions.create({ name: `${srcMeta?.name || `Session ${sourceId}`} (fork)` }, { fork: { conv: source, entryId: newest.id } });
      await deps.activate(fork);
      json(res, 200, { ok: true, activeId: String(fork.id) });
      return true;
    }
    if (p === '/api/sessions/select' && req.method === 'POST') {
      const id = str(body.id);
      if (!(await sessions.get(id))) throw unknownSession(id);
      const conversation = await harness.conversation(Number(id), ctx);
      if (!conversation) { json(res, 404, { error: 'session unavailable' }); return true; }
      await deps.activate(conversation);
      json(res, 200, { ok: true, activeId: String(conversation.id) });
      return true;
    }
    if (p === '/api/sessions/rename' && req.method === 'POST') {
      await renameSession(sessions, str(body.id), body.name);
      json(res, 200, { ok: true });
      return true;
    }
    if (p === '/api/sessions/delete' && req.method === 'POST') {
      const id = str(body.id);
      // stop its work first: a hidden session must not keep running tools
      await deleteSession(harness, sessions, id, ctx);
      // deleting the shown session must leave the chat page on a live one
      // Main (the root conversation) is the guaranteed landing spot; if the
      // deleted session was Main itself, re-register it so the list keeps it.
      if (id === String(deps.active.id)) {
        const root = await harness.root(ctx);
        await sessions.register(root.id, { name: 'Main' });
        await deps.activate(root);
      }
      json(res, 200, { ok: true, activeId: String(deps.active.id) });
      return true;
    }

    // --- active conversation
    if (p === '/api/prompt' && req.method === 'POST') {
      if (!(await ensureModel(active, models, ctx))) { json(res, 400, { error: 'no model: set an API key first' }); return true; }
      const sub = await active.submit({
        type: 'input',
        content: String(body.message || ''),
        requestId: requestIdOf(body.requestId), // exactly-once across client retries
        whenBusy: whenBusyOf(body.whenBusy),
      }, ctx);
      json(res, 200, { ok: true, submissionId: sub.id });
      return true;
    }
    if (p === '/api/abort' && req.method === 'POST') {
      await active.abort(ctx);
      json(res, 200, { ok: true });
      return true;
    }
    if (p === '/api/new' && req.method === 'POST') {
      await active.reset(typeof body.note === 'string' ? body.note : undefined, ctx);
      json(res, 200, { ok: true });
      return true;
    }
    if (p === '/api/compact' && req.method === 'POST') {
      const taskId = await active.compact(typeof body.instructions === 'string' ? body.instructions : undefined, ctx);
      json(res, 200, { ok: true, taskId });
      return true;
    }
    if (p === '/api/usage' && req.method === 'GET') {
      json(res, 200, { session: (await activeState()).usage, total: await harness.usage(ctx) });
      return true;
    }
    if (p === '/api/result' && req.method === 'POST') {
      const sub = await harness.submission(Number(body.id), ctx);
      if (!sub) { json(res, 404, { error: 'unknown submission' }); return true; }
      const settled = await sub.wait(ctx);
      json(res, 200, { status: settled.status });
      return true;
    }
    if (p === '/api/models' && req.method === 'GET') {
      const avail = await models.getAvailable();
      json(res, 200, { models: avail.map((m) => ({ provider: m.provider, modelId: m.id })) });
      return true;
    }
    if (p === '/api/model' && req.method === 'POST') {
      if (!body.provider || !body.modelId) { json(res, 400, { error: 'provider+modelId required' }); return true; }
      await active.configure({ model: { provider: str(body.provider), modelId: str(body.modelId) } }, ctx);
      const view = await active.viewState(ctx);
      try { json(res, 200, { ok: true, applied: agentOf(view).model }); } finally { view.dispose?.(); }
      return true;
    }
    return false;
  };
}
