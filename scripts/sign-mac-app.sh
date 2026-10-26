#!/bin/bash
# sign-mac-app.sh - Developer ID signing and notarization for the menu bar app and its DMG.
# Copied from jrmatherly/ai-kb (scripts/sign-mac-app.sh), with MACOS_SIGN_ENTITLEMENTS added.
# The only place the repository calls codesign, notarytool or stapler.
#
#   sign-mac-app.sh sign-app <App.app>   sign with the hardened runtime and verify
#   sign-mac-app.sh sign-dmg <file.dmg>  sign, then notarize, staple and assess with spctl
#
# Environment, all optional:
#   MACOS_SIGN_IDENTITY   codesign identity; default: the first "Developer ID Application" identity
#                         that `security find-identity -v -p codesigning` lists
#   MACOS_SIGN_REQUIRED   any value: a missing identity is an error instead of a skip
#   MACOS_SIGN_ENTITLEMENTS
#                         an entitlements plist passed to codesign by sign-app
#   APPLE_API_KEY_ID, APPLE_API_ISSUER_ID, APPLE_API_KEY_P8
#                         App Store Connect API key (P8 = the .p8 file contents); all three or none.
#                         Only sign-dmg notarizes: the ticket covers the app inside the image.
#
# State                                   sign   notarize + staple + spctl
# API key partly set                      -      -                           exit 1
# no identity, nothing requires one       -      -                           exit 0, target left unsigned
# no identity, required or API key set    -      -                           exit 1
# identity, API key absent                yes    skipped
# identity, API key complete              yes    sign-dmg only, fatal when rejected
set -euo pipefail

usage() {
  echo "usage: $0 sign-app <App.app> | sign-dmg <file.dmg>" >&2
  exit 2
}
[ $# -eq 2 ] || usage
mode=$1 target=$2
case "$mode" in sign-app | sign-dmg) ;; *) usage ;; esac
[ -e "$target" ] || {
  echo "sign-mac-app: $target not found" >&2
  exit 1
}

key_vars=(APPLE_API_KEY_ID APPLE_API_ISSUER_ID APPLE_API_KEY_P8)
key_set=0
for v in "${key_vars[@]}"; do
  if [ -n "${!v:-}" ]; then key_set=$((key_set + 1)); fi
done
case $key_set in
  0)
    notarize=0
    echo "sign-mac-app: ${key_vars[*]} unset, skipping notarization"
    ;;
  3) notarize=1 ;;
  *)
    echo "sign-mac-app: ${key_set} of ${key_vars[*]} are set; set all three to notarize, or none to skip" >&2
    exit 1
    ;;
esac

identity="${MACOS_SIGN_IDENTITY:-}"
if [ -z "$identity" ]; then
  identity=$({ security find-identity -v -p codesigning 2> /dev/null || true; } \
    | sed -n '/"Developer ID Application: /{s/^[^"]*"\(.*\)"$/\1/p;q;}')
fi
if [ -z "$identity" ]; then
  if [ -n "${MACOS_SIGN_REQUIRED:-}" ] || [ "$notarize" = 1 ]; then
    echo "sign-mac-app: no Developer ID Application identity found and signing is required" >&2
    exit 1
  fi
  echo "sign-mac-app: no Developer ID Application identity found, leaving $target unsigned"
  exit 0
fi
echo "sign-mac-app: signing $target as $identity"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# notarytool exits 0 for a finished but rejected submission, so the status decides.
notarize_file() {
  local key out status id
  key="$work/AuthKey_${APPLE_API_KEY_ID:-}.p8"
  (umask 077 && printf '%s\n' "${APPLE_API_KEY_P8:-}" > "$key")
  out=$(xcrun notarytool submit "$1" --key "$key" --key-id "${APPLE_API_KEY_ID:-}" \
    --issuer "${APPLE_API_ISSUER_ID:-}" --wait --timeout 30m --output-format json) \
    || {
      echo "sign-mac-app: notarytool submit failed for $1" >&2
      exit 1
    }
  echo "$out"
  status=$(plutil -extract status raw -o - - <<< "$out")
  if [ "$status" != Accepted ]; then
    id=$(plutil -extract id raw -o - - <<< "$out" || true)
    echo "sign-mac-app: notarization of $1 ended as '$status'; details: xcrun notarytool log $id" >&2
    exit 1
  fi
}

case "$mode" in
  sign-app)
    entitlements=()
    [ -z "${MACOS_SIGN_ENTITLEMENTS:-}" ] || entitlements=(--entitlements "$MACOS_SIGN_ENTITLEMENTS")
    codesign --force --options runtime --timestamp ${entitlements[@]+"${entitlements[@]}"} --sign "$identity" "$target"
    codesign --verify --deep --strict --verbose=2 "$target"
    ;;
  sign-dmg)
    codesign --force --timestamp --sign "$identity" "$target"
    codesign --verify --verbose=2 "$target"
    if [ "$notarize" = 1 ]; then
      notarize_file "$target"
      xcrun stapler staple "$target"
      spctl -a -vv -t open --context context:primary-signature "$target"
    fi
    ;;
esac
