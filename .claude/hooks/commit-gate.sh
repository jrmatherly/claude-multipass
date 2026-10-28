#!/bin/bash
#
# Claude Code PreToolUse hook (Bash): before a `git commit`, or the
# `--continue` of a merge, cherry-pick, revert, rebase or am, run `pnpm check`
# in the repo the commit targets and block the call (exit 2, the check's tail
# on stderr) when it fails. When it passes but bin/claude-multipass changed
# with no README.md or docs/ change, or bin/ or app/Sources/ changed with no
# CHANGELOG.md change, it tells Claude so through additionalContext. When the commit's worktree carries a different copy of
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

# A segment is a commit when its command word, after NAME=value prefixes,
# options and keywords such as then, is git and its subcommand (the first word
# after git's own options) is commit, or the --continue of a command whose
# conflicts were just resolved: the gate runs before the command, so for a
# plain merge or rebase the tree to check is not on disk yet. After a wrapper
# such as env, sudo or nice, every word up to a git or cd is skipped, since an
# option's value (nice -n 10, sudo -u root) cannot be told from a command; a
# wrapper that runs something else with git commit as its arguments is gated
# too, which costs only a check. dir follows each `cd <dir>` segment until the
# subshell it ran in closes; a commit's `git -C <dir>` moves only that
# segment's target. Known misses: git -C "$(...)" commit, sudo -u git git
# commit, and a cd inside backticks, which is not undone when they close
is_commit() {
  local seg w first prev gitdir sub cddir wrapped depth=0
  local -a saved
  cddir=$cwd
  while IFS= read -r seg; do
    case $seg in
      '(')
        depth=$((depth + 1))
        saved[depth]=$cddir
        continue
        ;;
      ')')
        if ((depth)); then
          cddir=${saved[depth]}
          depth=$((depth - 1))
        fi
        continue
        ;;
    esac
    first=""
    prev=""
    sub=""
    wrapped=""
    gitdir=$cddir
    for w in $seg; do
      if [ -z "$first" ]; then
        [[ $w =~ ^[A-Za-z_][A-Za-z0-9_]*= || $w == -* ]] && continue
        case ${w##*/} in
          # Wrappers that run the words after them as the command
          env | command | builtin | exec | nohup | time | nice | sudo | xargs | bash | sh | zsh)
            wrapped=1
            continue
            ;;
          # Shell keywords that a command can follow
          if | then | elif | else | do | while | until | !) continue ;;
          git | cd) first=${w##*/} ;;
          *)
            [ -n "$wrapped" ] && continue
            break
            ;;
        esac
      elif [ "$first" = cd ]; then
        enter "$w" "$cddir"
        cddir=$dir
        break
      elif [ -z "$sub" ]; then
        case $prev in
          -C)
            enter "$w" "$gitdir"
            gitdir=$dir
            prev=""
            continue
            ;;
          -c | --git-dir | --work-tree | --namespace | --config-env | --super-prefix)
            prev=""
            continue
            ;;
        esac
        if [[ $w != -* ]]; then
          sub=$w
          [ "$sub" = commit ] && dir=$gitdir && return 0
          case $sub in merge | cherry-pick | revert | rebase | am) ;; *) break ;; esac
        fi
      elif [ "$w" = --continue ]; then
        dir=$gitdir
        return 0
      fi
      prev=$w
    done
    # Split at every list operator, group and command substitution, with each
    # subshell paren on a line of its own; quotes dropped, so
    # `bash -c "git commit"` reads as a commit
  done < <(sed -E "s/[;&|{}\`]/\n/g; s/[()]/\n&\n/g; s/[\"']//g" <<< "$1")
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
notes=()
if grep -q '^bin/claude-multipass$' <<< "$changed" && ! grep -Eq '^(README\.md|docs/)' <<< "$changed"; then
  notes+=("Changed: bin/claude-multipass. Neither README.md nor docs/ is changed; the docs-mirror rule expects a doc edit in the same commit.")
fi
if grep -Eq '^(bin/|app/Sources/)' <<< "$changed" && ! grep -q '^CHANGELOG\.md$' <<< "$changed"; then
  notes+=("Changed: bin/ or app/Sources/ with no CHANGELOG.md change; a user-visible change adds its line under ## Unreleased in the same PR.")
fi
[ ${#notes[@]} -gt 0 ] || exit 0
jq -cn --arg c "${notes[*]}" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c}}'
