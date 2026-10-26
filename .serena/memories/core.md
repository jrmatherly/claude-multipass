# claude-multipass: core

One bash 3.2 script, `bin/claude-multipass`, that switches the Claude Desktop app between saved claude.ai accounts on one Mac and keeps every account's Claude Code sessions listed after a switch. macOS only.

`CLAUDE.md` is the authoritative project guide (overview, storage model, safety rails, release). Read it before anything else; these memories only add what it does not spell out.

## Source map

- `bin/claude-multipass`: the whole tool. Header comment block = the tldr page; `usage()` = `--help`. Functions: tput helpers, `jq_write`, Desktop lifecycle (`desktop_quit`, `desktop_launch`, `wait_gone`), profile ops (`profile_save`, `profile_restore`, `backup_login`, `copy_cookies`), `index_sync` (Code-tab pointer copy), `usage_report` (`safe_storage_key`, `access_token`), then command dispatch at the bottom.
- `test/claude-multipass.sh`: fixture self-check, stubs every external binary. `test/check.sh`: the gate (`pnpm check`).
- `raycast/*.sh`: three Raycast script commands calling the tool by name.
- `.claude/hooks/*.sh` with `test-*.sh` beside each: lint-on-edit and the commit gate.
- `.claude/rules/desktop-internals.md`: verified Desktop and CLI internals with evidence labels. Never re-derive them.
- `docs/claude-multipass.md` (user mechanism doc), `docs/research.md` (scrubbed research). `private/` is git-ignored and never published.

## Invariants

- Never run `save`, `add`, `switch`, `remove`, `sync` or `usage` against the real Desktop from an agent. `list`, `show`, `current` are read-only.
- A behaviour change edits `README.md` or `docs/` in the same commit; the commit gate reminds.
- Every new command, option or refusal gets a case in `test/claude-multipass.sh`.
- Refusals lifted only by `--force` (listed in `CLAUDE.md`); reviewer-rejected changes are listed in `.claude/rules/safety-and-terms.md`.

Further: `mem:tech_stack` (runtime and tool pins), `mem:suggested_commands` (what to run), `mem:conventions` (style and bash 3.2 traps), `mem:task_completion` (the done gate).
