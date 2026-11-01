# In-app updates implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Settings, About shows a badge, a change log and a one-click update, applied by `brew` on a cask install and by Sparkle on a DMG install.

**Architecture:** One feed in the tap, read by Sparkle's silent probe. `UpdateController` in `MultipassCore` owns one `UpdateState` and drives an `Installer` chosen from disk at each click. `SparkleUpdater` in the shell is the only file that imports Sparkle, and `Phase.updating` is the one lock.

**Tech Stack:** Swift 5 language mode (tools 5.9, SwiftPM, Swift Testing, `FakeRunner`), Sparkle 2.10.1, bash 3.2, GitHub Actions.

**Spec:** `docs/superpowers/specs/completed/2026-10-31-in-app-updates.md`

Line numbers are from `main` at `a4e1e5f`.

## Global constraints

- Each PR below is its own branch in its own git worktree against `main`, merged only after `check.yml` is green and Jason says so. Never commit code on `main`. Run `pnpm install` in a new worktree. Never pass `--admin`.
- `pnpm check` is the gate, and the commit-gate hook runs it before every commit. Format in a separate call before committing.
- A user-visible change adds a line under `## Unreleased` in `CHANGELOG.md` and edits `README.md` or `docs/` in the same PR.
- Do not cut a release until PR 5 is merged. `release.yml` requires the new secret from that PR on.
- `MultipassCore` stays Foundation only. No file but `app/Sources/ClaudeMultipass/SparkleUpdater.swift` imports Sparkle.
- Nothing installs without a click. `brew` runs only from the Update button, only on the cask route. No Keychain call from the app, no launch agent, no automatic switch.
- Sparkle stays pinned at `exact: "2.10.1"`.
- Tests never run real `brew`, touch the network or use the real tool.
- An agent never runs `save`, `add`, `switch`, `remove`, `sync`, `usage` or `pick`, and never launches a build with the real bundle id. Rehearsal builds use `net.matherly.mp-rehearsal`, which has its own preferences with usage off.
- Prose: no em-dashes, short declarative sentences, sentence-case headings.

## Review focus

Each line has its test in the owning task.

1. A release is rolled back while an offer is showing: the next successful probe returns nothing newer, so the badge clears (Task 5).
2. A laptop wakes offline: a scheduled check fails and nothing on screen changes, while Check now reports it and keeps any offer (Task 5).
3. `brew` exits 0 but the disk still holds the old version: the update reports failure and does not relaunch into the old app (Task 6).
4. The user already ran `brew upgrade` in a terminal, so the disk is newer at the click: no brew run, relaunch only (Task 6).
5. The user quits during `brew`: quit is refused, but Sparkle's own terminate and the app's relaunch still go through (Task 5).

Two more, past the usual five, because each can leave the app stuck or a new user lost:

6. The user clicks Update while a scheduled probe runs: the install waits for the probe, because Sparkle ignores a check during a session and the phase would otherwise stay held (Task 5).
7. The user runs the app from the mounted DMG: Check now says to move it to Applications, because Sparkle refuses with code 1003 (Task 9, rehearsed in Task 13).

## Jason's one-time setup

Needed before Task 8 (public key) and before the first tag (secret). Agents do not touch this key.

- [ ] **Step 1: Generate the key.** With `bin/generate_keys` from the [Sparkle 2.10.1 release](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.1) tarball, which prints the public key and stores the seed in the login Keychain.
- [ ] **Step 2: Export and store it.** `generate_keys -x <file>`, then `gh secret set SPARKLE_ED_KEY < <file>`, keep a copy in 1Password, and delete the file.
- [ ] **Step 3: Hand over the public key.** It is not secret, and Task 8 commits it in `scripts/build-app.sh` as the `SPARKLE_PUBLIC_KEY` default.

---

## PR 1: Core types and logic

Branch `updates-core`. No user-visible change, so no changelog line.

### Task 1: Version comparison and change log parsing

**Files:**

- Create: `app/Sources/MultipassCore/Updates.swift`
- Create: `app/Tests/MultipassCoreTests/UpdatesTests.swift`
- Modify: `app/Sources/MultipassCore/CLI.swift:146-151`

**Interfaces:**

- Produces: `Version.components(_ v: String) -> [Int]?`, `Version.isNewer(_ a: String, than b: String) -> Bool`
- Produces: `struct ReleaseNote: Equatable, Identifiable { version, date: String; lines: [String] }` with `id` the version
- Produces: `ChangeLog.notes(in markdown: String, newerThan running: String) -> [ReleaseNote]`

- [ ] **Step 1: Write the failing tests**

```swift
@Test func versionsCompareNumerically() {
  #expect(Version.isNewer("0.10.0", than: "0.9.1"))
  #expect(!Version.isNewer("0.9.1", than: "0.10.0"))
  #expect(!Version.isNewer("0.10", than: "0.10.0"))
  #expect(Version.isNewer("0.10.1", than: "0.10"))
  #expect(!Version.isNewer("garbage", than: "0.1.0"))
  #expect(!Version.isNewer("0.1.0", than: "garbage"))
}

@Test func notesKeepOnlyNewerSectionsNewestFirst() {
  let md = "# Changelog\n\n## Unreleased\n\n- soon\n\n## 0.11.0 (2026-11-02)\n\n- two\n- `three`\n\n## 0.10.0 (2026-11-01)\n\n- one\n\n## 0.9.0 (2026-10-31)\n\n- old\n"
  let notes = ChangeLog.notes(in: md, newerThan: "0.9.0")
  #expect(notes.map(\.version) == ["0.11.0", "0.10.0"])
  #expect(notes[0].date == "2026-11-02")
  #expect(notes[0].lines == ["two", "`three`"])
}

@Test func notesSurviveAFeedWithNoUsableHeadings() {
  #expect(ChangeLog.notes(in: "no headings here", newerThan: "0.1.0").isEmpty)
}
```

