# 2HBC — catalogue v2

Le chantier catégories, attributs et recherche filtrée est documenté dans [CATALOGUE_V2.md](docs/CATALOGUE_V2.md). Collecteur actuel : **0.4.0**. Le nettoyage et les migrations Supabase restent à appliquer ; le connecteur refuse les écritures au 16 octobre 2026. [Script atomique prêt pour le SQL Editor](supabase/operations/20261016_reset_catalogue.sql).

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
Il conserve les photos et les codes article Rexel/Sonepar, puis poursuit une recherche
bornée des codes manquants. `catalogue.json` rassemble les références et photos pour
le contrôle ; `products.json` reste le fichier à importer.
Le script peut aussi être téléchargé seul. Voir [le guide Windows et les limites](docs/COLLECTE_CATALOGUE.md).
Le 15 octobre 2026, une collecte de 100 produits a été importée dans Supabase avec
113 offres et 99 photos. Le catalogue réel compte désormais 103 produits en incluant
les trois pilotes. [Trace d'import et limites](catalog/imports/20261015/README.md).

L'[audit du 15 octobre sur les catégories et la recherche](docs/audits/2026-10-15/Audit_BDD_2HBC.md)
précise les évolutions nécessaires après l'import des 100 produits.
L'[audit initial de la BDD](docs/AUDIT_BDD.md) décrit les contrôles d'intégrité et
l'import en deux étapes. `scripts/prepare_catalogue_import.py` convertit la collecte
en SQL de préparation privée ; une publication nécessite des fiches relues et
`--approve`. La migration correspondante reste à appliquer à Supabase (erreur de
session du connecteur lors de la tentative du 12 octobre 2026).

Depuis le 13 octobre, le collecteur relève aussi la photo principale sur les fiches
Rexel et Sonepar, avec sa provenance et un bilan de couverture. Les trois produits
pilotes ont désormais une photo dans Supabase (`supabase/pilot_images.sql`), vérifiée
sur les pages réelles. Les cartes, la comparaison et le panier affichent les photos.
Pour les futurs imports avec images, appliquer ensuite la migration `catalogue_images` ;
elle dépend de `catalogue_integrity_import`, toujours en attente côté cloud.
