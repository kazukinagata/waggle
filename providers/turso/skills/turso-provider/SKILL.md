---
name: turso-provider
description: Turso-specific implementation for waggle. Loaded by detecting-provider when active_provider is turso.
user-invocable: false
---

# Waggle — Turso Provider

This file contains all Turso-specific implementation details for waggle.
Load this file when the active provider is **turso**.

## Config Retrieval

When `detecting-provider` requests config retrieval for the Turso provider:

1. **Cowork check**: If `execution_environment = "cowork"`, stop with error:
   > "Turso provider on Cowork requires a Desktop Extension for credential management, which is not yet available. Use the Notion provider for Cowork environments."

2. Read environment variables `TURSO_URL` and `TURSO_AUTH_TOKEN`.
   - If either is missing, instruct the user to set them in `~/.claude/settings.json` under the `env` field, then run the **setting-up-tasks** skill. Stop.

3. Set the following as the `headless_config` session variable:
   - `tursoUrl` — value of `TURSO_URL`
   - `tursoAuthToken` — value of `TURSO_AUTH_TOKEN`
   - `teamsDatabaseExists` (optional)
   - `sprintsDatabaseExists` (optional)

## Schema Validation

After loading config, verify tables exist:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/turso-provider/scripts/turso-exec.sh \
  "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;"
```

Expected tables: `intake_log`, `sprints`, `task_dependencies`, `tasks`, `teams`.

If any table is missing, run init:
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/turso-provider/scripts/init-db.sh
```

## CRUD Operations

### Create Task

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/turso-provider/scripts/turso-exec.sh \
  "INSERT INTO tasks (title, description, acceptance_criteria, status, priority, executor, requires_review, execution_plan, working_directory, assignees) VALUES ('<title>', '<description>', '<criteria>', '<status>', '<priority>', '<executor>', <0|1>, '<plan>', '<dir>', '<assignees_json>') RETURNING id;"
```

**IMPORTANT:** Escape single quotes in values by doubling them: `'` → `''`.

### Update Task

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/turso-provider/scripts/turso-exec.sh \
  "UPDATE tasks SET <field> = '<value>', updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = '<task_id>';"
```

### Get Task

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/turso-provider/scripts/turso-exec.sh \
  "SELECT t.*, GROUP_CONCAT(td.blocked_by_id) as blocked_by_ids FROM tasks t LEFT JOIN task_dependencies td ON t.id = td.task_id WHERE t.id = '<task_id>' GROUP BY t.id;"
```

### Delete Task

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/turso-provider/scripts/turso-exec.sh \
  "DELETE FROM tasks WHERE id = '<task_id>';"
```

### Manage Dependencies (Blocked By)

Add dependency:
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/turso-provider/scripts/turso-exec.sh \
  "INSERT OR IGNORE INTO task_dependencies (task_id, blocked_by_id) VALUES ('<task_id>', '<blocker_id>');"
```

Remove dependency:
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/turso-provider/scripts/turso-exec.sh \
  "DELETE FROM task_dependencies WHERE task_id = '<task_id>' AND blocked_by_id = '<blocker_id>';"
```

## Querying Tasks

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/turso-provider/scripts/query-tasks.sh \
  '<where_clause>' '<order_clause>'
```

Note: Turso query-tasks.sh does NOT take a db_path argument (connection info comes from env vars).

### Filter Recipes

**All tasks (no filter):**
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/turso-provider/scripts/query-tasks.sh
```

**Ready tasks:**
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/turso-provider/scripts/query-tasks.sh "t.status = 'Ready'"
```

**Tasks by executor and status (single executor):**
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/turso-provider/scripts/query-tasks.sh "t.status = 'Ready' AND t.executor = 'cowork'"
```

**Tasks by executor and status (multiple executors — for cli/claude-desktop environments):**
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/turso-provider/scripts/query-tasks.sh "t.status = 'Ready' AND t.executor IN ('cli','claude-desktop','cowork')"
```

**Tasks assigned to current user:**
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/turso-provider/scripts/query-tasks.sh "t.assignees LIKE '%<user_id>%'"
```

**In Progress tasks (for concurrency check):**
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/turso-provider/scripts/query-tasks.sh "t.status = 'In Progress' AND t.assignees LIKE '%<user_id>%'"
```

**Sort by Priority then Due Date:**
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/turso-provider/scripts/query-tasks.sh "" \
  "CASE t.priority WHEN 'Urgent' THEN 1 WHEN 'High' THEN 2 WHEN 'Medium' THEN 3 WHEN 'Low' THEN 4 END ASC, t.due_date ASC"
