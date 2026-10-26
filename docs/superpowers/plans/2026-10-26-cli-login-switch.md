# CLI login switch implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `save` and `switch` capture and restore the Claude Code CLI's terminal login per profile, so one switch moves Claude Desktop and the `claude` command together.

**Architecture:** The bash script gains Keychain helpers (`keychain_get`, `keychain_put`, `keychain_delete`), lock helpers (`cli_lock_all`, `cli_unlock`) and a `cli.json` identity file per profile; `profile_save` and `profile_restore` call them inside the existing re-save and backup flow. The CLI token only ever moves between two items of the login Keychain, as hex on `security -i`'s stdin. `list --json` reports `cliSaved` from the file's presence, and the menu bar app shows it plus the script's warnings. The fixture replaces its one-line `security` stub with a stateful one and points the script at a fixture `~/.claude.json`.

**Tech Stack:** bash 3.2, jq, `xxd` (ships with macOS), `/usr/bin/security`, SwiftPM (Foundation, SwiftUI), the fixture self-check.

**Spec:** `docs/superpowers/specs/2026-10-26-cli-login-switch.md`

## Global constraints

- Code goes on a worktree branch and a PR; nothing is committed on `main` (CLAUDE.md, Custom Notes).
- Every commit passes `pnpm check` (the commit-gate hook runs it); each task below ends in a green gate.
- No token on a command line, in output or in a log: the Keychain value goes through `security -i` on stdin as `-X <hex>`, the line under 3900 bytes counted under `LC_ALL=C` (spec 5). `security -i` stdout goes to `/dev/null` (it echoes prompts).
- The Keychain is touched only inside `save`, `add`, `switch`, `rename`, `remove` and the backup prune, through `security` on PATH; `list`, `list --json`, `show`, `current` and `doctor` never call it.
- Profiles hold no plaintext secret on disk; `cli.json` holds only `oauthAccount`.
- `~/.claude.json` is written only while the three CLI lock dirs are held, through `jq_write`, replacing the `oauthAccount` key alone (it re-indents the file with tabs; the CLI rewrites it in its own format on its next write, which is harmless).
- A non-44 `security` failure in the CLI part is a warning, never an abort of the Desktop switch.
- Every new behaviour, option or refusal gets a fixture case; every behaviour change edits README or `docs/` in the same commit.
- Prose: no em-dashes, short declarative sentences, sentence case. Version 0.3.0 in `bin/claude-multipass` and `package.json`; the app's floor rises to 0.3.0.

## Review focus

Inputs the spec implies that the tests must pin, most likely to bite first:

1. Restoring a profile while the CLI is already on that account must re-save the live tokens, never overwrite them with the saved copy (spec 4). Test in Task 3.
2. A re-save on switch-away while the CLI was signed in by hand as another account must leave the outgoing profile's `cli.json` and item untouched (spec 3). Test in Task 3.
3. A merged restore payload over 1900 bytes must skip the CLI part whole, backup included, with the warning (spec 5). Test in Task 3.
4. `~/.claude.json` keys other than `oauthAccount` must survive a restore with equal values (spec 4). Test in Task 3.
5. A stale lock dir must be removed and a fresh one must fail the switch before Desktop's config is restored (spec 6). Test in Task 3.

---

### Task 1: Fixture: stateful `security` stub and an isolated `~/.claude.json`

**Files:**

- Modify: `test/claude-multipass.sh:23-34` (isolation and stubs), `test/claude-multipass.sh:258-260` (the old `security` stub), `test/claude-multipass.sh:322-326` (`doctor never calls security`)
- Modify: `.claude/rules/testing.md` (Stubs, Isolation, Fixture layout bullets)

**Interfaces:**

