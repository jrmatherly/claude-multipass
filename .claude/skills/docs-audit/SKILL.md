---
name: docs-audit
description: Audit this repo's Markdown docs and agent instructions against the script, the tests, the Raycast commands, the installed tool and vendor docs they describe, and report mismatches (never edits). Use after changing bin/claude-multipass, the tests or the hooks, or before a docs pass.
argument-hint: '[doc path or directory; default: all docs]'
context: fork
agent: docs-auditor
background: false
allowed-tools: Bash(git log *)
---

Audit these docs: $ARGUMENTS

If no path was given, audit `README.md`, `docs/*.md`, `CLAUDE.md`, `.claude/rules/*.md`, `.claude/skills/*/SKILL.md` and `.claude/agents/*.md`.

Every claim gets a verdict. A claim about the repo is checked against `bin/claude-multipass`, `test/`, `raycast/`, `.claude/`, `package.json` and `.github/workflows/check.yml`. A claim about this machine (the installed version, the profile store, Desktop's folder layout, the formula) is checked by running the read-only command that reads it. A claim about a vendor (Claude Desktop or Claude Code behaviour, a Homebrew rule, a third-party tool's README) is checked against the vendor's documentation with WebFetch. A claim is "Unverifiable" only when none of the three can settle it, and then the report names what would. `docs/research.md` carries evidence labels; a claim labelled R or U there is reported as a mismatch only when a source contradicts it, not for being unverified.

Recently changed files, to check first:

!`git log --since=14.days --name-only --format= | grep . | sort -u | head -80 || true`
