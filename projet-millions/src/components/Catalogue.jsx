import React, { useEffect, useRef, useState } from 'react';
import { useAuth } from './AuthContext';
import { addToCart, formatPrice, searchCatalogue, PAGE_SIZE } from '../lib/data';
import PersonalPrice from './PersonalPrice';
import ProductImage from './ProductImage';
import CatalogueFilters from './CatalogueFilters';
const priceLabels = { demonstration: 'Tarif de démonstration', public: 'Tarif public', negocie: 'Tarif négocié' };
export default function Catalogue({ initialTerm = '', onLoginClick }) {
  const { user, loading: authLoading } = useAuth();
  const [term, setTerm] = useState(initialTerm);
  const [draft, setDraft] = useState(initialTerm);
  const [page, setPage] = useState(0);
  const [products, setProducts] = useState([]);
  const [filters, setFilters] = useState({});
  const [result, setResult] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [retry, setRetry] = useState(0);
  const [selected, setSelected] = useState(null);
  useEffect(() => { setTerm(initialTerm); setDraft(initialTerm); setPage(0); setFilters({}); }, [initialTerm]);
  useEffect(() => {
    if (authLoading) return;
    let active = true;
    setLoading(true); setError(''); setProducts([]); setSelected(null);
    searchCatalogue(term, filters, page).then(data => { if (active) { setProducts(data.items); setResult(data); } })
      .catch(() => { if (active) setError('Impossible de charger le catalogue. Réessayez dans un instant.'); })
      .finally(() => { if (active) setLoading(false); });
    return () => { active = false; };
  }, [term, filters, page, user?.id, authLoading, retry]);
  return <main className="page">
    <div className="section-heading"><div><p className="eyebrow">Votre matériel, au même endroit</p><h1>Catalogue produits vérifiés</h1></div></div>
    <p className="notice">Catalogue pilote : références réelles vérifiées. Les prix personnels sont lus à votre demande avec l’extension et enregistrés uniquement dans votre espace. Un changement de compte, d’affaire ou de quantité impose une nouvelle lecture.</p>
    <form className="search-form" onSubmit={e => { e.preventDefault(); setPage(0); setTerm(draft); }}>
      <label className="sr-only" htmlFor="catalog-search">Rechercher par nom, marque, EAN ou référence fournisseur</label>
      <input id="catalog-search" placeholder="Produit, marque, EAN, code Rexel ou Sonepar…" value={draft} maxLength={100} onChange={e => setDraft(e.target.value)} />
      <button>Rechercher</button>
    </form>
    <div className={result && !result.legacy ? 'catalogue-layout' : ''}>
    {result && !result.legacy && <CatalogueFilters facets={result.facets} categories={result.categories} filters={filters} disabled={loading} onChange={next => { setFilters(next); setPage(0); }} />}
    <section className="catalogue-results" aria-label="Résultats de recherche" aria-busy={loading}>
    {!loading && !error && result?.total != null && <p role="status" className="result-count">{result.total} produit{result.total !== 1 ? 's' : ''} trouvé{result.total !== 1 ? 's' : ''}</p>}
    {loading && <p role="status">Chargement du catalogue…</p>}
    {error && <div className="error" role="alert">{error} <button className="secondary" onClick={() => setRetry(x => x + 1)}>Réessayer</button></div>}
    {!loading && !error && products.length === 0 && <div className="empty"><h2>Aucun produit trouvé</h2><p>{term || Object.keys(filters).length ? 'Modifiez votre recherche ou effacez les filtres.' : 'Le catalogue est en cours de préparation. Les produits vérifiés apparaîtront ici.'}</p></div>}
    <div className="product-grid">{products.map(product => {
      const offers = product.offres || [];
      const prices = offers.filter(o => o.prix != null);
      const best = prices.reduce((a, o) => !a || o.prix < a.prix ? o : a, null);
      return <article className="product-card" key={product.id}>
        <ProductImage product={product} />
        <p className="reference">Réf. {product.ref_fabricant}</p><h2>{product.nom}</h2>
        <p className="muted">{[product.marque, product.gamme, product.categorie].filter(Boolean).join(' · ')}</p>
        {product.attributs?.length > 0 && <dl className="product-specs compact">{product.attributs.slice(0, 3).map(a => <React.Fragment key={a.code}><dt>{a.nom}</dt><dd>{attributeValue(a)}</dd></React.Fragment>)}</dl>}
        {user ? <div className="price-box"><strong>{formatPrice(best?.prix)}</strong>{best && <small>HT · {best.fournisseur} · {priceLabels[best.nature_prix]}<br />Conditionnement : {best.conditionnement || 'à confirmer'}</small>}</div> : <p className="muted">Connectez-vous pour consulter les tarifs.</p>}
        <button className="secondary" onClick={() => setSelected(product)}>{user ? 'Comparer et ajouter' : 'Voir le produit'}</button>
      </article>;
    })}</div>
    {!loading && !error && <div className="pagination"><button className="secondary" disabled={page === 0} onClick={() => setPage(p => p - 1)}>Précédent</button><span>Page {page + 1}{result?.total != null ? ` / ${Math.max(1, Math.ceil(result.total / PAGE_SIZE))}` : ''}</span><button className="secondary" disabled={result?.total != null ? (page + 1) * PAGE_SIZE >= result.total : products.length < PAGE_SIZE} onClick={() => setPage(p => p + 1)}>Suivant</button></div>}
    </section></div>
    {selected && <ProductDialog key={(user?.id || 'visitor') + ":" + selected.id} userId={user?.id} product={selected} onClose={() => setSelected(null)} onLoginClick={onLoginClick} />}
  </main>;
}
function attributeValue(attribute) {
  const value = typeof attribute.valeur === 'boolean' ? (attribute.valeur ? 'Oui' : 'Non') : attribute.valeur;
  return `${value}${attribute.unite ? ` ${attribute.unite}` : ''}`;
}
function ProductDialog({ product, userId, onClose, onLoginClick }) {
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
    <ProductImage product={product} />
    <p className="muted">{product.marque}{product.gamme ? ` · ${product.gamme}` : ''}{product.code_ean ? ` · EAN ${product.code_ean}` : ''}</p>
    {product.description && <p>{product.description}</p>}
    {product.attributs?.length > 0 && <><h3>Caractéristiques techniques</h3><dl className="product-specs">{product.attributs.map(a => <React.Fragment key={a.code}><dt>{a.nom}</dt><dd>{attributeValue(a)}</dd></React.Fragment>)}</dl></>}
    {!userId ? <button onClick={() => { onClose(); onLoginClick(); }}>Se connecter pour comparer les offres</button> : <>
    <fieldset className="offer-list"><legend>Choisir une offre fournisseur</legend>
      {(product.offres || []).map(o => <label className="offer" key={o.id}>
        <input type="radio" name="offer" value={o.id} checked={chosen === String(o.id)} onChange={e => setChosen(e.target.value)} />
        <span><strong>{o.fournisseur}</strong><small>{priceLabels[o.nature_prix]} · {o.conditionnement || 'Conditionnement à confirmer'}</small><small>{o.date_verification ? `Vérifié le ${new Date(o.date_verification).toLocaleDateString('fr-FR')}` : 'Tarif non vérifié'}</small></span>
        <strong>{formatPrice(o.prix)}</strong>
      </label>)}
      {!product.offres?.length && <p>Aucune offre disponible pour le moment.</p>}
    </fieldset>
    {(product.offres || []).map(o => <section key={o.id} aria-label={'Prix personnel ' + o.fournisseur}>
      <h3>{o.fournisseur}</h3><p className="reference">Référence fournisseur : {o.ref_fournisseur}</p>
      <PersonalPrice key={userId + ':' + o.id} userId={userId} offer={o}/>
    </section>)}
    <p className="muted">La lecture initiale porte sur une quantité de 1. Conditionnements, remises de quantité, écocontributions et livraison se vérifient chez le fournisseur. Ces observations ne constituent pas un devis garanti.</p>
    <p className="muted">Prix HT hors livraison. Les conditions et disponibilités sont à confirmer auprès du fournisseur.</p>
    {message && <p role="status" className="notice">{message}</p>}{error && <p role="alert" className="error">{error}</p>}
    <button disabled={!chosen || busy} onClick={add}>{busy ? 'Ajout en cours…' : 'Ajouter au panier'}</button>
    </>}
  </dialog>;
}
