/* global chrome, TwoHbc */
const status = document.getElementById('status');
let origins = [];
async function init() {
  const r = await chrome.runtime.sendMessage({ kind: 'CONTROL', action: 'LIST' });
  if (!r.ok) throw new Error(r.error);
  origins = r.result.origins;
  for (const id of ['rexel','sonepar']) document.getElementById(id).value = JSON.stringify(r.result.profiles[id], null, 2);
}
document.getElementById('form').addEventListener('submit', async event => {
  event.preventDefault(); status.textContent = '';
  try {
    const profiles = Object.fromEntries(['rexel','sonepar'].map(id => [id, JSON.parse(document.getElementById(id).value)]));
    const raw = document.getElementById('origin').value.trim();
    if (raw) {
      const origin = TwoHbc.validateOrigin(raw);
      const granted = await chrome.permissions.request({ origins: [origin + '/*'] });
      if (!granted) throw new Error('Permission non accordée.');
      origins = Array.from(new Set([...origins, origin]));
    }
    const r = await chrome.runtime.sendMessage({ kind: 'CONTROL', action: 'SAVE_SETTINGS', origins, profiles });
    if (!r.ok) throw new Error(r.error);
    status.textContent = 'Réglages enregistrés. Actualisez le site 2HBC et les onglets fournisseurs avant un nouvel essai.';
  } catch (e) { status.textContent = e.message; }
});
init().catch(e => { status.textContent = e.message; });
