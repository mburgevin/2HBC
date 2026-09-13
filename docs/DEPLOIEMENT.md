# Déploiement pilote 2HBC

## État vérifié le 13 septembre 2026

- Supabase `2HBC` (`gueuqeqyshhhmxbsiuxg`, eu-west-1) : migration initiale appliquée après contrôle du schéma public vide ; seed chargé, 9 tables protégées, 11 produits et 29 offres de démonstration, aucun client importé.
- API réelle : catalogue public HTTP 200, 11 produits et aucune offre visible sans connexion ; accès direct aux tarifs HTTP 200 avec résultat vide. Auth email et confirmation activés, connexions anonymes désactivées.
- Advisor sécurité : aucune alerte. Advisor performance : indices encore inutilisés sur cette nouvelle base et [politiques de lecture/admin qui se recouvrent](https://supabase.com/docs/guides/database/database-linter?lint=0006_multiple_permissive_policies), sans blocage de sécurité constaté.
- Compilation `build:deploy` réussie avec l'URL et la clé publiable de ce projet. Préversion Vercel `READY` : https://2-oo8we1xxx-mburgevins-projects.vercel.app (accès protégé Vercel).
- Cette préversion a été envoyée sous forme de fichiers compilés. Les futurs builds Git utilisent la configuration publique versionnée dans `projet-millions/.env.production`, surchargeable par les variables Vercel. La production existante n'a pas été remplacée. La page HTML de la préversion répond HTTP 200 via un lien de partage autorisé.
- Restent à vérifier/configurer : URL du site et redirections Auth, réception des emails, parcours avec deux comptes réels, rendu navigateur/mobile et administrateur désigné. Aucun succès de ces parcours n'est présumé.
- Dépôt et branche cible confirmés explicitement par Mathias : `mburgevin/2HBC`, `feature/2hbc-dev`.

## Architecture préparée

Frontend React dans `projet-millions/`, hébergé sur Vercel. Supabase fournit Auth, PostgreSQL et la Data API. Le dossier `backend/` est l'ancien prototype Express/SQLite ; il ne doit pas être déployé. Aucun compte ni panier SQLite n'est importé.

La migration doit être appliquée à un projet Supabase dédié et vide, après vérification du projet cible. Le seed est facultatif : 11 produits issus du prototype, tous les tarifs marqués `demonstration`, aucune donnée personnelle. Il est idempotent et ne remplace pas un tarif existant.

## Choix par rapport à db.txt

| Élément | Choix du pilote |
|---|---|
| Clients | UUID lié à `auth.users`, sans mot de passe ni copie d'email dans la table métier |
| Segments et catégories | Conservés séparément : métier du client et classement produit |
| Références et EAN | Texte pour conserver les lettres et zéros initiaux |
| Unicité produit | Marque + référence fabricant |
| Références fournisseurs | Dans `produits_fournisseurs` |
| Tarifs | Par offre fournisseur, EUR HT, origine, conditionnement et date de vérification |
| Panier | Un panier actif par client ; les articles désignent une offre fournisseur |
| Besoins clients | Table privée créée ; interface à ajouter ultérieurement |
| Variantes, caractéristiques structurées, promotions | À préciser avant ajout ; les champs description et spécificités sont conservés |
| Historique des achats et économies | Non activés sans confirmation d'achat et prix de comparaison vérifié |
| Contacts privés des fournisseurs | À stocker dans un espace privé ultérieurement |

À discuter : unités et conditionnements, tarifs propres à chaque artisan, validation des accords, variantes, cadence de mise à jour, preuve d'achat et abonnement.

## Supabase

1. Choisir explicitement le projet destiné à 2HBC ; ne pas appliquer ces fichiers à `jdr-app`.
2. Appliquer `supabase/migrations/20260913161414_initial_mvp.sql` selon le workflow de migrations. Le SQL est transactionnel ; il ne supprime pas de tables existantes.
3. Charger facultativement `supabase/seed.sql`.
4. Configurer email/mot de passe, confirmation email et un minimum de 10 caractères ; laisser les connexions anonymes désactivées.
5. Définir l'URL du site et les redirections Auth sur les adresses Vercel retenues. Pour le développement : `http://localhost:3000`. Préférer des previews explicitement autorisées.
6. Vérifier l'envoi réel des confirmations et réinitialisations. Préparer un SMTP adapté avant les invitations externes.
7. Récupérer l'URL du projet et une **publishable key**. Ne jamais placer de clé secrète/service_role dans les variables du frontend.
8. Pour un administrateur désigné, définir `app_metadata.role = "admin"` avec une opération d'administration Auth, puis rafraîchir la session. Ne jamais utiliser `user_metadata` pour les droits.
9. Exécuter les advisors Supabase et les tests finaux via Auth et PostgREST.

Les tarifs sont accessibles aux comptes authentifiés non anonymes dans ce pilote gratuit. L'abonnement payant n'est pas implémenté. Les profils et paniers restent privés à leur propriétaire, y compris pour les administrateurs du catalogue.

## Vercel

Projet existant identifié : `mburgevins-projects/2-hbc`, dépôt `mburgevin/2HBC`.

| Paramètre | Valeur |
|---|---|
| Root Directory | `projet-millions` |
| Framework | Create React App |
| Node.js | 22.x |
| Install | `npm ci` |
| Build | `npm run build:deploy` |
| Output | `build` |

Configuration publique du pilote versionnée dans `projet-millions/.env.production`. Les variables Vercel Preview/Production peuvent la surcharger :

```text
REACT_APP_SUPABASE_URL=https://<project-ref>.supabase.co
REACT_APP_SUPABASE_PUBLISHABLE_KEY=sb_publishable_...
```

Ces valeurs sont publiques et intégrées au build : un changement nécessite un nouveau build. Le script `build:deploy` refuse les variables absentes, les placeholders et les clés non publiables. Le fichier `projet-millions/vercel.json` configure la SPA et les en-têtes de sécurité. La CSP suppose un domaine Supabase standard ; l'utilisation d'un domaine personnalisé nécessitera son adaptation.

Créer et tester une preview avant toute promotion en production. Ne pas fusionner une migration non reliée au projet Supabase cible dans la branche actuellement publiée.

## Vérifications reproductibles

À la racine :

```bash
npm ci
npm run test:db
```

Dans `projet-millions` :

```bash
npm ci
CI=true npm test -- --watchAll=false --runInBand
CI=true npm run build
```

Les tests de base utilisent le moteur PostgreSQL embarqué PGlite et des claims Auth simulés. Ils valident le SQL et RLS ; ils ne remplacent pas un test du service Supabase Auth et des relations PostgREST sur le projet hébergé.

Avant publication, vérifier en ligne : confirmation et récupération email, connexion/restauration/déconnexion, recherche et catalogue, ajout/modification/suppression de panier, isolation avec deux comptes, droits admin, export CSV, affichage mobile et erreurs console/réseau.

## Limites

Pas de scraping en ligne, paiement, abonnement, commande automatiquement transmise, ni historique d'achat confirmé. Le CSV est une liste générique à adapter au format accepté par chaque fournisseur. Les totaux sont indicatifs, hors livraison ; les conditionnements doivent être vérifiés. Compléter les informations relatives à la société avant ouverture commerciale.

## Sources techniques

- [Supabase Auth et React](https://supabase.com/docs/guides/auth/quickstarts/react)
- [Supabase RLS](https://supabase.com/docs/guides/database/postgres/row-level-security)
- [Create React App sur Vercel](https://vercel.com/docs/frameworks/frontend/create-react-app)
