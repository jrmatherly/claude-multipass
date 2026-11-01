# In-app updates design

Status: awaiting Jason's review. Evidence labels: **measured** (run on this Mac on 2026-10-31, macOS 27.2), **source** (read in the vendor's code or docs), **inferred**, **not proven**.

## Goal

Settings, About tells the user when a newer version exists, shows a badge beside the version and the change log for every version they skipped, and applies the update with one click. Homebrew installs and installs from the DMG both work.

Two other things change for the people involved:

- A DMG install becomes usable on its own. Today it shows `CLI ?` forever, because the app only finds a tool in Homebrew's folders or at a custom path.
- A maintainer gains a gate. A signed release can be tested as a real update before any user is told about it.

## Decision

Sparkle plus brew, as Jason decided. The two installers sit behind one state machine and one UI.

| Install | Who updates | What moves |
| --- | --- | --- |
| Cask | `brew`, after a click | Formula, then app |
| DMG, no Homebrew | Sparkle, after a click | App, with the tool inside it |
| DMG plus the formula | Sparkle for the app | App only; the formula stays on `brew upgrade`, and the 0.3.0 floor catches skew |
| Development build | Nobody | About keeps showing `development build` |

## Sparkle's terms

Sparkle 2.10.1 can be used here. Its `LICENSE` is MIT plus third-party notices (bsdiff, sais-lite and others), and it permits redistribution in binaries when the notices ship with them (**source**). The app ships the file as `Contents/Resources/Sparkle-LICENSE`. GitHub reports the repository's license as `NOASSERTION` because of the extra notices, not because of a restriction (**inferred**). The project is active: last pushed 2026-10-25 (**measured**).

## Design

### The feed

There is one feed: `https://raw.githubusercontent.com/jrmatherly/homebrew-tap/HEAD/appcast.xml`. It lands in the same tap commit as the cask and formula bump.

