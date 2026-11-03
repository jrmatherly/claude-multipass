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
# open, fzf, security, xcode-select and curl are stubbed on PATH so no app is
# quit or launched and no Keychain or network is touched. CLAUDE_MULTIPASS_LLMR
# points at an llmr stub, so the real llm-router never runs.
#
# License: MIT

set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd -P)/bin/claude-multipass"
tmp=$(mktemp -d)
# A failed Hindsight case must not leave a stopped sleep behind for good.
hs_pids=''
trap '[[ -z $hs_pids ]] || kill -9 $hs_pids 2> /dev/null || true; rm -rf "$tmp"' EXIT

export CLAUDE_DESKTOP_DIR="$tmp/desktop" CLAUDE_MULTIPASS_DIR="$tmp/multipass"
export TERM=dumb
unset CLAUDE_MULTIPASS_DEBUG
d=$CLAUDE_DESKTOP_DIR p=$CLAUDE_MULTIPASS_DIR/profiles b=$CLAUDE_MULTIPASS_DIR/backups s=$CLAUDE_DESKTOP_DIR/claude-code-sessions
mkdir -p "$tmp/bin"
# pgrep says "not running" so quit is a no-op; the other three only log.
printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/pgrep"
for stub in osascript pkill; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\n' "$stub" "$tmp" > "$tmp/bin/$stub"
done
# desktop_launch runs open under env -i, so every open stub sets PATH itself: a
# security call in one must find the stub, not the real Keychain tool.
printf '#!/bin/sh\nPATH="%s/bin:$PATH"\necho "open $*" >> "%s/calls"\n' "$tmp" "$tmp" > "$tmp/bin/open"
printf '#!/bin/sh\necho /Library/Developer/CommandLineTools\n' > "$tmp/bin/xcode-select"
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
  [[ -z ${SECURITY_FAIL_DELETE:-} || $cmd != delete-generic-password ]] || return 1
  [[ -z ${SECURITY_FAIL_FIND:-} || $cmd != find-generic-password || $s != 'Claude Code-credentials' ]] || return "$SECURITY_FAIL_FIND"
  [[ ! -e ${kc%/*}/security-find-fail || $cmd != find-generic-password || $s != 'Claude Code-credentials' ]] || return 36
  case $cmd in
    add-generic-password)
      mkdir -p "$kc/$s"
      # Decoded straight to the file: a $(...) would strip a trailing newline the tool must not store.
      printf %s "$hex" | xxd -r -p > "$kc/$s/$a"
      ;;
    find-generic-password)
      if [[ $s == 'Claude Safe Storage' ]]; then printf %s "$pw"; return 0; fi
      # A slow read of the CLI item, for the lock keep-alive case: record the
      # named lock dir's mtime before and after a 4 s hold.
      if [[ -n ${SECURITY_HOLD:-} && $s == 'Claude Code-credentials' ]]; then
        stat -f %m "$SECURITY_HOLD" > "${kc%/*}/lock-mtime-before"
        sleep 4
        stat -f %m "$SECURITY_HOLD" > "${kc%/*}/lock-mtime-after"
      fi
      # A read held open, as by a Keychain prompt, for the run lock case: it
      # marks the hold, then waits until the named file is gone (30 s at most,
      # so an aborted case never hangs the gate).
      if [[ -n ${SECURITY_WAIT:-} && $s == 'Claude Code-credentials' ]]; then
        touch "$SECURITY_WAIT.held"
        for ((w = 0; w < 300; w++)); do
          [[ -e $SECURITY_WAIT ]] || break
          /bin/sleep 0.1
        done
      fi
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
# The Hindsight cases: the fake daemon's state at each Keychain access, and a
# daemon that dies at that moment.
fixture=${kc%/*}
if [[ -f $fixture/hindsight-pid ]]; then
  daemon=$(cat "$fixture/hindsight-pid")
  live_children=0
  if [[ -f $fixture/hindsight-child ]] && kill -0 "$(cat "$fixture/hindsight-child")" 2> /dev/null; then live_children=1; fi
  echo "$(ps -o state= -p "$daemon") children=$live_children" >> "$fixture/hindsight-states"
  [[ ! -e $fixture/hindsight-die ]] || kill -9 "$daemon" 2> /dev/null
fi
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
# llmr records its environment in llmr-env, logs its argv (to llmr-calls and calls) and exits with the status in
# llmr-fail, if any; on success it marks its Desktop up (llmr-up and
# claude-up) unless llmr-no-desktop exists.
mkdir -p "$tmp/llmr-bin"
printf '#!/bin/sh\n/usr/bin/env > "%s/llmr-env"\necho "llmr $*" >> "%s/llmr-calls"\n[ ! -f "%s/llmr-fail" ] || { echo "llmr: no such profile" >&2; exit "$(cat "%s/llmr-fail")"; }\necho "llmr $*" >> "%s/calls"\n[ -e "%s/llmr-no-desktop" ] || touch "%s/llmr-up" "%s/claude-up"\n' "$tmp" "$tmp" "$tmp" "$tmp" "$tmp" "$tmp" "$tmp" "$tmp" > "$tmp/llmr-bin/llmr"
chmod +x "$tmp/llmr-bin/llmr"
export CLAUDE_MULTIPASS_LLMR="$tmp/llmr-bin/llmr"
export CLAUDE_CLI_CONFIG="$tmp/claude.json" CLAUDE_CLI_HOME="$tmp/claude-home" CLAUDE_MULTIPASS_BIN="$script"
mkdir -p "$tmp/claude-home"
cda() { "$script" "$@"; }
# jq and cat that log their stdin's file type. bash 3.2 backs a here-string
# with a regular temp file on disk, a pipe is a FIFO, so a token sent to them
# through a here-string shows as "Regular File". Each drops its own dir from
# PATH before exec, since a version-manager shim looks the tool up on PATH again.
mkdir -p "$tmp/stdin-bin"
for tool in jq cat; do
  printf '#!/bin/sh\necho "%s $(stat -Lf %%HT /dev/stdin)" >> "%s/stdin-types"\nPATH=${PATH#*/stdin-bin:} exec %s "$@"\n' "$tool" "$tmp" "$tool" > "$tmp/stdin-bin/$tool"
done
chmod +x "$tmp"/stdin-bin/*
cda_stdin() { PATH="$tmp/stdin-bin:$PATH" "$script" "$@" < /dev/null; }
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
# Claude Code 2.1.316 clears a dead login in place: empty tokens, expiresAt 0. That is a sign-out, not a login to save
kc_put "Claude Code-credentials" "$USER" '{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0,"scopes":[]},"mcpOAuth":{"srv":"shared"}}'
check_true "save warns when Claude Code cleared its login" grep -q 'alpha: Claude Code cleared its login; switch to alpha, run claude auth login, then save alpha' <<< "$(cda save alpha --no-relaunch 2>&1 > /dev/null)"
check "a cleared save keeps the saved item" at-alpha "$(kc_get claude-multipass alpha | jq -r .claudeAiOauth.accessToken)"
# Only that exact shape: an item that still holds a refresh token is a login
kc_put "Claude Code-credentials" "$USER" '{"claudeAiOauth":{"accessToken":"","refreshToken":"rt-live","expiresAt":0}}'
cda save alpha --no-relaunch > /dev/null 2>&1
check "an item with a refresh token is saved" rt-live "$(kc_get claude-multipass alpha | jq -r .claudeAiOauth.refreshToken)"
kc_put "Claude Code-credentials" "$USER" "$live_item"
cda save alpha --no-relaunch > /dev/null 2>&1
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
# The CLI item is read once per run, so the switch waits 4 s once while holding the locks.
export SECURITY_HOLD=$tmp/claude.json.lock
out=$(cda switch beta --no-relaunch 2> "$tmp/switch-err" | tee "$tmp/switch-out")
unset SECURITY_HOLD
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
check_true "the config lock is touched while held" test "$(cat "$tmp/lock-mtime-after")" -gt "$(cat "$tmp/lock-mtime-before")"
sleep 4
check_true "no toucher outlives the switch" test ! -e "$tmp/claude.json.lock" -a ! -e "$tmp/claude-home/.oauth_refresh.lock" -a ! -e "$tmp/claude-home.lock"
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
check "switch to the signed-in account only syncs" "beta is already signed in" "$(cda switch beta --no-relaunch | sed -n 1p)"
rm "$d/Cookies"
cda switch beta --no-relaunch > /dev/null
check "same-name switch repairs missing cookies" cookie-B "$(cat "$d/Cookies")"
# Desktop rotated its cookies since the switch: a same-name switch must not put the profile's older copy back
printf cookie-B-rotated > "$d/Cookies"
cda switch beta --no-relaunch > /dev/null
check "same-name switch keeps rotated live cookies" cookie-B-rotated "$(cat "$d/Cookies")"

# The CLI already on the target account: its live tokens are fresher than the saved ones, so switch re-saves them and writes nothing
kc_put "Claude Code-credentials" "$USER" "$(kc_get "Claude Code-credentials" "$USER" | jq -c '.claudeAiOauth.accessToken = "at-beta-fresh"')"
n_backups=$(ls -1d "$b"/login-*/ | wc -l | tr -d ' ')
out=$(cda switch beta --no-relaunch)
check "switch to the signed-in account re-saves the live CLI login" "beta is already signed in" "$(head -1 <<< "$out")"
check "and writes no backup folder" "$n_backups" "$(ls -1d "$b"/login-*/ | wc -l | tr -d ' ')"
check "and leaves the live tokens alone" at-beta-fresh "$(kc_get "Claude Code-credentials" "$USER" | jq -r .claudeAiOauth.accessToken)"
check "and the profile now holds them" at-beta-fresh "$(kc_get claude-multipass beta | jq -r .claudeAiOauth.accessToken)"

# The CLI's identity says the target account but Claude Code cleared the item: restore the saved one, keep the shared keys
kc_put "Claude Code-credentials" "$USER" '{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0},"mcpOAuth":{"srv":"shared"}}'
err=$(cda switch beta --no-relaunch 2>&1 > /dev/null)
check "a same-account switch over a cleared item restores the saved login" at-beta-fresh "$(kc_get "Claude Code-credentials" "$USER" | jq -r .claudeAiOauth.accessToken)"
check "and keeps the shared MCP keys" '{"srv":"shared"}' "$(kc_get "Claude Code-credentials" "$USER" | jq -c .mcpOAuth)"
check "and leaves the profile's saved login alone" at-beta-fresh "$(kc_get claude-multipass beta | jq -r .claudeAiOauth.accessToken)"
check "and warns nothing" "" "$err"

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

# A cleared CLI login on the way out: the outgoing profile keeps its saved login, the target is still restored
kc_put "Claude Code-credentials" "$USER" '{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0},"mcpOAuth":{"srv":"shared"}}'
err=$(cda switch beta --no-relaunch 2>&1 > /dev/null)
check_true "a cleared outgoing CLI login warns by profile name" grep -q 'alpha: Claude Code cleared its login; switch to alpha, run claude auth login, then save alpha' <<< "$err"
check "and leaves the outgoing profile's CLI login alone" at-alpha "$(kc_get claude-multipass alpha | jq -r .claudeAiOauth.accessToken)"
check "and still restores the target's CLI login" at-beta-fresh "$(kc_get "Claude Code-credentials" "$USER" | jq -r .claudeAiOauth.accessToken)"
check "and keeps the shared MCP keys" '{"srv":"shared"}' "$(kc_get "Claude Code-credentials" "$USER" | jq -c .mcpOAuth)"
cda switch alpha --no-relaunch > /dev/null 2>&1

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
check_true "a failed read on the way out names the status and the profile" grep -q 'alpha: security exited 36 (the keychain is locked and cannot prompt here, as over SSH or in a hook; unlock it and retry) reading the CLI login; saved the Desktop login only' <<< "$err"
check_true "a failed read on the restore names the status" grep -q 'security exited 36 (the keychain is locked and cannot prompt here, as over SSH or in a hook; unlock it and retry) reading the CLI login; switched Desktop only' <<< "$err"
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
check_true "and warns" grep -q 'the live or saved CLI login is not valid JSON; switched Desktop only' <<< "$err"
check_true "and the session lists were still merged" grep -q written "$tmp/corrupt-out"
check "and the corrupt item is left alone" 'not json' "$(kc_get "Claude Code-credentials" "$USER")"
check_true "a corrupt live item never passes for the target's login" grep -q 'the live or saved CLI login is not valid JSON; switched Desktop only' <<< "$(cda switch alpha --no-relaunch 2>&1 > /dev/null)"
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
sleep 4
check_true "and no toucher outlives the failed switch" test ! -e "$tmp/claude-home/.oauth_refresh.lock" -a ! -e "$tmp/claude-home.lock"
# Each of the other two locks, held fresh, fails the switch the same way
cp "$d/config.json" "$tmp/config-locked"
for lock in "$tmp/claude-home/.oauth_refresh.lock" "$tmp/claude-home.lock"; do
  mkdir "$lock"
  st=0
  err=$(cda switch beta --no-relaunch 2>&1 > /dev/null) || st=$?
  check "a held ${lock##*/} fails the switch" 1 "$st"
  check_true "and names it" grep -q "Claude Code holds $lock; retry in a moment" <<< "$err"
  check_true "and Desktop's config is untouched" cmp -s "$d/config.json" "$tmp/config-locked"
  check "and oauthAccount too" aaaaaaaa-1111 "$(jq -r .oauthAccount.accountUuid "$tmp/claude.json")"
  rmdir "$lock"
  check_true "and the tool's own locks are released" test ! -e "$tmp/claude-home/.oauth_refresh.lock" -a ! -e "$tmp/claude-home.lock" -a ! -e "$tmp/claude.json.lock"
done

# A tool killed outright (the app's watchdog sends SIGKILL 2 s after SIGTERM) runs no
# trap, so the loop must notice on its own or it pins the CLI's locks for good.
export SECURITY_HOLD=$tmp/claude.json.lock
# The script itself, not cda: a function's & job is a subshell, and killing that would leave the script running.
"$script" switch beta --no-relaunch > /dev/null 2>&1 &
pid=$!
sleep 2
kill -9 "$pid"
wait "$pid" 2> /dev/null || true
unset SECURITY_HOLD
sleep 4
m1=$(stat -f %m "$tmp/claude.json.lock")
sleep 4
check "a toucher stops when the tool is killed outright" "$m1" "$(stat -f %m "$tmp/claude.json.lock")"
rm -rf "$tmp/claude.json.lock" "$tmp/claude-home/.oauth_refresh.lock" "$tmp/claude-home.lock"

# Verification after a restore: claude auth status must report the restored org
printf '#!/bin/sh\necho "{\\"loggedIn\\":true,\\"orgId\\":\\"org-other\\"}"\n' > "$tmp/bin/claude"
err=$(cda switch beta --no-relaunch 2>&1 > /dev/null)
check_true "an org mismatch warns and names the backup" grep -q "Claude Code reports a different org; the previous login is in $b/login-" <<< "$err"
# Under an API key, a helper, a setup-token or a third-party provider the CLI
# reports that credential's org, not the login just written (CLI reference)
printf '#!/bin/sh\necho "{\\"loggedIn\\":true,\\"authMethod\\":\\"api_key\\",\\"orgId\\":\\"org-other\\"}"\n' > "$tmp/bin/claude"
err=$(cda switch alpha --no-relaunch 2>&1 > /dev/null)
check_true "an overriding credential warns which one outranks the login" grep -q "Claude Code is using its api_key credential, which outranks the switched terminal login until that credential is removed" <<< "$err"
check "and not about the org" 0 "$(grep -c 'different org' <<< "$err")"
# A signed-out claude prints its JSON and exits 1 (measured with 2.1.311, as the CLI reference says)
printf '#!/bin/sh\necho "{\\"loggedIn\\":false,\\"authMethod\\":\\"none\\"}"\nexit 1\n' > "$tmp/bin/claude"
err=$(cda switch beta --no-relaunch 2>&1 > /dev/null)
check_true "a signed-out claude warns and names the backup" grep -q "Claude Code reports it is signed out; the previous login is in $b/login-" <<< "$err"
check "and not about the org" 0 "$(grep -c 'different org' <<< "$err")"
printf '#!/bin/sh\nexit 3\n' > "$tmp/bin/claude"
err=$(cda switch alpha --no-relaunch 2>&1 > /dev/null)
check_true "a failing claude auth status warns and names the backup" grep -q "claude auth status exited 3; could not verify the CLI login (the previous login is in $b/login-" <<< "$err"
printf '#!/bin/sh\necho not json\n' > "$tmp/bin/claude"
err=$(cda switch beta --no-relaunch 2>&1 > /dev/null)
check_true "a claude auth status without JSON warns and names the backup" grep -q "claude auth status printed no JSON; could not verify the CLI login (the previous login is in $b/login-" <<< "$err"
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
# one bad meta.json must not empty the list
mkdir -p "$p/broken" "$p/nodate"
printf 'not json' > "$p/broken/meta.json"
printf '{"account":"dddddddd-4444"}' > "$p/nodate/meta.json"
out=$(cda list --json 2> "$tmp/list-err")
check "list --json skips a meta.json it cannot parse" "alpha beta legacy nodate" "$(jq -r '[.profiles[].name] | join(" ")' <<< "$out")"
check "list --json savedAt is null when missing" null "$(jq -r '.profiles[] | select(.name == "nodate") | .savedAt | type' <<< "$out")"
check_true "and warns about the skipped row" grep -q "$p/broken/meta.json" "$tmp/list-err"
check "list skips it too" 0 "$(exit_code cda list)"
rm -rf "$p/broken" "$p/nodate"

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

# No token reaches jq or cat (keychain_put's reader) through a here-string's temp file
: > "$tmp/stdin-types"
cda_stdin switch alpha --no-relaunch > /dev/null 2>&1
cda_stdin switch beta --no-relaunch > /dev/null 2>&1
cda_stdin rename beta beta2 > /dev/null
cda_stdin rename beta2 beta > /dev/null
check "a switch and a rename pass the CLI login through pipes" 0 "$(grep -c 'Regular File' "$tmp/stdin-types" || true)"
check_true "and the log saw those pipes" grep -q '^cat Fifo File' "$tmp/stdin-types"
check "the script has no here-string, and one heredoc (the --help page)" 1 "$(grep -c '<<' "$script" || true)"

# Two runs at once: the second refuses before it quits Desktop, so its EXIT
# trap never relaunches Desktop while the first still writes config.json.
touch "$tmp/wait"
rm -f "$tmp/calls" "$tmp/wait.held"
SECURITY_WAIT=$tmp/wait "$script" switch alpha > /dev/null 2>&1 &
first=$!
for ((i = 0; i < 100; i++)); do
  [[ ! -e $tmp/wait.held ]] || break
  /bin/sleep 0.1
done
check_true "the first run waits on the Keychain" test -e "$tmp/wait.held"
rc=0
err=$(cda switch beta 2>&1 > /dev/null) || rc=$?
check "a second run refuses while the first works" 1 "$rc"
check_true "and names the first run" grep -q "Another claude-multipass run (pid $first) is changing accounts" <<< "$err"
check_true "and neither quits nor relaunches Desktop" test ! -e "$tmp/calls"
rm "$tmp/wait"
rc=0
wait "$first" || rc=$?
check "the first run completes" 0 "$rc"
check "and relaunches Desktop once" "open -a Claude" "$(cat "$tmp/calls")"
check "and switched" aaaaaaaa-1111 "$(jq -r .lastKnownAccountUuid "$d/config.json")"
check_true "and released the run lock" test ! -L "$CLAUDE_MULTIPASS_DIR/.run.lock"
# A lock whose holder is gone (killed without its trap), or whose pid now
# belongs to another program, is swept.
sh -c 'exit 0' &
dead=$!
wait "$dead"
ln -s "$dead" "$CLAUDE_MULTIPASS_DIR/.run.lock"
check "a dead holder's run lock does not block" 0 "$(exit_code cda switch beta --no-relaunch)"
check_true "and is gone afterwards" test ! -L "$CLAUDE_MULTIPASS_DIR/.run.lock"
/bin/sleep 30 > /dev/null 2>&1 &
other=$!
ln -s "$other" "$CLAUDE_MULTIPASS_DIR/.run.lock"
check "a pid reused by another program does not block" 0 "$(exit_code cda switch beta --no-relaunch)"
kill "$other"
rm -f "$tmp/calls"

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

# A Desktop that ignores the quit request gets pkill after 8 s, and the command
# fails 10 s later if even that leaves it running. The sleep stub skips the
# 0.5 s polls, so the waits cost nothing; Claude is gone once $tmp/gone exists.
printf '#!/bin/sh\n[ "$1" = 0.5 ] && exit 0\nexec /bin/sleep "$@"\n' > "$tmp/bin/sleep"
printf '#!/bin/sh\ncase "$*" in *Claude*) test ! -e "%s/gone" ;; *) exit 1 ;; esac\n' "$tmp" > "$tmp/bin/pgrep"
printf '#!/bin/sh\necho "pkill $*" >> "%s/calls"\n[ -z "$PKILL_WORKS" ] || touch "%s/gone"\n' "$tmp" "$tmp" > "$tmp/bin/pkill"
chmod +x "$tmp/bin/sleep"
rm -f "$tmp/calls" "$tmp/gone"
check "a Desktop that ignores quit is killed" 0 "$(PKILL_WORKS=1 exit_code cda switch beta --no-relaunch)"
check_true "after it was asked to quit" grep -q '^osascript ' "$tmp/calls"
check_true "with pkill -x Claude" grep -qx 'pkill -x Claude' "$tmp/calls"
rm -f "$tmp/gone"
rc=0
err=$(cda switch beta --no-relaunch 2>&1 > /dev/null) || rc=$?
check "a Desktop that survives pkill fails the command" 1 "$rc"
check_true "and says to quit it by hand" grep -q 'Claude did not quit; quit it by hand and retry' <<< "$err"
rm -f "$tmp/calls"
cda switch beta > /dev/null 2>&1 || true
check_true "a failed quit still relaunches Desktop" grep -qx 'open -a Claude' "$tmp/calls"
rm "$tmp/bin/sleep"
printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/pgrep"
printf '#!/bin/sh\necho "pkill $*" >> "%s/calls"\n' "$tmp" > "$tmp/bin/pkill"

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
# Each argument error exits 1 and names itself; err_of keeps only stderr.
err_of() { { TERM=dumb "$@" > /dev/null; } 2>&1 || true; }
check "an unknown option fails" 1 "$(exit_code cda list --bogus)"
check "and names it" "Unknown option: --bogus" "$(err_of cda list --bogus)"
check "a name with a leading - is read as an option" "Unknown option: -x" "$(err_of cda show -x)"
check "usage takes at most one name" "usage takes at most one name" "$(err_of cda usage a b)"
check "show with no name fails" 1 "$(exit_code cda show)"
check "and says it takes one" "show takes exactly one name" "$(err_of cda show)"
check "switch with no name says it takes one" "switch takes exactly one name" "$(err_of cda switch --no-relaunch)"
check "rename with three names fails" "rename takes the old name and the new name" "$(err_of cda rename a b c)"
name_rule='Give a name that starts with a letter or digit and is made of letters, digits, . _ -'
bad="$name_rule (got: a/b)"
check "show refuses a name with a slash" "$bad" "$(err_of cda show a/b)"
check "usage refuses it" "$bad" "$(err_of cda usage a/b)"
check "rename refuses it as the old name" "$bad" "$(err_of cda rename a/b ok)"
check "and as the new name" "$bad" "$(err_of cda rename home a/b)"
check "show refuses .." "$name_rule (got: ..)" "$(err_of cda show ..)"
check "show refuses a dot-leading name" "$name_rule (got: .foo)" "$(err_of cda show .foo)"
check "a run without Desktop's config fails" 1 "$(CLAUDE_DESKTOP_DIR="$tmp/no-desktop" exit_code cda list)"
check "and says to open Desktop once" "No $tmp/no-desktop/config.json: open Claude Desktop once first" "$(CLAUDE_DESKTOP_DIR="$tmp/no-desktop" err_of cda list)"
mkdir -p "$tmp/no-fzf"
ln -s "$(command -v jq)" "$tmp/no-fzf/jq"
check "pick without fzf fails" "pick needs fzf" "$(PATH="$tmp/no-fzf:/usr/bin:/bin" err_of cda pick)"
check "remove moves the profile to backups" 1 "$(
  cda remove home > /dev/null
  find "$b" -maxdepth 1 -name 'profile-home-*' | wc -l | tr -d ' '
)"
check_true "removed profile is gone from the store" test ! -e "$p/home"
check "remove deletes the CLI item" absent "$(kc_get claude-multipass home)"
cp -R "$p/beta" "$p/doomed"
err=$(SECURITY_FAIL_DELETE=1 cda remove doomed 2>&1 > /dev/null)
check_true "remove warns when the CLI item will not delete" grep -q 'could not delete the CLI login item for doomed' <<< "$err"
check_true "and still moves the profile aside" test ! -e "$p/doomed"
check "remove of an unknown name fails" 1 "$(exit_code cda remove home)"
check "--force is rejected for remove" 1 "$(exit_code cda remove home --force)"
check "and for rename" 1 "$(exit_code cda rename home x --force)"
check_true "and names the commands that take it" grep -q -- '--force applies to sync, switch, save and add' <<< "$(cda remove home --force 2>&1 > /dev/null)"
check "and --help lists --force on save, switch and add only" 1 "$(cda --help | grep -c 'save|switch|add <name> \[--no-relaunch\] \[--force\]')"
check "and gives remove no --no-relaunch, since it never quits Desktop" 1 "$(cda --help | grep -cx '  claude-multipass remove <name>')"
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

