# Audit fixes implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the defects and close the gaps that the audit of 2026-11-15 found in the script, the menu bar app, the local tooling, the docs and the repository settings.

**Architecture:** One docs-only preparation step, then five batches, each one change with its own evidence. Batches A, B and C are code and each lands as its own pull request from its own worktree. Batch D is Markdown only and goes straight to `main`. Batch E is repository settings that only Jason can change. After Task 0 the batches can run in any order or in parallel, with one link: the Dependabot choice in Task E1 adds two file changes to the batch C pull request.

**Tech stack:** bash 3.2 and `jq` (`bin/claude-multipass`, `test/claude-multipass.sh`), Swift 6 with Swift Testing (`app/`), GitHub Actions, `gh`.

**Spec:** There is no separate spec. The audit findings are in [Appendix A](#appendix-a-findings-and-evidence), with the evidence label each one carries. A task cites its finding by id (A1, B2 and so on). [Appendix B](#appendix-b-what-the-plan-review-ran) records what was run to check this plan itself.

## Status (2026-11-16)

- **Task 0: done.** `7d3c8da` on `main`.
- **Batch A: done.** PR 73, squash-merged as `7073a50`. It went further than Tasks A1 to A4 below, after a review of the PR:
  - `copy_cookies` stages both files as `.tmp` before it renames either, and checks each `mv` and `rm`.
  - `backup_login` removes a backup folder it could not fill.
  - `profile_restore` copies the cookies before it writes `config.json`, puts them back when that write fails, and names the backup in both failure messages.
  - `cli_restore` refuses a saved Keychain item that holds no login.
  - The Raycast usage command says `could not read the account list` when it cannot.
  - The `failclosed` section has 35 check lines, four of them in a loop that runs twice. The task text below is the plan as written, not the code as merged, so read `bin/claude-multipass` for the final form.
- **Batch B: PR 74 open**, branch `usage-floor-and-app-polish`, one commit. Both new tests failed or did not compile before the change and pass after. Not checked: the login item re-read, which needs a person (Task B3 Step 4).
- **Batch C: PR 75 open**, branch `gate-and-ci-hardening`. It adds one thing the tasks below do not name: when `swift test` fails, the gate prints every failed test line, because PR 74's first `check` run failed above the 60-line tail it printed. No Dependabot file, since Task E1 is not decided.
- **Batch D: done**, four commits on `main` (`e1cd465`, `f169cd6`, `45c3dd8`, `c5efaf3`). Three differences from the tasks below:
  - Task D2 Step 1 was skipped, since PR 75 adds the pin clause. Step 3 (`/docs-audit`) was not run. The two corrected sentences were checked against `check.yml` lines 11 to 14.
  - Task D3 Step 2 is wrong as written. Measured on 2026-11-16 against an empty store: an unknown option, a misplaced `--force`, `--json` or `--llmr` and an extra name exit 2, and only a missing name (`show`, `remove`) exits 1. The doc now says that.
  - Task D3 also gained a bullet for the refused first switch (exit 3), which the new `README.md` line points to and the section did not cover.
- **Batch E: not started.** It is Jason's.
- The step checkboxes in this file are not ticked. This section is the record.

## Global constraints

- Code never goes to `main`. Each of batches A, B and C starts with `git worktree add .claude/worktrees/<branch> -b <branch>` and `pnpm install` in that worktree, and lands only through its PR after `check` is green. Merging is Jason's call.
- The commit-gate hook runs `pnpm check` before every commit. Format in one Bash call and commit in the next, because the hook checks the tree before the command runs.
- A user-visible change in `bin/` or `app/Sources/` adds its line under `## Unreleased` in `CHANGELOG.md` in the same PR. Task 0 adds that heading first, so two branches never both add it. A change no user sees adds no line, and the gate's changelog reminder is then expected.
- A change to what the script does edits `README.md` or `docs/claude-multipass.md` in the same commit.
- Every reproduced defect and every new warning gets a case in `test/claude-multipass.sh`. A new section sets up the state it needs and does not lean on what an earlier section left, because the sections that run before it differ between a filtered run and a full run. Prove it both ways: `bash test/claude-multipass.sh <section>`, then the whole file.
- bash 3.2 is the target. No here-strings or heredocs for a secret. BSD tools only.
- Agents never run `save`, `add`, `switch`, `rename`, `remove`, `sync`, `usage`, `pick` or a bare `claude-multipass` against the real Desktop. The fixture self-check is the only place those run.
- `MultipassCore` imports only Foundation. Only `SparkleUpdater.swift` imports Sparkle.
- Swift commands need `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` when `xcode-select -p` names the Command Line Tools. Never run two Swift builds at once, and never run `pnpm check` beside one.
- Prose has no em-dashes. Commit subjects are short, imperative and sentence case, with no prefix.
- Still rejected and out of scope: any automatic switch, token renewal, routing, per-account `CLAUDE_CONFIG_DIR`, usage polling on by default or faster than 5 minutes.

## Review focus

1. A failed write that reports success. Expected: a failed `jq` or a failed write of `cli.json` leaves the old file untouched, returns non-zero and prints its warning. Task A1 pins it.
2. A profile whose `cli.json` is empty or holds no account id (left by a 0.14.0 run that hit finding A1). Expected: `switch` refuses to restore from it, warns, and `~/.claude.json` keeps its `oauthAccount`. Task A1 pins it.
3. A user who flips "Show usage" off and on several times in a minute. Expected: one `usage` run per 30 seconds at most. Task B1 pins it.
4. A commit made through a git alias (`git cm`, `git amend`). Expected: the gate runs `pnpm check`. Task C1 pins it.
5. A workflow that loses its ShellCheck pin. Expected: `pnpm check` fails. Task C2 pins it by a mutation run, since `test/check.sh` has no harness of its own.

## File map

| File | Batch | Change |
| --- | --- | --- |
| `CHANGELOG.md` | 0 | `## Unreleased` heading |
| `bin/claude-multipass` | A | `jq_write`, `cli_restore`, `cli_capture`, `cli_backup`, `backup_login`, `copy_cookies`, header line 25 |
| `test/claude-multipass.sh` | A | New section `failclosed`, two Raycast cases in `llmr`, one in `doctor` |
| `raycast/claude-account-usage.sh` | A | LLMR branch |
| `app/Sources/MultipassCore/AppState.swift` | B | Usage floor on the toggle path, interval helper call |
| `app/Sources/MultipassCore/AppSettings.swift` | B | `usagePollInterval(minutes:)` |
| `app/Sources/ClaudeMultipass/PopoverView.swift`, `PopoverController.swift`, `SettingsView.swift` | B | Refresh state, comment, login item re-read |
| `app/Tests/MultipassCoreTests/AppStateTests.swift`, `AppSettingsTests.swift` | B | Two tests |
| `.claude/hooks/commit-gate.sh`, `test-commit-gate.sh` | C | Aliases and four wrappers |
| `.claude/settings.json`, `.claude/hooks/test-settings.sh` | C | Two more ask-rule shapes per command |
| `test/check.sh` | C | Pin parity, Core import check |
| `.github/workflows/release.yml` | C | `concurrency`, no `brew install jq` |
| `.github/dependabot.yml`, `renovate.json` | C | Only if Jason picks Dependabot in E1 |
| `CLAUDE.md`, `.claude/skills/release/SKILL.md`, `docs/claude-multipass.md`, `README.md`, `SECURITY.md`, `docs/superpowers/plans/` | D | Corrections, new entries, three moves |

---

## Task 0: Add the `## Unreleased` heading (Markdown only, straight to `main`)

Batches A and B both add changelog lines. `CHANGELOG.md` starts at `## 0.14.0` today, so two branches that each add the heading would conflict on merge.

- [ ] **Step 1:** Add `## Unreleased` and a blank line above `## 0.14.0 (2026-11-03)`.
- [ ] **Step 2:** Run `bash test/appcast.sh`. Expected: exit 0. That test uses its own fixture changelogs, so the heading does not affect it. `release.yml` refuses a tag whose top heading is not the version, and `/release` renames the heading, so an empty `## Unreleased` cannot ship.
- [ ] **Step 3:** Commit as `Open the Unreleased section` and push.

---

## Batch A. Harden the script's writes (one PR, branch `harden-cli-writes`)

The fixes and the test section in this batch were run in a scratch copy of the repository on 2026-11-15. See [Appendix B](#appendix-b-what-the-plan-review-ran).

### The test section for Tasks A1 to A3

Add this section to `test/claude-multipass.sh` directly above `#@ done`. Each task below names the cases it owns. The section defines its own stderr helper, because `err_of` exists only inside the `args` section, and it rewrites both profiles' `cli.json` first, because the `refusals` section leaves `beta`'s on another account.

```bash
#@ failclosed needs switch
# The switch section leaves Desktop and the CLI on beta.
errs() { { TERM=dumb "$@" > /dev/null; } 2>&1 || true; }
# Earlier sections leave either profile's identity file on another account.
for n in alpha beta; do
  printf '{"oauthAccount":{"accountUuid":"%s","emailAddress":"%s@example.com","organizationUuid":"org-%s"}}' "$(jq -r .account "$p/$n/meta.json")" "$n" "$n" > "$p/$n/cli.json"
done
check "failclosed starts on alpha" 0 "$(exit_code cda switch alpha --no-relaunch)"
# a failed identity write keeps the old file and says so
mkdir -p "$tmp/jqfail"
printf '#!/bin/sh\ncase "$*" in *"--tab {oauthAccount}"*) exit 5 ;; esac\nPATH=${PATH#*/jqfail:} exec jq "$@"\n' > "$tmp/jqfail/jq"
chmod +x "$tmp/jqfail/jq"
before=$(cksum < "$p/alpha/cli.json")
out=$(PATH="$tmp/jqfail:$PATH" errs cda save alpha --no-relaunch)
check_true "save warns when cli.json cannot be written" grep -q 'could not write .*alpha/cli.json' <<< "$out"
check "and keeps the old cli.json" "$before" "$(cksum < "$p/alpha/cli.json")"
check_true "and leaves no temp file" test ! -e "$p/alpha/cli.json.tmp"
# an empty saved identity is never restored
cp "$p/beta/cli.json" "$tmp/beta-cli.json"
: > "$p/beta/cli.json"
live=$(jq -c .oauthAccount "$tmp/claude.json")
out=$(errs cda switch beta --no-relaunch)
check_true "switch refuses an unreadable cli.json" grep -q 'the saved CLI identity for beta is unreadable; run claude auth login, then save beta' <<< "$out"
check "and keeps oauthAccount in the CLI config" "$live" "$(jq -c .oauthAccount "$tmp/claude.json")"
cp "$tmp/beta-cli.json" "$p/beta/cli.json"
# Desktop is on beta and the CLI still on alpha: the same-account repair, with no backup made yet
token=$(kc_get "Claude Code-credentials" "$USER" | jq -r .claudeAiOauth.accessToken)
chmod 500 "$b"
out=$(cda switch beta --no-relaunch 2>&1 || true)
chmod 700 "$b"
check "a backup that cannot be made is not announced" 0 "$(grep -c 'Backed up the current login' <<< "$out" || true)"
check_true "and the run says so" grep -q 'could not back up the current login; switched Desktop only' <<< "$out"
check "and the CLI login is not written" "$token" "$(kc_get "Claude Code-credentials" "$USER" | jq -r .claudeAiOauth.accessToken)"
check "the repair then works" 0 "$(exit_code cda switch beta --no-relaunch)"
check "and moves the CLI to beta" "$(jq -r .account "$p/beta/meta.json")" "$(jq -r .oauthAccount.accountUuid "$tmp/claude.json")"
# an item with shared keys and no login is not a CLI login
saved=$(kc_get claude-multipass beta)
live_now=$(kc_get "Claude Code-credentials" "$USER")
kc_put "Claude Code-credentials" "$USER" '{"mcpOAuth":{"srv":"shared"}}'
out=$(errs cda save beta --no-relaunch)
check_true "save names an item with no tokens" grep -q 'beta: the live CLI login holds no tokens; saved the Desktop login only' <<< "$out"
check "and keeps the profile's saved CLI login" "$saved" "$(kc_get claude-multipass beta)"
kc_put "Claude Code-credentials" "$USER" "$live_now"
# a cookie copy that dies leaves the live file whole
printf '#!/bin/sh\nfor a; do last=$a; done\ncase "$last" in "%s/Cookies" | "%s/Cookies.tmp") printf half > "$last"; exit 1 ;; esac\nexec /bin/cp "$@"\n' "$d" "$d" > "$tmp/bin/cp"
chmod +x "$tmp/bin/cp"
before=$(cat "$d/Cookies")
check "a switch whose cookie copy dies fails" 1 "$(exit_code cda switch alpha --no-relaunch)"
check "and leaves the live Cookies file whole" "$before" "$(cat "$d/Cookies")"
check_true "and no temp file" test ! -e "$d/Cookies.tmp"
rm "$tmp/bin/cp"
```

The `cp` stub fails only on the live cookie file, never on a backup copy, so the run reaches the copy the fix protects.

### Task A1: `jq_write` fails closed and `cli_restore` rejects an unreadable identity

Findings A1 and A2. `jq_write` (`bin/claude-multipass:439`) runs inside `||` lists at lines 737 and 891, where bash turns `errexit` off for the whole function body. A failed `jq` then leaves `out` empty, `mv` installs a 0-byte file and the function returns 0. Its other callers (lines 1097, 1223, 1226, 1235 and 2080) run with `errexit` on and exit 1 as before.

**Files:**

- Modify: `bin/claude-multipass:439-445` (`jq_write`), `:936-948` (`cli_restore`), `:1146-1152` (`backup_login`), `:884-886` (`cli_backup`)
- Test: section `failclosed`, the cases from `save warns when cli.json cannot be written` through `and moves the CLI to beta`

**Interfaces:**

- Produces: `jq_write <dest> <jq args...>` returns non-zero and leaves `<dest>` and no `<dest>.tmp` when `jq` or the write fails. `backup_login` returns 1 when its `mkdir`, its `cp` of `config.json` or its cookie copy fails, and prints "Backed up" only on success.

- [ ] **Step 1: Add the test section above and see it fail**

Run: `bash test/claude-multipass.sh failclosed` Expected: exit 1 at `save warns when cli.json cannot be written`.

- [ ] **Step 2: Make `jq_write` fail closed**

```bash
jq_write() {
  local dest=$1 out
  shift
  out=$(jq --tab "$@") || return 1
  (umask 077 && printf '%s' "$out" > "$dest.tmp") || {
    rm -f "$dest.tmp"
    return 1
  }
  mv "$dest.tmp" "$dest"
}
```

- [ ] **Step 3: Make `cli_restore` reject an identity with no account id**

Add the check after the "already on the target account" block, the one that ends with `dbg "cli restore already on $(cli_signed_in_as)"` and `return 0` near line 947. That block re-saves the live login through `cli_capture`, which rewrites `cli.json`, so a check placed above it would block the repair.

```bash
if ! jq -e '.oauthAccount.accountUuid | strings' "$dir/cli.json" > /dev/null 2>&1; then
  warning "the saved CLI identity for $name is unreadable; run claude auth login, then save $name"
  return 0
fi
```

The redirect matters. Without it `jq` prints the account id on `switch`'s stdout.

- [ ] **Step 4: Make `backup_login` and its caller report a failed backup**

In `backup_login`, add `|| return 1` to the `mkdir` subshell, to `cp -p "$config" "$backup_dest/config.json"` and to `copy_cookies "$cookies" "$backup_dest"`. In `cli_backup`, replace `[[ -n $backup_dest ]] || backup_login` with:

```bash
[[ -n $backup_dest ]] || backup_login || {
  warning "could not back up the current login; switched Desktop only"
  return 1
}
```

`backup_login`'s other callers (lines 1234 and 2079) run with `errexit` on, so a `return 1` there exits the run as the bare failure did.

- [ ] **Step 5: Run the section through `and moves the CLI to beta`, then the whole file**

Run: `bash test/claude-multipass.sh failclosed` Expected: `ok:` for every case up to `and moves the CLI to beta`, then exit 1 at `save names an item with no tokens`, which Task A2 fixes.

- [ ] **Step 6: Write the changelog and docs lines, and do not commit yet**

Add a line under `## Unreleased`: a failed write of a profile's CLI identity now keeps the old file and warns, and a switch refuses to restore from an identity file it cannot read. Add one bullet to "When something is off" in `docs/claude-multipass.md` for the `unreadable` warning and one for `could not back up the current login`. The commit gate runs the whole self-check, and the new section fails until Tasks A2 and A3 are in, so Tasks A1 to A3 land as one commit, made in Task A3 Step 3.

### Task A2: `save` skips a CLI item that holds no tokens

Finding A3. `cli_restore` already treats an item without `claudeAiOauth` as no login (`bin/claude-multipass:943`). `cli_capture` does not, so `save` can store it.

**Files:**

- Modify: `bin/claude-multipass:727` (`cli_capture`, directly above the `cli_cleared` check)
- Test: section `failclosed`, the cases `save names an item with no tokens` and `and keeps the profile's saved CLI login`

- [ ] **Step 1: Add the check**

```bash
if ! printf '%s' "$live" | jq -e '.claudeAiOauth != null' > /dev/null 2>&1; then
  warning "$name: the live CLI login holds no tokens; saved the Desktop login only"
  return 0
fi
```

The item reaches `jq` on stdin, as everywhere else in the script.

- [ ] **Step 2: Run the section**

Expected: `ok:` through `and keeps the profile's saved CLI login`, then exit 1 at `and leaves the live Cookies file whole`, which Task A3 fixes.

- [ ] **Step 3:** Add the `CHANGELOG.md` line and a "When something is off" bullet for the new warning.

### Task A3: Cookie files are replaced atomically

Finding A4, the cheap half. `copy_cookies` (`bin/claude-multipass:1136`) runs `cp -p` onto the live `Cookies` file, so a kill mid-copy leaves a truncated file. The other half of A4 is deferred (see [Deferred](#deferred-with-reasons)).

**Files:**

- Modify: `bin/claude-multipass:1136-1141`
- Test: section `failclosed`, the last three cases

- [ ] **Step 1: Copy through a temp file**

```bash
copy_cookies() {
  local f
  for f in Cookies Cookies-journal; do
    if [[ -f $1/$f ]]; then
      cp -p "$1/$f" "$2/$f.tmp" || {
        rm -f "$2/$f.tmp"
        return 1
      }
      mv "$2/$f.tmp" "$2/$f"
    else
      rm -f "$2/$f"
    fi
  done
}
```

- [ ] **Step 2: Run the section, then the whole file**

Run: `bash test/claude-multipass.sh failclosed`, then `bash test/claude-multipass.sh` Expected: `Filtered claude-multipass checks passed`, then `All claude-multipass checks passed`.

- [ ] **Step 3: Commit Tasks A1 to A3**

Add `failclosed` to the section list in `.claude/rules/testing.md`. No `CHANGELOG.md` line for the cookie change, since nothing a user sees changes.

```bash
git add bin/claude-multipass test/claude-multipass.sh CHANGELOG.md docs/claude-multipass.md .claude/rules/testing.md
git commit -m "Fail closed when a login write cannot finish"
```

### Task A4: The Raycast usage command handles an LLMR profile, and the header says what `--force` deletes

Findings A5 and A6.

**Files:**

- Modify: `raycast/claude-account-usage.sh:28-32`, `bin/claude-multipass:25`
- Test: `test/claude-multipass.sh`, section `llmr` and section `doctor`

- [ ] **Step 1: Write the tests**

In section `llmr`, directly after the line `check "list --json names it current" router "$(cda list --json | jq -r .current)"`:

```bash
check "Raycast usage names a running LLMR profile" router "$("$raycast/claude-account-usage.sh" 2> /dev/null)"
check "and exits 0" 0 "$(exit_code "$raycast/claude-account-usage.sh")"
```

In section `doctor`, directly after the line that starts `check "but not when one name is asked for"`:

```bash
check "Raycast usage passes through not saved" "not saved" "$("$raycast/claude-account-usage.sh")"
```

`$raycast` is set in section `list`, which both `llmr` and `doctor` need, so it is in scope. The `not saved` case passes today. It covers a branch that had no test, and only the LLMR case is the regression test.

- [ ] **Step 2: Run the LLMR case and see it fail**

Run: `bash test/claude-multipass.sh "Raycast usage names a running LLMR profile"` Expected: exit 1 at that case.

- [ ] **Step 3: Add the LLMR branch**

Replace the `*)` arm:

```bash
  *)
    kind=$("$cda" list --json | jq -r --arg n "$name" '.profiles[] | select(.name == $n) | .kind // ""')
    if [[ $kind == llmr ]]; then echo "$name"; else "$cda" usage "$name"; fi
    ;;
```

A real `usage` error still shows, since only the LLMR case skips the call.

- [ ] **Step 4: Correct the header line**

Change line 25 from `(no quit, no Keychain)` to `(no quit; with --force over a claude.ai profile, that profile's CLI item is deleted)`. The `--help` text near line 292 is already right.

- [ ] **Step 5: Run the whole file, then commit**

Add a `CHANGELOG.md` line for the Raycast fix.

```bash
git commit -am "Show an LLMR profile's name in the Raycast usage command"
```

- [ ] **Step 6: Open the PR**

Push the branch and open the PR against `main`. The `## Why` opens with the goal: a failed write must never pass for a success, since the next switch trusts what the last one saved.

---

## Batch B. Close the usage floor and polish the app (one PR, branch `usage-floor-and-app-polish`)

The helpers these tests use (`readyState(clock:)`, `enabledUsage`, `TestClock`, `clearCalls`, `calls`) exist in `AppStateTests.swift` with these signatures. The tests in this batch have not been compiled.

### Task B1: Turning usage on honors the 30 second floor

Finding B1. `apply` (`app/Sources/MultipassCore/AppState.swift:97`) calls `refreshUsage()` directly. The comment on `refreshAll` at line 193 says the toggle is "spaced on its own", which is false.

**Files:**

- Modify: `app/Sources/MultipassCore/AppState.swift:96-99`, `:193-200`
- Test: `app/Tests/MultipassCoreTests/AppStateTests.swift`

**Interfaces:**

- Produces: `private var withinUsageFloor: Bool` on `AppState`, true when `usageAttemptedAt` is less than `AppSettings.usageRefreshFloor` before `now()`. `refreshAll` and the `(false, true)` branch both read it.

- [ ] **Step 1: Write the failing test**

```swift
@Test @MainActor func reEnablingUsageWithinTheFloorDoesNotFetch() async {
  let clock = TestClock()
  let (s, r) = await readyState(clock: clock)
  await s.apply(enabledUsage(s))
  r.clearCalls()
  await s.apply(AppSettings())
  await s.apply(enabledUsage(s))
  #expect(r.calls == [])
  #expect(s.isPollingUsage)
  clock.now += AppSettings.usageRefreshFloor
  await s.apply(AppSettings())
  await s.apply(enabledUsage(s))
  #expect(r.calls == [["usage", "--json"]])
}
```

- [ ] **Step 2: Run it and see it fail**

Run: `swift test --package-path app --filter reEnablingUsageWithinTheFloorDoesNotFetch` Expected: FAIL, `r.calls` holds one `usage --json` call after the first re-enable.

- [ ] **Step 3: Apply the floor on the toggle path**

Add `withinUsageFloor`, use it in `refreshAll`, and skip `refreshUsage()` in the `(false, true)` branch when it is true. The timer still starts. Rewrite the `refreshAll` comment so it says the toggle shares the floor.

- [ ] **Step 4: Run the test and the suite**

Run: `swift test --package-path app` Expected: PASS. `applyEnablingUsageFetchesOnce` still passes, since a first enable has no earlier attempt.

- [ ] **Step 5: Commit**

Add a `CHANGELOG.md` line: turning usage off and on again within 30 seconds no longer reads usage again.

```bash
git commit -am "Apply the refresh floor when usage is turned on"
```

### Task B2: The 5 minute timer floor has a test

Finding B2. The clamp lives inside a private timer (`AppState.swift:293`), so no test can see it.

**Files:**

- Modify: `app/Sources/MultipassCore/AppSettings.swift`, `app/Sources/MultipassCore/AppState.swift:293`
- Test: `app/Tests/MultipassCoreTests/AppSettingsTests.swift`

**Interfaces:**

- Produces: `public static func usagePollInterval(minutes: Int) -> TimeInterval` on `AppSettings`. It returns `max(minutes, 5) * 60` seconds. `startUsageTimer` calls it.

- [ ] **Step 1: Write the failing test**

```swift
@Test func usagePollIntervalNeverGoesBelowFiveMinutes() {
  #expect(AppSettings.usagePollInterval(minutes: 1) == 300)
  #expect(AppSettings.usagePollInterval(minutes: 5) == 300)
  #expect(AppSettings.usagePollInterval(minutes: 60) == 3600)
}
```

- [ ] **Step 2: Run it and see it fail to compile**

Run: `swift test --package-path app --filter usagePollInterval` Expected: a compile error, no member `usagePollInterval`.

- [ ] **Step 3: Add the function and call it from `startUsageTimer`**

- [ ] **Step 4: Run the suite and commit**

No `CHANGELOG.md` line, since nothing a user sees changes.

```bash
git commit -am "Test the usage poll interval's five minute floor"
```

### Task B3: Refresh shows that it is running, and two stale surfaces are corrected

Findings B3, B5 and the login item part of B6.

**Files:**

- Modify: `app/Sources/ClaudeMultipass/PopoverView.swift:55`, `PopoverController.swift:5-6`, `SettingsView.swift` (the `general` view at line 81)

- [ ] **Step 1: Disable Refresh while a refresh runs**

Add `.disabled(appState.isRefreshing || appState.isRefreshingUsage)` to the Refresh button.

- [ ] **Step 2: Correct the popover comment**

`PopoverController.swift:5-6` becomes "Opening it refreshes the snapshot. Usage runs on its own timer."

- [ ] **Step 3: Re-read the login item each time the settings window becomes key**

The window is created once and shown again with `makeKeyAndOrderFront` (`SettingsWindow.swift:27-34`), so `.onAppear` may not fire on a second open and the `@State` initializers run once. On the `general` view, add:

```swift
.onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
  launchAtLogin = Self.loginItemOn
  loginItemNote = Self.approvalNote
}
```

Setting `launchAtLogin` fires the existing `onChange`, whose handler returns at once at `guard enabled != Self.loginItemOn` (line 223), so no registration runs.

- [ ] **Step 4: Verify**

Run: `swift test --package-path app`, then `pnpm shots` Expected: both pass. Read the popover and General tab PNGs in `.shots/`, light and dark. The login item re-read cannot be seen in a shot. Jason checks it by hand: open Settings, remove the login item in System Settings, switch back, and the toggle reads off.

- [ ] **Step 5: Commit and open the PR**

Add `CHANGELOG.md` lines for the Refresh button and the login item state.

```bash
git commit -am "Show a running refresh and re-read the login item"
```

The PR's `## Why` opens with the goal: the app must hold the usage rails it states, on every path that can start a read.

---

## Batch C. Harden the gate and CI (one PR, branch `gate-and-ci-hardening`)

### Task C1: The commit gate follows git aliases and four more wrappers

Finding C1. `git cm`, `git amend`, `git append` and `git empty` are plain aliases for `git commit` in Jason's global config, and the hook matches only the literal subcommand `commit` (`.claude/hooks/commit-gate.sh:102`).

**Files:**

- Modify: `.claude/hooks/commit-gate.sh:73` (wrapper list), `:100-105` (subcommand match)
- Test: `.claude/hooks/test-commit-gate.sh`, cases 3 and 4

- [ ] **Step 1: Write the failing cases**

The throwaway repo sets its own aliases, so the test never reads Jason's config: `git -C "$proj" config alias.cm 'commit -m'` and `git -C "$proj" config alias.lg 'log --oneline'`. Add to the case 3 list (must gate): `'git cm x'`, `'timeout 600 git commit -m x'`, `'eval git commit -m x'`, `'caffeinate git commit -m x'`, `'stdbuf -o0 git commit'`. Add to the case 4 list (must not gate): `'git lg'`.

- [ ] **Step 2: Run it and see it fail**

Run: `.claude/hooks/test-commit-gate.sh` Expected: `not gated: git cm x`.

- [ ] **Step 3: Resolve the alias and extend the wrapper list**

When the subcommand is not `commit` and not one of the `--continue` commands, read `git -C "$gitdir" config --get "alias.$sub"`. Gate when its first word is `commit`. A shell alias (one that starts with `!`) is not followed. Add `timeout`, `eval`, `caffeinate` and `stdbuf` to the wrapper list at line 73.

- [ ] **Step 4: Run the self-check and commit**

Update the `test-commit-gate.sh` paragraph in `.claude/rules/testing.md` in the same commit, naming aliases and the four wrappers.

```bash
git commit -am "Gate commits made through a git alias"
```

### Task C2: `pnpm check` fails on a missing ShellCheck pin and on a UI import in `MultipassCore`

Findings C2 and B4.

**Files:**

- Modify: `test/check.sh:109-121`

- [ ] **Step 1: Tighten the pin check**

For each of `.github/workflows/check.yml` and `.github/workflows/release.yml`, require that `grep -c '^ *SHELLCHECK_SHA256:'` and `grep -c '^ *SHELLCHECK_VERSION:'` each print 1, and fail with `check: <file> has no single ShellCheck pin` otherwise. Then require one unique value of each across both files, with the existing message `check: check.yml and release.yml pin different ShellCheck releases`. A count across both files together would pass when one file held both lines.

- [ ] **Step 2: Add the Core import check**

Beside the Sparkle check, fail with `check: MultipassCore may import only Foundation, found: <files>` when any file under `app/Sources/MultipassCore` has an `import` line other than `import Foundation`. It holds today.

- [ ] **Step 3: Prove each check by mutation**

On a scratch copy of the repo, delete the `SHELLCHECK_SHA256` line from `release.yml` and run the pin block. Expected: `release.yml has no single ShellCheck pin`, exit 1. Add `import SwiftUI` to a scratch copy of `Formatting.swift` and run the import block. Expected: the new message, exit 1. Record both outputs in the PR body. Then run `pnpm check` on the clean tree. Expected: exit 0.

- [ ] **Step 4: Commit**

In the same commit, the `pnpm check` list in `CLAUDE.md` gains the Core import check. If Task D2 has not landed, add the ShellCheck pin clause too. If it has, leave its clause as it is.

```bash
git commit -am "Fail the gate on a missing pin or a UI import in Core"
```

### Task C3: A re-pushed tag cannot run two releases at once, and the workflow installs nothing it has

Finding C3. The hazard is two runs for the same tag racing on `gh release create` and on the assets. Two different tags make two different releases and do not conflict, so the group is per tag. A constant group was considered and rejected: GitHub keeps only one waiting run per group, so a third tag would cancel the second.

**Files:**

- Modify: `.github/workflows/release.yml:7-9`, `:41-43`

- [ ] **Step 1: Add the concurrency group**

After `permissions:`, add:

```yaml
concurrency:
  group: release-${{ github.ref }}
  cancel-in-progress: false
```

The group is at workflow level, so it covers both jobs (`build`, and `release` with `needs: build`).

- [ ] **Step 2: Replace `brew install jq`**

Replace the step with `- run: command -v jq`. `check.yml` runs `pnpm check`, which needs `jq`, on the same `macos-26` image with no install step, and its last 200 runs have 0 failures.

- [ ] **Step 3: Verify and commit**

Run: `node_modules/.bin/prettier --check .github/workflows/release.yml` Expected: no output, exit 0. The workflow itself first runs at the next tag, so say in the PR body that it is unproven until then.

```bash
git commit -am "Queue a re-pushed tag's release and stop installing jq"
```

### Task C4: The ask rules cover `./claude-multipass` and the tool named after a wrapper

Finding C4. Rules such as `Bash(claude-multipass switch*)` match only at the start of the command.

**Files:**

- Modify: `.claude/settings.json` (`permissions.ask`)
- Test: `.claude/hooks/test-settings.sh:71` (the `asks` array) and its must-not-ask list

- [ ] **Step 1: Write the failing samples**

Add to `asks`: `"cd bin && ./claude-multipass switch w"`, `"timeout 60 claude-multipass switch w"`, `"env FOO=1 claude-multipass save w"`, `"echo w | xargs claude-multipass switch"`. Add to the must-not-ask list: `"timeout 60 claude-multipass list"` and `"bash test/claude-multipass.sh switch"`.

- [ ] **Step 2: Run it and see it fail**

Run: `.claude/hooks/test-settings.sh` Expected: `permissions.ask does not cover: cd bin && ./claude-multipass switch w`.

- [ ] **Step 3: Add two rules per mutating command**

For each of `switch`, `add`, `save`, `remove`, `rename`, `sync`, `usage` and `pick`, add `Bash(*./claude-multipass* <cmd>*)` and `Bash(* claude-multipass <cmd>*)`, 16 rules in all. Keep the existing rules.

These shapes were run through the matcher in `test-settings.sh` on 2026-11-15. All four new samples ask, and both must-not-ask samples do not. The existing sample `git commit -m "claude-multipass add refuses x"` still does not ask, because a quote and not a space comes before the name, so that test stays as it is.

Two limits, to state in `.claude/rules/testing.md`. A command quoted inside `sh -c "claude-multipass remove w"` is not covered, for the same reason. A commit message with a space before the name (`-m 'fix claude-multipass add'`) costs one extra prompt.

- [ ] **Step 4: Run the self-check, commit and open the PR**

Update the ask-rule sentence in `CLAUDE.md` in the same commit.

```bash
git commit -am "Ask before the tool when a wrapper comes first"
```

The PR's `## Why` opens with the goal: the gate and the ask rules must hold for the forms a person and an agent really type.

---

## Batch D. Correct the docs (Markdown only, straight to `main`)

One commit per task, pushed with the docs-only bypass. Run `node_modules/.bin/prettier --write` on each edited file except `CLAUDE.md`, which `.prettierignore` skips.

### Task D1: Move the three shipped plans

Finding D1. PRs 66, 68 and 71 are merged and the code is present.

- [ ] **Step 1:** `git mv` these three into `docs/superpowers/plans/completed/`: `2026-11-02-cli-writeback-guard.md`, `2026-11-03-cli-login-truthful-surfaces.md`, `2026-11-03-doctor-and-self-check-hardening.md`.
- [ ] **Step 2:** Repoint references to the three moved files only. Find them with:

  ```bash
  grep -rn 'cli-writeback-guard\|cli-login-truthful-surfaces\|doctor-and-self-check-hardening' --include='*.md' --exclude-dir=node_modules --exclude-dir=worktrees .
  ```

  A plan's own `git add` line for itself is history and stays as written.

- [ ] **Step 3:** Commit as `Move three shipped plans to completed`.

`2026-11-03-last-known-usage.md` stays. Its Task 1 gate still waits on Jason's two `usage` recordings. `2026-11-15-doctor-cleanup.md` stays until Jason takes the `/context` reading.

### Task D2: Correct `CLAUDE.md` and the release skill

Findings D2 and C5.

- [ ] **Step 1:** In the `pnpm check` bullet of `CLAUDE.md`, add "that `check.yml` and `release.yml` pin the same ShellCheck release". The check exists at `test/check.sh:117` and the list omits it. Skip this step if Task C2 has landed and added the clause.
- [ ] **Step 2:** In Custom Notes, replace "each push to `main` cancels the run before it, so only the tip's run counts, and a cancelled tip run is rerun with `gh run rerun <id>`" with the true behavior: `check.yml` cancels in-progress runs for pull requests only, a run on `main` finishes, and a queued run is replaced by a newer one, so the tip's run is the one to read. Make the same correction where `.claude/skills/release/SKILL.md` repeats it.
- [ ] **Step 3:** Run `/docs-audit` on the result. Commit as `Correct the gate list and the CI cancellation note`.

### Task D3: Explain the messages the script prints

Finding D3.

- [ ] **Step 1:** Add bullets to "When something is off" in `docs/claude-multipass.md` for these messages, each with its cause and the next step. Take the exact text from the script.
  - `Claude did not quit; quit it by hand and retry` (`bin/claude-multipass:1015`)
  - `Claude Code holds <lock>; retry in a moment`, and its `save` form that ends "saved the Desktop login only" (`:2037`, `:2038`)
  - `Could not read "Claude Safe Storage" from the login Keychain` (`:1311`), which a denied Keychain prompt raises
  - The `usage` rows `cannot decrypt (the profile was saved on another Mac, or the app changed its key)` (`:1441`), `rate limited` and `unavailable (HTTP n)` (`:1453`, `:1454`)
- [ ] **Step 2:** At `docs/claude-multipass.md:203`, say that a bad option, a wrong name count and a misplaced `--force`, `--json` or `--llmr` exit 1, and that only an unknown command and a bare run without a terminal or `fzf` exit 2.
- [ ] **Step 3:** In `README.md`, after Install, add one line that points to "When something is off" for a refused first switch (exit 3).
- [ ] **Step 4:** Check each quoted message against the script with `grep -n`. Commit as `Explain the remaining script messages`.

### Task D4: Add `SECURITY.md`

Finding E3. Private vulnerability reporting is already on for this repository (`gh api repos/jrmatherly/claude-multipass/private-vulnerability-reporting` printed `{"enabled":true}` on 2026-11-15), so nothing blocks this task.

- [ ] **Step 1:** Create `SECURITY.md` with three short sections. Supported versions: the latest release only. Reporting: GitHub's private vulnerability reporting on this repository, with the link `https://github.com/jrmatherly/claude-multipass/security/advisories/new`. Scope: the script, the app, the release workflow and the update feed. Say that a report should never include a token or a profile folder.
- [ ] **Step 2:** Commit as `Add a security policy`.

---

## Batch E. Repository settings (Jason's)

Agents do not run these. Each is one command or one click, with the check that proves it.

### Task E1: Turn on dependency updates

Finding E1. `renovate.json` has been in the repository since v0.1.0, and Renovate has opened 0 pull requests and no dashboard issue. Dependabot security updates are disabled. `pnpm/action-setup` is one patch behind its pin.

Pick one:

- **Dependabot (recommended).** It needs no third-party app. An agent then adds `.github/dependabot.yml` (ecosystems `github-actions`, `npm` and `swift` with directory `/app`, weekly) and deletes `renovate.json`, in the batch C PR. Jason turns on security updates:

  ```bash
  gh api -X PUT repos/jrmatherly/claude-multipass/automated-security-fixes
  ```

- **Renovate.** Install the Renovate app on the repository at `https://github.com/apps/renovate`. Nothing in the repository changes.

- [ ] **Check:** within a week, `gh pr list --state all --search "author:app/dependabot"` (or `author:app/renovate`) lists at least one pull request.

### Task E2: Protect the tap that serves the update feed

Finding E2. `jrmatherly/homebrew-tap` has no ruleset and `main` is unprotected. The app reads `appcast.xml` from that repository's `HEAD` (`app/Info.plist.in:34`). The release steps push to the tap's `main` directly, so the ruleset blocks only deletion and force-pushes.

```bash
gh api -X POST repos/jrmatherly/homebrew-tap/rulesets --input - << 'EOF'
{"name":"protect main","target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"deletion"},{"type":"non_fast_forward"}]}
EOF
```

- [ ] **Check:** `gh api repos/jrmatherly/homebrew-tap/rulesets --jq length` prints `1`. The next release's tap push still succeeds.

---

## Deferred, with reasons

These findings are recorded and not planned. Each names what would change the call.

| Finding | Why it waits | What would start it |
| --- | --- | --- |
| A4, second half, what is left. A run killed between the cookie rename and the `config.json` write leaves the old account's token with the new account's cookies, and the retry's re-save then stores those cookies in the outgoing profile. PR 73 fixed the failure cases (a copy or a write that fails rolls back) but not a kill. | A marker that makes the retry skip the re-save would also skip it when the marker is stale and the account has been used since, which loses rotated tokens. "When something is off" tells the user to restore the newest login backup by hand. | A design for a marker that expires, or one real sighting. |
| The second cookie rename failing after the first succeeded (`copy_cookies`, PR 73 review). | Both files are already staged in the destination folder, so only a `mv` within one folder can fail, and it could not be produced outside a stub. | The same rollback the config write has, added to the `copy_cookies "$dir" "$cookies"` failure in `profile_restore`, the next time that function is edited. |
| `save --force` under a second name: when the move of the other name's CLI item fails, nothing is said, and `profile_set_aside` then deletes the source item (`profile_save`, PR 73 review, pre-existing). | A warning in an `else` would also fire when the `cli_capture` that follows succeeds and makes the move moot. It needs the warning placed after the capture, and its own test. | Batch-sized work on `profile_save`. |
| B6. The custom path field applies on every keystroke, so each executable prefix it passes runs once with `--version` (`SettingsView.swift:192`). | It needs a design choice. Committing on submit needs separate field state, because `.onReceive(appState.$settings)` at line 75 overwrites `draft` on every settings change, and there is no focus state to commit on. Refusing a path whose file name is not `claude-multipass` is smaller but narrows what a user may point at. | Jason's pick between the two. |
| B6. `PipeDrain.stop()` can close a handle while a read is running (`CLI.swift:238`). | Inferred. It needs a grandchild still writing past the timeout. | A crash log that names `availableData`. |
| B6. A failed `list --json` keeps the old account in the menu bar strip. | Keeping the snapshot on failure is deliberate and tested (`AppStateTests.swift:282`). The open popover shows the error. | A report of a stale strip after a switch. |
| B6. `stop()` does not stop the launch task's timers. | Its only callers are `start()` and app termination, so nothing a user sees. | A new caller of `stop()`. |
| B6. A scheduled update probe that lands mid-switch is skipped for a day. | Manual checks still work, and the next daily tick recovers. | Updates becoming time-critical. |
| B6. `overlappingRelocatesKeepTheLastRequested` orders two tasks with a 20 ms sleep. | It has not failed in the last 200 CI runs. | Its first flake. |
| The eight strict-concurrency warnings under `-strict-concurrency=complete`. | Each access was traced to the main actor. No real race. | A move to the Swift 6 language mode. |
| Renaming the feed from `appcast.xml`. | A rename strands installed apps unless the old file stays. No second feed exists in the tap. | A second Sparkle app in the tap. |
| Re-measuring "7 s measured on 2026-10-27" in `CLAUDE.md`. | The figure only says the Swift tests are fast. | The next edit of that sentence. |
| A command quoted inside `sh -c "..."` is outside the ask rules. | A rule wide enough to catch it also asks on every commit message that names a command, which the settings self-check forbids. | A mode change that makes unmatched commands run unasked by default. |

## Appendix A. Findings and evidence

Evidence labels: **Reproduced** means a command was run and its output read on 2026-11-15. **Read** means the cited lines were read. **Inferred** means reasoned from the code and not run.

| Id | Finding | Evidence |
| --- | --- | --- |
| A1 | A failed `jq_write` returns 0 and empties its destination. A later switch then writes `oauthAccount: null`. | Reproduced. The fixture case fails on today's script and passes with the fix. |
| A2 | `backup_login` under `cli_backup` ignores a failed `mkdir` or `cp` and still prints "Backed up the current login". | Reproduced. When the folder cannot be made, the CLI write is already stopped by the next step, so the defect is the false message and a stray backup item, not a lost login. |
| A3 | `save` stores a CLI item with no `claudeAiOauth`. | Reproduced in the fixture. Whether Claude Code leaves that shape is unknown. |
| A4 | A killed switch can leave truncated cookies (first half) or mismatched ones (second half). | First half reproduced with a `cp` stub. Second half inferred. |
| A5 | The Raycast usage command errors while an LLMR profile runs. | Reproduced in the fixture. |
| A6 | The header says `save --llmr` touches no Keychain. | Read. |
| B1 | Turning usage on skips the 30 second floor. | Read. The floor is checked only at `AppState.swift:199`. |
| B2 | The timer floor has no test. | Read, against 276 passing tests. |
| B3 | No view reads `isRefreshing` or `isRefreshingUsage`. | Reproduced by grep. |
| B4 | Nothing enforces "Core imports only Foundation". | Reproduced by grep. It holds today. |
| B5 | A comment says opening the popover refreshes usage. | Read. |
| B6 | Seven smaller app items: the stale login item state (Task B3) and six in the Deferred table. | Read or inferred, as the Deferred table says. |
| C1 | The gate misses git aliases and four wrappers. | Reproduced in a scratch repository. The four aliases were confirmed in `git config`. |
| C2 | The pin parity check passes when a pin is missing. | Read. |
| C3 | `release.yml` has no `concurrency` and installs `jq`. | Read. |
| C4 | The ask rules match only at the start of a command. | Reproduced against the matcher in `test-settings.sh`. |
| C5 | `CLAUDE.md` says a push to `main` cancels the run before it. | Read at `check.yml:14`. |
| D1 | Three shipped plans sit in the active folder. | Reproduced with `gh pr list` and the code. |
| D2 | The gate list in `CLAUDE.md` omits the pin check. | Read. |
| D3 | Six script messages have no doc entry, and the exit code sentence misleads. | Read. |
| E1 | Renovate has never run, and Dependabot security updates are off. | Reproduced with `gh`. |
| E2 | The tap has no ruleset. | Reproduced with `gh api`. |
| E3 | There is no `SECURITY.md`. Private vulnerability reporting is already on. | Reproduced with `ls` and `gh api`. |

Checked and sound, so nothing is planned: every action SHA matches its tag, Sparkle 2.10.1 is the latest release, `pnpm outdated` reports nothing, the last 200 `check` runs have 0 failures, the release job verifies tag, version and changelog before it builds, and no token reaches argv, a log or a temp file beyond what `CLAUDE.md` permits.

Not covered by the audit: the running app (no visual or VoiceOver pass), `scripts/rehearse-update.sh`, the vendor claims in `docs/research.md`, and `.claude/rules/desktop-internals.md` in depth.

## Appendix B. What the plan review ran

This plan was reviewed on 2026-11-15, by a second reader and by running batch A in a scratch copy of `bin/`, `test/` and `raycast/` (not in the repository).

Run and passing:

- The `failclosed` section fails on today's script at `save warns when cli.json cannot be written`.
- With the Task A1 to A3 fixes applied, the section passes alone, and the whole self-check passes (`All claude-multipass checks passed`).
- Dropping each fix in turn makes its own case fail: `jq_write` at `save warns when cli.json cannot be written`, the `cli_restore` check at `switch refuses an unreadable cli.json`, the `backup_login` returns at `a backup that cannot be made is not announced`, the `cli_capture` check at `save names an item with no tokens`, and the cookie temp file at `and leaves the live Cookies file whole`.
- The Raycast LLMR case fails on today's script and passes with the Task A4 fix.
- `shellcheck --severity=warning` is clean on the three changed files.
- The Task C4 rule shapes, through the matcher in `test-settings.sh`.

Not run:

- Any Swift build or test for batch B, and `pnpm shots`.
- The Task C1 hook change and its self-check.
- The Task C2 mutations.
- `release.yml` after Task C3, which first runs at the next tag.
- The batch E commands. Their endpoints were checked with read-only `gh api` calls.

Corrections the review made to the first draft of this plan: the test section used a helper and fixture names that did not exist and assumed the wrong starting account; the `cli_restore` check sat where it would block a repair and printed to stdout; the cookie test's stub failed on the backup copy and never reached the live one; the ShellCheck count could pass with both pins in one file; the concurrency note claimed one release at a time; the ask-rule step moved a test sample that must stay; the path-field step would have been overwritten by the settings publisher and is now deferred; `.onAppear` does not fire on a re-shown window; and private vulnerability reporting was already on.
