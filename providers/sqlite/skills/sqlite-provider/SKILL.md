---
name: sqlite-provider
description: SQLite-specific provider implementation for waggle. Loaded when the active provider is sqlite.
user-invocable: false
---

# Waggle — SQLite Provider

This file contains all SQLite-specific implementation details for waggle.
Load this file when the active provider is **sqlite**.

**Silent operation:** This skill runs as an internal step of an invoking skill. Return
results to the invoking flow without user-facing narration — the caller owns all user
communication. Only errors, warnings, and prompts required to proceed may surface directly.

## Config Retrieval

When `detecting-provider` requests config retrieval for the SQLite provider:

1. Check the `WAGGLE_SQLITE_DB_PATH` environment variable. If not set, default to `~/.waggle/tasks.db`.
2. Set the following as the `headless_config` session variable:
   - `dbPath` — the resolved path from step 1
   - `teamsDatabaseExists` (optional — true if teams table has rows)
   - `sprintsDatabaseExists` (optional — true if sprints table has rows)

## Schema Validation

After loading config, verify the database exists and has the correct schema:

```bash
sqlite3 "<dbPath>" ".tables"
```

Expected tables: `tasks`, `task_dependencies`, `teams`, `sprints`, `intake_log`.

If any table is missing, run the init script to auto-repair:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/sqlite-provider/scripts/init-db.sh "<dbPath>"
```

`init-db.sh` also migrates column additions on an already-initialized database (`CREATE TABLE IF NOT EXISTS` does not alter an existing table). It runs an idempotent, `pragma_table_info`-guarded `ALTER TABLE ... ADD COLUMN` for newer columns such as `attachments` (the `Attachments` extended field), so re-running it on any existing DB is safe and a no-op once present.

## CRUD Operations

### Create Task

**Precondition (v2.8.1+):** Before invoking the INSERT below, verify that the session-resolved `current_user.id` is **not** the fallback sentinel `"unknown"`. If it is, halt and surface an error to the caller:

> Cannot create task: current_user.id is "unknown". Configure proper identity resolution before retrying — see the Identity Resolution section below. The simplest fix is to ensure `$USER` is set in the shell environment, or set `WAGGLE_USER_ID` explicitly.

This enforces the protocol's "no anonymous tasks" rule. The Identity Resolution section (below) is structured so that `id` resolves to a real value (`$WAGGLE_USER_ID` → `$USER` → `"unknown"`) on every supported environment, so this halt should rarely fire in practice — it catches genuinely unconfigured environments (an unset `$USER` with no override).

```bash
sqlite3 "<dbPath>" "INSERT INTO tasks (title, description, acceptance_criteria, status, priority, executor, requires_review, execution_plan, working_directory, assignee, issuer) VALUES ('<title>', '<description>', '<criteria>', '<status>', '<priority>', '<executor>', <0|1>, '<plan>', '<dir>', '<assignee_json>', '${current_user.id}'); SELECT last_insert_rowid();"
```

The `issuer` column receives `${current_user.id}` directly from the substituted session variable. The caller does NOT pass an explicit Issuer — per the protocol's Issuer Auto-Populate Contract, Issuer is provider-managed.

To get the generated ID with the minimum required fields, use:
```bash
sqlite3 "<dbPath>" "INSERT INTO tasks (title, status, issuer) VALUES ('<title>', 'Backlog', '${current_user.id}') RETURNING id;"
```

**IMPORTANT:**
- Escape single quotes in values by doubling them: `'` -> `''`.
- Apply the same escape to `${current_user.id}` if the resolved value can contain quotes (it should not — `$USER`-derived strings and email addresses are quote-safe by construction, but defensive escaping is recommended).

### Update Task

```bash
sqlite3 "<dbPath>" "UPDATE tasks SET <field> = '<value>', updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = '<task_id>';"
```

For multiple fields:
```bash
sqlite3 "<dbPath>" "UPDATE tasks SET status = '<status>', agent_output = '<output>', updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = '<task_id>';"
```

`tags`, `assignee`, and `attachments` are stored as JSON-array text. For `attachments`, set a JSON array of file descriptors — this provider does **not** host files (`supportsFileHosting=false`), so each `url` must be an externally-hosted, caller-supplied URL:
```bash
sqlite3 "<dbPath>" "UPDATE tasks SET attachments = '[{\"url\":\"https://files.example.com/spec.pdf\",\"name\":\"spec.pdf\",\"mime_type\":\"application/pdf\"}]', updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = '<task_id>';"
```

### Get Task

```bash
sqlite3 -json "<dbPath>" "SELECT t.*, GROUP_CONCAT(td.blocked_by_id) as blocked_by_ids FROM tasks t LEFT JOIN task_dependencies td ON t.id = td.task_id WHERE t.id = '<task_id>' GROUP BY t.id;"
```

### Delete Task

```bash
sqlite3 "<dbPath>" "DELETE FROM tasks WHERE id = '<task_id>';"
```

