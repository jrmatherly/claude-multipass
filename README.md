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

A Desktop login is three keys of `~/Library/Application Support/Claude/config.json` plus the cookie files, encrypted by the app with a key in this Mac's login Keychain. `save` copies them as opaque bytes into a named profile; `switch` quits Desktop, re-saves the login you are leaving, swaps the saved one in, merges every account's Code-tab session list into every other account's, and relaunches. Nothing is decrypted for that, no daemon runs, and nothing switches on its own.

Claude Code transcripts live in `~/.claude/projects`, shared by every account, so a session started under one account can be continued under another. Chats, Projects and memory on claude.ai stay with their account.

[docs/claude-multipass.md](docs/claude-multipass.md) has the full command table, what carries over, the folders, the safety rails and the recovery steps. `claude-multipass --help` prints the command reference. [docs/research.md](docs/research.md) is the research the tool was built from, including the alternatives and the open questions.

## Commands

| Command | What it does |
| --- | --- |
| `list`, `show <name>`, `current` | What is saved and which account is signed in |
| `save`, `add`, `switch`, `remove`, `rename` | Manage saved logins; `save`, `add` and `switch` quit and relaunch Desktop |
| `sync` | Only the session-list merge (Desktop must be quit, or `--force`) |
| `usage [name]` | 5-hour and weekly usage per saved account. Opt-in: it decrypts the saved token with the app's Keychain key and reads Anthropic's OAuth usage endpoint outside the app, which third-party coverage says Anthropic's terms discourage. Read-only, runs only when asked |
| `pick` | The fzf picker (also a bare invocation on a terminal) |

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

## Development

`pnpm check` is the gate: `bash -n`, ShellCheck, Prettier, the fixture self-check (`test/claude-multipass.sh`, which stubs the app, Keychain and network and never touches the real Desktop folder) and the Claude Code hook self-checks. CI runs it on macOS for every pull request and push to `main`.

The mechanism follows [SnlperStripes/claude-account-switcher](https://github.com/SnlperStripes/claude-account-switcher) (Desktop login swap and session-list sync) and the token scheme shared by [realiti4/claude-swap](https://github.com/realiti4/claude-swap) and [XueshiQiao/CCSwitcher](https://github.com/XueshiQiao/CCSwitcher). MIT licence.
