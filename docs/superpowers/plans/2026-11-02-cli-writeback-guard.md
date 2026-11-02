# CLI login write-back guard implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A switch's CLI login stays switched while Hindsight's memory daemon is running, and a debug mode shows whether anything rewrote it afterwards.

**Architecture:** `bin/claude-multipass` gains a Hindsight pause (SIGSTOP the daemon, wait for its in-flight `claude` children, SIGCONT from the EXIT trap). The pause runs only when the daemon is found. A debug mode (`--debug` or `CLAUDE_MULTIPASS_DEBUG=1`) logs timings and process lists, and watches the CLI login for 30 s after the relaunch. The menu bar app gets one toggle that sets the variable on its runner.

**Tech Stack:** bash 3.2 (`set -euo pipefail`), `jq`, `security` on PATH, `pgrep`, the bash `kill` builtin; Swift 6 / SwiftUI for the toggle; the fixture self-check `test/claude-multipass.sh`; Swift Testing.

**Spec:** this plan carries its own spec in the Findings section below (the 2026-11-02 investigation). The decisions are Jason's, from 2026-11-02.

## Findings

Labels: **M** measured on this Mac on 2026-11-02, **S** read in source, **I** inferred.

1. **M.** Jason switched matherly-gmail to spoons from the popover on 0.11.0 at 15:01:39 local. Desktop quit and relaunched. No interactive Claude Code was running.
2. **M.** The switch wrote spoons' CLI login. `backups/login-20261102-150139-84939/cli.json` holds the gmail identity it replaced.
3. **M.** The live `Claude Code-credentials` item was rewritten at 15:01:56 (Keychain `mdat 20261102200156Z`). Its refresh token's hash matches none of the saved logins (spoons, matherly-gmail, matherly, the pre-switch backup), so it is a refresh-rotated token.
4. **M.** `~/.claude.json` `oauthAccount` went back to gmail (`1c7aa15d…`). Its `profileFetchedAt` is 15:01:40, a live profile fetch made with gmail's token one second into the switch. File mtime 15:02:56. Spoons' saved identity carries an Oct 31 fetch time, so the tool did not write this.
5. **M.** The Hindsight daemon `hindsight-api` runs as a plain process (`uv tool uvx hindsight-api@1.1.0 --idle-timeout 0 --port 9077` → python `…/bin/hindsight-api --idle-timeout 0 --port 9077`), not under launchd. With `HINDSIGHT_API_LLM_PROVIDER=claude-code`, its python process spawns one Claude Agent SDK `claude` per LLM call as a direct child (`…/claude_agent_sdk/_bundled/claude`, 2.1.316). The daemon env has no `CLAUDE_CODE_OAUTH_TOKEN`, so every child reads and writes the shared Keychain item and `~/.claude.json`.
6. **M.** Its log shows calls at 15:01:27-38, 15:01:39.9-52.5 (consolidation) and 15:01:52.6 onward, with 1723 calls on Nov 1-2.
7. **I.** A child that loaded gmail's login before the swap fetched gmail's profile and later wrote its rotated pair and identity back over spoons.
8. **S.** `cli_running_warning` (`bin/claude-multipass:591`) runs `pgrep -x claude` once and only warns. Spawn-per-call children start after it, so it never sees them.
9. **I, not measured.** The Oct 31 death of matherly-gmail's saved refresh token likely had the same cause: a background refresh rotated it after the save.
10. **M.** Current state is safe. The live item holds gmail's current pair and Desktop is spoons. A `switch matherly-gmail` takes the "already on target" path and re-saves the live pair.
11. **M.** A child that exits while its parent is stopped no longer matches `pgrep -P <parent> -x claude` (a compiled test binary named `claude` under a stopped `sh`, 2026-11-02). So waiting on children cannot hang on a zombie.
12. **I.** A child writes its `stream-json` output to a pipe its daemon reads. With the daemon stopped, a child that fills the pipe buffer blocks, and it already holds the old login. So the daemon must keep running while its children finish, and be stopped only once none is left.

Decisions (Jason, 2026-11-02):

