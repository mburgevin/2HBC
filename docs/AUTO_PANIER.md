# Prototype d’auto-panier 2HBC

## Ce qui est développé

- Panier React regroupé par fournisseur, sous-totaux et quantités saisissables.
- Références fournisseur modifiables **pour l’essai uniquement** : elles ne sont pas persistées dans Supabase.
  Le seed actuel ne remplit pas ref_fournisseur. Aucun identifiant n’est deviné à partir d’une référence fabricant.
- Bouton de transfert Rexel/Sonepar, protocole validé, contrôle de présence de l’extension, suivi du résultat.
- WebExtension Manifest V3, moteur partagé avec profils Rexel/Sonepar : lecture du panier initial,
  remplissage en bloc (texte ou fichier CSV en mémoire), analyse native, contrôle du lot reconnu,
  clic unique d’ajout, attente de confirmation et comparaison des quantités finales.
- Reprise après connexion avant toute mutation ; arrêt si la session change après une action.
- États persistés dans chrome.storage.session, délai de 30 minutes, protection contre le double lancement.
- Installation ZIP construite automatiquement avec le site, sans dépendance supplémentaire de production.

## Limite essentielle

**Le moteur est développé ; les interfaces réelles connectées ne sont pas encore qualifiées.**
Les profils sont donc désactivés par défaut. Les tests navigateur utilisent des pages simulées et ne
prouvent pas le fonctionnement actuel de Rexel ou Sonepar. Il faut effectuer le repérage ci-dessous,
activer le profil puis réaliser le test connecté. Ne pas présenter cette version comme un auto-panier
fournisseur déjà validé.

La route Rexel /frx/newQuickorder et le candidat .copyPasteDiv textarea viennent de l’étude publique ;
le candidat peut concerner une ancienne interface. Pour Sonepar, l’adresse exacte de l’ajout rapide
reste à relever. L’extension ouvre son accueil pour permettre la connexion. Elle ne devine pas de route.

## Construire et installer

Avec Node 22, à la racine du dépôt :

    node projet-millions/scripts/package-extension.cjs

Le dossier chargeable est projet-millions/public/extension ; l’archive est
projet-millions/public/extension-2hbc.zip. Les builds et npm start reconstruisent ces fichiers.
Ils sont ignorés par Git : les sources sont dans extensions/2hbc et src/lib/supplierTransfer.js.

Dans Chrome de bureau :
1. Télécharger le ZIP depuis /auto-panier.html, puis le décompresser.
2. Ouvrir chrome://extensions, activer le mode développeur.
3. Charger le dossier contenant manifest.json et épingler 2HBC.
4. Actualiser 2HBC et les onglets fournisseurs après toute mise à jour de l’extension.
5. Pour une prévisualisation Vercel, ajouter **son origine exacte** dans les réglages et accorder
   la permission à cette adresse. Ne pas ajouter une URL fournie par un tiers non vérifié.

Le manifeste annonce les deux domaines fournisseurs, les domaines 2HBC connus et localhost.
Les permissions de prévisualisation Vercel sont optionnelles et demandées pour une origine précise.
Le bridge refuse les iframes, les origines non enregistrées et les messages autres que PING/START/STATUS/CANCEL.
Les réglages, le lancement confirmé et la clôture ne sont accessibles qu’aux pages de l’extension.
Le protocole ne transporte aucun cookie, mot de passe ou jeton fournisseur. Aucun backend d’automatisation.

## Préparer les comptes

L’utilisateur autorisé saisit ses identifiants uniquement sur le site du fournisseur.
Ne pas transmettre ses mots de passe dans la conversation ou dans le dépôt.
Préférer un panier de test sans autre opération en parallèle ; relever le compte, l’agence,
le contexte tarifaire et les unités. L’extension n’essaie pas de lire les champs d’identification.
Les défis MFA/CAPTCHA sont traités par la personne.

La confirmation du bon compte dans l’extension est une étape volontaire de ce prototype.
Après qualification, on pourra étudier une expérience plus directe sans supprimer la maîtrise du client.

## Repérer un profil sur les pages connectées

Effectuer d’abord manuellement un lot de deux références existantes, sans valider de commande.
Relever des sélecteurs CSS précis avec les outils de développement du navigateur. Les sélecteurs de
référence et quantité sont relatifs à chaque ligne. Les composants dans un Shadow DOM ouvert sont
parcourus ; un Shadow DOM fermé exige une adaptation et ne doit pas être contourné.

| Réglage | Valeur attendue |
| --- | --- |
| enabled | false pendant le repérage, true lorsque les champs ont été vérifiés |
| mode | text pour une zone de collage, file pour un champ CSV |
| quickOrderUrl | Page réelle du lot, sur l’origine exacte du fournisseur |
| cartUrl | Page réelle de panier, distincte de la commande rapide |
| delimiter / header | Séparateur et en-tête exacts du modèle fournisseur ; en-tête vide si absent |
| inputSelector | Une seule zone de texte, ou un input type=file |
| analyzeSelector | Bouton natif d’analyse/import ; vide si le changement déclenche l’analyse |
| previewRows | Les lignes reconnues avant l’ajout, sans modèles cachés |
| previewRef / previewQty | Référence fournisseur exacte et quantité reconnue, sans libellé/préfixe |
| addSelector | Bouton « Ajouter au panier » ; jamais « Commander » |
| successSelector | Confirmation visible après ajout AJAX ; vide seulement si le site navigue au panier |
| cartRows | Lignes réelles du panier final, sans totaux ni modèles |
| cartRef / cartQty | Référence et quantité finales par ligne |
| emptyCartSelector | Élément réellement visible quand le panier est vide |
| errorSelector | Élément visible seulement lorsqu’une erreur fournisseur bloque l’opération |

