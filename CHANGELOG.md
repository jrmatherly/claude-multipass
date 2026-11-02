# Changelog

## Unreleased

- A Claude Code login that Claude Code itself cleared (both tokens empty, which it does to a login the server rejected) counts as signed out. `save` and the re-save on a switch warn `Claude Code cleared its login; switch to <name>, run claude auth login, then save <name>` and keep the profile's saved CLI login, and a `switch` to the same account restores the saved login instead of keeping the cleared one.

## 0.10.2 (2026-11-01)

- A warning a switch or save leaves in the popover clears on Refresh, and when you close a popover that opened on it. Desktop takes focus and closes the popover just after a switch, so a warning that arrives then shows at the next open. It describes the moment of the switch, such as a Claude Code process that has since quit, and used to stay until the next switch.

## 0.10.1 (2026-11-01)

- The app and the tool work as in 0.10.0. This is the first version 0.10.0 can install by itself, from Check now and Update and relaunch in Settings, About.
- The release build tries a signature again when Apple's timestamp service returns none, and says why when the Keychain lookup or the notarization submission fails.

## 0.10.0 (2026-11-01)

- The menu bar app checks for a newer version at launch and once a day, by reading one public file, the tap's `appcast.xml`. It sends no account data and reads no Keychain item. Nothing installs without a click.
- Settings, About shows a badge beside the version when a newer one exists, the change log for every version you skipped, and an Update and relaunch button. A Homebrew install updates through `brew`, and an install from the DMG updates in place. Check now runs a check on demand, and a toggle turns the daily check off. While an update is on offer, the popover footer and the right-click menu each have a line that opens About, and it says "Updating…" during an install and "Update failed" after one. If the updater cannot start, About says why and links to the release page.
- The menu bar app has an icon: two open rings with a dot passing through the gap, taken from the menu bar gauge. On macOS 26 and later it has a dark version and a tinted one, and earlier versions get an `.icns`. The bundle had no icon, so launchers showed a blank tile.
- The menu bar app carries the tool inside its bundle and uses that copy when no Homebrew tool is found, so a DMG install works without Homebrew and no longer shows `CLI ?`. On macOS 14, and on any Mac without `/usr/bin/jq`, it also needs `jq`, and turning usage on needs the Command Line Tools. A Homebrew tool still wins, so the app and the terminal run the same script.
- Without a working `jq`, every command but `--version`, `--help` and `doctor` exits 1 with a message naming `jq`, before Desktop quits. `current` printed `signed out` for a signed-in login, and `add` skipped its unsaved-login refusal and quit Desktop. `doctor` without a working `jq` says it did not check the config or the saved tokens, and no longer calls each token empty.
- `save`, `switch` and `add` exit 1 before Desktop quits on a `config.json` that `jq` cannot read as one object, and `--force` does not lift it. `list`, `current` and `usage` answer on such a file as before, and `doctor` reports it as a `fail:` line.
- `usage` without the Command Line Tools exits 1 and says it needs them, before any Keychain read. It blamed the Keychain, because the `/usr/bin/python3` shim failed in the same step.

## 0.9.0 (2026-10-31)

- With usage on, hovering a "Switch to" row with a fetched report shows a small panel beside the popover with that account's plan and weekly reset, then its 5-hour countdown and bars or its fetch error. The row's tooltip is gone, since a tooltip never showed in this popover while the app was inactive. The figures come from the last fetch, so hovering starts no fetch.

## 0.8.0 (2026-10-31)

- The popover header shows the day and time the weekly limit resets beside the plan name, and an Ultra account with no 5-hour limit no longer has a row saying so, since the header already names the plan. Only the 5-hour bar still names its reset.
- "Switch to" rows show the fuller of the 5-hour and weekly limits, where they showed only the weekly one, and a second bar for the fullest per-model limit, so an account with a full Fable or 5-hour limit no longer looks healthy.
- The menu bar ring has two layers: the outer ring and the strip percentage show the fuller of the 5-hour and weekly limits, and an inner ring shows the fullest per-model limit. A full Fable limit drew a full red ring reading `100%`, as if the account were out, while other models still worked. When a per-model limit is the fullest, the percentage now shows the account figure, where 0.7.0 showed the per-model one.

