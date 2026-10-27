# Research digest: multi-account Claude on macOS

The research claude-multipass was built from, condensed from a longer private report dated 2026-10-23 that measured Claude Desktop 3.6556.2 and Claude Code CLI 2.1.309 (Desktop bundled Claude Code 2.1.304 and 2.1.308). The full report is not published; it names accounts and one machine. Account names, emails, UUIDs and machine details are removed here.

Evidence labels: **M** measured on a Mac or in cloned source, **O** official Anthropic doc, **R** reported (issue, README, blog), **U** unverified or inferred.

## 1. Problem and priorities

- More than one Claude account (a Team seat plus a personal plan, say) and the 5-hour usage window, which is shared across chat and Code per account. Switch accounts on macOS Desktop and the CLI.
- Narrowed requirement: after switching and opening Desktop, "continue from our previous session where we left off" must work. A live session need not survive a switch. The sidebar is secondary. Desktop's "what did the other session do" cross-session tools should work across accounts.
- Context that must survive: Code session recall (handoff notes, auto memory, transcripts). Chat history, Projects and memory are server-side per account and cannot move client-side (O).
- Transcripts live in one shared store, `~/.claude/projects` (M), so Code context survives a switch; the Desktop Code-tab sidebar index is per account and org; chat is per account.

## 2. Verified facts about storage and identity

**Transcripts (M, O)**

- `~/.claude/projects/<cwd-slug>/<session-id>.jsonl`, written by both the CLI and the Desktop Code tab; the `entrypoint` field says which (`claude-desktop`, `cli`, `sdk-py`). Transcripts from several orgs coexist in the one store (M).
- Every 2.1.30x transcript has an `attachment` record of type `credential_org` with `organizationUuid` (M). Versions 2.1.201 to 2.1.255 reportedly had no identity in transcripts (R). Whether resume compares `credential_org` to the active account is unknown.
- Retention: the CLI is governed by `cleanupPeriodDays` (default 30, minimum 1, swept in the background after session start) (O). Desktop transcripts are kept unless `desktopSessionCleanupPeriodDays` is set (O). CLI pruning had left only 78 of 206 sidebar pointers with a transcript in one reporter's case (R).

**Desktop credentials (M)**

- App support folder `~/Library/Application Support/Claude/`. `config.json` login keys: `oauth:tokenCache`, `oauth:tokenCacheV2`, `lastKnownAccountUuid`. One login at a time. Plus `Cookies` and `Cookies-journal` (in `Network/` when that folder exists). All encrypted with the app's "Claude Safe Storage" Keychain key, which is per Mac, so profiles don't transfer between Macs.
- Desktop signs in with its own OAuth flow and ignores `ANTHROPIC_API_KEY`, `apiKeyHelper` and CLI profiles (O). It may ignore `CLAUDE_CONFIG_DIR` (U).
- Other measured files: `claude_desktop_config.json` (local MCP servers; survival across sign-out is U), `ccd-session-presets.json` keyed `byAccount`, `local-agent-mode-sessions/<accountUuid>/` (with `<org>/spaces.json` and `scheduled-tasks.json`), per-org `archived-sessions.idx` and `scheduled-tasks.json` beside the session pointers (M 2026-10-25), and a claude.ai IndexedDB that is a React Query cache, not chat storage (R). `app.asar` is about 50 MB under the hardened runtime.
- `config.json.journal` is the app's write-ahead copy, headed by the sha256 of the `config.json` it came from; the app discards it at startup when the digest no longer matches, as after a switch. Leave it alone.

**Code-tab process environment (M, `ps -E`, names only)**

