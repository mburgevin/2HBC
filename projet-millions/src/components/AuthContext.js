import React, { createContext, useContext, useEffect, useState } from 'react';
import { getSupabase, supabase, isAdmin } from '../lib/supabase';
import { ensureProfile } from '../lib/data';
const AuthContext = createContext(null);
const displayUser = user => user ? { ...user, nom: user.user_metadata?.nom || user.email, role: isAdmin(user) ? 'admin' : 'artisan' } : null;

function authMessage(error, action = 'auth') {
  if (!error) return 'Une erreur est survenue. Réessayez.';
  if (error.code === 'email_address_not_authorized') return "Cette adresse ne peut pas recevoir l’email de confirmation avec la configuration actuelle. Utilisez une adresse autorisée ou configurez un SMTP personnalisé.";
  if (error.code === 'email_address_invalid') return "Cette adresse email n’est pas acceptée par le service d’authentification. Utilisez une adresse email réelle et valide.";
  if (error.code === 'over_email_send_rate_limit') return "Trop d’emails ont été envoyés récemment. Attendez quelques minutes avant de réessayer.";
  if (action === 'login') return 'Connexion impossible. Vérifiez vos identifiants et la confirmation de votre email.';
  return 'Inscription impossible. Vérifiez les champs ou réessayez plus tard.';
}

export function AuthProvider({ children }) {
  const [user, setUser] = useState(null);
  const [loading, setLoading] = useState(true);
  const [authError, setAuthError] = useState('');
  const [recovery, setRecovery] = useState(false);
  useEffect(() => {
    localStorage.removeItem('token');
    if (!supabase) { setLoading(false); return; }
    let active = true;
    let generation = 0;
    const sync = async () => {
      const current = ++generation;
      try {
        const { data, error } = await supabase.auth.getUser();
        if (error && error.name !== 'AuthSessionMissingError') throw error;
        if (data?.user) await ensureProfile(data.user);
        if (active && current === generation) { setUser(displayUser(data?.user)); setAuthError(''); }
      } catch {
        if (active && current === generation) { setUser(null); setAuthError('Impossible de vérifier votre session. Rechargez la page.'); }
      } finally { if (active && current === generation) setLoading(false); }
    };
    const { data: { subscription } } = supabase.auth.onAuthStateChange(event => {
      if (event === 'SIGNED_OUT') { generation++; setUser(null); setRecovery(false); setLoading(false); return; }
      if (event === 'PASSWORD_RECOVERY') setRecovery(true);
      setTimeout(() => { if (active) sync(); }, 0);
    });
    sync();
    return () => { active = false; generation++; subscription.unsubscribe(); };
  }, []);
  async function login(email, password) {
    const { data, error } = await getSupabase().auth.signInWithPassword({ email: email.trim().toLowerCase(), password });
    if (error) throw new Error(authMessage(error, 'login'));
    await ensureProfile(data.user); setUser(displayUser(data.user)); setAuthError('');
  }
  async function register(nom, email, password) {
    const { data, error } = await getSupabase().auth.signUp({ email: email.trim().toLowerCase(), password, options: { data: { nom: nom.trim() }, emailRedirectTo: window.location.origin } });
    if (error) throw new Error(authMessage(error, 'register'));
    if (data.session) { await ensureProfile(data.user); setUser(displayUser(data.user)); }
    return { needsConfirmation: !data.session };
  }
  async function logout() {
    const { error } = await getSupabase().auth.signOut();
    if (error) { setAuthError('La déconnexion a échoué. Réessayez.'); return; }
    setUser(null);
  }
  return <AuthContext.Provider value={{ user, loading, login, register, logout, authError, recovery, finishRecovery: () => setRecovery(false) }}>{children}</AuthContext.Provider>;
}
export const useAuth = () => useContext(AuthContext);
