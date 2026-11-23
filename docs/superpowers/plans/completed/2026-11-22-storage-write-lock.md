# Storage write lock implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** a `switch` reads and rewrites the Claude Code login item only while it holds the lock Claude Code itself takes for every write of that item, so a switch can no longer drop an MCP login saved during it, and a Claude Code save can no longer put the old account back.

**Architecture:** `cli_restore` takes a fourth lock dir, `$cli_home/.storage-write.lock`, with the existing `cli_lock` helper. Under it the restore reads the live item again, then writes the item and `~/.claude.json`, then releases that one lock. The three locks `cli_lock_all` takes stay as they are and keep their order.

**Tech Stack:** bash 3.2, `jq`, the fixture self-check (`test/claude-multipass.sh`), Markdown docs.

**Spec:** this plan carries its own spec in the Findings and Decisions sections below.

**Reviewed:** 2026-11-22, by the author against the script and fixture and by one independent reviewer. The review changed Findings 7 and 10, Decisions 3 to 7, the code in Step 3 and cases D, E and G.

## Findings

Labels: **M** measured on this Mac on 2026-11-22 by reading the Claude Code 2.1.330 binary (`~/.local/share/claude/versions/2.1.330`), **S** read in this repo at `cb15140`, **I** inferred, **R** reported by a third party.

1. **M.** Claude Code's credential store has one `mutate` path. It runs read, transform and `update` inside a lock on `<storage dir>/.storage-write`, which the lock library turns into the directory `.storage-write.lock`. Options: `realpath:false`, 10 retries from 100 ms to 1000 ms (about 7.5 s in all), `stale:15000`, and an `onCompromised` handler that only logs a warning. Function `mRt`, and `mutate(...)` on all three store objects calls it.
2. **M.** MCP login saves call that `mutate` directly, with no refresh lock. Three call sites that rewrite `mcpOAuth` were read.
3. **M.** The token refresh takes `.oauth_refresh.lock` (`stale:60000`, `update:5000`), then `<realpath of the dir>.lock`. It retries 5 times, 1 to 2 s apart. It takes a lock over only when its mtime sat still for 7.5 s and an owner record proves the holder gone. With no owner record it takes nothing over.
4. **M.** `.storage-write.lock` is also in 2.1.328 and 2.1.329. **R:** an issue mirror dates the storage lock to about 2.1.136.
5. **S.** `cli_restore` (`bin/claude-multipass:949`) reads the live item (`:960`), writes a backup item, then writes the item (`:1001`), and on a failed `~/.claude.json` write puts the old item back (`:1011`). Those are the only writes of the `Claude Code-credentials` item in the script. It holds `.oauth_refresh.lock`, `~/.claude.lock` and `~/.claude.json.lock`, not `.storage-write.lock`.
6. **I.** So a Claude Code `mutate` between the read and `:1001` is lost, and one that read before `:1001` and writes after it puts the old `claudeAiOauth` back while `~/.claude.json` names the new account. Neither was reproduced.
7. **S.** `cli_restore` has two callers. `profile_restore` (`:1296`) calls it after Desktop's `config.json` is merged, so a busy lock there cannot fail the switch cleanly. The "already signed in" branch of `switch` (`:2121`) calls it too, to repair the CLI part, so running the same `switch` again after a skipped restore retries it. Every skip in `cli_restore` warns `...; switched Desktop only` and returns 0.
8. **S.** `cli_capture` (`:720`, the `save` path and the re-save of the profile being left) only reads the live item and writes the tool's own item. It needs no storage lock.
9. **S.** The tool moves no CLI login under `CLAUDE_CONFIG_DIR` or a non-empty `CLAUDE_SECURESTORAGE_CONFIG_DIR` (`cli_blocker`, `:692`), so the storage dir is always `$cli_home`.
10. **S.** `cli_live_read` (`:551`) caches the item for the run: `[[ -z $cli_live_rc ]] || return "$cli_live_rc"`. In a switch the re-save reads it first, so the restore's `cli_live_read` at `:960` makes no Keychain call. A lock taken around `:960` to `:1001` alone would therefore guard a value read before the lock, and close nothing.
11. **S.** `cli_lock <dir> <stale>` sweeps a dir older than `<stale>` seconds once, on entry, then tries `mkdir` 5 times with `sleep 1` between (`:763-790`). One call waits about 5 s.

## Decisions

