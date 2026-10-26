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
- Pointer sync is add-only: copy only when the source is newer, honour `deleted_*` tombstones, never delete, never symlink the folders (Desktop refuses a symlinked private dir), never touch a record a running Desktop owns.
- `spaces.json` has org-bound keys (`projects`, `migration`); a future sync of it must leave them out.
- `signed_in` requires a non-empty `oauth:tokenCacheV2` string. An empty session list must not crash under bash 3.2 `set -u` (reproduced, fixed, in the self-check).
- Profiles hold only encrypted tokens, cookie bytes and an account UUID, mode 0600 in a 0700 store. They are per Mac.
- Never use Desktop's own Log out to change accounts; it may revoke the saved token server-side. `add` signs out locally by deleting the three keys and the cookie files.
- The Keychain is read only for `usage`, through `/usr/bin/security` (so "Always Allow" persists), once per run. Never poll it.
- The bearer token reaches `curl` on stdin (`-K -`), never argv. The derived AES key is on the `openssl` command line for the moment of each decrypt, and that is the documented limit (`--help`, Cautions). Nothing prints a token.
- Stray `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_API_KEY` or `apiKeyHelper` in the environment silently override the subscription login in the CLI; the tool never sets them.
- Do not add a per-account `CLAUDE_CONFIG_DIR`: it splits transcripts, and `--resume` searches only the current dir.

## Terms posture

Reported, not legal advice. The Consumer Terms (2025-10-08 revision) have no multi-account clause but forbid credential sharing and bypassing protective measures, and allow suspension without notice. The Usage Policy bars multiple accounts only to evade bans. Reported risk gradient: several paid accounts is low; manual switching is a gray area; automated rotation is riskier; sharing or reselling is a clear violation. Third-party coverage says subscription OAuth tokens used outside Anthropic's own apps are discouraged.

So `usage` is the one feature in that gray area and stays opt-in (runs only when asked), read-only (one GET of the usage endpoint), never a daemon, never a trigger for an automatic switch. Everything else copies the app's own files as opaque bytes and decrypts nothing. Switching stays manual by construction; the Raycast switch command asks for confirmation.

Chats, Projects and memory on claude.ai are server-side per account and never move; only Claude Code sessions carry over. Sign in with the email code, not Google, so the browser hand-back lands in the right window.

## What a reviewer rejects

- Any daemon, launch agent, cron entry, menu bar loop or `--watch` mode.
- Polling `security`, or reading the Keychain outside `usage`.
- A token on a command line anywhere beyond the documented `openssl -K` moment, or a token in output or a log.
- A sync that deletes, renames, symlinks, or writes while Desktop runs without `--force`.
- A write to `config.json` without a `backup_login` first, or one that changes keys other than the three login keys.
- Any command that quits Desktop, or writes its files, while Desktop is open and `--force` was not given.
- An automatic switch of any kind (on a usage threshold, on a rate-limit error, on a schedule).
- Use of Desktop's own Log out, or a call to Anthropic's token refresh endpoint.
- A `CLAUDE_CONFIG_DIR` per account.
- A new command, option or refusal without a case in `test/claude-multipass.sh`, or a behaviour change without its README or `docs/` edit.
