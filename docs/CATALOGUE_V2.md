# Catalogue 2HBC — catégories, attributs et recherche

État du 29 octobre 2026 : le modèle métier de l’étape 2 est installé et vérifié dans [CATALOGUE_MODELE_V1.md](CATALOGUE_MODELE_V1.md). Il remplace les anciens profils par 3 univers, 19 familles finales et 99 attributs actifs. La vérification distante préalable confirme 0 produit et 0 offre, 2 utilisateurs, 1 client et 3 fournisseurs. Le résultat de l’installation est consigné dans ce nouveau document.

## Installation sur le catalogue vide

Le script adapté à cet état est [20261029_install_catalogue_v1.sql](../supabase/operations/20261029_install_catalogue_v1.sql). Il applique les quatre migrations en attente en une transaction et conserve comptes, clients et fournisseurs. Il refuse un catalogue non vide ou un historique inattendu. Aucun nettoyage n’est nécessaire.

**Le script historique `20261016_reset_catalogue.sql` ne correspond plus à l’état actuel : ne pas l’exécuter.** Il reste dans le dépôt pour la traçabilité de l’ancienne opération.

Les sections suivantes décrivent le collecteur et le contrat v2 existants. Le collecteur 0.5.0 et l’import v3 sont désormais décrits dans [COLLECTE_CATALOGUE.md](COLLECTE_CATALOGUE.md) ; utiliser ce nouveau guide pour toute nouvelle collecte. Après installation du modèle métier, `--approve` ne suffit plus à publier : chaque fiche doit satisfaire `diagnostic_publication`, puis être publiée explicitement par `publier_produit_catalogue`.

## Collecter sous Windows

Python 3.10 ou plus, aucune dépendance Python, aucun compte fournisseur ni clé Supabase nécessaire.

Télécharger le **nouveau** fichier `collect_catalogue_attributs_v0_4_0.py`, puis lancer dans son dossier :

```powershell
py collect_catalogue_attributs_v0_4_0.py --version
py collect_catalogue_attributs_v0_4_0.py --limit 100 --max-pages 500 --out catalogue-attributs-v040
```

La première commande doit afficher **0.4.0** et **attributs + catégories + photos + codes Rexel/Sonepar**. Utiliser un nouveau dossier : les états des versions antérieures sont refusés pour éviter de réutiliser des fiches sans attributs. Relancer la même commande reprend une collecte v0.4.0 ; Ctrl+C conserve sa progression.

Le programme respecte les exclusions `robots.txt`, ralentit les requêtes et suspend un fournisseur en cas de contrôle d’accès ou limitation. Il consulte les pages publiques, sans connexion, contournement, cookie ni API privée. Il ne collecte pas les prix personnels.

Fichiers à renvoyer pour contrôle :

- `products.json` : contrat d’import v2, identités, offres, photos et caractéristiques sourcées.
- `catalogue.json` : aperçu lisible, codes manquants, attributs et chemins de catégories.
- `report.json` : couverture, conflits et erreurs ; 100 produits ne signifie pas 100 doubles correspondances.
- `state.json` : reprise locale ; facultatif pour le contrôle.

## Ce qui est réellement extrait

Pour chaque offre : référence Rexel/Sonepar, URL, photo, date, empreinte de page, chemin de catégories exact (codes + libellés + URL), caractéristiques brutes (libellé + valeur), résumé public et gamme quand elle est explicitement exposée.

Les libellés reconnus deviennent des attributs typés : couleur, matière, pose, fixation, connexion, IP, sans halogène, courant, tension, modules, pôles, pôles protégés, courbe, section, conducteurs, longueur, puissance, flux, température, type de tension, Icn et Icu à 230 V. **Icn et Icu restent distincts**. Une indication `1P+N` n’est jamais transformée en `2P`.

Les valeurs inconnues restent dans les données brutes. Les plages comme `1...16 mm²` ne deviennent pas une fausse valeur unique. Le programme n’invente ni unité ni règle de commande depuis le titre. Les images sont des URL publiques, pas des fichiers recopiés.

Le rapprochement Rexel/Sonepar exige toujours **EAN + marque + référence fabricant concordants**. Un conflit sur un attribut est signalé dans `attribute_conflicts` et exclu des attributs normalisés ; aucun fournisseur ne gagne arbitrairement.

## Classer et publier

La catégorie de découverte du crawler n’est pas la catégorie finale du produit. Le chemin fournisseur est collecté mais `category_code` reste à attribuer après contrôle. Les catégories fournisseur sont parfois plus larges que nos familles : leur correspondance ne doit pas être généralisée automatiquement. La table `categories_fournisseurs` permet de valider ces correspondances ultérieurement.

Codes de catégories du contrat v2 historique (remplacés par le référentiel métier v1 ; voir le document lié ci-dessus) :

