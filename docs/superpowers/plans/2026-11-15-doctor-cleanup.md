# Doctor cleanup implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn off the Claude Code add-ons that `/doctor` found unused on 2026-11-15, and trim two blocks of `CLAUDE.md` that a session can rebuild from the repo, so every session in this project starts with up to 6k fewer estimated tokens of context.

**Architecture:** Every change is a setting or a deletion in `CLAUDE.md`. Plugins are turned off with the CLI's own `claude plugin disable`. The two keys that have no CLI command are written with `jq` through a temp file that `jq empty` has parsed. Each task ends with a `jq` or `grep` check. Nothing is uninstalled, so each task is undone by flipping its setting back.

**Tech stack:** the `claude` CLI, `jq`, `git`, `claude-catalog` and `claude-config` from `~/dev/dotfiles/bin`, the `/context` command.

**Spec:** None. The `/doctor` report of 2026-11-15 is the source, and the Evidence section below carries every figure the tasks use.

## Global constraints

- No plugin, skill or MCP server is uninstalled or removed. Never run `claude mcp remove`, which deletes the server config and its OAuth tokens.
- Read settings files by key only (`jq '.enabledPlugins'`). `~/.claude/settings.json` and `~/.claude.json` hold secrets in `env` and `headers`. Never print a whole file.
- User-scope edits go to `~/.claude/settings.json`. Project-scope edits go to `.claude/settings.local.json` (git-ignored) and the project entry in `~/.claude.json`. Never edit `.claude/settings.json` for this plan.
- Never restore an old copy of `~/.claude.json`. The file holds `oauthAccount`, the CLI identity that `claude-multipass switch` moves, and a stale copy would put back the identity of a previous account. Undo a change to it by deleting the one key.
- Do not run `claude-stack apply` for this plan. It refuses the three plugins of Task 4 (see Follow-ups), and its output file fails the commit gate's prettier check.
- This plan's only tracked change is `CLAUDE.md`, which is Markdown, so it commits and pushes on `main` with no branch or PR. Run `git commit` and `git push` in separate calls. The commit gate runs `pnpm check` (56 s typical) before the commit.
- Token figures are estimates (characters divided by 4). The skill listing in this project is already over its budget and shows many skills without a description, so the measured saving can be lower than the sum.
- The key names `skillOverrides` and `disabledMcpServers` come from the `/doctor` command text. No local copy of the Claude Code docs was found to confirm them, so Task 8 confirms each one by observing a new session.

## Review focus

1. A running Claude session rewrites `~/.claude.json` and drops the Task 3 edit. Expected: the key is still there 60 seconds later and in a new session. Task 3 step 4 checks the first, Task 8 the second.
2. A write leaves a settings file that does not parse, and Claude Code then ignores the whole file. Expected: no file is replaced before `jq empty` passes on the temp copy. Each `jq` write step does this.
3. A plugin or skill turned off everywhere is one that another project's `skill-stack.md` picks. Expected: that name is dropped from the list. Task 1 step 1 and Task 2 step 1 check. The check already removed `commit-commands` (see Evidence).
4. `claude plugin disable --scope local` writes its `false` somewhere other than `.claude/settings.local.json`. Expected: that file gains three keys and `~/.claude/settings.json` gains none. Task 4 step 3 checks both.
5. The release pointer in `CLAUDE.md` drops a fact that `.claude/skills/release/SKILL.md` does not hold. Expected: each removed fact is found in the skill first. Task 5 step 3 checks.

## Evidence

Scan of 1,306 sessions in the 30 days to 2026-11-15, plus the lifetime counters in `~/.claude.json`.

