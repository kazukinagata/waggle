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

### Step 1: Cache fast path (environment-aware)

Check the cache for resolved DB IDs before searching Notion. The cache mechanism differs by `execution_environment`:

- **`cli` / `claude-desktop`**: read env vars from the running shell. The full set of cached IDs is:

  | env var | `headless_config` field | required |
  |---|---|---|
  | `WAGGLE_NOTION_TASKS_DB_ID` | `tasksDatabaseId` | yes |
  | `WAGGLE_NOTION_TEAMS_DB_ID` | `teamsDatabaseId` | optional |
  | `WAGGLE_NOTION_INTAKE_LOG_DB_ID` | `intakeLogDatabaseId` | optional |
  | `WAGGLE_NOTION_SPRINTS_DB_ID` | `sprintsDatabaseId` | optional |
  | `WAGGLE_NOTION_ACTIVE_THREADS_DB_ID` | `activeThreadsDatabaseId` | optional |

  Read every env var that is set and copy it into the corresponding `headless_config` field.

- **`cowork`**: scan the active system prompt / available context for a block of the form:
  ```
  <waggle-config>
  {
    "tasksDatabaseId": "...",
    "teamsDatabaseId": "...",
    "intakeLogDatabaseId": "...",
    "sprintsDatabaseId": "...",
    "activeThreadsDatabaseId": "..."
  }
  </waggle-config>
  ```
  If present and parseable as JSON, copy each key into the corresponding `headless_config` field (same mapping as the table above; keys not present in the JSON remain unset). The Cowork JSON shape is the source of truth — a user who pastes only `tasksDatabaseId` and `teamsDatabaseId` gets a fast path with `intakeLogDatabaseId` etc. left unset, identical to the CLI / Desktop case where only those env vars are exported.

If the cache provides at least `tasksDatabaseId`, populate `headless_config` and skip to Schema Validation. Otherwise continue to Step 2. (Optional IDs missing from the cache do **not** force a fallback — Step 2 only runs when `tasksDatabaseId` itself is absent. Downstream skills that need an unset optional ID must fetch the Config page on demand at that point.)

### Step 2: Resolve via "Waggle Config" page (cache miss path)

Call `notion-search` with query `"Waggle Config"`. The MCP tool performs a partial-match / semantic search, so apply this **client-side filter** to the results before doing anything else:

```
keep only results where:
  result.title == "Waggle Config"   (exact, case-sensitive)
  AND result.type == "page"
  AND result is not trashed/archived
```

Discard everything else. In particular, member-scoped databases such as `Waggle:Hori`, `Waggle:Funase`, parent pages like `メンバー別：Waggle`, or any other partial-match hit MUST be dropped — they are never the Config page.

After filtering:

- **0 results**: no Config page exists. Instruct the user to run the `setting-up-tasks` skill, then stop. (There is no legacy fallback — the `Agentic Tasks Config` legacy name was removed in 2.6.0.)
- **1 result**: this is the Config page. Proceed.
- **2+ results**: a workspace has multiple `Waggle Config` pages. Use `AskUserQuestion` to ask the user which one to adopt.

`notion-fetch` the chosen page ID, parse the JSON code block, and populate `headless_config` with:

- `tasksDatabaseId` (required)
- `teamsDatabaseId` (optional)
- `sprintsDatabaseId` (optional — exists after setting-up-scrum)
- `intakeLogDatabaseId` (optional — exists after first ingesting-messages run)
- `activeThreadsDatabaseId` (optional — exists after first ingesting-messages run that registers a thread)

### Step 3: Cache populate (after Step 2 succeeds)

Persist the resolved IDs so the next session hits the fast path instead of running search again. Behavior differs by `execution_environment`:

- **`cli` / `claude-desktop`**: auto-write to `~/.claude/settings.json`.
  - Read the existing file (create with `{}` if missing), preserve all other keys, and merge each resolved ID into the `env` field using the table from Step 1:
    - `WAGGLE_NOTION_TASKS_DB_ID` ← `tasksDatabaseId`
    - `WAGGLE_NOTION_TEAMS_DB_ID` ← `teamsDatabaseId` (only if present in `headless_config`)
    - `WAGGLE_NOTION_INTAKE_LOG_DB_ID` ← `intakeLogDatabaseId` (only if present)
    - `WAGGLE_NOTION_SPRINTS_DB_ID` ← `sprintsDatabaseId` (only if present)
    - `WAGGLE_NOTION_ACTIVE_THREADS_DB_ID` ← `activeThreadsDatabaseId` (only if present)
  - If a key is already set to the resolved value, no-op. If the existing value differs, overwrite (the searched-and-fetched value is authoritative — the previous cache was stale).
  - This is silent (no user prompt) — env-var caching is non-intrusive.

