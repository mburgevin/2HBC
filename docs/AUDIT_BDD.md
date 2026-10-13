# Audit BDD et compatibilité de la collecte — 12 octobre 2026

**Complément du 13 octobre :** photos ajoutées au collecteur pour Rexel et Sonepar,
six liens média vérifiés sur les trois références pilotes, trois photos renseignées
dans Supabase via le champ `image_url` existant. Les nouvelles migrations restent
bloquées par le connecteur. `catalogue_images` ajoute la provenance de l'image et
étend l'import ; détails et état actuel dans [COLLECTE_CATALOGUE.md](COLLECTE_CATALOGUE.md).

Projet Supabase audité : **2HBC**, `gueuqeqyshhhmxbsiuxg`, PostgreSQL **17.6**.
Audit du schéma réel via les catalogues PostgreSQL, des contraintes, des index,
des fonctions et des règles RLS, puis comparaison avec le code du dépôt.
Aucun contenu de compte client, panier ou identifiant fournisseur n'a été collecté.

**État de livraison : corrections écrites et testées, migration distante non appliquée.**
L'outil Supabase `apply_migration` a retourné `Invalid or expired requestState` deux
fois. Les lectures et la liste des migrations ont confirmé l'absence de changement.
La base distante contient encore uniquement `initial_mvp` et
`personal_supplier_prices`. Le fichier prêt à appliquer est
`supabase/migrations/20261012163203_catalogue_integrity_import.sql`.

## Conclusion sur le modèle

Le découpage convient au MVP ; une refonte serait inutile. Un produit représente
une référence fabricant, une offre sa correspondance chez un fournisseur. Le panier
pointe vers l'offre choisie. Les prix propres à un artisan appartiennent à une table
privée distincte et ne sont pas des attributs globaux du produit.

| Ensemble | Diagnostic et décision |
|---|---|
| `produits` | Identité fabricant et contenu public au bon endroit. Renforcer EAN, doublons et preuve de validation. |
| `fournisseurs`, `produits_fournisseurs` | Bonne relation pour comparer une même référence. Ajouter l'unicité de la référence au sein d'un fournisseur. |
| `clients`, `segments_clients` | Profil lié à Supabase Auth ; aucun mot de passe local. À conserver. |
| `paniers`, `articles_panier` | Un panier actif par client, lignes uniques, quantités encadrées et ajout atomique. Suffisant pour le MVP. |
| `prix_personnels` | Prix privés par client/offre/contexte/quantité, montant HT, base de prix, unité et validité de dix minutes. À conserver séparés. |
| `categories`, `besoins_clients` | Structure utile. Les catégories sont encore vides ; ne pas confondre catégorie de découverte et classement vérifié. |
| Nouvelle `collectes_catalogue` | Zone de préparation et provenance privées, puis lien vers le produit après validation. |

État réel : **14 produits**, dont **3 vérifiés et 11 de démonstration** ; **35 offres**,
dont **6 correspondances vérifiées et 29 de démonstration** ; **0 catégorie** et
**0 observation de prix personnel**. Les six offres vérifiées n'ont aucun tarif
inventé. Les anciennes données restent conservées et distinguées des fiches réelles.

## Corrections préparées

- EAN/GTIN en texte, longueurs 8/12/13/14 avec clé de contrôle ; l'ancien contrôle
  acceptait aussi 9, 10 ou 11 chiffres et ne vérifiait pas la clé.
- Unicité des GTIN équivalents complétés à 14 chiffres, et des couples
  marque/référence sans différence de casse ou d'espaces en bordure. Un conflit
  impose une résolution humaine ; aucune fusion approximative sur le nom.
- Référence fournisseur unique chez un fournisseur ; noms et références non vides.
  Les zéros initiaux sont conservés. Les références peuvent être nulles sur les
  anciennes offres non vérifiées.
- Une fiche vérifiée exige marque, EAN, source et date ; une offre vérifiée exige
  référence fournisseur, URL et date. Un EAN à clé correcte n'est pas une preuve
  d'existence ou d'attribution : la revue des sources reste indispensable.
- Unicité des catégories sœurs et des fournisseurs avec casse/espaces normalisés.
- Remplacement des cinq politiques administrateur `FOR ALL` par des politiques
  d'écriture par opération : suppression du chevauchement avec les lectures RLS.
- Recherche catalogue enrichie de l'EAN, avec le même contrat de réponse pour le site.
- Import atomique, validation côté programme **et** PostgreSQL, contrôle admin,
  préparation privée par défaut, historique des sources et publication explicite.

Le réimport ne remplace pas les prix, les identifiants d'offres utilisés dans les
paniers, ni les correspondances existantes différentes. Une URL modifiée doit être
traitée manuellement : l'extension rattache ses observations à une URL précise.
Les images/descriptions existantes ne sont pas effacées. Une nouvelle collecte ne
remplace pas automatiquement un nom ou un conditionnement déjà renseigné.

## Le programme a-t-il les données nécessaires ?