Add one test that parses the repo's real `CHANGELOG.md` shape: a wrapped bullet stays one line per source line, and a section with no bullets yields empty `lines` and is still listed.

- [ ] **Step 2: Run to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path app --filter UpdatesTests` Expected: FAIL, `Version` and `ChangeLog` are not defined.

- [ ] **Step 3: Implement in `Updates.swift`**

A heading is `^## (\d+(\.\d+)+) \((\S+)\)$`. Other `## ` lines end the current section and are skipped. Strip a leading `- ` from each non-empty body line. Missing components compare as 0.

- [ ] **Step 4: Reuse `Version.components` in `CLI.isSupported`**

Behaviour stays as `CLITests` pins it, including the refusal of a one-component version.

- [ ] **Step 5: Run to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path app --filter 'UpdatesTests|CLITests'` Expected: PASS.

- [ ] **Step 6: Commit** `Add version comparison and change log parsing`

### Task 2: Install kind

**Files:**

- Modify: `app/Sources/MultipassCore/Updates.swift`
- Modify: `app/Tests/MultipassCoreTests/UpdatesTests.swift`

**Interfaces:**

- Produces: `enum InstallKind: Equatable { case homebrew(brew: URL), homebrewMissing, direct, development }`
- Produces: `InstallKind.detect(bundleURL: URL, version: String?, prefixes: [URL] = [/opt/homebrew, /usr/local]) -> InstallKind`

- [ ] **Step 1: Write the failing tests against real temp folders**

```swift
@Test func caskSymlinkToThisBundleIsHomebrew()      // Caskroom link resolves to the bundle, bin/brew executable
@Test func caskSymlinkToAnotherBundleIsDirect()     // a second copy elsewhere keeps Sparkle
@Test func caskroomWithoutBrewIsHomebrewMissing()   // never Sparkle over a bundle brew owns
@Test func noCaskroomIsDirect()
@Test func missingVersionOrNonAppBundleIsDevelopment()
```

Each asserts `InstallKind.detect` with `prefixes: [tempPrefix]`. Resolve symlinks on both sides, since `/tmp` is itself a link on macOS.

- [ ] **Step 2: Run to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path app --filter UpdatesTests` Expected: FAIL, `InstallKind` is not defined.

- [ ] **Step 3: Implement `detect`**

Glob `<prefix>/Caskroom/claude-multipass-app/*/Claude Multipass.app`. Stat only, never a subprocess.

- [ ] **Step 4: Run to verify they pass**

Same command. Expected: PASS.

- [ ] **Step 5: Commit** `Detect how the app was installed`

### Task 3: The update lock

**Files:**

- Modify: `app/Sources/MultipassCore/AppState.swift:3-5`, and beside `act` at `:232`
- Modify: `app/Tests/MultipassCoreTests/AppStateTests.swift`

**Interfaces:**

- Produces: `Phase.updating`
- Produces: `AppState.beginUpdate() async -> Bool`, false unless idle; sets `.updating`, then awaits `usageFetch` as `act` does
- Produces: `AppState.endUpdate() async`, back to `.idle`, then `relocate()`, since a failed upgrade may still have moved the formula

- [ ] **Step 1: Write the failing tests**

```swift
@Test @MainActor func switchIsBlockedDuringAnUpdate() async {
  let (s, r) = await readyState()
  r.clearCalls()
  #expect(await s.beginUpdate())
  await s.switchTo("alpha")
  #expect(r.calls.isEmpty)
  await s.endUpdate()
  #expect(s.phase == .idle)
}

@Test @MainActor func updateCannotStartDuringASwitch()      // gate the switch with Gate; beginUpdate returns false
@Test @MainActor func updateWaitsOutAUsageFetch()           // gate usage; beginUpdate returns only after the gate opens
@Test @MainActor func endUpdateProbesTheToolAgain()         // r.calls contains ["--version"] after endUpdate
```

- [ ] **Step 2: Run to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path app --filter AppStateTests` Expected: FAIL, `beginUpdate` is not defined.

- [ ] **Step 3: Add the case and the two methods**

- [ ] **Step 4: Run to verify they pass**

Same command. Expected: PASS.

- [ ] **Step 5: Commit** `Add a phase that blocks switching during an update`

### Task 4: Running brew through the CLI runner

**Files:**

- Modify: `app/Sources/MultipassCore/CLI.swift:44-49`, `:68-80`
- Modify: `app/Tests/MultipassCoreTests/CLITests.swift`

**Interfaces:**

- Produces: `CLI.init(executable:timeout:mutatingTimeout:extraEnvironment: [String: String] = [:])`

- [ ] **Step 1: Write the failing test**

Run a temp script that prints `$HOMEBREW_NO_ASK` through `CLI(executable:extraEnvironment: ["HOMEBREW_NO_ASK": "1"])` and assert stdout is `1`.

- [ ] **Step 2: Run to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path app --filter CLITests` Expected: FAIL, no such argument.

- [ ] **Step 3: Merge `extraEnvironment` last into `env`**

`brew`'s `update` and `upgrade` are not in `promptFreeCommands`, so they get the 600 s timeout with no change.

- [ ] **Step 4: Run to verify it passes**

Same command. Expected: PASS.

- [ ] **Step 5: Commit** `Let the runner set extra environment`

### Task 5: Update controller

**Files:**

