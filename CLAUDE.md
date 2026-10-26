# CLAUDE.md

Guidance for Claude Code in this repository.

## Overview

`bin/claude-multipass` switches the Claude Desktop app between saved claude.ai accounts on one Mac without an email code, and keeps every saved account's Claude Code sessions listed in the Code tab after a switch. One Mac, several accounts (personal, work, a second plan). macOS only (`osascript`, `open`, `security`, Application Support paths). Runs on the system `/bin/bash` 3.2 and needs `jq`. `fzf` is optional (the picker). `usage` also needs `curl`, the system `python3` and `openssl`.

Three Raycast script commands in `raycast/` call the tool by name. `bin/claude-multipass --help` is the command reference; `docs/claude-multipass.md` explains the mechanism for users; `docs/research.md` is the scrubbed research the tool was built from.

## Commands

- `pnpm check` (`test/check.sh`) is the gate. It exports `LC_ALL=en_US.UTF-8` (the self-checks grep for UTF-8 glyphs) and runs `bash -n` and `shellcheck --severity=warning` on `bin/claude-multipass`, `test/*.sh`, `.claude/hooks/*.sh`, `raycast/*.sh` and `scripts/*.sh`; `prettier --check` over `**/*.{js,cjs,ts,md,json,sh}`, `bin/*` and `.github/**/*.yml`; `test/claude-multipass.sh`; the three hook self-checks (`.claude/hooks/test-lint-edited.sh`, `test-lint-bash-edits.sh`, `test-commit-gate.sh`); a check that every `bin/` file has a comment on line 2; that `version=` in the script equals `package.json`; and `swift test --package-path app` (a debug build, about 20 s warm). The app module uses SwiftUI macros whose compiler plugin only Xcode ships, so the gate exports `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` when `xcode-select -p` is the Command Line Tools and Xcode is installed; with the Tools alone the core tests run only with `-Xswiftc -plugin-path -Xswiftc "$(xcode-select -p)/usr/lib/swift/host/plugins/testing"` and the app target does not build. CI (`.github/workflows/check.yml`) runs it on `macos-latest` for PRs and pushes to `main`.
- `pnpm format`: prettier `--write` over the same globs.
- One file: `bash -n <file> && shellcheck --severity=warning <file> && node_modules/.bin/prettier --check <file>`.
- `bash test/claude-multipass.sh`: the fixture self-check, exits 1 naming the first failed assertion. It never touches the real Desktop: `CLAUDE_DESKTOP_DIR` and `CLAUDE_MULTIPASS_DIR` point into a temp dir, and `pgrep`, `osascript`, `pkill`, `open`, `fzf`, `security` and `curl` are stubs on PATH (no app quit or launched, no Keychain, no network). The migration case sets `XDG_CONFIG_HOME` to the temp dir, not `HOME`, because tools on PATH read their own config from `HOME`. Details in `.claude/rules/testing.md`.
- Never run `save`, `add`, `switch`, `remove` or `sync` against the real Desktop folder from an agent: they quit the app and rewrite its login. `.claude/settings.json` asks before `save`, `add`, `switch` and `remove`. `usage` reads the Keychain and prompts the user; leave it to them. `list`, `show` and `current` are read-only.

## Architecture

```text
bin/claude-multipass     the tool, one bash script; its header comment is the tldr page
test/check.sh            pnpm check
test/claude-multipass.sh fixture self-check
raycast/                 claude-account.sh (inline, current name), claude-account-usage.sh (inline, opt-in), switch-claude-account.sh (argument, confirmation)
app/                     the menu bar app, a Swift package: Sources/MultipassCore (models, CLI runner, formatting, settings, state; Foundation only, unit tested), Sources/ClaudeMultipass (AppKit/SwiftUI shell), Tests/
scripts/                 build-app.sh (swift build, bundle, sign, optional DMG), sign-mac-app.sh (copied from ai-kb)
docs/                    claude-multipass.md (how it works, for users), research.md (scrubbed research digest)
.claude/                 settings.json (permissions, hooks), hooks/ (lint and commit gate with self-checks), rules/, skills/, agents/
.github/workflows/       check.yml
private/                 git-ignored research and notes, never published
```

Storage model:

- A Desktop login is three `config.json` keys (`oauth:tokenCache`, `oauth:tokenCacheV2`, `lastKnownAccountUuid`) plus the `Cookies` and `Cookies-journal` files (in `Network/` when that folder exists), all under `~/Library/Application Support/Claude` (`CLAUDE_DESKTOP_DIR` overrides). The app encrypts them with its "Claude Safe Storage" login-Keychain key; the tool copies them as opaque bytes.
- The Code tab lists one `claude-code-sessions/<account>/<org>/local_<id>.json` pointer per session, with no account field inside, so a copied pointer shows the session to another account. A `deleted_<id>` file beside them is a tombstone.
- Transcripts are shared in `~/.claude/projects` and never touched.
- Profiles live in `${CLAUDE_MULTIPASS_DIR:-${XDG_CONFIG_HOME:-~/.config}/claude-multipass}/profiles/<name>/` (`config.json` with the three keys, the cookie files, `meta.json` with `account` and `savedAt`), mode 0600 and 0700. `backups/` beside it holds the login each switch or add replaced (`login-*`, newest ten) and profiles replaced by `save --force` or `remove` (`profile-*`).
- A store left at `~/.config/dotfiles/claude-desktop-accounts` (plus `-backups`) by the tool's earlier life in a dotfiles repo is moved into place once, on the first run that finds it, no new store and no `CLAUDE_MULTIPASS_DIR`.