## 0.7.0 (2026-10-31)

- `usage` and the menu bar app show the per-model weekly limit (Fable on Max and Ultra) beside the 5-hour and weekly ones, and the ring fills to the fullest of them. A reached Fable limit showed as nothing, because the endpoint reports it only in its `limits` list. An odd window or reset time no longer costs the account. A non-object window or a non-string reset time dropped it from `usage --json`. A non-numeric utilization or a reset time with an offset failed the menu bar app's whole usage read. The text output shows an unreadable window as `?`.
- `usage` reads each account's plan name from the OAuth profile endpoint at most once a day, or an hour after a failed request while no name is cached. An Ultra account whose 5-hour window is missing or idle with no reset shows `Ultra` in place of the 5-hour figure. That is how a verified Ultra account, which has no 5-hour limit, reports. The popover shows the plan beside the account name and a row reading Ultra, no 5-hour limit in place of the 5-hour bar.

## 0.6.1 (2026-10-29)

- The backup prune in `switch`, `add`, `remove` and `save --force` keeps the folder it has just made whatever the clock says. Before, a Mac with its clock set back pruned that folder first, because the prune ordered folders by the timestamp in their names alone.

## 0.6.0 (2026-10-29)

- The menu bar app runs `usage --json` for a Refresh click at most once per 30 seconds. Every click ran it, one Keychain read and one usage request per account each time.
- `remove` and `save --force` keep the newest ten set-aside profiles under `backups/profile-*`, as `backups/login-*` already keeps ten logins; `doctor` counts both. Set-aside profiles were never pruned.
- After a switch, a Claude Code using an API key, an `apiKeyHelper`, a `CLAUDE_CODE_OAUTH_TOKEN` or a third-party provider is reported as such instead of as "a different org". The org in `claude auth status` is that credential's, not the login the switch wrote.
- The menu bar app's Launch at login toggle shows on, with a note, while macOS holds the login item for approval under System Settings, General, Login Items. It showed off, and a second toggle registered the item again.

## 0.5.2 (2026-10-28)

- `doctor` on a store with no `backups/` folder, such as a fresh install, prints every check and exits 0. It stopped after the store line with exit 1 and no `fail:` line.
- A Ctrl-C, a SIGTERM or a failed quit while `save`, `switch` or `add` waits for Desktop to quit now relaunches Desktop. The relaunch trap was set only after the quit finished, so Desktop stayed quit.
- Profile names must start with a letter or digit, in the tool and in the menu bar app's "Save this login as" row. A name such as `.foo` was accepted but never shown by `list`, `current` or the unsaved-login check, which skip dot folders.
- `doctor` warns when `claude` is not on PATH, since a switch then cannot verify the terminal login, and when `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` is set, since either overrides the terminal login.
- The menu bar app tells a failed version check apart from an old tool. A `claude-multipass --version` that exits non-zero (a missing `jq`), times out or prints no version line showed "too old, brew upgrade"; the popover now shows the error and the Settings General tab reads `failed: <error>`.
- The menu bar app no longer hangs in the switching phase when a command exits while a grandchild still holds its output pipe; it takes what was read after 2 s.
- A switch or save from the menu bar app waits for a usage run in flight to finish, so a usage run sitting on a Keychain prompt no longer gets a second prompt beside it.

## 0.5.1 (2026-10-27)

- The Settings About tab's documentation link reads "Open on GitHub" with an outward arrow instead of the file name `claude-multipass.md`.

## 0.5.0 (2026-10-27)