# save refuses a second name for an account already saved under another
kc_put claude-multipass beta '{"claudeAiOauth":{"accessToken":"at-zeta"}}'
printf '{"oauthAccount":{"accountUuid":"zzzzzzzz-9999"}}' > "$p/beta/cli.json"
rm -f "$tmp/calls"
check "save of a second name for a saved account is refused" 3 "$(exit_code cda save beta2)"
check_true "a refused second name does not quit or relaunch Desktop" test ! -e "$tmp/calls"
check_true "and creates no profile" test ! -e "$p/beta2"
check "save --force takes the second name" 0 "$(exit_code cda save beta2 --no-relaunch --force)"
check "and moves the first name to backups" 2 "$(find "$b" -maxdepth 1 -name 'profile-beta-*' | wc -l | tr -d ' ')"
check_true "leaving one name for the account" test ! -e "$p/beta"
check "the second name holds the account" zzzzzzzz-9999 "$(jq -r .account "$p/beta2/meta.json")"
check "and keeps the first name's CLI login" at-zeta "$(kc_get claude-multipass beta2 | jq -r .claudeAiOauth.accessToken)"
check_true "with its identity" test -f "$p/beta2/cli.json"
check "the first name's CLI item is gone" absent "$(kc_get claude-multipass beta)"
cda rename beta2 beta > /dev/null

# save over a profile whose meta.json is unreadable: refused before the quit, replaced with --force
cp "$d/config.json" "$tmp/config-before-broken"
printf '{"oauth:tokenCacheV2":"enc-Y","lastKnownAccountUuid":"yyyyyyyy-8888"}' > "$d/config.json"
mkdir -p "$p/broken"
printf 'not json' > "$p/broken/meta.json"
rm -f "$tmp/calls"
st=0
err=$(cda save broken 2>&1 > /dev/null) || st=$?
check "save over an unreadable meta.json is refused" 3 "$st"
check_true "and names the file" grep -q "broken: $p/broken/meta.json is not valid" <<< "$err"
check_true "and does not quit or relaunch Desktop" test ! -e "$tmp/calls"
check "save --force replaces the broken profile" 0 "$(exit_code cda save broken --no-relaunch --force)"
check "and moves it to backups" 1 "$(find "$b" -maxdepth 1 -name 'profile-broken-*' | wc -l | tr -d ' ')"
check "and saves the signed-in account" yyyyyyyy-8888 "$(jq -r .account "$p/broken/meta.json")"
cda remove broken > /dev/null
cp "$tmp/config-before-broken" "$d/config.json"

# add refuses to sign out a login that was never saved
printf '{"oauth:tokenCacheV2":"enc-Y","lastKnownAccountUuid":"yyyyyyyy-8888"}' > "$d/config.json"
rm -f "$tmp/calls"
check "add refuses to drop an unsaved login" 3 "$(exit_code cda add omega)"
check_true "a refused add does not quit or relaunch Desktop" test ! -e "$tmp/calls"
check "and leaves the login in place" yyyyyyyy-8888 "$(jq -r .lastKnownAccountUuid "$d/config.json")"
check "add --force signs it out anyway" 0 "$(exit_code cda add omega --no-relaunch --force)"
check "forced add cleared the login" null "$(jq -r .lastKnownAccountUuid "$d/config.json")"

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
cda add eps --no-relaunch --force > /dev/null 2>&1
check "login backups pruned to ten" 10 "$(find "$b" -mindepth 1 -maxdepth 1 -type d -name 'login-*' | wc -l | tr -d ' ')"
check "the oldest pruned backup's CLI item is gone" absent "$(kc_get claude-multipass login-20200101000001-1)"
for i in $(seq 1 12); do
  if [[ -d $b/login-2020010100000$i-1 ]]; then check "kept backup $i keeps its CLI item" old "$(kc_get claude-multipass "login-2020010100000$i-1" | jq -r .claudeAiOauth.accessToken)"; else check "pruned backup $i loses its CLI item" absent "$(kc_get claude-multipass "login-2020010100000$i-1")"; fi
done
# profile backups prune to the newest ten by stamp, not by name; a folder
# without a stamp is left alone
for i in $(seq 1 12); do
  mkdir -p "$b/profile-old-20200101-0000$(printf %02d "$i")-1"
done
mkdir -p "$b/profile-kept-by-hand"
cp -R "$p/beta" "$p/aa-two"
cda remove aa-two > /dev/null
check "profile backups pruned to ten" 10 "$(find "$b" -mindepth 1 -maxdepth 1 -type d -name 'profile-*' ! -name 'profile-kept-by-hand' | wc -l | tr -d ' ')"
check "the just-removed profile is kept" 1 "$(find "$b" -mindepth 1 -maxdepth 1 -type d -name 'profile-aa-two-*' | wc -l | tr -d ' ')"
check_true "the oldest set-aside profile is gone" test ! -e "$b/profile-old-20200101-000001-1"
check_true "the newest fixture stays" test -d "$b/profile-old-20200101-000012-1"
check_true "a folder without a stamp is left alone" test -d "$b/profile-kept-by-hand"
check "login backups untouched by the profile prune" 10 "$(find "$b" -mindepth 1 -maxdepth 1 -type d -name 'login-*' | wc -l | tr -d ' ')"
check_true "doctor counts both kinds" grep -q "ok: backups: 10 saved logins and 11 set-aside profiles in $b" <<< "$(cda doctor 2>&1)"
rm -r "$b/profile-kept-by-hand"
# A clock set back: the folder just made carries an older stamp than the
# backups already there, and must survive the prune anyway
for i in $(seq 1 10); do mkdir -p "$b/login-209901$(printf %02d "$i")-000000-1" "$b/profile-old-209901$(printf %02d "$i")-000000-1"; done
printf '{"oauth:tokenCache":"x","oauth:tokenCacheV2":"enc-R","lastKnownAccountUuid":"rrrrrrrr-0000"}' > "$d/config.json"
cda add zeta --no-relaunch --force > /dev/null 2>&1
check "login backups still pruned to ten under a clock set back" 10 "$(find "$b" -mindepth 1 -maxdepth 1 -type d -name 'login-*' | wc -l | tr -d ' ')"
check "the login just backed up survives a clock set back" 1 "$(find "$b" -mindepth 1 -maxdepth 1 -type d -name "login-$(date +%Y)*" | wc -l | tr -d ' ')"
check_true "and the oldest other login went" test ! -e "$b/login-20990101-000000-1"
check_true "while the newest other stays" test -d "$b/login-20990110-000000-1"
cp -R "$p/beta" "$p/aa-three"
cda remove aa-three > /dev/null
check "profile backups still pruned to ten under a clock set back" 10 "$(find "$b" -mindepth 1 -maxdepth 1 -type d -name 'profile-*' | wc -l | tr -d ' ')"
check "the profile just set aside survives a clock set back" 1 "$(find "$b" -mindepth 1 -maxdepth 1 -type d -name 'profile-aa-three-*' | wc -l | tr -d ' ')"
check_true "and the oldest other profile went" test ! -e "$b/profile-old-20990101-000000-1"
check_true "while the newest other stays" test -d "$b/profile-old-20990110-000000-1"
# A store path with a space: the prune must not split it and rm a sibling
# named after its first word. Run from $tmp so a split's relative half lands there.
spaced="$tmp/my store"
mkdir -p "$tmp/my/keep"
for i in $(seq 1 12); do mkdir -p "$spaced/backups/login-2020010100000$i-1"; done
(cd "$tmp" && CLAUDE_MULTIPASS_DIR=$spaced cda add zed --no-relaunch > /dev/null 2>&1)
check_true "a spaced store path spares a sibling directory" test -d "$tmp/my/keep"
check "and still prunes to ten" 10 "$(find "$spaced/backups" -mindepth 1 -maxdepth 1 -type d -name 'login-*' | wc -l | tr -d ' ')"
err=$(SECURITY_FAIL_DELETE=1 CLAUDE_MULTIPASS_DIR=$spaced cda add zed --no-relaunch 2>&1 > /dev/null)
check_true "a prune whose Keychain delete fails warns" grep -q "could not delete the Keychain item for $spaced/backups/login-" <<< "$err"
check "and still prunes the folder" 10 "$(find "$spaced/backups" -mindepth 1 -maxdepth 1 -type d -name 'login-*' | wc -l | tr -d ' ')"

