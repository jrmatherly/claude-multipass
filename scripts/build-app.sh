#!/bin/bash
# Build the menu bar app: swift build in release, assemble dist/Claude Multipass.app
# from app/Info.plist.in and the compiled icon, sign it with scripts/sign-mac-app.sh
# (unsigned when no Developer ID identity exists), and with --dmg package, sign and
# notarize a DMG.
#
#   scripts/build-app.sh [--dmg]
#
# The app module uses SwiftUI macros whose compiler plugin only Xcode ships, so
# when xcode-select points at the Command Line Tools and Xcode is installed the
# build goes through Xcode's developer dir (test/check.sh does the same).
set -euo pipefail

cd "$(dirname "$0")/.."

dmg=''
for arg in "$@"; do
  case $arg in
    --dmg) dmg=1 ;;
    *)
      echo "usage: scripts/build-app.sh [--dmg]" >&2
      exit 2
      ;;
  esac
done

swiftui_plugin=Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib
if [[ -z ${DEVELOPER_DIR:-} && ! -e "$(xcode-select -p)/$swiftui_plugin" && -e /Applications/Xcode.app/Contents/Developer/$swiftui_plugin ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

version=$(jq -r .version package.json)
app="dist/Claude Multipass.app"

swift build --package-path app -c release
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp app/.build/release/ClaudeMultipass "$app/Contents/MacOS/ClaudeMultipass"
install -m 755 bin/claude-multipass "$app/Contents/Resources/claude-multipass"
sed "s/@VERSION@/$version/g" app/Info.plist.in > "$app/Contents/Info.plist"
bash scripts/compile-icon.sh "$app/Contents/Resources"
printf 'APPL????' > "$app/Contents/PkgInfo"
MACOS_SIGN_ENTITLEMENTS="$PWD/app/ClaudeMultipass.entitlements" bash scripts/sign-mac-app.sh sign-app "$app"
echo "build-app: $app ($version)"

[[ -n $dmg ]] || exit 0
out="dist/claude-multipass-app_${version}_$(uname -m).dmg"
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
rm -f "$out"
hdiutil create -quiet -volname "Claude Multipass" -srcfolder "$staging" -format UDZO "$out"
bash scripts/sign-mac-app.sh sign-dmg "$out"
(cd dist && shasum -a 256 "$(basename "$out")" > "$(basename "$out").sha256")
echo "build-app: $out"
cat "$out.sha256"
