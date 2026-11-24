# LLM Router live tests on the UTM VM

**Goal:** run the live checks that the 2026-11-22 alignment review between claude-multipass and llm-router could not close by reading source, and record each result here.

**Status:** not started. Jason deferred the VM run on 2026-11-22. No step below has been run by anyone.

**Where:** the UTM throwaway (disposable) macOS VM. Never on Jason's Mac. These tests quit Desktop, rewrite a login and edit a Claude home.

**Who runs what:** an agent does not run `save`, `switch`, `add` or `usage` against a real Desktop folder. On the VM Jason runs them, or says in that session that the agent may.

## Background

The review compared claude-multipass 0.15.2 (`f8d607c`) with llm-router v8.1.0-1 (`eb84a3ba`). Both sessions read source and ran read-only commands on Jason's Mac. Labels: **read** is source read on 2026-11-22, **ran** is a read-only command that day, **Jason** is his word that day.

1. **read.** Multipass has no Claude Code home per profile, never sets `CLAUDE_CONFIG_DIR` and never writes `settings.json`. Its one write to `~/.claude.json` replaces `oauthAccount` and keeps every other key (`bin/claude-multipass:1008`), under Claude Code's lock dirs (`bin/claude-multipass:796`).
2. **read.** llm-router's `claude-code` local provider reads the Keychain item `Claude Code-credentials`, refreshes it at `platform.claude.com/v1/oauth/token` and writes the rotated pair back with `security add-generic-password -U` (`packages/core/src/agents/local-providers/claude-code.ts:36`, `:299`, `:411`). It takes no lock dir. Before the write it re-reads the item and adopts it when the refresh token differs from its baseline (`:356`).
3. **Jason.** That provider was enabled the last time the VM was used to test LLM Router.
4. **read.** llm-router rewrites a whole `.claude.json` to set `autoCompactWindowsCache`, with no lock (`packages/core/src/profiles/service.ts:2388`, `:2896`). In v8.0.0 and later it skips that write when the settings file is in `~/.claude`. A settings file directly in `$HOME` still makes it write `~/.claude.json`. llm-router plans a fix that compares resolved paths.
5. **ran.** `autoCompactWindowsCache` is Claude Code's own key. The 2.1.330 binary holds the string 5 times.
6. **read.** `llmr <profile> app` sets or deletes `CLAUDE_CONFIG_DIR` itself (`packages/core/src/agents/claude-app/launch.ts:83`), launches with `open -W -n` detached and returns before Desktop is up. The Desktop data folder is `<settings dir>/.llm-router/claude-app-user-data/<profile id>`.
7. **read.** A profile with `claudeAppTakeover` on writes the shared `Claude-3p` data folder, which a plain `open -a Claude` reads. Multipass relaunches with exactly that (`bin/claude-multipass:1059`).
8. **ran.** Jason's Mac has `llmr` 7.2.0 installed. At that tag every non-shared profile gets `CLAUDE_CONFIG_DIR`, `~/.claude` included. It left `~/.claude/.claude.json` and two `.llmr-*` copies there, dated 2026-10-28.
9. **read.** llm-router writes `apiKeyHelper` into `settings.json` in its helper auth mode and only ever removes `ANTHROPIC_AUTH_TOKEN` and `ANTHROPIC_API_KEY`. `doctor` already reads `apiKeyHelper` (`bin/claude-multipass:1622`).

### llm-router v9.0.0 (2026-11-24)

llm-router released v9.0.0 after the review. Read in its source at tag `v9.0.0` on 2026-11-24:

10. **read.** Finding 2 no longer holds. The `claude-code` local provider is 36 lines that register a `Claude Code API` provider and bind a pass-through hook (`packages/core/src/agents/local-providers/claude-code.ts`). It reads no Keychain item, refreshes nothing and writes nothing back. Its own description: it forwards the login Claude Code sends, only from a Claude Code profile in Claude login mode, and stores nothing.
11. **read.** The `$HOME` case of finding 4 is fixed. `writeClaudeCodeAutoCompactWindowsCache` returns before the write when `isClaudeCodeAccountFile` says the file is `.claude.json` in the home folder, with symlinks and letter case resolved (`packages/core/src/profiles/service.ts:2411`, `packages/core/src/agents/claude-code/environment.ts:55`).
12. **read.** Finding 9 has a third auth mode beside the helper and WIF modes. In `claude-login` mode LLMR writes its gateway key into `ANTHROPIC_CUSTOM_HEADERS` (header `x-llmr-api-key`) and removes its own `apiKeyHelper` (`service.ts:2897`, `:1591`). `doctor` reads neither `ANTHROPIC_CUSTOM_HEADERS` nor `ANTHROPIC_BASE_URL`, so it does not warn for such a profile.

