# Collecter 100 produits pour le pilote 2HBC

Le programme autonome `scripts/collect_catalogue.py` vise 100 **produits distincts**
à partir de fiches publiques Rexel France et Sonepar France. Python 3.10 ou plus
récent suffit ; aucune bibliothèque à installer, aucune clé et aucun compte requis.
Il fonctionne aussi téléchargé seul, en dehors du dépôt.

## Lancer sous Windows

1. Télécharger le fichier `collect_catalogue.py` depuis la branche
   `feat/auto-cart-prototype`, ou récupérer cette branche du dépôt.
2. Installer Python si nécessaire depuis https://www.python.org/downloads/windows/.
3. Ouvrir PowerShell dans le dossier contenant le fichier puis exécuter :

```powershell
py collect_catalogue.py --limit 100 --out catalogue-2hbc
```

Si le dépôt complet est ouvert à sa racine :

```powershell
py scripts/collect_catalogue.py --limit 100 --out catalogue-2hbc
```

Sur macOS/Linux, remplacer `py` par `python3`. Il faut une connexion Internet.
Le programme attend au minimum trois secondes entre deux requêtes sur un même
domaine, ou davantage si robots.txt le demande. Prévoir plusieurs minutes ; le
nombre de fiches rejetées et la vitesse des fournisseurs déterminent la durée.

## Résultat et reprise

Le dossier `catalogue-2hbc` contient :

- `products.json` : produits candidats, références fabricant, EAN, marque, nom,
  références distributeur, URL finales, conditionnement lorsqu’il est identifiable,
  catégorie de découverte, date et empreinte de la source, **photo principale par
  fournisseur lorsqu'elle est identifiée** (`offers[].image_url`).
- `catalogue.json` : récapitulatif lisible, avec `manufacturer_reference`, `ean`,
  `rexel_code`, `sonepar_code`, `image_url`, les deux pages sources et les deux photos
  fournisseur. Un champ inconnu vaut `null` ; `missing_fields` liste ce qui manque.
  Ce fichier sert au contrôle ; **l'importeur utilise toujours `products.json`**.
- `report.json` : nombre réellement obtenu, objectif atteint ou non, nombre de
  produits présents chez les deux fournisseurs, couverture photo
  (`products_with_image`, `products_without_image`, `images_by_supplier`), nombre
  avec **les deux codes et une photo** (`both_codes_and_image`), codes manquants
  par fournisseur, fiches rejetées et motifs. `complete` indique seulement que le
  nombre de produits demandé est atteint, pas que toutes les références sont doublées.
- `state.json` : progression, file de pages restantes et produits déjà collectés.

**Relancer exactement la même commande reprend la collecte.** Ctrl+C conserve aussi
la page interrompue. Pour recommencer complètement, choisir un nouveau dossier
`--out` ; ne pas supprimer une progression utile.

Le budget par lancement est de 300 pages, toutes phases confondues. Après avoir
atteint le nombre de produits, le mode `both` continue sur les fournisseurs dont
des codes manquent, dans une limite de **100 pages supplémentaires** incluse dans
ce budget total. Il s'arrête plus tôt si tous les codes sont trouvés ou si aucune
page disponible ne reste. Pour poursuivre avec un budget supérieur :

```powershell
py collect_catalogue.py --limit 100 --max-pages 500 --enrich-pages 200 --out catalogue-2hbc
```

Un fournisseur qui répond 401/403/429/503 est suspendu pour cette exécution. Il n’y
a ni contournement du CAPTCHA, ni rotation de proxy, ni récupération de session.
Ne pas relancer en boucle après un blocage ; attendre ou utiliser un flux autorisé.
La sortie vaut 0 si l’objectif est atteint, 2 si le résultat est partiel et 130 après
interruption. Le rapport fait foi : **le programme ne garantit pas d’atteindre 100**
si les pages sont bloquées, rendues uniquement en JavaScript ou modifiées.
`--enrich-pages 0` désactive la phase supplémentaire. En mode fournisseur unique,
le script s'arrête au nombre de produits demandé. Les autres produits rencontrés
pendant l'enrichissement sont différés dans `state.json`, sans dépasser l'objectif ;
ils redeviennent candidats si une exécution ultérieure augmente `--limit`.

