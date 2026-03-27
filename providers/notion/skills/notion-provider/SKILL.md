---
name: notion-provider
description: Notion-specific provider implementation for waggle. Loaded when the active provider is notion.
user-invocable: false
---

# Waggle — Notion Provider

This file contains all Notion-specific implementation details for waggle.
Load this file when the active provider is **notion**.

## Config Retrieval

When `detecting-provider` requests config retrieval for the Notion provider, follow these steps to populate `headless_config`:

1. **Local config file** (fastest path): Read `~/.waggle/config.json` via Bash: `cat ~/.waggle/config.json 2>/dev/null`
   - If the file exists and contains `tasksDatabaseId`, use those values to populate `headless_config` and skip to Schema Validation.

2. **Waggle Config page**: Search for the "Waggle Config" page using `notion-search`:
   - If multiple pages match:
     - Filter out trashed/archived pages
     - Prefer the page that is a child of the same parent as the Tasks database
     - If still ambiguous, ask the user which Config page to use
   - Retrieve the page body using `notion-fetch`
   - Parse the JSON code block and set the following as the `headless_config` session variable:
     - `tasksDatabaseId` (required)
     - `teamsDatabaseId` (optional)
     - `sprintsDatabaseId` (optional — exists after setting-up-scrum)
     - `intakeLogDatabaseId` (optional — exists after first ingesting-messages run)

3. **Legacy fallback**: If no "Waggle Config" page is found, search for "Agentic Tasks Config" using `notion-search`:
   - If found, use it as the Config page (do not rename it). Follow the same parsing logic as step 2.

> **Note:** `maxConcurrentAgents` may exist in legacy config files but is no longer used. Ignore it if present.

If no source provides the config, instruct the user to run the setting-up-tasks skill, then stop.

## Schema Validation

After loading config, verify Core fields by calling `notion-fetch` with `tasksDatabaseId` and inspecting the returned schema's `properties` object.

Required Core fields (15): `Title`, `Description`, `Acceptance Criteria`, `Status`, `Blocked By`, `Priority`, `Executor`, `Requires Review`, `Execution Plan`, `Working Directory`, `Session Reference`, `Dispatched At`, `Agent Output`, `Error Message`, `Issuer`.

### Auto-Repair (Missing Fields)

If any Core field is missing, automatically repair using `notion-update-data-source`.
First obtain the data source ID via `notion-fetch` on the database URL.
Then run the appropriate DDL (one `ADD COLUMN` per call):

| Missing Field | Repair DDL |
|---|---|
| Status | `ADD COLUMN "Status" SELECT('Backlog':gray, 'Ready':blue, 'In Progress':yellow, 'In Review':orange, 'Done':green, 'Blocked':red)` |
| Priority | `ADD COLUMN "Priority" SELECT('Urgent':red, 'High':orange, 'Medium':yellow, 'Low':blue)` |
| Executor | `ADD COLUMN "Executor" SELECT('cli':purple, 'claude-desktop':green, 'cowork':blue, 'human':gray)` |
| Dispatched At / Due Date | `ADD COLUMN "<field>" DATE` |
| Issuer | `ADD COLUMN "Issuer" PERSON` |
| (other text fields) | `ADD COLUMN "<field>" RICH_TEXT` |

After repair, re-verify and continue. **Never ask the user to manually fix the schema.**

## MCP Tool Reference

- `notion-create-pages` — Create a task (parent: `{ "data_source_id": TASKS_DS_ID }`)
- `notion-update-page` — Update task properties
- `notion-fetch` — Get a database, data source, or single task by URL/ID
- `notion-search` — Full-text search across tasks; use for filtering by field value
- `notion-get-comments` / `notion-create-comment` — Read/write task comments

## Delete Operation

Notion does not support hard delete via the API. To delete a task, archive the page:

```
notion-update-page page_id="<page_id>" archived=true
```

This removes the page from views but retains it in Notion's trash (recoverable for 30 days).

## Schema: Notion Property -> Canonical Role

### Core Fields (15 required — verify existence at session start)

| Property | Notion Type | Canonical Role | Notes |
|---|---|---|---|
| Title | title | `task_title` | Task name |
| Description | rich_text | `task_description` | Orchestrator-written detail |
| Acceptance Criteria | rich_text | `task_acceptance_criteria` | Verifiable completion conditions |
| Status | select | `task_status` | Backlog / Ready / In Progress / In Review / Done / Blocked |
| Blocked By | relation | `task_blocked_by` | Self-relation (dependency). Empty or all blockers Done = actionable |
| Priority | select | `task_priority` | Urgent / High / Medium / Low |
| Executor | select | `task_executor` | cli / claude-desktop / cowork / human |
| Requires Review | checkbox | `task_requires_review` | On -> must pass In Review. Off -> can go directly to Done |
| Execution Plan | rich_text | `task_execution_plan` | Orchestrator's plan written before dispatch. write-once |
| Working Directory | rich_text | `task_working_directory` | Absolute path to the working directory |
| Session Reference | rich_text | `task_session_ref` | Written after dispatch: tmux session name / Scheduled task ID |
| Dispatched At | date | `task_dispatched_at` | Dispatch timestamp. Used for timeout detection |
| Agent Output | rich_text | `task_agent_output` | Execution result |
| Error Message | rich_text | `task_error_message` | Written on failure only. Query with "Error Message is not empty" |
| Issuer | people | `task_issuer` | Who created/initiated this task. Auto-populated with current_user. Write-once. |

