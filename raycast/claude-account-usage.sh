#!/bin/bash
#
# Raycast inline command: the signed-in saved account with its 5-hour (or
# Ultra), weekly and per-model weekly usage. Opt-in: it reads the saved
# token through the Keychain, see `claude-multipass --help`, Cautions. The
# first run shows a macOS Keychain dialog for "Claude Safe Storage"; click
# Always Allow once, or the dialog returns on every refresh. Add it in Raycast
# only if you want that.
#
# @raycast.schemaVersion 1
# @raycast.title Claude Account Usage
# @raycast.mode inline
# @raycast.refreshTime 5m
# @raycast.packageName Claude Desktop
# @raycast.icon 📊

set -euo pipefail

# Raycast runs scripts without the login shell's PATH; claude-multipass and
# jq live in Homebrew's bin (Apple Silicon, then Intel).
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
cda=${CLAUDE_MULTIPASS_BIN:-claude-multipass}
command -v "$cda" > /dev/null || {
  echo "$cda not installed: brew install jrmatherly/tap/claude-multipass"
  exit 1
}

name=$("$cda" current)
case $name in
  "not saved" | "signed out") echo "$name" ;;
  *) "$cda" usage "$name" ;;
esac