Dependencies are automatically removed via `ON DELETE CASCADE`.

### Manage Dependencies (Blocked By)

Add dependency:
```bash
sqlite3 "<dbPath>" "INSERT OR IGNORE INTO task_dependencies (task_id, blocked_by_id) VALUES ('<task_id>', '<blocker_id>');"
```

Remove dependency:
```bash
sqlite3 "<dbPath>" "DELETE FROM task_dependencies WHERE task_id = '<task_id>' AND blocked_by_id = '<blocker_id>';"
```

## Querying Tasks

Use the query script for filtered queries with JSON output:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/sqlite-provider/scripts/query-tasks.sh \
  "<dbPath>" '<where_clause>' '<order_clause>'
```

### Filter Recipes

**All tasks (no filter):**
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/sqlite-provider/scripts/query-tasks.sh "<dbPath>"
```

**Ready tasks:**
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/sqlite-provider/scripts/query-tasks.sh "<dbPath>" "t.status = 'Ready'"
```

**Tasks by executor and status (single executor):**
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/sqlite-provider/scripts/query-tasks.sh "<dbPath>" "t.status = 'Ready' AND t.executor = 'cowork'"
```

**Tasks by executor and status (multiple executors — for cli/claude-desktop environments):**
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/sqlite-provider/scripts/query-tasks.sh "<dbPath>" "t.status = 'Ready' AND t.executor IN ('cli','claude-desktop','cowork')"
```

**Tasks assigned to current user:**
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/sqlite-provider/scripts/query-tasks.sh "<dbPath>" "t.assignee LIKE '%<user_id>%'"
```

**Tasks owned by user via Assignee OR Issuer fallback (v2.8.1+):**
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/sqlite-provider/scripts/query-tasks.sh "<dbPath>" \
  "(t.assignee LIKE '%<user_id>%' OR (t.issuer = '<user_id>' AND (t.assignee IS NULL OR t.assignee = '' OR t.assignee = '[]')))"
```

Note that `t.issuer` is a single-value `TEXT` column (not a JSON array), so it uses `=` for exact match against `<user_id>`. This is the SQLite equivalent of the Notion filter `Issuer.created_by:{contains:<user_id>}`.

**In Progress tasks (for concurrency check):**
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/sqlite-provider/scripts/query-tasks.sh "<dbPath>" "t.status = 'In Progress' AND t.assignee LIKE '%<user_id>%'"
```

**Sort by Priority then Due Date:**
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/sqlite-provider/scripts/query-tasks.sh "<dbPath>" "" \
  "CASE t.priority WHEN 'Urgent' THEN 1 WHEN 'High' THEN 2 WHEN 'Medium' THEN 3 WHEN 'Low' THEN 4 END ASC, t.due_date ASC"
```

#### Hierarchy Queries

**Subtasks of a parent:**
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/sqlite-provider/scripts/query-tasks.sh "<dbPath>" "t.parent_task_id = '<parent_task_id>'"
```

**Check if a task has children:**
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/sqlite-provider/scripts/query-tasks.sh "<dbPath>" "t.parent_task_id = '<task_id>'" | jq '.results | length'
```

**Check if a candidate parent is itself a subtask:**
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/sqlite-provider/scripts/query-tasks.sh "<dbPath>" "t.id = '<candidate_parent_id>'" | jq '.results[0].parent_task_id'
```
If the result is non-null, the candidate is already a subtask and cannot be used as a parent (2-level limit).

### Post-Processing (all queries)

- **Blocked By resolved**: Check that the `blocked_by` array is empty OR query each blocked_by task and confirm all have status = 'Done'.
- **Sort** (if not done in query): Priority — Urgent > High > Medium > Low; then by Due Date (earliest first).

### Displaying Task Lists

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/sqlite-provider/scripts/query-tasks.sh "<dbPath>" '<where>' '<order>' | \
  jq '[.results[] | {id, title, status, priority, executor, assignee, due_date, blocked_by: (.blocked_by | length | tostring) + " deps"}]'
```

## Task Record Reference

When referring to a task in dispatch prompts and completion instructions, use:
- **Task ID**: the hex string ID from the `id` column
- **Update instruction**: "Run: `sqlite3 <dbPath> \"UPDATE tasks SET agent_output = '<result>', status = 'Done', updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = '<task_id>';\"`"

## On Completion Template

The following template is injected into dispatch prompts by `executing-tasks`. Placeholders are resolved at dispatch time.

```
Task ID: <task_id>
Database path: <db_path>

On completion:
1. Run: sqlite3 "<db_path>" "UPDATE tasks SET agent_output='<result>', status='Done', updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id='<task_id>';"
   - If Requires Review = ON: set status to 'In Review' instead of 'Done'
2. On error: sqlite3 "<db_path>" "UPDATE tasks SET error_message='<error>', status='Blocked', updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id='<task_id>';"
```