- That commit is the announcement. "Newest version" and "brew can install it" cannot disagree. The measured gap between a GitHub release and its tap commit was 2.5 min for 0.9.0 and 53 min for 0.8.0, so `releases/latest` would announce versions brew cannot install.
- It adds a gate. The DMG and appcast exist on the release before anyone is told, so a real older app can update from that release's own `appcast.xml` first. Setting `SUFeedURL` in `defaults` points it there, with no server (**measured**, including a real GitHub release asset as the feed).
- It gives a rollback. Reverting the tap commit stops new offers on both routes.
- GitHub serves the file as `text/plain` with `max-age=300`, and Sparkle parsed such a file (**measured**, with Sparkle's own sample appcast).

The cost is that DMG users wait for the human tap bump, and the tap's name and path are frozen in shipped binaries.

The item's `description` holds the whole `CHANGELOG.md` with `sparkle:format="markdown"`. A 20 KB appcast parsed and all 19,717 characters of the change log reached `itemDescription` (**measured**). The app filters to the sections newer than the running version, so skipped versions need no second fetch and the feed holds no state between releases.

### Routing

Read from disk at each click, never stored. A menu bar app runs for weeks, and brew can appear under it.

- `homebrew`: a `<prefix>/Caskroom/claude-multipass-app/*/Claude Multipass.app` symlink resolves to this bundle and `<prefix>/bin/brew` is executable. That symlink exists on a real install (**measured**).
- `homebrewMissing`: the same symlink with no `brew`. About says so and offers the download. Sparkle must not overwrite a bundle brew owns.
- `development`: no `CFBundleShortVersionString`, or the bundle is not an `.app`.
- `direct`: everything else.

A cask install never runs Sparkle's installer, so brew's version record stays true and the cask keeps no `auto_updates`. With `auto_updates true`, a plain `brew upgrade` would skip the cask (**source**).

### The tool

`bin/claude-multipass` is copied to `Contents/Resources/claude-multipass`, last in precedence: override, `/opt/homebrew/bin`, `/usr/local/bin`, bundled.

- A brew tool wins, so the app and the terminal run the same script.
- The file name satisfies the run lock's sweep, which looks for `claude-multipass` in the holder's command (`bin/claude-multipass:1328`).
- Sparkle replaces it with the bundle, so it cannot skew from the app.
- A quarantined script in a signed bundle ran with exit 0 (**measured**, un-notarized). The real notarized case is checked in `release.yml` and at the gate.
- Terminal and Raycast users on a DMG install get one documented `ln -s` line. The app writes nothing to PATH.

Default: `jq` is not bundled. macOS 15 and later has `/usr/bin/jq` (**measured** on this Mac's 27.2; the version floor is **inferred**). A macOS 14 install without Homebrew sees the tool's own `jq` error, and the docs name the requirement.

### State

```swift
public enum UpdateState: Equatable {
  case idle, checking
  case upToDate(Date)
  case available(UpdateOffer)
  case installing(UpdateOffer, InstallStage)
  case failed(UpdateOffer?, UpdateProblem)   // the offer survives a failed check
}
```

- `MultipassCore` holds this, `UpdateController` and `BrewInstaller`, all tested with fakes. Sparkle cannot enter Core, so `UpdateFeed` and `Installer` are protocols there.
- `ClaudeMultipass/SparkleUpdater.swift` is the only file that imports Sparkle. It implements both protocols.
- `Phase.updating` is the one lock. `act`, `refresh`, `refreshUsage`, `AccountRow` and `SaveRow` all test `phase == .idle`, and nothing in `Sources` switches over `Phase` (**measured**), so all of them block with no edit.

### UI

A custom `SPUUserDriver`, not Sparkle's windows. Brew needs inline UI anyway, so the standard windows would add a second UI for one button. The driver is 15 methods and worked end to end (**measured**).

About, top to bottom:

```text
Claude Multipass        0.10.0   [0.11.0 available]
What's new              0.11.0 (2026-11-02) ...   (scrolls, every skipped version)
                        [Update and relaunch]     Updates with Homebrew
Updates                 Checked 2 h ago  [Check now]
                        [x] Check for updates once a day
Documentation           Open on GitHub
```

The popover footer gets one line and the right-click menu one item while an offer stands, both opening About, because a badge only in Settings is rarely seen. The menu bar strip stays about accounts. During an install the button becomes a stage line and account rows grey out.

### Checks

At launch, then every 24 h, through the app's own task. Default: on, with a toggle in About, because it reads one public file and sends no account data. This is the app's first network call of its own, so it is Jason's to confirm. Sparkle's scheduler stays off (`SUEnableAutomaticChecks=false`: no prompt, no scheduled check, **measured**). `checkForUpdateInformation()` is the silent probe and fires `didFindValidUpdate` with no driver UI (**measured**). A scheduled failure changes nothing on screen; Check now shows it and keeps any offer.

## Measured behaviour

| Fact | Result |
| --- | --- |
| Sparkle through SwiftPM on the command line, with an rpath from `unsafeFlags` | Builds, signs and runs |
| Real package with Sparkle on the executable target | 130 existing tests pass, 40 s cold; first resolve downloads 10 MB |
| Signing with `XPCServices` removed: `Autoupdate`, `Updater.app`, framework, app | `codesign --verify --deep --strict` passes; prototype app 2.7 MB |
| Sparkle update from a UDZO DMG, scratch folder and `/Applications` | Passes and relaunches; inode changes; login item stays enabled |
| Bad EdDSA signature; EdDSA-signed DMG of another app | Both rejected with 4005; disk unchanged where checked |
| Feed unreachable or malformed | `didAbortWithError` 2001, then `didFinishUpdateCycleFor` with 2001 |
| Feed same or older (a rollback) | `didNotFind` and `didAbort` 1001, then `didFinishUpdateCycleFor` with 1001 |
| App 0.9.0, feed 0.10.0 | Found: Sparkle compares numerically |
| Probe, then install, in one process | Passes; `didFindValidUpdate` fires twice |
| Second probe during a session | `canCheckForUpdates` is false and the call does nothing |
| App run from a read-only DMG | Probe fails with 1003 |
| A `@MainActor` class conforming to `SPUUserDriver`, `SPUUpdaterDelegate` and both protocols | Compiles clean in Swift 5 mode |
| Plain HTTP to `127.0.0.1` with no App Transport Security key | Works; a `file://` feed fails with 2001 |
| Local 302 to the appcast; real `github.com/.../latest/download` enclosure | Both followed |
| `SUFeedURL` in `defaults` | Overrides the plist, so a released build can be pointed at one release's asset |
| `sign_update --ed-key-file -` with the key on stdin; `--verify` | Signs with no temp file; good exit 0, bad exit 1 |
| `brew upgrade` from a Developer ID app with stdin null, notarized DMGs | Exit 0 in 7 s, in place, no sudo |
| Running app replaced by brew, then a detached `sleep 1; open` | Stays alive through the swap; the new version launches; login item stays enabled |
| `brew upgrade formula cask` with both current | Exit 0, a warning on stderr |
| launchd during a Sparkle install | Transient jobs `<bundle id>-sparkle-updater` and `-sparkle-progress`; gone afterwards; no new file in `~/Library/LaunchAgents` |

## Not proven

- **App Management on a real installed app.** The probe's control did not fire: an ad-hoc signed app could also write into throwaway apps, notarized copy included, so the probe cannot show that same-team signing is what lets brew through. Secondary sources say it does. A denial reaches the failed state with the exact command to copy. The first real upgrade settles it.
- **Sparkle with a notarized, stapled, quarantined app.** Needs notarization, which only CI has. The gate in `release` step 7a settles it for 0.10.1, with no user exposed.
- **The cask route in the real app.** `brew` from a signed app and a replaced running app were measured on scratch apps, not through `BrewInstaller`, and the rehearsal cannot run it because the package names are fixed. The wait-for-exit relaunch was measured as a script only. The first real upgrade proves it, and a failure there leaves the copyable command.
- **Brew's relaunch prompt on the real app.** Brew carries the user's approval forward when the signer is unchanged (**source**), and the real app's quarantine flags include that bit (`01c1`, **measured**), so no prompt is expected (**inferred**).

## Bootstrap

Installs at 0.9.0 or older have no updater. They reach 0.10.0 by `brew upgrade` or a new DMG. 0.10.0 proves the build and the probe; 0.10.1 is the first real update and passes through the gate.

## Risks a maintainer inherits

- **The EdDSA seed has no recovery.** Losing it strands DMG installs on one manual download with a new key. Brew installs are unaffected. Jason keeps it in the GitHub secret and 1Password.
- **A mismatched secret strands updates silently.** Nothing compares the CI secret with the shipped public key at build time. The gate catches it, because a real build rejects the signature before anything is announced.
- **Three frozen formats:** the tap's raw path, `CHANGELOG.md` headings (already gated by `release.yml`), and Sparkle's driver protocol, pinned at an exact version.
- **`brew update` touches every tap the user has.** It only runs after a click, and `HOMEBREW_NO_INSTALL_CLEANUP` bounds what follows.

## Rejected

| Alternative | Why |
| --- | --- |
| `releases/latest/download/appcast.xml` | Announces before brew can install, and needs a second feed or a "catching up" state |
| Per-route feeds (raw cask file for brew, appcast for Sparkle) | A second parser and a second notes source, to work around what one tap file removes |
| CI pushes to the tap | Adds a write token and removes the human audit and the gate |
| Launch journal, stderr classifier, relaunch watchdog | Each handles a failure a disk read or Sparkle's own error already reports |
| Cancel button | Killing brew between removing and placing a bundle is the one way to lose the app |
| Bundled `jq` | A second signed binary with its own update duty, for one OS version |
| Signed feed (`SURequireSignedFeed`) | The update itself is already EdDSA-signed. Without it, someone controlling the tap could only change the offer's text and version, and that person already controls what brew installs |
| Newest of the two tools wins | The tool would change under a terminal user with no action of theirs |

## Out of scope

Automatic install, beta channels, delta updates, skip-this-version, macOS notifications and a menu bar badge.
