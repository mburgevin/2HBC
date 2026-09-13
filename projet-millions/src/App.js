import React, { useState } from 'react';
import { AuthProvider, useAuth } from './components/AuthContext';
import AuthModal from './components/AuthModal';
import Catalogue from './components/Catalogue';
import Panier from './components/Panier';
import Dashboard from './components/Dashboard';
import Admin from './components/Admin';
import { isConfigured } from './lib/supabase';
import './App.css';

const baseTabs = [
  ['accueil', 'Accueil'],
  ['catalogue', 'Catalogue'],
  ['panier', 'Mon panier'],
  ['dashboard', 'Mes économies'],
];

const valueCards = [
  ['01', 'Catalogue centralisé', 'Retrouvez vos références et vos fournisseurs au même endroit.'],
  ['02', 'Prix comparés', 'Comparez les offres disponibles et identifiez rapidement la meilleure option.'],
  ['03', 'Gain de temps', 'Préparez vos achats en quelques clics et gardez une sélection claire.'],
  ['04', 'Pensé pour les pros', 'Un outil simple, direct et adapté au quotidien des artisans électriciens.'],
];

function Brand({ onClick }) {
  return <button className="brand" onClick={onClick} aria-label="2HBC, accueil">
    <span className="brand-mark"><b>2</b>HBC</span>
    <span className="brand-tagline">L'électricité pro, plus loin ensemble</span>
  </button>;
}

