#!/bin/bash
#
# Self-check for claude-multipass against a fixture Desktop folder.
#
# - Run it (pnpm check does too); exits 1 naming the first failed assertion:
#
# `test/claude-multipass.sh`
#
# ---
# Never touches the real Claude Desktop folder: CLAUDE_DESKTOP_DIR and
# CLAUDE_MULTIPASS_DIR point into a temp dir, and pgrep, osascript, pkill,
# open, fzf, security and curl are stubbed on PATH so no app is quit or
# launched and no Keychain or network is touched.
#
# License: MIT

set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd -P)/bin/claude-multipass"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export CLAUDE_DESKTOP_DIR="$tmp/desktop" CLAUDE_MULTIPASS_DIR="$tmp/multipass"
d=$CLAUDE_DESKTOP_DIR p=$CLAUDE_MULTIPASS_DIR/profiles b=$CLAUDE_MULTIPASS_DIR/backups s=$CLAUDE_DESKTOP_DIR/claude-code-sessions
mkdir -p "$tmp/bin"
# pgrep says "not running" so quit is a no-op; the other three only log.
printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/pgrep"
for stub in osascript pkill open; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\n' "$stub" "$tmp" > "$tmp/bin/$stub"
done
# A stateful security stub. Every call and every `-i` stdin line goes to
# $tmp/security-calls, so the log tells the stdin route from the argv one the
# script takes for an item too large for a security -i line. The "Claude Safe
# Storage" read answers with the fixture password for usage.
pw='fixture pass!$'
cat > "$tmp/bin/security" << EOF
#!/bin/bash
kc="$tmp/keychain"
log="$tmp/security-calls"
pw='$pw'
EOF
cat >> "$tmp/bin/security" << 'EOF'
run() {
  local cmd=$1 a='' s='' hex='' want_w=''
  shift
  while [[ $# -gt 0 ]]; do
    case $1 in
      -a) a=$2; shift ;;
      -s) s=$2; shift ;;
      -w) want_w=1 ;;
      -X) hex=$2; shift ;;
    esac
    shift
  done
  # Failure hooks for the self-check: a refused write, a failed read of the CLI item.
  [[ -z ${SECURITY_FAIL_ADD:-} || $cmd != add-generic-password ]] || return 1
  [[ -z ${SECURITY_FAIL_FIND:-} || $cmd != find-generic-password || $s != 'Claude Code-credentials' ]] || return "$SECURITY_FAIL_FIND"
  case $cmd in
    add-generic-password)
      mkdir -p "$kc/$s"
      # Decoded straight to the file: a $(...) would strip a trailing newline the tool must not store.
      printf %s "$hex" | xxd -r -p > "$kc/$s/$a"
      ;;
    find-generic-password)
      if [[ $s == 'Claude Safe Storage' ]]; then printf %s "$pw"; return 0; fi
      [[ -f $kc/$s/$a ]] || { echo "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain." >&2; return 44; }
      # Like the real tool: a value with any non-printable byte (a newline) prints as hex.
      if [[ -n $want_w ]]; then
        if [[ $(LC_ALL=C tr -d '[:print:]' < "$kc/$s/$a" | wc -c) -gt 0 ]]; then xxd -p "$kc/$s/$a" | tr -d '\n'; else cat "$kc/$s/$a"; fi
      fi
      ;;
    delete-generic-password)
      [[ -f $kc/$s/$a ]] || return 44
      rm "$kc/$s/$a"
      ;;
    *) echo "security: unknown command $cmd" >&2; return 1 ;;
  esac
}
echo "security $*" >> "$log"
if [[ ${1:-} == -i ]]; then
  while IFS= read -r line; do
    echo "stdin $line" >> "$log"
    # The exact shape the script emits; the service name carries a space.
    [[ $line =~ ^add-generic-password\ -U\ -a\ \"([^\"]*)\"\ -s\ \"([^\"]*)\"\ -X\ ([0-9a-f]*)$ ]] \
      || { echo "security: unparsed line: $line" >&2; exit 1; }
    run add-generic-password -a "${BASH_REMATCH[1]}" -s "${BASH_REMATCH[2]}" -X "${BASH_REMATCH[3]}" || st=$?
  done
  # The real tool propagates the inner command's status (measured).
  exit "${st:-0}"
fi
run "$@"
EOF
# Decodes a hex read like the script does, so a UTF-8 value compares as bytes.
kc_get() {
  local v
  v=$(security find-generic-password -a "$2" -s "$1" -w 2> /dev/null) || {
    echo absent
    return
  }
  if [[ $v =~ ^[0-9a-f]+$ ]]; then printf %s "$v" | xxd -r -p; else printf %s "$v"; fi
}
kc_put() { printf 'add-generic-password -U -a "%s" -s "%s" -X %s\n' "$2" "$1" "$(printf %s "$3" | xxd -p | tr -d '\n')" | security -i > /dev/null; }
kc_delete() { security delete-generic-password -a "$2" -s "$1" > /dev/null 2>&1 || true; }
chmod +x "$tmp"/bin/*
export PATH="$tmp/bin:$PATH"
export CLAUDE_CLI_CONFIG="$tmp/claude.json" CLAUDE_CLI_HOME="$tmp/claude-home" CLAUDE_MULTIPASS_BIN="$script"
mkdir -p "$tmp/claude-home"
cda() { "$script" "$@"; }
pkg_version=$(jq -r .version "$(dirname "$script")/../package.json")

check() {
  if [[ $2 != "$3" ]]; then
    printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3" >&2
    exit 1
  fi
  echo "ok: $1"
}
check_true() {
  local name=$1
  shift
  "$@" || {
    echo "FAIL: $name" >&2
    exit 1
  }
  echo "ok: $name"
}
exit_code() {
  "$@" > /dev/null 2>&1 && echo 0 || echo $?
}

kc_put t u 'a "b" c'"'"'d'
check "security stub decodes a hex value" 'a "b" c'"'"'d' "$(kc_get t u)"
security add-generic-password -U -a u -s t -X "$(printf argv | xxd -p)"
check "security stub takes a hex value on argv too" argv "$(kc_get t u)"
check "security stub reports a missing item" 44 "$(
  security find-generic-password -a u -s none -w > /dev/null 2>&1
  echo $?
)"
kc_delete t u
check "security stub deletes" absent "$(kc_get t u)"
kc_put t u "$(printf 'a\nb')"
check "security stub prints a value with a newline as hex, like the real tool" 610a62 "$(security find-generic-password -a u -s t -w)"
check "and kc_get decodes it" 610a62 "$(kc_get t u | xxd -p)"
kc_delete t u

mkdir -p "$d" "$p/beta" "$s/aaaaaaaa-1111/org-a" "$s/bbbbbbbb-2222/org-b"
tab=$'\t'
printf '{\n\t"theme": "dark",\n\t"oauth:tokenCache": "enc-A1",\n\t"windowBounds": {\n\t\t"x": 1,\n\t\t"y": 2.50\n\t},\n\t"oauth:tokenCacheV2": "enc-A2",\n\t"lastKnownAccountUuid": "aaaaaaaa-1111",\n\t"zeta": [\n\t\t"é",\n\t\tnull\n\t]\n}' > "$d/config.json"
printf cookie-A > "$d/Cookies"
printf journal-A > "$d/Cookies-journal"

# The CLI is signed in as the same account as Desktop: claude.json carries the
# identity, the Keychain item the tokens plus shared MCP keys.
jq -n '{numStartups: 3, nested: {a: [1, 2], b: {c: "d"}}, k1: 1, k2: 2, k3: 3, k4: 4, k5: 5, k6: 6, k7: 7, k8: 8, k9: 9, k10: 10, k11: 11, k12: 12, k13: 13, k14: 14, k15: 15, k16: 16, k17: 17, k18: 18,
  oauthAccount: {accountUuid: "aaaaaaaa-1111", emailAddress: "a@example.com", organizationUuid: "org-alpha", organizationRole: "admin"}}' > "$tmp/claude.json"
live_item='{"claudeAiOauth":{"accessToken":"at-alpha","refreshToken":"rt-alpha","expiresAt":1,"scopes":["a"],"subscriptionType":"max"},"mcpOAuth":{"srv":"shared"},"trustedDeviceToken":"dev-alpha","trustedDeviceEnrolledAfterRefusalAtMs":5}'
kc_put "Claude Code-credentials" "$USER" "$live_item"

# save captures exactly the three keys and the cookie files
: > "$tmp/security-calls"
cda save alpha > /dev/null
check "save writes cli.json with the identity block" "$(jq -c .oauthAccount "$tmp/claude.json")" "$(jq -c .oauthAccount "$p/alpha/cli.json")"
check "save keeps cli.json private" 600 "$(stat -f %Lp "$p/alpha/cli.json")"
check "save stores the CLI tokens in the Keychain" '{"claudeAiOauth":{"accessToken":"at-alpha","refreshToken":"rt-alpha","expiresAt":1,"scopes":["a"],"subscriptionType":"max"},"trustedDeviceToken":"dev-alpha","trustedDeviceEnrolledAfterRefusalAtMs":5}' "$(kc_get claude-multipass alpha)"
check "save never puts the token on a command line" 0 "$(grep -c 'rt-alpha' "$tmp/security-calls")"
check "a small CLI item goes to security -i on stdin" 1 "$(grep -c '^stdin add-generic-password -U -a "alpha" -s "claude-multipass" -X [0-9a-f]*$' "$tmp/security-calls")"
check "and not on argv" 0 "$(grep -c '^security add-generic-password' "$tmp/security-calls")"
check "no token on disk in the store" 0 "$(grep -rl rt-alpha "$p" | wc -l | tr -d ' ')"
check "save keeps only the auth keys, in order" \
  '{"oauth:tokenCache":"enc-A1","oauth:tokenCacheV2":"enc-A2","lastKnownAccountUuid":"aaaaaaaa-1111"}' \
  "$(jq -c . "$p/alpha/config.json")"
check "save copies Cookies" cookie-A "$(cat "$p/alpha/Cookies")"
check "save copies Cookies-journal" journal-A "$(cat "$p/alpha/Cookies-journal")"
check "save records the account" aaaaaaaa-1111 "$(jq -r .account "$p/alpha/meta.json")"
check "save writes the profile config private" 600 "$(stat -f %Lp "$p/alpha/config.json")"
check "save writes meta.json private" 600 "$(stat -f %Lp "$p/alpha/meta.json")"
check "save relaunches the app" "open -a Claude" "$(cat "$tmp/calls")"
rm "$tmp/calls"

# A CLI signed in by hand as another account, or signed out, leaves the saved CLI login alone
cp "$tmp/claude.json" "$tmp/claude-alpha.json"
jq '.oauthAccount.accountUuid = "zzzzzzzz-9999"' "$tmp/claude.json" > "$tmp/claude.json.new" && mv "$tmp/claude.json.new" "$tmp/claude.json"
err=$(cda save alpha --no-relaunch 2>&1 > /dev/null)
check_true "save warns when the CLI is on another account" grep -q 'Claude Code is signed in as a different account, or signed out; saved the Desktop login only' <<< "$err"
check "a mismatched save keeps cli.json" aaaaaaaa-1111 "$(jq -r .oauthAccount.accountUuid "$p/alpha/cli.json")"
check "a mismatched save keeps the saved item" at-alpha "$(kc_get claude-multipass alpha | jq -r .claudeAiOauth.accessToken)"
check_true "save with CLAUDE_CONFIG_DIR skips the CLI login" grep -q 'CLAUDE_CONFIG_DIR is set; the CLI login is not saved or switched' <<< "$(CLAUDE_CONFIG_DIR=/x cda save alpha --no-relaunch 2>&1 > /dev/null)"
check_true "save with CLAUDE_SECURESTORAGE_CONFIG_DIR skips the CLI login" grep -q 'CLAUDE_SECURESTORAGE_CONFIG_DIR is set; the CLI login is not saved or switched' <<< "$(CLAUDE_SECURESTORAGE_CONFIG_DIR=/x cda save alpha --no-relaunch 2>&1 > /dev/null)"
check "an empty CLAUDE_SECURESTORAGE_CONFIG_DIR does not block the save" 0 "$(CLAUDE_SECURESTORAGE_CONFIG_DIR='' cda save alpha --no-relaunch 2>&1 > /dev/null | grep -c 'CLAUDE_SECURESTORAGE_CONFIG_DIR is set')"
cp "$tmp/claude-alpha.json" "$tmp/claude.json"
kc_delete "Claude Code-credentials" "$USER"
check_true "save warns when the CLI is signed out" grep -q 'signed in as a different account, or signed out' <<< "$(cda save alpha --no-relaunch 2>&1 > /dev/null)"
check "a signed-out save keeps the saved item" at-alpha "$(kc_get claude-multipass alpha | jq -r .claudeAiOauth.accessToken)"
kc_put "Claude Code-credentials" "$USER" "$live_item"
err=$(SECURITY_FAIL_ADD=1 cda save alpha --no-relaunch 2>&1 > /dev/null)
check_true "a refused Keychain write on save warns" grep -q 'alpha: security exited 1 saving the CLI login; saved the Desktop login only' <<< "$err"
check "and keeps the earlier saved item" at-alpha "$(kc_get claude-multipass alpha | jq -r .claudeAiOauth.accessToken)"
check "and still saved the Desktop login" aaaaaaaa-1111 "$(jq -r .lastKnownAccountUuid "$p/alpha/config.json")"

printf '{"oauth:tokenCache":"enc-B1","oauth:tokenCacheV2":"enc-B2","lastKnownAccountUuid":"bbbbbbbb-2222"}' > "$p/beta/config.json"
printf '{"account":"bbbbbbbb-2222","savedAt":"2026-01-01T00:00:00Z"}' > "$p/beta/meta.json"
printf cookie-B > "$p/beta/Cookies"
kc_put claude-multipass beta '{"claudeAiOauth":{"accessToken":"at-beta","refreshToken":"rt-beta","expiresAt":2,"scopes":["a"],"subscriptionType":"max"}}'
printf '{"oauthAccount":{"accountUuid":"bbbbbbbb-2222","emailAddress":"b@example.com","organizationUuid":"org-beta"}}' > "$p/beta/cli.json"
# claude on PATH answers the verification after a restore
printf '#!/bin/sh\nls -d "%s"/claude.json.lock "%s"/claude-home/.oauth_refresh.lock "%s"/claude-home.lock 2> /dev/null | wc -l | tr -d " " > "%s/locks-at-verify"\necho "{\\"loggedIn\\":true,\\"orgId\\":\\"org-beta\\"}"\n' "$tmp" "$tmp" "$tmp" "$tmp" > "$tmp/bin/claude"
chmod +x "$tmp/bin/claude"
cp "$tmp/claude.json" "$tmp/claude-before.json"

printf '{"lastActivityAt":100,"title":"one"}' > "$s/aaaaaaaa-1111/org-a/local_s1.json"
printf '{"lastActivityAt":200}' > "$s/aaaaaaaa-1111/org-a/local_s2.json"
printf '{"lastActivityAt":150}' > "$s/bbbbbbbb-2222/org-b/local_s2.json"
printf '{"lastActivityAt":300}' > "$s/aaaaaaaa-1111/org-a/local_s3.json"
touch "$s/bbbbbbbb-2222/org-b/deleted_s3"
printf '{"lastActivityAt":50}' > "$s/bbbbbbbb-2222/org-b/local_s4.json"
printf '{}' > "$s/aaaaaaaa-1111/org-a/local_s5.json"
printf '{"old":true}' > "$s/bbbbbbbb-2222/org-b/local_s5.json"
touch -t 202001010000 "$s/bbbbbbbb-2222/org-b/local_s5.json"
# Same mtime, different content: the mtime prefilter must not hide a newer lastActivityAt
touch -t 202101010000 "$s/aaaaaaaa-1111/org-a/local_s2.json" "$s/bbbbbbbb-2222/org-b/local_s2.json"

# A token refresh since the save, which switch must keep by re-saving alpha
before=$(jq --tab '.["oauth:tokenCacheV2"] = "enc-A2-new"' "$d/config.json")
printf '%s' "$before" > "$d/config.json"

: > "$tmp/security-calls"
out=$(cda switch beta --no-relaunch 2> "$tmp/switch-err" | tee "$tmp/switch-out")
check "switch merges keys in place, other keys byte-identical" \
  "{
${tab}\"theme\": \"dark\",
${tab}\"oauth:tokenCache\": \"enc-B1\",
${tab}\"windowBounds\": {
${tab}${tab}\"x\": 1,
${tab}${tab}\"y\": 2.50
${tab}},
${tab}\"oauth:tokenCacheV2\": \"enc-B2\",
${tab}\"lastKnownAccountUuid\": \"bbbbbbbb-2222\",
${tab}\"zeta\": [
${tab}${tab}\"é\",
${tab}${tab}null
${tab}]
}" "$(cat "$d/config.json")"
check "switch keeps config.json private" 600 "$(stat -f %Lp "$d/config.json")"
check "switch re-saves the outgoing profile" enc-A2-new "$(jq -r '.["oauth:tokenCacheV2"]' "$p/alpha/config.json")"
check "switch restores Cookies" cookie-B "$(cat "$d/Cookies")"
check_true "switch removes a Cookies-journal the profile lacks" test ! -e "$d/Cookies-journal"
check "switch writes one backup folder beside the store" 1 "$(find "$b" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
check "backup is the previous config" "$before" "$(cat "$b"/*/config.json)"
check "backup holds the previous cookies" cookie-A "$(cat "$b"/*/Cookies)"
check_true "--no-relaunch does not launch" test ! -e "$tmp/calls"
check "switch restores the CLI tokens" at-beta "$(kc_get "Claude Code-credentials" "$USER" | jq -r .claudeAiOauth.accessToken)"
check "switch keeps the shared MCP keys" '{"srv":"shared"}' "$(kc_get "Claude Code-credentials" "$USER" | jq -c .mcpOAuth)"
check "switch drops the previous device token" null "$(kc_get "Claude Code-credentials" "$USER" | jq -r .trustedDeviceToken)"
check "switch drops the previous account's enrolment stamp" null "$(kc_get "Claude Code-credentials" "$USER" | jq -r .trustedDeviceEnrolledAfterRefusalAtMs)"
check "switch replaces oauthAccount" bbbbbbbb-2222 "$(jq -r .oauthAccount.accountUuid "$tmp/claude.json")"
check "switch leaves the other claude.json keys as they were" "$(jq -S 'del(.oauthAccount)' "$tmp/claude-before.json")" "$(jq -S 'del(.oauthAccount)' "$tmp/claude.json")"
check "switch keeps claude.json private" 600 "$(stat -f %Lp "$tmp/claude.json")"
dest=$(sed -n 's/^Backed up the current login to //p' "$tmp/switch-out")
check "switch backs up the previous CLI tokens" at-alpha "$(kc_get claude-multipass "$(basename "$dest")" | jq -r .claudeAiOauth.accessToken)"
check "switch backs up the previous identity" aaaaaaaa-1111 "$(jq -r .oauthAccount.accountUuid "$dest/cli.json")"
check "switch re-saves the outgoing CLI login" at-alpha "$(kc_get claude-multipass alpha | jq -r .claudeAiOauth.accessToken)"
check "switch releases the CLI locks" 0 "$(ls -d "$tmp"/claude.json.lock "$tmp"/claude-home/.oauth_refresh.lock "$tmp"/claude-home.lock 2> /dev/null | wc -l | tr -d ' ')"
check "a matching org raises no warning" 0 "$(grep -c 'different org' "$tmp/switch-err")"
check "the CLI locks are released before claude auth status runs" 0 "$(cat "$tmp/locks-at-verify")"
check "a clean switch warns nothing" "" "$(cat "$tmp/switch-err")"
check "the stored CLI value has no trailing newline" '}' "$(kc_get claude-multipass alpha | tail -c 1)"
check "switch never puts a token on a command line" 0 "$(grep -c 'at-beta\|rt-beta\|at-alpha' "$tmp/security-calls")"

# sync (run by switch)
check "sync output" "aaaaaaaa-1111/org-a: 1 written
bbbbbbbb-2222/org-b: 3 written" "$(grep written <<< "$out")"
check "sync copies a missing pointer" '{"lastActivityAt":100,"title":"one"}' "$(cat "$s/bbbbbbbb-2222/org-b/local_s1.json")"
check "sync prefers the newer lastActivityAt despite equal mtimes" 200 "$(jq .lastActivityAt "$s/bbbbbbbb-2222/org-b/local_s2.json")"
check "sync keeps the newer copy" 200 "$(jq .lastActivityAt "$s/aaaaaaaa-1111/org-a/local_s2.json")"
check_true "sync skips a tombstoned id" test ! -e "$s/bbbbbbbb-2222/org-b/local_s3.json"
check_true "sync never deletes" test -e "$s/aaaaaaaa-1111/org-a/local_s3.json" -a -e "$s/bbbbbbbb-2222/org-b/deleted_s3"
check "sync copies the other way" 50 "$(jq .lastActivityAt "$s/aaaaaaaa-1111/org-a/local_s4.json")"
check "sync falls back to mtime" '{}' "$(cat "$s/bbbbbbbb-2222/org-b/local_s5.json")"
check "sync is idempotent" "aaaaaaaa-1111/org-a: 0 written
bbbbbbbb-2222/org-b: 0 written" "$(cda sync)"
check "switch to the signed-in account only syncs" "beta is already signed in" "$(cda switch beta --no-relaunch | head -1)"
rm "$d/Cookies"
cda switch beta --no-relaunch > /dev/null
check "same-name switch repairs missing cookies" cookie-B "$(cat "$d/Cookies")"

# The CLI already on the target account: its live tokens are fresher than the saved ones, so switch re-saves them and writes nothing
kc_put "Claude Code-credentials" "$USER" "$(kc_get "Claude Code-credentials" "$USER" | jq -c '.claudeAiOauth.accessToken = "at-beta-fresh"')"
n_backups=$(ls -1d "$b"/login-*/ | wc -l | tr -d ' ')
out=$(cda switch beta --no-relaunch)
check "switch to the signed-in account re-saves the live CLI login" "beta is already signed in" "$(head -1 <<< "$out")"
check "and writes no backup folder" "$n_backups" "$(ls -1d "$b"/login-*/ | wc -l | tr -d ' ')"
check "and leaves the live tokens alone" at-beta-fresh "$(kc_get "Claude Code-credentials" "$USER" | jq -r .claudeAiOauth.accessToken)"
check "and the profile now holds them" at-beta-fresh "$(kc_get claude-multipass beta | jq -r .claudeAiOauth.accessToken)"

# The CLI's identity says the target account but its Keychain item is gone: restore the saved one
kc_delete "Claude Code-credentials" "$USER"
check_true "a same-account switch with the live item gone restores it" grep -q 'beta is already signed in' <<< "$(cda switch beta --no-relaunch)"
check "and the live item is back" at-beta-fresh "$(kc_get "Claude Code-credentials" "$USER" | jq -r .claudeAiOauth.accessToken)"

# A hand login as a foreign account on the way out: the outgoing profile's CLI login is left alone, the target's restored
jq '.oauthAccount.accountUuid = "zzzzzzzz-9999"' "$tmp/claude.json" > "$tmp/claude.json.new" && mv "$tmp/claude.json.new" "$tmp/claude.json"
kc_put "Claude Code-credentials" "$USER" "$(kc_get "Claude Code-credentials" "$USER" | jq -c '.claudeAiOauth.accessToken = "at-foreign"')"
err=$(cda switch alpha --no-relaunch 2>&1 > /dev/null)
check_true "a foreign CLI login warns on the way out" grep -q 'signed in as a different account, or signed out; saved the Desktop login only' <<< "$err"
check "and leaves the outgoing profile's CLI login alone" at-beta-fresh "$(kc_get claude-multipass beta | jq -r .claudeAiOauth.accessToken)"
check "and still restores the target's CLI login" at-alpha "$(kc_get "Claude Code-credentials" "$USER" | jq -r .claudeAiOauth.accessToken)"
check "and its identity" aaaaaaaa-1111 "$(jq -r .oauthAccount.accountUuid "$tmp/claude.json")"

# A live item larger than a real one (20 KB of MCP logins) moves whole: too
# long for a security -i line, its hex goes on security's argv, as Claude
# Code writes it. The backup item keeps the account part only.
big=$(printf 'x%.0s' $(seq 1 20000))
big_item="{\"claudeAiOauth\":{\"accessToken\":\"at-alpha\"},\"mcpOAuth\":\"$big\"}"
kc_put "Claude Code-credentials" "$USER" "$big_item"
: > "$tmp/security-calls"
out=$(cda switch beta --no-relaunch 2> "$tmp/big-err")
check "a 20 KB live item warns nothing" "" "$(cat "$tmp/big-err")"
check "and the live item is the shared keys plus the saved account part, byte for byte" "$(jq -c --argjson s "$(kc_get claude-multipass beta)" '{mcpOAuth, mcpOAuthClientConfig, mcpXaaIdp, mcpXaaIdpConfig, pluginSecrets} | with_entries(select(.value != null)) + $s' <<< "$big_item")" "$(kc_get "Claude Code-credentials" "$USER")"
check "and its write went on security's argv" 1 "$(grep -c "^security add-generic-password -U -a $USER -s Claude Code-credentials -X [0-9a-f]*$" "$tmp/security-calls")"
check "and only that write did" 1 "$(grep -c '^security add-generic-password' "$tmp/security-calls")"
check "and nothing about the token reached stdout or stderr" 0 "$(grep -c 'at-beta\|61742d62657461' <<< "$out$(cat "$tmp/big-err")")"
check "and the backup item holds the account part only" '["claudeAiOauth"]' "$(kc_get claude-multipass "$(basename "$(ls -1d "$b"/login-*/ | sort | tail -1)")" | jq -c keys)"
cda switch alpha --no-relaunch > /dev/null 2>&1
kc_put "Claude Code-credentials" "$USER" "$live_item"

# A live item with a non-ASCII byte comes back from security -w as hex (measured
# on the real tool); the tool decodes it, so the merge still sees JSON
utf8_item='{"claudeAiOauth":{"accessToken":"at-alpha"},"mcpOAuth":{"caf\u00e9":"\xe2\x9c\x93"}}'
kc_put "Claude Code-credentials" "$USER" "$(printf "$utf8_item")"
err=$(cda switch beta --no-relaunch 2>&1 > /dev/null)
check "a live item with UTF-8 bytes warns nothing" "" "$err"
check "and its shared keys survive the hex read" "$(printf '\xe2\x9c\x93')" "$(kc_get "Claude Code-credentials" "$USER" | jq -r '.mcpOAuth["caf\u00e9"]')"
cda switch alpha --no-relaunch > /dev/null 2>&1

# The route boundary: a security -i line of at most 4000 bytes, argv above it.
# The profile item is the account part, so its size follows the token.
: > "$tmp/security-calls"
kc_put "Claude Code-credentials" "$USER" "{\"claudeAiOauth\":{\"accessToken\":\"$(printf 'y%.0s' $(seq 1 1900))\"}}"
cda save alpha --no-relaunch > /dev/null 2>&1
check "a profile item just under the line limit goes to security -i" 1 "$(grep -c '^stdin add-generic-password -U -a "alpha"' "$tmp/security-calls")"
: > "$tmp/security-calls"
kc_put "Claude Code-credentials" "$USER" "{\"claudeAiOauth\":{\"accessToken\":\"$(printf 'y%.0s' $(seq 1 1990))\"}}"
cda save alpha --no-relaunch > /dev/null 2>&1
check "and one just over it goes on argv" 1 "$(grep -c '^security add-generic-password -U -a alpha ' "$tmp/security-calls")"
check "and not to security -i" 0 "$(grep -c '^stdin add-generic-password -U -a "alpha"' "$tmp/security-calls")"
# Alpha's live item and saved item are put back for the cases that follow
kc_put "Claude Code-credentials" "$USER" "$live_item"
cda save alpha --no-relaunch > /dev/null 2>&1

# A Mac where the CLI never ran (no ~/.claude.json): Desktop only, nothing created
mv "$tmp/claude.json" "$tmp/claude-aside.json"
check_true "switch without a claude.json says the CLI never ran here" grep -q 'Claude Code has not run on this Mac; switched Desktop only' <<< "$(cda switch beta --no-relaunch 2>&1 > /dev/null)"
check_true "and creates no claude.json" test ! -e "$tmp/claude.json"
check "and leaves the live item alone" at-alpha "$(kc_get "Claude Code-credentials" "$USER" | jq -r .claudeAiOauth.accessToken)"
mv "$tmp/claude-aside.json" "$tmp/claude.json"
cda switch alpha --no-relaunch > /dev/null 2>&1

# security refuses the write (a locked Keychain, a denied prompt): nothing is written over a login that has no copy
err=$(SECURITY_FAIL_ADD=1 cda switch beta --no-relaunch 2>&1 > /dev/null)
check_true "a failed CLI backup warns" grep -q 'could not back up the CLI login; switched Desktop only' <<< "$err"
check "and the profile's saved item survives" at-beta-fresh "$(kc_get claude-multipass beta | jq -r .claudeAiOauth.accessToken)"
check "and leaves the live CLI item alone" at-alpha "$(kc_get "Claude Code-credentials" "$USER" | jq -r .claudeAiOauth.accessToken)"
check "and leaves oauthAccount alone" aaaaaaaa-1111 "$(jq -r .oauthAccount.accountUuid "$tmp/claude.json")"
check "and still switches Desktop" bbbbbbbb-2222 "$(jq -r .lastKnownAccountUuid "$d/config.json")"
cda switch alpha --no-relaunch > /dev/null 2>&1

# security fails the read of the CLI item with another status: the status is named, nothing moves
err=$(SECURITY_FAIL_FIND=36 cda switch beta --no-relaunch 2>&1 > /dev/null)
check_true "a failed read on the way out names the status and the profile" grep -q 'alpha: security exited 36 (no Keychain prompt is possible here: a shell over SSH, a hook, or a timer) reading the CLI login; saved the Desktop login only' <<< "$err"
check_true "a failed read on the restore names the status" grep -q 'security exited 36 (no Keychain prompt is possible here: a shell over SSH, a hook, or a timer) reading the CLI login; switched Desktop only' <<< "$err"
check "and leaves the live CLI item alone" at-alpha "$(kc_get "Claude Code-credentials" "$USER" | jq -r .claudeAiOauth.accessToken)"
check "and leaves oauthAccount alone" aaaaaaaa-1111 "$(jq -r .oauthAccount.accountUuid "$tmp/claude.json")"
cda switch alpha --no-relaunch > /dev/null 2>&1

# CLAUDE_CONFIG_DIR: the CLI has a per-directory item the tool does not know
check_true "switch with CLAUDE_CONFIG_DIR skips the CLI login" grep -q 'CLAUDE_CONFIG_DIR is set; the CLI login is not saved or switched' <<< "$(CLAUDE_CONFIG_DIR=/x cda switch beta --no-relaunch 2>&1 > /dev/null)"
check "and leaves oauthAccount alone" aaaaaaaa-1111 "$(jq -r .oauthAccount.accountUuid "$tmp/claude.json")"
CLAUDE_CONFIG_DIR=/x cda switch alpha --no-relaunch > /dev/null 2>&1
# CLAUDE_SECURESTORAGE_CONFIG_DIR moves the item the same way (2.1.310)
check_true "switch with CLAUDE_SECURESTORAGE_CONFIG_DIR skips the CLI login" grep -q 'CLAUDE_SECURESTORAGE_CONFIG_DIR is set; the CLI login is not saved or switched' <<< "$(CLAUDE_SECURESTORAGE_CONFIG_DIR=/x cda switch beta --no-relaunch 2>&1 > /dev/null)"
check "and leaves oauthAccount alone too" aaaaaaaa-1111 "$(jq -r .oauthAccount.accountUuid "$tmp/claude.json")"
CLAUDE_SECURESTORAGE_CONFIG_DIR=/x cda switch alpha --no-relaunch > /dev/null 2>&1

# A corrupt ~/.claude.json (the CLI rewrites it often): Desktop only, nothing aborted
cp "$tmp/claude.json" "$tmp/claude-good.json"
printf 'not json' > "$tmp/claude.json"
st=0
err=$(cda switch beta --no-relaunch 2>&1 > "$tmp/corrupt-cfg-out") || st=$?
check "a corrupt claude.json does not abort the switch" 0 "$st"
check_true "and warns" grep -q 'claude.json is not valid JSON; switched Desktop only' <<< "$err"
check_true "and the session lists were still merged" grep -q written "$tmp/corrupt-cfg-out"
check "and the live CLI item is left alone" at-alpha "$(kc_get "Claude Code-credentials" "$USER" | jq -r .claudeAiOauth.accessToken)"
cp "$tmp/claude-good.json" "$tmp/claude.json"
check "a switch after repairing claude.json succeeds" 0 "$(exit_code cda switch alpha --no-relaunch)"

# The claude.json write fails after the Keychain write: the live item is put back, nothing half-moved
mkdir "$tmp/claude.json.tmp"
err=$(cda switch beta --no-relaunch 2>&1 > /dev/null)
check_true "a failed claude.json write warns and names the backup" grep -q "could not write $tmp/claude.json; the CLI login was put back" <<< "$err"
check "and the live CLI item is back to the previous login" at-alpha "$(kc_get "Claude Code-credentials" "$USER" | jq -r .claudeAiOauth.accessToken)"
check "and oauthAccount still names it" aaaaaaaa-1111 "$(jq -r .oauthAccount.accountUuid "$tmp/claude.json")"
rmdir "$tmp/claude.json.tmp"
cda switch alpha --no-relaunch > /dev/null 2>&1
check "claude.json is written 2-space indented with a final newline, as the CLI writes it" "$(jq --indent 2 . "$tmp/claude.json")" "$(cat "$tmp/claude.json")"

# A held CLI lock during save: the Desktop login is saved, the CLI part skipped with a warning
mkdir "$tmp/claude.json.lock"
st=0
err=$(cda save alpha --no-relaunch 2>&1 > /dev/null) || st=$?
check "a held lock does not fail save" 0 "$st"
check_true "and says the CLI part was skipped" grep -q 'Claude Code holds .*claude.json.lock; saved the Desktop login only' <<< "$err"
rmdir "$tmp/claude.json.lock"

# A live item that is not JSON (another tool's truncated write): Desktop only, nothing aborted
kc_put "Claude Code-credentials" "$USER" 'not json'
st=0
err=$(cda switch beta --no-relaunch 2>&1 > "$tmp/corrupt-out") || st=$?
check "a corrupt live CLI item does not abort the switch" 0 "$st"
check_true "and warns" grep -q 'the live CLI login is not valid JSON; switched Desktop only' <<< "$err"
check_true "and the session lists were still merged" grep -q written "$tmp/corrupt-out"
check "and the corrupt item is left alone" 'not json' "$(kc_get "Claude Code-credentials" "$USER")"
check_true "a corrupt live item never passes for the target's login" grep -q 'the live CLI login is not valid JSON; switched Desktop only' <<< "$(cda switch alpha --no-relaunch 2>&1 > /dev/null)"
check "and keeps the profile item" at-beta-fresh "$(kc_get claude-multipass beta | jq -r .claudeAiOauth.accessToken)"
kc_put "Claude Code-credentials" "$USER" "$live_item"

# A profile saved by 0.2.x has no CLI login
mkdir -p "$p/legacy"
printf '{"oauth:tokenCache":"enc-C1","oauth:tokenCacheV2":"enc-C2","lastKnownAccountUuid":"cccccccc-3333"}' > "$p/legacy/config.json"
printf '{"account":"cccccccc-3333","savedAt":"2026-01-01T00:00:00Z"}' > "$p/legacy/meta.json"
check_true "switch to a legacy profile says it switched Desktop only" grep -q 'no CLI login saved for legacy; switched Desktop only' <<< "$(cda switch legacy --no-relaunch 2>&1 > /dev/null)"
check "and leaves oauthAccount alone" aaaaaaaa-1111 "$(jq -r .oauthAccount.accountUuid "$tmp/claude.json")"

# cli.json without its Keychain item
kc_delete claude-multipass beta
check_true "a missing saved item warns" grep -q 'the saved CLI login for beta is missing from the Keychain; run claude auth login, then save beta' <<< "$(cda switch beta --no-relaunch 2>&1 > /dev/null)"
check "and leaves oauthAccount alone" aaaaaaaa-1111 "$(jq -r .oauthAccount.accountUuid "$tmp/claude.json")"
kc_put claude-multipass beta '{"claudeAiOauth":{"accessToken":"at-beta","refreshToken":"rt-beta","expiresAt":2,"scopes":["a"],"subscriptionType":"max"}}'

# The CLI's locks: a stale one is removed, a fresh one fails the switch before Desktop's config is touched
mkdir "$tmp/claude-home/.oauth_refresh.lock"
touch -t 202001010000 "$tmp/claude-home/.oauth_refresh.lock"
check "a stale CLI lock does not block the switch" 0 "$(exit_code cda switch alpha --no-relaunch)"
check_true "and is removed" test ! -e "$tmp/claude-home/.oauth_refresh.lock"
mkdir "$tmp/claude.json.lock"
cp "$d/config.json" "$tmp/config-locked"
check "a held CLI lock fails the switch" 1 "$(exit_code cda switch beta --no-relaunch)"
check_true "and Desktop's config is untouched" cmp -s "$d/config.json" "$tmp/config-locked"
check "and oauthAccount too" aaaaaaaa-1111 "$(jq -r .oauthAccount.accountUuid "$tmp/claude.json")"
check_true "and the tool's own locks are released" test ! -e "$tmp/claude-home/.oauth_refresh.lock" -a ! -e "$tmp/claude-home.lock"
rmdir "$tmp/claude.json.lock"

# Verification after a restore: claude auth status must report the restored org
printf '#!/bin/sh\necho "{\\"loggedIn\\":true,\\"orgId\\":\\"org-other\\"}"\n' > "$tmp/bin/claude"
err=$(cda switch beta --no-relaunch 2>&1 > /dev/null)
check_true "an org mismatch warns and names the backup" grep -q "Claude Code reports a different org; the previous login is in $b/login-" <<< "$err"
printf '#!/bin/sh\necho "{\\"loggedIn\\":false}"\n' > "$tmp/bin/claude"
err=$(cda switch alpha --no-relaunch 2>&1 > /dev/null)
check_true "a signed-out claude warns and names the backup" grep -q "Claude Code reports it is signed out; the previous login is in $b/login-" <<< "$err"
check "and not about the org" 0 "$(grep -c 'different org' <<< "$err")"
rm "$tmp/bin/claude"
# a PATH without claude (jq's folder, the stub folder and the system folders only)
noclaude="$tmp/bin:$(dirname "$(command -v jq)"):/usr/bin:/bin"
check_true "the no-claude PATH has no claude" test -z "$(PATH=$noclaude command -v claude || true)"
check "no claude on PATH, no verification warning" 0 "$(PATH=$noclaude "$script" switch alpha --no-relaunch 2>&1 > /dev/null | grep -c 'different org')"

# A running claude keeps its token and can refresh it over the switched login
printf '#!/bin/sh\ncase "$*" in *"-x claude"*) echo 4242; exit 0 ;; esac\nexit 1\n' > "$tmp/bin/pgrep"
check_true "switch warns about a running claude" grep -q 'Claude Code is running (pid 4242); quit it first, or its next token refresh can overwrite the switched login' <<< "$(cda switch beta --no-relaunch 2>&1 > /dev/null)"
printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/pgrep"
check "the CLI follows Desktop back to beta" bbbbbbbb-2222 "$(jq -r .oauthAccount.accountUuid "$tmp/claude.json")"
# The switches away re-saved beta; the list and show cases below expect its hand-written save time.
jq '.savedAt = "2026-01-01T00:00:00Z"' "$p/beta/meta.json" > "$tmp/meta.new" && mv "$tmp/meta.new" "$p/beta/meta.json"

# list marks the active profile
list=$(cda list)
check_true "list marks beta active" grep -Eq '^\* beta +bbbbbbbb  2026-01-01T00:00:00Z  4 sessions$' <<< "$list"
check_true "list leaves alpha unmarked" grep -Eq '^  alpha +aaaaaaaa  ' <<< "$list"
out=$(cda list --json)
check "list --json current" beta "$(jq -r .current <<< "$out")"
check "list --json signedIn" true "$(jq -r .signedIn <<< "$out")"
check "list --json desktopRunning" false "$(jq -r .desktopRunning <<< "$out")"
check "list --json names in order" "alpha beta legacy" "$(jq -r '[.profiles[].name] | join(" ")' <<< "$out")"
check "list --json sessions is a number" number "$(jq -r '.profiles[1].sessions | type' <<< "$out")"
check "list --json sessions" 4 "$(jq -r '.profiles[1].sessions' <<< "$out")"
check "list --json version" "$pkg_version" "$(jq -r .version <<< "$out")"
check "list --json cliSaved true" true "$(jq -r '.profiles[] | select(.name == "beta") | .cliSaved' <<< "$out")"
check "list --json cliSaved false for a legacy profile" false "$(jq -r '.profiles[] | select(.name == "legacy") | .cliSaved' <<< "$out")"
check "--json rejected elsewhere" 1 "$(exit_code cda current --json)"

# show, the fzf picker (stub fzf picks the beta row) and the Raycast scripts
check "show prints the profile and its sessions per org" "beta
account bbbbbbbb
saved at 2026-01-01T00:00:00Z
CLI login: saved
org org-b: 4 sessions" "$(cda show beta)"
check_true "show says when no CLI login is saved" grep -q '^CLI login: not saved' <<< "$(cda show legacy)"
check "show of an unknown name fails" 1 "$(exit_code cda show nope)"
printf '#!/bin/sh\necho "fzf $*" > "%s/fzf-args"\ntee "%s/fzf-in" | grep "^beta "\n' "$tmp" "$tmp" > "$tmp/bin/fzf"
chmod +x "$tmp/bin/fzf"
out=$(cda pick)
check "picker switches to the chosen row" "beta is already signed in" "$(head -1 <<< "$out")"
check "picker rows put the name first and mark the active one" \
  "beta             bbbbbbbb  2026-01-01T00:00:00Z  4 sessions  (signed in)" "$(grep '^beta' "$tmp/fzf-in")"
check "picker previews with show" "fzf --header Enter: switch   esc: quit --preview $script show {1}" "$(cat "$tmp/fzf-args")"
check "picker relaunches by default" "open -a Claude" "$(cat "$tmp/calls")"
rm -f "$tmp/calls"
cda pick --no-relaunch > /dev/null
check_true "picker forwards --no-relaunch" test ! -e "$tmp/calls"
printf '#!/bin/sh\nexit 130\n' > "$tmp/bin/fzf"
cp "$d/config.json" "$tmp/config-before"
check "picker esc exits 0" 0 "$(exit_code cda pick)"
check_true "picker esc changes nothing" cmp -s "$d/config.json" "$tmp/config-before"
bare() { cda < /dev/null; }
check "bare without a terminal prints usage and exits 2" 2 "$(exit_code bare)"
# bare on a real terminal runs the picker: `script` lends one
printf '#!/bin/sh\ngrep "^beta "\n' > "$tmp/bin/fzf"
check "bare on a terminal switches through the picker" "beta is already signed in" "$(script -q /dev/null "$script" < /dev/null 2>&1 | grep -o 'beta is already signed in')"
raycast="$(cd "$(dirname "$script")/.." && pwd -P)/raycast"
check "current prints the active name" beta "$(cda current)"
check "Raycast inline shows the active account" beta "$("$raycast/claude-account.sh")"
: > "$tmp/security-calls"
check "Raycast switch ends with a toast line" "Switched to alpha" "$("$raycast/switch-claude-account.sh" alpha 2> /dev/null | tail -1)"
# Raycast puts Homebrew's bin first; an installed tool would have answered instead.
check "and ran the checkout, whose CLI write reached the stub" 1 "$(grep -c '^stdin add-generic-password -U -a "'"$USER"'" -s "Claude Code-credentials"' "$tmp/security-calls")"
cda switch beta --no-relaunch > /dev/null 2>&1

# Run from a shell inside Desktop (the Code tab's terminal): BSD pgrep excludes
# its own ancestors, so plain pgrep says "not running" while pgrep -a finds it.
printf '#!/bin/sh\ncase "$1" in -a*) exit 0 ;; esac\nexit 1\n' > "$tmp/bin/pgrep"
cp "$d/config.json" "$tmp/config-inside"
rm -f "$tmp/calls"
check "switch from inside Desktop refuses" 1 "$(exit_code cda switch alpha --no-relaunch)"
check_true "and names the way out" grep -q 'inside Claude Desktop' <<< "$(cda switch alpha --no-relaunch 2>&1 || true)"
check_true "and touches nothing" cmp -s "$d/config.json" "$tmp/config-inside"
check_true "and neither quits nor launches" test ! -e "$tmp/calls"
check "save from inside Desktop refuses" 1 "$(exit_code cda save beta --no-relaunch)"
check "sync from inside Desktop refuses as Desktop running" 3 "$(exit_code cda sync)"
check "list from inside Desktop works" 0 "$(exit_code cda list)"
printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/pgrep"

# sync refuses while Desktop runs (pgrep finds it)
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/pgrep"
check "sync refuses while Desktop runs" 3 "$(exit_code cda sync)"
check "sync --force runs anyway" 0 "$(exit_code cda sync --force)"
printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/pgrep"

# add re-saves the active login and signs out locally
out=$(cda add gamma --no-relaunch)
check "add clears the auth keys" '["theme","windowBounds","zeta"]' "$(jq -c keys_unsorted "$d/config.json")"
check_true "add removes the cookie files" test ! -e "$d/Cookies"
check_true "add prints the save step" grep -q 'claude-multipass save gamma' <<< "$out"
check_true "add says how to sign the terminal in" grep -q 'claude auth login' <<< "$out"
check "save refuses when signed out" 1 "$(exit_code cda save gamma --no-relaunch)"
check "unknown command exits 2" 2 "$(exit_code cda bogus)"
check "two names fail" 1 "$(exit_code cda switch alpha beta --no-relaunch)"
check "list with a name fails" 1 "$(exit_code cda list alpha)"
check "current with a name fails" 1 "$(exit_code cda current x)"
check "--help shows the commands" 1 "$(cda --help | grep -c "^  rename <old> <new>   ")"
check "version" "claude-multipass $pkg_version" "$(cda --version)"
check "version exits 0" 0 "$(exit_code cda --version)"
check "rename moves the profile" "Renamed alpha to home" "$(cda rename alpha home)"
check_true "renamed profile keeps its login" test -f "$p/home/config.json" -a ! -e "$p/alpha"
check "rename moves the CLI item" at-alpha "$(kc_get claude-multipass home | jq -r .claudeAiOauth.accessToken)"
check "rename removes the old CLI item" absent "$(kc_get claude-multipass alpha)"
check "rename of a profile without a CLI item succeeds" 0 "$(exit_code cda rename legacy legacy2)"
err=$(SECURITY_FAIL_ADD=1 cda rename home home2 2>&1 > /dev/null)
check_true "a rename whose Keychain copy fails says so" grep -q 'could not move the CLI login to home2 (the old item stays under home)' <<< "$err"
check "and keeps the old item" at-alpha "$(kc_get claude-multipass home | jq -r .claudeAiOauth.accessToken)"
check_true "and the renamed folder claims no CLI login" test ! -e "$p/home2/cli.json"
cda rename home2 home > /dev/null
cda rename legacy2 legacy > /dev/null
check "rename onto an existing name fails" 1 "$(exit_code cda rename home beta)"
check "rename needs two names" 1 "$(exit_code cda rename home)"
check "remove moves the profile to backups" 1 "$(
  cda remove home > /dev/null
  find "$b" -maxdepth 1 -name 'profile-home-*' | wc -l | tr -d ' '
)"
check_true "removed profile is gone from the store" test ! -e "$p/home"
check "remove deletes the CLI item" absent "$(kc_get claude-multipass home)"
check "remove of an unknown name fails" 1 "$(exit_code cda remove home)"
cp -R "$b"/profile-home-* "$p/alpha"
check "--force outside sync or switch fails" 1 "$(exit_code cda list --force)"
# an unsaved login must not be switched away from silently
printf '{"oauth:tokenCacheV2":"enc-Z","lastKnownAccountUuid":"zzzzzzzz-9999"}' > "$d/config.json"
check "list --json current is null when not saved" null "$(cda list --json | jq -r .current)"
check "list --json still signed in" true "$(cda list --json | jq -r .signedIn)"
check "switch refuses to drop an unsaved login" 3 "$(exit_code cda switch alpha --no-relaunch)"
check "switch --force drops it anyway" 0 "$(exit_code cda switch alpha --no-relaunch --force)"
check "forced switch restored alpha" aaaaaaaa-1111 "$(jq -r .lastKnownAccountUuid "$d/config.json")"
check "no backups folder inside the profile store" "" "$(ls -d "$p/backups" 2> /dev/null || true)"

