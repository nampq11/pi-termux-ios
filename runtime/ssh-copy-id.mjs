// ssh-copy-id without a terminal. The interactive binary needs a PTY for the
// password prompt, which iOS cannot provide; this performs the same install
// the upstream script does (create ~/.ssh, dedupe, append, tight modes) over
// one password-authenticated exec on the pure-JS backend.
import { shq } from './remote-provision.mjs';
import { jsSshBackend } from './ssh-js-backend.mjs';

/** The remote install step, idempotent like ssh-copy-id: append unless the
 * exact key line is already present, with 0700/0600 modes. */
export function sshCopyIdCommand(pubkey) {
  const key = shq(pubkey);
  return 'umask 077; mkdir -p "$HOME/.ssh" && touch "$HOME/.ssh/authorized_keys" '
    + '&& chmod 700 "$HOME/.ssh" && chmod 600 "$HOME/.ssh/authorized_keys" '
    + `&& { grep -qxF ${key} "$HOME/.ssh/authorized_keys" || echo ${key} >> "$HOME/.ssh/authorized_keys"; }`;
}

/** Install the device key on the host. Auth rejection is reported distinctly
 * so the UI can re-ask for the password instead of showing a raw SSH error. */
export async function installDeviceKey({ home, host, port, password, pubkey, signal }) {
  try {
    const r = await jsSshBackend.run({ home, host, port, password, signal, command: sshCopyIdCommand(pubkey) });
    if (r.code !== 0) return { ok: false, error: r.err || 'key installation failed' };
    return { ok: true };
  } catch (e) {
    const authFailed = e?.level === 'client-authentication' || /authentication methods failed/i.test(e?.message || '');
    return { ok: false, authFailed, error: authFailed ? 'password rejected' : String(e?.message || e) };
  }
}