# usage: a fixture token cache encrypted the way the app does; security and
# curl are stubs on PATH, so no Keychain and no network
mkdir -p "$p/usagey" "$p/stale"
# The usage and profile endpoints answer from files; profile-code sets the
# profile's HTTP code. Every call's argv and stdin go to curl-args.
write_curl() {
  printf '#!/bin/sh\n{ echo "curl $*"; cat; } >> "%s/curl-args"\ncase "$*" in\n  *3456/health*) exit 0 ;;\n  *oauth/profile*) cat "%s/profile.json" 2> /dev/null; printf "\\n%%s" "$(cat "%s/profile-code" 2> /dev/null || echo 200)" ;;\n  *) cat "%s/usage.json"; printf "\\n200" ;;\nesac\n' "$tmp" "$tmp" "$tmp" "$tmp" > "$tmp/bin/curl"
}
printf '{"five_hour":{"utilization":42.6,"resets_at":"2026-10-23T19:45:00.123456+00:00"},"seven_day":{"utilization":18.0,"resets_at":"2026-10-27T13:00:00Z"}}' > "$tmp/usage.json"
write_curl
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
write_curl
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

# usage: the plan label from the profile endpoint, cached a day per account;
# a verified Ultra (Ultra label, idle session with no reset) shows Ultra in
# place of the 5-hour window; per-model weekly limits come from limits[]
plans=$CLAUDE_MULTIPASS_DIR/plans
rm -rf "$plans"
: > "$tmp/curl-args"
printf '{"organization":{"organization_type":"claude_max","rate_limit_tier":"default_claude_max_20x","plan_display_name":"Ultra"}}' > "$tmp/profile.json"
printf '{"five_hour":{"utilization":0.0,"resets_at":null,"locked_reason":null},"seven_day":{"utilization":69.0,"resets_at":null},"limits":[{"kind":"session","percent":0,"resets_at":null,"scope":null},{"kind":"weekly_all","percent":69,"resets_at":null,"scope":null},{"kind":"weekly_scoped","percent":96,"severity":"critical","resets_at":null,"scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}},{"kind":"weekly_scoped","percent":5,"scope":"odd"},"junk"]}' > "$tmp/usage.json"
check "usage shows Ultra for a verified Ultra and the Fable limit" "usagey           Ultra  7d 69%  Fable 96%" "$(cda usage usagey)"
check "usage reads the profile endpoint once" 1 "$(grep -c 'https://api.anthropic.com/api/oauth/profile' "$tmp/curl-args")"
check "usage caches the plan per account" Ultra "$(cat "$plans/uuuuuuuu-1")"
check "the plan cache is private" 600 "$(stat -f %Lp "$plans/uuuuuuuu-1")"
check "the plans folder is private" 700 "$(stat -f %Lp "$plans")"
out=$(cda usage usagey --json)
check "a second run within a day reads the cache, not the endpoint" 1 "$(grep -c 'oauth/profile' "$tmp/curl-args")"
check "usage --json plan" Ultra "$(jq -r '.profiles[0].plan' <<< "$out")"
check "usage --json ultra" true "$(jq -r '.profiles[0].ultra' <<< "$out")"
check "usage --json drops the 5-hour window for a verified Ultra" null "$(jq -r '.profiles[0].fiveHour' <<< "$out")"
check "usage --json scoped limits, malformed entries skipped" '[{"name":"Fable","utilization":96}]' "$(jq -c '.profiles[0].scoped' <<< "$out")"
check "usage --json never prints a token with the plan" 0 "$(grep -c tok-u <<< "$out")"
check "the profile call keeps the token off the command line" 0 "$(grep -c 'curl .*tok-u' "$tmp/curl-args")"
printf '{"five_hour":{"utilization":17.0,"resets_at":"2026-10-23T19:45:00Z"},"seven_day":{"utilization":59.0},"limits":[{"kind":"weekly_scoped","percent":100,"severity":"critical","resets_at":"2026-10-27T13:00:00Z","scope":{"model":{"display_name":"Fable"}}}]}' > "$tmp/usage.json"
out=$(cda usage usagey --json)
check "an Ultra still under a session limit keeps its 5-hour window" 17.0 "$(jq -r '.profiles[0].fiveHour.utilization' <<< "$out")"
check "and is not marked ultra" null "$(jq -r '.profiles[0].ultra' <<< "$out")"
check "usage --json scoped resetsAt" 2026-10-27T13:00:00Z "$(jq -r '.profiles[0].scoped[0].resetsAt' <<< "$out")"
check "usage prints a reached Fable limit" "usagey           5h 17% (resets $(date -r 1792784700 '+%a %H:%M'))  7d 59%  Fable 100% (resets $(date -r 1793106000 '+%a %H:%M'))" "$(cda usage usagey)"
printf '{"five_hour":{"utilization":0.0,"resets_at":null},"seven_day":{"utilization":3.0}}' > "$tmp/usage.json"
touch -t 202001010000 "$plans/uuuuuuuu-1"
printf '{"organization":{"plan_display_name":"Max"}}' > "$tmp/profile.json"
check "a day-old plan is read again, and only Ultra replaces the 5-hour window" "usagey           5h 0%  7d 3%" "$(cda usage usagey)"
check "the stale cache took the new label" Max "$(cat "$plans/uuuuuuuu-1")"
touch -A -250000 "$plans/uuuuuuuu-1"
printf 500 > "$tmp/profile-code"
check "a failed profile read keeps the last label" Max "$(cda usage usagey --json | jq -r '.profiles[0].plan')"
calls=$(grep -c 'oauth/profile' "$tmp/curl-args")
cda usage usagey > /dev/null
check "and is not retried until the day is out" "$calls" "$(grep -c 'oauth/profile' "$tmp/curl-args")"
# the week cap counts from when the label was read (birth time), not from the
# last touch: a backdated mtime moves the birth time back, a later touch does not
printf 500 > "$tmp/profile-code"
touch -t 202001010000 "$plans/uuuuuuuu-1"
touch -t "$(date -v-25H +%Y%m%d%H%M)" "$plans/uuuuuuuu-1"
check "a label read over a week ago is not kept through a failed read" null "$(cda usage usagey --json | jq -r '.profiles[0].plan')"
printf Max > "$plans/uuuuuuuu-1" && touch -t "$(date -v-6d -v-1H +%Y%m%d%H%M)" "$plans/uuuuuuuu-1"
check "nor one read over six days ago, so it never shows past a week" null "$(cda usage usagey --json | jq -r '.profiles[0].plan')"
for code in 429 408; do
  printf "$code" > "$tmp/profile-code"
  printf Max > "$plans/uuuuuuuu-1" && touch -A -250000 "$plans/uuuuuuuu-1"
  check "a $code is a failed read that keeps the label" Max "$(cda usage usagey --json | jq -r '.profiles[0].plan')"
  rm -f "$plans/uuuuuuuu-1"
  cda usage usagey > /dev/null
  calls=$(grep -c 'oauth/profile' "$tmp/curl-args")
  touch -A -010100 "$plans/uuuuuuuu-1"
  cda usage usagey > /dev/null
  check "a $code with nothing cached is retried after an hour" "$((calls + 1))" "$(grep -c 'oauth/profile' "$tmp/curl-args")"
done
for code in 401 403; do
  printf "$code" > "$tmp/profile-code"
  printf Max > "$plans/uuuuuuuu-1" && touch -A -250000 "$plans/uuuuuuuu-1"
  check "a $code refusal keeps a cached label" Max "$(cda usage usagey --json | jq -r '.profiles[0].plan')"
  rm -f "$plans/uuuuuuuu-1"
  check "a $code refusal with nothing cached gives no plan" null "$(cda usage usagey --json | jq -r '.profiles[0].plan')"
  calls=$(grep -c 'oauth/profile' "$tmp/curl-args")
  touch -A -020000 "$plans/uuuuuuuu-1"
  cda usage usagey > /dev/null
  check "and stands for the day, not an hour: $code" "$calls" "$(grep -c 'oauth/profile' "$tmp/curl-args")"
done
printf 200 > "$tmp/profile-code"
printf Max > "$plans/uuuuuuuu-1" && touch -A -250000 "$plans/uuuuuuuu-1"
for odd in '<html>proxy</html>' '{"error":"x"}' '{"organization":"x"}'; do
  printf '%s' "$odd" > "$tmp/profile.json"
  check "a 200 that is not a profile keeps the label: $odd" Max "$(cda usage usagey --json | jq -r '.profiles[0].plan')"
  touch -A -250000 "$plans/uuuuuuuu-1"
done
printf '{"organization":{"plan_display_name":"Max"}}' > "$tmp/profile.json"
rm -f "$tmp/profile-code" "$plans/uuuuuuuu-1"
printf '{"organization":{"plan_display_name":"Ultra\\u001b[31m"}}' > "$tmp/profile.json"
check "a plan label outside the name pattern is dropped" null "$(cda usage usagey --json | jq -r '.profiles[0].plan')"
rm -f "$plans/uuuuuuuu-1"
# each half of the Ultra rule on its own keeps the 5-hour window
printf '{"organization":{"plan_display_name":"Ultra"}}' > "$tmp/profile.json"
printf '{"five_hour":{"utilization":0.0,"resets_at":"2026-10-23T19:45:00Z"},"seven_day":{"utilization":1.0}}' > "$tmp/usage.json"
out=$(cda usage usagey --json)
check "Ultra at 0% with a reset keeps its 5-hour window" 0.0 "$(jq -r '.profiles[0].fiveHour.utilization' <<< "$out")"
check "and is not marked ultra" null "$(jq -r '.profiles[0].ultra' <<< "$out")"
printf '{"five_hour":{"utilization":5.0,"resets_at":null},"seven_day":{"utilization":1.0}}' > "$tmp/usage.json"
out=$(cda usage usagey --json)
check "Ultra at 5% with no reset keeps its 5-hour window" 5.0 "$(jq -r '.profiles[0].fiveHour.utilization' <<< "$out")"
printf '{"seven_day":{"utilization":1.0}}' > "$tmp/usage.json"
check "Ultra with no 5-hour window at all is marked ultra" true "$(cda usage usagey --json | jq -r '.profiles[0].ultra')"
check "every profile call sends the bearer header on stdin" "$(grep -c 'oauth/profile' "$tmp/curl-args")" "$(sed -n '/oauth\/profile/{n;p;}' "$tmp/curl-args" | grep -c -x 'header = "Authorization: Bearer tok-u"')"
# any 200 is the answer for a day, so a plan that loses its label stops showing
touch -t 202001010000 "$plans/uuuuuuuu-1"
printf '{"organization":{"plan_display_name":null}}' > "$tmp/profile.json"
check "a 200 with no label replaces the cached one" null "$(cda usage usagey --json | jq -r '.profiles[0].plan')"
calls=$(grep -c 'oauth/profile' "$tmp/curl-args")
touch -A -020000 "$plans/uuuuuuuu-1"
cda usage usagey > /dev/null
check "and stands for the day, not an hour" "$calls" "$(grep -c 'oauth/profile' "$tmp/curl-args")"
# a failed first read caches nothing usable for an hour, then retries
rm -f "$plans/uuuuuuuu-1"
printf 500 > "$tmp/profile-code"
check "a failed first read gives no plan" null "$(cda usage usagey --json | jq -r '.profiles[0].plan')"
calls=$(grep -c 'oauth/profile' "$tmp/curl-args")
cda usage usagey > /dev/null
check "and is not retried within the hour" "$calls" "$(grep -c 'oauth/profile' "$tmp/curl-args")"
rm -f "$tmp/profile-code"
printf '{"organization":{"plan_display_name":"Ultra"}}' > "$tmp/profile.json"
touch -A -010100 "$plans/uuuuuuuu-1"
check "an hour after a failed first read it is read again" Ultra "$(cda usage usagey --json | jq -r '.profiles[0].plan')"
# a plans folder that cannot be written means no profile call at all
rm -rf "$plans" && mkdir -m 500 "$plans"
calls=$(grep -c 'oauth/profile' "$tmp/curl-args")
check "an unwritable plans folder still reports usage" 1.0 "$(cda usage usagey --json | jq -r '.profiles[0].sevenDay.utilization')"
check "and makes no profile call" "$calls" "$(grep -c 'oauth/profile' "$tmp/curl-args")"
check_true "doctor warns about an unwritable plans folder" grep -q "^warn: plans: $plans is not writable" <<< "$(cda doctor)"
chmod 700 "$plans"
check "doctor is quiet about a writable plans folder" 0 "$(cda doctor | grep -c '^warn: plans:')"
# odd limits[] shapes and reset times never cost the account
printf '{"organization":{"plan_display_name":"Ultra"}}' > "$tmp/profile.json"
printf '{"five_hour":{"utilization":5.0,"resets_at":"bogus"},"seven_day":{"utilization":9.0},"limits":[{"kind":"weekly_scoped","percent":5,"resets_at":1730000000,"scope":{"model":{"display_name":"Fable"}}},{"kind":"weekly_scoped","percent":7,"resets_at":"2026-11-01T00:00:00-04:30","scope":{"model":null,"surface":{"display_name":" Cowork "}}},{"kind":"weekly_scoped","percent":8,"scope":{"model":{"display_name":"   "}}}]}' > "$tmp/usage.json"
out=$(cda usage usagey --json)
check "an unparsable reset time is dropped and an offset converted, the account kept" '[{"name":"Fable","utilization":5},{"name":"Cowork","utilization":7,"resetsAt":"2026-11-01T04:30:00Z"}]' "$(jq -c '.profiles[0].scoped' <<< "$out")"
check "and the 5-hour window keeps its figure" 5.0 "$(jq -r '.profiles[0].fiveHour.utilization' <<< "$out")"
check "the text line skips a bad reset time" "usagey           5h 5%  7d 9%  Fable 5%  Cowork 7% (resets $(date -r 1793507400 '+%a %H:%M'))" "$(cda usage usagey)"
printf '{"five_hour":5,"seven_day":{"utilization":"20"},"limits":[{"kind":"weekly_scoped","percent":null,"scope":{"model":{"display_name":"Fable"}}},{"kind":"weekly_scoped","percent":"96","scope":{"model":{"display_name":"Fable"}}},{"kind":"weekly_scoped","percent":3,"scope":{"model":{"display_name":"Fa\\u001b[31mble"}}},{"kind":"weekly_scoped","percent":4,"scope":{"model":{"display_name":"A model name that runs well past forty characters"}}},{"kind":"weekly_scoped","percent":6,"scope":{"model":{"display_name":"Fable"}}}]}' > "$tmp/usage.json"
out=$(cda usage usagey --json)
check "odd windows are left out, the account kept" usagey "$(jq -r '.profiles[0] | select(has("fiveHour") or has("sevenDay") | not) | .name' <<< "$out")"
check "a limit without a numeric percent or with an unsafe name is dropped" '[{"name":"Fable","utilization":6}]' "$(jq -c '.profiles[0].scoped' <<< "$out")"
check "the plan is Ultra for this case" Ultra "$(jq -r '.profiles[0].plan' <<< "$out")"
check "the text line shows an unreadable window as ? and only the safe limit" "usagey           5h ?  7d ?  Fable 6%" "$(cda usage usagey)"
printf '{"five_hour":{"utilization":1e400},"seven_day":{"utilization":3.0,"resets_at":"9999-12-31T23:59:59-12:00"},"limits":[{"kind":"weekly_scoped","percent":1e400,"scope":{"model":{"display_name":"Fable"}}},{"kind":"weekly_scoped","percent":4,"resets_at":"2026-11-01T00:00:00+99:99","scope":{"model":{"display_name":"Fable"}}}]}' > "$tmp/usage.json"
out=$(cda usage usagey --json)
check "no out-of-range number reaches the JSON" 0 "$(grep -c -i 'e+4' <<< "$out")"
check "an out-of-range limit is dropped, a bad offset loses only its reset" '[{"name":"Fable","utilization":4}]' "$(jq -c '.profiles[0].scoped' <<< "$out")"
check "a reset past year 9999 is dropped, the text line kept" "usagey           5h ?  7d 3%  Fable 4%" "$(cda usage usagey)"
printf '{"seven_day":{"utilization":"20","resets_at":"2026-11-01T00:00:00Z"},"limits":[{"kind":"weekly_scoped","percent":1,"resets_at":"2026-11-01T00:00:00+14:00","scope":{"model":{"display_name":"A"}}},{"kind":"weekly_scoped","percent":2,"resets_at":"2026-11-01T00:00:00+15:00","scope":{"model":{"display_name":"B"}}},{"kind":"weekly_scoped","percent":3,"resets_at":"2026-11-01T00:00:00+05:60","scope":{"model":{"display_name":"C"}}}]}' > "$tmp/usage.json"
out=$(cda usage usagey --json)
check "a +14:00 offset converts, +15:00 and a 60-minute offset are dropped" '[{"name":"A","utilization":1,"resetsAt":"2026-10-31T10:00:00Z"},{"name":"B","utilization":2},{"name":"C","utilization":3}]' "$(jq -c '.profiles[0].scoped' <<< "$out")"
check "an unreadable window shows no reset" "usagey           Ultra  7d ?  A 1% (resets $(date -r 1793440800 '+%a %H:%M'))  B 2%  C 3%" "$(cda usage usagey)"
printf '{"_plan":5,"seven_day":{"utilization":3.0}}' > "$tmp/usage.json"
out=$(cda usage usagey --json)
check "a _plan in the server's body never reaches the output" Ultra "$(jq -r '.profiles[0].plan' <<< "$out")"
printf '[1]' > "$tmp/usage.json"
check "a body that is not an object is an unreadable response" "unreadable response" "$(cda usage usagey --json | jq -r '.profiles[0].error')"
# the account id names the cache file, so one that is not an id writes nothing
mkdir -p "$p/escapey"
esc_plain='{"acct:../escape|c:o:a:user:profile":{"token":"tok-e","expiresAt":FUTURE}}'
enc=$(encrypt "${esc_plain//FUTURE/$future}")
jq -n --arg v "$enc" '{"oauth:tokenCacheV2":$v}' > "$p/escapey/config.json"
printf '{"account":"../escape","savedAt":"2026-01-01T00:00:00Z"}' > "$p/escapey/meta.json"
cp "$tmp/usage-full.json" "$tmp/usage.json"
out=$(cda usage escapey --json)
check "an account that is not an id still reports usage" 18.0 "$(jq -r '.profiles[0].sevenDay.utilization' <<< "$out")"
check "with no plan" null "$(jq -r '.profiles[0].plan' <<< "$out")"
check_true "and writes nothing outside the plans folder" test ! -e "$CLAUDE_MULTIPASS_DIR/escape"
rm -rf "$p/escapey"
rm -rf "$plans" "$tmp/profile.json"
cp "$tmp/usage-full.json" "$tmp/usage.json"
cp "$p/usagey/meta.json" "$tmp/usagey-meta"
printf 'not json' > "$p/usagey/meta.json"
bad_meta="usagey: $p/usagey/meta.json is not valid; remove usagey, then save it again"
n_login=$(find "$b" -mindepth 1 -maxdepth 1 -name 'login-*' | wc -l | tr -d ' ')
for c in show usage switch; do
  rc=0
  err=$(cda "$c" usagey --no-relaunch 2>&1 > /dev/null) || rc=$?
  check "$c of a name with an unreadable meta.json fails" 1 "$rc"
  check_true "and names the file" grep -qF "$bad_meta" <<< "$err"
