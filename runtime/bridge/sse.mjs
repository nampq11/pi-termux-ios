// bridge/sse.mjs — one watchEvents stream per client. A stream's snapshot is
// the state at attach time; giving every (re)connecting client its own stream
// delivers the current state plus deltas (late join). server.mjs re-attaches
// every client whenever the active conversation changes.
import { watchEvents } from '@earendil-works/pi-durable';

export function createSseHub({ harness, sessions, ctx, getActive }) {
  const clients = new Set();

  function write(client, event) {
    try { client.res.write(`data: ${JSON.stringify(event)}\n\n`); } catch {}
  }

  async function attach(client) {
    const previous = client.stream;
    client.stream = null;
    if (previous) { try { await previous.stop(); } catch {} }
    const active = getActive();
    if (!active || client.closed) return;
    const conversationId = active.id;
    const stream = await watchEvents(harness, conversationId, ctx);
    if (client.closed) { await stream.stop(); return; }
    client.stream = stream;
    const meta = await sessions.get(conversationId);
    write(client, {
      type: 'bridge_snapshot', snapshot: stream.snapshot,
      sessionId: String(conversationId), sessionName: meta?.name ?? `Session ${conversationId}`,
    });
    stream.start(async (events) => {
      if (client.stream !== stream) return;
      for (const e of events) write(client, e);
    });
  }

  const ping = setInterval(() => {
    for (const client of clients) { try { client.res.write(': ping\n\n'); } catch {} }
  }, 20_000);
  ping.unref();

  return {
    clients,
    write,
    attach,
    /** Disconnect one client: mark it closed, forget it, stop its stream. */
    async detach(client) {
      client.closed = true;
      clients.delete(client);
      try { await client.stream?.stop(); } catch {}
    },
    /** Stop every client's event stream and close its response. */
    async stopAll() {
      for (const client of clients) { try { await client.stream?.stop(); client.res.end(); } catch {} }
    },
  };
}
