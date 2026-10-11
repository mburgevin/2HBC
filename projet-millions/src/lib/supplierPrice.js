// Shared validation for the site and the extension. No credentials in this protocol.
export const PRICE_TTL = 10 * 60 * 1000;
export function productPage(supplier, value) {
  try {
    const u = new URL(value);
    const origin = {rexel:'https://www.rexel.fr',sonepar:'https://www.sonepar.fr'}[supplier];
    const path = supplier === 'rexel' ? /^\/frx\/.*\/p\/[0-9]+$/ : /^\/catalog\/fr-fr\/products\/[a-z0-9-]+$/i;
    return u.origin === origin && !u.username && !u.password && !u.search && !u.hash && path.test(u.pathname) ? u.href : null;
  } catch { return null; }
}
export function priceRequest(value) {
  if (!value || !/^[a-zA-Z0-9-]{16,80}$/.test(value.id || '') || !/^[a-f0-9-]{36}$/i.test(value.userId || '') ||
      !/^[a-f0-9-]{36}$/i.test(value.sessionId || '') || !Number.isSafeInteger(value.offerId) || value.offerId < 1 ||
      !productPage(value.supplier, value.url) || typeof value.ref !== 'string' || !/^[A-Za-z0-9._ /-]{1,80}$/.test(value.ref) ||
      !Number.isInteger(value.quantity) || value.quantity < 1 || value.quantity > 9999) throw new Error('Demande de prix invalide.');
  return {id:value.id,userId:value.userId,sessionId:value.sessionId,offerId:value.offerId,supplier:value.supplier,
    url:value.url,ref:value.ref,quantity:value.quantity};
}
export function frenchDecimal(value) {
  const text = String(value).trim().replace(/[\s\u00a0\u202f]/g,'').replace(/(?:€|EUR)$/i,'');
  // Ambiguous thousands/decimal separators, ranges and labels are rejected.
  if (!/^\d+(?:[,.]\d{1,4})?$/.test(text)) throw new Error('Montant ou quantité illisible.');
  const n = Number(text.replace(',','.'));
  if (!Number.isFinite(n) || n <= 0 || n > 1000000) throw new Error('Montant ou quantité hors limites.');
  return n;
}
export function validatePrice(value, request, now = Date.now()) {
  const r = priceRequest(request);
  if (!value || value.offerId !== r.offerId || value.supplier !== r.supplier || value.ref !== r.ref ||
      value.quantity !== r.quantity || value.url !== r.url || value.currency !== 'EUR' || value.tax !== 'HT' || value.kind !== 'net_account' ||
      !/^[a-f0-9]{64}$/.test(value.contextKey || '') || !['piece','m','kg'].includes(value.unit) ||
      !Number.isFinite(value.amount) || value.amount <= 0 || value.amount > 1000000 ||
      !Number.isFinite(value.basis) || value.basis <= 0 || value.basis > 1000000 ||
      !Number.isFinite(value.observedAt) || value.observedAt > now + 60000 || now - value.observedAt >= PRICE_TTL) {
    throw new Error('Prix personnel non vérifiable ou périmé.');
  }
  return {offerId:r.offerId,supplier:r.supplier,ref:r.ref,quantity:r.quantity,url:r.url,amount:value.amount,basis:value.basis,
    unit:value.unit,currency:'EUR',tax:'HT',kind:'net_account',contextKey:value.contextKey,observedAt:value.observedAt,
    expiresAt:value.observedAt + PRICE_TTL};
}
