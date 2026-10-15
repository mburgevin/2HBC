# Audit de la structure BDD 2HBC — catégories, filtres et recherche

Audit du 15 octobre 2026. Projet Supabase : `gueuqeqyshhhmxbsiuxg`.
Code examiné : `b3c337689e56f3123099d281a052226cad7922ed`, branche `feat/auto-cart-prototype`.

**Décision : conserver le socle actuel et l'étendre par migrations additives.**
Le modèle convient à l'identité des produits, aux offres et aux paniers. Il ne suffit
pas encore pour une recherche métier avec catégories et filtres techniques.
Les principaux travaux concernent les contrôles de publication, la classification,
les attributs structurés, les unités de vente et le moteur de recherche.

Cet audit n'applique aucune migration et ne modifie aucune donnée distante.
Les écritures de reproduction ont lieu uniquement dans une base PostgreSQL embarquée
éphémère. Aucune donnée personnelle, aucun prix de client, aucun identifiant de
connexion ni cookie fournisseur n'a été extrait.

## 1. Périmètre et preuves

Inspection distante des colonnes, contraintes, index, politiques RLS, fonctions,
extensions et migrations ; mesures agrégées du catalogue ; requêtes de lecture sous
rôles visiteur et connecté avec claims synthétiques ; EXPLAIN ANALYZE d'une recherche.
Lecture des migrations en attente, de l'import réel, du collecteur, des appels React
et du protocole de l'extension.

Les lectures SQL initialement empêchées par une limite d'utilisation ont abouti à
la reprise du 15 octobre. Les constats ci-dessous reposent donc sur l'état distant
relevé à la reprise.

Fichiers de preuve :

- [evidence.json](evidence.json) : schéma, droits, agrégats et plans d'exécution.
- [read-only-queries.sql](read-only-queries.sql) : requêtes principales de lecture.
- [local-audit.mjs](local-audit.mjs) : reproductions isolées et contrôle des migrations.
- [local-results.json](local-results.json) : résultats des 15 vérifications locales.

Les tests locaux reconstituent le schéma des deux migrations appliquées, le seed,
les trois pilotes et l'import réel des 100 produits. Les comptes utilisés sont
synthétiques. Ces tests complètent l'audit distant ; ils ne constituent pas un test
de charge ou une validation du parcours navigateur déployé.

## 2. État réel

| Élément | État vérifié |
|---|---|
| PostgreSQL | 17.6 |
| Tables métier dans public | 10, toutes avec RLS activée |
| Contraintes / clés étrangères / index | 52 / 13 / 26 |
| Politiques RLS / fonctions métier | 20 / 3 |
| Fonctions métier SECURITY DEFINER | 0 |
| Vues et triggers métier | Aucun |
| Produits | 114 : 103 vérifiés et 11 anciennes démonstrations |
| Offres | 148 : 119 vérifiées, 29 anciennes démonstrations |
| Offres vérifiées par fournisseur | 69 Rexel, 50 Sonepar |
| Catégories / produits classés | 0 / 0 |
| Produits vérifiés avec photo | 102 sur 103 |
| Description, spécificité et PDF des produits vérifiés | 0 renseigné |
| EAN valides des produits vérifiés | 103 sur 103 |
| Doublons normalisés marque/référence, EAN ou code fournisseur | Aucun détecté |
| Offres vérifiées avec prix partagé | 0 ; prix NULL volontairement |
| Offres de démonstration avec prix | 18 sur 29 |

Une photo désigne ici une URL enregistrée ; la disponibilité actuelle de chaque image
n'a pas été retestée. La validité mathématique d'un EAN ne certifie pas son attribution
à un produit ; les sources de collecte restent nécessaires.

Toutes les clés étrangères existantes ont un index utilisable par leur première
colonne. Aucune contrainte non validée n'a été relevée.

## 3. Ce qui doit être conservé

| Ensemble | Décision |
|---|---|
| produits | Identité fabricant, nom, EAN et contenu commun : conserver les IDs et les données. |
| fournisseurs / produits_fournisseurs | Bonne séparation entre produit et code article distributeur. Conserver les IDs des offres. |
| categories | Conserver parent_id : une arborescence simple suffit au MVP. |
| paniers / articles_panier | Conserver la référence à l'offre choisie et l'ajout atomique. Un panier actif par utilisateur convient au MVP. |
| prix_personnels | Conserver la séparation par client, offre, contexte, quantité et date. Aucun prix personnel dans le catalogue commun. |
| clients | Conserver le lien vers Supabase Auth ; aucune table de mots de passe fournisseur à ajouter. |
| besoins_clients / segments_clients | Conserver ; ce ne sont pas les tables de classification des produits. |