| Item | Scope | Lifetime uses | Calls in 30 days | Est. resident tokens |
| --- | --- | --- | --- | --- |
| 10 plugins in Task 1 | user | 0 each | 0 | about 1.4k together |
| 10 skills in Task 2 | user | 0 each | 0 | about 1k together |
| 5 MCP servers in Task 3 | user | no counter | 0 | about 0.5k of server instructions |
| `voltagent-qa-sec` | user | 1 | 1 | about 1k |
| `plugin-dev` | user | 5 | 8 | about 0.9k |
| `microsoft-docs` | user | 58 | 51, last on 2026-10-24 | about 0.4k |
| `CLAUDE.md` tree block | checked in | n/a | n/a | about 420 (1,684 bytes) |
| `CLAUDE.md` release section | checked in | n/a | n/a | about 150 saved (809 bytes become about 220) |

Kept on purpose:

- `commit-commands` has 0 uses, but `~/dev/career-ops/.claude/rules/skill-stack.md` line 21 picks `/commit-commands:commit`.
- `voltagent-lang` has 0 uses, but this project's `skill-stack.md` picks its Swift agent.
- `coderabbit` was installed on 2026-11-09, which is too recent to judge.
- The MCP servers `hindsight`, `codegraph`, `serena`, `rea`, `siderolabs-docs`, `better-auth` and `scrapling` were all called in the window.

## Before you start

- [ ] **Jason runs `/context` in a new session in this project and keeps the figures**

Task 8 compares against them. Without this reading the saving cannot be measured.

---

### Task 1: Turn off 10 never-used plugins everywhere

**Files:**

- Modify: `~/.claude/settings.json` (key `enabledPlugins`, written by the CLI)

- [ ] **Step 1: Check that no other project picks these plugins**

```bash
grep -n -E 'agent-sdk-dev|claude-md-management|code-simplifier|mcp-server-dev|modern-web-guidance|session-report|superdesign|browser-use|rust-analyzer-lsp|lua-lsp' ~/dev/*/.claude/rules/skill-stack.md
```

Expected: no output (verified on 2026-11-15). A printed line under "Tools chosen for this project" names a plugin to drop from step 3. A line under "Plugins turned off here" is no reason to drop it.

- [ ] **Step 2: Record the starting state**

```bash
jq '[.enabledPlugins | to_entries[] | select(.value == true)] | length' ~/.claude/settings.json
```

Expected: 62.

- [ ] **Step 3: Disable the 10 plugins at user scope**

```bash
for p in agent-sdk-dev@claude-plugins-official claude-md-management@claude-plugins-official code-simplifier@claude-plugins-official mcp-server-dev@claude-plugins-official modern-web-guidance@claude-plugins-official session-report@claude-plugins-official superdesign@claude-plugins-official browser-use@claude-plugins-official rust-analyzer-lsp@claude-plugins-official lua-lsp@claude-plugins-official; do claude plugin disable "$p" --scope user || echo "FAILED $p"; done
```

Expected: one confirmation line per plugin and no `FAILED` line. On a `FAILED` line, stop and report the CLI's message.

- [ ] **Step 4: Verify**

```bash
jq '[.enabledPlugins | to_entries[] | select(.value == true)] | length' ~/.claude/settings.json
```

Expected: 52 (62 minus 10, or one more for each name step 1 dropped).

```bash
jq empty ~/.claude/settings.json && echo ok
```

Expected: `ok`.

Undo: `claude plugin enable <key> --scope user`.

### Task 2: Turn off 10 never-used personal skills everywhere

**Files:**

- Modify: `~/.claude/settings.json` (key `skillOverrides`, absent today)

Each key is the skill's frontmatter `name`, which equals its folder name under `~/.claude/skills` for all ten (verified on 2026-11-15). The folders are symlinks into `~/.agents/skills` and stay installed.

- [ ] **Step 1: Check that no other project names these skills**

```bash
grep -n -E 'doc-coauthoring|find-skills|internal-comms|mcp-builder|theme-factory|web-artifacts-builder|supabase-prompts|organization-best-practices|email-and-password-best-practices|two-factor-authentication-best-practices' ~/dev/*/.claude/rules/skill-stack.md ~/dev/*/CLAUDE.md
```

Expected: no output (verified on 2026-11-15). Drop any skill that a printed line tells its sessions to use.

- [ ] **Step 2: Add the overrides**

