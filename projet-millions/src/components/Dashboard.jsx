import React from 'react';
import { useAuth } from './AuthContext';

export default function Dashboard() {
  const { user } = useAuth();
  if (!user) return <main className="page dashboard-page"><section className="dashboard-hero compact-page-hero"><p className="eyebrow">Mes économies</p><h1>Connectez-vous pour accéder à votre espace.</h1><p>Votre tableau de bord regroupera vos sélections et, à terme, vos économies réellement vérifiées.</p></section></main>;

  return <main className="page dashboard-page">
    <section className="dashboard-hero"><div><p className="eyebrow">Mes économies</p><h1>Bonjour {user.nom},</h1><p>Votre espace est prêt à suivre vos achats dès que les premières confirmations fournisseurs seront disponibles.</p></div><span className="status-pill">Pilote en cours</span></section>
    <section className="dashboard-grid" aria-label="Indicateurs du tableau de bord">
      <article><span>Sélections enregistrées</span><strong>—</strong><small>Disponible prochainement</small></article>
      <article><span>Économies vérifiées</span><strong>— €</strong><small>Calculées uniquement sur achats réels</small></article>
      <article><span>Fournisseurs comparés</span><strong>—</strong><small>Historique à venir</small></article>
    </section>
    <section className="dashboard-body">
      <article className="dashboard-main-card"><div className="section-heading"><div><p className="eyebrow">Suivi d'activité</p><h2>Vos premiers achats restent à confirmer</h2></div></div><div className="empty-state-visual"><span>2HBC</span><div /><div /><div /></div><p>Cette version prépare vos paniers. Elle ne reçoit pas encore les confirmations d’achat des fournisseurs.</p><p>Aucune économie n’est affichée tant qu’elle n’a pas été vérifiée à partir d’un achat réel et d’un prix de comparaison.</p></article>
      <aside className="dashboard-side-card"><p className="eyebrow light">Pourquoi attendre la confirmation ?</p><h2>Des chiffres utiles, pas des économies fictives.</h2><p>2HBC affichera uniquement des économies calculées à partir de données comparables et vérifiées.</p><ul><li>Prix d'achat réel</li><li>Prix de comparaison identifié</li><li>Date et fournisseur connus</li></ul></aside>
    </section>
  </main>;
}