### Extended Fields (optional — graceful degradation if absent)

| Property | Notion Type | Canonical Role | Notes |
|---|---|---|---|
| Context | rich_text | `task_context` | Background info, constraints |
| Artifacts | rich_text | `task_artifacts` | PR URLs, file paths (newline-separated) |
| Repository | url | `task_repository` | GitHub repository URL |
| Due Date | date | `task_due_date` | ISO format |
| Tags | multi_select | `task_tags` | Free tags |
| Parent Task | relation | `task_parent` | Self-relation (hierarchy) |
| Assignees | people | `task_assignees` | Human executor assignment |
| Branch | rich_text | `task_branch` | Git branch name (e.g. feature/task-slug). Leave blank to work on the current branch |
| Source Message ID | rich_text | `task_source_message_id` | Messaging tool message unique ID (e.g. Slack `channel_id:ts`). Used for cross-member dedup |
| Acknowledged At | date | `task_acknowledged_at` | Auto-set when assignee sees the task. Reset on delegation. |

### Auto-Repair DDL for Extended Fields

If `Source Message ID` is missing and needed, repair with:
```
ADD COLUMN "Source Message ID" RICH_TEXT
```

If `Acknowledged At` is missing and needed, repair with:
```
ADD COLUMN "Acknowledged At" DATE
```

## Intake Log Database

The Intake Log DB tracks processed message IDs to avoid reprocessing. It is created automatically by the ingesting-messages skill on first run.

| Property | Notion Type | Required | Description |
|---|---|---|---|
| Message ID | title | Yes | Message unique ID (e.g. Slack: `channel_id:ts`) |
| Tool Name | select | Yes | Options: `slack` / `teams` / `discord` |
| Processed At | date | Yes | Processing timestamp (ISO 8601) |

The database ID is stored in the config page as `intakeLogDatabaseId`.

## Querying Tasks

Use the first available query path. The detection order depends on `execution_environment`:

### Query Path Detection

**CLI (`execution_environment = "cli"`):**
1. `NOTION_TOKEN` env var set (check: `[ -n "$NOTION_TOKEN" ] && echo "SET" || echo "NOT SET"`) → Path 1 (API script)
2. Otherwise → Path 2 (MCP fallback)

**Claude Desktop (`execution_environment = "claude-desktop"`):**
1. `NOTION_TOKEN` env var set → Path 1 (API script)
2. `mcp__notion-query__notion-query` tool available → Path 1b (Desktop Extension)
3. Otherwise → Path 2 (MCP fallback)

**Cowork (`execution_environment = "cowork"`):**
1. `mcp__notion-query__notion-query` tool available → Path 1b (Desktop Extension, preferred)
2. Otherwise → Path 2 (MCP fallback)

### Path 1: Notion API Script (requires NOTION_TOKEN)

Call the query script for server-side filtering:

```bash
bash ${PROVIDER_PLUGIN_ROOT}/skills/notion-provider/scripts/query-tasks.sh \
  "<tasksDatabaseId>" '<filter_json>' '<sort_json>'
```

The script returns `{"results": [...]}` with full page objects including all properties.

#### Filter Recipes

**Tasks assigned to a user:**
```json
{"property":"Assignees","people":{"contains":"<user_id>"}}
```

**Ready tasks assigned to a user:**
```json
{"and":[{"property":"Status","select":{"equals":"Ready"}},{"property":"Assignees","people":{"contains":"<user_id>"}}]}
```

**In Progress tasks (for concurrency check):**
```json
{"and":[{"property":"Status","select":{"equals":"In Progress"}},{"property":"Assignees","people":{"contains":"<user_id>"}}]}
```

**Ready tasks by executor and assignee (single executor):**
```json
{"and":[{"property":"Status","select":{"equals":"Ready"}},{"property":"Executor","select":{"equals":"cowork"}},{"property":"Assignees","people":{"contains":"<user_id>"}}]}
```

