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

- `CLAUDE_DESKTOP_DIR` and `CLAUDE_MULTIPASS_DIR` point into the temp dir. The script reads both, and `migrate_store` never runs when `CLAUDE_MULTIPASS_DIR` is set.
- Stubs on PATH: `pgrep` exits 1 (Desktop "not running", so the quit is a no-op) or 0 for the refusal cases; `osascript`, `pkill` and `open` append their arguments to `$tmp/calls` (so "relaunched" is `open -a Claude` in that file and "not launched" is the file missing); `fzf` is rewritten per case (pick a row, exit 130 for esc); `security` prints a fixture password and logs `security <args>` to `$tmp/calls` (the `doctor` case asserts it is never called); `curl` records its arguments and stdin to `$tmp/curl-args` and prints a fixture body plus an HTTP code. No app is quit or launched, no Keychain or network is touched.
- Fixture layout: `$d` is the Desktop folder with a tab-indented `config.json` carrying non-login keys (`theme`, `windowBounds`, a UTF-8 string) that must survive byte-identical; `$p/<name>/` profiles; `$b/` backups; `$s/<account>/<org>/local_*.json` pointers with `lastActivityAt`, a `deleted_*` tombstone and an mtime-only pair for the fallback.
- The `usage` case encrypts a fixture token cache the way the app does (`v10` + AES-128-CBC with the PBKDF2 key of the stub password, IV 16 spaces, base64) and asserts the token never appears in `curl`'s argv or in the output.
- The migration case runs with `CLAUDE_MULTIPASS_DIR` unset and `XDG_CONFIG_HOME` pointed at a temp home, not `HOME`: tools on PATH (jq, fzf, python3) read their own config from `HOME`, and changing it would change their behaviour mid-test.
- A real terminal for the bare invocation comes from `script -q /dev/null`.

Rules:

- Every new command, option or refusal gets a case, and so does every reproduced defect (the `--force` refusals, the empty pointer set under bash 3.2, the mtime prefilter hiding a newer `lastActivityAt`).
- Assert what the user observes: file contents, modes, exit codes, printed lines, which stubs were called. Not internals.
- bash 3.2 is the target (the shebang is `/bin/bash`). It mis-parses escaped quotes nested in `$(...)`, so build such strings in a variable first. BSD tools: `stat -f %Lp`, `date -r`, no `head -n -N`.

## The hook self-checks

Each hook in `.claude/hooks/` has a `test-<hook>.sh` beside it, run by `pnpm check`:

- `test-lint-edited.sh` feeds `lint-edited.sh` sample PostToolUse payloads against the real checkout: a Markdown file gets formatted, a bash syntax error exits 2, a path outside the project, a missing file and a gitignored file are skipped, a non-bash `bin/` file is left unmodified, a Serena `relative_path` works, a `.sh` outside the gate's list is formatted but not shellchecked, and a `bin/` script, `raycast/*.sh` or `scripts/*.sh` with a warning exits 2.
- `test-lint-bash-edits.sh` feeds `lint-bash-edits.sh` payloads with and without `tool_response.bashEditDiff`: a `skipped` list is ignored, more than 25 files asks for `pnpm check` instead of linting, each listed file (paths with spaces included) reaches `lint-edited.sh`, gitignored and deleted files are skipped, a missing or crashing `lint-edited.sh` is handled, and a string `tool_response` is not an error.
- `test-commit-gate.sh` builds a throwaway git repo that ships a copy of the hook and stubs `pnpm` to exit per a state file. It checks that a non-commit command runs no check, a failing check blocks with exit 2, the commit forms it must gate (`cd` then commit, `git -C`, env prefixes, chains) are gated and the others are not, the docs-mirror reminder appears when `bin/claude-multipass` changed alone and not when `docs/` changed too, and a foreign repo or one without the hook is never gated.

A change to a hook edits its self-check in the same commit. The hooks run inside Claude Code only; the self-checks are how they get exercised in CI.
