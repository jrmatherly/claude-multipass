# claude-multipass

`claude-multipass` switches the Claude Desktop app between several claude.ai accounts without an email code, and keeps every account's Claude Code sessions listed in the Code tab after a switch. It is for one Mac with several accounts (personal, work, a second personal plan). `claude-multipass --help` prints the command reference; this page says how it works, what carries over, and what to do when something is off.

## Summary

- A Desktop login is three keys of `config.json` plus the cookie files, all encrypted by the app with a key in this Mac's login Keychain. The script copies them as opaque bytes into a named profile and swaps them back on `switch`. Nothing is decrypted for that.
- Claude Code transcripts live in `~/.claude/projects`, shared by every account. Only the Code tab's per-account session list differs, and `switch` merges every account's list entries into every account, so a session started under one account shows up under the other.
- Chats, Projects and memory on the claude.ai side stay per account. They do not move.
- Profiles are per Mac. Save each account once on each Mac you use.
- Never use the app's own Log out to change accounts; it may revoke the saved token on the server. Use `add` or `switch`.

## First run

```sh
claude-multipass save personal # the account Desktop is signed in as now
claude-multipass add work      # Desktop relaunches at its sign-in screen
# sign in with the email code (not Google, whose browser hand-back can land in the wrong window)
claude-multipass save work
claude-multipass list
```

From then on, when one account hits its 5-hour or weekly limit:

```sh
claude-multipass switch personal
```

Desktop quits, relaunches signed in as that account, and the Code tab lists both accounts' sessions. Open the session you were in and continue. Running `claude-multipass` with no arguments on a terminal opens an fzf picker over the saved accounts instead.

## Commands

| Command | What it does |
| --- | --- |
| `list` | Saved accounts with a short account id, save time and Code-session count; `*` marks the signed-in one |
| `show <name>` | One account, with its session count per organization folder |
| `save <name>` | Snapshot the current login as `<name>`. Refuses a name that holds a different account; `--force` replaces it and keeps the old profile in the backups folder |
| `add <name>` | Re-save the current login, clear it locally, relaunch at the sign-in screen. Then sign in and run `save <name>` |
| `switch <name>` | Quit Desktop, re-save the outgoing login, swap in `<name>`, merge the session lists, relaunch. Refuses to drop a login you never saved; `--force` drops it |
| `sync` | Only the session-list merge. Needs Desktop quit, or `--force` |
| `rename <old> <new>` | Rename a profile |
| `remove <name>` | Move a profile to the backups folder |
| `current` | The signed-in saved name, `not saved` or `signed out` (for scripts and Raycast) |
| `usage [name]` | 5-hour and weekly usage per saved account with reset times. Opt-in, see below |
| `pick` | The fzf picker |

`--no-relaunch` leaves Desktop quit after `save`, `switch` or `add`.

## What carries over, and what does not

| Context | Where it lives | After a switch |
| --- | --- | --- |
| Claude Code sessions (Code tab and terminal) | `~/.claude/projects/<folder>/<session>.jsonl`, one store for every account | Available. `switch` adds the other account's entries to the Code tab's list, and Desktop's "what did the other session do" tools see them |
| The remember plugin's handoff and auto memory | The repo's `.remember/` and `~/.claude/projects/<folder>/memory/` | Available; both key on the project folder, not the account |
| Desktop projects (Cowork spaces) | `local-agent-mode-sessions/<account>/<org>/spaces.json` | Not synced yet; a copied session shows outside its project grouping |
| claude.ai chats, Projects, memory | Anthropic's servers, per account | Stay with their account. Export memory with the verbatim prompt and import it on the other account by hand |

## Raycast