- **`cowork`**: use `AskUserQuestion` **at most once per session** to ask the user whether to cache:
  > "Would you like to cache these Notion DB IDs in your Cowork Global Instructions so future sessions skip the Notion search? Paste the block below into Global Instructions if Yes."
  >
  > Options: `Yes — show paste block` / `Later`
  >
  > If `Yes`: display
  > ```
  > <waggle-config>
  > { ...JSON with all resolved IDs... }
  > </waggle-config>
  > ```
  > If `Later`: set a session-local flag `cowork_cache_prompt_dismissed = true` and do not ask again this session. The next session will ask again until the user pastes the block (and the block is found in Step 1).

### Recovery from stale cache

If Step 1 returns a cached `tasksDatabaseId` but Schema Validation (next section) fails with a `404` "Could not find database with ID" error from Notion, treat the cache as stale: discard all cached IDs in `headless_config`, fall through to Step 2 (search), and re-populate the cache via Step 3 with the freshly-resolved IDs.

**Precedence over the Error Handling table**: this recovery path takes precedence over the `Database access denied → Terminal` row in the Error Handling table at the bottom of this file. Do **not** halt the current step when the failure originates from a Step 1 cached value — the same 404 signal is non-terminal in that specific context because the search-based fallback may resolve a fresh ID. The Error Handling table's terminal classification continues to apply for every other origin (e.g. a query against a task ID, a relation update, a Schema Validation failure during normal Step 2 operation).

**Second failure is terminal**: if Schema Validation **still** fails with the same 404 after Step 2 resolves a fresh ID — meaning the Config page itself contains a stale ID (e.g. the Tasks DB was deleted in Notion but the Config page was not updated) — treat it as terminal at that point. Surface the error verbatim, and instruct the user either to update the Config page's `tasksDatabaseId` to point at the current Tasks DB, or to re-run `setting-up-tasks` to recreate the DB and rewrite the Config page.

> **Note:** `maxConcurrentAgents` may exist in legacy config files but is no longer used. Ignore it if present.

## Schema Validation

After loading config, verify Core fields by calling `notion-fetch` with `tasksDatabaseId` and inspecting the returned schema's `properties` object.

Required Core fields (16): `Title`, `Description`, `Acceptance Criteria`, `Status`, `Blocked By`, `Priority`, `Executor`, `Requires Review`, `Execution Plan`, `Working Directory`, `Session Reference`, `Dispatched At`, `Agent Output`, `Error Message`, `Issuer`, `Quality Verdict` (added in v2.8.0 for the quality gate cache; see waggle-protocol § Quality Spec).

### Auto-Repair (Missing Fields)

If any Core field is missing, automatically repair using `notion-update-data-source`.
First obtain the data source ID via `notion-fetch` on the database URL.
Then run the appropriate DDL (one `ADD COLUMN` per call):

| Missing Field | Repair DDL |
|---|---|
| Status | `ADD COLUMN "Status" SELECT('Backlog':gray, 'Ready':blue, 'In Progress':yellow, 'In Review':orange, 'Done':green, 'Blocked':red, 'Cancelled':purple)` |
| Priority | `ADD COLUMN "Priority" SELECT('Urgent':red, 'High':orange, 'Medium':yellow, 'Low':blue)` |
| Executor | `ADD COLUMN "Executor" SELECT('cli':purple, 'claude-desktop':green, 'cowork':blue, 'human':gray)` |
| Dispatched At / Due Date | `ADD COLUMN "<field>" DATE` |
| Issuer | `ADD COLUMN "Issuer" CREATED_BY` (v2.8.1+; was `PERSON` in earlier versions. See "Migration Guide: v2.7.x → v2.8.1" below if upgrading an existing DB.) |
| Quality Verdict | `ADD COLUMN "Quality Verdict" RICH_TEXT` |
| (other text fields) | `ADD COLUMN "<field>" RICH_TEXT` |

