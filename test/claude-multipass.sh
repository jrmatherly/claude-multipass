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
chmod +x "$tmp"/bin/*
export PATH="$tmp/bin:$PATH"
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

mkdir -p "$d" "$p/beta" "$s/aaaaaaaa-1111/org-a" "$s/bbbbbbbb-2222/org-b"
tab=$'\t'
printf '{\n\t"theme": "dark",\n\t"oauth:tokenCache": "enc-A1",\n\t"windowBounds": {\n\t\t"x": 1,\n\t\t"y": 2.50\n\t},\n\t"oauth:tokenCacheV2": "enc-A2",\n\t"lastKnownAccountUuid": "aaaaaaaa-1111",\n\t"zeta": [\n\t\t"é",\n\t\tnull\n\t]\n}' > "$d/config.json"
printf cookie-A > "$d/Cookies"
printf journal-A > "$d/Cookies-journal"

# save captures exactly the three keys and the cookie files
cda save alpha > /dev/null
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

printf '{"oauth:tokenCache":"enc-B1","oauth:tokenCacheV2":"enc-B2","lastKnownAccountUuid":"bbbbbbbb-2222"}' > "$p/beta/config.json"
printf '{"account":"bbbbbbbb-2222","savedAt":"2026-01-01T00:00:00Z"}' > "$p/beta/meta.json"
printf cookie-B > "$p/beta/Cookies"

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

out=$(cda switch beta --no-relaunch)
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

# list marks the active profile
list=$(cda list)
check_true "list marks beta active" grep -Eq '^\* beta +bbbbbbbb  2026-01-01T00:00:00Z  4 sessions$' <<< "$list"
check_true "list leaves alpha unmarked" grep -Eq '^  alpha +aaaaaaaa  ' <<< "$list"

# show, the fzf picker (stub fzf picks the beta row) and the Raycast scripts
check "show prints the profile and its sessions per org" "beta
account bbbbbbbb
saved at 2026-01-01T00:00:00Z
org org-b: 4 sessions" "$(cda show beta)"
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
# The Raycast scripts call claude-multipass by name
ln -s "$script" "$tmp/bin/claude-multipass"
raycast="$(cd "$(dirname "$script")/.." && pwd -P)/raycast"
check "current prints the active name" beta "$(cda current)"
check "Raycast inline shows the active account" beta "$("$raycast/claude-account.sh")"
check "Raycast switch ends with a toast line" "Switched to beta" "$("$raycast/switch-claude-account.sh" beta | tail -1)"

# sync refuses while Desktop runs (pgrep finds it)
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/pgrep"
check "sync refuses while Desktop runs" 1 "$(exit_code cda sync)"
check "sync --force runs anyway" 0 "$(exit_code cda sync --force)"
printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/pgrep"

# add re-saves the active login and signs out locally
out=$(cda add gamma --no-relaunch)
check "add clears the auth keys" '["theme","windowBounds","zeta"]' "$(jq -c keys_unsorted "$d/config.json")"
check_true "add removes the cookie files" test ! -e "$d/Cookies"
check_true "add prints the save step" grep -q 'claude-multipass save gamma' <<< "$out"
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
check "rename onto an existing name fails" 1 "$(exit_code cda rename home beta)"
check "rename needs two names" 1 "$(exit_code cda rename home)"
check "remove moves the profile to backups" 1 "$(
  cda remove home > /dev/null
  find "$b" -maxdepth 1 -name 'profile-home-*' | wc -l | tr -d ' '
)"
check_true "removed profile is gone from the store" test ! -e "$p/home"
check "remove of an unknown name fails" 1 "$(exit_code cda remove home)"
cp -R "$b"/profile-home-* "$p/alpha"
check "--force outside sync or switch fails" 1 "$(exit_code cda list --force)"
# an unsaved login must not be switched away from silently
printf '{"oauth:tokenCacheV2":"enc-Z","lastKnownAccountUuid":"zzzzzzzz-9999"}' > "$d/config.json"
check "switch refuses to drop an unsaved login" 1 "$(exit_code cda switch alpha --no-relaunch)"
check "switch --force drops it anyway" 0 "$(exit_code cda switch alpha --no-relaunch --force)"
check "forced switch restored alpha" aaaaaaaa-1111 "$(jq -r .lastKnownAccountUuid "$d/config.json")"
check "no backups folder inside the profile store" "" "$(ls -d "$p/backups" 2> /dev/null || true)"

# save refuses to overwrite a profile that holds another account
printf '{"oauth:tokenCacheV2":"enc-Z","lastKnownAccountUuid":"zzzzzzzz-9999"}' > "$d/config.json"
check "save over another account's profile fails" 1 "$(exit_code cda save beta --no-relaunch)"
check "the refused save left beta untouched" bbbbbbbb-2222 "$(jq -r .account "$p/beta/meta.json")"
check "save --force replaces it" 0 "$(exit_code cda save beta --no-relaunch --force)"
check "forced save moved the old profile to backups" 1 "$(find "$b" -maxdepth 1 -name 'profile-beta-*' | wc -l | tr -d ' ')"
check "forced save holds the new account" zzzzzzzz-9999 "$(jq -r .account "$p/beta/meta.json")"

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

# backups prune to the newest ten
for i in $(seq 1 12); do mkdir -p "$b/login-2020010100000$i-1"; done
printf '{"oauth:tokenCache":"x","oauth:tokenCacheV2":"enc-Q","lastKnownAccountUuid":"qqqqqqqq-0000"}' > "$d/config.json"
cda add eps --no-relaunch > /dev/null 2>&1
check "login backups pruned to ten" 10 "$(find "$b" -mindepth 1 -maxdepth 1 -type d -name 'login-*' | wc -l | tr -d ' ')"

# usage: a fixture token cache encrypted the way the app does; security and
# curl are stubs on PATH, so no Keychain and no network
mkdir -p "$p/usagey" "$p/stale"
pw='fixture pass!$'
printf '#!/bin/sh\nprintf %%s "%s"\n' "$pw" > "$tmp/bin/security"
printf '{"five_hour":{"utilization":42.6,"resets_at":"2026-10-23T19:45:00.123456+00:00"},"seven_day":{"utilization":18.0,"resets_at":"2026-10-27T13:00:00Z"}}' > "$tmp/usage.json"
printf '#!/bin/sh\n{ echo "curl $*"; cat; } >> "%s/curl-args"\ncat "%s/usage.json"; printf "\\n200"\n' "$tmp" "$tmp" > "$tmp/bin/curl"
chmod +x "$tmp/bin/security" "$tmp/bin/curl"
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
printf '{"oauth:tokenCache":"x","oauth:tokenCacheV2":"enc","lastKnownAccountUuid":"uuuuuuuu-1"}' > "$d/config.json"
check "Raycast usage command shows the active account's figures" "usagey           $expected" "$("$raycast/claude-account-usage.sh")"

# the dotfiles-era store moves into the default location once, backups too
# (XDG_CONFIG_HOME, not HOME: tools on PATH may read their own config from HOME)
mkdir -p "$tmp/home/.config/dotfiles/claude-desktop-accounts/old" "$tmp/home/.config/dotfiles/claude-desktop-accounts-backups/login-1"
printf '{"account":"aaaaaaaa-1111","savedAt":"2026-01-01T00:00:00Z"}' > "$tmp/home/.config/dotfiles/claude-desktop-accounts/old/meta.json"
cp "$p/beta/config.json" "$tmp/home/.config/dotfiles/claude-desktop-accounts/old/config.json"
check "first run moves the old store" "Moved the saved accounts from $tmp/home/.config/dotfiles/claude-desktop-accounts to $tmp/home/.config/claude-multipass/profiles" "$(env -u CLAUDE_MULTIPASS_DIR XDG_CONFIG_HOME="$tmp/home/.config" "$script" list | head -1)"
check_true "old backups moved beside it" test -d "$tmp/home/.config/claude-multipass/backups/login-1" -a ! -e "$tmp/home/.config/dotfiles/claude-desktop-accounts"
check "the moved store is private" 700 "$(stat -f %Lp "$tmp/home/.config/claude-multipass")"
check "second run does not move again" "  old " "$(env -u CLAUDE_MULTIPASS_DIR XDG_CONFIG_HOME="$tmp/home/.config" "$script" list | head -1 | cut -c1-6)"
check "an explicit store never migrates" "No saved accounts yet: run claude-multipass save <name> for the signed-in one, add <name> for another" "$(CLAUDE_MULTIPASS_DIR="$tmp/empty2" XDG_CONFIG_HOME="$tmp/home/.config" cda list | head -1)"

echo "All claude-multipass checks passed"