done
check "switch fails before quitting Desktop, so no login is backed up" "$n_login" "$(find "$b" -mindepth 1 -maxdepth 1 -name 'login-*' | wc -l | tr -d ' ')"
cp "$tmp/usagey-meta" "$p/usagey/meta.json"

# doctor: one line per check, exit 1 on any fail:, no Keychain, no network
rm -f "$tmp/calls"
touch "$tmp/calls"
check "doctor healthy" 0 "$(exit_code cda doctor)"
check_true "doctor reports jq" grep -q '^ok: jq' <<< "$(cda doctor)"
check_true "doctor reports the Command Line Tools" grep -q '^ok: Command Line Tools' <<< "$(cda doctor)"
# Without the Tools /usr/bin/python3 is a shim that fails, which must not read as a Keychain failure.
printf '#!/bin/sh\nexit 2\n' > "$tmp/bin/xcode-select"
n_security=$(wc -l < "$tmp/security-calls")
check "usage without the Command Line Tools exits 1" 1 "$(exit_code cda usage)"
check "and names them" "usage needs the Command Line Tools (xcode-select --install)" "$(err_of cda usage)"
check "usage --json without them exits 1 too" 1 "$(exit_code cda usage --json)"
check "and neither reads the Keychain" "$n_security" "$(wc -l < "$tmp/security-calls")"
check_true "doctor warns about them" grep -q '^warn: Command Line Tools: not installed' <<< "$(cda doctor)"
printf '#!/bin/sh\necho /Library/Developer/CommandLineTools\n' > "$tmp/bin/xcode-select"
n_sec=$(wc -l < "$tmp/security-calls" | tr -d ' ')
cda doctor > /dev/null
check "doctor never calls security" "$n_sec" "$(wc -l < "$tmp/security-calls" | tr -d ' ')"
check_true "doctor names a profile without a CLI login" grep -q '^warn: legacy: no CLI login saved' <<< "$(cda doctor)"
check_true "doctor warns on CLAUDE_CONFIG_DIR" grep -q '^warn: CLAUDE_CONFIG_DIR is set; the CLI login is not saved or switched' <<< "$(CLAUDE_CONFIG_DIR=/x cda doctor)"
check_true "doctor warns on CLAUDE_SECURESTORAGE_CONFIG_DIR" grep -q '^warn: CLAUDE_SECURESTORAGE_CONFIG_DIR is set; the CLI login is not saved or switched' <<< "$(CLAUDE_SECURESTORAGE_CONFIG_DIR=/x cda doctor)"
check_true "doctor warns on ANTHROPIC_API_KEY" grep -q '^warn: ANTHROPIC_API_KEY is set; it overrides the terminal login' <<< "$(ANTHROPIC_API_KEY=x cda doctor)"
check_true "doctor warns on CLAUDE_CODE_OAUTH_TOKEN" grep -q '^warn: CLAUDE_CODE_OAUTH_TOKEN is set; it overrides the terminal login' <<< "$(CLAUDE_CODE_OAUTH_TOKEN=x cda doctor)"
check_true "doctor warns when claude is not on PATH" grep -q '^warn: claude: not on PATH; the terminal login is not verified after a switch' <<< "$(PATH=$noclaude cda doctor)"
mkdir -p "$tmp/has-claude"
printf '#!/bin/sh\n' > "$tmp/has-claude/claude"
chmod +x "$tmp/has-claude/claude"
check "doctor is quiet about claude when it is on PATH" 0 "$(PATH="$tmp/has-claude:$noclaude" cda doctor | grep -c '^warn: claude:')"
check "doctor on a fresh store exits 0" 0 "$(CLAUDE_MULTIPASS_DIR="$tmp/fresh-store" exit_code cda doctor)"
check_true "doctor on a fresh store counts no backups" grep -q '^ok: backups: 0 saved logins' <<< "$(CLAUDE_MULTIPASS_DIR="$tmp/fresh-store" cda doctor)"
check_true "the fresh store has no plans folder" test ! -d "$tmp/fresh-store/plans"
check "doctor is quiet when there is no plans folder yet" 0 "$(CLAUDE_MULTIPASS_DIR="$tmp/fresh-store" cda doctor | grep -c '^warn: plans:')"
mkdir -p "$tmp/legacy-home/dotfiles/claude-desktop-accounts"
check_true "doctor warns about a leftover dotfiles-era store" grep -q "^warn: legacy store: $tmp/legacy-home/dotfiles/claude-desktop-accounts still exists" <<< "$(XDG_CONFIG_HOME="$tmp/legacy-home" cda doctor)"
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
# an unsaved live login gets its own row, read from Desktop's config.json
cp "$d/config.json" "$tmp/config-saved-live"
plain='{"acct:vvvvvvvv-1|c:o:a:user:profile user:inference":{"token":"tok-v","expiresAt":FUTURE}}'
enc=$(encrypt "${plain//FUTURE/$future}")
jq -n --arg v "$enc" '{"oauth:tokenCacheV2":$v,"lastKnownAccountUuid":"vvvvvvvv-1"}' > "$d/config.json"
check "usage adds a (signed in) row for an unsaved live login" "(signed in)      $expected" "$(cda usage | grep '^(signed in) ')"
check "but not when one name is asked for" 0 "$(cda usage usagey | grep -c '^(signed in)' || true)"
: > "$tmp/stdin-types"
cda_stdin usage > /dev/null
check "usage passes the decrypted token cache to jq through a pipe" 0 "$(grep -c 'Regular File' "$tmp/stdin-types" || true)"
check_true "and the log saw jq read a pipe" grep -q '^jq Fifo File' "$tmp/stdin-types"
cp "$tmp/config-saved-live" "$d/config.json"

# Without jq, signed_in would read a signed-in login as signed out, so add
# would skip its unsaved-login refusal and quit Desktop. The system folders
# are linked one by one, because /usr/bin holds a jq from macOS 15.
mkdir -p "$tmp/no-jq"
ln -sf /usr/bin/* /bin/* "$tmp/no-jq/"
rm -f "$tmp/no-jq/jq"
nojq="$tmp/bin:$tmp/no-jq"
check "the no-jq PATH has no jq" "" "$(env PATH="$nojq" /bin/sh -c "command -v jq || true")"
# Reports Claude running until a stub logs a quit, so a quit is seen and returns at once.
printf '#!/bin/sh\ntest ! -s "%s/calls"\n' "$tmp" > "$tmp/bin/pgrep"
: > "$tmp/calls"
n_login=$(find "$b" -mindepth 1 -maxdepth 1 -name 'login-*' | wc -l | tr -d ' ')
jq_message='jq is missing or not working and claude-multipass needs it (https://jqlang.org/download/)'
add_rc=$(PATH=$nojq exit_code cda add nojq-new)
check "add without jq never quits Desktop" "" "$(cat "$tmp/calls")"
check "add without jq exits 1" 1 "$add_rc"
check "and names jq" "$jq_message" "$(PATH=$nojq err_of cda add nojq-new)"
check "--force does not lift it" 1 "$(PATH=$nojq exit_code cda add nojq-new --force)"
check "switch without jq exits 1" 1 "$(PATH=$nojq exit_code cda switch usagey)"
check "and names jq" "$jq_message" "$(PATH=$nojq err_of cda switch usagey)"
check "current without jq exits 1" 1 "$(PATH=$nojq exit_code cda current)"
check "and names jq" "$jq_message" "$(PATH=$nojq err_of cda current)"
check "no stub saw a quit or a launch" "" "$(cat "$tmp/calls")"
check "and no login was backed up" "$n_login" "$(find "$b" -mindepth 1 -maxdepth 1 -name 'login-*' | wc -l | tr -d ' ')"
check "--version runs without jq" "claude-multipass $pkg_version" "$(PATH=$nojq cda --version)"
check "--help runs without jq" 0 "$(PATH=$nojq exit_code cda --help)"
store_state() { (cd "$CLAUDE_MULTIPASS_DIR" && find . -type f -exec cksum {} + | sort); }
store_before=$(store_state)
check_jq_refused() {
  local jq_path=$1 run err rc
  for run in 'save usagey' list 'list --json' 'show usagey' 'sync --force' usage 'rename usagey jq-renamed' 'remove usagey' pick; do
    err=$(PATH=$jq_path TERM=dumb cda $run 2>&1 > /dev/null) && rc=0 || rc=$?
    check "$run with this jq exits 1" 1 "$rc"
    check "and names jq" "$jq_message" "$err"
  done
  check "and none changed the store" "$store_before" "$(store_state)"
  check "or quit Desktop" "" "$(cat "$tmp/calls")"
}
check_jq_refused "$nojq"
check_doctor_without_jq() {
  local out rc
  out=$(PATH=$1 cda doctor) && rc=0 || rc=$?
  check "doctor with this jq exits 1" 1 "$rc"
  check_true "and reports it" grep -q '^fail: jq: not on PATH or not working' <<< "$out"
  check "and that is its only fail: line" 1 "$(grep -c '^fail: ' <<< "$out")"
  check "and says it did not check the config" 1 "$(grep -c '^warn: config: not checked without jq$' <<< "$out")"
  check "and does not call the config ok" 0 "$(grep -c '^ok: config: ' <<< "$out")"
  check "and blames no profile's token" 0 "$(grep -c 'empty oauth:tokenCacheV2' <<< "$out")"
  check "and calls no profile ok" 0 "$(grep -c '^ok: usagey' <<< "$out")"
  check "and says once that it skipped the check" 1 "$(grep -c '^warn: profiles: saved tokens not checked without jq' <<< "$out")"
}
check_doctor_without_jq "$nojq"
# A jq that runs and fails, as a stale version-manager shim does (exit 1), must
# not read as signed out either.
mkdir -p "$tmp/broken-jq"
printf '#!/bin/sh\necho "mise ERROR not a valid shim" >&2\nexit 1\n' > "$tmp/broken-jq/jq"
chmod +x "$tmp/broken-jq/jq"
brokenjq="$tmp/broken-jq:$PATH"
check "add with a jq that exits 1 exits 1" 1 "$(PATH=$brokenjq exit_code cda add badread-new)"
check "and names jq" "$jq_message" "$(PATH=$brokenjq err_of cda add badread-new)"
check "and never quits Desktop" "" "$(cat "$tmp/calls")"
check "current with a jq that exits 1 exits 1" 1 "$(PATH=$brokenjq exit_code cda current)"
check_jq_refused "$brokenjq"
check_doctor_without_jq "$brokenjq"
# A config.json jq cannot read: the commands that quit Desktop stop first, and
# everything else answers as it always did. The cases run with Desktop "running".
cp "$d/config.json" "$tmp/config-before-bad-read"
printf '#!/bin/sh\ngrep "^usagey "\n' > "$tmp/bin/fzf"
check_bad_config() {
  local out rc=0
  printf '%s' "$1" > "$d/config.json"
  check "add on config '$1' exits 1" 1 "$(exit_code cda add badread-new)"
  check "and names the file" 1 "$(err_of cda add badread-new | grep -c "^Could not read $d/config.json")"
  check "and none quit Desktop" "" "$(cat "$tmp/calls")"
  check "or backed up a login" "$n_login" "$(find "$b" -mindepth 1 -maxdepth 1 -name 'login-*' | wc -l | tr -d ' ')"
  check "or wrote the config" "$1" "$(cat "$d/config.json")"
  check_true "or left the run lock" test ! -L "$CLAUDE_MULTIPASS_DIR/.run.lock"
  out=$(cda list --json 2> /dev/null) || rc=$?
  check "list --json still answers" 0 "$rc"
  check "as signed out" false "$(jq -r .signedIn <<< "$out")"
  check "with the profiles listed" 1 "$(jq '[.profiles[] | select(.name == "usagey")] | length' <<< "$out")"
  rc=0
  out=$(cda doctor) || rc=$?
  check "doctor exits 1" 1 "$rc"
  check "and fails the config" 1 "$(grep -c "^fail: config: could not read $d/config.json" <<< "$out")"
  check "and does not call it ok" 0 "$(grep -c '^ok: config: ' <<< "$out")"
}
for bad in '{"oauth:tokenCacheV2":' '[]' '[] {}' '{} {}'; do
  check_bad_config "$bad"
  for run in 'add badread-new --force' 'switch usagey' 'switch usagey --force' 'save usagey' 'save usagey --force' pick; do
    check "$run on config '$bad' exits 1" 1 "$(exit_code cda $run)"
    check_true "and leaves no run lock" test ! -L "$CLAUDE_MULTIPASS_DIR/.run.lock"
  done
  check "and none quit Desktop" "" "$(cat "$tmp/calls")"
  check "or backed up a login" "$n_login" "$(find "$b" -mindepth 1 -maxdepth 1 -name 'login-*' | wc -l | tr -d ' ')"
  check "switch names the file" 1 "$(err_of cda switch usagey | grep -c "^Could not read $d/config.json")"
  check "save names the file" 1 "$(err_of cda save usagey | grep -c "^Could not read $d/config.json")"
  check "list still answers" 1 "$(cda list 2> /dev/null | grep -c '^  usagey ')"
  check "current still answers" "signed out" "$(cda current 2> /dev/null)"
  check "usage --json is not blocked" 0 "$(exit_code cda usage --json)"
  check "sync is not blocked" 0 "$(exit_code cda sync --force)"
done
# signed_in judges the last document, so this one reads as a signed-in login no profile holds.
printf '{"oauth:tokenCacheV2":"x"} {"oauth:tokenCacheV2":"y"}' > "$d/config.json"
for run in 'switch usagey' 'add badread-new' 'save badread-new'; do
  check "$run on a signed-in two-document config exits 1, not a refusal" 1 "$(exit_code cda $run)"
  check "and names the file" 1 "$(err_of cda $run | grep -c "^Could not read $d/config.json")"
done
check "and none quit Desktop" "" "$(cat "$tmp/calls")"
check_bad_config ''
chmod 000 "$d/config.json"
check "add on a config it may not read exits 1" 1 "$(exit_code cda add badread-new)"
check "and never quits Desktop" "" "$(cat "$tmp/calls")"
check "list --json still answers" 0 "$(exit_code cda list --json)"
chmod 600 "$d/config.json"
# An object is readable, whatever it holds: a signed-out config goes on to the quit.
for readable in '{}' '{"oauth:tokenCacheV2":""}'; do
  printf '%s' "$readable" > "$d/config.json"
  check "add on config '$readable' goes ahead" 0 "$(exit_code cda add badread-new --no-relaunch)"
  check "and quits Desktop" 1 "$(grep -c '^osascript' "$tmp/calls")"
  check "doctor calls it ok" 1 "$(cda doctor | grep -c '^ok: config: ')"
  : > "$tmp/calls"
done
cp "$tmp/config-before-bad-read" "$d/config.json"
printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/pgrep"

# An LLMR profile. The cases start from beta, whose CLI login matches Desktop's,
# with Desktop quit. In this block Claude runs while claude-up exists and LLMR's
# Desktop while llmr-up does (llmr makes both); the quit removes both.
llmr_pgrep() { printf '#!/bin/sh\ncase "$*" in\n  "-axq Claude" | "-xq Claude") test -e "%s/claude-up" ;;\n  "-aqf -- --user-data-dir=.*/claude-app-user-data/") test -e "%s/llmr-up" ;;\n  *) exit 1 ;;\nesac\n' "$tmp" "$tmp" > "$tmp/bin/pgrep"; }
llmr_pgrep
printf '#!/bin/sh\necho "osascript $*" >> "%s/calls"\nrm -f "%s/claude-up" "%s/llmr-up"\n' "$tmp" "$tmp" "$tmp" > "$tmp/bin/osascript"
rm -f "$tmp/claude-up" "$tmp/llmr-up"
cda switch beta --no-relaunch > /dev/null 2>&1
acct=beta
beta_uuid=$(jq -r .lastKnownAccountUuid "$d/config.json")
jq --arg u "$beta_uuid" '.oauthAccount = {accountUuid: $u, emailAddress: "b@example.com", organizationUuid: "org-beta"}' "$tmp/claude.json" > "$tmp/claude.json.new" && mv "$tmp/claude.json.new" "$tmp/claude.json"
kc_put "Claude Code-credentials" "$USER" '{"claudeAiOauth":{"accessToken":"at-beta-llmr","refreshToken":"rt-beta-llmr","expiresAt":2},"mcpOAuth":{"srv":"shared"}}'
jq -n --arg u "$beta_uuid" '{oauthAccount: {accountUuid: $u, emailAddress: "stale@example.com", organizationUuid: "org-beta"}}' > "$p/beta/cli.json"
check "the LLMR cases start signed in as beta" beta "$(cda current)"
cp "$d/config.json" "$tmp/config-before-llmr"

