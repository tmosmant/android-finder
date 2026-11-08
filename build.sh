#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app="Android Finder.app"
mkdir -p "$app/Contents/MacOS"
(
  cd mtp
  go build -o "../$app/Contents/MacOS/android-mtp" .
)
swiftc -module-cache-path "$PWD/.build/modules" Sources/*.swift -o "$app/Contents/MacOS/Android Finder"
cp Info.plist "$app/Contents/"
printf '%s\n' "$PWD/$app"
