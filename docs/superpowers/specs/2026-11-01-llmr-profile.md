# LLM Router profile design

Status: draft. It depends on an `llmr takeover` command that llm-router has not agreed to build. Jason decides whether it does. Evidence labels: **source** (read in llm-router's code on 2026-11-01, by its session and checked by this one), **measured**, **inferred**, **not proven**.

## Goal

A saved profile you can switch to that runs Claude through llm-router (LLMR). The Desktop app boots its third-party instance with inference through LLMR, and `claude` in a terminal routes through LLMR. Switching back to a claude.ai account undoes both and restores that account's Desktop and CLI logins. Jason chose Desktop and CLI together on 2026-11-01.

For the user, the LLMR profile is one more row in `list`, the picker and the menu bar. For the next maintainer, claude-multipass never writes LLMR's files. It calls one LLMR command and keeps its own storage model unchanged.

## Decision: LLMR owns the takeover writes

claude-multipass calls `llmr takeover` and never writes `Claude-3p/` or `~/.claude/settings.json` itself.

- LLMR derives the takeover from its own config on every config save and on every service start and stop (`syncClaudeAppGatewayConfig`, `packages/core/src/agents/claude-app/gateway-service.ts:88`; stop restores at `packages/core/src/web/management-server.ts:533`) (source). A direct write by claude-multipass would be undone, in either direction, the next time LLMR syncs.
- LLMR's only scripting surface today is its management RPC (`POST http://127.0.0.1:3458/api/llmr/rpc`). Its auth token is random per run unless `LLMR_WEB_AUTH_TOKEN` was set at launch (source), so another tool cannot rely on it.

## The LLMR contract (proposed, not confirmed)

| Command | Effect |
| --- | --- |
| `llmr takeover on <profile>` | Sets `enabled` and `claudeAppTakeover: true` on that claude-code profile, then applies the Desktop takeover (`Claude-3p/`) and the Claude Code takeover (`settings.json`, `apiKeyHelper`). Rejects a profile whose `surface` is `cli`. |
| `llmr takeover off` | Clears the takeover on every profile and restores both. The LLMR config library entry stays. |
| `llmr takeover status --json` | `{"profile": <name or null>, "desktop": bool, "cli": bool, "running": bool}` |

All three are idempotent, exit non-zero with one plain line on stderr on a refusal, and print no key or token. `on` with the LLMR service stopped fails with "start LLMR first", because Desktop on 3p with nothing listening fails every request and the Desktop write needs the gateway's live models (source, agreed by llm-router's session). `off` works with the service stopped.

## What LLMR writes (source, for reference only)

- Desktop. Under `~/Library/Application Support/Claude-3p/` only, never `Claude/`. The switch is `deploymentMode: "3p"` in `claude_desktop_config.json`, plus `appliedId` in `configLibrary/_meta.json` and a library entry with the gateway URL and a static LLMR key. The restore reverts those two keys from a backup at `~/.llm-router/claude-app-gateway-backup.json` and keeps the library entry.
- Claude Code. `~/.claude/settings.json` gets `ANTHROPIC_BASE_URL` and related env keys, model env, and `apiKeyHelper` pointing at `~/.llm-router/bin/llmr-claude-code-api-key-<slug>`. It loses `ANTHROPIC_AUTH_TOKEN` and `ANTHROPIC_API_KEY`. The revert restores LLMR's backup and deletes the helper.
- LLMR is account-agnostic. It records no claude.ai account for either path.

## claude-multipass changes