- Modify: `app/Sources/MultipassCore/Updates.swift`
- Modify: `app/Sources/MultipassCore/AppSettings.swift:9-46`
- Modify: `app/Tests/MultipassCoreTests/AppSettingsTests.swift`
- Create: `app/Tests/MultipassCoreTests/UpdateControllerTests.swift`

**Interfaces:**

- Consumes: `AppState.beginUpdate`, `AppState.endUpdate`, `ChangeLog.notes`
- Produces:

```swift
public struct FeedItem: Equatable { public let version: String; public let changelog: String }
public struct UpdateOffer: Equatable { public let version: String; public let notes: [ReleaseNote] }
public enum InstallStage: Equatable { case preparing, updatingHomebrew, upgrading, downloading(Double?), extracting, installing, relaunching }
public struct UpdateProblem: Equatable {
  public enum Fallback: Equatable { case command(String), download(URL) }
  public let message: String; public let detail: String?; public let fallback: Fallback?
}
public enum UpdateState: Equatable {
  case idle, checking, upToDate(Date), available(UpdateOffer)
  case installing(UpdateOffer, InstallStage), failed(UpdateOffer?, UpdateProblem)
  public var offer: UpdateOffer? { get }
  public var blocksQuit: Bool { get }     // true only for .updatingHomebrew and .upgrading
}
public protocol UpdateFeed: AnyObject { @MainActor func probe() async throws -> FeedItem? }
public protocol Installer: AnyObject {
  /// Returns once the relaunch has started (brew). Never returns on success when the installer's own quit ends the process (Sparkle). Throws UpdateProblem.
  @MainActor func install(_ offer: UpdateOffer, report: @escaping @MainActor (InstallStage) -> Void) async throws
}
extension UpdateProblem: Error {}
@MainActor public final class UpdateController: ObservableObject {
  @Published public private(set) var state: UpdateState
  @Published public private(set) var checkedAt: Date?
  public var isAvailable: Bool { get }    // false for a development build: no update rows
  public var installKind: InstallKind { get }   // re-read from disk; the view's route caption uses it
  public init(appState: AppState, feed: UpdateFeed?, detect: @escaping @MainActor () -> InstallKind,
              installer: @escaping @MainActor (InstallKind) -> Installer?,
              runningVersion: String?, checkInterval: TimeInterval = 86_400, now: @escaping () -> Date = Date.init)
  public func start(); public func stop()
  public func check() async          // manual
  public func install() async
}
```

`AppSettings.updateChecksEnabled = true`, with its key, encode and `decodeIfPresent`.

- [ ] **Step 1: Write the failing tests with `FakeFeed` and `FakeInstaller`**

```swift
@Test @MainActor func aNewerFeedItemBecomesAnOfferWithFilteredNotes()
@Test @MainActor func nothingNewerIsUpToDateAndStampsCheckedAt()

// Review focus 1
@Test @MainActor func aRolledBackReleaseClearsTheOffer() async {
  // feed returns 0.11.0, then nil
  await c.check(); #expect(c.state.offer?.version == "0.11.0")
  await c.check(); if case .upToDate = c.state {} else { Issue.record("offer stayed") }
}

// Review focus 2
@Test @MainActor func aScheduledFailureChangesNothing()       // start() with a throwing feed: state stays .available
@Test @MainActor func aManualFailureReportsAndKeepsTheOffer() // .failed(offer, problem), offer non-nil

@Test @MainActor func overlappingChecksProbeOnce() async {
  // Gate in FakeFeed; a second check() while the first waits: feed.calls == 1. Sparkle has one continuation.
}
// Review focus 6
@Test @MainActor func installWaitsForAProbeInFlight() async {
  // Gate in FakeFeed; install() while the probe waits: installer.calls == 0 until the gate opens, then 1
}
@Test @MainActor func homebrewMissingReportsAndNeverInstalls() // installer nil: .failed(offer, p), fallback .download, phase idle
@Test @MainActor func startNeverInstalls() async {
  // start() with a newer feed and a short checkInterval, several ticks: installer.calls == 0
}
@Test @MainActor func checksOffMeansStartDoesNotProbe()
@Test @MainActor func installHoldsThePhaseWhileRunning()      // Gate in FakeInstaller: appState.phase == .updating
@Test @MainActor func aFailedInstallReleasesThePhase()        // throws: .failed(offer, p), phase == .idle
@Test @MainActor func installDuringASwitchDoesNothing()       // state returns to .available, installer.calls == 0
@Test @MainActor func stagesReachTheState()                   // report(.upgrading): .installing(offer, .upgrading)
@Test @MainActor func aDevelopmentBuildHasNoUpdates()         // feed nil: isAvailable false, check() does nothing

// Review focus 5
@Test func onlyBrewStagesBlockQuit() {
  #expect(UpdateState.installing(offer, .upgrading).blocksQuit)
  #expect(UpdateState.installing(offer, .updatingHomebrew).blocksQuit)
  #expect(!UpdateState.installing(offer, .installing).blocksQuit)
  #expect(!UpdateState.installing(offer, .relaunching).blocksQuit)
  #expect(!UpdateState.available(offer).blocksQuit)
}
```

Add to `AppSettingsTests`: an old blob with no `updateChecksEnabled` decodes to `true`, and `false` round-trips.

