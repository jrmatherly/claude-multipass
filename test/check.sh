#!/bin/bash
#
# The whole gate: shell syntax, ShellCheck, formatting, the tool's fixture
# self-check, the hook self-checks and the bin/ header rule. Run: pnpm check
# A glob that matches nothing stays literal, so a missing script fails here
# instead of being skipped.

set -euo pipefail
# The self-checks grep for UTF-8 glyphs with bracket expressions, which match
# single bytes under the C locale that Claude Code's Bash tool runs in
export LC_ALL=en_US.UTF-8

cd "$(dirname "$0")/.."
# Run directly (not through pnpm), prettier is not on PATH otherwise
PATH=$PWD/node_modules/.bin:$PATH

shell_scripts=(
  bin/claude-multipass
  test/*.sh
  .claude/hooks/*.sh
  raycast/*.sh
)

bash -n "${shell_scripts[@]}"
shellcheck --severity=warning "${shell_scripts[@]}"
prettier --log-level warn --ignore-unknown --check "**/*.{js,cjs,ts,md,json,sh}" "bin/*" ".github/**/*.yml"
# bin/claude-multipass against a fixture Desktop folder (never the real one)
bash test/claude-multipass.sh > /dev/null
# the Claude Code hooks against sample payloads
bash .claude/hooks/test-lint-edited.sh > /dev/null
bash .claude/hooks/test-lint-bash-edits.sh > /dev/null
bash .claude/hooks/test-commit-gate.sh > /dev/null
# Every bin/ file has a comment on line 2
for file in bin/*; do
  sed -n 2p "$file" | grep -q '^#' || {
    echo "check: no header comment on line 2 of $file" >&2
    exit 1
  }
done
