import React, { useEffect, useRef, useState } from 'react';
import { useAuth } from './AuthContext';
import { addToCart, formatPrice, listProducts, PAGE_SIZE, safeUrl } from '../lib/data';
const priceLabels = { demonstration: 'Tarif de démonstration', public: 'Tarif public', negocie: 'Tarif négocié' };
export default function Catalogue({ initialTerm = '', onLoginClick }) {
  const { user, loading: authLoading } = useAuth();
  const [term, setTerm] = useState(initialTerm);
  const [draft, setDraft] = useState(initialTerm);
  const [page, setPage] = useState(0);
  const [products, setProducts] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [retry, setRetry] = useState(0);
  const [selected, setSelected] = useState(null);
  useEffect(() => { setTerm(initialTerm); setDraft(initialTerm); setPage(0); }, [initialTerm]);
  useEffect(() => {
    if (authLoading) return;
    let active = true;
    setLoading(true); setError(''); setProducts([]); setSelected(null);
    listProducts(term, page).then(data => { if (active) setProducts(data); })
      .catch(() => { if (active) setError('Impossible de charger le catalogue. Réessayez dans un instant.'); })
      .finally(() => { if (active) setLoading(false); });
    return () => { active = false; };
  }, [term, page, user?.id, authLoading, retry]);
  return <main className="page">
    <div className="section-heading"><div><p className="eyebrow">Votre matériel, au même endroit</p><h1>Catalogue produits</h1></div></div>
    <form className="search-form" onSubmit={e => { e.preventDefault(); setPage(0); setTerm(draft); }}>
      <label className="sr-only" htmlFor="catalog-search">Rechercher par nom ou référence</label>
      <input id="catalog-search" placeholder="Nom du produit, marque ou référence…" value={draft} maxLength={100} onChange={e => setDraft(e.target.value)} />
      <button>Rechercher</button>
    </form>
    {loading && <p role="status">Chargement du catalogue…</p>}
    {error && <div className="error" role="alert">{error} <button className="secondary" onClick={() => setRetry(x => x + 1)}>Réessayer</button></div>}
    {!loading && !error && products.length === 0 && <div className="empty"><h2>Aucun produit trouvé</h2><p>Essayez une autre référence ou un terme plus court.</p></div>}
    <div className="product-grid">{products.map(product => {
      const offers = product.offres || [];
      const prices = offers.filter(o => o.prix != null);
      const best = prices.reduce((a, o) => !a || o.prix < a.prix ? o : a, null);
      return <article className="product-card" key={product.id}>
        <div className="product-image">{safeUrl(product.image_url) ? <img src={safeUrl(product.image_url)} alt="" loading="lazy" onError={e => { e.currentTarget.hidden = true; }} /> : <span>2HBC</span>}</div>
        <p className="reference">Réf. {product.ref_fabricant}</p><h2>{product.nom}</h2>
        {user ? <div className="price-box"><strong>{formatPrice(best?.prix)}</strong>{best && <small>HT · {best.fournisseur} · {priceLabels[best.nature_prix]}<br />Conditionnement : {best.conditionnement || 'à confirmer'}</small>}</div> : <p className="muted">Connectez-vous pour consulter les tarifs.</p>}
        <button className="secondary" onClick={() => user ? setSelected(product) : onLoginClick()}>{user ? 'Comparer et ajouter' : 'Voir les prix'}</button>
      </article>;
    })}</div>
    {!loading && !error && <div className="pagination"><button className="secondary" disabled={page === 0} onClick={() => setPage(p => p - 1)}>Précédent</button><span>Page {page + 1}</span><button className="secondary" disabled={products.length < PAGE_SIZE} onClick={() => setPage(p => p + 1)}>Suivant</button></div>}
    {selected && user && <ProductDialog key={selected.id} product={selected} onClose={() => setSelected(null)} />}
  </main>;
}
function ProductDialog({ product, onClose }) {
  const dialog = useRef(null);
  const [chosen, setChosen] = useState('');
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState('');
  const [error, setError] = useState('');
  useEffect(() => { dialog.current.showModal(); }, []);
  async function add() {
    setBusy(true); setMessage(''); setError('');
    try { await addToCart(Number(chosen)); setMessage('Produit ajouté au panier.'); }
    catch { setError('Ajout impossible. Vérifiez votre connexion puis réessayez.'); }
    finally { setBusy(false); }
  }
  return <dialog ref={dialog} className="modal" onCancel={onClose} aria-labelledby="product-title">
    <button className="close" aria-label="Fermer" onClick={onClose}>×</button>
    <h2 id="product-title">{product.nom}</h2><p className="reference">Réf. {product.ref_fabricant}</p>
    <fieldset className="offer-list"><legend>Choisir une offre fournisseur</legend>
      {(product.offres || []).map(o => <label className="offer" key={o.id}>
        <input type="radio" name="offer" value={o.id} checked={chosen === String(o.id)} onChange={e => setChosen(e.target.value)} />
        <span><strong>{o.fournisseur}</strong><small>{priceLabels[o.nature_prix]} · {o.conditionnement || 'Conditionnement à confirmer'}</small><small>{o.date_verification ? `Vérifié le ${new Date(o.date_verification).toLocaleDateString('fr-FR')}` : 'Tarif non vérifié'}</small></span>
        <strong>{formatPrice(o.prix)}</strong>
      </label>)}
      {!product.offres?.length && <p>Aucune offre disponible pour le moment.</p>}
    </fieldset>
    <p className="muted">Prix HT hors livraison. Les conditions et disponibilités sont à confirmer auprès du fournisseur.</p>
    {message && <p role="status" className="notice">{message}</p>}{error && <p role="alert" className="error">{error}</p>}
    <button disabled={!chosen || busy} onClick={add}>{busy ? 'Ajout en cours…' : 'Ajouter au panier'}</button>
  </dialog>;
}