Three script commands in `raycast/` wrap the tool for Raycast: **Claude Account** (the signed-in name in Root Search), **Claude Account Usage** (opt-in, with the 5-hour and weekly figures) and **Switch Claude Account**. They call `claude-multipass` by name with Homebrew's bin on PATH. Copy them once to a folder you own, `cp -R "$(brew --prefix)/share/claude-multipass/raycast" ~/.config/claude-multipass/raycast` (Homebrew's `share` path is a symlink into a versioned folder that changes on upgrade, and the macOS picker hides `/opt`), then add that folder: Raycast, **Settings, Script Commands, Add Script Directory**, Cmd+Shift+G in the picker, `~/.config/claude-multipass/raycast`. A repo checkout's `raycast/` folder works too. Do not use **Developer, Import Extension**: that imports a packaged extension, not a script directory. Save each account first with `claude-multipass save {{name}}`.

## Usage headroom

`usage` reads each saved account's 5-hour and weekly utilization from Anthropic's OAuth usage endpoint. To do that it decrypts the saved token cache with the app's own key: the "Claude Safe Storage" password from the login Keychain (macOS asks once; click Always Allow), stretched with PBKDF2 and used as an AES-128-CBC key, the same scheme Chromium uses. The fetches run in parallel, one key derivation serves them all, and nothing prints a token.

This is the one part of the tool that uses a subscription token outside Anthropic's own apps. Third-party coverage says Anthropic's terms discourage that pattern; it is read-only and runs only when you ask for it, and the call is yours. Desktop's own usage ring and Claude Code's `/usage` still work after a switch without it.

## Where things live

| Path | Holds |
| --- | --- |
| `~/.config/claude-multipass/profiles/<name>/` | A profile: `config.json` (the three login keys), `Cookies`, `Cookies-journal`, `meta.json` (account id, save time). Mode 0600 |
| `~/.config/claude-multipass/backups/login-*/` | The login each `switch` or `add` replaced, newest ten |
| `~/.config/claude-multipass/backups/profile-*/` | Profiles that `remove` or a forced `save` set aside |
| `~/Library/Application Support/Claude/` | Desktop's data: `config.json`, the cookie files, `claude-code-sessions/<account>/<org>/local_*.json` (the Code tab's list) |

`CLAUDE_MULTIPASS_DIR` moves the profile and backup folders (`XDG_CONFIG_HOME` moves their default parent); `CLAUDE_DESKTOP_DIR` points at another Desktop data folder. A store left by the tool's earlier life as `claude-desktop-account` in a dotfiles repo (`~/.config/dotfiles/claude-desktop-accounts` and its `-backups` sibling) is moved into the new location on the first run that finds it, and the run says so.

## When something is off

- Desktop relaunches signed in as the wrong account after `add` or `switch`: the previous login is under the backups folder. Copy its `config.json` keys and cookie files back by hand, or run `switch` to the profile you want.
- A switch died midway: run the same `switch` again. It re-copies the cookies even when the account already matches.
- `usage` says `token expired, sign in and re-save`: sign in to that account in Desktop (through `switch` or `add`) and run `save <name>` again.
- The Code tab does not list the other account's sessions: quit Desktop and run `sync`, then reopen. Sessions deleted in any account stay deleted.

## Safety rails

- `save` never overwrites a profile that holds another account without `--force`.
- `switch` never drops an unsaved login without `--force`.
- Every write of `config.json` goes through a temp file and keeps the app's other keys byte for byte; every replaced login is backed up first.
- `sync` never deletes; it honours `deleted_<id>` tombstones.
- A failure after the app was quit still relaunches it.

The self-check `test/claude-multipass.sh` runs in `pnpm check` against a fixture folder, with `pgrep`, `osascript`, `pkill`, `open`, `fzf`, `security` and `curl` stubbed on PATH, so it never touches the real app, Keychain or network.

## Background

The mechanism follows two audited open-source tools, [snlperstripes/claude-account-switcher](https://github.com/SnlperStripes/claude-account-switcher) (Desktop login swap and session-list sync) and the token scheme shared by [realiti4/claude-swap](https://github.com/realiti4/claude-swap) and [XueshiQiao/CCSwitcher](https://github.com/XueshiQiao/CCSwitcher). The research behind it, including the alternatives considered and the open questions, is in [research.md](research.md).
