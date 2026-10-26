#!/bin/bash
#
# Claude Code PostToolUse hook (Bash): lint the files a Bash command changed
# (heredocs, sed -i, tee, cp…), which the Edit/Write hook never sees. Claude
# Code lists them in tool_response.bashEditDiff.changedFiles with gitignored
# files already dropped (best effort, 200-file cap, v2.1.269+). Each goes
# through lint-edited.sh, which owns the scope and the rules. Problems go to
# stderr with exit 2, so Claude sees them although the command already ran.
# Wired up in .claude/settings.json; self-check: .claude/hooks/test-lint-bash-edits.sh

set -uo pipefail

# Drain stdin before any early exit, or the writer gets a broken pipe
input=$(cat)
hook=${CLAUDE_PROJECT_DIR:-$(pwd -P)}/.claude/hooks/lint-edited.sh
[ -x "$hook" ] || exit 0

# skipped: a git checkout or stash moved the tree, so the list is not edits
files=()
while IFS= read -r f; do
  [ -n "$f" ] && files+=("$f")
done < <(jq -r '.tool_response.bashEditDiff? // empty | select(.skipped != true) | .changedFiles[]?' <<< "$input")
[ "${#files[@]}" -gt 0 ] || exit 0

# A bulk rewrite (pnpm format, a sync script) is pnpm check's job, not 26 hook runs
if [ "${#files[@]}" -gt 25 ]; then
  echo "lint-bash-edits: ${#files[@]} files changed in one command; run pnpm check" >&2
  exit 2
fi

rc=0
for f in "${files[@]}"; do
  if ! out=$(jq -cn --arg p "$f" '{tool_name: "Bash", tool_input: {file_path: $p}}' | "$hook" 2>&1); then
    printf '%s\n' "$out" >&2
    rc=2
  fi
done
exit $rc
