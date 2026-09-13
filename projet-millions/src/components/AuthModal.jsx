import React, { useEffect, useRef, useState } from 'react';
import { useAuth } from './AuthContext';
import { getSupabase } from '../lib/supabase';
export default function AuthModal({ onClose }) {
  const { login, register, recovery, finishRecovery } = useAuth();
  const [mode, setMode] = useState(recovery ? 'password' : 'login');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [message, setMessage] = useState('');
  const dialog = useRef(null);
  useEffect(() => { dialog.current.showModal(); }, []);
  const titles = { login: 'Se connecter', register: 'Créer un compte', reset: 'Mot de passe oublié', password: 'Nouveau mot de passe' };
  async function submit(e) {
    e.preventDefault(); setBusy(true); setError(''); setMessage('');
    const fields = new FormData(e.currentTarget);
    try {
      if (mode === 'register') {
        const result = await register(fields.get('nom'), fields.get('email'), fields.get('password'));
        if (result.needsConfirmation) setMessage('Consultez votre boîte mail pour confirmer votre inscription avant de vous connecter.');
        else onClose();
      } else if (mode === 'reset') {
        const { error } = await getSupabase().auth.resetPasswordForEmail(fields.get('email').trim(), { redirectTo: window.location.origin });
        if (error) throw error;
        setMessage('Si ce compte existe, un email de réinitialisation vous sera envoyé.');
      } else if (mode === 'password') {
        const { error } = await getSupabase().auth.updateUser({ password: fields.get('password') });
        if (error) throw error;
        finishRecovery(); onClose();
      } else { await login(fields.get('email'), fields.get('password')); onClose(); }
    } catch (err) { setError(err.message || 'Une erreur est survenue. Réessayez.'); }
    finally { setBusy(false); }
  }
  return <dialog ref={dialog} className="modal" aria-labelledby="auth-title" onCancel={onClose}>
    <button className="close" type="button" aria-label="Fermer" onClick={onClose}>×</button>
    <h2 id="auth-title">{titles[mode]}</h2>
    <form onSubmit={submit} className="stack">
      {mode === 'register' && <label>Votre nom<input name="nom" autoComplete="name" required maxLength={120} /></label>}
      {mode !== 'password' && <label>Email<input name="email" type="email" autoComplete="email" required /></label>}
      {mode !== 'reset' && <label>Mot de passe<input name="password" type="password" autoComplete={mode === 'login' ? 'current-password' : 'new-password'} required minLength={mode === 'login' ? 1 : 10} maxLength={128} /></label>}
      {(mode === 'register' || mode === 'password') && <small>Au moins 10 caractères.</small>}
      {error && <p className="error" role="alert">{error}</p>}
      {message && <p className="notice" role="status">{message}</p>}
      <button disabled={busy}>{busy ? 'Veuillez patienter…' : titles[mode]}</button>
    </form>
    {mode !== 'password' && <div className="stack modal-links">
      <button className="secondary" onClick={() => { setMode(mode === 'register' ? 'login' : 'register'); setError(''); setMessage(''); }}>{mode === 'register' ? 'Déjà un compte ? Se connecter' : 'Créer un compte'}</button>
      <button className="text-button" onClick={() => { setMode(mode === 'reset' ? 'login' : 'reset'); setError(''); setMessage(''); }}>{mode === 'reset' ? 'Retour à la connexion' : 'Mot de passe oublié ?'}</button>
    </div>}
  </dialog>;
}