- The menu bar app is redesigned. The strip is one line: a ring filled to the fuller of the 5-hour and weekly limits (orange from 70 %, red from 90 %), the account name and the percentage, or the ring or name alone. The popover leads with the signed-in account's two usage bars, reset times and when usage was last fetched, then a "Switch to" list with each account's weekly figure, in the tool's order with no ranking. Settings has General, Menu Bar, Usage and About tabs, and the tool path field appears only for a custom location. Quit moves to the right-click menu. Saved settings carry over: any usage cell on becomes the ring style, otherwise name only.
- Tokens and the decrypted Desktop token cache reach other commands through a pipe, never a here-string. Under the system bash 3.2 a here-string is a temp file in `/var/tmp`, so `save`, `switch`, `rename` and `usage` wrote secrets to disk for a moment.
- One `save`, `switch`, `add`, `sync`, `rename` or `remove` runs at a time. A second run exits 1 naming the first run's pid, before it quits Desktop. Two at once, such as a terminal switch waiting on a Keychain prompt and a menu bar switch, let the second relaunch Desktop while the first still wrote `config.json`.
- The menu bar app drops a usage result that arrives after usage was turned off, and no longer restarts the usage timer then. It showed a usage error, or figures, with usage off.
- The menu bar app pauses its account and usage polls while a switch or save runs, and reloads the account list once the switch ends, even when a poll was in flight. The popover could show the state from mid-switch for up to 30 s. It also reloads after a failed switch, which may have quit and relaunched Desktop.
- The app inside the DMG is notarized and stapled on its own, so a copy dragged out of the image opens offline on first launch.
- A release builds only from a tag on a commit in `main` whose version matches the top CHANGELOG heading, and never replaces a DMG it already published, so the cask's sha256 stays valid.

## 0.4.0 (2026-10-27)

- After a `switch`, a signed-out terminal `claude` is reported as `Claude Code reports it is signed out`. `claude auth status` exits 1 when signed out, so the tool said only that the check exited 1; it now reads the JSON before the exit code.
- `save` over a profile whose `meta.json` cannot be read refuses with a message naming the file (exit 3, before Desktop quits), and `--force` moves that profile to `backups/` and saves fresh. It failed with a raw `jq` error, and with `--force` only after quitting Desktop, so `save` could not repair it.
- The menu bar app gives `usage` the 10-minute limit too, since its Safe Storage read can wait on a Keychain prompt.
- `save` refuses a second name for an account already saved under another name (exit 3, before Desktop quits). Two names for one account made `switch` to the second restore its older tokens. `--force` moves the other profile to `backups/` and saves under the new name, which keeps the other name's CLI login when the terminal is on another account.
- `add` refuses to clear a login that was never saved (exit 3), as `switch` does; it only warned before. `--force` clears it anyway, and `--help` now lists `--force` on `save`, `switch` and `add`.
- `list` and `list --json` skip a profile whose `meta.json` cannot be read, with a warning, instead of failing (exit 5). `list --json` sends a missing `savedAt` as `null`, not the string `"null"`.
- The menu bar app decodes `savedAt` leniently, so one profile without a save time no longer empties the account list.
- The menu bar app gives `save`, `switch` and the other commands that quit Desktop 10 minutes instead of 2, since they can wait on an Automation or Keychain prompt. A timeout now SIGKILLs the tool's whole process group, so an `osascript` or `security` child that outlives the SIGTERM is gone too.
- A failed usage fetch in the menu bar app clears the old usage figures, and its error stays shown until a usage fetch succeeds or usage is turned off. A snapshot success used to hide it.
- `switch` and `save` honour all three of the CLI's lock dirs. Only `~/.claude.json.lock` stopped them before; a held `~/.claude/.oauth_refresh.lock` or `~/.claude.lock` was ignored. A switch now fails naming the held lock, and a save keeps the Desktop login only.
- The backup prune no longer splits a store path that holds a space. Before, it could `rm -rf` a sibling folder named after the path's first word.
- `switch` to the account already signed in keeps the live cookies, which Desktop may have rotated since the save, and copies the profile's only when the live `Cookies` file is missing.
- Opening the menu bar popover refreshes the account list only. It ran `usage --json` too, so each open read the Keychain and the usage endpoint outside the 5-minute usage interval.
- `show`, `usage` and `switch` given a profile whose `meta.json` cannot be read fail with a message naming the file. `show` died with a raw `jq` parse error (exit 5), `usage` printed nothing, and `switch` quit Desktop before failing on it.
- A Keychain read that fails with `security` exit 36 now says the keychain is locked and the failure is transient (unlock it and retry).
- `--help` no longer lists `--no-relaunch` for `remove`, which never quits Desktop.
- The menu bar app's Settings asks for claude-multipass 0.3.0 or newer, the version it checks for; it said 0.2.0.
- The release workflow builds and signs with a read-only token and hands the DMG to a separate job, the only one that can write to the release. CI and the release build run on the `macos-26` image instead of `macos-latest`, and `.nvmrc` pins Node 24.

