# claude-multipass

`claude-multipass` switches the Claude Desktop app between several claude.ai accounts without an email code, and keeps every account's Claude Code sessions listed in the Code tab after a switch. It is for one Mac with several accounts (personal, work, a second personal plan). `claude-multipass --help` prints the command reference; this page says how it works, what carries over, and what to do when something is off.

## Summary

- A Desktop login is three keys of `config.json` plus the cookie files, all encrypted by the app with a key in this Mac's login Keychain. The script copies them as opaque bytes into a named profile and swaps them back on `switch`. Nothing is decrypted for that.
- The Claude Code CLI (the `claude` command) has its own login: a login-Keychain item with its OAuth tokens and an `oauthAccount` block in `~/.claude.json`. `save` copies the tokens into a Keychain item of the tool's own, named after the profile, and the identity block into the profile's `cli.json`, when the CLI is signed in as the same account as Desktop. Otherwise it saves Desktop only and says so.
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
| `list` | Saved accounts with a short account id, save time and Code-session count; `*` marks the signed-in one. `--json` prints one object: `version`, `signedIn`, `desktopRunning`, `current` (`null` when the login has no name) and `profiles` (`name`, `account`, `savedAt`, `null` when the profile records none, `sessions`, `cliSaved`). A profile whose `meta.json` cannot be read is skipped with a warning on stderr, so one bad file never empties the list |
| `show <name>` | One account, whether it holds a CLI login, and its session count per organization folder |
| `save <name>` | Snapshot the current login as `<name>`: Desktop's, and the CLI's when `claude` is signed in as the same account (a warning says when it is not, and the profile's earlier CLI login stays). Refuses a name that holds a different account or an unreadable `meta.json`, and a second name for an account already saved under another (two names would leave one with stale tokens); `--force` replaces that profile and keeps it in the backups folder (a second name's replaced profile hands its CLI login to the new name when the terminal cannot supply one) |
| `add <name>` | Re-save the current login, clear it locally, relaunch at the sign-in screen. Then sign in, run `claude auth login` for the terminal, and run `save <name>`. `add` leaves the CLI's login alone. Refuses to clear a login you never saved; `--force` clears it |
| `switch <name>` | Quit Desktop, re-save the outgoing login, swap in `<name>`, merge the session lists, relaunch. The CLI login moves too when the profile holds one (the live CLI item and `oauthAccount` are backed up first; see below for what a warning means). Refuses to drop a login you never saved; `--force` drops it |
| `sync` | Only the session-list merge. Needs Desktop quit, or `--force` |
| `rename <old> <new>` | Rename a profile, its CLI login item with it |
| `remove <name>` | Move a profile to the backups folder and delete its CLI login item (the CLI token is not recoverable from the backup; the Desktop login is) |
| `current` | The signed-in saved name, `not saved` or `signed out` (for scripts and Raycast) |
| `usage [name]` | 5-hour and weekly usage per saved account with reset times. Opt-in, see below. `--json` prints the figures as one object |
| `pick` | The fzf picker |
| `doctor` | One `ok:`, `warn:` or `fail:` line per check (config, tools, store and profile modes, each profile's token, backups, Desktop running, the pre-0.1 store, profiles without a CLI login, `CLAUDE_CONFIG_DIR` or `CLAUDE_SECURESTORAGE_CONFIG_DIR`). Exits 1 on any `fail:`. No Keychain, no network |
| `--version` | Print the version |

`--no-relaunch` leaves Desktop quit after `save`, `switch` or `add`.

## What carries over, and what does not

| Context | Where it lives | After a switch |
| --- | --- | --- |
| Claude Code sessions (Code tab and terminal) | `~/.claude/projects/<folder>/<session>.jsonl`, one store for every account | Available. `switch` adds the other account's entries to the Code tab's list. Whether Desktop's cross-session tools read the copied entries is not yet checked |
| The terminal's `claude` login | The login-Keychain item `Claude Code-credentials` (tokens) and `oauthAccount` in `~/.claude.json` (account, org) | Moves with the profile when it holds a CLI login: `switch` swaps the account part of the item and the `oauthAccount` block, under the CLI's own lock dirs, and keeps the shared MCP keys. A `claude` process already running keeps its old token and can write it back on its next refresh, so quit terminal sessions first; `switch` warns when one runs. The Code tab is unchanged |
| The remember plugin's handoff and auto memory | The repo's `.remember/` and `~/.claude/projects/<folder>/memory/` | Available; both key on the project folder, not the account |
| Desktop projects (Cowork spaces) | `local-agent-mode-sessions/<account>/<org>/spaces.json` | Not synced yet; a copied session shows outside its project grouping |
| claude.ai chats, Projects, memory | Anthropic's servers, per account | Stay with their account. Export memory with the verbatim prompt and import it on the other account by hand |

## Raycast

Three script commands in `raycast/` wrap the tool for Raycast: **Claude Account** (the signed-in name in Root Search), **Claude Account Usage** (opt-in, with the 5-hour and weekly figures) and **Switch Claude Account**. They call `claude-multipass` by name with Homebrew's bin on PATH. Copy them once to a folder you own, `mkdir -p ~/.config/claude-multipass/raycast && cp -R "$(brew --prefix)/share/claude-multipass/raycast/." ~/.config/claude-multipass/raycast` (Homebrew's `share` path is a symlink into a versioned folder that changes on upgrade, and the macOS picker hides `/opt`), then add that folder: Raycast, **Settings, Script Commands, Add Script Directory**, Cmd+Shift+G in the picker, `~/.config/claude-multipass/raycast`. A repo checkout's `raycast/` folder works too. Do not use **Developer, Import Extension**: that imports a packaged extension, not a script directory. Save each account first with `claude-multipass save {{name}}`.

