/* global chrome, TwoHbc */
(() => {
  if (globalThis.__twoHbcSupplier) return;
  globalThis.__twoHbcSupplier = true;
  let running = false, lastState = '', since = Date.now(), stopped = false;
  let rootsCache = [];
  const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
  function roots() {
    const list = [document];
    for (let i = 0; i < list.length; i++) {
      for (const el of list[i].querySelectorAll('*')) if (el.shadowRoot) list.push(el.shadowRoot);
    }
    return list;
  }
  function all(selector, root) {
    if (!selector) return [];
    return Array.from(new Set((root ? [root] : rootsCache).flatMap(r => Array.from(r.querySelectorAll(selector)))));
  }
  function visible(el) { return el && !el.hidden && el.getClientRects().length > 0 && getComputedStyle(el).visibility !== 'hidden'; }
  function one(selector, { hidden = false } = {}) {
    const found = all(selector).filter(el => hidden || visible(el));
    if (found.length > 1) throw new Error('Plusieurs éléments correspondent au réglage. Précisez le sélecteur.');
    return found[0] || null;
  }
  function samePath(a,b) { return new URL(a).origin === new URL(b).origin && new URL(a).pathname === new URL(b).pathname; }
  function value(el) { return typeof el.value === 'string' ? el.value.trim() : el.textContent.trim(); }
  function snapshot(p, preview = false) {
    const rows = all(preview ? p.previewRows : p.cartRows).filter(visible);
    if (!rows.length) return !preview && one(p.emptyCartSelector) ? {} : null;
    if (rows.length > 2000) throw new Error('Panier trop volumineux pour ce prototype.');
    const result = Object.create(null);
    for (const row of rows) {
      const refs = all(preview ? p.previewRef : p.cartRef, row);
      const quantities = all(preview ? p.previewQty : p.cartQty, row);
      if (refs.length !== 1 || quantities.length !== 1) throw new Error('Référence ou quantité non identifiable dans une ligne.');
      const ref = value(refs[0]), raw = value(quantities[0]);
      if (!ref || ref.length > 80 || !/^[0-9]+$/.test(raw)) throw new Error('Format de référence ou quantité inattendu. Vérifiez les unités.');
      const n = Number(raw);
      if (!Number.isInteger(n) || n < 1 || n > 1000000) throw new Error('Quantité non prise en charge.');
      result[ref] = (result[ref] || 0) + n;
    }
    return result;
  }
  function nativeInput(el, text) {
    if (!(el instanceof HTMLTextAreaElement || el instanceof HTMLInputElement && ['text','search'].includes(el.type))) throw new Error('Le champ du lot doit être une zone de texte.');
    if (el.disabled || el.readOnly || el.value.trim()) throw new Error('Videz la commande rapide existante avant cet essai.');
    const prototype = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(prototype, 'value').set.call(el, text);
    el.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
    el.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
  }
  function button(selector, type, supplier) {
    const el = one(selector);
    if (!el) return null;
    if (!(el instanceof HTMLButtonElement || el instanceof HTMLInputElement && ['button','submit'].includes(el.type)) ||
        el.disabled || el.getAttribute('aria-disabled') === 'true') return null;
    const label = (el.textContent || el.value || el.getAttribute('aria-label') || '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase();
    if (/commander|commande|valider|payer|paiement|checkout|acheter|purchase|buy|confirm/.test(label)) throw new Error('Ce bouton peut engager une commande : action refusée.');
    if (type === 'add' ? !/ajouter.*panier|add.*cart/.test(label)
      : /panier|cart/.test(label) || !/analyser|importer|rechercher|charger|afficher|ajouter.*(produit|reference)/.test(label)) throw new Error('Libellé du bouton non reconnu pour cette étape.');
    const action = el.form && (el.getAttribute('formaction') || el.form.action);
    if (action && !TwoHbc.supplierUrl(supplier, new URL(action, location.href).href)) throw new Error('Destination de formulaire refusée.');
    return el;
  }
  async function send(action, t, extra = {}) {
    const r = await chrome.runtime.sendMessage({ kind: 'SUPPLIER', action, id: t?.id, ...extra });
    if (!r?.ok) throw new Error(r?.error || 'Extension indisponible.');
    return r.result;
  }
  function loginPage() {
    return /\/(?:login|connexion|signin|register)(?:[/?]|$)/i.test(location.pathname) ||
      all('input[type="password"], input[autocomplete="one-time-code"], iframe[src*="captcha"], [data-testid="captcha"]').some(visible);
  }
  async function tick() {
    if (running || stopped) return;
    running = true;
    let t;
    try {
      rootsCache = roots();
      t = await send('GET', null, { login: loginPage() });
      if (!t || t.terminal) return;
      if (t.state !== lastState) { lastState = t.state; since = Date.now(); }
      const p = t.profile;
      if (!p || ['awaiting_login','awaiting_confirmation','awaiting_setup','preparing','submitting'].includes(t.state)) return;
      if (Date.now() - since > 45000) throw new Error('Interface attendue non trouvée. Vérifiez les réglages et le panier avant un nouvel essai.');
      if (p.errorSelector && one(p.errorSelector)) throw new Error('Le fournisseur affiche une erreur. Corrigez-la manuellement et vérifiez le panier.');
      if (t.state === 'baseline' && samePath(location.href, p.cartUrl)) {
        const before = snapshot(p);
        if (before) await send('BASELINE', t, { snapshot: before });
      } else if (t.state === 'awaiting_quick_order' && samePath(location.href, p.quickOrderUrl)) {
        const input = one(p.inputSelector, { hidden: p.mode === 'file' });
        if (!input) return;
        if (all(p.previewRows).filter(visible).length) throw new Error('La commande rapide contient déjà des lignes. Videz-la avant le test.');
        if (p.mode === 'text' && input.value?.trim()) throw new Error('La zone de saisie contient déjà une sélection.');
        if (p.mode === 'file' && (!(input instanceof HTMLInputElement) || input.type !== 'file' || input.disabled || input.files.length)) throw new Error('Champ de fichier non disponible.');
        const analyze = p.analyzeSelector ? button(p.analyzeSelector, 'analyze', t.supplier) : null;
        // Claim persists BEFORE any event: a supplier can react to a file change immediately.
        await send('CLAIM_PREPARE', t);
        const text = TwoHbc.quickOrderText(t.lines, p.delimiter, p.header);
        if (p.mode === 'text') nativeInput(input, text);
        else {
          const data = new DataTransfer();
          data.items.add(new File(['\uFEFF' + text], 'panier-2hbc.csv', { type: 'text/csv' }));
          input.files = data.files;
          input.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
          input.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
        }
        // Some sites enable the analyze action only once the input has changed.
        if (p.analyzeSelector) {
          const ready = analyze || button(p.analyzeSelector, 'analyze', t.supplier);
          if (!ready) throw new Error('Le bouton d’analyse n’est pas disponible après saisie.');
          ready.click();
        }
        await send('PREPARED', t);
      } else if (t.state === 'awaiting_preview' && samePath(location.href, p.quickOrderUrl)) {
        const preview = snapshot(p, true);
        if (!preview) return;
        const comparison = TwoHbc.reconcile(t.lines, {}, preview);
        if (comparison.state !== 'verified' || Object.keys(preview).length !== t.lines.length) throw new Error('Le lot reconnu diffère des références ou quantités demandées. Aucun clic d’ajout effectué.');
        const add = button(p.addSelector, 'add', t.supplier);
        if (!add) return;
        if (p.successSelector && one(p.successSelector)) throw new Error('Une ancienne confirmation est encore visible. Vérifiez le panier avant de continuer.');
        await send('CLAIM_ADD', t, { snapshot: preview });
        add.click();
        // Do not leave the page immediately: this could abort the site's own XHR.
        for (let i = 0; i < 60; i++) {
          await pause(500);
          rootsCache = roots();
          if (samePath(location.href, p.cartUrl)) return; // GET will reconcile after navigation.
          if (p.errorSelector && one(p.errorSelector)) throw new Error('Le fournisseur signale une erreur après l’ajout. Vérifiez le panier.');
          if (p.successSelector && one(p.successSelector)) { await send('ADDED', t); return; }
        }
        throw new Error('Ajout envoyé sans confirmation détectable. Vérifiez le panier ; ne relancez pas automatiquement.');
      } else if (t.state === 'awaiting_cart' && samePath(location.href, p.cartUrl)) {
        const after = snapshot(p);
        if (after) await send('VERIFIED', t, { snapshot: after });
      }
    } catch (error) {
      if (t?.id) {
        try { await send('FAIL', t, { detail: error.message }); } catch { stopped = true; }
      }
    } finally { running = false; }
  }
  setInterval(tick, 1200);
  tick();
})();
