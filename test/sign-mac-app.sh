#!/bin/bash
# Self-check for the codesign retry in scripts/sign-mac-app.sh, with stub codesign and sleep.
# No real identity, no network.
set -euo pipefail

cd "$(dirname "$0")/.."
script=$PWD/scripts/sign-mac-app.sh

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "sign-mac-app test: $1" >&2
  exit 1
}

mkdir "$tmp/bin"
# Fails the first $STUB_FAILS signing calls with $STUB_ERROR
cat > "$tmp/bin/codesign" << 'STUB'
#!/bin/bash
if [[ $* == *--verify* ]]; then
  echo "$*" >> "$STUB_DIR/verify-calls"
  exit 0
fi
echo "$*" >> "$STUB_DIR/sign-calls"
count=$(wc -l < "$STUB_DIR/sign-calls")
if [ "$count" -le "${STUB_FAILS:-0}" ]; then
  [ -z "$STUB_ERROR" ] || echo "$STUB_ERROR" >&2
  exit "${STUB_RC:-1}"
fi
echo "replacing existing signature" >&2
STUB
cat > "$tmp/bin/sleep" << 'STUB'
#!/bin/bash
echo "$1" >> "$STUB_DIR/sleeps"
STUB
chmod +x "$tmp/bin/codesign" "$tmp/bin/sleep"

export STUB_DIR=$tmp PATH="$tmp/bin:$PATH" MACOS_SIGN_IDENTITY=fixture
unset APPLE_API_KEY_ID APPLE_API_ISSUER_ID APPLE_API_KEY_P8 MACOS_SIGN_ENTITLEMENTS
timestamp_error="$tmp/x: A timestamp was expected but was not found."

dmg=$tmp/x.dmg
: > "$dmg"
# Runs the script on the DMG; sets rc, out and calls (signing calls made)
run_dmg() {
  rm -f "$tmp/sign-calls" "$tmp/sleeps" "$tmp/verify-calls"
  rc=0
  out=$(STUB_FAILS=$1 STUB_ERROR=$2 bash "$script" sign-dmg "$dmg" 2>&1) || rc=$?
  calls=$(wc -l < "$tmp/sign-calls" | tr -d ' ')
}

run_dmg 0 unused
[ "$rc" = 0 ] && [ "$calls" = 1 ] && [ ! -e "$tmp/sleeps" ] || fail "a clean signature: rc $rc, $calls calls"
[[ $out == *'replacing existing signature'* ]] || fail "a clean signature hid codesign's output: $out"
grep -q -- '--force --timestamp' "$tmp/sign-calls" || fail "signed without --force --timestamp"
[ -e "$tmp/verify-calls" ] || fail "the signature was not verified"

run_dmg 2 "$timestamp_error"
[ "$rc" = 0 ] && [ "$calls" = 3 ] || fail "two timestamp failures then a pass: rc $rc, $calls calls"
[[ $out == *'A timestamp was expected'* ]] || fail "a retried failure was not printed: $out"

run_dmg 99 "$timestamp_error"
[ "$rc" = 1 ] && [ "$calls" = 4 ] || fail "timestamp failures every time: rc $rc, $calls calls"
[ "$(tr '\n' ' ' < "$tmp/sleeps")" = "15 15 15 " ] || fail "expected three 15 s waits: $(tr '\n' ' ' < "$tmp/sleeps")"
[ ! -e "$tmp/verify-calls" ] || fail "verified after giving up"

run_dmg 99 "$tmp/x: errSecInternalComponent"
[ "$rc" = 1 ] && [ "$calls" = 1 ] && [ ! -e "$tmp/sleeps" ] || fail "another failure was retried: rc $rc, $calls calls"
[[ $out == *errSecInternalComponent* ]] || fail "another failure was not printed: $out"

export STUB_RC=3
run_dmg 99 ""
unset STUB_RC
[ "$rc" = 3 ] && [ "$calls" = 1 ] && [ "$out" = "${out//$'\n\n'/}" ] || fail "a silent failure: expected codesign's exit 3 and no blank line, got rc $rc: $out"

# A failing keychain lookup says so, whatever it decides next
cat > "$tmp/bin/security" << 'STUB'
#!/bin/bash
exit 1
STUB
chmod +x "$tmp/bin/security"
rc=0
out=$(env -u MACOS_SIGN_IDENTITY bash "$script" sign-dmg "$dmg" 2>&1) || rc=$?
[ "$rc" = 0 ] && [[ $out == *'security find-identity failed'* ]] || fail "the keychain failure was not reported: rc $rc: $out"

# A failed submission shows what notarytool said on stdout
cat > "$tmp/bin/xcrun" << 'STUB'
#!/bin/bash
echo '{"message":"the reason"}'
exit 1
STUB
chmod +x "$tmp/bin/xcrun"
rc=0
out=$(APPLE_API_KEY_ID=k APPLE_API_ISSUER_ID=i APPLE_API_KEY_P8=p bash "$script" sign-dmg "$dmg" 2>&1) || rc=$?
[ "$rc" = 1 ] && [[ $out == *'the reason'* ]] || fail "notarytool's reason was dropped: rc $rc: $out"

# The app route retries too, and only the app itself gets the entitlements
app=$tmp/X.app
sparkle=$app/Contents/Frameworks/Sparkle.framework
mkdir -p "$sparkle/Versions/B/Updater.app"
: > "$sparkle/Versions/B/Autoupdate"
rm -f "$tmp/sign-calls" "$tmp/sleeps"
STUB_FAILS=1 STUB_ERROR=$timestamp_error MACOS_SIGN_ENTITLEMENTS=$tmp/e.plist bash "$script" sign-app "$app" > /dev/null 2>&1 \
  || fail "the app route did not pass after one timestamp failure"
[ "$(grep -c -- '--options runtime' "$tmp/sign-calls")" = 5 ] || fail "the app route: expected 5 hardened signing calls"
[ "$(grep -c -- '--entitlements' "$tmp/sign-calls")" = 1 ] || fail "the entitlements reached a nested part"
! grep -q -- '--deep' "$tmp/sign-calls" || fail "signed with --deep, which hands the app's entitlements to Sparkle's helpers"
! grep -qv -- '--force --timestamp' "$tmp/sign-calls" || fail "a signing call without --force --timestamp"
order=$(awk -F/ '{print $NF}' "$tmp/sign-calls" | tr '\n' ' ')
[ "$order" = "Autoupdate Autoupdate Updater.app Sparkle.framework X.app " ] || fail "not signed inside out, or the failed part not retried first: $order"
[[ $(tail -n 1 "$tmp/sign-calls") == *"--entitlements $tmp/e.plist"*"$app" ]] || fail "the app itself did not get the entitlements"

echo "sign-mac-app: all checks passed"
