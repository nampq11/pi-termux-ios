// Real-behavior tests for the software spaces key store: the wire contract
// (SPKI base64 public key, DER sha256 signature, gate-fingerprint keyId),
// persistence across instances (rotation reconnects by alias after a
// restart), and the privacy guarantees the profile enforces for itself.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readdirSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import crypto from 'node:crypto';
import { createSpaceKeys } from './space-keys.mjs';

const dir = () => mkdtempSync(join(tmpdir(), 'space-keys-'));

test('a created signer satisfies the pi-spaces wire contract', async () => {
  const root = dir();
  try {
    const keys = createSpaceKeys(join(root, 'space-keys'));
    const signer = await keys.createSigner('phone');

    // keyId must equal the gate's fingerprint, or enrollment answers with a
    // different id and spaces-mobile's identity check fails.
    const raw = Buffer.from(signer.publicKey, 'base64');
    const expect = crypto.createHash('sha256').update(raw).digest('hex').slice(0, 32);
    assert.equal(signer.keyId, expect);
    assert.equal(signer.algorithm, 'ecdsa-p256');
    // publicKey is the SPKI DER of a P-256 key
    const pub = crypto.createPublicKey({ key: raw, format: 'der', type: 'spki' });
    assert.equal(pub.asymmetricKeyType, 'ec');

    // the signature verifies against that public key, DER-encoded, sha256
    const message = Buffer.from('pi-spaces/auth/v1\nchallenge');
    const signature = signer.sign(message);
    assert.ok(crypto.verify('sha256', message, pub, signature));
    // and the fingerprint derivation matches what pi-spaces computes from the record
    assert.equal(signer.keyId, crypto.createHash('sha256').update(pub.export({ format: 'der', type: 'spki' })).digest('hex').slice(0, 32));
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('keys persist on disk and reload by alias with the same identity', async () => {
  const root = dir();
  try {
    const keysDir = join(root, 'space-keys');
    const first = await createSpaceKeys(keysDir).createSigner('phone');
    // a fresh instance (app restart) resolves the same alias and identity
    const reloaded = await createSpaceKeys(keysDir).signer(first.alias);
    assert.equal(reloaded.keyId, first.keyId);
    assert.equal(reloaded.publicKey, first.publicKey);
    const again = await createSpaceKeys(keysDir).createSigner('phone');
    assert.notEqual(again.alias, first.alias); // rotation needs a distinct key
    assert.notEqual(again.keyId, first.keyId);

    // privacy: 0700 directory, 0600 key files, nothing else in there
    assert.equal(statSync(keysDir).mode & 0o777, 0o700);
    for (const f of readdirSync(keysDir)) {
      assert.match(f, /^space-[A-Za-z0-9_.:-]+-[0-9a-f]+\.key$/);
      assert.equal(statSync(join(keysDir, f)).mode & 0o777, 0o600);
    }
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('aliases and peer ids are validated before they reach the filesystem', async () => {
  const root = dir();
  try {
    const keys = createSpaceKeys(join(root, 'space-keys'));
    await assert.rejects(keys.signer('../profile.json'), /invalid space key alias/);
    await assert.rejects(keys.signer('sub/dir'), /invalid space key alias/);
    await assert.rejects(keys.createSigner('a/b'), /invalid peer identity/);
    await assert.rejects(keys.signer('never-created'), /no space key/);
    assert.deepEqual(readdirSync(root), []); // nothing was created
  } finally { rmSync(root, { recursive: true, force: true }); }
});