## Sélection de produits

Les catégories initiales couvrent appareillage, protection/distribution, connectique,
fils et câbles, éclairage et outillage. Elles servent de points de départ ; aucune
répartition par catégorie ou marque n’est garantie. Le programme suit uniquement
les liens de produits et la pagination visible de la même catégorie. Il ne visite
pas les pages de connexion, les paniers ou les API privées.
Les visites alternent entre fournisseurs tant qu'une page est disponible pour chacun.

Pour limiter la collecte à Sonepar ou Rexel, utiliser un dossier distinct :

```powershell
py collect_catalogue.py --supplier sonepar --limit 100 --out catalogue-sonepar
```

Pour une sélection métier précise, créer `urls.txt` avec une URL publique de produit
ou de catégorie par ligne, puis :

```powershell
py collect_catalogue.py --urls urls.txt --limit 100 --out catalogue-selection
```

Les paramètres autres que `page` sont refusés. Les liens de suivi marketing doivent
être retirés de la liste. Les URL sans paramètres sont préférables.

Pour tester rapidement les trois références pilotes avec leurs six fiches :

```powershell
py scripts/collect_catalogue.py --urls catalog/collector-pilot-urls.txt --limit 3 --max-pages 10 --out catalogue-pilote
```

Avec le script téléchargé seul, télécharger aussi `collector-pilot-urls.txt`, puis
retirer `scripts/` et `catalog/` de cette commande. Ajouter les URL connues des deux
fournisseurs à une sélection augmente les chances de retrouver les deux codes.

## Qualité des données et suite dans 2HBC

Un produit n’est accepté que si marque, référence fabricant, EAN13 valide, titre et
référence fournisseur sont lisibles et cohérents. Les références restent des chaînes,
avec leurs zéros initiaux. Un rapprochement Rexel/Sonepar exige **le même EAN, la même
marque et la même référence fabricant**, sans rapprochement approximatif par nom.
Les conflits sont signalés. La ponctuation des marques n’est pas arbitrairement effacée.

100 produits collectés ne signifie pas 100 produits disponibles chez les deux
fournisseurs. La phase supplémentaire parcourt les pages publiques découvertes :
ce n'est ni un moteur de recherche par EAN, ni une garantie de correspondance.
Le code manquant n'est jamais déduit du nom, de la référence fabricant ou d'un
préfixe supposé. Les recherches internes, dont certaines sont exclues par robots.txt,
ne sont pas utilisées. Une correspondance reste absente si sa fiche n'est pas trouvée.

Exemple vérifié pour un même produit :

| Champ | Valeur |
| --- | --- |
| Marque | Legrand |
| Référence fabricant | `069511L` |
| EAN | `3414971877986` |
| Code Rexel | `LEG069511L` |
| Code Sonepar | `00001187798` |

Les identifiants numériques dans les URL média Rexel sont des identifiants de page,
pas les codes article à envoyer au panier. `offers[].reference` conserve le code
article propre au fournisseur ; `reference` à la racine reste la référence fabricant.

Chaque produit porte `review_status: pending`. Avant intégration dans Supabase,
contrôler les correspondances, les variantes, les conditionnements et les droits
de réutilisation. **Le collecteur n’exécute aucun SQL et n’écrit pas dans Supabase.**
Ne pas remplacer directement le fichier pilote déjà validé par ce résultat : son
importeur historique marque les lignes comme vérifiées. Utiliser le nouvel importeur
ci-dessous, qui correspond exactement au JSON produit par le collecteur.

## Préparer puis publier dans Supabase