Les prix et paniers d'un autre client restent inaccessibles dans les reproductions
locales, y compris pour un administrateur applicatif tiers concernant les prix.
Les rôles d'infrastructure `postgres` et `service_role` restent privilégiés.
Un faux rôle admin dans `user_metadata` n'accorde aucun droit.

Le dossier `backend/` décrit un ancien prototype SQLite et n'est pas le schéma
utilisé par le site hébergé. Les futures évolutions doivent viser Supabase.

## 4. Constats prioritaires

### A. Publication et données de démonstration — à corriger avant ouverture du catalogue enrichi

Le RPC actuel renvoie 103 produits, mais une lecture directe de `produits` sous
le rôle visiteur renvoie 114 produits, dont les 11 démonstrations.
L'ancien RPC `rechercher_catalogue` renvoie aussi les 114 produits.
Un compte connecté peut lire les 29 offres non vérifiées ; l'ajout d'une telle offre
par `ajouter_au_panier` est accepté dans la reproduction locale.

Il s'agit d'une incohérence de publication, pas d'une fuite constatée de prix personnels.

Prévoir une règle de publication commune aux lectures directes et aux deux RPC.
L'écriture dans le panier doit également contrôler le statut du produit et de l'offre :
protéger le seul bouton React ou le seul RPC d'ajout ne suffit pas, puisque la table
des lignes de panier accepte aussi des écritures directes autorisées par RLS.

Conserver l'accès administrateur aux brouillons et définir le traitement des offres
retirées déjà présentes dans les paniers : afficher une indisponibilité explicite,
sans supprimer les lignes ou casser les références. Une règle de lecture ciblée ou
un RPC respectant la propriété du panier devra couvrir ce cas.

Séparer progressivement identité vérifiée, publication et état de classification.
Un produit réel encore à classer n'est pas un faux produit et ne doit pas être fusionné
avec les données de démonstration.

### B. Intégrité des identités — corrections déjà préparées, pas encore en ligne

Le schéma distant autorise actuellement :

- un GTIN à neuf chiffres ou avec une mauvaise clé ;
- le même EAN pour deux identités distinctes ;
- des doublons de marque/référence différant seulement par casse ou espaces ;
- le même code fournisseur rattaché à plusieurs produits ;
- un produit déclaré vérifié sans source, date ou marque.

Ces cas ont été reproduits localement. Aucun de ces défauts n'a été trouvé dans
les identités du catalogue réel importé ; le problème est l'absence de garanties
pour les écritures futures.

La migration `catalogue_integrity_import` renforce déjà ces contrôles.
Garder les références en texte, avec leurs zéros initiaux et leur ponctuation.
La normalisation destinée à la recherche ne doit pas devenir une fusion approximative
des identités.

### C. Catégories — table récupérable, règles manquantes

La contrainte actuelle interdit seulement qu'une catégorie soit son propre parent.
Un cycle de deux catégories est accepté ; des catégories racines équivalentes le sont aussi.

Compléter avec :

- un code/slug stable et unique, nom non vide, ordre d'affichage et état actif ;
- unicité des noms normalisés entre catégories sœurs, y compris à la racine ;
- prévention des cycles indirects ;
- règle d'affectation à une catégorie terminale pertinente ;
- état explicite « à classer », sans remplir arbitrairement les catégories manquantes.

La prévention des cycles doit gérer les modifications concurrentes, par exemple avec
un verrou transactionnel de l'arbre et un contrôle récursif. Un simple CHECK sur la ligne
ne contrôle pas toute la hiérarchie.

Conserver une catégorie principale par produit au MVP. Les regroupements transversaux
« chantier », « promotion » ou « sélection » pourront devenir des collections séparées.
Une structure d'arbre `parent_id` avec requête récursive suffit à ce stade ; aucune
nécessité démontrée d'ajouter immédiatement ltree, une table de fermeture ou une profondeur figée.

### D. Caractéristiques et marques — manque bloquant pour les filtres

`specificite text` ne permet pas des filtres numériques et des valeurs normalisées.
Les propriétés électriques, dimensions, couleurs et gammes doivent être structurées.

Modèle proposé, à implémenter après cet audit :

