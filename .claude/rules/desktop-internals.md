---
paths:
  - 'bin/**'
  - 'test/**'
  - 'raycast/**'
---

# Desktop and CLI internals

Verified facts the tool rests on. Do not re-derive them; cite them. Evidence labels: **M** measured on a Mac or in cloned source, **O** official Anthropic doc, **R** reported (issue, README, blog), **U** unverified or inferred. Measured 2026-10-23 against Desktop 3.6556.2 and CLI 2.1.309 (Desktop bundled Claude Code 2.1.304 and 2.1.308); re-measure after an app update before trusting a layout claim. The full digest is `docs/research.md`.

## Desktop paths and keys

- App support folder `~/Library/Application Support/Claude/` (M). `config.json` holds the login in three keys, `oauth:tokenCache`, `oauth:tokenCacheV2`, `lastKnownAccountUuid`; one login at a time (M). The app writes it tab-indented, no final newline, mode 0600 (M; `jq_write` matches that). Cookies are `Cookies` and `Cookies-journal`, in `Network/` when that folder exists (M).
- `config.json.journal` is the app's write-ahead copy, headed by the sha256 of the `config.json` it came from; the app discards it at startup when the digest no longer matches, as after a switch (M). Leave it alone.
- The token caches and cookies are encrypted with the "Claude Safe Storage" login-Keychain password, Chromium style: PBKDF2-SHA1 of that password, salt `saltysalt`, 1003 rounds, 16 bytes, as an AES-128-CBC key, IV of 16 spaces, `v10` prefix on the ciphertext (R for the scheme, Chromium's macOS os_crypt; M only that the self-check round-trips a fixture the same way; `usage` printing figures on a real Mac is what confirms it against a real cache). Per Mac, so profiles don't transfer between Macs.
- Reading that Keychain item prompts; using `/usr/bin/security` makes the user's "Always Allow" persist (M in CCSwitcher's source and the Raycast usage command). At most one call per 5 minutes: claude-swap issue 496 reports that about eight `security` spawns a second crashed securityd, so the menu bar app's usage poll makes one call per run and never runs faster than that.
- Desktop signs in with its own OAuth flow and ignores `ANTHROPIC_API_KEY`, `apiKeyHelper` and CLI profiles (O). Whether it honours `CLAUDE_CONFIG_DIR` is U.
- Other files beside the login (M): `claude_desktop_config.json` (local MCP servers; survival across sign-out is U), `ccd-session-presets.json` keyed `byAccount`, `local-agent-mode-sessions/<account>/<org>/spaces.json` (Desktop projects; its `projects` and `migration` keys are org-bound) and `scheduled-tasks.json`, plus a per-org `archived-sessions.idx` and `scheduled-tasks.json` beside the session pointers. None of these is synced yet.

## Code tab session index

- `claude-code-sessions/<accountUuid>/<orgUuid>/local_<uuid>.json`, one per session (M layout, undocumented). Keys: `cliSessionId`, `cwd`, `title`, timestamps including `lastActivityAt`, `isArchived`, `permissionMode`, `model`, `effort`, `remoteMcpServersConfig`. No account or org field inside, so a plain copy between folders works (M).
- `deleted_<uuid>` tombstones sit beside the pointers (R). Sync honours them and never copies a tombstoned id back.
- Switching account or org makes Desktop read a different folder, so the sidebar empties while transcripts stay (R, issue 74662, open since 2026-07-06). Symlinking the folder fails with "Refusing non-directory at private dir path" (R). Never touch a record a running Desktop session owns (R).
- Transcripts are shared: `~/.claude/projects/<cwd-slug>/<session-id>.jsonl`, written by the CLI and the Code tab alike (M, O). Every 2.1.30x transcript carries a `credential_org` attachment with `organizationUuid` (M); whether resume compares it to the active account is U. CLI retention is `cleanupPeriodDays` (default 30); Desktop transcripts stay unless `desktopSessionCleanupPeriodDays` is set (O).

