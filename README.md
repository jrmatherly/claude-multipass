# claude-multipass

Switch the Claude Desktop app on macOS between several claude.ai accounts without typing an email code each time, and keep every account's Claude Code sessions listed in the Code tab after a switch.

It is for one Mac with more than one account (personal, work, a second plan): when one hits its 5-hour or weekly limit, switch to the other and carry on in the same Code session.

```sh
claude-multipass save personal   # once: the account Desktop is signed in as
claude-multipass add work        # once: relaunches at the sign-in screen
claude-multipass save work       # once: after signing in with the email code
claude-multipass switch personal # every day: no email code, both accounts' sessions listed
claude-multipass                 # or pick one in fzf
```

## Install

```sh
brew install jrmatherly/tap/claude-multipass
```

Needs `jq` (installed with it); `fzf` for the picker; the system `python3`, `openssl` and `curl` for the opt-in `usage` command. Or clone the repo and put `bin/claude-multipass` on your PATH.

## How it works

A Desktop login is three keys of `~/Library/Application Support/Claude/config.json` plus the cookie files, encrypted by the app with a key in this Mac's login Keychain. `save` copies them as opaque bytes into a named profile; `switch` quits Desktop, re-saves the login you are leaving, swaps the saved one in, merges every account's Code-tab session list into every other account's, and relaunches. Nothing is decrypted for that, and nothing switches on its own. The menu bar app only polls `list --json` (no Keychain) and, when you turn usage on, `usage --json` at most every 5 minutes.

Claude Code transcripts live in `~/.claude/projects`, shared by every account, so a session started under one account can be continued under another. Chats, Projects and memory on claude.ai stay with their account.

[docs/claude-multipass.md](docs/claude-multipass.md) has the full command table, what carries over, the folders, the safety rails and the recovery steps. `claude-multipass --help` prints the command reference. [docs/research.md](docs/research.md) is the research the tool was built from, including the alternatives and the open questions.

## Commands

| Command | What it does |
| --- | --- |
| `list`, `show <name>`, `current` | What is saved and which account is signed in. `list --json` prints one object for scripts and the menu bar app |
| `save`, `add`, `switch`, `remove`, `rename` | Manage saved logins; `save`, `add` and `switch` quit and relaunch Desktop |
| `sync` | Only the session-list merge (Desktop must be quit, or `--force`) |
| `usage [name]` | 5-hour and weekly usage per saved account. Opt-in: it decrypts the saved token with the app's Keychain key and reads Anthropic's OAuth usage endpoint outside the app, which third-party coverage says Anthropic's terms discourage. Read-only, runs only when asked |
| `pick` | The fzf picker (also a bare invocation on a terminal) |
| `doctor` | Check the setup: config, tools, store modes, profile tokens. Exits 1 on any `fail:` line |

`--no-relaunch` leaves Desktop quit; `--force` overrides the refusals named in `--help`.

## Cautions

- Never use Desktop's own **Log out** to change accounts; it may revoke the saved token on the server. Use `add` or `switch`.
- Sign in with the email code, not Google, so the browser hand-back lands in the right window.
- Profiles are per Mac: the app's Keychain key encrypts them. Save each account once on every Mac.
- Whether to run several accounts, and `usage`, is your call under Anthropic's terms. This tool keeps switching manual and never rotates accounts by itself.

## Raycast

`raycast/` holds three script commands (current account, usage, switch). Copy them to a folder you own, because Homebrew's `share` path is a symlink into a versioned folder that changes on upgrade and the macOS picker hides `/opt`:

```sh
cp -R "$(brew --prefix)/share/claude-multipass/raycast" ~/.config/claude-multipass/raycast
```

Then in Raycast, **Settings, Script Commands, Add Script Directory**, press Cmd+Shift+G in the picker and enter `~/.config/claude-multipass/raycast`.

## Menu bar app

**Claude Multipass** is a menu bar app over the same tool. The strip shows an icon and `@` over the signed-in saved account (`not saved` or `signed out` otherwise). A left click opens a popover with every saved account and its Code session count; clicking another account expands an inline confirm, and Switch runs `claude-multipass switch` (Desktop quits and relaunches). A right click gives Refresh, Settings and Quit. Install:

```sh
brew install --cask jrmatherly/tap/claude-multipass-app
```

The cask depends on the `claude-multipass` formula and the app needs 0.2.0 or newer; it says so in the popover when the tool is missing or older. The first launch of a downloaded build needs the network once, for Gatekeeper to check the notarization ticket.

Usage in the menu bar (5-hour and weekly bars and reset countdowns) is off by default. Turning it on in Settings has the same caution as the `usage` command: the app runs `claude-multipass usage --json` on a timer, at least 5 minutes apart, which decrypts the saved tokens through this Mac's Keychain (one prompt the first time; click Always Allow) and reads Anthropic's usage endpoint outside the app. Turn it off and the polling stops.

## Development

`pnpm check` is the gate: `bash -n`, ShellCheck, Prettier, the fixture self-check (`test/claude-multipass.sh`, which stubs the app, Keychain and network and never touches the real Desktop folder) and the Claude Code hook self-checks. CI runs it on macOS for every pull request and push to `main`.

The mechanism follows [SnlperStripes/claude-account-switcher](https://github.com/SnlperStripes/claude-account-switcher) (Desktop login swap and session-list sync) and the token scheme shared by [realiti4/claude-swap](https://github.com/realiti4/claude-swap) and [XueshiQiao/CCSwitcher](https://github.com/XueshiQiao/CCSwitcher). MIT licence.