| Objet | Contenu et règles principales |
|---|---|
| marques | Identité de marque stable, nom et alias contrôlés ; rattachement progressif des produits. |
| gammes | Gamme rattachée à sa marque ; unicité par marque. |
| attributs | Code stable, libellé, type de valeur, unité canonique éventuelle. |
| attribut_options | Valeurs autorisées d'un attribut à choix : couleur, courbe, mode de pose, etc. |
| categorie_attributs | Attributs pertinents pour une famille terminale, ordre, caractère filtrable et importance. |
| produit_attributs | Valeurs typées, source, date et statut de validation par produit. |
| categories_fournisseurs | Fournisseur, code et chemin d'origine, correspondance 2HBC validée lorsque possible. |
| collectes_catalogue | JSON brut de collecte et provenance privés ; table déjà prévue par une migration en attente. |

Pour les valeurs, utiliser des colonnes adaptées (nombre, booléen, option contrôlée,
et intervalle si le besoin est confirmé), avec exactement une représentation valide.
L'absence de valeur, « non applicable » et false/0 doivent rester distincts.
La cohérence option/attribut et produit/famille doit être imposée par des clés composites
ou des triggers ciblés ; un CHECK interrogeant une autre table ne suffit pas.

Pour le MVP, les catégories terminales peuvent porter les définitions techniques.
Si la navigation évolue vers plusieurs classements indépendants, isoler alors les
classes techniques dans un référentiel distinct. Prévoir des codes ETIM et leur version
lorsqu'ils sont connus, sans imposer tout ETIM à la première livraison.

Ne pas faire une colonne de `produits` pour chaque caractéristique imaginable.
Conserver le JSON source en préparation ; les facettes publiées doivent utiliser des
valeurs normalisées. Par exemple 2,5 mm² et 2.5 mm² peuvent partager la même valeur
canonique ; 1P+N et 2P ne doivent pas être considérés identiques.

Un chemin fournisseur large ne suffit pas à attribuer automatiquement une catégorie
terminale. Les correspondances ambiguës restent à revoir. Le contrat JSON et les listes
de champs autorisés du collecteur/importeur devront évoluer ensemble, avec compatibilité
des anciennes collectes.

### E. Recherche — changement de requête et d'index nécessaire

La requête actuelle applique `position(lower(terme) in lower(nom || référence || marque))`.
Elle n'exploite aucun index de recherche textuelle ; l'index B-tree sur (nom,id) ne
résout pas cette recherche de sous-chaîne.

Contrôles distants en rôle connecté :

| Requête | Produits renvoyés sur la première page |
|---|---:|
| 600335 | 1 |
| LEG600335 | 0 |
| 3414971006102 | 0 |
| prise Legrand | 0 |
| prise | 24 |

Le plan du corps SQL lit les 114 produits et retient 26 correspondances avant limite.
Le RPC mesuré a pris environ 3,24 ms côté PostgreSQL ; le corps SQL explicité environ
0,48 ms, sur ce petit jeu et dans ce contexte. Cela ne mesure ni le réseau, ni le
navigateur, ni la charge concurrente. Il n'y a pas de preuve d'une lenteur actuelle ;
l'insuffisance fonctionnelle est déjà démontrée.

Recommandation MVP : rester sur PostgreSQL/Supabase.

- Résolution exacte prioritaire des références fabricant, codes fournisseur et GTIN.
- Recherche lexicale pondérée dans nom, marque, gamme et termes contrôlés.
- Index GIN sur le document textuel ; normalisation des accents et variantes maîtrisées.
- Tolérance aux fautes sur les mots via pg_trgm si nécessaire ; jamais comme preuve
  d'identité ou substitution silencieuse d'une référence.
- Attributs numériques traités comme filtres, avec leurs unités.
- RPC versionné, paramètres de filtre validés et bornés, total et facettes calculés
  sur l'ensemble des résultats autorisés avant pagination.
- OU au sein d'un filtre multi-sélection, ET entre filtres ; définir les compteurs
  de facettes pour conserver les choix alternatifs utiles.
- Pagination stable, puis curseur si les mesures rendent les pages profondes coûteuses.

L'index d'identité (marque,référence) n'est pas optimisé pour une recherche de référence
sans marque ; prévoir un accès par référence normalisée. Même remarque pour le code
fournisseur recherché sans connaître le fournisseur. Les index seront choisis à partir
des requêtes réellement exposées.

Un vecteur textuel généré ne peut pas directement agréger les données d'autres tables :
si marque, gamme ou catégories contribuent au document, il faut maintenir explicitement
la projection lors de leur modification. Les index doivent utiliser exactement les mêmes
expressions normalisées que les requêtes.