- Produces: `$tmp/bin/security`, a stateful stub answering `add-generic-password -U -a A -s S -X HEX` (as a line on stdin after `-i`, decoded with `xxd -r -p`; the argv form with `-w` or `-X` is answered too, so a drift to argv is visible in the log), `find-generic-password -a A -s S -w` (prints the value, exit 44 when absent) and `delete-generic-password -a A -s S` (exit 44 when absent), items in `$tmp/keychain/<S>/<A>`, every invocation and every stdin line logged to `$tmp/security-calls` (never `$tmp/calls`), the fixture password still printed for service `Claude Safe Storage`. Env `CLAUDE_CLI_CONFIG=$tmp/claude.json` and `CLAUDE_CLI_HOME=$tmp/claude-home` exported beside the existing two, with `mkdir -p "$tmp/claude-home"`. Fixture helpers `kc_get S A` (prints the value or `absent`) and `kc_put S A VALUE`.
- The `-i` line is split on spaces with `set --` after stripping the double quotes around `-a` and `-s` values (the script emits exactly that shape; hex has no spaces), so no `eval`.

- [ ] **Step 1: Write the stub, the env exports and the helpers** at `test/claude-multipass.sh:23-34`, before any `cda` call. Move the `pw` fixture password up with it and delete the one-line stub at line 260.

- [ ] **Step 2: Add the stub's own cases** right after it

```sh
printf 'add-generic-password -U -a "u" -s "t" -X %s\n' "$(printf 'a "b" c'"'"'d' | xxd -p | tr -d '\n')" | security -i > /dev/null
check "security stub decodes a hex value" 'a "b" c'"'"'d' "$(kc_get t u)"
check "security stub reports a missing item" 44 "$(
  security find-generic-password -a u -s none -w > /dev/null 2>&1
  echo $?
)"
security delete-generic-password -a u -s t > /dev/null
check "security stub deletes" absent "$(kc_get t u)"
```

- [ ] **Step 3: Rewrite `doctor never calls security`** to count lines in `$tmp/security-calls` before and after `cda doctor`, equal counts.

- [ ] **Step 4: Run the fixture.** Run: `bash test/claude-multipass.sh`. Expected: `All claude-multipass checks passed` (the usage cases still get the fixture password).

- [ ] **Step 5: Update `.claude/rules/testing.md`** (Stubs: stateful `security`, log file `security-calls`, the hex line; Isolation: the two new env vars, HOME still untouched; Fixture layout: `claude.json`, `claude-home`, `keychain/`).

- [ ] **Step 6: Commit**

```bash
git add test/claude-multipass.sh .claude/rules/testing.md
git commit -m "Give the fixture a stateful security stub and a CLI config file"
```

### Task 2: `profile_save` captures the CLI login (with the Keychain helpers)

**Files:**

- Modify: `bin/claude-multipass:119-128` (paths), after `jq_write` at `:270-276` (helpers), `:352-374` (`profile_save`), header lines 17-23 and 80-98, `usage()` lines 188-193
- Modify: `docs/claude-multipass.md:7,37,94`, `README.md:25`
- Test: `test/claude-multipass.sh:63-77` (save section)

**Interfaces:**

- Produces, paths: `claude_json="${CLAUDE_CLI_CONFIG:-$HOME/.claude.json}"`, `cli_home="${CLAUDE_CLI_HOME:-$HOME/.claude}"`, `cli_service='Claude Code-credentials'`, `cli_account=${USER:-$(id -un)}`, `mp_service=claude-multipass`, `keychain_payload_limit=1900`.
- `keychain_get <service> <account>`: `security find-generic-password -a "$2" -s "$1" -w` as its last command, so the status (44 absent, anything else a failure) reaches the caller; callers write `v=$(keychain_get S A) || rc=$?`.
- `keychain_put <service> <account>`: reads the value from stdin, measures it under `LC_ALL=C`, returns 2 with `warning "the CLI login is too large for security -i"` when over `$keychain_payload_limit`, else writes `add-generic-password -U -a "<account>" -s "<service>" -X <hex>` as one line to `security -i > /dev/null`, returning `security`'s status.
- `keychain_delete <service> <account>`: `delete-generic-password`, 44 mapped to 0.
- `cli_signed_in_as`: prints `oauthAccount.accountUuid` from `$claude_json`, or nothing when the file or key is missing (`jq -r '.oauthAccount.accountUuid // empty' 2>/dev/null`).
- `cli_capture <name>`: the CLI part of a save. When `CLAUDE_CONFIG_DIR` is set: `warning "CLAUDE_CONFIG_DIR is set; the CLI login is not switched"`, return. When `cli_signed_in_as` differs from `live_account` or the live item read returns 44: `warning "Claude Code is signed in as a different account, or signed out; saved the Desktop login only"`, return, touching nothing. Else write `$dir/cli.json` (`jq_write "$dir/cli.json" '{oauthAccount}' "$claude_json"`) and `keychain_put "$mp_service" "$name"` with `jq -c '{claudeAiOauth, trustedDeviceToken} | with_entries(select(.value != null))'` of the live item; a non-44 read failure or a put failure is a warning naming the status. `profile_save` calls `cli_capture "$name"` after `meta.json`.

