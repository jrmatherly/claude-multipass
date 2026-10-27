# CLI account hardening implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the validated gaps in claude-multipass's handling of the Claude Code CLI login: a missing `CLAUDE_SECURESTORAGE_CONFIG_DIR` blocker, lock dirs that go stale while held, a sibling-key merge that lets an account-scoped key cross accounts, and documented Claude Code facts the 2.1.310 binary contradicts.

**Architecture:** Every change is a few lines in `bin/claude-multipass` (bash 3.2) with a case in `test/claude-multipass.sh` and the matching line in `docs/` or `README.md`. One task is docs only. Each code task is its own branch, worktree and PR against `main` (CLAUDE.md); the docs task commits straight to `main`.

**Tech Stack:** bash 3.2, `jq`, `/usr/bin/security` (stubbed in the self-check), `pnpm check` as the gate.

**Spec:** `/Users/jason/dev/claude-multipass/private/claude-swap-rea-study.md`. It is git-ignored, so a fresh worktree does not have it: read it from the main checkout by that absolute path. Its ranked table gives each gap's evidence; the task numbers below follow its PR plan. The measured facts it rests on are cited there by byte offset into `~/.local/share/claude/versions/2.1.310`.

## Global constraints

- Code changes go on a branch in a worktree and land through a PR after `check.yml` is green; Markdown-only commits may go straight to `main` (CLAUDE.md, Custom Notes).
- `pnpm check` must pass before every commit (the commit-gate hook runs it): `bash -n`, `shellcheck --severity=warning`, `prettier --check`, the self-check, the hook self-checks, `swift test`.
- Every new refusal or behaviour gets a case in `test/claude-multipass.sh`, and a behaviour change edits `README.md` or `docs/` in the same commit (`.claude/rules/testing.md`, CLAUDE.md Conventions).
- The Keychain is touched through `security` on PATH only, inside `save`, `add`, `switch`, `rename`, `remove` and the backup prune; `list`, `show`, `current` and `doctor` never call it; no token on argv except the oversize `security add-generic-password -X <hex>` write (`.claude/rules/safety-and-terms.md`).
- `~/.claude.json` is written only while the three lock dirs are held and only `oauthAccount` changes; the Desktop switch always completes when the CLI part cannot (`.claude/rules/safety-and-terms.md`).
- Prose in docs, comments and help: no em-dashes, short declarative sentences, sentence-case headings, straight quotes. Commit subjects short, imperative, sentence case, no prefix.
- Shell style: `set -euo pipefail`, inline helpers, comments explain the why only. bash 3.2: no associative arrays, build strings with escaped quotes in a variable before `$(...)`. BSD `stat -f %m`, `touch -c`.

## Review focus

