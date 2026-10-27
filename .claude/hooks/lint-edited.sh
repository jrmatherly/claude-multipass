#!/bin/bash
#
# Claude Code PostToolUse hook (Edit, Write and Serena's edit tools): format
# and lint the one file that was just edited, in whichever checkout or
# worktree of this repo it lives, with the same tools and scope as
# `pnpm check`. Problems go to stderr with exit 2, which Claude Code shows to
# Claude so it fixes them in the same turn (exit 1 would only reach the user).
# Wired up in .claude/settings.json; self-check: .claude/hooks/test-lint-edited.sh

set -uo pipefail

project=${CLAUDE_PROJECT_DIR:-$(pwd -P)}
# Edit/Write send an absolute file_path; Serena's edit tools a relative_path
file=$(jq -r '.tool_input.file_path // .tool_input.relative_path // empty')
[ -n "$file" ] || exit 0
[[ $file == /* ]] || file="$project/$file"

# Only existing files (a directory, e.g. from replace_in_files, is skipped:
# pnpm check covers multi-file edits), in a checkout that ships this very hook.
# CLAUDE_PROJECT_DIR stays at the session's root when Claude enters a
# worktree, and every code change here is made in one, so the file's own
# checkout is the scope, as commit-gate.sh does for a commit.
[ -f "$file" ] || exit 0
root=$(git -C "$(dirname "$file")" rev-parse --show-toplevel 2> /dev/null) || exit 0
cmp -s "$0" "$root/.claude/hooks/lint-edited.sh" || exit 0

# prettier resolves its plugin, .gitignore and .prettierignore from the cwd
cd "$root" || exit 0
rel=${file#"$root"/}

# Machine-local files (private/, .codegraph/, ...) aren't ours to lint
git check-ignore -q -- "$rel" && exit 0

problems=""
run() {
  local out
  if ! out=$("$@" 2>&1); then
    problems+="\$ $*"$'\n'"$out"$'\n'
  fi
}

# Prettier: the globs `pnpm check` uses, any *.{js,cjs,ts,md,json,sh}, the
# workflow YAML under .github/, plus the top level of bin/ (`bin/*`)
case $rel in
  *.js | *.cjs | *.ts | *.md | *.json | *.sh | .github/*.yml | bin/*)
    # bin/* here means the top level only, like the prettier glob
    if [[ $rel != bin/*/* ]] && [ -x node_modules/.bin/prettier ]; then
      run node_modules/.bin/prettier --write --ignore-unknown --log-level warn -- "$rel"
    fi
    ;;
esac

# bash -n + shellcheck: test/check.sh's script list (test/*.sh,
# .claude/hooks/*.sh, raycast/*.sh, scripts/*.sh) plus top-level bin/ files with a bash/sh
# shebang, which covers bin/claude-multipass
gated=false
if [[ $rel =~ ^(test|\.claude/hooks|raycast|scripts)/[^/]+\.sh$ ]]; then
  gated=true
elif [[ $rel =~ ^bin/[^/]+$ ]] \
  && head -n 1 "$rel" | grep -Eq '^#!(/bin/(ba)?sh|/usr/bin/env (ba)?sh)$'; then
  gated=true
fi
if [ "$gated" = true ]; then
  run bash -n "$rel"
  run shellcheck --severity=warning "$rel"
fi

if [ -n "$problems" ]; then
  printf 'lint-edited: problems in %s (the edit was applied; fix and re-edit)\n%s' "$rel" "$problems" >&2
  exit 2
fi
exit 0
