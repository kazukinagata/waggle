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
├── setting-up-scrum/      # Provisions Sprints DB and sprint-related fields
├── managing-tasks/        # Task CRUD + personal task dashboard
├── managing-sprints/      # Sprint lifecycle, backlog ordering, sprint planning
├── executing-tasks/       # Task dispatch orchestration (single, tmux parallel, Scheduled Tasks)
├── viewing-tasks/         # Local view server management
├── delegating-tasks/      # Reassign tasks to other org members
├── ingesting-messages/    # Auto-convert Slack/Teams DMs into tasks
├── running-standup/       # Automated sprint status report with stall detection
├── running-daily-tasks/   # Unified daily routine
├── reviewing-sprint/      # Sprint close: velocity calculation
├── analyzing-sprint-metrics/ # Retrospective metrics
└── managing-views/        # Custom view management
```

### Skill Dependency Flow

All user-invocable skills start by loading `detecting-provider` (shared) to determine the active data source and retrieve config. Skills that need user identity also load `resolving-identity`. Skills never cross-reference each other directly — shared logic lives in shared skills (`user-invocable: false`).

```
User-invocable skill
  → detecting-provider (provider + config)
  → resolving-identity (current_user)
  → providers/{active_provider}/SKILL.md (provider-specific operations)
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

Tasks have 14 Core fields (auto-repaired if missing) and 11 Extended fields (graceful degradation). See `spec/protocol.md` for the full specification.

## Development Commands

### View Server

```bash
cd skills/viewing-tasks/server

npm install          # Install dependencies
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
- No cross-references between skills — shared logic is extracted into shared skills
- Provider-specific logic belongs in `skills/providers/{name}/`
- The `CLAUDE_PLUGIN_ROOT` variable points to this repository root at runtime
- Stall detection constants: `stallThresholdMultiplier=4`, `stallDefaultHours=24`
- `maxConcurrentAgents` defaults to 3 (configurable per sprint)

## Semantic Versioning

| Change Type | Version Bump |
|---|---|
| Breaking changes (protocol spec) | MAJOR |
| New features (new skills, new providers) | MINOR |
| Bug fixes, docs fixes | PATCH |
