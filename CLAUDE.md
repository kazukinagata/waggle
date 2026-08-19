# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Waggle** is an async task coordination protocol for autonomous AI agents, implemented as a Claude Code plugin. It provides natural language CRUD operations, real-time HTML views (Kanban, List, Calendar, Gantt), and autonomous task execution via tmux parallel sessions or Scheduled Tasks. It supports any schema-definable data source through a provider abstraction (currently Notion).

## Architecture

### Plugin Structure

This repository is a Claude Code plugin marketplace (`.claude-plugin/marketplace.json`). The core
plugin lives in `core/` and each provider is its own plugin under `providers/`. A plugin's tree must
contain exactly one `.claude-plugin/plugin.json`, which is why `core/` is a subdirectory rather than
the repository root. Skills are the core building blocks — each skill is a self-contained
markdown-driven module under `core/skills/`.

```
core/                          # the `waggle` plugin
├── .claude-plugin/plugin.json
├── agents/
└── skills/
    ├── detecting-provider/    # (shared) Provider auto-detection + config retrieval
    ├── resolving-identity/    # (shared) Current user identity resolution
    ├── looking-up-members/    # (shared) Member name/email → provider user ID
    ├── setting-up-tasks/      # Initial plugin setup and MCP configuration
    ├── troubleshooting/       # Diagnoses common issues, schema mismatches, post-upgrade problems
    ├── managing-tasks/        # Task CRUD + personal task dashboard
    ├── executing-tasks/       # Task dispatch orchestration (single, tmux parallel, Scheduled Tasks)
    ├── viewing-tasks/         # Local view server management
    ├── delegating-tasks/      # Reassign tasks to other org members
    ├── ingesting-messages/    # Auto-convert Slack/Teams DMs into tasks
    ├── planning-tasks/        # AC/Execution Plan generation with brainstorming agents
    ├── running-daily-tasks/   # Unified daily routine
    ├── managing-views/        # Custom view management
    ├── monitoring-tasks/      # Task health check and quality metrics
    └── validating-fields/     # (shared) Deterministic field validation for status transitions

providers/                     # one plugin per data source
├── notion/                    # Notion-specific implementation
├── sqlite/
└── turso/
```

### Skill Dependency Flow

All user-invocable skills start by invoking `detecting-provider` (shared) to determine the active data source and retrieve config. Skills that need user identity also invoke `resolving-identity`.

Skills interact with each other only through natural language invocation. A skill's SKILL.md or reference files may instruct the agent to "invoke the `<other-skill>` skill" in plain English, and the agent (which has all skill frontmatters indexed via Claude Code's skill discovery mechanism) will load the target skill's SKILL.md and follow its instructions. Invocation is permitted across any two skills regardless of `user-invocable` value (though shared skills are preferred for logic reuse).

A skill must NOT know anything about another skill beyond the name and description in the target's frontmatter. The following patterns are forbidden in any skill file (SKILL.md, references/*, scripts/*):

- Hardcoded paths to another skill's files: `bash ${CLAUDE_PLUGIN_ROOT}/skills/other-skill/scripts/foo.sh`
- Hardcoded paths to another skill's SKILL.md: `Load ${CLAUDE_PLUGIN_ROOT}/skills/other-skill/SKILL.md`
- References to another skill's internal structure: line number citations, internal function or predicate names, internal reference file names, internal step number references

The only stable public contract is the frontmatter (name + description); agents resolve invocations through skill discovery. The target skill's internal structure (script layout, function names, step numbers, reference file names) must be free to evolve without breaking dependents.

Plugin-level subagents under `agents/` (e.g. `task-planning-agent`, `task-quality-reviewer-agent`, `task-agent`) are **not** skill internals — they are a stable public interface of the plugin, and any skill may spawn them by name (multiple skills already do). Renaming an agent is a breaking change to that interface and requires updating every referencing skill in the same commit.

A skill is always free to reference its own files. For self-references, use the official Claude Code runtime variable `${CLAUDE_SKILL_DIR}`, which the runtime resolves to the directory containing the current skill's SKILL.md.

