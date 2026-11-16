# Doctor and self-check hardening implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `doctor` names every credential that can shadow or outrank the terminal login, `usage` stops telling people to sign in again when a switch would do, the tool addresses the same Keychain item Claude Code does for any user name, and the self-check fails when a run reaches the real credentials file.

**Architecture:** All five changes are small edits to `bin/claude-multipass` and `test/claude-multipass.sh`, in one PR. `doctor` stays free of Keychain and network calls and never reads the contents of the credentials file. The leak guard lives in the self-check's `EXIT` trap, because a filtered run never reaches the `done` section, and it looks for the fixture's own marker, so a real login being refreshed can never trip it.

**Tech Stack:** bash 3.2 (`set -euo pipefail`), `jq`, the fixture self-check, Swift Testing for two fixture strings.

**Spec:** this plan carries its own spec in the Findings section below, from the comparison with [clausona](https://github.com/larcane97/clausona) at `676aca0` on 2026-11-03.

## Findings

Labels: **M** measured on this Mac on 2026-11-03, **B** read in the Claude Code 2.1.318 binary, **O** Claude Code's docs, **S** read in this repo, **I** inferred.

1. **M.** `~/.claude/.credentials.json` held the self-check's fixture. Its `mcpOAuth`, `trustedDeviceToken`, `trustedDeviceEnrolledAfterRefusalAtMs`, `scopes` and `subscriptionType` all equalled `live_item` at `test/claude-multipass.sh:289`, and both tokens were empty. It was dated Oct 29 08:48. Jason removed it on 2026-11-03 and `claude auth status` still answered `loggedIn: true`.
2. **I.** How it got there is not established. The likeliest route is a real `claude` that found the stubbed `security`, cleared the fixture's dead login, and fell back to the file when the stub refused the write. Claude Code's code allows that route (finding 3), but none of the 8 transcripts in this project from that hour mention the file, so what ran stays unknown. The file's date did not move through later self-check runs, so it does not recur on every run. The `CLAUDE_MULTIPASS_BIN` wrapper from `190bcfe` closed one route on Nov 3, but no Homebrew `claude` exists today, so that route is not shown to be the cause.
3. **B, S.** The tool never looks at that file (`grep -c 'credentials\.json' bin/claude-multipass` prints 0). Claude Code's store (function `O`, `keychain-with-plaintext-fallback` in 2.1.318) reads the Keychain first and the file when that read returns nothing, and a `security` exit 36, a locked keychain, also returns nothing by default. It writes the file only when the Keychain write fails for a non-transient reason, and deletes the file only after a good Keychain write that found no item before it. So a stray file outlives every ordinary token refresh, which is why the fixture lasted from Oct 29 to Nov 3. A switch moves only the Keychain item, so a real login in the file stays behind.
4. **S.** `access_token` (`bin/claude-multipass:1306`) prints nothing when the profile's access token has passed `expiresAt`, and `usage_fetch` (`:1418`) then says `token expired, sign in and re-save`. A 401 (`:1431`) says the same. The first case is a lapsed access token beside a refresh token that may still work, so the advice can cost an email code for nothing. **M:** this should be rare. Each account's `oauth:tokenCacheV2` hash stayed the same across `backups/login-*` and its saved profile, from Oct 28 to Nov 3 for spoons, Oct 29 to Nov 2 for matherly-gmail, and Nov 1 to Nov 3 for matherly. The message change is still worth its few lines, but no one has seen the case on this Mac.
5. **B.** Claude Code's Keychain account is `process.env.USER || os.userInfo().username`, replaced by `claude-code-user` when it fails `/^[a-zA-Z0-9._-]+$/` or when reading it throws (function `R0` in 2.1.318). The tool uses `${USER:-$(id -un)}` (`:177`) with no such rule.
6. **S.** `desktop_launch` passes `USER="$cli_account"` to `open` (`:1018`), so `cli_account` cannot simply take the Claude Code rule.
7. **O.** Claude Code's authentication precedence is `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX` or `CLAUDE_CODE_USE_FOUNDRY`, then `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_API_KEY`, `apiKeyHelper`, `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_PROFILE` when named, then `/login`. `doctor` checks only `ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN` (`:1541-1542`).
8. **S.** `SELF_CHECK_DRY_RUN=1 bash test/claude-multipass.sh runlock` prints `sections: setup runlock`. A filtered run skips `#@ done` and exits right after its sections, so a check placed there would not run on a filtered run.
9. **S.** `CHANGELOG.md` has no `## Unreleased` heading today. Its first section is `## 0.13.0 (2026-11-03)`, and `/release` turns `## Unreleased` into the version heading.

Decisions, with reasons:

- `doctor` tests only that the credentials file exists. It never reads it, because a real one holds tokens. It warns and does not fail, because a real fallback login is legitimate.
- The warning does not say to delete the file, because it can hold the only copy of a login. The docs give the check that tells the two cases apart.
- Bedrock's siblings seen in the binary (`CLAUDE_CODE_USE_ANTHROPIC_AWS`, `CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD`, `CLAUDE_CODE_USE_MANTLE`, `CLAUDE_CODE_USE_GATEWAY`) stay out, because the precedence doc does not list them. Managed and project-level `apiKeyHelper` stay out too: one needs root-owned paths and the other depends on the working directory.
- The account name test runs under `LC_ALL=C`, because the self-check and many shells set a UTF-8 locale, where a bash range can match non-ASCII letters and Claude Code's JavaScript range does not.
- A `CLAUDE_CODE_USE_*` variable warns on any non-empty value, as the existing checks do, so `=0` also warns. Claude Code's own truthiness test was not read, and a false warning here costs one line.
- A user whose name fails the rule keeps an orphan item from earlier versions, under the raw name, which nothing reads. The tool leaves it, since it cannot tell whose it is and it holds no live login once a switch writes the right one.
- The new lapsed message is 6 characters longer than the old one. It needs no render: no shot fixture holds a usage error, and both places that draw it, `AccountPanel.swift:72` and `PopoverView.swift:115`, are `Text` with no line limit.
- `usage` keeps reading the signed-in account's saved copy, not `config.json`. A prototype that read the live login passed its own case and broke the Raycast fixture at `test/claude-multipass.sh:1401`, and finding 4's hashes show the saved copy not going stale, so the change has no measured benefit.

Corrected by the `interrogate` review on 2026-11-03 (Opus and Sonnet; the Fable seat hit its usage limit), then by a second pass the same day. On a scratch copy, Tasks 1 to 3, Task 4's messages and the Task 5 guard as written here passed a full self-check with 1034 `ok` lines and ShellCheck. Task 5's Steps 3 and 4 printed the outcomes they expect. The Swift suite and the doc edits have not been run.

## Global Constraints

- Follow `CLAUDE.md` Custom Notes: a worktree and branch for this change, then `pnpm install` in it. This PR goes against `main`, and merging is Jason's call.
- `doctor` makes no Keychain and no network call, and prints no contents of the credentials file.
- bash 3.2: no `<<<` or heredoc carrying a secret, `/usr/bin/stat -f`, indirect expansion as `${!name:-}` so `set -u` holds.
- `CHANGELOG.md` gets a user-visible line under `## Unreleased` for Tasks 1, 2, 3 and 4. Task 1 creates that heading above `## 0.13.0`. Task 5 is tooling and adds none.
- Prose has no em-dashes, sentence-case headings and straight quotes. Run prettier in a separate call before committing, since the commit gate checks the tree before the command runs.
- Before each commit run `/simplify` and `/code-review` on that commit's diff, and `/no-comments` before review, per J mode.

## Review Focus

1. A credentials file with a real token in it: `doctor` must warn and print none of its contents. Pinned in Task 1.
2. A `USER` that fails the rule, on a switch: the Keychain write goes to `claude-code-user` while Desktop still launches with the real `USER`. Pinned in Task 3.
3. A `settings.json` that `jq` cannot read, or `apiKeyHelper` set to an empty string: no warning and no crash under `set -e`. Pinned in Task 2.
4. The current account with a lapsed token: the message must still make sense when there is nothing to switch to. Its wording, "use it in Desktop", covers that. No fixture pins it, because the row's text does not depend on which account is current.
5. A real login in the credentials file during a self-check: the gate must not fail or read it out. A self-check that fails an assertion must keep its message and exit code. Both pinned in Task 5.

---

### Task 1: Doctor warns about the credentials file

**Files:**

- Modify: `bin/claude-multipass` (`doctor_report`, beside `:1543`; the `doctor` entry in `--help` at `:345`)
- Modify: `README.md:43`, `docs/claude-multipass.md:48` and its troubleshooting list near `:136`
- Modify: `.claude/rules/desktop-internals.md` (CLI credentials), `CHANGELOG.md`
- Test: `test/claude-multipass.sh` (section `doctor`, after the line for `doctor warns when claude is not on PATH`)

**Interfaces:**

- Consumes: `cli_home`, which the fixture points at `$tmp/claude-home` through `CLAUDE_CLI_HOME`.
- Produces: the line `warn: credentials file: <path> exists; Claude Code reads it when the Keychain has no item or is locked, and a switch does not move it`.

- [ ] **Step 1: Write the failing tests**

```bash
printf '{"claudeAiOauth":{"accessToken":"at-secret-in-file"}}' > "$CLAUDE_CLI_HOME/.credentials.json"
out=$(cda doctor)
check_true "doctor warns about the credentials file" grep -qF "warn: credentials file: $CLAUDE_CLI_HOME/.credentials.json exists; Claude Code reads it when the Keychain has no item or is locked, and a switch does not move it" <<< "$out"
check "doctor prints nothing from the credentials file" 0 "$(grep -c at-secret-in-file <<< "$out")"
check "a credentials file does not fail doctor" 0 "$(exit_code cda doctor)"
rm -f "$CLAUDE_CLI_HOME/.credentials.json"
check "doctor is quiet with no credentials file" 0 "$(cda doctor | grep -c '^warn: credentials file:')"
```

- [ ] **Step 2: Run the section and confirm it fails**

Run: `bash test/claude-multipass.sh doctor` Expected: exit 1 naming `doctor warns about the credentials file`.

- [ ] **Step 3: Add the existence test to `doctor_report`**

One line beside the `claude: not on PATH` check, a `[[ ! -e ... ]] || echo` in the same style. Name the check in `--help`, `README.md:43` and `docs/claude-multipass.md:48`.

- [ ] **Step 4: Document how to tell a leftover from a real login**

In the `docs/claude-multipass.md` troubleshooting list, add a bullet with this command, which reads attributes only and raises no prompt:

```bash
security find-generic-password -s "Claude Code-credentials" > /dev/null && echo "Keychain item exists"
```

When the item exists, Claude Code does not read the file while the Keychain is unlocked and answers, so the file is a leftover and can be moved aside. When it does not, the file may hold the only login, so run `claude auth login` first. Add finding 1 (M) and finding 3's read and write rules (M, in the 2.1.318 binary) to `.claude/rules/desktop-internals.md`, in the bullet that says the CLI reads the Keychain before the file.

- [ ] **Step 5: Run the section and confirm it passes**

Run: `bash test/claude-multipass.sh doctor` Expected: `Filtered claude-multipass checks passed`.

- [ ] **Step 6: Commit**

```bash
git add bin/claude-multipass test/claude-multipass.sh README.md docs/claude-multipass.md .claude/rules/desktop-internals.md CHANGELOG.md
git commit -m "Warn in doctor about a stray credentials file"
```

### Task 2: Doctor names every documented login override

**Files:**

- Modify: `bin/claude-multipass` (`doctor_report`, `:1541-1542`; `--help` at `:349-350`)
- Modify: `README.md:43`, `docs/claude-multipass.md:48`, `.claude/rules/safety-and-terms.md` (the stray-credentials bullet), `CHANGELOG.md`
- Test: `test/claude-multipass.sh` (section `doctor`, replacing the two cases at `:1349-1350`)

**Interfaces:**

- Consumes: `jq_works`, set at the top of `doctor_report`.
- Produces: `warn: <NAME> is set; it overrides the terminal login` per variable, and `warn: apiKeyHelper is set in <path>; it overrides the terminal login`.

- [ ] **Step 1: Write the failing tests**

```bash
for var in CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_PROFILE; do
  check_true "doctor warns on $var" grep -q "^warn: $var is set; it overrides the terminal login" <<< "$(env "$var=x" "$script" doctor)"
done
printf '{"apiKeyHelper":"/x/helper"}' > "$CLAUDE_CLI_HOME/settings.json"
check_true "doctor warns on apiKeyHelper" grep -qF "warn: apiKeyHelper is set in $CLAUDE_CLI_HOME/settings.json; it overrides the terminal login" <<< "$(cda doctor)"
printf '{"apiKeyHelper":""}' > "$CLAUDE_CLI_HOME/settings.json"
check "an empty apiKeyHelper does not warn" 0 "$(cda doctor | grep -c '^warn: apiKeyHelper')"
printf 'not json' > "$CLAUDE_CLI_HOME/settings.json"
check "an unreadable settings.json does not warn" 0 "$(cda doctor | grep -c '^warn: apiKeyHelper')"
check "or fail doctor" 0 "$(exit_code cda doctor)"
rm -f "$CLAUDE_CLI_HOME/settings.json"
```

- [ ] **Step 2: Run the section and confirm it fails**

Run: `bash test/claude-multipass.sh doctor` Expected: exit 1 naming `doctor warns on CLAUDE_CODE_USE_BEDROCK`.

- [ ] **Step 3: Replace the two lines with a loop and add the settings check**

Loop over the seven names in precedence order, reading each with `${!var:-}`. Test `apiKeyHelper` with `jq -e '.apiKeyHelper | type == "string" and length > 0' "$cli_home/settings.json" > /dev/null 2>&1`, only when `jq_works` is set. Update `--help`, the two docs and the rules bullet to name the documented order.

- [ ] **Step 4: Run the section and confirm it passes**

Run: `bash test/claude-multipass.sh doctor` Expected: `Filtered claude-multipass checks passed`.

- [ ] **Step 5: Commit**

```bash
git add bin/claude-multipass test/claude-multipass.sh README.md docs/claude-multipass.md .claude/rules/safety-and-terms.md CHANGELOG.md
git commit -m "Name every documented login override in doctor"
```

### Task 3: Use Claude Code's rule for the Keychain account

**Files:**

- Modify: `bin/claude-multipass:177` and `:1014-1018`
- Modify: the lines that say the item's account is the macOS user name: `bin/claude-multipass:169`, `CLAUDE.md:42`, `docs/claude-multipass.md:121`, `.claude/rules/desktop-internals.md:43`. Leave `:94` of that rule and `docs/research.md:85`, which record a closed test.
- Modify: `CHANGELOG.md`
- Test: `test/claude-multipass.sh` (a new `#@ account-name needs switch` section directly before `#@ migration needs switch`)

**Interfaces:**

- Produces: `macos_user` (`${USER:-$(id -un)}`, used only for `desktop_launch`) and `cli_account` (`macos_user`, or `claude-code-user` when it fails the rule). No other `cli_account` caller changes: `:533`, `:960`, `:970` all name the Keychain item.

- [ ] **Step 1: Write the failing section**

The section builds its own CLI login for `alpha`, because by this point in a full run `alpha` has none, and it restores the plain `open` stub and the signed-in account for `migration`.

```bash
#@ account-name needs switch
# Claude Code answers for "claude-code-user" when USER fails its rule, so that is the item it reads.
printf '#!/bin/sh\nexport PATH="%s/bin:$PATH"\n/usr/bin/env > "%s/open-env"\n' "$tmp" "$tmp" > "$tmp/bin/open"
kc_put claude-multipass alpha '{"claudeAiOauth":{"accessToken":"at-name","refreshToken":"rt-name","expiresAt":2}}'
printf '{"oauthAccount":{"accountUuid":"%s"}}' "$(jq -r .account "$p/alpha/meta.json")" > "$p/alpha/cli.json"
USER='first last' cda switch alpha --force > /dev/null 2>&1
check "a user name Claude Code rejects writes the item it reads" at-name "$(kc_get "Claude Code-credentials" claude-code-user | jq -r .claudeAiOauth.accessToken)"
check "and Desktop still launches with the real user name" 'USER=first last' "$(grep '^USER=' "$tmp/open-env")"
kc_delete "Claude Code-credentials" claude-code-user
printf '#!/bin/sh\nexport PATH="%s/bin:$PATH"\necho "open $*" >> "%s/calls"\n' "$tmp" "$tmp" > "$tmp/bin/open"
cda switch beta --no-relaunch --force > /dev/null 2>&1
rm -f "$tmp/calls"
```

- [ ] **Step 2: Run the section and confirm it fails**

Run: `bash test/claude-multipass.sh account-name` Expected: exit 1 naming `a user name Claude Code rejects writes the item it reads`.

- [ ] **Step 3: Split the two names**

`macos_user=${USER:-$(id -un)}`, then `cli_account=$macos_user`, then `printf %s "$cli_account" | LC_ALL=C grep -Eq '^[a-zA-Z0-9._-]+$' || cli_account=claude-code-user`. `desktop_launch` passes `USER="$macos_user"`, and its comment at `:1014` names that variable. A one-line comment at `:177` says the rule is Claude Code's. Add finding 5 to the internals rule, labelled M in the 2.1.318 binary.

- [ ] **Step 4: Run the section, then the whole self-check**

Run: `bash test/claude-multipass.sh account-name && bash test/claude-multipass.sh` Expected: `Filtered claude-multipass checks passed`, then `All claude-multipass checks passed`. The full run matters, because the section's starting state differs from the filtered one.

- [ ] **Step 5: Commit**

```bash
git add bin/claude-multipass test/claude-multipass.sh CLAUDE.md docs/claude-multipass.md .claude/rules/desktop-internals.md CHANGELOG.md
git commit -m "Follow Claude Code's rule for the Keychain account name"
```

### Task 4: Say what a lapsed token actually needs

**Files:**

- Modify: `bin/claude-multipass:1418` and `:1431`
- Modify: `docs/claude-multipass.md:140`, `CHANGELOG.md`
- Test: `test/claude-multipass.sh:1120`, `:1125`, `:1133` and `:1141`; fixtures at `app/Tests/MultipassCoreTests/AppStateTests.swift:494-496` and `app/Tests/MultipassCoreTests/ModelsTests.swift:91-97`

**Interfaces:**

- Produces: `usage` errors `token lapsed, use it in Desktop to renew` (no unexpired access token) and `token refused, sign in and re-save` (HTTP 401). `app/Sources` matches neither string, so the app only displays them.

- [ ] **Step 1: Change the expected strings in the four self-check cases**

```bash
check "usage reports a lapsed token" "stale            token lapsed, use it in Desktop to renew" "$(cda usage stale)"
check "usage reports a refused token" "usagey           token refused, sign in and re-save" "$(cda usage usagey)"
```

`:1133` (`usage lists every saved account in order`) and `:1141` (`usage --json error entry`) quote the `stale` profile, so both expect `token lapsed, use it in Desktop to renew`.

- [ ] **Step 2: Run the section and confirm it fails**

Run: `bash test/claude-multipass.sh usage` Expected: exit 1 naming `usage reports a lapsed token`.

- [ ] **Step 3: Change the two messages and the docs**

Split `docs/claude-multipass.md:140` into one bullet per message. The lapsed one says using the account in Desktop, through `switch`, renews it with no email code. Update the Swift test fixtures to the lapsed text, since they quote the tool's output.

- [ ] **Step 4: Run the section and the app's tests**

Run: `bash test/claude-multipass.sh usage && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path app` Expected: `Filtered claude-multipass checks passed`, then all Swift tests pass.

- [ ] **Step 5: Commit**

```bash
git add bin/claude-multipass test/claude-multipass.sh docs/claude-multipass.md CHANGELOG.md app/Tests/MultipassCoreTests/AppStateTests.swift app/Tests/MultipassCoreTests/ModelsTests.swift
git commit -m "Tell a lapsed usage token from a refused one"
```

- [ ] **Step 6: Note the real-Mac check for Jason**

Add to the PR's test plan: "If an account ever shows `token lapsed`, switch to it and confirm its figures return with no email code." This proves the new message's claim, which no fixture can, and finding 4 says it may be a long wait. Agents do not run it, because `switch` and `usage` are on the ask list.

### Task 5: Fail the self-check when the fixture reaches the real credentials file

**Files:**

- Modify: `test/claude-multipass.sh` (the `trap` at `:36`; a check beside `:262`)
- Modify: `.claude/rules/testing.md`, `CLAUDE.md` (the self-check paragraph in Commands)

**Interfaces:**

- Produces: `SELF_CHECK_REAL_HOME`, default `$HOME`, used only by this guard so its proof can run against a scratch folder.

- [ ] **Step 1: Add the stub-resolution case to `setup`**

```bash
check "security resolves to the stub" "$tmp/bin/security" "$(command -v security)"
```

- [ ] **Step 2: Add the guard to the `EXIT` trap**

Replace the one-line `trap` with a function, since the message's apostrophe does not survive a single-quoted trap string:

```bash
creds="${SELF_CHECK_REAL_HOME:-$HOME}/.claude/.credentials.json"
self_check_exit() {
  local rc=$?
  [[ -z $hs_pids ]] || kill -9 $hs_pids 2> /dev/null || true
  rm -rf "$tmp"
  if /usr/bin/grep -qE 'dev-alpha|"srv": ?"shared"' "$creds" 2> /dev/null; then
    echo "FAILED: $creds holds this self-check's fixture. A real claude reached the security stub. Remove the file." >&2
    exit 1
  fi
  exit "$rc"
}
trap self_check_exit EXIT
```

Those two strings appear only in fixtures, so a real login never matches, and `grep -q` prints nothing from the file. A leftover from an earlier run fails every run until it is removed, which is what we want. The path is absolute because the fixture may stub tools.

- [ ] **Step 3: Prove all four outcomes against a scratch home**

```bash
h=$(mktemp -d)
mkdir -p "$h/.claude"
SELF_CHECK_REAL_HOME=$h bash test/claude-multipass.sh runlock > /dev/null
echo "no file: $?"
printf '{"claudeAiOauth":{"accessToken":"x"}}' > "$h/.claude/.credentials.json"
SELF_CHECK_REAL_HOME=$h bash test/claude-multipass.sh runlock > /dev/null
echo "real-looking: $?"
printf '{"mcpOAuth":{"srv":"shared"}}' > "$h/.claude/.credentials.json"
SELF_CHECK_REAL_HOME=$h bash test/claude-multipass.sh runlock > /dev/null
echo "fixture: $?"
rm -f "$h/.claude/.credentials.json"
SELF_CHECK_REAL_HOME=$h bash test/claude-multipass.sh zzznope > /dev/null 2>&1
echo "filter miss: $?"
```

Expected: `no file: 0`, `real-looking: 0`, `fixture: 1` with the `FAILED:` line on stderr, `filter miss: 2`.

- [ ] **Step 4: Prove a failed assertion keeps its code**

Add a temporary `check "deliberate failure" a b` under `#@ runlock`, run `bash test/claude-multipass.sh runlock; echo "exit $?"`, then revert it. Expected: `FAIL: deliberate failure`, `exit 1`, and no `FAILED:` line.

- [ ] **Step 5: Document the guard**

One bullet in `.claude/rules/testing.md` and one clause in the `CLAUDE.md` self-check paragraph. State what it detects, that it cannot detect a real Keychain write, and that the Oct 29 leak is why it exists.

- [ ] **Step 6: Commit**

```bash
git add test/claude-multipass.sh .claude/rules/testing.md CLAUDE.md
git commit -m "Fail the self-check when its fixture reaches the real credentials file"
```

### Task 6: Open the PR

**Files:** none new.

- [ ] **Step 1: Run the whole gate**

Run: `pnpm check` Expected: exit 0.

- [ ] **Step 2: Run the docs audit**

Run the `docs-audit` skill on the branch, since the PR changes the script and the tests. Fix what it finds in this PR.

- [ ] **Step 3: Confirm the real `doctor` output on this Mac**

Run: `bin/claude-multipass doctor`. It is read-only, with no Keychain and no network. Expected: no `warn: credentials file:` line, since the file is gone, and any override warnings match the shell's real environment. A Claude Code session sets `CLAUDE_CODE_OAUTH_TOKEN` and possibly others, so say which shell it ran from.

- [ ] **Step 4: Push and open the PR against `main`**

The description lists the five changes, the Task 4 real-Mac check for Jason, and what was not checked. Stop at merge-ready.
