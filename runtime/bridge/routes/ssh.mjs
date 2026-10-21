// bridge/routes/ssh.mjs — the registry of SSH client hosts the UI connects
// to, plus the device's own ed25519 keypair.
import { existsSync, readFileSync } from 'node:fs';
import { mkdir } from 'node:fs/promises';
import { json, str } from '../http.mjs';
import { parseSshTarget } from '../../remote-client.mjs';
import { sshBackend } from '../../ssh-transport.mjs';
import { installDeviceKey } from '../../ssh-copy-id.mjs';
import { readJson, writeFileAtomic } from '../../fileio.mjs';

export function createSshRoutes(deps) {
  const { homeDir, clientsFile } = deps;

  const readClients = () => readJson(clientsFile, []);
  const writeClients = (clients) => writeFileAtomic(clientsFile, JSON.stringify(clients, null, 2));
  function sshKeyInfo() {
    const pub = `${homeDir}/.ssh/id_ed25519.pub`;
    const priv = `${homeDir}/.ssh/id_ed25519`;
    if (existsSync(pub) && existsSync(priv)) {
      try { return { exists: true, pubkey: readFileSync(pub, 'utf8').trim() }; } catch { return { exists: true, pubkey: null }; }
    }
    return { exists: false, pubkey: null };
  }
  /** The device keypair, generating it on first use (the sshkey button and
   * key installs share this). */
  async function ensureKey() {
    const info = sshKeyInfo();
    if (info.exists) return info;
    const sshDir = `${homeDir}/.ssh`;
    await mkdir(sshDir, { recursive: true, mode: 0o700 });
    const r = await sshBackend().generateKey({ dir: sshDir, comment: 'pi-mobile' });
    return r === 0 ? sshKeyInfo() : null;
  }

  return async function sshRoutes(req, res, url, p, body) {
    if (p === '/api/clients' && req.method === 'GET') {
      json(res, 200, { clients: readClients() });
      return true;
    }
    if (p === '/api/clients' && req.method === 'POST') {
      if (body.delete) {
        writeClients(readClients().filter((c) => c.name !== str(body.delete)));
        json(res, 200, { ok: true });
        return true;
      }
      if (!body.target) { json(res, 400, { error: 'target required' }); return true; }
      const target = str(body.target);
      parseSshTarget(target); // throws on invalid / option-like targets
      const name = str(body.name || target, 100);
      const clients = readClients().filter((c) => c.name !== name);
      clients.push({ name, target });
      writeClients(clients);
      json(res, 200, { ok: true });
      return true;
    }
    if (p === '/api/sshkey' && req.method === 'GET') {
      json(res, 200, sshKeyInfo());
      return true;
    }
    if (p === '/api/sshkey' && req.method === 'POST') {
      const info = (await ensureKey()) ?? { exists: false, pubkey: null };
      json(res, info.exists ? 200 : 500, { ok: info.exists, ...info });
      return true;
    }
    // Interactive ssh-copy-id needs a PTY for the password; iOS has none, so
    // the bridge installs the key with one password-authenticated exec
    // (ssh-copy-id.mjs, pure-JS backend).
    if (p === '/api/ssh-copy-id' && req.method === 'POST') {
      if (!body.target || !body.password) { json(res, 400, { error: 'target and password required' }); return true; }
      let target;
      try { target = parseSshTarget(str(body.target)); } catch (e) { json(res, 400, { error: String(e?.message || e) }); return true; }
      const info = await ensureKey();
      if (!info?.pubkey) { json(res, 500, { ok: false, error: 'cannot generate the device key' }); return true; }
      const { host, port } = target;
      json(res, 200, await installDeviceKey({ home: homeDir, host, port, password: str(body.password), pubkey: info.pubkey }));
      return true;
    }
    return false;
  };
}