# save refuses to overwrite a profile that holds another account
printf '{"oauth:tokenCacheV2":"enc-Z","lastKnownAccountUuid":"zzzzzzzz-9999"}' > "$d/config.json"
rm -f "$tmp/calls"
check "save over another account's profile is refused" 3 "$(exit_code cda save beta)"
check_true "a refused save does not quit or relaunch Desktop" test ! -e "$tmp/calls"
check "the refused save left beta untouched" bbbbbbbb-2222 "$(jq -r .account "$p/beta/meta.json")"
check "save --force replaces it" 0 "$(exit_code cda save beta --no-relaunch --force)"
check "forced save moved the old profile to backups" 1 "$(find "$b" -maxdepth 1 -name 'profile-beta-*' | wc -l | tr -d ' ')"
check "forced save holds the new account" zzzzzzzz-9999 "$(jq -r .account "$p/beta/meta.json")"
check "forced save deletes the replaced profile's CLI item" absent "$(kc_get claude-multipass beta)"
check_true "and the moved profile keeps no cli.json claim on it" test ! -e "$p/beta/cli.json"

# an error after the quit still relaunches when relaunch is on
rm -f "$tmp/calls"
check "switch to a missing profile fails" 1 "$(exit_code cda switch nope)"
check_true "a failure before the quit does not launch" test ! -e "$tmp/calls"
printf '{"theme":"dark"}' > "$d/config.json"
check "save when signed out fails before quitting" 1 "$(exit_code cda save delta)"
check_true "and does not launch" test ! -e "$tmp/calls"