- Pause Hindsight around the swap, but only when it is found. No dependency on Hindsight's own CLI.
- Add the post-switch check as a debug mode, plus other useful debug output. Make it reachable from the menu bar app.
- No controlled reproduction run; the evidence above is enough.

## Global Constraints

- bash 3.2: no `<<<`, no new heredoc (the self-check asserts the script has exactly one heredoc and no here-string), no associative arrays, `${arr[@]+"${arr[@]}"}` for possibly empty arrays.
- No token or token hash in output, `debug.log` or argv. Hashes are compared in memory only.
- `security` stays the only Keychain accessor. The debug watch reads `Claude Code-credentials` only inside `switch`.
- `list`, `list --json`, `show`, `current` and `doctor` stay Keychain-free and signal no process.
- Never kill a Hindsight process. Only `kill -STOP` and `kill -CONT` on the daemon pids found at pause time.
- The daemon is always resumed. The EXIT trap sends SIGCONT on every path: success, `fail`, a refusal after the pause, and a signal.
- Prose: no em-dashes, short declarative sentences, straight quotes.
- Exit codes are unchanged: refusals 3, failures 1, usage errors 2.
- Every new option and behaviour gets a case in `test/claude-multipass.sh`.
- `debug.log` is written only by `save`, `switch` and `add`, the commands that quit Desktop. `--debug` is accepted by every command and does nothing for the others, because the app's toggle reaches its 30 s `list` poll too.

## Review Focus

1. **A `fail` between the pause and the end.** For example, `cli_lock_all` fails on `switch` ("Claude Code holds …"). The daemon must still get SIGCONT. Task 1 tests a failure after the pause.
2. **Hindsight's hooks and MCP server talk to the frozen daemon.** Their HTTP calls stall for the pause. The wait is capped at 60 s, so the worst-case freeze is the quit plus 60 s plus the swap. The pause must end when the CLI part ends, not after the relaunch and the 30 s debug watch. Task 1 tests that CONT comes before `open -a Claude`.
3. **Hindsight is busy with no idle gap.** The pause waits for a moment with no `claude` child, then stops the daemon. After 60 s without one it stops the daemon anyway and names the children that were still running. Task 1 tests that a child alive at the first stop is waited out with the daemon running.
4. **The daemon exits or restarts during the pause.** SIGCONT to a dead pid must not fail the switch (`kill -CONT … 2> /dev/null || true`). Task 1 tests a pid that is gone by resume time.
5. **Debug mode in the app.** The toggle must take effect without a relaunch. AppState rebuilds the runner when it changes, as it does for `cliPathOverride`. Task 3 tests that the runner is rebuilt with the new setting.

---

### Task 1: Pause Hindsight's daemon around the CLI login swap

**Files:**

- Modify: `bin/claude-multipass`. New functions go beside `cli_running_warning` (`:591`). The pause call goes in `main` right after `desktop_quit` (`:1695`), before `cli_running_warning` (`:1702`). Both trap strings change (`:1694`). The CLI-part end goes after the `case $cmd in … esac` arms finish their CLI work. Header tldr notes and `--help` Cautions get updated.
- Test: `test/claude-multipass.sh`.

**Interfaces:**

- Produces:
  - Global `hindsight_paused=()`: the pids this run stopped.
  - `hindsight_pause()`: finds the daemon and stops it only once it has no `claude` child, prints one info line. Returns 0 always.
  - `hindsight_resume()`: SIGCONT to every pid in `hindsight_paused`, then empties it. Idempotent and safe from the trap.
  - `hindsight_daemon_pids()`: prints daemon pids, one per line, from `pgrep -f '/bin/hindsight-api( |$)'`.
  - `hindsight_children <pid…>`: prints the live `claude` children of the given pids (`pgrep -P <pid> -x claude` for each).
- Consumes: `sleep`, `info`, `warning`, the existing trap structure.

- [ ] **Step 1: Write the failing tests**

Fixture: start two real background processes, each a `sleep 300` (`fake_daemon`, `fake_wrapper`), and a short `sleep 2` (`fake_child`). Extend the existing `pgrep` stub (`$tmp/bin/pgrep`):

