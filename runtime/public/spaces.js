import { initApi, postJson } from './api.js';
import { renderMenu } from './menu.js';
initApi(renderMenu());
const message = document.getElementById('space-message'), result = document.getElementById('space-result');
async function call(action, body = {}) {
  const buttons = [...document.querySelectorAll('button')]; buttons.forEach(b => b.disabled = true); message.textContent = 'Läuft …';
  try { const reply = await postJson('/api/spaces/' + action, body); if (reply.error) throw new Error(reply.error); result.textContent = JSON.stringify(reply, null, 2); message.textContent = 'Ergebnis empfangen'; return reply; }
  catch (error) { message.textContent = error.message; }
  finally { buttons.forEach(b => b.disabled = false); }
}
for (const button of document.querySelectorAll('[data-action]')) button.addEventListener('click', () => call(button.dataset.action));
for (const [id, action] of [['prepare', 'prepare'], ['data', 'dataHost']]) document.getElementById(id).addEventListener('submit', event => { event.preventDefault(); call(action, Object.fromEntries(new FormData(event.target))); });
document.getElementById('pair').addEventListener('submit', async event => {
  event.preventDefault(); const input = document.getElementById('enroll-token'); let value = input.value.trim(), controlSpaceId; input.value = '';
  try { if (value.startsWith('{')) { const qr = JSON.parse(value), status = await call('status'); if (!status) return; if (qr.v !== 1 || qr.endpoint !== status.profile?.endpoint || (status.profile?.controlSpaceId && qr.space !== status.profile.controlSpaceId)) throw new Error('QR-Endpunkt oder Control-Space passt nicht zur vorbereiteten Identität'); value = qr.token; controlSpaceId = qr.space; } await call('enroll', { token: value, controlSpaceId }); }
  catch (error) { message.textContent = error.message; }
  finally { value = ''; }
});
call('status');