```bash
tmp=$(mktemp) && jq '.skillOverrides = ((.skillOverrides // {}) + {"doc-coauthoring": "off", "find-skills": "off", "internal-comms": "off", "mcp-builder": "off", "theme-factory": "off", "web-artifacts-builder": "off", "supabase-prompts": "off", "organization-best-practices": "off", "email-and-password-best-practices": "off", "two-factor-authentication-best-practices": "off"})' ~/.claude/settings.json > "$tmp" && jq empty "$tmp" && cat "$tmp" > ~/.claude/settings.json
rm -f "$tmp"
```

`cat` into the file keeps its mode (0600).

- [ ] **Step 3: Verify**

```bash
jq '.skillOverrides | length' ~/.claude/settings.json
```

Expected: 10.

Undo: write the file the same way with `del(.skillOverrides["<name>"])` for one skill, or `del(.skillOverrides)` for all.

### Task 3: Disable 5 idle MCP servers in this project

**Files:**

- Modify: `~/.claude.json` (key `.projects["/Users/jason/dev/claude-multipass"].disabledMcpServers`, absent today)

The servers stay configured at user scope and stay on in every other project. `claude mcp` has no `disable` subcommand, so the two routes are the `/mcp` command inside a terminal session and a hand edit.

- [ ] **Step 1: Record the starting state**

```bash
jq '.projects["/Users/jason/dev/claude-multipass"].disabledMcpServers' ~/.claude.json
```

Expected: `null`.

- [ ] **Step 2: Add the list**

Preferred route: Jason runs `claude` in a terminal at the repo root and types `/mcp disable <server>` for each of `agent-browser`, `astro-docs`, `jean`, `mise` and `snippetslab`. Claude Code then writes the key itself, under its own locks. The Code tab has no `/mcp` dialog, so an agent there cannot take this route.

Fallback, by hand. `.claude/rules/safety-and-terms.md` forbids the tool from writing `~/.claude.json` outside the CLI's locks. That rule governs `bin/claude-multipass`, not this one-off edit, but the race it guards against is the same one. Run the command only while no Claude session in this project is mid-turn and no `claude-multipass switch` is running, because both save `~/.claude.json`.

```bash
tmp=$(mktemp) && jq '.projects["/Users/jason/dev/claude-multipass"].disabledMcpServers = ["agent-browser", "astro-docs", "jean", "mise", "snippetslab"]' ~/.claude.json > "$tmp" && jq empty "$tmp" && cat "$tmp" > ~/.claude.json
rm -f "$tmp"
```

- [ ] **Step 3: Verify**

```bash
jq '.projects["/Users/jason/dev/claude-multipass"].disabledMcpServers | length' ~/.claude.json
```

Expected: 5.

- [ ] **Step 4: Verify that the edit survives**

Wait 60 seconds with a session open, then run the step 3 command again. Expected: 5. If it prints `null`, a session overwrote the file. Quit Claude Desktop sessions for this project, repeat step 2, and report that the first write was lost.

Undo: `/mcp enable <server>` in a terminal session, or `del(.projects["/Users/jason/dev/claude-multipass"].disabledMcpServers)` written the same way as step 2.

### Task 4: Turn off 3 plugins in this project

**Files:**

- Modify: `.claude/settings.local.json` (key `enabledPlugins`, written by the CLI)

`claude-stack` cannot do this. Its dry run refuses all three keys as "not selectable" (see Follow-ups). `claude-stack` keeps a `false` that it did not write, so a later `claude-stack apply` leaves these three off. `.claude/rules/skill-stack.md` will not list them.

- [ ] **Step 1: Record the starting state**

```bash
jq '.enabledPlugins | length' .claude/settings.local.json
```

Expected: 21.

```bash
jq '[.enabledPlugins | to_entries[] | select(.value == false)] | length' ~/.claude/settings.json
```

Expected: 15 after Task 1 (5 before it).

- [ ] **Step 2: Disable the three plugins at local scope**

Run from the repo root.

