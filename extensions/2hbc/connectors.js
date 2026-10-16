/* global TwoHbc */
(() => {
  const fields = ['inputSelector','analyzeSelector','previewRows','previewRef','previewQty',
    'addSelector','successSelector','cartRows','cartRef','cartQty','emptyCartSelector','errorSelector'];
  const priceFields = ['accountSelector','contextSelector','refSelector','kindSelector','taxSelector',
    'quantitySelector','unitSelector','currencySelector','priceSelector','basisSelector'];
  function priceDefaults() { return {enabled:false,...Object.fromEntries(priceFields.map(k=>[k,'']))}; }
  function priceProfile(value) {
    const out = {...priceDefaults(),...value};
    if (typeof out.enabled !== 'boolean') throw new Error('Profil de prix invalide.');
    for (const key of priceFields) {
      if (typeof out[key] !== 'string' || out[key].length > 240 || (out.enabled && !out[key].trim())) throw new Error('Repérage de prix requis : ' + key);
    }
    return {enabled:out.enabled,...Object.fromEntries(priceFields.map(k=>[k,out[k].trim()]))};
  }
  function defaults(id) {
    return { price: priceDefaults(), enabled: false, mode: 'text', quickOrderUrl: TwoHbc.SUPPLIERS[id].quickOrderUrl,
      cartUrl: '', delimiter: ',', header: '',
      inputSelector: id === 'rexel' ? '.copyPasteDiv textarea' : '',
      analyzeSelector: '', previewRows: '', previewRef: '', previewQty: '', addSelector: '',
      successSelector: '', cartRows: '', cartRef: '', cartQty: '', emptyCartSelector: '', errorSelector: '' };
  }
  function validateProfile(id, value) {
    const p = { ...defaults(id), ...value };
    if (!TwoHbc.SUPPLIERS[id] || typeof p.enabled !== 'boolean') throw new Error('Connecteur invalide.');
    const out = { price: priceProfile(p.price), enabled: p.enabled, mode: p.mode, delimiter: p.delimiter, header: p.header,
      quickOrderUrl: p.quickOrderUrl, cartUrl: p.cartUrl };
    if (!['text','file'].includes(p.mode) || ![',',';','\t'].includes(p.delimiter) ||
        typeof p.header !== 'string' || p.header.length > 160 || /[\r\n]/.test(p.header)) throw new Error('Format du lot invalide.');
    for (const key of fields) {
      if (typeof p[key] !== 'string' || p[key].length > 240) throw new Error('Sélecteur invalide : ' + key);
      out[key] = p[key].trim();
    }
    if (p.enabled) {
      if (!TwoHbc.supplierUrl(id, p.quickOrderUrl) || !TwoHbc.supplierUrl(id, p.cartUrl) ||
          /login|register|connexion/i.test(new URL(p.quickOrderUrl).pathname + new URL(p.cartUrl).pathname) ||
          new URL(p.quickOrderUrl).pathname === new URL(p.cartUrl).pathname) throw new Error('Vérifiez les URL de commande rapide et de panier.');
      for (const key of ['inputSelector','previewRows','previewRef','previewQty','addSelector','cartRows','cartRef','cartQty','emptyCartSelector']) {
        if (!out[key]) throw new Error('Repérage connecté requis : ' + key);
      }
    }
    return out;
  }
  globalThis.TwoHbcConnectors = { defaults, validateProfile };
})();
