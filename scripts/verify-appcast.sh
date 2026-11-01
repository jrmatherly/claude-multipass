#!/bin/bash
# Check a release from the outside, with no secret: the appcast is well formed, its length
# is the archive's, and the public key inside the app accepts its signature. sign_update
# --verify cannot show the last one, because it takes the same seed that signed.
#
#   scripts/verify-appcast.sh <app> <dmg> <appcast>
set -euo pipefail

die() {
  echo "verify-appcast: $1" >&2
  exit 1
}

[[ $# == 3 ]] || {
  echo "usage: scripts/verify-appcast.sh <app> <dmg> <appcast>" >&2
  exit 2
}
app=$1 dmg=$2 appcast=$3

enclosure_attribute() {
  xmllint --xpath "string(//*[local-name()='enclosure']/@*[local-name()='$1'])" "$appcast"
}

xmllint --noout "$appcast" 2> /dev/null || die "$appcast is not well formed"
[[ $(enclosure_attribute length) == "$(/usr/bin/stat -f %z "$dmg")" ]] || die "the appcast's length is not the size of $dmg"

KEY=$(plutil -extract SUPublicEDKey raw -o - "$app/Contents/Info.plist") \
SIGNATURE=$(enclosure_attribute edSignature) \
ARCHIVE=$dmg \
  swift -e 'import CryptoKit
import Foundation
let env = ProcessInfo.processInfo.environment
guard let key = Data(base64Encoded: env["KEY"]!),
  let signature = Data(base64Encoded: env["SIGNATURE"]!),
  let archive = FileManager.default.contents(atPath: env["ARCHIVE"]!),
  let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key),
  publicKey.isValidSignature(signature, for: archive)
else { exit(1) }' || die "the public key in $app does not accept the signature of $dmg"
