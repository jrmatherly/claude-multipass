# Refresh floor and profile backup prune

Two design calls left by the 2026-10-28 audit, investigated on 2026-10-28 against `main` at `aa591e4` plus PR 35. This is the decision record the plan at `docs/superpowers/plans/2026-10-28-refresh-floor-and-profile-backup-prune.md` implements.

## 1. A floor on the menu bar app's manual usage refresh

### What the code does today

Four triggers end in `AppState.refreshUsage()` (`app/Sources/MultipassCore/AppState.swift`): the popover's Refresh button and the status item's right-click Refresh (both `refreshAll()`, snapshot then usage), `start()` at launch, `apply` when usage is turned on, and the usage timer every `max(usageIntervalMinutes, 5)` minutes. Opening the popover refreshes the snapshot only. The only guard is `isRefreshingUsage`, one run in flight at a time; a second call during a run is dropped, not queued. Nothing compares the time since the last run.

One `usage --json` run costs one `security` read of the Safe Storage key and one GET of the usage endpoint per saved profile, plus one for an unsaved live login (measured 2026-10-28, `.claude/rules/desktop-internals.md`, "Counting tool runs"). The 5-minute rule in `.claude/rules/safety-and-terms.md` covers the timer; a Refresh click runs `usage` at once, and two clicks nine seconds apart ran it twice (same measurement).

### Options

| Option | Cost per click | What the user loses | Code |
| --- | --- | --- | --- |
| A. Leave it | 1 Keychain read, N GETs, serialized by `isRefreshingUsage` | nothing | none |
| B. Floor in `refreshUsage()` keyed on the last attempt | 0 within the floor | figures up to the floor old after a click; the popover already shows "updated N ago" | about 8 lines, 2 tests and a test clock, six existing tests advance it |
| C. Floor in the two views | as B | as B, duplicated in `PopoverView` and `StatusItemController`, no injectable clock for tests | more, and untestable |
| D. Queue the click behind a run in flight | 1 extra run per burst | nothing | more state, not what the audit asked |

### Decision

Option B with a 30 second floor on attempts, success or failure. The stamp of the last attempt is set in `refreshUsage()`, and the check sits in `refreshAll()`, the path the popover and menu Refresh and launch take. The implementation review (2026-10-29) moved the check there from `refreshUsage()`: the timer (5 minutes at least) and the usage toggle (once, on enable) call `refreshUsage()` directly and can never land within 30 seconds of an attempt, so a check there only forced a reset on disable and a clock advance in five unrelated tests. Turning usage off and on fetches at once, as today. `start()` passes because nothing was attempted yet. The floor is a mash guard, not a rate limit the terms posture needs: the measured risk (eight `security` spawns a second crashed securityd, claude-swap issue 496) is already out of reach because runs are serialized. Thirty seconds keeps a deliberate second click cheap and makes a burst of clicks cost one run. A failed attempt counts, so a click after a failure within 30 seconds does not retry; `usageFailureDoesNotRetry` already pins that no automatic retry exists.

No UI change: the snapshot still refreshes on every click, and the usage block keeps showing when its figures were fetched.

### Constraints the change must keep

- The rule text in `.claude/rules/safety-and-terms.md` (the timer sentence on the Keychain line and the "Usage polling" paragraph) and the Refresh cadence table in `docs/claude-multipass.md` say what the manual path does now; both gain the floor.
- `usageUpdatedAt` keeps its meaning (when the shown figures were fetched, nil while there are none). The floor needs its own stamp, because a failed run clears `usageUpdatedAt`.
- The injected `now` closure is the clock; no test may sleep.

## 2. Pruning `backups/profile-*`

### What the code does today

`profile_set_aside` (`bin/claude-multipass`) moves a profile folder to `backups/profile-<name>-<timestamp>-<pid>` and deletes the profile's CLI Keychain item. Three callers: `save --force` over a profile that holds another account, `save --force` as a second name for a saved account, and `remove`. A set-aside folder holds the three encrypted Desktop login keys, the cookie files, `meta.json` and `cli.json` (identity only, no token). It is encrypted with this Mac's Safe Storage key and sits mode 0700 inside the 0700 store. Nothing in the tool reads, counts or prunes these folders; `doctor` counts `login-*` only. `backup_login` prunes `login-*` to the newest ten and deletes each pruned folder's Keychain item. The docs promise "the last ten replaced logins, plus replaced or removed profiles" with no retention for the profiles.

### Options

| Option | What stays | Risk | Code |
| --- | --- | --- | --- |
| A. Leave it | every set-aside profile, forever | a usable (per-Mac) Desktop login per removed profile accumulates with no cap; the only consumer is a hand restore | none |
| B. Newest ten, same rule as `login-*` | ten set-aside profiles | the eleventh-oldest hand restore is gone; a `remove` is a deliberate act and ten undo slots is plenty | about 10 lines, 1 case, 5 doc lines |
| C. Newest N per name | N per profile name | a name reused across accounts keeps old accounts' logins longer; harder to explain | more |
| D. Age-based (30 days) | anything newer than 30 days | a user who removes a profile and returns after a month finds nothing | needs `date -r` parsing, BSD only |

### Decision

Option B. `profile_set_aside` prunes `backups/profile-*` to the newest ten after each move, matching the `login-*` rule the docs already state. The prune touches no Keychain item (a set-aside folder has none), so it adds no `security` call and stays inside `save` and `remove`, where the folders are made. `doctor` counts both kinds.

The folder name sorts by profile name, not by age, so the prune sorts on the `YYYYMMDD-HHMMSS` stamp before the pid. The glob, not `ls`, is the source of names, as in `backup_login` (a store path with a space must never split; CHANGELOG 0.3.x records the `rm -rf` of a sibling that this fixed).

### Constraints the change must keep

- No `security` call outside `usage`, `save`, `add`, `switch`, `rename`, `remove` and the backup prune; `doctor` never calls it. The new prune calls none.
- The header comment of `bin/claude-multipass`, `--help` (the `save --force` sentence, the `remove` entry and the Folders list), `docs/claude-multipass.md` (the folder table), `CLAUDE.md` (the storage model line) and `.claude/rules/safety-and-terms.md` (the two `--force` rules) say "kept in the backups folder" with no cap; each gains "newest ten".
- A new case in `test/claude-multipass.sh`, beside the `login-*` prune case.
- bash 3.2: no `head -n -N`, `[[ =~ ]]` with `BASH_REMATCH` is available.

## Out of scope

- Any floor on the popover-open snapshot refresh or the 30 second snapshot timer (no Keychain, no network).
- Pruning by age, or a setting for either cap.
- Pruning `login-*` differently.