- [ ] **Step 1: Write the fixture `claude.json`, the live CLI item and the cases** at the top of the save section. Desktop is signed in as `alpha` (`aaaaaaaa-1111`) there, so `claude.json` has `oauthAccount.accountUuid` `aaaaaaaa-1111`, `organizationUuid` `org-alpha`, twenty other top-level keys including a nested object; the live item is `kc_put "Claude Code-credentials" "$USER" '{"claudeAiOauth":{"accessToken":"at-alpha","refreshToken":"rt-alpha","expiresAt":1,"scopes":["a"],"subscriptionType":"max"},"mcpOAuth":{"srv":"shared"},"trustedDeviceToken":"dev-alpha"}'`.

```sh
check "save writes cli.json with the identity block" "$(jq -c .oauthAccount "$tmp/claude.json")" "$(jq -c .oauthAccount "$p/alpha/cli.json")"
check "save keeps cli.json private" 600 "$(stat -f %Lp "$p/alpha/cli.json")"
check "save stores the CLI tokens in the Keychain" '{"claudeAiOauth":{"accessToken":"at-alpha","refreshToken":"rt-alpha","expiresAt":1,"scopes":["a"],"subscriptionType":"max"},"trustedDeviceToken":"dev-alpha"}' "$(kc_get claude-multipass alpha)"
check "save sends the token as hex on stdin" 0 "$(grep -c 'rt-alpha' "$tmp/security-calls")"
check "save never puts a token on argv" 0 "$(grep -c -- '-w ' "$tmp/security-calls")"
check "no token on disk in the store" 0 "$(grep -rl rt-alpha "$p" | wc -l | tr -d ' ')"
```

Then, with `oauthAccount.accountUuid` set to `zzzzzzzz-9999`: `cda save alpha --no-relaunch` keeps `$p/alpha/cli.json` and the item unchanged and prints the mismatch warning on stderr; `CLAUDE_CONFIG_DIR=/x cda save alpha --no-relaunch` prints its warning; with the live item deleted and the uuid restored, a save warns the same mismatch text and keeps the earlier item. Finally one oversize case: `kc_put` a live item with a 2000-byte `claudeAiOauth.accessToken` and assert the "too large" warning and an unchanged profile item.

- [ ] **Step 2: Run the fixture to see them fail.** Expected: `FAIL: save writes cli.json with the identity block`.

- [ ] **Step 3: Implement** the paths, the five helpers and the `profile_save` call. Comments explain the 4 KB `security -i` limit, why hex, and why the account uuid is the fingerprint.

- [ ] **Step 4: Run the fixture.** Expected: `All claude-multipass checks passed`.

- [ ] **Step 5: Docs in the same commit**: the `save` row, the login overview sentence (`docs/claude-multipass.md:7`), the profile folder table (`cli.json`), README line 25, the header tldr `save` bullet and the Profiles paragraph, `usage()` `save` text.

- [ ] **Step 6: Commit**

```bash
git add bin/claude-multipass test/claude-multipass.sh docs/claude-multipass.md README.md
git commit -m "Save the CLI login with the profile"
```

### Task 3: `switch` restores the CLI login (with the lock helpers)

**Files:**

