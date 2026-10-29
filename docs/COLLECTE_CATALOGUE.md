# Collecteur métier 2HBC — version 0.5.0

État du 30 octobre 2026 (Europe/Paris). Étape 3 : collecte publique, propositions métier, revue et import v3. Les catégories et contraintes de l’étape 2 restent la référence. La recherche et les filtres du site seront adaptés séparément.

## Démarrer sous Windows

Télécharger [collecteur-metier-v0.5.0.zip](../releases/collecteur-metier-v0.5.0.zip), extraire **tout** le dossier, puis ouvrir un terminal dans le dossier extrait. Python 3.10 ou supérieur suffit ; aucune dépendance à installer, clé Supabase ou connexion fournisseur à fournir.

```powershell
py scripts/collect_catalogue.py --version
py scripts/collect_catalogue.py --limit 100 --max-pages 500 --out catalogue-metier-v050
```

La première commande affiche `0.5.0`. Le paquet contient les deux programmes, leur module métier commun et le dictionnaire des 99 attributs. Ne pas déplacer un seul script hors de ce dossier. Sous macOS/Linux, remplacer `py` par `python3`.

Les points de départ couvrent désormais l’appareillage, la protection et la connectique. Un chemin fournisseur n’attribue pas automatiquement une famille 2HBC. Pour une sélection précise, utiliser `--urls urls.txt` avec une URL publique de produit ou de catégorie par ligne. Les valeurs inconnues, les familles hors périmètre et les compositions ambiguës restent à revoir.

La reprise fonctionne dans un dossier v0.5.0. Les anciens dossiers de progression sont refusés ; choisir un nouveau `--out` pour ne pas perdre leur contenu. Ctrl+C conserve la progression. Les limites, robots.txt, délais par domaine, redirections autorisées et suspensions sur 401/403/429/503 sont conservés. L’atteinte de 100 produits n’est pas garantie : le rapport indique le résultat réel. Aucun prix connecté n’est collecté.

## Résultats

| Fichier | Usage |
|---|---|
| `products.json` | Contrat d’import v3 : identité, offres, sources brutes, observations proposées et décisions de revue. |
| `catalogue.json` | Aperçu lisible des codes Rexel/Sonepar, photos et informations de revue. |
| `review.json` | Conflits par attribut/contexte, champs essentiels non sélectionnés après classement, exigences complémentaires, données non normalisées et suggestions de famille sourcées. |
| `report.json` | Couverture, erreurs, fournisseurs manquants, photos et objectif atteint ou non. |
| `state.json` | Progression du collecteur ; ne pas y effectuer la revue métier. |

Chaque observation conserve le fournisseur, le libellé et la valeur bruts, la règle de normalisation, la valeur proposée, son unité et son contexte. Sa source et sa date viennent de l’offre correspondante. Le collecteur met toujours `status: pending` et `selected: false`. Aucune source ne gagne arbitrairement en cas de contradiction.

Les intervalles restent des objets `{ "min": 0.5, "max": 2.5 }`, avec une source unique ; les sections rigides, souples et avec/sans embout sont distinctes. Les mesures Icn/Icu incluent norme et tension. Un IP sans contexte d’assemblage, une valeur de modules ambiguë ou une terminologie non reconnue restent dans les données brutes. Une donnée non normalisée n’est pas une donnée perdue. Le rapport ne remplace pas le diagnostic de publication de la base.

Les suggestions de famille reposent uniquement sur un libellé final fournisseur reconnu ; elles conservent leur source et restent `a_revoir`. Les correspondances fournisseur et les alias de la BDD ne sont pas approuvés automatiquement. Le collecteur utilise un dictionnaire local versionné, sans connexion à la BDD.

## Convertir une ancienne collecte sans refaire les requêtes

Les JSON v2 possèdent déjà les caractéristiques brutes. La conversion les conserve et recalcule des propositions v3 ; les anciennes approbations et attributions de famille ne sont pas reconduites.

```powershell
py scripts/prepare_catalogue_import.py ancienne-collecte/products.json --upgrade-out catalogue-metier-v050/products.json
```

Le fichier source n’est jamais écrasé. Cette commande ne visite aucun site et ne produit aucune publication.

## Préparer, qualifier, publier

La migration `20261029233412_catalogue_import_metier_v3.sql` ajoute la fonction `importer_catalogue_v3` et le rattachement des observations à leurs collectes. Elle vient après les six migrations de l’étape 2. Le statut de son installation est indiqué dans [ETAPE_3_IMPORT_METIER.md](ETAPE_3_IMPORT_METIER.md).

