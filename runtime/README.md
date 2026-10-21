# runtime/ — the pi-termux-ios runtime

No build step: these files ship as-is, twice (see "Payloads" below). Node >= 22.19,
ESM, German UI text is deliberate. `npm test` runs every `test-*.mjs` suite —
black-box E2E against real server processes plus protocol stubs, no mocks of
internals.

## Entry points

- `server.mjs` — the phone bridge (HTTP + SSE + WebSocket/PTY) behind the app
  UI. On iOS it runs in-process in `NodeEngine.swift` with `PI_PLATFORM=ios`
  (no child processes, no PTY); during development it runs directly under Node
  on Linux and serves the web UI.
- `pi-serverd.mjs` — the daemon on remote hosts (Unix socket).
  `serverd-tcp.mjs` is its opt-in loopback TCP listener for the pure-JS SSH
  tunnel on iOS.
- `env-server.mjs` — dependency-free remote exec/fs sandbox. It must keep zero
  relative imports; a guard test enforces it.

## Layers (server.mjs is the composition root)

- `bridge/` — HTTP plumbing: `http.mjs` (MIME, body, token auth, static),
  `sse.mjs` (event hub), `pty.mjs` (terminal), `routes/` (system, sessions,
  ssh, remote, accounts). Each route module is a factory taking the shared
  deps object; `server.mjs` dispatches to them in order (spaces before the
  readiness gate, accounts after it).
- `common.mjs` — the domain layer: credential store, model catalog, sessions,
  harness.
- `fileio.mjs` — crash-safe file primitives (atomic writes, locks).
- `session-ops.mjs` — the one set of session write rules (rename, delete,
  legacy import) shared by phone and daemon.
- `semver.mjs` — the one version comparator (Node and pi package checks).
- `remote-client.mjs`, `remote-state.mjs`, `remote-provision.mjs`,
  `remote-env.mjs`, `ssh-transport.mjs`, `ssh-js-backend.mjs` — the remote
  cluster: SSH transport with injectable backends (spawn/js), one bridge
  attachment owned by a generation, staged daemon provisioning with rollback,
  and the pi-durable ExecutionEnv over HTTP (`readlines` windows with a
  whole-file fallback for old env-servers).
- `spaces-mobile.mjs`, `space-keystore.mjs` — Spaces pairing/control on the
  phone, Android keystore signer.
- `manual-remote-client.mjs` — manual smoke script against a pi-serverd socket.

## public/ (WebView pages)

- `api.js` — the one HTTP client: `initApi(renderMenu())` binds the session
  token, then `authUrl`/`getJson`/`postJson`. No page calls fetch itself.
- `composer.js` — the shared prompt composer (optimistic bubble, one requestId
  per retry chain, whenBusy steer).
- `menu.js` — the single NAV table driving both the terminal sheet and the
  bottom bar.
- `transcript.js` — conversation rendering shared by chat and Remote.

## Payloads and manifests

- `FILES` in `scripts/payload_common.py` — the phone payload (Android and iOS
  packaging scripts share it).
- `REMOTE_FILES` in `remote-provision.mjs` — the remote daemon tar.
- Both are guarded: every static relative import of an entry point must be
  manifested, and every import of a `public/*.js` page must resolve. Runs on
  `npm test` (`test-manifests.mjs`) and at packaging (`check_import_closures`).

## pi-spaces sync (vendored bundle)

`pi-spaces.mjs` is generated — never edit it here. It is rebuilt from the
sibling source checkout (`PI_SPACES_SOURCE`, default `../pi-spaces`) by the
packaging scripts before every build.

- Provenance: `pi-spaces.stamp` records the source revision of the last
  refresh (`…-dirty` when local source changes went into the bundle; missing
  stamp = unknown provenance). Commit it together with the bundle.
- Loud by design: a refresh that changes the committed bundle fails the build
  (commit the refreshed bundle + stamp, then rerun); a missing bundle fails
  the build; a missing source checkout only warns and ships the committed
  bundle as-is.