- `-f '/bin/hindsight-api( |$)'` prints `$(cat "$tmp/hindsight-pid")` when that file exists, otherwise exits 1. The wrapper pid is never printed, since the real wrapper does not match the pattern.
- `-P <pid> -x claude` prints `fake_child`'s pid while `kill -0` on it succeeds.

Extend the `security` stub to append `<state> children=<n>` to `$tmp/hindsight-states` on every call. `<state>` is `ps -o state= -p $(cat "$tmp/hindsight-pid")` and `<n>` is the number of live `claude` children the `pgrep -P` stub reports. The `pgrep -P` stub also appends `running-with-child` to `$tmp/hindsight-wait` when it reports a child while the daemon's state is not `T`. That records the daemon's state at each Keychain access. Extend the `open` stub to append the same state to `$tmp/hindsight-at-open`.

```bash
# switch with Hindsight running
check "switch stops Hindsight while it reads the CLI login" yes "$(grep -q '^T' "$tmp/hindsight-states" && echo yes)"
check "and resumes it before relaunching Desktop" no "$(grep -q '^T' "$tmp/hindsight-at-open" && echo yes || echo no)"
check "and leaves it running" no "$(ps -o state= -p "$fake_daemon" | grep -q '^T' && echo yes || echo no)"
check "and never signals the uvx wrapper" no "$(ps -o state= -p "$fake_wrapper" | grep -q '^T' && echo yes || echo no)"
check "and says so" yes "$(printf "%s" "$out" | grep -q "Paused Hindsight's memory daemon" && echo yes)"
check "and waits for its in-flight claude" gone "$(kill -0 "$fake_child" 2> /dev/null && echo alive || echo gone)"
check "no Hindsight claude is alive when the CLI login is read" yes "$(! grep -q 'children=[1-9]' "$tmp/hindsight-states" && echo yes)"
check "and the daemon runs while that child finishes" yes "$(grep -q 'running-with-child' "$tmp/hindsight-wait" && echo yes)"
# a failure after the pause: switch with cli_lock_all failing (pre-create "$tmp/home/.claude.lock")
check "a failed switch still resumes Hindsight" no "$(ps -o state= -p "$fake_daemon" | grep -q '^T' && echo yes || echo no)"
# no Hindsight: rm "$tmp/hindsight-pid"
check "switch without Hindsight pauses nothing" '' "$(printf "%s" "$out" | grep "Paused Hindsight")"
# the daemon gone before resume: the security stub kills fake_daemon on its first call
check "a daemon gone before resume does not fail the switch" 0 "$rc"
# a child that never exits within the cap: stub sleep to return at once and the child to stay alive
check "a child still running after 60 s is named and the switch goes on" yes "$(printf "%s" "$err" | grep -q 'still running after 60 s' && echo yes)"
```

Use whatever capture helpers the file already has for `$out`, `$err` and `$rc`. Kill the fixture processes at the end of the block.

- [ ] **Step 2: Run the self-check to verify the new cases fail**

Run: `bash test/claude-multipass.sh < /dev/null > "$S/sc.log" 2>&1 &` (background; in the foreground the agent shell dies with exit 144). Then `tail -3 "$S/sc.log"`. Expected: FAIL at "switch stops Hindsight while it reads the CLI login".

- [ ] **Step 3: Implement the pause in `bin/claude-multipass`**

- `hindsight_daemon_pids`: `pgrep -f '/bin/hindsight-api( |$)' 2> /dev/null || true`.
- `hindsight_pause`: return 0 when `hindsight_daemon_pids` prints nothing. Otherwise loop for at most 120 rounds of 0.5 s:
  - while the daemon has children, sleep 0.5 s with it running (its children need it to read their output);
  - when it has none, `kill -STOP` each daemon pid (record the ones that succeed in `hindsight_paused`), then check children once more;
  - none: done;
  - one appeared in that gap: `kill -CONT` the same pids, empty `hindsight_paused`, and go on looping.

  After the cap, stop the daemon anyway and `warning "Hindsight's claude (pid <pids>) was still running after 60 s; it may write back the login it loaded"`. When the daemon was stopped, `info "Paused Hindsight's memory daemon during the CLI login swap"`.