## Pushing Data to View Server

After any task operation (create, update, delete), push fresh data to the local view server:

1. Fetch all tasks:
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/sqlite-provider/scripts/query-tasks.sh "<dbPath>"
```

2. Format as TasksResponse and POST:
```bash
TASKS_JSON=$(bash ${CLAUDE_PLUGIN_ROOT}/skills/sqlite-provider/scripts/query-tasks.sh "<dbPath>" | jq -c '{tasks: [.results[] | {
  id, title, description, acceptanceCriteria: .acceptance_criteria, status, blockedBy: .blocked_by,
  priority, executor, requiresReview: .requires_review, executionPlan: .execution_plan,
  workingDirectory: .working_directory, sessionReference: .session_reference,
  dispatchedAt: .dispatched_at, agentOutput: .agent_output, errorMessage: .error_message,
  context, artifacts, repository, dueDate: .due_date, tags, parentTaskId: .parent_task_id,
  project, team, assignee, attachments, issuer, url: "", sprintId: .sprint_id, sprintName: null,
  complexityScore: .complexity_score, backlogOrder: .backlog_order
}], updatedAt: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))}')

curl -s http://localhost:3456/api/health -o /dev/null 2>/dev/null && \
  curl -s -X POST http://localhost:3456/api/data \
    -H "Content-Type: application/json" -d "$TASKS_JSON" -o /dev/null 2>/dev/null || true
```

### View Server Field Mapping

| SQLite Column | TasksResponse Field |
|---|---|
| id | `id` |
| title | `title` |
| description | `description` |
| acceptance_criteria | `acceptanceCriteria` |
| status | `status` |
| blocked_by (via task_dependencies) | `blockedBy` |
| priority | `priority` |
| executor | `executor` |
| requires_review | `requiresReview` (boolean) |
| execution_plan | `executionPlan` |
| working_directory | `workingDirectory` |
| session_reference | `sessionReference` |
| dispatched_at | `dispatchedAt` |
| agent_output | `agentOutput` |
| error_message | `errorMessage` |
| context | `context` |
| artifacts | `artifacts` |
| repository | `repository` |
| due_date | `dueDate` |
| tags | `tags` (JSON array) |
| parent_task_id | `parentTaskId` |
| project | `project` |
| team | `team` |
| assignee | `assignee` (JSON array) |
| attachments | `attachments` (JSON array of `{url, name, mime_type?, size?}`; `supportsFileHosting=false` — externally-hosted URLs only) |
| issuer | `issuer` (single user ID string; auto-populated by Create Task template, v2.8.1+) |
| (empty string) | `url` |
| sprint_id | `sprintId` |
| complexity_score | `complexityScore` |
| backlog_order | `backlogOrder` |

## Identity: Resolve Current User

Called by `resolving-identity` shared skill when `active_provider = sqlite`.

SQLite is local — no remote user system. Identity is derived from the shell environment so that multi-user machines and CI environments produce distinct user IDs.

Resolution order:

1. If `WAGGLE_USER_ID` env var is set and non-empty → use it. This is the override path for environments where `$USER` is not meaningful (CI runners, shared service accounts, automation).
2. Else if `$USER` env var is set and non-empty → use it. On Linux / macOS / WSL this gives a per-user shell account name that is unique on the machine. (v2.8.1+: previously this populated only `name`; now it also populates `id`.)
3. Else → `id` ← `"unknown"`. This sentinel signals "identity is genuinely unresolvable" and triggers the Create Task precondition halt.

Concretely set:
- `id` ← `$WAGGLE_USER_ID` if non-empty, else `$USER` if non-empty, else `"unknown"`
- `name` ← `$USER` env var or `"unknown"`
- `email` ← `null`

**Note (v2.8.1+):** The Create Task precondition halts only when `id == "unknown"`. The literal `"local"` is no longer used as a fallback — using `$USER` directly gives a real identifier on every supported environment, eliminating the "every task is owned by 'local'" failure mode.

## Identity: Resolve Team Membership

If teams table has rows:
1. Query: `sqlite3 -json "<dbPath>" "SELECT * FROM teams;"`
2. Parse members JSON array for each team
3. Match by name (case-insensitive) against `current_user.name`
4. Set `current_user.teams` and `current_team` per the same logic as other providers

## Identity: List Org Members

SQLite is local — return members from teams table if available, otherwise `org_members: []`.

```bash
sqlite3 -json "<dbPath>" "SELECT members FROM teams;" | jq '[.[].members | fromjson | .[] ] | unique_by(.name)'
```

## Error Handling

| Error Category | Condition | Action |
|---|---|---|
| Database locked | `SQLITE_BUSY` | Retryable — wait 1-2 seconds and retry, max 3 attempts |
| File not found | DB path does not exist | Terminal — instruct user to run `setting-up-tasks` |
| Schema mismatch | Missing table or column | Auto-repair — run `init-db.sh` to create missing tables |
