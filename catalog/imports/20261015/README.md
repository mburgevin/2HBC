# Import du catalogue — 15 octobre 2026

Publication demandée explicitement par Mathias après réception de la collecte 0.3.0.
Le fichier source est `products(2).json`, collecte terminée le 14 octobre à
22:23:26 UTC. `products.json` conserve les 100 fiches et toutes leurs sources ;
seul `review_status` est passé de `pending` à `approved` pour cette publication.
L'approbation porte sur l'import du catalogue demandé, après validation technique
des identifiants, de la structure et des correspondances. Elle ne certifie pas
les conditionnements ni des prix de compte fournisseur.

## Résultat distant

- Projet Supabase : `gueuqeqyshhhmxbsiuxg` (2HBC).
- 100 nouveaux produits, 113 offres : 66 Rexel et 47 Sonepar.
- 99 produits avec une URL photo ; 112 URL photo fournisseur dans la source.
- 13 produits du lot ont les deux codes fournisseur.
- Tous les nouveaux prix sont `NULL` ; `nature_prix = public` décrit le type
  d'offre et ne signifie pas qu'un prix public a été collecté.
- Base après import : 114 produits, dont 103 publiés dans le catalogue réel,
  et 148 offres, dont 119 références vérifiées. Les 11 anciens produits de
  démonstration restent hors du catalogue réel.
- Les 14 produits et 35 offres préexistants sont inchangés.
- Aucun doublon EAN ou marque/référence fabricant détecté.

La référence Schneider Electric `R9HPNFC15137P` reste sans photo.

## Exécution

`import.sql` a été exécuté en une seule transaction dans le schéma déjà en ligne.
Il contient uniquement des opérations sur les données et des contrôles de conflit,
sans création de table, fonction, colonne ou changement de droits. Les identifiants
de base sont résolus à partir des références et ne sont pas imposés.
Un réimport identique ne modifie ni les prix ni les lignes existantes. Une identité,
un EAN ou un code fournisseur contradictoire fait annuler le lot entier.

La nouvelle tentative de `apply_migration` a échoué avec
`Invalid or expired requestState`. Les migrations
`20261012163203_catalogue_integrity_import.sql` et
`20261013131653_catalogue_images.sql` restent donc à appliquer. Le schéma existant
possède déjà `produits.image_url`, les codes fournisseur, les liens et les indicateurs
de vérification. La provenance complète et les deux photos éventuelles sont conservées
dans le JSON de ce dossier ; les nouvelles colonnes de provenance image et la table
de préparation privée ne sont pas encore présentes dans Supabase.

## Contrôles

- Validation des 100 fiches par `prepare_catalogue_import.validate(..., approve=True)`.
- Exécution PostgreSQL locale : lot complet, réimport sans doublon, et annulation
  intégrale sur collision volontaire de code fournisseur.
- Comparaison distante : 100 produits et 113 offres correspondent exactement au
  fichier source ; 99 photos renseignées.
- RPC publique : 103 produits, 102 avec photo, offres masquées pour les visiteurs.
- Contrôle du rôle connecté par claims SQL simulés, sans création de compte ni
  accès aux prix personnels : la référence Legrand `600335` expose ses deux offres.
- Contrôle de sécurité Supabase : aucune alerte sur les tables/RLS ; avertissement
  préexistant sur la protection contre les mots de passe compromis désactivée.
  Documentation : https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection

SHA-256 de `products.json` :
`3c100374da2032d689949a2acb2f812f4a529a150a35922bdb6205e5e3074de1`.
