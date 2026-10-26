# Claude Multipass menu bar app: design

Date 2026-10-25. Status: approved in conversation, pending plan review.

## Goal

A macOS menu bar app that shows which saved claude.ai account Claude Desktop is signed in as, switches to another saved account in two clicks, and, when the user opts in, shows the 5-hour and 7-day usage of each saved account in the menu bar. It reuses the existing `claude-multipass` script for every account operation.

## Why this shape

The four surveyed projects (CCSwitcher, cc-switch, claude-profile-manager, teamclaude) all switch Claude Code CLI credentials or API providers. None switches the Claude Desktop login, which is this project's job. CCSwitcher is the closest UX model: a Swift menu bar app with configurable two-line "modules" (account, 5h bar, 7d bar, reset countdowns) and a popover. Its headline feature, automatic switching at a usage threshold, stays out of this project (decision 2026-10-25; see `.claude/rules/safety-and-terms.md`).

Decisions taken with the user on 2026-10-25:

- Host: a native SwiftUI app, not a SwiftBar plugin or a Raycast extension.
- Usage in the menu bar is opt-in with a user-set interval (5, 15, 30 or 60 minutes, default 15). The account name refreshes without the Keychain.
- No automatic switch of any kind.
- Scope beyond the menu bar, by the maintainer's judgment: `--json` output and `--version` on the CLI (the app needs them), a refusal exit code, and a small `doctor` command. Dropped: atomic writes (`jq_write` already stages a temp file and renames) and "refuse to remove the last profile" (`remove` already moves the profile to `backups/`).

## Measured constraints

- This Mac has macOS 27.0.1, Swift 6.4 and the Command Line Tools only, no Xcode. `swift build` compiles a SwiftUI `MenuBarExtra` app in 28 s. XCTest is unavailable (unresolved module). Swift Testing runs only with the macro plugin path passed explicitly: `swift test -Xswiftc -plugin-path -Xswiftc "$(xcode-select -p)/usr/lib/swift/host/plugins/testing"` (measured twice on 2026-10-25; a plain `swift test` fails with `plugin for module 'TestingMacros' not found`, and one earlier run that passed without the flag did not reproduce). The gate adds the flag when that directory exists, so CI on Xcode is unaffected. So the app is a Swift package built by `swift build`, assembled into a bundle by a script, with Swift Testing for unit tests and no `.xcodeproj`.
- A "Developer ID Application: Jason Matherly (7BSA2L4Z5L)" identity is in the login Keychain. `codesign --options runtime --timestamp` on the prototype bundle succeeded and the app launched as an accessory process. `xcrun notarytool` and `stapler` are present.
- `~/dev/ai-kb/scripts/sign-mac-app.sh` is a bash signing and notarization script driven by `MACOS_SIGN_IDENTITY`, `MACOS_SIGN_REQUIRED`, `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID` and `APPLE_API_KEY_P8`. Its release workflow imports `MACOS_CERT_P12` and `MACOS_CERT_PASSWORD` into a throwaway keychain on the runner. This project copies the script and the secret names.
- `claude-multipass current` and `list` read only `config.json` and the profile `meta.json` files. Only `usage` reads the Keychain (one `security` call per run) and the network.
- The Homebrew tap `jrmatherly/homebrew-tap` holds `Formula/claude-multipass.rb` and no casks yet.
- CCSwitcher hosts a SwiftUI strip inside an `NSStatusItem` button through `NSHostingController` with `sizingOptions = [.intrinsicContentSize]` and mirrors the strip's width onto `statusItem.length`, because `MenuBarExtra`'s label is limited to one line. It re-reads state on a 3 s timer because `ObservableObject` delivery into a status item view is unreliable.

## Product

### Menu bar strip

Icon plus a row of two-line modules, iStats style: a short uppercase label on top, a value or a capsule bar below. Modules:

| Module | Label | Value | Needs usage opt-in |
| --- | --- | --- | --- |
| account | `@` | current profile name, `not saved`, `signed out` | no |
| session bar | `5H` | capsule bar plus `42%` | yes |
| weekly bar | `7D` | capsule bar plus `12%` | yes |
| session reset | `5H↻` | countdown `2h 14m` | yes |
| weekly reset | `7D↻` | countdown `4d 6h` | yes |

Each module has an on/off toggle in Settings. Order is fixed (the table order). No drag reorder in this version. Unknown values render `–`; a bar with unknown value is an empty capsule. Bar fill is `Color.primary`, red above 90 %, clamped at 100 %.

The strip width follows its content, as CCSwitcher does. Profile names longer than 16 characters are truncated with an ellipsis.

### Popover (left click)

