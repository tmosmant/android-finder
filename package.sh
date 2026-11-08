#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
output=${1:-../Android Finder.dmg}
./build.sh
mkdir -p .build
stage=$(mktemp -d "$PWD/.build/dmg.XXXXXX")
trap 'rm -rf "$stage"' EXIT
ditto "Android Finder.app" "$stage/Android Finder.app"
ln -s /Applications "$stage/Applications"
hdiutil create -ov -volname "Android Finder" -srcfolder "$stage" -format UDZO "$output"
