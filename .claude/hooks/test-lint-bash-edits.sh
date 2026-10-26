#!/bin/bash
#
# Self-check for lint-bash-edits.sh. Run: .claude/hooks/test-lint-bash-edits.sh

set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd -P)
cd "$root"
hook=.claude/hooks/lint-bash-edits.sh
# Files to lint live in $tmp (a tracked path, so lint-edited.sh sees them);
# captured stderr lives under private/, which git ignores
tmp=hooktest-$$
scratch=private/hooktest-$$
mkdir -p "$tmp" "$scratch"
err=$scratch/err
trap 'rm -rf "$root/$tmp" "$root/$scratch"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}
# A PostToolUse Bash payload whose bashEditDiff lists the given absolute paths
payload() {
  jq -cn '$ARGS.positional as $p | {tool_name: "Bash", tool_input: {command: "true"},
    tool_response: {stdout: "", stderr: "", bashEditDiff: {changedFiles: $p, moreFiles: 0}}}' --args "$@"
}
# Feed a payload on stdin to the hook; stderr to $err
lint() {
  CLAUDE_PROJECT_DIR=$root "$hook" 2> "$err"
}
expect_rc() {
  [ "$1" -eq "$2" ] || fail "$3: expected exit $2, got $1"
}

# 1. A listed shell file with a syntax error → exit 2, problem names the file
printf '#!/bin/bash\nif then\n' > "$tmp/b.sh"
rc=0
payload "$root/$tmp/b.sh" | lint || rc=$?
expect_rc "$rc" 2 "syntax error"
grep -q "$tmp/b.sh" "$err" || fail "syntax error: file not named in stderr"

# 2. No bashEditDiff in the payload (older Claude Code, non-git cwd, recording off) → exit 0
printf '{"tool_name":"Bash","tool_input":{"command":"true"},"tool_response":{"stdout":"","stderr":""}}' \
  | lint || fail "no bashEditDiff: non-zero exit"

# 3. skipped: true (git checkout/stash moved the tree) → exit 0 even with files listed
jq -cn --arg p "$root/$tmp/b.sh" '{tool_name: "Bash", tool_input: {command: "git checkout x"},
  tool_response: {bashEditDiff: {changedFiles: [$p], skipped: true}}}' \
  | lint || fail "skipped: non-zero exit"

# 4. More than 25 listed files → one line pointing at pnpm check, exit 2, nothing linted
bulk=()
for i in $(seq 1 26); do
  printf '# T\n\n* c\n' > "$tmp/bulk$i.md"
  bulk+=("$root/$tmp/bulk$i.md")
done
rc=0
payload "${bulk[@]}" | lint || rc=$?
expect_rc "$rc" 2 "bulk"
grep -q 'pnpm check' "$err" || fail "bulk: stderr does not point at pnpm check"
grep -q '^\* c$' "$tmp/bulk1.md" || fail "bulk: files were linted one by one"

# 5. A listed unformatted Markdown file gets formatted, exit 0
printf '# T\n\n* a\n' > "$tmp/a.md"
payload "$root/$tmp/a.md" | lint || fail "markdown: non-zero exit"
grep -q '^- a$' "$tmp/a.md" || fail "markdown: not formatted"

# 6. A path with a space is linted and formatted
printf '# T\n\n* b\n' > "$tmp/a b.md"
payload "$root/$tmp/a b.md" | lint || fail "path with space: non-zero exit"
grep -q '^- b$' "$tmp/a b.md" || fail "path with space: not formatted"

# 7. A listed gitignored file (private/) is skipped by lint-edited.sh → exit 0
printf '#!/bin/bash\nif then\n' > "$scratch/bad.sh"
payload "$root/$scratch/bad.sh" | lint || fail "gitignored file: should be skipped"

# 8. A listed file the command deleted → exit 0
payload "$root/$tmp/gone.sh" | lint || fail "deleted file: non-zero exit"

# 9. A project without lint-edited.sh (CLAUDE_PROJECT_DIR elsewhere) → exit 0, nothing run
payload "$root/$tmp/b.sh" | CLAUDE_PROJECT_DIR=$root/$tmp "$hook" 2> "$err" || fail "no lint-edited.sh: non-zero exit"

# 10. lint-edited.sh failing for another reason (exit 1) is surfaced, not swallowed → exit 2, its output in stderr
mkdir -p "$tmp/.claude/hooks"
printf '#!/bin/bash\ncat > /dev/null\necho boom\nexit 1\n' > "$tmp/.claude/hooks/lint-edited.sh"
chmod +x "$tmp/.claude/hooks/lint-edited.sh"
rc=0
payload "$root/$tmp/b.sh" | CLAUDE_PROJECT_DIR=$root/$tmp "$hook" 2> "$err" || rc=$?
expect_rc "$rc" 2 "crashing lint-edited.sh"
grep -q boom "$err" || fail "crashing lint-edited.sh: output not in stderr"

# 11. tool_response of an unexpected shape → exit 0 and silence, no jq error
printf '{"tool_name":"Bash","tool_input":{"command":"true"},"tool_response":"text"}' \
  | lint || fail "string tool_response: non-zero exit"
[ ! -s "$err" ] || fail "string tool_response: stderr not empty: $(cat "$err")"

# 12. shared: true (another Bash call ran at the same time) is best effort, still linted → exit 2
rc=0
jq -cn --arg p "$root/$tmp/b.sh" '{tool_name: "Bash", tool_input: {command: "true"},
  tool_response: {bashEditDiff: {changedFiles: [$p], shared: true}}}' | lint || rc=$?
expect_rc "$rc" 2 "shared"

echo "lint-bash-edits: all checks passed"
