# Waggle — Turso Provider

This file contains all Turso-specific implementation details for waggle.
Load this file when the active provider is **turso**.

## Config Retrieval

When `detecting-provider` requests config retrieval for the Turso provider:

1. Read `~/.waggle/config.json`
2. Parse and set the following as the `headless_config` session variable:
   - `tursoUrl` (required) — Turso database HTTP URL
   - `tursoAuthToken` (required) — Turso auth token
   - `teamsDatabaseExists` (optional)
   - `sprintsDatabaseExists` (optional)
   - `maxConcurrentAgents` (optional — default: 3)
3. Set environment variables for scripts:
   ```bash
   export TURSO_URL="<tursoUrl>"
   export TURSO_AUTH_TOKEN="<tursoAuthToken>"
   ```

If `~/.waggle/config.json` is not found or missing Turso fields, instruct the user to run the **setting-up-tasks** skill.

## Schema Validation

After loading config, verify tables exist:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/providers/turso/scripts/turso-exec.sh \
  "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;"
```

Expected tables: `intake_log`, `sprints`, `task_dependencies`, `tasks`, `teams`.

If any table is missing, run init:
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/providers/turso/scripts/init-db.sh
```

## CRUD Operations

### Create Task

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/providers/turso/scripts/turso-exec.sh \
  "INSERT INTO tasks (title, description, acceptance_criteria, status, priority, executor, requires_review, execution_plan, working_directory, assignees) VALUES ('<title>', '<description>', '<criteria>', '<status>', '<priority>', '<executor>', <0|1>, '<plan>', '<dir>', '<assignees_json>') RETURNING id;"
```

**IMPORTANT:** Escape single quotes in values by doubling them: `'` → `''`.

### Update Task

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/providers/turso/scripts/turso-exec.sh \
  "UPDATE tasks SET <field> = '<value>', updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = '<task_id>';"
```

### Get Task

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/providers/turso/scripts/turso-exec.sh \
  "SELECT t.*, GROUP_CONCAT(td.blocked_by_id) as blocked_by_ids FROM tasks t LEFT JOIN task_dependencies td ON t.id = td.task_id WHERE t.id = '<task_id>' GROUP BY t.id;"
```

### Delete Task

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/providers/turso/scripts/turso-exec.sh \
  "DELETE FROM tasks WHERE id = '<task_id>';"
```

### Manage Dependencies (Blocked By)

Same SQL as SQLite, executed via turso-exec.sh.

## Querying Tasks

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/providers/turso/scripts/query-tasks.sh \
  '<where_clause>' '<order_clause>'
```

Filter recipes and post-processing are identical to the SQLite provider. See SQLite SKILL.md for examples.

Note: Turso query-tasks.sh does NOT take a db_path argument (connection info comes from env vars).

## Task Record Reference

- **Task ID**: the hex string ID from the `id` column
- **Update instruction**: "Run: `bash ${CLAUDE_PLUGIN_ROOT}/skills/providers/turso/scripts/turso-exec.sh \"UPDATE tasks SET agent_output = '<result>', status = 'Done', updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = '<task_id>';\"`"

## Pushing Data to View Server

Same pattern as SQLite provider, using `turso/scripts/query-tasks.sh` (no db_path arg):

```bash
TASKS_JSON=$(bash ${CLAUDE_PLUGIN_ROOT}/skills/providers/turso/scripts/query-tasks.sh | jq -c '{tasks: [.results[] | {
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

## Identity

Same as SQLite provider — local identity based on `$USER` env var. Teams and org members from the teams table if populated.
