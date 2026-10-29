# Catalogue métier 2HBC — étape 2

Date : 29 octobre 2026. Projet : `gueuqeqyshhhmxbsiuxg`.

## Résultat et périmètre

Le schéma traduit le référentiel métier approuvé à l’étape 1. Il contient 3 univers, 19 familles finales et 99 attributs actifs. Il n’importe aucun produit et ne modifie pas les comptes, clients ou fournisseurs. Les anciens codes restent présents mais inactifs pour préserver les références historiques.

Installation distante : **appliquée et contrôlée le 29 octobre 2026 à 16 h 34 UTC**. L’historique contient les six migrations attendues. Le contrôle après installation confirme 0 produit, 0 offre, 2 utilisateurs, 1 client et 3 fournisseurs ; les empreintes des identifiants utilisateurs et des données fournisseurs sont identiques avant/après. Les 24 tables métier ont la RLS, aucune fonction métier n’est `SECURITY DEFINER` et aucun rôle client ne possède les droits de table excessifs contrôlés. Une recherche exécutée en rôle `anon` renvoie un catalogue et une navigation vides ; les observations lui sont interdites.

Les tests PostgreSQL locaux passent : **56/56**, dont le retour arrière de toute l’installation sur erreur. L’audit Supabase ne signale aucune nouvelle anomalie de schéma ou de RLS. Il conserve l’avertissement préexistant sur la [protection contre les mots de passe compromis](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection), désactivée dans Auth ; ce réglage n’a pas été modifié. L’audit de performance signale seulement des [index encore inutilisés](https://supabase.com/docs/guides/database/database-linter?lint=0005_unused_index), cohérents avec le catalogue vide.

| Univers | Familles finales |
|---|---|
| Appareillage mural et boîtes | prises, interrupteurs, poussoirs, plaques, enjoliveurs, supports, boites, boitiers-saillie, boites-derivation, sorties-cable |
| Protections et distribution | disjoncteurs, differentiels, disjoncteurs-differentiels, coffrets, peignes |
| Connexion et raccordement | bornes, barrettes-vis, bornes-rail, accessoires-bornes |

## Données et contrôles

- `attributs` et `attribut_valeurs` décrivent les textes, nombres, entiers, booléens, choix, ensembles et intervalles. Les unités et contextes requis sont vérifiés côté base.
- `categorie_attributs` définit les attributs applicables et essentiels de chaque famille. `categorie_exigences` porte les conditions complémentaires : gamme, compatibilité, entraxe multiposte, pouvoir de coupure qualifié et plages par conducteur.
- `observations_attributs` conserve les données brutes et normalisées, URL, date, unité, contexte, version de règle et décision de revue. Les observations retenues sont immuables tant qu’elles alimentent une valeur catalogue.
- `valeurs_catalogue` retient une valeur issue d’une observation validée du même produit, du même attribut et du même contexte. « Non applicable » exige un motif et une source ; ce n’est pas une valeur technique publique.
- `compatibilites_produits` exprime une relation sourcée vers un produit précis ou un système/version. Elle ne crée aucune identité ni équivalence de remplacement.
- `regles_categories_fournisseurs` et `alias_attributs` préparent les correspondances contextualisées du collecteur. Aucune règle fournisseur non vérifiée n’est préremplie.

Les intervalles sont stockés atomiquement, par exemple `section_souple_avec_embout = {"min": 0.5, "max": 2.5}` en mm², avec une seule observation. Les codes min/max du document métier sont donc réunis dans un objet : les deux bornes ne peuvent pas provenir de sources différentes. La plage générique souple reste distincte de la plage avec embout. Les ensembles sont comparés sans tenir compte de l’ordre. Les nouveaux vocabulaires inconnus restent en observation avant revue.

## Publication

Les états sont `collecte`, `a_revoir` et `publie`. Un ancien import approuvé prépare encore les identités/offres, mais ne contourne pas la qualification métier.

1. Classer le produit dans une famille finale active et vérifier son identité/GTIN ainsi qu’au moins une offre.
2. Enregistrer et valider les observations ; sélectionner les valeurs applicables.
3. Résoudre les contradictions par une décision explicite et documentée.
4. Lire `diagnostic_publication(produit_id)` et corriger les erreurs.
5. Appeler `publier_produit_catalogue(produit_id)` avec un compte administrateur autorisé.

La publication exige les critères essentiels renseignés ou explicitement non applicables et les exigences complémentaires satisfaites. Une photo ou un second fournisseur manquant n’est pas bloquant. La base revalide les valeurs contre le dictionnaire courant. Par prudence, toute observation contradictoire non résolue bloque actuellement la publication, même sur un critère facultatif.

Une modification des observations, valeurs retenues, compatibilités ou offres dépublie la fiche jusqu’à sa prochaine revue. Pour ce premier modèle, toute modification du référentiel nécessite de dépublier d’abord les fiches ; cette règle conservatrice évite de rendre silencieusement invalides des fiches déjà publiques.

## Accès

Les tables publiques métier ont toutes la RLS. Les observations et règles de correspondance sont réservées aux administrateurs via `app_metadata`. Les visiteurs lisent les produits publiés et leurs valeurs techniques validées. Les tarifs personnels restent accessibles uniquement à leur propriétaire, y compris face à un autre compte administrateur. Les offres non publiées sont refusées au panier. La vue de navigation ne montre que les branches contenant des produits publiés.

Aucune fonction métier `SECURITY DEFINER` n’est ajoutée. Les permissions héritées `TRUNCATE`, `TRIGGER` et `REFERENCES` sont retirées aux rôles clients.

## Migration et maintenance

- Migration générée : `supabase/migrations/20261029161909_catalogue_modele_metier_v1.sql`.
- Installation de l’état distant vide : `supabase/operations/20261029_install_catalogue_v1.sql` ; applique intégrité/import, images, facettes puis modèle métier et enregistre leurs versions dans la même transaction.
- Sources : `scripts/build_referentiel_v1.py` et `supabase/catalogue/referentiel_schema.sql`.
- Génération : `python scripts/build_referentiel_v1.py`, puis `python scripts/build_catalogue_install.py`.
- Vérification : `npm run test:db` et `git diff --check`.

Le script d’installation exige exactement les deux migrations initiales et l’absence de produit, d’offre et de catégorie. Un second lancement est refusé. En cas d’erreur dans un éditeur SQL, exécuter `ROLLBACK;` avant toute autre opération. Ne pas exécuter séparément des fragments du script. Après application, ne plus régénérer/modifier une migration déjà installée : créer une nouvelle migration pour toute évolution.

## Suite du travail

L’étape 3 doit adapter le collecteur et le contrat d’import aux nouveaux profils, conserver les observations et proposer les correspondances à revoir. Ensuite, la recherche et le site doivent lire `valeurs_catalogue` pour exposer les ensembles, intervalles et contextes. La RPC v2 actuelle continue à utiliser ses anciennes valeurs `produit_attributs` pour les facettes ; seuls les accès et la navigation sont alignés à cette étape. Aucun filtre métier nouveau n’est prétendu opérationnel dans l’interface.

Les quantités décimales du panier et de l’extension nécessitent toujours une adaptation coordonnée distincte.