1. Header: current account, and whether Claude Desktop is running.
2. Saved accounts: one row per profile with name, session count and, when usage is on, `5h 42%  7d 12%` (or `–`, with the CLI's reason as a tooltip). The current one is marked. Clicking another row expands it inline to: "Switch to work? Claude Desktop quits and relaunches signed in as work. Its Code tab will list every saved account's sessions." with Switch and Cancel buttons. No sheet or dialog: a transient popover and a presented sheet do not mix reliably, and one inline pattern serves the confirm, the refusal and the error.
3. During a switch the account rows and the save row are disabled and the row shows a spinner with "Switching to work…". The CLI takes 5 to 20 s because it quits and relaunches Desktop. Refresh, Settings and Quit stay enabled at all times; a background snapshot or usage refresh disables nothing.
4. When the CLI refuses (exit code 3, see below) the row shows the CLI's message with a "Switch anyway" button, which reruns with `--force`. Any other failure shows the CLI's stderr in the row with a Retry button.
5. When signed in but not saved: a "Save this login as…" row with a name field. The Save button is enabled only when the name passes the CLI's rule (`^[A-Za-z0-9._-]+$`, not `.` or `..`) and is not already a saved profile, so the CLI's "another account" refusal cannot be reached from the app.
6. Footer: Refresh, Settings…, Quit. Opening the popover also triggers a snapshot refresh.

Right click on the icon: a native menu with Refresh, Settings…, Quit.

### Settings window

- Usage: toggle "Show usage (reads the saved tokens through the Keychain and Anthropic's usage endpoint; see the caution)", interval picker 5/15/30/60 min (a stored value outside that set rounds down to the nearest allowed, minimum 5), a link to the Usage headroom section of `docs/claude-multipass.md` on GitHub, which holds the caution.
- Menu bar: one toggle per module.
- General: Launch at login (`SMAppService.mainApp`), CLI path (auto-detected, with an override field and the detected version).

### Refresh cadence

- Snapshot (`list --json`): every 30 s, on popover open, after every switch or save, and on Refresh. No Keychain.
- Usage (`usage --json`): only when enabled, every N minutes, on Refresh, and once when enabled. One `security` call per run, inside the CLI. Never more often than every 5 minutes on a timer.
- The strip re-reads state on a 3 s tick (the hosting pattern CCSwitcher documents), which also recomputes the countdowns from the cached `resetsAt`. No separate countdown timer.
- Turning a module on or off never triggers a usage fetch. Enabling usage fetches once; disabling it cancels the timer.
- Nothing in the app ever runs `switch` without a click.

### Failure surfaces

- CLI not found: the popover shows "Install the CLI: `brew install jrmatherly/tap/claude-multipass`" and Settings lets the user pick a path. Changing the path in Settings re-locates the CLI at once, without a relaunch.
- CLI older than 0.2.0: "Update the CLI: `brew upgrade claude-multipass`". Detection: the 0.1.0 script answers `--version` with its usage page and exit 2 (measured on the Homebrew install), so any failure of `--version` counts as too old.
- Usage error for one profile (cannot decrypt, 401, 429, offline): that profile shows `–` with the reason in a tooltip. The next attempt is the next scheduled tick, never an immediate retry.

## CLI changes (`bin/claude-multipass`, version 0.2.0)

- `--version` prints `claude-multipass 0.2.0`. A `version=` constant near the top is the source; `package.json` carries the same number for pnpm and the app build, `test/check.sh` fails when the two differ, and the release skill bumps both. It is handled in the first `case $cmd` beside `--help`, because `main` shifts the command word off before the option loop.
- `migrate_store`'s one-time message moves to stderr so a first run of `list --json` prints JSON only.
- `--json` is accepted by `list` and `usage`, rejected elsewhere with `--json applies to list and usage`.
- `list --json`:

  ```json
  {
    "version": "0.2.0",
    "signedIn": true,
    "desktopRunning": true,
    "current": "work",
    "profiles": [
      {
        "name": "work",
        "account": "<uuid>",
        "savedAt": "2026-10-25T01:02:03Z",
        "sessions": 12
      }
    ]
  }
  ```

  `current` is `null` when signed out or when the login is not saved; `signedIn` tells the two apart.

- `usage --json`:

  ```json
  {
    "profiles": [
      {
        "name": "work",
        "fiveHour": {
          "utilization": 42,
          "resetsAt": "2026-10-25T12:00:00Z"
        },
        "sevenDay": {
          "utilization": 12,
          "resetsAt": "2026-10-29T00:00:00Z"
        }
      },
      { "name": "personal", "error": "cannot decrypt" }
    ]
  }
  ```

  The unsaved signed-in login appears as `"name": "(signed in)"`, as in the text output. `error` is the CLI's full text, for example `cannot decrypt (the profile was saved on another Mac, or the app changed its key)`. `resetsAt` is normalised to `YYYY-MM-DDTHH:MM:SSZ` with the `sub()` the text path already uses (the endpoint returns `.123456+00:00`), and omitted when absent. A window whose `utilization` is null is omitted. With nothing to report the output is `{"profiles":[]}`.

- Exit code 3 for the three refusals that `--force` lifts (`save` over another account, `switch` away from an unsaved login, `sync` while Desktop runs). Exit 1 stays for every other failure, exit 2 for the usage page on a bad invocation. The `save` refusal moves before the Desktop quit, so a refused save no longer quits and relaunches the app for nothing.
- `doctor`: prints `ok:`, `warn:` and `fail:` lines and exits 1 when any `fail:` was printed. Checks: `config.json` exists; `jq` on PATH; `fzf`, `python3`, `openssl`, `curl` on PATH (warn, with what each enables); the store is mode 0700 and every profile file 0600 (warn); every profile has `meta.json` and `config.json` with a non-empty `oauth:tokenCacheV2` (fail); the backups folder count; whether Claude Desktop is running; whether the pre-0.1 store at `~/.config/dotfiles/claude-desktop-accounts` still exists (warn). No Keychain, no network.

## App layout

```text
app/
  Package.swift                 tools 5.9, macOS 14, Swift 5 language mode
  Sources/MultipassCore/        models, JSON decoding, formatting, CLI runner, state machine (no AppKit)
  Sources/ClaudeMultipass/      App entry, status item, strip, popover, settings (AppKit + SwiftUI)
  Tests/MultipassCoreTests/     Swift Testing
  Info.plist.in                 template; build-app.sh fills the version
scripts/
  build-app.sh [--dmg]          swift build, assemble dist/Claude Multipass.app, sign, optional DMG
  sign-mac-app.sh               copied from ai-kb
.github/workflows/release.yml   on tag v*: build, sign, notarize, upload the DMG and its sha256
```

Bundle identifier `net.matherly.claude-multipass` (the ai-kb convention), display name `Claude Multipass`, `LSUIElement` true, minimum macOS 14.0, arm64 only in this version. No custom app icon. No Sparkle; updates come through Homebrew.

The CLI quits Desktop with `osascript … tell application "Claude" to quit`, and the app is the responsible process for that Apple event. Under the hardened runtime that needs the `com.apple.security.automation.apple-events` entitlement and an `NSAppleEventsUsageDescription` string, or every switch from the app would fall back to the CLI's `pkill` after 8 s. The bundle ships both, and the signing script passes the entitlements file.

Data shape in `MultipassCore` (names avoid SwiftUI's `Settings` and `Window`):

```swift
struct Snapshot: Decodable, Equatable { version, signedIn, desktopRunning, current: String?, profiles: [Profile] }
struct Profile: Decodable, Equatable, Identifiable { name, account, savedAt: Date, sessions: Int }   // id = name
struct UsageReport: Decodable, Equatable { profiles: [UsageEntry] }
struct UsageEntry: Decodable, Equatable, Identifiable { name, fiveHour: UsageWindow?, sevenDay: UsageWindow?, error: String? }
struct UsageWindow: Decodable, Equatable { utilization: Double, resetsAt: Date? }
enum Phase: Equatable { case idle, switching(String), saving(String) }     // background refreshes are separate flags, not phases
enum CLIStatus: Equatable { case unknown, ready(String), missing, tooOld }  // unknown until the first --version probe answers
struct RowError: Equatable { let name: String; let message: String; let refused: Bool }   // the one row-level failure on show
enum CLIError: Error, Equatable { case refused(String), failed(status: Int32, stderr: String), badJSON(String), timedOut }
func isValidProfileName(_ s: String) -> Bool                                // the CLI's rule
```

`AppState` is a `@MainActor` `ObservableObject` holding `snapshot`, `usage`, `phase`, `isRefreshing`, `isRefreshingUsage`, `lastError` (refresh and usage failures), `rowError` (a switch or save failure, with `refused` deciding between "Switch anyway" and Retry; cleared by Cancel, by tapping another row, or by a later success), `cliStatus`, the settings, and the timers. Settings change through `func apply(_ settings: AppSettings) async`, never a `didSet`, so the work it triggers (re-locating the CLI, starting or stopping usage polling, one fetch on enable) is awaited by callers and tests alike. `currentUsage` is `usage[snapshot.current ?? "(signed in)"]`, the entry the strip reads. Refresh runs `refresh()` then `refreshUsage()`; while `cliStatus` is not `.ready`, `refresh()` re-probes instead of calling `list --json`, so a `brew upgrade` is picked up without a relaunch. It talks to the CLI only through `protocol CommandRunner { func run(_ args: [String]) async throws -> Data }`, with a `makeRunner: (AppSettings) -> CommandRunner?` factory; tests use a fake. The real runner kills a command that runs longer than 120 s (a Keychain prompt left unanswered) and reports `.timedOut`. Percentages floor, as the CLI's text output does, and the danger colour starts at 90 on the floored value. While `cliStatus` is not `.ready` the strip shows `CLI` over `?`.

## Distribution

- `scripts/build-app.sh` produces `dist/Claude Multipass.app`, signed when an identity exists, unsigned otherwise (the ai-kb script's behaviour), with the version read from `package.json`. `--dmg` adds `dist/claude-multipass-app_<version>_arm64.dmg` with an `/Applications` symlink, signed, notarized and stapled when the API key env vars are set.
- `scripts/sign-mac-app.sh` is ai-kb's script with one addition, an optional `MACOS_SIGN_ENTITLEMENTS` file passed to `codesign` for `sign-app`, reformatted by prettier, on the house `#!/bin/bash` shebang, and with the `APPLE_API_*` reads written as `${VAR:-}` (the repo's `check-unassigned-uppercase` flags them otherwise, measured). The DMG is notarized and stapled; the app inside carries the ticket online but is not stapled itself, so a first launch with no network shows the Gatekeeper delay. Accepted for this version.
- `release.yml` runs on tags `v*`, imports the certificate from `MACOS_CERT_P12` and `MACOS_CERT_PASSWORD`, builds with `--dmg`, and uploads the DMG and `.sha256` to the GitHub release with `gh` (`GH_TOKEN: ${{ github.token }}`). Secrets are the ones ai-kb already uses; the maintainer copies them into this repository.
- The tap gains `Casks/claude-multipass-app.rb` (the folder does not exist yet) with `depends_on formula: "jrmatherly/tap/claude-multipass"` and `depends_on arch: :arm64`. The cask token differs from the formula name so `brew install jrmatherly/tap/claude-multipass` keeps meaning the CLI. The formula is bumped before the cask at release time, or the app reports the CLI as too old.
- The release skill gains the cask steps and the version bump in both the script and `package.json`.

## Gate

`pnpm check` adds `scripts/*.sh` to the ShellCheck list, asserts that `version=` in the script equals `package.json`'s version, and runs `swift test --package-path app` with the Swift Testing plugin path when the Command Line Tools provide it (a debug build; the release build happens only in `build-app.sh`). The lint-on-edit hook's path regex and the commit-gate hook's timeout (180 s today, 600 s after) move with it. CI already runs on `macos-latest`, where Swift is present. The first local run adds about a minute; later runs are incremental. Tests compare version strings against `package.json`, not a literal, so a release bump does not break them.

## Rails

The rails are rewritten in the same commit as the app package scaffold, before any polling code lands. Every line that contradicts the app, found by grep on 2026-10-25:

- `.claude/rules/safety-and-terms.md` line 22 ("Never poll it"), line 31 ("runs only when asked … never a daemon"), line 37 ("Any daemon, launch agent, cron entry, menu bar loop"), line 38 ("Polling `security`").
- `.claude/rules/desktop-internals.md` line 17 ("Never poll it", which keeps the securityd crash fact and becomes "at most one call per 5 minutes").
- `CLAUDE.md` line 60 (the `usage` bullet, "run only when asked, never a daemon").
- `README.md` line 25 ("no daemon runs").
- `docs/claude-multipass.md` Safety rails and Usage headroom sections.
- `bin/claude-multipass` `usage()` Cautions ("only runs when you ask for it").
- `.serena/memories/task_completion.md` ("no daemon").

The new wording, in each place at the depth that file uses:

- Allowed: the menu bar app polls `list --json` on a timer. It reads `config.json` and `meta.json`, never the Keychain. Usage polling is opt-in, through `usage --json`, with an interval of at least 5 minutes, one `security` call per run, and stops when the user turns it off.
- Still rejected: any automatic switch; usage polling that is on by default or faster than 5 minutes; a launch agent or daemon separate from the user-visible app; reading the Keychain anywhere but inside `usage`.

## Out of scope

Drag reorder of modules, a custom app icon, Sparkle, a widget, a universal (Intel) build, `add` from the app (it needs the user to sign in with an email code in Desktop; the CLI flow stays), per-org session counts in the popover, localisation.

## Manual checks an agent may not run

From `CLAUDE.md`: an agent never runs `save`, `add`, `switch`, `remove` or `sync` against the real Desktop, and leaves `usage` (which prompts for the Keychain) to the user. So in the plan's manual checks an agent builds and launches the app, reads the strip and the popover, opens and cancels the inline confirm, and stops there. Pressing Switch, enabling usage, and toggling Launch at login are the maintainer's steps. A throwaway bundle must have Launch at login turned off before it is deleted, or `SMAppService` keeps a dangling login item.
