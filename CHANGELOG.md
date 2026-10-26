# Changelog

## 0.3.2 (unreleased)

- The CLI login now moves whatever its size. 0.3.0 wrote Keychain items through `security -i`, which holds at most 4019 bytes of a line, and a real item with MCP logins is about 15 KB, so every switch said `too large for security -i; switched Desktop only`. Items are read and written through the Security framework from the system `python3`, the value on stdin.

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
