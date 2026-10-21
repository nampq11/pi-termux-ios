# pi-termux-ios

> **Experimental software:** This is a personal prototype under active
> development. Remote sessions and iOS background/suspend handling may still
> change or fail on individual devices.

iOS app that runs the **pi** coding agent (`@earendil-works/pi-coding-agent`
1.0.2 with a **pi-durable** harness + pi-ai/chord) on the phone, behind a tiny
HTTP/SSE/WebSocket bridge (`runtime/server.mjs`). iOS never allows apps to
`exec()` external binaries, so there is no rootfs and no `node` child process:
a Node engine is linked into the app — nodejs-mobile **Node 24 LTS**
(`NodeMobile.xcframework`, fetched and SHA256-pinned by
`scripts/prepare-runtime-ios.py`; includes `node:sqlite` for pi-durable) — and
`server.mjs` runs in-process on a dedicated thread via `node_start`.

The UI is a native SwiftUI app (`ios/`) speaking to the bridge's HTTP/SSE API;
the bridge also serves a web UI (`runtime/public/`) that remains the full
reference implementation and is used from a desktop browser during development
on Linux.

This fork is **iOS-only**. It started as `pi-termux-mobile` (an Android app
embedding a Termux rootfs); the Android app, its build, and its packaging were
removed — `ANALYSE.md` and the changelog preserve that history, and the
upstream project still carries it.

The durable harness gives: SQLite-backed conversations
(`home/.pi-mobile/harness.sqlite` — survive process death, `harness.resume()`
continues interrupted runs), a `subagent` tool (child conversations owned by
the calling task), model selection per conversation, and per-conversation
execution environments — including remote hosts.

## Space RPC through pi-serverd

`pi-serverd.mjs` connects the space service to socket requests with
`withSpaceService`; the existing `sessions` service remains available.
For a standalone daemon, explicitly provision its private socket identity:

```sh
PI_SERVERD_SPACE_PRINCIPAL=local-operator PI_SERVERD_SPACE_ROLES=member \
  node runtime/pi-serverd.mjs
```

Both variables are required together. Without them, space requests are denied;
SSH/socket access does not assign a space role automatically. Federation mode
uses `PI_SERVERD_FEDERATION_CONFIG` and its provisioned identity, key proofs,
and grants. Client request fields cannot override either identity.

## Remote control, two ways

### 1. SSH pi TUI (immediate, full fidelity)

SSH reaches hosts through a pure-JS client on iOS (`ssh2` over the bridge;
`ssh`/`ssh-keygen` binaries on a Linux dev machine — the backend is selected
at startup). Workflow: Clients → *generate key* → *add client*
(`user@host[:port]`) → `⇧key` (install the device key, remote password once)
→ `▸_` connects and runs the full pi TUI on the host.

### 2. pi-server protocol (multi-client attach to durable sessions)

`runtime/pi-serverd.mjs` is a `pi-server` (`createUnixServer`) host app:
durable Harness + own SQLite under `~/.pi-serverd/`, services
`sessions.list/create/delete/attach/models` and
`chat.prompt/abort/state/configure/history/events` (events via long-poll
cursor — Chord subscriptions deliberately skipped).

```bash
# on the remote machine (Node >= 22.19.0, same runtime dir, uses ~/.pi/agent/auth.json)
node pi-serverd.mjs        # socket: ~/.pi-serverd/server.sock
```