- `hindsight_resume`: `kill -CONT "$pid" 2> /dev/null || true` for each pid, then `hindsight_paused=()`.
- Comment for the why, one or two lines: Hindsight's `claude-code` LLM provider spawns a `claude` per call on the shared login, and a call that loaded the old login writes its rotated pair back after the swap (measured 2026-11-02).
- Call `hindsight_pause` right after `desktop_quit` in `main`. That point is before `cli_running_warning`, `cli_lock_all` and any `profile_save`, `cli_capture` or `cli_restore`.
- Call `hindsight_resume` at the end of the CLI part: after the `case` arms in `main`, before the function returns. That is before the trap's `desktop_launch`.
- Add `hindsight_resume;` at the start of both trap strings, ahead of `cli_unlock`, so every exit path resumes.

- [ ] **Step 4: Run the self-check to verify it passes**

Run it as in Step 2. Expected: `All claude-multipass checks passed`.

- [ ] **Step 5: Update the docs in the same commit**

- The `--help` Cautions and the header mechanism notes: one paragraph saying switch, save and add pause a running Hindsight daemon (`hindsight-api`) while they read or write the CLI login, and why.
- `docs/claude-multipass.md`: the same in the CLI-login section.
- `.claude/rules/safety-and-terms.md`: one rule line. The tool sends SIGSTOP and SIGCONT only to the `hindsight-api` daemon it found, never kills it, and always resumes it from the EXIT trap.
- `.claude/rules/desktop-internals.md`: Findings 3-7 as an **M** entry, Finding 9 as **I**. In Open tests item 8, add that a background agent-SDK `claude` does write back (measured).
- `CHANGELOG.md`: a new `## Unreleased` with one line for the pause.

- [ ] **Step 6: Commit**

```bash
node_modules/.bin/prettier --write CHANGELOG.md docs/claude-multipass.md bin/claude-multipass test/claude-multipass.sh
git add -A && git commit -m "Pause Hindsight's daemon while a switch moves the CLI login"
```

(Format in its own call before the commit; the commit-gate hook checks the tree first.)

### Task 2: Debug mode in the script

**Files:**

- Modify: `bin/claude-multipass`. The option parsing in `main` (`:1544`) and the trap strings change. `cli_restore` records what it wrote. New functions go beside the Task 1 functions. `--help` gains an Options line.
- Test: `test/claude-multipass.sh`.

**Interfaces:**

- Consumes: `hindsight_pause` and `hindsight_resume` from Task 1. Debug lines go at their start and end.
- Produces:
  - Global `debug`: set by `--debug` or a non-empty `CLAUDE_MULTIPASS_DEBUG`, then cleared unless the command is `save`, `switch` or `add`. `--debug` is accepted by every command.
  - `dbg <message…>`: no-op unless `debug`. Otherwise prints `debug: <HH:MM:SS> <message>` to stderr and appends `<ISO-8601 UTC> <pid> <message>` to `$root/debug.log`, created with mode 0600. At the first `dbg` of a run, the log is trimmed to its last 2000 lines.
  - `dbg_claude_procs()`: under debug, one `dbg` line per running `claude` (from `pgrep -x claude`): `claude pid=<pid> ppid=<ppid> <command, first 160 chars>`.
  - `debug_arm()`: under debug, at the end of the CLI part (just before `hindsight_resume`), reads the live item once and keeps the sha256 of its refresh token in `cli_written_hash`, never printed. That covers both a written login and one `cli_restore` re-saved.
  - `debug_watch()`: called from the trap after `desktop_launch`. A no-op unless `debug` and `cli_written_hash` is set. Polls 15 times, 2 s apart, until it finds the first change.

- [ ] **Step 1: Write the failing tests**

