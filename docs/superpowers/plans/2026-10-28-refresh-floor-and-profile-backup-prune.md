# Refresh floor and profile backup prune implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A 30 second floor on the menu bar app's manual usage refresh, and a newest-ten prune of `backups/profile-*` in the tool.

**Architecture:** Two independent changes in two PRs. The floor is one stamp and one guard in `AppState.refreshUsage()`, the single method every usage trigger passes through, tested with the injected clock. The prune is one function in `bin/claude-multipass` called from `profile_set_aside`, sorting the set-aside folders on their timestamp, tested in the fixture self-check.

**Tech Stack:** Swift 5 language mode (`app/Package.swift`, tools 5.9, SwiftPM, Swift Testing, `FakeRunner`), bash 3.2, `jq`, the fixture self-check `test/claude-multipass.sh`.

**Spec:** `docs/superpowers/specs/2026-10-28-refresh-floor-and-profile-backup-prune.md`

Line numbers below are from `main` at `aa591e4`. PR 35 adds six lines to `test/claude-multipass.sh` and shifts `bin/claude-multipass` by a few lines, so each step also names the function or the string to search for; the anchor wins over the number.

## Global constraints

- Each task is its own branch in its own git worktree, opened as a PR against `main`, merged only after `check.yml` is green. Never commit code on `main`. After `git worktree add`, run `pnpm install` in the worktree.
- `pnpm check` is the gate; the commit-gate hook runs it before every commit. Format in a separate call before committing.
- A user-visible change adds a line under `## Unreleased` in `CHANGELOG.md` (create that heading above the newest release heading when it is absent) and edits `README.md` or `docs/` in the same PR.
- No `security` call outside `usage`, `save`, `add`, `switch`, `rename`, `remove` and the backup prune; `list`, `show`, `current` and `doctor` never call it.
- The floor is 30 seconds, on attempts (success or failure), reset when usage is turned off. The prune keeps the newest ten `profile-*` folders.
- bash 3.2 and BSD tools: no `head -n -N`, globs instead of `ls`, `[[ =~ ]]` with `BASH_REMATCH`.
- Prose in docs, comments and replies: no em dashes, short declarative sentences, straight quotes.

## Review focus

1. A Refresh click within 30 seconds of a failed usage run: the user expects no retry storm; the figures stay cleared and the error stays shown. Pinned by `usageRefreshWithinTheFloorIsSkipped` (Task 1), which fails the first run.
2. Usage turned off and on again within 30 seconds: the user expects fresh figures at once, as today. Pinned by `disablingUsageResetsTheFloor` (Task 1).
3. A profile name containing hyphens, such as `aa-two`, set aside: the prune must sort on the stamp, not the name, and keep the newest folder. Pinned by the self-check case in Task 2, whose newest folder has that name and sorts first by name.
4. A set-aside folder renamed by hand so it has no stamp: the prune must leave it alone rather than guess its age. Pinned by Task 2's case, which seeds one such folder and asserts it survives.
5. `doctor` after the prune: it must count both kinds without a `security` call. Pinned by Task 2's `doctor` assertion and the existing `security-calls` line-count check in the `doctor` case.

---

### Task 1: Floor on the manual usage refresh (app)

**Files:**

- Modify: `app/Sources/MultipassCore/AppSettings.swift` (one constant beside `snapshotInterval`, line 15)
- Modify: `app/Sources/MultipassCore/AppState.swift` (`isRefreshingUsage` line 48, `usageFetch` line 72, `apply` line 83, `refreshUsage` lines 160 to 168)
- Test: `app/Tests/MultipassCoreTests/AppStateTests.swift` (`readyState` at line 123; new tests after `usageUpdatedAtFollowsTheLastSuccess`, line 584)
- Docs: `docs/claude-multipass.md` line 81, `.claude/rules/safety-and-terms.md` (Keychain line and the "Usage polling" paragraph), `CLAUDE.md` (the `usage` safety rail), `CHANGELOG.md` under `## Unreleased`

**Interfaces:**

- Produces: `AppSettings.usageRefreshFloor: TimeInterval` (30). `AppState` gains a private `usageAttemptedAt: Date?`; `refreshUsage()` returns without a run while `now().timeIntervalSince(usageAttemptedAt) < AppSettings.usageRefreshFloor`. Nothing public changes shape. In the tests, `TestClock` (a plain `final class` with `var now: Date`; Swift 5 language mode, so no isolation annotation) and `readyState(clock:)`.

- [ ] **Step 1: Create the worktree and branch**

