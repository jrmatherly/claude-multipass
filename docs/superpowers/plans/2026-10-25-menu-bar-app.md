# Claude Multipass menu bar app implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A signed, notarized macOS menu bar app that shows the signed-in saved account, switches accounts in two clicks, and optionally shows per-account usage, driving the existing `claude-multipass` script.

**Architecture:** The bash script stays the only code that touches Desktop's files; it gains `--json`, `--version`, a refusal exit code and `doctor`. A Swift package in `app/` has an AppKit-free core (models, formatting, CLI runner, state machine, all unit tested with Swift Testing) and a thin AppKit/SwiftUI shell (`NSStatusItem` hosting a SwiftUI strip, a popover, a settings window). `scripts/build-app.sh` assembles and signs the bundle; `release.yml` notarizes and publishes a DMG; the tap gets a cask.

**Tech Stack:** bash 3.2, jq, Swift 6.4 toolchain via Command Line Tools (no Xcode), SwiftPM, Swift Testing, SwiftUI + AppKit, `codesign`/`notarytool`/`stapler`, Homebrew cask.

**Spec:** `docs/superpowers/specs/2026-10-25-menu-bar-app.md`

Revised 2026-10-25 after two three-model adversarial review rounds; each revision's commit message lists the findings and their disposition.

## Global constraints

- Script target is `/bin/bash` 3.2: no associative arrays, no `mapfile`, build strings with nested escaped quotes in a variable first. BSD `stat -f %Lp`, `date -r`. `main` takes the command word as `$1`, shifts it, then parses options from the rest: a new top-level flag goes in the first `case $cmd`, not in the option loop. Every new variable the option loop sets is declared on `main`'s `local` line (`set -u`).
- Every new command, option or refusal gets a case in `test/claude-multipass.sh`, asserting what the user observes, against the fixture that exists (profiles `alpha`, `beta`, then `usagey` and `stale`; the signed-in account changes through the file, so each new case names the line it goes after). `check_true` runs its arguments as a command, so a negative assertion uses `check "…" 0 "$(grep -c … /dev/null …)"` or `test ! -e`, never `check_true … !`. `$tmp/calls` persists across cases: `rm -f` it before asserting on it, and remember `grep -c` on a missing file prints nothing, not `0`.
- Version strings in tests come from `pkg_version=$(jq -r .version "$(dirname "$script")/../package.json")`, defined once near the top of the self-check, never a literal.
- A behaviour change edits `README.md` or `docs/` in the same commit; the header tldr block and `usage()` stay accurate.
- `pnpm check` must pass before every commit (the commit-gate hook runs it). Commit subjects: short, imperative, sentence case, no prefix. Prose: no em-dashes, short sentences, sentence-case headings.
- The script never reads the Keychain outside `usage`, never switches without a user action, never sets `CLAUDE_CONFIG_DIR`.
- Agent-run manual checks stop before anything `CLAUDE.md` reserves for the user: no Switch, no Save, no usage enable (Keychain prompt), no Launch at login toggle, and no write to the real profile store (a throwaway app runs against a copied store via `open --env CLAUDE_MULTIPASS_DIR=…`, which `open` supports, measured). Those are maintainer steps and say so.
- Swift package: tools version 5.9, `platforms: [.macOS(.v14)]`, `swiftLanguageVersions: [.v5]`. `MultipassCore` imports Foundation only. Tests use `import Testing`, never XCTest, and run with `-Xswiftc -plugin-path -Xswiftc "$(xcode-select -p)/usr/lib/swift/host/plugins/testing"` under the Command Line Tools (measured: without it, `plugin for module 'TestingMacros' not found`). Type names avoid SwiftUI's `Settings` and `Window`. Every type the app module constructs has a `public init`.
- Bundle identifier `net.matherly.claude-multipass`, product name `Claude Multipass`, `LSUIElement` true, `LSMinimumSystemVersion` 14.0, arm64.
- The app runs `switch` only from the inline confirm's Switch button or the "Switch anyway" button. Usage polling only when `usageEnabled` is true, interval at least 5 minutes, never triggered by a module toggle.
- CLI JSON shapes are exactly the ones in the spec (key names, `null` for a missing `current`, `error` string instead of windows, `resetsAt` normalised to `Z`).
- Manual checks run against the repo's script, not the Homebrew 0.1.0 install: the throwaway bundle gets a `CFBundleIdentifier` so `defaults` reach it, and the settings blob is a String with every key optional on decode, so a partial `defaults write … settings -string '{"cliPathOverride":"<repo>/bin/claude-multipass"}'` takes effect. The first thing the check confirms is that Settings shows CLI version `0.2.0`.

## Review focus

1. CLI missing, not executable, or older than 0.2.0: the popover shows the install or upgrade hint, the strip shows `CLI` over `?`, never a crash or an empty strip. Pinned in Task 7 (`locate`), Task 8 (`displayName` is not used for that state), Task 10 (`cliStatus` tests, including the exit-2 `--version` of a 0.1.0 script, and re-probe on refresh).
2. `switch` refused because the signed-in login is unsaved: exit 3 becomes the "Switch anyway" path, `--force` appears in the rerun's arguments, and Cancel clears it. Pinned in Task 2 (exit code) and Task 10 (`rowError`).
3. Usage failure for one profile (cannot decrypt, 401, 429, offline, unreadable body): render `–`, keep the other profiles, no retry before the next tick; a Keychain prompt left open times out instead of stalling polling forever. Pinned in Task 4 (`error` entries, empty report), Task 7 (timeout) and Task 10 (no immediate retry).
4. A profile name of 17 or more characters, or `not saved`: the strip truncates and the status item width follows the content. Pinned in Task 8 (`displayName`) and the manual check in Task 11 step 2.
5. `resetsAt` in the past or missing, or a window with null utilization: countdown shows `–`, never a negative duration, and one odd window never fails the whole report. Pinned in Task 4 (window omitted) and Task 8.

---

### Task 1: `--version` and the version constant

**Files:**

- Modify: `bin/claude-multipass` (header tldr block; `usage()` Options; the first `case $cmd` at ~617, beside `-h | --help | help`)
- Modify: `package.json` (`version` to `0.2.0`; it stays unreleased until the release skill tags it)
- Modify: `test/check.sh` (version equality assertion)
- Modify: `test/claude-multipass.sh` (`pkg_version` near the top, two cases)
- Modify: `.claude/skills/release/SKILL.md` steps 1 and 2; `CHANGELOG.md` (`## 0.2.0 (unreleased)` section, first entry)
- Modify: `docs/claude-multipass.md` Commands table

**Interfaces:**