# save --llmr writes meta.json only, without quitting Desktop or reading the Keychain
: > "$tmp/security-calls"
rm -f "$tmp/calls"
check "save --llmr succeeds" 0 "$(exit_code cda save router --llmr router-p)"
check "save --llmr writes kind and llmrProfile" '{"kind":"llmr","llmrProfile":"router-p"}' "$(jq -c '{kind, llmrProfile}' "$p/router/meta.json")"
check "and nothing but meta.json" meta.json "$(ls "$p/router")"
check "and keeps it private" 600 "$(stat -f %Lp "$p/router/meta.json")"
check "save --llmr neither quits nor launches Desktop" "" "$(cat "$tmp/calls" 2> /dev/null)"
check "save --llmr never calls security" 0 "$(wc -l < "$tmp/security-calls" | tr -d ' ')"
check "save --llmr never runs llmr" "" "$(cat "$tmp/llmr-calls" 2> /dev/null)"
check "save --llmr over a claude.ai profile is refused" 3 "$(exit_code cda save "$acct" --llmr router-p)"
check "a claude.ai save over an LLMR profile is refused" 3 "$(exit_code cda save router)"
check "--llmr applies to save only" 1 "$(exit_code cda switch router --llmr router-p)"
check "--llmr needs a value" 1 "$(exit_code cda save router --llmr)"
check "--llmr takes a valid name" 1 "$(exit_code cda save router --llmr .bad)"
mkdir -p "$p/forced"
cp "$p/beta/config.json" "$p/forced/config.json"
printf '{"account":"ffffffff-0000","savedAt":"2026-01-01T00:00:00Z"}' > "$p/forced/meta.json"
kc_put claude-multipass forced '{"claudeAiOauth":{"accessToken":"at-forced"}}'
check "save --llmr --force replaces a claude.ai profile" 0 "$(exit_code cda save forced --llmr router-p --force)"
check "and sets the old one aside in backups" 1 "$(find "$b" -maxdepth 1 -name 'profile-forced-*' | wc -l | tr -d ' ')"
check "and deletes its CLI login item" absent "$(kc_get claude-multipass forced)"
rm -rf "$p/forced"
check "list --json exposes kind and llmrProfile" '{"name":"router","account":"","kind":"llmr","llmrProfile":"router-p","sessions":0,"cliSaved":false}' "$(cda list --json | jq -c '.profiles[] | select(.name == "router") | del(.savedAt)')"
check "list shows the LLMR row, unmarked while it does not run" 1 "$(cda list | grep -c '^  router           llmr router-p  ')"
check "show names the LLMR profile and the terminal hint" "LLMR profile router-p|terminal: run llmr router-p" "$(cda show router | sed -n '2p;4p' | paste -sd '|' -)"
check "doctor calls the LLMR profile ok" 1 "$(cda doctor | grep -c '^ok: router (LLMR profile router-p)$')"
check "usage refuses an LLMR profile" 1 "$(exit_code cda usage router)"
check "usage leaves LLMR profiles out" 0 "$(cda usage --json 2> /dev/null | jq '[.profiles[] | select(.name == "router")] | length')"

# switch to it saves the outgoing login, quits Desktop first and runs llmr in place of the relaunch
touch "$tmp/claude-up"
rm -f "$tmp/calls" "$tmp/llmr-calls"
: > "$tmp/security-calls"
oauth_before=$(jq -c .oauthAccount "$tmp/claude.json")
item_before=$(kc_get "Claude Code-credentials" "$USER")
printf '{"lastActivityAt":100}' > "$s/aaaaaaaa-1111/org-a/local_llmr1.json"
out=$(cda switch router 2>&1)
check "switch to an LLMR profile runs llmr <profile> app" "llmr router-p app" "$(cat "$tmp/llmr-calls")"
check "after it quits Desktop" "osascript|llmr" "$(grep -E '^(osascript|llmr) ' "$tmp/calls" | cut -d' ' -f1 | paste -sd '|' -)"
check "and does not relaunch the claude.ai login" "" "$(grep '^open' "$tmp/calls" || true)"
check "and writes the marker with the saved name" router "$(cat "$CLAUDE_MULTIPASS_DIR/active-llmr")"
check_true "and re-saves the login it leaves" grep -q "Saved the signed-in account as $acct" <<< "$out"
check "and refreshes the outgoing profile's CLI identity" b@example.com "$(jq -r .oauthAccount.emailAddress "$p/beta/cli.json")"
check "and leaves the terminal's oauthAccount alone" "$oauth_before" "$(jq -c .oauthAccount "$tmp/claude.json")"
check "and the terminal's CLI item" "$item_before" "$(kc_get "Claude Code-credentials" "$USER")"
check "and writes no CLI item" 0 "$(grep -c 'add-generic-password.*Claude Code-credentials' "$tmp/security-calls" || true)"
check_true "and backs up nothing, since nothing merges into config.json" test -z "$(grep 'Backed up the current login' <<< "$out")"
check "and leaves the Desktop folder's login as it was" "$(jq -c 'with_entries(select(.key | test("oauth|lastKnown")))' "$tmp/config-before-llmr")" "$(jq -c 'with_entries(select(.key | test("oauth|lastKnown")))' "$d/config.json")"
check_true "and prints the terminal hint" grep -q 'terminal: run llmr router-p' <<< "$out"
check_true "and syncs no Code tab lists" test ! -e "$s/bbbbbbbb-2222/org-b/local_llmr1.json"
rm -f "$s/aaaaaaaa-1111/org-a/local_llmr1.json"

# From one running LLMR profile to a second name on it: quit, then llmr, and the marker names the second
cda save router-b --llmr router-p > /dev/null
rm -f "$tmp/calls"
cda switch router-b > /dev/null 2>&1
check "an LLMR-to-LLMR switch quits, then runs llmr, with no relaunch" "osascript|llmr" "$(grep -E '^(osascript|llmr|open) ' "$tmp/calls" | cut -d' ' -f1 | paste -sd '|' -)"
check "the second name is the one current reports" router-b "$(cda current 2> /dev/null)"
check "list marks only that name" 1 "$(cda list | grep -c '^\* router-b ')"
check "list --json names it current" router-b "$(cda list --json | jq -r .current)"
cda rename router-b router-c > /dev/null
check "rename of the running LLMR profile moves the marker" router-c "$(cat "$CLAUDE_MULTIPASS_DIR/active-llmr")"
cda remove router-c > /dev/null
check_true "remove of the running LLMR profile removes the marker" test ! -e "$CLAUDE_MULTIPASS_DIR/active-llmr"
echo router > "$CLAUDE_MULTIPASS_DIR/active-llmr"

# While an LLMR-launched Desktop runs, read commands report the LLMR profile
: > "$tmp/curl-args"
check "current reports the running LLMR profile" router "$(cda current 2> /dev/null)"
check "with no warning while the gateway answers" "" "$(cda current 2>&1 > /dev/null)"
check_true "the probe asks the gateway's health route, skipping curlrc and proxies" grep -q '^curl -q .*--noproxy \* .*http://127.0.0.1:3456/health$' "$tmp/curl-args"
check "list marks it" 1 "$(cda list | grep -c '^\* router           llmr router-p  ')"
check "and marks no claude.ai account" 1 "$(cda list | grep -c '^\*')"
check "list --json names it current" router "$(cda list --json | jq -r .current)"
printf '#!/bin/sh\ncase "$*" in *3456/health*) exit 7 ;; esac\nexit 0\n' > "$tmp/bin/curl"
check "current warns when the gateway does not answer" "router: LLMR profile, gateway not running" "$(cda current 2>&1 > /dev/null)"
check "and still prints the profile" router "$(cda current 2> /dev/null)"
check "list says the gateway is not running" 1 "$(cda list | grep -c '^\* router .*  (gateway not running)$')"
write_curl

# The picker shows the LLMR row and switches through llmr
printf '#!/bin/sh\ntee "%s/fzf-in" | grep "^router "\n' "$tmp" > "$tmp/bin/fzf"
rm -f "$tmp/llmr-calls"
cda pick > /dev/null 2>&1
check "the picker lists the LLMR row" 1 "$(grep -c '^router           llmr router-p  .*  (signed in)$' "$tmp/fzf-in")"
check "and picking it runs llmr <profile> app" "llmr router-p app" "$(cat "$tmp/llmr-calls")"

# save of the claude.ai login while LLMR's Desktop runs quits that instance and relaunches the claude.ai login
rm -f "$tmp/calls" "$tmp/llmr-calls"
check "save while LLMR's Desktop runs succeeds" 0 "$(exit_code cda save "$acct")"
check "and quits, then relaunches the claude.ai login" "osascript|open" "$(grep -E '^(osascript|llmr|open) ' "$tmp/calls" | cut -d' ' -f1 | paste -sd '|' -)"
check_true "and removes the marker" test ! -e "$CLAUDE_MULTIPASS_DIR/active-llmr"
check "and runs no llmr" "" "$(cat "$tmp/llmr-calls" 2> /dev/null)"

# A marker with no LLMR Desktop is stale: reads report the claude.ai login and keep it, a writing run removes it
echo router > "$CLAUDE_MULTIPASS_DIR/active-llmr"
rm -f "$tmp/claude-up" "$tmp/llmr-up"
check "a stale marker: current reports the claude.ai login" "$acct" "$(cda current)"
check "list --json too" "$acct" "$(cda list --json | jq -r .current)"
check_true "and the read commands leave the marker" test -f "$CLAUDE_MULTIPASS_DIR/active-llmr"
cda sync > /dev/null
check_true "a writing run removes the stale marker" test ! -e "$CLAUDE_MULTIPASS_DIR/active-llmr"

# Switch away to the account the Desktop folder still holds: quit and relaunch anyway
echo router > "$CLAUDE_MULTIPASS_DIR/active-llmr"
touch "$tmp/claude-up" "$tmp/llmr-up"
rm -f "$tmp/calls"
check "current reports LLMR before the switch away" router "$(cda current 2> /dev/null)"
check "switch away to the same account succeeds" 0 "$(exit_code cda switch "$acct")"
check "and quits LLMR's Desktop" 1 "$(grep -c '^osascript' "$tmp/calls")"
check "and relaunches the claude.ai login" 1 "$(grep -c '^open -a Claude$' "$tmp/calls")"
check_true "and removes the marker" test ! -e "$CLAUDE_MULTIPASS_DIR/active-llmr"

# A failed llmr launch relaunches the untouched claude.ai login and exits 1
rm -f "$tmp/calls" "$tmp/llmr-calls"
echo 2 > "$tmp/llmr-fail"
err=$(cda switch router 2>&1 > /dev/null) && rc=0 || rc=$?
check "a failed llmr launch exits 1" 1 "$rc"
check_true "and shows the error" grep -q 'llmr router-p app exited 2; relaunching the claude.ai login' <<< "$err"
check_true "and llmr's own message" grep -q 'llmr: no such profile' <<< "$err"
check "and relaunches the claude.ai login" 1 "$(grep -c '^open -a Claude$' "$tmp/calls")"
check_true "and writes no marker" test ! -e "$CLAUDE_MULTIPASS_DIR/active-llmr"
check "and leaves the Desktop folder's login as it was" "$(jq -c 'with_entries(select(.key | test("oauth|lastKnown")))' "$tmp/config-before-llmr")" "$(jq -c 'with_entries(select(.key | test("oauth|lastKnown")))' "$d/config.json")"
rm -f "$tmp/llmr-fail" "$tmp/calls"