```bash
for p in voltagent-qa-sec@voltagent-subagents plugin-dev@claude-plugins-official microsoft-docs@claude-plugins-official; do claude plugin disable "$p" --scope local || echo "FAILED $p"; done
```

Expected: no `FAILED` line. On a `FAILED` line, set that key to `false` under `enabledPlugins` in `.claude/settings.local.json` with `jq`, through a temp file as in Task 2 step 2.

- [ ] **Step 3: Verify**

```bash
jq '.enabledPlugins | length' .claude/settings.local.json
```

Expected: 24.

Run the second command of step 1 again. Expected: the same number as in step 1. A higher number means the CLI wrote to user scope. Run `claude plugin enable <key> --scope user` for each of the three and use the `jq` fallback of step 2.

```bash
git status --short
```

Expected: no output, because `.claude/settings.local.json` is git-ignored.

Undo: `claude plugin enable <key> --scope local`.

### Task 5: Trim `CLAUDE.md`

**Files:**

- Modify: `CLAUDE.md:23-37` (the tree under `## Architecture`)
- Modify: `CLAUDE.md:73` (the body of `## Release`)

- [ ] **Step 1: Confirm the anchors**

````bash
grep -n -E '^## |^```' CLAUDE.md
````

Expected: `21:## Architecture`, a fence on line 23, a fence on line 36 and `71:## Release`. If the numbers differ, use the printed ones.

- [ ] **Step 2: Delete the tree block**

Delete the fenced `text` block (lines 23 to 36) and the blank line after it (line 37). Keep the `## Architecture` heading, the "Storage model:" list and the sentence that points to `.claude/rules/desktop-internals.md`.

- [ ] **Step 3: Check that the release skill holds each fact, then replace the section body**

```bash
for t in SPARKLE_ED_KEY homebrew-tap claude-multipass-app 'appcast\.xml' 'git revert' follow-tags 'six secrets' sha256; do
  printf '%s: ' "$t"
  grep -c -E "$t" .claude/skills/release/SKILL.md
done
```

Expected: every count is 1 or more (measured on 2026-11-15: 1, 7, 4, 4, 1, 1, 1, 4). A term that prints 0 stays in `CLAUDE.md` as its original sentence.

Replace the one-paragraph body of `## Release` with this text:

```markdown
The release steps are in `.claude/skills/release/SKILL.md`. The gate fails when `version=` in `bin/claude-multipass` and `package.json` differ. The tap commit is the announcement, and `git revert` of it stops new offers.
```

- [ ] **Step 4: Verify**

```bash
wc -c CLAUDE.md
```

Expected: about 18,200 bytes, down from 20,446.

```bash
grep -c -E 'Storage model|^## Release|^## Architecture' CLAUDE.md
```

Expected: 3.

- [ ] **Step 5: Commit, then push**

```bash
git add CLAUDE.md
git commit -m "Trim the tree and the release steps from CLAUDE.md"
```

```bash
git push
```

Expected: the push output names the `check` rule it bypassed, which is the intended docs-only bypass.

### Task 6: Record the change in dotfiles

**Files:**

- Modify: `~/dev/dotfiles/agents/claude-plugins.txt`, `~/dev/dotfiles/agents/claude-settings.json` (written by `claude-config save`)
- Modify: `~/.claude/catalog/CATALOG.md` (rebuilt by `claude-catalog`)

`claude-config` tracks the plugin list (with a `disabled` flag) and the base settings in the dotfiles repo. Without this task the next `claude-config save` shows the changes as a surprise, and another Mac keeps the old state. This task writes outside this repo, so it runs only on Jason's say.

- [ ] **Step 1: Rebuild the catalog**

```bash
claude-catalog
```

- [ ] **Step 2: Record the machine state**

```bash
claude-config save
```

```bash
git -C ~/dev/dotfiles diff --stat agents/
```

Expected: `claude-plugins.txt` shows 10 lines that gained `disabled`, and `claude-settings.json` shows the new `skillOverrides` key. Leave the commit in the dotfiles repo to Jason.

