# Tech stack

- Runtime: system `/bin/bash` 3.2 (shebang `#!/bin/bash`), macOS BSD userland. Hard deps: `jq`. Optional: `fzf` (picker). `usage` also needs `curl`, system `python3`, `openssl`.
- No build step, no compiled artifacts. `package.json` exists only for prettier: `prettier` 3 with `prettier-plugin-sh`, `pnpm` (pinned in `packageManager`), node >= 24.
- Lint: `shellcheck --severity=warning`, `.shellcheckrc` enables `check-unassigned-uppercase` (optional env vars are read as `${VAR:-}`).
- Format: `prettier.config.cjs`, `singleQuote`, no semis; Markdown `printWidth 70`, `proseWrap never`. `.prettierignore` skips `CLAUDE.md`, `.serena/`, `private/`, `.remember/`, `logs/`, `.claude/settings.local.json`.
- CI: `.github/workflows/check.yml` runs `pnpm check` on `macos-26`; `.nvmrc` pins Node 24.
- Distribution: git tag plus Homebrew formula in `jrmatherly/homebrew-tap` (`Formula/claude-multipass.rb`); steps in `.claude/skills/release/SKILL.md`.
- Serena: bash language server enabled in `.serena/project.yml` (binary from mise, `npm-bash-language-server`).