- Profile kind. `profiles/<name>/meta.json` gains `kind: "llmr"` and `llmrProfile: "<LLMR profile name>"`. Such a profile holds no `config.json`, cookies or CLI item. Existing profiles have no `kind` and stay claude.ai profiles.
- Creating one. `save <name> --llmr <llmr-profile>`. It checks `llmr takeover status --json` runs, and that the LLMR profile exists. It never quits Desktop.
- Switching to it. Save the outgoing login as `switch` does now (backup, CLI capture), quit Desktop, run `llmr takeover on <p>`, relaunch. `open -a Claude` then boots the 3p instance. If `on` fails, relaunch the untouched claude.ai login and show LLMR's line.
- Switching away. Quit Desktop, run `llmr takeover off`, restore the target's Desktop login and CLI item as now, relaunch. `off` runs before the relaunch, or Desktop boots 3p again.
- The refusal "switch away from a login that was never saved" does not apply while the LLMR profile is active, since there is no claude.ai login to lose.
- `current` and `list` read `llmr takeover status --json` when the last switch went to an LLMR profile, so a takeover turned off in LLMR's own UI shows as not active.
- `index_sync` and `usage` skip LLMR profiles. The menu bar shows the row with no usage meter.
- `llmr` is found on PATH, then at `~/.llm-router/bin/llmr`. `CLAUDE_MULTIPASS_LLMR` overrides it, and the self-check stubs it.

## Safety rules this touches

- "The tool never sets `apiKeyHelper` or `ANTHROPIC_API_KEY`" stays true. LLMR sets them, and only after the user switched to an LLMR profile. The rule in `.claude/rules/safety-and-terms.md` gains that one sentence.
- Desktop is still quit before any takeover change, and the `EXIT` trap still relaunches it. A failed `llmr takeover` call is a warning, never a stuck quit.
- No automatic switch. A takeover turned off in LLMR's UI is only reported, never followed by a switch.

## Risks

- Token rotation. When LLMR refreshes an expired token in `Claude Code-credentials`, the refresh token rotates and any older copy is dead (source). The switch away from LLMR must not restore a CLI item saved before LLMR last refreshed that account. The dead-token fix (treat an item with empty tokens and `expiresAt` 0 as signed out) covers the cleared case, not this one. _Proposed:_ while an LLMR profile is active, the switch away captures the live CLI item into the outgoing account's profile first, when its `oauthAccount` matches.
- Keychain race. LLMR re-reads the item before its write-back and adopts a changed pair, but the check and the write are not atomic (source). A swap inside that window could be overwritten. The window is small. _Accepted_, and stated in the docs.
- The item's account name. claude-multipass writes the CLI item under `$USER`, which is the account LLMR looks up first (source). Keep it that way.
- Other 3p triggers. `deploymentMode` is not the only one (source, Desktop 4.4212.0 `app.asar`, read 2026-11-01). `resolve3pForcingSource` forces the 3p instance whenever the effective config activates third-party mode (`kl`: an applied config library entry, managed policy, or any key marked `activatesThirdPartyMode`). It returns `"chooser-disabled"` when `authentication.disableClaudeAiSignIn` is true, `null` (1P) only when `deploymentMode` is `"1p"`, and otherwise `"persisted"` or `"hybrid-pointer"`. So a missing `deploymentMode` with LLMR's `appliedId` still in `_meta.json` boots 3p. `llmr takeover off` must revert `appliedId` as well as `deploymentMode`, which `restoreClaudeAppGatewayConfig` does today. `takeover status` must report `desktop: true` whenever an applied entry would activate 3p, not only when `deploymentMode` is `"3p"`. Managed policy that activates 3p is outside both tools; `doctor` should name it. Not measured by a launch.

## Out of scope

- Writing any LLMR file, or starting or stopping the LLMR service.
- Listing Code tab sessions from `Claude-3p/` after a switch.
- Usage for an LLMR profile.

## Open

- Jason: whether llm-router builds `llmr takeover`, and when. Check: a reply in the llm-router session, or a PR in `jrmatherly/llm-router`.
- Desktop's 3p triggers by a real launch: apply, `off`, relaunch, and confirm Desktop opens the `Claude` folder's account. Check: run it with a throwaway LLMR profile once `llmr takeover` exists.
