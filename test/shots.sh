#!/bin/bash
# pnpm shots [dir]: render the menu bar app's strip, popover and Settings tabs to PNGs, light and dark
#
# Runs the Shots suite in app/Tests over fixture state; it never runs the real
# tool or touches Desktop. The PNGs land in [dir], default .shots/ (ignored).
set -euo pipefail
cd "$(dirname "$0")/.."

dir=${1:-.shots}
mkdir -p "$dir"
dir=$(cd "$dir" && pwd -P)
# The same SwiftUI macro plugin rule as test/check.sh: the Command Line Tools
# lack it, so build through Xcode when it is installed
swiftui_plugin=Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib
if [[ -z ${DEVELOPER_DIR:-} && ! -e "$(xcode-select -p)/$swiftui_plugin" && -e /Applications/Xcode.app/Contents/Developer/$swiftui_plugin ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
UI_SHOTS_DIR=$dir swift test --package-path app --filter Shots
echo "shots: $(find "$dir" -name '*.png' | wc -l | tr -d ' ') PNGs in $dir"
