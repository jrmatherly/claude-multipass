# Doctor cleanup implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn off, in this project only, the Claude Code add-ons that `/doctor` found unused on 2026-11-15, and trim two blocks of `CLAUDE.md` that a session can rebuild from the repo, so every session in this project starts with up to 5k fewer estimated tokens of context.

**Architecture:** Every change is inside this repo. Two files change: `.claude/settings.local.json` (git-ignored, read only by sessions in this project) and `CLAUDE.md`. Plugins are turned off with the CLI's own `claude plugin disable --scope local`. The skill overrides are written with `jq` through a temp file that `jq empty` has parsed. Nothing is uninstalled, so each task is undone by flipping its setting back.

**Tech stack:** the `claude` CLI, `jq`, `git`, the `/context` command.

**Spec:** None. The `/doctor` report of 2026-11-15 is the source, and the Evidence section below carries every figure the tasks use.

## Global constraints

- **Project-local only (Jason, 2026-11-15).** No task writes a file outside `/Users/jason/dev/claude-multipass`. That rules out `~/.claude/settings.json`, `~/.claude.json`, `~/.claude/` in general and the dotfiles repo. Every other project keeps its current setup.
- No plugin, skill or MCP server is uninstalled or removed.
- Read settings files by key only (`jq '.enabledPlugins'`). `~/.claude/settings.json` and `~/.claude.json` hold secrets in `env` and `headers`. The checks below read two keys from the first file and never write it.
- Never edit `.claude/settings.json` (checked in) for this plan.
- Do not run `claude-stack apply` for this plan. It refuses three of the plugins in Task 1 (see Follow-ups), and its output file fails the commit gate's prettier check. `claude-stack` keeps a `false` that it did not write and keeps keys other than `enabledPlugins`, so a later `claude-stack apply` leaves this plan's settings in place (`merge_settings` in `~/dev/dotfiles/agents/catalog/stack.py`).
- This plan's only tracked change is `CLAUDE.md`, which is Markdown, so it commits and pushes on `main` with no branch or PR. Run `git commit` and `git push` in separate calls. The commit gate runs `pnpm check` (56 s typical) before the commit.
- Token figures are estimates (characters divided by 4). The skill listing in this project is already over its budget and shows many skills without a description, so the measured saving can be lower than the sum.
- The key name `skillOverrides` comes from the `/doctor` command text, which places it in `.claude/settings.local.json` for a project skill. Whether that file can also turn off a skill installed in `~/.claude/skills` is not confirmed. Task 5 confirms it by observing a new session.

## Review focus

1. `claude plugin disable --scope local` writes its `false` to user scope and turns a plugin off in every project. Expected: `.claude/settings.local.json` gains 14 keys and `~/.claude/settings.json` gains none. Task 1 step 3 checks both and says how to put a leak back.
2. A write leaves `.claude/settings.local.json` unparseable, and Claude Code then ignores the whole file, which turns the 21 plugins `claude-stack` disabled back on. Expected: the file is not replaced before `jq empty` passes on the temp copy. Task 2 step 1 does this.
3. `skillOverrides` in the local file does not reach a skill in `~/.claude/skills`. Expected: the ten skills are absent from a new session's listing. Task 5 step 2 checks. If they are still listed, Task 2 is reverted and reported, not moved to user scope.
4. A plugin turned off here is one that this project's `skill-stack.md` picks. Expected: none of the 14 is picked. Task 1 step 1 checks.
5. The release pointer in `CLAUDE.md` drops a fact that `.claude/skills/release/SKILL.md` does not hold. Expected: each removed fact is found in the skill first. Task 3 step 3 checks.

## Evidence

Scan of 1,306 sessions in the 30 days to 2026-11-15, plus the lifetime counters in `~/.claude.json`. The counters cover every project on this Mac.

| Item | Lifetime uses | Calls in 30 days | Est. resident tokens |
| --- | --- | --- | --- |
| 11 never-used plugins in Task 1 | 0 each | 0 | about 1.5k together |
| `voltagent-qa-sec` | 1 | 1 | about 1k |
| `plugin-dev` | 5 | 8 | about 0.9k |
| `microsoft-docs` | 58 | 51, last on 2026-10-24 | about 0.4k |
| 10 skills in Task 2 | 0 each | 0 | about 1k together |
| `CLAUDE.md` tree block | n/a | n/a | about 420 (1,684 bytes) |
| `CLAUDE.md` release section | n/a | n/a | about 150 saved (809 bytes become about 220) |

