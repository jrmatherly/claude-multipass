# LLM Router profile design

Status: implemented on branch `llmr-profile` (the claude-multipass side), revision 2. The real-launch check of the quit reaching LLMR's `open -n` instance is still open. The first draft proposed a new `llmr takeover` command. llm-router's review showed it fights LLMR's lifecycle, so this revision uses the existing `llmr <profile> app` instead. Nothing here is agreed with llm-router; Jason decides what it builds. Evidence labels: **source** (read in code on 2026-11-01), **measured**, **inferred**, **not proven**.

## Goal

A saved profile you can switch to that runs Claude Desktop through llm-router (LLMR). Switching back to a claude.ai account brings back that account's Desktop login. For the user it is one more row in `list`, the picker and the menu bar. For the next maintainer, claude-multipass never writes an LLMR file or the shared `Claude-3p/` folder.

## How Desktop picks its instance (source)

Read in Desktop 4.4212.0's `app.asar` by both sessions (`resolve3pForcingSource`; `m4` in `.vite/build/index.pre.js`).

- Desktop boots its third-party instance when the effective config activates third-party mode (an applied entry in `Claude-3p/configLibrary`, managed policy, or a key marked `activatesThirdPartyMode`) and `Claude-3p/claude_desktop_config.json` does not say `deploymentMode: "1p"`. A missing `deploymentMode` still boots 3p. `authentication.disableClaudeAiSignIn` forces it.
- With `CLAUDE_USER_DATA_DIR` set, Desktop uses that folder as given and skips the `-3p` relocation.
- The claude.ai login lives in `Claude/`. A mode change needs a full quit and relaunch.

## Decision: launch LLMR's own instance, leave the shared folders alone

`llmr <profile> app` already does what the profile needs (source, `packages/cli/src/cli.ts:205-220`, `packages/core/src/agents/claude-app/launch.ts:55-100`). It writes the gateway config into that LLMR profile's own data dir with `backup: false`, then spawns Desktop detached with `--user-data-dir=<dir>` and `CLAUDE_USER_DATA_DIR`. It writes the shared `Claude-3p/` only when the LLMR profile opts in with `claudeAppTakeover`; the profile used here must not.

So:

- Switch to the LLMR profile: save the outgoing login as `switch` does now, quit Desktop, run `llmr <p> app` in place of the relaunch.
- Switch away: quit Desktop, restore the target's login as now, `open -a Claude`. The shared `Claude/` and `Claude-3p/` were never changed, so Desktop boots the claude.ai login.

Why not `llmr takeover` (the first draft): LLMR undoes the shared takeover on an Electron quit, on `llmr stop`, and when the `llmr <profile>` daemon idles out 2 s after its last lease (source, `cli.ts:71`, `:555-566`). A kill -9 leaves Desktop on 3p pointed at a dead port. A CLI cannot reach a running Electron LLMR. A command named `takeover` would shadow an LLMR profile of that name (`cli.ts:259-280`). The launch path avoids all of these, because nothing shared changes.

## The CLI side

