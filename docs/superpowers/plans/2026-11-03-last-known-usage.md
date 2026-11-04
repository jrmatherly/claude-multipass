# Last-known usage implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** when an account's usage cannot be read, the account panel shows the last figures the tool read, labelled with their age, instead of only an error.

**Architecture:** Task 1 is a gate that can end this plan with nothing built. Past it, `usage` keeps each account's last good reading in `usage-last/<account>`, and an error entry in `usage --json` carries those figures and a `readAt`. Windows whose reset has passed, or that name no reset, are dropped when read. The app shows them in the hover panel only, never in the popover rows, the signed-in section or the menu bar strip.

**Tech Stack:** bash 3.2, `jq`, the fixture self-check, Swift 6 / SwiftUI, Swift Testing, `pnpm shots`.

**Spec:** this plan carries its own spec in the Findings section below.

**Depends on:** `2026-11-03-doctor-and-self-check-hardening.md` being merged first, because Task 4 of that plan sets the error strings this plan matches.

## Findings

Labels: **M** measured on this Mac on 2026-11-03, **S** read in this repo or Desktop's bundle, **I** inferred, **U** not known yet.

1. **S.** `access_token` returns nothing once the saved access token passes `expiresAt`, so a saved account that has sat idle reads as an error until it is used again. Token renewal is what clausona does here, and `.claude/rules/safety-and-terms.md` rejects it.
2. **U.** How soon that happens is unmeasured. Clausona says 8 hours in its docs, for the CLI's token. Nobody has recorded how often it shows in the popover here. Task 1 settles this.
3. **M.** Desktop's `plan-usage-history.json` was the first candidate. It holds 341 samples across 3 orgs, and each org matches exactly one `claude-code-sessions/<account>/<org>` folder.
4. **S.** It cannot carry this feature alone. Desktop's writer stores only `five_hour`, `seven_day`, the per-model `seven_day_*` figures and extra usage, each as a bare number. It holds no reset times and no `weekly_scoped` limit, so no Fable figure. It is also undocumented.
5. **M.** Idle figures drift, so an age label is mandatory. Across the 28 gaps of 6 hours or more in that history, the longest 92 hours: the weekly figure rose by 5 points or less in 15, by 6 to 20 in 4, by more than 20 in 5, and dropped in 4 (a reset). That is the rise while Desktop was not sampling that org, so a last-known figure can understate by over 20 points about one time in five.
6. **S.** `AppState.fetchUsage` clears all figures when the whole command fails, with the comment "Old figures would read as current". Clausona's `docs/plan-quota.md` records the same trap (an account signed out for a month listing `100% now`), and it drops the figures for a refused sign-in while keeping them, dimmed, for other failures.

Decisions, with reasons:

- **The tool keeps its own last reading.** It has reset times and Fable, which finding 4 rules out for Desktop's file, and it depends on nothing undocumented. Its cost is that it has data only for accounts read while usage was on. That is acceptable, since nothing else shows usage while it is off.
- **Drop a window once its `resetsAt` has passed, and drop one with no `resetsAt`.** A passed window's old figure is known to be wrong. A window with no reset could never expire, and the fixtures have them. Weekly windows reset within 7 days, so this bounds the age with no second expiry rule.
- **Figures only for failures that say nothing about the account:** a lapsed token, a 429, a `curl` failure or a 5xx. Everything else shows only the error, including a 401, any other 4xx, an unreadable response and a failed decrypt, following clausona's rule and finding 6.
- **Only in the hover panel.** The strip, the signed-in section and the popover rows read as current, so a stale 100% must never fill a gauge or a bar. `currentUsage` and `AccountRow.entry` both remove the figures. The signed-in account has no hover panel, because `PopoverView` only sets `rowHover` on the `others` rows.
- **No new network or Keychain call.** The cache is written from a response `usage` already got.

Corrected by the `interrogate` review on 2026-11-03 (Opus and Sonnet; the Fable seat hit its usage limit). This plan's code was traced by reading and not prototyped, apart from the drift measurement in finding 5.

Rejected: token renewal (the rules), Desktop's history as the source (finding 4), an in-memory cache in the app (lost on every relaunch, and the CLI's text output would differ).