```bash
git worktree add -b usage-refresh-floor .claude/worktrees/usage-refresh-floor origin/main && cd .claude/worktrees/usage-refresh-floor && pnpm install
```

- [ ] **Step 2: Add a test clock and the failing tests**

Six existing tests make two usage attempts with no time between them (`readyState()` uses real time), so the floor needs a clock the tests can advance. Add beside `readyState`:

```swift
final class TestClock {
  var now = Date(timeIntervalSince1970: 1_000_000)
}

@MainActor
private func readyState(clock: TestClock = TestClock()) async -> (AppState, FakeRunner) {
  let r = readyRunner()
  let s = makeState(r, now: { clock.now })
  await s.relocate()
  await s.refresh()
  r.clearCalls()
  return (s, r)
}
```

That replaces the existing `readyState()`; every current caller compiles unchanged. Then add after `usageUpdatedAtFollowsTheLastSuccess`:

```swift
@Test @MainActor func usageRefreshWithinTheFloorIsSkipped() async {
  let clock = TestClock()
  let (s, r) = await readyState(clock: clock)
  r.fail("usage", .timedOut)
  await s.apply(enabledUsage(s))
  r.answer("usage", usageBoth)
  r.clearCalls()
  clock.now += 29
  await s.refreshAll()
  #expect(r.calls == [["list", "--json"]])
  #expect(s.usage.isEmpty)
  clock.now += 1
  await s.refreshAll()
  #expect(r.calls == [["list", "--json"], ["list", "--json"], ["usage", "--json"]])
  #expect(s.usage["beta"] != nil)
}

@Test @MainActor func disablingUsageResetsTheFloor() async {
  let (s, r) = await readyState()
  await s.apply(enabledUsage(s))
  var off = s.settings
  off.usageEnabled = false
  await s.apply(off)
  r.clearCalls()
  await s.apply(enabledUsage(s))
  #expect(r.calls == [["usage", "--json"]])
}
```

- [ ] **Step 3: Run them to verify the first fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path app --filter 'usageRefreshWithinTheFloorIsSkipped|disablingUsageResetsTheFloor'` Expected: `usageRefreshWithinTheFloorIsSkipped` fails on its first `#expect(r.calls == ...)` because a second `usage` call ran; `disablingUsageResetsTheFloor` passes already (it pins behaviour the floor must not break).

- [ ] **Step 4: Add `public static let usageRefreshFloor: TimeInterval = 30` to `AppSettings`**

Beside `snapshotInterval` in `app/Sources/MultipassCore/AppSettings.swift`.

- [ ] **Step 5: Implement the floor in `AppState`**

In `app/Sources/MultipassCore/AppState.swift`: a `private var usageAttemptedAt: Date?` beside `usageFetch`. In `refreshUsage()`, after the existing guard, return when `let last = usageAttemptedAt, now().timeIntervalSince(last) < AppSettings.usageRefreshFloor`. Set `usageAttemptedAt = now()` where `isRefreshingUsage = true` is set, before the run. In `apply`, the `(true, false)` case sets `usageAttemptedAt = nil`. One comment on the guard: a Refresh click runs `usage` at once, so a burst of clicks costs one Keychain read and one GET per account, not one per click.

- [ ] **Step 6: Advance the clock in the six tests that make a second attempt**

Each of these makes a usage attempt through `apply(enabledUsage(s))` and then a second one; without time passing the floor skips the second and the test fails. In each, take the clock from `readyState` (`let clock = TestClock(); let (s, r) = await readyState(clock: clock)`) and add `clock.now += AppSettings.usageRefreshFloor` before the second attempt:

- `refreshAllFetchesUsageWhenEnabled`: before the second `refreshAll()`.
- `currentUsageUsesSignedInKey`: before its `refreshAll()`.
- `usageFailureClearsOldFiguresAndOutlivesASnapshot`: before each `refreshUsage()` after the `apply`.
- `overlappingUsageRefreshesRunOnce`: before the `Task { await s.refreshUsage() }`.
- `switchWaitsOutAUsageRun`: before its `Task { await s.refreshUsage() }`.
- `usageUpdatedAtFollowsTheLastSuccess`: it builds its own fixed clock; change `fetched` into a `TestClock` passed to `makeState(r, now: { clock.now })`, keep the `#expect(s.usageUpdatedAt == clock.now)` after the `apply`, and add `clock.now += AppSettings.usageRefreshFloor` before `r.fail`.

`snapshotErrorWinsAndUsageSuccessKeepsIt` keeps passing but its last `refreshUsage()` no longer runs; add the same advance before it so the test still exercises the success path.