# empty pointer set does not crash under bash 3.2
rm -f "$s"/*/*/local_*.json
check "sync with no pointers says so" "No Code tab sessions to sync" "$(cda sync)"

# list with nothing saved
check "list with no profiles explains" "No saved accounts yet: run claude-multipass save <name> for the signed-in one, add <name> for another" "$(CLAUDE_MULTIPASS_DIR="$tmp/empty" cda list)"
check "list --json with no profiles is an empty array" "[]" "$(CLAUDE_MULTIPASS_DIR="$tmp/empty" cda list --json | jq -c .profiles)"

# backups prune to the newest ten
for i in $(seq 1 12); do
  mkdir -p "$b/login-2020010100000$i-1"
  kc_put claude-multipass "login-2020010100000$i-1" '{"claudeAiOauth":{"accessToken":"old"}}'
done
printf '{"oauth:tokenCache":"x","oauth:tokenCacheV2":"enc-Q","lastKnownAccountUuid":"qqqqqqqq-0000"}' > "$d/config.json"
cda add eps --no-relaunch > /dev/null 2>&1
check "login backups pruned to ten" 10 "$(find "$b" -mindepth 1 -maxdepth 1 -type d -name 'login-*' | wc -l | tr -d ' ')"
check "the oldest pruned backup's CLI item is gone" absent "$(kc_get claude-multipass login-20200101000001-1)"
for i in $(seq 1 12); do
  if [[ -d $b/login-2020010100000$i-1 ]]; then check "kept backup $i keeps its CLI item" old "$(kc_get claude-multipass "login-2020010100000$i-1" | jq -r .claudeAiOauth.accessToken)"; else check "pruned backup $i loses its CLI item" absent "$(kc_get claude-multipass "login-2020010100000$i-1")"; fi
