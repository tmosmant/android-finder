# Android Finder

[Lire en français](README.fr.md)

Android Finder is a small macOS file browser for Android phones connected over USB. It opens in List view, with an optional Icon view and a clickable path for moving between folders.

## Build and run

```sh
brew install go libusb pkgconf
./build.sh
open "Android Finder.app"
```

The Xcode Command Line Tools are required (`xcode-select --install`). Connect one phone, unlock it, and select **File transfer** in its USB notification. Quit other MTP clients before refreshing.

- Double-click a folder to open it. Press Space on a file to preview a temporary local copy with Quick Look.
- Drag files from Finder into Android Finder to copy them into the current Android folder.
- Drag items into Finder to copy them to your Mac or an external drive.
- Delete selected items after confirmation. Deletion on Android is permanent.

The interface uses AppKit. A bundled Go helper communicates with the phone via [go-mtpfs](https://github.com/ganeshrvel/go-mtpfs). The app uses the first storage volume exposed by the phone and displays the current operation.

## Keyboard shortcuts

- **↑ / ↓** move through List view. In Icon view, all four arrow keys navigate the grid.
- **Any arrow key outside the file area** moves focus to the files and selects the first item.
- **⌘ ↑** opens the parent folder and reselects the folder you just left.
- **Return** or **⌘ ↓** opens the selected folder or previews the selected file.
- **Space** opens or closes Quick Look. The preview follows the selection as you use the arrow keys. **Escape** also closes it.
- **⌫** asks for confirmation before deleting the selection.
- **⌘ R** refreshes the current folder. **⌘ Q** quits the app.

## Installation and automatic USB launch

Open the disk image and drag the app into **Applications**. In the **Android Finder** menu, choose **Ouverture automatique sur USB…**. If macOS asks for approval, allow the background item in **System Settings → General → Login Items & Extensions**. The agent opens the app when it detects a new USB interface named MTP. If the phone connects in charging mode, select **File transfer** on the phone. Use the same menu item to turn off automatic launch.

The package bundles libusb. Run `./package.sh` to create the disk image for your Mac’s architecture. The minimum macOS version also depends on the bundled libusb build. Local builds use ad hoc signing by default.

## Interrupted transfers

When copying to the Mac, the app stages each item and places it at its final destination after the copy completes. When copying to Android, the app stages each item under a temporary name before renaming it. A disconnect may leave an `AndroidFinder-incomplet-…` item on the phone. The error identifies it so you can remove it after reconnecting. Completed items are kept. Reconnect the phone and retry the remaining items.

## Privacy and verification

- The Android Finder source contains no telemetry, cloud service, or automatic updater. Transfers use USB. Quick Look uses temporary local copies that are removed on normal exit.
- Review the [interface and transfer code](Sources/), [USB helper](mtp/), and [optional launch agent](Watcher/main.swift). The agent detects local MTP interfaces and opens the app.
- If you have access to the repository, check out a specific commit and build it locally using the commands above. For a DMG accompanied by a `.sha256` file, put both files in the same directory and run `shasum -a 256 -c "Android Finder.dmg.sha256"`. Compare the digest with one obtained through a trusted channel. A matching digest verifies the file’s bytes. The package uses ad hoc signing for local code integrity checks. Publisher identity requires a Developer ID signature.

### Verify a GitHub release

Download the Apple Silicon DMG and its checksum from [Releases](https://github.com/tmosmant/android-finder/releases). The [build workflow](.github/workflows/release.yml) runs on a GitHub-hosted Mac and attests the DMG against its source commit. With the GitHub CLI, check both the digest and the provenance from your download folder.

```sh
shasum -a 256 -c "Android Finder.dmg.sha256"
gh attestation verify "Android Finder.dmg" \
  --repo tmosmant/android-finder \
  --signer-workflow tmosmant/android-finder/.github/workflows/release.yml \
  --deny-self-hosted-runners
```

The provenance shows where the file was built and which source revision it came from. Reviewing that revision is a separate check.
