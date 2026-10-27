#!/bin/bash
#
# Claude Code PreToolUse hook (Bash): before a `git commit`, run `pnpm check`
# in the repo the commit targets and block the call (exit 2, the check's tail
# on stderr) when it fails. When it passes but bin/claude-multipass changed
# with no README.md or docs/ change, it tells Claude so through
# additionalContext. When the commit's worktree carries a different copy of
# this hook, that copy runs instead, so a branch that edits the hook is gated
# by its own version.
# Wired up in .claude/settings.json; self-check: .claude/hooks/test-commit-gate.sh

set -uo pipefail
# Word splitting below must not expand globs in the command
set -f

input=$(cat)
command=$(jq -r '.tool_input.command // empty' <<< "$input")
cwd=$(jq -r '.cwd // empty' <<< "$input")
cwd=${cwd:-${CLAUDE_PROJECT_DIR:-$(pwd -P)}}

# Resolve $1 against $2 into dir, as cd and git -C would (no quotes, so no
# spaces; a leading ~ is the one expansion a bare word gets)
enter() {
  case $1 in
    /*) dir=$1 ;;
    [~] | [~]/*) dir=$HOME${1:1} ;;
    *) dir=$2/$1 ;;
  esac
}

# A segment is a commit when its command word (after NAME=value prefixes) is
# git and a later word is `commit`; quoted text is not parsed. dir follows
# each `cd <dir>` segment before it and the commit's own `git -C <dir>`
is_commit() {
  local seg w first prev gitdir
  dir=$cwd
  while IFS= read -r seg; do
    first=""
    prev=""
    gitdir=$dir
    for w in $seg; do
      if [ -z "$first" ]; then
        [[ $w =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && continue
        first=${w##*/}
        [ "$first" = git ] || [ "$first" = cd ] || break
      elif [ "$first" = cd ]; then
        enter "$w" "$dir"
        break
      elif [ "$prev" = -C ]; then
        enter "$w" "$gitdir"
        gitdir=$dir
      elif [ "$w" = commit ]; then
        dir=$gitdir
        return 0
      fi
      prev=$w
    done
  done < <(sed -E 's/(&&|\|\||;|\|)/\n/g' <<< "$1")
  return 1
}

is_commit "$command" || exit 0
root=$(git -C "$dir" rev-parse --show-toplevel 2> /dev/null) || exit 0
# Gate only repos that ship this hook, so a commit in a foreign repo never
# runs that repo's check script. When a worktree's own copy differs from this
# one, its copy gates instead, so a branch that edits the hook is still gated
[ -e "$root/test/check.sh" ] || exit 0
copy=$root/.claude/hooks/commit-gate.sh
if ! cmp -s "$0" "$copy"; then
  # Delegate only to a worktree of the session's own repository, never to a
  # copy some other repo ships. The copy runs as $0 == $copy, so it never
  # delegates again
  [ -f "$copy" ] || exit 0
  common=$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2> /dev/null) || exit 0
  [ "$common" = "$(git -C "${CLAUDE_PROJECT_DIR:-$(pwd -P)}" rev-parse --path-format=absolute --git-common-dir 2> /dev/null)" ] || exit 0
  # bash, not the file itself, so a copy that lost its executable bit still gates
  exec bash "$copy" <<< "$input"
fi

if ! out=$(cd "$root" && pnpm check 2>&1); then
  {
    echo "pnpm check failed in $root, so the commit is blocked:"
    tail -n 40 <<< "$out"
  } >&2
  exit 2
fi

# The working tree, not the index: in `git add x && git commit` this runs
# before the add. -uall lists files inside new directories, and the second
# expression keeps a rename's new path
changed=$(git -C "$root" status --porcelain -uall | sed -E 's/^...//; s/.* -> //')
grep -q '^bin/claude-multipass$' <<< "$changed" || exit 0
grep -Eq '^(README\.md|docs/)' <<< "$changed" && exit 0
jq -cn --arg c "Changed: bin/claude-multipass. Neither README.md nor docs/ is changed; the docs-mirror rule expects a doc edit in the same commit." \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c}}'
