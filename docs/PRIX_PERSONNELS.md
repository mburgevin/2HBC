# Catalogue réel et prix personnels — prototype 0.2

## Décision

Le catalogue est commun. Les prix observés dans le compte d’un artisan sont privés.
2HBC recherche d’abord ses produits connus ; l’extension consulte ensuite une fiche
fournisseur à la demande. Avoir des onglets fournisseurs ouverts ne donne aucun accès
à leurs sessions au serveur Vercel : l’extension de bureau est nécessaire.

Le moteur de panier et le moteur de lecture de prix sont indépendants. Ni paiement,
ni commande, ni création de devis dans le parcours de lecture. Pas d’API privée appelée.
Aucun mot de passe, cookie ou jeton fournisseur n’est collecté ou envoyé à Supabase.

## Ce qui est livré

- Trois produits Legrand Plexo réels : 069511L, 069611L, 069711L.
- Six correspondances fabricant/EAN/référence fournisseur, sources officielles dans
  `catalog/pilot-products.json`. Les zéros initiaux Sonepar sont conservés.
- Import additif et idempotent `supabase/pilot_catalog.sql`, généré par
  `node scripts/catalog-sql.cjs`. Pas d’écrasement du catalogue ou des prix existants.
- Catalogue pilote distinct des anciennes données de démonstration via le RPC
  `rechercher_catalogue_personnel`. Les tarifs non lus restent absents.
- Bouton « Lire mon prix » dans la comparaison et le panier, relié à une fiche connue.
- Lecture du DOM après deux observations stables : référence, quantité, prix net HT,
  devise, unité et base de prix. Le contrôle porte sur une observation, pas une garantie tarifaire.
- Conservation privée en `prix_personnels`, RLS par `auth.uid()`. Le rôle applicatif
  admin ne peut pas lire les prix d’autrui ; le propriétaire d’infrastructure/service_role
  reste privilégié comme pour les autres données Supabase.
- Tests PostgreSQL, protocole/worker, React et Chromium avec pages simulées.

## Ce qui reste à qualifier avec les comptes

Les deux profils (panier et prix) sont désactivés initialement. Aucun sélecteur connecté
Rexel/Sonepar n’est inventé ou présenté comme validé. Les valeurs de tests sont fictives.

Dans les réglages JSON de chaque fournisseur, remplir l’objet `price` :

| Champ | Élément visible attendu |
| --- | --- |
| enabled | true après qualification |
| accountSelector | Identifiant non secret du compte client actif, sans champ de connexion |
| contextSelector | Agence + affaire/dérogation actives, ou un contexte standard explicite |
| refSelector | Référence fournisseur seule, exactement celle du catalogue |
| kindSelector | « Prix net » ou « Prix net HT » |
| taxSelector | « HT » seul |
| quantitySelector | Quantité actuellement affichée sur la fiche |
| unitSelector | unité, unité(s), pièce, pièce(s), m ou kg |
| currencySelector | EUR |
| priceSelector | Montant numérique seul, éventuellement suffixé € ou EUR |
| basisSelector | Nombre d’unités auxquelles ce montant s’applique (1, 100, etc.) |

Ces contraintes sont volontairement strictes. Si une page ne fournit pas ces éléments
séparément, développer un adaptateur testé pour son format réel plutôt que sélectionner
un prix public, brut ou TTC. Le lecteur de prix actuel parcourt le DOM classique ; un
composant encapsulé nécessite une adaptation. Deux lectures stables ne prouvent pas
que le fournisseur a terminé tous ses calculs : qualifier aussi ses indicateurs de chargement.

La quantité n’est pas modifiée automatiquement par le lecteur de prix. Pour le premier
essai, régler la valeur sur la fiche fournisseur. Le parcours de comparaison commence
à 1 ; le panier demande sa quantité enregistrée. La future version pourra actualiser
les quantités via le mécanisme natif observé, après vérification des effets de bord.

Sonepar indique un conditionnement de 10 unités pour les trois références. Ce n’est pas
une preuve du minimum commandable ni de la base tarifaire. Le prix est normalisé par sa
base observée ; ne pas comparer une boîte à une pièce ou 100 mètres à 1 mètre. Aucune
remise par quantité n’est extrapolée. Écotaxes, transport et disponibilité ne sont pas
encore lus ; le total final reste calculé chez le fournisseur.

Si la connexion redirige ailleurs, revenir sur la fiche produit demandée dans l’onglet
ouvert par l’extension. La tâche attend deux minutes et peut être annulée. Les défis MFA
et CAPTCHA sont gérés par l’utilisateur. Aucun contournement.

## Isolation et durée

Chaque lecture est liée à un utilisateur 2HBC, une session d’interface aléatoire, un onglet
et une origine autorisée. Une réponse d’une autre session est refusée. Le compte et son
contexte sont hachés avec un sel de session ; leurs libellés bruts ne quittent pas le navigateur.
L’application revérifie l’identité 2HBC avant d’enregistrer une réponse asynchrone.

Une observation est affichée dix minutes avec son heure. Elle n’est pas rechargée comme
prix courant après fermeture de la comparaison, changement de quantité ou nouvelle
connexion. Après un changement de compte/affaire fournisseur, cliquer de nouveau sur
« Lire mon prix ». Il n’existe pas encore de détection continue de ces changements.
Les observations expirées restent dans l’historique privé Supabase et peuvent être
supprimées par leur propriétaire ; elles ne servent pas à un cache commun ou au calcul
automatique du total panier. Les tâches de lecture locales expirent après deux minutes.

Les données venant du navigateur sont des observations non signées, modifiables par leur
propriétaire. Ne pas les utiliser comme preuve contractuelle, commission ou remise 2HBC.
Les tarifs négociés 2HBC devront provenir d’un flux fournisseur identifié et distinct.

## Extension du catalogue

Ce lot de trois produits sert à valider le chemin complet. Pour le pilote métier, choisir
50 à 100 références courantes avec les artisans, puis vérifier marque, référence fabricant,
EAN, variante, référence de chaque distributeur et unité de vente. Conserver une source
et une date par correspondance. Aucun rapprochement automatique fondé seulement sur un nom.

Pour un catalogue large : import fabricant/fournisseur autorisé, API ou fichier structuré.
L’extension sert aux prix personnels des produits consultés ; elle n’aspire pas tout le
catalogue à chaque recherche. La diffusion commerciale et les droits de réutilisation
restent à valider avec Rexel/Sonepar ; une API officielle pourra remplacer la lecture DOM.

## Sources vérifiées le 11 octobre 2026

- https://www.rexel.fr/frx/login — prix personnalisés après connexion.
- https://www.sonepar.fr/fr-fr/static/vos-questions-frequentes — choix net/brut,
  changement de compte et dérogations affaires, périodes de maintenance.
- https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts — lecture DOM et isolation.
- https://supabase.com/docs/guides/database/postgres/row-level-security — isolation des données.
- Sources exactes des six offres : `catalog/pilot-products.json`.

Le contrôle de sécurité Supabase ne signale pas de défaut RLS sur les nouveaux objets.
Il signale un réglage Auth existant : protection des mots de passe compromis désactivée.
Documentation : https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection
