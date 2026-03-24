# Canonical Task Schema

This document defines the canonical JSON shape for a waggle Task object. All provider plugins MUST map their storage-specific representation to this shape when returning query results.

## Core Fields (14 fields — required)

Every waggle-compatible task board MUST support these fields. Providers MUST auto-repair any missing Core field on schema validation.

| Field | Type | JSON Key | Description |
|---|---|---|---|
| Title | text | `title` | Task name |
| Description | rich_text | `description` | What the task should accomplish |
| Acceptance Criteria | rich_text | `acceptanceCriteria` | Verifiable completion conditions |
| Status | enum | `status` | One of: `Backlog`, `Ready`, `In Progress`, `In Review`, `Done`, `Blocked` |
| Priority | enum | `priority` | One of: `Urgent`, `High`, `Medium`, `Low` |
| Executor | enum | `executor` | One of: `cli`, `claude-desktop`, `cowork`, `human` (extensible) |
| Blocked By | relation[] | `blockedBy` | Array of task IDs that must be Done before this task is actionable |
| Requires Review | boolean | `requiresReview` | If true, task must pass In Review before Done |
| Execution Plan | rich_text | `executionPlan` | Step-by-step plan written before dispatch. Write-once |
| Working Directory | text | `workingDirectory` | Absolute path for agent execution (workspace-relative in cowork) |
| Session Reference | text | `sessionReference` | Runtime session identifier (tmux session name, Scheduled Task ID) |
| Dispatched At | datetime | `dispatchedAt` | ISO 8601 timestamp when the task was dispatched |
| Agent Output | rich_text | `agentOutput` | Execution result written by the agent on completion |
| Error Message | rich_text | `errorMessage` | Written on failure only |

## Extended Fields (9 fields — optional)

Providers MAY support these additional fields. Skills degrade gracefully if absent. Providers MUST NOT fail if these fields do not exist.

| Field | Type | JSON Key | Description |
|---|---|---|---|
| Context | rich_text | `context` | Background info, constraints, delegation history |
| Artifacts | rich_text | `artifacts` | PR URLs, file paths (newline-separated) |
| Repository | url | `repository` | GitHub repository URL |
| Due Date | date | `dueDate` | ISO 8601 format |
| Tags | multi_select | `tags` | Free-form tags (array of strings) |
| Parent Task | relation | `parentTask` | Parent task ID (subtask relationship) |
| Project | text | `project` | Project grouping |
| Team | text | `team` | Team assignment |
| Assignees | person[] | `assignees` | Array of `{ id, name }` objects |

## Query-Only Fields

The following fields are used in query results but are NOT pushed to the view server:

- `branch` — Git branch name. Used during dispatch but not displayed in views.
- `sourceMessageId` — Messaging tool message unique ID. Used for cross-member dedup.

## Canonical Task JSON Shape

```json
{
  "id": "task-unique-id",
  "title": "Implement login page",
  "description": "Build the login page with email/password authentication...",
  "acceptanceCriteria": "1. User can log in with email/password\n2. Invalid credentials show error",
  "status": "Ready",
  "priority": "High",
  "executor": "cli",
  "blockedBy": [],
  "requiresReview": true,
  "executionPlan": "1. Create LoginPage component\n2. Add form validation\n3. Connect to auth API",
  "workingDirectory": "/home/user/project",
  "sessionReference": "",
  "dispatchedAt": null,
  "agentOutput": "",
  "errorMessage": "",
  "context": "Part of the auth epic. Design mockups in Figma.",
  "artifacts": "",
  "repository": "https://github.com/org/repo",
  "dueDate": "2026-03-25",
  "tags": ["auth", "frontend"],
  "parentTask": null,
  "project": "Auth System",
  "team": "Platform",
  "assignees": [{ "id": "user-123", "name": "Alice" }]
}
```

## Provider Mapping

Each provider maps its native field representation to the canonical JSON keys above. For example:

- **Notion**: `properties.Title.title[0].plain_text` maps to `title`
- **SQLite/Turso**: Column `title` maps directly to `title`

The mapping logic lives in each provider's SKILL.md under the "Schema" or "CRUD Operations" section.
