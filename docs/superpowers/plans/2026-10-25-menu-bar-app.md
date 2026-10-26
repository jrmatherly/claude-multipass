# Claude Multipass menu bar app implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A signed, notarized macOS menu bar app that shows the signed-in saved account, switches accounts in two clicks, and optionally shows per-account usage, driving the existing `claude-multipass` script.

**Architecture:** The bash script stays the only code that touches Desktop's files; it gains `--json`, `--version`, a refusal exit code and `doctor`. A Swift package in `app/` has an AppKit-free core (models, formatting, CLI runner, state machine, all unit tested with Swift Testing) and a thin AppKit/SwiftUI shell (`NSStatusItem` hosting a SwiftUI strip, a popover, a settings window). `scripts/build-app.sh` assembles and signs the bundle; `release.yml` notarizes and publishes a DMG; the tap gets a cask.

**Tech Stack:** bash 3.2, jq, Swift 6.4 toolchain via Command Line Tools (no Xcode), SwiftPM, Swift Testing, SwiftUI + AppKit, `codesign`/`notarytool`/`stapler`, Homebrew cask.

**Spec:** `docs/superpowers/specs/2026-10-25-menu-bar-app.md`

## Global constraints

- Script target is `/bin/bash` 3.2: no associative arrays, no `mapfile`, build strings with nested escaped quotes in a variable first. BSD `stat -f %Lp`, `date -r`.
- Every new command, option or refusal gets a case in `test/claude-multipass.sh`, asserting what the user observes. Hooks changed get their `test-<hook>.sh` updated.
- A behaviour change edits `README.md` or `docs/` in the same commit; the header tldr block and `usage()` stay accurate.
- `pnpm check` must pass before every commit (the commit-gate hook runs it). Commit subjects: short, imperative, sentence case, no prefix. Prose: no em-dashes, short sentences, sentence-case headings.
- The script never reads the Keychain outside `usage`, never switches without a user action, never sets `CLAUDE_CONFIG_DIR`.
- Swift package: tools version 5.9, `platforms: [.macOS(.v14)]`, `swiftLanguageVersions: [.v5]`. `MultipassCore` imports Foundation only. Tests use `import Testing`, never XCTest (unavailable under the Command Line Tools).
- Bundle identifier `net.matherly.claude-multipass`, product name `Claude Multipass`, `LSUIElement` true, `LSMinimumSystemVersion` 14.0.
- The app runs `switch` only from the confirm sheet's Switch button or the "Switch anyway" button. Usage polling only when `usageEnabled` is true, interval at least 5 minutes.
- CLI JSON shapes are exactly the ones in the spec (key names, `null` for a missing `current`, `error` string instead of windows).

## Review focus

1. CLI missing, not executable, or older than 0.2.0: the popover must show the install or upgrade hint, never a crash or an empty strip. Pinned in Task 9 (`locate`, `tooOld`) and Task 12 (popover states).
2. `switch` refused because the signed-in login is unsaved: exit 3 must become the "Switch anyway" path, and `--force` must appear in the rerun's arguments. Pinned in Task 2 (exit code) and Task 10 (`pendingForce`).
3. Usage failure for one profile (cannot decrypt, 401, 429, offline): render `–`, keep the other profiles, no retry before the next tick. Pinned in Task 4 (`error` entries) and Task 10 (no immediate retry).
4. A profile name of 17 or more characters, or `not saved`: the strip truncates and the status item width follows the content. Pinned in Task 8 (`displayName`) and the manual check in Task 14.
5. `resetsAt` in the past or missing: countdown shows `–`, never a negative duration. Pinned in Task 8.

---

### Task 1: `--version` and the version constant

**Files:**