1. `CLAUDE_SECURESTORAGE_CONFIG_DIR` defined but empty selects the default Keychain item (`Jj()` in the binary), so the tool must proceed, not refuse. Task 2 adds a case for the empty value.
2. A keep-alive loop that outlives its lock would `touch` a missing path and create a regular file where Claude Code expects a directory, blocking its `mkdir` for good. Task 3's loop exits on its own once the dir is gone and uses `touch -c` for the race between that check and the touch; the test asserts the lock path stays absent 4 s after the switch returns.
3. A background loop that inherits the tool's stdout and stderr keeps the menu bar app's and Raycast's pipes open until it exits (measured: 3 s for an orphaned `sleep 3`; `app/Sources/MultipassCore/CLI.swift` drains both pipes to EOF). Task 3 redirects the loop's three fds to `/dev/null` and kills it in `cli_unlock`, which the `EXIT` trap also runs, so a `fail` after the locks were taken stops it too.
4. A live item with no shared keys at all must merge to the saved account part alone, with no `null` entries. Task 4's `with_entries(select(.value != null))` covers it and the existing absent-item case (rc 44) exercises the `live=''` branch.
5. An unknown sibling key now travels with the profile, so a future shared key would be stale after a switch until Claude Code re-prompts for it. That is the chosen trade (claude-swap's too); Task 4 documents it and asserts the key moves.

---

### Task 1: Correct the Claude Code facts in the rules (docs only, on `main`)

**Files:**

- Modify: `.claude/rules/desktop-internals.md:37-38,57-58`

**Interfaces:**

- Consumes: the measured facts in `private/claude-swap-rea-study.md`, rows 5 and 1, and its "Measurements on this Mac".
- Produces: the sentences later tasks' comments cite (the 2 s timeout, the 30 s cache, the owner record).

- [ ] **Step 1: Edit `.claude/rules/desktop-internals.md` line 37**

Replace "caches the read about 30 s (R)" with "caches the read 30 s (M in the 2.1.310 binary, `sKt=30000`); its storage reads, writes and deletes give `security` 2 s, and only the startup prefetch 10 s, so a Keychain prompt open past 2 s reads as signed out for that process (M)". After the lock sentence add: "Since 2.1.310 the CLI also writes `.oauth_refresh.lock.owner` (pid, process start, lock birthtime) and takes over a dead holder's locks early only when that record exists; a record-less dir, the tool's, is judged by mtime staleness alone (M). Its config writer retries `~/.claude.json.lock` at 200, 400, 800, 1600, 3200 and 4000 ms, then takes over a dir older than 10 s; its token refresh tries the credential locks 5 times, 1 to 2 s apart, then fails that attempt (M). Config writes diff against the last read and write only changed keys, and refuse when the re-read file lacks auth the cache has (GH #3117) (M); that a running `claude` therefore leaves a spliced `oauthAccount` alone is inferred, not reproduced (U)."

- [ ] **Step 2: Edit line 38**

After "exit 44 means absent (M)" add ", exit 36 with an item the CLI knows exists means the keychain is locked and the failure transient (M)". After the shared-keys sentence add: "`trustedDeviceEnrolledAfterRefusalAtMs` is written beside `trustedDeviceToken` and is account-scoped (M). `CLAUDE_SECURESTORAGE_CONFIG_DIR`, when defined and non-empty, selects the suffixed item and the `.credentials.json` path instead of `CLAUDE_CONFIG_DIR`; defined and empty selects the default item; Desktop-spawned child sessions carry it (M, names from `ps -E`)."

- [ ] **Step 3: Edit open test 12 (line 57)**

Append: "Measured again 2026-10-26 21:30 EDT: the four `claude-multipass` items are still `apple:`, the CLI item `apple-tool:`; no switch has run since v0.3.3, so the first restore of each profile will prompt once."

- [ ] **Step 4: Format and check**

Run: `node_modules/.bin/prettier --write .claude/rules/desktop-internals.md && pnpm check` Expected: `prettier` rewraps nothing unexpected; `pnpm check` ends with the Swift tests passing.

- [ ] **Step 5: Commit on `main` and push**

```bash
git add .claude/rules/desktop-internals.md
git commit -m "Record the 2.1.310 Keychain timeouts, lock owner record and securestorage variable"
git push
```

---

### Task 2: Refuse the CLI part under `CLAUDE_SECURESTORAGE_CONFIG_DIR`

**Files:**

- Modify: `bin/claude-multipass:258` (help), `:385-389` (`cli_blocker`), `:888` (`doctor_report`)
- Modify: `docs/claude-multipass.md:47,110,121`, `CHANGELOG.md` (new "Unreleased" section at the top)
- Test: `test/claude-multipass.sh` beside lines 187, 372-375 and 699

**Interfaces:**

- Consumes: `cli_blocker` prints one reason line per blocker; `cli_capture` and `cli_restore` print it as `warning "<name>: <why>; saved the Desktop login only"` and `warning "<why>; switched Desktop only"`.
- Produces: the exact reason string `CLAUDE_SECURESTORAGE_CONFIG_DIR is set; the CLI login is not saved or switched`, and the `doctor` line `warn: CLAUDE_SECURESTORAGE_CONFIG_DIR is set; the CLI login is not saved or switched`.

- [ ] **Step 1: Write the failing cases**

After line 187:

```bash
check_true "save with CLAUDE_SECURESTORAGE_CONFIG_DIR skips the CLI login" grep -q 'CLAUDE_SECURESTORAGE_CONFIG_DIR is set; the CLI login is not saved or switched' <<< "$(CLAUDE_SECURESTORAGE_CONFIG_DIR=/x cda save alpha --no-relaunch 2>&1 > /dev/null)"
check "an empty CLAUDE_SECURESTORAGE_CONFIG_DIR does not block the save" 0 "$(CLAUDE_SECURESTORAGE_CONFIG_DIR= exit_code cda save alpha --no-relaunch)"
```

After line 375 (the `CLAUDE_CONFIG_DIR` switch pair), the same two lines for `switch beta` and `switch alpha`, asserting `jq -r .oauthAccount.accountUuid "$tmp/claude.json"` is unchanged after the blocked switch.

After line 699:

```bash
check_true "doctor warns on CLAUDE_SECURESTORAGE_CONFIG_DIR" grep -q '^warn: CLAUDE_SECURESTORAGE_CONFIG_DIR is set; the CLI login is not saved or switched' <<< "$(CLAUDE_SECURESTORAGE_CONFIG_DIR=/x cda doctor)"
```

- [ ] **Step 2: Run the self-check to see them fail**

Run: `bash test/claude-multipass.sh` Expected: exits 1 at "save with CLAUDE_SECURESTORAGE_CONFIG_DIR skips the CLI login".

- [ ] **Step 3: Add the blocker**

In `cli_blocker` (line 386), add one line after the `CLAUDE_CONFIG_DIR` check: `[[ -z ${CLAUDE_SECURESTORAGE_CONFIG_DIR:-} ]] || echo "CLAUDE_SECURESTORAGE_CONFIG_DIR is set; the CLI login is not saved or switched"`. `${VAR:-}` treats defined-and-empty as unset, which is what the CLI does with it. In `doctor_report` (line 888) add the matching `warn:` line. Comment, one line: the variable moves the CLI's item to a suffixed name the tool does not know (2.1.310, measured).

- [ ] **Step 4: Run the self-check to see them pass**

Run: `bash test/claude-multipass.sh` Expected: every `ok:` line, exit 0.

- [ ] **Step 5: Mirror the docs**

`bin/claude-multipass:258`: "whether CLAUDE_CONFIG_DIR is set" becomes "whether CLAUDE_CONFIG_DIR or CLAUDE_SECURESTORAGE_CONFIG_DIR is set". `docs/claude-multipass.md:47,110,121`: add `CLAUDE_SECURESTORAGE_CONFIG_DIR` beside each `CLAUDE_CONFIG_DIR`. `CHANGELOG.md`: a new `## Unreleased` section with one bullet: "`save` and `switch` leave the CLI login alone, with a warning, when `CLAUDE_SECURESTORAGE_CONFIG_DIR` is set: Claude Code 2.1.310 keeps its item under a suffixed name then. `doctor` warns about it."

- [ ] **Step 6: Gate and commit**

Run: `pnpm check` Expected: passes.

```bash
git add bin/claude-multipass test/claude-multipass.sh docs/claude-multipass.md CHANGELOG.md
git commit -m "Skip the CLI login under CLAUDE_SECURESTORAGE_CONFIG_DIR"
git push -u origin HEAD
gh pr create --fill
```

---

### Task 3: Keep the CLI lock dirs fresh while held

**Files:**

- Modify: `bin/claude-multipass:429-467` (`cli_lock`, `cli_unlock`, `cli_running_warning`)
- Modify: `docs/claude-multipass.md:120`, `CHANGELOG.md` (Unreleased)
- Test: `test/claude-multipass.sh` (the `security` stub's `find-generic-password` branch, the switch case near line 259, the held-lock case near line 440)

**Interfaces:**

- Consumes: `cli_lock <dir> <stale>` takes one dir with `mkdir` and appends it to `cli_locks`; `cli_unlock` runs from the `EXIT` trap and `rmdir`s each.
- Produces: a parallel array `cli_touchers` of background pids, one per held dir, stopped by `cli_unlock` before the `rmdir`.

- [ ] **Step 1: Write the failing cases**

In the `security` stub, in the `find-generic-password` branch (`test/claude-multipass.sh:57-64`, beside the `SECURITY_FAIL_FIND` check, for the `Claude Code-credentials` service only): when `${SECURITY_HOLD:-}` is set, write `stat -f %m "$SECURITY_HOLD"` to `$tmp/lock-mtime-before`, `sleep 4`, write it again to `$tmp/lock-mtime-after`, then print the value as before. Then in the switch case, before the `cda switch beta` at line 220, `export SECURITY_HOLD=$tmp/claude.json.lock` (exported, so the stub sees it; the CLI item is read once per run, so the switch waits 4 s once), and after line 259 add:

```bash
check_true "the config lock is touched while held" test "$(cat "$tmp/lock-mtime-after")" -gt "$(cat "$tmp/lock-mtime-before")"
sleep 4
check_true "no toucher outlives the switch" test ! -e "$tmp/claude.json.lock" -a ! -e "$tmp/claude-home/.oauth_refresh.lock" -a ! -e "$tmp/claude-home.lock"
unset SECURITY_HOLD
```

In the held-lock failure case (after line 443's `rmdir`), add `sleep 4` and the same "no toucher outlives" assertion for the two dirs the tool took before it failed. Both assertions prove no file was left at a lock path; a loop that merely lingers is bounded by its own `-d` check (step 3) and is not observable from the fixture without a process listing, which `pgrep` being stubbed rules out.

- [ ] **Step 2: Run the self-check to see them fail**

Run: `bash test/claude-multipass.sh` Expected: exits 1 at "the config lock is touched while held" (both mtimes equal).

- [ ] **Step 3: Implement the keep-alive**

In `cli_lock`, after the successful `mkdir`:

```bash
(while sleep 3; do
  [[ -d $dir ]] || exit
  touch -c "$dir" 2> /dev/null || exit
done) > /dev/null 2>&1 < /dev/null &
cli_touchers+=($!)
```

Declare `cli_touchers=()` beside `cli_locks=()`. In `cli_unlock`, before the `rmdir` loop: `for pid in ${cli_touchers[@]+"${cli_touchers[@]}"}; do kill "$pid" 2> /dev/null || true; done; cli_touchers=()`. Comments, one line each: Claude Code treats `~/.claude.json.lock` as stale after 10 s and the credential locks after 60 s, and touches its own every 5 s; the loop ends itself when the dir is gone and `-c` covers the race, so a lingering loop never leaves a file where the CLI expects a dir; the fds go to `/dev/null` because the menu bar app and Raycast drain the tool's pipes to EOF and an inherited fd would hold them until the next `sleep` ends (measured 3 s). Verified on `/bin/bash` 3.2 by the probe at `/private/tmp/claude-501/-Users-jason-dev-claude-multipass/a94b4f3f-7744-46ba-86ed-a29162c36052/scratchpad/toucher-probe.sh`: the mtime moves, the loop is gone 3 s after `rmdir` without a kill, no file is left, and the subshell does not run the parent's `EXIT` trap.

- [ ] **Step 4: Extend the running-CLI warning**

`cli_running_warning`: append to the message "; it also serves its cached login for up to 30 s after a switch".

- [ ] **Step 5: Run the self-check to see them pass**

Run: `bash test/claude-multipass.sh` Expected: exit 0. The switch case now takes about 8 s longer.

- [ ] **Step 6: Mirror the docs**

`docs/claude-multipass.md:120`: after "a busy CLI fails the switch before Desktop's config moves" add ", and the dirs are touched every 3 s while held so the CLI never deems them stale". `CHANGELOG.md` Unreleased: "`switch` and `save` keep the CLI's lock dirs fresh while they hold them (Claude Code treats `~/.claude.json.lock` as stale after 10 s), and the running-CLI warning mentions the CLI's 30 s login cache."

- [ ] **Step 7: Gate and commit**

Run: `pnpm check` Expected: passes.

```bash
git add bin/claude-multipass test/claude-multipass.sh docs/claude-multipass.md CHANGELOG.md
git commit -m "Touch the CLI lock dirs while they are held"
git push -u origin HEAD
gh pr create --fill
```

---

### Task 4: Keep only the shared keys from the live CLI item

**Files:**

- Modify: `bin/claude-multipass:391-393` (`cli_account_part`), `:544` (the restore merge)
- Modify: `docs/claude-multipass.md:121`, `CHANGELOG.md` (Unreleased)
- Test: `test/claude-multipass.sh:156,164,251,315`

**Interfaces:**

- Consumes: `cli_account_part` (stdin JSON to stdout JSON) feeds `cli_capture` and `cli_backup`; the merge at line 544 builds `merged` from `$live` and `$saved`.
- Produces: the shared-key list, in one place: `mcpOAuth`, `mcpOAuthClientConfig`, `mcpXaaIdp`, `mcpXaaIdpConfig`, `pluginSecrets` (measured shared in `.claude/rules/desktop-internals.md:38`).

- [ ] **Step 1: Write the failing cases**

Line 156: append `"trustedDeviceEnrolledAfterRefusalAtMs":5` as the last key of `live_item`. Line 164: the expected profile item gains the same key in the same position (`jq` keeps input order, so the expected string is the live item minus `mcpOAuth`). After line 251:

```bash
check "switch drops the previous account's enrolment stamp" null "$(kc_get "Claude Code-credentials" "$USER" | jq -r .trustedDeviceEnrolledAfterRefusalAtMs)"
```

Line 315: the expected expression becomes `'{mcpOAuth, mcpOAuthClientConfig, mcpXaaIdp, mcpXaaIdpConfig, pluginSecrets} | with_entries(select(.value != null)) + $s'`.

- [ ] **Step 2: Run the self-check to see them fail**

Run: `bash test/claude-multipass.sh` Expected: exits 1 at "save stores the CLI tokens in the Keychain" (the stamp is missing from the profile item).

- [ ] **Step 3: Implement the allowlist**

Define `cli_shared='mcpOAuth, mcpOAuthClientConfig, mcpXaaIdp, mcpXaaIdpConfig, pluginSecrets'` once beside `cli_account_part`. `cli_account_part` becomes `jq -c "del(.${cli_shared//, /, .})"` (bash 3.2 does `${var//pat/rep}`; verified by the probe named in Task 3). The merge at line 544 becomes `jq -c --argjson s "$saved" "{$cli_shared} | with_entries(select(.value != null)) + \$s" <<< "$live"`. Comment: an unknown sibling key is account-scoped until proven shared, so it moves with the profile; the five shared keys are the only ones the live item keeps. `docs/claude-multipass.md:57,100` already say "the account part" and "the shared MCP keys"; they stay true under the new definition.

- [ ] **Step 4: Run the self-check to see them pass**

Run: `bash test/claude-multipass.sh` Expected: exit 0.

- [ ] **Step 5: Mirror the docs**

`docs/claude-multipass.md:121`: add "A profile holds every key of the CLI item except the five shared MCP and plugin keys, which stay with the live item, so an account-scoped key the tool does not know still moves with its account." `CHANGELOG.md` Unreleased: "A profile's CLI item now keeps every account-scoped key (2.1.310 adds `trustedDeviceEnrolledAfterRefusalAtMs`); only the shared MCP and plugin keys stay in the live item."

- [ ] **Step 6: Gate and commit**

Run: `pnpm check` Expected: passes.

```bash
git add bin/claude-multipass test/claude-multipass.sh docs/claude-multipass.md CHANGELOG.md
git commit -m "Keep only the shared keys from the live CLI item"
git push -u origin HEAD
gh pr create --fill
```

---

### Task 5 (optional): Rewrite the target profile item on restore

Skip unless Jason wants the one-time `apple:` partition prompt gone on the first restore rather than on the next outgoing re-save. The rule already predicts the prompt and `CHANGELOG.md` 0.3.3 documents it.

**Files:**

- Modify: `bin/claude-multipass:537-543` (`cli_restore`, after `saved` is read)
- Test: `test/claude-multipass.sh` near line 259

- [ ] **Step 1: Write the failing case**

After line 259: `check "switch rewrites the target profile item" 1 "$(grep -c 'add-generic-password -U -a "beta" -s "claude-multipass"' "$tmp/security-calls")"`. The route cases at lines 316-317 count argv writes only, so the extra stdin write does not disturb them; line 264 (no token on a command line) still holds because the write goes through `security -i`.

- [ ] **Step 2: Run it to see it fail**

Run: `bash test/claude-multipass.sh` Expected: exits 1 at "switch rewrites the target profile item" (count 0).

- [ ] **Step 3: Implement**

After the `saved` read succeeds: `keychain_put "$mp_service" "$name" <<< "$saved" || true`. Comment: an in-place write by `security` moves an item 0.3.2 left in the `python3` partition, so the first restore heals it instead of the next re-save.

- [ ] **Step 4: Run, gate, docs, commit**

Run: `bash test/claude-multipass.sh`, then `pnpm check`. `docs/claude-multipass.md:82`: "until 0.3.3 saves it again, which the re-save on the way out of the next switch does" becomes "until the next switch to or from that profile". `CHANGELOG.md` Unreleased (released entries stay as written): "A switch to a profile whose item 0.3.2 wrote rewrites that item through `security`, so it asks once on that switch and never again." Commit "Rewrite the target profile item on restore", push, open the PR.

---

## Self-review notes

- Spec coverage: rows 1 to 5 and 9 of the study's table map to Tasks 5, 3, 2, 4, 1 and 3 (step 4). Rows 6, 7 and 8 were judged not worth a change in the study and have no task.
- Review focus items 1, 2, 3 and 5 each have an assertion in the owning task; item 4 rides on the existing absent-item case.
- Names used across tasks: `cli_blocker`, `cli_lock`, `cli_unlock`, `cli_touchers`, `cli_account_part`, `cli_shared`, `SECURITY_HOLD`. Each is defined in the task that introduces it.
- Length: about the size of the diffs it describes plus their tests; the one code block (Task 3's loop) is there because its fd handling and self-exit are the decisions, not the loop.
- Verified before writing (2026-10-26, `/bin/bash` 3.2.57, the probe script named in Task 3): `VAR= func` exports to the function's child processes (the existing `CLAUDE_CONFIG_DIR=/x cda ...` cases rely on the same), `${cli_shared//, /, .}` builds the `del` filter, the `with_entries` merge drops `null` shared keys, a backgrounded `( ... )` does not run the parent's `EXIT` trap, and an orphan with inherited fds holds a pipe 3 s while a redirected one does not.
