// bridge/routes/ssh.mjs — the registry of SSH client hosts the UI connects
// to, plus the device's own ed25519 keypair.
import { existsSync, readFileSync } from 'node:fs';
import { mkdir } from 'node:fs/promises';
import { json, str } from '../http.mjs';
import { parseSshTarget } from '../../remote-client.mjs';
import { sshBackend } from '../../ssh-transport.mjs';
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
      if (sshKeyInfo().exists) { json(res, 200, { ok: true, ...sshKeyInfo() }); return true; }
      const sshDir = `${homeDir}/.ssh`;
      await mkdir(sshDir, { recursive: true, mode: 0o700 });
      const r = await sshBackend().generateKey({ dir: sshDir, comment: 'pi-mobile' });
      json(res, r === 0 ? 200 : 500, { ok: r === 0, ...sshKeyInfo() });
      return true;
    }
    return false;
  };
}
