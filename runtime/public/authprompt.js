// One modal implementation for security decisions. Never interpolate remote text as HTML.
import { postJson } from './api.js';
import { API } from './constants.js';

function ask(message, yes, no, danger = false) {
  return new Promise((resolve) => {
    const overlay = document.createElement('div');
    overlay.className = 'modal-overlay';
    const box = document.createElement('div');
    box.className = 'modal-box';
    const text = document.createElement('p');
    text.textContent = message;
    if (danger) text.className = 'danger-text';
    const row = document.createElement('div');
    row.className = 'modal-row';
    const done = (v) => { overlay.remove(); resolve(v); };
    for (const [label, v] of [[yes, true], [no, false]]) {
      const button = document.createElement('button');
      button.textContent = label;
      if (v && danger) button.className = 'danger-btn';
      button.addEventListener('click', () => done(v));
      row.appendChild(button);
    }
    box.append(text, row);
    overlay.appendChild(box);
    document.body.appendChild(overlay);
  });
}
export const askTrustHost = (target, fingerprint) => ask(
  `Verify the SSH host fingerprint for ${target} OUTSIDE this app before continuing: ${fingerprint}. A fake host could steal all API keys and OAuth tokens from this phone. Do you trust this fingerprint?`,
  'Fingerprint verified', 'Cancel', true);
export const askCopyAuth = (target) => ask(
  `WARNING: ${target} has no auth.json. Copy ALL API keys and OAuth tokens stored on this phone to the host? Anyone with access to that host could use them.`,
  'Yes, copy', 'No', true);
export const askInstallKey = (target) => ask(
  `${target} does not accept this device's SSH key. Install it with ssh-copy-id? You will be asked for the host password once.`,
  'Yes, install key', 'No');
export const askUpdate = (target, info) => ask(
  `pi-serverd on ${target} is outdated (${info.installed || 'unknown'} → ${info.available}). Update it now? Running work is interrupted; durable sessions resume afterwards.`,
  'Yes, update', 'No, keep old version');

/** Password prompt for the PTY-less key install (iOS): the value goes to one
 * bridge call and is never stored. Resolves null on cancel. */
function askPassword(message) {
  return new Promise((resolve) => {
    const overlay = document.createElement('div');
    overlay.className = 'modal-overlay';
    const box = document.createElement('div');
    box.className = 'modal-box';
    const text = document.createElement('p');
    text.textContent = message;
    const input = document.createElement('input');
    input.type = 'password';
    input.autocomplete = 'off';
    input.placeholder = 'password';
    const row = document.createElement('div');
    row.className = 'modal-row';
    const done = (v) => { overlay.remove(); resolve(v); };
    for (const [label, v] of [['Install key', () => input.value], ['Cancel', null]]) {
      const button = document.createElement('button');
      button.textContent = label;
      button.addEventListener('click', () => done(v()));
      row.appendChild(button);
    }
    box.append(text, input, row);
    overlay.appendChild(box);
    document.body.appendChild(overlay);
    input.focus();
  });
}

/** Key install without a terminal (iOS): confirm, ask the host password, let
 * the bridge install the device key over password-authenticated SSH. A
 * rejected password is re-asked; any other failure ends the flow. */
export async function installKeyWithPassword(target) {
  if (!await askInstallKey(target)) return false;
  for (let i = 0; i < 3; i++) {
    const password = await askPassword(`Password for ${target}:`);
    if (password === null) return false;
    const r = await postJson(API.sshCopyId, { target, password });
    if (r.ok) return true;
    if (!r.authFailed) {
      await ask(`Installing the key on ${target} failed: ${r.error || 'unknown error'}`, 'OK', 'Close');
      return false;
    }
  }
  return false;
}
