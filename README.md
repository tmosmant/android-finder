# Android Finder

Une petite fenêtre macOS pour parcourir le stockage Android en USB. La vue Liste est sélectionnée au démarrage. Le bouton Icônes change l’affichage et le fil d’Ariane permet de remonter dans les dossiers.

## Compiler et ouvrir

```sh
brew install go libusb pkgconf
./build.sh
open "Android Finder.app"
```

Les outils en ligne de commande Xcode sont requis (`xcode-select --install`). Branche un seul téléphone, déverrouille-le, puis choisis **Transfert de fichiers** dans la notification USB. Quitte les autres clients MTP avant d’actualiser.

- Double-clique sur un dossier pour l’ouvrir. Appuie sur Espace sur un fichier pour ouvrir Quick Look après une copie temporaire.
- Glisse des fichiers depuis le Finder dans la fenêtre pour les copier vers le dossier Android courant.
- Glisse des éléments vers le Finder pour les copier vers le Mac ou un disque externe.
- Supprime une sélection depuis la fenêtre après confirmation. La suppression sur Android est définitive.

La fenêtre utilise AppKit. Un exécutable Go embarqué communique avec le téléphone via [go-mtpx](https://github.com/ganeshrvel/go-mtpx). Cette première version utilise le premier stockage exposé par le téléphone et affiche un état pendant les opérations.
