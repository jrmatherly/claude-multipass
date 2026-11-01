#!/bin/bash
# Self-check for scripts/make-appcast.sh, with a stub sign_update, and scripts/verify-appcast.sh,
# with real signatures from a throwaway key. No real key, no network.
set -euo pipefail

cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "appcast: $1" >&2
  exit 1
}

cat > "$tmp/sign_update" << 'STUB'
#!/bin/bash
cat >> "$STUB_DIR/stdin"
echo "$*" >> "$STUB_DIR/argv"
[[ $* != *--verify* ]] || exit "${STUB_VERIFY_EXIT:-0}"
[[ -z ${STUB_SIGN_EMPTY:-} ]] || exit 0
echo "${STUB_SIGNATURE:-FAKESIG==}"
STUB
chmod +x "$tmp/sign_update"

dmg="$tmp/claude-multipass-app_1.2.3_arm64.dmg"
printf 'not really a dmg' > "$dmg"
log="$tmp/CHANGELOG.md"
printf '# Changelog\n\n## 1.2.3 (2026-11-01)\n\n- A line with <markup> & an ampersand.\n\n## 1.2.2 (2026-10-31)\n\n- An older line.\n' > "$log"

export SIGN_UPDATE="$tmp/sign_update" STUB_DIR="$tmp" SPARKLE_ED_KEY=SECRETSEED
make_appcast() { bash scripts/make-appcast.sh "$@"; }

# Exit 1 with the expected message, so a refusal cannot pass on some other failure.
refused() {
  local name=$1 reason=$2 code=0 said
  shift 2
  said=$("$@" 2>&1 > /dev/null) || code=$?
  [[ $code == 1 ]] || fail "$name: expected exit 1, got $code"
  [[ $said == *"$reason"* ]] || fail "$name: expected '$reason', got '$said'"
}

out="$tmp/appcast.xml"
make_appcast "$dmg" 1.2.3 "$log" > "$out"

xmllint --noout "$out" || fail "the appcast is not well formed"
grep -q '<sparkle:version>1.2.3</sparkle:version>' "$out" || fail "no sparkle:version"
grep -q 'sparkle:edSignature="FAKESIG=="' "$out" || fail "no signature"
grep -q "length=\"$(stat -f %z "$dmg")\"" "$out" || fail "wrong length"
grep -q 'url="https://github.com/jrmatherly/claude-multipass/releases/download/v1.2.3/claude-multipass-app_1.2.3_arm64.dmg"' "$out" || fail "wrong default url"
grep -q '<sparkle:minimumSystemVersion>14.0.0</sparkle:minimumSystemVersion>' "$out" || fail "wrong minimum system"
grep -q 'sparkle:format="markdown"' "$out" || fail "no markdown format"
grep -qF 'A line with <markup> & an ampersand.' "$out" || fail "the change log is not in the description verbatim"
grep -qF 'An older line.' "$out" || fail "the description lost an older section"
if grep -q 'SECRETSEED' "$out"; then fail "the key reached the output"; fi
if grep -q 'SECRETSEED' "$tmp/argv"; then fail "the key reached sign_update's argv"; fi
grep -q 'SECRETSEED' "$tmp/stdin" || fail "the key did not reach sign_update on stdin"
grep -qF -- "-p $dmg" "$tmp/argv" || fail "the archive was not signed"
grep -qF -- "--verify --ed-key-file - $dmg FAKESIG==" "$tmp/argv" || fail "the archive's signature was not verified"

(cd "$tmp" && bash "$OLDPWD/scripts/make-appcast.sh" "$(basename "$dmg")" 1.2.3 "$(basename "$log")" > /dev/null) || fail "relative arguments do not resolve against the caller's folder"

base_url=$(APPCAST_DOWNLOAD_BASE=http://127.0.0.1:1 make_appcast "$dmg" 1.2.3 "$log")
grep -q 'url="http://127.0.0.1:1/claude-multipass-app_1.2.3_arm64.dmg"' <<< "$base_url" || fail "APPCAST_DOWNLOAD_BASE ignored"

printf '## 1.2.3 (2026-11-01)\n\n- Ends the section ]]> early.\n' > "$tmp/cdata.md"
refused "a change log containing ]]>" "contains ]]>" make_appcast "$dmg" 1.2.3 "$tmp/cdata.md"
refused "SPARKLE_ED_KEY unset" "SPARKLE_ED_KEY is not set" env -u SPARKLE_ED_KEY bash scripts/make-appcast.sh "$dmg" 1.2.3 "$log"
refused "a version that is not the top heading" "the top change log heading is 1.2.3, not 1.2.2" make_appcast "$dmg" 1.2.2 "$log"
refused "an Unreleased top heading" "the top change log heading is Unreleased, not 1.2.3" make_appcast "$dmg" 1.2.3 <(printf '## Unreleased\n\n- x\n\n## 1.2.3 (2026-11-01)\n')
refused "a missing archive" "none.dmg not found" make_appcast "$tmp/none.dmg" 1.2.3 "$log"
STUB_VERIFY_EXIT=1 refused "a signature that fails --verify" "does not verify" make_appcast "$dmg" 1.2.3 "$log"
STUB_SIGN_EMPTY=1 refused "no signature from sign_update" "printed no signature" make_appcast "$dmg" 1.2.3 "$log"

verify() { bash scripts/verify-appcast.sh "$@"; }
keys=$(ARCHIVE=$dmg swift -e 'import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
print(key.publicKey.rawRepresentation.base64EncodedString())
print(try! key.signature(for: FileManager.default.contents(atPath: ProcessInfo.processInfo.environment["ARCHIVE"]!)!).base64EncodedString())
print(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString())')
make_app() {
  mkdir -p "$1/Contents"
  plutil -create xml1 "$1/Contents/Info.plist"
  plutil -insert SUPublicEDKey -string "$2" "$1/Contents/Info.plist"
}
make_app "$tmp/Right.app" "$(sed -n 1p <<< "$keys")"
make_app "$tmp/Wrong.app" "$(sed -n 3p <<< "$keys")"
signed="$tmp/signed.xml"
STUB_SIGNATURE=$(sed -n 2p <<< "$keys") make_appcast "$dmg" 1.2.3 "$log" > "$signed"
verify "$tmp/Right.app" "$dmg" "$signed" || fail "a good release did not verify"
refused "a public key that is not the signer's" "does not accept" verify "$tmp/Wrong.app" "$dmg" "$signed"
printf 'not really a dmX' > "$tmp/same-size.dmg"
refused "bytes that were not signed" "does not accept" verify "$tmp/Right.app" "$tmp/same-size.dmg" "$signed"
printf 'longer than the signed archive' > "$tmp/longer.dmg"
refused "an archive of another size" "length" verify "$tmp/Right.app" "$tmp/longer.dmg" "$signed"
printf '<rss>' > "$tmp/broken.xml"
refused "a malformed appcast" "not well formed" verify "$tmp/Right.app" "$dmg" "$tmp/broken.xml"

echo "appcast: ok"