## Before the first test

Unknown today, so settle each on the VM before running anything:

- [ ] The VM's name in UTM and how a session reaches it (shared folder, ssh, or Jason at its screen).
- [ ] `llmr --version` on the VM. Tests 1 to 7 assume v8.0.0 or later. Test 8 covers the upgrade from 7.2.0.
- [ ] `claude --version` and the Claude Desktop version on the VM.
- [ ] `claude-multipass --version` on the VM, 0.15.2 or later.
- [ ] Two claude.ai accounts saved as multipass profiles on the VM (call them A and B), each with a CLI login (`list` shows no "no CLI login" note). Tests 4, 5 and 7 need both.
- [ ] One LLMR profile for Claude Code, global scope, settings file `~/.claude/settings.json` (the System default case), saved in multipass with `save router --llmr <llmr-profile>`.
- [ ] The `claude-code` local provider enabled in the VM's LLMR config, and the gateway running (`curl -fs http://127.0.0.1:3456/health`).
- [ ] A snapshot of the VM, so each test starts from the same state.

## Tests

Each test names the claim it settles, the steps, and what pass and fail look like. Write the outcome in the results table at the end, with the date and the versions.

### 1. A switch away ends LLM Router's Desktop

Settles the comment at `bin/claude-multipass:2086`, the help text for `save --llmr` and the last lines of the Claude-3p paragraph in `docs/claude-multipass.md`, which all say this is "not yet checked against a real llmr launch".

- [ ] `claude-multipass switch router`. Expect `Switched to router (terminal: run llmr <llmr-profile>)` within 10 s.
- [ ] `pgrep -axfl Claude`. Expect one process whose arguments hold `--user-data-dir=` and `/claude-app-user-data/`. Note the process name: the quit depends on it being exactly `Claude`.
- [ ] `claude-multipass current` prints `router`. `cat ~/.config/claude-multipass/active-llmr` prints `router`.
- [ ] `claude-multipass switch A`.
- [ ] `pgrep -axfl Claude`. Pass: no process with `claude-app-user-data` remains, one Desktop runs on the default folder, `current` prints `A`, and `active-llmr` is gone. Fail: LLMR's instance still runs. Record whether the AppleScript quit or the `pkill` after 8 s ended it (run the switch with `--debug` and read the log).

### 2. The 10 s wait is long enough

Settles `llmr_wait_up` (`bin/claude-multipass:1086`).

- [ ] From a cold start (Desktop not running, after a VM reboot), time `claude-multipass switch router`. Pass: it succeeds. Record the seconds between `Launching Claude through LLMR profile` and `Switched to`. A failure with `did not start through llmr ... within 10 s` on a healthy launch means the wait is too short.

### 3. A takeover profile and a multipass relaunch

Settles the claim in `docs/claude-multipass.md` that with a third-party gateway active "a switch ... can relaunch the gateway's instance instead of the account you picked".

- [ ] In LLMR, turn `claudeAppTakeover` on for an app-surface profile. Confirm `~/Library/Application Support/Claude-3p` exists.
- [ ] `claude-multipass switch B`.
- [ ] Look at which Desktop came up and which account it shows. Pass for the docs: the result matches the paragraph, whichever way it goes. If Desktop comes up on account B with takeover on, the paragraph is wrong and needs a rewrite. Record what `current` prints.
- [ ] Turn takeover off again.

### 4. A switch during LLM Router's token refresh

Retired 2026-11-24. llm-router v9.0.0 has no refresh and no write-back to race a switch (finding 10), so there is nothing to run.

### 5. The gateway follows the switch

Settles what finding 10 implies: after a switch from A to B, a Claude login mode profile's traffic runs on B.

- [ ] With llm-router v9.0.0 or later, a `Claude Code API` provider and a Claude Code profile with "Sign in with my Claude login" on, start `llmr <llmr-profile>` on A and send one request. Note which account LLMR's log or `/status` names.
- [ ] `claude-multipass switch B`. Send another request from that session, then one from a new `llmr <llmr-profile>` session.
- [ ] Record which account served each. There is no pass or fail: the result goes into the docs, because a user may not expect a switch to move the gateway's subscription, and the running session may keep A until it reads the login again.

### 6. Claude Code and `autoCompactWindowsCache`

Settles whether llm-router's planned restore can delete the key safely.

