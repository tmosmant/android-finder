# Android Finder

[English](README.md)

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

La fenêtre utilise AppKit. Un exécutable Go embarqué communique avec le téléphone via [go-mtpfs](https://github.com/ganeshrvel/go-mtpfs). Cette première version utilise le premier stockage exposé par le téléphone et affiche un état pendant les opérations.

La vue Liste affiche le nom, le type, la taille et les dates de modification et de création lorsque le téléphone les fournit. Clique sur un en-tête pour trier, puis clique à nouveau pour inverser l’ordre. Fais glisser les séparateurs pour ajuster les largeurs. Les colonnes occupent toute la fenêtre, avec Nom comme colonne la plus large par défaut. Le champ de recherche filtre les noms des fichiers dans le dossier courant et ses sous-dossiers, sans tenir compte des majuscules. La vue Liste indique le dossier sous le nom de chaque résultat.

## Raccourcis clavier

- **↑ / ↓** — parcourir la liste. En vue Icônes, les quatre flèches suivent la grille.
- **Une flèche hors de la zone de fichiers** — remettre le focus sur les fichiers et sélectionner le premier élément.
- **⌘ ↑** — remonter au dossier parent et resélectionner le dossier quitté.
- **Retour** ou **⌘ ↓** — ouvrir le dossier sélectionné ou prévisualiser le fichier.
- **Espace** — ouvrir ou fermer Quick Look. Les flèches continuent de changer la sélection et l’aperçu suit. **Échap** ferme aussi l’aperçu.
- **⌫** — demander la suppression de la sélection.
- **⌘ F** place le focus dans la recherche. **Entrée** ou **↓** passe aux résultats. **Échap** efface la recherche lorsque Quick Look est fermé.
- **⌘ R** — actualiser le dossier courant. **⌘ Q** — quitter l’app.

## Installation et lancement USB

Ouvre l’image disque et glisse l’app dans **Applications**. Dans le menu **Android Finder**, clique sur **Ouverture automatique sur USB…**. Si macOS le demande, autorise l’agent Android Finder dans **Réglages Système → Général → Ouverture et extensions**. L’agent ouvre l’app dès qu’il détecte une nouvelle interface USB nommée MTP. Si le téléphone se branche en mode recharge, choisis **Transfert de fichiers**. Le même menu permet de désactiver l’agent.

Le paquet intègre libusb. `./package.sh` produit l’image disque pour l’architecture du Mac de compilation. Le minimum macOS du paquet dépend aussi de la version de libusb embarquée. La compilation locale utilise une signature ad hoc par défaut.

## Copie interrompue

Vers le Mac, l’app copie chaque fichier ou dossier dans un emplacement temporaire et ne publie l’élément qu’une fois terminé. Vers Android, chaque élément est d’abord copié sous un nom temporaire, puis renommé. Une coupure peut laisser un élément `AndroidFinder-incomplet-…` sur le téléphone. L’erreur indique son nom pour permettre de le supprimer après reconnexion. Les éléments déjà terminés sont conservés. Recommence la copie des éléments restants après avoir reconnecté le téléphone.

## Confidentialité et vérification

- Le code d’Android Finder ne contient ni télémétrie, ni service cloud, ni mise à jour automatique. Les transferts passent par l’USB. Les aperçus sont copiés dans un cache temporaire sur le Mac, supprimé à la fermeture normale.
- Tu peux inspecter [l’interface et les transferts](Sources/), [le moteur USB](mtp/) et [l’agent de lancement](Watcher/main.swift). L’agent est facultatif. Il détecte les interfaces MTP locales et ouvre l’app.
- Si tu as accès au dépôt, tu peux compiler depuis un commit précis avec les commandes ci-dessus. Pour vérifier un DMG accompagné de son fichier `.sha256`, place les deux dans le même dossier et lance `shasum -a 256 -c "Android Finder.dmg.sha256"`. Compare l’empreinte à celle publiée par un canal de confiance. L’empreinte vérifie les octets du fichier. La signature ad hoc du paquet permet de vérifier son intégrité localement. L’identité de l’éditeur requiert une signature Developer ID.

### Vérifier une version GitHub

Télécharge le DMG Apple Silicon et son empreinte depuis les [versions publiées](https://github.com/tmosmant/android-finder/releases). Le [workflow de compilation](.github/workflows/release.yml) s’exécute sur un Mac hébergé par GitHub et associe le DMG à son commit source dans une attestation. Avec GitHub CLI, vérifie l’empreinte et l’attestation depuis ton dossier de téléchargement.

```sh
shasum -a 256 -c "Android-Finder.dmg.sha256"
gh attestation verify "Android-Finder.dmg" \
  --repo tmosmant/android-finder \
  --signer-workflow tmosmant/android-finder/.github/workflows/release.yml \
  --deny-self-hosted-runners
```

L’attestation indique où le fichier a été compilé et à partir de quelle révision. Le code de cette révision peut être examiné séparément.
