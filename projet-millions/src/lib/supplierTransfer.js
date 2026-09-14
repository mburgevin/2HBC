// Shared with the extension by scripts/package-extension.cjs.
export const PROTOCOL = '2HBC_AUTO_CART_V1';
export const MAX_LINES = 200;
export const TTL_MS = 30 * 60 * 1000;
export const SUPPLIERS = Object.freeze({
  rexel: { name: 'Rexel', origin: 'https://www.rexel.fr', quickOrderUrl: 'https://www.rexel.fr/frx/newQuickorder' },
  sonepar: { name: 'Sonepar', origin: 'https://www.sonepar.fr', quickOrderUrl: 'https://www.sonepar.fr/fr-fr' }
});
export const DEFAULT_APP_ORIGINS = Object.freeze([
  'https://2-hbc.vercel.app',
  'https://2-hbc-mburgevins-projects.vercel.app',
  'https://2-hbc-git-feature-2hbc-dev-mburgevins-projects.vercel.app',
  'http://localhost:3000', 'http://127.0.0.1:3000'
]);
export function supplierId(name) {
  const normalized = String(name || '').trim().toLowerCase();
  return normalized === 'rexel' || normalized === 'rexel france' ? 'rexel'
    : normalized === 'sonepar' || normalized === 'sonepar france' ? 'sonepar' : null;
}
export function supplierUrl(id, value) {
  try {
    const u = new URL(value);
    if (!SUPPLIERS[id] || u.origin !== SUPPLIERS[id].origin || u.username || u.password || u.hash) return null;
    if (/checkout|payment|place.?order|submit.?order|confirmation.?commande|j_spring_security_check/i.test(u.pathname)) return null;
    return u.href;
  } catch { return null; }
}
export function validateOrigin(value) {
  const u = new URL(value);
  const isVercelOrigin = u.protocol === 'https:' && u.hostname.endsWith('.vercel.app');
  const isLocalOrigin = u.protocol === 'http:' &&
    ['localhost', '127.0.0.1'].includes(u.hostname) && u.port === '3000';
  if (u.origin !== value || u.username || u.password || !(isVercelOrigin || isLocalOrigin)) {
    throw new Error('Utilisez l’origine exacte du site 2HBC sur Vercel ou http://localhost:3000.');
  }
  return u.origin;
}
export function normalizeLines(lines) {
  if (!Array.isArray(lines) || !lines.length || lines.length > MAX_LINES) throw new Error('Le transfert doit contenir de 1 à 200 lignes.');
  const result = new Map();
  for (const line of lines) {
    if (!line || typeof line.ref !== 'string') throw new Error('Référence fournisseur manquante.');
    const ref = line.ref.trim();
    // Keep leading zeroes, reject CSV formulas, delimiters and multiline payloads.
    if (!/^[\p{L}\p{N}][\p{L}\p{N}._ /-]{0,79}$/u.test(ref)) throw new Error('Référence fournisseur invalide : ' + ref.slice(0, 80));
    if (!Number.isInteger(line.quantity) || line.quantity < 1 || line.quantity > 9999) throw new Error('Quantité attendue : un entier entre 1 et 9999.');
    const quantity = (result.get(ref)?.quantity || 0) + line.quantity;
    if (quantity > 9999) throw new Error('Quantité cumulée supérieure à 9999 pour ' + ref + '.');
    result.set(ref, { ref, quantity });
  }
  return Array.from(result.values());
}
export function validateTransfer(value, now = Date.now()) {
  if (!value || value.version !== 1 || !SUPPLIERS[value.supplier] ||
      typeof value.id !== 'string' || !/^[a-zA-Z0-9-]{16,80}$/.test(value.id)) throw new Error('Transfert non reconnu.');
  if (!Number.isFinite(value.createdAt) || !Number.isFinite(value.expiresAt) ||
      value.createdAt > now + 60000 || value.expiresAt <= now ||
      value.expiresAt - value.createdAt > TTL_MS || value.expiresAt <= value.createdAt) throw new Error('Transfert expiré. Préparez une nouvelle sélection.');
  return { version: 1, id: value.id, supplier: value.supplier, createdAt: value.createdAt,
    expiresAt: value.expiresAt, lines: normalizeLines(value.lines) };
}
export function createTransfer(supplier, items, now = Date.now(), id = crypto.randomUUID()) {
  const lines = items.map(item => {
    const offer = item.produits_fournisseurs;
    if (!offer || supplierId(offer.fournisseurs?.nom) !== supplier) throw new Error('Le panier contient un autre fournisseur.');
    return { ref: offer.ref_fournisseur, quantity: item.quantite };
  });
  return validateTransfer({ version: 1, id, supplier, createdAt: now, expiresAt: now + TTL_MS, lines }, now);
}
export function groupCart(items) {
  const groups = new Map();
  for (const item of items) {
    const offer = item.produits_fournisseurs;
    const name = offer?.fournisseurs?.nom || 'Offres indisponibles';
    const id = supplierId(name);
    const key = id || name;
    if (!groups.has(key)) groups.set(key, { key, id, name: id ? SUPPLIERS[id].name : name, items: [] });
    groups.get(key).items.push(item);
  }
  return Array.from(groups.values()).sort((a, b) => a.name.localeCompare(b.name, 'fr'));
}
export function quickOrderText(lines, delimiter = ',', header = '') {
  if (![',', ';', '\t'].includes(delimiter)) throw new Error('Séparateur non pris en charge.');
  if (typeof header !== 'string' || /[\r\n]/.test(header) || header.length > 160) throw new Error('En-tête invalide.');
  return (header ? header + '\r\n' : '') + normalizeLines(lines).map(l => l.ref + delimiter + l.quantity).join('\r\n');
}
export function reconcile(lines, before, after) {
  const normalized = normalizeLines(lines);
  const known = value => value && typeof value === 'object' && !Array.isArray(value) &&
    Object.values(value).every(n => Number.isInteger(n) && n >= 0 && n <= 1000000);
  if (!known(before) || !known(after)) return { state: 'unverified', lines: [] };
  const checked = normalized.map(l => {
    const expected = (Object.prototype.hasOwnProperty.call(before, l.ref) ? before[l.ref] : 0) + l.quantity;
    const actual = Object.prototype.hasOwnProperty.call(after, l.ref) ? after[l.ref] : 0;
    return { ...l, expected, actual, status: actual === expected ? 'verified' : actual < expected ? 'missing' : 'excess' };
  });
  return { state: checked.every(l => l.status === 'verified') ? 'verified' : 'partial', lines: checked };
}
export function fingerprint(transfer) {
  return transfer.supplier + ':' + JSON.stringify(normalizeLines(transfer.lines).sort((a, b) => a.ref.localeCompare(b.ref)));
}