## Global Constraints

- Follow `CLAUDE.md` Custom Notes: a worktree and branch, `pnpm install`, a PR against `main`, merging is Jason's call.
- The cached file holds no token, is mode 0600 in a 0700 folder, and is written with `mktemp` and `mv`. When the folder cannot be written, `usage` carries on without it.
- `usage` makes no extra network call and no extra `security` call. `list`, `show`, `current` and `doctor` still make none at all.
- Docs mirror behaviour: `README.md`, `docs/claude-multipass.md`, `--help` and `.claude/rules/safety-and-terms.md` change with the script. `CHANGELOG.md` gets one line under `## Unreleased`.
- Prose has no em-dashes, sentence-case headings and straight quotes.
- Before each commit run `/simplify` and `/code-review` on that commit's diff, per J mode. Any UI review starts with `pnpm shots`, light and dark.

## Review Focus

1. A reading whose weekly window reset yesterday: that window is gone from the output, and with no window left the entry is a plain error. Pinned in Task 2.
2. A lapsed token on any account: the strip, the signed-in section and the popover rows show no old figure, and only the hover panel does. Pinned in Task 3.
3. A refused token over a good cache: no figures, and the cache stays for a later recovery. A 403 behaves the same. Pinned in Task 2.
4. A corrupt or empty cache file, or an account id that is not an id such as `../escape`: treated as no cache, nothing written outside the folder, and `usage` never fails for it. Pinned in Task 2.
5. A saved account that shares no cache yet, such as one added today: a plain error, as before. Pinned in Task 2.

---

### Task 1: Decide whether this is worth building

This task is the gate. It changes no code in the repo, and its prototype is throwaway, in the session scratchpad.

**Files:** none in the repo. Append the result to this plan under a `## Gate result` heading, as a docs-only commit on `main`.

- [ ] **Step 1: Ask Jason to record what idle accounts show**

Over one normal day, Jason notes each saved account's line from the popover's hover panel, or from this command, twice, about 12 hours apart. Agents do not run it, since `usage` reads the Keychain and prompts.

```bash
claude-multipass usage
```

Record: which accounts showed `token expired` or `token lapsed`, and how long each had been idle.

- [ ] **Step 2: Apply the stop rule**

If no saved account shows it in that day, stop. Write "Gate failed: idle accounts do not lapse within a day here" under `## Gate result`, move this plan to `docs/superpowers/plans/completed/`, and build nothing.

- [ ] **Step 3: Re-read the drift numbers with Jason**

Show finding 5. If Jason would rather see an error than a figure that may understate by over 20 points, stop in the same way. This is a preference no run can settle.

- [ ] **Step 4: Record the result**

Write the accounts, idle times and decision under `## Gate result`. Commit and push to `main`, in separate calls.

```bash
git add docs/superpowers/plans/2026-11-03-last-known-usage.md
git commit -m "Record the last-known usage gate result"
```

### Task 2: Keep and read back the last reading in the tool

**Files:**

- Modify: `bin/claude-multipass` (`usage_fetch` at `:1414`, `usage_line` at `:1451`, `usage_object` at `:1463`; header comment and `--help` beside `plans/` at `:116` and `:380-395`)
- Modify: `README.md`, `docs/claude-multipass.md` near `:104`, `.claude/rules/safety-and-terms.md`, `CHANGELOG.md`
- Test: `test/claude-multipass.sh` (section `usage`)

**Interfaces:**

- Consumes: `usage_defs` (`win_ok`, `reset`, `scoped`, `ultra`), the error strings from the hardening plan.
- Produces, in `usage --json`: `{name, error}` as today, plus `readAt` (UTC `...Z`) and whichever of `plan`, `ultra`, `fiveHour`, `sevenDay`, `scoped` survive. In text: `<error> (as of <Day HH:MM>: <figures>)`.
- Internal: `usage_keep <account> <body>` writes the cache, and `usage_recall <account>` prints a compact body with passed and reset-less windows removed, or nothing when no window is left. Both guard `account` with the `^[0-9A-Za-z-]+$` test from `plan_label` and do nothing on a mismatch.
- Internal, the `usage_fetch` output on a carrying error: `error: <reason>`, a newline, then the recalled compact JSON. Both formatters call it in `$(...)`, so a variable cannot carry this. Each splits on the first newline, `${body%%$'\n'*}` for the reason and the rest for the JSON, and the second line is absent on every other error.