- [ ] **Step 2: Run to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path app --filter 'UpdateControllerTests|AppSettingsTests'` Expected: FAIL, `UpdateController` is not defined.

- [ ] **Step 3: Implement the controller**

`start` checks at launch, then in a `Task` loop every `checkInterval`, reading `settings.updateChecksEnabled` at each tick. One private `probing` flag serializes every probe, scheduled or manual: a check during a probe returns at once, and a probe is skipped unless `appState.phase == .idle`. `install` calls `detect()`, then `installer(kind)`, at the click.

The test file builds its own `AppState` from `FakeRunner` and a scratch `UserDefaults` suite, because `readyState` and `makeState` are `private` to `AppStateTests.swift`. `FakeRunner` and `Gate` are internal and usable as they are. `install` first awaits any probe in flight, sets `.installing(offer, .preparing)`, then calls `beginUpdate`, because `beginUpdate` can wait out a Keychain prompt and the UI must say so; a false return restores `.available(offer)`. A thrown non-`UpdateProblem` error becomes one with `localizedDescription`, because `AppState.describe` is private. When the installer returns, the state stays `.installing(offer, .relaunching)` and the phase stays held until the process exits.

- [ ] **Step 4: Run to verify they pass**

Same command. Expected: PASS.

- [ ] **Step 5: Commit** `Add the update controller`

### Task 6: Brew installer

**Files:**

- Modify: `app/Sources/MultipassCore/Updates.swift`
- Create: `app/Tests/MultipassCoreTests/BrewInstallerTests.swift`

**Interfaces:**

- Consumes: `CommandRunner`, `Installer`, `UpdateProblem`, `Version`
- Produces:

```swift
public final class BrewInstaller: Installer {
  public static let environment: [String: String]   // see below
  public static let command: String                 // for the Copy button
  public init(runner: CommandRunner, appURL: URL, diskVersion: @escaping (URL) -> String?, relaunch: @escaping (URL) -> Void)
}
```

`environment` is exactly `HOMEBREW_NO_ASK=1`, `HOMEBREW_NO_AUTO_UPDATE=1`, `HOMEBREW_NO_INSTALL_CLEANUP=1`, `HOMEBREW_NO_ENV_HINTS=1`. `command` is exactly `brew update && brew upgrade jrmatherly/tap/claude-multipass jrmatherly/tap/claude-multipass-app`.

- [ ] **Step 1: Write the failing tests with `FakeRunner`**

```swift
@Test @MainActor func runsUpdateThenUpgradesFormulaAndCaskThenRelaunches() {
  // disk 0.10.0 before, 0.11.0 after
  #expect(r.calls == [["update", "--quiet"], ["upgrade", "jrmatherly/tap/claude-multipass", "jrmatherly/tap/claude-multipass-app"]])
  #expect(relaunched == appURL)
  #expect(stages == [.updatingHomebrew, .upgrading, .relaunching])
}

// Review focus 3
@Test @MainActor func exitZeroWithAnOldDiskIsAFailure()    // throws; message names the version; fallback .command; no relaunch

// Review focus 4
@Test @MainActor func aDiskAlreadyNewerSkipsBrew()         // r.calls empty, relaunched

@Test @MainActor func aBrewFailureCarriesItsTailAndTheCommand()   // CLIError.failed: detail == stderr tail, fallback .command
@Test @MainActor func aTimeoutReportsAndChecksTheDisk()           // CLIError.timedOut, disk moved: still relaunches
@Test @MainActor func aMissingBundleAfterBrewIsReported()         // diskVersion nil: message says to reinstall; no relaunch
```

- [ ] **Step 2: Run to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path app --filter BrewInstallerTests` Expected: FAIL, `BrewInstaller` is not defined.

- [ ] **Step 3: Implement `install`**

The disk read decides success, on a thrown run too. `CLIError.refused` reads as a plain failure, since exit 3 means nothing to brew. Add one hint when the tail contains `Operation not permitted`: "macOS may be blocking this. Check System Settings, Privacy and Security, App Management." `detail` is the last 20 lines.

- [ ] **Step 4: Run to verify they pass**

Same command. Expected: PASS.

- [ ] **Step 5: Run the whole gate and open the PR**

Run: `pnpm check`. Expected: exit 0. Then run the opening-a-PR steps.

---

## PR 2: Bundled tool

Branch `bundled-tool`. Independent of PR 1. A DMG install stops showing `CLI ?` once this ships.

### Task 7: Find the tool inside the app

**Files:**

- Modify: `app/Sources/MultipassCore/CLI.swift:54-66`
- Modify: `app/Tests/MultipassCoreTests/CLITests.swift`
- Modify: `app/Sources/ClaudeMultipass/App.swift:21-23`
- Modify: `app/Sources/ClaudeMultipass/SettingsView.swift:105-107`
- Modify: `scripts/build-app.sh:38-39`
- Modify: `README.md`, `docs/claude-multipass.md`, `CHANGELOG.md`

**Interfaces:**

- Produces: `CLI.locate(override: String?, bundled: URL? = nil, isExecutable:) -> URL?`

- [ ] **Step 1: Write the failing tests**

```swift
@Test func bundledToolIsLastInPrecedence() {
  let b = URL(fileURLWithPath: "/App/Contents/Resources/claude-multipass")
  #expect(CLI.locate(override: nil, bundled: b, isExecutable: { $0 == b.path }) == b)
  #expect(CLI.locate(override: nil, bundled: b, isExecutable: { _ in true })?.path == "/opt/homebrew/bin/claude-multipass")
  #expect(CLI.locate(override: "/custom", bundled: b, isExecutable: { _ in true })?.path == "/custom")
  #expect(CLI.locate(override: nil, bundled: nil, isExecutable: { _ in false }) == nil)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path app --filter CLITests` Expected: FAIL, no such argument.

- [ ] **Step 3: Implement and wire it**