Ne pas introduire un moteur externe, du partitionnement ou un cache commun des prix
personnels sans mesure qui en justifie le coût.

### F. Unités, conditionnements et offres — nécessaire pour étendre l'auto-panier

Le panier et les demandes de prix utilisent des quantités entières.
Le conditionnement est un texte libre. Le prix partagé est à deux décimales et ne porte
ni unité ni base tarifaire ; les observations personnelles ont déjà quatre décimales,
une base et une unité.

Avant de couvrir les câbles, lots et ventes à la coupe, formaliser par offre :

- unité de commande et unité comparable ;
- quantité contenue, conversion vérifiée, minimum et multiple de commande ;
- précision et quantité décimale uniquement lorsque réellement autorisées ;
- source et état de validation des règles de vente.

La contrainte unique (produit,fournisseur) autorise une seule offre par paire.
La conserver pour le périmètre actuel, puis la revoir si un même article existe sous
plusieurs codes ou modes de vente chez un fournisseur. Définir d'abord le modèle des
variantes/conditionnements et du GTIN concerné ; ne pas simplement supprimer l'unicité.
Les IDs d'offres sont référencés par les paniers et les prix privés et doivent être conservés.

Un changement SQL de integer vers numeric ne suffit pas : le site et l'extension
refusent eux aussi les quantités non entières. L'évolution doit être coordonnée et testée.
Une information de conditionnement inconnue reste inconnue, sans conversion automatique.

### G. Prix privés et sécurité — socle correct, précautions pour la future recherche

Les dix tables ont la RLS active. Les fonctions métier sont SECURITY INVOKER avec
search_path fixé. Les politiques utilisent `app_metadata` pour l'administration.
Un visiteur voit zéro offre et n'a pas de droit SELECT sur les observations privées.

Le futur tri par prix personnel devra lire uniquement les observations de l'utilisateur,
pour le contexte et la quantité compatibles, non expirées, et avec des unités comparables.
La RLS permet de lire son historique expiré : c'est cohérent, mais elle ne remplace pas
le filtre de fraîcheur d'une recherche de prix courant.

L'empreinte de contexte actuelle inclut un identifiant aléatoire propre à chaque lecture.
Elle ne constitue pas une clé de compte durable permettant de réutiliser librement les
observations d'une lecture à l'autre. Définir un protocole de contexte vérifiable avant
tout cache interlecture ou tri global. Aucun cookie ou mot de passe ne doit être stocké.

Les observations venant du navigateur ne sont pas des attestations tarifaires signées.
Les prix négociés contractuels 2HBC devront avoir une origine et une portée distinctes.

`clients.segment_id` est actuellement modifiable par le propriétaire du profil.
Cela ne donne pas aujourd'hui de remise supplémentaire, mais ce champ ne doit pas
devenir une source d'autorisation pour des tarifs réservés sans protection administrative.

## 5. Optimisations confirmées par Supabase