- Modify: `bin/claude-multipass` helpers (after Task 2's), `:336-350` (`backup_login`), `:376-384` (`profile_restore`), `:867-883` (quit, trap and the `switch` branch), `usage()` lines 198-203, header `switch` bullet
- Modify: `docs/claude-multipass.md:39,55,70,97,104-106,108-117`, `README.md:36,69`
- Test: `test/claude-multipass.sh:80-120` (switch section)

**Interfaces:**

- Consumes: Task 2's helpers.
- Produces: `cli_locks=''` (global). `cli_lock <dir> <stale-seconds>`: removes `<dir>` when `stat -f %m` is older than the threshold, then tries `mkdir "$dir"` five times a second apart, appends to `$cli_locks` on success, else `fail "Claude Code holds $dir; retry in a moment"`. `cli_lock_all`: `cli_lock "$cli_home/.oauth_refresh.lock" 60`, `cli_lock "$cli_home.lock" 60`, `cli_lock "$claude_json.lock" 10`. `cli_unlock`: `rmdir` of each dir in `$cli_locks` with `2> /dev/null || true`. The trap line becomes `trap 'cli_unlock; desktop_launch' EXIT` (or `trap cli_unlock EXIT` with `--no-relaunch`), set right after `desktop_quit`; `cli_lock_all` runs right after it in the `switch` and `save` branches when the CLI part applies (`cli.json` present for the target, or the outgoing profile has one). `cli_running_warning`: `pgrep -x claude` found, `warning "Claude Code is running (pid N); quit it first, or its next token refresh can overwrite the switched login"`.
- `cli_restore <name>`: no `cli.json`: warn `no CLI login saved for <name>; switched Desktop only`, return. `cli_signed_in_as` equals the profile's `meta.json` account: `cli_capture "$name"` (the re-save, spec 4), return. Saved item read returns 44: warn `the saved CLI login for <name> is missing from the Keychain; run claude auth login, then save <name>`, return. Live item present and the merged payload over the limit: warn `the CLI login is too large for security -i; switched Desktop only`, return, nothing written. Else `cli_backup` (below), `keychain_put "$cli_service" "$cli_account"` with `(live | del(.claudeAiOauth, .trustedDeviceToken)) + saved` (saved alone when no live item), then `jq_write "$claude_json" --slurpfile c "$dir/cli.json" '.oauthAccount = $c[0].oauthAccount' "$claude_json"`, then `cli_verify`.
- `cli_backup <dest>`: inside `backup_login` after the cookies, when a live item exists: `keychain_put "$mp_service" "$(basename "$dest")"` with the live item and `jq_write "$dest/cli.json" '{oauthAccount}' "$claude_json"`; the prune loop calls `keychain_delete "$mp_service" "$(basename "$old")"` per removed folder. Because the live item is read once, `cli_restore` reads it under the locks and passes it to `cli_backup` through a variable rather than a second `security` call.
- `cli_verify <org>`: when `command -v claude` succeeds, `claude auth status | jq -r .orgId` must equal `<org>`, else `warning "Claude Code reports a different org; the previous login is in $dest"`.
- The "already signed in" path calls `backup_login` then `cli_restore "$name"` beside the cookie re-copy.

- [ ] **Step 1: Write the failing cases.** Beta is hand-written at test:75; give it `kc_put claude-multipass beta '{"claudeAiOauth":{"accessToken":"at-beta","refreshToken":"rt-beta","expiresAt":2,"scopes":["a"],"subscriptionType":"max"}}'` and `$p/beta/cli.json` with `accountUuid` `bbbbbbbb-2222`, `organizationUuid` `org-beta`. A `claude` stub on `$tmp/bin` prints `{"orgId":"org-beta"}`. Save `$tmp/claude-before.json` first. After the existing `cda switch beta`:

```sh
check "switch restores the CLI tokens" at-beta "$(kc_get "Claude Code-credentials" "$USER" | jq -r .claudeAiOauth.accessToken)"
check "switch keeps the shared MCP keys" '{"srv":"shared"}' "$(kc_get "Claude Code-credentials" "$USER" | jq -c .mcpOAuth)"
check "switch drops the previous device token" null "$(kc_get "Claude Code-credentials" "$USER" | jq -r .trustedDeviceToken)"
check "switch replaces oauthAccount" bbbbbbbb-2222 "$(jq -r .oauthAccount.accountUuid "$tmp/claude.json")"
check "switch leaves the other claude.json keys as they were" "$(jq -S 'del(.oauthAccount)' "$tmp/claude-before.json")" "$(jq -S 'del(.oauthAccount)' "$tmp/claude.json")"
dest=$(sed -n 's/^Backed up the current login to //p' "$tmp/switch-out")
check "switch backs up the previous CLI tokens" at-alpha "$(kc_get claude-multipass "$(basename "$dest")" | jq -r .claudeAiOauth.accessToken)"
check "switch backs up the previous identity" aaaaaaaa-1111 "$(jq -r .oauthAccount.accountUuid "$dest/cli.json")"
check "switch re-saves the outgoing CLI login" at-alpha "$(kc_get claude-multipass alpha | jq -r .claudeAiOauth.accessToken)"
check "switch releases the CLI locks" 0 "$(ls -d "$tmp"/claude.json.lock "$tmp"/claude-home/.oauth_refresh.lock "$tmp"/claude-home.lock 2> /dev/null | wc -l | tr -d ' ')"
```

The existing `cda switch beta` call must capture stdout to `$tmp/switch-out`, and the "one backup folder" check at test:113 counts folders, which this flow keeps at one. Then add, each with its own `switch` call and `--no-relaunch` where the surrounding flow uses it:

- same-account re-save (review focus 1): with the CLI on `bbbbbbbb-2222` and the live access token changed by hand to `at-beta-fresh`, `cda switch beta` prints "already signed in", the live item still says `at-beta-fresh`, and `kc_get claude-multipass beta` now says `at-beta-fresh`;
- foreign hand login (review focus 2): set `oauthAccount.accountUuid` to `zzzzzzzz-9999` and the live token to `at-foreign`, `cda switch alpha`: `kc_get claude-multipass beta` still `at-beta-fresh`, the mismatch warning on stderr, and alpha restored (`at-alpha` live, uuid `aaaaaaaa-1111`);
- oversize (review focus 3): a live item with a 2000-byte `mcpOAuth` value, `cda switch beta`: the live item unchanged, no new backup item, the "too large" warning, `oauthAccount` unchanged, Desktop switched;
- legacy profile (review focus 5 of the spec): `mkdir "$p/legacy"` with `meta.json` (`cccccccc-3333`) and `config.json` only, `cda switch legacy`: `oauthAccount` unchanged, the "no CLI login saved" warning;
- missing item: `cli.json` present for a profile whose item was deleted, the "missing from the Keychain" warning, `oauthAccount` unchanged;
- stale and fresh locks (review focus 5): `mkdir "$tmp/claude-home/.oauth_refresh.lock"` with `touch -t 202001010000`, a switch succeeds and the dir is gone; `mkdir "$tmp/claude.json.lock"`, a switch exits 1, `oauthAccount` unchanged and Desktop's `config.json` unchanged (`cmp` against a copy taken before), then `rmdir`;
- verification: the `claude` stub printing `{"orgId":"org-other"}`, a switch exits 0 and the warning names `$dest`; the stub removed from PATH, no warning;
- running session: a `pgrep` stub that exits 0 with `4242` for `-x claude` (and 1 otherwise, as today), the "Claude Code is running (pid 4242)" warning on a switch;
- prune: the existing eleven-folder case at test:251 gives each fake folder a `kc_put claude-multipass login-<name>` item; after the prune the oldest item is `absent` and ten remain.

- [ ] **Step 2: Run the fixture to see them fail.** Expected: `FAIL: switch restores the CLI tokens`.

- [ ] **Step 3: Implement** the lock helpers, `cli_running_warning`, `cli_backup`, `cli_restore`, `cli_verify`, the `backup_login` and `profile_restore` changes, the trap line, and the `switch` branch.

- [ ] **Step 4: Run the fixture.** Expected: all `ok`.

- [ ] **Step 5: Docs in the same commit**: the `switch` row; a new table row at `:55` for the CLI login (what moves, the running-session and Code-tab caveats from spec 9); the Desktop folder table (`~/.claude.json`, the Keychain items); the recovery bullets (the CLI backup item, the `invalid_grant` symptom that can appear hours later, `claude auth login` then `save`; a removed profile's CLI token is not recoverable); the Safety rails section (`~/.claude.json` writes under the CLI's locks, CLI backups); the Keychain prompt note in the menu bar section and README line 69; README line 36; the upgrade recipe (after `claude auth login`, the next switch away captures the login, spec 11).

- [ ] **Step 6: Commit**

```bash
git add bin/claude-multipass test/claude-multipass.sh docs/claude-multipass.md README.md
git commit -m "Restore the CLI login on switch"
```

### Task 4: `rename`, `remove`, forced `save`, `add`, `doctor`

**Files:**

- Modify: `bin/claude-multipass:687-692` (`profile_rename`), `:727-732` (`profile_remove`), `:360-362` (forced save), `:886-896` (`add` hint), `:537-583` (`doctor_report`), `usage()` lines 224-228 and 253-262
- Modify: `docs/claude-multipass.md:38,46`, `README.md`
- Test: `test/claude-multipass.sh` (rename at `:203`, remove at `:208`, force-save, add and doctor sections)

**Interfaces:**

- Consumes: `keychain_get`, `keychain_put`, `keychain_delete`.
- Produces: `profile_rename`: `v=$(keychain_get "$mp_service" "$1") || rc=$?`; on 0, `keychain_put` under `$2` and `keychain_delete` the old; on 44 nothing. `profile_remove` and the forced-save move call `keychain_delete "$mp_service" "$name"`. `add` prints `Sign in to Desktop, then run claude auth login for the terminal, then claude-multipass save <name>`. `doctor_report` adds `cli.json` to the mode loop, `warn: <name>: no CLI login saved` per profile without it, `warn: CLAUDE_CONFIG_DIR is set; the CLI login is not switched` when set.

- [ ] **Step 1: Write the failing cases** around the existing rename (`alpha` to `home` at test:203) and remove (`home` at test:208)

```sh
check "rename moves the CLI item" at-alpha "$(kc_get claude-multipass home | jq -r .claudeAiOauth.accessToken)"
check "rename removes the old CLI item" absent "$(kc_get claude-multipass alpha)"
check "remove deletes the CLI item" absent "$(kc_get claude-multipass home)"
check_true "doctor names a profile without a CLI login" grep -q '^warn: legacy: no CLI login saved' <<< "$(cda doctor)"
check_true "doctor warns on CLAUDE_CONFIG_DIR" grep -q '^warn: CLAUDE_CONFIG_DIR' <<< "$(CLAUDE_CONFIG_DIR=/x cda doctor)"
check_true "add says how to sign the terminal in" grep -q 'claude auth login' <<< "$(cda add other --no-relaunch)"
```

Add a rename of a profile with no item (the `legacy` profile) that succeeds, and a forced save over another account asserting the old item is `absent`. `doctor never calls security` stays and must still pass.

- [ ] **Step 2: Run the fixture to see them fail.** Expected: `FAIL: rename moves the CLI item`.

- [ ] **Step 3: Implement** the five changes.

- [ ] **Step 4: Run the fixture.** Expected: all `ok`.

- [ ] **Step 5: Docs and help text in the same commit.**

- [ ] **Step 6: Commit**

```bash
git add bin/claude-multipass test/claude-multipass.sh docs/claude-multipass.md README.md
git commit -m "Keep the CLI item in step through rename, remove and doctor"
```

### Task 5: `list --json` reports `cliSaved`; `show` prints it

**Files:**

- Modify: `bin/claude-multipass:656-674` (`list_json`), `profile_show`, `usage()` `list` text
- Modify: `docs/claude-multipass.md:35`
- Test: `test/claude-multipass.sh:141-148, 217-218`

**Interfaces:**

- Produces: each `profiles[]` object gains `cliSaved: true|false` (`[[ -f $dir/cli.json ]]`). `show <name>` prints `CLI login: saved` or `CLI login: not saved`.

- [ ] **Step 1: Write the failing cases** (the `legacy` profile from Task 3 exists by then; place these after it, or create `legacy` here if the sections run earlier)

```sh
check "list --json cliSaved true" true "$(jq -r '.profiles[] | select(.name == "beta") | .cliSaved' <<< "$out")"
check "list --json cliSaved false for a legacy profile" false "$(jq -r '.profiles[] | select(.name == "legacy") | .cliSaved' <<< "$out")"
check_true "show prints the CLI login state" grep -q '^CLI login: saved' <<< "$(cda show beta)"
```

- [ ] **Step 2: Run to see them fail.** Expected: `FAIL: list --json cliSaved true`.

- [ ] **Step 3: Implement** with `--argjson cliSaved` in the per-profile `jq -n`; no `security` call.

- [ ] **Step 4: Run the fixture.** Expected: all `ok`, `doctor never calls security` included.

- [ ] **Step 5: Commit**

```bash
git add bin/claude-multipass test/claude-multipass.sh docs/claude-multipass.md
git commit -m "Report whether a profile holds a CLI login"
```

### Task 6: Menu bar app: `cliSaved`, the script's warnings, the PATH and the floor

**Files:**

- Modify: `app/Sources/MultipassCore/Models.swift:38-51` (`Profile`), `app/Sources/MultipassCore/CLI.swift:3-11` (`CommandRunner`), `:50` (PATH), `:86-93` (return), `:104-109` (`isSupported`), `app/Sources/MultipassCore/AppState.swift:168-183` (`act`), `app/Sources/ClaudeMultipass/AccountRow.swift:25,53`, `app/Sources/ClaudeMultipass/SaveRow.swift:18`, `app/Sources/ClaudeMultipass/PopoverView.swift:23`
- Modify: `README.md:69`, `docs/claude-multipass.md:70` ("0.2.0 or newer")
- Test: `app/Tests/MultipassCoreTests/ModelsTests.swift`, `CLITests.swift`, `AppStateTests.swift`

**Interfaces:**

- Produces: `Profile.cliSaved: Bool`, decoded with `decodeIfPresent(Bool.self, forKey: .cliSaved) ?? false` in a hand-written `init(from:)`, and `cliSaved: Bool = false` as the last parameter of the memberwise `init`. `public struct CommandOutput: Sendable { public let stdout: Data; public let stderr: String }`; `CommandRunner` gains `func runCapturing(_ args: [String]) async throws -> CommandOutput` with a protocol-extension default that wraps `run` with an empty `stderr`; `CLI.runCapturing` returns both on status 0 and `run` returns `.stdout`. `CLI.run`'s PATH gains `$HOME/.local/bin` after `/usr/local/bin`. `CLI.isSupported` floor `[0, 3, 0]`. `AppState.act` uses `runCapturing` and sets a new `@Published public private(set) var rowNote: RowNote?` (`name`, `message`) from a non-empty `stderr` (ANSI stripped with `plainText`), cleared at the start of the next action; `dismissRowError` also clears it. `AccountRow` shows `rowNote.message` as a secondary caption under the row when `rowNote.name == profile.name`, a `"\(profile.sessions) sessions · CLI"` caption when `cliSaved`, and the confirm text gains `The terminal's claude login switches too.` when `cliSaved`, `The terminal's claude login stays as it is (no CLI login saved).` otherwise. `SaveRow` caption: `This login is not saved yet (Desktop, and the terminal when it is signed in as the same account).` `PopoverView` says `0.3.0 or newer`.

- [ ] **Step 1: Write the failing tests**

```swift
// ModelsTests.swift
@Test func decodesCliSaved() throws { /* the 0.3.0 shape with "cliSaved":true */ #expect(s.profiles[0].cliSaved == true) }
@Test func cliSavedDefaultsToFalse() throws { /* the 0.2.x shape */ #expect(s.profiles[0].cliSaved == false) }
// CLITests.swift
@Test func runCapturingReturnsStderrOnSuccess() async throws { /* a stub that prints to both and exits 0 */ #expect(out.stderr == "careful") }
@Test func versionFloorIs030() { #expect(CLI.isSupported("0.2.2") == false); #expect(CLI.isSupported("0.3.0")) }
// AppStateTests.swift
@Test @MainActor func switchWarningBecomesRowNote() async { /* FakeRunner.runCapturing returns stderr "switched Desktop only" */ #expect(s.rowNote == RowNote(name: "alpha", message: "switched Desktop only")) }
@Test @MainActor func nextActionClearsRowNote() async { ... }
```

`FakeRunner` (in `AppStateTests.swift:10`) gains an `onStderr: [String: String]` map consulted by its `runCapturing`.

- [ ] **Step 2: Run to see them fail.** Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path app`. Expected: compile errors on `cliSaved`, `runCapturing`, `rowNote`.

- [ ] **Step 3: Implement** the model, runner, state and view changes, and the two doc lines.

- [ ] **Step 4: Run the full gate.** Run: `pnpm check`. Expected: exit 0.

- [ ] **Step 5: Commit**

```bash
git add app README.md docs/claude-multipass.md
git commit -m "Show CLI login state and the script's warnings in the app"
```

### Task 7: Rules, agent instructions, changelog and version

**Files:**

- Modify: `.claude/rules/safety-and-terms.md` ("Profiles hold only encrypted tokens…", "The Keychain is read only for `usage`…", the terms-posture paragraph, the rejected bullet "a `security` call outside `usage`; reading the Keychain anywhere but inside `usage`")
- Modify: `CLAUDE.md` (Overview sentence, the agent rule on `usage` and the Keychain, Storage model bullets, the Safety rails bullets on the Keychain and "Profiles are per Mac")
- Modify: `.claude/rules/desktop-internals.md` (CLI credentials section: mark measured facts M, add the `security -i` 4019-byte and exit-45 quoting measurements, the hex write path the CLI itself uses, the three lock dirs, close open test 6; add that `oauthAccount.accountUuid` equals Desktop's `lastKnownAccountUuid`, M)
- Modify: `.claude/agents/docs-auditor.md:16` (add `cli.json` and `~/.claude.json` to the never-read list), `.claude/skills/release/SKILL.md` step 12 (verify adds `claude auth status`)
- Modify: `CHANGELOG.md` (`## Unreleased` section, one line per user-visible change), `bin/claude-multipass` `version=0.3.0`, `package.json` `0.3.0`

- [ ] **Step 1: Amend the rails** per spec 14: Keychain access allowed inside `save`, `add`, `switch`, `rename`, `remove` and the backup prune, for the CLI login item and the tool's own items; still rejected anywhere else; never a token on argv, in output or a log; `list --json` and `doctor` stay Keychain-free.

- [ ] **Step 2: Update CLAUDE.md, desktop-internals.md, docs-auditor.md, the release skill, the changelog and both version fields.**

- [ ] **Step 3: Run the gate.** Run: `pnpm check`. Expected: exit 0.

- [ ] **Step 4: Commit**

```bash
git add .claude CLAUDE.md CHANGELOG.md bin/claude-multipass package.json
git commit -m "Allow the CLI login swap in the rails and bump to 0.3.0"
```

### Task 8: Real-Mac verification (Jason, Desktop free, no `claude` sessions running)

**Files:** none. Record results in `.claude/rules/desktop-internals.md` open tests.

- [ ] **Step 1:** From the worktree, `bin/claude-multipass save <current>` with Desktop signed in as the account the terminal is on. Expected: `cli.json` in the profile, the item under `claude-multipass` (`security find-generic-password -s claude-multipass -a <current>` without `-w` shows it exists). Note whether any Keychain prompt appeared and what it said.
- [ ] **Step 2:** `bin/claude-multipass switch <other>` where `<other>` was saved with a CLI part. Expected: Desktop relaunches as `<other>`, `claude auth status` in a new terminal prints `<other>`'s email and org, no org warning.
- [ ] **Step 3:** Switch back. Expected: the first account's CLI works at once (`claude -p 'say ok'`), which settles the rotation question for a round trip through the tool. If `invalid_grant`, record it and run `claude auth login` then `save`.
- [ ] **Step 4:** One switch from the menu bar app built from the worktree (`scripts/build-app.sh`). Expected: the same, any warning visible under the row, and the prompt behaviour from step 1 repeated or absent.
- [ ] **Step 5:** Open the PR with the results in its description.