`App.swift` passes `Bundle.main.url(forResource: "claude-multipass", withExtension: nil)`. `build-app.sh` runs `mkdir -p "$app/Contents/Resources"` and `install -m 755 bin/claude-multipass "$app/Contents/Resources/claude-multipass"` before signing. The General footer's automatic text becomes "Looked up in /opt/homebrew/bin, then /usr/local/bin, then inside the app."

- [ ] **Step 4: Run to verify it passes**

Same command. Expected: PASS.

- [ ] **Step 5: Verify a built bundle**

Run: `scripts/build-app.sh && "dist/Claude Multipass.app/Contents/Resources/claude-multipass" --version && codesign --verify --deep --strict "dist/Claude Multipass.app"` Expected: `claude-multipass <version>`, and the verify exits 0. Do not launch this build.

- [ ] **Step 6: Document it**

README and `docs/`: a DMG install works without Homebrew; on macOS 14 it also needs `jq`; a terminal or Raycast user can run `ln -s "/Applications/Claude Multipass.app/Contents/Resources/claude-multipass" ~/.local/bin/claude-multipass`. Add the changelog line.

- [ ] **Step 7: Run the gate and open the PR**

Run: `pnpm check`. Expected: exit 0.

---

## PR 3: Sparkle in the bundle

Branch `sparkle-updater`, after PR 1. Needs Jason's public key.

### Task 8: Build, embed and sign

**Files:**

- Modify: `app/Package.swift`
- Create: `app/Package.resolved`
- Modify: `app/Info.plist.in`
- Modify: `scripts/build-app.sh`, `scripts/sign-mac-app.sh`, `test/check.sh`

**Interfaces:**

- Produces: `build-app.sh` reads `SPARKLE_PUBLIC_KEY`, `APP_VERSION` and `APP_BUNDLE_ID` from the environment. The first defaults to the committed key, the others to `package.json` and `net.matherly.claude-multipass`. Task 13 uses all three; `release.yml` sets none.

- [ ] **Step 1: Add the dependency**

`.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")`, with the product and `linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]` on the `ClaudeMultipass` target only. Commit the resolved file.

- [ ] **Step 2: Run the tests**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path app` Expected: PASS, with no test count below the previous run.

- [ ] **Step 3: Enforce the one-importer rule in the gate**

Add to `test/check.sh`: fail when `grep -rl '^import Sparkle' app/Sources` prints anything but `app/Sources/ClaudeMultipass/SparkleUpdater.swift`. It passes while no file imports Sparkle yet.

- [ ] **Step 4: Add the plist keys**

`SUFeedURL` = `https://raw.githubusercontent.com/jrmatherly/homebrew-tap/HEAD/appcast.xml`, `SUPublicEDKey` = `@SPARKLE_PUBLIC_KEY@`, `SUEnableAutomaticChecks` = false. `build-app.sh` substitutes the key from `SPARKLE_PUBLIC_KEY`, defaulting to Jason's committed public key.

- [ ] **Step 5: Embed the framework in `build-app.sh`**

`ditto app/.build/release/Sparkle.framework` into `Contents/Frameworks`, remove `Versions/B/XPCServices` and the top-level `XPCServices` link, and copy `app/.build/artifacts/sparkle/Sparkle/LICENSE` to `Contents/Resources/Sparkle-LICENSE`.

- [ ] **Step 6: Sign inside out in `sign-mac-app.sh`**

In `sign-app`, when `Contents/Frameworks/Sparkle.framework` exists, sign `Versions/B/Autoupdate`, `Versions/B/Updater.app` and the framework, each with `--force --options runtime --timestamp` and no entitlements, before the app. This stays the only `codesign` caller. No `--deep` on signing.

- [ ] **Step 7: Verify the bundle**

Run: `scripts/build-app.sh && codesign --verify --deep --strict "dist/Claude Multipass.app" && otool -l "dist/Claude Multipass.app/Contents/MacOS/ClaudeMultipass" | grep -A2 LC_RPATH | grep Frameworks && du -sh "dist/Claude Multipass.app"` Expected: verify exits 0, the rpath line prints, the bundle is under 5 MB. Do not launch it.

- [ ] **Step 8: Commit** `Embed Sparkle in the app bundle`

### Task 9: Sparkle updater

**Files:**

- Create: `app/Sources/ClaudeMultipass/SparkleUpdater.swift`
- Modify: `app/Sources/ClaudeMultipass/App.swift`
- Modify: `.claude/rules/safety-and-terms.md`

**Interfaces:**

- Consumes: `UpdateFeed`, `Installer`, `FeedItem`, `InstallStage`, `UpdateProblem`
- Produces: `@MainActor final class SparkleUpdater: NSObject, SPUUserDriver, SPUUpdaterDelegate, UpdateFeed, Installer`, with `init(bundle: Bundle) throws`
- Produces: `AppDelegate.updates: UpdateController`, for the UI tasks

Measured mapping through a class of this exact shape, which compiles clean in Swift 5 mode, so the implementer need not rediscover it:

