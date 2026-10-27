#!/bin/bash
#
# Self-check for commit-gate.sh. Run: .claude/hooks/test-commit-gate.sh

set -euo pipefail

hook=$(cd "$(dirname "$0")" && pwd -P)/commit-gate.sh
tmp=$(mktemp -d "${TMPDIR:-/tmp}/commit-gate.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
proj=$tmp/proj
STATE=$tmp/state
mkdir -p "$proj/test" "$proj/.claude/hooks" "$STATE" "$tmp/bin"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# The gate's "this is the repo" markers, committed so the tree starts clean
: > "$proj/test/check.sh"
chmod +x "$proj/test/check.sh"
cp "$hook" "$proj/.claude/hooks/commit-gate.sh"
git -C "$proj" init -q
git -C "$proj" add test/check.sh .claude/hooks/commit-gate.sh
git -C "$proj" -c user.name=test -c user.email=test@example.com \
  -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -qm init

# Stub pnpm: records that the check ran, exits with $STATE/check-rc
cat > "$tmp/bin/pnpm" << EOF
#!/bin/bash
touch "$STATE/check-ran"
echo "stub check output"
exit "\$(cat "$STATE/check-rc" 2> /dev/null || echo 0)"
EOF
chmod +x "$tmp/bin/pnpm"

# A second repo with test/check.sh but no hook copy, as a -C target
other=$tmp/other
mkdir -p "$other/test"
: > "$other/test/check.sh"
git -C "$other" init -q

# Feed the hook a PreToolUse payload with cwd $2 (default: the project);
# sets out (stdout) and rc
run() {
  local payload
  payload=$(jq -cn --arg c "$1" --arg d "${2:-$proj}" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')
  rc=0
  out=$(CLAUDE_PROJECT_DIR=$proj PATH="$tmp/bin:$PATH" "$hook" <<< "$payload" 2> /dev/null) || rc=$?
}
touch_path() {
  mkdir -p "$(dirname "$proj/$1")"
  echo line >> "$proj/$1"
}

# 1. a non-commit command never runs the check, exit 0
run 'gh pr view --json commits'
[ "$rc" -eq 0 ] && [ ! -e "$STATE/check-ran" ] || fail "non-commit ran the check"
# 2. a failing check blocks the commit
echo 1 > "$STATE/check-rc"
run 'git commit -m "x"'
[ "$rc" -eq 2 ] || fail "failing check: expected exit 2, got $rc"
# 3. every commit spelling gates
echo 0 > "$STATE/check-rc"
for c in 'git -C . commit --amend' 'git -c commit.gpgsign=false commit' '/usr/bin/git commit' 'GIT_EDITOR=true git commit' 'git add x && git commit -m y' 'echo x && git commit' \
  'env git commit -m x' 'env -i GIT_EDITOR=true git commit' 'command git commit -m x' 'time git commit -m x' 'nohup git commit -m x' 'git --no-pager commit -m x' \
  'bash -c "git commit -m x"' "sh -c 'git commit'" \
  'git merge --continue' 'git cherry-pick --continue' 'git revert --continue' 'git rebase --continue' 'git am --continue' \
  "git -C $other status; git commit -m x"; do
  rm -f "$STATE/check-ran"
  run "$c"
  [ -e "$STATE/check-ran" ] || fail "not gated: $c"
done
# 4. mentions of the word do not gate, nor do commands whose commit tree is not on disk yet
for c in 'pre-commit run' 'echo "git commit"' 'git commit-tree HEAD^{tree}' 'git log --grep commit' 'git show commit' 'git -c commit.gpgsign=false log' \
  'git merge feature' 'git merge --abort' 'git rebase main' 'git cherry-pick abc' 'git revert HEAD' 'git pull'; do
  rm -f "$STATE/check-ran"
  run "$c"
  [ ! -e "$STATE/check-ran" ] || fail "wrongly gated: $c"
done
# 5. a passing check with bin/claude-multipass changed and no doc warns
touch_path bin/claude-multipass
run 'git commit -m "x"'
[ "$rc" -eq 0 ] && grep -q README <<< "$out" || fail "docs-mirror warning missing"
# 6. a docs/ file changed alongside silences the warning
touch_path docs/x.md
run 'git commit -m "x"'
[ "$rc" -eq 0 ] && [ -z "$out" ] || fail "warning printed with docs/ changed"
# 7. from outside, a leading cd (absolute or relative) or git -C targets the repo
for c in "cd $proj && git commit -m x" 'cd proj; git commit -m x' "git -C $proj commit -m x"; do
  rm -f "$STATE/check-ran"
  run "$c" "$tmp"
  [ -e "$STATE/check-ran" ] || fail "not gated from outside: $c"
done
# 8. git -C into a repo without the hook copy is not gated, even from this repo
rm -f "$STATE/check-ran"
run "git -C $other commit -m x"
[ "$rc" -eq 0 ] && [ ! -e "$STATE/check-ran" ] || fail "-C into a repo without the hook was gated"
# 8a. a worktree of this repo whose hook copy differs is gated by that copy
git -C "$proj" worktree add -q "$tmp/wt"
# The edited copy records that it ran; mode 0644, as a tool that drops the bit leaves it
sed -i '' "1a\\
touch $STATE/copy-ran
" "$tmp/wt/.claude/hooks/commit-gate.sh"
chmod 644 "$tmp/wt/.claude/hooks/commit-gate.sh"
echo 1 > "$STATE/check-rc"
rm -f "$STATE/check-ran"
run 'git commit -m x' "$tmp/wt"
[ "$rc" -eq 2 ] && [ -e "$STATE/copy-ran" ] && [ -e "$STATE/check-ran" ] || fail "worktree with a differing hook copy: expected its copy to block with exit 2, got $rc"
echo 0 > "$STATE/check-rc"
# 8b. a differing copy in another repo is never run
mkdir -p "$other/.claude/hooks"
printf '#!/bin/bash\ntouch %q\n' "$STATE/foreign-ran" > "$other/.claude/hooks/commit-gate.sh"
chmod +x "$other/.claude/hooks/commit-gate.sh"
run "git -C $other commit -m x"
[ "$rc" -eq 0 ] && [ ! -e "$STATE/foreign-ran" ] || fail "another repo's hook copy was run"
# 9. a commit in a repo without test/check.sh is not gated
rm "$proj/test/check.sh"
rm -f "$STATE/check-ran"
run 'git commit -m "x"'
[ "$rc" -eq 0 ] && [ ! -e "$STATE/check-ran" ] || fail "foreign repo was gated"
# 10. a repo with test/check.sh but without this hook is not gated
: > "$proj/test/check.sh"
rm "$proj/.claude/hooks/commit-gate.sh"
rm -f "$STATE/check-ran"
run 'git commit -m "x"'
[ "$rc" -eq 0 ] && [ ! -e "$STATE/check-ran" ] || fail "repo without the hook was gated"

echo "commit-gate: all checks passed"
