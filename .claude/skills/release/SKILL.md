---
name: release
description: Cut a claude-multipass release. Tags the repo, pushes, and bumps the Homebrew formula in jrmatherly/homebrew-tap to the new tag's tarball and sha256. Use for "cut a release", "bump the formula", "tag vX.Y.Z", or "release X.Y.Z".
argument-hint: '<X.Y.Z>'
---

Release version `$ARGUMENTS` (write it as `X.Y.Z` below; the tag is `vX.Y.Z`).

Preconditions: on `main`, clean tree, `pnpm check` passes, the tap is cloned at `~/dev/homebrew-tap` (`ls ~/dev/homebrew-tap/Formula/claude-multipass.rb`).

1. Update `CHANGELOG.md`: a `## X.Y.Z (YYYY-MM-DD)` section at the top (no `v`, matching the existing headings) listing the user-visible changes since the previous tag (`git log --oneline <prev-tag>..HEAD`). When a `## X.Y.Z (unreleased)` heading exists, replace it with the dated one.
2. Bump `version=` in `bin/claude-multipass` and `"version"` in `package.json` to `X.Y.Z` together; `pnpm check` fails when they differ.
3. Commit: `git commit -am "Release vX.Y.Z"` (the commit-gate hook runs `pnpm check`).
4. Tag: `git tag -a vX.Y.Z -m "vX.Y.Z"`.
5. Push with the tag: `git push --follow-tags`.
6. Compute the tarball digest (GitHub builds the archive from the tag; wait for the push to land):

   ```sh
   curl -sL https://github.com/jrmatherly/claude-multipass/archive/refs/tags/vX.Y.Z.tar.gz | shasum -a 256
   ```

7. Edit `~/dev/homebrew-tap/Formula/claude-multipass.rb`: set `url` to `https://github.com/jrmatherly/claude-multipass/archive/refs/tags/vX.Y.Z.tar.gz` and `sha256` to the digest.
8. Audit the formula: `brew audit --strict --formula jrmatherly/tap/claude-multipass`. Fix what it reports before going on.
9. Commit and push the tap: `git -C ~/dev/homebrew-tap commit -am "claude-multipass vX.Y.Z" && git -C ~/dev/homebrew-tap push`.
10. Upgrade locally: `brew update && brew upgrade claude-multipass`.
11. Verify: `claude-multipass list` prints the saved accounts, and `brew info jrmatherly/tap/claude-multipass` shows `X.Y.Z`.

Report the tag, the digest, the tap commit, and the output of step 11. A failed audit or a digest mismatch stops the release; nothing is retagged. If the tag must move, delete it locally and remotely first (`git tag -d vX.Y.Z && git push origin :refs/tags/vX.Y.Z`), and say so, since the published tarball changes.