# llmr exits 0 but no LLMR Desktop appears: the launch is not confirmed
touch "$tmp/llmr-no-desktop"
printf '#!/bin/sh\n[ "$1" = 0.5 ] && exit 0\nexec /bin/sleep "$@"\n' > "$tmp/bin/sleep"
chmod +x "$tmp/bin/sleep"
err=$(cda switch router 2>&1 > /dev/null) && rc=0 || rc=$?
check "an unconfirmed llmr launch exits 1" 1 "$rc"
check_true "and says so" grep -q 'Claude did not start through llmr router-p within 10 s; relaunching the claude.ai login' <<< "$err"
check "and relaunches the claude.ai login" 1 "$(grep -c '^open -a Claude$' "$tmp/calls")"
check_true "and writes no marker" test ! -e "$CLAUDE_MULTIPASS_DIR/active-llmr"
rm -f "$tmp/bin/sleep" "$tmp/llmr-no-desktop" "$tmp/calls" "$tmp/claude-up" "$tmp/llmr-up"
check "a missing llmr exits 1" 1 "$(CLAUDE_MULTIPASS_LLMR="$tmp/no-llmr" exit_code cda switch router)"
check "before it quits or launches Desktop" "" "$(cat "$tmp/calls" 2> /dev/null)"
check "--no-relaunch does not apply to an LLMR switch" 1 "$(exit_code cda switch router --no-relaunch)"
check "and quits nothing" "" "$(cat "$tmp/calls" 2> /dev/null)"
check_true "doctor warns when llmr is missing" grep -q '^warn: router: llmr not found' <<< "$(CLAUDE_MULTIPASS_LLMR="$tmp/no-llmr" cda doctor)"
check "and does not fail for it" 0 "$(CLAUDE_MULTIPASS_LLMR="$tmp/no-llmr" exit_code cda doctor)"
rm -f "$tmp/llmr-calls" "$tmp/claude-up" "$tmp/llmr-up"
env -u CLAUDE_MULTIPASS_LLMR PATH="$tmp/llmr-bin:$PATH" "$script" switch router > /dev/null 2>&1
check "without CLAUDE_MULTIPASS_LLMR, llmr is found on PATH" "llmr router-p app" "$(cat "$tmp/llmr-calls")"
# PATH holds no llmr (only the stubs, jq and the system dirs), so the real one is
# never reached. jq runs with the real HOME and PATH, which a version-manager
# shim needs.
mkdir -p "$tmp/home/.llm-router/bin" "$tmp/jq-only"
cp "$tmp/llmr-bin/llmr" "$tmp/home/.llm-router/bin/llmr"
printf '#!/bin/sh\nHOME="%s" PATH="%s" exec "%s" "$@"\n' "$HOME" "$PATH" "$(command -v jq)" > "$tmp/jq-only/jq"
chmod +x "$tmp/jq-only/jq"
rm -f "$tmp/llmr-calls" "$tmp/claude-up" "$tmp/llmr-up"
env -u CLAUDE_MULTIPASS_LLMR HOME="$tmp/home" PATH="$tmp/bin:$tmp/jq-only:/usr/bin:/bin" "$script" switch router > /dev/null 2>&1
check "with no llmr on PATH, ~/.llm-router/bin/llmr runs" "llmr router-p app" "$(cat "$tmp/llmr-calls")"
rm -rf "$tmp/home/.llm-router"
printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/pgrep"
printf '#!/bin/sh\necho "osascript $*" >> "%s/calls"\n' "$tmp" > "$tmp/bin/osascript"
rm -f "$CLAUDE_MULTIPASS_DIR/active-llmr" "$tmp/claude-up" "$tmp/llmr-up"
: > "$tmp/security-calls"
cda rename router router2 > /dev/null
check "rename moves an LLMR profile" router-p "$(jq -r .llmrProfile "$p/router2/meta.json")"
check "without a Keychain call" 0 "$(wc -l < "$tmp/security-calls" | tr -d ' ')"
rm -rf "$p/router2" "$tmp/calls"

# Hindsight's memory daemon. The daemon and its claude are real background
# sleeps, so the script's kill builtin really stops and resumes them; the pgrep
# stub names them as hindsight-api and its claude child. Desktop counts as quit.
hs_file=$tmp/hindsight
cat > "$tmp/bin/pgrep" << EOF
#!/bin/sh
hs=$hs_file
EOF
cat >> "$tmp/bin/pgrep" << 'EOF'
stopped() { ps -o state= -p "$(cat "$hs-pid")" | grep -q '^T'; }
# Started here, not by the case, so a slow start of the script cannot outlive it.
spawn_claude() {
  rm "$1"
  /bin/sleep 1 > /dev/null 2>&1 &
  echo $! > "$hs-child"
  [ ! -e "$hs-desktop-reopens" ] || touch "$hs-desktop-up"
}
case "$*" in
  "-f ^([^ ]*/python[^ ]* )?[^ ]*/bin/hindsight-api( |\$)")
    [ ! -e "$hs-silent" ] || exit 0
    [ -f "$hs-pid" ] || exit 1
    cat "$hs-pid"
    ;;
  "-P "*" -x claude")
    [ "$2" = "$(cat "$hs-pid")" ] || exit 1
    if [ -e "$hs-spawn-at-first-look" ]; then spawn_claude "$hs-spawn-at-first-look"; fi
    if [ -e "$hs-spawn-at-stop" ] && stopped; then spawn_claude "$hs-spawn-at-stop"; fi
    [ -f "$hs-child" ] && kill -0 "$(cat "$hs-child")" 2> /dev/null || exit 1
    stopped || echo running-with-child >> "$hs-wait"
    cat "$hs-child"
    ;;
  "-x claude")
    [ ! -e "$hs-die-at-warning" ] || kill -9 "$(cat "$hs-pid")"
    exit 1
    ;;
  "-axq Claude") test -e "$hs-desktop-up" ;;
  "-aqf -- --user-data-dir=.*/claude-app-user-data/") test -e "$hs-llmr-up" ;;
  *) exit 1 ;;
esac
EOF
printf '#!/bin/sh\nPATH="%s/bin:$PATH"\necho "open $*" >> "%s/calls"\n[ ! -f "%s-pid" ] || ps -o state= -p "$(cat "%s-pid")" >> "%s-at-open"\n' "$tmp" "$tmp" "$hs_file" "$hs_file" "$hs_file" > "$tmp/bin/open"
printf '#!/bin/sh\nps -o state= -p "$(cat "%s-pid")" > "%s-at-llmr"\ntouch "%s-llmr-up"\n' "$hs_file" "$hs_file" "$hs_file" > "$tmp/hs-llmr"
chmod +x "$tmp/hs-llmr"
# Quitting a Desktop that came back clears it, and records what had been written by then.
printf '#!/bin/sh\necho "osascript $*" >> "%s/calls"\nrm -f "%s-desktop-up"\njq -r .lastKnownAccountUuid "%s/config.json" > "%s-config-at-quit"\nwc -l < "%s-states" > "%s-keychain-at-quit"\n' "$tmp" "$hs_file" "$d" "$hs_file" "$hs_file" "$hs_file" > "$tmp/bin/osascript"
hs_background() {
  "$@" > /dev/null 2>&1 &
  hs_last=$!
  # Out of the job table, or bash prints "Killed: 9" when hs_end lands.
  disown "$hs_last"
  hs_pids="$hs_pids $hs_last"
}
hs_stopped() { ps -o state= -p "$1" 2> /dev/null | grep -q '^T' && echo yes || echo no; }
hs_end() {
  [[ -z $hs_pids ]] || kill -9 $hs_pids 2> /dev/null || true
  hs_pids=''
  rm -f "$hs_file"-*
}
# A fresh daemon, nothing logged yet, with an optional long-lived claude: its seconds.
hs_start() {
  hs_end
  hs_background /bin/sleep 300
  fake_daemon=$hs_last
  echo "$fake_daemon" > "$hs_file-pid"
  : > "$hs_file-states"
  : > "$hs_file-wait"
  : > "$hs_file-at-open"
  if [[ -n ${1:-} ]]; then
    hs_background /bin/sleep "$1"
    fake_child=$hs_last
    echo "$fake_child" > "$hs_file-child"
  fi
}
# A SIGSTOP that lands while the fixture is still in its exec is lost (measured), so it repeats.
hs_stop_daemon() {
  local i
  for ((i = 0; i < 50; i++)); do
    kill -STOP "$fake_daemon"
    [[ $(hs_stopped "$fake_daemon") == no ]] || return 0
    /bin/sleep 0.05
  done
  check "the fixture daemon stops" yes no
}
hs_run() {
  hs_rc=0
  hs_out=$(cda "$@" 2> "$hs_file-err") || hs_rc=$?
  hs_err=$(cat "$hs_file-err")
}

# The pattern from the script against the real pgrep. It may print a real daemon
# too, so only these fixtures' pids are looked at, and only they are signalled.
hs_pattern=$(sed -n "s/^hindsight_daemon_pids() { pgrep -f '\(.*\)' 2> .*/\1/p" "$script")
mkdir -p "$tmp/x/bin"
printf 'while :; do /bin/sleep 1; done\n' > "$tmp/x/bin/hindsight-api"
hs_background /bin/bash -c 'exec -a /x/bin/hindsight-api /bin/sleep 30'
hs_bare=$hs_last
hs_background /bin/bash -c 'exec -a /x/bin/python3.12 /bin/bash "$0" --port 9077' "$tmp/x/bin/hindsight-api"
hs_python=$hs_last
hs_background /bin/bash -c '/bin/sleep 10; true # /x/bin/hindsight-api '
hs_comment=$hs_last
hs_background /bin/sh -c '/bin/sleep 10; true' 'uv tool uvx hindsight-api@1.1.0 --port 9077'
hs_wrapper=$hs_last
for ((i = 0; i < 50; i++)); do
  [[ $(ps -o command= -p "$hs_bare") != /x/bin/hindsight-api* || $(ps -o command= -p "$hs_python") != /x/bin/python3.12* ]] || break
  /bin/sleep 0.1
done
hs_real=$(/usr/bin/pgrep -f "$hs_pattern" || true)
hs_in_real() { grep -qx "$1" <<< "$hs_real" && echo yes || echo no; }
check "the daemon pattern matches a bare hindsight-api" yes "$(hs_in_real "$hs_bare")"
check "and one run by python" yes "$(hs_in_real "$hs_python")"
check "and not a shell whose text holds that path" no "$(hs_in_real "$hs_comment")"
check "nor the uvx wrapper" no "$(hs_in_real "$hs_wrapper")"
hs_end

# A second account to switch to, so these cases do not lean on the ones above.
mkdir -p "$p/hsother"
printf '{"oauth:tokenCache":"enc-C1","oauth:tokenCacheV2":"enc-C2","lastKnownAccountUuid":"hhhhhhhh-8888"}' > "$p/hsother/config.json"
printf '{"account":"hhhhhhhh-8888","savedAt":"2026-01-01T00:00:00Z"}' > "$p/hsother/meta.json"
printf cookie-C > "$p/hsother/Cookies"
printf '{"oauthAccount":{"accountUuid":"hhhhhhhh-8888","emailAddress":"h@example.com","organizationUuid":"org-other"}}' > "$p/hsother/cli.json"
kc_put claude-multipass hsother '{"claudeAiOauth":{"accessToken":"at-other","refreshToken":"rt-other","expiresAt":2}}'
cda switch beta --force --no-relaunch > /dev/null 2>&1

hs_start
touch "$hs_file-spawn-at-first-look" "$hs_file-desktop-reopens"
hs_run switch hsother
check "a switch with Hindsight running succeeds" 0 "$hs_rc"
check "and moves the CLI login" hhhhhhhh-8888 "$(jq -r .oauthAccount.accountUuid "$tmp/claude.json")"
check_true "switch stops Hindsight while it reads the CLI login" grep -q '^T' "$hs_file-states"
check "at every Keychain access" 0 "$(grep -cv '^T' "$hs_file-states" || true)"
check "and resumes it before relaunching Desktop" no "$(grep -q '^T' "$hs_file-at-open" && echo yes || echo no)"
check_true "the relaunch did happen" test -s "$hs_file-at-open"
check "and leaves it running" no "$(hs_stopped "$fake_daemon")"
check_true "and says so" grep -q "Paused Hindsight's memory daemon" <<< "$hs_out"
check "and waits for its in-flight claude" gone "$(kill -0 "$(cat "$hs_file-child")" 2> /dev/null && echo alive || echo gone)"
check "no Hindsight claude is alive when the CLI login is read" yes "$(! grep -q 'children=[1-9]' "$hs_file-states" && echo yes)"
check_true "and the daemon runs while that child finishes" grep -q 'running-with-child' "$hs_file-wait"
check "so no warning names it" "" "$(grep 'still running after 60 s' <<< "$hs_err" || true)"
check_true "and it says what it waits for" grep -q "Waiting up to 60 s for Hindsight's claude (pid $(cat "$hs_file-child")) to finish" <<< "$hs_out"
check "and a running daemon is not reported as resumed" "" "$(grep "Resumed Hindsight" <<< "$hs_out" || true)"
check_true "a Desktop reopened during that wait is quit again" grep -q 'osascript -e tell application "Claude" to quit' "$tmp/calls"
check "before the Desktop login moves" "$(jq -r .account "$p/beta/meta.json")" "$(cat "$hs_file-config-at-quit")"
check "and before any Keychain access" 0 "$(tr -d ' ' < "$hs_file-keychain-at-quit")"

# A claude spawned in the gap between the check and the stop
hs_start
touch "$hs_file-spawn-at-stop"
hs_run switch beta --no-relaunch
check_true "a claude spawned as the daemon stops resumes the daemon to finish it" grep -q 'running-with-child' "$hs_file-wait"
check "and the login is read only after it ended" 0 "$(grep -c 'children=[1-9]' "$hs_file-states" || true)"
check_true "with the daemon stopped again" grep -q '^T' "$hs_file-states"
check "and it ends running" no "$(hs_stopped "$fake_daemon")"

# save and add pause it too
hs_start
hs_run save beta --no-relaunch
check_true "save stops Hindsight while it reads the CLI login" grep -q '^T' "$hs_file-states"
check "and leaves it running" no "$(hs_stopped "$fake_daemon")"
hs_start
rm -f "$CLAUDE_MULTIPASS_DIR/debug.log"
hs_run save beta --no-relaunch --debug
check_true "debug logs the Hindsight pause" grep -q "hindsight stopped pid $fake_daemon; waited 0 s for children: none" "$CLAUDE_MULTIPASS_DIR/debug.log"
check_true "and the resume" grep -q "hindsight resumed pid $fake_daemon" "$CLAUDE_MULTIPASS_DIR/debug.log"
# A switch under debug. The sleep stub records the daemon's state at each 2 s poll.
printf '#!/bin/sh\n[ "$1" != 2 ] || { ps -o state= -p "$(cat "%s-pid")" >> "%s-at-poll"; exit 0; }\nexec /bin/sleep "$@"\n' "$hs_file" "$hs_file" > "$tmp/bin/sleep"
chmod +x "$tmp/bin/sleep"
hs_start
touch "$hs_file-spawn-at-first-look"
hs_run switch beta --no-relaunch --debug
rm "$tmp/bin/sleep"
check_true "debug logs the wait" grep -q "waiting up to 60 s for Hindsight's claude (pid $(cat "$hs_file-child"))" "$CLAUDE_MULTIPASS_DIR/debug.log"
check "the watch polls 15 times with Hindsight" 15 "$(wc -l < "$hs_file-at-poll" | tr -d ' ')"
check "and the daemon runs from the first poll" 0 "$(grep -c '^T' "$hs_file-at-poll" || true)"
check "its hash was armed while the daemon was stopped: only the polls read a running one" 15 "$(grep -cv '^T' "$hs_file-states" || true)"
rm -f "$CLAUDE_MULTIPASS_DIR/debug.log"
cp "$d/config.json" "$tmp/config-before-hs-add"
hs_start
hs_run add hsnew --no-relaunch
check_true "add stops Hindsight while it re-saves the CLI login" grep -q '^T' "$hs_file-states"
check "and leaves it running" no "$(hs_stopped "$fake_daemon")"
cp "$tmp/config-before-hs-add" "$d/config.json"
printf cookie-B > "$d/Cookies"

# A failure after the pause: a held CLI lock fails the switch. The sleep stub
# skips its 5 s of retries.
printf '#!/bin/sh\ncase "$1" in 0.5 | 1) exit 0 ;; esac\nexec /bin/sleep "$@"\n' > "$tmp/bin/sleep"
chmod +x "$tmp/bin/sleep"
hs_start
mkdir "$tmp/claude-home/.oauth_refresh.lock"
hs_run switch hsother --no-relaunch
check "a switch that fails after the pause exits 1" 1 "$hs_rc"
check_true "after pausing" grep -q "Paused Hindsight's memory daemon" <<< "$hs_out"
check "a failed switch still resumes Hindsight" no "$(hs_stopped "$fake_daemon")"
# The same failure with the daemon gone by the time the trap resumes it
hs_start
touch "$hs_file-die-at-warning"
hs_run switch hsother --no-relaunch
check "a daemon gone before the trap keeps the exit code" 1 "$hs_rc"
rmdir "$tmp/claude-home/.oauth_refresh.lock"
rm "$tmp/bin/sleep"

# No Hindsight, or nothing named by pgrep
hs_end
hs_run switch beta --no-relaunch
check "switch without Hindsight succeeds" 0 "$hs_rc"
check "and pauses nothing" "" "$(grep "Paused Hindsight" <<< "$hs_out" || true)"
touch "$hs_file-silent"
hs_run switch beta --no-relaunch
check "a pgrep that exits 0 and prints nothing finds no daemon" "" "$(grep "Paused Hindsight" <<< "$hs_out" || true)"
rm "$hs_file-silent"