- [ ] In a throwaway `CLAUDE_CONFIG_DIR`, run `claude` once, then `jq 'has("autoCompactWindowsCache")' "$CLAUDE_CONFIG_DIR/.claude.json"`.
- [ ] Delete the key with `jq 'del(.autoCompactWindowsCache)'`, run `claude` again, and read the key again.
- [ ] Record whether Claude Code writes the key on its own, and whether it writes it back after a delete. Send the result to the llm-router project.

### 7. A System default LLMR terminal session across a switch

Settles the open question carried in the handoffs since 2026-11-19: whether an LLMR-wrapped System default session writes a rotated login back after a switch. Also checks the v8.0.0 wording in the help page and `README.md`.

- [ ] In terminal 1, `llmr <llmr-profile>` (the System default profile). Inside it, `env | grep -c CLAUDE_CONFIG_DIR`. Pass for the docs: 0.
- [ ] In that session, confirm it is on account A (`/status`).
- [ ] In terminal 2, `claude-multipass switch B --debug`.
- [ ] Use the session in terminal 1 for a few turns, then leave it idle past one access-token lifetime if the VM run allows.
- [ ] In terminal 2, `claude auth status`. Pass: still B. Fail: A again, which means the wrapped session wrote its login back. The `--debug` watch log shows a rewrite inside its 30 s.

### 8. Upgrade from 7.2.0 and the old leftovers

Settles how an upgrade treats what the old rule wrote (finding 8).

- [ ] On a VM snapshot with `llmr` 7.2.0 and a System default profile applied, list `~/.claude/.claude.json*` and `~/.claude.json*`.
- [ ] Upgrade to the current llm-router, apply the profile again, then restore it.
- [ ] List both sets of files again. Record what was added, changed or removed. Pass: `~/.claude.json` is byte-identical before and after (`shasum`), apart from changes Claude Code itself made.

### 9. The per-directory Keychain item name

Settles the R label on the `Claude Code-credentials-<8 hex>` item in `.claude/rules/desktop-internals.md` (CLI credentials, and open test 6). llm-router's source says it was verified against Claude Code 2.1.220.

- [ ] In a throwaway `HOME` with `CLAUDE_CONFIG_DIR` set, put a logging `security` stub first on PATH and run `claude`. Read the service names the stub recorded.
- [ ] Repeat with `CLAUDE_CONFIG_DIR` set to the default directory, `$HOME/.claude`. llm-router PR 126 says the name is suffixed even then.
- [ ] Relabel the fact to M with the Claude Code version.

### 10. llm-router's `$HOME` fix

Owned by the llm-router project, and built in v9.0.0 (finding 11). Listed here so multipass's dependency on it is checked on a real run.

- [ ] With a profile whose settings file is directly in the home folder, apply it. Pass: `~/.claude.json` is byte-identical before and after.
- [ ] Repeat with the home folder reached through a symlink.

## Not a test: decisions waiting on Jason

- Decided 2026-11-22, shipped in llm-router v9.0.0: llm-router forwards the login and no longer refreshes or writes it back, so it takes no refresh lock.
- Whether `doctor` should warn on an `ANTHROPIC_BASE_URL` or `ANTHROPIC_CUSTOM_HEADERS` line in `~/.claude/settings.json` (finding 12).
- Whether to remove `~/.claude/.claude.json` and its two `.llmr-*` copies from Jason's Mac. Nothing reads them under v8.
- Whether `llmr` should report its port, profile id and Desktop data folder in a machine-readable form. Until it does, a custom gateway port makes `list` and `current` say "gateway not running" (`bin/claude-multipass:1116`, a marked shortcut).

## When a test is done

- Write the row in the table below.
- Tests 1 and 2: remove "not yet checked against a real llmr launch" from the script comment, the help page and `docs/claude-multipass.md`, in a PR, since the script changes.
- Tests 3, 5 and 7: correct or extend `README.md` and `docs/claude-multipass.md` to match what was seen.
- Test 7 failing: that is a bug report for llm-router or a new guard here. Stop and decide with Jason.
- Test 9: relabel in `.claude/rules/desktop-internals.md` and `docs/research.md`.
- When every row is filled, move this file to `completed/`.

## Results

| Test | Date | Versions (llmr, claude, Desktop, multipass) | Result |
| --- | --- | --- | --- |
| 1 |  |  |  |
| 2 |  |  |  |
| 3 |  |  |  |
| 4 |  |  | retired 2026-11-24 |
| 5 |  |  |  |
| 6 |  |  |  |
| 7 |  |  |  |
| 8 |  |  |  |
| 9 |  |  |  |
| 10 |  |  |  |