Avoid `${CLAUDE_PLUGIN_ROOT}/skills/<self-name>/scripts/...` for self-references — it hardcodes the skill name and breaks silently on rename or relocation.

**Reading** a bundled file with Read, Glob, or Grep needs nothing further — those tools operate in the agent loop's own filesystem, which is where `${CLAUDE_SKILL_DIR}` points.

**Executing** a bundled file through the shell does. `${CLAUDE_SKILL_DIR}` is substituted when the skill loads, and the value is an agent-loop path; on runtimes where code execution happens elsewhere (Cowork runs the agent loop natively on the host and Bash in an isolated Linux VM) that path does not exist for the shell. So `bash ${CLAUDE_SKILL_DIR}/scripts/my-script.sh` is **forbidden** — it fails there every time, and the observed failure mode is worse than an error: the agent cannot find the script, silently substitutes an improvised equivalent, and a deterministic check never runs.

Resolve the directory in shell first, with the canonical three-tier resolver defined in the `provider-contract` skill (§ Resolving the Skill Directory) — convert the path, then a scoped search, then fail closed:

```bash
SCRIPT=scripts/my-script.sh; SKILL_DIR="${CLAUDE_SKILL_DIR}"
if [ ! -d "$SKILL_DIR" ]; then _S="${PWD%%/mnt/*}"; _R="$_S/mnt/.remote-plugins"
  case "$SKILL_DIR" in */plugin_*) _P="plugin_${SKILL_DIR#*/plugin_}"; SKILL_DIR="$_R/$_P"
    if [ ! -f "$SKILL_DIR/$SCRIPT" ]; then _M=$(find "$_R/${_P%%/*}" -path "*/$SCRIPT" 2>/dev/null)
      [ "$(printf %s "$_M" | grep -c .)" = 1 ] && SKILL_DIR="${_M%/$SCRIPT}"; fi ;;
  esac
fi
[ -f "$SKILL_DIR/$SCRIPT" ] || { echo "waggle: skill directory unresolved; $SCRIPT not found. Operation not performed." >&2; exit 1; }
bash "$SKILL_DIR/$SCRIPT"
```

Copy it whole. An abbreviated version is worse than none — the elided clauses are the ones that keep a failure from becoming a wrongly-resolved path.

Three rules apply wherever it is used, and `provider-contract` is the normative source for all of them:

- Resolution and invocation MUST sit in the **same** Bash call. Each Bash call is a fresh process, so a resolver placed once at the top of a section does not apply to the commands below it.
- The block is a **template**: `SCRIPT` names *this* script. A block copied between skills with another skill's script name resolves the wrong directory.
- Failure MUST **fail closed**: report that the operation was not performed. Never reimplement a bundled script's logic in the model — an improvised validator does not error, it returns a plausible answer.

The rule covers every shell command that reaches a bundled file, not just `bash` — `cd`, `source`, and command substitution alike.

Never feed a shell-emitted path back into a later shell command. On Cowork, listing files under a connected folder from the shell prints host paths, not the VM paths the shell itself can open. Recompute paths instead of round-tripping them through command output.

```
User-invocable skill
  → invoke detecting-provider (provider + config)
  → invoke resolving-identity (current_user)
  → invoke providers/{active_provider} (provider-specific operations)
```

### Provider Abstraction

The provider layer (`providers/{name}/skills/`) encapsulates all data-source-specific operations: schema validation, auto-repair, CRUD via MCP tools, identity resolution, and view server data push. Currently Notion is implemented; SQLite and Turso are planned.

### View Server

A Hono-based TypeScript server at `core/skills/viewing-tasks/server/` serves interactive HTML views on `http://localhost:3456`. It receives task data via POST `/api/data` and pushes real-time updates to clients via SSE at `/api/events`.

### Task Execution