**1. Préparer en privé** : générer le SQL, puis l’exécuter en entier dans le SQL Editor du projet 2HBC.

```powershell
py scripts/prepare_catalogue_import.py catalogue-metier-v050/products.json --out preparation.sql --review-out revue.json
```

Cette étape conserve les documents dans `collectes_catalogue`, réservée aux administrateurs. Elle ne crée aucun produit public ni aucune observation sélectionnée.

**2. Relire une copie** `products-reviewed.json` : vérifier les identités et références fournisseur, attribuer `category_code` dans les 19 familles actives, contrôler la gamme et chaque caractéristique utile. Passer `review_status` à `approved` uniquement pour les identités relues. Pour chaque observation retenue, indiquer `status: validated` et `selected: true`. Garder les autres propositions `pending`, ou écrire `status: rejected`, `selected: false` et un `review_note` explicite d’au moins 10 caractères en cas de rejet. Une seule sélection est permise par attribut/contexte.

```powershell
py scripts/prepare_catalogue_import.py catalogue-metier-v050/products-reviewed.json --approve --out qualification.sql
```

L’exécution crée ou actualise une fiche **privée**, ses offres et ses observations. Le résultat inclut `diagnostic` : champs manquants, conflits ou exigences restantes. Les données sélectionnées sont contrôlées côté serveur, y compris les unités, intervalles, dictionnaires, contextes, provenance et applicabilité.

`exceptions` permet de marquer un attribut non applicable avec `code`, `context`, `reason` et `source_url`. `compatibilities` documente un système précis via `system`, `version`, `role`, `source_url`, `observed_at` et `evidence`. Ne pas déduire ces informations d’une gamme ou d’une photo. Ces listes restent vides tant que leurs preuves ne sont pas vérifiées.

**3. Publier explicitement**, après résolution des erreurs :

```powershell
py scripts/prepare_catalogue_import.py catalogue-metier-v050/products-reviewed.json --approve --publish --out publication.sql
```

`--publish` exige `--approve` et des documents v3. Le diagnostic serveur est déterminant : une seule fiche non publiable annule **tout le lot**, y compris les insertions précédentes de ce lot. En cas d’erreur dans un éditeur SQL laissant la transaction ouverte, exécuter `ROLLBACK;`. La commande Python seule ne se connecte jamais à Supabase.

## Réimports et preuves

Un document relu identique est idempotent : il ne duplique ni produits ni offres ni observations et ne dépublie pas une fiche inchangée. Les prix personnels ne sont jamais écrits par cet import.

Une nouvelle collecte conserve ses nouvelles observations et les anciennes preuves. Les sélections constituent des mises à jour explicites, pas un remplacement implicite de tout l’historique : omettre une ancienne observation ne la supprime pas et ne résout pas un conflit. Un rejet documenté d’une observation précédemment sélectionnée retire cette sélection et impose une nouvelle qualification. Une proposition `pending` ne rétrograde pas une observation déjà relue.

Un conflit ancien non résolu reste bloquant, même si une nouvelle source est sélectionnée. Les observations retenues restent immuables ; leur contenu ne peut pas être corrigé en place. Enregistrer la nouvelle preuve et retirer/rejeter explicitement l’ancienne sélection si nécessaire. Une simple nouvelle collecte ne constitue jamais une autorisation de publication.

## Validation effectuée et limites

- Tests Python : extraction HTML, unités, intervalles, ensembles, ambiguïtés, preuves, conversion v2 et commande d’import.
- Tests PostgreSQL : vrai générateur Python → SQL, préparation privée, qualification, publication, refus des accès non administrateurs, rejeu idempotent, résolution des conflits, retrait des sélections, annulation de lots et isolation des prix personnels.
- Contrôle réel le 30 octobre 2026 (Paris) : **6 pages officielles, 3 références rapprochées, 6 photos, 219 caractéristiques brutes, aucun rejet réseau**. Après enrichissement des alias exacts observés sur ces pages : **87 propositions normalisées**, toutes en attente, et **132 caractéristiques brutes non normalisées**. Les preuves et le rapport sont dans `catalog/validation/20261030/`.

Ce pilote porte sur trois références Plexo et ne prouve pas la couverture de toutes les familles. Les formats des bornes et protections sont couverts par des cas automatisés ; leur couverture réseau doit être étendue sur un lot représentatif. Aucune collecte de 100 fiches ni publication métier de ces trois références n’est déclarée validée. Le site utilise encore ses anciennes facettes : leur raccordement aux valeurs métier est l’étape suivante de l’interface.
