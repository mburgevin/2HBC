/* global chrome, TwoHbc, TwoHbcConnectors */
importScripts('core.js', 'connectors.js');
const C = TwoHbc;
const TERMINAL = new Set(['verified','partial','indeterminate','cancelled','expired','interaction_required']);
const LABELS = {
  awaiting_setup: 'Réglage du connecteur requis', awaiting_confirmation: 'Confirmez le compte dans l’extension',
  baseline: 'Lecture du panier existant', awaiting_login: 'Connectez-vous chez le fournisseur',
  awaiting_quick_order: 'Ouverture de la commande rapide', preparing: 'Préparation du lot',
  awaiting_preview: 'Vérification des lignes reconnues', submitting: 'Ajout en cours',
  awaiting_cart: 'Vérification du panier', verified: 'Lignes et quantités vérifiées',
  partial: 'Écart détecté : vérifiez le panier', indeterminate: 'Résultat incertain : ne relancez pas sans vérifier',
  interaction_required: 'Intervention nécessaire chez le fournisseur', cancelled: 'Assistance arrêtée',
  expired: 'Transfert expiré'
};
let queue = Promise.resolve();
function locked(fn) {
  const next = queue.then(fn, fn);
  queue = next.catch(() => {});
  return next;
}
async function settings() {
  const data = await chrome.storage.local.get(['origins','profiles']);
  return { origins: Array.from(new Set([...C.DEFAULT_APP_ORIGINS, ...(data.origins || [])])),
    profiles: Object.fromEntries(Object.keys(C.SUPPLIERS).map(id => [id, data.profiles?.[id] || TwoHbcConnectors.defaults(id)])) };
}
async function tasks() { return (await chrome.storage.session.get('tasks')).tasks || {}; }
async function save(all) { await chrome.storage.session.set({ tasks: all }); }
function status(t) {
  return { id: t.id, supplier: t.supplier, state: t.state, message: LABELS[t.state] || t.state,
    detail: t.detail || '', result: t.result || null, attempted: Boolean(t.attempted), expiresAt: t.expiresAt };
}
function setState(t, state, detail = '') { t.state = state; t.updatedAt = Date.now(); t.detail = detail; }
function isSupplier(sender, t) {
  try { return sender.frameId === 0 && sender.tab?.id === t.supplierTab &&
    new URL(sender.url).origin === C.SUPPLIERS[t.supplier].origin; } catch { return false; }
}
function samePath(a, b) { try { return new URL(a).origin === new URL(b).origin && new URL(a).pathname === new URL(b).pathname; } catch { return false; } }
async function go(t, url) {
  if (!C.supplierUrl(t.supplier, url)) throw new Error('Destination fournisseur refusée.');
  await chrome.tabs.update(t.supplierTab, { url, active: true });
}
function currentUrl(sender) { return sender.url || sender.tab?.url || ''; }
async function cleanup() {
  const all = await tasks();
  const now = Date.now();
  let changed = false;
  for (const [id,t] of Object.entries(all)) {
    if (t.expiresAt <= now) { delete all[id]; changed = true; }
  }
  if (changed) await save(all);
}
chrome.runtime.onInstalled.addListener(() => {
  chrome.storage.session.setAccessLevel({ accessLevel: 'TRUSTED_CONTEXTS' });
  chrome.alarms.create('expire-transfers', { periodInMinutes: 1 });
});
chrome.alarms.onAlarm.addListener(a => { if (a.name === 'expire-transfers') locked(cleanup); });
chrome.tabs.onRemoved.addListener(tabId => locked(async () => {
  const all = await tasks();
  for (const t of Object.values(all)) {
    if (t.supplierTab === tabId && !TERMINAL.has(t.state)) setState(t, t.attempted ? 'indeterminate' : 'cancelled', 'Onglet fournisseur fermé.');
  }
  await save(all);
}));
async function handleApp(m, sender) {
  const conf = await settings();
  const origin = new URL(currentUrl(sender)).origin;
  if (sender.frameId !== 0 || !conf.origins.includes(origin)) throw new Error('Site 2HBC non autorisé dans les réglages de l’extension.');
  if (m.action === 'PING') return { version: '0.1.0', suppliers: Object.fromEntries(Object.entries(conf.profiles).map(([k,v]) => [k, Boolean(v.enabled)])) };
  await cleanup();
  const all = await tasks();
  if (m.action === 'START') {
    const transfer = C.validateTransfer(m.payload);
    const key = C.fingerprint(transfer);
    const duplicate = Object.values(all).find(t => t.sourceOrigin === origin && t.sourceTab === sender.tab.id &&
      (t.id === transfer.id || t.fingerprint === key) && (t.attempted || t.state !== 'cancelled'));
    if (duplicate) return status(duplicate);
    if (Object.values(all).some(t => t.supplier === transfer.supplier && !TERMINAL.has(t.state))) throw new Error('Un transfert est déjà en cours chez ce fournisseur. Terminez-le dans l’extension.');
    if (Object.keys(all).length >= 10) throw new Error('Trop de transferts en cours. Terminez-les ou attendez leur expiration.');
    const profile = TwoHbcConnectors.validateProfile(transfer.supplier, conf.profiles[transfer.supplier]);
    const tab = await chrome.tabs.create({ url: C.SUPPLIERS[transfer.supplier].quickOrderUrl, active: true });
    const t = { ...transfer, supplierTab: tab.id, sourceTab: sender.tab.id, sourceOrigin: origin,
      fingerprint: key, attempted: false, updatedAt: Date.now(),
      state: profile.enabled ? 'awaiting_confirmation' : 'awaiting_setup' };
    all[t.id] = t; await save(all);
    await chrome.action.setBadgeText({ text: '1' });
    return status(t);
  }
  const t = all[m.payload?.id];
  if (!t || t.sourceOrigin !== origin || t.sourceTab !== sender.tab.id) throw new Error('Transfert introuvable ou expiré.');
  if (m.action === 'STATUS') return status(t);
  if (m.action === 'CANCEL') {
    setState(t, t.attempted ? 'indeterminate' : 'cancelled', t.attempted ? 'Assistance arrêtée ; vérifiez les éventuels ajouts dans le panier.' : '');
    await save(all); return status(t);
  }
  throw new Error('Action refusée.');
}
async function handleControl(m, sender) {
  if (!sender.url?.startsWith(chrome.runtime.getURL('')) || !/\/(popup|options)\.html(?:[?#]|$)/.test(sender.url)) throw new Error('Contrôle réservé à l’extension.');
  await cleanup();
  const conf = await settings(), all = await tasks();
  if (m.action === 'LIST') return { tasks: Object.values(all).map(t => ({ ...status(t), count: t.lines.length, supplierTab: t.supplierTab })),
    origins: conf.origins, profiles: conf.profiles };
  if (m.action === 'SAVE_SETTINGS') {
    const profiles = Object.fromEntries(Object.keys(C.SUPPLIERS).map(id => [id, TwoHbcConnectors.validateProfile(id, m.profiles?.[id])]));
    const origins = (m.origins || []).map(C.validateOrigin);
    for (const origin of origins) {
      const u = new URL(origin);
      const pattern = u.protocol + '//' + u.hostname + '/*';
      if (!await chrome.permissions.contains({ origins: [pattern] })) throw new Error('Autorisez d’abord le domaine dans le navigateur.');
    }
    await chrome.storage.local.set({ profiles, origins });
    const existing = await chrome.scripting.getRegisteredContentScripts();
    if (existing.length) await chrome.scripting.unregisterContentScripts({ ids: existing.map(s => s.id) });
    const custom = origins.filter(o => !C.DEFAULT_APP_ORIGINS.includes(o));
    if (custom.length) await chrome.scripting.registerContentScripts(custom.map((origin, i) => ({
      id: 'two-hbc-' + i, matches: [origin + '/*'], js: ['core.js','bridge.js'], runAt: 'document_idle', persistAcrossSessions: true
    })));
    return { saved: true };
  }
  const t = all[m.id];
  if (!t) throw new Error('Transfert introuvable ou expiré.');
  if (m.action === 'ARCHIVE') {
    if (!TERMINAL.has(t.state)) throw new Error('Arrêtez le transfert avant de le clôturer.');
    delete all[t.id]; await save(all); return { archived: true };
  }
  if (m.action === 'FOCUS') { await chrome.tabs.update(t.supplierTab, { active: true }); return status(t); }
  if (m.action === 'CANCEL') {
    setState(t, t.attempted ? 'indeterminate' : 'cancelled', 'Assistance arrêtée. Aucun ajout déjà effectué n’est annulé.');
    await save(all); return status(t);
  }
  if (m.action === 'RUN') {
    if (t.attempted || !['awaiting_setup','awaiting_confirmation'].includes(t.state)) throw new Error('Ce transfert ne peut pas être relancé. Vérifiez le panier.');
    const profile = TwoHbcConnectors.validateProfile(t.supplier, conf.profiles[t.supplier]);
    if (!profile.enabled) throw new Error('Repérez et activez le connecteur dans les réglages.');
    // Freeze the adapter for this transfer; editing settings cannot change an in-flight operation.
    t.profile = profile;
    setState(t, 'baseline'); await save(all); await go(t, profile.cartUrl);
    return status(t);
  }
  throw new Error('Action de contrôle refusée.');
}
async function handleSupplier(m, sender) {
  const all = await tasks();
  const t = Object.values(all).find(value => isSupplier(sender, value) && (!m.id || value.id === m.id));
  if (!t) return null;
  if (t.expiresAt <= Date.now()) { delete all[t.id]; await save(all); return null; }
  const p = t.profile;
  if (!p || TERMINAL.has(t.state)) return { ...status(t), terminal: true };
  if (m.action === 'GET') {
    if (m.login && !['awaiting_setup','awaiting_confirmation','awaiting_login'].includes(t.state)) {
      if (t.attempted) setState(t, 'indeterminate', 'Session interrompue pendant le transfert. Vérifiez le panier.');
      else { t.resumeState = t.state; setState(t, 'awaiting_login'); }
      await save(all);
    } else if (!m.login && t.state === 'awaiting_login') {
      setState(t, t.resumeState || 'baseline'); await save(all);
      await go(t, t.state === 'baseline' ? p.cartUrl : p.quickOrderUrl);
    }
    // A navigation after the add click is a valid way for the supplier to show its cart.
    if (t.state === 'submitting' && samePath(sender.url, p.cartUrl)) { setState(t, 'awaiting_cart'); await save(all); }
    if (['preparing','submitting'].includes(t.state) && Date.now() - t.updatedAt > 45000) {
      setState(t, 'indeterminate', 'Aucune confirmation reçue après une action. Vérifiez le panier avant tout nouvel essai.'); await save(all);
    }
    return { ...status(t), lines: t.lines, profile: p, terminal: TERMINAL.has(t.state) };
  }
  if (m.action === 'FAIL') {
    setState(t, t.attempted ? 'indeterminate' : 'interaction_required', String(m.detail || 'Interface non reconnue.').slice(0, 300));
    await save(all); return status(t);
  }
  const expected = {
    BASELINE: 'baseline', CLAIM_PREPARE: 'awaiting_quick_order', PREPARED: 'preparing',
    CLAIM_ADD: 'awaiting_preview', ADDED: 'submitting', VERIFIED: 'awaiting_cart'
  }[m.action];
  if (!expected || t.state !== expected) throw new Error('Étape déjà traitée ou arrêtée.');
  const expectedUrl = ['BASELINE','VERIFIED'].includes(m.action) ? p.cartUrl : p.quickOrderUrl;
  if (!samePath(sender.url, expectedUrl)) throw new Error('Page fournisseur inattendue.');
  if (m.action === 'BASELINE' || m.action === 'VERIFIED') {
    const snapshot = m.snapshot;
    if (!snapshot || Array.isArray(snapshot) || typeof snapshot !== 'object' || Object.keys(snapshot).length > 2000 ||
        Object.entries(snapshot).some(([ref,qty]) => typeof ref !== 'string' || ref.length > 80 || !Number.isInteger(qty) || qty < 0 || qty > 1000000)) throw new Error('Lecture de panier invalide.');
    if (m.action === 'BASELINE') {
      t.before = snapshot; setState(t, 'awaiting_quick_order'); await save(all); await go(t, p.quickOrderUrl);
    } else {
      t.result = C.reconcile(t.lines, t.before, snapshot);
      setState(t, t.result.state); await save(all); await chrome.action.setBadgeText({ text: t.state === 'verified' ? '✓' : '!' });
    }
  } else if (m.action === 'CLAIM_PREPARE') {
    t.attempted = true; setState(t, 'preparing'); await save(all);
  } else if (m.action === 'PREPARED') {
    setState(t, 'awaiting_preview'); await save(all);
  } else if (m.action === 'CLAIM_ADD') {
    const r = C.reconcile(t.lines, {}, m.snapshot);
    if (r.state !== 'verified' || Object.keys(m.snapshot).some(ref => !t.lines.some(l => l.ref === ref))) throw new Error('Les références ou quantités reconnues diffèrent du lot. Vérifiez la commande rapide.');
    setState(t, 'submitting'); await save(all);
  } else if (m.action === 'ADDED') {
    setState(t, 'awaiting_cart'); await save(all); await go(t, p.cartUrl);
  }
  return status(t);
}
chrome.runtime.onMessage.addListener((m, sender, reply) => {
  locked(async () => {
    if (!m || typeof m !== 'object') throw new Error('Message invalide.');
    if (m.kind === 'APP') return handleApp(m, sender);
    if (m.kind === 'CONTROL') return handleControl(m, sender);
    if (m.kind === 'SUPPLIER') return handleSupplier(m, sender);
    throw new Error('Canal non autorisé.');
  }).then(result => reply({ ok: true, result }), error => reply({ ok: false, error: error.message || 'Opération refusée.' }));
  return true;
});