**Ready tasks by executor and assignee (multiple executors — for cli/claude-desktop environments):**
```json
{"and":[{"property":"Status","select":{"equals":"Ready"}},{"or":[{"property":"Executor","select":{"equals":"cli"}},{"property":"Executor","select":{"equals":"claude-desktop"}},{"property":"Executor","select":{"equals":"cowork"}}]},{"property":"Assignees","people":{"contains":"<user_id>"}}]}
```

**Sort by Priority then Due Date:**
```json
[{"property":"Priority","direction":"ascending"},{"property":"Due Date","direction":"ascending"}]
```

**Blocked tasks owned by user (via Assignees OR Issuer fallback):**
```json
{"and":[{"property":"Status","select":{"equals":"Blocked"}},{"or":[{"property":"Assignees","people":{"contains":"<user_id>"}},{"and":[{"property":"Issuer","people":{"contains":"<user_id>"}},{"property":"Assignees","people":{"is_empty":true}}]}]}]}
```

**Ready human tasks owned by user (via Assignees OR Issuer fallback):**
```json
{"and":[{"property":"Status","select":{"equals":"Ready"}},{"property":"Executor","select":{"equals":"human"}},{"or":[{"property":"Assignees","people":{"contains":"<user_id>"}},{"and":[{"property":"Issuer","people":{"contains":"<user_id>"}},{"property":"Assignees","people":{"is_empty":true}}]}]}]}
```

#### Hierarchy Queries

**Subtasks of a parent task:**
```json
{"property":"Parent Task","relation":{"contains":"<parent_task_id>"}}
```

**Check if a task is a parent (has children):** Query with the subtasks filter above. If results are non-empty, the task has children.

**Check if a candidate parent is itself a subtask:** Fetch the candidate parent with `notion-fetch` and check if its `Parent Task` relation is empty. If non-empty, it is already a subtask and cannot be used as a parent (2-level limit).

### Path 1b: Desktop Extension (notion-query MCP tool)

Available when the `mcp__notion-query__notion-query` tool is present. Primary query path in cowork environments.

Call `mcp__notion-query__notion-query` with:
- `database_id`: the `tasksDatabaseId`
- `filter`: filter JSON (same format as Path 1 filter recipes above)
- `sorts`: sort JSON

Returns `{"results": [...]}` in the same Notion API format as Path 1.

### Path 2: MCP Fallback (no token)

Use `notion-search` with `data_source_url` to find task pages, then `notion-fetch` each page individually to get properties. Filter client-side by checking property values.

This is the slower path — use only when Path 1 is unavailable.

### Post-Processing (all paths)

- **Blocked By resolved**: Check that the `Blocked By` relation array is empty OR fetch each referenced task's Status and confirm all are "Done". This cannot be filtered server-side.
- **Sort** (if not done server-side): Priority — Urgent > High > Medium > Low; then by Due Date (earliest first).

### Displaying Task Lists

When displaying queried tasks to the user in list or table format, extract only display-relevant fields to prevent output truncation:

```bash
bash ${PROVIDER_PLUGIN_ROOT}/skills/notion-provider/scripts/query-tasks.sh \
  "<tasksDatabaseId>" '<filter_json>' '<sort_json>' | \
  jq '[.results[] | {
    id: .id,
    title: (.properties.Title.title[0].plain_text // ""),
    status: (.properties.Status.select.name // ""),
    priority: (.properties.Priority.select.name // ""),
    executor: (.properties.Executor.select.name // ""),
    assignees: ([.properties.Assignees.people[]?.name] | join(", ")),
    due_date: (.properties["Due Date"].date.start // ""),
    blocked_by: (([.properties["Blocked By"].relation[]?.id] | length | tostring) + " deps")
  }]'
```

For single-task detail views (update, status change), use the full page object.

### Fetch All Tasks

To retrieve all tasks (e.g. for view server data push), use the detected query path with no filter:

- **Path 1**: `bash ${PROVIDER_PLUGIN_ROOT}/skills/notion-provider/scripts/query-tasks.sh "<tasksDatabaseId>"` (no filter/sort args)
- **Path 2**: `notion-search` with `data_source_url` + `notion-fetch` per page

No post-processing needed (no Blocked By filter, no sort required).

## Task Record Reference

When referring to a task in dispatch prompts and completion instructions, use:
- **Task ID**: the Notion page ID (from the `id` field when the task was created)
- **Update instruction**: "Use `notion-update-page` with page ID `<Page ID>` to write results to Agent Output and update Status."

In the Claude Desktop environment, the dispatch prompt is set as the Scheduled Task's prompt.
Notion MCP tools (notion-update-page) are available in both environments.

## On Completion Template

The following template is injected into dispatch prompts by `executing-tasks`. Placeholders are resolved at dispatch time.

