---
name: sqlite-provider
description: SQLite-specific provider implementation for waggle. Loaded when the active provider is sqlite.
user-invocable: false
---

# Waggle — SQLite Provider

This file contains all SQLite-specific implementation details for waggle.
Load this file when the active provider is **sqlite**.

## Config Retrieval

When `detecting-provider` requests config retrieval for the SQLite provider:

1. Read `~/.waggle/config.json`
2. Parse and set the following as the `headless_config` session variable:
   - `dbPath` (required) — path to the SQLite database file
   - `teamsDatabaseExists` (optional — true if teams table has rows)
   - `sprintsDatabaseExists` (optional — true if sprints table has rows)
   - `maxConcurrentAgents` (optional — default: 3)

If `~/.waggle/config.json` is not found, instruct the user to run the **setting-up-tasks** skill, then stop.

## Schema Validation

After loading config, verify the database exists and has the correct schema:

```bash
sqlite3 "<dbPath>" ".tables"
```

Expected tables: `tasks`, `task_dependencies`, `teams`, `sprints`, `intake_log`.

If any table is missing, run the init script to auto-repair:

```bash
bash ${PROVIDER_PLUGIN_ROOT}/skills/sqlite-provider/scripts/init-db.sh "<dbPath>"
```

## CRUD Operations

### Create Task

```bash
sqlite3 "<dbPath>" "INSERT INTO tasks (title, description, acceptance_criteria, status, priority, executor, requires_review, execution_plan, working_directory, assignees) VALUES ('<title>', '<description>', '<criteria>', '<status>', '<priority>', '<executor>', <0|1>, '<plan>', '<dir>', '<assignees_json>'); SELECT last_insert_rowid();"
```

To get the generated ID, use:
```bash
sqlite3 "<dbPath>" "INSERT INTO tasks (title, status) VALUES ('<title>', 'Backlog') RETURNING id;"
```

**IMPORTANT:** Escape single quotes in values by doubling them: `'` -> `''`.

### Update Task

```bash
sqlite3 "<dbPath>" "UPDATE tasks SET <field> = '<value>', updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = '<task_id>';"
```

For multiple fields:
```bash
sqlite3 "<dbPath>" "UPDATE tasks SET status = '<status>', agent_output = '<output>', updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = '<task_id>';"
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
bash ${PROVIDER_PLUGIN_ROOT}/skills/sqlite-provider/scripts/query-tasks.sh \
  "<dbPath>" '<where_clause>' '<order_clause>'
```

### Filter Recipes

**All tasks (no filter):**
```bash
bash ${PROVIDER_PLUGIN_ROOT}/skills/sqlite-provider/scripts/query-tasks.sh "<dbPath>"
```

**Ready tasks:**
```bash
bash ${PROVIDER_PLUGIN_ROOT}/skills/sqlite-provider/scripts/query-tasks.sh "<dbPath>" "t.status = 'Ready'"
```

**Tasks by executor and status:**
```bash
bash ${PROVIDER_PLUGIN_ROOT}/skills/sqlite-provider/scripts/query-tasks.sh "<dbPath>" "t.status = 'Ready' AND t.executor = 'cli'"
```

**Tasks assigned to current user:**
```bash
bash ${PROVIDER_PLUGIN_ROOT}/skills/sqlite-provider/scripts/query-tasks.sh "<dbPath>" "t.assignees LIKE '%<user_id>%'"
```

**In Progress tasks (for concurrency check):**
```bash
bash ${PROVIDER_PLUGIN_ROOT}/skills/sqlite-provider/scripts/query-tasks.sh "<dbPath>" "t.status = 'In Progress' AND t.assignees LIKE '%<user_id>%'"
```

**Sort by Priority then Due Date:**
```bash
bash ${PROVIDER_PLUGIN_ROOT}/skills/sqlite-provider/scripts/query-tasks.sh "<dbPath>" "" \
  "CASE t.priority WHEN 'Urgent' THEN 1 WHEN 'High' THEN 2 WHEN 'Medium' THEN 3 WHEN 'Low' THEN 4 END ASC, t.due_date ASC"
```

### Post-Processing (all queries)

- **Blocked By resolved**: Check that the `blocked_by` array is empty OR query each blocked_by task and confirm all have status = 'Done'.
- **Sort** (if not done in query): Priority — Urgent > High > Medium > Low; then by Due Date (earliest first).

### Displaying Task Lists

```bash
bash ${PROVIDER_PLUGIN_ROOT}/skills/sqlite-provider/scripts/query-tasks.sh "<dbPath>" '<where>' '<order>' | \
  jq '[.results[] | {id, title, status, priority, executor, assignees, due_date, blocked_by: (.blocked_by | length | tostring) + " deps"}]'
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
bash ${PROVIDER_PLUGIN_ROOT}/skills/sqlite-provider/scripts/query-tasks.sh "<dbPath>"
```

2. Format as TasksResponse and POST:
```bash
TASKS_JSON=$(bash ${PROVIDER_PLUGIN_ROOT}/skills/sqlite-provider/scripts/query-tasks.sh "<dbPath>" | jq -c '{tasks: [.results[] | {
  id, title, description, acceptanceCriteria: .acceptance_criteria, status, blockedBy: .blocked_by,
  priority, executor, requiresReview: .requires_review, executionPlan: .execution_plan,
  workingDirectory: .working_directory, sessionReference: .session_reference,
  dispatchedAt: .dispatched_at, agentOutput: .agent_output, errorMessage: .error_message,
  context, artifacts, repository, dueDate: .due_date, tags, parentTaskId: .parent_task_id,
  project, team, assignees, url: "", sprintId: .sprint_id, sprintName: null,
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
| assignees | `assignees` (JSON array) |
| (empty string) | `url` |
| sprint_id | `sprintId` |
| complexity_score | `complexityScore` |
| backlog_order | `backlogOrder` |

## Identity: Resolve Current User

Called by `resolving-identity` shared skill when `active_provider = sqlite`.

SQLite is local — no remote user system. Set:
- `id` <- `"local"`
- `name` <- `$USER` environment variable or `"local"`
- `email` <- `null`

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
