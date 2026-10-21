// session-ops.mjs — the write-side session rules shared by the phone bridge
// (server.mjs) and the remote daemon (pi-serverd.mjs): one name policy,
// delete = abort-then-remove, and the one-time import of the legacy JSON
// registry. The read side (listing, storage) is common.mjs's sessionStore.
import { unlinkSync } from 'node:fs';
import { readJson, writeFileAtomic } from './fileio.mjs';

/** Session display name: any input stringified, trimmed, capped at 100 chars; blank → undefined. */
export function sessionName(value) {
  const name = String(value ?? '').trim().slice(0, 100);
  return name || undefined;
}

function unknownSession(id) {
  const e = new Error(`unknown session: ${id}`);
  e.status = 404; // the bridge's catch-all maps this onto the HTTP code
  return e;
}

/** Point a session at a new display name; a blank name clears it. */
export async function renameSession(sessions, id, name) {
  if (!(await sessions.get(id))) throw unknownSession(id);
  await sessions.update(id, { name: sessionName(name) });
}

/** Delete a session: abort its running work first (a deleted session must
 * not keep tools running), then drop the registry entry — the transcript
 * itself stays in SQLite. A registry entry whose conversation no longer
 * opens is still deletable. */
export async function deleteSession(harness, sessions, id, ctx) {
  if (!(await sessions.get(id))) throw unknownSession(id);
  const conversation = await harness.conversation(Number(id), ctx);
  if (conversation) await conversation.abort(ctx);
  await sessions.remove(id);
}

/** One-time import of the legacy JSON registry ({id: meta} map) of older
 * releases. Imports only into an empty registry, then moves the file aside
 * (kept as `<file>.migrated`) so a leftover copy cannot resurrect sessions
 * deleted since. Returns the number of imported sessions. */
export async function importLegacySessions(sessions, legacyFile) {
  const legacy = readJson(legacyFile, null)?.sessions;
  if (!legacy || !Object.keys(legacy).length || (await sessions.list()).length) return 0;
  const n = await sessions.migrate(legacy);
  writeFileAtomic(`${legacyFile}.migrated`, JSON.stringify({ sessions: legacy }, null, 2));
  try { unlinkSync(legacyFile); } catch {}
  return n;
}