| Call | Sparkle path |
| --- | --- |
| Construct | `SPUUpdater(hostBundle:applicationBundle:userDriver:delegate:)`, then `start()` |
| `probe()` | `checkForUpdateInformation()`. `didFindValidUpdate` gives `displayVersionString` and `itemDescription`. `updater(_:didFinishUpdateCycleFor:error:)` resumes the one continuation: code 1001 is nil, any other error throws. Do not act on `didAbortWithError`, which also fires for 1001. Code 2001 is an unreachable or malformed feed. Code 1003 is a read-only volume: message `Move Claude Multipass to Applications to update.` |
| `install` | Throw if `!canCheckForUpdates`, because `checkForUpdates()` during a session would leave the await hanging and the phase held. `checkForUpdates()`. `showUpdateFound` replies `.install`. `showReady(toInstallAndRelaunch:)` reports `.installing` and replies `.install`. Sparkle terminates and relaunches. `didFindValidUpdate` fires again here, so it must only store the item |
| Errors | `showUpdaterError` acknowledges and throws `UpdateProblem` with `fallback: .download(<release page>)`. `showUpdateNotFoundWithError` acknowledges and throws "No longer offered" |
| Stages | `showDownloadDidReceiveExpectedContentLength` and `showDownloadDidReceiveData` give `.downloading(fraction)`. `showDownloadDidStartExtractingUpdate` gives `.extracting`. `showInstallingUpdate` gives `.relaunching`, since it arrives after the ready reply |

- [ ] **Step 1: Implement the class**

Resume each continuation once. `show(_:reply:)` replies with automatic checks off and no system profile. The remaining driver methods are empty.

- [ ] **Step 2: Compose in `App.swift`**

Build `SparkleUpdater` only when `InstallKind.detect` is not `.development`; a throw leaves `feed` nil and is logged. The `installer` closure re-detects at each call: `.homebrew(brew)` gives `BrewInstaller(runner: CLI(executable: brew, extraEnvironment: BrewInstaller.environment), ...)`, `.direct` gives the `SparkleUpdater`, `.homebrewMissing` and `.development` give nil.

`relaunch` starts `/bin/sh -c 'while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; open "$0"' <path> <pid>` detached, then calls `NSApp.terminate`. Waiting for the exit replaces a fixed sleep, because an `open` while the old process lives would only reactivate it. `diskVersion` reads the bundle's `Info.plist` directly, because `Bundle` caches.

`applicationShouldTerminate` returns `.terminateCancel` while `updates.state.blocksQuit`. `updates.start()` runs after `appState.start()`, and `applicationWillTerminate` calls `updates.stop()`.

- [ ] **Step 3: Change the rails in the same PR**

This PR starts the app's first network call, so its rules land with it. In `safety-and-terms.md`:

- The allowed timers gain "the update check: one GET of the tap's `appcast.xml` at launch and daily, off by a toggle, no account data, no Keychain".
- The reject list gains "an install, `brew` run or Sparkle install without a click".
- The launch agent rule notes the measured exception: during a clicked install, Sparkle runs transient launchd jobs (`<bundle id>-sparkle-updater`, `-sparkle-progress`) that end with the install and leave no file in `~/Library/LaunchAgents`.

- [ ] **Step 4: Run the gate**

Run: `pnpm check`. Expected: exit 0. Nothing in the UI uses this yet, and the probe fails silently until the tap has an `appcast.xml`.

- [ ] **Step 5: Open the PR** `Add the Sparkle updater`

---

## PR 4: The About tab

Branch `update-ui`, after PR 3. User-visible.

### Task 10: Update section, badge and notices

**Files:**

- Create: `app/Sources/ClaudeMultipass/UpdateSection.swift`
- Modify: `app/Sources/ClaudeMultipass/SettingsView.swift:31-58`, `:153-168`
- Modify: `app/Sources/ClaudeMultipass/SettingsWindow.swift:15-16`
- Modify: `app/Sources/ClaudeMultipass/StatusItemController.swift:48`, `:70-82`
- Modify: `app/Sources/ClaudeMultipass/PopoverController.swift`, `PopoverView.swift:48-51`
- Modify: `app/Tests/ClaudeMultipassTests/ShotsTests.swift`
- Modify: `README.md`, `docs/claude-multipass.md`, `CHANGELOG.md`

**Interfaces:**

- Consumes: `UpdateController`
- Produces: `SettingsView(appState:, pane:, updates: UpdateController? = nil)`, `PopoverView(..., updates: UpdateController? = nil)`. Existing test call sites keep compiling.

Exact copy:

| State | Text |
| --- | --- |
| Badge | `0.11.0 available` |
| Button | `Update and relaunch` |
| Route caption | `Updates with Homebrew`, or none on a direct install |
| Stages | `Preparing…`, `Updating Homebrew…`, `Upgrading…`, `Downloading 40 %`, `Extracting…`, `Installing…`, `Relaunching…` |
| Up to date | `Up to date. Checked 2 h ago` |
| Toggle | `Check for updates once a day` |
| Popover and menu | `Update available`, `Update to 0.11.0…` |

- [ ] **Step 1: Write the failing render tests**

Add a fixture `UpdateController` per state to `ShotsTests`, using `FakeFeed` and `FakeInstaller` copies, since test targets cannot share them. Reach each state by calling `check()` and `install()`; `installing` uses an installer that reports a stage and then awaits a gate. Render About as `about-update-<state>` for `upToDate`, `available`, `installing`, `failedBrew` (with the command) and `failedSparkle` (with the download link), light and dark. Add one assertion per state on the rendered height growing or staying above the tab's base height, as the General test does for its path field. `available` must be at least 100 pt taller than `upToDate`, which proves the change log did not collapse.

- [ ] **Step 2: Run to verify they fail**

Run: `pnpm shots` Expected: FAIL, `SettingsView` takes no `updates` argument.

- [ ] **Step 3: Implement the views**