**Prérequis administrateur :** appliquer une seule fois la migration
`supabase/migrations/20261012163203_catalogue_integrity_import.sql` au projet 2HBC.
Au 12 octobre 2026, elle est testée mais son application via le connecteur a échoué
(`Invalid or expired requestState`). Elle n'est pas encore dans la base distante.
Ce fichier peut être exécuté en entier dans le SQL Editor Supabase par un
administrateur ; ne pas réexécuter les anciennes migrations ou réinitialiser la base.
Pour les collectes avec photos, appliquer ensuite
`supabase/migrations/20261013131653_catalogue_images.sql`. La première migration
étant toujours bloquée au 13 octobre, cette seconde migration reste également
en attente. L'ordre est nécessaire : la seconde étend la fonction créée par la première.

Télécharger aussi `scripts/prepare_catalogue_import.py` (Python standard, autonome),
ou travailler depuis la racine du dépôt. Préparer le SQL sans aucun accès réseau :

```powershell
py scripts/prepare_catalogue_import.py catalogue-2hbc/products.json --out catalogue-2hbc/preparation.sql
```

Exécuter ensuite `preparation.sql` dans le SQL Editor du projet 2HBC. Les fiches sont
stockées dans `collectes_catalogue`, accessible aux seuls administrateurs. Elles ne
créent encore aucun produit visible sur le site. Le programme n'a besoin d'aucune clé
Supabase. Ne jamais lui fournir une clé `service_role` ou un mot de passe fournisseur.

Pour publier :

1. Copier les fiches retenues dans `catalogue-2hbc/products-reviewed.json`.
2. Vérifier sur les sources la marque, la référence fabricant, l'EAN, la variante,
   la référence fournisseur et le conditionnement. Contrôler les droits de réutilisation.
3. Passer uniquement les fiches relues à `"review_status": "approved"`.
4. Générer le SQL de publication puis l'exécuter dans le SQL Editor :

```powershell
py scripts/prepare_catalogue_import.py catalogue-2hbc/products-reviewed.json --approve --out catalogue-2hbc/publication.sql
```

Sans `--approve`, le SQL reste en mode préparation, même si les fiches sont marquées
`approved`. Avec `--approve`, une seule fiche encore `pending` fait refuser tout le
fichier. La base contrôle aussi le contenu, les sources et les droits de l'appelant.

Les réimports sont idempotents : pas de nouveau produit/offre pour une correspondance
identique et aucun prix écrasé. Un EAN contradictoire, une référence fournisseur déjà
liée à un autre produit, ou un changement d'URL déjà associée fait annuler le lot.
Résoudre le conflit explicitement ; ne pas supprimer les contraintes pour le forcer.
Une nouvelle date/empreinte de collecte crée une nouvelle trace privée sans dupliquer
les produits. L'empreinte conserve une trace technique, elle ne certifie pas la véracité
du contenu. Les dates de collecte et de validation restent distinctes.

Les catégories de découverte sont conservées dans la trace, sans attribution
automatique à la taxonomie métier. PDF, descriptions et quantités de vente
normalisées ne sont pas inventés. Les prix des nouvelles offres restent `NULL`.

## Photos Rexel et Sonepar

La collecte recherche désormais les photos **sur les deux fournisseurs** :

- Rexel : image marquée `Main media`, dont l'identifiant média correspond exactement
  à celui de la fiche produit. Route publique observée : `api.rexel.fr/media/api/fr/content/…`.
- Sonepar : première image explicitement étiquetée « Vignette Photo produit 1 »,
  puis sa version pleine taille présente dans la page. CDN observé sur les fiches :
  `fra-connect.mo.cloudinary.net/PRODUCT/IMAGE/…`.

Les logos, pictogrammes, scènes d'ambiance et produits voisins ne servent pas de
photos de remplacement. Une image inconnue n'est pas devinée depuis la référence.
Les routes média et leurs paramètres publics sont contrôlés ; aucun jeton ou
cookie n'est conservé. Le collecteur stocke des liens, pas les fichiers image.