Kept on purpose:

- `voltagent-lang` has 0 uses, but this project's `skill-stack.md` picks its Swift agent.
- `coderabbit` was installed on 2026-11-09, which is too recent to judge.

## Before you start

- [ ] **Jason runs `/context` in a new session in this project and keeps the figures**

Task 5 compares against them. Without this reading the saving cannot be measured.

---

### Task 1: Turn off 14 plugins in this project

**Files:**

- Modify: `/Users/jason/dev/claude-multipass/.claude/settings.local.json` (key `enabledPlugins`, written by the CLI)

- [ ] **Step 1: Record the starting state**

```bash
grep -n -E 'agent-sdk-dev|claude-md-management|code-simplifier|commit-commands|mcp-server-dev|modern-web-guidance|session-report|superdesign|browser-use|rust-analyzer-lsp|lua-lsp|voltagent-qa-sec|plugin-dev|microsoft-docs' .claude/rules/skill-stack.md
```

Expected: no output, so this project picks none of them.

```bash
jq '.enabledPlugins | length' .claude/settings.local.json
```

Expected: 21.

```bash
jq '[.enabledPlugins | to_entries[] | select(.value == false)] | length' ~/.claude/settings.json
```

Expected: 5. Keep this number for step 3.

- [ ] **Step 2: Disable the 14 plugins at local scope**

Run from the repo root.

```bash
for p in agent-sdk-dev@claude-plugins-official claude-md-management@claude-plugins-official code-simplifier@claude-plugins-official commit-commands@claude-plugins-official mcp-server-dev@claude-plugins-official modern-web-guidance@claude-plugins-official session-report@claude-plugins-official superdesign@claude-plugins-official browser-use@claude-plugins-official rust-analyzer-lsp@claude-plugins-official lua-lsp@claude-plugins-official voltagent-qa-sec@voltagent-subagents plugin-dev@claude-plugins-official microsoft-docs@claude-plugins-official; do claude plugin disable "$p" --scope local || echo "FAILED $p"; done
```

Expected: no `FAILED` line. On a `FAILED` line, set that key to `false` under `enabledPlugins` in `.claude/settings.local.json` with `jq`, through a temp file as in Task 2 step 1.

- [ ] **Step 3: Verify**

```bash
jq '.enabledPlugins | length' .claude/settings.local.json
```

Expected: 35.

Run the third command of step 1 again. Expected: 5, the same as before. A higher number means the CLI wrote to user scope. For each of the 14 keys that is now `false` in `~/.claude/settings.json`, run `claude plugin enable <key> --scope user`, confirm the count is 5 again, and use the `jq` fallback of step 2 for that key.

```bash
git status --short
```

Expected: no output, because `.claude/settings.local.json` is git-ignored.

Undo: `claude plugin enable <key> --scope local`.

### Task 2: Turn off 10 never-used personal skills in this project

**Files:**

- Modify: `/Users/jason/dev/claude-multipass/.claude/settings.local.json` (key `skillOverrides`, absent today)

Each key is the skill's frontmatter `name`, which equals its folder name under `~/.claude/skills` for all ten (verified on 2026-11-15). The skills stay installed and stay on in every other project.

- [ ] **Step 1: Add the overrides**

```bash
tmp=$(mktemp) && jq '.skillOverrides = ((.skillOverrides // {}) + {"doc-coauthoring": "off", "find-skills": "off", "internal-comms": "off", "mcp-builder": "off", "theme-factory": "off", "web-artifacts-builder": "off", "supabase-prompts": "off", "organization-best-practices": "off", "email-and-password-best-practices": "off", "two-factor-authentication-best-practices": "off"})' .claude/settings.local.json > "$tmp" && jq empty "$tmp" && cat "$tmp" > .claude/settings.local.json
rm -f "$tmp"
```

- [ ] **Step 2: Verify**

```bash
jq '[(.skillOverrides | length), (.enabledPlugins | length)]' .claude/settings.local.json
```

Expected: `[10, 35]`.

Undo: write the file the same way with `del(.skillOverrides)`.

### Task 3: Trim `CLAUDE.md`

**Files:**