- [ ] **Step 7: Run the whole core suite**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path app` Expected: all pass. `applyEnablingUsageFetchesOnce` and `usageFailureDoesNotRetry` need no change: each makes one attempt.

- [ ] **Step 8: Docs**

`docs/claude-multipass.md` line 81, the Usage figures row: replace "on Refresh" with "on Refresh, at most once per 30 s". `.claude/rules/safety-and-terms.md`: the Keychain line's last sentence becomes "The menu bar app may call `usage --json` on a timer only when the user turned usage on, at most once per 5 minutes, and on the user's Refresh at most once per 30 seconds."; the "Usage polling" paragraph adds "A Refresh click runs it at most once per 30 seconds." `CLAUDE.md` `usage` rail: after "at an interval of at least 5 minutes, one `security` call per run" add ", and on Refresh at most once per 30 seconds". `CHANGELOG.md` under `## Unreleased` (create the heading above `## 0.5.2` if PR 35 has not merged): "The menu bar app runs `usage --json` for a Refresh click at most once per 30 seconds. Every click ran it, one Keychain read and one usage request per account each time."

- [ ] **Step 9: Format, gate, commit, push, open the PR**

```bash
pnpm format && pnpm check
```

```bash
git add -A && git commit -m "Floor the manual usage refresh at 30 seconds"
```

```bash
git push -u origin usage-refresh-floor && gh pr create --base main --fill
```

PR body: what changed, the two new tests and the clock helper, the measured cost of a click before (one Keychain read and N GETs per click, `.claude/rules/desktop-internals.md`, "Counting tool runs"), and the gate result.

---

### Task 2: Prune `backups/profile-*` to the newest ten (script)

**Files:**

- Modify: `bin/claude-multipass` (`profile_set_aside`; the header comment lines 87 to 89; `--help` lines 215 to 216, 245 to 248 and 283 to 284; `doctor`, the `logins=` glob)
- Test: `test/claude-multipass.sh` (after the `login-*` prune loop, before the comment "A store path with a space")
- Docs: `docs/claude-multipass.md` line 104, `CLAUDE.md` line 41, `.claude/rules/safety-and-terms.md` (the two `--force` rules), `CHANGELOG.md` under `## Unreleased`

**Interfaces:**

- Produces: `prune_profile_backups()` in `bin/claude-multipass`, no arguments, removes every `$backups/profile-*/` folder past the newest ten by the `YYYYMMDD-HHMMSS` stamp before the pid, and leaves a folder without that stamp alone. Called once at the end of `profile_set_aside`. `doctor` prints `ok: backups: N saved logins and M set-aside profiles in $backups`.

- [ ] **Step 1: Create the worktree and branch**

```bash
git worktree add -b prune-profile-backups .claude/worktrees/prune-profile-backups origin/main && cd .claude/worktrees/prune-profile-backups && pnpm install
```

- [ ] **Step 2: Write the failing self-check case**

Insert after the `login-*` prune loop (`for i in $(seq 1 12); do if [[ -d $b/login-... ]]`) and before the comment "A store path with a space". Facts the case rests on: `$p/beta` exists here (the second-name case renames `beta2` back to `beta`); six set-aside folders already sit in `$b` from the `remove home`, `remove doomed`, `save beta --force`, `save beta2 --force`, `save broken --force` and `remove broken` cases; `aa-two` passes `valid_name`; `remove` needs no Desktop quit and no new stub. The fixtures use the real stamp shape, `YYYYMMDD-HHMMSS`, with `%02d` so every stamp has six time digits. The `login-*` fixtures above use hyphenless names because `backup_login` sorts by name; do not copy them. The newest folder gets a hyphenated name that sorts before `old` so a sort by name would prune it.

```bash
# profile backups prune to the newest ten by stamp, not by name; a folder
# without a stamp is left alone
for i in $(seq 1 12); do
  mkdir -p "$b/profile-old-20200101-0000$(printf %02d "$i")-1"
done
mkdir -p "$b/profile-kept-by-hand"
cp -R "$p/beta" "$p/aa-two"
cda remove aa-two > /dev/null
check "profile backups pruned to ten" 10 "$(find "$b" -mindepth 1 -maxdepth 1 -type d -name 'profile-*' ! -name 'profile-kept-by-hand' | wc -l | tr -d ' ')"
check "the just-removed profile is kept" 1 "$(find "$b" -mindepth 1 -maxdepth 1 -type d -name 'profile-aa-two-*' | wc -l | tr -d ' ')"
check_true "the oldest set-aside profile is gone" test ! -e "$b/profile-old-20200101-000001-1"
check_true "the newest fixture stays" test -d "$b/profile-old-20200101-000012-1"
check_true "a folder without a stamp is left alone" test -d "$b/profile-kept-by-hand"
check "login backups untouched by the profile prune" 10 "$(find "$b" -mindepth 1 -maxdepth 1 -type d -name 'login-*' | wc -l | tr -d ' ')"
check_true "doctor counts both kinds" grep -q "ok: backups: 10 saved logins and 11 set-aside profiles in $b" <<< "$(cda doctor 2>&1)"
rm -r "$b/profile-kept-by-hand"
```

