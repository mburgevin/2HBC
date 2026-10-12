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
  catégorie de découverte, date et empreinte de la source.
- `report.json` : nombre réellement obtenu, objectif atteint ou non, nombre de
  produits présents chez les deux fournisseurs, fiches rejetées et motifs.
- `state.json` : progression, file de pages restantes et produits déjà collectés.

**Relancer exactement la même commande reprend la collecte.** Ctrl+C conserve aussi
la page interrompue. Pour recommencer complètement, choisir un nouveau dossier
`--out` ; ne pas supprimer une progression utile.

Le budget par lancement est de 300 pages. Pour poursuivre avec un budget supérieur :

```powershell
py collect_catalogue.py --limit 100 --max-pages 500 --out catalogue-2hbc
```

Un fournisseur qui répond 401/403/429/503 est suspendu pour cette exécution. Il n’y
a ni contournement du CAPTCHA, ni rotation de proxy, ni récupération de session.
Ne pas relancer en boucle après un blocage ; attendre ou utiliser un flux autorisé.
La sortie vaut 0 si l’objectif est atteint, 2 si le résultat est partiel et 130 après
interruption. Le rapport fait foi : **le programme ne garantit pas d’atteindre 100**
si les pages sont bloquées, rendues uniquement en JavaScript ou modifiées.

## Sélection de produits

Les catégories initiales couvrent appareillage, protection/distribution, connectique,
fils et câbles, éclairage et outillage. Elles servent de points de départ ; aucune
répartition par catégorie ou marque n’est garantie. Le programme suit uniquement
les liens de produits et la pagination visible de la même catégorie. Il ne visite
pas les pages de connexion, les paniers ou les API privées.

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

## Qualité des données et suite dans 2HBC

Un produit n’est accepté que si marque, référence fabricant, EAN13 valide, titre et
référence fournisseur sont lisibles et cohérents. Les références restent des chaînes,
avec leurs zéros initiaux. Un rapprochement Rexel/Sonepar exige **le même EAN, la même
marque et la même référence fabricant**, sans rapprochement approximatif par nom.
Les conflits sont signalés. La ponctuation des marques n’est pas arbitrairement effacée.

100 produits collectés ne signifie pas 100 produits disponibles chez les deux
fournisseurs. Le programme s’arrête au nombre de produits distincts demandé ; il ne
continue pas une recherche exhaustive de toutes les correspondances manquantes.

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
automatique à la taxonomie métier. Images, PDF, descriptions et quantités de vente
normalisées ne sont pas inventés. Les prix des nouvelles offres restent `NULL`.

Voir [l'audit de la base et la correspondance des champs](AUDIT_BDD.md).

Il ne collecte **aucun prix**, aucune photo ni description longue. Les prix propres
à l’artisan restent le rôle de l’extension dans sa session connectée. Une quantité
dans « Conditionnement » n’est pas automatiquement le minimum commandable ni la
base d’un tarif. Une empreinte de page sert à tracer la collecte, pas à certifier
commercialement un prix ou une donnée.

## Validation et limites connues

Les libellés de références et les catégories ont été vérifiés sur les pages publiques
le 11 octobre 2026. Les tests automatisés emploient du HTML synthétique et des réponses
HTTP simulées : extraction, EAN, URLs, doublons/conflits, robots.txt, redirections,
blocages, reprise, interruption et rapport partiel.

Le téléchargement direct depuis l’environnement de développement a été bloqué par
l’autorisation réseau. **Aucune collecte complète de 100 fiches n’a donc été validée.**
La première exécution sur le poste de l’utilisateur doit confirmer la disponibilité
des pages et la compatibilité du HTML réellement servi. Les pages uniquement rendues
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
