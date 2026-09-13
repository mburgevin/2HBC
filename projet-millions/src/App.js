import React, { useState } from 'react';
import { AuthProvider, useAuth } from './components/AuthContext';
import AuthModal from './components/AuthModal';
import Catalogue from './components/Catalogue';
import Panier from './components/Panier';
import Dashboard from './components/Dashboard';
import Admin from './components/Admin';
import { isConfigured } from './lib/supabase';
import './App.css';
function AppInner() {
  const { user, logout, authError, recovery, finishRecovery } = useAuth();
  const [tab, setTab] = useState('accueil');
  const [showAuth, setShowAuth] = useState(false);
  const [search, setSearch] = useState('');
  const [draft, setDraft] = useState('');
  function goCatalogue(term = '') { setSearch(term); setTab('catalogue'); }
  const tabs = [['accueil','Accueil'], ['catalogue','Catalogue'], ['panier','Mon panier'], ['dashboard','Mes économies'], ...(user?.role === 'admin' ? [['admin','Administration']] : [])];
  return <div className="app">
    <a className="skip-link" href="#main-content">Aller au contenu</a>
    <header className="site-header"><button className="brand" onClick={() => setTab('accueil')} aria-label="2HBC, accueil">2HBC<span>Le matériel, ensemble.</span></button>
      <form className="header-search" onSubmit={e => { e.preventDefault(); goCatalogue(draft); }}><label className="sr-only" htmlFor="global-search">Rechercher un produit</label><input id="global-search" value={draft} maxLength={100} onChange={e => setDraft(e.target.value)} placeholder="Produit, référence…" /><button aria-label="Lancer la recherche">Rechercher</button></form>
      <div className="account">{user ? <><span>Bonjour, {user.nom}</span><button className="secondary" onClick={logout}>Déconnexion</button></> : <button disabled={!isConfigured} onClick={() => setShowAuth(true)}>Se connecter</button>}</div>
    </header>
    <nav className="site-nav" aria-label="Navigation principale">{tabs.map(([id,label]) => <button key={id} aria-current={tab === id ? 'page' : undefined} onClick={() => { setTab(id); if (id === 'catalogue') setSearch(''); }}>{label}</button>)}</nav>
    <div className="pilot-banner">Version pilote · Les tarifs de démonstration ne constituent pas une offre commerciale.</div>
    {!isConfigured && <p className="notice config-notice" role="status">Le service est en cours de préparation. Le catalogue et les comptes seront disponibles prochainement.</p>}
    {authError && <p className="error" role="alert">{authError}</p>}
    {(showAuth || recovery) && <AuthModal key={recovery ? 'recovery' : 'auth'} onClose={() => { setShowAuth(false); if (recovery) finishRecovery(); }} />}
    <div id="main-content" className="main-content">
      {tab === 'catalogue' && <Catalogue initialTerm={search} onLoginClick={() => setShowAuth(true)} />}
      {tab === 'panier' && <Panier />}
      {tab === 'dashboard' && <Dashboard />}
      {tab === 'admin' && <Admin />}
      {tab === 'accueil' && <main className="page home"><section className="hero"><p className="eyebrow">Pour les artisans électriciens</p><h1>Préparez vos achats.<br /><span>Comparez simplement.</span></h1><p className="hero-copy">Retrouvez vos références, comparez les offres disponibles et préparez votre sélection par fournisseur, dans un seul espace.</p><div className="hero-actions"><button onClick={() => goCatalogue()}>Explorer le catalogue</button><a className="button secondary" href="mailto:2hbc.contact@gmail.com">Participer au pilote</a></div></section><section className="steps" aria-label="Comment ça marche"><article><span>01</span><h2>Retrouvez le bon produit</h2><p>Recherchez une référence ou parcourez le catalogue.</p></article><article><span>02</span><h2>Comparez les offres</h2><p>Consultez les tarifs, leur origine et leur conditionnement.</p></article><article><span>03</span><h2>Préparez votre panier</h2><p>Exportez votre sélection, puis finalisez vos achats auprès des fournisseurs.</p></article></section><section className="pilot-card"><h2>Construisons cette première version ensemble</h2><p>Votre retour sur vos habitudes d’achat et les références qui vous manquent nous aide à construire un service utile.</p><a href="mailto:2hbc.contact@gmail.com">Échanger avec l’équipe →</a></section></main>}
    </div><footer className="site-footer"><strong>2HBC</strong><span>© {new Date().getFullYear()} · Version pilote</span><a href="mailto:2hbc.contact@gmail.com">2hbc.contact@gmail.com</a></footer>
  </div>;
}
export default function App() { return <AuthProvider><AppInner /></AuthProvider>; }