`UpdateSection` switches over `state`, exhaustively. Each change log line renders through `AttributedString(markdown:, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))`. The change log sits in a `ScrollView` with a fixed height of 160 pt, because the form uses `.fixedSize(vertical: true)`, where a `maxHeight` scroll view can collapse, and with `.scrollDisabled(false)`, since the form sets `.scrollDisabled(true)`. The Update button is disabled while `appState.phase != .idle`. A fallback renders as selectable monospaced text with a Copy button, or as a link. `SettingsView` and `PopoverView` hold `updates` as a plain `let`, not `@ObservedObject`. `UpdateSection`, the badge and `UpdateNotice` each take a non-optional `@ObservedObject` controller, and render only when one exists. The route caption reads `updates.installKind`.

- [ ] **Step 4: Render and inspect**

Run: `pnpm shots`. Expected: exit 0. Read each `about-update-*` PNG zoomed, light and dark, per `CLAUDE.md`. Check the long change log does not push the window off screen, and that the badge does not truncate the version.

- [ ] **Step 5: Document and open the PR**

README and `docs/` describe the check, the two routes and the toggle. `docs/` also says that installs at 0.9.0 or older update by brew or a new DMG, and that a DMG install with the formula keeps the formula on `brew upgrade`. Its uninstall steps add the DMG case: delete the app, then `~/Library/Caches/net.matherly.claude-multipass` and `~/Library/HTTPStorages/net.matherly.claude-multipass`. Add the changelog line.

Run: `pnpm check`. Expected: exit 0.

---

## PR 5: Pipeline, rails and rehearsal

Branch `update-pipeline`, after PR 4, because Task 13 clicks the real UI. Jason's secret must exist before this merges.

### Task 11: Appcast generator

**Files:**

- Create: `scripts/make-appcast.sh`
- Create: `test/appcast.sh`
- Modify: `test/check.sh:17-24`, and its run list

**Interfaces:**

- Produces: `make-appcast.sh <dmg> <version> <changelog>` prints the appcast on stdout. It reads `SPARKLE_ED_KEY` from the environment, `SIGN_UPDATE` for the tool, defaulting to `app/.build/artifacts/sparkle/Sparkle/bin/sign_update`, and `APPCAST_DOWNLOAD_BASE` for the enclosure's folder, defaulting to `https://github.com/jrmatherly/claude-multipass/releases/download/v<version>`. Task 13 needs the last one.

- [ ] **Step 1: Write the failing self-check**

`test/appcast.sh` uses a stub `SIGN_UPDATE` that records its stdin and prints `FAKESIG==`, and asserts:

```bash
xmllint --noout "$out" # well formed
grep -q '<sparkle:version>1.2.3</sparkle:version>' "$out"
grep -q 'sparkle:edSignature="FAKESIG=="' "$out"
grep -q "length=\"$(stat -f %z "$dmg")\"" "$out"
grep -q 'releases/download/v1.2.3/claude-multipass-app_1.2.3_arm64.dmg' "$out"
grep -q '<sparkle:minimumSystemVersion>14.0.0</sparkle:minimumSystemVersion>' "$out"
grep -q 'sparkle:format="markdown"' "$out"
APPCAST_DOWNLOAD_BASE=http://127.0.0.1:1 scripts/make-appcast.sh "$dmg" 1.2.3 "$log" | grep -q 'url="http://127.0.0.1:1/claude-multipass-app_1.2.3_arm64.dmg"'
# refusals, each exit 1:
#   a change log containing ]]>
#   SPARKLE_ED_KEY unset
#   a version that is not the top heading of the change log
grep -q 'SECRETSEED' "$out" && exit 1 # the key never reaches the output
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash test/appcast.sh`. Expected: FAIL, `scripts/make-appcast.sh` not found.

- [ ] **Step 3: Implement**

The key goes by pipe: `printf '%s' "$SPARKLE_ED_KEY" | "$sign_update" --ed-key-file - -p "$dmg"`, as measured. No here-string, no temp file. Then run `--verify` on the same pair and fail on non-zero.

Note that `--verify` takes the key the same way, so it proves the archive matches the secret, not the shipped public key. The gate proves that.

- [ ] **Step 4: Run to verify it passes**

Run: `bash test/appcast.sh`. Expected: exit 0. Add the script and the test to `shell_scripts`, and the test to the run list in `test/check.sh`.

- [ ] **Step 5: Commit** `Generate the appcast`

### Task 12: Release workflow, skill and rails

**Files:**

- Modify: `.github/workflows/release.yml`
- Modify: `.claude/skills/release/SKILL.md`
- Modify: `.claude/rules/safety-and-terms.md`, `CLAUDE.md`
- Tap repo, at the 0.10.0 release: `Casks/claude-multipass-app.rb` (`zap`), `appcast.xml`

- [ ] **Step 1: Change `release.yml`**

- Add `secrets.SPARKLE_ED_KEY` to `HAS_SECRETS` and its error text.
- After `build-app.sh --dmg`, a new step with `SPARKLE_ED_KEY` in that step's `env` only runs `make-appcast.sh dist/*.dmg "$(jq -r .version package.json)" CHANGELOG.md > dist/appcast.xml`. It must run after `build-app.sh`, because the signature covers the final stapled bytes.
- A second new step mounts the DMG, runs `codesign --verify --deep --strict` on the app inside, and runs `".../Contents/Resources/claude-multipass" --version`, failing unless it prints the version. This checks the bytes users get, after `build-app.sh`'s staging copy.
- Add `dist/appcast.xml` to the artifact paths, the refuse-if-exists loop and both upload commands.

- [ ] **Step 2: Validate the workflow**

Run: `pnpm check`. Expected: exit 0, prettier passes on the YAML. Confirm with `grep -n 'SPARKLE_ED_KEY' .github/workflows/release.yml` that the secret appears only in `HAS_SECRETS` and in that one step's `env`.

- [ ] **Step 3: Change the release skill**

