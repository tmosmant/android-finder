#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app="Android Finder.app"
contents="$app/Contents"
agent=com.tmosmant.android-finder.usb.plist
mkdir -p "$contents"/{MacOS,Frameworks,Library/LaunchAgents,Resources}
mkdir -p .build/AppIcon.iconset
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Assets/AppIcon.png --out ".build/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  sips -z "$((size * 2))" "$((size * 2))" Assets/AppIcon.png --out ".build/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns .build/AppIcon.iconset -o "$contents/Resources/AppIcon.icns"
export MACOSX_DEPLOYMENT_TARGET=13.0
swift_target="$(uname -m)-apple-macos$MACOSX_DEPLOYMENT_TARGET"
(
  cd mtp
  go build -o "../$contents/MacOS/android-mtp" .
  for module in go-mtpfs usb; do
    module_dir=$(go list -m -f '{{.Dir}}' "github.com/ganeshrvel/$module")
    cp "$module_dir/LICENSE" "../$contents/Resources/$module-LICENSE"
  done
  go_root=$(go env GOROOT)
  go_license="$go_root/LICENSE"
  if [[ ! -f "$go_license" ]]; then
    go_license="$(dirname "$go_root")/LICENSE"
  fi
  cp "$go_license" "../$contents/Resources/Go-LICENSE"
)
libusb=$(pkg-config --variable=libdir libusb-1.0)
dependency=$(otool -L "$contents/MacOS/android-mtp" | awk '/libusb/ {print $1}')
cp -L "$libusb/libusb-1.0.0.dylib" "$contents/Frameworks/"
chmod u+w "$contents/Frameworks/libusb-1.0.0.dylib"
install_name_tool -id '@rpath/libusb-1.0.0.dylib' "$contents/Frameworks/libusb-1.0.0.dylib"
install_name_tool -change "$dependency" '@executable_path/../Frameworks/libusb-1.0.0.dylib' "$contents/MacOS/android-mtp"
libusb_prefix=$(pkg-config --variable=prefix libusb-1.0)
cp "$libusb_prefix/COPYING" "$contents/Resources/libusb-COPYING"
if [[ -n "${ANDROID_FINDER_LIBUSB_SOURCE:-}" ]]; then
  cp "$ANDROID_FINDER_LIBUSB_SOURCE" "$contents/Resources/"
fi
swiftc -target "$swift_target" -module-cache-path "$PWD/.build/modules" Sources/*.swift -o "$contents/MacOS/Android Finder"
swiftc -target "$swift_target" -module-cache-path "$PWD/.build/modules" Watcher/main.swift -o "$contents/MacOS/android-usb-watcher"
cp Info.plist "$contents/"
libusb_min=$(vtool -show-build "$contents/Frameworks/libusb-1.0.0.dylib" | awk '/minos/ {print $2; exit}')
if [[ -n "$libusb_min" ]]; then
  minimum=$(printf '%s\n' "$MACOSX_DEPLOYMENT_TARGET" "$libusb_min" | sort -V | tail -1)
  /usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $minimum" "$contents/Info.plist"
fi
cp "$agent" "$contents/Library/LaunchAgents/"
identity=${ANDROID_FINDER_SIGN_IDENTITY:--}
for binary in "$contents/Frameworks/libusb-1.0.0.dylib" "$contents/MacOS/android-mtp" "$contents/MacOS/android-usb-watcher" "$app"; do
  codesign --force --sign "$identity" "$binary"
done
codesign --verify --deep --strict "$app"
printf '%s\n' "$PWD/$app"
