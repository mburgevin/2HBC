import React, { useCallback, useEffect, useState } from 'react';
import { useAuth } from './AuthContext';
import { cartCsv, formatPrice, listCart, removeCartItem, safeUrl, updateQuantity } from '../lib/data';
import { groupCart } from '../lib/supplierTransfer';
import SupplierTransfer from './SupplierTransfer';

function QuantityInput({ item, name, disabled, onSave, onDirty }) {
  const [draft, setDraft] = useState(String(item.quantite));
  const [error, setError] = useState('');
  useEffect(() => { setDraft(String(item.quantite)); setError(''); onDirty(item.id, false); }, [item.id, item.quantite, onDirty]);
  function submit(event) {
    event.preventDefault();
    const n = Number(draft);
    if (!/^[0-9]+$/.test(draft) || !Number.isInteger(n) || n < 1 || n > 9999) {
      setError('Saisissez un entier de 1 à 9999.'); return;
    }
    setError(''); if (n !== item.quantite) onSave(item.id, n);
  }
  return <form className="quantity-form" onSubmit={submit}>
    <label htmlFor={'quantity-' + item.id}>Quantité</label>
    <div className="quantity">
      <button type="button" className="secondary" aria-label={'Diminuer ' + name} disabled={disabled || item.quantite <= 1} onClick={() => onSave(item.id, item.quantite - 1)}>−</button>
      <input id={'quantity-' + item.id} aria-label={'Quantité de ' + name} inputMode="numeric" value={draft} maxLength={4} disabled={disabled} onChange={e => { setDraft(e.target.value); onDirty(item.id, e.target.value !== String(item.quantite)); }} />
      <button type="button" className="secondary" aria-label={'Augmenter ' + name} disabled={disabled || item.quantite >= 9999} onClick={() => onSave(item.id, item.quantite + 1)}>+</button>
    </div>
    {draft !== String(item.quantite) && <button className="text-button" disabled={disabled}>Enregistrer la quantité</button>}
    {error && <small className="error" role="alert">{error}</small>}
  </form>;
}
export default function Panier() {
  const { user, loading: authLoading } = useAuth();
  const userId = user?.id;
  const [items, setItems] = useState([]);
  const [references, setReferences] = useState({});
  const [dirtyQuantities, setDirtyQuantities] = useState({});
  const [owner, setOwner] = useState(null);
  const markDirty = useCallback((id, dirty) => setDirtyQuantities(prev => prev[id] === dirty ? prev : { ...prev, [id]: dirty }), []);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(null);
  const [reload, setReload] = useState(0);
  useEffect(() => { setReferences({}); setDirtyQuantities({}); }, [userId]);
  useEffect(() => {
    setError('');
    if (!userId) { setItems([]); setLoading(false); return; }
    let active = true; setLoading(true);
    listCart().then(data => { if (active) { setItems(data); setOwner(userId); } })
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
  const prepared = (owner === userId ? items : []).map(item => {
    const offer = item.produits_fournisseurs;
    return offer ? { ...item, produits_fournisseurs: { ...offer,
      ref_fournisseur: references[item.id] ?? offer.ref_fournisseur } } : item;
  });
  const valid = prepared.filter(i => i.produits_fournisseurs?.produits && i.produits_fournisseurs?.fournisseurs);
  const groups = groupCart(prepared);
  const total = valid.reduce((sum,i) => sum + Number(i.produits_fournisseurs.prix || 0) * i.quantite, 0);
  const incomplete = valid.some(i => i.produits_fournisseurs.prix == null) || valid.length !== items.length;
  function download(selection = valid, name = 'selection') {
    const url = URL.createObjectURL(new Blob([cartCsv(selection)], { type: 'text/csv;charset=utf-8;' }));
    const a = document.createElement('a'); a.href = url; a.download = 'panier-2hbc-' + name + '.csv'; a.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }
  if (authLoading) return <main className="page" role="status">Chargement…</main>;
  if (!user) return <main className="page empty"><h1>Votre panier</h1><p>Connectez-vous pour retrouver votre sélection.</p></main>;
  return <main className="page cart-page">
    <div className="section-heading"><h1>Votre panier par fournisseur</h1><button className="secondary" disabled={!valid.length || loading} onClick={() => download()}>Exporter toute la sélection</button></div>
    <p className="notice">Auto-panier · Prototype à tester avec l’extension 2HBC. Les références fournisseur doivent être vérifiées. Les références saisies ici servent à cet essai et ne modifient pas le catalogue.</p>
    <p><a href="/auto-panier.html" target="_blank" rel="noopener noreferrer">Installer l’extension et préparer le premier essai ↗</a></p>
    {loading && <p role="status">Chargement du panier…</p>}
    {error && <div className="error" role="alert">{error} <button className="secondary" onClick={() => setReload(x => x + 1)}>Recharger</button></div>}
    {!loading && !error && !items.length && <div className="empty"><h2>Votre panier est vide</h2><p>Choisissez un produit et son fournisseur dans le catalogue.</p></div>}
    <div className="supplier-columns">{groups.map(group => {
      const usable = group.items.filter(i => i.produits_fournisseurs?.produits && i.produits_fournisseurs?.fournisseurs);
      const subtotal = usable.reduce((sum,i) => sum + Number(i.produits_fournisseurs.prix || 0) * i.quantite, 0);
      return <section className="supplier-section" aria-label={'Panier ' + group.name} key={userId + ':' + group.key}>
        <header className="supplier-heading"><div><h2>{group.name}</h2><p>{group.items.length} article(s)</p></div><strong>{formatPrice(subtotal)} HT<small>Prix connus · indicatif</small></strong></header>
        {group.items.map(item => {
          const o = item.produits_fournisseurs;
          if (!o?.produits || !o?.fournisseurs) return <article className="cart-item" key={item.id}><p>Cette offre n’est plus disponible.</p><button disabled={busy != null || loading} onClick={() => mutate(item.id,0)}>Supprimer</button></article>;
          return <article className="cart-item" key={item.id}>
            <div className="cart-info"><h3>{o.produits.nom}</h3><p className="reference">Réf. fabricant : {o.produits.ref_fabricant}</p><p>{formatPrice(o.prix)} HT · {o.conditionnement || 'Conditionnement à confirmer'}</p>
              {o.nature_prix === 'demonstration' && <span className="badge">Prix de démonstration</span>}
              {safeUrl(o.url_produit) && <p><a href={safeUrl(o.url_produit)} target="_blank" rel="noopener noreferrer">Vérifier la fiche fournisseur ↗</a></p>}
              {group.id && <label className="supplier-reference">Référence {group.name} pour le transfert
                <input aria-label={'Référence ' + group.name + ' de ' + o.produits.nom} value={o.ref_fournisseur || ''} maxLength={80} placeholder="Référence fournisseur vérifiée" onChange={e => setReferences(prev => ({ ...prev, [item.id]: e.target.value }))} />
              </label>}
            </div>
            <div className="cart-actions"><QuantityInput item={item} name={o.produits.nom} disabled={busy != null || loading} onSave={mutate} onDirty={markDirty} /><strong>{formatPrice(o.prix == null ? null : o.prix * item.quantite)}</strong><button className="text-button" disabled={busy != null || loading} onClick={() => mutate(item.id,0)}>Supprimer</button></div>
          </article>;
        })}
        {group.items.some(i => dirtyQuantities[i.id]) && <p className="notice">Enregistrez les quantités modifiées avant de préparer le transfert.</p>}
        <SupplierTransfer group={group} disabled={loading || busy != null || Boolean(error) || usable.length !== group.items.length || group.items.some(i => dirtyQuantities[i.id])} />
        <button className="text-button" disabled={!usable.length || loading} onClick={() => download(usable, group.id || 'fournisseur')}>Exporter la sélection {group.name} (CSV générique)</button>
      </section>;
    })}</div>
    {!!items.length && <aside className="cart-total"><span>{incomplete ? 'Sous-total des prix connus HT' : 'Total indicatif HT'}</span><strong>{formatPrice(total)}</strong><small>Hors livraison · {incomplete ? 'Certaines offres sont sans prix.' : 'À confirmer auprès des fournisseurs.'}</small></aside>}
  </main>;
}