La photo reste associée à son offre, donc au fournisseur, à sa page source et à sa
date de collecte. À la publication, la première photo disponible remplit
`produits.image_url`, avec `image_source_url` et `image_verifiee_le`. Une photo
existante différente reste conservée. L'absence de photo n'empêche pas l'import
des références : elle est comptée dans le rapport et le site affiche « Visuel à venir ».
Les liens externes peuvent changer ; la même présentation est prévue en cas d'erreur.

Pour enrichir une ancienne collecte déjà terminée sans photos, utiliser un **nouveau
dossier `--out`** : la reprise ne revisite pas les fiches déjà traitées. Vérifier les
visuels et leurs droits de réutilisation en même temps que les références, avant publication.

Contrôle réel du 13 octobre 2026 : les six fiches officielles des trois références
pilotes ont été lues avec le collecteur, et les six liens photo répondent en HTTP 200
avec un fichier image valide. Les images Rexel sont de 300 × 300 pixels ; celles
de Sonepar de 3000 × 3000 pixels pour ces références. Les trois photos Rexel ont
été vérifiées visuellement et renseignées dans la base existante avec
`supabase/pilot_images.sql`, sans dépendre des nouvelles migrations. Les liens et
sources des deux fournisseurs sont conservés dans `catalog/pilot-images.json`.

Le site utilise les photos dans les cartes catalogue, la comparaison et le panier,
avec chargement différé, proportions conservées et absence de referrer. La collecte
de 100 produits avec photos reste à exécuter ; le contrôle réel portait sur ces trois références.

Voir [l'audit de la base et la correspondance des champs](AUDIT_BDD.md).

Il ne collecte **aucun prix** ni description longue. Les prix propres
à l’artisan restent le rôle de l’extension dans sa session connectée. Une quantité
dans « Conditionnement » n’est pas automatiquement le minimum commandable ni la
base d’un tarif. Une empreinte de page sert à tracer la collecte, pas à certifier
commercialement un prix ou une donnée.

## Validation et limites connues

Les libellés de références et les catégories ont été vérifiés sur les pages publiques
le 11 octobre 2026. Les tests automatisés emploient du HTML synthétique et des réponses
HTTP simulées : extraction, EAN, URLs, doublons/conflits, robots.txt, redirections,
blocages, reprise, interruption et rapport partiel.

Un premier contrôle réseau a été bloqué le 11 octobre ; les six fiches des trois
produits pilotes ont ensuite été lues réellement le 13 octobre.
Le 14 octobre 2026, la commande pilote ci-dessus a collecté les six fiches en six
lectures de produits : **3 produits, 3 paires de codes, 6 URL photo, aucun rejet**.
Le code Sonepar du troisième produit a bien été ajouté après avoir atteint `--limit 3`.
Le JSON obtenu est accepté par `prepare_catalogue_import.py` pour préparer le SQL.
Les 31 tests Python passent, y compris les limites de pages, la reprise, les conflits
d'identifiants et la conservation des références sous forme de chaînes.
**Aucune collecte complète de 100 fiches n'a été validée.**
La disponibilité des autres pages et la compatibilité du HTML restent à confirmer
pendant la collecte. Les pages uniquement rendues
en JavaScript sont écartées avec un motif ; aucun navigateur furtif n’est fourni.

Sources officielles :

- https://www.rexel.fr/robots.txt
- https://www.sonepar.fr/robots.txt
- https://www.sonepar.fr/fr-fr/static/terms-and-conditions
- https://www.sonepar.fr/catalog/fr-fr/products/legrand-interrupteur-ou-va-et-vient-10ax-250v-etanche-plexo-composable-gris-00001187798
- https://www.rexel.fr/frx/p/73224603

Le respect de robots.txt ne constitue pas une autorisation de réutilisation commerciale.
Les CGU Sonepar encadrent notamment les extractions substantielles ou répétées portant
atteinte aux droits du producteur de la base. Un accord ou un export fournisseur reste
la voie à privilégier pour étendre et maintenir durablement le catalogue.
