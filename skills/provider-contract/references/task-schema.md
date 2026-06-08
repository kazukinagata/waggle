# Canonical Task Schema

This document defines the canonical JSON shape for a waggle Task object. All provider plugins MUST map their storage-specific representation to this shape when returning query results.

## Core Fields (15 fields — required)

Every waggle-compatible task board MUST support these fields. Providers MUST auto-repair any missing Core field on schema validation.

| Field | Type | JSON Key | Description |
|---|---|---|---|
| Title | text | `title` | Task name |
| Description | rich_text | `description` | What the task should accomplish |
| Acceptance Criteria | rich_text | `acceptanceCriteria` | Verifiable completion conditions |
| Status | enum | `status` | One of: `Backlog`, `Ready`, `In Progress`, `In Review`, `Done`, `Blocked`, `Cancelled` |
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
| Issuer | provider-managed | `issuer` | Who created/initiated this task. **Auto-populated by the provider on create (Notion: `created_by` column type; SQLite/Turso: `TEXT` with caller-substituted `${current_user.id}` in the provider's Create Task template). Read-only after creation. Skills MUST NOT include Issuer in create payloads.** See waggle-protocol § Issuer Auto-Populate Contract. v2.8.1+ |

## Hierarchy Fields (1 field — required for subtask support)

| Field | Type | JSON Key | Description |
|---|---|---|---|
| Parent Task | relation | `parentTask` | Parent task ID. Creates a 2-level hierarchy (parent → subtask). |

### Hierarchy Constraints

- **2-level limit**: A task with a non-null `parentTask` (i.e., a subtask) MUST NOT have children of its own. Enforced at write time by validation.
- **No circular references**: A task cannot be its own parent.
- **Status cascading**: When all subtasks reach Done, the parent auto-transitions to Done. Adding or re-opening a subtask on a Done parent reverts it to In Progress. See managing-tasks for details.

## Extended Fields (11 fields — optional)

Providers MAY support these additional fields. Skills degrade gracefully if absent. Providers MUST NOT fail if these fields do not exist.

| Field | Type | JSON Key | Description |
|---|---|---|---|
| Context | rich_text | `context` | Background info, constraints, delegation history |
| Artifacts | rich_text | `artifacts` | PR URLs, file paths (newline-separated) |
| Repository | url | `repository` | GitHub repository URL |
| Due Date | date | `dueDate` | ISO 8601 format |
| Tags | multi_select | `tags` | Free-form tags (array of strings) |
| Project | text | `project` | Project grouping |
| Team | text | `team` | Team assignment |
| Assignee | person[] | `assignee` | Array of `{ id, name }` objects |
| Attachments | file[] | `attachments` | Array of file descriptors `{ url, name, mime_type?, size? }`. References to hosted bytes, not the bytes. Hosting is per-provider — see `supportsFileHosting` under Provider Mapping. v2.13.0+ |
| Created At | datetime | `createdAt` | ISO 8601 timestamp, auto-populated on creation. Read-only. |
| Acknowledged At | datetime | `acknowledgedAt` | ISO 8601 timestamp, auto-set when assignee first views the task. Reset on delegation. |

### `file[]` shape

Each element of an `attachments` array is a file descriptor:

| Key | Type | Required | Description |
|---|---|---|---|
| `url` | string | yes | Location of the hosted bytes. Provider-hosted URLs may be signed and time-limited (see Provider Mapping); externally-hosted URLs are stable. |
| `name` | string | yes | Display filename. |
| `mime_type` | string | no | MIME type if known (e.g. `image/png`, `application/pdf`). |
| `size` | number | no | Byte size if known. |

The field carries **references** to bytes hosted elsewhere — never the bytes themselves. A provider that cannot host file bytes (`supportsFileHosting=false`) stores only externally-hosted URLs the caller supplies.

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
  "issuer": { "id": "user-123", "name": "Alice" },     // normalized at the provider boundary — see "Issuer shape normalization" below
  "context": "Part of the auth epic. Design mockups in Figma.",
  "artifacts": "",
  "repository": "https://github.com/org/repo",
  "dueDate": "2026-03-25",
  "tags": ["auth", "frontend"],
  "parentTask": null,
  "project": "Auth System",
  "team": "Platform",
  "assignee": [{ "id": "user-123", "name": "Alice" }],
  "attachments": [
    { "url": "https://files.example.com/spec.pdf", "name": "spec.pdf", "mime_type": "application/pdf", "size": 18234 }
  ],
  "createdAt": "2026-03-20T10:00:00.000Z",
  "acknowledgedAt": null
}
```

### Issuer shape normalization (v2.8.1+)

Different providers store Issuer in different native shapes:

- **Notion**: a `created_by` property value, which the API returns as `{ "id": "<uuid>", "name": "<full name>", "type": "person", "person": { "email": "..." } }`.
- **SQLite / Turso**: a single `TEXT` column holding a user ID string (typically `$USER` or a `WAGGLE_USER_ID` override).

To keep downstream consumers (view server, monitoring scripts, validators) provider-agnostic, **each provider normalizes Issuer into the same `{ id, name }` shape at the boundary**:

| Provider | Native value | Normalized canonical value |
|---|---|---|
| Notion | `{id, name, person.email, ...}` | `{ id, name }` (other fields dropped) |
| SQLite / Turso | `"alice"` (plain string) | `{ id: "alice", name: "alice" }` (id and name both set to the string; `email` is omitted) |

This means consumers of the canonical JSON can always assume `issuer.id` exists and is a string. If they need a human-readable label, they can use `issuer.name`. Provider implementations are responsible for performing this normalization in their query/get paths (e.g., the SQLite provider's view-server mapping `jq` expression wraps the bare `issuer` text into the object shape).

## Provider Mapping

Each provider maps its native field representation to the canonical JSON keys above. For example:

- **Notion**: `properties.Title.title[0].plain_text` maps to `title`
- **SQLite/Turso**: Column `title` maps directly to `title`

The mapping logic lives in each provider's SKILL.md under the "Schema" or "CRUD Operations" section.

### Attachments hosting (`supportsFileHosting`)

The `attachments` (`file[]`) field is special: it is not just a column type but a **hosting capability**. A
file descriptor's `url` must point at hosted bytes, and providers differ in whether they can produce that
hosting. This is declared per provider as `supportsFileHosting`. Waggle has no runtime capability negotiation
— this flag is **guidance for skills**, not a value any code reads.

| Provider | supportsFileHosting | Mechanism |
|---|---|---|
| Notion | true | Native `files` property. Local files are uploaded via the Notion File Upload API and Notion hosts them; uploaded entries read back as `type:"file"` with a **signed URL that expires (~1h)**. External-URL entries are stored as-is and are stable. |
| SQLite | false | `attachments TEXT` column holding a JSON array. No hosting — the `url` of each descriptor must be an externally-hosted, caller-supplied URL. |
| Turso | false | Same as SQLite (libSQL). No hosting — externally-hosted URLs only. |

**Skill guidance:** when the active provider's `supportsFileHosting` is `false`, skills MUST require an
externally-hosted `url` for each attachment and MUST NOT attempt to upload a local file. When it is `true`,
skills may upload a local file and let the provider host it. Because provider-hosted URLs can expire,
consumers that need a fresh URL should re-fetch the task from the provider rather than trust a cached `url`.
