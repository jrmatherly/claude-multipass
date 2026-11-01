#!/bin/bash
# Compile app/AppIcon.icon (Icon Composer's format) into <dir>/Assets.car, which
# macOS 26 and later read, and <dir>/AppIcon.icns, which earlier versions read.
# Needs Xcode's actool; build-app.sh and test/check.sh set DEVELOPER_DIR for it.
#
#   scripts/compile-icon.sh <dir>
set -euo pipefail

[[ $# == 1 ]] || {
  echo "usage: scripts/compile-icon.sh <dir>" >&2
  exit 2
}
out=$1
mkdir -p "$out"
# actool resolves a relative path against a directory of its own, not the caller's
out=$(cd "$out" && pwd)
rm -f "$out/Assets.car" "$out/AppIcon.icns"
# Info.plist.in already names the icon, so nothing reads the partial plist
log=$(xcrun actool "$(cd "$(dirname "$0")/.." && pwd)/app/AppIcon.icon" --compile "$out" --app-icon AppIcon \
  --platform macosx --target-device mac --minimum-deployment-target 14.0 \
  --output-partial-info-plist /dev/null --output-format human-readable-text 2>&1) || true
# actool exits 0 and writes nothing when it rejects the icon, so the files decide
[[ -s "$out/Assets.car" && -s "$out/AppIcon.icns" ]] || {
  printf '%s\n' "$log" >&2
  echo "compile-icon: actool wrote no Assets.car or AppIcon.icns in $out" >&2
  exit 1
}