Cached shape, at `$root/usage-last/<account>`, one JSON object:

```json
{
  "five_hour": {},
  "seven_day": {},
  "limits": [],
  "_plan": "Ultra",
  "_readAt": "2026-11-03T14:05:00Z"
}
```

- [ ] **Step 1: Write the failing tests**

Use `write_curl` and the `usagey` profile. The fixture's `usage.json` has resets already in the past, so write one with future times, `date -u -v+3d +%Y-%m-%dT%H:%M:%SZ`, and write `usagey`'s token as expired after its good read, since `stale` can never have one. Name the cases, with these assertions:

- `usage keeps the reading of a good call`: `$CLAUDE_MULTIPASS_DIR/usage-last/<account>` exists, mode 600, its folder 700, and holds `_readAt`.
- `the kept reading holds no token`: `grep -c tok-u` on it is 0.
- `a lapsed token carries the last figures`: with the token expired after one good call, `usage --json` has `.error`, `.readAt` and `.sevenDay.utilization`.
- `a rate limit carries them too` and `an unavailable endpoint carries them too`: curl stubbed to 429, and to a failure exit.
- `a 5xx carries them too`: curl stubbed to 503.
- `a refused token carries none`: curl stubbed to 401, no `.sevenDay` and no `.readAt`, and the cache file still exists.
- `another 4xx carries none`: curl stubbed to 403, no `.sevenDay`.
- `a passed window is dropped`: a cache with `seven_day.resets_at` in the past and a future `five_hour` has no `.sevenDay` and keeps `.fiveHour`.
- `a window with no reset is dropped`: a cache whose `seven_day` has no `resets_at` has no `.sevenDay`.
- `nothing left means a plain error`: all windows passed, no `.readAt`.
- `a corrupt cache is ignored`: `not json` in the file, `usage` exits 0 with a plain error.
- `no cache means a plain error`: a profile never read.
- `an unwritable folder costs nothing`: `usage-last` mode 500, `usage` still prints figures from the call. Restore the mode after.
- `an account that is not an id keeps nothing`: the existing `escapey` case still finds no `$CLAUDE_MULTIPASS_DIR/escape`, and nothing appears outside `usage-last/`.
- `the text line names the age`: matches `(as of `.
- `no extra security call`: the `security-calls` count across a recalled run equals a normal run's.

- [ ] **Step 2: Run the section and confirm it fails**

Run: `bash test/claude-multipass.sh usage` Expected: exit 1 naming `usage keeps the reading of a good call`.

- [ ] **Step 3: Implement `usage_keep` and `usage_recall`, and call them**

`usage_fetch` calls `usage_keep` on a good body. Each branch sets a local `carry`: on for the lapsed token, 429, `curl` failure and 5xx, off otherwise. When it is on and `usage_recall` prints something, the output gains the second line from Interfaces. Both formatters' `case` on `error:\ *` then splits on the first newline, so the JSON never reaches the printed reason. `usage_recall` filters with `jq` in the style of the `reset` def.

- [ ] **Step 4: Run the section and confirm it passes**

Run: `bash test/claude-multipass.sh usage` Expected: `Filtered claude-multipass checks passed`.

- [ ] **Step 5: Update the docs and rules**

Name `usage-last/` wherever `plans/` is named. In `safety-and-terms.md`, add that the folder holds no secret, that it adds no network or Keychain call, and that the figures never reach the strip.

- [ ] **Step 6: Commit**

```bash
git add bin/claude-multipass test/claude-multipass.sh README.md docs/claude-multipass.md .claude/rules/safety-and-terms.md CHANGELOG.md
git commit -m "Keep each account's last usage reading for when a read fails"
```

### Task 3: Show the figures in the account panel, labelled

**Files:**

