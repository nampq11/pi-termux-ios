// bridge/pty.mjs — interactive pi CLI over WebSocket + util-linux `script`.
// On the pure-JS backend (iOS: no binaries to spawn) the SSH channel itself
// is the pty for remote sessions; the local CLI path stays spawn-based and is
// unreachable on iOS (exec() is denied there).
import { spawn } from 'node:child_process';
import { existsSync, readdirSync, readlinkSync } from 'node:fs';
import path from 'node:path';
import { remoteBash } from '../remote-provision.mjs';
import { parseSshTarget } from '../remote-client.mjs';
import { sshBackend } from '../ssh-transport.mjs';

const clampInt = (v, lo, hi, dflt) => {
  const n = Math.trunc(Number(v));
  return Number.isFinite(n) && n >= lo && n <= hi ? n : dflt;
};

// Remote command for "pi CLI (ssh)": install pi if absent, otherwise compare it
// to npm's latest stable release and update only when newer. The update stays in
// ~/.local (no root); if npm/the registry is unreachable the existing pi starts.
const REMOTE_PI_SCRIPT = [
  'PKG=@earendil-works/pi-coding-agent;',
  'if ! command -v pi >/dev/null 2>&1; then',
  ' if ! command -v npm >/dev/null 2>&1; then echo "pi is missing; npm (and Node.js >= 22.19.0) is required."; read -r _; exit 1; fi;',
  ' echo "pi not found - installing latest $PKG into ~/.local ...";',
  ' npm install -g --prefix "$HOME/.local" "$PKG@latest" || { echo "pi installation failed"; read -r _; exit 1; };',
  'else',
  ' if command -v npm >/dev/null 2>&1; then',
  '  have=$(pi --version 2>/dev/null | head -n 1); latest=$(npm view "$PKG" version --fetch-timeout=10000 --fetch-retries=1 2>/dev/null | head -n 1);',
  // shell-side twin of semver.mjs's semverNewer (this node -e runs on the remote host): keep in step
  '  if [ -n "$latest" ] && node -e "const p=s=>String(s).match(/^([0-9]+)\\.([0-9]+)\\.([0-9]+)/)?.slice(1).map(Number); const [a,b]=process.argv.slice(1).map(p); let c=0; if(a&&b) for(let i=0;i<3;i++) if(a[i]!==b[i]) { c=b[i]-a[i]; break; } process.exit(c>0?0:1)" "$have" "$latest"; then',
  '   echo "updating pi: $have -> $latest ..."; npm install -g --prefix "$HOME/.local" "$PKG@latest" || echo "pi update failed; starting $have";',
  '  elif [ -z "$latest" ]; then echo "could not check for pi updates; starting $have"; fi;',
  ' fi;',
  'fi;',
  'exec pi',
].join(' ');
// single-quoted for the local `sh -c`: the base64 payload has no quote characters
const REMOTE_PI_CMD = `'${remoteBash(REMOTE_PI_SCRIPT)}'`;

/** Bridge the WebSocket to an SSH channel pty (JS backends). Keystrokes
 * arriving during the SSH handshake are queued so they cannot vanish; \x01
 * control frames become setWindow resizes, everything else is stdin. */
async function startSshChannelPty(ws, { target, command, cols, rows }) {
  let handle = null;
  ws.on('close', () => handle?.kill()); // covers a close during the handshake too
  const queued = [];
  const collect = (d) => queued.push(d);
  ws.on('message', collect);
  try {
    handle = await sshBackend().openShell({
      home: process.env.HOME || '/tmp',
      host: target.host,
      port: target.port,
      command,
      cols,
      rows,
    });
    ws.removeListener('message', collect);
    const { stream } = handle;
    stream.on('data', (d) => { if (ws.readyState === 1) ws.send(d); });
    stream.stderr.on('data', (d) => { if (ws.readyState === 1) ws.send(d); });
    stream.on('error', (e) => { if (ws.readyState === 1) ws.send(`\r\n[ssh error] ${e?.message || e}\r\n`); });
    stream.on('close', () => { try { ws.close(1000, 'pty exited'); } catch {} });
    const deliver = (data) => {
      const s = data.toString();
      if (s.charCodeAt(0) === 1) {
        try {
          const msg = JSON.parse(s.slice(1));
          if (msg.resize) {
            stream.setWindow(clampInt(msg.resize.rows, 5, 500, rows), clampInt(msg.resize.cols, 10, 1000, cols), 0, 0);
          }
        } catch {}
        return;
      }
      try { stream.write(data); } catch {} // a half-dead channel must not throw into the ws
    };
    for (const d of queued) deliver(d);
    ws.on('message', deliver);
  } catch (e) {
    ws.removeListener('message', collect);
    try {
      if (ws.readyState === 1) ws.send(`\r\n[ssh error] ${e?.message || e}\r\n`);
      ws.close(1011, 'ssh failed');
    } catch {}
  }
}

