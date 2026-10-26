# Task completion

Before calling a change done:

1. `pnpm check` passes (the commit-gate hook runs it on every `git commit` anyway and blocks on failure).
2. If `bin/claude-multipass` behaviour changed: `README.md` or `docs/` updated in the same change, and the header tldr block still accurate.
3. New command, option, refusal or reproduced defect has a case in `test/claude-multipass.sh`; a hook change has its `test-<hook>.sh` updated.
4. Safety rails in `CLAUDE.md` and `.claude/rules/safety-and-terms.md` still hold (no daemon, no token on a command line, add-only `index_sync`, Desktop quit before writes).
5. Release only via `.claude/skills/release/SKILL.md` (CHANGELOG, package.json version, annotated tag, Homebrew formula sha).
