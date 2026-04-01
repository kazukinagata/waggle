---
name: provider-contract
description: >
  Waggle provider plugin development guide and interface contract.
  Defines the required SKILL.md sections, data shapes, naming conventions,
  and compliance checklist for building a waggle provider plugin.
  Trigger on: "provider contract", "provider interface", "create provider plugin",
  "new provider", "provider compliance", "how to build a provider".
user-invocable: true
---

# Waggle Provider Contract

This document defines the interface contract for building a waggle provider plugin. A provider plugin connects waggle to a specific data store (Notion, SQLite, Turso, etc.) by implementing a standardized set of operations and SKILL.md sections.

## How Provider Discovery Works

Waggle core discovers provider skills differently depending on the runtime environment:

- **Cowork**: Provider skills appear in the `<available_skills>` system prompt block. Each skill is listed with `<name>`, `<description>`, and `<location>`.
- **CLI / Claude Desktop**: Provider skills are registered via `installed_plugins.json`. The plugin's `.claude-plugin/plugin.json` declares the plugin metadata.

In all environments, waggle core loads the provider SKILL.md via the Skill tool. `${CLAUDE_PLUGIN_ROOT}` in the provider SKILL.md is automatically resolved to the provider plugin's absolute path.

## Naming Conventions

Follow these naming rules strictly:

| Entity | Pattern | Example |
|---|---|---|
| Plugin directory | `waggle-{provider}` | `waggle-sqlite` |
| Setup skill | `{provider}-setup` | `sqlite-setup` |
| Provider skill | `{provider}-provider` | `sqlite-provider` |
| Plugin name in plugin.json | `waggle-{provider}` | `waggle-sqlite` |

- The setup skill MUST be `user-invocable: true`.
- The provider skill MUST be `user-invocable: false`.

## Plugin Directory Structure

```
waggle-{provider}/
├── .claude-plugin/
│   └── plugin.json          # Plugin metadata (name, version, description)
├── skills/
│   ├── {provider}-setup/
│   │   ├── SKILL.md         # user-invocable: true — initial setup wizard
│   │   └── references/      # Setup-specific references (optional)
│   └── {provider}-provider/
│       ├── SKILL.md         # user-invocable: false — all provider operations
│       └── scripts/         # Bash scripts using SCRIPT_DIR pattern
└── CLAUDE.md                # Project-level instructions
```

## Required Sections in Provider SKILL.md

The `{provider}-provider/SKILL.md` file MUST contain all of the following sections with exact headings. Waggle core skills reference these sections by name.

### 1. Config Retrieval

Retrieve provider configuration (database IDs, constants) and populate the `headless_config` session variable.

Requirements:
- MUST be self-sufficient — do not depend on a local config file as the sole source.
- Each provider uses its natural storage for config:
  - Notion: Search for the "Waggle Config" page, parse JSON code block.
  - Turso: Read from `TURSO_URL` and `TURSO_AUTH_TOKEN` environment variables.
  - SQLite: Use a default path (`~/.waggle/waggle.db`) or `WAGGLE_SQLITE_PATH` env var.
- `~/.waggle/config.json` MAY be used as a local cache for faster startup, but MUST NOT be the only source.
- If config is not found, instruct the user to run the `{provider}-setup` skill, then stop.

The `headless_config` object MUST include at minimum:
- `tasksDatabaseId` (or equivalent identifier for the tasks data source)

Optional fields:
- `teamsDatabaseId`
- `intakeLogDatabaseId`

### 2. Schema Validation & Auto-Repair

Verify that all 15 Core fields exist in the backing store. See `references/task-schema.md` for the complete field list.

Requirements:
- On startup, check every Core field exists with the correct type.
- If any Core field is missing, automatically repair it — create the field with sensible defaults.
- Never ask the user to manually fix the schema.
- After repair, re-verify and continue.

### 3. CRUD Operations

Implement Create, Read, Update, and Delete for tasks.

Requirements:
- **Create**: Accept all Core and Extended fields. Return the created task ID.
- **Read**: Retrieve a single task by ID with all field values.
- **Update**: Update one or more fields on an existing task by ID.
- **Delete**: Delete a task by ID.
- Document which MCP tools or API calls are used for each operation.

### 4. Query Tasks

Filter and sort tasks, returning results in the standard query output format.

Requirements:
- Accept filter and sort parameters.
- Return `{ "results": [Task, Task, ...] }` — see `references/query-output-format.md`.
- Support filtering by: Status, Priority, Executor, Assignees.
- Support sorting by: Priority, Due Date.
- Document the query mechanism (API script, SQL query, MCP tool).
- Include a "Fetch All Tasks" variant with no filter for view server data push.
- Include a "Displaying Task Lists" variant that extracts only display-relevant fields.

### 5. Identity Resolution

Resolve the current user, team membership, and org members.

Requirements:
- **Current User**: Return `{ id, name, email }`. Provide a fallback using `$USER` env var if the provider API is unavailable.
- **Team Membership**: Given `teamsDatabaseId`, determine which teams the current user belongs to. Handle single-team, multi-team (ask user), and no-team cases.
- **Org Members**: List all workspace/org members as `{ id, name, email }[]`. Provide a fallback (empty array) if unavailable.
- **Self-Task Detection**: Describe how to check if a task is assigned to the current user.

