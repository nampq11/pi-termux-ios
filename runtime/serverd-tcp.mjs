// Opt-in loopback TCP listener for pi-serverd, so clients behind a pure-JS
// SSH tunnel (iOS: no process spawning, and ssh2 cannot open OpenSSH
// streamlocal channels) can reach the pi-server protocol over direct-tcpip.
//
// Same listener contract as @earendil-works/pi-server's UnixListener
// (start(accept)/close, connection with closed/send/close), so Server takes
// both. The wire protocol is identical to the unix transport — length-framed
// messages, no framing changes here.
//
// Security: binds 127.0.0.1 only. The pi-server protocol is unauthenticated
// by design; the unix socket is protected by fs permissions, the TCP listener
// by loopback. Anyone who can reach it can already run code on this host as
// this user (SSH key or local shell), so this adds no new privilege — but on
// multi-user hosts other local accounts can speak the protocol. Only enable
// PI_SERVERD_TCP_PORT on single-user hosts.
import net from 'node:net';

const DEFAULT_GRACEFUL_CLOSE_MS = 5_000;

/** A Server-protocol connection over one TCP socket. Mirrors the semantics
 * pi-server's UnixByteConnection exposes to the Server: send() resolves when
 * the bytes are handed to the socket, close() ends gracefully with a final
 * frame and force-destroys after the grace period. */
class TcpByteConnection {
  #socket;
  #gracefulCloseMs;
  #closed = false;

  constructor(socket, gracefulCloseMs) {
    this.#socket = socket;
    this.#gracefulCloseMs = gracefulCloseMs;
  }

  get closed() { return this.#closed || this.#socket.destroyed; }

  send(chunk) {
    if (this.closed) return Promise.reject(new Error('TCP connection is closed'));
    return new Promise((resolve, reject) => {
      this.#socket.write(chunk, (e) => (e ? reject(e) : resolve()));
    });
  }

  close(finalChunk) {
    if (this.closed) { this.#markClosed(); return Promise.resolve(); }
    return new Promise((resolve) => {
      const timer = setTimeout(() => { this.#socket.destroy(); this.#markClosed(); }, this.#gracefulCloseMs);
      timer.unref();
      this.#socket.once('close', () => { clearTimeout(timer); this.#markClosed(); resolve(); });
      try { this.#socket.end(finalChunk ?? undefined); } catch { this.#socket.destroy(); }
    });
  }

  #markClosed() { this.#closed = true; }
}

export function createTcpListener({ host = '127.0.0.1', port, gracefulCloseTimeoutMs = DEFAULT_GRACEFUL_CLOSE_MS }) {
  if (!Number.isInteger(port) || port < 0 || port > 65535) {
    throw new TypeError(`TCP listener port must be an integer between 0 and 65535, got ${port}`);
  }
  let server = null;
  let closing = false;
  const connections = new Set();
  return {
  /** The OS-assigned port once started (undefined before start / after close). */
  get boundPort() { return server ? server.address().port : undefined; },
    /** Resolves with the bound port (relevant when started with port 0). */
    async start(accept) {
      if (server) throw new Error('TCP listener is already started');
      if (closing) throw new Error('TCP listener is closing or closed');
      server = net.createServer((socket) => {
        const connection = new TcpByteConnection(socket, gracefulCloseTimeoutMs);
        connections.add(connection);
        const handler = accept(connection);
        socket.on('data', (chunk) => handler.onData(new Uint8Array(chunk.buffer, chunk.byteOffset, chunk.byteLength)));
        socket.on('error', (error) => { handler.onError(error); socket.destroy(); });
        socket.once('close', () => { connections.delete(connection); handler.onClose(); });
      });
      await new Promise((resolve, reject) => {
        const onError = (e) => { server.off('listening', onListening); reject(e); };
        const onListening = () => { server.off('error', onError); resolve(); };
        server.once('error', onError);
        server.once('listening', onListening);
        server.listen({ host, port });
      });
      return server.address().port;
    },
    async close() {
      if (!server) return;
      closing = true;
      const s = server;
      server = null;
      await Promise.all([...connections].map((c) => c.close().catch(() => {})));
      connections.clear();
      await new Promise((resolve) => s.close(() => resolve()));
    },
  };
}