```
Notion page ID for this task: <task_id>

On completion, perform the following:
1. Use notion-update-page with page ID <task_id> to write execution results to the "Agent Output" field
2. Update Status:
   - If Requires Review = ON: "In Review"
   - If Requires Review = OFF: "Done"
3. On error: write error details to "Error Message" and update Status to "Blocked"
4. If the Notion update fails, ignore the error and complete execution
```

## Pushing Data to View Server

After any task operation (create, update, delete), push fresh data to the local view server:

1. Use **Fetch All Tasks** (above) to retrieve all tasks from the tasks database
2. Format the response as a `TasksResponse` JSON object:
   ```json
   { "tasks": [...], "updatedAt": "<ISO timestamp>" }
   ```
3. POST to `http://localhost:3456/api/data` with `Content-Type: application/json`

```bash
# Silently skip if server is not running
curl -s http://localhost:3456/api/health -o /dev/null 2>/dev/null && \
  curl -s -X POST http://localhost:3456/api/data \
    -H "Content-Type: application/json" -d '<json>' -o /dev/null 2>/dev/null || true
```

### View Server Field Mapping

| Notion Property | TasksResponse Field |
|---|---|
| `id` (page ID) | `id` |
| Title | `title` |
| Description | `description` |
| Acceptance Criteria | `acceptanceCriteria` |
| Status | `status` |
| Blocked By | `blockedBy` (array of page IDs) |
| Priority | `priority` |
| Executor | `executor` |
| Requires Review | `requiresReview` |
| Execution Plan | `executionPlan` |
| Working Directory | `workingDirectory` |
| Session Reference | `sessionReference` |
| Dispatched At | `dispatchedAt` |
| Agent Output | `agentOutput` |
| Error Message | `errorMessage` |
| Context | `context` |
| Artifacts | `artifacts` |
| Repository | `repository` |
| Due Date | `dueDate` |
| Tags | `tags` |
| Parent Task | `parentTaskId` |
| Assignees | `assignees` |
| Issuer | `issuer` |
| Acknowledged At | `acknowledgedAt` |
| `url` (page URL) | `url` |
| Sprint (relation) | `sprintId` / `sprintName` |
| (not in Notion) | `complexityScore`, `backlogOrder` |

---

## Identity: Resolve Current User

Called by `resolving-identity` shared skill when `active_provider = notion`.

1. Call `notion-get-users` with `user_id: "self"`.
2. Map the response:
   - `id` <- `response.id`
   - `name` <- `response.name`
   - `email` <- `response.person.email` (null if Bot user)
3. Save to session variable `current_user: { id, name, email }`.
4. **Fallback**: If `notion-get-users` is unavailable or fails:
   - `id` <- `"unknown"`
   - `name` <- `$USER` environment variable or "local"
   - `email` <- null

## Identity: Resolve Team Membership

Called by `resolving-identity` shared skill when `teamsDatabaseId` is present in config.

1. Call `notion-fetch` on `teamsDatabaseId` to retrieve all team pages.
2. For each team, inspect the `Members` people field. Check if `current_user.id` is present in the array.
3. Set `current_user.teams` to the list of matching teams: `[{ id, name, members: [{ id, name }] }]`.
4. Determine `current_team`:
   - 1 matching team -> automatically set `current_team` to that team.
   - 2+ matching teams -> use AskUserQuestion: "You belong to multiple teams: [list]. Which team are you working with now?"
   - 0 matching teams -> set `current_team: null`.
5. If `current_team` is set, populate `current_team.members` with all members from that team's `Members` field (array of `{ id, name }`). This is used by downstream skills for team-scoped filtering.

## Identity: List Org Members

Called by `resolving-identity` shared skill when `org_members` lookup is needed.

1. Call `notion-get-users` with no arguments to list all workspace members.
2. Map each user to `OrgMember { id, name, email }`:
   - `id` <- `user.id`
   - `name` <- `user.name`
   - `email` <- `user.person.email` (null for Bot users)
3. Save to session variable `org_members: OrgMember[]`.
4. **Fallback**: If `notion-get-users` is unavailable, set `org_members: []` and return.
   The `looking-up-members` skill will then fall back to TeamsDB Members field.

## Identity: Self-Task Detection

To determine whether a task is assigned to the current user:

- Fetch the task's `Assignees` property (people type — returns an array of person objects).
- Check if any element in the array has `id === current_user.id`.
- Use this check when filtering tasks in `managing-tasks` and `executing-tasks`.

## Error Handling

| Error Category | HTTP Code | Action |
|---|---|---|
| Rate limit | 429 | Retryable — wait for `Retry-After` header seconds, then retry |
| Page not found | 404 | Terminal — the page was deleted or the integration lost access. Report to user |
| Server error | 500 | Retryable — exponential backoff (1s, 2s, 4s), max 3 attempts |
| MCP tool unavailable | N/A | Terminal — the Notion MCP server is not configured. Instruct user to check MCP settings |