```

#### Hierarchy Queries

**Subtasks of a parent:**
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/turso-provider/scripts/query-tasks.sh "t.parent_task_id = '<parent_task_id>'"
```

**Check if a task has children:**
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/turso-provider/scripts/query-tasks.sh "t.parent_task_id = '<task_id>'" | jq '.results | length'
```

**Check if a candidate parent is itself a subtask:**
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/turso-provider/scripts/query-tasks.sh "t.id = '<candidate_parent_id>'" | jq '.results[0].parent_task_id'
```
If the result is non-null, the candidate is already a subtask and cannot be used as a parent (2-level limit).

### Post-Processing

- **Blocked By resolved**: Check that the `blocked_by` array is empty OR query each blocked_by task and confirm all have status = 'Done'.
- **Sort** (if not done in query): Priority — Urgent > High > Medium > Low; then by Due Date (earliest first).

## Task Record Reference

- **Task ID**: the hex string ID from the `id` column
- **Update instruction**: "Run: `bash ${CLAUDE_PLUGIN_ROOT}/skills/turso-provider/scripts/turso-exec.sh \"UPDATE tasks SET agent_output = '<result>', status = 'Done', updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = '<task_id>';\"`"

## On Completion Template

The following template is injected into dispatch prompts by `executing-tasks`. Placeholders are resolved at dispatch time. `<absolute_path_to_turso_exec_sh>` is resolved to the absolute path of `${CLAUDE_PLUGIN_ROOT}/skills/turso-provider/scripts/turso-exec.sh` at dispatch generation time.

```
Task ID: <task_id>
Turso exec script: <absolute_path_to_turso_exec_sh>

On completion:
1. Run: bash "<absolute_path_to_turso_exec_sh>" "UPDATE tasks SET agent_output='<result>', status='Done', updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id='<task_id>';"
   - If Requires Review = ON: set status to 'In Review' instead of 'Done'
2. On error: bash "<absolute_path_to_turso_exec_sh>" "UPDATE tasks SET error_message='<error>', status='Blocked', updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id='<task_id>';"
```

## Pushing Data to View Server

```bash
TASKS_JSON=$(bash ${CLAUDE_PLUGIN_ROOT}/skills/turso-provider/scripts/query-tasks.sh | jq -c '{tasks: [.results[] | {
  id, title, description, acceptanceCriteria: .acceptance_criteria, status, blockedBy: .blocked_by,
  priority, executor, requiresReview: .requires_review, executionPlan: .execution_plan,
  workingDirectory: .working_directory, sessionReference: .session_reference,
  dispatchedAt: .dispatched_at, agentOutput: .agent_output, errorMessage: .error_message,
  context, artifacts, repository, dueDate: .due_date, tags, parentTaskId: .parent_task_id,
  project, team, assignees, issuer, url: "", sprintId: .sprint_id, sprintName: null,
  complexityScore: .complexity_score, backlogOrder: .backlog_order
}], updatedAt: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))}')

curl -s http://localhost:3456/api/health -o /dev/null 2>/dev/null && \
  curl -s -X POST http://localhost:3456/api/data \
    -H "Content-Type: application/json" -d "$TASKS_JSON" -o /dev/null 2>/dev/null || true
```

### View Server Field Mapping

| Turso Column | TasksResponse Field |
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
| issuer | `issuer` |
| (empty string) | `url` |
| sprint_id | `sprintId` |
| complexity_score | `complexityScore` |
| backlog_order | `backlogOrder` |

## Identity: Resolve Current User

Turso is remote but has no user system. Set:
- `id` ← `"local"`
- `name` ← `$USER` environment variable or `"local"`
- `email` ← `null`

## Identity: Resolve Team Membership

If teams table has rows:
1. Query: `bash ${CLAUDE_PLUGIN_ROOT}/skills/turso-provider/scripts/turso-exec.sh "SELECT * FROM teams;"`
2. Parse members JSON array for each team
3. Match by name (case-insensitive) against `current_user.name`
4. Set `current_user.teams` and `current_team` per the same logic as other providers

## Identity: List Org Members

Return members from teams table if available, otherwise `org_members: []`.

## Error Handling

| Error Category | Condition | Action |
|---|---|---|
| Connection timeout | HTTP timeout or network error | Retryable — wait 2 seconds, max 3 attempts |
| Auth failure | 401 Unauthorized | Terminal — instruct user to check `tursoAuthToken` in config |
| SQL error | 400 Bad Request with SQL syntax error | Terminal — report the malformed query to user |