- Cinq tables ont une politique admin FOR ALL qui recouvre une politique de lecture.
  Les séparer par opération évite ce travail redondant. La migration d'intégrité le prévoit.
  [Explication Supabase](https://supabase.com/docs/guides/database/database-linter?lint=0006_multiple_permissive_policies).
- Huit index sont signalés non utilisés. Les garder : l'activité du pilote et les
  catégories encore vides ne justifient pas de supprimer les index de relations.
  [Interprétation de l'alerte](https://supabase.com/docs/guides/database/database-linter?lint=0005_unused_index).
- Les 13 clés étrangères sont déjà couvertes par un index en première colonne.
  Ne pas ajouter un deuxième index identique à celui couvert par une contrainte unique.
- La protection Auth contre les mots de passe compromis est désactivée.
  [Réglage et documentation](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection).
  Ce point est distinct de la classification.
- Le serveur est en PostgreSQL 17.6. Supabase annonce une mise à jour mineure 17.11 :
  [note de maintenance officielle](https://supabase.com/changelog/postgres-15-19-17-11-breaking-changes).
  Planifier la maintenance et ses contrôles via la plateforme ; aucune mise à niveau
  n'a été déclenchée. Aucun index ltree/btree_gist n'est présent dans le schéma audité.

Pour les nouvelles facettes, indexer les clés d'attribut et leurs valeurs typées selon
les filtres effectivement exposés. Éviter un index pour chaque champ par défaut.
Définir également la conservation des observations de prix expirées avant d'organiser
une purge ; aucune donnée privée n'a été supprimée durant cet audit.

## 6. Migrations : dépôt et cloud

| Migration | Cloud au 15 octobre | Résultat local sur le catalogue importé |
|---|---|---|
| initial_mvp | Appliquée | Base de la reproduction |
| personal_supplier_prices | Appliquée | Base de la reproduction |
| catalogue_integrity_import | Absente | Application réussie, IDs et volumes conservés |
| catalogue_images | Absente | Application réussie après la précédente |

Les deux migrations absentes ne créent pas les catégories métier, ne collectent pas
les caractéristiques, ne préviennent pas les cycles indirects et ne ferment pas les
accès historiques aux démonstrations. La recherche reste une recherche littérale,
avec seulement l'ajout de l'EAN. Elles sont utiles mais ne suffisent pas au chantier.

La trace complète de l'import actuel est conservée dans
[catalog/imports/20261015](../../../catalog/imports/20261015/README.md).
La table de préparation et les nouvelles colonnes de provenance photo n'existent pas
encore dans le cloud ; il faudra les alimenter à partir de cette trace après migration.

## 7. Ordre d'implémentation recommandé

1. Préparer une sauvegarde/restauration vérifiable pour la migration, établir l'état
   de référence des IDs, puis appliquer les migrations d'intégrité et d'images par
   le mécanisme de migration prévu. Elles ont passé le contrôle local, pas encore cloud.
2. Harmoniser publication, lectures directes, ancien RPC, ajout au panier et traitement
   des lignes historiques ; tester visiteurs, clients et administrateurs.
3. Étendre les catégories et créer les dictionnaires de marques/gammes/attributs.
   Ajouter les colonnes de liaison de façon nullable, puis enrichir les données.
4. Versionner le contrat du collecteur/importeur. Relever classification, caractéristiques
   et provenance, valider les correspondances et renseigner progressivement les 103 produits.
5. Ajouter une nouvelle recherche avec facettes et index mesurés ; adapter l'interface.
   Garder l'ancien contrat pendant le basculement, puis retirer ses usages après vérification.
6. Qualifier les unités de vente, quantités et conditionnements avant d'élargir l'auto-panier
   aux familles qui le nécessitent. Réserver les stocks/prix temps réel à des données
   effectivement observées ou fournies par une intégration.

Pas de recréation de base, pas de suppression du catalogue et pas de renumérotation
des produits/offres. Ne pas rendre immédiatement la catégorie obligatoire : les 103
produits existants sont encore non classés. Les migrations devront être additives et
les anciens champs conservés jusqu'au basculement des consommateurs.

## 8. Conditions de validation de la prochaine livraison

- Une référence fabricant, un EAN et les deux codes distributeur retrouvent la même
  fiche lorsque ces correspondances existent.
- Une recherche multiterme indépendante de l'ordre trouve les produits pertinents.
- Les filtres sont propres à la famille et les compteurs portent sur tout le résultat,
  avec les mêmes règles de visibilité que les produits.
- Catégories cycliques, doublons normalisés et valeurs techniques incohérentes refusés.
- Aucun mélange entre pièces, boîtes, mètres et unités de prix.
- Démonstrations/brouillons hors des accès clients ordinaires, sans casser leurs paniers.
- Aucun accès croisé aux prix personnels ; les observations expirées/contextes différents
  ne deviennent pas des prix courants.
- IDs existants, quantités de paniers et données privées préservés.
- Mesures de recherche sur un jeu représentatif, pas seulement 103 produits.
- Contrôles Supabase sécurité/performance refaits après les migrations distantes.

Les quinze contrôles locaux réussis dans cet audit incluent des tests qui attendent
l'acceptation d'une donnée invalide afin de reproduire une lacune. Leur réussite ne
signifie donc pas « quinze protections déjà actives ».

## Références techniques consultées

- [Recherche textuelle Supabase](https://supabase.com/docs/guides/database/full-text-search).
- [PostgreSQL 17 : pg_trgm et index de similarité](https://www.postgresql.org/docs/17/pgtrgm.html).
- [PostgreSQL 17 : contraintes, clés étrangères et limites des CHECK](https://www.postgresql.org/docs/17/ddl-constraints.html).
- [Supabase : sécurité au niveau des lignes](https://supabase.com/docs/guides/database/postgres/row-level-security).
- [Changelog Supabase](https://supabase.com/changelog).