**Oui pour un catalogue minimal de références comparables ; non pour les prix
personnels ou les règles de commande connectées.** Le collecteur public existant
est compatible avec `prepare_catalogue_import.py`. L'ancien `catalog-sql.cjs`
reste réservé aux trois fiches historiques déjà vérifiées.

| Sortie du collecteur | Destination / traitement | État |
|---|---|---|
| `brand`, `reference`, `ean`, `name` | `produits.marque`, `ref_fabricant`, `code_ean`, `nom` | Obligatoires et contrôlés |
| `offers[].supplier` | Recherche/création du fournisseur Rexel ou Sonepar | Obligatoire |
| `offers[].reference` | `produits_fournisseurs.ref_fournisseur` | Obligatoire, texte |
| `offers[].url` | `url_produit` et source du produit | HTTPS officiel, fiche produit sans paramètres |
| `offers[].pack` | `conditionnement`, texte brut | Facultatif, aucune déduction numérique |
| `offers[].collected_at`, `page_sha256` | Trace par fournisseur dans `collectes_catalogue.donnees` | Obligatoires |
| `categories` | Catégories de découverte dans la trace | Aucune catégorie métier créée automatiquement |
| `review_status` + option `--approve` | Préparation privée ou publication vérifiée | Deux étapes explicites |
| Source et date de validation | Source issue d'une offre ; date calculée à la publication | Générées côté base |
| IDs produit/fournisseur/offre | Identités générées/résolues côté base | Pas d'ID à deviner dans le programme |
| `offers[].image_url` (depuis le 13 octobre) | Photo publique liée à sa source fournisseur ; `produits.image_url` après validation | Collectée si identifiée ; extension d'import en attente de migration |
| Description, PDF, caractéristiques détaillées | Colonnes facultatives laissées vides | Non collectés actuellement |
| Prix, stock, minimum/multiple de vente, base et unité de prix | Hors collecte publique | À qualifier dans la session fournisseur |

L'importeur prépare des fichiers SQL sans connexion réseau ni clé secrète. Leur
exécution est une opération administrateur. Le flux détaillé et les commandes
Windows se trouvent dans [COLLECTE_CATALOGUE.md](COLLECTE_CATALOGUE.md).

Pour les prix personnels, l'extension devra transmettre une offre vérifiée, le
montant HT, la base, l'unité, la quantité, l'empreinte de contexte et les dates.
Le site rattache l'observation au client Supabase authentifié. Aucun cookie,
mot de passe ou numéro de compte fournisseur n'est nécessaire à l'import catalogue.
Les profils connectés de l'extension restent à qualifier avec de vrais comptes.

## Contrôles exécutés et limites

- **25 tests PostgreSQL embarqué réussis**, incluant les régressions existantes,
  droits visiteur/client/admin, protections des prix privés, contraintes et import.
- **21 tests Python réussis**, dont compatibilité du JSON réellement émis par les
  parseurs Rexel/Sonepar avec l'importeur, refus des champs absents et revue obligatoire.
- Parcours de **100 fiches synthétiques** : le vrai générateur Python produit le SQL,
  PostgreSQL prépare puis publie le lot deux fois sans doublons. Vérification de
  l'échappement SQL, des conflits et de l'annulation complète d'un lot en erreur.
- Aucune de ces 100 fiches de test n'a été envoyée au projet cloud. Les 100 vrais
  produits restent à collecter et à contrôler ; la collecte réelle n'est pas prouvée
  par les tests de parseurs sur HTML synthétique.
- Pas encore de validation des nouvelles contraintes dans le cloud, car la migration
  n'a pas pu être appliquée. Contrôler ensuite les migrations, les effectifs, la
  recherche d'un EAN connu et les advisors Supabase sécurité/performance.

Le dernier contrôle Supabase signale la [protection contre les mots de passe divulgués
désactivée](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection).
Ce paramètre Auth reste à traiter avant ouverture publique. Les avertissements de
politiques permissives multiples sont corrigés par la migration en attente. Les
index signalés « inutilisés » sont conservés : une base presque vide ne permet pas
de conclure qu'un index de clé étrangère est superflu.

Supabase annonce une [mise à jour mineure PostgreSQL 17.11 depuis 17.6](https://supabase.com/changelog/postgres-15-19-17-11-breaking-changes).
Planifier cette maintenance de sécurité via la plateforme ; aucune mise à niveau
ni interruption du service n'a été déclenchée durant cet audit.

## Évolutions à différer

Pas de table de commandes/paiements nécessaire tant que l'artisan valide chez le
fournisseur. Pas de multi-entreprise, multi-agence ou comptes partagés à introduire
avant d'avoir défini leurs règles d'accès. Les références alternatives et unités
de vente normalisées seront à modéliser à partir des données réellement disponibles.

Le tarif commun `prix` reste historiquement à deux décimales et suppose une unité
de vente connue par l'interface. Avant d'y publier des tarifs négociés 2HBC pour
câbles, rouleaux ou boîtes, ajouter une base/unité/multiple explicites et adapter les
calculs du site. La collecte actuelle laisse ces prix nuls ; les prix personnels
possèdent déjà une base/unité et quatre décimales. Le nettoyage périodique des
observations expirées et la politique de conservation sont également à définir.