- Modify: `app/Sources/MultipassCore/Models.swift:106-132` (`UsageEntry`)
- Modify: `app/Sources/MultipassCore/AppState.swift:62` (`currentUsage`)
- Modify: `app/Sources/ClaudeMultipass/AccountPanel.swift:71-77`, `app/Sources/ClaudeMultipass/AccountRow.swift:114` (`entry`)
- Test: `app/Tests/MultipassCoreTests/ModelsTests.swift`, `app/Tests/MultipassCoreTests/AppStateTests.swift`, `app/Tests/ClaudeMultipassTests/AccountPanelTests.swift`, `app/Tests/ClaudeMultipassTests/ShotsTests.swift`

**Interfaces:**

- Consumes: the JSON from Task 2, and `Format.ago(_:now:)`.
- Produces: `UsageEntry.readAt: Date?` (nil on a live reading), and `UsageEntry.withoutLastKnown: UsageEntry`, which clears the figures and `readAt` and keeps `name`, `plan` and `error`.

- [ ] **Step 1: Write the failing tests**

- `decodesAnErrorWithLastKnownFigures` in `ModelsTests`: JSON with `error`, `readAt` and `sevenDay` decodes all three.
- `anUnreadableReadAtDropsOnlyThatField` in `ModelsTests`, matching how `ScopedWindow` treats a reset time that will not parse. A bad `readAt` must not sink the report, and with no age to show, the entry shows no figures.
- `currentUsageNeverShowsLastKnownFigures` in `AppStateTests`: for the signed-in account's entry with `readAt`, `currentUsage?.sevenDay == nil`, `.accountPeak == nil`, `.error` kept.
- `theOtherAccountKeepsItsLastKnownFigures` in `AppStateTests`: `usage["beta"]?.sevenDay` is still there.
- `aRowDrawsNoLastKnownFigures`, beside the existing row tests: a row whose entry has `error`, `readAt` and a 100% `sevenDay` has `accountFigure == nil`, `modelFigure == nil`, and the error as its `usageLabel`.
- `aPanelWithLastKnownFiguresNamesTheirAge` in `AccountPanelTests`: both the error and `as of 6 h ago` show, the `Format.ago` wording.
- A last-known fixture in `ShotsTests`.

- [ ] **Step 2: Run them and confirm they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path app` Expected: compile failure on `readAt`.

- [ ] **Step 3: Implement the model and `currentUsage`**

`try?` on one field needs a hand-written `init(from:)` over all of `UsageEntry`'s keys, as `ScopedWindow` has, and the existing memberwise `init` stays. A failed `readAt` parse leaves `readAt` nil and clears the figures when `error` is set, since they have no age to show. `currentUsage` returns `usage[...]?.withoutLastKnown`, and `withoutLastKnown` returns the entry unchanged when `readAt` is nil.

- [ ] **Step 4: Implement the panel**

`AccountPanel` shows the error, then, when `readAt` is set, the meters in `.secondary` under a caption `as of <Format.ago>`. The meters stay readable to VoiceOver with the age in the combined label. `AccountRow.entry` becomes `appState.usage[profile.name]?.withoutLastKnown`, so the row keeps its plain error and draws no figure or bar. `AccountPanel.detailEntry` keeps the raw entry.

- [ ] **Step 5: Run all the app's tests**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path app` Expected: all pass.

- [ ] **Step 6: Render and read the panel**

Run: `pnpm shots`, then read the new panel PNGs zoomed, light and dark. Expected: the figures read as old at a glance, the panel keeps its 260-point width, and the row beside it shows no bar. If they read as current, change the styling before committing. This is what the feature rests on.

- [ ] **Step 7: Commit**

```bash
git add app/Sources app/Tests
git commit -m "Show last-known usage in the account panel with its age"
```

### Task 4: Open the PR

**Files:** none new.

- [ ] **Step 1: Run the whole gate**

Run: `pnpm check` Expected: exit 0.

- [ ] **Step 2: Run the docs audit**

Run the `docs-audit` skill on the branch and fix what it finds in this PR.

- [ ] **Step 3: Push and open the PR against `main`**

The description quotes finding 5's drift numbers, and carries the shots. Add for Jason, on a real Mac: "With usage on, wait for an idle account to lapse, then confirm its panel shows the figures and their age, and that the strip does not." Stop at merge-ready.