- Produces: `claude-multipass --version` prints `claude-multipass 0.2.0` and exits 0. A top-level `version=0.2.0` variable right after `set -euo pipefail`. `test/check.sh` fails when that value differs from `jq -r .version package.json`.

- [ ] **Step 1: Write the failing tests**

After line 33 (`cda()`): `pkg_version=$(jq -r .version "$(dirname "$script")/../package.json")`. After the `--help shows the commands` case (line 190):

```bash
check "version" "claude-multipass $pkg_version" "$(cda --version)"
check "version exits 0" 0 "$(exit_code cda --version)"
```

- [ ] **Step 2: Run it, expect failure**

Run: `bash test/claude-multipass.sh` Expected: exit 1, `FAIL: version` (today `--version` falls through to the usage page and exit 2).

- [ ] **Step 3: Implement**

`version=0.2.0` after `set -euo pipefail`. In the first `case $cmd`, a new arm before `-h | --help | help`: `--version) echo "claude-multipass $version"; return 0 ;;`. Add `--version` to `usage()` Options and a tldr entry. `package.json` version `0.2.0`. In `test/check.sh`, after the header-comment loop: compare `sed -n 's/^version=//p' bin/claude-multipass` with `jq -r .version package.json`, exit 1 with `check: bin/claude-multipass version=… differs from package.json …` on mismatch. In the release skill: step 1 writes the heading as `## X.Y.Z (YYYY-MM-DD)` (no `v`, matching the existing `## 0.1.0 (2026-10-25)`), replacing a `(unreleased)` heading when one exists; step 2 bumps `version=` in `bin/claude-multipass` and `package.json` together and says `pnpm check` enforces the match. Start `CHANGELOG.md` with `## 0.2.0 (unreleased)` and the line `- --version prints the version.`

- [ ] **Step 4: Run the gate**

Run: `bash test/claude-multipass.sh` (prints `ok: version`), then `pnpm check` (exit 0; it sends the self-check output to `/dev/null`).

- [ ] **Step 5: Commit**

```bash
git add bin/claude-multipass package.json test/check.sh test/claude-multipass.sh docs/claude-multipass.md .claude/skills/release/SKILL.md CHANGELOG.md
git commit -m "Add --version"
```

### Task 2: exit code 3 for refusals `--force` lifts

**Files:**

- Modify: `bin/claude-multipass` (`fail` at ~120; `profile_save` ~320; `main` `sync` arm ~651, `save` arm ~682, `switch` arm ~686)
- Modify: `test/claude-multipass.sh` lines 176, 205, 212
- Modify: `docs/claude-multipass.md` Safety rails; `.claude/rules/safety-and-terms.md` (one line under "Rules a change must keep"); `CHANGELOG.md`

**Interfaces:**

- Produces: `refuse()` beside `fail()`, same output style, `exit 3`. The three refusals exit 3. The `save` account-mismatch check runs in the pre-quit `save)` arm of `main` (next to the `signed_in` check), so a refused save never quits Desktop and never installs the relaunch trap; `profile_save` keeps its check as a second guard for the `switch` re-save path.

- [ ] **Step 1: Change the assertions**

Lines 176 (`sync refuses while Desktop runs`) and 205 (`switch refuses to drop an unsaved login`): expected `3`. Replace line 212 with:

```bash
rm -f "$tmp/calls"
check "save over another account's profile is refused" 3 "$(exit_code cda save beta)"
check_true "a refused save does not quit or relaunch Desktop" test ! -e "$tmp/calls"
```

(No `--no-relaunch`: today the refusal fires inside `profile_save`, after `trap desktop_launch EXIT` is set, so the `open` stub logs `open -a Claude` and the second check is red; after the fix nothing is logged. `$tmp/calls` holds entries from lines 166 and 172 at this point, hence the `rm -f`.)

- [ ] **Step 2: Run, expect lines 176 and 205 to fail with actual `1`, and the new `check_true` to fail**

- [ ] **Step 3: Implement**

`refuse()` next to `fail()`. Replace `fail` with `refuse` at the three sites. In `main`'s `save)` arm, after `signed_in || fail …`, add the mismatch check: if `$store/$name/meta.json` exists and its `.account` differs from `live_account` and `--force` is absent, `refuse` with the message `profile_save` uses today. Document in `--help` under `--force`: "a refusal exits 3". Add to `docs/claude-multipass.md` Safety rails and to `safety-and-terms.md`: "Refusals that `--force` lifts exit 3, so a caller can offer the override; other failures exit 1. A refused `save` is decided before Desktop quits." CHANGELOG line.

- [ ] **Step 4: Gate.** `pnpm check` passes.

- [ ] **Step 5: Commit** `Exit 3 for the refusals --force lifts`.

### Task 3: `list --json`

**Files:**