- Modify: `/Users/jason/dev/claude-multipass/CLAUDE.md:23-37` (the tree under `## Architecture`)
- Modify: `/Users/jason/dev/claude-multipass/CLAUDE.md:73` (the body of `## Release`)

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

### Task 4: Find out why plugins that are off still connect their servers

This task ends in a finding, not a change. `.claude/settings.local.json` has set `logfire`, `sentry` and `cloudflare` to `false` since 2026-11-03. A session started in this project on 2026-11-15 still listed tools from `plugin_logfire_logfire`, `plugin_sentry_sentry` and `plugin_cloudflare_cloudflare`, while the subagents of plugins turned off in the same file were gone. The cause is unknown. It matters here because `microsoft-docs` and `browser-use` from Task 1 each bring a server.

- [ ] **Step 1: Confirm the setting**

```bash
jq '.enabledPlugins | with_entries(select(.key | test("^(logfire|sentry|cloudflare)@")))' .claude/settings.local.json
```

Expected: three keys, all `false`.

- [ ] **Step 2: Compare the terminal with the desktop app**

Run `claude mcp list` from the repo root in a terminal. Then start a new Code tab session in this project and ask it which `mcp__plugin_` tools it lists. Record which of the three servers appear in each.

- [ ] **Step 3: Report**

Write the result in the session reply. If the servers appear only in the desktop app, the finding is "the app connects plugin servers without reading the project's `enabledPlugins`". If they appear in both, the finding is "a plugin's `false` does not stop its MCP server". Neither finding leads to a change outside this project.

### Task 5: Verify in a new session

- [ ] **Step 1: Jason runs `/context` in a new session in this project**

Compare with the reading from "Before you start". Expected: the skills, agents and memory-file lines are lower by up to 5k tokens together.

- [ ] **Step 2: Check the listings in that session**

Expected absent: any `plugin-dev:`, `commit-commands:` or `agent-sdk-dev:` skill, the `voltagent-qa-sec:` agent types, and the skills `doc-coauthoring`, `find-skills` and `mcp-builder`.

If the plugin entries are gone but the three skills are still listed, `skillOverrides` in the local file does not reach user skills. Revert Task 2 with its undo command and report that. Do not move the overrides to `~/.claude/settings.json`.

- [ ] **Step 3: Confirm that nothing outside the project changed**

```bash
jq '[([.enabledPlugins | to_entries[] | select(.value == false)] | length), (.skillOverrides // {} | length)]' ~/.claude/settings.json
```

Expected: `[5, 0]`.

## Left out because it is not project-local

- **The 5 idle MCP servers (`agent-browser`, `astro-docs`, `jean`, `mise`, `snippetslab`).** They are configured at user scope, and the per-project switch for them is the `disabledMcpServers` key inside `~/.claude.json`. Its effect is limited to this project, but the file is outside it, so the plan does not touch it. The cost of leaving them on is about 0.5k estimated tokens of server instructions. Jason can type `/mcp disable <server>` in a terminal `claude` session at the repo root if that trade is acceptable.
- **Turning anything off at user scope**, and **recording the state in dotfiles** with `claude-config save`. Nothing this plan changes is tracked by `claude-config`, which reads `~/.claude/settings.json`.

## Follow-ups, not part of this plan

- **`.prettierignore` does not list `.claude/skill-stack.json`.** `pnpm check` runs `prettier --check` over `**/*.json`, and `claude-stack apply` writes that file in a style prettier rejects. The commit gate failed on it on 2026-11-15 until `node_modules/.bin/prettier --write .claude/skill-stack.json` ran. Fixed on 2026-11-15: `.prettierignore` now lists `.claude/skill-stack.json` and `.claude/rules/skill-stack.md`, the two files `claude-stack apply` rewrites. With the JSON file compacted by `jq -c`, the gate's prettier command failed before the change and passed after it. Jason asked for this one to go straight to `main`.
- **`claude-stack` refuses three enabled plugins.** `claude-stack scan --off voltagent-qa-sec@voltagent-subagents --off plugin-dev@claude-plugins-official --off microsoft-docs@claude-plugins-official` prints "not selectable (not in [stack.signals], or off at user scope)". The cause was not traced. It belongs to the dotfiles repo, so this plan only notes it.

## Owner decisions, not tasks

`/usage` flagged four more items. None is a change to this project.

