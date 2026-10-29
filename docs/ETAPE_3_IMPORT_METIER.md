# Étape 3 — collecteur et import métier v3

Livré le 30 octobre 2026 (Europe/Paris).

Le collecteur **0.5.0** produit le contrat métier v3 : observations sourcées, intervalles atomiques, ensembles, unités et contextes. Le programme d’import distingue préparation privée, qualification des données relues et publication explicite. Le [guide d’utilisation](COLLECTE_CATALOGUE.md) décrit les commandes Windows et la revue. Le [paquet autonome](../releases/collecteur-metier-v0.5.0.zip) contient tous les fichiers nécessaires.

## Installation Supabase confirmée

Projet `gueuqeqyshhhmxbsiuxg`. Migration enregistrée : `20261029233412_catalogue_import_metier_v3.sql`, septième migration. Le nom local a été aligné sur la version attribuée par Supabase lors de son application.

La fonction `importer_catalogue_v3(jsonb, boolean, boolean)` est installée avec `SECURITY INVOKER`, interdite à `anon` et réservée aux administrateurs via `app_metadata`. Les deux nouvelles colonnes d’observation permettent le dédoublonnage et le rattachement à la collecte d’origine. Les index couvrent la clé d’import et la nouvelle clé étrangère. Les protections RLS existantes sont conservées.

Un essai réel de préparation sur une fiche fournisseur a créé les trois traces privées attendues (identité, document v2 interne et document v3), sans produit ni valeur sélectionnée, puis a été **annulé par ROLLBACK**. Le contrôle suivant confirme **0 produit, 0 offre, 0 collecte et 0 observation**. Les 2 utilisateurs, 1 client et 3 fournisseurs sont conservés. Le catalogue public et la navigation restent vides.

L’audit Supabase ne signale aucune nouvelle anomalie de sécurité. L’avertissement Auth préexistant sur la [protection contre les mots de passe compromis](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection) reste inchangé ; aucun réglage d’authentification n’a été modifié.

## Vérification

- **46 tests Python réussis**, y compris l’extraction du paquet et son lancement depuis un dossier indépendant du dépôt.
- **68 tests PostgreSQL réussis**, y compris le vrai générateur SQL, la séparation qualification/publication, le rejeu, les conflits, les exceptions, la compatibilité documentée, l’annulation des lots et l’isolation des prix personnels.
- **Pilote réseau : 3 produits, 6 pages, 6 photos et 219 caractéristiques brutes**. Les alias exacts observés ont permis de produire 87 propositions ; 132 caractéristiques restent en brut. Toutes les observations sont en attente, aucune valeur sélectionnée automatiquement.
- Les documents issus de ces six pages ont aussi été préparés dans PostgreSQL local sans publication ni perte des données brutes.
- `git diff --check` et compilation Python réussis.

Les résultats sont versionnés dans `catalog/validation/20261030/`. Les décisions de revue restent à prendre : le pilote n’est pas un lot prêt à publier et sa couverture ne représente pas encore les 19 familles.

## Suite

Préparer un lot représentatif des familles, relire les identités et caractéristiques, compléter les preuves manquantes puis utiliser le diagnostic serveur avant publication. La recherche et les filtres du site doivent ensuite être raccordés à `valeurs_catalogue` ; leurs anciennes facettes ne consomment pas encore les intervalles et contextes métier. Les quantités décimales du panier restent une adaptation distincte.