- Preconditions name six secrets.
- Step 3 confirms `appcast.xml` is on the release.
- Step 7 adds: `gh release download vX.Y.Z -p appcast.xml -O ~/dev/homebrew-tap/appcast.xml --clobber`, then `git -C ~/dev/homebrew-tap add appcast.xml`, because step 8's `commit -am` skips an untracked file and 0.10.0 adds it for the first time. Then assert that `sparkle:version` and the cask `version` both equal X.Y.Z.
- New step 7a, the gate, skipped for 0.10.0 because nothing can self-update yet. On Jason's Mac, with the installed app quit and a browser-downloaded DMG of the previous version in `~/Applications`:
  - Run `defaults write net.matherly.claude-multipass SUFeedURL https://github.com/jrmatherly/claude-multipass/releases/download/vX.Y.Z/appcast.xml`. The asset is already on the release, so no server is needed.
  - Open that copy, Check now, then Update and relaunch. Expect the new version.
  - Run `defaults delete net.matherly.claude-multipass SUFeedURL` whether the update passed or failed, or that app stays pointed at this one release.
  - Delete the `~/Applications` copy, reopen the installed app, and confirm that Launch at login still reads on, since two copies share one bundle id.
  - A failure here stops the release before anyone is told.
- Step 8's commit includes `appcast.xml`. It is the announcement.
- A new rollback note: `git revert` of the tap commit stops new offers.
- Step 9 changes: do not run `brew upgrade` by hand. Open About on the old running app, Check now, then Update and relaunch. That upgrades the formula and the cask, and it is the real test of the cask route. The manual `brew` commands stay as the fallback, and for 0.10.0, whose previous version has no updater.
- Step 10 stays as it is, and also confirms that Launch at login still reads on.

- [ ] **Step 4: Update the project notes**

`safety-and-terms.md` changed in Task 9. `CLAUDE.md`: Overview, Architecture, the `scripts/` line and the Release section. `Sparkle`'s pin and the new secret are named.

- [ ] **Step 5: Run the docs audit**

Use the `docs-audit` skill on the branch and fix what it confirms.

- [ ] **Step 6: Commit** `Publish the appcast and document the update rails`

### Task 13: Rehearsal

**Files:**

- Create: `scripts/rehearse-update.sh`
- Modify: `CLAUDE.md`, `.claude/rules/desktop-internals.md` (record the results)

**Interfaces:**

- Produces: `rehearse-update.sh [--bad-signature | --stop-feed | --from-dmg]` builds two versions with `APP_BUNDLE_ID=net.matherly.mp-rehearsal`, a throwaway seed and a matching `SPARKLE_PUBLIC_KEY`, copying each out of `dist/` because the next build erases it. It installs 0.0.1 under a temp folder, serves a real `make-appcast.sh` feed for 0.0.2 on localhost with `APPCAST_DOWNLOAD_BASE`, sets `SUFeedURL` for that bundle id, and opens the app. It stays in the foreground, polls the disk version for up to 180 s, exits 0 when it reads 0.0.2, and removes the app, the preferences and the caches on exit. Plain HTTP to `127.0.0.1` works with no App Transport Security key (measured).

- [ ] **Step 1: Write the script**

Generate the seed with a CryptoKit one-liner through `swift`, as in the prototype, so no Keychain is touched. The feed's change log is the real `CHANGELOG.md` with a `## 0.0.2 (<today>)` section prepended in a temp copy, because `make-appcast.sh` refuses a version that is not the top heading.

- [ ] **Step 2: Run the happy path**

Run: `bash scripts/rehearse-update.sh`, then click Update and relaunch in About, or drive it with computer use. Expected: About shows the badge and the change log; the app relaunches as 0.0.2; the script exits 0.

- [ ] **Step 3: Run the failure paths**

`--bad-signature`: expect the failed state with the download link, disk unchanged. `--stop-feed`: expect nothing on screen after launch, and a message on Check now. `--from-dmg`: open the app from the mounted DMG, and expect the move-to-Applications message on Check now.

- [ ] **Step 4: Recheck what Sparkle leaves behind**

During the update, run `launchctl print gui/$(id -u) | grep -i -E 'sparkle|autoupdate'`, and diff `~/Library/LaunchAgents` before and after. Expect `<bundle id>-sparkle-updater` and `-sparkle-progress` during the install, nothing after, and no new file, as the prototype measured. If anything remains, stop and raise it.

- [ ] **Step 5: Open the PR**

Run: `pnpm check`. Expected: exit 0. The rehearsal cannot cover the cask route, because `BrewInstaller`'s package names are fixed and the shipped app has no override. Its proof is the first real upgrade in the pair below; unit tests and the scratch-tap probe in the spec cover it until then.

---

## Release: the first real pair

Run after PRs 1 to 5 merge, through `/release`, on Jason's word.

- [ ] **0.10.0.** Skips step 7a. The tap's first `appcast.xml` lands. Verify `curl -s <raw url> | grep sparkle:version`. Upgrade with `brew upgrade`, since 0.9.0 has no updater. Add `~/Library/Caches/net.matherly.claude-multipass` and `~/Library/HTTPStorages/net.matherly.claude-multipass` to the cask's `zap`. Jason opens About and sees `Up to date`.
- [ ] **0.10.1.** Runs step 7a for the first time. This is the first proof of Sparkle under a notarized, quarantined app and of the bundled tool under quarantine. Step 9's in-app update is the first proof of the cask route and of its relaunch, and it settles App Management. Jason checks that the login item stays on and that no Gatekeeper prompt appears. Record both results in `.claude/rules/desktop-internals.md`, and update the spec's Not proven section.
