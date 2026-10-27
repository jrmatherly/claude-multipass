---
name: release
description: Cut a claude-multipass release. Tags the repo, pushes (release.yml builds, signs, notarizes and uploads the menu bar app DMG), bumps the Homebrew formula in jrmatherly/homebrew-tap to the new tag's tarball and sha256, then the cask to the DMG. Use for "cut a release", "bump the formula", "tag vX.Y.Z", or "release X.Y.Z".
argument-hint: '<X.Y.Z>'
disable-model-invocation: true
---

Release version `$ARGUMENTS` (write it as `X.Y.Z` below; the tag is `vX.Y.Z`). Stop if it does not match `^[0-9]+\.[0-9]+\.[0-9]+$`.

Preconditions: on `main`, clean tree, `pnpm check` passes, the tap is cloned at `~/dev/homebrew-tap` (`ls ~/dev/homebrew-tap/Formula/claude-multipass.rb ~/dev/homebrew-tap/Casks/claude-multipass-app.rb`), and `gh secret list` shows the five secrets `release.yml` needs (copied by name from the ai-kb repository settings): `MACOS_CERT_P12` (base64 of the Developer ID .p12), `MACOS_CERT_PASSWORD`, `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID`, `APPLE_API_KEY_P8` (the .p8 contents). Without all five, or when the tag differs from `package.json`'s version, the workflow fails before building. Casks and formulae from a third-party tap load only after `brew trust jrmatherly/tap` (once per Mac; `brew audit --cask` and a bare `brew install` refuse otherwise; `brew bundle` with `trusted: true` on the line does it itself, which is how the dotfiles Brewfile installs them).

1. Check that `main` already carries the release: `CHANGELOG.md` has a `## X.Y.Z (YYYY-MM-DD)` section at the top (no `v`, matching the existing headings; a `## Unreleased` heading becomes the dated one) and `version=` in `bin/claude-multipass` equals `"version"` in `package.json` equals `X.Y.Z`. Those edits are code and land through a PR like any other (CLAUDE.md, Custom Notes), so a release never commits on `main`: when they are missing, open that PR first and come back after it merges.
2. Tag: `git tag -a vX.Y.Z -m "vX.Y.Z"`.
3. Push the tag: `git push --follow-tags`. The tag starts `release.yml`; wait with `gh run watch --exit-status <run id>` (`gh run list --workflow release.yml --limit 1` finds it). It publishes `claude-multipass-app_X.Y.Z_arm64.dmg` and its `.sha256` on the GitHub release (the suffix is the runner's `uname -m`; `macos-latest` is arm64). Confirm the DMG is notarized: download it and run `spctl -a -vv -t open --context context:primary-signature <dmg>`, expected `accepted`.
4. Compute the tarball digest (GitHub builds the archive from the tag; wait for the push to land):

   ```sh
   curl -sL https://github.com/jrmatherly/claude-multipass/archive/refs/tags/vX.Y.Z.tar.gz | shasum -a 256
   ```

5. Edit `~/dev/homebrew-tap/Formula/claude-multipass.rb`: set `url` to `https://github.com/jrmatherly/claude-multipass/archive/refs/tags/vX.Y.Z.tar.gz` and `sha256` to the digest.
6. Audit the formula: `brew audit --strict --formula jrmatherly/tap/claude-multipass`. Fix what it reports before going on.
7. Edit `~/dev/homebrew-tap/Casks/claude-multipass-app.rb`: set `version` to `X.Y.Z` and `sha256` to the digest in the release asset `claude-multipass-app_X.Y.Z_arm64.dmg.sha256`. The formula is bumped first (step 5) because the app refuses an older tool. Audit it: `brew audit --cask --strict jrmatherly/tap/claude-multipass-app`. The cask token is `claude-multipass-app`, not the formula's name, so `brew install jrmatherly/tap/claude-multipass` keeps meaning the tool; if the audit ever reports a token clash, rename it to `claude-multipass-menubar` and record why here.
8. Commit and push the tap: `git -C ~/dev/homebrew-tap commit -am "claude-multipass vX.Y.Z" && git -C ~/dev/homebrew-tap push`.
9. Upgrade locally: `brew update && brew upgrade claude-multipass && brew install --cask jrmatherly/tap/claude-multipass-app` (or `brew upgrade --cask`).
10. Verify: `claude-multipass --version` prints `claude-multipass X.Y.Z`, `claude-multipass list` prints the saved accounts, `brew info jrmatherly/tap/claude-multipass` shows `X.Y.Z`, and the app is relaunched (`pkill -x ClaudeMultipass; open -a 'Claude Multipass'`) so the installed bundle is the one running. The real switch is Jason's, never the agent's: ask him to switch from the popover or an outside terminal and run `claude auth status` in a new terminal, and report what he sees.

Report the tag, the digest, the DMG digest, the tap commit, and the output of step 10. A failed audit or a digest mismatch stops the release; nothing is retagged. If the tag must move, delete it locally and remotely first (`git tag -d vX.Y.Z && git push origin :refs/tags/vX.Y.Z`), and say so, since the published tarball changes.
