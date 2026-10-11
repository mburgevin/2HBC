import React, { useEffect, useRef, useState } from 'react';
import { extensionRequest } from '../lib/autoCart';
import { formatPrice, savePersonalPrice } from '../lib/data';
import { supplierId } from '../lib/supplierTransfer';
import { productPage, validatePrice } from '../lib/supplierPrice';

// Mounted separately for each user/offer/quantity. Observations are never reused
// as current account prices after a remount or account switch.
export default function PersonalPrice({ offer, userId, quantity = 1 }) {
  const [job, setJob] = useState(null);
  const [quote, setQuote] = useState(null);
  const [message, setMessage] = useState('');
  const [busy, setBusy] = useState(false);
  const [now, setNow] = useState(Date.now());
  const active = useRef(true);
  const supplier = supplierId(offer.fournisseur);
  const ready = offer.reference_verifiee && productPage(supplier, offer.url_produit);
  useEffect(() => {
    active.current = true;
    const timer = setInterval(() => setNow(Date.now()), 5000);
    return () => { active.current = false; clearInterval(timer); };
  }, []);
  useEffect(() => {
    if (!job) return undefined;
    let running = false, cancelled = false;
    const poll = async () => {
      if (running || cancelled) return;
      running = true;
      try {
        const result = await extensionRequest('PRICE_STATUS',job);
        if (cancelled) return;
        if (result.state === 'observed') {
          const checked = validatePrice(result.quote,job);
          setQuote(checked); setJob(null); setBusy(false);
          setMessage('Prix observé dans votre compte. Vérifiez les frais et le total chez le fournisseur.');
          try { await savePersonalPrice(checked,job); }
          catch { if (active.current) setMessage('Prix lu, mais son enregistrement privé a échoué.'); }
        } else if (result.state === 'reading' && result.error) {
          setMessage(result.error + ' Vérifiez la fiche fournisseur et les réglages de l’extension.');
        } else if (result.state !== 'reading') {
          throw new Error(result.error || 'Lecture arrêtée.');
        }
      } catch (e) {
        if (!cancelled) { setMessage(e.message); setJob(null); setBusy(false); }
      } finally { running = false; }
    };
    const timer = setInterval(poll, 1500);
    return () => { cancelled = true; clearInterval(timer); };
  }, [job]);
  async function read() {
    setBusy(true); setMessage(''); setQuote(null);
    const request = {id:crypto.randomUUID(),sessionId:crypto.randomUUID(),userId,offerId:offer.id,
      supplier,url:offer.url_produit,ref:offer.ref_fournisseur,quantity};
    try {
      await extensionRequest('PRICE_START',request,12000);
      if (active.current) { setJob(request); setMessage('Dans l’onglet fournisseur, connectez-vous et vérifiez le compte, l’affaire et la quantité ' + quantity + '. La lecture attend un prix net HT identifiable.'); }
    } catch (e) { if (active.current) {setMessage(e.message);setBusy(false);} }
  }
  async function cancel() {
    const request = job; setJob(null); setBusy(false); setMessage('Lecture arrêtée.');
    if (request) try {await extensionRequest('PRICE_CANCEL',request);} catch { /* expires after two minutes */ }
  }
  const fresh = quote && quote.expiresAt > now;
  return <div className="personal-price">
    {fresh && <p><strong>{formatPrice(quote.amount / quote.basis)} HT / {quote.unit === 'piece' ? 'pièce' : quote.unit}</strong><br/>
      <small>Prix personnel observé à {new Date(quote.observedAt).toLocaleTimeString('fr-FR')} pour {quote.quantity} {quote.unit}. Base affichée : {formatPrice(quote.amount)} pour {quote.basis} {quote.unit}.</small></p>}
    {quote && !fresh && <p className="notice">Cette observation a expiré. Actualisez votre prix.</p>}
    <button type="button" className="secondary" disabled={!ready || busy} onClick={read}>{busy ? 'Lecture en cours…' : 'Lire mon prix ' + offer.fournisseur}</button>
    {job && <button type="button" className="text-button" onClick={cancel}>Arrêter la lecture</button>}
    {message && <p role="status" className="muted">{message}</p>}
    {!ready && <small>Correspondance fournisseur à vérifier.</small>}
  </div>;
}
