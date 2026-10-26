# Suggested commands

- `pnpm check`: the full gate (syntax, shellcheck, prettier check, fixture self-check, hook self-checks, bin header rule). Exports `LC_ALL=en_US.UTF-8` itself.
- `pnpm format`: prettier write over the gate's globs.
- One file: `bash -n <f> && shellcheck --severity=warning <f> && node_modules/.bin/prettier --check <f>`.
- `bash test/claude-multipass.sh`: fixture self-check alone; prints `ok: <case>` per case, exits 1 naming the first failure. Safe: never touches the real Desktop.
- `bash .claude/hooks/test-<hook>.sh`: one hook self-check.
- Safe tool invocations from an agent: `bin/claude-multipass list|show <name>|current|--help`. Everything else quits the app or touches Keychain: leave to the user.
- Docs audit: `/docs-audit` skill (read-only auditor agent).

Darwin specifics the code relies on: `stat -f %Lp` (mode), `date -r`, no `head -n -N`, `sed -i ''`, `script -q /dev/null` for a fake tty in tests.
