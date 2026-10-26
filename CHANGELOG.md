# Changelog

## Unreleased

- The "Save this login as" row keeps showing a failed save's message while the name is edited; it used to vanish on the first keystroke.
- `list --json` builds its output in memory; a failure midway no longer leaves a temp file behind.
- `scripts/build-app.sh` names the DMG after the architecture of the machine that built it, not a fixed `arm64`.

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
