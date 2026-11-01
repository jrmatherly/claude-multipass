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

# A variable, not a process substitution, whose failure the loop would never see
hook_commands=$(jq -r '.hooks[][].hooks[].command' "$settings") || fail "cannot read the hook commands"
while IFS= read -r cmd; do
  file=${cmd/\$\{CLAUDE_PROJECT_DIR\}/$root}
  [[ $file != "$cmd" ]] || fail "hook command not under \${CLAUDE_PROJECT_DIR}: $cmd"
  [ -x "$file" ] || fail "hook command missing or not executable: $cmd"
done <<< "$hook_commands"

has '[.permissions.allow[], .permissions.ask[]] | all(startswith("Bash("))' \
  "a permissions.allow or ask entry does not start with Bash("
# Claude Code's Bash rule match as its docs give it: * is any text, and a
# trailing " *" that is the rule's only wildcard also matches the bare command.
# A bare run opens the picker only on a terminal, so its by-path forms are
# exact rules: *bin/claude-multipass would also ask before a lint of the file
allow_rules=()
ask_rules=()
while IFS= read -r rule; do allow_rules+=("$rule"); done < <(jq -r '.permissions.allow[]' "$settings")
while IFS= read -r rule; do ask_rules+=("$rule"); done < <(jq -r '.permissions.ask[]' "$settings")
matches() { # matches <rule...> -- <command>
  local rule pat cmd=${*: -1}
  for rule in "${@:1:$#-2}"; do
    pat=${rule#Bash(}
    pat=${pat%)}
    # shellcheck disable=SC2053 # the rule is a glob on purpose
    [[ $cmd == $pat ]] && return 0
    [[ $pat == *' *' && ${pat%' *'} != *'*'* && $cmd == "${pat%' *'}" ]] && return 0
  done
  return 1
}
asks=(claude-multipass bin/claude-multipass ./bin/claude-multipass "bash bin/claude-multipass" "bash test/../bin/claude-multipass switch w" "/opt/homebrew/bin/claude-multipass save --force w"
  "raycast/switch-claude-account.sh w" "bash raycast/switch-claude-account.sh w"
  '"/Users/x/bin/claude-multipass" switch w' "bash 'bin/claude-multipass' sync")
bundled="/Applications/Claude Multipass.app/Contents/Resources/claude-multipass"
for prefix in claude-multipass bin/claude-multipass ./bin/claude-multipass "bash bin/claude-multipass" "$root/bin/claude-multipass" "\"$bundled\"" "bash \"$bundled\""; do
  for cmd in switch add save remove rename sync usage pick; do
    asks+=("$prefix $cmd w")
  done
done
for c in "${asks[@]}"; do
  matches "${ask_rules[@]}" -- "$c" || fail "permissions.ask does not cover: $c"
done
for c in "\"$bundled\" --version" "\"$bundled\" list" "claude-multipass list" "bin/claude-multipass show w" "bash test/claude-multipass.sh" 'git commit -m "claude-multipass add refuses x"' "shellcheck bin/claude-multipass"; do
  ! matches "${ask_rules[@]}" -- "$c" || fail "permissions.ask covers a read-only command: $c"
done
for c in "bash test/../bin/claude-multipass switch w" "bash test/other.sh" ".claude/hooks/test-../../bin/claude-multipass switch w"; do
  ! matches "${allow_rules[@]}" -- "$c" || fail "permissions.allow covers: $c"
done
for f in "$root"/.claude/hooks/test-*.sh; do
  matches "${allow_rules[@]}" -- ".claude/hooks/${f##*/}" \
    || fail "permissions.allow misses .claude/hooks/${f##*/} (one rule per file: a test-* glob would also allow .claude/hooks/test-../ paths)"
done
matches "${allow_rules[@]}" -- "bash test/claude-multipass.sh" || fail "permissions.allow misses bash test/claude-multipass.sh"
has '.permissions.allow | index("Bash(pnpm check *)")' "Bash(pnpm check *) is not in permissions.allow"
has '(.permissions.deny // []) | length == 0' "permissions.deny is not empty"

echo "settings: all checks passed"
