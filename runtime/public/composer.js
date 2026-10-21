// composer.js — the prompt composer shared by the chat and Remote pages:
// submitting shows the text at once (optimistic bubble) and posts it with one
// requestId for every retry, so a prompt the server already accepted before
// the connection dropped is never run a second time. Ctrl/cmd+Enter submits.
import { postJson } from './api.js';
import { newRequestId } from './transcript.js';

export function wireComposer({ form, input, transcript, steerBox, isBusy, endpoint, retries = 0 }) {
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const text = input.value.trim();
    if (!text) return;
    input.value = '';
    const pending = transcript.addPendingUser(text);
    const body = { message: text, requestId: newRequestId() };
    if (isBusy() && steerBox?.checked) body.whenBusy = 'steer';
    const r = await postJson(endpoint, body, { retries });
    if (r.error) transcript.failPending(pending, r.error);
  });
  input.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) form.requestSubmit();
  });
}