- Each Desktop-spawned `claude` has `CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_CODE_ACCOUNT_UUID`, `CLAUDE_CODE_ORGANIZATION_UUID`, `CLAUDE_CODE_USER_EMAIL`, `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_SDK_HAS_HOST_AUTH_REFRESH` and a `--settings` flag.
- `CLAUDE_CODE_OAUTH_TOKEN` outranks the Keychain login (O precedence: cloud-provider variables, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_API_KEY`, `apiKeyHelper`, `CLAUDE_CODE_OAUTH_TOKEN`, an Anthropic profile or federation credential when one is named, then `/login`). Consequence: a terminal `/login` or a Keychain swap does not move a Code-tab session; only changing Desktop's own sign-in does. The host app refreshes the token itself.
- The Code-tab argv lists `mcp__ccd_session_mgmt__list_sessions`, `get_session`, `search_session_transcripts` and `send_message` (M). Their universe is inferred (R, issue 74662) to be the index folder below.
- Plugin SessionStart hooks and plugin MCP tools do run in Code-tab sessions (M).

**Desktop Code sidebar index (M layout, undocumented)**

- `~/Library/Application Support/Claude/claude-code-sessions/<accountUuid>/<orgUuid>/local_<uuid>.json`. Keys: `cliSessionId`, `cwd`, `title`, timestamps (`lastActivityAt`), `isArchived`, `permissionMode`, `model`, `effort`, `remoteMcpServersConfig`. No account or org field inside the file, so a plain copy between folders works. `deleted_<uuid>` tombstones sit beside them (R).
- Switching account or org makes Desktop read a different folder, so the sidebar empties; transcripts are untouched (R, issue 74662, open since 2026-07-06). Symlinking the folders fails with "Refusing non-directory at private dir path" (R). Do not touch a record a running Desktop session owns (R).

**CLI credentials**

- macOS Keychain generic password service `Claude Code-credentials`; fallback `~/.claude/.credentials.json` mode 0600 (O). The JSON holds `claudeAiOauth` with `accessToken`, `refreshToken`, `expiresAt`, `scopes`, `subscriptionType` (M in tool sources). Identity block: `oauthAccount` in `~/.claude.json`, which pins the cached org per request, so a token swap without rewriting it can bill the wrong org (R, two tool sources agree).
- Per-directory item: `Claude Code-credentials-<first 8 hex of sha256(NFC(CLAUDE_CONFIG_DIR))>` (R, from claude-swap citing `macOsKeychainHelpers.ts`). The CLI reads the Keychain before the plaintext file (M in source) and caches the Keychain read about 30 s on macOS (R).
- `CLAUDE_CONFIG_DIR`: own settings, history, login and Keychain entry (O). `claude --resume <id>` searches only the current config dir (O).
- Lock files used by the CLI: `.oauth_refresh.lock`, `~/.claude.json.lock` (M in claude-swap source).
- Commands (O): `claude auth login [--email|--sso|--console]`, `claude auth logout`, `claude auth status`, `/login`, `/logout`, `/status`, `/usage`, `/usage-credits`, `/rate-limit-options`, `/desktop`, `/resume`, `claude --desktop --resume <session-id>` (v2.1.285+), the `claude://resume?session=<id>` deep link (R). The interactive-mode doc lists switching accounts with `/login` as keeping the conversation (O, untested).
- Rate limits: auto-continue since v2.1.234; the Code tab has a separate "Auto-continue when limits reset" checkbox. The prompt cache is per account, so the first turn after a switch re-sends the whole transcript (R).

**Server-side (O)**: chats, Projects and memory are per account. Different emails means sign out and in; an org switch under one login is the lower-left menu. Personal-to-Team migration is same-email and one-way. Export (Settings > Privacy > Export data) cannot be imported into another personal account. Memory moves by the verbatim-export prompt or Settings > Memory import. Usage credits (Settings > Usage) pay past limits at API rates.

**Second Desktop instance (R)**: `open -n -a Claude --args --user-data-dir="$HOME/Library/Application Support/Claude-Work"`; about 1 to 2 GB per instance. Google or browser sign-in returns through a `claude://` link that can land in the wrong instance, so use email-code sign-in or quit the other instance. Do not add a per-profile `CLAUDE_CONFIG_DIR` (it would split transcripts). Symlink and directory swaps break Cowork VirtioFS and file locks.

## 3. Audit of the third-party tools

Cloned and source-read 2026-10-23, none executed.

**realiti4/claude-swap** (MIT, Python, `uv tool install claude-swap`, v0.28.0): `cswap add` snapshots the Keychain token JSON plus `oauthAccount`; `cswap switch` writes them back under Claude Code's lock dirs; `cswap list` reads 5h and 7d usage from `https://api.anthropic.com/api/oauth/usage`; `cswap auto` switches at a threshold; `cswap run <n> [--share-history]` launches under a per-account `CLAUDE_CONFIG_DIR` with symlinked settings. Misses: nothing touches Desktop or `claude-code-sessions`. It refreshes tokens itself by POSTing to `https://platform.claude.com/v1/oauth/token` with the CLI's hardcoded `client_id`. Issues 496 (the TUI spawns `/usr/bin/security` about eight times a second, securityd crashes), 460 (usage 429s), 469 (a switch drops Remote Control), 489 (the active account is identified by the config email, not the UUID). Export files hold plaintext refresh tokens. README: no `/logout` before adding an account. Reusable: the lock protocol, the `--share-history` recipe, the usage endpoint reading.

**XueshiQiao/CCSwitcher** (MIT since 2026-10-26, no license file at the 2026-10-23 read; Swift 6 menu bar app, macOS 14+): the same Keychain plus `oauthAccount` swap with fingerprint checks and `claude auth status` verification; adds accounts via a background `claude auth login`; reads the Keychain via `/usr/bin/security` so "Always Allow" persists; refresh delegated to the CLI. Misses: no Desktop support; issue 25 (usage attributed to the wrong account when the identity block and Keychain drift). Issue 37, which asked for a license, closed 2026-10-26 with the MIT file.

**PriyanshuGeTRekT/Claude-Code-Desktop-Switcher** (MIT, PowerShell 5.1, Windows only): whole Desktop profiles via Electron `--user-data-dir`; optionally registers as the `claude://` handler; `Copy-CodeSession` copies a `local_*.json` pointer and rewrites account and org strings (a no-op on macOS, where the file holds neither). Reusable: the pointer-copy idea.

**SnlperStripes/claude-account-switcher** (Go, Apache-2.0, tray app, macOS build untested by its author): `profiles.go` and `desktop.go` give the exact swap key list (the config keys plus the Cookies files, nothing decrypted); `sessions.go` and `spaces.go` give the union sync. This is the mechanism claude-multipass follows. Others seen: `claude-multiprofile` (clones Claude.app per profile), claude-transplant, ccdejavu, restore-desktop-sessions, claude-switcher.

**Common finding**: no tool switches a running Code-tab session on macOS; the Code tab is outside every Keychain-swap tool's reach.

## 4. Recommendation and rejected alternatives

- CLI and VS Code: `uv tool install claude-swap`, manual `cswap switch`, avoid the TUI and `cswap auto`. CCSwitcher is the GUI alternative that never touches the private endpoint. `/login` is the no-tool fallback.
- Desktop: claude-multipass. Commands `list`, `show`, `save`, `add`, `switch`, `sync`, `rename`, `remove`, `usage`, `current`, `pick`, `doctor`. `switch` quits Desktop via AppleScript, re-saves the outgoing login, merges the target's three keys into `config.json` (other keys byte-identical), copies the cookies, union-syncs `local_*.json` across every account folder (newer `lastActivityAt` wins, tombstones honoured, nothing deleted) and relaunches. No private endpoints (except the opt-in `usage`), no daemon, manual by construction.
- Recall: a transcript-search MCP reading the shared store (obra/episodic-memory ranked first; thedotmack/claude-mem rejected).
- Routine after a switch: sign Desktop in as the other account, open a new Code-tab session in the same project folder, ask to continue (handoff notes, auto memory, CLAUDE.md, past transcripts), or `claude --resume <id>` and `claude --desktop --resume <id>`.
- Chat side: usage credits first, then a second Desktop instance with email-code sign-in.
- Rejected: hand-made per-account `CLAUDE_CONFIG_DIR` (splits history), `cswap auto` (terms risk plus 429s), cux and claude-code-profile-switcher (automated), patching `app.asar` (breaks the signature), Claude Desktop 3P (a different product).
- Terms (reported, not legal advice): the Consumer Terms (2025-10-08) have no multi-account clause but forbid credential sharing and "bypassing any of our systems or protective measures"; section 12 allows suspension without notice. The Usage Policy bars multiple accounts only to evade bans. Risk gradient: several paid accounts low; manual switching gray; automated rotation higher; sharing or reselling a clear violation. Subscription OAuth tokens outside Claude Code are reportedly prohibited (R); claude-swap extracts and refreshes, CCSwitcher extracts but delegates refresh, claude-multipass `usage` extracts, read-only and opt-in.

## 5. Open questions and untested claims

1. `/login` mid-session in the CLI keeps the conversation (O wording, untested).
2. Resume across accounts on 2.1.30x: create a Code-tab session under account one, sign Desktop into account two, then `claude --resume <id>` and `claude --desktop --resume <id>`. Success means `credential_org` is informational.
3. `claude://resume?session=<id>` import across accounts on macOS.
4. Whether Settings > Memory still has an export control.
5. `claude_desktop_config.json` unchanged across a Desktop sign-out and sign-in.
6. Closed 2026-10-26: `security find-generic-password -s "Claude Code-credentials"` finds the item, account the macOS user name. The `-<8 hex>` variant for `CLAUDE_CONFIG_DIR` stays R.
7. Whether the cross-session tools read copied index entries (stage a titled `local_<uuid>.json`, copy it, ask about it).
8. claude-swap mid-session switch behaviour (the `/status` Email row).
9. Whether two personal accounts pool limits at all.
10. Closed 2026-10-25: the tool runs against a real Desktop folder; several profiles saved and switched since 2026-10-23.

## 6. Constraints, gotchas, safety rules

- Quit Desktop before touching `config.json`, `Cookies` or `claude-code-sessions`; `sync` refuses while Desktop runs unless `--force`. A failure after the quit must still relaunch the app; back up `config.json` before every merge.
- Profiles are per Mac (the Safe Storage key); the files hold only encrypted tokens and a UUID.
- Never overwrite a saved profile that holds a different account (a reproduced defect, fixed with the `--force` refusal). An empty session list must not crash under bash 3.2 `set -u` (reproduced, fixed). `signed_in` requires a non-empty token string.
- Pointer sync is add-only; honour `deleted_*` tombstones; never symlink the folders; never touch records owned by a running Desktop; the `projects` and `migration` keys in `spaces.json` are org-bound (not synced).
- Keychain: reading the stored token prompts for access; `/usr/bin/security` makes "Always Allow" persist; avoid polling (the issue 496 storm). Identity (`oauthAccount`) must swap together with the token on the CLI side.
- Do not `/logout` before adding an account to claude-swap. Never use Desktop's own Log out to change accounts; it may revoke the saved token server-side. A stray `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_API_KEY` or `apiKeyHelper` silently overrides the login or bills the API instead of the subscription.
- `CLAUDE_CONFIG_DIR` splits history (resume only searches the current dir).
- Second instance: avoid Google sign-in; quit the other instance first; don't symlink Cowork dirs.
- Tool-version fragility: claude-swap tracks Claude Code's lock protocol and a private OAuth client id.
- Treat automated rotation as terms-risky; keep switching manual.

## 7. Future enhancement ideas (not built)

- A lock against concurrent runs; `--dry-run`; account names or emails in `list` (needs decrypting; today only the UUID prefix shows).
- Sync Desktop projects (`local-agent-mode-sessions/<account>/<org>/spaces.json`, minus the org-bound `projects` and `migration` keys), the per-org `archived-sessions.idx` and `scheduled-tasks.json`, so copied sessions keep their grouping, archived state and scheduled tasks.
- Install and configure obra/episodic-memory for recall.
- Optional claude-swap one-shot commands as shell aliases for the CLI side.
- A note on switch cost: the first turn after a switch re-sends the transcript (per-account prompt cache).