## Code tab process environment

- Each Desktop-spawned `claude` has `CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_CODE_ACCOUNT_UUID`, `CLAUDE_CODE_ORGANIZATION_UUID`, `CLAUDE_CODE_USER_EMAIL`, `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_SDK_HAS_HOST_AUTH_REFRESH` and a `--settings` flag (M, `ps -E`, names only).
- `CLAUDE_CODE_OAUTH_TOKEN` outranks the Keychain login (O precedence: cloud-provider vars, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_API_KEY`, `apiKeyHelper`, `CLAUDE_CODE_OAUTH_TOKEN`, then `/login`). So a terminal `/login` or a Keychain swap never moves a Code-tab session; only changing Desktop's own sign-in does. The host app refreshes the token itself.
- Plugin SessionStart hooks and plugin MCP tools run in Code-tab sessions (M).

## CLI credentials

- Keychain generic password service `Claude Code-credentials`, fallback `~/.claude/.credentials.json` mode 0600 (O). The JSON holds `claudeAiOauth` with `accessToken`, `refreshToken`, `expiresAt`, `scopes`, `subscriptionType` (M in tool sources). The identity block `oauthAccount` in `~/.claude.json` pins the org per request, so a token swap without it can bill the wrong org (R, two tools agree).
- Per-directory item `Claude Code-credentials-<first 8 hex of sha256(NFC(CLAUDE_CONFIG_DIR))>` (R). The CLI reads the Keychain before the file (M in source) and caches the read about 30 s (R). The locks are directories, `mkdir` to take, stale after a threshold: `~/.claude/.oauth_refresh.lock` (60 s), `~/.claude.lock` (60 s) and `~/.claude.json.lock` (10 s) (M in claude-swap source).
- Measured 2026-10-26 on this Mac: the live item is 14625 bytes, 14053 of them `mcpOAuth`, so a `security -i` line (4019 bytes at most) cannot carry it. Claude Code 2.1.310 (read from its binary) reads its item with `security find-generic-password -a <user> -w -s <service>` and writes it with an `add-generic-password -U -a "<user>" -s "<service>" -X "<hex>" ` line on `security -i` stdin when that line is at most 4032 bytes, else with `security add-generic-password -U -a <user> -s <service> -X <hex>` on argv (it logs "Keychain payload exceeds security -i stdin limit; using argv") (M). A Keychain item carries a partition_id ACL entry beside the application ACL: `/usr/bin/security` is in partition `apple-tool:`, the Command Line Tools python is in `apple:`. An app in the application ACL still prompts (with the login password) unless its partition is in the item's partition list, the GUI's Always Allow edits only the application ACL, and an in-place update resets the partition list to the writer's partition (M, corroborated by anthropics/claude-code issue 62361). So the tool goes through `security` only, in Claude Code's shape. The item's account is the macOS user name and `oauthAccount.accountUuid` in `~/.claude.json` equals Desktop's `lastKnownAccountUuid` for the same claude.ai account (M). `claude auth status` prints JSON by default with `orgId` and `email` (M). The CLI writes its item through `security -i` with `-X <hex>` on stdin (M in source), which was the tool's original route too: `security -i` keeps at most 4019 bytes of a line and corrupts the rest, its parser rejects the shell's `'\''` escape (exit 45), `-X <hex>` round-trips any value, the `-w` prompt reads the terminal rather than a pipe, and exit 44 means absent (M). The item's other top-level keys (`mcpOAuth`, `mcpOAuthClientConfig`, `mcpXaaIdp`, `mcpXaaIdpConfig`, `pluginSecrets`) are shared across accounts (M). `~/.claude.json` is 2-space indented, mode 600 (M).
- `CLAUDE_CONFIG_DIR` gives its own settings, history, login and Keychain entry; `claude --resume <id>` searches only the current config dir, so per-account config dirs split history (O).
- Rate limits auto-continue since v2.1.234; the Code tab has its own "Auto-continue when limits reset" checkbox. The prompt cache is per account, so the first turn after a switch re-sends the transcript (R).

## Open tests

Untested or unverified claims, from the digest. Settle one before building on it.

1. `/login` mid-session in the CLI keeps the conversation (O wording, untested).
2. Resume across accounts on 2.1.30x: create a Code-tab session under account one, sign Desktop into account two, then `claude --resume <id>` and `claude --desktop --resume <id>`. Success means `credential_org` is informational.
3. `claude://resume?session=<id>` import across accounts on macOS.
4. Whether Settings > Memory still has an export control.
5. `claude_desktop_config.json` unchanged across a Desktop sign-out and sign-in.
6. Closed 2026-10-26: `security find-generic-password -s "Claude Code-credentials"` finds the item, account the macOS user name. The `-<8 hex>` variant for `CLAUDE_CONFIG_DIR` stays R.
7. Refresh-token rotation across a tool round trip: whether a login saved by `save`, left while the other account is used, then restored by `switch` still refreshes (or fails with `invalid_grant`). To be settled by the real-Mac round trip in the plan's Task 8.
8. The exit code of `security` when the Keychain prompt is denied, and whether a running `claude` waits on the lock dirs or fails.
9. Whether Desktop's cross-session tools (`mcp__ccd_session_mgmt__list_sessions` and friends) read copied index entries: stage a titled `local_<uuid>.json`, copy it, ask about it.
10. claude-swap mid-session switch behaviour (`/status` Email row).
11. Whether two personal accounts pool limits at all.
12. Closed 2026-10-26: 0.3.2's round trip on this Mac prompted on every Claude Code read, and Always Allow did not stop it, because the python helper's items sat in the `apple:` partition while `security` is in `apple-tool:` (the partition facts above); 0.3.3 writes through `security` only, and its next save of a profile item (the re-save on the way out of a switch) moves that item into `security`'s partition.
13. Closed 2026-10-25: the tool works against a real Desktop folder (several profiles saved and switched since 2026-10-23). Measured 2026-10-26 in review: `claude auth status` under an isolated config dir returns at once with `.claude.json.lock` held and rewrites `.claude.json` itself, so it does not honour that lock for reads; whether its token refresh waits on a held `.oauth_refresh.lock` is still open (the tool releases its locks before asking it).

## Third-party tools audited

Cloned and source-read 2026-10-23, none executed.

| Tool | Mechanism | What it misses | Licence |
| --- | --- | --- | --- |
| realiti4/claude-swap (Python, `uv tool install claude-swap`) | Snapshots the CLI Keychain JSON plus `oauthAccount`; `switch` writes them back under the CLI's locks; `list` reads 5h/7d usage from the OAuth usage endpoint; `auto` switches at a threshold; refreshes tokens itself through a private endpoint with the CLI's client id | Desktop and `claude-code-sessions`; its TUI polls `security` (issue 496); 429s on usage; export files hold plaintext refresh tokens | MIT |
| XueshiQiao/CCSwitcher (Swift menu bar, macOS 14+) | Same Keychain plus `oauthAccount` swap with fingerprint checks and `claude auth status` after; adds accounts via background `claude auth login`; refresh left to the CLI | Desktop; usage attributed to the wrong account when the identity block drifts (issue 25) | MIT (added after the 2026-10-23 read; issue 37 closed 2026-10-26) |
| PriyanshuGeTRekT/Claude-Code-Desktop-Switcher (PowerShell, Windows) | Whole Desktop profiles via Electron `--user-data-dir`; copies a `local_*.json` pointer and rewrites account strings | macOS entirely; the string rewrite is a no-op here | MIT |
| SnlperStripes/claude-account-switcher (Go tray app) | Swaps the three config keys plus the cookie files, nothing decrypted; union-syncs session pointers and spaces | macOS build untested by its author | Apache-2.0 |

claude-multipass follows the last one's mechanism. Common finding: no tool moves a running Code-tab session on macOS, because the Code tab is outside every Keychain-swap tool's reach.