Tasks can be executed in three modes based on execution environment:
- **cli (Terminal)**: Single task in current session, or parallel via tmux panes
- **claude-desktop (Claude Desktop)**: Single task in current session, or parallel via Scheduled Tasks
- **cowork (Cowork)**: Single task in current session, or parallel via Scheduled Tasks

### Task Schema

Tasks have 15 Core fields (auto-repaired if missing) and 12 Extended fields (graceful degradation). Key fields: Status (Backlog/Ready/In Progress/In Review/Done/Blocked/Cancelled), Executor (cli/claude-code/claude-desktop/cowork/human), Priority, Blocked By (dependency relation), Issuer (task creator/owner). CLI and Claude Desktop environments can execute tasks for any AI executor type (cli/claude-code/claude-desktop/cowork), while Cowork can only execute cowork tasks due to VM constraints.

## Development Commands

### View Server

```bash
cd core/skills/viewing-tasks/server

npm ci               # Install dependencies (uses lockfile)
npm run dev          # Start with hot-reload (tsx watch)
npm run build        # TypeScript compilation
npm test             # Run tests (vitest)
npm run test:watch   # Interactive watch mode
```

### Notion Provider Caveats

- Relations must be added ONE AT A TIME via `notion-update-data-source`. Batching multiple `ADD COLUMN RELATION` statements in a single call causes a 500 error.

### SKILL.md Format

Every skill has a `SKILL.md` with YAML front-matter:

```yaml
---
name: skill-name
description: Brief description of what the skill does and its trigger phrases.
user-invocable: true|false
---
```

## Key Conventions

- All natural language in the project (SKILL.md, comments, scripts, docs) must be in English
  - Exception: skill description front-matter may include non-English trigger phrases
- Each skill must be self-contained: scripts and resources live within the skill's own directory
- Cross-skill interaction is natural-language-only: "Invoke the `<skill>` skill" is the single allowed pattern. Hardcoded file paths, line numbers, internal function names, and internal reference files of other skills are forbidden. Shared logic that is reused across 2+ skills should live in a `user-invocable: false` shared skill, invoked via natural language. For smaller duplication (a few lines of regex or configuration), prefer inline duplication over cross-skill coupling.
- For self-references within a skill, use `${CLAUDE_SKILL_DIR}` (the official Claude Code runtime variable for the current skill's directory) — not hardcoded `${CLAUDE_PLUGIN_ROOT}/skills/<self>/...` paths.
- Reading a bundled file with Read / Glob / Grep needs nothing further. **Executing or reading one through the shell** (`bash`, `cd`, `source`, command substitution) MUST first resolve the directory with the canonical resolver — see `provider-contract` § Resolving the Skill Directory. `bash ${CLAUDE_SKILL_DIR}/scripts/foo.sh` is forbidden; resolution and invocation must sit in the same Bash call, and failure must fail closed rather than fall back to model-improvised logic. CI enforces the absence of unresolved shell uses.
- Never feed a shell-emitted path back into a later shell command — on Cowork the shell prints host paths it cannot itself open. Recompute instead.
- Provider-specific logic belongs in `providers/{name}/`
- The `CLAUDE_PLUGIN_ROOT` variable points to the plugin root at runtime; `${CLAUDE_SKILL_DIR}` points to the current skill's own directory
- **Output discipline**: skills run as multi-step pipelines, but the user only needs outcomes — without an explicit directive the agent narrates every step transition and relays protocol internals (provider detection, schema checks, cache state). Every user-invocable workflow skill carries an `## Output Discipline` section (limiting user-facing text to prompts, errors/warnings, outcome-changing intermediate results, and the final summary); every shared (`user-invocable: false`) skill carries a `**Silent operation:**` line. New skills must include the matching block. Pure specification skills (`waggle-protocol`, `provider-contract`) are exempt — they are documents, not pipelines.

## Semantic Versioning

| Change Type | Version Bump |
|---|---|
| Breaking changes (protocol spec) | MAJOR |
| New features (new skills, new providers) | MINOR |
| Bug fixes, docs fixes | PATCH |
