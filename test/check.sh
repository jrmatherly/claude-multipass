#!/bin/bash
#
# The whole gate: shell syntax, ShellCheck, formatting, the self-checks, the
# app's tests, the icon and the repo's own rules. Run: pnpm check
# A glob that matches nothing stays literal, so a missing script fails here
# instead of being skipped.

set -euo pipefail
# The self-checks grep for UTF-8 glyphs with bracket expressions, which match
# single bytes under the C locale that Claude Code's Bash tool runs in
export LC_ALL=en_US.UTF-8

cd "$(dirname "$0")/.."
# Run directly (not through pnpm), prettier is not on PATH otherwise
PATH=$PWD/node_modules/.bin:$PATH

shell_scripts=(
  bin/*
  test/*.sh
  .claude/hooks/*.sh
  raycast/*.sh
  scripts/*.sh
)

# bash -n checks only its first argument; the rest become positional args
for script in "${shell_scripts[@]}"; do
  bash -n "$script"
done
shellcheck --severity=warning "${shell_scripts[@]}"
prettier --log-level warn --ignore-unknown --check "**/*.{js,cjs,ts,md,json,sh}" "bin/*" ".github/**/*.yml"
# bin/claude-multipass against a fixture Desktop folder (never the real one)
bash test/claude-multipass.sh > /dev/null
# scripts/make-appcast.sh and scripts/verify-appcast.sh
bash test/appcast.sh > /dev/null
# the codesign retry in scripts/sign-mac-app.sh
bash test/sign-mac-app.sh > /dev/null
# make-appcast.sh refuses this, and a tag would find out only after notarizing
if grep -qF ']]>' CHANGELOG.md; then
  echo "check: CHANGELOG.md contains ]]>, which would end the appcast's CDATA section" >&2
  exit 1
fi
# The menu bar app, a debug build and its tests. The app module uses SwiftUI
# macros whose compiler plugin only Xcode ships (the Command Line Tools have
# the Testing plugin but not libSwiftUIMacros), so when xcode-select points at
# the Tools and Xcode is installed, build through Xcode's developer dir.
swiftui_plugin=Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib
if [[ -z ${DEVELOPER_DIR:-} && ! -e "$(xcode-select -p)/$swiftui_plugin" && -e /Applications/Xcode.app/Contents/Developer/$swiftui_plugin ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
swift_log=$(mktemp)
swift test --package-path app > "$swift_log" 2>&1 || {
  grep -vE 'ld: warning|^\s*$' "$swift_log" | tail -n 60 >&2
  echo "check: swift test failed (the app needs Xcode, not only the Command Line Tools; the last lines of its output are above)" >&2
  rm -f "$swift_log"
  exit 1
}
rm -f "$swift_log"
# The app icon compiles with this Xcode, or a tag finds out in release.yml
icon_out=$(mktemp -d)
bash scripts/compile-icon.sh "$icon_out"
rm -rf "$icon_out"
# the Claude Code hooks against sample payloads, and their wiring
for hook_check in .claude/hooks/test-*.sh; do
  bash "$hook_check" > /dev/null
done
# Every bin/ file has a comment on line 2
for file in bin/*; do
  sed -n 2p "$file" | grep -q '^#' || {
    echo "check: no header comment on line 2 of $file" >&2
    exit 1
  }
done
# The script's version= line and package.json agree
script_version=$(sed -n 's/^version=//p' bin/claude-multipass)
pkg_version=$(jq -r .version package.json)
[[ $script_version == "$pkg_version" ]] || {
  echo "check: bin/claude-multipass version=$script_version differs from package.json $pkg_version" >&2
  exit 1
}
# One file imports Sparkle, so Core and the UI stay testable without it
sparkle_importers=$(grep -rlE '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+([a-z]+[[:space:]]+)?Sparkle\b' app/Sources app/Tests | grep -vxF app/Sources/ClaudeMultipass/SparkleUpdater.swift || true)
[[ -z $sparkle_importers ]] || {
  echo "check: only SparkleUpdater.swift may import Sparkle, found: $sparkle_importers" >&2
  exit 1
}
# Both workflows pin the same ShellCheck release
pins=$(grep -ho 'SHELLCHECK_SHA256: *[0-9a-f]*' .github/workflows/check.yml .github/workflows/release.yml | tr -d ' ' | sort -u | wc -l | tr -d ' ')
[[ $pins == 1 ]] || {
  echo "check: check.yml and release.yml pin different ShellCheck releases" >&2
  exit 1
}
