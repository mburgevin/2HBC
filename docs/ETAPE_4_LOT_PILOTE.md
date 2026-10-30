# Étape 4 — premier lot métier publié

Exécution confirmée dans Supabase le **30 octobre 2026**, projet `gueuqeqyshhhmxbsiuxg`.

La collecte fournie du 28 octobre contient **100 produits et 119 offres**, dont 19 produits présents chez Rexel et Sonepar. Les 100 identités ont été converties au contrat v3 et conservées en préparation privée. Après revue documentaire, **9 produits sont publiés**, avec **16 offres**, **81 valeurs validées**, 163 observations conservées et une compatibilité précise. Les **91 autres restent en préparation**, sans fiche publique. Les 316 traces techniques d'import correspondent aux documents successifs et internes ; ce ne sont pas 316 produits.

| Famille | Références Legrand publiées | Produits |
|---|---|---:|
| Interrupteurs | 600001, 600002 | 2 |
| Interrupteurs différentiels | 411650, 411651 | 2 |
| Disjoncteurs | 406782, 406783 | 2 |
| Disjoncteurs différentiels | 410705 | 1 |
| Bornes sur rail | 037162 | 1 |
| Accessoires de bornes | 037550 | 1 |

Ce pilote couvre **6 familles sur 19 et les 3 univers**, avec une seule marque. Il valide le parcours d'import ; il ne constitue pas une couverture complète du catalogue.

## Revue et limites

Chaque valeur retenue possède une preuve fournisseur, une date, une empreinte de page et une décision explicite dans le [manifeste](../catalog/imports/20261030-pilot/review-manifest.json). Les descriptions utilisées comme preuves sont recopiées exactement depuis la collecte, avec leur origine documentée. Aucune exception « non applicable » n'a été créée pour contourner une donnée manquante.

- Le 600002 est qualifié **double va-et-vient** : les deux propositions génériques « va-et-vient » sont rejetées avec motif, sans effacer leurs sources.
- Icn et Icu restent séparés par norme et tension. Pour le 410705, le contexte 230 V est établi par lecture croisée de la tension assignée et du pouvoir de coupure EN 61009 de la même offre. Les propositions à 400 V des 406782/406783 restent non sélectionnées.
- Les plages de la borne 037162 distinguent les fils souples avec et sans embout. Les autres types de conducteurs ne sont pas déclarés qualifiés dans ce pilote.
- La cloison 037550 est rattachée uniquement aux blocs Viking **3** à vis, 1 entrée/1 sortie et pas 5/6/8/10 mm explicitement décrits.
- Les prises dont le standard n'est pas prouvé, les plaques sans compatibilité précise, la contradiction de norme du A9P22610 et celle de couleur/RAL du MUR35031 restent en attente. Les cosses, embouts, certains appareils industriels, tableaux équipés et luminaires nécessitent une classification hors du périmètre actuel. D'autres références attendent simplement leur revue complète.

La nouvelle collecte réseau n'a rafraîchi qu'une référence, puis a rencontré des erreurs d'accès. Elle n'est pas mélangée au lot approuvé : celui-ci repose sur les preuves fournies du **28 octobre**, sans prétendre à une nouvelle vérification fabricant en ligne.

## Contrôles effectués

- **46 tests Python et 74 tests PostgreSQL réussis**. Le test du lot réel couvre préparation, qualification privée, publication, rejeu sans doublons et refus d'une prise incomplète. Une republication explicite actualise la date de qualification ; le simple réimport la conserve.
- Dans Supabase, les 9 diagnostics serveur sont valides. Avant publication, le rôle visiteur voyait 0 produit ; après publication, il voit 9 produits et 81 valeurs validées.
- Un client connecté voit 16 offres, mais aucune collecte privée ni observation non publiée. La recherche renvoie 9 produits et retrouve la référence 406783.
- Les **2 utilisateurs, 1 client et 3 fournisseurs** sont conservés. Aucun prix personnel, tarif commun ou compte fournisseur n'a été ajouté. Toutes les tables publiques conservent leur RLS.

Résultats chiffrés : [evidence.json](../catalog/imports/20261030-pilot/evidence.json). Aucune nouvelle migration de schéma n'était nécessaire.

## Reproduire le lot

Le [paquet du pilote](../releases/lot-pilote-20261030.zip) contient la collecte originale, le manifeste, les fichiers v3, les scripts SQL et les outils de reconstruction. Après extraction, dans son dossier :

```sh
python scripts/build_reviewed_pilot.py source-products-v2.json review-manifest.json --out regenerated
```

L'empreinte SHA-256 verrouille la revue sur ce fichier exact : une nouvelle collecte exige une nouvelle revue. La génération ne se connecte pas à Supabase. Les scripts SQL séparent préparation, qualification privée et publication explicite. Le lot décrit ici est **déjà importé**.

## Étape suivante

Raccorder la recherche, les filtres et les fiches produit du site à `valeurs_catalogue`, avec les unités, ensembles, intervalles et contextes. La recherche actuelle retrouve les produits et leurs catégories, mais ses attributs techniques viennent encore de l'ancienne table et restent vides pour ce lot. Ensuite, compléter progressivement les 91 références et les familles absentes ; les quantités décimales du panier restent un chantier distinct.