done

# usage: a fixture token cache encrypted the way the app does; security and
# curl are stubs on PATH, so no Keychain and no network
mkdir -p "$p/usagey" "$p/stale"
printf '{"five_hour":{"utilization":42.6,"resets_at":"2026-10-23T19:45:00.123456+00:00"},"seven_day":{"utilization":18.0,"resets_at":"2026-10-27T13:00:00Z"}}' > "$tmp/usage.json"
printf '#!/bin/sh\n{ echo "curl $*"; cat; } >> "%s/curl-args"\ncat "%s/usage.json"; printf "\\n200"\n' "$tmp" "$tmp" > "$tmp/bin/curl"
chmod +x "$tmp/bin/curl"
key=$(printf '%s' "$pw" | /usr/bin/python3 -c 'import hashlib, sys; print(hashlib.pbkdf2_hmac("sha1", sys.stdin.buffer.read(), b"saltysalt", 1003, 16).hex())')
encrypt() { {
  printf 'v10'
  printf '%s' "$1" | openssl enc -aes-128-cbc -K "$key" -iv 20202020202020202020202020202020
} | base64; }
future=$(($(date +%s) + 3600))000
past=$(($(date +%s) - 3600))000
# bash 3.2 (the shebang) mis-parses escaped quotes nested in $(...), so build
# each plaintext in a variable first.
plain='{"acct:uuuuuuuu-1|c:o:a:user:profile user:inference":{"token":"tok-u","expiresAt":FUTURE},"acct:uuuuuuuu-1|c:o:a:user:other":{"token":"wrong","expiresAt":FUTURE}}'
enc=$(encrypt "${plain//FUTURE/$future}")
jq -n --arg v "$enc" '{"oauth:tokenCacheV2":$v}' > "$p/usagey/config.json"
printf '{"account":"uuuuuuuu-1","savedAt":"2026-01-01T00:00:00Z"}' > "$p/usagey/meta.json"
plain='{"acct:ssssssss-1|c:o:a:user:profile":{"token":"old","expiresAt":PAST}}'
enc=$(encrypt "${plain//PAST/$past}")
jq -n --arg v "$enc" '{"oauth:tokenCacheV2":$v}' > "$p/stale/config.json"
printf '{"account":"ssssssss-1","savedAt":"2026-01-01T00:00:00Z"}' > "$p/stale/meta.json"
expected="5h 42% (resets $(date -r 1792784700 '+%a %H:%M'))  7d 18% (resets $(date -r 1793106000 '+%a %H:%M'))"
check "usage decrypts the saved token and reads the endpoint" "usagey           $expected" "$(cda usage usagey)"
check_true "usage reads its config from stdin" grep -q -- ' -K - ' "$tmp/curl-args"
check_true "usage sends the beta header and the endpoint" grep -q 'anthropic-beta: oauth-2025-04-20 https://api.anthropic.com/api/oauth/usage' "$tmp/curl-args"
check_true "usage passes the bearer token on stdin, not argv" grep -qx 'header = "Authorization: Bearer tok-u"' "$tmp/curl-args"
check "usage never puts the token on a command line" 0 "$(grep -c 'curl .*tok-u' "$tmp/curl-args")"
check "usage reports an expired token" "stale            token expired, sign in and re-save" "$(cda usage stale)"
check "usage for an unknown name fails loudly" 1 "$(exit_code cda usage nope)"
cp -R "$p/usagey" "$tmp/outside"
check_true "usage rejects a path as a name" grep -q 'Give a name' <<< "$(cda usage ../outside 2>&1)"
printf '#!/bin/sh\ncat > /dev/null; printf "{}\\n401"\n' > "$tmp/bin/curl"
check "usage reports a rejected token" "usagey           token expired, sign in and re-save" "$(cda usage usagey)"
printf '#!/bin/sh\ncat > /dev/null; printf "{}\\n429"\n' > "$tmp/bin/curl"
check "usage reports rate limiting" "usagey           rate limited" "$(cda usage usagey)"
printf '#!/bin/sh\n{ echo "curl $*"; cat; } >> "%s/curl-args"\ncat "%s/usage.json"; printf "\\n200"\n' "$tmp" "$tmp" > "$tmp/bin/curl"
printf '{"oauth:tokenCacheV2":"djEwbm90IHJlYWxseSBlbmNyeXB0ZWQgYnl0ZXM="}' > "$p/stale/config.json"
check "usage says when a cache will not decrypt" "stale            cannot decrypt (the profile was saved on another Mac, or the app changed its key)" "$(cda usage stale)"
enc=$(encrypt "${plain//PAST/$past}")
jq -n --arg v "$enc" '{"oauth:tokenCacheV2":$v}' > "$p/stale/config.json"
check "usage lists every saved account in order" "stale            token expired, sign in and re-save
usagey           $expected" "$(cda usage | grep -E '^(stale|usagey) ')"
check "usage never prints a token" 0 "$(cda usage | grep -c 'tok-u')"
out=$(cda usage --json)
check "usage --json good entry" usagey "$(jq -r '.profiles[] | select(.fiveHour) | .name' <<< "$out")"
check "usage --json 5h utilization" 42.6 "$(jq -r '.profiles[] | select(.name=="usagey").fiveHour.utilization' <<< "$out")"
check "usage --json normalises resetsAt" 2026-10-23T19:45:00Z "$(jq -r '.profiles[] | select(.name=="usagey").fiveHour.resetsAt' <<< "$out")"
check "usage --json 7d resetsAt" 2026-10-27T13:00:00Z "$(jq -r '.profiles[] | select(.name=="usagey").sevenDay.resetsAt' <<< "$out")"
check "usage --json error entry" "token expired, sign in and re-save" "$(jq -r '.profiles[] | select(.name=="stale").error' <<< "$out")"
check "usage --json never puts the token on a command line" 0 "$(grep -c 'curl .*tok-u' "$tmp/curl-args")"
check "usage --json never prints a token" 0 "$(grep -c tok-u <<< "$out")"
cp "$tmp/usage.json" "$tmp/usage-full.json"
printf '{"five_hour":{"utilization":42.6},"seven_day":{"utilization":null}}' > "$tmp/usage.json"
out=$(cda usage usagey --json)
check "usage --json keeps the profile with a null window" usagey "$(jq -r '.profiles[0].name' <<< "$out")"
check "usage --json keeps the other window" 42.6 "$(jq -r '.profiles[0].fiveHour.utilization' <<< "$out")"
check "usage --json omits a null window" null "$(jq -r '.profiles[0].sevenDay' <<< "$out")"
cp "$tmp/usage-full.json" "$tmp/usage.json"
mkdir -p "$tmp/emptyd" && printf '{"theme":"dark"}' > "$tmp/emptyd/config.json"
check "usage --json with nothing saved" '{"profiles":[]}' "$(CLAUDE_DESKTOP_DIR="$tmp/emptyd" CLAUDE_MULTIPASS_DIR="$tmp/empty" cda usage --json)"

