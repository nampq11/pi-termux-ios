// Software key store for spaces pairing. The Android app kept its P-256
// device keys in the system Keystore (hardware-backed, non-exportable); iOS
// has no equivalent available to the in-process engine, so the keys live as
// PKCS#8 PEM files in the app-private state directory (0700 dir, 0600 files).
// The wire contract is pi-spaces' generateKey(): publicKey is the base64 SPKI
// DER, signatures are DER, sha256-signed, and keyId is the gate's fingerprint
// (sha256 over the raw public key bytes, first 32 hex chars) — enrollment
// answers with the server-side fingerprint and the profile comparison in
// spaces-mobile.mjs requires both to match.
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const ALGORITHM = 'ecdsa-p256';
const ALIAS = /^[A-Za-z0-9_.:-]{1,64}$/;

/** Same derivation as pi-spaces' keyFingerprint. */
function fingerprint(publicKeyB64) {
  return crypto.createHash('sha256').update(Buffer.from(publicKeyB64, 'base64')).digest('hex').slice(0, 32);
}

function keyFile(dir, alias) {
  if (!ALIAS.test(alias)) throw new Error(`invalid space key alias "${alias}"`);
  return path.join(dir, `${alias}.key`);
}

/** The signer shape pi-spaces' RemoteSpace expects. */
function signerFor(alias, privateKey) {
  const publicKeyB64 = crypto.createPublicKey(privateKey).export({ format: 'der', type: 'spki' }).toString('base64');
  return {
    alias,
    keyId: fingerprint(publicKeyB64),
    publicKey: publicKeyB64,
    algorithm: ALGORITHM,
    sign: (data) => crypto.sign('sha256', Buffer.from(data), privateKey),
  };
}

/** A keys store rooted at `dir`. Aliases are filesystem-safe by validation;
 * the private keys never leave this directory. */
export function createSpaceKeys(dir) {
  return {
    /** The signer for an existing key (rotation reconnects by alias). */
    async signer(alias) {
      let pem;
      try { pem = readFileSync(keyFile(dir, alias), 'utf8'); } catch (e) { throw new Error(`no space key "${alias}" (${e.code || e.message})`); }
      return signerFor(alias, crypto.createPrivateKey(pem));
    },
    /** A fresh P-256 device key under a unique, peer-derived alias. */
    async createSigner(peerId) {
      if (!ALIAS.test(peerId)) throw new Error(`invalid peer identity "${peerId}"`);
      const alias = `space-${peerId}-${crypto.randomBytes(4).toString('hex')}`;
      const { privateKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'P-256' });
      mkdirSync(dir, { recursive: true, mode: 0o700 });
      writeFileSync(keyFile(dir, alias), privateKey.export({ format: 'pem', type: 'pkcs8' }), { mode: 0o600 });
      return signerFor(alias, privateKey);
    },
  };
}
