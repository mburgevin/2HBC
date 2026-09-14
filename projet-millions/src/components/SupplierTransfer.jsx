import React, { useEffect, useState } from 'react';
import { extensionRequest } from '../lib/autoCart';
import { createTransfer, quickOrderText } from '../lib/supplierTransfer';

const done = new Set(['verified','partial','indeterminate','interaction_required','cancelled','expired']);
export default function SupplierTransfer({ group, disabled }) {
  const [extension, setExtension] = useState(null);
  const [task, setTask] = useState(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [copied, setCopied] = useState(false);
  useEffect(() => {
    let active = true;
    extensionRequest('PING').then(info => { if (active) setExtension(info); })
      .catch(() => { if (active) setExtension(false); });
    return () => { active = false; };
  }, []);
  useEffect(() => {
    if (!task?.id || done.has(task.state)) return undefined;
    let active = true;
    const timer = setInterval(() => {
      extensionRequest('STATUS', { id: task.id }).then(next => { if (active) setTask(next); })
        .catch(e => { if (active) setError(e.message); });
    }, 2500);
    return () => { active = false; clearInterval(timer); };
  }, [task?.id, task?.state]);
  if (!group.id) return <p className="muted">Transfert automatique non disponible pour ce fournisseur.</p>;
  let invalid = '';
  try { createTransfer(group.id, group.items, Date.now(), 'validation-2hbc-00000001'); }
  catch (e) { invalid = e.message; }
  async function start() {
    setBusy(true); setError('');
    try {
      const info = await extensionRequest('PING');
      setExtension(info);
      const transfer = createTransfer(group.id, group.items);
      const next = await extensionRequest('START', transfer, 12000);
      setTask(next);
    } catch (e) { setError(e.message); }
    finally { setBusy(false); }
  }
  async function copy() {
    setError('');
    try {
      const transfer = createTransfer(group.id, group.items);
      await navigator.clipboard.writeText(quickOrderText(transfer.lines));
      setCopied(true);
    } catch (e) { setError(e.message || 'Copie impossible.'); }
  }
  async function stop() {
    try { setTask(await extensionRequest('CANCEL', { id: task.id })); }
    catch (e) { setError(e.message); }
  }
  return <div className="supplier-transfer">
    <p className="muted">Le fournisseur calculera ses prix. Vous gardez la validation finale de la commande.</p>
    {invalid && <p className="notice">{invalid} Renseignez les références fournisseur vérifiées pour cet essai.</p>}
    <div className="transfer-actions">
      <button disabled={disabled || busy || Boolean(invalid) || Boolean(task)} onClick={start}>
        {busy ? 'Préparation…' : 'Préparer mon panier ' + group.name}
      </button>
      <button className="secondary" disabled={disabled || Boolean(invalid) || Boolean(task?.attempted)} onClick={copy}>
        {copied ? 'Liste copiée' : 'Copier les références et quantités'}
      </button>
    </div>
    {extension === false && <p className="muted">Extension non détectée. <a href="/auto-panier.html" target="_blank" rel="noopener noreferrer">Installer l’extension de test</a>, puis revenez cliquer sur « Préparer mon panier ».</p>}
    {extension && !extension.suppliers?.[group.id] && <p className="notice">Le connecteur {group.name} doit être réglé sur ses pages connectées avant l’essai.</p>}
    {task && <div className={task.state === 'verified' ? 'notice' : 'transfer-status'} role="status">
      <strong>{task.message}</strong>{task.detail && <p>{task.detail}</p>}
      {['awaiting_setup','awaiting_confirmation'].includes(task.state) && <p>Connectez-vous chez {group.name}, puis ouvrez l’extension 2HBC pour confirmer le compte et lancer l’essai.</p>}
      {task.result?.lines?.length > 0 && <ul>{task.result.lines.map(l => <li key={l.ref}>{l.ref} : quantité attendue dans le panier {l.expected}, présente {l.actual}.</li>)}</ul>}
      {!done.has(task.state) && <button className="secondary" onClick={stop}>Arrêter l’assistance</button>}
      {done.has(task.state) && <p>Vérifiez le panier fournisseur avant tout autre transfert de ces références.</p>}
    </div>}
    {error && <p className="error" role="alert">{error}</p>}
    <details><summary>Solution de secours</summary><p>La liste copiée utilise « référence,quantité », sans en-tête. Vérifiez le format demandé par le fournisseur. Après un ajout incertain, contrôlez d’abord le panier pour éviter les doublons.</p></details>
  </div>;
}