- Modify: `bin/claude-multipass` (`list_profiles` ~507; `main`'s `local` line ~595 gains `json=''`; option loop ~605; the `--force` applicability line ~614; `migrate_store` echo ~592; `list` arm ~645)
- Modify: `test/claude-multipass.sh` (line 294 changes shape)
- Modify: `docs/claude-multipass.md`, `README.md` Commands table, header tldr, `CHANGELOG.md`

**Interfaces:**

- Produces: `list --json` prints one JSON object per the spec. `--json` sets `json=1` in the option loop; `[[ -z $json || $cmd == list || $cmd == usage ]] || fail "--json applies to list and usage"`. `migrate_store` prints its message to stderr.

- [ ] **Step 1: Write the failing tests**

After line 139 (`list leaves alpha unmarked`; `beta` is signed in, `pgrep` exits 1):

```bash
out=$(cda list --json)
check "list --json current" beta "$(jq -r .current <<< "$out")"
check "list --json signedIn" true "$(jq -r .signedIn <<< "$out")"
check "list --json desktopRunning" false "$(jq -r .desktopRunning <<< "$out")"
check "list --json names in order" "alpha beta" "$(jq -r '[.profiles[].name] | join(" ")' <<< "$out")"
check "list --json sessions is a number" number "$(jq -r '.profiles[1].sessions | type' <<< "$out")"
check "list --json sessions" 4 "$(jq -r '.profiles[1].sessions' <<< "$out")"
check "list --json version" "$pkg_version" "$(jq -r .version <<< "$out")"
check "--json rejected elsewhere" 1 "$(exit_code cda current --json)"
```

After line 204 (the unsaved `zzzzzzzz-9999` login is in place):

```bash
check "list --json current is null when not saved" null "$(cda list --json | jq -r .current)"
check "list --json still signed in" true "$(cda list --json | jq -r .signedIn)"
```

Replace line 294 with:

```bash
out=$(env -u CLAUDE_MULTIPASS_DIR XDG_CONFIG_HOME="$tmp/home/.config" "$script" list --json 2> "$tmp/migrate-err")
check "first run moves the old store" "Moved the saved accounts from $tmp/home/.config/dotfiles/claude-desktop-accounts to $tmp/home/.config/claude-multipass/profiles" "$(cat "$tmp/migrate-err")"
check "first run list --json is clean JSON" old "$(jq -r '.profiles[0].name' <<< "$out")"
```

- [ ] **Step 2: Run, expect `Unknown option: --json`**

- [ ] **Step 3: Implement**

`list_json()`: for each `meta.json`, `jq -n --arg name --arg account --arg savedAt --argjson sessions '{name:$name, account:$account, savedAt:$savedAt, sessions:$sessions}'` appended to a temp file; then `jq -n --arg v "$version" --argjson signedIn … --argjson running … --arg current "$(active_profile)" --slurpfile p "$tmpfile" '{version:$v, signedIn:$signedIn, desktopRunning:$running, current:(if $current=="" then null else $current end), profiles:$p}'`. `--slurpfile` on a file of bare objects yields a flat array, and `[]` for an empty file (measured). `migrate_store`'s `echo` goes to `>&2`. Document `--json` in `usage()`, the tldr block, README and docs; CHANGELOG line.

- [ ] **Step 4: Gate.** `pnpm check` passes.

- [ ] **Step 5: Commit** `Add list --json`.

### Task 4: `usage --json`

**Files:**

- Modify: `bin/claude-multipass` (`usage_jq` ~432, `usage_text` ~438, `usage_report` ~466)
- Modify: `test/claude-multipass.sh` (after line 285, where `usagey` is good and `stale` is an expired token)
- Modify: `docs/claude-multipass.md` Usage headroom section, `CHANGELOG.md`

**Interfaces:**

- Produces: `usage --json` prints `{"profiles":[...]}` per the spec: per entry `name` and either `fiveHour`/`sevenDay` (`utilization` number, `resetsAt` normalised `…Z` string when present; a window omitted when its utilization is null) or `error` with the CLI's full text (today's strings: `token expired, sign in and re-save`, `cannot decrypt (…)`, `rate limited`, `unavailable`, `unavailable (HTTP <code>)`, `unreadable response`). `(signed in)` keeps that name. `{"profiles":[]}` with nothing to report. Exit code and the token-on-stdin property are unchanged.

- [ ] **Step 1: Write the failing tests**

After line 285:

```bash
out=$(cda usage --json)
check "usage --json good entry" usagey "$(jq -r '.profiles[] | select(.fiveHour) | .name' <<< "$out")"
check "usage --json 5h utilization" 42.6 "$(jq -r '.profiles[] | select(.name=="usagey").fiveHour.utilization' <<< "$out")"
check "usage --json normalises resetsAt" 2026-10-23T19:45:00Z "$(jq -r '.profiles[] | select(.name=="usagey").fiveHour.resetsAt' <<< "$out")"
check "usage --json 7d resetsAt" 2026-10-27T13:00:00Z "$(jq -r '.profiles[] | select(.name=="usagey").sevenDay.resetsAt' <<< "$out")"
check "usage --json error entry" "token expired, sign in and re-save" "$(jq -r '.profiles[] | select(.name=="stale").error' <<< "$out")"
check "usage --json never puts the token on a command line" 0 "$(grep -c 'curl .*tok-u' "$tmp/curl-args")"
check "usage --json never prints a token" 0 "$(grep -c tok-u <<< "$out")"
cp "$tmp/usage.json" "$tmp/usage-full.json"
printf '{"five_hour":{"utilization":42.6},"seven_day":{"utilization":null}}' > "$tmp/usage.json"
check "usage --json omits a null window" null "$(cda usage usagey --json | jq -r '.profiles[0].sevenDay')"
cp "$tmp/usage-full.json" "$tmp/usage.json"
mkdir -p "$tmp/emptyd" && printf '{"theme":"dark"}' > "$tmp/emptyd/config.json"
check "usage --json with nothing saved" '{"profiles":[]}' "$(CLAUDE_DESKTOP_DIR="$tmp/emptyd" CLAUDE_MULTIPASS_DIR="$tmp/empty" cda usage --json)"
```

(`usage.json` is restored because the Raycast usage check at line 287 reads it.)

- [ ] **Step 2: Run, expect failure**

- [ ] **Step 3: Implement**