1. The lock is `$cli_home/.storage-write.lock`, staleness 15 s, the value Claude Code uses.
2. It is taken inside the three existing locks and released before them. Claude Code nests it the same way inside its refresh lock.
3. It is held only around the restore's own read and writes, never for the whole run. The work under it is one Keychain read, the backup write, the item write and the `~/.claude.json` write. Claude Code waits about 7.5 s for this lock, so a hold longer than that (a Keychain prompt left on screen) fails a concurrent MCP save in Claude Code. That risk is accepted; today the same save is silently lost.
4. Under the lock the restore reads the live item again (clear `cli_live_rc` first). This costs one more `security` read per switch than today. No extra Keychain prompt is expected, because `security` is the same reader in both calls (I).
5. The wait is one `cli_lock` call, about 5 s. Claude Code's own holds are far shorter. A longer wait would also keep the other three locks from Claude Code for as long.
6. A busy lock warns `Claude Code holds <dir>; switched Desktop only (run claude-multipass switch <name> again)` and returns 0. It is not a refusal, `--force` does not apply, and the exit code stays 0. The same `switch` run again repairs the CLI part (Finding 7). A lock left by a holder that died clears itself: it is swept once it is older than 15 s, so a second or third run gets through.
7. Sweeping follows Claude Code's own rule. A live Claude Code touches its lock about every 7.5 s (the library default for `stale:15000`, not read in the binary), so only a holder that went quiet for 15 s is swept, and it then only logs a warning (Finding 1). A holder suspended that long and resumed can still write. That case is accepted, as it is for the other three locks.
8. No owner check on release, and no pre-quit probe of the locks. Both were considered on 2026-11-22 and left out.

## Global Constraints

- Code never lands on `main`: work in a new worktree and branch, run `pnpm install` there, open a PR against `main`. Merging is Jason's call.
- The script runs on `/bin/bash` 3.2 under `set -euo pipefail`. No here-string or heredoc in `bin/claude-multipass` beyond the one `--help` heredoc.
- `pnpm check` is the gate and the commit hook runs it. `test/check.sh` prints nothing on success.
- A behaviour change edits `docs/` in the same commit and adds one line under `## Unreleased` in `CHANGELOG.md`.
- Prose: no em-dashes, short declarative sentences, sentence-case headings, straight quotes.
- Never run `switch`, `save` or `add` against the real Desktop folder. The fixture is the only place these run.

## Review Focus

1. The restore must read the item again under the lock, not reuse the re-save's read. Case A asserts a `find-generic-password held` line.
2. A live holder keeps `.storage-write.lock` for the whole wait: the switch exits 0, warns with the remedy, and leaves the CLI item and `oauthAccount` as they were. Case C.
3. The remedy works: the same `switch` run again, with the lock gone, moves the CLI login. Case G.
4. A lock left by a dead holder (older than 15 s) is removed and the CLI login moves. Case B.
5. A lock freed during the retries does not cost the CLI login. Case F.

---

### Task 1: Take the storage lock around the item read and write

**Files:**

- Modify: `bin/claude-multipass:547-549` (the comment on the shared read), `:756-812` (the lock comment, a new `cli_unlock_last`), `:946-1022` (`cli_restore`)
- Modify: `test/claude-multipass.sh`: the `security` stub's `run()` (near `:92`); the `claude` stub's lock list at `:363` (in `#@ setup`); in `#@ switch`, the comment at `:385`, the lock lists at `:423-426`, one assertion in the case at `:544`, and new cases after the "lock freed during the retries" case that ends near `:664`
- Modify: `docs/claude-multipass.md:58`, `:154`, `:159`, `:209`, `CHANGELOG.md`

**Interfaces:**

- Consumes: `cli_lock <dir> <stale-seconds>` (returns 1 and sets `held_lock` when the dir stays held), the parallel arrays `cli_locks` and `cli_touchers`, `cli_unlock`, `cli_live_rc`.
- Produces: `cli_unlock_last` (no arguments: kills the newest toucher, `rmdir`s the newest lock, drops both array entries; a no-op on empty arrays). `cli_swap <name>` (the body `cli_restore` has today from `cli_live_read` through `dbg "cli restore wrote ..."`; always returns 0; sets the global `cli_swapped=1` only on the path that wrote the item and `~/.claude.json`). Global `cli_swapped=''` declared beside `cli_skip`.

- [ ] **Step 1: Write the failing tests**

In the `security` stub, inside `run()` after the argument loop, record the lock at each access of the CLI item. `${kc%/*}` is the fixture's `$tmp`, and `security -i` lines reach `run()` too:

```bash
[[ $s != 'Claude Code-credentials' ]] || { [[ -d ${kc%/*}/claude-home/.storage-write.lock ]] && echo "$cmd held" || echo "$cmd free"; } >> "${kc%/*}/storage-lock-log"
```

Add `"$tmp"/claude-home/.storage-write.lock` to the `ls -d` lists at `:363` and `:423`, and to the `test ! -e` chain at `:426`.

In the existing refused-write case at `:544`, add after its last check: `check_true "and the storage lock is released" test ! -e "$tmp/claude-home/.storage-write.lock"`. This is a guard: it passes before the change too.