function AppInner() {
  const { user, logout, authError, recovery, finishRecovery } = useAuth();
  const [tab, setTab] = useState('accueil');
  const [showAuth, setShowAuth] = useState(false);
  const [search, setSearch] = useState('');
  const [draft, setDraft] = useState('');
  const tabs = [...baseTabs, ...(user?.role === 'admin' ? [['admin', 'Administration']] : [])];

  function goCatalogue(term = '') {
    setSearch(term);
    setTab('catalogue');
  }

  function changeTab(id) {
    setTab(id);
    if (id === 'catalogue') setSearch('');
  }

  return <div className="app">
    <a className="skip-link" href="#main-content">Aller au contenu</a>

    <div className="pilot-banner">
      <span>Version pilote 2HBC</span>
      <span>Les tarifs de démonstration ne constituent pas une offre commerciale.</span>
    </div>

    <header className="site-header">
      <div className="header-main">
        <Brand onClick={() => setTab('accueil')} />
        <form className="header-search" onSubmit={e => { e.preventDefault(); goCatalogue(draft); }}>
          <label className="sr-only" htmlFor="global-search">Rechercher un produit</label>
          <span className="search-icon" aria-hidden="true">⌕</span>
          <input id="global-search" value={draft} maxLength={100} onChange={e => setDraft(e.target.value)} placeholder="Rechercher un produit, une référence, une marque…" />
          <button aria-label="Lancer la recherche">Rechercher</button>
        </form>
        <div className="account">
          {user ? <>
            <div className="account-copy"><span>Mon compte</span><strong>{user.nom}</strong></div>
            <button className="secondary compact" onClick={logout}>Déconnexion</button>
          </> : <button className="account-login" disabled={!isConfigured} onClick={() => setShowAuth(true)}>Mon compte</button>}
        </div>
      </div>
      <nav className="site-nav" aria-label="Navigation principale">
        <div className="nav-inner">
          {tabs.map(([id, label]) => <button key={id} aria-current={tab === id ? 'page' : undefined} onClick={() => changeTab(id)}>{label}</button>)}
          <a href="mailto:2hbc.contact@gmail.com">Nous contacter</a>
        </div>
      </nav>
    </header>

    {!isConfigured && <p className="notice config-notice" role="status">Le service est en cours de préparation. Le catalogue et les comptes seront disponibles prochainement.</p>}
    {authError && <p className="error global-error" role="alert">{authError}</p>}
    {(showAuth || recovery) && <AuthModal key={recovery ? 'recovery' : 'auth'} onClose={() => { setShowAuth(false); if (recovery) finishRecovery(); }} />}

    <div id="main-content" className="main-content">
      {tab === 'catalogue' && <Catalogue initialTerm={search} onLoginClick={() => setShowAuth(true)} />}
      {tab === 'panier' && <Panier />}
      {tab === 'dashboard' && <Dashboard />}
      {tab === 'admin' && <Admin />}
      {tab === 'accueil' && <main className="page home">
        <section className="hero">
          <div className="hero-content">
            <p className="eyebrow">Matériel électrique pour les professionnels</p>
            <h1>Préparez vos achats.<br /><span>Achetez mieux, plus vite.</span></h1>
            <p className="hero-copy">2HBC centralise vos références, vos offres fournisseurs et votre sélection pour vous aider à comparer simplement et préparer vos achats sans perdre de temps.</p>
            <form className="hero-search" onSubmit={e => { e.preventDefault(); goCatalogue(draft); }}>
              <span className="search-icon" aria-hidden="true">⌕</span>
              <input value={draft} maxLength={100} onChange={e => setDraft(e.target.value)} placeholder="Produit, marque ou référence…" aria-label="Rechercher dans le catalogue" />
              <button>Rechercher</button>
            </form>
            <div className="quick-links" aria-label="Accès rapides">
              <span>Accès rapide :</span>
              {['Disjoncteur', 'Câble électrique', 'Prise', 'Éclairage'].map(term => <button key={term} onClick={() => goCatalogue(term)}>{term}</button>)}
            </div>
          </div>
          <aside className="hero-visual" aria-label="Aperçu de l'espace professionnel">
            <div className="visual-glow" />
            <div className="visual-topline"><span>2HBC PRO</span><span>● En ligne</span></div>
            <div className="visual-panel">
              <div className="visual-panel-title"><span>Votre activité</span><strong>Cette semaine</strong></div>
              <div className="visual-kpis">
                <div><span>Références suivies</span><strong>24</strong></div>
                <div><span>Fournisseurs</span><strong>3</strong></div>
                <div><span>Sélections</span><strong>5</strong></div>
              </div>
              <div className="visual-list">
                <div><span className="visual-dot orange" />Disjoncteur iC60N 16A <b>Comparé</b></div>
                <div><span className="visual-dot blue" />Câble R2V 3G2,5 <b>Ajouté</b></div>
                <div><span className="visual-dot green" />Prise 2P+T <b>Disponible</b></div>
              </div>
            </div>
            <blockquote>« Du matériel pro, au service de ceux qui construisent demain. »</blockquote>
          </aside>
        </section>

        <section className="value-grid" aria-label="Les avantages 2HBC">
          {valueCards.map(([num, title, copy]) => <article key={num}>
            <span className="value-icon">{num}</span>
            <div><h2>{title}</h2><p>{copy}</p></div>
          </article>)}
        </section>

        <section className="brand-section">
          <div className="brand-story">
            <p className="eyebrow light">Un seul espace, plusieurs fournisseurs</p>
            <h2>Les grandes marques et distributeurs, plus faciles à comparer.</h2>
            <p>Le pilote 2HBC rassemble progressivement les références utiles aux artisans. L'objectif : vous faire gagner du temps sans changer votre façon d'acheter.</p>
            <button onClick={() => goCatalogue()}>Explorer le catalogue →</button>
          </div>
          <div className="partner-grid" aria-label="Exemples de marques du secteur">
            {['Legrand', 'Schneider Electric', 'Hager', 'ABB', 'Nexans', 'Philips', 'Atlantic', 'Sonepar'].map(name => <span key={name}>{name}</span>)}
          </div>
        </section>

        <section className="pro-space">
          <div>
            <p className="eyebrow">Votre espace pro, simplement</p>
            <h2>Une sélection claire pour préparer vos achats.</h2>
            <p>Comparez les offres, ajoutez votre choix au panier, ajustez les quantités puis exportez votre sélection pour poursuivre auprès de vos fournisseurs.</p>
            <div className="hero-actions">
              <button onClick={() => goCatalogue()}>Explorer le catalogue</button>
              {!user && <button className="secondary" onClick={() => setShowAuth(true)}>Créer mon compte pro</button>}
            </div>
          </div>
          <div className="process-card">
            <span className="process-label">Parcours d'achat</span>
            <ol>
              <li><b>01</b><div><strong>Recherchez</strong><span>Une référence, un produit ou une marque.</span></div></li>
              <li><b>02</b><div><strong>Comparez</strong><span>Les tarifs et conditionnements disponibles.</span></div></li>
              <li><b>03</b><div><strong>Préparez</strong><span>Votre panier par fournisseur.</span></div></li>
            </ol>
          </div>
        </section>

        <section className="pilot-card">
          <div><p className="eyebrow">Pilote 2HBC</p><h2>Construisons cette première version avec les artisans.</h2><p>Vos retours sur les références manquantes, les fournisseurs et les usages réels nous permettent d'améliorer le service.</p></div>
          <a className="button" href="mailto:2hbc.contact@gmail.com">Échanger avec l'équipe</a>
        </section>
      </main>}
    </div>

    <footer className="site-footer">
      <div className="footer-brand"><Brand onClick={() => setTab('accueil')} /></div>
      <div><strong>Des pros pour les pros.</strong><span>Catalogue · Comparaison · Sélection</span></div>
      <div><a href="mailto:2hbc.contact@gmail.com">2hbc.contact@gmail.com</a><span>© {new Date().getFullYear()} 2HBC · Version pilote</span></div>
    </footer>
  </div>;
}

export default function App() {
  return <AuthProvider><AppInner /></AuthProvider>;
}
