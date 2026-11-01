#!/bin/bash
# Print the Sparkle appcast for one release on stdout: one item, whose description
# holds the whole change log, so the app can show every version a user skipped.
#
#   SPARKLE_ED_KEY=<seed> scripts/make-appcast.sh <dmg> <version> <changelog>
#
# Environment:
#   SPARKLE_ED_KEY        required, the EdDSA seed; it reaches sign_update only by pipe
#   SIGN_UPDATE           default: Sparkle's sign_update in app/.build/artifacts
#   APPCAST_DOWNLOAD_BASE default: the GitHub release folder for this version
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)

die() {
  echo "make-appcast: $1" >&2
  exit 1
}

[[ $# == 3 ]] || {
  echo "usage: scripts/make-appcast.sh <dmg> <version> <changelog>" >&2
  exit 2
}
dmg=$1 version=$2 log=$3
sign_update=${SIGN_UPDATE:-$root/app/.build/artifacts/sparkle/Sparkle/bin/sign_update}
base=${APPCAST_DOWNLOAD_BASE:-https://github.com/jrmatherly/claude-multipass/releases/download/v$version}

[[ -n ${SPARKLE_ED_KEY:-} ]] || die "SPARKLE_ED_KEY is not set"
[[ -f $dmg ]] || die "$dmg not found"
changelog=$(cat "$log")
top=$(awk '/^## /{print $2; exit}' <<< "$changelog")
[[ $top == "$version" ]] || die "the top change log heading is $top, not $version"
# It would end the CDATA section and turn the rest of the change log into markup.
if grep -qF ']]>' <<< "$changelog"; then die "the change log contains ]]>"; fi

signature=$(printf '%s' "$SPARKLE_ED_KEY" | "$sign_update" --ed-key-file - -p "$dmg")
[[ -n $signature ]] || die "sign_update printed no signature"
printf '%s' "$SPARKLE_ED_KEY" | "$sign_update" --verify --ed-key-file - "$dmg" "$signature" > /dev/null || die "the signature does not verify"

minimum=$(plutil -extract LSMinimumSystemVersion raw -o - "$root/app/Info.plist.in").0

cat << APPCAST
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Claude Multipass</title>
    <item>
      <title>$version</title>
      <sparkle:version>$version</sparkle:version>
      <sparkle:minimumSystemVersion>$minimum</sparkle:minimumSystemVersion>
      <description sparkle:format="markdown"><![CDATA[$changelog]]></description>
      <enclosure url="$base/$(basename "$dmg")" length="$(stat -f %z "$dmg")" type="application/octet-stream" sparkle:edSignature="$signature"/>
    </item>
  </channel>
</rss>
APPCAST