New cases, in `#@ switch`, right after the "lock freed during the retries" case, which leaves Desktop and the CLI on `alpha` and `beta` with a saved CLI login:

```bash
sw="$tmp/claude-home/.storage-write.lock"
# A: the restore reads the item again and writes it, both under the storage lock
: > "$tmp/storage-lock-log"
check "a switch moves the CLI login" 0 "$(exit_code cda switch beta --no-relaunch)"
# The re-save of the profile being left reads the item first, with no storage lock (Finding 8).
check "no write of the CLI item ran outside the storage lock" 0 "$(grep -c -E '^(add|delete)-generic-password free$' "$tmp/storage-lock-log" || true)"
check_true "the item was written under it" grep -q '^add-generic-password held$' "$tmp/storage-lock-log"
check_true "and read again under it first" grep -q '^find-generic-password held$' "$tmp/storage-lock-log"
check_true "and the storage lock is released" test ! -e "$sw"
cda switch alpha --no-relaunch > /dev/null 2>&1
# B: a stale one is swept
mkdir "$sw" && touch -t 202001010000 "$sw"
check "a stale storage lock does not block the switch" 0 "$(exit_code cda switch beta --no-relaunch)"
check "and the CLI login moved" bbbbbbbb-2222 "$(jq -r .oauthAccount.accountUuid "$tmp/claude.json")"
check_true "and it is removed" test ! -e "$sw"
cda switch alpha --no-relaunch > /dev/null 2>&1
# E: save takes no storage lock (a guard: it passes before the change too)
mkdir "$sw"
err=$(cda save alpha --no-relaunch 2>&1 > /dev/null) || true
check "save does not wait on the storage lock" 0 "$(grep -c 'Claude Code holds' <<< "$err")"
check "and still captures the CLI login" "$(kc_get "Claude Code-credentials" "$USER" | jq -r .claudeAiOauth.accessToken)" "$(kc_get claude-multipass alpha | jq -r .claudeAiOauth.accessToken)"
# C: a fresh one, held throughout, moves Desktop only
live=$(kc_get "Claude Code-credentials" "$USER" | jq -r .claudeAiOauth.accessToken)
st=0
err=$(cda switch beta --no-relaunch 2>&1 > /dev/null) || st=$?
check "a held storage lock does not fail the switch" 0 "$st"
check_true "and says why and what to run" grep -qF "Claude Code holds $sw; switched Desktop only (run claude-multipass switch beta again)" <<< "$err"
check "and Desktop moved" bbbbbbbb-2222 "$(jq -r .lastKnownAccountUuid "$d/config.json")"
check "and oauthAccount did not" aaaaaaaa-1111 "$(jq -r .oauthAccount.accountUuid "$tmp/claude.json")"
check "and the CLI item did not" "$live" "$(kc_get "Claude Code-credentials" "$USER" | jq -r .claudeAiOauth.accessToken)"
check_true "and the holder's lock is left alone" test -d "$sw"
check_true "and the tool's own locks are released" test ! -e "$tmp/claude-home/.oauth_refresh.lock" -a ! -e "$tmp/claude-home.lock" -a ! -e "$tmp/claude.json.lock"
rmdir "$sw"
# G: the same switch again repairs the CLI part
check "the same switch again exits 0" 0 "$(exit_code cda switch beta --no-relaunch)"
check "and moves the CLI login" bbbbbbbb-2222 "$(jq -r .oauthAccount.accountUuid "$tmp/claude.json")"
cda switch alpha --no-relaunch > /dev/null 2>&1
```

- **F:** copy the "lock freed during the retries" case with `$sw` as the lock (its `sleep 1` stub runs `rmdir "$sw"`; `mkdir "$sw"` before the switch). Assert exit 0 and that `oauthAccount` is `bbbbbbbb-2222`. End with `fast_sleep` and `cda switch alpha --no-relaunch > /dev/null 2>&1`, as that case does.

The block must end with Desktop and the CLI on `alpha`, which is what the next case (the SIGKILL toucher case) starts from.

- [ ] **Step 2: Run the section to see it fail**

Run: `bash test/claude-multipass.sh switch` Expected: exit 1, `FAIL: no write of the CLI item ran outside the storage lock`.

- [ ] **Step 3: Implement**

- `cli_unlock_last` beside `cli_unlock`, per the Interfaces block. bash 3.2 has no negative index: compute the last index from `${#cli_locks[@]}`.
- Move the body of `cli_restore` from `cli_live_read` to `dbg "cli restore wrote ..."` into `cli_swap`, unchanged except that the write path ends with `cli_swapped=1`. `cli_swap` starts with `local name=$1 dir="$store/$1" saved live merged rc=0`: under `set -u` an undeclared `rc` exits the script.
- `cli_restore` starts with `local name=$1 dir="$store/$1" why`, keeps its two early checks (`cli.json` present, `cli_blocker`), then:

