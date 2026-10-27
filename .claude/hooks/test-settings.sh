#!/bin/bash
#
# Self-check for the hook wiring and permissions in .claude/settings.json.
# Run: .claude/hooks/test-settings.sh

set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd -P)
settings=$root/.claude/settings.json

fail() {
  echo "FAIL: $1" >&2
  exit 1
}
# jq -e against the settings: exit 0 only when the filter yields true
has() {
  jq -e "$1" "$settings" > /dev/null || fail "$2"
}

has '.bashEditDiffEnabled == true' "bashEditDiffEnabled is not true"

has '[.hooks.PreToolUse[] | select(.matcher == "Bash")] | length == 1' \
  "not exactly one PreToolUse entry with matcher Bash"
has '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks
  | length == 1 and (.[0].command | endswith("/.claude/hooks/commit-gate.sh"))
    and .[0].onFailure == "block"' \
  "PreToolUse Bash is not one commit-gate.sh hook with onFailure block"

# The edit matcher is a regex Claude Code tests against the tool name
edit_matcher=$(jq -r '.hooks.PostToolUse[]
  | select(any(.hooks[]; .command | endswith("/.claude/hooks/lint-edited.sh")))
  | .matcher' "$settings")
[ -n "$edit_matcher" ] || fail "no PostToolUse entry runs lint-edited.sh"
for tool in Edit Write mcp__serena__replace_content; do
  [[ $tool =~ $edit_matcher ]] || fail "lint-edited.sh matcher misses $tool"
done
[[ ! Bash =~ $edit_matcher ]] || fail "lint-edited.sh matcher matches Bash"
has 'any(.hooks.PostToolUse[]; .matcher == "Bash"
  and any(.hooks[]; .command | endswith("/.claude/hooks/lint-bash-edits.sh")))' \
  "no PostToolUse Bash entry runs lint-bash-edits.sh"

while IFS= read -r cmd; do
  file=${cmd/\$\{CLAUDE_PROJECT_DIR\}/$root}
  [[ $file != "$cmd" ]] || fail "hook command not under \${CLAUDE_PROJECT_DIR}: $cmd"
  [ -x "$file" ] || fail "hook command missing or not executable: $cmd"
done < <(jq -r '.hooks[][].hooks[].command' "$settings")

has '[.permissions.allow[], .permissions.ask[]] | all(startswith("Bash("))' \
  "a permissions.allow or ask entry does not start with Bash("
for prefix in claude-multipass bin/claude-multipass ./bin/claude-multipass; do
  for cmd in switch add save remove rename sync usage; do
    jq -e --arg e "Bash($prefix $cmd *)" '.permissions.ask | index($e)' "$settings" > /dev/null \
      || fail "Bash($prefix $cmd *) is not in permissions.ask"
  done
done
has '.permissions.allow | index("Bash(pnpm check *)")' "Bash(pnpm check *) is not in permissions.allow"
has '(.permissions.deny // []) | length == 0' "permissions.deny is not empty"

echo "settings: all checks passed"