```bash
check "--debug is accepted by list" 0 "$(
  cda list --debug > /dev/null 2>&1
  echo $?
)"
check "and list writes no debug.log" absent "$([[ -e $root/debug.log ]] && echo present || echo absent)"
check "debug.log is created 0600" 600 "$(stat -f %Lp "$root/debug.log")"
check "debug logs the quit and the swap" yes "$(grep -q 'quit done' "$root/debug.log" && grep -q 'cli restore wrote' "$root/debug.log" && echo yes)"
check "debug lists running claude processes at the swap" yes "$(grep -q 'claude pid=' "$root/debug.log" && echo yes)"
check "debug.log holds no token" no "$(grep -q -e "$fixture_refresh_token" -e "$fixture_access_token" "$root/debug.log" && echo yes || echo no)"
# write-back: the open stub rewrites the fake Claude Code-credentials item with another refresh token
check "debug watch reports a write-back" yes "$(printf "%s" "$err" | grep -q 'CLI login changed after the switch' && echo yes)"
check "and names the processes then" yes "$(grep -c 'claude pid=' "$root/debug.log" | awk '$1>=2{print "yes"}')"
# no write-back
check "debug watch reports a stable login" yes "$(grep -q 'CLI login unchanged for 30 s' "$root/debug.log" && echo yes)"
check "without debug no debug.log is written" absent "$([[ -e $root2/debug.log ]] && echo present || echo absent)"
check "CLAUDE_MULTIPASS_DEBUG=1 turns it on for a switch" yes "$(
  CLAUDE_MULTIPASS_DEBUG=1 cda switch beta > /dev/null 2>&1
  [[ -s $root/debug.log ]] && echo yes
)"
check "debug watches a re-save switch too" yes "$(grep -q 'CLI login unchanged for 30 s' "$root/debug.log" && echo yes)"
check "debug.log is trimmed to its last 2000 lines" yes "$(
  seq 3000 > "$root/debug.log"
  cda switch beta --debug > /dev/null 2>&1
  (($(wc -l < "$root/debug.log") <= 2100)) && ! grep -qx 1 "$root/debug.log" && echo yes
)"
```

The watch runs 15 polls of 2 s, so stub `sleep` to a no-op for the debug-watch cases only, the same way the quit-fallback case does.

- [ ] **Step 2: Run the self-check to verify the new cases fail**

Run it as in Task 1, Step 2. Expected: FAIL at "--debug is accepted by list" (`Unknown option: --debug`).

- [ ] **Step 3: Implement**

- Parse `--debug) debug=1 ;;` and initialise `debug=${CLAUDE_MULTIPASS_DEBUG:+1}` before the loop. `debug` is a global, not `main`'s local, because the trap reads it.
- Add `dbg` calls at:
  - the start of the run (the command, the tool version, `defaults read /Applications/Claude.app/Contents/Info.plist CFBundleShortVersionString` or `unknown`);
  - `desktop_quit`'s start and end (`quit done`);
  - Hindsight paused (pids), children waited (count, seconds) and resumed;
  - `cli_running_warning` (`dbg_claude_procs`);
  - `cli_restore` after its write (`cli restore wrote <target account uuid>`);
  - `desktop_launch`.
- `debug_arm`: `cli_live_read`, then `cli_written_hash=$(printf '%s' "$cli_live" | jq -r '.claudeAiOauth.refreshToken // empty' | shasum -a 256 | cut -c1-64)`. Skip it when the run made no CLI change (`cli_skip`, or no `~/.claude.json`).
- `debug_watch`: each poll reads the live item with the existing `cli_live_read`, hashes its refresh token the same way, and reads `cli_signed_in_as`.
  - On the first change, `warning "debug: CLI login changed after the switch (now <account uuid or unknown>); see $root/debug.log"`, call `dbg_claude_procs`, and stop.
  - After 15 stable polls, `dbg "CLI login unchanged for 30 s"`.
- Trap order: `hindsight_resume; cli_unlock; [[ -n $llmr_launched ]] || desktop_launch; debug_watch; run_unlock`. The `--no-relaunch` trap gets `debug_watch` too.
- `--help` Options: `--debug  log timings and process lists to $root/debug.log and stderr, and watch the CLI login for 30 s after a switch (also CLAUDE_MULTIPASS_DEBUG=1)`.

