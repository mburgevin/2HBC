# Revue du SQL de nettoyage — 28 octobre 2026

Projet Supabase : `2HBC`, `gueuqeqyshhhmxbsiuxg`. Revue effectuée sur la base réelle et le script complet, avant toute application.

## État observé

Les 10 tables publiques ont la RLS activée et au moins une politique. Les 13 clés étrangères sont validées ; aucune vue publique ni fonction métier `SECURITY DEFINER`. Les deux seules migrations enregistrées restent `initial_mvp` et `personal_supplier_prices`.

| Tables | Accès observés |
|---|---|
| `clients`, `paniers`, `articles_panier`, `besoins_clients` | Accès utilisateur limité au propriétaire par RLS ; aucun droit de table pour `anon` |
| `prix_personnels` | Observations privées limitées à leur propriétaire, insertion contrôlée |
| `segments_clients`, `categories`, `fournisseurs`, `produits` | Lecture publique ; écritures de catalogue limitées au rôle admin dans `app_metadata` |
| `produits_fournisseurs` | Lecture pour comptes connectés non anonymes ; écritures administrateur |

114 produits, 148 offres, 7 lignes de panier, 0 prix personnel, 1 compte, 1 panier, 0 catégorie et 3 fournisseurs. Les 7 lignes de panier portent toutes sur des offres non vérifiées de démonstration. Empreinte du catalogue et de ses dépendances : `ddcd60b13e9ee0fda578740b7519c6f1`, identique à la sauvegarde privée du 16 octobre. Les nombres estimés de `list_tables` étaient nuls ; les décomptes ci-dessus viennent de `COUNT(*)`.

## Avertissements et corrections

1. **Destruction** : avertissement légitime. Le script supprime les anciennes lignes de panier, les offres et les produits selon le nettoyage autorisé. Il ne supprime aucune table ni compte ni conteneur de panier. Il verrouille le catalogue et vérifie son empreinte avant toute suppression. Toutes les modifications sont dans une transaction ; une erreur entraîne son annulation.
2. **UPDATE sans WHERE** : deux instructions de reprise déclenchaient la normalisation des marques et la projection publique des références fournisseurs. Elles sont maintenant limitées aux produits avec marque et aux offres vérifiées. La reprise sur une base non vide reste testée.
3. **RLS** : les six tables de facettes activaient auparavant la RLS dans une boucle dynamique. Chaque activation est maintenant un `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` explicite immédiatement après création. La table de collecte disposait déjà d'une activation explicite. Un contrôle avant validation vérifie toutes les tables publiques et leurs politiques.
4. **Permissions héritées** : le projet accorde par défaut `ALL` aux rôles `anon` et `authenticated` sur les nouvelles tables et séquences, et `EXECUTE` sur les fonctions. Un simple `GRANT SELECT` ne retire pas ces droits. Les migrations en attente les révoquent désormais avant d'accorder les seuls droits voulus. Les droits `TRUNCATE`, `TRIGGER` et `REFERENCES` sont retirés des nouvelles tables pour ces rôles. Les séquences existantes et nouvelles n'autorisent plus l'accès anonyme ni `setval` aux utilisateurs. Les imports et l'ajout au panier ne sont plus exécutables par `anon`. Les fonctions restent `SECURITY INVOKER`.

Les migrations déjà appliquées ne sont pas réécrites. Seules les trois migrations confirmées en attente, leur script d'application et les tests sont corrigés. Aucun droit par défaut global du projet n'est modifié ; toute future table doit donc définir explicitement ses protections.

Documentation officielle consultée : [RLS et permissions Supabase](https://supabase.com/docs/guides/database/postgres/row-level-security). La RLS complète les permissions SQL ; elle ne dispense pas de les limiter.

## Vérifications effectuées

- `npm run test:db` : **40 tests réussis**, dont isolation des comptes, import, facettes et reprise des références.
- Les tests reproduisent maintenant les permissions par défaut réellement observées dans Supabase. Ils refusent effectivement `TRUNCATE`, les imports anonymes et les écritures de marque sans rôle admin.
- `node tests/catalogue-reset.mjs /chemin/prive/2hbc-catalogue-20261016.json` : annulation vérifiée après erreur injectée, nettoyage limité au catalogue, compte et panier conservés, trois migrations enregistrées, 17 tables protégées, deuxième exécution refusée.
- Résultat local après application : 0 produit, 0 offre, 0 ligne de panier, 1 compte, 1 panier, 21 catégories, 22 attributs.

Les conseillers Supabase ne signalent aucune table publique sans RLS. Ils signalent la protection contre les mots de passe compromis désactivée et des index inutilisés sur ce petit jeu de données. Ces réglages ne sont pas modifiés par ce correctif. [Réglage Auth concerné](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection).

## Application distante

La tentative via `apply_migration` a été interrompue sans confirmation. Le contrôle en lecture effectué ensuite retrouve les deux migrations initiales, 114 produits, 148 offres et 7 lignes de panier, sans table `attributs`. **Le correctif n'est donc pas confirmé appliqué dans Supabase.** Aucune nouvelle tentative de mutation n'a été effectuée après l'interruption.

Le script à utiliser est [20261016_reset_catalogue.sql](../../../supabase/operations/20261016_reset_catalogue.sql), révision du 28 octobre. Remplacer intégralement le contenu de l'ancien onglet SQL et exécuter l'ensemble. Conserver impérativement le contrôle d'empreinte ; si celui-ci échoue, réexaminer les données avant toute suppression. Le catalogue sera vide jusqu'à la publication de la prochaine collecte relue.