## Menu bar app

**Claude Multipass** (`app/`, a Swift package; the bundle comes from `scripts/build-app.sh`) is a menu bar front end over the same `claude-multipass` command. The bash script stays the only code that touches Desktop's files; the app runs it as a subprocess, with `list --json`, `usage --json`, `switch` and `save`, and needs 0.3.0 or newer. Install it with `brew install --cask jrmatherly/tap/claude-multipass-app`; the cask depends on the formula.

The strip is an icon plus two-line modules, each with its own toggle in Settings: `@` over the signed-in saved name (`not saved`, `signed out`, names longer than 16 characters truncated), and with usage on, `5H` and `7D` capsule bars with the percentage (red from 90 %), and `5H↻` and `7D↻` reset countdowns. Unknown values show `–`. While the tool is missing or too old the strip shows `CLI` over `?` and the popover shows the install or upgrade line.

The popover (left click) lists the saved accounts with session counts (`· CLI` after the count when the profile holds the terminal's login) and, when usage is on, `5h 42%  7d 12%` per account. A warning the tool prints while a switch or save succeeds, such as `switched Desktop only`, shows under that row until the next action. Clicking another account expands an inline confirm; Switch runs `claude-multipass switch <name>`, so Desktop quits and relaunches, and the row shows a spinner meanwhile. A refusal (exit 3, for example when the signed-in login was never saved) shows the tool's message with a "Switch anyway" button that reruns with `--force`; any other failure shows the message with Retry. Commands that never prompt (`list`, `show`, `current`, `doctor`, `--version`) time out after 2 minutes; `save`, `switch`, `usage` and the other commands get 10 minutes, since they can wait on an Automation or Keychain prompt. A timeout kills the tool and every process it started (`osascript`, `security`). When the signed-in login has no name, a "Save this login as…" row runs `save <name>` for a name the tool accepts. Right click: Refresh, Settings, Quit. Settings: the usage toggle and interval, one toggle per module, Launch at login, and the tool's path (auto-detected in Homebrew's bin, shown beside the version; an override field for another copy).

Refresh cadence:

| What | Command | When |
| --- | --- | --- |
| Snapshot (accounts, signed-in state, Desktop running) | `list --json` | every 30 s, on popover open, after a switch or save, on Refresh; reads `config.json` and `meta.json`, never the Keychain |
| Usage figures | `usage --json` | only when usage is on: every 5, 15, 30 or 60 minutes, once when turned on, on Refresh; one Keychain read per run |
| Strip redraw and countdowns | none | every 3 s from cached data |

A failed usage fetch clears the usage figures, so old numbers never read as current, and its error stays in the popover until a usage fetch succeeds or usage is turned off; a snapshot success does not hide it.

Turning a module on or off never fetches usage. Nothing in the app runs `switch` without a click. The first switch raises the macOS Automation prompt, "Claude Multipass wants to control Claude", because the app is the responsible process for the tool's `osascript` quit; allow it, or every switch falls back to the tool's `pkill` after 8 s. Revisit it under System Settings, Privacy & Security, Automation. The first switch that moves a CLI login may raise a Keychain prompt naming `security`; click Always Allow, which persists, or the switch finishes Desktop only with the reason in its warning. The items are written through the same `security` tool Claude Code reads and writes its own item with, so `claude` raises no prompt of its own after a switch. A profile item 0.3.2 saved stays in the `python3` partition until 0.3.3 saves it again, which the re-save on the way out of the next switch does. Until then a switch to that profile may ask once or twice to let `security` use the item (Always Allow, then the login password), and a `login-*` backup item 0.3.2 wrote may ask once when the prune deletes it. The first launch of a downloaded build needs the network once, for Gatekeeper to check the notarization ticket (the DMG is notarized and stapled; the app inside carries the ticket online).

## Usage headroom

