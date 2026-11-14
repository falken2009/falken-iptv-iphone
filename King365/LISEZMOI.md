# Falken IPTV — lecteur IPTV pour iPhone

Lecteur IPTV en SwiftUI (iOS 17+, Xcode 26), en mode paysage :
- **Intro animée** : le faucon apparaît et « FALKEN IPTV » s'écrit lettre par lettre avec un son d'ouverture (coupé si l'iPhone est en mode silencieux).
- **Accueil noir et rouge** : connexion, puis quatre grandes tuiles TV en direct, Guide, Films, Séries, avec la date d'expiration de l'abonnement.
- **TV en direct** : en paysage, catégories à gauche et chaînes à droite, recherche, programme en cours avec barre de progression, guide complet de chaque chaîne.
- **Films** et **Séries** : catalogue de ton abonnement Xtream, affiches, résumés, saisons et épisodes.
- **Derniers ajouts** : catégorie « 🆕 Derniers ajouts » en tête des Films et des Séries (300 titres, du plus récent au plus ancien), et tri « Derniers ajouts » dans chaque catégorie.
- **Recherche vocale en français** : touche le micro et dis le titre d'un film ou d'une série.
- **Lecteur VLC intégré** : MKV, AVI, TS… avec choix de la langue et des sous-titres.
- **Sagas regroupées** : dans Films, les films d'une même saga (Harry Potter, John Wick…) sont rassemblés sous une seule affiche.
- **Images de fond** : dans Films et Séries, les affiches défilent en arrière-plan ; la fiche d'un film ou d'une série affiche son image de fond.
- **Sagas et jaquettes depuis Internet (TMDB)** : avec une clé gratuite de themoviedb.org (Réglages), les sagas sont regroupées d'après TMDB et les jaquettes manquantes sont complétées.
- **Une seule copie par titre** : quand un film ou une série existe en plusieurs qualités (4K, FHD, HD, SD…), seule la meilleure est affichée (bouton de regroupement pour tout revoir).
- **Replay** : revois les programmes déjà diffusés sur les chaînes qui proposent le rattrapage (Xtream).
- **Reprise de lecture** : films et épisodes reprennent là où tu t'es arrêté, épisodes vus cochés.
- **Contrôle parental** : code à 4 chiffres, catégories adultes bloquées, verrouillage par appui long.
- **Multi-écran** : 2 ou 4 chaînes en même temps, son au choix.
- **État de la connexion** (Réglages) : un bouton teste Internet, le serveur et son temps de réponse, l'état du compte, la date d'expiration et les écrans utilisés, avec un conseil clair.
- **Réseau robuste** : nouvelles tentatives automatiques, identifiant d'appli réglable (IPTV Smarters, VLC…), messages d'erreur clairs, détection des abonnements expirés.
- **Profils** (« Qui regarde ? ») : favoris, reprise et liste séparés pour chaque personne.
- **Plusieurs abonnements** enregistrés, changement en un geste dans Réglages.
- **Continuer à regarder** sur l'accueil, **épisode suivant automatique**, **zapping** (flèches à droite du lecteur), **minuteur de veille** (lune).
- **Grille du guide** façon télé (3 heures visibles, ◀ ▶ pour avancer) et **rappels** 5 min avant un programme.
- **Ma liste** (« À voir plus tard »), **filtres** des films par année, note et genre, **choix du thème** (rouge, bleu, vert, or).
- **Favoris**, **AirPlay**, **image dans l'image**.

L'appli ne fournit aucune chaîne : elle lit le contenu de ton abonnement.

## Installation dans Xcode (Mac nécessaire)

1. **Xcode → File → New → Project → iOS → App**
   - Product Name : `King365`
   - Interface : SwiftUI, Language : Swift
   - Minimum Deployments : iOS 17.0
2. Supprime les fichiers `ContentView.swift` et `King365App.swift` créés par Xcode.
3. Glisse les 28 fichiers `.swift` et le son `intro.wav` de ce dossier dans le projet (coche « Copy items if needed »).
4. **Autoriser les flux en http** (la plupart des serveurs IPTV ne sont pas en https) :
   cible King365 → onglet **Info** → ajoute la clé `App Transport Security Settings`,
   puis dedans `Allow Arbitrary Loads` = `YES`.
5. **Image dans l'image et son en arrière-plan** :
   onglet **Signing & Capabilities** → **+ Capability** → **Background Modes** →
   coche « Audio, AirPlay, and Picture in Picture ».
6. **Mode paysage uniquement** : onglet **General** → **Deployment Info** → décoche « Portrait »
   et « Upside Down », garde « Landscape Left » et « Landscape Right ».
7. **Micro et reconnaissance vocale** : onglet **Info**, ajoute les clés
   `Privacy - Microphone Usage Description` et `Privacy - Speech Recognition Usage Description`
   avec une phrase d'explication (par exemple « Pour chercher un film à la voix »).
8. **Lecteur VLC** : menu **File → Add Package Dependencies…**, colle
   `https://github.com/koombea/vlckit-spm`, puis ajoute le produit **VLCKitSPM** à la cible King365.
9. **Icône** : dans Xcode, ouvre `Assets` → `AppIcon` et glisse `Assets.xcassets/AppIcon.appiconset/icon-1024.png`.
10. Dans **Signing**, choisis ton Apple ID (Team), branche ton iPhone et clique ▶︎.
   Avec un compte Apple gratuit, l'appli doit être réinstallée tous les 7 jours ;
   avec le programme développeur (99 €/an), elle reste un an.
   Sur l'iPhone, la première fois : Réglages → Général → VPN et gestion de l'appareil → faire confiance au développeur.

Tu mets à jour une version précédente ? Remplace tous les fichiers et ajoute les nouveaux
(`EPG.swift`, `Xtream.swift`, `VODViews.swift`, `Theme.swift`, `Home.swift`, `Splash.swift`, `intro.wav`), puis touche « Charger la playlist » une fois
pour récupérer les identifiants du guide.

## Utilisation

- **Réglages** : colle ton lien M3U, ou choisis « Xtream Codes » et saisis serveur, utilisateur et mot de passe, puis « Charger la playlist ».
- **Guide des programmes** :
  - avec Xtream, il est téléchargé automatiquement ;
  - avec un lien M3U, il est lu dans la playlist si elle l'indique (`url-tvg`) ; sinon colle le lien XMLTV de ton fournisseur dans Réglages ;
  - il se met à jour tout seul au démarrage (au plus toutes les 6 heures) et couvre les 36 prochaines heures.
- Dans **Direct**, le titre du programme en cours s'affiche sous chaque chaîne ; touche l'icône liste pour voir la suite de la journée.
- **Films / Séries** : disponibles uniquement avec Xtream Codes. Touche une affiche pour la fiche, puis « Lecture » ou un épisode.

## Bon à savoir

- Les films et séries en **MKV, AVI ou TS** sont lus avec le lecteur VLC intégré (langues et sous-titres au choix). Le HLS et le MP4 utilisent le lecteur d'Apple, qui garde l'AirPlay et l'image dans l'image ; s'il échoue, l'appli bascule sur VLC automatiquement.
- Le guide XMLTV compressé (`.xml.gz`) n'est pas pris en charge : utilise le lien non compressé.
- Si Xcode affiche des erreurs, copie-les pour qu'elles soient corrigées.

