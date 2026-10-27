---
paths:
  - 'bin/**'
  - 'docs/**'
  - 'README.md'
---

# Safety rules and terms posture

## Rules a change must keep

- Quit Desktop before touching `config.json`, the cookie files or `claude-code-sessions`: the cookie database is locked and `config.json` rewritten while the app runs. `sync` refuses while Desktop runs unless `--force`. Everything past the quit runs under an `EXIT` trap that relaunches the app, so a failure midway still brings it back (`--no-relaunch` opts out).
- Back up the live login (`config.json` plus cookies) into `backups/login-*` before every merge into `config.json`. The ten newest are kept.
- Only the three login keys change in `config.json`; every other key stays byte-identical (the self-check compares the whole file).
- Never overwrite a saved profile that holds a different account; `save` refuses unless `--force`, and then moves the old profile into `backups/` (a reproduced data-loss defect, now a case in the self-check).
- Never switch away from a login that was never saved; `switch` refuses unless `--force`, because that login would need its email code again.
- Refusals that `--force` lifts exit 3, so a caller can offer the override; other failures exit 1. A refused `save` is decided before Desktop quits.
- Pointer sync is add-only: copy only when the source is newer, honour `deleted_*` tombstones, never delete, never symlink the folders (Desktop refuses a symlinked private dir), never touch a record a running Desktop owns.
- `spaces.json` has org-bound keys (`projects`, `migration`); a future sync of it must leave them out.
- `signed_in` requires a non-empty `oauth:tokenCacheV2` string. An empty session list must not crash under bash 3.2 `set -u` (reproduced, fixed, in the self-check).
- Profiles hold only encrypted tokens, cookie bytes, an account UUID and the CLI's identity block (`cli.json`, no secret), mode 0600 in a 0700 store. They are per Mac. The CLI's tokens for a profile live in a login-Keychain item of the tool's own (service `claude-multipass`, account the profile name), never on disk.
- The CLI login moves only with proof it belongs to the profile: `save` captures it only when `oauthAccount.accountUuid` equals Desktop's live account, a restore over a CLI already on the target account re-saves the live tokens instead of writing, and otherwise replaces whatever account the live item held (backed up first). A capture with a mismatch or a signed-out CLI, and any run under `CLAUDE_CONFIG_DIR`, with a corrupt `~/.claude.json` or a failed Keychain call, leaves everything as it was with a warning, and the Desktop switch always completes. `~/.claude.json` is written only while the CLI's three lock dirs are held, as the CLI writes it (2 spaces, final newline), and no key but `oauthAccount` changes value; the live CLI item and identity are backed up first (`backups/login-*` and a Keychain item of the same name).
- Never use Desktop's own Log out to change accounts; it may revoke the saved token server-side. `add` signs out locally by deleting the three keys and the cookie files.
- The Keychain is touched one way only: `security` on PATH (`/usr/bin/security` on a stock Mac, the tool Claude Code reads and writes its own item with; the self-check stubs it). It reads Safe Storage once per `usage` run, and reads and writes the CLI login item (`Claude Code-credentials`) and the tool's own `claude-multipass` items inside `save`, `add` (its re-save and the backup prune), `switch`, `rename`, `remove` and the backup prune only. No other accessor, the system `python3` included: a Keychain item remembers the partition of its last writer, a reader in another partition is prompted even after "Always Allow", and an in-place update resets the partition to the writer's, so 0.3.2's `python3` writes made every Claude Code read prompt (measured 2026-10-26). `list`, `list --json`, `show`, `current` and `doctor` never touch the Keychain. The menu bar app may call `usage --json` on a timer only when the user turned usage on, at most once per 5 minutes.
- The bearer token reaches `curl` on stdin (`-K -`), never argv. A Keychain value reaches `security -i` as hex on stdin while the line is at most 4000 bytes (`security -i` keeps at most 4019 bytes of a line, measured), and on `security`'s own argv otherwise, which is exactly how Claude Code writes its item (a live one with MCP logins is about 15 KB): that one argv is allowed and no other. The derived AES key is on the `openssl` command line for the moment of each decrypt, and that is the documented limit (`--help`, Cautions). Nothing prints a token.
- Stray `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_API_KEY` or `apiKeyHelper` in the environment silently override the subscription login in the CLI; the tool never sets them.
- Do not add a per-account `CLAUDE_CONFIG_DIR`: it splits transcripts, and `--resume` searches only the current dir.

## Terms posture

Reported, not legal advice. The Consumer Terms (2025-10-08 revision) have no multi-account clause but forbid credential sharing and bypassing protective measures, and allow suspension without notice. The Usage Policy bars multiple accounts only to evade bans. Reported risk gradient: several paid accounts is low; manual switching is a gray area; automated rotation is riskier; sharing or reselling is a clear violation. Third-party coverage says subscription OAuth tokens used outside Anthropic's own apps are discouraged.

So `usage` is the one feature in that gray area and stays opt-in (the CLI runs it only when asked; the menu bar app polls it only after the user turns usage on, at an interval of at least 5 minutes), read-only (one GET of the usage endpoint per account per run), never a trigger for an automatic switch. The menu bar app polls `list --json` on a timer; that reads `config.json` and `meta.json`, never the Keychain. Usage polling is opt-in, through `usage --json`, with an interval of at least 5 minutes, one `security` call per run, and stops when the user turns it off. The CLI login swap copies the CLI's token between two items of the same login Keychain, for the CLI's own use, and sends it nowhere; it is not in the gray area. Everything else copies the app's own files as opaque bytes and decrypts nothing. Switching stays manual by construction; the Raycast switch command asks for confirmation.

Chats, Projects and memory on claude.ai are server-side per account and never move; only Claude Code sessions carry over. Sign in with the email code, not Google, so the browser hand-back lands in the right window.

## What a reviewer rejects

- A launch agent, cron entry, daemon or `--watch` mode separate from the user-visible menu bar app. The app's own timers are allowed: the snapshot poll (`list --json`, no Keychain) and the opt-in usage poll.
- Usage polling that is on by default or faster than 5 minutes; a `security` call outside `usage`, `save`, `add`, `switch`, `rename`, `remove` and the backup prune; any Keychain access from `list`, `show`, `current` or `doctor`; a CLI token in output or in a log, or on any argv but `security add-generic-password -X <hex>` for a line too long for `security -i` (Claude Code's own writer); a `~/.claude.json` write outside the CLI's locks or touching a key other than `oauthAccount`.
- A token on a command line anywhere beyond the documented `openssl -K` moment and the oversize `security add-generic-password -X` write, or a token in output or a log.
- A sync that deletes, renames, symlinks, or writes while Desktop runs without `--force`.
- A write to `config.json` without a `backup_login` first, or one that changes keys other than the three login keys.
- Any command that quits Desktop, or writes its files, while Desktop is open and `--force` was not given.
- An automatic switch of any kind (on a usage threshold, on a rate-limit error, on a schedule).
- Use of Desktop's own Log out, or a call to Anthropic's token refresh endpoint.
- A `CLAUDE_CONFIG_DIR` per account.
- A new command, option or refusal without a case in `test/claude-multipass.sh`, or a behaviour change without its README or `docs/` edit.
