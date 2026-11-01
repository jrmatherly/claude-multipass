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
[[ $* != *--verify* ]] || exit 0
echo "$*" >> "$STUB_DIR/sign-calls"
count=$(wc -l < "$STUB_DIR/sign-calls")
if [ "$count" -le "${STUB_FAILS:-0}" ]; then
  echo "$STUB_ERROR" >&2
  exit 1
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
  rm -f "$tmp/sign-calls" "$tmp/sleeps"
  rc=0
  out=$(STUB_FAILS=$1 STUB_ERROR=$2 bash "$script" sign-dmg "$dmg" 2>&1) || rc=$?
  calls=$(wc -l < "$tmp/sign-calls" | tr -d ' ')
}

run_dmg 0 unused
[ "$rc" = 0 ] && [ "$calls" = 1 ] && [ ! -e "$tmp/sleeps" ] || fail "a clean signature: rc $rc, $calls calls"
[[ $out == *'replacing existing signature'* ]] || fail "a clean signature hid codesign's output: $out"

run_dmg 2 "$timestamp_error"
[ "$rc" = 0 ] && [ "$calls" = 3 ] || fail "two timestamp failures then a pass: rc $rc, $calls calls"
[[ $out == *'A timestamp was expected'* ]] || fail "a retried failure was not printed: $out"

run_dmg 99 "$timestamp_error"
[ "$rc" = 1 ] && [ "$calls" = 4 ] || fail "timestamp failures every time: rc $rc, $calls calls"

run_dmg 99 "$tmp/x: errSecInternalComponent"
[ "$rc" = 1 ] && [ "$calls" = 1 ] && [ ! -e "$tmp/sleeps" ] || fail "another failure was retried: rc $rc, $calls calls"
[[ $out == *errSecInternalComponent* ]] || fail "another failure was not printed: $out"

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
[[ $(tail -n 1 "$tmp/sign-calls") == *"--entitlements $tmp/e.plist"*"$app" ]] || fail "the app itself did not get the entitlements"

echo "sign-mac-app: all checks passed"