- [ ] **Step 4: Run the self-check to verify it passes**

Expected: `All claude-multipass checks passed`.

- [ ] **Step 5: Docs**

- `docs/claude-multipass.md`: a short "Debugging a switch" section covering what the log holds and that it holds no secret.
- `CHANGELOG.md`: one line under `## Unreleased`.
- `.claude/rules/safety-and-terms.md`: `debug.log` is mode 0600 and holds no secret, and the watch's Keychain reads happen only inside `switch` and only under debug.

- [ ] **Step 6: Commit**

`Add a debug mode that watches the CLI login after a switch`

### Task 3: Debug toggle in the menu bar app

**Files:**

- Modify: `app/Sources/MultipassCore/AppSettings.swift`. Add a `debugSwitches` field, its `Keys` case and a `decodeIfPresent`.
- Modify: `app/Sources/MultipassCore/AppState.swift:88-95`. `apply` calls `relocate()` when `debugSwitches` changes as well as `cliPathOverride`.
- Modify: `app/Sources/ClaudeMultipass/App.swift:22-27`. `makeRunner` passes `extraEnvironment: settings.debugSwitches ? ["CLAUDE_MULTIPASS_DEBUG": "1"] : [:]`.
- Modify: `app/Sources/ClaudeMultipass/SettingsView.swift`. One `Toggle(isOn: binding(\.debugSwitches))` with a caption, in the General tab below the existing toggles.
- Test: `app/Tests/MultipassCoreTests/AppSettingsTests.swift`, `app/Tests/MultipassCoreTests/AppStateTests.swift`.

**Interfaces:**

- Consumes: Task 2's `CLAUDE_MULTIPASS_DEBUG`.
- Produces: `AppSettings.debugSwitches: Bool = false`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func debugSwitchesDefaultsOffAndDecodes() throws {
  #expect(AppSettings().debugSwitches == false)
  let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"debugSwitches":true}"#.utf8))
  #expect(s.debugSwitches)
}

@Test @MainActor func turningDebugOnRebuildsTheRunner() async {
  var built: [AppSettings] = []
  let s = makeState(nil, makeRunner: { built.append($0); return FakeRunner() })
  await s.relocate()
  var on = s.settings
  on.debugSwitches = true
  await s.apply(on)
  #expect(built.last?.debugSwitches == true)
}
```

Use the file's existing `makeState`/`FakeRunner` helpers. The second test asserts the runner is rebuilt with the new settings. The environment mapping lives in `App.swift`, which has no unit test seam, so Shots covers the toggle visually.

- [ ] **Step 2: Run to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path app --filter 'debugSwitches|turningDebugOn'` Expected: FAIL, with `debugSwitches` not defined.

- [ ] **Step 3: Implement**

- Add the setting and the `apply` condition.
- Add the `makeRunner` environment.
- Add the toggle with the label "Debug log for switches". Caption: "Writes timings and process lists to debug.log in the claude-multipass folder, and checks for 30 s after a switch that the terminal login stayed switched. No tokens are written."

- [ ] **Step 4: Run to verify they pass, then render**

Run the same `swift test` command, expect PASS. Then run `pnpm shots .shots`, read the General tab PNGs in light and dark (`magick <png> -scale 400% <out> 2>/dev/null`), and confirm the toggle and caption fit without clipping.

- [ ] **Step 5: Commit**

`Add a debug toggle for switches to Settings`

### Task 4: Gate, PR

- [ ] **Step 1:** Run `pnpm check` in the background and expect exit 0.
- [ ] **Step 2:** Push the branch `cli-writeback-guard` and open a PR against `main`. The body has the Findings summary, the Review Focus list, and what was not run: no real switch with Hindsight running.
- [ ] **Step 3:** Once merged, Jason's real check: turn the debug toggle on, switch to spoons from the popover, and read `debug.log` and `claude auth status`. Expect "Paused Hindsight's memory daemon" and "CLI login unchanged for 30 s".
