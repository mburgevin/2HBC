import React, { useCallback, useEffect, useState } from 'react';
import { useAuth } from './AuthContext';
import { cartCsv, formatPrice, listCart, removeCartItem, safeUrl, updateQuantity } from '../lib/data';
export default function Panier() {
  const { user, loading: authLoading } = useAuth();
  const userId = user?.id;
  const [items, setItems] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(null);
  const [reload, setReload] = useState(0);
  useEffect(() => {
    setItems([]); setError('');
    if (!userId) { setLoading(false); return; }
    let active = true; setLoading(true);
    listCart().then(data => { if (active) setItems(data); })
      .catch(() => { if (active) setError('Impossible de charger le panier.'); })
      .finally(() => { if (active) setLoading(false); });
    return () => { active = false; };
  }, [userId, reload]);
  const mutate = useCallback(async (id, quantity) => {
    setBusy(id); setError('');
    try {
      if (quantity === 0) await removeCartItem(id); else await updateQuantity(id, quantity);
      setReload(x => x + 1);
    } catch (e) { setError(e.message || 'Modification impossible. Réessayez.'); }
    finally { setBusy(null); }
  }, []);
  const valid = items.filter(i => i.produits_fournisseurs?.produits && i.produits_fournisseurs?.fournisseurs);
  const total = valid.reduce((sum, i) => sum + Number(i.produits_fournisseurs.prix || 0) * i.quantite, 0);
  const incomplete = valid.some(i => i.produits_fournisseurs.prix == null) || valid.length !== items.length;
  function download() {
    const url = URL.createObjectURL(new Blob([cartCsv(valid)], { type: 'text/csv;charset=utf-8;' }));
    const a = document.createElement('a'); a.href = url; a.download = 'panier-2hbc.csv'; a.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }
  if (authLoading) return <main className="page" role="status">Chargement…</main>;
  if (!user) return <main className="page empty"><h1>Votre panier</h1><p>Connectez-vous pour retrouver votre sélection.</p></main>;
  return <main className="page"><div className="section-heading"><h1>Votre panier</h1><button disabled={!valid.length || loading} onClick={download}>Exporter ma sélection CSV</button></div>
    <p className="notice">L’export prépare votre liste d’achat. Il ne transmet aucune commande et son format d’import reste à vérifier avec chaque fournisseur.</p>
    {loading && <p role="status">Chargement du panier…</p>}
    {error && <div className="error" role="alert">{error} <button className="secondary" onClick={() => setReload(x => x + 1)}>Recharger</button></div>}
    {!loading && !error && !items.length && <div className="empty"><h2>Votre panier est vide</h2><p>Choisissez un produit et son fournisseur dans le catalogue.</p></div>}
    {items.map(item => {
      const o = item.produits_fournisseurs;
      if (!o?.produits || !o?.fournisseurs) return <article className="cart-item" key={item.id}><p>Cette offre n’est plus disponible.</p><button disabled={busy != null} onClick={() => mutate(item.id, 0)}>Supprimer</button></article>;
      return <article className="cart-item" key={item.id}>
        <div className="cart-info"><p className="eyebrow">{o.fournisseurs.nom}</p><h2>{o.produits.nom}</h2><p className="reference">Réf. {o.produits.ref_fabricant}</p><p>{formatPrice(o.prix)} HT · {o.conditionnement || 'Conditionnement à confirmer'}</p>{o.nature_prix === 'demonstration' && <span className="badge">Démonstration</span>}{safeUrl(o.url_produit) && <p><a href={safeUrl(o.url_produit)} target="_blank" rel="noopener noreferrer">Voir la fiche fournisseur ↗</a></p>}</div>
        <div className="cart-actions"><div className="quantity"><button className="secondary" aria-label={`Diminuer ${o.produits.nom}`} disabled={busy != null || item.quantite <= 1} onClick={() => mutate(item.id, item.quantite - 1)}>−</button><span aria-label="Quantité">{item.quantite}</span><button className="secondary" aria-label={`Augmenter ${o.produits.nom}`} disabled={busy != null || item.quantite >= 9999} onClick={() => mutate(item.id, item.quantite + 1)}>+</button></div><strong>{formatPrice(o.prix == null ? null : o.prix * item.quantite)}</strong><button className="text-button" disabled={busy != null} onClick={() => mutate(item.id, 0)}>Supprimer</button></div>
      </article>;
    })}
    {!!items.length && <aside className="cart-total"><span>{incomplete ? 'Sous-total des prix connus HT' : 'Total indicatif HT'}</span><strong>{formatPrice(total)}</strong><small>Hors livraison · {incomplete ? 'Certaines offres sont sans prix.' : 'À confirmer auprès des fournisseurs.'}</small></aside>}
  </main>;
}
