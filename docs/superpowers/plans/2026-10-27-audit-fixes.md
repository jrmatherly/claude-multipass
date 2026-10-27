# Audit fixes plan

The 2026-10-27 audit found six confirmed defects, six narrower ones and a set of docs and hygiene gaps. This plan fixes them in three tiers and five PRs. A tier starts only after the previous tier's PRs merge, because the tiers edit the same files. Each PR adds a test case for every behaviour it changes, as CLAUDE.md requires.

Order. T1a and T1b in parallel, then T2, then T3a and T3b in parallel.

## How to read this

One box is one unit of work. Check a box only when its evidence exists, such as a test case, a command output or a SHA. Each tier runs in its own session under `/jstack:j-mode` (the Bug fix playbook for defects). Every code PR goes on its own branch and worktree, runs `pnpm install` first, and lands only through a green PR (`check.yml`). The coordinating session merges each green PR with `gh pr merge <n> --squash --delete-branch`, never `--admin`, on the operator's standing approval from 2026-10-27.

## Tier 1a. Script and app safety fixes (T1a)

**Depends on.** None.

- [ ] `cli_lock_all` fails when any of its three locks is held, and names that lock (`bin/claude-multipass:476`). Test. hold `.oauth_refresh.lock`, then `~/.claude.lock`, each fresh. Switch exits 1, Desktop's config and `oauthAccount` are untouched.
- [ ] The backup prune iterates a glob array, not `$(ls ...)` (`bin/claude-multipass:676`). Test. a store path with a space and more than ten `login-*` folders. Ten remain, and a decoy directory named after the first word survives.
- [ ] `switch` to the signed-in profile re-saves the live cookies into the profile before it repairs, so no newer cookie is lost (`bin/claude-multipass:1247`). Test. rotate the live `Cookies`, switch to the same name, and the rotated cookie survives.
- [ ] Opening the popover refreshes the snapshot only, not usage (`app/Sources/ClaudeMultipass/PopoverController.swift:31`). This restores the 5-minute usage rule. Test in `AppStateTests` if the call moves into `MultipassCore`.

## Tier 1b. Gate and release fixes (T1b)

**Depends on.** None. Its files do not overlap T1a's.

- [ ] `test/check.sh` runs `bash -n` once per file. Evidence. a deliberate syntax error in a second file fails the gate, then is reverted.
- [ ] `commit-gate.sh` delegates to the worktree's own copy when it differs and the git common dir matches, as `lint-edited.sh` does. Test. a case in `test-commit-gate.sh` with a differing copy and a failing `pnpm` stub, so the commit is blocked.
- [ ] `release.yml` fails when `${GITHUB_REF_NAME#v}` differs from `package.json`'s version.
- [ ] `release.yml` sets `MACOS_SIGN_REQUIRED=1` on every tag build and requires all three `APPLE_API_*` secrets, so a release never publishes an unsigned or un-notarized DMG.

## Tier 2. Narrower defects (T2)

**Depends on.** T1a and T1b merged.

- [ ] `save` refuses a second name for an account already saved under another name. `--force` lifts the refusal and moves the old profile to `backups/` (operator's choice, 2026-10-27). Test. save `alpha2` for alpha's account exits 3, then succeeds with `--force`.
- [ ] `add` refuses to sign out a login that was never saved, with exit 3 unless `--force`, as `switch` does. Test both paths.
- [ ] The app gives `switch` and `save` a longer timeout than the read-only commands, and the watchdog signals the whole process group (`app/Sources/MultipassCore/CLI.swift:89`). Test with `FakeRunner` or a scripted child.
- [ ] A failed usage fetch clears or marks the old usage figures, and a later snapshot success does not hide the usage error (`AppState.swift:124,139`). Test in `AppStateTests`.
- [ ] One bad `meta.json` no longer empties the account list. `savedAt` decodes leniently in `Models.swift`, and `list --json` skips or nulls a row it cannot parse. Test in the script self-check and `ModelsTests`.

## Tier 3a. Small fixes and test gaps (T3a)

**Depends on.** T2 merged.

- [ ] Settings says 0.3.0 or newer (`SettingsView.swift:72`).
- [ ] The `--help` synopsis reads `add <name> [--no-relaunch]` and `remove <name>`.
- [ ] The `keychain_exit` text for exit 36 says the keychain is locked, as `desktop-internals.md` records.
- [ ] Pin CI and release to a named macOS image and an exact Node version (`check.yml`, `release.yml`, `.nvmrc`). Split `release.yml` so only the upload step holds `contents: write`.
- [ ] Hook syntax-error cases put the error on a gated path, so `bash -n` is exercised, not prettier.
- [ ] Add self-check cases for the untested branches. They are `cli_verify` failures, prune and `remove` delete warnings, the `desktop_quit` `pkill` fallback, the `usage` "(signed in)" row and doctor's legacy-store warning.

## Tier 3b. Docs corrections (T3b)

**Depends on.** T2 merged. Markdown only, so it may land directly on `main`.

- [ ] CLAUDE.md lists `rename` on the ask list and `docs/superpowers/` in the tree.
- [ ] `docs/research.md:44` labels the 30 s Keychain cache (M), read in Claude Code 2.1.310.
- [ ] `docs/claude-multipass.md` documents the re-switch repair, the post-switch `claude auth status` warning, and the new `save` and `add` refusals.
- [ ] CHANGELOG Unreleased lists every user-visible change from T1a to T3a.

## Close the program

- [ ] Every PR merged green, its worktree and branch removed.
- [ ] `bash test/claude-multipass.sh` and `pnpm check` pass on `main`.

## Appendix. Evidence and choices

- The lock bug, the prune word-split, the re-switch cookie loss and the two-names stale restore were reproduced with the fixture harness during the audit. The popover usage call, the gate delegation gap, the `bash -n` call and the missing release guards were confirmed by reading the code.
- The jstack plan skeleton's ten live lanes and perf gate per PR were left out. These are small shell and Swift fixes whose surface is the fixture self-check and `swift test`, so the unit cases are the live proof. No PR here changes performance.
- Not covered. the real Keychain, the real app and the Homebrew tap.
