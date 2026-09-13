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

Cette version est un pilote : les tarifs importés sont de démonstration, l'export CSV ne transmet aucune commande et les économies ne sont pas simulées.
