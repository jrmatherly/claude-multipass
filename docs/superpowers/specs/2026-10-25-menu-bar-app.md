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

- This Mac has macOS 27.0.1, Swift 6.4 and the Command Line Tools only, no Xcode. `swift build` compiles a SwiftUI `MenuBarExtra` app in 28 s and `swift test` runs Swift Testing. XCTest is unavailable (unresolved module). So the app is a Swift package built by `swift build`, assembled into a bundle by a script, with Swift Testing for unit tests and no `.xcodeproj`.
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
2. Saved accounts: one row per profile with name, session count and, when usage is on, `5h 42%  7d 12%` (or `–`). The current one is marked. Clicking another row asks: "Switch to work? Claude Desktop quits and relaunches signed in as work. Its Code tab will list every saved account's sessions." Buttons Switch, Cancel.
3. During a switch every control is disabled and the row shows a spinner with "Switching to work…". The CLI takes 5 to 20 s because it quits and relaunches Desktop.
4. When the CLI refuses (exit code 3, see below) the error text is shown with a second button, "Switch anyway", which reruns with `--force`. Any other failure shows the CLI's stderr and a Retry button.
5. When signed in but not saved: a "Save this login as…" row with a name field (same character rule as the CLI, `^[A-Za-z0-9._-]+$`) that runs `save <name>`.
6. Footer: Refresh, Settings…, Quit.

Right click on the icon: a native menu with Refresh, Settings…, Quit.

### Settings window

- Usage: toggle "Show usage (reads the saved tokens through the Keychain and Anthropic's usage endpoint; see the caution)", interval picker 5/15/30/60 min, a link to the caution text from `claude-multipass --help`.
- Menu bar: one toggle per module.
- General: Launch at login (`SMAppService.mainApp`), CLI path (auto-detected, with an override field and the detected version).

### Refresh cadence

- Snapshot (`list --json`): every 30 s, on popover open, after every switch or save, and on Refresh. No Keychain.
- Usage (`usage --json`): only when enabled, every N minutes, on Refresh, and once when enabled. One `security` call per run, inside the CLI. Never more often than every 5 minutes on a timer.
- Countdowns recompute every 60 s from the cached `resetsAt`.
- Nothing in the app ever runs `switch` without a click.

### Failure surfaces

- CLI not found: the popover shows "Install the CLI: `brew install jrmatherly/tap/claude-multipass`" and Settings lets the user pick a path.
- CLI older than 0.2.0 (no `--json`): "Update the CLI: `brew upgrade claude-multipass`".
- Usage error for one profile (cannot decrypt, 401, 429, offline): that profile shows `–` with the reason in a tooltip. The next attempt is the next scheduled tick, never an immediate retry.

## CLI changes (`bin/claude-multipass`, version 0.2.0)

- `--version` prints `claude-multipass 0.2.0`. A `version=` constant near the top is bumped by the release skill.
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

  The unsaved signed-in login appears as `"name": "(signed in)"`, as in the text output. `resetsAt` is omitted when the endpoint gives none.

- Exit code 3 for the three refusals that `--force` lifts (`save` over another account, `switch` away from an unsaved login, `sync` while Desktop runs). Exit 1 stays for every other failure, exit 2 for usage errors.
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

Bundle identifier `net.matherly.claude-multipass` (the ai-kb convention), display name `Claude Multipass`, `LSUIElement` true, minimum macOS 14.0. No custom app icon in this version. No Sparkle; updates come through Homebrew.

Data shape in `MultipassCore`:

```swift
struct Snapshot: Decodable, Equatable { version, signedIn, desktopRunning, current: String?, profiles: [Profile] }
struct Profile: Decodable, Equatable, Identifiable { name, account, savedAt: Date, sessions: Int }   // id = name
struct UsageReport: Decodable, Equatable { profiles: [UsageEntry] }
struct UsageEntry: Decodable, Equatable, Identifiable { name, fiveHour: Window?, sevenDay: Window?, error: String? }
struct Window: Decodable, Equatable { utilization: Double, resetsAt: Date? }
enum Phase: Equatable { case idle, refreshing, switching(String), saving(String) }
enum CLIError: Error, Equatable { case notFound, tooOld(String), refused(String), failed(status: Int32, stderr: String), badJSON(String) }
```

`AppState` is a `@MainActor` `ObservableObject` holding `snapshot`, `usage`, `phase`, `lastError`, `pendingForce: String?`, the settings, and the timers. It talks to the CLI only through `protocol CommandRunner { func run(_ args: [String]) async throws -> Data }`, so tests use a fake.

## Distribution

- `scripts/build-app.sh` produces `dist/Claude Multipass.app`, signed when an identity exists, unsigned otherwise (the ai-kb script's behaviour). `--dmg` adds `dist/claude-multipass-app_<version>_arm64.dmg` with an `/Applications` symlink, signed, notarized and stapled when the API key env vars are set.
- `release.yml` runs on tags `v*`, imports the certificate from `MACOS_CERT_P12` and `MACOS_CERT_PASSWORD`, builds with `--dmg`, and uploads the DMG and `.sha256` to the GitHub release. Secrets are the ones ai-kb already uses; the maintainer copies them into this repository.
- The tap gains `Casks/claude-multipass-app.rb` with `depends_on formula: "jrmatherly/tap/claude-multipass"`. The cask token differs from the formula name so `brew install jrmatherly/tap/claude-multipass` keeps meaning the CLI (inferred; `brew audit --cask` in the release task verifies it).
- The release skill gains the cask steps and the version constant bump.

## Gate

`pnpm check` adds `scripts/*.sh` to the ShellCheck list and runs `swift build --package-path app` and `swift test --package-path app`. CI already runs on `macos-latest`, where Swift is present. The first local run adds about a minute; later runs are incremental.

## Rails

`.claude/rules/safety-and-terms.md` and `CLAUDE.md` are rewritten so the rail says what is now allowed and what is still rejected:

- Allowed: the menu bar app polls `list --json` on a timer. It reads `config.json` and `meta.json`, never the Keychain. Usage polling is opt-in, through `usage --json`, with an interval of at least 5 minutes, and stops when the user turns it off.
- Still rejected: any automatic switch; usage polling that is on by default or faster than 5 minutes; a launch agent or daemon separate from the user-visible app; reading the Keychain anywhere but inside `usage`.

## Out of scope

Drag reorder of modules, a custom app icon, Sparkle, a widget, `add` from the app (it needs the user to sign in with an email code in Desktop; the CLI flow stays), per-org session counts in the popover, localisation.