### 6. View Server Data Push

Push task data to the local view server after any task mutation.

Requirements:
- Fetch all tasks from the data source.
- Transform into the `TasksResponse` shape: `{ "tasks": [...], "updatedAt": "<ISO timestamp>" }`.
- POST to `http://localhost:3456/api/data`.
- Silently skip if the view server is not running (check health endpoint first).

### 7. On Completion Template

Define the instructions injected into dispatch prompts so dispatched agents know how to report results. See `references/dispatch-completion-template.md` for the full specification.

Requirements:
- Include the task ID placeholder.
- Specify how to write results to Agent Output.
- Specify how to update Status based on Requires Review.
- Specify how to record errors to Error Message.
- Use absolute paths for any scripts. MUST NOT use `${CLAUDE_PLUGIN_ROOT}`.

### 8. Error Handling

Define error categories and retry behavior.

Requirements:
- Classify errors into retryable (transient network errors, rate limits) and terminal (auth failures, missing permissions, invalid schema).
- For retryable errors: specify max retries and backoff strategy.
- For terminal errors: specify the user-facing message and recovery action.
- Provider API errors MUST NOT crash the skill — handle gracefully and report.

## Script Path Convention

Bash scripts in the provider plugin MUST follow these rules:

1. Use the `SCRIPT_DIR` pattern for self-referencing paths:
   ```bash
   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
   ```

2. MUST NOT use `${CLAUDE_PLUGIN_ROOT}` in bash scripts. This variable is only available in the SKILL.md instruction context, not in shell execution.

3. SKILL.md instructions MUST reference scripts using `${CLAUDE_PLUGIN_ROOT}`:
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/skills/{provider}-provider/scripts/query-tasks.sh ...
   ```
   Provider SKILL.md is loaded via the Skill tool, which automatically resolves `${CLAUDE_PLUGIN_ROOT}` to the provider plugin's absolute path.

4. Scripts that call other scripts within the plugin MUST use `SCRIPT_DIR`-relative paths:
   ```bash
   source "${SCRIPT_DIR}/helpers.sh"
   ```

## Config Storage

All provider configuration is stored via environment variables in `~/.claude/settings.json` (under the `env` field). The legacy `~/.waggle/config.json` file is deprecated — use the `health-checking` skill to migrate.

| Provider | Env Vars | Fallback |
|---|---|---|
| Notion | `WAGGLE_NOTION_TASKS_DB_ID`, `WAGGLE_NOTION_TEAMS_DB_ID` (optional cache) | "Waggle Config" Notion page search |
| Turso | `TURSO_URL`, `TURSO_AUTH_TOKEN` (required) | None |
| SQLite | `WAGGLE_SQLITE_DB_PATH` (optional, default: `~/.waggle/tasks.db`) | Default path |

## Environment Support

Not all providers support all execution environments:

| Provider | CLI | Claude Desktop | Cowork | Notes |
|---|---|---|---|---|
| Notion | Yes | Yes | Yes | Requires Notion MCP tools |
| Turso | Yes | Yes | No | Requires `TURSO_URL` and `TURSO_AUTH_TOKEN` env vars; Cowork requires Desktop Extension (not yet available) |
| SQLite | Yes | Yes | No | Local file — not accessible from Cowork |

See `references/environment-detection.md` for runtime environment detection logic.

## Provider Compliance Checklist

Use this checklist to verify a provider plugin meets all requirements before release:

### Plugin Structure
- [ ] Plugin directory follows `waggle-{provider}` naming
- [ ] `.claude-plugin/plugin.json` exists with correct metadata
- [ ] Setup skill exists at `skills/{provider}-setup/SKILL.md` with `user-invocable: true`
- [ ] Provider skill exists at `skills/{provider}-provider/SKILL.md` with `user-invocable: false`

### Provider SKILL.md Sections
- [ ] Config Retrieval — self-sufficient, not solely dependent on local config file
- [ ] Schema Validation & Auto-Repair — all 15 Core fields verified and auto-repaired
- [ ] CRUD Operations — Create, Read, Update, Delete documented
- [ ] Query Tasks — filter/sort with `{ "results": [...] }` output format
- [ ] Identity Resolution — current user, teams, org members, self-task detection
- [ ] View Server Data Push — TasksResponse shape, POST to localhost:3456
- [ ] On Completion Template — task ID placeholder, absolute paths, no `${CLAUDE_PLUGIN_ROOT}`
- [ ] Error Handling — retryable vs terminal classification

### Script Conventions
- [ ] All bash scripts use `SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"` pattern
- [ ] No `${CLAUDE_PLUGIN_ROOT}` in bash scripts
- [ ] SKILL.md uses `${CLAUDE_PLUGIN_ROOT}` for script references

### Schema Support
- [ ] All 15 Core fields supported with correct types
- [ ] Extended fields supported with graceful degradation if absent
- [ ] Auto-repair creates missing fields without user intervention

### Data Format
- [ ] Query output matches `{ "results": [Task, ...] }` format
- [ ] Task objects include `id` and all populated field values
- [ ] View server data matches `TasksResponse` shape