Before the prune there are 19 stamped folders (six earlier, twelve fixtures, `aa-two`); the prune keeps the seven real ones plus fixtures 10, 11 and 12. `doctor` counts every `profile-*/` folder, so it reports 11 with the hand-named one still present.

- [ ] **Step 3: Run the self-check to verify it fails**

Run: `bash test/claude-multipass.sh 2>&1 | grep -v '^ok'` Expected: `FAIL: profile backups pruned to ten` with 19.

- [ ] **Step 4: Implement `prune_profile_backups()` and call it**

In `bin/claude-multipass`, before `profile_set_aside`:

```bash
# profile-<name>-<stamp>-<pid> sorts by name, so the prune sorts on the stamp;
# the newest ten stay and a folder without a stamp is never touched. No
# Keychain item: the profile's went with the move.
prune_profile_backups() {
  local dir
  for dir in "$backups"/profile-*/; do
    [[ -d $dir && $dir =~ -([0-9]{8}-[0-9]{6})-[0-9]+/$ ]] || continue
    printf '%s\t%s\n' "${BASH_REMATCH[1]}" "$dir"
  done | sort -r | tail -n +11 | while IFS=$'\t' read -r _ dir; do rm -rf "$dir"; done
}
```

Call it as the last line of `profile_set_aside`. `sort -r` puts the newest first, `tail -n +11` is everything past ten, `read -r _ dir` splits on the tab only, so a store path with a space survives. The pipeline exits 0 with no match (an unmatched glob fails the `-d` test).

- [ ] **Step 5: `doctor` counts both kinds**

In `doctor`, beside `logins=("$backups"/login-*/)` and its `-d` guard, add `profiles=("$backups"/profile-*/)` with the same guard, and print `ok: backups: ${#logins[@]} saved logins and ${#profiles[@]} set-aside profiles in $backups`. The existing fresh-store assertion (`grep -q '^ok: backups: 0 saved logins'` in the self-check) matches the new line as a prefix.

- [ ] **Step 6: Run the self-check to verify it passes**

Run: `bash test/claude-multipass.sh 2>&1 | grep -v '^ok'; echo "rc=$?"` Expected: no `FAIL` line. The spaced-path case that follows still passes (it uses its own store, `$spaced`, and `add` there calls `backup_login`, not `profile_set_aside`).

- [ ] **Step 7: Docs**

`bin/claude-multipass` header lines 87 to 89: "plus any profile `save --force` replaced or moved aside as a second name for the same account, and any `remove` set aside, newest ten". `--help` lines 215 to 216: "(it is kept in the backups folder, newest ten)"; `remove` entry at lines 245 to 248: "moving its folder to the backups folder (the newest ten set-aside profiles are kept)"; Folders line 284: "(the last ten replaced logins and the last ten replaced or removed profiles)". `docs/claude-multipass.md` line 104: "Profiles that `remove` or a forced `save` set aside, newest ten". `CLAUDE.md` line 41: "(`profile-*`, newest ten)". `.claude/rules/safety-and-terms.md`: in both `--force` rules (lines 16 and 17, "moves the old profile into `backups/`" and "moves the other profile into `backups/`") append " (newest ten kept)" after `backups/`. `CHANGELOG.md` under `## Unreleased` (create the heading above `## 0.5.2` if PR 35 has not merged): "`remove` and `save --force` keep the newest ten set-aside profiles under `backups/profile-*`, as `backups/login-*` already keeps ten logins; `doctor` counts both. Set-aside profiles were never pruned."

- [ ] **Step 8: Format, gate, commit, push, open the PR**

```bash
pnpm format && pnpm check
```

```bash
git add -A && git commit -m "Prune set-aside profiles to the newest ten"
```

```bash
git push -u origin prune-profile-backups && gh pr create --base main --fill
```

PR body: what changed, why the sort is on the stamp, that the prune makes no Keychain call, the new case, and the gate result.
