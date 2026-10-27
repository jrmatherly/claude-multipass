#!/bin/bash
#
# Raycast inline command: the saved Claude Desktop account signed in now,
# "not saved" for an unsaved login, or "signed out".
#
# @raycast.schemaVersion 1
# @raycast.title Claude Account
# @raycast.mode inline
# @raycast.refreshTime 1m
# @raycast.packageName Claude Desktop
# @raycast.icon 👤

set -euo pipefail

# Raycast runs scripts without the login shell's PATH; claude-multipass and
# jq live in Homebrew's bin (Apple Silicon, then Intel).
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
cda=${CLAUDE_MULTIPASS_BIN:-claude-multipass}
command -v "$cda" > /dev/null || {
  echo "$cda not installed: brew install jrmatherly/tap/claude-multipass"
  exit 1
}

"$cda" current
