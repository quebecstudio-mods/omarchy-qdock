# Journal des versions

## 1.2.1 - 2026-11-16

### Changements

- **Le README explique comment désinstaller le plugin**, et le dépôt a une image d'aperçu pour le répertoire de plugins d'Omarchy.

## 1.2.0 - 2026-11-16

### Ajouts

- **La recherche avec qSpot.** Avec [qSpot](https://github.com/quebecstudio-mods/omarchy-qspot) activé, une loupe peut se placer après le bouton des apps (`search`, désactivée par défaut ; un clic droit ouvre les réglages de qSpot). Dans la grille d'apps, Tab passe ce que vous avez tapé à qSpot pour chercher partout, et Entrée aussi quand aucune app ne correspond.
- **L'album** dans la bulle de la musique en cours, sous le titre et l'artiste (omis pour un single qui porte le nom de sa piste).

### Changements

- **Musique en cours :** sous le pointeur, la tuile montre ce que fait un clic, lecture ou pause, sur la pochette ou à la place de la note. La bulle ne nomme plus le lecteur.
- **Les pubs de Spotify** gardent leur propre texte comme titre, avec « Publicité » à la place de l'artiste.

### Corrections

- **Fenêtres hors écran.** Une fenêtre flottante peut sortir de tous les écrans quand l'un d'eux disparaît puis revient (mise en veille d'un moniteur). Un clic sur son app lui donnait le focus sans qu'on la voie ; le dock la recentre maintenant sur son écran en la ramenant.
- **Météo qui ne se charge jamais.** Open-Meteo refusait les prévisions (403) quand la requête partait avec l'identifiant par défaut de curl, et la tuile restait sur « … ». qDock s'identifie maintenant dans ses requêtes.

## 1.1.1 - 2026-11-13

### Corrections

- **Pochettes dans la tuile Musique.** Une pochette venue du web (celle de Spotify, par exemple) ne s'affichait parfois jamais, et la tuile gardait sa note. qDock télécharge maintenant chaque pochette une fois dans `~/.cache/qdock/covers` et affiche ce fichier.
- **Les pubs de Spotify.** La tuile affiche « Publicité », sans artiste et avec la note, plutôt que le slogan de la pub.

## 1.1.0 - 2026-11-12

### Ajouts

- **Musique en cours.** Une tuile avec la pochette, le titre et l'artiste de la musique qui joue dans n'importe quel lecteur (Spotify, mpv, un navigateur, une web app) ; au survol, la progression et les commandes. Trois tailles, masquée par défaut (`music`).
- **Météo.** Le ciel et la température, et les trois prochains jours au survol. Masquée par défaut (`weather`) ; le lieu se choisit en cherchant une ville.
- **Quatre styles.** Omarchy (opaque, avec les coins et bordures de votre thème), Cupertino, Redmond et Plasma, chacun avec ses indicateurs d'apps ouvertes, son survol, ses pastilles, ses alertes et ses étiquettes. Les alertes (`attention`) et les étiquettes (`labels`) se choisissent aussi à part.
- **Une fenêtre de réglages**, dessinée avec les contrôles d'Omarchy : Apparence, Comportement, Tuiles, Météo et À propos. Elle s'ouvre depuis le menu du dock ou avec `omarchy-shell -q quebecstudio.qdock settings` ; une entrée de lanceur (Réglages de qDock) est fournie dans `assets/`, à copier comme l'indique le README.
- **Deux grilles d'apps** (`launcher`) : la carte d'Omarchy, qui flotte seule sans voile ni flou derrière, ou le plein écran de Cupertino. Recliquer le bouton Apps ferme la grille.
- **Icônes.** Un style d'icônes Système, qui prend Fichiers, la pile et la corbeille dans votre thème d'icônes. Fichiers est maintenant un dossier ouvert.

### Changements

- **Le style par défaut est maintenant Omarchy**, et la grille par défaut la carte d'Omarchy. Pour garder l'allure de la 1.0, réglez `style` et `launcher` à `"cupertino"`.
- **Valeurs renommées**, les anciens noms toujours lus : `style` `"mac"` → `"cupertino"` ; `iconStyle` et `filesIcon` `"mono"` → `"omarchy"` ; `filesIcon` `"theme"` → `"system"`.
- **Les commandes** sont maintenant sous `quebecstudio.qdock`. `omarchy.dock` répond encore à celles d'Omarchy (`apps`, `refresh`) et à celles de la 1.0 (`stack`, `stackOn`, `settings`, `settingsOn`) ; `settings` et `settingsOn` ouvrent maintenant la fenêtre de réglages ; le menu du dock est `menu` (`menuOn` pour un écran nommé).

### Corrections

- Réordonner le dock : une app atterrit là où on la dépose même pendant qu'une autre se ferme, et une app qui s'ouvre ou se ferme en cours de glisser met fin au glisser au lieu de déplacer la mauvaise.
- Les menus plus hauts que la place restante défilent au lieu d'être coupés.
- Les fichiers dont le nom contient une tabulation s'affichent dans la pile.

## 1.0.0 - 2026-11-11

Première version.