After repair, re-verify and continue. **Never ask the user to manually fix the schema.**

The `Quality Verdict` column stores the v2.8.0 Reviewer verdict cache. It is populated automatically by the `reviewing-quality` skill — users do not edit it directly. Format: `<verdict> hash=<8hex> @<iso8601> v1 [suppressed-until=<iso8601>]`. See `skills/reviewing-quality/references/cache-format.md`.

## Migration Guide: v2.7.x → v2.8.1 (Issuer column type change)

In v2.8.1 the Issuer column type changes from `PERSON` (a writable people property) to `CREATED_BY` (a read-only built-in property auto-populated by Notion with the API token's owning user). Auto-repair handles fresh databases automatically, but a database already initialized under v2.7.x has the old `PERSON`-typed column and the auto-repair check will see Issuer as present-but-wrong-type. It will NOT replace the column on its own — the change is destructive (existing Issuer values are lost) and so the user must run it manually.

### Why this change

Under the old design, every skill flow had to set `Issuer = current_user` explicitly. Empirically ~27% of tasks ended up with empty Issuer because the flows had multiple ways to drop the field — third-party automations posting directly to Notion, intake flows omitting Issuer in the payload, scheduled tasks where `current_user` could not be resolved. Switching to `created_by` lets Notion enforce auto-population at the data store level, eliminating all of those paths in one step.

### Trade-offs to acknowledge before migrating

- **Existing Issuer values are lost.** Notion does not support converting a `PERSON` column to `CREATED_BY` in place. The migration drops the old column and adds a fresh `CREATED_BY` column. Notion then back-fills the new column on every existing row using each row's stored `created_by` metadata — so Issuer will be 100% populated immediately after migration, but the values reflect the **actual creator** of each page, not any deliberate "issuer override" that may have been written into the old column.
- **Single-issuer model.** `CREATED_BY` returns one user, not an array. If your prior workflow relied on multi-issuer tasks, that capability is gone.
- **No more proxy/override.** If a teammate previously created tasks "on behalf of" someone else by writing the other person's user into Issuer, that override is lost; the actual creator's identity surfaces instead. The recommended replacement is to set `Assignee` to the intended owner and leave Issuer alone.

### Migration procedure

**Do these steps in order.** Skipping step 2 or running step 3 before step 2 will permanently destroy all existing Issuer values with no in-DB recovery path (only your step-1 backup file can restore them).

1. **Back up the current Issuer values.** Query the Tasks DB via the Notion API and dump `(page_id, page_url, title, properties.Issuer)` to a local JSON file. Keep this file outside the repo (or git-ignore it) — it contains user IDs from your workspace and serves as an audit trail of overrides that the new column type cannot represent.

2. **Add a `CREATED_BY`-typed verification column** while the old `PERSON`-typed `Issuer` column is still present. This must happen *before* step 3 — adding the verification column gives Notion an opportunity to back-fill it from each page's `created_by` metadata so you can confirm the new column type produces the expected values before dropping the old one.

   ```
   ADD COLUMN "Created By (verification)" CREATED_BY
   ```

   After this DDL, re-query a sample of pages and confirm that `Created By (verification)` is populated for every existing row. If it is not (for example, if your Notion workspace has rows created by deleted users), STOP here and decide whether to proceed — those rows will end up with empty Issuer after step 3.

3. **Drop the old `Issuer` column and rename the verification column into place.** Run as a single DDL transaction:

   ```
   DROP COLUMN "Issuer"; RENAME COLUMN "Created By (verification)" TO "Issuer"
   ```

   Doing this in two transactions (step 2 then step 3) rather than one big transaction avoids a window where the canonical `Issuer` name does not exist.

   If Notion appends `" 1"` to the renamed column (it does this when an internal trash entry for the original name still exists), run a second rename: `RENAME COLUMN "Issuer 1" TO "Issuer"`.

4. **Verify.** Re-query the database and confirm:
   - The `Issuer` property has `"type": "created_by"` in the schema.
   - All existing pages return a non-empty Issuer value (Notion back-fills from each page's `created_by` metadata).
   - The fill rate is 100%.

5. **Update your config.** No config changes are needed — `headless_config` does not reference Issuer's type.

If you need to revert, restore from your backup JSON manually (no rollback script is shipped).

## MCP Tool Reference

- `notion-create-pages` — Create a task (parent: `{ "data_source_id": TASKS_DS_ID }`)
- `notion-update-page` — Update task properties
- `notion-fetch` — Get a database, data source, or single task by URL/ID
- `notion-search` — Full-text/semantic search across pages by name (e.g. finding the Waggle Config page during bootstrap). NOT for filtered task queries — server-side property filters such as Assignee/Status are unsupported. Use the Querying Tasks flow instead.
- `notion-get-comments` / `notion-create-comment` — Read/write task comments

## Updating Relation Fields

`notion-update-page` properties only accept `string | number | null` — it cannot set relation fields (Blocked By, Parent Task, Sprint) which require arrays of `{id}` objects. Use the appropriate path below.

### Relation Update Path Detection

The available path depends on `execution_environment` because `NOTION_TOKEN` is exposed to the shell only in CLI; in Claude Desktop / Cowork the token is injected directly into MCP tool invocations and cannot drive a bash script.

**CLI (`execution_environment = "cli"`):**
1. `NOTION_TOKEN` env var available in shell (check: `[ -n "$NOTION_TOKEN" ] && echo "SET" || echo "NOT SET"`) → Path 1 (bash script)
2. Otherwise → warn the user (no fallback)

**Claude Desktop / Cowork (`execution_environment = "claude-desktop"` or `"cowork"`):**
1. `mcp__notion-extension__notion-update-relation` tool available → Path 2 (Desktop Extension)
2. Otherwise → warn the user (no fallback)

If no path is available, warn the user. The warning depends on environment:

- **CLI**: "Relation field updates require `NOTION_TOKEN` to be available in your shell environment. Set it in `~/.claude/settings.json` env block, or export it in your shell profile."
- **Claude Desktop / Cowork**: "Relation field updates require the `notion-extension` Desktop Extension. Install it via the plugin setup."

### Path 1: Bash Script (CLI, requires NOTION_TOKEN)

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/update-relations.sh \
  <page_id> <property_name> <mode> [page_id_1] [page_id_2] ...
```

- **mode `replace`**: Set the relation to exactly the provided IDs (zero IDs = clear)
- **mode `append`**: Merge with existing values (dedup)

#### Examples

**Set Blocked By to multiple tasks:**
```bash
bash ${CLAUDE_SKILL_DIR}/scripts/update-relations.sh \
  "<page_id>" "Blocked By" replace "<blocker_id_1>" "<blocker_id_2>"
```

**Append a blocker:**
```bash
bash ${CLAUDE_SKILL_DIR}/scripts/update-relations.sh \
  "<page_id>" "Blocked By" append "<new_blocker_id>"
```

**Set Parent Task (single value):**
```bash
bash ${CLAUDE_SKILL_DIR}/scripts/update-relations.sh \
  "<page_id>" "Parent Task" replace "<parent_id>"
```

**Clear a relation:**
```bash
bash ${CLAUDE_SKILL_DIR}/scripts/update-relations.sh \
  "<page_id>" "Blocked By" replace
```

### Path 2: Desktop Extension (notion-update-relation MCP tool, Claude Desktop / Cowork)

Available when the `mcp__notion-extension__notion-update-relation` tool is present.

Call `mcp__notion-extension__notion-update-relation` with:
- `page_id`: the Notion page UUID
- `property_name`: relation property name (e.g., `"Blocked By"`, `"Parent Task"`)
- `mode`: `"replace"` or `"append"`
- `relation_ids`: array of page IDs (omit or `[]` with replace to clear)

Returns a minimal confirmation echo: `{ok, page_id, property_name, mode, relation_ids}` where `relation_ids` is the post-update final state (the merged + deduplicated list for `append`). If you need other page fields after the update, re-fetch via `notion-fetch` or `notion-query`.

### When to use

Use the relation update path for **any** relation field update. For non-relation fields, continue using `notion-update-page`. A single task update that changes both relation and non-relation fields requires two calls.

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
| Status | select | `task_status` | Backlog / Ready / In Progress / In Review / Done / Blocked / Cancelled |
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
| Issuer | created_by | `task_issuer` | Who created/initiated this task. **Auto-populated by Notion on insert; read-only.** Do NOT pass Issuer in `notion-create-pages` properties — Notion will reject the write. v2.8.1+ (was `people` in v2.7.x). |

### Extended Fields (optional — graceful degradation if absent)

| Property | Notion Type | Canonical Role | Notes |
|---|---|---|---|
| Context | rich_text | `task_context` | Background info, constraints |
| Artifacts | rich_text | `task_artifacts` | PR URLs, file paths (newline-separated) |
| Repository | url | `task_repository` | GitHub repository URL |
| Due Date | date | `task_due_date` | ISO format |
| Tags | multi_select | `task_tags` | Free tags |
| Parent Task | relation | `task_parent` | Self-relation (hierarchy) |
| Assignee | people | `task_assignee` | Human executor assignment |
| Branch | rich_text | `task_branch` | Git branch name (e.g. feature/task-slug). Leave blank to work on the current branch |
| Source Message ID | rich_text | `task_source_message_id` | Messaging tool message unique ID (e.g. Slack `channel_id:ts`). Used for cross-member dedup |
| Acknowledged At | date | `task_acknowledged_at` | Auto-set when assignee sees the task. Reset on delegation. |
| Created At | created_time | `task_created_at` | Auto-populated by Notion on page creation. Read-only. |

### Auto-Repair DDL for Extended Fields

If `Source Message ID` is missing and needed, repair with:
```
ADD COLUMN "Source Message ID" RICH_TEXT
```

If `Acknowledged At` is missing and needed, repair with:
```
ADD COLUMN "Acknowledged At" DATE
```

If `Created At` is missing, repair with:
```
ADD COLUMN "Created At" CREATED_TIME
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

Use the first available query path. The detection depends on `execution_environment` because server-side filtering is delivered by different mechanisms in each environment — bash script (CLI) vs. Desktop Extension MCP tool (Claude Desktop / Cowork).

### Query Path Detection

**CLI (`execution_environment = "cli"`):**
1. `NOTION_TOKEN` env var available in shell (check: `[ -n "$NOTION_TOKEN" ] && echo "SET" || echo "NOT SET"`) → Path 1 (bash script)
2. Otherwise → halt the current step and surface the error to the user (no fallback). See "Error Handling for Query Path" below.

**Claude Desktop / Cowork (`execution_environment = "claude-desktop"` or `"cowork"`):**
In these environments `NOTION_TOKEN` is not exposed to the shell, so the bash script is not usable. Use the Desktop Extension MCP tool:
1. `mcp__notion-extension__notion-query` tool available → Path 2 (Desktop Extension)
2. Otherwise → halt the current step and surface the error to the user (no fallback). See "Error Handling for Query Path" below.

### Path 1: Notion API Bash Script (CLI, requires NOTION_TOKEN)

Call the query script for server-side filtering:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/query-tasks.sh \
  "<tasksDatabaseId>" '<filter_json>' '<sort_json>'
```

The script returns `{"results": [...]}` with full page objects including all properties.

#### Filter Recipes

**Tasks assigned to a user:**
```json
{"property":"Assignee","people":{"contains":"<user_id>"}}
```

**Ready tasks assigned to a user:**
```json
{"and":[{"property":"Status","select":{"equals":"Ready"}},{"property":"Assignee","people":{"contains":"<user_id>"}}]}
```

**In Progress tasks (for concurrency check):**
```json
{"and":[{"property":"Status","select":{"equals":"In Progress"}},{"property":"Assignee","people":{"contains":"<user_id>"}}]}
```

**Ready tasks by executor and assignee (single executor):**
```json
{"and":[{"property":"Status","select":{"equals":"Ready"}},{"property":"Executor","select":{"equals":"cowork"}},{"property":"Assignee","people":{"contains":"<user_id>"}}]}
```

**Ready tasks by executor and assignee (multiple executors — for cli/claude-desktop environments):**
```json
{"and":[{"property":"Status","select":{"equals":"Ready"}},{"or":[{"property":"Executor","select":{"equals":"cli"}},{"property":"Executor","select":{"equals":"claude-desktop"}},{"property":"Executor","select":{"equals":"cowork"}}]},{"property":"Assignee","people":{"contains":"<user_id>"}}]}
```

**Sort by Priority then Due Date:**
```json
[{"property":"Priority","direction":"ascending"},{"property":"Due Date","direction":"ascending"}]
```

**Blocked tasks owned by user (via Assignee OR Issuer fallback):**
```json
{"and":[{"property":"Status","select":{"equals":"Blocked"}},{"or":[{"property":"Assignee","people":{"contains":"<user_id>"}},{"and":[{"property":"Issuer","created_by":{"contains":"<user_id>"}},{"property":"Assignee","people":{"is_empty":true}}]}]}]}
```

**Ready human tasks owned by user (via Assignee OR Issuer fallback):**
```json
{"and":[{"property":"Status","select":{"equals":"Ready"}},{"property":"Executor","select":{"equals":"human"}},{"or":[{"property":"Assignee","people":{"contains":"<user_id>"}},{"and":[{"property":"Issuer","created_by":{"contains":"<user_id>"}},{"property":"Assignee","people":{"is_empty":true}}]}]}]}
```

> **v2.8.1 note**: the Issuer filter syntax shifted from `"people":{...}` to `"created_by":{...}` to match the new column type. The operator names (`contains`, `is_empty`) are the same.

#### Hierarchy Queries

**Subtasks of a parent task:**
```json
{"property":"Parent Task","relation":{"contains":"<parent_task_id>"}}
```

**Check if a task is a parent (has children):** Query with the subtasks filter above. If results are non-empty, the task has children.

**Check if a candidate parent is itself a subtask:** Fetch the candidate parent with `notion-fetch` and check if its `Parent Task` relation is empty. If non-empty, it is already a subtask and cannot be used as a parent (2-level limit).

### Path 2: Desktop Extension (notion-query MCP tool, Claude Desktop / Cowork)

Available when the `mcp__notion-extension__notion-query` tool is present. Uses the same filter recipes as Path 1 above.

Call `mcp__notion-extension__notion-query` with:
- `database_id`: the `tasksDatabaseId`
- `filter`: filter JSON
- `sorts`: sort JSON
- `page_size` (optional, 1-100): when set, the tool returns one Notion API page at a time and the response includes `has_more` and `next_cursor` so the caller can iterate. When omitted, all pages are aggregated server-side — this risks overflowing the MCP host's token cap on databases with hundreds of rows.
- `start_cursor` (optional): pass the previous response's `next_cursor` to fetch the next page. Only meaningful alongside `page_size`.
- `filter_properties` (optional, array of Notion property IDs): when set, only the named properties appear in each result's `properties` object. Reduces payload but does not strip Notion's page-level metadata.

Returns `{"results": [...]}` in the same Notion API format as Path 1; when `page_size` is set, the response also includes `has_more` (boolean) and `next_cursor` (string or null).

**Pagination requires extension v0.4.0+**. The tool name `mcp__notion-extension__notion-query` is unchanged from v0.3.x, so the tool's mere presence does not guarantee pagination support. v0.3.x silently ignores `page_size` and `start_cursor` and always returns the aggregated full result set — defeating the pagination strategy and risking the original token-cap overflow. **How to detect at runtime**: when calling with `page_size`, check whether the response contains a `has_more` field. If it does not, the installed extension is v0.3.x or earlier; halt the calling step and surface "Notion Desktop Extension is older than v0.4.0. Install the latest version to use paginated queries on this database." Users can also verify their installed version proactively via the `health-checking` skill, which probes for this.

**When to paginate**: any time the target database may grow past a few hundred records (Intake Log, Tasks DB, custom-source mirrors). The legacy "no page_size" mode is preserved for short queries with bounded result sets where one round-trip is simpler.

### Error Handling for Query Path

- If the detected query path is unavailable, OR a structured query call returns a database-access error like `Could not find database with ID: <id>. Make sure the relevant pages and databases are shared with your integration <name>`, do NOT fall back to `notion-search`.
- Halt the current step (not the whole skill). Surface the Notion API error verbatim. The caller (e.g. `running-daily-tasks`) prompts the user `[Continue to next step] [End]` after surfacing the error.

Halt-message templates per environment:

- **CLI, `NOTION_TOKEN` missing**: "Cannot run Notion database query: NOTION_TOKEN is not exposed to the shell. Set it in `~/.claude/settings.json` env block, then re-run. Step halted."
- **Claude Desktop / Cowork, `notion-extension` MCP missing**: "Cannot run Notion database query: the `notion-extension` Desktop Extension is not installed. Install it and re-run. Step halted."
- **Any environment, Notion API returned `Could not find database with ID …`**: surface the API error verbatim, then add: "The integration `<integration name from error>` does not have access to this database. In Notion, share the database with the integration. If you also use `ingesting-messages`, share the Intake Log and Active Threads databases with the same integration. Then re-run. Step halted."

The `notion-search` fallback was removed in 2.5.6 because it cannot filter on people properties server-side and returned tasks owned by other assignees, while masking the real setup error.

### Post-Processing (all paths)

- **Blocked By resolved**: Check that the `Blocked By` relation array is empty OR fetch each referenced task's Status and confirm all are "Done". This cannot be filtered server-side.
- **Sort** (if not done server-side): Priority — Urgent > High > Medium > Low; then by Due Date (earliest first).

### Displaying Task Lists

When displaying queried tasks to the user in list or table format, reduce each result to display-relevant fields to prevent output truncation. Apply this jq shape to the `results` array returned by the chosen query path:

```jq
[.results[] | {
  id: .id,
  title: (.properties.Title.title[0].plain_text // ""),
  status: (.properties.Status.select.name // ""),
  priority: (.properties.Priority.select.name // ""),
  executor: (.properties.Executor.select.name // ""),
  assignee: ([.properties.Assignee.people[]?.name] | join(", ")),
  due_date: (.properties["Due Date"].date.start // ""),
  blocked_by: (([.properties["Blocked By"].relation[]?.id] | length | tostring) + " deps")
}]
```

For single-task detail views (update, status change), use the full page object.

### Fetch All Tasks

To retrieve all tasks (e.g. for view server data push), use the detected query path with no filter:

- **Path 1 (CLI)**: `bash ${CLAUDE_SKILL_DIR}/scripts/query-tasks.sh "<tasksDatabaseId>"` (no filter/sort args)
- **Path 2 (Claude Desktop / Cowork)**: call `mcp__notion-extension__notion-query` with `database_id: <tasksDatabaseId>` and no `filter` / `sorts`
- If neither Path 1 nor Path 2 is available: halt per "Error Handling for Query Path" above.

No post-processing needed (no Blocked By filter, no sort required).

## Querying Any Notion Database

When querying ANY Notion database (not just the Tasks DB — e.g., Intake Log, external databases), use the same per-environment detection as the Tasks DB query:

**CLI:**
1. `NOTION_TOKEN` env var available → call the bash script: `bash ${CLAUDE_SKILL_DIR}/scripts/query-tasks.sh "<database_id>" '<filter_json>' '<sort_json>'`
2. Otherwise → halt and surface the error per "Error Handling for Query Path" above. Do not fall back to notion-search.

**Claude Desktop / Cowork:**
1. `mcp__notion-extension__notion-query` available → call the MCP tool with the target database ID and filter. For databases that may grow past ~200 rows (Intake Log, Tasks DB, custom-source mirrors), pass `page_size` (1-100) and iterate using the response's `has_more` / `next_cursor`. See Path 2 above for full parameter docs.
2. Otherwise → halt and surface the error per "Error Handling for Query Path" above. Do not fall back to notion-search.

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
| Assignee | `assignee` |
| Issuer | `issuer` |
| Acknowledged At | `acknowledgedAt` |
| Created At | `createdAt` |
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

- Fetch the task's `Assignee` property (people type — returns an array of person objects).
- Check if any element in the array has `id === current_user.id`.
- Use this check when filtering tasks in `managing-tasks` and `executing-tasks`.

## Error Handling

| Error Category | HTTP Code | Action |
|---|---|---|
| Rate limit | 429 | Retryable — wait for `Retry-After` header seconds, then retry |
| Database access denied | 404, body contains `"Could not find database with ID"` | Terminal — the integration does not have access to the database. Surface the error verbatim, name the missing integration, and instruct the user to share the database in Notion. Halt the current step. **Exception**: if this 404 fires during Schema Validation immediately after Step 1 returned a cached `tasksDatabaseId`, follow the "Recovery from stale cache" path in Config Retrieval instead — the failure is non-terminal in that specific context. |
| Page not found | 404 (body does **not** match the database-access pattern above) | Terminal — the page was deleted or the integration lost access. Report to user |
| Server error | 500 | Retryable — exponential backoff (1s, 2s, 4s), max 3 attempts |
| MCP tool unavailable | N/A | Terminal — the Notion MCP server is not configured. Instruct user to check MCP settings |