# doctor: one line per check, exit 1 on any fail:, no Keychain, no network
rm -f "$tmp/calls"
touch "$tmp/calls"
check "doctor healthy" 0 "$(exit_code cda doctor)"
check_true "doctor reports jq" grep -q '^ok: jq' <<< "$(cda doctor)"
check_true "doctor reports the Command Line Tools" grep -q '^ok: Command Line Tools' <<< "$(cda doctor)"
n_sec=$(wc -l < "$tmp/security-calls" | tr -d ' ')
cda doctor > /dev/null
check "doctor never calls security" "$n_sec" "$(wc -l < "$tmp/security-calls" | tr -d ' ')"
check_true "doctor names a profile without a CLI login" grep -q '^warn: legacy: no CLI login saved' <<< "$(cda doctor)"
check_true "doctor warns on CLAUDE_CONFIG_DIR" grep -q '^warn: CLAUDE_CONFIG_DIR is set; the CLI login is not saved or switched' <<< "$(CLAUDE_CONFIG_DIR=/x cda doctor)"
check_true "doctor warns on CLAUDE_SECURESTORAGE_CONFIG_DIR" grep -q '^warn: CLAUDE_SECURESTORAGE_CONFIG_DIR is set; the CLI login is not saved or switched' <<< "$(CLAUDE_SECURESTORAGE_CONFIG_DIR=/x cda doctor)"
cp "$p/usagey/config.json" "$tmp/usagey-config"
printf '{"oauth:tokenCacheV2":""}' > "$p/usagey/config.json"
check "doctor fails on an empty token" 1 "$(exit_code cda doctor)"
check_true "doctor names the profile" grep -q '^fail: usagey: empty oauth:tokenCacheV2' <<< "$(cda doctor || true)"
cp "$tmp/usagey-config" "$p/usagey/config.json"
rm "$p/usagey/meta.json"
check_true "doctor names a profile without meta.json" grep -q '^fail: usagey: missing meta.json' <<< "$(cda doctor || true)"
printf '{"account":"uuuuuuuu-1","savedAt":"2026-01-01T00:00:00Z"}' > "$p/usagey/meta.json"
chmod 755 "$p"
check "doctor warns on a loose store but still exits 0" 0 "$(exit_code cda doctor)"
check_true "doctor names the store mode" grep -q '^warn: store: mode 755' <<< "$(cda doctor)"
chmod 700 "$p"
printf '{"oauth:tokenCache":"x","oauth:tokenCacheV2":"enc","lastKnownAccountUuid":"uuuuuuuu-1"}' > "$d/config.json"
check "Raycast usage command shows the active account's figures" "usagey           $expected" "$("$raycast/claude-account-usage.sh")"

