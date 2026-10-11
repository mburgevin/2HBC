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
importeur marque les lignes comme vérifiées. Après contrôle, les produits retenus
pourront être intégrés par un import additif adapté.

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
