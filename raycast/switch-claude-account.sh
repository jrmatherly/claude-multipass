#!/bin/bash
#
# Raycast command: switch Claude Desktop to a saved account (quits and
# relaunches the app).
#
# @raycast.schemaVersion 1
# @raycast.title Switch Claude Account
# @raycast.mode compact
# @raycast.packageName Claude Desktop
# @raycast.icon 🔀
# @raycast.needsConfirmation true
# @raycast.argument1 { "type": "text", "placeholder": "account name" }

set -euo pipefail

# Raycast runs scripts without the login shell's PATH; claude-multipass and
# jq live in Homebrew's bin (Apple Silicon, then Intel).
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
cda=claude-multipass
command -v "$cda" > /dev/null || {
  echo "$cda not installed: brew install jrmatherly/tap/claude-multipass"
  exit 1
}

"$cda" switch "$1"
# compact mode shows only the last line as the toast
echo "Switched to $1"
