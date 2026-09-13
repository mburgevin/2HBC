import { getSupabase } from './supabase';
export const PAGE_SIZE = 24;
function checked({ data, error }) { if (error) throw error; return data; }
export async function listProducts(term = '', page = 0) {
  return checked(await getSupabase().rpc('rechercher_catalogue', { terme: term.trim().slice(0, 100), page_num: page }));
}
export async function ensureProfile(user) {
  const client = getSupabase();
  const existing = checked(await client.from('clients').select('id').eq('id', user.id).maybeSingle());
  if (!existing) checked(await client.from('clients').upsert({ id: user.id, nom_complet: user.user_metadata?.nom || '' }, { onConflict: 'id', ignoreDuplicates: true }));
}
export async function addToCart(offerId) {
  checked(await getSupabase().rpc('ajouter_au_panier', { offre_id: offerId, qte: 1 }));
}
export async function listCart() {
  return checked(await getSupabase().from('articles_panier').select(`
    id, quantite, produits_fournisseurs (
      id, ref_fournisseur, prix, nature_prix, conditionnement, url_produit,
      fournisseurs (nom), produits (nom, ref_fabricant, image_url)
    )
  `).order('id'));
}
export async function updateQuantity(id, quantite) {
  const data = checked(await getSupabase().from('articles_panier').update({ quantite }).eq('id', id).select('id'));
  if (!data.length) throw new Error('Cet article ne peut plus être modifié. Rechargez le panier.');
}
export async function removeCartItem(id) {
  const data = checked(await getSupabase().from('articles_panier').delete().eq('id', id).select('id'));
  if (!data.length) throw new Error('Cet article ne peut plus être supprimé. Rechargez le panier.');
}
export async function listOffers() {
  return checked(await getSupabase().from('produits_fournisseurs').select('id, prix, nature_prix, date_verification, produits(nom,ref_fabricant), fournisseurs(nom)').order('id'));
}
export async function saveOffer(id, prix, nature_prix) {
  const data = checked(await getSupabase().from('produits_fournisseurs').update({ prix, nature_prix, date_verification: new Date().toISOString() }).eq('id', id).select('id'));
  if (!data.length) throw new Error('Modification refusée. Vérifiez vos droits administrateur.');
}
export function formatPrice(value) {
  return value == null ? 'Prix à confirmer' : new Intl.NumberFormat('fr-FR', { style: 'currency', currency: 'EUR' }).format(value);
}
export function safeUrl(value) {
  try { const url = new URL(value); return url.protocol === 'https:' ? url.href : null; } catch { return null; }
}
export function csvCell(value) {
  let text = String(value ?? '');
  if (/^[\s]*[=+\-@]/.test(text)) text = "'" + text;
  return '"' + text.replace(/"/g, '""') + '"';
}
export function cartCsv(items) {
  const rows = [['Fournisseur', 'Référence fournisseur', 'Référence fabricant', 'Désignation', 'Quantité', 'Prix unitaire HT', 'Type de prix']];
  for (const item of items) {
    const o = item.produits_fournisseurs;
    rows.push([o.fournisseurs.nom, o.ref_fournisseur, o.produits.ref_fabricant, o.produits.nom, item.quantite, o.prix, o.nature_prix]);
  }
  return '\uFEFF' + rows.map(row => row.map(csvCell).join(';')).join('\r\n');
}