## 0.3.4 (2026-10-26)

- `save` and `switch` leave the CLI login alone, with a warning, when `CLAUDE_SECURESTORAGE_CONFIG_DIR` is set: Claude Code 2.1.310 keeps its item under a suffixed name then. `doctor` warns about it.
- A profile's CLI item now keeps every account-scoped key (2.1.310 adds `trustedDeviceEnrolledAfterRefusalAtMs`); only the shared MCP and plugin keys stay in the live item.
- `switch` and `save` keep the CLI's lock dirs fresh while they hold them (Claude Code treats `~/.claude.json.lock` as stale after 10 s), and the running-CLI warning mentions the CLI's 30 s login cache.

## 0.3.3 (2026-10-26)

- The CLI login moves through `security` again, and only through it. 0.3.2 read and wrote the Keychain items from the system `python3`, which left every item it wrote in another partition than `/usr/bin/security`, so Claude Code's own reads asked for the login password on every run, Always Allow could not stop it, and after Claude Code's next write the tool asked again. Items are now read with `security find-generic-password -w` and written exactly as Claude Code writes its own: the hex on a `security -i` stdin line when the line fits, on `security`'s own command line otherwise, so no item is too large. The Command Line Tools are needed for `usage` only. A profile item 0.3.2 saved stays in the `python3` partition until 0.3.3 saves it again, which the re-save on the way out of the next switch does. Until then a switch to that profile may ask once or twice to let `security` use the item (click Always Allow and enter the login password), and a `login-*` backup item 0.3.2 wrote may ask once when the prune deletes it. Claude Code's own item asks once only if 0.3.2 wrote it last.
- A Keychain read decodes the hex `security -w` prints for a value with a non-ASCII byte, so a live item with such an MCP value still moves. A Keychain failure still names its reason (a declined prompt, a cancelled prompt, no prompt possible over SSH or from a timer).
- A backup's Keychain item holds the account part of the CLI login only (`claudeAiOauth`, `trustedDeviceToken`), as a profile does; the shared MCP keys stay in the live item.
- `switch` warns when `claude auth status` reports it is signed out after the restore, naming the backup, instead of reporting a different org.
- The Raycast commands run `$CLAUDE_MULTIPASS_BIN` when it is set, else `claude-multipass` by name, so the self-check's Raycast cases run the checkout. On a Mac with an older tool installed, the old fixture ran the installed tool against the fixture and reached the real Keychain. Nothing changes for Raycast.

## 0.3.2 (2026-10-26)

- The CLI login now moves whatever its size. 0.3.0 wrote Keychain items through `security -i`, which holds at most 4019 bytes of a line, and a real item with MCP logins is about 15 KB, so a switch on a Mac with MCP logins said `too large for security -i; switched Desktop only`. Items are read and written through the Security framework from the system `python3`, the value on stdin, so the Command Line Tools are now required and `doctor` checks for them. A Keychain failure names its OSStatus and what to do (a declined prompt, no prompt possible over SSH).

## 0.3.1 (2026-10-26)