| Famille | Codes finaux |
|---|---|
| Appareillage | `prises`, `interrupteurs`, `appareillage-composable`, `plaques`, `boites` |
| Protection | `disjoncteurs`, `differentiels`, `disjoncteurs-differentiels`, `coffrets` |
| Fils et câbles | `fils`, `cables-installation` |
| Raccordement | `bornes` |
| Éclairage | `luminaires`, `lampes` |
| Outillage | `outils` |

1. Préparer les fiches en privé, après activation des migrations :

```powershell
py prepare_catalogue_import.py catalogue-attributs-v040/products.json --out preparation.sql
```

Exécuter ce SQL dans le projet 2HBC. Il n’affiche pas les fiches dans le catalogue.

2. Contrôler les identités et sources ; attribuer `category_code`, vérifier la gamme et les attributs applicables. Résoudre chaque conflit en consultant les sources, ou conserver uniquement les données brutes et retirer l’attribut incertain. Copier les fiches relues dans `products-reviewed.json` et passer leur `review_status` à `approved`.

3. Générer puis exécuter la publication :

```powershell
py prepare_catalogue_import.py catalogue-attributs-v040/products-reviewed.json --approve --out publication.sql
```

Le contrat v2 vérifie types, unités, provenance, catégorie finale, conflits, GTIN et références. Le modèle métier v1 ajoute ses propres observations, valeurs retenues, exigences et qualification avant toute exposition publique. Une erreur annule le lot. Le réimport d’un document v2 approuvé remplace ses attributs canoniques par l’instantané relu, sans remplacer les tarifs existants. La préparation conserve deux documents privés : contrat d’identité historique et document v2 complet.

## Structure et recherche

- Catégories en arbre, codes stables, unicité des noms parmi les frères et prévention des cycles. Les modifications concurrentes de l’arbre sont sérialisées ; un conflit de verrouillage impose de recommencer la transaction.
- Marques et gammes normalisées ; renommages répercutés dans les produits et l’index de recherche.
- Définitions d’attributs typées, applicabilité par catégorie, valeurs canoniques sourcées. Une absence reste inconnue ; `false` et `0` sont conservés. Les attributs textuels restent ouverts, sans dictionnaire ETIM exhaustif imposé.
- Colonnes de règles de vente (`unite_vente`, minimum, multiple, date de vérification), laissées nulles tant que les règles ne sont pas établies. **Les quantités décimales ne sont pas encore prises en charge par le panier et l’extension** ; une adaptation coordonnée reste nécessaire pour certains câbles.
- Recherche française sans accents, index GIN, priorité aux identifiants exacts, EAN et codes fournisseur publics. Pas de rapprochement approximatif d’identités.
- `rechercher_catalogue_v2(terme, filtres, page_num)` : produits, total, facettes et arbre des catégories. OU entre valeurs d’un même filtre, ET entre filtres ; intervalles numériques dans l’unité canonique. Les compteurs sont calculés avant pagination et ignorent leur propre filtre.
- Les prix personnels restent privés et ne servent pas à un filtre global de prix. Le catalogue public ne révèle aucun tarif connecté. Les offres non publiées sont refusées à l’ajout au panier, y compris par écriture directe.

## Validation et limites

Les tests couvrent le chemin Python → SQL → PostgreSQL, l’isolation des rôles, les identifiants exacts, les filtres combinés, les compteurs, la pagination, les cycles, les conflits de données et le nettoyage avec annulation sur erreur.

Quatre pages publiques ont été relues le 16 octobre : un disjoncteur présent chez les deux fournisseurs et deux prises distinctes. Elles exposent respectivement 28, 25, 59 et 54 attributs bruts. Les données de validation sont dans `catalog/validation/20261016/`, marquées **pending** ; elles ne sont pas publiées dans Supabase. Ce test ne qualifie pas tous les rayons fournisseurs.

Les changements d’HTML peuvent réduire la couverture ; `report.json` permet de les repérer. Les dictionnaires de libellés et les catégories seront enrichis avec les nouvelles familles. Les conditions de réutilisation des catalogues/photos et les accords de données à grande échelle restent à établir avec les fournisseurs.

Le statut d’installation Supabase est suivi dans `CATALOGUE_MODELE_V1.md`. La RPC existante conserve les facettes de `produit_attributs` ; l’interface et la recherche des ensembles, intervalles et contextes de `valeurs_catalogue` restent à adapter. La présence des nouvelles tables ne signifie pas que ces nouveaux filtres sont déjà disponibles sur le site.

Le contrôle en navigateur automatisé local est préparé dans `tests/catalogue-browser.mjs`, mais n’a pas pu démarrer ici : Chromium est absent et son téléchargement échoue. Les interactions React sont couvertes par Testing Library, et le contrat complet de collecte/import/recherche par PostgreSQL embarqué. Le contrôle visuel en navigateur reste à effectuer après activation.
