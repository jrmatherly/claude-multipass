#!/bin/bash
#
# Self-check for lint-edited.sh. Run: .claude/hooks/test-lint-edited.sh

set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd -P)
cd "$root"
hook=.claude/hooks/lint-edited.sh
tmp=hooktest-$$
# Gated fixtures sit in the real bin/ and raycast/, since scope is by path
gated_bin=bin/hooktest-$$
swift_bin=bin/hooktest-swift-$$
gated_raycast=raycast/hooktest-$$.sh
gated_scripts=scripts/hooktest-$$.sh
mkdir -p "$tmp" private
trap 'rm -rf "$root/$tmp" "$root/private/hooktest-$$.sh" "$root/$gated_bin" "$root/$swift_bin" "$root/$gated_raycast" "$root/$gated_scripts"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}
# Feed the hook a PostToolUse payload; prints nothing, returns the hook's exit code
run() {
  printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$1" \
    | CLAUDE_PROJECT_DIR=$root "$hook" 2> /dev/null
}

# 1. Unformatted Markdown gets formatted, exit 0
printf '# T\n\n* a\n' > "$tmp/a.md"
run "$root/$tmp/a.md" || fail "markdown: non-zero exit"
grep -q '^- a$' "$tmp/a.md" || fail "markdown: not formatted"

# 2. Bash syntax error → exit 2
printf '#!/bin/bash\nif then\n' > "$tmp/b.sh"
set +e
run "$root/$tmp/b.sh"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "bash syntax error: expected exit 2, got $rc"

# 3. Paths outside the project and missing paths are ignored
run /etc/hosts || fail "outside path: non-zero exit"
run "$root/$tmp/missing.md" || fail "missing path: non-zero exit"

# 4. Gitignored files are skipped (private/ is gitignored)
printf '#!/bin/bash\nif then\n' > "private/hooktest-$$.sh"
run "$root/private/hooktest-$$.sh" || fail "gitignored file: should be skipped"

# 5. Extensionless non-bash script in bin/ (Swift) is skipped untouched
printf '#!/usr/bin/env swift\nlet x = $(1)\n' > "$swift_bin"
cp "$swift_bin" "$tmp/swift.orig"
run "$root/$swift_bin" || fail "swift bin: non-zero exit"
cmp -s "$swift_bin" "$tmp/swift.orig" || fail "swift bin: file was modified"

# 6. Serena's edit tools send a project-relative path
printf '# T\n\n* b\n' > "$tmp/e.md"
printf '{"tool_name":"mcp__serena__replace_content","tool_input":{"relative_path":"%s"}}' "$tmp/e.md" \
  | CLAUDE_PROJECT_DIR=$root "$hook" 2> /dev/null || fail "serena relative_path: non-zero exit"
grep -q '^- b$' "$tmp/e.md" || fail "serena relative_path: not formatted"

# 7. A .sh file outside pnpm check's shellcheck set is formatted only → exit 0
printf 'cat $(ls)\n' > "$tmp/loose.sh"
run "$root/$tmp/loose.sh" || fail "ungated .sh: should not be shellchecked"

# 8. A bash script in bin/, a raycast/*.sh and a scripts/*.sh are shellchecked like the gate does
for f in "$gated_bin" "$gated_raycast" "$gated_scripts"; do
  printf '#!/bin/bash\ncat $(ls)\n' > "$f"
  set +e
  run "$root/$f"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "$f: expected exit 2, got $rc"
done

# 9. A file in this checkout is linted whatever CLAUDE_PROJECT_DIR says: a
# worktree session keeps the session root in that variable
printf '# T\n\n* c\n' > "$tmp/w.md"
printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$root/$tmp/w.md" \
  | CLAUDE_PROJECT_DIR=/nonexistent "$hook" 2> /dev/null || fail "other project dir: non-zero exit"
grep -q '^- c$' "$tmp/w.md" || fail "other project dir: file in this checkout not formatted"

# 10. A file in a repo without this hook is left alone
foreign=$(mktemp -d "${TMPDIR:-/tmp}/lint-edited.XXXXXX")
repos=$(mktemp -d "${TMPDIR:-/tmp}/lint-edited.XXXXXX")
trap 'rm -rf "$root/$tmp" "$root/private/hooktest-$$.sh" "$root/$gated_bin" "$root/$swift_bin" "$root/$gated_raycast" "$root/$gated_scripts" "$foreign" "$repos"' EXIT
git -C "$foreign" init -q
printf '# T\n\n* d\n' > "$foreign/f.md"
run "$foreign/f.md" || fail "foreign repo: non-zero exit"
grep -q '^\* d$' "$foreign/f.md" || fail "foreign repo: file was modified"

# 11. A worktree whose copy differs runs its copy with the payload: a
# throwaway repo ships the hook, its second worktree a stub recording stdin.
# No node_modules there, so the marker, not formatting, proves which ran.
proj=$repos/proj
mkdir -p "$proj/test" "$proj/.claude/hooks"
: > "$proj/test/check.sh"
cp "$hook" "$proj/.claude/hooks/lint-edited.sh"
git -C "$proj" init -q
git -C "$proj" add test/check.sh .claude/hooks/lint-edited.sh
git -C "$proj" -c user.name=test -c user.email=test@example.com \
  -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -qm init
git -C "$proj" worktree add -q "$repos/wt" 2> /dev/null
marker=$repos/marker
stub() {
  printf '#!/bin/bash\ncat >> %q\n' "$marker" > "$1/.claude/hooks/lint-edited.sh"
  chmod +x "$1/.claude/hooks/lint-edited.sh"
}
stub "$repos/wt"
printf '# T\n\n* g\n' > "$repos/wt/g.md"
printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$repos/wt/g.md" \
  | CLAUDE_PROJECT_DIR=$proj "$hook" 2> /dev/null || fail "worktree copy: non-zero exit"
grep -q "$repos/wt/g.md" "$marker" 2> /dev/null || fail "worktree copy: not delegated to"

# 12. A different repo's differing copy is never run
rm -f "$marker"
mkdir -p "$repos/other/.claude/hooks"
git -C "$repos/other" init -q
stub "$repos/other"
printf '# T\n\n* h\n' > "$repos/other/h.md"
printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$repos/other/h.md" \
  | CLAUDE_PROJECT_DIR=$proj "$hook" 2> /dev/null || fail "other repo copy: non-zero exit"
[ ! -e "$marker" ] || fail "other repo copy: delegated to"
grep -q '^\* h$' "$repos/other/h.md" || fail "other repo copy: file was modified"

echo "lint-edited: all checks passed"
