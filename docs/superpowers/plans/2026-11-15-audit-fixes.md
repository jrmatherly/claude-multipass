# Audit fixes implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the defects and close the gaps that the audit of 2026-11-15 found in the script, the menu bar app, the local tooling, the docs and the repository settings.

**Architecture:** Five batches, each one change with its own evidence. Batches A, B and C are code and each lands as its own pull request from its own worktree. Batch D is Markdown only and goes straight to `main`. Batch E is repository settings that only Jason can change. No batch depends on another, so they can run in any order or in parallel.

**Tech stack:** bash 3.2 and `jq` (`bin/claude-multipass`, `test/claude-multipass.sh`), Swift 6 with Swift Testing (`app/`), GitHub Actions, `gh`.

**Spec:** There is no separate spec. The audit findings are in [Appendix A](#appendix-a-findings-and-evidence), with the evidence label each one carries. A task cites its finding by id (A1, B2 and so on).

## Global constraints

- Code never goes to `main`. Each of batches A, B and C starts with `git worktree add .claude/worktrees/<branch> -b <branch>` and `pnpm install` in that worktree, and lands only through its PR after `check` is green. Merging is Jason's call.
- The commit-gate hook runs `pnpm check` before every commit. Format in one Bash call and commit in the next, because the hook checks the tree before the command runs.
- A user-visible change in `bin/` or `app/Sources/` adds its line under `## Unreleased` at the top of `CHANGELOG.md` in the same PR. `CHANGELOG.md` has no such heading today, so the first PR to need it adds the heading above `## 0.14.0`. A tooling-only change adds none.
- A change to what the script does edits `README.md` or `docs/claude-multipass.md` in the same commit.
- Every reproduced defect and every new warning gets a case in `test/claude-multipass.sh`. Prove a new section alone first: `bash test/claude-multipass.sh <section>`.
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
| `bin/claude-multipass` | A | `jq_write`, `cli_restore`, `cli_capture`, `cli_backup`, `backup_login`, `copy_cookies`, header line 25 |
| `test/claude-multipass.sh` | A | New section `failclosed`, three Raycast cases in `llmr` and `usage` |
| `raycast/claude-account-usage.sh` | A | LLMR branch |
| `app/Sources/MultipassCore/AppState.swift` | B | Usage floor on the toggle path, interval helper call |
| `app/Sources/MultipassCore/AppSettings.swift` | B | `usagePollInterval(minutes:)` |
| `app/Sources/ClaudeMultipass/PopoverView.swift`, `PopoverController.swift`, `SettingsView.swift` | B | Refresh state, comment, login item re-read, path commit |
| `app/Tests/MultipassCoreTests/AppStateTests.swift`, `AppSettingsTests.swift` | B | Three tests |
| `.claude/hooks/commit-gate.sh`, `test-commit-gate.sh` | C | Aliases and four wrappers |
| `.claude/settings.json`, `.claude/hooks/test-settings.sh` | C | Two ask-rule shapes per command |
| `test/check.sh` | C | Pin parity, Core import check |
| `.github/workflows/release.yml` | C | `concurrency`, no `brew install jq` |
| `.github/dependabot.yml`, `renovate.json` | C | Only if Jason picks Dependabot in E1 |
| `CLAUDE.md`, `.claude/skills/release/SKILL.md`, `docs/claude-multipass.md`, `README.md`, `SECURITY.md`, `docs/superpowers/plans/` | D | Corrections, new entries, three moves |

---

## Batch A. Harden the script's writes (one PR, branch `harden-cli-writes`)

### Task A1: `jq_write` fails closed and `cli_restore` rejects an unreadable identity

Findings A1 and A2. `jq_write` (`bin/claude-multipass:438`) runs inside `||` lists at lines 737 and 891, where bash turns `errexit` off for the whole function body. A failed `jq` then leaves `out` empty, `mv` installs a 0-byte file and the function returns 0.

**Files:**

- Modify: `bin/claude-multipass:438-444` (`jq_write`), `:930-934` (`cli_restore`), `:1146-1151` (`backup_login`), `:884-886` (`cli_backup`)
- Test: `test/claude-multipass.sh`, new section `#@ failclosed needs switch`, placed before `#@ done`

**Interfaces:**

- Produces: `jq_write <dest> <jq args...>` returns non-zero and leaves `<dest>` and no `<dest>.tmp` when `jq` or the write fails. `backup_login` returns 1 when its `mkdir` or its `cp` of `config.json` fails, and prints "Backed up" only on success.

- [ ] **Step 1: Write the failing tests**

Add the section. Use the profiles the `switch` section leaves, and follow the fixture style at `test/claude-multipass.sh:361` for writing `cli.json`. The `jq` stub makes only the identity write fail, and it removes its own folder from `PATH` before `exec`, as the `cda_stdin` wrappers do.

```bash
#@ failclosed needs switch
# a failed identity write keeps the old file and says so
mkdir -p "$tmp/jqfail"
printf '#!/bin/sh\ncase "$*" in *"--tab {oauthAccount}"*) exit 5 ;; esac\nPATH=${PATH#%s:}\nexec jq "$@"\n' "$tmp/jqfail" > "$tmp/jqfail/jq"
chmod +x "$tmp/jqfail/jq"
before=$(cksum < "$p/alpha/cli.json")
out=$(PATH="$tmp/jqfail:$PATH" err_of cda save alpha)
check_true "save warns when cli.json cannot be written" grep -q 'could not write .*alpha/cli.json' <<< "$out"
check "and keeps the old cli.json" "$before" "$(cksum < "$p/alpha/cli.json")"
check_true "and leaves no temp file" test ! -e "$p/alpha/cli.json.tmp"
# an empty saved identity is never restored
cp "$p/beta/cli.json" "$tmp/beta-cli.json"
: > "$p/beta/cli.json"
live=$(jq -c .oauthAccount "$tmp/claude.json")
out=$(err_of cda switch beta)
check_true "switch refuses an unreadable cli.json" grep -q 'the saved CLI identity for beta is unreadable; run claude auth login, then save beta' <<< "$out"
check "and keeps oauthAccount in the CLI config" "$live" "$(jq -c .oauthAccount "$tmp/claude.json")"
cp "$tmp/beta-cli.json" "$p/beta/cli.json"
# a backup that cannot be made stops the CLI write
chmod 500 "$b"
out=$(err_of cda switch alpha)
chmod 700 "$b"
check_true "no backup, no claim of one" test -z "$(grep 'Backed up the current login' <<< "$out")"
```

`save alpha` must run while Desktop's live account is alpha, and the last case must reach the same-account repair path, where `backup_dest` is still empty. Add the `cda switch` calls that put the fixture in those states, and assert the exit code each time with `exit_code`.

- [ ] **Step 2: Run the section and see it fail**

Run: `bash test/claude-multipass.sh failclosed` Expected: exit 1 at `save warns when cli.json cannot be written`.

- [ ] **Step 3: Make `jq_write` fail closed**

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

- [ ] **Step 4: Make `cli_restore` reject an identity with no account id**

After the `[[ ! -f $dir/cli.json ]]` block at line 930, add a check that `jq -e '.oauthAccount.accountUuid | strings' "$dir/cli.json"` succeeds. On failure, `warning "the saved CLI identity for $name is unreadable; run claude auth login, then save $name"` and `return 0`.

- [ ] **Step 5: Make `backup_login` and its caller report a failed backup**

In `backup_login`, add `|| return 1` to the `mkdir` subshell and to `cp -p "$config" "$backup_dest/config.json"`. In `cli_backup`, replace `[[ -n $backup_dest ]] || backup_login` with a form that warns `could not back up the current login; switched Desktop only` and returns 1 when `backup_login` fails.

- [ ] **Step 6: Run the section, then the whole file**

Run: `bash test/claude-multipass.sh failclosed`, then `bash test/claude-multipass.sh` Expected: `ok:` for every case, exit 0.

- [ ] **Step 7: Commit**

Add a line under `## Unreleased` in `CHANGELOG.md`: a failed write of a profile's CLI identity now keeps the old file and warns, and a switch refuses to restore from an identity file it cannot read. Add one bullet to "When something is off" in `docs/claude-multipass.md` for the new `unreadable` warning.

```bash
git add bin/claude-multipass test/claude-multipass.sh CHANGELOG.md docs/claude-multipass.md
git commit -m "Fail closed when the CLI identity cannot be written"
```

### Task A2: `save` skips a CLI item that holds no tokens

Finding A3. `cli_restore` already treats an item without `claudeAiOauth` as no login (`bin/claude-multipass:943`). `cli_capture` does not, so `save` can store it.

**Files:**

- Modify: `bin/claude-multipass:727-730` (`cli_capture`, beside the `cli_cleared` check)
- Test: `test/claude-multipass.sh`, section `failclosed`

- [ ] **Step 1: Write the failing test**

```bash
# an item with shared keys and no login is not a CLI login
saved=$(kc_get "$mp_service_name" alpha)
kc_put "Claude Code-credentials" "$cli_user" '{"mcpOAuth":{"srv":"shared"}}'
out=$(err_of cda save alpha)
check_true "save names an item with no tokens" grep -q 'alpha: the live CLI login holds no tokens; saved the Desktop login only' <<< "$out"
check "and keeps the profile's saved CLI login" "$saved" "$(kc_get "$mp_service_name" alpha)"
```

Use the fixture's own names for the service and account arguments of `kc_get` and `kc_put` (see `test/claude-multipass.sh:160-169`), and restore the live item afterwards.

- [ ] **Step 2: Run it and see it fail**

Run: `bash test/claude-multipass.sh failclosed` Expected: exit 1 at `save names an item with no tokens`.

- [ ] **Step 3: Add the check to `cli_capture`**

Before the `cli_cleared` check, test `printf '%s' "$live" | jq -e '.claudeAiOauth != null'`. On failure, `warning "$name: the live CLI login holds no tokens; saved the Desktop login only"` and `return 0`. The token-bearing item reaches `jq` on stdin, as everywhere else.

- [ ] **Step 4: Run the section and the whole file**

Expected: exit 0.

- [ ] **Step 5: Commit**

Add the `CHANGELOG.md` line and a "When something is off" bullet for the new warning.

```bash
git commit -am "Skip a CLI item that holds no login on save"
```

### Task A3: Cookie files are replaced atomically

Finding A4, the cheap half. `copy_cookies` (`bin/claude-multipass:1136`) runs `cp -p` onto the live `Cookies` file, so a kill mid-copy can leave a truncated file. The other half of A4 is deferred (see [Deferred](#deferred-with-reasons)).

**Files:**

- Modify: `bin/claude-multipass:1136-1141`
- Test: `test/claude-multipass.sh`, section `failclosed`

- [ ] **Step 1: Write the failing test**

A `cp` stub on the fixture `PATH` that writes half the source and exits 1 when its target ends in `Cookies.tmp`, and otherwise runs `/bin/cp`.

```bash
before=$(cksum < "$d/Cookies")
check "a switch whose cookie copy dies fails" 1 "$(exit_code cda switch beta)"
check "and leaves the live Cookies file whole" "$before" "$(cksum < "$d/Cookies")"
```

Use `$d/Network/Cookies` when the fixture has a `Network/` folder. Remove the stub afterwards.

- [ ] **Step 2: Run it and see it fail**

Expected: exit 1 at `and leaves the live Cookies file whole`.

- [ ] **Step 3: Copy through a temp file**

In `copy_cookies`, copy each file to `"$2/$f.tmp"` with `cp -p` and then `mv` it onto `"$2/$f"`. Remove the `.tmp` when the `cp` fails, and let the failure stop the run.

- [ ] **Step 4: Run the section and the whole file**

Expected: exit 0. The mode cases in `setup` and `switch` already assert 0600 on the cookie files.

- [ ] **Step 5: Commit**

No `CHANGELOG.md` line, since nothing a user sees changes.

```bash
git commit -am "Replace cookie files through a temp file"
```

### Task A4: The Raycast usage command handles an LLMR profile, and the header says what `--force` deletes

Findings A5 and A6.

**Files:**

- Modify: `raycast/claude-account-usage.sh:28-32`, `bin/claude-multipass:25`
- Test: `test/claude-multipass.sh`, section `llmr` (the LLMR case) and section `usage` beside line 1418 (the other two)

- [ ] **Step 1: Write the failing tests**

```bash
# section llmr, while the LLMR Desktop runs as the saved profile `gw`
check "Raycast usage names an LLMR profile and exits 0" "gw" "$("$raycast/claude-account-usage.sh")"
check "with status 0" 0 "$(exit_code "$raycast/claude-account-usage.sh")"
# section usage
check "Raycast usage passes through signed out" "signed out" "$("$raycast/claude-account-usage.sh")"
check "Raycast usage passes through not saved" "not saved" "$("$raycast/claude-account-usage.sh")"
```

Use the LLMR profile name the `llmr` section already saves in place of `gw`, and put each case where the fixture is in that state.

- [ ] **Step 2: Run them and see the LLMR case fail**

Run: `bash test/claude-multipass.sh llmr` Expected: exit 1 at `Raycast usage names an LLMR profile and exits 0`.

- [ ] **Step 3: Add the LLMR branch**

In the `*)` arm, read the profile's kind from `"$cda" list --json` with `jq -r --arg n "$name" '.profiles[] | select(.name == $n) | .kind // ""'`. When it is `llmr`, `echo "$name"`. Otherwise run `"$cda" usage "$name"` as today, so a real `usage` error still shows.

- [ ] **Step 4: Correct the header line**

Change line 25 from `(no quit, no Keychain)` to `(no quit; with --force over a claude.ai profile, that profile's CLI item is deleted)`. The `--help` text at line 292 is already right.

- [ ] **Step 5: Run both sections and the whole file, then commit**

Add a `CHANGELOG.md` line for the Raycast fix.

```bash
git commit -am "Show an LLMR profile's name in the Raycast usage command"
```

- [ ] **Step 6: Open the PR**

Push the branch and open the PR against `main`. The `## Why` opens with the goal: a failed write must never pass for a success, since the next switch trusts what the last one saved.

---

## Batch B. Close the usage floor and polish the app (one PR, branch `usage-floor-and-app-polish`)

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

```bash
git commit -am "Test the usage poll interval's five minute floor"
```

### Task B3: Refresh shows that it is running, and two stale views are corrected

Findings B3, B5 and B6 (the login item and the path field).

**Files:**

- Modify: `app/Sources/ClaudeMultipass/PopoverView.swift:55`, `PopoverController.swift:5-6`, `SettingsView.swift:37-39`, `:112`, `:192-196`

- [ ] **Step 1: Disable Refresh while a refresh runs**

Add `.disabled(appState.isRefreshing || appState.isRefreshingUsage)` to the Refresh button.

- [ ] **Step 2: Correct the popover comment**

`PopoverController.swift:5-6` becomes "Opening it refreshes the snapshot. Usage runs on its own timer."

- [ ] **Step 3: Re-read the login item each time the General pane appears**

In `.onAppear` of the General pane, set `launchAtLogin = Self.loginItemOn` and `loginItemNote = Self.approvalNote`. The settings window is cached for the app's lifetime, so the `@State` initializers run once.

- [ ] **Step 4: Apply the custom path on submit, not per keystroke**

`cliPathBinding`'s setter writes only `draft.cliPathOverride`. The `TextField` at line 112 gets `.onSubmit` that calls `update(\.cliPathOverride, ...)` with the draft value, and the same commit runs when the field loses focus. Today each keystroke runs `<prefix> --version` on whatever executable the prefix names.

- [ ] **Step 5: Verify**

Run: `swift test --package-path app`, then `pnpm shots` Expected: both pass. The shots suite asserts that no settings field takes focus on open and that the General tab grows when Custom adds the path field. Read the General tab and popover PNGs in `.shots/`, light and dark.

- [ ] **Step 6: Commit and open the PR**

Add `CHANGELOG.md` lines for the Refresh button, the login item state and the path field.

```bash
git commit -am "Show a running refresh and re-read the login item"
```

The PR's `## Why` opens with the goal: the app must hold the usage rails it states, on every path that can start a read.

---

## Batch C. Harden the gate and CI (one PR, branch `gate-and-ci-hardening`)

### Task C1: The commit gate follows git aliases and four more wrappers

Finding C1. `git cm`, `git amend`, `git append` and `git empty` are aliases for `git commit` in Jason's global config, and the hook matches only the literal subcommand `commit` (`.claude/hooks/commit-gate.sh:102`).

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

Require exactly two `SHELLCHECK_SHA256:` lines and two `SHELLCHECK_VERSION:` lines across `check.yml` and `release.yml`, with one unique value for each. Keep the message `check: check.yml and release.yml pin different ShellCheck releases` for a mismatch, and add `check: a workflow has no ShellCheck pin` for a count other than two.

- [ ] **Step 2: Add the Core import check**

Beside the Sparkle check, fail with `check: MultipassCore may import only Foundation, found: <files>` when any file under `app/Sources/MultipassCore` has an `import` line other than `import Foundation`.

- [ ] **Step 3: Prove each check by mutation**

On a scratch copy of the repo, delete the `SHELLCHECK_SHA256` line from `release.yml` and run the pin block. Expected: `a workflow has no ShellCheck pin`, exit 1. Add `import SwiftUI` to a scratch copy of `Formatting.swift` and run the import block. Expected: the new message, exit 1. Record both outputs in the PR body. Then run `pnpm check` on the clean tree. Expected: exit 0.

- [ ] **Step 4: Commit**

Add both checks to the `pnpm check` list in `CLAUDE.md` in the same commit.

```bash
git commit -am "Fail the gate on a missing pin or a UI import in Core"
```

### Task C3: The release workflow runs one at a time and installs nothing it has

Finding C3.

**Files:**

- Modify: `.github/workflows/release.yml:7-9`, `:41-43`

- [ ] **Step 1: Add the concurrency group**

After `permissions:`, add:

```yaml
concurrency:
  group: release-${{ github.ref }}
  cancel-in-progress: false
```

- [ ] **Step 2: Replace `brew install jq`**

Replace the step with `- run: command -v jq`. `check.yml` runs `pnpm check`, which needs `jq`, on the same `macos-26` image with no install step, and its last 200 runs have 0 failures.

- [ ] **Step 3: Verify and commit**

Run: `node_modules/.bin/prettier --check .github/workflows/release.yml` Expected: no output, exit 0. The workflow itself first runs at the next tag, so say in the PR body that it is unproven until then.

```bash
git commit -am "Run one release at a time and stop installing jq"
```

### Task C4: The ask rules cover `./claude-multipass` and a tool named mid-command

Finding C4. Rules such as `Bash(claude-multipass switch*)` match only at the start of the command.

**Files:**

- Modify: `.claude/settings.json` (`permissions.ask`)
- Test: `.claude/hooks/test-settings.sh:71` (the `asks` array) and its must-not-ask list

- [ ] **Step 1: Write the failing samples**

Add to `asks`: `"cd bin && ./claude-multipass switch w"`, `"timeout 60 claude-multipass switch w"`, `"env FOO=1 claude-multipass save w"`, `"echo w | xargs claude-multipass switch"`, `'sh -c "claude-multipass remove w"'`. Add to the must-not-ask list: `"timeout 60 claude-multipass list"`.

- [ ] **Step 2: Run it and see it fail**

Run: `.claude/hooks/test-settings.sh` Expected: a failure naming the first new sample.

- [ ] **Step 3: Add two rules per mutating command**

For each of `switch`, `add`, `save`, `remove`, `rename`, `sync`, `usage` and `pick`, add `Bash(*./claude-multipass* <cmd>*)` and `Bash(* claude-multipass <cmd>*)`. The existing test sample "a commit message naming a command must not ask" will now ask. Move that sample to `asks` and note in `.claude/rules/testing.md` that a commit message holding ` claude-multipass <cmd>` costs one extra prompt.

- [ ] **Step 4: Run the self-check, commit and open the PR**

Update the ask-rule sentence in `CLAUDE.md` in the same commit.

```bash
git commit -am "Ask before the tool when it is named mid-command"
```

The PR's `## Why` opens with the goal: the gate and the ask rules must hold for the forms a person and an agent really type.

---

## Batch D. Correct the docs (Markdown only, straight to `main`)

One commit per task, pushed with the docs-only bypass. Run `node_modules/.bin/prettier --write` on each edited file except `CLAUDE.md`, which `.prettierignore` skips.

### Task D1: Move the three shipped plans

Finding D1. PRs 66, 68 and 71 are merged and the code is present.

- [ ] **Step 1:** `git mv` these three into `docs/superpowers/plans/completed/`: `2026-11-02-cli-writeback-guard.md`, `2026-11-03-cli-login-truthful-surfaces.md`, `2026-11-03-doctor-and-self-check-hardening.md`.
- [ ] **Step 2:** `grep -rn "plans/2026-11-0[23]-" --include='*.md' .` and repoint each link it finds.
- [ ] **Step 3:** Commit as `Move three shipped plans to completed`.

`2026-11-03-last-known-usage.md` stays. Its Task 1 gate still waits on Jason's two `usage` recordings. `2026-11-15-doctor-cleanup.md` stays until Jason takes the `/context` reading.

### Task D2: Correct `CLAUDE.md` and the release skill

Findings D2 and C8.

- [ ] **Step 1:** In the `pnpm check` bullet of `CLAUDE.md`, add "that `check.yml` and `release.yml` pin the same ShellCheck release". The check exists at `test/check.sh:117` and the list omits it. Skip this step if Task C2 has landed, since that task rewrites the same sentence.
- [ ] **Step 2:** In Custom Notes, replace "each push to `main` cancels the run before it, so only the tip's run counts, and a cancelled tip run is rerun with `gh run rerun <id>`" with the true behavior: `check.yml` cancels in-progress runs for pull requests only, a run on `main` finishes, and a queued run is replaced by a newer one, so the tip's run is the one to read. Make the same correction where `.claude/skills/release/SKILL.md` repeats it.
- [ ] **Step 3:** Run `/docs-audit` on the result. Commit as `Correct the gate list and the CI cancellation note`.

### Task D3: Explain the messages the script prints

Findings D4, D5 and D6.

- [ ] **Step 1:** Add bullets to "When something is off" in `docs/claude-multipass.md` for these messages, each with its cause and the next step. Take the exact text from the script.
  - `Claude did not quit; quit it by hand and retry` (`bin/claude-multipass:1015`)
  - `Claude Code holds <lock>; retry in a moment`, and its `save` form that ends "saved the Desktop login only" (`:2037`, `:2038`)
  - `Could not read "Claude Safe Storage" from the login Keychain` (`:1311`), which a denied Keychain prompt raises
  - The `usage` rows `cannot decrypt (the profile was saved on another Mac, or the app changed its key)`, `rate limited` and `unavailable (HTTP n)` (`:1453` and nearby)
- [ ] **Step 2:** At `docs/claude-multipass.md:203`, say that a bad option, a wrong name count and a misplaced `--force`, `--json` or `--llmr` exit 1, and that only an unknown command and a bare run without a terminal or `fzf` exit 2.
- [ ] **Step 3:** In `README.md`, after Install, add one line that points to "When something is off" for a refused first switch (exit 3).
- [ ] **Step 4:** Check each quoted message against the script with `grep -n`. Commit as `Explain the remaining script messages`.

### Task D4: Add `SECURITY.md`

Finding E3. Depends on Task E3, which turns on the reporting channel it names.

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

### Task E3: Turn on private vulnerability reporting

```bash
gh api -X PUT repos/jrmatherly/claude-multipass/private-vulnerability-reporting
```

- [ ] **Check:** `gh api repos/jrmatherly/claude-multipass/private-vulnerability-reporting --jq .enabled` prints `true`. Task D4 can then land.

---

## Deferred, with reasons

These findings are recorded and not planned. Each names what would change the call.

| Finding | Why it waits | What would start it |
| --- | --- | --- |
| A4, second half. A kill between the config merge and the cookie copy leaves the new tokens with the old cookies, and a re-run skips the copy because `Cookies` exists (`bin/claude-multipass:2063`). | Inferred from code order, not reproduced. The fix needs a marker file and a recovery path, and "When something is off" already sends a half-finished switch to the login backup. | One real sighting of a wrong-account Desktop after a killed switch. |
| B6. `PipeDrain.stop()` can close a handle while a read is running (`CLI.swift:238`). | Inferred. It needs a grandchild still writing past the timeout. | A crash log that names `availableData`. |
| B6. A failed `list --json` keeps the old account in the menu bar strip. | Keeping the snapshot on failure is deliberate and tested (`AppStateTests.swift:282`). The open popover shows the error. | A report of a stale strip after a switch. |
| B6. `stop()` does not stop the launch task's timers. | Its only callers are `start()` and app termination, so nothing a user sees. | A new caller of `stop()`. |
| B6. A scheduled update probe that lands mid-switch is skipped for a day. | Manual checks still work, and the next daily tick recovers. | Updates becoming time-critical. |
| B6. `overlappingRelocatesKeepTheLastRequested` orders two tasks with a 20 ms sleep. | It has not failed in the last 200 CI runs. | Its first flake. |
| The eight strict-concurrency warnings under `-strict-concurrency=complete`. | Each access was traced to the main actor. No real race. | A move to the Swift 6 language mode. |
| Renaming the feed from `appcast.xml`. | A rename strands installed apps unless the old file stays. No second feed exists in the tap. | A second Sparkle app in the tap. |
| Re-measuring "7 s measured on 2026-10-27" in `CLAUDE.md`. | The figure only says the Swift tests are fast. | The next edit of that sentence. |

## Appendix A. Findings and evidence

Evidence labels: **Reproduced** means a command was run and its output read on 2026-11-15. **Read** means the cited lines were read. **Inferred** means reasoned from the code and not run.

| Id | Finding | Evidence |
| --- | --- | --- |
| A1 | A failed `jq_write` returns 0 and empties its destination. | Reproduced twice. The real function, given a bad input file inside `\|\|`, returned 0 and left a 0-byte file. |
| A2 | `backup_login` under `cli_backup` ignores a failed `mkdir` or `cp`. | Read. Same mechanism as A1. |
| A3 | `save` stores a CLI item with no `claudeAiOauth`. | Read. Whether Claude Code leaves that shape is unknown. |
| A4 | A killed switch can leave mismatched or truncated cookies. | Inferred. |
| A5 | The Raycast usage command errors while an LLMR profile runs. | Read. |
| A6 | The header says `save --llmr` touches no Keychain. | Read. |
| B1 | Turning usage on skips the 30 second floor. | Read. The floor is checked only at `AppState.swift:199`. |
| B2 | The timer floor has no test. | Read, against 276 passing tests. |
| B3 | No view reads `isRefreshing` or `isRefreshingUsage`. | Reproduced by grep. |
| B4 | Nothing enforces "Core imports only Foundation". | Reproduced by grep. It holds today. |
| B5 | A comment says opening the popover refreshes usage. | Read. |
| B6 | Six smaller app items. | Read or inferred, as the Deferred table says. |
| C1 | The gate misses git aliases and four wrappers. | Reproduced by the reviewer in a scratch repository. The four aliases were confirmed in `git config`. |
| C2 | The pin parity check passes when a pin is missing. | Read. |
| C3 | `release.yml` has no `concurrency` and installs `jq`. | Read. |
| C4 | The ask rules match only at the start of a command. | Reproduced against the matcher in `test-settings.sh`. |
| C8 | `CLAUDE.md` says a push to `main` cancels the run before it. | Read at `check.yml:13`. |
| D1 | Three shipped plans sit in the active folder. | Reproduced with `gh pr list` and the code. |
| D2 | The gate list in `CLAUDE.md` omits the pin check. | Read. |
| D4 to D6 | Five script messages have no doc entry, and the exit code sentence misleads. | Read. |
| E1 | Renovate has never run, and Dependabot security updates are off. | Reproduced with `gh`. |
| E2 | The tap has no ruleset. | Reproduced with `gh api`. |
| E3 | There is no `SECURITY.md`. | Reproduced with `ls`. |

Checked and sound, so nothing is planned: every action SHA matches its tag, Sparkle 2.10.1 is the latest release, `pnpm outdated` reports nothing, the last 200 `check` runs have 0 failures, the release job verifies tag, version and changelog before it builds, and no token reaches argv, a log or a temp file beyond what `CLAUDE.md` permits.

Not covered by the audit: the running app (no visual or VoiceOver pass), `scripts/rehearse-update.sh`, the vendor claims in `docs/research.md`, and `.claude/rules/desktop-internals.md` in depth.