The verified Desktop and CLI internals, with evidence labels, are in `.claude/rules/desktop-internals.md`. Do not re-derive them.

## Conventions

- Shell style, as in the script: `#!/bin/bash`, `set -euo pipefail`, inline `tput` helpers (`info`, `warning`, `fail`), no sourced library. The header comment block is the tldr page (one `- description:` line and a backticked command per entry, then `---` and the mechanism notes), so keep it accurate when behaviour changes. Comments explain the non-obvious why (a macOS quirk, a bash 3.2 limit, the app's file format), not what the code does.
- Prettier with `prettier-plugin-sh` (`prettier.config.cjs`: `singleQuote`, `semi: false`; Markdown `printWidth: 70`, `proseWrap: never`). ShellCheck at `--severity=warning` with `check-unassigned-uppercase` (`.shellcheckrc`). `.prettierignore` skips `CLAUDE.md`, `.serena/`, `private/`, `.remember/`, `logs/` and `.claude/settings.local.json`; don't hand-format them.
- Prose, in docs, comments and replies: no em-dashes, short declarative sentences, sentence-case headings, straight quotes, facts and paths over adjectives.
- Commit subjects are short, imperative, sentence case, with no conventional-commit prefix.
- Docs mirror behaviour: a change to what the script does edits `README.md` or `docs/` in the same commit. The commit-gate hook (`.claude/hooks/commit-gate.sh`) runs `pnpm check` before every `git commit` and reminds about this when `bin/claude-multipass` changed without a README or docs change.
- Every new command, option or refusal gets a case in `test/claude-multipass.sh`.

## Safety rails

Keep these when changing the script. The rules a reviewer rejects a change for are in `.claude/rules/safety-and-terms.md`.

- Refusals, each lifted only by `--force`: `save` over a profile that holds a different account (the old profile moves to `backups/`); `switch` away from a login that was never saved; `sync` while Desktop runs. `--force` is rejected for any other command. `save` refuses when signed out, before quitting the app.
- `backup_login` copies `config.json` and the cookies into `backups/login-<timestamp>-<pid>` before every merge into `config.json` (`switch`, `add`).
- `index_sync` is add-only: it copies a pointer only when the source is newer (`lastActivityAt`, else mtime), skips any id with a `deleted_*` tombstone, and never deletes or symlinks.
- Desktop is quit before any write (`osascript` quit, then `pkill` after 8 s, fail after 10 s more), and relaunched from the `EXIT` trap so an error midway still brings it back. `--no-relaunch` leaves it quit.
- Never use Desktop's own Log out to change accounts; it may revoke the saved token server-side. `add` signs out locally by deleting the three keys and the cookie files instead.
- `usage` is the one terms-gray-area feature: it decrypts saved tokens with the Keychain key and reads Anthropic's OAuth usage endpoint outside the app. It stays opt-in, read-only, never a trigger for an automatic switch. The CLI runs it only when asked; the menu bar app polls `usage --json` only after the user turns usage on, at an interval of at least 5 minutes, one `security` call per run. The app's snapshot poll (`list --json`) reads `config.json` and `meta.json`, never the Keychain. Still rejected: any automatic switch; usage polling that is on by default or faster than 5 minutes; a launch agent or daemon separate from the user-visible app; reading the Keychain anywhere but inside `usage`. The bearer token goes to `curl` on stdin; the derived AES key is on the `openssl` command line only for the moment of each decrypt.
- Profiles are per Mac: the Safe Storage key is in that Mac's login Keychain, so a copied profile won't decrypt elsewhere.

## Release

`git tag -a vX.Y.Z` after updating `CHANGELOG.md` and `package.json`, then `git push --follow-tags`. The Homebrew formula lives in `github.com/jrmatherly/homebrew-tap` as `Formula/claude-multipass.rb` and needs the new tag's tarball `url` and `sha256`. The exact steps are in `.claude/skills/release/SKILL.md`.

## Path-scoped rules

`.claude/rules/` loads when matching files are touched: `desktop-internals.md` (the verified facts, on `bin/**`, `test/**`, `raycast/**`), `safety-and-terms.md` (rails and terms posture, on `bin/**`, `docs/**`, `README.md`), `testing.md` (self-check structure, on `test/**`, `.claude/hooks/**`). Skills: `release`, `docs-audit` (forks the `docs-auditor` agent, which reads and runs read-only commands, never edits).

## Custom Notes

Add project-specific notes here. This section is never auto-modified.

- Never commit to `main`. Every change, a one-line fix included, goes on its own branch in its own git worktree, becomes a pull request against `main`, and lands only through that PR after CI (`check.yml`) is green. Start work by creating the worktree and branch; never edit or commit in the `main` checkout.
- Standing approval on a feature branch: once `pnpm check` passes (the commit-gate hook runs it) and the change is what was asked, commit, push the branch and open the PR without asking. Merging the PR is Jason's call.
