# 2HBC — pilote Supabase et Vercel

Plateforme de préparation des achats de matériel pour les artisans électriciens.

- `projet-millions/` : application React, comptes Supabase Auth, catalogue et paniers.
- `supabase/migrations/` : schéma PostgreSQL et politiques de sécurité.
- `supabase/seed.sql` : catalogue facultatif de démonstration, sans données personnelles.
- `tests/` : tests PostgreSQL embarqués pour la migration et l'isolation RLS.
- `backend/` : ancien prototype local Express/SQLite, non utilisé par la version hébergée.

## Développement

Dans `projet-millions/`, installer avec `npm ci`, copier `.env.example` vers `.env.local` et renseigner l'URL Supabase et la clé publiable. Lancer `npm start` après application du schéma au projet de développement choisi.

Sans configuration Supabase, l'accueil indique que le service est en préparation. Le déploiement utilise `npm run build:deploy`, qui refuse une configuration absente ou une clé secrète.

Les builds de production utilisent la configuration **publique** du projet pilote 2HBC dans `projet-millions/.env.production`. Pour un autre environnement, utiliser les variables Vercel ou les fichiers locaux ignorés par Git.

Voir [le guide de déploiement](docs/DEPLOIEMENT.md) pour le schéma, les décisions à discuter, les tests et les paramètres Vercel.

Cette version est un pilote : les tarifs importés sont de démonstration et les économies ne sont pas simulées.

## Auto-panier — prototype

Le panier est regroupé par fournisseur. Une extension Manifest V3 prépare les transferts par lot vers Rexel ou Sonepar, avec vérification des quantités et sans validation de commande. Les interfaces connectées doivent encore être repérées avant d’activer les profils. Les tests automatisés utilisent des fournisseurs simulés.

Voir [le guide d’installation et de test](docs/AUTO_PANIER.md). Le site fournit l’archive installable sur `/auto-panier.html` après son build. Aucun mot de passe ou cookie fournisseur ne doit être transmis à 2HBC.

### Prix personnels et catalogue réel

Le prototype 0.2 ajoute un catalogue pilote vérifié et une lecture des prix nets du
compte fournisseur via l’extension. Les observations sont privées, horodatées et
séparées des tarifs communs. Guide et limites : [docs/PRIX_PERSONNELS.md](docs/PRIX_PERSONNELS.md).
Les profils connectés nécessitent une qualification avec un compte Rexel/Sonepar.

### Collecte du catalogue pilote

`python3 scripts/collect_catalogue.py --limit 100` prépare un fichier de produits
publics, sans prix ni écriture en base, avec dédoublonnage et reprise automatique.
Le script peut aussi être téléchargé seul. Voir [le guide Windows et les limites](docs/COLLECTE_CATALOGUE.md).
Les 100 fiches restent à collecter et contrôler : seuls les tests hors réseau ont été exécutés.
