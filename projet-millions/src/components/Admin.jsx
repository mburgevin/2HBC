import React, { useEffect, useState } from 'react';
import { useAuth } from './AuthContext';
import { listOffers, saveOffer } from '../lib/data';
export default function Admin() {
  const { user } = useAuth();
  const [offers, setOffers] = useState([]);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);
  useEffect(() => {
    if (user?.role !== 'admin') return;
    let active = true;
    listOffers().then(data => { if (active) setOffers(data); }).catch(() => { if (active) setError('Chargement des offres impossible.'); }).finally(() => { if (active) setLoading(false); });
    return () => { active = false; };
  }, [user?.id, user?.role]);
  if (user?.role !== 'admin') return <main className="page">Accès réservé aux administrateurs.</main>;
  return <main className="page"><h1>Gestion des tarifs</h1><p>Indiquez l’origine du tarif. Un prix récupéré sur un site public n’est pas automatiquement un prix négocié.</p>{loading && <p>Chargement…</p>}{error && <p role="alert" className="error">{error}</p>}<div className="stack">{offers.map(o => <OfferEditor key={o.id} offer={o} />)}</div></main>;
}
function OfferEditor({ offer }) {
  const [price, setPrice] = useState(offer.prix ?? '');
  const [type, setType] = useState(offer.nature_prix);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [saved, setSaved] = useState(false);
  async function submit(e) {
    e.preventDefault(); setBusy(true); setError(''); setSaved(false);
    try { await saveOffer(offer.id, price === '' ? null : Number(price), type); setSaved(true); }
    catch (e) { setError(e.message || 'Sauvegarde impossible.'); }
    finally { setBusy(false); }
  }
  return <form className="admin-offer" onSubmit={submit}><div><strong>{offer.produits.nom}</strong><p>{offer.fournisseurs.nom} · {offer.produits.ref_fabricant}</p></div><label>Prix HT<input type="number" min="0" max="9999999999" step="0.01" value={price} onChange={e => { setPrice(e.target.value); setSaved(false); }} /></label><label>Origine<select value={type} onChange={e => { setType(e.target.value); setSaved(false); }}><option value="demonstration">Démonstration</option><option value="public">Public</option><option value="negocie">Négocié</option></select></label><button disabled={busy}>{busy ? 'Enregistrement…' : 'Enregistrer'}</button>{saved && <p role="status">Tarif enregistré.</p>}{error && <p role="alert" className="error">{error}</p>}</form>;
}
