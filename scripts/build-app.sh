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
#
# Environment, all optional, for the update rehearsal:
#   APP_VERSION           default: package.json
#   APP_BUNDLE_ID         default: net.matherly.claude-multipass
#   SPARKLE_PUBLIC_KEY    default: the key whose seed signs real releases
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

version=${APP_VERSION:-$(jq -r .version package.json)}
bundle_id=${APP_BUNDLE_ID:-net.matherly.claude-multipass}
sparkle_key=${SPARKLE_PUBLIC_KEY:-lbhBShOOk5mkUbxO/Ln3Cc6N8USH2EC57/L5+/JvBs0=}
app="dist/Claude Multipass.app"

swift build --package-path app -c release
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp app/.build/release/ClaudeMultipass "$app/Contents/MacOS/ClaudeMultipass"
sed "s/@VERSION@/$version/g" app/Info.plist.in > "$app/Contents/Info.plist"
bash scripts/compile-icon.sh "$app/Contents/Resources"
printf 'APPL????' > "$app/Contents/PkgInfo"
sed -i '' -e "s/@BUNDLE_ID@/$bundle_id/g" -e "s|@SPARKLE_PUBLIC_KEY@|$sparkle_key|g" "$app/Contents/Info.plist"
sparkle="$app/Contents/Frameworks/Sparkle.framework"
ditto app/.build/release/Sparkle.framework "$sparkle"
# The XPC services only serve a sandboxed app, and this one is not sandboxed.
rm -rf "$sparkle/Versions/B/XPCServices" "$sparkle/XPCServices"
cp app/.build/artifacts/sparkle/Sparkle/LICENSE "$app/Contents/Resources/Sparkle-LICENSE"
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