# the dotfiles-era store moves into the default location once, backups too
# (XDG_CONFIG_HOME, not HOME: tools on PATH may read their own config from HOME)
mkdir -p "$tmp/home/.config/dotfiles/claude-desktop-accounts/old" "$tmp/home/.config/dotfiles/claude-desktop-accounts-backups/login-1"
printf '{"account":"aaaaaaaa-1111","savedAt":"2026-01-01T00:00:00Z"}' > "$tmp/home/.config/dotfiles/claude-desktop-accounts/old/meta.json"
cp "$p/beta/config.json" "$tmp/home/.config/dotfiles/claude-desktop-accounts/old/config.json"
out=$(env -u CLAUDE_MULTIPASS_DIR XDG_CONFIG_HOME="$tmp/home/.config" "$script" list --json 2> "$tmp/migrate-err")
check "first run moves the old store" "Moved the saved accounts from $tmp/home/.config/dotfiles/claude-desktop-accounts to $tmp/home/.config/claude-multipass/profiles" "$(cat "$tmp/migrate-err")"
check "first run list --json is clean JSON" old "$(jq -r '.profiles[0].name' <<< "$out")"
check_true "old backups moved beside it" test -d "$tmp/home/.config/claude-multipass/backups/login-1" -a ! -e "$tmp/home/.config/dotfiles/claude-desktop-accounts"
check "the moved store is private" 700 "$(stat -f %Lp "$tmp/home/.config/claude-multipass")"
check "second run does not move again" "  old " "$(env -u CLAUDE_MULTIPASS_DIR XDG_CONFIG_HOME="$tmp/home/.config" "$script" list | head -1 | cut -c1-6)"
check "an explicit store never migrates" "No saved accounts yet: run claude-multipass save <name> for the signed-in one, add <name> for another" "$(CLAUDE_MULTIPASS_DIR="$tmp/empty2" XDG_CONFIG_HOME="$tmp/home/.config" cda list | head -1)"
mkdir -p "$tmp/home2/.config/dotfiles/claude-desktop-accounts/old" "$tmp/home2/.config/dotfiles/claude-desktop-accounts-backups" "$tmp/home2/.config/claude-multipass/backups"
cp "$tmp/home/.config/claude-multipass/profiles/old/"* "$tmp/home2/.config/dotfiles/claude-desktop-accounts/old/"
env -u CLAUDE_MULTIPASS_DIR XDG_CONFIG_HOME="$tmp/home2/.config" "$script" list > /dev/null 2> "$tmp/migrate-err2"
check_true "migration warns when the new backups folder already exists" grep -q "Left $tmp/home2/.config/dotfiles/claude-desktop-accounts-backups in place" "$tmp/migrate-err2"
check_true "and leaves the legacy backups where they were" test -d "$tmp/home2/.config/dotfiles/claude-desktop-accounts-backups"

echo "All claude-multipass checks passed"