`usage` reads each saved account's 5-hour and weekly utilization from Anthropic's OAuth usage endpoint. To do that it decrypts the saved token cache with the app's own key: the "Claude Safe Storage" password from the login Keychain (macOS asks once; click Always Allow), stretched with PBKDF2 and used as an AES-128-CBC key, the same scheme Chromium uses. The fetches run in parallel, one key derivation serves them all, and nothing prints a token.

`usage --json` prints the same figures for scripts and the menu bar app: `{"profiles":[...]}` with one entry per account, either `{"name","fiveHour","sevenDay"}` (each window `{"utilization","resetsAt"}`, `resetsAt` in UTC ending in `Z`, a window left out when its utilization is null) or `{"name","error"}` with the same reason text the plain command prints. The unsaved live login appears as `(signed in)`. With nothing to report it prints `{"profiles":[]}`.

This is the one part of the tool that uses a subscription token outside Anthropic's own apps. Third-party coverage says Anthropic's terms discourage that pattern; it is read-only, the CLI runs it only when you ask for it, and the menu bar app polls it only after you turn usage on there (at least 5 minutes apart, one Keychain read per run). The call is yours. Desktop's own usage ring and Claude Code's `/usage` still work after a switch without it.

## Where things live

| Path | Holds |
| --- | --- |
| `~/.config/claude-multipass/profiles/<name>/` | A profile: `config.json` (the three login keys), `Cookies`, `Cookies-journal`, `meta.json` (account id, save time), `cli.json` (the CLI's `oauthAccount` block, no secret). Mode 0600. The CLI's tokens for the profile are a login-Keychain item, service `claude-multipass`, account `<name>` |
| `~/.config/claude-multipass/backups/login-*/` | The login each `switch` or `add` replaced, newest ten |
| `~/.config/claude-multipass/backups/profile-*/` | Profiles that `remove` or a forced `save` set aside |
| `~/Library/Application Support/Claude/` | Desktop's data: `config.json`, the cookie files, `claude-code-sessions/<account>/<org>/local_*.json` (the Code tab's list) |
| `~/.claude.json` and the login Keychain | The CLI's data: `oauthAccount` in the file, the tokens in the Keychain item `Claude Code-credentials` (account: your macOS user name). The tool's own items are service `claude-multipass`, one per profile and one per `login-*` backup folder whose switch wrote the CLI item. A backup's item holds the account part only, as a profile's does. `CLAUDE_CLI_CONFIG` and `CLAUDE_CLI_HOME` point at another file and CLI home (the self-check uses them) |

`CLAUDE_MULTIPASS_DIR` moves the profile and backup folders (`XDG_CONFIG_HOME` moves their default parent); `CLAUDE_DESKTOP_DIR` points at another Desktop data folder. A store left by the tool's earlier life as `claude-desktop-account` in a dotfiles repo (`dotfiles/claude-desktop-accounts` and its `-backups` sibling under `XDG_CONFIG_HOME`, `~/.config` by default) is moved into the new location on the first run that finds it, and the run says so. When a `backups` folder already exists in the new location, the legacy `-backups` folder stays where it was and the run warns.

## When something is off

- Start with `claude-multipass doctor`. It prints one line per check and names the profile that needs a re-save.
- Desktop relaunches signed in as the wrong account after `add` or `switch`: the previous login is under the backups folder. Copy its `config.json` keys and cookie files back by hand, or run `switch` to the profile you want.
- A switch died midway: run the same `switch` again. When the account already matches, it restores the profile's cookies if the live `Cookies` file is missing (live cookies stay, since Desktop may have rotated them) and repairs the CLI login.
- After a `switch` writes the CLI login (a repair included), the tool runs `claude auth status` and warns when the CLI reports signed out (`Claude Code reports it is signed out`) or another org (`Claude Code reports a different org`), or when the check itself fails. The previous login is in the backup folder the warning names. Run `claude auth login`, then `save <name>`. A CLI already signed in as the target account is re-saved, not written, so no check runs.
- `usage` says `token expired, sign in and re-save`: sign in to that account in Desktop (through `switch` or `add`) and run `save <name>` again.
- `switch` said `switched Desktop only`: the restore of the target's CLI login was skipped and the reason is in the same line (no CLI login saved for that profile, its Keychain item missing, no `~/.claude.json` because the CLI never ran on this Mac, a corrupt `~/.claude.json` or live item, `CLAUDE_CONFIG_DIR` or `CLAUDE_SECURESTORAGE_CONFIG_DIR` set, a Keychain call that failed). `<name>: ... saved the Desktop login only` is the re-save of the profile you are leaving: the CLI was signed in as another account or signed out, so that profile's earlier CLI login was kept; the target's login is still restored, replacing the live one (backed up first). Run `claude auth login` for the account you want, then `save <name>`; from then on the next `switch` away from it captures the login through the re-save.
- `claude` fails with `invalid_grant` after a switch, possibly hours later when its access token expires: the likely cause is a saved refresh token the CLI rotated past in a session the tool did not see (not yet measured on a real round trip). Run `claude auth login`, then `save <name>`.
- The previous CLI login is in the backup folder `switch` named: `oauthAccount` in its `cli.json`, the tokens in the Keychain item `claude-multipass` / `login-<timestamp>-<pid>`. A removed profile's CLI token is not recoverable from `backups/profile-*`; its Desktop login is.
- The Code tab does not list the other account's sessions: quit Desktop and run `sync`, then reopen. Sessions deleted in any account stay deleted.

