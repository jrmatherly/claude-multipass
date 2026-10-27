---
paths:
  - 'test/**'
  - '.claude/hooks/**'
---

# Testing

## The self-check, `test/claude-multipass.sh`

One bash script, run by `pnpm check` and on its own (`bash test/claude-multipass.sh`). It exits 1 at the first failed assertion, naming it with the expected and actual values, and prints `ok: <name>` per passing case. `set -euo pipefail`, a temp dir removed by an `EXIT` trap.

Helpers:

- `check <name> <expected> <actual>`: string equality, so pass the actual value as `"$(...)"`.
- `check_true <name> <command...>`: the command's exit status.
- `exit_code <command...>`: prints the status, output discarded, for `check "..." 3 "$(exit_code cda sync)"` (a refusal exits 3).
- `cda`: runs the script under test.

Isolation, so no case can touch the real Desktop:

- `CLAUDE_DESKTOP_DIR`, `CLAUDE_MULTIPASS_DIR`, `CLAUDE_CLI_CONFIG` (`$tmp/claude.json`) and `CLAUDE_CLI_HOME` (`$tmp/claude-home`) point into the temp dir; `HOME` stays untouched. The script reads all four, and `migrate_store` never runs when `CLAUDE_MULTIPASS_DIR` is set.
- Stubs on PATH: `pgrep` exits 1 (Desktop "not running", so the quit is a no-op) or 0 for the refusal cases; `osascript`, `pkill` and `open` append their arguments to `$tmp/calls` (so "relaunched" is `open -a Claude` in that file and "not launched" is the file missing); `fzf` is rewritten per case (pick a row, exit 130 for esc); `security` is stateful: items live in `$tmp/keychain/<service>/<account>`, `add-generic-password -X <hex>` decodes the hex into one, from a `security -i` stdin line or from argv, `find-generic-password -w` prints it (as hex when it holds a non-printable byte, like the real tool) or exits 44, `delete-generic-password` exits 44 when absent, the `Claude Safe Storage` read answers the fixture password for `usage`, and `SECURITY_FAIL_ADD` and `SECURITY_FAIL_FIND` make a write or the CLI item's read fail; it logs every argv and every stdin line to `$tmp/security-calls` (the `doctor` case asserts the line count does not grow, the token cases that no token appears there, the route cases which of `stdin` and argv carried a write); `kc_get`, `kc_put <service> <account> <value>` and `kc_delete` are the fixture's helpers; `curl` records its arguments and stdin to `$tmp/curl-args` and prints a fixture body plus an HTTP code. No app is quit or launched, no Keychain or network is touched.
- Fixture layout: `$d` is the Desktop folder with a tab-indented `config.json` carrying non-login keys (`theme`, `windowBounds`, a UTF-8 string) that must survive byte-identical; `$p/<name>/` profiles; `$b/` backups; `$s/<account>/<org>/local_*.json` pointers with `lastActivityAt`, a `deleted_*` tombstone and an mtime-only pair for the fallback. `$tmp/claude.json` is the CLI's config file, `$tmp/claude-home` its home (the lock dirs), `$tmp/keychain/` the stub's items.
- The `usage` case encrypts a fixture token cache the way the app does (`v10` + AES-128-CBC with the PBKDF2 key of the stub password, IV 16 spaces, base64) and asserts the token never appears in `curl`'s argv or in the output.
- The migration case runs with `CLAUDE_MULTIPASS_DIR` unset and `XDG_CONFIG_HOME` pointed at a temp home, not `HOME`: tools on PATH (jq, fzf, python3) read their own config from `HOME`, and changing it would change their behaviour mid-test.
- A real terminal for the bare invocation comes from `script -q /dev/null`.
- The Raycast cases run `raycast/*.sh`, which put Homebrew's bin first on PATH and run `$CLAUDE_MULTIPASS_BIN`, else `claude-multipass` by name. The fixture exports `CLAUDE_MULTIPASS_BIN` as the checkout's script, and the Raycast switch case asserts its CLI write reached the `security` stub. Without it an installed tool would run against the fixture environment and, with a version that reaches the Keychain some other way, the real Keychain.

