import React from 'react';
import { useAuth } from './AuthContext';
export default function Dashboard() {
  const { user } = useAuth();
  return <main className="page empty"><p className="eyebrow">Mes économies</p><h1>{user ? 'Vos premiers achats restent à confirmer' : 'Connectez-vous pour accéder à votre espace'}</h1><p>Cette version prépare vos paniers. Elle ne reçoit pas encore les confirmations d’achat des fournisseurs.</p><p>Aucune économie n’est affichée tant qu’elle n’a pas été vérifiée à partir d’un achat réel et d’un prix de comparaison.</p></main>;
}