## Safety rails

- `save` never overwrites a profile that holds another account without `--force`.
- `save` never gives one account a second name without `--force`.
- `switch` and `add` never drop an unsaved login without `--force`.
- Every write of `config.json` goes through a temp file and keeps the app's other keys byte for byte; every replaced login is backed up first.
- `~/.claude.json` is written only while the CLI's own lock dirs are held (`~/.claude/.oauth_refresh.lock`, `~/.claude.lock`, `~/.claude.json.lock`; a busy CLI fails the switch before Desktop's config moves, and the dirs are touched every 3 s while held so the CLI never deems them stale), only its `oauthAccount` key changes, and the live CLI item and identity are backed up first. The CLI token never appears in output or in a log. It goes to `security -i` as hex on stdin when the line fits, and on `security`'s own command line otherwise, exactly as Claude Code writes its item; no other tool touches the items, because an item written from another partition prompts on every read.
- A CLI login that does not belong to the profile (another account, signed out, `CLAUDE_CONFIG_DIR` or `CLAUDE_SECURESTORAGE_CONFIG_DIR` set) is never captured over a saved one, and a CLI already on the target account is re-saved, never overwritten. A profile holds every key of the CLI item except the five shared MCP and plugin keys, which stay with the live item, so an account-scoped key the tool does not know still moves with its account.
- `sync` never deletes; it honours `deleted_<id>` tombstones.
- A failure after the app was quit still relaunches it.
- The menu bar app polls `list --json` on a timer; that reads `config.json` and `meta.json`, never the Keychain. Usage polling is opt-in, through `usage --json`, with an interval of at least 5 minutes, one `security` call per run, and stops when the user turns it off. Keychain reads and writes happen only inside `save`, `add` (its re-save and the backup prune), `switch`, `rename`, `remove` and the backup prune, for the CLI login item and the tool's own items. Still rejected: any automatic switch; usage polling that is on by default or faster than 5 minutes; a launch agent or daemon separate from the user-visible app; reading the Keychain anywhere else.
- Refusals that `--force` lifts exit 3, so a caller can offer the override; other failures exit 1, and a usage error (an unknown command, a bare run without a terminal or `fzf`) exits 2. A refused `save` is decided before Desktop quits.
- One writing run at a time. `save`, `switch`, `add`, `sync`, `rename` and `remove` take a run lock (`.run.lock` beside `profiles/`, a symlink to the holder's pid) before anything else, and a second run refuses with exit 1, `Another claude-multipass run (pid N) is changing accounts`, before it quits Desktop. So a terminal switch waiting on a Keychain prompt and a menu bar or Raycast switch never interleave, and the loser never relaunches Desktop under the winner. `--force` does not lift it. A lock whose holder is gone (killed before its trap ran), or whose pid now belongs to another program, is swept. `list`, `show`, `current`, `usage` and `doctor` take no lock.
- A secret never passes through a here-string or heredoc: bash 3.2 backs both with a regular temp file on disk, so tokens and the decrypted token cache reach `jq` and `security` through pipes.
- `save`, `switch` and `add` refuse (exit 1) from a shell that Desktop owns, such as the Code tab's terminal: quitting Desktop would end that shell mid-switch. BSD `pgrep` never reports its own ancestors, so the tool checks with `pgrep -a` too; run those commands from Terminal or the menu bar app.

The self-check `test/claude-multipass.sh` runs in `pnpm check` against a fixture folder, with `pgrep`, `osascript`, `pkill`, `open`, `fzf`, `security`, `curl`, `claude` and `sleep` stubbed on PATH, so it never touches the real app, Keychain or network.

## Background

The mechanism follows two audited open-source tools, [snlperstripes/claude-account-switcher](https://github.com/SnlperStripes/claude-account-switcher) (Desktop login swap and session-list sync) and the token scheme shared by [realiti4/claude-swap](https://github.com/realiti4/claude-swap) and [XueshiQiao/CCSwitcher](https://github.com/XueshiQiao/CCSwitcher). The research behind it, including the alternatives considered and the open questions, is in [research.md](research.md).
