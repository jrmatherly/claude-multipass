# Conventions

## Shell

- `set -euo pipefail`, inline `tput` helpers `info`/`warning`/`fail`, no sourced library, single file.
- Comments explain a non-obvious why only (macOS quirk, bash 3.2 limit, app file format). No what-comments, no history.
- Header comment block is the tldr page: one `- description:` line plus a backticked command per entry, then `---` and mechanism notes. Keep it in sync with behaviour.
- Every `bin/` file must have a comment on line 2 (the gate checks).

## bash 3.2 traps

- Escaped quotes nested inside `$(...)` mis-parse: build the string in a variable first.
- No associative arrays, no `${var,,}`, no `mapfile`. Empty globs stay literal (used deliberately in `test/check.sh`).
- Uppercase vars that are only read must be `${VAR:-}` or shellcheck fails.

## Tests (`.claude/rules/testing.md` has the full structure)

- Helpers `check`, `check_true`, `exit_code`, `cda`. Assert user-observable things: file bytes, modes, exit codes, printed lines, which stubs were called.
- Stubs on PATH replace `pgrep`, `osascript`, `pkill`, `open`, `fzf`, `security`, `curl`. Fixture dirs via `CLAUDE_DESKTOP_DIR` and `CLAUDE_MULTIPASS_DIR`; migration case uses `XDG_CONFIG_HOME`, never `HOME`.
- Hook change edits its `test-<hook>.sh` in the same commit.

## Prose and git

- Docs, comments, replies: no em-dashes, short declarative sentences, sentence-case headings, straight quotes.
- Commit subjects: short, imperative, sentence case, no conventional-commit prefix.
- Never commit code to `main`: every code change goes on its own branch in its own git worktree and lands through a PR after CI. Docs-only commits (Markdown under README, CHANGELOG, docs/, CLAUDE.md, .claude/rules, .claude/skills, .serena/memories) go directly on `main`. Standing approval: once `pnpm check` passes and the change is what was asked, commit and push without asking, opening the PR on a branch; merging is Jason's (`CLAUDE.md` Custom Notes).