The phone bridge (`runtime/remote-client.mjs`) forwards the remote unix
socket to a unix socket in the app-private directory. With the OpenSSH
backend this is streamlocal forwarding (`ssh -N -L`); the pure-JS backend
cannot open streamlocal channels and instead bridges through
**direct-tcpip** into pi-serverd's opt-in loopback TCP listener
(`PI_SERVERD_TCP_PORT`, published in `~/.pi-serverd/server.tcp` — provisioning
from a JS backend enables it automatically). A loopback TCP port would be
reachable by every app on the phone, and pi-server does not authenticate
peers; SSH is the only auth. A dropped tunnel is rebuilt with backoff and the
session is re-attached; prompts carry a `requestId`, so a retried prompt is
answered exactly once. `user@host:port` targets are supported. The Remote page
connects and loads sessions as soon as a host is selected, creates one
automatically when the host has none, opens the newest session first, restores
its transcript, and displays a model picker using the remote host's available
models. Remote uses non-interactive SSH key login, so install the device key
(**⇧key**) for a host before using it here.
On connect the app checks the host and sets it up if needed — see [Remote host setup](#remote-host-setup-automatic).
Endpoints: `/api/remote/{connect,status,trust-host,auth-status,copy-auth,sessions,models,model,create,delete,attach,prompt,abort,compact,state,history,events,disconnect,stop}`.
Events are long-polled with a sequence number and an epoch (`?after=<seq>&epoch=<id>`);
several clients can read the same session, a lost response is fetched again,
and a client that fell behind or saw a daemon restart gets `reset` and reloads
the transcript.

The session list is a pi-durable document (`app.sessions`) in
`~/.pi-serverd/harness.sqlite`, written in the same commit that creates a
conversation; an old `sessions.json` is imported once. Deleting a session first
aborts its running work, then removes its registry entry, so it no longer
appears or can be attached through Remote. Its transcript is kept in SQLite; it
is not a destructive purge. Existing attachments reject further calls after deletion;
mutating calls are serialized with deletion so new work cannot slip past its abort.
The state directory is `0700` and the socket `0600`. `pi-client` runs
on the phone as the protocol client, while the durable harness, model calls,
and tools run in `pi-serverd` on the remote host. For the full interactive Pi
TUI instead, use **Clients → ▸_**; run it in `tmux` when an SSH disconnect must
not end the TUI process.

### 3. env-server (remote *tool execution*, different thing)

A conversation whose cwd is `remote:<name>:/path` runs its tools on that
host via `runtime/remote-env.mjs` (client) + `runtime/env-server.mjs`:

```bash
# on the remote machine — Node >= 22, no deps; binds 127.0.0.1 by default
PI_REMOTE_TOKEN=<secret, >=16 chars> PI_REMOTE_PORT=7842 node env-server.mjs
# reach it via ssh -L or a VPN address: PI_REMOTE_HOST=<tailscale-ip>

# on the phone: home/.pi-mobile/remotes.json (or PI_REMOTES env)
{"workstation": {"url": "http://127.0.0.1:7842", "token": "<secret>"}}
```

env-server is not `pi-serverd`: `pi-serverd` (section 1/2) runs the whole
conversation on the host, while env-server only executes single tool calls for a
conversation that stays on the phone. It is a small HTTP server (POST, JSON,
bearer token compared in constant time) with two endpoints: `/exec` runs
`bash -c <command>` (optional `cwd`, `env`, `timeout`, `stream`; output capped at
8 MB when not streamed) and `/fs` performs file operations (`read`, `write`,
`append`, `truncate`, `rename`, `info`, `list`, `exists`, `mkdir`, `remove`,
`canonical`, `tempdir`, `tempfile`; contents as base64). It starts only with a
token of at least 16 characters.

Output is streamed (NDJSON); aborting a tool call kills the command's whole
process group on the remote host. Never expose env-server on a LAN without a
tunnel/VPN — it executes arbitrary commands.

## Remote host setup (automatic)

Connecting to a host from the **Remote** page or **Clients → ▸_** prepares the
host over SSH. Everything runs with the phone's key (non-interactive SSH),
under the host user's account; no root is needed except for installing tmux.
Each sensitive step asks first.

| Step | When | Asks? |
|---|---|---|
| **SSH key** | host rejects the phone's ed25519 key | yes — installs the key (remote password once), then returns and reconnects |
| **SSH trust + auth.json** | host has no `~/.pi/agent/auth.json` | yes — verify and persist the SSH fingerprint first, then **red warning** before copying API keys / OAuth tokens (mode 600) |
| **pi-serverd** (Remote page) | no daemon running | no — installs and starts it |
| **pi-serverd update** | daemon running, files differ from the phone's | yes — the daemon restarts, running work is interrupted (durable sessions resume) |
| **pi-serverd stop** | **stop server** button next to connect | yes — confirm dialog; aborts running work, disconnects this device, works without an active connection (durable sessions are kept; the next connect starts and, if needed, updates the daemon) |
| **pi** (pi CLI ssh) | `pi` not found on the host | no — installs the latest release |
| **pi update** (pi CLI ssh) | `pi` version < npm latest | no — updates to latest, falls back to existing on failure |

**pi-serverd.** A new release is unpacked and dependency-checked in a private
staging directory first. Only after that succeeds is the daemon stopped and the
release directory swapped using same-filesystem renames; a failed swap (including
failure between the renames) or restart restores and restarts the preceding release. The daemon PID is read from its own lock file (not a global `pkill`),
and its Unix socket plus `sessions.list` protocol call are health-checked. The
daemon runs in the tmux session `pi-serverd`; missing tmux is installed through
apt / dnf / yum / pacman / apk / zypper / brew / Termux `pkg` when running as
root or with `sudo -n`, otherwise it falls back to `nohup setsid` (log:
`~/.pi-mobile-remote/runtime/serverd.log`). Progress is shown in Remote
(`/api/remote/status` → `log`).

**Stopping.** `POST /api/remote/stop {target}` drops the local connection, then
stops the daemon over SSH with the same PID-from-lock logic (TERM, then KILL
after 10 s) and removes the `pi-serverd` tmux session. It answers
`{ok, stopped}`; `stopped:false` means no daemon was running.

**Version check.** The installed state is a SHA-256 (16 hex chars) over
`pi-serverd.mjs`, `common.mjs`, `pi-spaces.mjs`, `package.json`, `package-lock.json`
and the optional generated `space-examples/` directory, stored in
`~/.pi-mobile-remote/runtime/.version` (`.deps` holds the dependency hash). Any
difference to the files on the phone means *outdated*; declining the update keeps
the old daemon.

**pi.** For the full TUI, SSH runs `pi` through a login shell. If `pi`
is missing and npm exists, the latest `@earendil-works/pi-coding-agent` is
installed with `npm install -g --prefix ~/.local` (no root; `~/.local/bin` is put
in front of `PATH`) and started; the installation output is visible in the terminal.
Before every SSH-TUI start, the installed version is compared to `npm view`
(`@earendil-works/pi-coding-agent@latest`) and is updated only when the registry
has a newer stable semantic version. If npm/the registry is unavailable or an
update fails, the installed pi starts unchanged.

**Node.** Node.js **>= 22.19.0** and npm must already exist on the host and are *not*
installed automatically. This exact minimum comes from the bundled
`pi-coding-agent` and `pi-durable` packages; Node 22.18.x is not supported. They are found in login shells and — because nvm, fnm,
Volta, asdf and nodenv set `PATH` in `~/.bashrc` — through a prelude that sources
`~/.nvm/nvm.sh` and adds the usual shim directories.

**auth.json.** Without credentials the daemon has no models and prompts fail with
*Internal server error*. Declining the copy is fine: add a key on the host (`pi`,
`/login`) instead. Never copy it to hosts you do not fully trust.

## Web UI (development reference)

The bridge serves `runtime/public/`: Chat (`/`), Accounts (`keys.html`),
Sessions (`sessions.html`), Clients (`clients.html`), Remote (`remote.html`),
pi CLI (`terminal.html`), Spaces (`spaces.html`) and Spaces-Steuerung
(`spacectl.html`). It is the feature-complete reference UI — every page speaks
the same `/api` endpoints the native SwiftUI screens use — and the everyday UI
when developing the bridge on a Linux machine. Screenshots:
`docs/screens/`.

With `PI_PLATFORM=ios` the server injects `window.PI_MOBILE_IOS=1` into HTML
pages; `menu.js` then hides only the local pi CLI page — child processes are
denied in the in-process engine. Everything else stays reachable in the web UI.

## Accounts: API keys and OAuth

Accounts support both API keys and provider OAuth/subscription logins. Select
an OAuth provider under **OAuth / subscription**, then choose **sign in**. When
a provider offers multiple methods, a dialog offers for example **Browser
login** or **Device code login**. Browser flows open in the system browser and
the app polls the login until it completes — returning to the app finishes the
sign-in; device flows show the verification URL and code in the app. Completed
credentials are stored in
`~/.pi/agent/auth.json` and immediately become available to the model picker.

## Layout

- `ios/` — the iOS app: SwiftPM package built with [xtool](https://xtool.sh)
  (Swift shell + native UI), `NodeMobile.xcframework`, runtime payload zip
- `runtime/` — `server.mjs` (durable bridge + `/pty` WS + remote attach),
  `common.mjs` (shared harness setup, credential store with file lock, durable
  session registry, sequenced event hub, single-owner lock),
  `pi-serverd.mjs` (remote session daemon), `remote-client.mjs` (pi-client
  + ssh tunnel), `remote-env.mjs`/`env-server.mjs` (tool exec),
  `public/` (web UI), package.json for prod node_modules
- `scripts/` — `prepare-runtime-ios.py` (payload + engine), `payload_common.py`
  (shared packaging + guards), `mux-forward.py` (USB port forward),
  `verify-ios-device.sh`
- `tools/` — local toolchain artifacts (nodejs-mobile archive) — not committed

## Build

```bash
# once: xtool setup (Swift 6.4 toolchain, Xcode.xip → darwin SDK, Apple ID)
python3 scripts/prepare-runtime-ios.py   # runtime payload zip + pinned NodeMobile engine
cd ios && xtool dev                      # build, sign, install to a USB iPhone
```

The payload zip is STORED (uncompressed) on purpose: Apple's Compression
framework has no raw-DEFLATE mode, so `RuntimeArchive` only copies bytes.
Changed payload fingerprints re-extract on the next launch; `home/` and
`work/` are preserved.

The Swift shell: `RuntimeController` drives boot (install payload → start
engine → wait for the port/token handshake files, same as the bridge has
always written: `home/.pi-mobile/port` and `token`), `NodeEngine` runs
`node_start` on a dedicated 8 MB thread, `RuntimeInstaller` extracts the
payload with a dependency-free unzip, and the native UI lives in
`Agent/` + `UIRenderer/`.

Unlike an ephemeral port, the iOS bridge listens on a fixed loopback port
(`41943`) so it can be reached from the host over USB for debugging:
`python3 scripts/mux-forward.py 41943 41943` (or any usbmux TCP forwarder),
then `curl http://127.0.0.1:41943/`.

**Honest limitations of the iOS sandbox:**

- **Works locally:** chat with models over durable SQLite sessions, session
  management, accounts (API keys + OAuth via the system browser), SSH to
  remote hosts through the pure-JS backend, remote sessions over the TCP
  tunnel, spaces pairing, and the web UI from a desktop browser.
- **Cannot work without processes:** bash tool calls, ripgrep, git and a
  *local* pi terminal (PTY) rely on child processes — spawns are denied per
  call on iOS. The npm self-update is likewise impossible (ship updates with
  the app payload instead).
- **Engine cannot restart:** nodejs-mobile allows one engine instance per
  process, so a crashed engine needs an app relaunch. With `PI_PLATFORM=ios`
  the bridge never calls `process.exit` (that would kill the app); boot
  failures are written to `$HOME/.pi-mobile/fatal` and shown by the shell.
  An iOS-only `uncaughtException` guard does the same for early crashes.
- **No background execution:** iOS suspends the app (and with it the engine)
  in the background; there is no foreground-service equivalent.
- Free-Apple-ID installs expire after 7 days; rerun `xtool dev` to renew.

Build prerequisites: Python 3 + curl for the payload script, xtool with the
darwin SDK, a USB-connected iPhone (no simulator on Linux). Refreshing
pi-spaces from source needs the sibling checkout (`PI_SPACES_SOURCE`).

First launch extracts the payload to app-private storage, then the engine
starts the bridge. `server.mjs` holds `~/.pi-mobile/server.lock`
(pi-durable allows one storage owner). Open the app → **Accounts** to store a
provider key or sign in through OAuth, then prompt. Local conversation state
lives in `home/.pi-mobile/harness.sqlite` and survives process death. The
session registry and the active session are a pi-durable document in the same
database (an old `sessions.json` is imported once), so a restart reopens the
session that was active. The chat streams answers, shows tool output, subagent
children, usage, and offers *steer* while a run is busy; every prompt carries
a `requestId` so retries are exactly-once.

See ANALYSE.md for the full evaluation and upstream facts.

## Tests

```bash
cd runtime
npm ci --ignore-scripts
npm test
```

These offline tests need Node >=22.19.0, bash and tar; no SSH host, API keys or
model calls are needed. They cover rename routing, deleted-session attachments,
prompt deduplication, release rollback/restart, SSH/protocol/RPC deadlines,
connection cancellation races, packaging invariants, and the spaces
mobile-pairing lifecycle. Metadata and protocol connection attempts time out
after 15 seconds; RPC calls after 35 seconds (including 25-second event polls).
Disconnect cancels pending connection and recovery operations.

## Repackaging assets

`scripts/prepare-runtime-ios.py` rebuilds pi-spaces from the sibling checkout,
synchronizes `runtime/pi-spaces.mjs` and compiled `runtime/space-examples/*.mjs`,
then packages the runtime payload zip and its fingerprint. Changed payloads are
re-extracted on the device without a manual version bump. Unchanged files keep
their timestamps.

Refreshing from source additionally needs Node/npm and the pi-spaces development
dependencies. Set `PI_SPACES_SOURCE` for a source checkout elsewhere. If the
source is missing, the build warns (with the stamped provenance) and uses the
existing mobile bundle — the checked-in `pi-spaces.mjs` with its `pi-spaces.stamp`
is required; a bundle whose digest drifted from the stamp fails the build.
Generated `space-examples/` CLI programs are optional, so a fresh checkout can
run tests and provision a remote host without the sibling source tree. Available
examples are still packaged, hashed and uploaded. Running `npm run bundle` in
pi-spaces also synchronizes this checkout automatically; an alternate mobile
checkout can be selected with `PI_SPACES_MOBILE_ROOT`. Generated example modules
are CLI programs, not additional mobile buttons or Federation services. Remote
provisioning includes them in its release hash and transfers them along with the
library; existing update confirmation rules still apply.

## Changelog

### 0.0.6 — 2026-10-21

The fork becomes iOS-only (work in progress toward full parity with the former
Android feature set).

- Removed the Android app (`android/`), its Gradle build, APK packaging
  (`scripts/prepare-runtime.py`), the wireless installer (`install-wifi.sh`),
  and the Android/Gradle `.gitignore` entries.
- The mobile-lifecycle spaces tests moved into the runtime suite
  (`runtime/test-spaces-mobile.mjs`) and now run as part of `npm test`.
- README rewritten iOS-first.

### 0.0.5 — 2026-10-05

New UI design, pi update in the app, remote session rename, and various fixes.

**UI redesign**

- Hamburger menu replaced by a **bottom tab bar** (Chat · Remote · CLI · Clients · Keys).
- On the Terminal page a **≡ slide-up sheet** replaces the menu.
- Chat header: inline **＋ / ⇊ / ■** buttons (new session, compact, abort).
- Session name in the Chat header links to the Sessions page.
- Remote page: two-row connect bar — host + connect/disconnect on the first row,
  session dropdown + ✎ ＋ ✕ ■ ⇊ on the second row.
- **stop server** button next to connect: ends `pi-serverd` on the selected host
  (with or without an active connection); the next connect restarts/updates it.
- Host selection no longer auto-connects; the user clicks **connect** explicitly.
- Cards, status dots, section headers throughout; CSS custom properties for theming.

**pi update in the app (Accounts page)**

- Shows the installed pi version and checks npm for a newer release.
- **Update** button runs `npm install @earendil-works/*@latest` directly on the
  phone.
- npm install uses `--ignore-scripts` to skip postinstall failures.
- Progress streams line by line; on failure the npm output and error are shown.
- Bridge restarts automatically after a successful update (relaunch the app on iOS).

**Remote: session rename**

- Added **✎** rename button on the Remote session row.
- `pi-serverd.mjs` now handles the `sessions.rename` member of the sessions service.

**Fixes**

- Remote connect bar no longer auto-connects on host dropdown change.
- Status code `2` (tar/npm exit code) no longer crashes the HTTP server.
- Node >= 22.19.0 required (matches upstream `pi-coding-agent` / `pi-durable`).

**Dependencies**

- All `@earendil-works/*` packages bumped to `^1.0.3` in `package.json`.

### 0.0.4 — 2026-10-05

- **pi CLI (ssh):** compares `pi --version` with the current npm release before
  starting. A newer `@earendil-works/pi-coding-agent` is installed to `~/.local`.
  Registry-check and update failures leave the installed pi usable.

### 0.0.3 — 2026-10-05

Hardening and correctness pass for remote provisioning.

- Enforces the upstream Node engine requirement **>= 22.19.0** (rather than
  accepting every Node 22 release).
- `auth.json` is copied only after explicit SSH fingerprint verification and
  the red credential warning. The saved fingerprint is checked again server-side.
- Release updates are staged first, switched atomically, and roll back on a
  failed start. PID-targeted shutdown replaces global `pkill`.
- A live socket is additionally verified through `sessions.list`; unhealthy
  daemons are restarted.
- Failed key install no longer silently proceeds to reconnect.
- Cancelling a Remote connection invalidates an in-flight provisioning result.
- Adds basic Node-version, target-validation and release-hash tests.

### 0.0.2 — 2026-10-05

Hosts are now prepared automatically when connecting remotely. Details:
[Remote host setup](#remote-host-setup-automatic).

- **pi-serverd installation.** Connecting from the Remote page checks the host
  over SSH; without a running daemon the server files are copied to
  `~/.pi-mobile-remote/runtime`, dependencies installed (`npm ci --omit=dev`) and
  the daemon started in the tmux session `pi-serverd`. tmux is installed if
  possible (root or `sudo -n`), otherwise `nohup setsid` is used. The progress
  log appears in the Remote page.
- **Version check and update.** A hash over the server files decides whether the
  daemon on the host is outdated; updating restarts it and asks first.
  `npm ci` only runs when the package files changed.
- **pi installation.** *pi CLI (ssh)* and *Clients → ▸_* install the latest
  `@earendil-works/pi-coding-agent` into `~/.local` when `pi` is missing and npm
  exists.
- **auth.json.** A host without `~/.pi/agent/auth.json` gets the phone's file
  only after a red warning dialog and consent (mode 600). Without credentials the
  remote daemon answered every prompt with *Internal server error*.
- **SSH key.** A host that rejects the phone's key offers an interactive key
  install and then reconnects (Remote page) or continues (terminal).
- **Node from version managers.** Remote commands source nvm/fnm/Volta/asdf paths;
  Node installed through them was reported as missing before.
- The Remote page connect button turns into **disconnect** while connected.

**Fixes**

- The terminal registered another key handler on every reconnect, which would
  send input twice.

### 0.0.1 — 2026-10-04

Lots of bugfixes around durable sessions, security and the app service.

**Security**

- Remote attach tunnels a unix socket in the app-private directory
  (`ssh -L local.sock:remote.sock`) instead of a loopback TCP port that every
  app on the phone could reach — pi-server does not authenticate peers.
- An unauthenticated request for a directory (e.g. `GET /vendor`) no longer
  crashes the bridge (unhandled `EISDIR`); static serving is confined to
  `public/`.
- Host-header check against DNS rebinding, constant-time token comparison,
  request body limit, token removed from the visible URL/history.
- SSH targets are validated (`user@host[:port]`); option-like targets such as
  `-oProxyCommand=…` are rejected, `--` is passed before the host.
- `env-server.mjs` binds `127.0.0.1` by default, requires a token of at least
  16 characters, compares it in constant time and limits body size.
- `pi-serverd` keeps its state directory at `0700` and its socket at `0600`.
- `auth.json` is written atomically under a lock file (bridge and pi-serverd),
  so a concurrent OAuth refresh cannot lose a rotated refresh token.
- The remote host key fingerprint is shown on connect (trust on first use).

**Durable sessions**

- The selected model is no longer overwritten before every prompt and on every
  remote attach (the code read `viewState().value.agent`, which does not exist;
  agent choices live in `docs['pi.agent']`). `busy` is derived from
  `docs['pi.live'].run`.
- Prompts carry a client-generated `requestId`: retries after a dropped
  connection are exactly-once.
- Every SSE client gets its own `watchEvents()` stream, so a reconnecting chat
  shows the current state instead of the snapshot from when the session was
  opened; pi-durable's `snapshot` and `agent_changed` events are handled.
- Remote events are sequence-numbered with an epoch: several clients can read
  one session, a lost response is fetched again, and a client that fell behind
  or saw a daemon restart reloads the transcript.
- A dropped remote tunnel is rebuilt with backoff and the session re-attached.
- The session registry and the active session are a pi-durable document in
  the same SQLite database, written in the same commit as the conversation;
  old `sessions.json` files are imported once. The active session survives a
  restart.
- Deleting a session aborts its running work first.
- The subagent tool returns the child's answer again (the child handle has no
  `commit()`); its child conversation is shown in the transcript.
- One storage owner: `server.mjs`/`pi-serverd.mjs` take a lock file and stop an
  orphaned predecessor; both close the harness on `SIGTERM`.

**App shell**

- Opening the app no longer restarts the running bridge (which interrupted
  running tool calls and briefly opened the database twice). Exactly one
  bridge process runs; a crash is restarted with backoff and a stop sends
  `SIGTERM` + grace period.
- Runtime archives are streamed into `tar` (no temporary 170 MB copy); an
  upgrade replaces the runtime tree completely, user data in `home/` and
  `work/` is kept.
- Node log rotation; longer first-start wait in the UI.

**UI**

- Answers stream live (the old code expected a non-existent event shape),
  tool output can be expanded, subagent children and usage/cost are shown.
- *Steer* while a run is busy, *Compact context*, fork and rename sessions,
  remote abort/compact and a reconnect status.
- Shared transcript renderer for local and remote chat, deduplicated by entry
  id; generic `.hidden` CSS rule (remote controls were never hidden).

**Other**

- `env-server`: streamed output (NDJSON); aborting a tool call kills the
  command's whole process group. Remotes can be configured in
  `~/.pi-mobile/remotes.json`.
- Shared `runtime/common.mjs` for both servers; `PI_TEST_FAUX=1` provides a
  scripted offline model for tests.
- `start_server.sh` now actually passes `PI_WORKDIR` to pi-serverd (it was set
  as an unexported shell variable).

## Device test report (0.0.1, Android-era)

Historical record from the Android app; the durable-session behaviors it
verifies still apply. Tested on 2026-10-04, upgrading an installed 0.1.0 build
(runtime 42) in place. Remote host: Fedora with OpenSSH, reached over Wi-Fi
with the phone's Termux OpenSSH.

| Test | Result |
|---|---|
| Upgrade runtime 42 → 43 | ✅ toybox `tar` reads from stdin, done in ~13 s; runtime replaced, credentials and sessions kept |
| Legacy `sessions.json` | ✅ imported into the durable registry; "Main" and the active session kept |
| `GET /vendor`, foreign `Host`, missing token | ✅ bridge keeps running / 421 / 401 |
| Model choice + real prompt | ✅ `claude-haiku-4-5` stays selected after the prompt, answer "pong" |
| Same `requestId` sent twice | ✅ one submission |
| Activity recreated 3× (`onCreate`) | ✅ node keeps the same PID, no bridge restart |
| Agent kills its own bridge during a bash call | ✅ supervisor restarts node after ~1 s, `resume()` continues the run, bash returns `interrupted`, the model answers |
| WebView UI | ✅ loads over `127.0.0.1`; tool line, usage and menu work |
| Remote over Termux OpenSSH | ✅ tunnel socket `0600` in a `0700` directory, host key fingerprint matches the host, daemon socket `0600` |
| Phone's sshd session killed | ✅ status `reconnecting`, reconnected after ~2 s, retried prompt runs exactly once |
| Remote page in the app | ✅ host selected, session attached with full history, model and usage shown |

---

*vibe coding fun with pi* — [Earendil Pi on GitHub](https://github.com/earendil-works/pi)

The Spaces page prepares a P-256 device key, pairs via an entered token/QR
JSON, checks pairing/authentication and resolves own-key rotation. It connects
to explicitly trusted control/data hosts over the overlay and displays the
selected space's objects and statistics. Request identities and public
metadata are saved privately before sending, without persisting enrollment
tokens. Camera QR scanning remains pending.

`PI_SERVERD_FEDERATION_CONFIG` opts pi-serverd into the provisioned federation
runtime, independent boot/authority checks and its supervisor. Configuration,
keys and register endpoints must be provisioned explicitly. A persistent
`restart.lock` blocks normal server startup. Operational requirements and open
recovery integration are documented in the sibling pi-spaces
`docs/ap1b-betrieb.md` and `docs/ap1b-abnahme.md`.

Mobile lifecycle checks run as part of `cd runtime && npm test`.

The **Spaces-Steuerung** page (`runtime/public/spacectl.html`) sends admin commands (runs, workers) through the paired control connection. Each command ID is stored in the private profile before it is sent and is reused after a timeout, double tap or restart; results are polled only while the page is visible.