Rules:

- Every new command, option or refusal gets a case, and so does every reproduced defect (the `--force` refusals, the empty pointer set under bash 3.2, the mtime prefilter hiding a newer `lastActivityAt`).
- Assert what the user observes: file contents, modes, exit codes, printed lines, which stubs were called. Not internals.
- bash 3.2 is the target (the shebang is `/bin/bash`). It mis-parses escaped quotes nested in `$(...)`, so build such strings in a variable first. BSD tools: `stat -f %Lp`, `date -r`, no `head -n -N`.

## The hook self-checks

Each hook in `.claude/hooks/` has a `test-<hook>.sh` beside it, and `test-settings.sh` checks the wiring in `.claude/settings.json`, all run by `pnpm check`:

- `test-lint-edited.sh` feeds `lint-edited.sh` sample PostToolUse payloads against the real checkout: a Markdown file gets formatted, a bash syntax error exits 2, a missing file, a gitignored file and a file in a repo without this hook are skipped, a file in this checkout is linted whatever `CLAUDE_PROJECT_DIR` says (the hook scopes by the file's own checkout, since that variable stays at the session root inside a worktree), a non-bash `bin/` file is left unmodified, a Serena `relative_path` works, a `.sh` outside the gate's list is formatted but not shellchecked, a `bin/` script, `raycast/*.sh` or `scripts/*.sh` with a warning exits 2, a worktree of a throwaway repo whose copy of the hook differs gets the payload handed to its copy (a stub that records stdin, so a branch editing the hook lints with its own version), and a differing copy in another repo is never run.
- `test-lint-bash-edits.sh` feeds `lint-bash-edits.sh` payloads with and without `tool_response.bashEditDiff` (Claude Code records that list in every permission mode only because `.claude/settings.json` sets `bashEditDiffEnabled`; without it, only auto and bypass mode sessions carry it): a `skipped` list is ignored, more than 25 files asks for `pnpm check` instead of linting, each listed file (paths with spaces included) reaches `lint-edited.sh`, gitignored and deleted files are skipped, a missing or crashing `lint-edited.sh` is handled, and a string `tool_response` is not an error.
- `test-settings.sh` checks `.claude/settings.json` with `jq`. `bashEditDiffEnabled` is true. `PreToolUse` has one `Bash` entry, a single `commit-gate.sh` hook with `onFailure` `block`. The `PostToolUse` matcher that runs `lint-edited.sh` matches `Edit`, `Write` and `mcp__serena__replace_content` and not `Bash`, and a `Bash` entry runs `lint-bash-edits.sh`. Every hook command is a `${CLAUDE_PROJECT_DIR}` path to an executable file in the checkout. Every `allow` and `ask` entry is a `Bash(` rule, `ask` holds `switch`, `add`, `save`, `remove`, `rename`, `sync` and `usage` under all three spellings of the tool (`claude-multipass`, `bin/`, `./bin/`), `allow` holds `Bash(pnpm check *)`, and there is no `deny` rule.
- `test-commit-gate.sh` builds a throwaway git repo that ships a copy of the hook and stubs `pnpm` to exit per a state file. It checks that a non-commit command runs no check, a failing check blocks with exit 2, the commit forms it must gate (`cd` then commit, `git -C`, env prefixes, chains) are gated and the others are not, the docs-mirror reminder appears when `bin/claude-multipass` changed alone and not when `docs/` changed too, a worktree of the repo whose copy of the hook differs is gated by that copy (a failing check blocks), a differing copy in another repo is never run, and a foreign repo or one without the hook is never gated.

A change to a hook edits its self-check in the same commit. The hooks run inside Claude Code only; the self-checks are how they get exercised in CI.
