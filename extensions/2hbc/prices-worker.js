/* global chrome, TwoHbcPrice */
// Jobs live only in this browser session. Caller identity binds each response to
// the initiating tab and UI session; Supabase independently enforces ownership.
async function priceJobs() {
  const data = (await chrome.storage.session.get('priceJobs')).priceJobs || {};
  for (const [id,job] of Object.entries(data)) if (Date.now() > job.deadline) delete data[id];
  return data;
}
function priceStatus(job) { return {id:job.id,state:job.state,error:job.error || '',quote:job.quote || null}; }
async function priceApp(m, sender, conf) {
  const all = await priceJobs(), origin = new URL(sender.url).origin;
  if (m.action === 'PRICE_START') {
    const r = TwoHbcPrice.priceRequest(m.payload);
    const profile = conf.profiles[r.supplier].price;
    if (!profile?.enabled) throw new Error('La lecture des prix doit être réglée sur les pages connectées de ce fournisseur.');
    const existing = all[r.id];
    if (existing) {
      if (existing.sourceTab !== sender.tab.id || existing.origin !== origin || existing.sessionId !== r.sessionId || existing.userId !== r.userId) throw new Error('Demande déjà utilisée.');
      return priceStatus(existing);
    }
    if (Object.values(all).some(j => j.supplier === r.supplier && j.state === 'reading')) throw new Error('Une lecture est déjà en cours chez ce fournisseur.');
    if (Object.keys(all).length >= 20) throw new Error('Trop de lectures récentes. Réessayez dans deux minutes.');
    const tab = await chrome.tabs.create({url:r.url,active:true});
    const job = {...r,profile,origin,sourceTab:sender.tab.id,supplierTab:tab.id,deadline:Date.now()+120000,state:'reading'};
    all[r.id] = job; await chrome.storage.session.set({priceJobs:all});
    return priceStatus(job);
  }
  const job = all[m.payload?.id];
  if (!job || job.sourceTab !== sender.tab.id || job.origin !== origin || job.userId !== m.payload.userId || job.sessionId !== m.payload.sessionId) throw new Error('Lecture expirée ou liée à une autre session.');
  if (m.action === 'PRICE_CANCEL') { job.state = 'cancelled'; delete job.quote; }
  else if (m.action !== 'PRICE_STATUS') throw new Error('Action de prix refusée.');
  await chrome.storage.session.set({priceJobs:all}); return priceStatus(job);
}
async function priceSupplier(m, sender) {
  const all = await priceJobs();
  const job = Object.values(all).find(j => j.supplierTab === sender.tab?.id && sender.frameId === 0 &&
    sender.url === j.url && (!m.id || m.id === j.id) && j.state === 'reading');
  if (!job) return null;
  if (m.action === 'GET') return job;
  if (m.action === 'RESULT') {
    job.quote = TwoHbcPrice.validatePrice(m.quote,job); job.state = 'observed';
  } else if (m.action === 'WAIT') {
    job.error = String(m.error || 'Lecture en attente.').slice(0,240);
  } else if (m.action === 'FAIL') {
    job.state = 'unavailable'; job.error = String(m.error || 'Prix indisponible.').slice(0,240);
  } else throw new Error('Action fournisseur refusée.');
  await chrome.storage.session.set({priceJobs:all}); return priceStatus(job);
}