- Modify: `bin/claude-multipass` (header tldr block; `usage()` Options; `main` option loop near line 605)
- Modify: `package.json` (`version` stays 0.1.0 until release; the constant is the script's own)
- Modify: `test/claude-multipass.sh`
- Modify: `.claude/skills/release/SKILL.md` step 2
- Modify: `docs/claude-multipass.md` Commands table

**Interfaces:**

- Produces: `claude-multipass --version` prints `claude-multipass 0.2.0` and exits 0. A top-level `version=0.2.0` variable right after `set -euo pipefail`.

- [ ] **Step 1: Write the failing test**

Add to `test/claude-multipass.sh` beside the help case:

```bash
check "version" "claude-multipass 0.2.0" "$(cda --version)"
check "version exits 0" 0 "$(exit_code cda --version)"
```

- [ ] **Step 2: Run it, expect failure**

Run: `bash test/claude-multipass.sh` Expected: exit 1, `version` named with `Unknown option: --version`.

- [ ] **Step 3: Implement**

`version=0.2.0` after `set -euo pipefail`. In the option loop, `--version) echo "claude-multipass $version"; return 0 ;;` placed before the `-*)` arm. Add `--version` to `usage()` Options and a tldr entry (`- Print the version:` / `` `claude-multipass --version` ``). In `docs/claude-multipass.md` add `--version` to the options line. In the release skill step 2, also bump `version=` in `bin/claude-multipass`.

- [ ] **Step 4: Run the gate**

Run: `pnpm check` Expected: exit 0, `ok: version` printed by the self-check.

- [ ] **Step 5: Commit**

```bash
git add bin/claude-multipass test/claude-multipass.sh docs/claude-multipass.md .claude/skills/release/SKILL.md
git commit -m "Add --version"
```

### Task 2: exit code 3 for refusals `--force` lifts

**Files:**

- Modify: `bin/claude-multipass` (`fail` at ~120; `profile_save` ~320; `main` sync ~651 and switch ~686)
- Modify: `test/claude-multipass.sh` (the three existing refusal cases)
- Modify: `docs/claude-multipass.md` Safety rails; `.claude/rules/safety-and-terms.md` (one line under "Rules a change must keep")

**Interfaces:**

- Produces: `refuse() { ... exit 3; }` with the same output style as `fail`. The three refusals (`save` over another account, `switch` from an unsaved login, `sync` while Desktop runs) exit 3; everything else keeps exit 1.

- [ ] **Step 1: Change the three refusal assertions**

Find the existing cases that assert exit `1` for `sync` while running, `switch` from unsaved, and `save --force` refusal; change the expected code to `3`. Add one assertion that a non-refusal failure still exits 1:

```bash
check "unknown profile exits 1" 1 "$(exit_code cda switch nobody)"
```

- [ ] **Step 2: Run, expect the three cases to fail with actual `1`**

Run: `bash test/claude-multipass.sh`

- [ ] **Step 3: Implement `refuse`**

Define `refuse()` next to `fail()`: same message to stderr, `exit 3`. Replace `fail` with `refuse` at the three sites. Document in `--help` Options under `--force`: "a refusal exits 3". Add to `docs/claude-multipass.md` Safety rails and to `safety-and-terms.md`: "Refusals that `--force` lifts exit 3, so a caller can offer the override; other failures exit 1."

- [ ] **Step 4: Gate**

Run: `pnpm check`. Expected: pass.

- [ ] **Step 5: Commit**

```bash
git commit -am "Exit 3 for the refusals --force lifts"
```

### Task 3: `list --json`

**Files:**

- Modify: `bin/claude-multipass` (`list_profiles` ~507; option loop; `desktop_running` ~239)
- Modify: `test/claude-multipass.sh`
- Modify: `docs/claude-multipass.md`, `README.md` Commands table

**Interfaces:**

- Produces: `list --json` prints one JSON object per the spec: `version`, `signedIn` (bool), `desktopRunning` (bool), `current` (string or null), `profiles` (array of `{name, account, savedAt, sessions}` with `sessions` a number). `--json` is parsed into a `json=1` variable; `[[ -z $json || $cmd == list || $cmd == usage ]] || fail "--json applies to list and usage"`.

- [ ] **Step 1: Write the failing tests**

In the fixture with two profiles (`personal` signed in, `work` saved) and the `pgrep` stub exiting 1:

```bash
out=$(cda list --json)
check "list --json current" personal "$(jq -r .current <<< "$out")"
check "list --json signedIn" true "$(jq -r .signedIn <<< "$out")"
check "list --json desktopRunning" false "$(jq -r .desktopRunning <<< "$out")"
check "list --json names" "personal work" "$(jq -r '[.profiles[].name] | join(" ")' <<< "$out")"
check "list --json sessions is a number" number "$(jq -r '.profiles[0].sessions | type' <<< "$out")"
check "list --json version" 0.2.0 "$(jq -r .version <<< "$out")"
check "--json rejected elsewhere" 1 "$(exit_code cda current --json)"
```

Add, in the "not saved" fixture state already used by the `current` case: `check "list --json current null when not saved" null "$(cda list --json | jq -r .current)"`.

- [ ] **Step 2: Run, expect `Unknown option: --json`**

- [ ] **Step 3: Implement**

`list_json()` builds each profile object with `jq -n --arg name --arg account --arg savedAt --argjson sessions` and collects them with `jq -s`, then wraps: `jq -n --arg v "$version" --argjson signedIn --argjson running --arg current "$(active_profile)" --slurpfile p ... '{version:$v, signedIn:$signedIn, desktopRunning:$running, current:(if $current=="" then null else $current end), profiles:$p}'`. `signedIn` from `signed_in`, `running` from `desktop_running`. The `list` arm calls `list_json` when `json=1`. Document `--json` in `usage()`, the tldr block, README and docs.

- [ ] **Step 4: Gate.** `pnpm check` passes.

- [ ] **Step 5: Commit** `Add list --json`.

### Task 4: `usage --json`

**Files:**

- Modify: `bin/claude-multipass` (`usage_text` ~438, `usage_jq` ~432, `usage_report` ~466)
- Modify: `test/claude-multipass.sh` (the existing `usage` case, which encrypts a fixture token and stubs `curl` and `security`)
- Modify: `docs/claude-multipass.md` Usage headroom section

**Interfaces:**

- Produces: `usage --json` prints `{"profiles":[...]}` per the spec. Each entry has `name` and either `fiveHour` and `sevenDay` objects (`utilization` number, `resetsAt` ISO string when present) or `error` string. The `(signed in)` entry keeps that name. Exit code and the token-never-in-argv property are unchanged.

- [ ] **Step 1: Write the failing tests**

With the fixture body the `curl` stub returns (it already carries `five_hour` and `seven_day`):

```bash
out=$(cda usage --json)
check "usage --json name" personal "$(jq -r '.profiles[0].name' <<< "$out")"
check "usage --json 5h utilization" "$EXPECTED_PCT" "$(jq -r '.profiles[0].fiveHour.utilization' <<< "$out")"
check "usage --json resetsAt" "$EXPECTED_RESET" "$(jq -r '.profiles[0].fiveHour.resetsAt' <<< "$out")"
check_true "usage --json no token in curl argv" ! grep -q "$token" "$tmp/curl-args"
```

Take `EXPECTED_PCT` and `EXPECTED_RESET` from the fixture body in the existing case. Add a profile whose config cannot decrypt (a different key) and assert `check "usage --json error entry" "cannot decrypt" "$(jq -r '.profiles[] | select(.name=="broken").error' <<< "$out")"`.

- [ ] **Step 2: Run, expect failure**

- [ ] **Step 3: Implement**

Split `usage_text` into `usage_fetch` (prints the raw response body on success, or `error: <reason>` for cannot decrypt, HTTP 401/403/429, curl failure) and two formatters: `usage_line` (today's text, built from `usage_jq`) and `usage_object` (`jq --arg name '{name:$name, fiveHour:{utilization:.five_hour.utilization, resetsAt:.five_hour.resets_at} | with_entries(select(.value!=null)), sevenDay:...}'`, or `{name, error}`). `usage_report` writes one object per temp file when `json=1` and finishes with `jq -s '{profiles: .}' "$out"/*`. Keep the token on `curl`'s stdin.

- [ ] **Step 4: Gate.** `pnpm check` passes; the existing text `usage` assertions still pass.

- [ ] **Step 5: Commit** `Add usage --json`.

### Task 5: `doctor`

**Files:**

- Modify: `bin/claude-multipass` (new `doctor_report`; `main` dispatch, in the group that runs before `migrate_store` is needed)
- Modify: `test/claude-multipass.sh`
- Modify: `docs/claude-multipass.md` "When something is off"; `README.md` Commands table; header tldr

**Interfaces:**

- Produces: `doctor` prints `ok: …`, `warn: …`, `fail: …` lines (one check per line, in the spec's order) and exits 1 when any `fail:` was printed, else 0. It calls neither `security` nor `curl`.

- [ ] **Step 1: Write the failing tests**

```bash
check "doctor healthy" 0 "$(exit_code cda doctor)"
check_true "doctor reports jq" grep -q '^ok: jq' <<< "$(cda doctor)"
# break a profile: empty tokenCacheV2
jq '.["oauth:tokenCacheV2"]=""' "$p/work/config.json" > "$p/work/c" && mv "$p/work/c" "$p/work/config.json"
check "doctor fails on empty token" 1 "$(exit_code cda doctor)"
check_true "doctor names the profile" grep -q '^fail: work' <<< "$(cda doctor || true)"
check_true "doctor never calls security" ! grep -q security "$tmp/calls"
```

Make the `security` stub append to `$tmp/calls` for this case if it does not already.

- [ ] **Step 2: Run, expect the usage page (unknown command exits 2)**

- [ ] **Step 3: Implement `doctor_report`**

One function, a `status=0` variable set to 1 by each `fail:` line, `return $status`. Checks in spec order: config present; `jq`; `fzf`/`python3`/`openssl`/`curl` as `warn: <tool> missing (<what it enables>)`; store mode `stat -f %Lp` is 700 and profile files 600 (warn); per profile `meta.json` and `config.json` present and `signed_in`-style non-empty token (fail); `ls -1d "$backups"/login-*` count; `desktop_running`; legacy store path exists (warn). Dispatch: `doctor` takes no name, runs before the `[[ -f $config ]]` check so it can report a missing config as `fail:`.

- [ ] **Step 4: Gate.** `pnpm check` passes.

- [ ] **Step 5: Commit** `Add doctor`.

### Task 6: Swift package scaffold and the gate

**Files:**

- Create: `app/Package.swift`, `app/Sources/MultipassCore/Models.swift`, `app/Sources/ClaudeMultipass/App.swift` (placeholder `@main` that exits), `app/Tests/MultipassCoreTests/ModelsTests.swift`, `app/.gitignore` (`.build/`)
- Modify: `test/check.sh` (add `scripts/*.sh` to `shell_scripts` once Task 14 creates them; add the swift lines now), `.prettierignore` (add `app/.build/`), `.gitignore` (`dist/`)
- Modify: `CLAUDE.md` Commands and Architecture tree (an `app/` line and the two swift commands)

**Interfaces:**

- Produces: `MultipassCore` with `Snapshot`, `Profile`, `UsageReport`, `UsageEntry`, `Window` exactly as the spec declares them, `Decodable` with a `JSONDecoder` factory `MultipassJSON.decoder` (ISO 8601 dates, including fractional seconds absent). `Profile.id == name`, `UsageEntry.id == name`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func decodesSnapshot() throws {
  let json = #"{"version":"0.2.0","signedIn":true,"desktopRunning":false,"current":"work","profiles":[{"name":"work","account":"abc","savedAt":"2026-10-25T01:02:03Z","sessions":12}]}"#
  let s = try MultipassJSON.decoder.decode(Snapshot.self, from: Data(json.utf8))
  #expect(s.current == "work"); #expect(s.profiles[0].sessions == 12); #expect(s.desktopRunning == false)
}
@Test func decodesNullCurrent() throws { /* "current":null → s.current == nil, signedIn true */ }
@Test func decodesUsageErrorEntry() throws {
  let json = #"{"profiles":[{"name":"work","fiveHour":{"utilization":42,"resetsAt":"2026-10-25T12:00:00Z"},"sevenDay":{"utilization":12}},{"name":"personal","error":"cannot decrypt"}]}"#
  let r = try MultipassJSON.decoder.decode(UsageReport.self, from: Data(json.utf8))
  #expect(r.profiles[0].fiveHour?.utilization == 42); #expect(r.profiles[0].sevenDay?.resetsAt == nil); #expect(r.profiles[1].error == "cannot decrypt")
}
```

- [ ] **Step 2: Run, expect a build failure (types missing)**

Run: `swift test --package-path app`

- [ ] **Step 3: Implement Package.swift and Models.swift**

Three targets: `MultipassCore` (library), `ClaudeMultipass` (executable, depends on core), `MultipassCoreTests` (test target, depends on core). Models per the spec. Placeholder `App.swift`: `@main struct Placeholder { static func main() {} }`.

- [ ] **Step 4: Tests pass; wire the gate**

`swift test --package-path app` passes. In `test/check.sh` after the hook self-checks add `swift build --package-path app -c release > /dev/null` and `swift test --package-path app > /dev/null`. Run `pnpm check`; expected pass, under two minutes cold.

- [ ] **Step 5: Commit** `Scaffold the menu bar app package`.

### Task 7: CLI runner and locator

**Files:**

- Create: `app/Sources/MultipassCore/CLI.swift`, `app/Tests/MultipassCoreTests/CLITests.swift`

**Interfaces:**

- Produces:

```swift
public protocol CommandRunner: Sendable { func run(_ args: [String]) async throws -> Data }
public enum CLIError: Error, Equatable { case notFound, tooOld(String), refused(String), failed(status: Int32, stderr: String), badJSON(String) }
public struct CLI: CommandRunner {
  public let executable: URL
  public static let candidates = ["/opt/homebrew/bin/claude-multipass", "/usr/local/bin/claude-multipass"]
  public static func locate(override: String?, fileExists: (String) -> Bool = FileManager.default.isExecutableFile) -> URL?
  public func run(_ args: [String]) async throws -> Data      // Process, PATH prefixed with /opt/homebrew/bin:/usr/local/bin; exit 3 → .refused(stderr), other non-zero → .failed
  public func version() async throws -> String                 // parses "claude-multipass X.Y.Z"
  public static func isSupported(_ version: String) -> Bool    // >= 0.2.0, numeric compare
}
```

- [ ] **Step 1: Write the failing tests**

Write a stub script into a temp dir in the test (`#!/bin/bash`, `case "$1" in --version) echo "claude-multipass 0.2.0";; list) echo '{"version":"0.2.0","signedIn":false,"desktopRunning":false,"current":null,"profiles":[]}';; switch) echo "refused here" >&2; exit 3;; *) echo boom >&2; exit 1;; esac`), `chmod +x`.

```swift
@Test func locatePrefersOverride() { /* override path exists → that URL; override missing → first existing candidate; none → nil */ }
@Test func runParsesVersion() async throws { #expect(try await cli.version() == "0.2.0") }
@Test func exit3IsRefused() async { await #expect(throws: CLIError.refused("refused here")) { try await cli.run(["switch","x"]) } }
@Test func exit1IsFailed() async { /* .failed(status: 1, stderr: "boom") */ }
@Test func versionCompare() { #expect(CLI.isSupported("0.2.0")); #expect(!CLI.isSupported("0.1.9")); #expect(CLI.isSupported("1.0.0")) }
```

- [ ] **Step 2: Run, expect build failure**

- [ ] **Step 3: Implement.** `Process` with pipes, `waitUntilExit` on a background continuation, stderr trimmed of its trailing newline.

- [ ] **Step 4: `swift test --package-path app` passes.**

- [ ] **Step 5: Commit** `Add the CLI runner`.

### Task 8: Formatting helpers

**Files:**

- Create: `app/Sources/MultipassCore/Formatting.swift`, `app/Tests/MultipassCoreTests/FormattingTests.swift`

**Interfaces:**

- Produces (all `public static` on `enum Format`):

```swift
static func percent(_ utilization: Double?) -> String            // nil → "–", 41.6 → "42%", 130 → "130%"
static func fill(_ utilization: Double?) -> Double                // 0...1, nil → 0, clamps above 100
static func isDanger(_ utilization: Double?) -> Bool              // > 90
static func countdown(to date: Date?, now: Date) -> String        // nil or past → "–"; < 1h "14m"; < 1d "2h 14m"; else "4d 6h"
static func displayName(_ name: String?, signedIn: Bool) -> String // nil & !signedIn → "signed out"; nil & signedIn → "not saved"; > 16 chars → 15 chars + "…"
```

- [ ] **Step 1: Tests** for each line above, one `@Test` per function with the boundary values named (90 and 90.1, 16 and 17 characters, 59 m and 60 m, 23 h 59 m and 24 h, a past date).

- [ ] **Step 2: Run, expect build failure.**

- [ ] **Step 3: Implement.** Durations by integer division of seconds, no `DateComponentsFormatter` (its output varies by locale).

- [ ] **Step 4: Tests pass.**

- [ ] **Step 5: Commit** `Add menu bar formatting`.

### Task 9: Settings model

**Files:**

- Create: `app/Sources/MultipassCore/Settings.swift`, `app/Tests/MultipassCoreTests/SettingsTests.swift`

**Interfaces:**

- Produces:

```swift
public enum Module: String, CaseIterable, Codable { case account, sessionBar, weeklyBar, sessionReset, weeklyReset
  public var label: String  // "@", "5H", "7D", "5H↻", "7D↻"
  public var needsUsage: Bool }
public struct Settings: Equatable, Codable {
  public var usageEnabled = false
  public var usageIntervalMinutes = 15      // allowed: 5, 15, 30, 60; clamped on decode
  public var enabledModules: Set<Module> = [.account]
  public var cliPathOverride: String? = nil
  public static let snapshotInterval: TimeInterval = 30
  public static let countdownInterval: TimeInterval = 60
  public var visibleModules: [Module]       // Module.allCases order, filtered by enabledModules and usageEnabled
}
public final class SettingsStore { init(defaults: UserDefaults); func load() -> Settings; func save(_:) }   // one JSON blob under key "settings"
```

- [ ] **Step 1: Tests:** `visibleModules` drops usage modules when `usageEnabled` is false even if enabled; interval 7 decodes as 5 and 90 as 60; round trip through a `UserDefaults(suiteName:)` instance.

- [ ] **Step 2: Fail. Step 3: Implement. Step 4: Pass.**

- [ ] **Step 5: Commit** `Add app settings model`.

### Task 10: AppState

**Files:**

- Create: `app/Sources/MultipassCore/AppState.swift`, `app/Tests/MultipassCoreTests/AppStateTests.swift`

**Interfaces:**

- Consumes: `CommandRunner`, `CLIError`, `Settings`, models, `Format`.
- Produces:

```swift
public enum Phase: Equatable { case idle, refreshing, switching(String), saving(String) }
@MainActor public final class AppState: ObservableObject {
  @Published public private(set) var snapshot: Snapshot?
  @Published public private(set) var usage: [String: UsageEntry] = [:]   // by name
  @Published public private(set) var phase: Phase = .idle
  @Published public private(set) var lastError: String?
  @Published public private(set) var pendingForce: String?               // profile a refusal blocked; nil otherwise
  @Published public var settings: Settings { didSet { store.save(settings); rescheduleUsage() } }
  public private(set) var cliStatus: CLIStatus                            // .ready(version) | .missing | .tooOld(String)
  public init(runner: CommandRunner?, store: SettingsStore, now: @escaping () -> Date = Date.init)
  public func refresh() async                 // list --json → snapshot; sets lastError on failure, keeps the old snapshot
  public func refreshUsage() async            // only when settings.usageEnabled; usage --json → usage map
  public func switchTo(_ name: String, force: Bool = false) async   // phase .switching(name) → run → refresh(); on .refused sets pendingForce = name
  public func saveCurrent(as name: String) async
  public func start()                         // timers: snapshot every Settings.snapshotInterval; usage per settings; countdown tick
  public func stop()
}
```

- [ ] **Step 1: Tests with a `FakeRunner` (records `calls: [[String]]`, scripted responses or throws)**

```swift
@Test func refreshStoresSnapshot() async
@Test func switchSuccessRefreshes() async           // calls == [["switch","work"],["list","--json"]]; phase back to .idle
@Test func switchRefusedSetsPendingForce() async    // runner throws .refused → pendingForce == "work", phase .idle, lastError == message
@Test func switchAnywayPassesForce() async          // switchTo("work", force: true) → calls[0] == ["switch","work","--force"], pendingForce nil
@Test func usageSkippedWhenDisabled() async         // refreshUsage() makes no call
@Test func usageErrorEntryKept() async              // entry with error present in map; other entries intact
@Test func usageFailureDoesNotRetry() async         // runner throws once; after refreshUsage() call count is 1, lastError set
@Test func missingRunnerIsMissingStatus()           // runner nil → cliStatus == .missing, refresh() makes no call
```

- [ ] **Step 2: Fail. Step 3: Implement.** Timers as `Task`s with `Task.sleep`, cancelled in `stop()` and in `rescheduleUsage()`. `refresh()` and `refreshUsage()` are reentrancy-guarded by `phase`.

- [ ] **Step 4: Pass. Step 5: Commit** `Add the app state machine`.

### Task 11: App entry and the status item strip

**Files:**

- Replace: `app/Sources/ClaudeMultipass/App.swift`
- Create: `app/Sources/ClaudeMultipass/StatusItemController.swift`, `StripView.swift`, `ModuleView.swift`

**Interfaces:**

- Consumes: `AppState`, `Settings`, `Format`, `Module`.
- Produces: `@main struct ClaudeMultipassApp: App` with an `NSApplicationDelegateAdaptor` that sets `.accessory` policy, builds `AppState(runner: CLI.locate(...).map(CLI.init), store: SettingsStore(defaults: .standard))`, calls `start()`, and installs `StatusItemController`. `StatusItemController.install(appState:)` creates `NSStatusBar.system.statusItem(withLength: .variableLength)`, hosts `StripView` in an `NSHostingController` with `sizingOptions = [.intrinsicContentSize]`, centres it in the button, mirrors the reported width onto `statusItem.length`, left click toggles the popover (Task 12), right click shows an `NSMenu` with Refresh, Settings…, Quit. `StripView` renders `Image(systemName: "person.crop.circle")` then one `ModuleView` per `settings.visibleModules`, re-reads state on a 3 s `Timer.publish` tick (the pattern CCSwitcher documents for status item hosting). `ModuleView` is the two-line cell: label `.system(size: 9, weight: .semibold)`, value `.system(size: 11, design: .monospaced)` or a 28×8 pt capsule with `Format.fill`, red when `Format.isDanger`.

- [ ] **Step 1: Build the app bundle (Task 14's script does not exist yet): `swift build --package-path app -c release` succeeds.**

- [ ] **Step 2: Launch for a manual check** with a throwaway bundle: copy the binary into `/tmp/cm.app/Contents/MacOS/`, write a minimal `Info.plist` with `LSUIElement`, `open /tmp/cm.app`. Expected: an icon and `@` over the current profile name in the menu bar; the width fits the name; right click shows the three items; Quit works. Record what you saw in the commit message body.

- [ ] **Step 3: Commit** `Add the status item strip`.

### Task 12: Popover

**Files:**

- Create: `app/Sources/ClaudeMultipass/PopoverController.swift`, `PopoverView.swift`, `AccountRow.swift`
- Modify: `StatusItemController.swift` (left click → `popover.toggle()`)

**Interfaces:**

- Consumes: `AppState` (snapshot, usage, phase, pendingForce, cliStatus, lastError, `switchTo`, `saveCurrent`, `refresh`).
- Produces: `PopoverController` owning an `NSPopover` (`.transient`, `NSHostingController(rootView: PopoverView(appState:))`). `PopoverView` states, top to bottom: CLI missing → the install hint with the brew command in a selectable text; CLI too old → the upgrade hint; otherwise header (display name, "Claude Desktop is running" or "not running"), the account list, the save-current row when `snapshot.signedIn && snapshot.current == nil`, an error line when `lastError != nil`, footer buttons Refresh, Settings…, Quit. `AccountRow`: name, `N sessions`, usage text `5h 42%  7d 12%` when `settings.usageEnabled` (`–` per missing value), a checkmark on the current one, a `ProgressView` while `phase == .switching(name)`. Tapping a non-current row sets `confirmTarget`; a `.confirmationDialog` with the spec's text and a Switch button calls `switchTo`. When `pendingForce == name`, the row shows the refusal text and a "Switch anyway" button calling `switchTo(name, force: true)`. All buttons disabled while `phase != .idle`.

- [ ] **Step 1: Build.** `swift build --package-path app -c release`.

- [ ] **Step 2: Manual check with the throwaway bundle,** against the real profiles, read-only steps only: open the popover, confirm the current account is marked and session counts match `claude-multipass list`, open the confirm dialog for another account and Cancel. Do not press Switch from an agent session (CLAUDE.md forbids switching the real Desktop from an agent); the maintainer runs that step and reports.

- [ ] **Step 3: Commit** `Add the account popover`.

### Task 13: Settings window and launch at login

**Files:**

- Create: `app/Sources/ClaudeMultipass/SettingsWindow.swift`, `SettingsView.swift`
- Modify: `StatusItemController.swift` (Settings… opens the window), `PopoverView.swift` (footer button)

**Interfaces:**

- Produces: `SettingsWindowController` (one `NSWindow` with `NSHostingController`, `isReleasedWhenClosed = false`, `show()` activates the app and brings it front). `SettingsView` sections per the spec: Usage (toggle with the caution text, interval `Picker` over `[5, 15, 30, 60]`), Menu bar (one `Toggle` per `Module.allCases`, usage modules disabled while usage is off), General (`Toggle("Launch at login")` bound to `SMAppService.mainApp.status == .enabled`, registering or unregistering on change and showing the error text on failure; CLI path field bound to `settings.cliPathOverride`, with the detected version or "not found" beside it).

- [ ] **Step 1: Build. Step 2: Manual check:** toggle a module and watch the strip change within 3 s; enable usage and confirm the first `usage --json` run shows the Keychain prompt once; turn Launch at login on and check `System Settings > General > Login Items` lists Claude Multipass; turn it off again.

- [ ] **Step 3: Commit** `Add the settings window`.

### Task 14: Build, sign and package scripts; rails and docs

**Files:**

- Create: `scripts/build-app.sh`, `scripts/sign-mac-app.sh` (copied from `~/dev/ai-kb/scripts/sign-mac-app.sh`, header line 2 adapted), `app/Info.plist.in`
- Modify: `test/check.sh` (`scripts/*.sh` in `shell_scripts`), `.gitignore` (`dist/`)
- Modify: `.claude/rules/safety-and-terms.md`, `CLAUDE.md` (Overview, Commands, Architecture, Safety rails), `README.md` (new "Menu bar app" section after Raycast), `docs/claude-multipass.md` (new "Menu bar app" section; Safety rails)

**Interfaces:**

- Produces: `scripts/build-app.sh [--dmg]`: reads the version from `package.json` with `jq`, `swift build --package-path app -c release`, assembles `dist/Claude Multipass.app` (`Contents/MacOS/ClaudeMultipass`, `Contents/Info.plist` from the template with `@VERSION@` replaced, `Contents/PkgInfo` = `APPL????`), runs `scripts/sign-mac-app.sh sign-app`, and with `--dmg` builds `dist/claude-multipass-app_<version>_arm64.dmg` (`hdiutil create -volname "Claude Multipass" -srcfolder <staging with /Applications symlink> -format UDZO`) then `sign-mac-app.sh sign-dmg` and writes `<dmg>.sha256`.

- [ ] **Step 1: Write the scripts,** then `bash -n`, `shellcheck --severity=warning` and `prettier --check` on both.

- [ ] **Step 2: Verify locally:** `bash scripts/build-app.sh` prints the signing identity line from the sign script, `codesign --verify --deep --strict "dist/Claude Multipass.app"` exits 0, `open "dist/Claude Multipass.app"` shows the strip, then quit it from the menu. Expected `spctl -a -vv "dist/Claude Multipass.app"` is rejected until notarized; note that, it is correct at this stage.

- [ ] **Step 3: Rewrite the rails.** In `safety-and-terms.md` replace the two bullets under "What a reviewer rejects" ("Any daemon, launch agent, cron entry, menu bar loop or `--watch` mode" and "Polling `security`, or reading the Keychain outside `usage`") with the spec's Rails section wording: allowed (snapshot polling of `list --json`; opt-in `usage --json` at 5 minutes or more) and rejected (automatic switch; usage on by default or under 5 minutes; a daemon or launch agent apart from the visible app; Keychain outside `usage`). Mirror in `CLAUDE.md` Safety rails. Add the `app/` and `scripts/` lines to the Architecture tree and the swift commands to Commands.

- [ ] **Step 4: Docs.** README "Menu bar app": what it shows, install line (cask, from Task 15), the usage opt-in caution, the Keychain prompt note. `docs/claude-multipass.md`: same plus the refresh cadence table from the spec.

- [ ] **Step 5: `pnpm check` passes. Commit** `Add the app build and signing scripts` (scripts, gate, gitignore) and `Document the menu bar app and update the rails` (docs and rules), two commits.

### Task 15: Release workflow, cask and release skill

**Files:**

- Create: `.github/workflows/release.yml`
- Modify: `.claude/skills/release/SKILL.md`, `CHANGELOG.md` (an `## 0.2.0 (unreleased)` section listing `--version`, `--json`, exit 3, `doctor`, the app), `package.json` version to 0.2.0 when the maintainer cuts the release (not in this task)
- Create in the tap checkout `~/dev/homebrew-tap/Casks/claude-multipass-app.rb` (committed by the maintainer at release time; this task writes it with placeholder `sha256 :no_check` replaced at release)

**Interfaces:**

- Produces: `release.yml` triggered by `push: tags: ['v*']`, `runs-on: macos-latest`, `permissions: contents: write`. Steps: checkout (pinned by SHA like `check.yml`), pnpm setup, `brew install shellcheck jq`, `pnpm install --frozen-lockfile`, `pnpm check`, the ai-kb certificate import step verbatim (secrets `MACOS_CERT_P12`, `MACOS_CERT_PASSWORD`, sets `MACOS_SIGN_REQUIRED=1`), `bash scripts/build-app.sh --dmg` with `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID`, `APPLE_API_KEY_P8` from secrets, then `gh release create "$GITHUB_REF_NAME" dist/*.dmg dist/*.sha256 --generate-notes` (or `gh release upload` when the release exists). The cask: `cask "claude-multipass-app"`, `version`, `sha256`, `url "https://github.com/jrmatherly/claude-multipass/releases/download/v#{version}/claude-multipass-app_#{version}_arm64.dmg"`, `name "Claude Multipass"`, `desc`, `homepage`, `depends_on formula: "jrmatherly/tap/claude-multipass"`, `depends_on macos: ">= :sonoma"`, `app "Claude Multipass.app"`, `zap trash: "~/Library/Preferences/net.matherly.claude-multipass.plist"`.

- [ ] **Step 1: Write `release.yml`;** run `actionlint` if installed (`command -v actionlint`), else `prettier --check`.

- [ ] **Step 2: Write the cask and audit it:** `brew audit --cask --strict ~/dev/homebrew-tap/Casks/claude-multipass-app.rb` (with `sha256 :no_check` for the audit run). Expected: no errors about the token clashing with the formula; if it reports a clash, rename the token to `claude-multipass-menubar` and record the reason in the release skill.

- [ ] **Step 3: Update the release skill:** steps for bumping `version=` in the script, the secrets the workflow needs (copied from the ai-kb repository settings, listed by name), waiting for `release.yml`, taking the DMG `sha256` from the release asset, updating the cask, `brew audit`, `brew install --cask jrmatherly/tap/claude-multipass-app`, and the final verification (`claude-multipass --version`, the app in the menu bar).

- [ ] **Step 4: `pnpm check` passes. Commit** `Add the release workflow and cask steps`.

- [ ] **Step 5: Maintainer-only release checklist (not run by an agent):** add the five secrets to the repository, run `/release 0.2.0`, confirm the DMG is notarized (`spctl -a -vv -t open --context context:primary-signature <dmg>` says accepted), install the cask on this Mac, verify the app and a real switch from the popover.

---

## Self-review notes

- Spec coverage: every spec section maps to a task (CLI changes 1 to 5, layout and data shape 6 to 10, strip 11, popover 12, settings 13, distribution and rails 14 to 15). Dropped items (atomic writes, last-profile refusal, reorder, icon, Sparkle, `add`) are named in the spec's Out of scope.
- Signatures: `CommandRunner`, `CLIError`, `Settings.visibleModules`, `Phase`, `AppState.switchTo(_:force:)` and `pendingForce` are spelled the same in Tasks 7, 9, 10 and 12.
- Review focus items each name their pinning task.
- Manual UI checks in Tasks 11 to 14 stop short of pressing Switch against the real Desktop, per `CLAUDE.md`; the maintainer owns that step.