### Task 7: Find out why plugins that are off still connect their servers

This task ends in a finding, not a change. `.claude/settings.local.json` has set `logfire`, `sentry` and `cloudflare` to `false` since 2026-11-03. A session started in this project on 2026-11-15 still listed tools from `plugin_logfire_logfire`, `plugin_sentry_sentry` and `plugin_cloudflare_cloudflare`, while the subagents of plugins turned off in the same file were gone. The cause is unknown.

- [ ] **Step 1: Confirm the setting**

```bash
jq '.enabledPlugins | with_entries(select(.key | test("^(logfire|sentry|cloudflare)@")))' .claude/settings.local.json
```

Expected: three keys, all `false`.

- [ ] **Step 2: Compare the terminal with the desktop app**

Run `claude mcp list` from the repo root in a terminal. Then start a new Code tab session in this project and ask it which `mcp__plugin_` tools it lists. Record which of the three servers appear in each.

- [ ] **Step 3: Report**

Write the result in the session reply. If the servers appear only in the desktop app, the finding is "the app connects plugin servers without reading the project's `enabledPlugins`". If they appear in both, the finding is "a plugin's `false` does not stop its MCP server". In that case `microsoft-docs` from Task 4 keeps its server too. Turning the plugins off at user scope would stop the servers in every project, and that is Jason's decision.

### Task 8: Verify in a new session

- [ ] **Step 1: Jason runs `/context` in a new session in this project**

Compare with the reading from "Before you start". Expected: the skills, agents, MCP and memory-file lines are lower by up to 6k tokens together.

- [ ] **Step 2: Check the listings in that session**

Expected absent: the skills `doc-coauthoring`, `find-skills` and any `plugin-dev:` entry, the `voltagent-qa-sec:` agent types, and the tools `mcp__snippetslab__`, `mcp__jean__`, `mcp__mise__`, `mcp__astro-docs__` and `mcp__agent-browser__`. An entry that is still present means its key name was wrong or the setting is not read. Report it with the key that was written.

## Follow-ups, not part of this plan

- **`.prettierignore` does not list `.claude/skill-stack.json`.** `pnpm check` runs `prettier --check` over `**/*.json`, and `claude-stack apply` writes that file in a style prettier rejects. The commit gate failed on it on 2026-11-15 until `node_modules/.bin/prettier --write .claude/skill-stack.json` ran. The fix is one line in `.prettierignore`, which is tooling and needs its own branch and PR.
- **`claude-stack` refuses three enabled plugins.** `claude-stack scan --off voltagent-qa-sec@voltagent-subagents --off plugin-dev@claude-plugins-official --off microsoft-docs@claude-plugins-official` prints "not selectable (not in [stack.signals], or off at user scope)". All three are on at user scope and appear in `~/dev/dotfiles/agents/catalog/curated.toml`. The cause was not traced. It belongs to the dotfiles repo.

## Owner decisions, not tasks

`/usage` flagged four more items. None is an agent's to change from this repo.

- **Start fresh when you switch tasks (86% of usage).** Run `/clear` between tasks.
- **`jstack:j-agent` subagents (13%).** The agent file sets no model. `~/dev/dotfiles/tilde/.claude/rules/jstack-models.md` sets the code roles to `opus medium` by hand. Setting `swarm workers`, `feature, refactoring` and `bug-fix` to `sonnet medium` would lower this share.
- **`~/dev/career-ops/AGENTS.md` (25%, 26k tokens per request).** Keep the rules most tasks need and move the rest into files it points to. That edit belongs to a session in that repo.
- **`ccd_turn` (12%) and the `jstack` plugin (26%).** `ccd_turn` is the desktop app's built-in task list and has no setting. The `jstack` share is the work run under it, and this project uses it.

Checks 0, 2, 8 and 9 of `/doctor` found nothing to change: one native install on PATH, every settings file parses, auto mode is already the default, and the denials in the window were `automode-unavailable`, which no allow rule fixes safely.