```bash
cli_swapped=''
cli_lock "$cli_home/.storage-write.lock" 15 || {
  warning "Claude Code holds $held_lock; switched Desktop only (run claude-multipass switch $name again)"
  return 0
}
# The re-save read the item before this lock was held.
cli_live_rc=''
cli_swap "$name"
cli_unlock_last
[[ -n $cli_swapped ]] || return 0
```

followed by the existing `cli_unlock` and `cli_verify` lines.

- Rewrite the comment at `:547-549`: the re-save and the restore no longer share the read. The restore reads again under the storage lock.
- Rewrite the comment above `cli_locks=()`: four lock dirs, the staleness of each (60, 60, 10 and 15 s), that the storage lock is the one Claude Code holds for every write of its credential item (2.1.330, `mutate`), and that it is held only around the restore's read and writes because Claude Code waits about 7.5 s for it.
- Replace the comment at `:1019` ("claude-swap reports ... (unverified here)") with the measured fact: Claude Code's refresh takes `.oauth_refresh.lock` and then `~/.claude.lock` (2.1.330), so both are released before `claude` is asked.
- In the fixture, correct the comment at `:385`: the restore now reads the item a second time, so that case's 2 s hold happens twice.

- [ ] **Step 4: Run the section, then the gate**

Run: `bash test/claude-multipass.sh switch` Expected: exit 0, no output naming a failure.

Run: `pnpm check; echo "exit $?"` Expected: `exit 0`. The whole fixture matters here: the Hindsight and debug sections count Keychain accesses (`test/claude-multipass.sh:1921`), and the restore now makes one more. If a count there changes, confirm the extra access is the restore's read under the lock before changing the expected number.

- [ ] **Step 5: Docs in the same commit**

- `docs/claude-multipass.md:58`: the item is read and rewritten under Claude Code's own storage lock as well as its three lock dirs.
- `docs/claude-multipass.md:154`: correct the wait. A switch tries each lock 5 times, 1 s apart. 60, 60 and 10 s are how old a lock must be before the tool removes it as abandoned.
- `docs/claude-multipass.md:159`: a new bullet after it, not a new reason in its list, because the remedy differs. `Claude Code holds .../.storage-write.lock; switched Desktop only`: Claude Code was writing its login item for the whole 5 s wait. Run the same `switch` again; it sees Desktop already on that account and moves the terminal login.
- `docs/claude-multipass.md:209`: name the fourth lock, and say that a busy storage lock moves Desktop only, where a busy one of the other three fails the switch before Desktop's config moves.
- `CHANGELOG.md`, under `## Unreleased`: one line, "A switch now reads and rewrites the terminal login under the lock Claude Code takes for its own writes, so a login for an MCP server saved during a switch is no longer lost."

- [ ] **Step 6: Commit**

```bash
git add bin/claude-multipass test/claude-multipass.sh docs/claude-multipass.md CHANGELOG.md
git commit -m "Hold Claude Code's storage lock while a switch rewrites the CLI login"
```

### Task 2: Record the measured lock facts

**Files:**

- Modify: `.claude/rules/desktop-internals.md` (CLI credentials section, Open tests item 13)
- Modify: `.claude/rules/safety-and-terms.md` (the "CLI login moves only with proof" bullet)
- Modify: `.claude/rules/testing.md` (the stubs bullet)

**Interfaces:**

- Consumes: Findings 1 to 4 above, and the names Task 1 produced.
- Produces: nothing later tasks use.

- [ ] **Step 1: Edit the three files**

- `desktop-internals.md`, CLI credentials: add Findings 1 to 3 as M facts with "Claude Code 2.1.330 binary, read 2026-11-22", and Finding 4 with its R label. Open tests item 13: replace "whether its token refresh waits on a held `.oauth_refresh.lock` is still open" with the answer from Finding 3, labelled M in source, not run.
- `safety-and-terms.md`: in that bullet, after "`~/.claude.json` is written only while the CLI's three lock dirs are held", add that the live CLI item is read and written only while `.storage-write.lock` is held too, and that a busy storage lock moves Desktop only.
- `testing.md`: the `security` stub appends `<command> held` or `<command> free` to `$tmp/storage-lock-log` for each access of the CLI item.

- [ ] **Step 2: Check formatting**

Run: `node_modules/.bin/prettier --check .claude/rules/desktop-internals.md .claude/rules/safety-and-terms.md .claude/rules/testing.md` Expected: `All matched files use Prettier code style!`

- [ ] **Step 3: Commit, push, open the PR**

```bash
git add .claude/rules
git commit -m "Record Claude Code's storage and refresh lock behaviour"
```

Push the branch and open the PR against `main`. Its `## Why` opens with the Goal line of this plan. Then move this file to `docs/superpowers/plans/completed/` in the same PR.
