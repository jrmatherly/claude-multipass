# Changelog

## 0.2.0 (unreleased)

- `--version` prints the version.
- Refusals that `--force` lifts (`save` over another account, `switch` from an unsaved login, `sync` while Desktop runs) exit 3; other failures exit 1. A refused `save` no longer quits and relaunches Desktop.

## 0.1.0 (2026-10-25)

First release as its own project. The tool lived as `bin/claude-desktop-account` in [jrmatherly/dotfiles](https://github.com/jrmatherly/dotfiles) from 2026-10-23.

- Renamed to `claude-multipass`; the profile store moves from `~/.config/dotfiles/claude-desktop-accounts` to `~/.config/claude-multipass/profiles` (with `backups/` beside it) once, automatically, on the first run that finds the old store.
- `XDG_CONFIG_HOME` is honoured for the store's default parent.
- The Raycast scripts call `claude-multipass` by name, with Homebrew's bin on PATH for Apple Silicon and Intel. Copy them to `~/.config/claude-multipass/raycast` before adding them to Raycast; the Homebrew `share` path changes on upgrade.
