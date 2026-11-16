# Truthful CLI login surfaces implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Desktop launches with a clean environment, the debug watch says what happened to the CLI login and what to do, and the popover says which account the terminal is on instead of implying it works.

**Architecture:** `desktop_launch` runs `open` under `env -i`, as a Dock launch would. `debug_watch` classifies each change into one of three messages that use profile names, not account ids. `list --json` gains `cliAccount`, read from `~/.claude.json` with no Keychain access, and `Snapshot` turns it into the popover's clause.

**Tech Stack:** bash 3.2 (`set -euo pipefail`), `jq`, Swift 6 / SwiftUI, the fixture self-check `test/claude-multipass.sh`, Swift Testing.

**Spec:** this plan carries its own spec in the Findings section below (the 2026-11-02 real switch on 0.12.0).

## Findings

Labels: **M** measured on this Mac on 2026-11-02 and 2026-11-03, **S** read in source, **I** inferred.

1. **M.** A real switch to spoons (debug log, 00:06:14-00:06:25 UTC) wrote spoons' login at 00:06:20. The live item changed at 00:06:25, 2 s after the relaunch, to empty tokens and `expiresAt` 0, which is Claude Code's cleared shape. The popover showed `debug: CLI login changed after the switch (now c6b83d23-0cb2-48b3-aa16-e0fe39220a2e); see /Users/jason/.config/claude-multipass/debug.log`.
2. **S.** The tool already recognises that shape: `cli_cleared` (`bin/claude-multipass:625`), used by `cli_capture` and `cli_restore`. The watch does not call it. It also cannot today, because `cli_token_hash` (`:539`) reads inside `$(...)`, so the parent never sees `cli_live`.
3. **M.** `claude auth status` said nothing wrong at the swap: `cli_verify` ran on the restored dead login and raised no warning. It reports `loggedIn=false` only after the clear. So no check at switch time can tell a dead saved token, and the only proof would be a refresh, which the rules reject (`.claude/rules/safety-and-terms.md`).
4. **S.** `terminal login too` (`app/Sources/ClaudeMultipass/PopoverView.swift:94`) comes from `cliSaved`, which is only whether `cli.json` exists (`bin/claude-multipass:1600`). So it was wrong twice on 2026-11-02: with Desktop on spoons and the terminal on gmail, and with the terminal signed out.
5. **M.** `oauthAccount` stays in `~/.claude.json` after a clear (`/status` showed spoons' email with `Login: Expired`). So that file can tell another account from this one with no Keychain read, and cannot tell a dead login. Nothing outside the Keychain can.
6. **M.** Reading it is cheap: `jq` on the 160 KB file took 36 ms, against 586 ms for a whole `list --json`.
7. **S.** A login the user fixes with `claude auth login` is captured by the re-save on the next switch away (`cli_capture`), so a skipped `save` is not lost. Claude Code itself says `Login: Expired - log in again`. So a switch with debug off needs no new check.

8. **M.** `open` passes the caller's whole environment to the app it launches (a throwaway probe app, 2026-11-03). `PROBE_X=1 open` delivered it, with 155 variables. `env -u PROBE_X open` removed only that one, leaving 154 and every `CLAUDE_*`. `env -i HOME=... USER=... open` delivered 16 names, the launchd baseline, `PATH` included.
9. **M.** So the environment travels down the chain. Step 10 of the release skill ran `open -a 'Claude Multipass'` from an agent session at 19:00:49, so the menu bar app (pid 68662) holds that session's `CLAUDE_CODE_*`, `TERM=dumb` and `PATH`. Its debug switch at 19:06:23 ran `open -a Claude`, so Desktop (pid 79473) holds all of those plus `CLAUDE_MULTIPASS_DEBUG=1`, and every session it spawns inherits them. Turning the toggle off clears nothing until Desktop and the app next launch clean. A terminal `switch` has the same leak, with the terminal's environment.
10. **M.** The self-check does not isolate that variable. In a session that inherited it, `test/claude-multipass.sh` fails at `the config lock is touched while held` with `test: : integer expected`, on `main` with no code change, and it passes with `env -u CLAUDE_MULTIPASS_DEBUG`. So the commit gate blocks every commit in such a session. **I:** the debug watch reads the CLI item after the locks are released, so the `SECURITY_HOLD` stub's `stat` of the gone lock writes an empty file.
11. **M, then guess.** The Desktop that spawned the `claude` beside the clear (pid 79652) had that polluted environment, including `CLAUDE_CODE_OAUTH_SCOPES=user:inference` and `CLAUDE_CODE_SDK_HAS_HOST_AUTH_REFRESH=1`. `USE_STAGING_OAUTH` and `USE_LOCAL_OAUTH` are blank, and `CLAUDE_CODE_OAUTH_TOKEN` and `ANTHROPIC_API_KEY` are absent. So "spoons' saved token was already dead" (Finding 1) is still the likeliest cause but is not proven, because whether those two inherited flags changed how that `claude` handled the login is unmeasured. That cannot be settled now, because signing in replaced spoons' old token, so the plan treats the cause as open and fixes both paths.

Decisions, with reasons:

- No new check with debug off. A dead token cannot be detected ahead of time (Finding 3), a wait after every relaunch would only catch a clear that happens to land in it, and Claude Code already tells the user.
- No `claude auth status` from the poll. It reads the Keychain, and the poll must not (`.claude/rules/safety-and-terms.md`).
- `env -i` for Desktop, not `env -u`. Finding 8 shows `env -u` leaves the rest of the caller's environment, and a Dock launch is the case Desktop is built for.
- `llmr` keeps the caller's `PATH` and takes only `env -u CLAUDE_MULTIPASS_DEBUG`. It is a script that needs its tools on `PATH`, and what it needs from its environment is unmeasured.
- The app's own environment handling does not change. Once `desktop_launch` is clean, what the app holds stops reaching Desktop.
- `AccountRow`'s `Desktop and terminal login` stays. It says what a switch moves, and that is true. The current-account line is the one that claims a present state.

## Global Constraints

- bash 3.2: no `<<<`, no new heredoc in the script, `${arr[@]+"${arr[@]}"}` for possibly empty arrays.
- Anything the agent itself launches from a session passes that session's environment on, so an agent relaunching the app uses `env -i` too.
- `list`, `list --json`, `show`, `current` and `doctor` never touch the Keychain and signal no process.
- The watch's Keychain reads stay inside `switch`, under debug only, through `security`. No token or token hash in output or `debug.log`.
- `debug_watch` runs as `debug_watch || true` from the trap and must not change the exit code.
- `list --json` must keep answering with a missing or corrupt `~/.claude.json`.
- An app built before this field and a tool without it must both still work: `cliAccount` absent decodes to nil.
- Prose: no em-dashes, short declarative sentences, straight quotes.
- **The self-check must never reach the real Keychain or launch a real app.** `env -i` drops the fixture's `PATH`, and the debug block's `dbg-at-open` runs `security add-generic-password` on `Claude Code-credentials` from inside the `open` stub. With no `PATH` line that is the real `/usr/bin/security`, overwriting the user's live login. So `desktop_launch` resolves `open` with `command -v` before `env -i`, and every `open` stub in the self-check starts by setting `PATH` to the fixture's `bin`.
- Self-check cost: the gate is about 6 min against a 600 s hook limit, so change existing runs' assertions and add at most one new `switch` run per task.

Exact copy, verbatim:

| Case | Text |
| --- | --- |
| Item in the cleared shape, or absent | `debug: the CLI login was cleared; run claude auth login, then save <name>` |
| Identity is another account | `debug: the CLI login went back to <label> after the switch to <name>; run claude-multipass switch <name>` |
| Token changed, identity is the target | `debug: the CLI login's token changed on <name>, usually an ordinary refresh; claude auth status shows the account it uses` |
| At the arm, wrong account | `debug: the CLI login is on <label>, not <name>` (replaces the id in today's line) |
| Popover, terminal on this account | `Desktop running · terminal on this account` |
| Popover, terminal on another saved account | `Desktop running · terminal on <name>` |
| Popover, terminal on an unsaved account | `Desktop running · terminal on another account` |
| Popover, no identity, or an LLMR current profile | `Desktop running` |

`<label>` is the saved profile holding that account id, else the id, else `unknown`. `Desktop not running` takes the same clauses.

## Review Focus

1. **An identity that changes after the token.** In the measured incident the Keychain item changed about a minute before `~/.claude.json`, so a write-back can read as the "ordinary refresh" message. That message must therefore name `claude auth status`. Task 1 asserts the exact copy.
2. **A clear already there at the arm.** `debug_arm` runs after `cli_verify`, and a clear can land before it. The cleared message must fire then too, once. Task 1 tests it.
3. **A cleared login that then stays cleared.** Later polls see the same pair, so the message must not repeat. Task 1 asserts one warning across 15 polls.
4. **A non-JSON or unreadable item.** It stays a failed read, never a "cleared" verdict. Task 1 keeps those checks.
5. **The terminal on an account no profile holds, or `~/.claude.json` corrupt.** The popover must not name a stranger's id, and `list --json` must still answer. Task 2 tests both.

---

### Task 0: Launch Desktop with a clean environment, and isolate the self-check

This task comes first, because without it the gate fails in any session that inherited the variable, and every later commit needs the gate.

**Files:**

- Modify: `bin/claude-multipass` (`desktop_launch`, and the `llmr` launch in `main`'s `switch` arm).
- Test: `test/claude-multipass.sh` (near the top beside the fixture's exports, and all five places that write `$tmp/bin/open`: the loop at `:31`, `:1609`, `:1888`, `:1911` and `:2161`).
- Docs: `docs/claude-multipass.md` ("Debugging a switch"), `.claude/rules/testing.md`, `.claude/rules/desktop-internals.md` (Findings 8 and 9 as **M**), `.claude/skills/release/SKILL.md` step 10, `CHANGELOG.md` under a new `## Unreleased`.

**Interfaces:**

- Produces: `desktop_launch` runs `env -i HOME="$HOME" USER="$USER" "$open_bin" -a Claude`, with `open_bin=$(command -v open)` taken first. The `llmr` launch runs under `env -u CLAUDE_MULTIPASS_DEBUG`.

- [ ] **Step 1: Write the failing tests**

Every `open` stub starts with `PATH="$tmp/bin:$PATH"` baked in. Reuse an existing debug-block relaunch run that sets `dbg_put_item` with refresh token `rt-rotated`, and have its stub write `/usr/bin/env` to `$tmp/open-env`.

```bash
export DBG_LEAK_PROBE=1
CLAUDE_MULTIPASS_DEBUG=1 dbg_run switch dbother
check "a debug run does not pass the variable to Desktop" 0 "$(grep -c '^CLAUDE_MULTIPASS_DEBUG=' "$tmp/open-env" || true)"
check "nor the caller's other variables" 0 "$(grep -c '^DBG_LEAK_PROBE=' "$tmp/open-env" || true)"
check "and HOME reaches it" 1 "$(grep -c '^HOME=' "$tmp/open-env")"
check_true "through the stub, not a real open" grep -q 'open -a Claude' "$tmp/calls"
check_true "and a write from the stub lands in the fixture Keychain" test "$(kc_get "Claude Code-credentials" "$USER" | jq -r .claudeAiOauth.refreshToken)" = rt-rotated
unset DBG_LEAK_PROBE
# in the existing LLMR case: the llmr stub records the variable, and it is absent
```

Beside the fixture's exports: `unset CLAUDE_MULTIPASS_DEBUG`. Its proof is that the whole file passes when started as `CLAUDE_MULTIPASS_DEBUG=1 bash test/claude-multipass.sh`.

- [ ] **Step 2: Run to verify they fail**

Run the self-check as in Task 1. Expected: FAIL at `a debug run does not pass the variable to Desktop`.

- [ ] **Step 3: Implement**

Add the `unset` and both launch changes. Do the stub `PATH` lines before the `env -i` change, so no run ever has one without the other.

- [ ] **Step 4: Run to verify they pass, and prove the Keychain guard**

Run `CLAUDE_MULTIPASS_DEBUG=1 bash test/claude-multipass.sh < /dev/null > "$LOG" 2>&1` in the background. Expected: `All claude-multipass checks passed`. To prove the guard without risking the real item, replace `security` in a scratch copy of the stub with a logger and confirm the `PATH` line decides which one runs. Never remove the `PATH` line in the real file and run it.

- [ ] **Step 5: Docs and commit**

Say in the docs that a switch launches Desktop with the environment a Dock launch gets. Change the release skill's step 10 to `env -i HOME="$HOME" USER="$USER" open -a 'Claude Multipass'` and say why. Record the `open` behaviour in `desktop-internals.md`, and the stub `PATH` rule in `testing.md`.

Commit subject: `Launch Desktop with a clean environment`

### Task 1: The watch says what happened

**Files:**

- Modify: `bin/claude-multipass` (`dbg_warning` `:511`, `cli_token_hash` `:539`, `debug_arm` `:550`, `debug_watch` `:572`, tldr and `--help` only where they quote a message).
- Test: `test/claude-multipass.sh` (the debug block, `:1930`, `:2015-2020`, `:2041`).
- Docs: `docs/claude-multipass.md` ("Debugging a switch", `:165`), `.claude/rules/desktop-internals.md` (Finding 3 as **M**: `claude auth status` passes on a dead saved login), `CHANGELOG.md`.

**Interfaces:**

- Produces:
  - `cli_live_fresh()`: clears `cli_live_rc`, calls `cli_live_read`, returns 0 on status 0 or 44, 1 otherwise. Runs in the caller's shell, so `cli_live` is visible.
  - `cli_token_hash()` keeps its name and its pipes, and now hashes the current `$cli_live` with no read of its own. It fails on non-JSON through `pipefail`.
  - `account_label <id>`: prints the saved profile holding that id, else the id, else `unknown`. Skips LLMR profiles, whose account is empty.
  - `debug_report_login <hash> <now>`: emits exactly one of the three messages from the copy table, then `dbg_claude_procs`.
  - Globals `cli_watch_name` and `cli_watch_want`, set by `debug_arm`, because the trap has no access to `main`'s locals.

- [ ] **Step 1: Write the failing tests**

Change the existing debug-block assertions to the new copy, and add these. `dbg_warned` becomes a count of lines starting `debug: the CLI login`.

```bash
# the existing write-back run: token change on the target, later token change, identity flip
check_true "a token change names the profile, not an id" grep -q "debug: the CLI login's token changed on dbother, usually an ordinary refresh; claude auth status shows the account it uses" <<< "$hs_err"
check_true "an identity flip says it went back" grep -q "debug: the CLI login went back to bbbbbbbb-flip after the switch to dbother; run claude-multipass switch dbother" <<< "$hs_err"
check "and no warning prints an account id for the target" 0 "$(grep -c 'dddddddd-7777' <<< "$hs_err" || true)"
# in the same run, one more dbg_at_poll flips the identity to beta's account (bbbbbbbb-2222); the counts of 3 warnings and 4 process lists become 4 and 5
check_true "an account with a profile prints its name" grep -q "went back to beta after the switch to dbother" <<< "$hs_err"
# the item goes to the cleared shape after the relaunch
dbg_put_item '{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0}}'
dbg_run switch dbother --debug
check_true "a cleared login says so and what to do" grep -q "debug: the CLI login was cleared; run claude auth login, then save dbother" <<< "$hs_err"
check "once across all 15 polls" 1 "$(dbg_warned)"
check "with no ordinary refresh message" 0 "$(grep -c 'usually an ordinary refresh' <<< "$hs_err" || true)"
# on the existing deleted-item run
check_true "a deleted item is the same message" grep -q "debug: the CLI login was cleared" <<< "$hs_err"
# on the existing emptied-refresh-token run, which is not the cleared shape
check_true "an emptied refresh token alone stays the token message" grep -q "token changed on" <<< "$hs_err"
# a run whose item is already cleared when the watch arms (the claude stub clears it in cli_verify)
check "a login cleared before the arm says so once" 1 "$(dbg_warned)"
# on the existing non-JSON and failed-read runs
check "a read that tells nothing is never called cleared" 0 "$(grep -c 'was cleared' <<< "$hs_err" || true)"
```

- [ ] **Step 2: Run the self-check to verify the new cases fail**

Run: `bash test/claude-multipass.sh < /dev/null > "$LOG" 2>&1` with `run_in_background: true`; in the foreground the agent shell dies with exit 144. Expected: FAIL at the first changed assertion.

- [ ] **Step 3: Implement**

The rule `debug_report_login` applies, in this order: `cli_live_rc` is 44 or `cli_cleared "$cli_live"` gives the cleared message; `<now>` differs from `cli_watch_want` gives the went-back message; otherwise the token message. `debug_arm` and `debug_watch` call `cli_live_fresh` then `cli_token_hash` in the parent. `debug_arm` reports a cleared login at once and then keeps watching. A cleared login that stays cleared changes no pair, so it never repeats. Drop `see <log>` from the warnings.

- [ ] **Step 4: Run the self-check to verify it passes**

Expected: `All claude-multipass checks passed`. Prove the checks can fail: remove the `cli_cleared` branch, then swap the went-back and token branches, and name the check that catches each.

- [ ] **Step 5: Docs and commit**

Replace the docs paragraph's message list with the three messages, what each means, and that a same-account change can still be a write-back because the identity file can lag (Review Focus 1). Add one `CHANGELOG.md` line under the `## Unreleased` Task 0 made.

Commit subject: `Say what happened to the CLI login in the debug watch`

### Task 2: The popover names the terminal's account

**Files:**

- Modify: `bin/claude-multipass` (`list_json` `:1588`, the `--help` field list `:241`).
- Modify: `app/Sources/MultipassCore/Models.swift` (`Snapshot` `:23`), `app/Sources/ClaudeMultipass/PopoverView.swift:94`.
- Test: `test/claude-multipass.sh`, `app/Tests/MultipassCoreTests/ModelsTests.swift`, the `snapshot` fixture in `app/Tests/ClaudeMultipassTests/ShotsTests.swift:42`.
- Docs: `docs/claude-multipass.md` (`:36`, `:73`, `:90`, `:180`), `CLAUDE.md` (`:68`), `.claude/rules/safety-and-terms.md` (`:39`, the sentence naming what the poll reads), `CHANGELOG.md`.

**Interfaces:**

- Consumes: `cli_signed_in_as` and `cli_blocker` in the script.
- Produces:
  - `list --json` top-level `cliAccount`: the id from `oauthAccount.accountUuid`, or `null` when signed out or when `cli_blocker` prints a reason.
  - `Snapshot.cliAccount: String?`, last parameter of `init`, default `nil`.
  - `Snapshot.terminalClause: String?`: the part after `·`, or nil.

- [ ] **Step 1: Write the failing tests**

```bash
check "list --json names the terminal's account" bbbbbbbb "$(cda list --json | jq -r .cliAccount | cut -c1-8)"
check "and null with no claude.json" null "$(<run with claude.json moved aside> | jq -r .cliAccount)"
check "and with a corrupt one, and it still answers" null "$(<run with a corrupt claude.json> | jq -r .cliAccount)"
check "and under CLAUDE_CONFIG_DIR" null "$(CLAUDE_CONFIG_DIR=$tmp/x cda list --json | jq -r .cliAccount)"
check "and reads no Keychain item" 0 "$(wc -l < "$tmp/security-calls" | tr -d ' ')"
```

```swift
@Test func terminalClauseSaysWhichAccountTheTerminalIsOn() {
  let beta = Profile(name: "beta", account: "b", savedAt: nil, sessions: 0)
  let alpha = Profile(name: "alpha", account: "a", savedAt: nil, sessions: 0)
  func clause(_ cli: String?, current: String? = "beta") -> String? {
    Snapshot(version: "0", signedIn: true, desktopRunning: true, current: current, profiles: [beta, alpha], cliAccount: cli).terminalClause
  }
  #expect(clause("b") == "terminal on this account")
  #expect(clause("a") == "terminal on alpha")
  #expect(clause("stranger") == "terminal on another account")
  #expect(clause(nil) == nil)
  #expect(clause("b", current: nil) == nil)
}

@Test func anLLMRCurrentHasNoTerminalClause() { /* a current profile with kind "llmr" gives nil */ }
@Test func aSnapshotFromAToolWithoutTheFieldHasNoClause() throws { /* decode today's JSON, no cliAccount: nil */ }
```

- [ ] **Step 2: Run to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path app --filter 'terminalClause|TerminalClause|WithoutTheField'`. Expected: FAIL, `cliAccount` not defined. The self-check, as in Task 1, fails at `list --json names the terminal's account`.

- [ ] **Step 3: Implement**

The script reads the identity once per `list --json`, guarded by `cli_blocker`. `PopoverView:94` appends ` · <clause>` when `terminalClause` is non-nil. `cliSaved` keeps its other uses. `AccountRow` does not change.

- [ ] **Step 4: Run to verify they pass, then render**

Run the swift tests and the self-check, expect PASS. Run `pnpm shots .shots` with the fixture's `cliAccount` set, read the popover PNGs light and dark, zoomed with `magick <png> -scale 400% <out> 2>/dev/null`, and confirm the line wraps without clipping at the popover's 320 pt width, with a profile name of 30 characters.

- [ ] **Step 5: Docs and commit**

Name `cliAccount` in the field lists and say the poll now also reads `oauthAccount` from `~/.claude.json`, never the Keychain. In the docs' popover paragraph, say the clause names the account and cannot say whether its login still works, and point at `claude auth status`. Add one `CHANGELOG.md` line.

Commit subject: `Name the terminal's account in the popover`

### Task 3: Gate and PR

- [ ] **Step 1:** Run `pnpm check` through the commit gate on each commit, and expect exit 0.
- [ ] **Step 2:** Push and open a PR against `main`, with the Findings summary and the Review Focus list. Say what was not run: a real switch, and whether Finding 11's two inherited flags had any effect.
- [ ] **Step 3:** Merging and releasing are Jason's call. After a release, reopen both apps from `/Applications` so neither holds an old environment, and confirm with `ps eww` that Desktop has no `CLAUDE_CODE_SESSION_ID`. Then the real check is the popover line with the terminal on another account, then a debug switch. With a clean Desktop, a switch that clears means that profile's saved login was dead, whatever happened at 00:06. A switch that does not clear means that login was alive, and says nothing about the old spoons token.
