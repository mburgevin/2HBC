/* global chrome, TwoHbcPrice */
(() => {
  let busy = false, last = null;
  const visible = el => el && el.getClientRects().length && getComputedStyle(el).visibility !== 'hidden';
  function read(selector) {
    const nodes = [...document.querySelectorAll(selector)].filter(visible);
    if (nodes.length !== 1 || nodes[0].type === 'password') throw new Error('Champ de prix absent ou ambigu.');
    return String(nodes[0].value ?? nodes[0].textContent).trim();
  }
  function snapshot(p, job) {
    const account = read(p.accountSelector), context = read(p.contextSelector);
    if (!account || !context) throw new Error('Compte ou contexte commercial non identifié.');
    if (read(p.refSelector) !== job.ref) throw new Error('Référence différente de celle demandée.');
    if (!/^prix net(?:\s+HT)?$/i.test(read(p.kindSelector)) || !/^HT$/i.test(read(p.taxSelector))) throw new Error('Le prix net HT du compte n’est pas identifié.');
    const quantity = TwoHbcPrice.frenchDecimal(read(p.quantitySelector));
    if (quantity !== job.quantity) throw new Error('Réglez la quantité demandée sur la fiche fournisseur.');
    const units = {'unité':'piece','unité(s)':'piece','pièce':'piece','pièce(s)':'piece','m':'m','kg':'kg'};
    const unit = units[read(p.unitSelector).toLowerCase()];
    if (!unit || read(p.currencySelector) !== 'EUR') throw new Error('Unité ou devise non reconnue.');
    return {account,context,amount:TwoHbcPrice.frenchDecimal(read(p.priceSelector)),basis:TwoHbcPrice.frenchDecimal(read(p.basisSelector)),quantity,unit};
  }
  async function tick() {
    if (busy) return;
    busy = true;
    try {
      const response = await chrome.runtime.sendMessage({kind:'PRICE_SUPPLIER',action:'GET'});
      const job = response?.result;
      if (!job) { last = null; return; }
      // Never read login or challenge fields. User completes authentication normally.
      if ([...document.querySelectorAll('input[type="password"],input[autocomplete="one-time-code"],iframe[src*="captcha"]')].some(visible)) {last=null;return;}
      let data;
      try { data = snapshot(job.profile,job); } catch { last=null;return; }
      // Two stable DOM observations reduce reads while prices/context are loading.
      const key = JSON.stringify(data);
      if (!last || last.id !== job.id || last.key !== key) {last={id:job.id,key};return;}
      const bytes = new TextEncoder().encode([job.sessionId,job.userId,job.supplier,data.account,data.context].join('\n'));
      const hash = await crypto.subtle.digest('SHA-256',bytes);
      const contextKey = [...new Uint8Array(hash)].map(b=>b.toString(16).padStart(2,'0')).join('');
      const quote = {offerId:job.offerId,supplier:job.supplier,ref:job.ref,url:job.url,quantity:data.quantity,
        amount:data.amount,basis:data.basis,unit:data.unit,currency:'EUR',tax:'HT',kind:'net_account',contextKey,observedAt:Date.now()};
      await chrome.runtime.sendMessage({kind:'PRICE_SUPPLIER',action:'RESULT',id:job.id,quote});
      last=null;
    } catch { last=null; } finally {busy=false;}
  }
  tick();setInterval(tick,1500);
})();