Decided by Jason on 2026-11-01 (relayed by llm-router's session): per-launch, shared home. Pending llm-router's shared-home mode, which is planned and not started.

- Terminal `claude` reaches LLMR only when started as `llmr <p>`. LLMR will run `claude --settings <generated file>` with `CLAUDE_CONFIG_DIR` unset, so `~/.claude` (CLAUDE.md, skills, plugins, MCP servers, history) stays in use. The file carries the base URL env, the model env and `apiKeyHelper`.
- `--settings` sits above user, project and local settings and below managed settings, and `apiKeyHelper` outranks the saved claude.ai login for that process only (Anthropic's settings and authentication docs, as read by llm-router's session; not checked by this one). Plain `claude` in other terminals keeps the claude.ai login.
- claude-multipass does nothing for the CLI on an LLMR switch. No `settings.json` write, no Keychain change. `cli_verify` and `doctor` are unaffected.
- The LLMR row shows the hint "terminal: run `llmr <p>`".
- Rejected: LLMR's current `llmr`-scope profile, which sets `CLAUDE_CONFIG_DIR` to a blank home and loses the user's setup; a global-scope profile, which writes `~/.claude/settings.json` on every launch; and a global takeover, for the lifecycle reasons above.
- Until the shared-home mode ships, `llmr <p>` works today only with a blank Claude home.

## claude-multipass changes

- Profile kind. `profiles/<name>/meta.json` gains `kind: "llmr"` and `llmrProfile: "<LLMR profile>"`. It holds no `config.json`, cookies or CLI item. Existing profiles have no `kind`.
- Creating one. `save <name> --llmr <p>` writes that meta and nothing else. It does not quit Desktop. Whether `<p>` exists is checked at switch time by `llmr <p> app` itself, until LLMR offers a profile list.
- Active marker. `$root/active-llmr` holds the LLMR profile name while Desktop runs LLMR's instance. `switch` to an LLMR profile writes it after `llmr <p> app` succeeds. Any switch away removes it.
- `current` and `list`. With the marker present and a Desktop process whose arguments carry `--user-data-dir` for that profile, the LLMR profile is current. A marker with no such process is stale: `current` reports the `Claude/` login and removes the marker.
- Switch away when the target is the account `Claude/` still holds. Today that hits the "already signed in" branch (`bin/claude-multipass:1510-1520`), which does not relaunch. With the marker present, the switch quits Desktop and relaunches with `open -a Claude` even though the login is unchanged.
- Failures. If `llmr <p> app` fails, the `EXIT` trap relaunches the untouched claude.ai login and the error line is shown. The profile switch is then not current.
- Refusals. "Switch away from a login that was never saved" still applies to the outgoing claude.ai login. Leaving an LLMR profile has no login to lose, so it never refuses.
- `index_sync`, `usage` and `rename`'s Keychain move skip LLMR profiles. The menu bar shows the row with no usage meter.
- `llmr` is found on PATH, then at `~/.llm-router/bin/llmr`. `CLAUDE_MULTIPASS_LLMR` overrides it, and the self-check stubs it, recording its arguments.
- Docs. `README.md:52` and `docs/claude-multipass.md:141` ("close the gateway before a switch") get a line for the LLMR profile.

## The gateway's lifetime (source, llm-router `cli.ts:167-178`, `launch-core.ts:84-89`)

- `llmr <p> app` takes no lease and starts no daemon for a claude-code app launch. It needs the user's long-running LLMR (the desktop app, or `llmr start`/`serve`) already up, and exits non-zero otherwise. The fallback relaunch above covers that.
- That LLMR does not idle out. If the user quits it while LLMR's Desktop is open, Desktop's requests fail until it comes back, because the profile's own folder still points at `127.0.0.1:3456`.
- So `current` also probes that LLMR answers, and reports "LLMR profile, gateway not running" when it does not. Not run live.

## Safety rules this touches

- Desktop is still quit before any change and relaunched from the `EXIT` trap. `llmr <p> app` replaces the relaunch only after the quit succeeded.
- The tool still never sets `apiKeyHelper` or `ANTHROPIC_API_KEY`. LLMR passes `apiKeyHelper` per process through `--settings` and writes no file claude-multipass manages.
- No automatic switch. A stale marker is reported, never followed.

## Must check before building

- The quit. Whether `osascript` quit of "Claude" and the `pgrep -x Claude` fallback stop an instance launched with `--user-data-dir`. Check: launch with `llmr <p> app`, run the quit path, `pgrep -lf Claude`.
- The quit reaching the second instance. LLMR launches it with `open -W -n` (source, `launch.ts:77-123`), so it is a separate instance of the same bundle, and an AppleScript quit by name may reach only one.
- Code tab sessions. LLMR's instance sets `CLAUDE_CONFIG_DIR` for its own Code tab (source, `launch.ts:64`). Sessions there do not appear under claude.ai accounts and are outside `index_sync`. State it in the docs.

## Out of scope

- Writing any LLMR file, `Claude-3p/`, or `~/.claude/settings.json`.
- Starting or stopping the LLMR service beyond running `llmr <p> app`.
- Usage for an LLMR profile.

## Useful from LLMR, not required

- A read-only `llmr status --json` (`{profile, desktop, cli, running}`, no secrets) would let `current` drop the process check and `save --llmr` check the profile exists.
- The `llmr stop` bug that leaves `settings.json` taken over is LLMR's to fix, whatever this design does.