Le format de référence doit être le même en entrée, dans l’aperçu et dans le panier. Si le fournisseur
résout une référence fabricant vers un autre SKU, utiliser dès le départ le SKU exact ou développer
une correspondance explicite, à faire vérifier par l’utilisateur. Le moteur actuel refuse une divergence.

L’interface doit séparer la reconnaissance du lot et l’ajout au panier. Vérifier que le changement du
champ, notamment un fichier, **ne commande jamais et n’ajoute pas directement les lignes**. Le prototype
marque néanmoins toute injection comme une tentative potentielle afin de ne pas la rejouer après un incident.
Si le composant exige un événement utilisateur réel ou un fichier choisi manuellement, arrêter la qualification
et adapter le connecteur : ne pas prétendre que le fichier s’est importé.

Les champs de quantité doivent exposer des entiers. Pour les câbles vendus en longueur décimale,
les multiples, les bobines ou les changements d’unité, arrêter et adapter le modèle avant de tester.
Ne pas rendre les contrôles plus permissifs pour faire passer une référence ambiguë.

Ouvrir l’extension > Réglages des connecteurs, compléter le JSON et enregistrer.
Aucun sélecteur de production non observé n’est fourni comme « validé ». Les valeurs dans tests/ sont
des fixtures artificielles ; ne pas les recopier comme réglages Rexel ou Sonepar.

## Déroulement de l’essai

1. Dans 2HBC, sélectionner deux offres du même fournisseur.
2. Renseigner leurs références fournisseur **vérifiées**, conserver les zéros initiaux.
3. Saisir les quantités et cliquer « Enregistrer la quantité ».
4. Cliquer « Préparer mon panier … ». L’extension conserve le lot et ouvre le fournisseur.
5. Se connecter si nécessaire ; ouvrir l’extension, confirmer le compte et lancer le transfert.
6. Le moteur lit d’abord le panier existant. Sans preuve de lignes lisibles ou de panier vide, il s’arrête.
7. Il remplit le lot d’un coup, analyse les lignes, puis compare strictement références et quantités.
8. Il enregistre l’étape d’ajout avant le clic et ne clique jamais une deuxième fois.
9. Après confirmation native, il ouvre le panier et vérifie quantité initiale + quantité demandée.
10. Contrôler humainement les produits, unités, prix et compte. **Ne pas commander pendant l’essai.**

Un HTTP 200 ou un clic envoyé ne suffit pas à afficher « vérifié ».
Le prix négocié 2HBC ne peut pas être imposé par ce transfert. Les droits commerciaux restent côté fournisseur.
Le panier existant n’est jamais vidé ; les doublons de références dans le lot sont agrégés avant l’envoi.

## Erreur, reprise et nouvel essai

Avant injection, une erreur de configuration bloque l’opération. Après injection, une erreur devient
« résultat incertain » car un gestionnaire natif peut avoir réagi à l’événement. Ne pas recommencer
ni importer un CSV complet sans vérifier le panier.

Pour un nouvel essai : vérifier le panier fournisseur, éventuellement retirer manuellement les lignes
de test, arrêter la tâche si nécessaire, cocher le contrôle du panier et cliquer « Clore cet essai »
dans l’extension. Actualiser ensuite le panier 2HBC et créer une nouvelle intention.
La clôture n’annule aucun ajout. L’expiration et le redémarrage du navigateur suppriment les tâches ;
ils n’annulent pas non plus les effets chez le fournisseur.

Les réglages persistent dans chrome.storage.local ; les lots et leur résultat restent dans
chrome.storage.session et sont supprimés à expiration/fermeture. Aucun envoi de catalogue, historique,
tarif privé ou session fournisseur vers 2HBC. Le site reçoit seulement le statut et le contrôle des lignes de son lot.

## Vérifications automatisées

- Tests React : regroupement, saisie de référence, sauvegarde de quantité, transfert bloqué tant
  qu’une quantité n’est pas enregistrée.
- Tests Node : protocole, origines, quantités, références manquantes, expiration, cumul, comparaison
  avant/après et transitions de l’extension, dont persistance d’un ajout commencé après redémarrage.
- Tests Playwright : extension réellement chargée dans Chromium, sites fournisseurs **interceptés et
  simulés**, parcours texte Rexel et fichier Sonepar, reprise de connexion, refus d’écart ou de bouton de commande.
- Build de l’application et contrôle syntaxique des scripts de l’extension.
- Le ZIP de test est publié comme artefact de la vérification GitHub.

Commandes :
    node projet-millions/scripts/package-extension.cjs
    node --test tests/transfer.test.cjs
    npm --prefix projet-millions test -- --watchAll=false --runInBand

Le workflow dédié installe Playwright pour les tests du navigateur. Aucun compte fournisseur réel ni secret
n’est utilisé par la CI, et ses fixtures n’effectuent aucun appel vers les fournisseurs.

## Après le premier test connecté

Fixer et versionner les profils observés, ajouter des tests de non-régression représentatifs et qualifier
les formats/imports et limites. Vérifier l’usage autorisé avant diffusion commerciale, notamment au regard
des CGU Sonepar. Une intégration API officielle de panier non commandé peut remplacer cet adaptateur
ultérieurement ; le POST privé Rexel observé n’est pas utilisé dans cette version.