# No CLI login can move, so nothing stops, but a daemon a killed run left stopped runs again.
hs_start
mv "$tmp/claude.json" "$tmp/claude.json.hs"
hs_run switch beta --no-relaunch
mv "$tmp/claude.json.hs" "$tmp/claude.json"
check "a switch with no claude.json pauses nothing" "" "$(grep "Paused Hindsight" <<< "$hs_out" || true)"
hs_stop_daemon
CLAUDE_CONFIG_DIR=$tmp/hs-config hs_run switch beta --no-relaunch
check "nor does one under CLAUDE_CONFIG_DIR" "" "$(grep "Paused Hindsight" <<< "$hs_out" || true)"
check "which still resumes a daemon a killed run left stopped" no "$(hs_stopped "$fake_daemon")"
check_true "and says so" grep -q "Resumed Hindsight's memory daemon, left stopped by a killed run" <<< "$hs_out"
CLAUDE_SECURESTORAGE_CONFIG_DIR=$tmp/hs-config hs_run switch beta --no-relaunch
check "nor does one under CLAUDE_SECURESTORAGE_CONFIG_DIR" "" "$(grep "Paused Hindsight" <<< "$hs_out" || true)"
mv "$tmp/claude.json" "$tmp/claude.json.hs"
printf '{' > "$tmp/claude.json"
hs_run switch beta --no-relaunch
mv "$tmp/claude.json.hs" "$tmp/claude.json"
check "nor does one with an invalid claude.json" "" "$(grep "Paused Hindsight" <<< "$hs_out" || true)"

# The daemon gone at the first Keychain read, or before the stop
hs_start
touch "$hs_file-die"
hs_run switch beta --no-relaunch
check "a daemon gone before resume does not fail the switch" 0 "$hs_rc"
hs_start
sh -c 'exit 0' &
dead=$!
wait "$dead"
echo "$dead" > "$hs_file-pid"
hs_run switch beta --no-relaunch
check "a daemon gone before the stop does not fail the switch" 0 "$hs_rc"
check "and is not reported as paused" "" "$(grep "Paused Hindsight" <<< "$hs_out" || true)"

# An LLMR launch waits up to 10 s, so the daemon is resumed before it
hs_start
cda save hsrouter --llmr router-p > /dev/null
CLAUDE_MULTIPASS_LLMR=$tmp/hs-llmr hs_run switch hsrouter
check "an LLMR switch succeeds with Hindsight running" 0 "$hs_rc"
check_true "and stops Hindsight while it re-saves the CLI login" grep -q '^T' "$hs_file-states"
check_true "llmr ran" test -s "$hs_file-at-llmr"
check "and resumes it before llmr launches" no "$(grep -q '^T' "$hs_file-at-llmr" && echo yes || echo no)"
rm -rf "$p/hsrouter" "$CLAUDE_MULTIPASS_DIR/active-llmr"

# A claude that outlives the 60 s cap. The sleep stub skips the 0.5 s rounds.
printf '#!/bin/sh\n[ "$1" = 0.5 ] && exit 0\nexec /bin/sleep "$@"\n' > "$tmp/bin/sleep"
chmod +x "$tmp/bin/sleep"
hs_start 300
hs_run switch beta --no-relaunch
rm "$tmp/bin/sleep"
check "a claude still running after the cap does not stop the switch" 0 "$hs_rc"
check_true "a child still running after 60 s is named and the switch goes on" grep -q "Hindsight's claude (pid $fake_child) was still running after 60 s; it may write back the login it loaded" <<< "$hs_err"
check_true "and the daemon is stopped anyway for the swap" grep -q '^T.*children=1' "$hs_file-states"
check "and ends running" no "$(hs_stopped "$fake_daemon")"

# A daemon left stopped by a run the watchdog killed. The child stands in for a
# claude blocked on a pipe the stopped daemon does not read: it ends only once the daemon runs.
hs_start
hs_stop_daemon
hs_background /bin/sh -c 'i=0; while [ $i -lt 300 ] && ps -o state= -p "$0" | grep -q "^T"; do /bin/sleep 0.1; i=$((i + 1)); done; /bin/sleep 1' "$fake_daemon"
fake_child=$hs_last
echo "$fake_child" > "$hs_file-child"
hs_run switch beta --no-relaunch
check "a daemon an earlier run left stopped does not hang the wait for its claude" "" "$(grep 'still running after 60 s' <<< "$hs_err" || true)"
check_true "it runs again while that claude finishes" grep -q 'running-with-child' "$hs_file-wait"
check_true "and says it resumed it" grep -q "Resumed Hindsight's memory daemon, left stopped by a killed run" <<< "$hs_out"
check "and ends running" no "$(hs_stopped "$fake_daemon")"

# A real SIGTERM, then a real SIGKILL, in the middle of a swap (the app's
# watchdog sends both). The script itself, not cda: see the toucher case.
hs_killed_run() {
  touch "$tmp/wait"
  rm -f "$tmp/wait.held"
  SECURITY_WAIT=$tmp/wait "$script" switch beta --no-relaunch > /dev/null 2>&1 &
  hs_run_pid=$!
  for ((i = 0; i < 100; i++)); do
    [[ ! -e $tmp/wait.held ]] || break
    /bin/sleep 0.1
  done
  check_true "the run $1 waits on the Keychain" test -e "$tmp/wait.held"
  check "with the daemon stopped" yes "$(hs_stopped "$fake_daemon")"
  kill "-$1" "$hs_run_pid"
  # bash runs its trap only once the stub in front of it returns.
  rm "$tmp/wait"
  wait "$hs_run_pid" 2> /dev/null || true
}
hs_start
hs_killed_run TERM
check "a SIGTERM still resumes Hindsight" no "$(hs_stopped "$fake_daemon")"
hs_start
hs_killed_run KILL
check "a SIGKILL leaves it stopped" yes "$(hs_stopped "$fake_daemon")"
check_true "the limit --help names" grep -q 'the daemon stays stopped until the next save, switch or add that gets past its refusals' <<< "$(cda --help | tr -s ' \n' ' ')"
rm -rf "$tmp/claude.json.lock" "$tmp/claude-home/.oauth_refresh.lock" "$tmp/claude-home.lock"
# Read commands signal nothing, so it stays stopped through them.
cda list > /dev/null
cda list --json > /dev/null
cda show beta > /dev/null
cda current > /dev/null
hs_doctor=$(cda doctor 2>&1 || true)
check "list, show, current and doctor do not resume it" yes "$(hs_stopped "$fake_daemon")"
check_true "doctor warns about it and names the line that resumes it" grep -q "^warn: hindsight: .*kill -CONT $fake_daemon" <<< "$hs_doctor"
hs_run switch beta --no-relaunch
check "the next switch heals it" no "$(hs_stopped "$fake_daemon")"
check "and doctor no longer warns" "" "$(cda doctor 2>&1 | grep '^warn: hindsight' || true)"
hs_end
rm -rf "$p/hsother"
printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/pgrep"
printf '#!/bin/sh\necho "osascript $*" >> "%s/calls"\n' "$tmp" > "$tmp/bin/osascript"
printf '#!/bin/sh\nPATH="%s/bin:$PATH"\necho "open $*" >> "%s/calls"\n' "$tmp" "$tmp" > "$tmp/bin/open"
rm -f "$tmp/calls"

check "a caller with no USER can still switch" 0 "$(exit_code env -u USER "$script" switch beta)"
check_true "and Desktop still relaunches" grep -q 'open -a Claude' "$tmp/calls"
rm -f "$tmp/calls"

# Debug mode. pgrep names a real background process as a running claude, with a
# token past the 160 characters of its command the log keeps. The open stub runs
# $tmp/dbg-at-open, a late writer of the CLI item. The sleep stub counts the
# watch's 2 s polls and skips them, running $tmp/dbg-at-poll-<n> at poll n.
dbg_log=$CLAUDE_MULTIPASS_DIR/debug.log
mkdir -p "$p/dbother"
printf '{"oauth:tokenCache":"enc-D1","oauth:tokenCacheV2":"enc-D2","lastKnownAccountUuid":"dddddddd-7777"}' > "$p/dbother/config.json"
printf '{"account":"dddddddd-7777","savedAt":"2026-01-01T00:00:00Z"}' > "$p/dbother/meta.json"
printf cookie-D > "$p/dbother/Cookies"
printf '{"oauthAccount":{"accountUuid":"dddddddd-7777","emailAddress":"d@example.com","organizationUuid":"org-other"}}' > "$p/dbother/cli.json"
kc_put claude-multipass dbother '{"claudeAiOauth":{"accessToken":"at-dbother","refreshToken":"rt-dbother","expiresAt":2}}'
cda switch beta --force --no-relaunch > /dev/null 2>&1
cat > "$tmp/bin/pgrep" << EOF
#!/bin/sh
case "\$*" in
  "-ax claude") [ -f "$tmp/dbg-claude" ] && cat "$tmp/dbg-claude" || exit 1 ;;
  "-aqf -- --user-data-dir=.*/claude-app-user-data/") test -e "$tmp/llmr-up" ;;
  *) exit 1 ;;
esac
EOF
printf '#!/bin/sh\nPATH="%s/bin:$PATH"\necho "open $*" >> "%s/calls"\n/usr/bin/env > "%s/open-env"\n[ ! -f "%s/dbg-at-open" ] || . "%s/dbg-at-open"\n' "$tmp" "$tmp" "$tmp" "$tmp" "$tmp" > "$tmp/bin/open"
printf '#!/bin/sh\ncase "$1" in 2) [ ! -e "%s/dbg-sleep-fail" ] || exit 1; echo poll >> "%s/dbg-polls"; at="%s/dbg-at-poll-$(wc -l < "%s/dbg-polls" | tr -d " ")"; [ ! -f "$at" ] || . "$at"; exit 0 ;; 0.5 | 1) exit 0 ;; esac\nexec /bin/sleep "$@"\n' "$tmp" "$tmp" "$tmp" "$tmp" > "$tmp/bin/sleep"
chmod +x "$tmp/bin/sleep"
hs_background /bin/sh -c 'while :; do /bin/sleep 1; done' "$(printf 'a%.0s' {1..200})rt-argv-leak"
fake_claude=$hs_last
echo "$fake_claude" > "$tmp/dbg-claude"
# Every run's log and stderr pile up for the no-token check at the end.
dbg_run() {
  rm -f "$dbg_log"
  : > "$tmp/dbg-polls"
  hs_run "$@"
  [[ ! -f $dbg_log ]] || cat "$dbg_log" >> "$tmp/dbg-all"
  printf '%s\n' "$hs_err" >> "$tmp/dbg-all"
  rm -f "$tmp"/dbg-at-poll-*
}
dbg_at_open() { printf '%s\n' "$1" > "$tmp/dbg-at-open"; }
dbg_at_poll() { printf '%s\n' "$2" > "$tmp/dbg-at-poll-$1"; }
dbg_item_cmd() { echo "security add-generic-password -U -a \"\$USER\" -s 'Claude Code-credentials' -X $(printf %s "$1" | xxd -p | tr -d '\n')"; }
dbg_put_item() { dbg_at_open "$(dbg_item_cmd "$1")"; }
dbg_warned() { grep -c '^debug: the CLI login' <<< "$hs_err" || true; }
dbg_polls() { wc -l < "$tmp/dbg-polls" | tr -d ' '; }
dbg_logged() { grep -q -- "$1" "$dbg_log" && echo yes || echo no; }

# Read commands log nothing and read no Keychain item, with the app's variable or the flag.
rm -f "$dbg_log"
: > "$tmp/security-calls"
for c in list 'list --json' 'show beta' current doctor; do
  CLAUDE_MULTIPASS_DEBUG=1 cda $c > /dev/null 2>&1 || true
  cda $c --debug > /dev/null 2>&1 || true
done
check "--debug is accepted by list" 0 "$(exit_code cda list --debug)"
check "--debug is accepted by doctor" 0 "$(exit_code cda doctor --debug)"
check "list, show, current and doctor under debug write no debug.log" absent "$([[ -e $dbg_log ]] && echo present || echo absent)"
check "and read no Keychain item" 0 "$(wc -l < "$tmp/security-calls" | tr -d ' ')"
cda sync --force --debug > /dev/null 2>&1
check "sync under debug writes no debug.log" absent "$([[ -e $dbg_log ]] && echo present || echo absent)"
cda save dbllmr --llmr router-p --debug > /dev/null
check "an LLMR save under debug writes no debug.log" absent "$([[ -e $dbg_log ]] && echo present || echo absent)"

dbg_run switch dbother
check "without debug no debug.log is written" absent "$([[ -e $dbg_log ]] && echo present || echo absent)"
check "and no watch runs" 0 "$(dbg_polls)"
cda switch beta --no-relaunch > /dev/null 2>&1
CLAUDE_MULTIPASS_DEBUG='' dbg_run switch dbother --no-relaunch
check "an empty CLAUDE_MULTIPASS_DEBUG stays off" absent "$([[ -e $dbg_log ]] && echo present || echo absent)"
cda switch beta --no-relaunch > /dev/null 2>&1

# A write to a closed pipe raises SIGPIPE, and the relaunch still happens. Under
# bash 3.2 the failed line stays in the builtin's buffer, and a $(...) in the trap
# would capture it, so the lock check tells whether the trap cleared that.
rm -f "$tmp/calls"
# shellcheck disable=SC2216
{ cda switch dbother --debug > /dev/null; } 2>&1 | : || true
check_true "a closed stderr still relaunches Desktop" grep -q 'open -a Claude' "$tmp/calls"
check "and frees the run lock" absent "$([[ -L $CLAUDE_MULTIPASS_DIR/.run.lock ]] && echo present || echo absent)"
# shellcheck disable=SC2216
{ cda switch dbother --debug --no-relaunch > /dev/null; } 2>&1 | : || true
check "and so does a --no-relaunch run, with no later write to flush that line" absent "$([[ -L $CLAUDE_MULTIPASS_DIR/.run.lock ]] && echo present || echo absent)"
rm -f "$tmp/calls"
# shellcheck disable=SC2216
{ cda switch dbother 2> /dev/null; } | : || true
check_true "a closed stdout still relaunches Desktop" grep -q 'open -a Claude' "$tmp/calls"
check "and frees the run lock" absent "$([[ -L $CLAUDE_MULTIPASS_DIR/.run.lock ]] && echo present || echo absent)"
rm -f "$tmp/calls"
cda switch beta --no-relaunch > /dev/null 2>&1

# A stable login
dbg_run switch dbother --debug
check "a switch under debug succeeds" 0 "$hs_rc"
check "debug.log is created 0600" 600 "$(stat -f %Lp "$dbg_log")"
check "debug logs the run" yes "$(dbg_logged "switch dbother: claude-multipass $pkg_version, Claude ")"
check "debug logs the quit with Desktop not running" yes "$(dbg_logged 'quit done')"
check "debug logs the swap" yes "$(dbg_logged 'cli restore wrote dddddddd-7777')"
check "debug logs the relaunch" yes "$(dbg_logged 'launching Claude')"
check "debug lists running claude processes at the swap" yes "$(dbg_logged "claude pid=$fake_claude ppid=[0-9]* /bin/sh -c while")"
check "from pgrep -a, while the warning keeps plain pgrep, which hides this run's ancestors" "" "$(grep 'Claude Code is running' <<< "$hs_err" || true)"
check "debug watch reports a stable login" yes "$(dbg_logged 'CLI login unchanged for 30 s')"
check "after 15 polls of 2 s" 15 "$(dbg_polls)"
check "a process line is cut at 160 characters of its command" 160 "$(grep 'claude pid=' "$dbg_log" | sed -E 's/.* ppid=[0-9]+ //' | head -1 | tr -d '\n' | wc -c | tr -d ' ')"
check "each log line is a UTC time, the pid and the message" 0 "$(grep -Ecv '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z [0-9]+ ' "$dbg_log" || true)"
check_true "stderr carries the same lines with a local time" grep -Eq '^debug: [0-9:]{8} quit done$' <<< "$hs_err"

dbg_run switch dbother --debug --no-relaunch
check "debug logs the re-save on the already-on-target path" yes "$(dbg_logged 'cli restore already on dddddddd-7777')"
check "debug watches a re-save switch too, under --no-relaunch" yes "$(dbg_logged 'CLI login unchanged for 30 s')"