export function createPtyHandler({ root, prefix, workDir }) {
  const cli = path.join(root, 'node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js');
  return function startPty(ws, url) {
    const cols = clampInt(url.searchParams.get('cols'), 10, 1000, 120);
    const rows = clampInt(url.searchParams.get('rows'), 5, 500, 30);
    const scriptBin = prefix && existsSync(`${prefix}/bin/script`) ? `${prefix}/bin/script` : 'script';
    const sshParam = url.searchParams.get('ssh');
    const sshCmd = url.searchParams.get('sshop'); // 'copyid' -> interactive ssh-copy-id
    if (sshParam && sshBackend().name === 'js') {
      // key install has its own password flow on JS backends (ssh-copy-id.mjs)
      if (sshCmd === 'copyid') {
        try {
          if (ws.readyState === 1) ws.send('\r\n[key install runs through the ⇧key password prompt on this device]\r\n');
          ws.close(1008, 'use the password flow');
        } catch {}
        return;
      }
      let target;
      try { target = parseSshTarget(sshParam); } catch (e) { ws.close(1008, e.message); return; }
      startSshChannelPty(ws, { target, command: remoteBash(REMOTE_PI_SCRIPT), cols, rows });
      return;
    }
    let inner;
    if (sshParam) {
      let target;
      try { target = parseSshTarget(sshParam); } catch (e) { ws.close(1008, e.message); return; }
      const portFlag = target.port ? `-p ${target.port}` : '';
      if (sshCmd === 'copyid') {
        // run ssh-copy-id inside the pty so password entry is interactive
        inner = `stty cols ${cols} rows ${rows}; "${prefix}/bin/bash" "${prefix}/bin/ssh-copy-id" -i "$HOME/.ssh/id_ed25519" ${portFlag} -o "UserKnownHostsFile=$HOME/.ssh/known_hosts" -- "${target.host}"; rc=$?; echo; if [ "$rc" -eq 0 ]; then echo '[SSH_KEY_INSTALLED]'; else echo "[ssh-copy-id failed: $rc]"; fi; echo '[press Enter to continue]'; read -r _ 2>/dev/null`;
      } else {
        // remote pi session over ssh (keys via $HOME/.ssh on this device)
        inner = `stty cols ${cols} rows ${rows}; exec "${prefix}/bin/ssh" -tt ${portFlag} -o "StrictHostKeyChecking=accept-new" -o "UserKnownHostsFile=$HOME/.ssh/known_hosts" -i "$HOME/.ssh/id_ed25519" -- "${target.host}" ${REMOTE_PI_CMD}`;
      }
    } else {
      // -c runs under sh inside the pty: set size first, then replace with pi
      inner = `stty cols ${cols} rows ${rows}; exec "${process.execPath}" "${cli}"`;
    }
    const child = spawn(scriptBin, ['-qfec', inner, '/dev/null'], {
      env: { ...process.env, TERM: 'xterm-256color', COLUMNS: String(cols), LINES: String(rows) },
      cwd: workDir,
    });
    child.stdout.on('data', (d) => { if (ws.readyState === 1) ws.send(d); });
    child.stderr.on('data', (d) => { if (ws.readyState === 1) ws.send(d); });
    child.on('exit', () => { try { ws.close(1000, 'pty exited'); } catch {} });
    child.on('error', (e) => { try { ws.send(`\r\n[pty error] ${e.message}\r\n`); } catch {} });

    // discover the pty slave path so we can push resizes via stty -F
    let ptsPath = null;
    const findPts = setInterval(() => {
      if (ptsPath || !child.pid) { clearInterval(findPts); return; }
      try {
        for (const fd of readdirSync(`/proc/${child.pid}/fd`)) {
          const l = readlinkSync(`/proc/${child.pid}/fd/${fd}`);
          if (l.startsWith('/dev/pts/')) { ptsPath = l; break; }
        }
        if (ptsPath) clearInterval(findPts);
      } catch {}
    }, 300);
    setTimeout(() => clearInterval(findPts), 15000);

    ws.on('message', (data) => {
      // \x01-prefixed frames are JSON control messages, everything else is stdin
      const s = data.toString();
      if (s.charCodeAt(0) === 1) {
        try {
          const msg = JSON.parse(s.slice(1));
          if (msg.resize && ptsPath) {
            const c = clampInt(msg.resize.cols, 10, 1000, cols);
            const r = clampInt(msg.resize.rows, 5, 500, rows);
            spawn(`${prefix}/bin/stty`, ['-F', ptsPath, 'cols', String(c), 'rows', String(r)]);
          }
        } catch {}
        return;
      }
      child.stdin.write(data);
    });
    ws.on('close', () => child.kill('SIGKILL'));
  };
}
