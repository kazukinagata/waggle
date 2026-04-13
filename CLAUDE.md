# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Waggle** is an async task coordination protocol for autonomous AI agents, implemented as a Claude Code plugin. It provides natural language CRUD operations, real-time HTML views (Kanban, List, Calendar, Gantt), and autonomous task execution via tmux parallel sessions or Scheduled Tasks. It supports any schema-definable data source through a provider abstraction (currently Notion).

## Architecture

### Plugin Structure

This is a Claude Code plugin (`.claude-plugin/plugin.json`). Skills are the core building blocks — each skill is a self-contained markdown-driven module under `skills/`.

```
skills/
├── detecting-provider/    # (shared) Provider auto-detection + config retrieval
├── resolving-identity/    # (shared) Current user identity resolution
├── looking-up-members/    # (shared) Member name/email → provider user ID
├── providers/notion/      # Notion-specific implementation
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
```

### Skill Dependency Flow

All user-invocable skills start by invoking `detecting-provider` (shared) to determine the active data source and retrieve config. Skills that need user identity also invoke `resolving-identity`.

Skills interact with each other only through natural language invocation. A skill's SKILL.md or reference files may instruct the agent to "invoke the `<other-skill>` skill" in plain English, and the agent (which has all skill frontmatters indexed via Claude Code's skill discovery mechanism) will load the target skill's SKILL.md and follow its instructions. Invocation is permitted across any two skills regardless of `user-invocable` value (though shared skills are preferred for logic reuse).

A skill must NOT know anything about another skill beyond the name and description in the target's frontmatter. The following patterns are forbidden in any skill file (SKILL.md, references/*, scripts/*):

- Hardcoded paths to another skill's files: `bash ${CLAUDE_PLUGIN_ROOT}/skills/other-skill/scripts/foo.sh`
- Hardcoded paths to another skill's SKILL.md: `Load ${CLAUDE_PLUGIN_ROOT}/skills/other-skill/SKILL.md`
- References to another skill's internal structure: line number citations, internal function or predicate names, internal reference file names, internal step number references

The only stable public contract is the frontmatter (name + description); agents resolve invocations through skill discovery. The target skill's internal structure (script layout, function names, step numbers, reference file names) must be free to evolve without breaking dependents.

A skill is always free to reference its own files. For self-references, use the official Claude Code runtime variable `${CLAUDE_SKILL_DIR}`, which the runtime automatically resolves to the directory containing the current skill's SKILL.md:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/my-script.sh
```

Avoid `${CLAUDE_PLUGIN_ROOT}/skills/<self-name>/scripts/...` for self-references — it hardcodes the skill name and breaks silently on rename or relocation.

```
User-invocable skill
  → invoke detecting-provider (provider + config)
  → invoke resolving-identity (current_user)
  → invoke providers/{active_provider} (provider-specific operations)
```

### Provider Abstraction

The provider layer (`skills/providers/{name}/SKILL.md`) encapsulates all data-source-specific operations: schema validation, auto-repair, CRUD via MCP tools, identity resolution, and view server data push. Currently Notion is implemented; SQLite and Turso are planned.

### View Server

A Hono-based TypeScript server at `skills/viewing-tasks/server/` serves interactive HTML views on `http://localhost:3456`. It receives task data via POST `/api/data` and pushes real-time updates to clients via SSE at `/api/events`.

### Task Execution

Tasks can be executed in three modes based on execution environment:
- **cli (Terminal)**: Single task in current session, or parallel via tmux panes
- **claude-desktop (Claude Desktop)**: Single task in current session, or parallel via Scheduled Tasks
- **cowork (Cowork)**: Single task in current session, or parallel via Scheduled Tasks

### Task Schema

Tasks have 15 Core fields (auto-repaired if missing) and 9 Extended fields (graceful degradation). Key fields: Status (Backlog/Ready/In Progress/In Review/Done/Blocked/Cancelled), Executor (cli/claude-code/claude-desktop/cowork/human), Priority, Blocked By (dependency relation), Issuer (task creator/owner). CLI and Claude Desktop environments can execute tasks for any AI executor type (cli/claude-code/claude-desktop/cowork), while Cowork can only execute cowork tasks due to VM constraints.

## Development Commands

### View Server

```bash
cd skills/viewing-tasks/server

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
- Provider-specific logic belongs in `skills/providers/{name}/`
- The `CLAUDE_PLUGIN_ROOT` variable points to the plugin root at runtime; `${CLAUDE_SKILL_DIR}` points to the current skill's own directory

## Semantic Versioning

| Change Type | Version Bump |
|---|---|
| Breaking changes (protocol spec) | MAJOR |
| New features (new skills, new providers) | MINOR |
| Bug fixes, docs fixes | PATCH |