# A trim keeps the last lines and the mode, and a log that cannot be written fails nothing.
seq 3000 > "$dbg_log"
chmod 644 "$dbg_log"
cda save dbother --debug > /dev/null 2>&1
check "debug.log is trimmed to its last 2000 lines" yes "$( (($(wc -l < "$dbg_log") <= 2100)) && ! grep -qx 1 "$dbg_log" && grep -qx 1001 "$dbg_log" && echo yes)"
check "the trim leaves it 0600" 600 "$(stat -f %Lp "$dbg_log")"
check "and no temp file" absent "$([[ -e $dbg_log.tmp ]] && echo present || echo absent)"
chmod 000 "$dbg_log"
check "a debug.log that cannot be written fails nothing" 0 "$(exit_code cda save dbother --debug)"
rm -f "$dbg_log"

# A late writer of the CLI item. Without the cache reset the watch sees none of them.
cda switch beta --no-relaunch > /dev/null 2>&1
dbg_put_item '{"claudeAiOauth":{"accessToken":"at-rotated","refreshToken":"rt-rotated","expiresAt":3}}'
dbg_at_poll 3 "$(dbg_item_cmd '{"claudeAiOauth":{"accessToken":"at-rotated","refreshToken":"rt-rotated-later","expiresAt":3}}')"
dbg_at_poll 5 "jq '.oauthAccount.accountUuid = \"bbbbbbbb-flip\"' '$tmp/claude.json' > '$tmp/claude.json.new' && mv '$tmp/claude.json.new' '$tmp/claude.json'"
beta_account=$(jq -r .account "$p/beta/meta.json")
dbg_at_poll 7 "jq '.oauthAccount.accountUuid = \"$beta_account\"' '$tmp/claude.json' > '$tmp/claude.json.new' && mv '$tmp/claude.json.new' '$tmp/claude.json'"
dbg_at_poll 9 "jq 'del(.oauthAccount)' '$tmp/claude.json' > '$tmp/claude.json.new' && mv '$tmp/claude.json.new' '$tmp/claude.json'"
dbg_run switch dbother --debug
check "a write-back does not change the exit code" 0 "$hs_rc"
check_true "a token change names the profile, not an id" grep -q "^debug: the CLI login's token changed on dbother, usually an ordinary refresh; claude auth status shows the account it uses$" <<< "$hs_err"
check "a change, then a later write, both warn, and so does each identity-only flip" 5 "$(dbg_warned)"
check_true "an identity flip says it went back" grep -q "^debug: the CLI login went back to bbbbbbbb-flip after the switch to dbother; run claude-multipass switch dbother$" <<< "$hs_err"
check_true "an account with a profile prints its name" grep -q "^debug: the CLI login went back to beta after the switch to dbother; run claude-multipass switch dbother$" <<< "$hs_err"
check_true "no identity at all prints unknown, not the LLMR profile with no account" grep -q "^debug: the CLI login went back to unknown after the switch to dbother" <<< "$hs_err"
check "and no warning prints an account id for the target" 0 "$(grep '^debug: the CLI login' <<< "$hs_err" | grep -c 'dddddddd-7777' || true)"
check "and no warning points at the log" 0 "$(grep -c 'see .*debug.log' <<< "$hs_err" || true)"
check "and every poll runs" 15 "$(dbg_polls)"
check "and names the processes at each change" 6 "$(grep -c 'claude pid=' "$dbg_log")"
check "and logs the changes" yes "$(dbg_logged 'the CLI login went back to beta')"
check "and does not call it stable" no "$(dbg_logged 'CLI login unchanged')"

cda switch beta --no-relaunch > /dev/null 2>&1
dbg_put_item '{"claudeAiOauth":{"accessToken":"at-rotated","refreshToken":"rt-rotated","expiresAt":3}}'
rm -f "$tmp/calls"
export DBG_LEAK_PROBE=1
CLAUDE_MULTIPASS_DEBUG=1 dbg_run switch dbother
check "a debug run does not pass the variable to Desktop" 0 "$(grep -c '^CLAUDE_MULTIPASS_DEBUG=' "$tmp/open-env" || true)"
check "nor the caller's other variables" 0 "$(grep -c '^DBG_LEAK_PROBE=' "$tmp/open-env" || true)"
check "and HOME reaches it" 1 "$(grep -c '^HOME=' "$tmp/open-env")"
check_true "through the stub, not a real open" grep -q 'open -a Claude' "$tmp/calls"
check_true "and a write from the stub lands in the fixture Keychain" test "$(kc_get "Claude Code-credentials" "$USER" | jq -r .claudeAiOauth.refreshToken)" = rt-rotated
unset DBG_LEAK_PROBE
check "CLAUDE_MULTIPASS_DEBUG=1 turns it on for a switch" yes "$(dbg_logged 'quit done')"
check "and keeps its lines off stderr, which the app shows as a warning" "" "$(grep -E '^debug: [0-9:]{8} ' <<< "$hs_err" || true)"
check "the watch with it" 15 "$(dbg_polls)"
check "and a change warning still reaches stderr, for the app's row note" 1 "$(dbg_warned)"
rm "$tmp/dbg-at-open"

cda switch beta --no-relaunch > /dev/null 2>&1
dbg_at_open 'security delete-generic-password -a "$USER" -s "Claude Code-credentials"'
dbg_run switch dbother --debug
check "a deleted item counts as one change" 1 "$(dbg_warned)"
check_true "a deleted item is the same message" grep -q "^debug: the CLI login was cleared; run claude auth login, then save dbother$" <<< "$hs_err"
rm "$tmp/dbg-at-open"

cda switch beta --no-relaunch > /dev/null 2>&1
dbg_put_item '{"claudeAiOauth":{"accessToken":"at-rotated","refreshToken":"","expiresAt":3}}'
dbg_run switch dbother --debug
check "an emptied refresh token counts as a change" 1 "$(dbg_warned)"
check_true "an emptied refresh token alone stays the token message" grep -q "^debug: the CLI login's token changed on dbother" <<< "$hs_err"
rm "$tmp/dbg-at-open"

# Reads that tell nothing skip their poll: an item that is not JSON, a failed read.
cda switch beta --no-relaunch > /dev/null 2>&1
dbg_put_item 'not json'
dbg_run switch dbother --debug
check "an item that is not JSON does not change the exit code" 0 "$hs_rc"
check "and skips each poll" 15 "$(dbg_polls)"
check "and the log says nothing was checked" yes "$(dbg_logged 'could not read the CLI login in any of the 15 polls; nothing was checked')"
check_true "and so does a warning" grep -q 'debug: could not read the CLI login in any of the 15 polls; nothing was checked' <<< "$hs_err"
check "and does not call it unchanged" no "$(dbg_logged 'unchanged')"
check "and never calls it cleared" 0 "$(grep -c 'was cleared' <<< "$hs_err" || true)"
rm "$tmp/dbg-at-open"
kc_put "Claude Code-credentials" "$USER" '{"claudeAiOauth":{"accessToken":"at-dbother","refreshToken":"rt-dbother","expiresAt":2}}'

cda switch beta --no-relaunch > /dev/null 2>&1
dbg_at_open "touch '$tmp/security-find-fail'"
dbg_at_poll 8 "rm '$tmp/security-find-fail'"
dbg_run switch dbother --debug
rm "$tmp/dbg-at-open"
check "a read that fails does not change the exit code" 0 "$hs_rc"
check_true "and a warning names how many failed" grep -q 'debug: could not read the CLI login in 7 of 15 polls' <<< "$hs_err"
check "and does not call it unchanged" no "$(dbg_logged 'unchanged')"
check "and a read that tells nothing is never called cleared" 0 "$(grep -c 'was cleared' <<< "$hs_err" || true)"

# The trap runs under set -e, so a failure inside the watch must not end it.
touch "$tmp/dbg-sleep-fail"
dbg_run switch dbother --debug
rm "$tmp/dbg-sleep-fail"
check "a failure inside the watch keeps the exit code" 0 "$hs_rc"
check "and the rest of the trap runs" absent "$([[ -L $CLAUDE_MULTIPASS_DIR/.run.lock ]] && echo present || echo absent)"

# A failed run reached no arm, so its watch does nothing.
cda switch beta --no-relaunch > /dev/null 2>&1
mkdir "$tmp/claude-home/.oauth_refresh.lock"
: > "$tmp/security-calls"
dbg_run switch dbother --debug
rmdir "$tmp/claude-home/.oauth_refresh.lock"
check "a switch that fails under debug still exits 1" 1 "$hs_rc"
check "and watches nothing" 0 "$(dbg_polls)"
check "and logs no watch line" no "$(dbg_logged 'CLI login')"
check "but logs the run" yes "$(dbg_logged 'quit done')"
check "and reads no Keychain item" 0 "$(wc -l < "$tmp/security-calls" | tr -d ' ')"

# No CLI part, no watch
CLAUDE_CONFIG_DIR=$tmp/dbg-config dbg_run switch dbother --debug --no-relaunch
check "a blocked CLI part arms no watch" 0 "$(dbg_polls)"
check "and logs why" yes "$(dbg_logged 'no watch: CLAUDE_CONFIG_DIR is set')"
check "and no verdict on the login" no "$(dbg_logged 'the CLI login was\|the CLI login went\|the CLI login.s token\|the CLI login is on\|CLI login unchanged')"

# The arm: a login that did not follow the switch reads as that, not as stable.
mv "$p/dbother/cli.json" "$tmp/dbother-cli.json"
dbg_run switch dbother --debug --no-relaunch
mv "$tmp/dbother-cli.json" "$p/dbother/cli.json"
check_true "a CLI login left on another account warns at the arm, by profile name" grep -q "^debug: the CLI login is on beta, not dbother$" <<< "$hs_err"
check "and logs it" yes "$(dbg_logged "the CLI login is on beta, not dbother")"
check "and keeps watching" 15 "$(dbg_polls)"
touch "$tmp/security-find-fail"
dbg_run switch dbother --debug --no-relaunch
rm "$tmp/security-find-fail"
check_true "a read that fails at the arm warns" grep -q 'debug: could not read the CLI login; no watch' <<< "$hs_err"
check "and watches nothing" 0 "$(dbg_polls)"
cda switch beta --no-relaunch --force > /dev/null 2>&1

# A clear already there at the arm: the claude that cli_verify runs clears the item.
{
  printf '#!/bin/sh\nPATH="%s/bin:$PATH"\n' "$tmp"
  dbg_item_cmd '{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0}}'
  printf 'echo %s\n' "'{\"loggedIn\":true,\"orgId\":\"org-other\"}'"
} > "$tmp/bin/claude"
chmod +x "$tmp/bin/claude"
dbg_run switch dbother --debug --no-relaunch
rm "$tmp/bin/claude"
check "a login cleared before the arm says so once" 1 "$(dbg_warned)"
check_true "with the cleared message" grep -q "^debug: the CLI login was cleared; run claude auth login, then save dbother$" <<< "$hs_err"
check "and keeps watching" 15 "$(dbg_polls)"
cda switch beta --no-relaunch --force > /dev/null 2>&1

# save and add log, and watch nothing, and read the Keychain as often as without debug.
: > "$tmp/security-calls"
dbg_run save beta
save_calls=$(wc -l < "$tmp/security-calls")
: > "$tmp/security-calls"
dbg_run save beta --debug
check "save under debug logs" yes "$(dbg_logged 'quit done')"
check "and watches nothing" 0 "$(dbg_polls)"
check "and logs no watch line" no "$(dbg_logged 'CLI login')"
check "and adds no Keychain call" "$save_calls" "$(wc -l < "$tmp/security-calls")"
cp "$d/config.json" "$tmp/config-before-dbg-add"
: > "$tmp/security-calls"
dbg_run add dbnew
add_calls=$(wc -l < "$tmp/security-calls")
cp "$tmp/config-before-dbg-add" "$d/config.json"
printf cookie-B > "$d/Cookies"
: > "$tmp/security-calls"
dbg_run add dbnew --debug
check "add under debug logs" yes "$(dbg_logged 'quit done')"
check "and watches nothing" 0 "$(dbg_polls)"
check "and logs no watch line" no "$(dbg_logged 'CLI login')"
check "and adds no Keychain call" "$add_calls" "$(wc -l < "$tmp/security-calls")"
cp "$tmp/config-before-dbg-add" "$d/config.json"
printf cookie-B > "$d/Cookies"

# An LLMR switch moves no CLI login.
rm -f "$tmp/llmr-env"
CLAUDE_MULTIPASS_DEBUG=1 dbg_run switch dbllmr --debug
check "an LLMR switch under debug succeeds" 0 "$hs_rc"
check "and does not pass the variable to llmr" 0 "$(grep -c '^CLAUDE_MULTIPASS_DEBUG=' "$tmp/llmr-env" || true)"
check "and logs" yes "$(dbg_logged 'quit done')"
check "and watches nothing" 0 "$(dbg_polls)"
rm -rf "$p/dbllmr" "$CLAUDE_MULTIPASS_DIR/active-llmr" "$tmp/llmr-up" "$tmp/claude-up"

# pick re-enters main for its switch, and pick itself logs nothing.
printf '#!/bin/sh\ngrep "^dbother "\n' > "$tmp/bin/fzf"
chmod +x "$tmp/bin/fzf"
# Its relaunch is also the run for a clear that lands after the arm.
dbg_put_item '{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0}}'
dbg_run pick --debug
rm "$tmp/dbg-at-open"
check_true "a cleared login says so and what to do" grep -q "^debug: the CLI login was cleared; run claude auth login, then save dbother$" <<< "$hs_err"
check "once across all 15 polls" 1 "$(dbg_warned)"
check "with no ordinary refresh message" 0 "$(grep -c 'usually an ordinary refresh' <<< "$hs_err" || true)"
kc_put "Claude Code-credentials" "$USER" '{"claudeAiOauth":{"accessToken":"at-rotated","refreshToken":"rt-rotated-3","expiresAt":3}}'
check "pick --debug succeeds" 0 "$hs_rc"
check "and its switch logs" yes "$(dbg_logged 'switch dbother: claude-multipass')"
check "and watches" 15 "$(dbg_polls)"
check "and pick itself logs nothing" no "$(dbg_logged ' pick')"
printf '#!/bin/sh\nexit 130\n' > "$tmp/bin/fzf"
chmod +x "$tmp/bin/fzf"
dbg_run pick --debug
check "a cancelled pick --debug writes no debug.log" absent "$([[ -e $dbg_log ]] && echo present || echo absent)"

# With jq -r's newline, as the watch hashes it.
token_hash=$(printf 'rt-dbother\n' | shasum -a 256 | cut -c1-64)
rotated_hash=$(printf 'rt-rotated\n' | shasum -a 256 | cut -c1-64)
check "no token or token hash in any debug.log or stderr" 0 "$(grep -cE "at-dbother|rt-dbother|at-beta|rt-beta|at-rotated|rt-rotated|at-alpha|rt-alpha|rt-argv-leak|$token_hash|$rotated_hash" "$tmp/dbg-all" || true)"
check_true "--help names the option" grep -q -- '--debug .*CLAUDE_MULTIPASS_DEBUG=1' <<< "$(cda --help | tr -s ' \n' ' ')"
check_true "the tldr names it" grep -q 'claude-multipass switch {{name}} --debug' "$script"

hs_end
rm -rf "$p/dbother" "$tmp/dbg-claude" "$dbg_log" "$tmp/bin/sleep"
printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/pgrep"
printf '#!/bin/sh\nPATH="%s/bin:$PATH"\necho "open $*" >> "%s/calls"\n' "$tmp" "$tmp" > "$tmp/bin/open"
printf '#!/bin/sh\ngrep "^beta "\n' > "$tmp/bin/fzf"
rm -f "$tmp/calls"

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
check "an explicit store never migrates" "No saved accounts yet: run claude-multipass save <name> for the signed-in one, add <name> for another" "$(CLAUDE_MULTIPASS_DIR="$tmp/empty2" XDG_CONFIG_HOME="$tmp/home/.config" cda list | sed -n 1p)"
mkdir -p "$tmp/home2/.config/dotfiles/claude-desktop-accounts/old" "$tmp/home2/.config/dotfiles/claude-desktop-accounts-backups" "$tmp/home2/.config/claude-multipass/backups"
cp "$tmp/home/.config/claude-multipass/profiles/old/"* "$tmp/home2/.config/dotfiles/claude-desktop-accounts/old/"
env -u CLAUDE_MULTIPASS_DIR XDG_CONFIG_HOME="$tmp/home2/.config" "$script" list > /dev/null 2> "$tmp/migrate-err2"
check_true "migration warns when the new backups folder already exists" grep -q "Left $tmp/home2/.config/dotfiles/claude-desktop-accounts-backups in place" "$tmp/migrate-err2"
check_true "and leaves the legacy backups where they were" test -d "$tmp/home2/.config/dotfiles/claude-desktop-accounts-backups"

echo "All claude-multipass checks passed"