- **Start fresh when you switch tasks (86% of usage).** Run `/clear` between tasks.
- **`jstack:j-agent` subagents (13%).** The agent file sets no model. `~/dev/dotfiles/tilde/.claude/rules/jstack-models.md` sets the code roles to `opus medium` by hand.
- **`~/dev/career-ops/AGENTS.md` (25%, 26k tokens per request).** That edit belongs to a session in that repo.
- **`ccd_turn` (12%) and the `jstack` plugin (26%).** `ccd_turn` is the desktop app's built-in task list and has no setting. The `jstack` share is the work run under it, and this project uses it.

Checks 0, 2, 8 and 9 of `/doctor` found nothing to change: one native install on PATH, every settings file parses, auto mode is already the default, and the denials in the window were `automode-unavailable`, which no allow rule fixes safely.

## Results (2026-11-15)

- **Task 1: done.** `.claude/settings.local.json` went from 21 to 35 `enabledPlugins` keys. `~/.claude/settings.json` has the same checksum before and after.
- **Task 2: done, confirmed.** `skillOverrides` holds the 10 names. A session started at 16:59 after the change lists none of the ten, while it lists the other skills in `~/.claude/skills` (`archify`, `sentry-cli`, `siderolabs` and more). So `skillOverrides` in the local file does reach user skills.
- **Task 3: done** in `2eed3d7`. `CLAUDE.md` is 18,174 bytes, down from 20,446.
- **Task 4: finding.** A plugin's `false` in the local file does stop its server. `claude mcp list` at the repo root shows one plugin server, `chrome-devtools`, and none of `logfire`, `sentry`, `cloudflare`, `microsoft-docs` or `browser-use`. The Code tab session that listed the first three at 16:08 had started in a spare folder outside the project (its scratchpad path named `claude-spares`), and it dropped all three when it resumed inside the project at 16:41. That the spare start is the cause is inferred from those two paths, not tested.
- **Task 5: step 3 done.** `~/.claude/settings.json` reads `[5, 0]` and `disabledMcpServers` in `~/.claude.json` is still absent. No `/context` baseline was taken before Task 1, so the saving can be read only as an absolute figure.
- **Task 5: step 2 done, with one gap.** The 16:59 session lists no `plugin-dev:`, `commit-commands:` or `agent-sdk-dev:` skill, no `voltagent-qa-sec:` agent type, and none of `doc-coauthoring`, `find-skills` and `mcp-builder`. It does list the MCP tools of `logfire`, `sentry`, `cloudflare` and `microsoft-docs`, four plugins the local file turns off. Its scratchpad path names `claude-spares`, as the 16:08 session's did, so this is a second sighting of the Task 4 pattern: a Code tab session that starts in a spare folder connects the plugin servers before it reaches the project. The cause is still inferred. Step 1 (`/context`) is Jason's.

## Closed (2026-11-16)

Jason dropped Task 5 step 1, the `/context` reading, on 2026-11-16. No baseline was taken before Task 1, so the reading could only have been an absolute figure. Nothing else in this plan is open.

A third sighting of the Task 4 pattern, the same day: a Code tab session that started in a spare folder (its scratchpad path named `claude-spares`) listed the tools of `logfire`, `sentry`, `cloudflare` and `microsoft-docs`, and the app reported those tools as no longer available when the session resumed inside the project. The cause is still inferred from the paths, not tested.

## Review (2026-11-15)

A fresh reviewer checked `f37472b..b865507` and the local settings file. It found no critical issue and two things to correct.

- **A design rule had lived only in the removed tree.** No other agent doc said that `MultipassCore` imports only Foundation and `ClaudeMultipass` is the UI shell. `CLAUDE.md` now states it in one sentence under `## Architecture`.
- **Task 4's finding rests on `claude mcp list` alone.** The reviewer ran as a subagent of the session that did Task 1, and it still listed the tools, skills and agents of the plugins that Task 1 turned off. A subagent takes its parent's loaded plugins, and the parent loaded them before Task 1, so this neither confirms nor contradicts the finding. The same subagent did not list the ten skills of Task 2, which is weak evidence that `skillOverrides` works from the local file. Task 5 steps 1 and 2 stay open until a session that starts after the change is checked.

The step checkboxes above were not ticked during the run. The Results section is the record of what ran.