- `save`, `switch` and `add` refuse from a shell that Desktop owns (the Code tab's terminal). BSD `pgrep` hides its own ancestors, so 0.3.0 and earlier took Desktop for not running there and rewrote its login under the live app, which kept its own.

## 0.3.0 (2026-10-26)

- `save` also captures the Claude Code CLI's terminal login (the Keychain item's tokens into a Keychain item of the tool's own, the `oauthAccount` identity into the profile's `cli.json`) when the CLI is signed in as the same account as Desktop, and `switch` restores it under the CLI's own locks, keeping the shared MCP keys. A CLI already on the target account is re-saved, never overwritten. The live CLI login is backed up beside the Desktop backup.
- `save`, and the re-save on the way out of a switch, keep a profile's earlier CLI login and warn when the CLI is signed in as another account or signed out. `switch` restores the target's CLI login over whatever the live item held (backed up first) and moves Desktop only, with a warning, when the profile has no CLI login, its Keychain item is missing, `~/.claude.json` is absent or corrupt, `CLAUDE_CONFIG_DIR` is set, the item is too large for `security -i`, or a `security` call fails. `switch` warns when a `claude` process is running and when `claude auth status` reports another org after the restore.
- `rename` moves the profile's CLI item; `remove` and a forced `save` delete it; `doctor` names profiles without a CLI login; `list --json` gains `cliSaved` and `show` prints the CLI login state; `add` says to run `claude auth login` before `save`.
- The menu bar app shows `· CLI` on profiles with a CLI login, shows the tool's warnings under the row after a switch or save, finds the native `claude` in `~/.local/bin`, and needs tool 0.3.0 or newer.
- The self-check's `security` stub is stateful and the script reads `CLAUDE_CLI_CONFIG` and `CLAUDE_CLI_HOME`, so the real `~/.claude.json` and Keychain are never touched.

## 0.2.2 (2026-10-26)

- The "Save this login as" row keeps showing a failed save's message while the name is edited; it used to vanish on the first keystroke.
- `list --json` builds its output in memory; a failure midway no longer leaves a temp file behind.
- `scripts/build-app.sh` names the DMG after the architecture of the machine that built it, not a fixed `arm64`.
- The Raycast commands print an install hint instead of bash's "command not found" when `claude-multipass` is not on their PATH.
- The one-time store migration warns when it leaves the legacy `-backups` folder behind because a `backups` folder already exists.
- The README and docs copy the Raycast folder's contents, so a second copy no longer nests `raycast/raycast`.

## 0.2.1 (2026-10-26)

- Settings shows the path of the detected command line tool beside its version.
- The popover opens flush under the menu bar item; it used to be placed for a default 320 pt height and then shrink, leaving a gap.

## 0.2.0 (2026-10-26)

A menu bar app joins the command line tool. Both are per Mac, as before.

- Claude Multipass, a signed and notarized menu bar app for Apple Silicon on macOS 14 or newer: `brew install --cask jrmatherly/tap/claude-multipass-app`. The strip shows the signed-in saved account; a left click opens a popover that lists every saved account with its Code session count and switches with an inline confirm (a refusal such as an unsaved login offers "Switch anyway"); a right click gives Refresh, Settings and Quit. Settings has Launch at login and the tool's path. The app drives `claude-multipass` and needs 0.2.0 or newer.
- Usage in the menu bar (5-hour and weekly bars, reset countdowns) is off by default. Turning it on in Settings polls `usage --json` at least 5 minutes apart, with the same Keychain prompt and the same caution as the `usage` command. The first switch from the app raises the macOS Automation prompt once ("Claude Multipass wants to control Claude"); allow it, or Desktop is force-quit after 8 s instead of asked to quit.
- `--version` prints the version.
- `list --json` and `usage --json` print the saved accounts and the usage figures as JSON, for scripts and the app. The first-run store migration message moves to stderr.
- `doctor` checks the setup (Desktop's `config.json`, the tools on PATH, store and profile modes, each profile's token, the backups count) and prints one `ok:`, `warn:` or `fail:` line per check.
- Refusals that `--force` lifts (`save` over another account, `switch` from an unsaved login, `sync` while Desktop runs) exit 3; other failures exit 1. A refused `save` no longer quits and relaunches Desktop.

## 0.1.0 (2026-10-25)

First release as its own project. The tool lived as `bin/claude-desktop-account` in [jrmatherly/dotfiles](https://github.com/jrmatherly/dotfiles) from 2026-10-23.

- Renamed to `claude-multipass`; the profile store moves from `~/.config/dotfiles/claude-desktop-accounts` to `~/.config/claude-multipass/profiles` (with `backups/` beside it) once, automatically, on the first run that finds the old store.
- `XDG_CONFIG_HOME` is honoured for the store's default parent.
- The Raycast scripts call `claude-multipass` by name, with Homebrew's bin on PATH for Apple Silicon and Intel. Copy them to `~/.config/claude-multipass/raycast` before adding them to Raycast; the Homebrew `share` path changes on upgrade.
