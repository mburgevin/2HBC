/* global chrome, TwoHbc */
(() => {
  if (globalThis.__twoHbcBridge) return;
  globalThis.__twoHbcBridge = true;
  const { PROTOCOL } = TwoHbc;
  const allowed = new Set(['PING', 'START', 'STATUS', 'CANCEL']);
  window.addEventListener('message', async event => {
    const m = event.data;
    if (event.source !== window || event.origin !== location.origin || !m ||
        m.channel !== PROTOCOL || m.direction !== 'app' || !allowed.has(m.action) ||
        typeof m.requestId !== 'string' || m.requestId.length > 80) return;
    let reply;
    try {
      reply = await chrome.runtime.sendMessage({ kind: 'APP', action: m.action, payload: m.payload });
    } catch {
      reply = { ok: false, error: 'Extension rechargée. Actualisez cette page.' };
    }
    window.postMessage({ channel: PROTOCOL, direction: 'extension', requestId: m.requestId,
      ok: Boolean(reply?.ok), result: reply?.result, error: reply?.error }, location.origin);
  });
})();
