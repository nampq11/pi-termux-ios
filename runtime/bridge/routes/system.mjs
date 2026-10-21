// bridge/routes/system.mjs — the pi package updater: installed vs. latest
// version, and the npm self-update it triggers. The spawned npm, its log ring,
// and the post-update restart decision live here with the routes that expose
// them. (/api/state is the active conversation's state — session routes.)
import { spawn } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { json } from '../http.mjs';
import { semverNewer } from '../../semver.mjs';

const PI_PKG = '@earendil-works/pi-coding-agent';
const EARENDIL_PKGS = ['@earendil-works/pi-coding-agent','@earendil-works/pi-durable',
  '@earendil-works/pi-ai','@earendil-works/pi-client','@earendil-works/pi-server','@earendil-works/chord'];

export function createSystemRoutes(deps) {
  const { root, homeDir, ios } = deps;

  function piInstalledVersion() {
    try { return JSON.parse(readFileSync(path.join(root,'node_modules',PI_PKG,'package.json'),'utf8')).version; } catch { return null; }
  }
  async function piLatestVersion() {
    try {
      const r = await fetch(`https://registry.npmjs.org/${PI_PKG}/latest`,{ signal: AbortSignal.timeout(8000) });
      return (await r.json()).version ?? null;
    } catch { return null; }
  }
  const piUpdate = { running: false, done: false, ok: false, version: null, error: null, log: [] };
  function startPiUpdate() {
    if (piUpdate.running) return false;
    Object.assign(piUpdate, { running: true, done: false, ok: false, version: null, error: null, log: [] });
    const prefix = process.env.PREFIX || '';
    // Run npm via node to avoid Termux shebang incompatibility on Android.
    // Try: node <npm-cli.js>, fallback to direct npm binary.
    const nodeBin = process.execPath;
    const npmCli = prefix ? `${prefix}/lib/node_modules/npm/bin/npm-cli.js` : null;
    let spawnArgs;
    if (npmCli && existsSync(npmCli)) {
      spawnArgs = [nodeBin, [npmCli, 'install']];
    } else {
      const npmBin = prefix ? `${prefix}/bin/npm` : 'npm';
      spawnArgs = [npmBin, ['install']];
    }
    const pkgs = EARENDIL_PKGS.map(p => `${p}@latest`);
    const child = spawn(spawnArgs[0], [...spawnArgs[1], ...pkgs, '--no-fund', '--no-audit', '--ignore-scripts', '--no-package-lock'], {
      cwd: root, env: { ...process.env, npm_config_cache: path.join(homeDir, '.npm') },
    });
    const addLog = (d) => { for (const l of String(d).split('\n')) { const t = l.trimEnd(); if (t) { piUpdate.log.push(t); if (piUpdate.log.length > 500) piUpdate.log.shift(); } } };
    child.stdout.on('data', addLog); child.stderr.on('data', addLog);
    child.on('close', (code) => {
      piUpdate.running = false; piUpdate.done = true;
      piUpdate.ok = code === 0; piUpdate.version = piInstalledVersion();
      piUpdate.error = code !== 0 ? `npm exited with code ${code}` : null;
      if (code === 0) {
        addLog(`pi updated to ${piUpdate.version} — restarting bridge…`);
        setTimeout(() => {
          // the in-process iOS engine cannot be restarted; relaunch the app instead
          if (ios) { addLog('restart skipped on iOS: relaunch the app to load the new version'); return; }
          process.exit(0);
        }, 1500);
      }
    });
    child.on('error', (e) => { piUpdate.running = false; piUpdate.done = true; piUpdate.ok = false; piUpdate.error = e.message; });
    return true;
  }

  return async function systemRoutes(req, res, url, p) {
    if (p === '/api/pi-version' && req.method === 'GET') {
      const installed = piInstalledVersion();
      const latest = await piLatestVersion();
      json(res, 200, { installed, latest, updateAvailable: semverNewer(installed, latest) });
      return true;
    }
    if (p === '/api/pi-update' && req.method === 'POST') {
      json(res, 200, { started: startPiUpdate() });
      return true;
    }
    if (p === '/api/pi-update-status' && req.method === 'GET') {
      json(res, 200, piUpdate);
      return true;
    }
    return false;
  };
}