Split `usage_text` into `usage_fetch` (prints the raw body on HTTP 200 with a parseable body, or `error: <reason>` using exactly the reason strings listed above) and two formatters: `usage_line` (today's text via `usage_jq`) and `usage_object` (`jq --arg name` building `{name:$name}` plus `fiveHour`/`sevenDay` objects, each `{utilization, resetsAt}` with `resetsAt` through the existing `sub("(\\.[0-9]+)?(\\+00:00|Z)$"; "Z")` and dropped when null, the whole window dropped when `utilization == null`; or `{name:$name, error:$reason}`). `usage_report` writes one object per temp file when `json=1` and ends with `if [[ -n $(ls -A "$out") ]]; then jq -s '{profiles: .}' "$out"/*; else echo '{"profiles":[]}'; fi`. The token stays on `curl`'s stdin.

- [ ] **Step 4: Gate.** `pnpm check` passes; every existing text `usage` assertion still passes.

- [ ] **Step 5: Commit** `Add usage --json`.

### Task 5: `doctor`

**Files:**

- Modify: `bin/claude-multipass` (new `doctor_report`; the first `case $cmd` gets `doctor` in the `list | sync | current | pick` "takes no name" arm; the dispatch runs `doctor` before the `[[ -f $config ]]` check)
- Modify: `test/claude-multipass.sh` (after the Task 4 cases; the `security` stub at line 243 gains a `calls` log line)
- Modify: `docs/claude-multipass.md` "When something is off"; `README.md` Commands table; header tldr; `CHANGELOG.md`

**Interfaces:**

- Produces: `doctor` prints one line per check, in the spec's order, each `ok: <subject>`, `warn: <subject>: <detail>` or `fail: <subject>: <detail>`, where `<subject>` is the tool name, `store`, `backups`, `desktop`, `legacy store`, or the profile name for per-profile checks (`fail: usagey: empty oauth:tokenCacheV2 (re-save it)`, `fail: <name>: missing meta.json`). Exits 1 when any `fail:` was printed, else 0. No `security`, no `curl`.

- [ ] **Step 1: Write the failing tests**

Change line 243 so the `security` stub also appends `security $*` to `$tmp/calls`. Then, after the Task 4 cases:

```bash
rm -f "$tmp/calls"
touch "$tmp/calls"
check "doctor healthy" 0 "$(exit_code cda doctor)"
check_true "doctor reports jq" grep -q '^ok: jq' <<< "$(cda doctor)"
check "doctor never calls security" 0 "$(grep -c security "$tmp/calls")"
cp "$p/usagey/config.json" "$tmp/usagey-config"
printf '{"oauth:tokenCacheV2":""}' > "$p/usagey/config.json"
check "doctor fails on an empty token" 1 "$(exit_code cda doctor)"
check_true "doctor names the profile" grep -q '^fail: usagey: empty oauth:tokenCacheV2' <<< "$(cda doctor || true)"
cp "$tmp/usagey-config" "$p/usagey/config.json"
```

- [ ] **Step 2: Run, expect the usage page and exit 2 for `doctor`**

- [ ] **Step 3: Implement `doctor_report`**

One function, `status=0` set to 1 by each `fail:` line, `return $status`. Checks in spec order; the backups count uses the `ls -1d "$backups"/login-*/ 2> /dev/null | wc -l` form from `backup_login` so an empty match cannot abort under `set -e`. Dispatch before the `[[ -f $config ]]` line so a missing config is a `fail: config: …` line, not a `fail` exit.

- [ ] **Step 4: Gate.** `pnpm check` passes.

- [ ] **Step 5: Commit** `Add doctor`.

### Task 6: Swift package scaffold, gate, and the rails rewrite

**Files:**

- Create: `app/Package.swift`, `app/Sources/MultipassCore/Models.swift`, `app/Sources/ClaudeMultipass/App.swift` (placeholder `@main` that exits), `app/Tests/MultipassCoreTests/ModelsTests.swift`, `app/.gitignore` (`.build/`)
- Modify: `test/check.sh` (swift test line with the conditional plugin path), `.claude/settings.json` (commit-gate `timeout` 180 to 600), `.claude/hooks/test-commit-gate.sh` only if it asserts the timeout (check first), `.prettierignore` (`app/.build/`), `.gitignore` (`dist/`)
- Modify: the eight rails locations the spec lists, `CLAUDE.md` Architecture tree (`app/`, `scripts/`) and Commands

**Interfaces:**

- Produces: `MultipassCore` with `Snapshot`, `Profile`, `UsageReport`, `UsageEntry`, `UsageWindow` as the spec declares them, all with `public init`, `Decodable` through `MultipassJSON.decoder` (a `JSONDecoder` with a custom date strategy that parses `YYYY-MM-DDTHH:MM:SSZ` via `ISO8601DateFormatter` and throws on anything else). `Profile.id == name`, `UsageEntry.id == name`. The gate line in `test/check.sh`:

```bash
plugins="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
swift_flags=()
[[ -d $plugins ]] && swift_flags=(-Xswiftc -plugin-path -Xswiftc "$plugins")
swift test --package-path app "${swift_flags[@]}" > /dev/null
```

(bash 3.2 with `set -u`: an empty array expansion needs `${swift_flags[@]+"${swift_flags[@]}"}`; use that form.)

- [ ] **Step 1: Write the failing tests**

```swift
@Test func decodesSnapshot() throws {
  let json = #"{"version":"0.2.0","signedIn":true,"desktopRunning":false,"current":"beta","profiles":[{"name":"beta","account":"bbbbbbbb-2222","savedAt":"2026-01-01T00:00:00Z","sessions":4}]}"#
  let s = try MultipassJSON.decoder.decode(Snapshot.self, from: Data(json.utf8))
  #expect(s.current == "beta"); #expect(s.profiles[0].sessions == 4); #expect(s.desktopRunning == false)
}
@Test func decodesNullCurrent() throws { /* "current":null, "signedIn":true → s.current == nil, s.signedIn */ }
@Test func decodesUsageEntries() throws {
  let json = #"{"profiles":[{"name":"usagey","fiveHour":{"utilization":42.6,"resetsAt":"2026-10-23T19:45:00Z"},"sevenDay":{"utilization":18}},{"name":"stale","error":"token expired, sign in and re-save"}]}"#
  let r = try MultipassJSON.decoder.decode(UsageReport.self, from: Data(json.utf8))
  #expect(r.profiles[0].fiveHour?.utilization == 42.6); #expect(r.profiles[0].sevenDay?.resetsAt == nil); #expect(r.profiles[1].error == "token expired, sign in and re-save"); #expect(r.profiles[1].fiveHour == nil)
}
@Test func decodesEmptyReport() throws { /* {"profiles":[]} → [] */ }
```

- [ ] **Step 2: Run, expect a build failure (types missing)**

Run: `swift test --package-path app -Xswiftc -plugin-path -Xswiftc "$(xcode-select -p)/usr/lib/swift/host/plugins/testing"`

- [ ] **Step 3: Implement Package.swift and Models.swift**

Three targets: `MultipassCore` (library), `ClaudeMultipass` (executable, depends on core), `MultipassCoreTests` (test target, depends on core). Placeholder `App.swift`: `@main struct Placeholder { static func main() {} }`.

- [ ] **Step 4: Tests pass; wire the gate**

The test command ends with `Test run with 4 tests in 0 suites passed` (a zero-test run means discovery failed). Add the gate lines to `test/check.sh`, raise the commit-gate timeout, run `pnpm check`; expected pass. Note the wall time in the commit message.

- [ ] **Step 5: Rewrite the rails** in each of the eight places the spec lists, with the spec's wording, then `pnpm check` again (prettier covers the docs; `CLAUDE.md` and `.serena/` are prettier-ignored, keep their style by hand).

- [ ] **Step 6: Commit** `Scaffold the menu bar app package and update the rails`.

### Task 7: CLI runner and locator

**Files:**

- Create: `app/Sources/MultipassCore/CLI.swift`, `app/Tests/MultipassCoreTests/CLITests.swift`

**Interfaces:**

- Produces:

```swift
public protocol CommandRunner: Sendable { func run(_ args: [String]) async throws -> Data }
public enum CLIError: Error, Equatable { case refused(String), failed(status: Int32, stderr: String), badJSON(String), timedOut }
public struct CLI: CommandRunner {
  public let executable: URL
  public let timeout: TimeInterval
  public init(executable: URL, timeout: TimeInterval = 120)
  public static let candidates = ["/opt/homebrew/bin/claude-multipass", "/usr/local/bin/claude-multipass"]
  public static func locate(override: String?, isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> URL?
  public func run(_ args: [String]) async throws -> Data      // Process; env PATH = "/opt/homebrew/bin:/usr/local/bin:" + inherited, TERM=dumb; both pipes drained concurrently before exit is awaited; exit 3 → .refused(stderr), other non-zero → .failed; past `timeout` the process is terminated and .timedOut thrown
  public static func parseVersion(_ data: Data) -> String?    // "claude-multipass 0.2.0\n" → "0.2.0"
  public static func isSupported(_ version: String) -> Bool   // >= 0.2.0, numeric compare per component
}
```

- [ ] **Step 1: Write the failing tests**

Write a stub script into a temp dir in the test (`#!/bin/bash`, `case "$1" in --version) echo "claude-multipass 0.2.0";; list) echo '{"version":"0.2.0","signedIn":false,"desktopRunning":false,"current":null,"profiles":[]}';; switch) echo "refused here" >&2; exit 3;; big) head -c 200000 /dev/zero | tr '\0' x;; slow) sleep 5;; color) tput setaf 1; echo boom >&2; exit 1;; *) echo boom >&2; exit 1;; esac`), `chmod +x`.

```swift
@Test func locatePrefersOverride()            // override exists → it; override missing → first existing candidate; none → nil
@Test func runParsesVersion() async throws    // CLI.parseVersion(try await cli.run(["--version"])) == "0.2.0"
@Test func exit3IsRefused() async             // await #expect(throws: CLIError.refused("refused here")) { try await cli.run(["switch","x"]) }
@Test func exit1IsFailed() async              // .failed(status: 1, stderr: "boom")
@Test func stderrHasNoEscapeCodes() async     // "color" arm → stderr == "boom"
@Test func largeOutputDoesNotDeadlock() async throws   // "big" arm → 200000 bytes back
@Test func slowCommandTimesOut() async        // CLI(executable:, timeout: 1), "slow" arm → .timedOut within about 2 s
@Test func versionCompare()                   // isSupported("0.2.0"), !isSupported("0.1.9"), isSupported("1.0.0"), !isSupported("garbage")
```

- [ ] **Step 2: Run, expect build failure**

- [ ] **Step 3: Implement.** `Process` with pipes; read each pipe to EOF on its own task while the process runs; exit awaited through a continuation on `terminationHandler`; a timeout task calls `terminate()` then `kill(pid, SIGKILL)` after 2 s; stderr trimmed of its trailing newline.

- [ ] **Step 4: Tests pass.**

- [ ] **Step 5: Commit** `Add the CLI runner`.

### Task 8: Formatting helpers

**Files:**

- Create: `app/Sources/MultipassCore/Formatting.swift`, `app/Tests/MultipassCoreTests/FormattingTests.swift`

**Interfaces:**

- Produces (all `public static` on `enum Format`, plus one free function):

```swift
static func percent(_ utilization: Double?) -> String            // nil → "–", 42.6 → "42%" (floor, as the CLI prints), 130 → "130%"
static func fill(_ utilization: Double?) -> Double                // 0...1, nil → 0, clamps above 100
static func isDanger(_ utilization: Double?) -> Bool              // floor(utilization) >= 90, so the red bar and the shown number agree
static func countdown(to date: Date?, now: Date) -> String        // nil or past → "–"; < 1h "14m"; < 1d "2h 14m"; else "4d 6h"
static func displayName(_ name: String?, signedIn: Bool) -> String // nil & !signedIn → "signed out"; nil & signedIn → "not saved"; > 16 chars → 15 chars + "…"
public func isValidProfileName(_ s: String) -> Bool                // ^[A-Za-z0-9._-]+$ and not "." or ".."
```

- [ ] **Step 1: Tests** for each line above, one `@Test` per function with the boundary values named (89.9 and 90.0 and 90.9 for danger; 16 and 17 characters; 59 m and 60 m; 23 h 59 m and 24 h; a past date; `"."`, `".."`, `"a b"`, `"work-2"`).

- [ ] **Step 2: Run, expect build failure.**

- [ ] **Step 3: Implement.** Durations by integer division of seconds, no `DateComponentsFormatter` (locale-dependent output).

- [ ] **Step 4: Tests pass.**

- [ ] **Step 5: Commit** `Add menu bar formatting`.

### Task 9: App settings model

**Files:**

- Create: `app/Sources/MultipassCore/AppSettings.swift`, `app/Tests/MultipassCoreTests/AppSettingsTests.swift`

**Interfaces:**

- Produces:

```swift
public enum Module: String, CaseIterable, Codable { case account, sessionBar, weeklyBar, sessionReset, weeklyReset
  public var label: String  // "@", "5H", "7D", "5H↻", "7D↻"
  public var needsUsage: Bool }
public struct AppSettings: Equatable, Codable {
  public var usageEnabled = false
  public var usageIntervalMinutes = 15      // allowed 5, 15, 30, 60; rounds down to the nearest allowed on decode, minimum 5
  public var enabledModules: Set<Module> = [.account]
  public var cliPathOverride: String? = nil
  public static let snapshotInterval: TimeInterval = 30
  public init()
  public init(from decoder: Decoder) throws   // hand-written: decodeIfPresent for every key, defaults otherwise; enabledModules decoded as [String] with unknown names dropped
  public var visibleModules: [Module]         // Module.allCases order, filtered by enabledModules and usageEnabled
}
public final class SettingsStore { public init(defaults: UserDefaults); public func load() -> AppSettings; public func save(_: AppSettings) }   // one JSON String under key "settings" (a String so `defaults write … -string` can seed it)
```

- [ ] **Step 1: Tests:** `visibleModules` drops usage modules when `usageEnabled` is false even if enabled; `{}` decodes to the defaults; `{"cliPathOverride":"/x"}` alone decodes with every other default intact; interval 7 decodes as 5, 10 as 5, 45 as 30, 90 as 60; round trip through a `UserDefaults(suiteName:)` instance; an unknown module string is dropped, not fatal; a `-string` written value loads.

- [ ] **Step 2: Fail. Step 3: Implement. Step 4: Pass.**

- [ ] **Step 5: Commit** `Add the app settings model`.

### Task 10: AppState

**Files:**

- Create: `app/Sources/MultipassCore/AppState.swift`, `app/Tests/MultipassCoreTests/AppStateTests.swift`

**Interfaces:**

- Consumes: `CommandRunner`, `CLIError`, `CLI.parseVersion`, `CLI.isSupported`, `AppSettings`, models, `Format`.
- Produces:

```swift
public enum Phase: Equatable { case idle, switching(String), saving(String) }
public enum CLIStatus: Equatable { case unknown, ready(String), missing, tooOld }
public struct RowError: Equatable { public let name: String; public let message: String; public let refused: Bool }
@MainActor public final class AppState: ObservableObject {
  @Published public private(set) var snapshot: Snapshot?
  @Published public private(set) var usage: [String: UsageEntry] = [:]   // by name
  @Published public private(set) var phase: Phase = .idle
  @Published public private(set) var isRefreshing = false
  @Published public private(set) var isRefreshingUsage = false
  @Published public private(set) var lastError: String?                  // refresh and usage failures
  @Published public private(set) var rowError: RowError?                 // switch and save failures
  @Published public private(set) var cliStatus: CLIStatus = .unknown
  @Published public private(set) var settings: AppSettings
  public var currentUsage: UsageEntry? { usage[snapshot?.current ?? "(signed in)"] }
  public init(makeRunner: @escaping (AppSettings) -> CommandRunner?, store: SettingsStore, now: @escaping () -> Date = Date.init)
  public func apply(_ new: AppSettings) async   // store.save; relocate() if cliPathOverride changed; usage: enable → refreshUsage() once and start the timer; disable → cancel; interval change → restart timer without a fetch; module changes → nothing else
  public func relocate() async        // runner = makeRunner(settings); nil → .missing; run(["--version"]) → .ready(v) when parseVersion succeeds and isSupported, else .tooOld (any thrown error counts as tooOld)
  public func refresh() async         // guarded by isRefreshing; if cliStatus != .ready: relocate() and return; else list --json → snapshot; failure sets lastError and keeps the old snapshot
  public func refreshUsage() async    // only when settings.usageEnabled and cliStatus == .ready; guarded by isRefreshingUsage; usage --json → usage map; failure sets lastError, no retry
  public func refreshAll() async      // refresh() then refreshUsage(); the Refresh buttons call this
  public func switchTo(_ name: String, force: Bool = false) async   // rowError = nil; phase .switching(name) → run → refresh(); .refused → rowError(name, message, refused: true); other errors → rowError(name, message, refused: false)
  public func saveCurrent(as name: String) async                    // same shape with ["save", name] and phase .saving(name)
  public func dismissRowError()
  public func start()                 // Task: relocate, refresh, then the snapshot timer every AppSettings.snapshotInterval, and the usage timer if enabled
  public func stop()
}
```

- [ ] **Step 1: Tests with a `FakeRunner` (records `calls: [[String]]`, scripted responses keyed by first argument, optional throw)**

```swift
@Test func relocateReadyWhenVersionSupported() async      // cliStatus == .ready("0.2.0")
@Test func relocateTooOldWhenVersionFails() async         // runner throws .failed(status: 2, stderr: "…usage…") → .tooOld
@Test func relocateMissingWhenNoRunner() async            // makeRunner returns nil → .missing; refresh() makes no list call
@Test func refreshReprobesWhileNotReady() async           // status .tooOld, then the fake starts answering --version → after refresh(), .ready and a list call followed
@Test func applyPathOverrideRelocates() async             // makeRunner called again with the new override
@Test func refreshStoresSnapshot() async
@Test func refreshFailureKeepsOldSnapshot() async         // second refresh throws → snapshot unchanged, lastError set
@Test func switchSuccessRefreshes() async                 // calls == [["switch","beta"],["list","--json"]]; phase .idle; rowError nil
@Test func switchRefusedSetsRowError() async              // .refused → rowError == RowError(name: "beta", message: m, refused: true), phase .idle
@Test func switchFailureSetsRetryError() async            // .failed → rowError.refused == false
@Test func switchAnywayPassesForce() async                // calls[0] == ["switch","beta","--force"]; rowError nil afterwards
@Test func dismissClearsRowError() async
@Test func saveCurrentRunsSave() async                    // calls[0] == ["save","work"]; then list --json
@Test func usageSkippedWhenDisabled() async               // refreshUsage() makes no call
@Test func applyEnablingUsageFetchesOnce() async          // apply(usageEnabled: true) → exactly one ["usage","--json"] call
@Test func applyModuleToggleDoesNotFetchUsage() async     // apply with a changed enabledModules and usage on → no new usage call
@Test func applyDisablingUsageStopsTimer() async
@Test func refreshAllFetchesUsageWhenEnabled() async      // calls end with ["usage","--json"]
@Test func currentUsageUsesSignedInKey() async            // snapshot.current nil → entry named "(signed in)"
@Test func usageErrorEntryKept() async                    // entry with error present in map; others intact
@Test func usageFailureDoesNotRetry() async               // runner throws once; call count stays 1; lastError set
@Test func refreshDoesNotChangePhase() async              // during refresh(), phase == .idle
```

- [ ] **Step 2: Fail. Step 3: Implement.** Timers as `Task`s with `Task.sleep`, cancelled in `stop()` and by `apply`. No `didSet` on `settings`.

- [ ] **Step 4: Pass. Step 5: Commit** `Add the app state machine`.

### Task 11: App entry and the status item strip

**Files:**

- Replace: `app/Sources/ClaudeMultipass/App.swift`
- Create: `app/Sources/ClaudeMultipass/StatusItemController.swift`, `StripView.swift`, `ModuleView.swift`

**Interfaces:**

- Consumes: `AppState`, `AppSettings`, `Format`, `Module`, `CLI.locate`, `CLI.init(executable:timeout:)`.
- Produces: `@main final class AppDelegate: NSObject, NSApplicationDelegate` with `static func main()` that creates `NSApplication.shared`, sets the delegate and calls `run()` (no SwiftUI `App` scene; `LSUIElement` keeps it out of the Dock). `applicationDidFinishLaunching` builds `AppState(makeRunner: { CLI.locate(override: $0.cliPathOverride).map { CLI(executable: $0) } }, store: SettingsStore(defaults: .standard))`, calls `start()`, and installs `StatusItemController`. `StatusItemController.install(appState:)` creates `NSStatusBar.system.statusItem(withLength: .variableLength)`, hosts `StripView` in an `NSHostingController` with `sizingOptions = [.intrinsicContentSize]`, centres it in the button, mirrors the reported width onto `statusItem.length`, left click toggles the popover (Task 12), right click shows an `NSMenu` with Refresh (`refreshAll()`), Settings…, Quit. `StripView` renders `Image(systemName: "person.crop.circle")` then, while `cliStatus != .ready`, one cell `CLI` over `?`; otherwise one `ModuleView` per `settings.visibleModules` reading `appState.currentUsage`, re-reading state on a 3 s `Timer.publish` tick. `ModuleView` is the two-line cell: label `.system(size: 9, weight: .semibold)`, value `.system(size: 11, design: .monospaced)` or a 28×8 pt capsule with `Format.fill`, red when `Format.isDanger`.

- [ ] **Step 1: Build.** `swift build --package-path app -c release` succeeds.

- [ ] **Step 2: Agent manual check with a throwaway bundle** in the scratchpad directory: `<scratchpad>/cm.app/Contents/MacOS/ClaudeMultipass` plus an `Info.plist` with `CFBundleIdentifier` `net.matherly.claude-multipass`, `CFBundleExecutable` `ClaudeMultipass`, `CFBundlePackageType` `APPL`, `LSUIElement` true. Seed the CLI path: `defaults write net.matherly.claude-multipass settings -string '{"cliPathOverride":"<repo>/bin/claude-multipass"}'`. Copy the real store: `cp -R ~/.config/claude-multipass <scratchpad>/store`, then `open --env CLAUDE_MULTIPASS_DIR=<scratchpad>/store <scratchpad>/cm.app`. Expected: Settings (Task 13) or the right-click menu shows CLI `0.2.0` first; the icon and `@` over the current profile name; the width fits. In the copied store, `CLAUDE_MULTIPASS_DIR=<scratchpad>/store bin/claude-multipass rename <current> a-seventeen-char-nm` and confirm within 3 s that the strip truncates and re-fits; right click shows the three items; Quit works. `defaults delete net.matherly.claude-multipass` afterwards. Record what you saw in the commit message body.

- [ ] **Step 3: Commit** `Add the status item strip`.

### Task 12: Popover

**Files:**

- Create: `app/Sources/ClaudeMultipass/PopoverController.swift`, `PopoverView.swift`, `AccountRow.swift`, `SaveRow.swift`
- Modify: `StatusItemController.swift` (left click → `popover.toggle()`, which calls `appState.refreshAll()` on open)

**Interfaces:**

- Consumes: `AppState` (snapshot, usage, phase, rowError, cliStatus, lastError, `switchTo`, `saveCurrent`, `dismissRowError`, `refreshAll`), `isValidProfileName`.
- Produces: `PopoverController` owning an `NSPopover` (`.transient`, `NSHostingController(rootView: PopoverView(appState:))`). `PopoverView` states, top to bottom: `cliStatus == .unknown` → "Checking the CLI…"; `.missing` → the install hint with the brew command as selectable text; `.tooOld` → the upgrade hint; otherwise header (display name, "Claude Desktop is running" or "not running"), the account list, `SaveRow` when `snapshot.signedIn && snapshot.current == nil`, a `lastError` line when set, footer buttons Refresh, Settings…, Quit (always enabled). `AccountRow`: name, `N sessions`, usage text `5h 42%  7d 12%` when `settings.usageEnabled` (`–` per missing value, the entry's `error` as `.help`), a checkmark on the current one, a `ProgressView` while `phase == .switching(name)`. Tapping a non-current row sets `expanded = name` (and calls `dismissRowError()`) and the row grows inline to the spec's confirm text with Switch and Cancel; Cancel collapses it and calls `dismissRowError()`. When `rowError?.name == name`: `refused` true → the message and "Switch anyway" (`switchTo(name, force: true)`); `refused` false → the message and Retry. Account rows and `SaveRow` are disabled while `phase != .idle`; nothing is disabled by `isRefreshing`. `SaveRow`: a `TextField` and a Save button enabled only when `isValidProfileName(name)` and no profile has that name.

- [ ] **Step 1: Build.** `swift build --package-path app -c release`.

- [ ] **Step 2: Agent manual check** with the Task 11 throwaway bundle and copied store, read-only: open the popover, confirm the current account is marked and session counts match `claude-multipass list`, expand the confirm for another account and Cancel, confirm the Save row is absent while a saved account is signed in. Stop there.

- [ ] **Step 3: Maintainer check (not an agent):** against the real store, press Switch for another account and watch the spinner, the Desktop relaunch, and the popover's new current mark.

- [ ] **Step 4: Commit** `Add the account popover`.

### Task 13: Settings window and launch at login

**Files:**

- Create: `app/Sources/ClaudeMultipass/SettingsWindow.swift`, `SettingsView.swift`
- Modify: `StatusItemController.swift` (Settings… opens the window), `PopoverView.swift` (footer button)

**Interfaces:**

- Produces: `SettingsWindowController` (one `NSWindow` with `NSHostingController`, `isReleasedWhenClosed = false`, `show()` activates the app and brings it front). `SettingsView` keeps a local `@State var draft: AppSettings` seeded from `appState.settings` and calls `Task { await appState.apply(draft) }` on every change. Sections per the spec: Usage (toggle whose label carries the caution text and a `Link` to `https://github.com/jrmatherly/claude-multipass/blob/main/docs/claude-multipass.md#usage-headroom`, interval `Picker` over `[5, 15, 30, 60]`), Menu bar (one `Toggle` per `Module.allCases`, usage modules disabled while usage is off), General (`Toggle("Launch at login")` bound to `SMAppService.mainApp.status == .enabled`, registering or unregistering on change and showing the error text on failure; CLI path `TextField` bound to `draft.cliPathOverride`, with `cliStatus` rendered beside it as the version, "not found", "too old" or "checking…").

- [ ] **Step 1: Build. Step 2: Agent manual check:** open Settings, confirm the CLI version reads `0.2.0`, toggle a module and watch the strip change within 3 s, type a wrong CLI path and see "not found", restore it and see the version. Stop there.

- [ ] **Step 3: Maintainer check (not an agent):** enable usage, accept the one Keychain prompt with Always Allow, see the bars; turn Launch at login on, check System Settings > General > Login Items, turn it off again before deleting the throwaway bundle.

- [ ] **Step 4: Commit** `Add the settings window`.

### Task 14: Build, sign and package scripts; docs

**Files:**

- Create: `scripts/build-app.sh`, `scripts/sign-mac-app.sh` (copied from `~/dev/ai-kb/scripts/sign-mac-app.sh`, shebang `#!/bin/bash`, `pnpm format` applied, `${APPLE_API_KEY_ID:-}` and the other two reads made `:-`, plus `MACOS_SIGN_ENTITLEMENTS`), `app/Info.plist.in`, `app/ClaudeMultipass.entitlements`
- Modify: `test/check.sh` (`scripts/*.sh` in `shell_scripts`), `.claude/hooks/lint-edited.sh` line 55 (add `scripts` to the gate-path regex) and `.claude/hooks/test-lint-edited.sh` (a case that a `scripts/*.sh` warning exits 2), `.claude/rules/testing.md` (the hook's covered paths)
- Modify: `README.md` (new "Menu bar app" section after Raycast), `docs/claude-multipass.md` (new "Menu bar app" section with the refresh cadence table), `CHANGELOG.md`

**Interfaces:**

- Produces: `scripts/build-app.sh [--dmg]`, run from any directory (it `cd`s to the repo root first): `version=$(jq -r .version package.json)`, `swift build --package-path app -c release`, assembles `dist/Claude Multipass.app` with `Contents/MacOS/ClaudeMultipass` and `Contents/Info.plist` from the template (`CFBundleIdentifier`, `CFBundleName`, `CFBundleExecutable`, `CFBundlePackageType` `APPL`, `CFBundleShortVersionString` and `CFBundleVersion` from `@VERSION@`, `LSMinimumSystemVersion` `14.0`, `LSUIElement`, `NSAppleEventsUsageDescription` "Claude Multipass asks Claude Desktop to quit before switching accounts."), exports `MACOS_SIGN_ENTITLEMENTS=$PWD/app/ClaudeMultipass.entitlements` and runs `scripts/sign-mac-app.sh sign-app "dist/Claude Multipass.app"`; with `--dmg` builds `dist/claude-multipass-app_<version>_arm64.dmg` (`hdiutil create -volname "Claude Multipass" -srcfolder <staging with /Applications symlink> -format UDZO`), runs `sign-mac-app.sh sign-dmg <dmg>` and writes `<dmg>.sha256`. The entitlements file holds `com.apple.security.automation.apple-events` true. In the copied sign script, `sign-app` adds `--entitlements "$MACOS_SIGN_ENTITLEMENTS"` when `${MACOS_SIGN_ENTITLEMENTS:-}` is set.

- [ ] **Step 1: Write the scripts,** run `pnpm format`, then `bash -n`, `shellcheck --severity=warning` (the repo's `.shellcheckrc` applies) and `prettier --check` on both; update the hook regex, its self-check and `testing.md`.

- [ ] **Step 2: Verify locally:** `bash scripts/build-app.sh` prints the identity line from the sign script; `codesign --verify --deep --strict "dist/Claude Multipass.app"` exits 0; `codesign -d --entitlements - "dist/Claude Multipass.app"` lists the apple-events key; `open "dist/Claude Multipass.app"` shows the strip, then quit it from the menu. `spctl -a -vv "dist/Claude Multipass.app"` is rejected until notarized; note that, it is correct at this stage.

- [ ] **Step 3: Maintainer check (not an agent):** one switch from the signed `dist` app with `log stream --predicate 'process == "osascript"'` open; the quit must be the graceful one (no 8 s wait before Desktop closes). If it is not, the entitlement did not take and Task 14 is not done.

- [ ] **Step 4: Docs.** README "Menu bar app": what it shows, the install line (cask, from Task 15), the usage opt-in caution, the one-time Keychain prompt, the first-launch-needs-network note. `docs/claude-multipass.md`: same plus the refresh cadence table from the spec. CHANGELOG line.

- [ ] **Step 5: `pnpm check` passes. Commit** `Add the app build and signing scripts` (scripts, templates, gate, hooks) and `Document the menu bar app` (docs), two commits.

### Task 15: Release workflow, cask and release skill

**Files:**

- Create: `.github/workflows/release.yml`
- Modify: `.claude/skills/release/SKILL.md`
- Create in the tap checkout `~/dev/homebrew-tap/Casks/claude-multipass-app.rb` (`mkdir Casks`; committed by the maintainer at release time with the real `sha256`)

**Interfaces:**

- Produces: `release.yml` on `push: tags: ['v*']`, `runs-on: macos-latest`, `permissions: contents: write`. Steps mirror `check.yml` (checkout pinned by SHA, `pnpm/action-setup`, `actions/setup-node` with `node-version-file: .nvmrc`, `brew install shellcheck jq`, `pnpm install --frozen-lockfile`, `pnpm check`), then the ai-kb certificate import step verbatim (secrets `MACOS_CERT_P12`, `MACOS_CERT_PASSWORD`, sets `MACOS_SIGN_REQUIRED=1`), `bash scripts/build-app.sh --dmg` with `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID`, `APPLE_API_KEY_P8` from secrets, then `gh release create "$GITHUB_REF_NAME" dist/*.dmg dist/*.sha256 --generate-notes` with `GH_TOKEN: ${{ github.token }}` (`gh release upload --clobber` when the release already exists). The cask: `cask "claude-multipass-app"`, `version`, `sha256`, `url "https://github.com/jrmatherly/claude-multipass/releases/download/v#{version}/claude-multipass-app_#{version}_arm64.dmg"`, `name "Claude Multipass"`, `desc`, `homepage`, `depends_on formula: "jrmatherly/tap/claude-multipass"`, `depends_on arch: :arm64`, `depends_on macos: ">= :sonoma"`, `app "Claude Multipass.app"`, `zap trash: "~/Library/Preferences/net.matherly.claude-multipass.plist"`.

- [ ] **Step 1: Write `release.yml`;** run `actionlint` (installed, measured) and `prettier --check`.

- [ ] **Step 2: Write the cask and audit it.** `brew audit` refuses a bare path, so copy the file into `$(brew --repository jrmatherly/tap)/Casks/` with `sha256 :no_check` and run `brew audit --cask --strict jrmatherly/tap/claude-multipass-app`; remove the copy afterwards. Expected: no error about the token; a token clash error means renaming to `claude-multipass-menubar` and recording why in the release skill. If `--strict` rejects `:no_check`, run the audit again after the first release with the real digest and say so in the skill.

- [ ] **Step 3: Update the release skill:** the five secrets the workflow needs (copied from the ai-kb repository settings, listed by name); push the tag, wait for `release.yml`; bump the formula first (existing steps), then the cask with the DMG `sha256` from the release asset; `brew audit` both; `brew install --cask jrmatherly/tap/claude-multipass-app`; verify `claude-multipass --version` and the app in the menu bar.

- [ ] **Step 4: `pnpm check` passes. Commit** `Add the release workflow and cask steps`.

- [ ] **Step 5: Maintainer-only release checklist (not run by an agent):** add the five secrets, run `/release 0.2.0`, confirm the DMG is notarized (`spctl -a -vv -t open --context context:primary-signature <dmg>` says accepted), install the cask on this Mac, verify the app and a real switch from the popover.

---

## Self-review notes

- Spec coverage: every spec section maps to a task (CLI changes 1 to 5, layout, data shape and rails 6 to 10, strip 11, popover 12, settings 13, distribution 14 to 15). Dropped items (atomic writes, last-profile refusal, reorder, icon, Sparkle, `add`, Intel, app stapling) are named in the spec's Out of scope or Distribution.
- Signatures: `CommandRunner`, `CLIError` (with `timedOut`), `CLIStatus` (with `unknown`), `RowError`, `AppSettings.visibleModules`, `Phase`, `AppState.apply(_:)`, `switchTo(_:force:)`, `dismissRowError()`, `refreshAll()`, `currentUsage`, `isValidProfileName`, `CLI.init(executable:timeout:)` are spelled the same in Tasks 7 to 13.
- Review focus items each name their pinning task.
- Agent manual checks in Tasks 11 to 14 run against a copied store and stop at reading and cancelling; Switch, usage enable, Launch at login and the Apple-events check are maintainer steps, per `CLAUDE.md` and the spec's last section.
