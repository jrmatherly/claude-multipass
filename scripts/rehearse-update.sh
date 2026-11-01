#!/bin/bash
# Rehearse an in-app update from 0.0.1 to 0.0.2 with a real Sparkle install, on this Mac.
# A bundle id of its own, so the real app's settings and login item stay out of it, and a
# throwaway key, so no Keychain item is read. Click through About while it waits.
#
#   scripts/rehearse-update.sh [--bad-signature | --stop-feed | --from-dmg]
#
#   (none)           serve a good feed; exit 0 once the disk reads 0.0.2, 1 at the deadline
#   --bad-signature  the feed's signature is from another key; About shows the failure
#   --stop-feed      nothing serves the feed; silent at launch, a message on Check now
#   --from-dmg       the app runs from a mounted DMG; Check now says to move it
#
# The three failure modes exit 0 when the disk still reads 0.0.1 at REHEARSE_SECONDS (default
# 180). That proves only the disk, whether or not anyone clicked; the message is in About.
# On exit the app, its builds in dist/, its preferences and its caches go.
set -euo pipefail

cd "$(dirname "$0")/.."

mode=happy
case ${1:-} in
  '') ;;
  --bad-signature) mode=bad-signature ;;
  --stop-feed) mode=stop-feed ;;
  --from-dmg) mode=from-dmg ;;
  *)
    echo "usage: scripts/rehearse-update.sh [--bad-signature | --stop-feed | --from-dmg]" >&2
    exit 2
    ;;
esac
deadline=${REHEARSE_SECONDS:-180}

bundle_id=net.matherly.mp-rehearsal
agents_dir=$HOME/Library/LaunchAgents
work=$(mktemp -d)
server=''
mount=''
app_path=''

cleanup() {
  [[ -z $app_path ]] || pkill -f "$app_path/Contents/MacOS/ClaudeMultipass" || true
  [[ -z $server ]] || kill "$server" 2> /dev/null || true
  [[ -z $mount ]] || hdiutil detach -quiet -force "$mount" || true
  defaults delete "$bundle_id" 2> /dev/null || true
  rm -rf "$work" "dist/Claude Multipass.app" dist/claude-multipass-app_0.0.[12]_* "$HOME/Library/Caches/$bundle_id" "$HOME/Library/HTTPStorages/$bundle_id" "$HOME/Library/Preferences/$bundle_id.plist"
}
trap cleanup EXIT

# CryptoKit, so no Keychain is touched: the seed, then its public key.
keypair() {
  swift -e 'import CryptoKit
let k = Curve25519.Signing.PrivateKey()
print(k.rawRepresentation.base64EncodedString())
print(k.publicKey.rawRepresentation.base64EncodedString())'
}
keys=$(keypair)
seed=$(sed -n 1p <<< "$keys")
export SPARKLE_PUBLIC_KEY APP_BUNDLE_ID=$bundle_id
SPARKLE_PUBLIC_KEY=$(sed -n 2p <<< "$keys")
# A rehearsal build is signed, never notarized.
unset APPLE_API_KEY_ID APPLE_API_ISSUER_ID APPLE_API_KEY_P8

# Copies, because the next build erases dist/.
APP_VERSION=0.0.1 bash scripts/build-app.sh --dmg
mkdir -p "$work/install" "$work/feed"
cp -R "dist/Claude Multipass.app" "$work/install/"
cp dist/claude-multipass-app_0.0.1_*.dmg "$work/old.dmg"
APP_VERSION=0.0.2 bash scripts/build-app.sh --dmg
new_dmg=$(echo dist/claude-multipass-app_0.0.2_*.dmg)
cp "$new_dmg" "$work/feed/"
new_dmg=$work/feed/$(basename "$new_dmg")

{
  printf '# Changelog\n\n## 0.0.2 (%s)\n\n- The rehearsal build.\n\n' "$(date +%Y-%m-%d)"
  # Past the file's own title, which would read as a line of the new section.
  tail -n +2 CHANGELOG.md
} > "$work/CHANGELOG.md"
port=$(/usr/bin/python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
feed_key=$seed
[[ $mode != bad-signature ]] || feed_key=$(keypair | sed -n 1p)
SPARKLE_ED_KEY=$feed_key APPCAST_DOWNLOAD_BASE=http://127.0.0.1:$port \
  bash scripts/make-appcast.sh "$new_dmg" 0.0.2 "$work/CHANGELOG.md" > "$work/feed/appcast.xml"

if [[ $mode != stop-feed ]]; then
  /usr/bin/python3 -m http.server "$port" --bind 127.0.0.1 --directory "$work/feed" > /dev/null 2>&1 &
  server=$!
fi

app_path="$work/install/Claude Multipass.app"
if [[ $mode == from-dmg ]]; then
  mount=$work/mount
  mkdir "$mount"
  hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mount" "$work/old.dmg"
  app_path="$mount/Claude Multipass.app"
fi

agents_before=$(ls "$agents_dir" 2> /dev/null || true)
defaults write "$bundle_id" SUFeedURL "http://127.0.0.1:$port/appcast.xml"
open "$app_path"
echo "rehearse: running $app_path ($mode). Open Settings, About. Waiting up to $deadline s." >&2

disk_version() {
  plutil -extract CFBundleShortVersionString raw -o - "$app_path/Contents/Info.plist"
}
sparkle_jobs() {
  launchctl print "gui/$(id -u)" | grep -oE "$bundle_id-sparkle-[a-z]+" | sort -u || true
}

seen_jobs=''
updated=''
for ((i = 0; i < deadline; i++)); do
  jobs_now=$(sparkle_jobs)
  [[ -z $jobs_now ]] || seen_jobs=$(printf '%s\n%s\n' "$seen_jobs" "$jobs_now" | sed '/^$/d' | sort -u)
  if [[ $(disk_version) == 0.0.2 ]]; then
    updated=1
    break
  fi
  sleep 1
done

if [[ -z $updated ]]; then
  if [[ $mode == happy ]]; then
    echo "rehearse: the disk still reads 0.0.1 after $deadline s" >&2
    exit 1
  fi
  echo "rehearse: $mode: the disk still reads 0.0.1, as expected" >&2
  exit 0
fi
if [[ $mode != happy ]]; then
  echo "rehearse: $mode: the disk reads 0.0.2, and it must not" >&2
  exit 1
fi

# The rail in .claude/rules/safety-and-terms.md: nothing of Sparkle's outlives the install.
echo "rehearse: launchd during the install: ${seen_jobs:-none seen}" >&2
for ((i = 0; i < 30; i++)); do
  [[ -n $(sparkle_jobs) ]] || break
  sleep 1
done
left=$(sparkle_jobs)
[[ -z $left ]] || {
  echo "rehearse: launchd jobs remain after the install: $left" >&2
  exit 1
}
[[ $(ls "$agents_dir" 2> /dev/null || true) == "$agents_before" ]] || {
  echo "rehearse: $agents_dir changed during the install" >&2
  exit 1
}
# The new bundle on disk does not prove the relaunch.
for ((i = 0; i < 30; i++)); do
  if pgrep -f "$app_path/Contents/MacOS/ClaudeMultipass" > /dev/null; then
    echo "rehearse: updated to 0.0.2 and relaunched; no launchd job or LaunchAgents file left" >&2
    exit 0
  fi
  sleep 1
done
echo "rehearse: the disk reads 0.0.2 but the app did not relaunch" >&2
exit 1
