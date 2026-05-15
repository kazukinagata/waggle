---
name: health-checking
description: >
  Checks waggle configuration health: Scheduled Task remnants, custom intake settings,
  config.json migration status, and Notion Desktop Extension version.
  Triggers on: "health check", "check config", "check setup", "ヘルスチェック",
  "設定チェック", "設定確認"
user-invocable: true
---

# Waggle — Health Check

You are performing a configuration health check for waggle. This skill verifies that user-dependent settings are correct and up-to-date.

## Step 0: Session Bootstrap

Invoke the `bootstrap-session` skill to establish the active provider and current user.
Skip if `active_provider` and `current_user` are already set in this conversation.

## Step 1: Run Checks

Run each check below and collect results. Skip checks marked with environment/provider conditions when they don't apply.

---

### Check 1: Scheduled Task Remnant (Claude Desktop / Cowork only)

**Skip if** `execution_environment = "cli"`.

Call `mcp__scheduled-tasks__list_scheduled_tasks` to retrieve all Scheduled Tasks.

Look for entries where:
- `description` contains "waggle" (case-insensitive), AND
- `cronExpression` is set (i.e., it is a recurring scheduled task, not a one-time `fireAt` task)

| Condition | Result |
|---|---|
| No matching entries | PASS: No legacy daily routine Scheduled Tasks found |
| Matching entries found | FAIL: Legacy daily routine Scheduled Task detected. Display the `taskId` and `description` of each match. Instruct the user to delete them — the daily routine should now be run manually via the `running-daily-tasks` skill |

---

### Check 2: Custom Intake Instructions

#### CLI / Claude Desktop (`execution_environment` is `"cli"` or `"claude-desktop"`)

Read `~/.waggle/intake-prompt.md` via Bash: `cat ~/.waggle/intake-prompt.md 2>/dev/null`

| Condition | Result |
|---|---|
| File exists | INFO: Display the file contents |
| File does not exist | INFO: Custom intake messages are not configured |

#### Cowork (`execution_environment = "cowork"`)

Check the system prompt for `<waggle-custom-intake>` and `</waggle-custom-intake>` tags.

| Condition | Result |
|---|---|
| Tags found | INFO: Display the content between the tags |
| Tags not found | INFO: Custom intake messages are not configured |

---

### Check 3: `~/.waggle/config.json` Migration (CLI / Claude Desktop only)

**Skip if** `execution_environment = "cowork"`.

Read `~/.waggle/config.json` via Bash: `cat ~/.waggle/config.json 2>/dev/null`

| Condition | Result |
|---|---|
| File does not exist | PASS: No legacy config.json found |
| File exists | WARN: Legacy config.json detected — proceed to migration flow below |

#### Migration Flow

1. Parse the config.json content and identify the provider and values:

   | Provider | Config Key | Target Env Var |
   |---|---|---|
   | Notion | `tasksDatabaseId` | `WAGGLE_NOTION_TASKS_DB_ID` |
   | Notion | `teamsDatabaseId` | `WAGGLE_NOTION_TEAMS_DB_ID` |
   | Notion | `intakeLogDatabaseId` | `WAGGLE_NOTION_INTAKE_LOG_DB_ID` |
   | Notion | `sprintsDatabaseId` | `WAGGLE_NOTION_SPRINTS_DB_ID` |
   | Notion | `activeThreadsDatabaseId` | `WAGGLE_NOTION_ACTIVE_THREADS_DB_ID` |
   | SQLite | `dbPath` | `WAGGLE_SQLITE_DB_PATH` |
   | Turso | `tursoUrl` | `TURSO_URL` |
   | Turso | `tursoAuthToken` | `TURSO_AUTH_TOKEN` |

2. Display the migration plan to the user:
   > "Legacy `~/.waggle/config.json` found. I can migrate these values to `~/.claude/settings.json` env and delete the old file."
   >
   > Show the key → env var mapping with values.

3. Ask for confirmation via `AskUserQuestion`:
   > "Proceed with config.json migration?"

4. If approved:
   - Read `~/.claude/settings.json` (create if it doesn't exist)
   - Add each env var to the `env` field (preserve existing env vars)
   - Write the updated `~/.claude/settings.json`
   - Delete `~/.waggle/config.json` via Bash: `rm ~/.waggle/config.json`
   - Report: PASS: Migration complete

5. If declined:
   - Report: WARN: Migration skipped. Manual migration recommended.

---

### Check 4: Notion Desktop Extension Version (Claude Desktop / Cowork, Notion provider only)

**Skip if** `execution_environment = "cli"` or `active_provider` is not `"notion"`.

Check available MCP tools, then probe pagination support:

| Condition | Result |
|---|---|
| `mcp__notion-extension__notion-query` tool is available AND pagination probe succeeds (see below) | PASS: Latest Notion Desktop Extension (v0.4.0+) is installed |
| `mcp__notion-extension__notion-query` tool is available BUT pagination probe shows v0.3.x semantics | WARN: Outdated `notion-extension` detected (v0.3.x or earlier — silently ignores `page_size`). Install v0.4.0 or later so `ingesting-messages` and large-database queries can paginate. Without this, the Intake Log query can overflow the MCP token cap and stall the run for many minutes. |
| `mcp__notion-query__notion-query` tool is available (but not `mcp__notion-extension__*`) | WARN: Outdated extension detected. Uninstall `notion-query` and install the new `notion-extension` v0.4.0+ |
| Neither tool is available | WARN: Notion Desktop Extension is not installed. Install `notion-extension` v0.4.0+ for full functionality (paginated queries, relation field updates, people property filters) |

**Pagination probe**: when `mcp__notion-extension__notion-query` is available, call it with `database_id: <any small reachable database, e.g. the Waggle Config DB derived from active_provider's identity flow>` and `page_size: 1`. Inspect the response:

- Response object contains a `has_more` key → server honors `page_size` → v0.4.0+. PASS.
- Response object does not contain `has_more` (only `results`) → server ignored `page_size` and aggregated everything → v0.3.x or earlier. WARN.

The Waggle Config DB or the Intake Log DB IDs are good probe targets because they exist whenever waggle is set up and are tiny; do not probe the Tasks DB if it is large, since v0.3.x will pull it in full during the probe.

---

## Step 2: Report

Output a markdown report summarizing all check results:

```
## Waggle Health Check Report

| Check | Result | Details |
|---|---|---|
| Scheduled Task Remnant | PASS/FAIL | ... |
| Custom Intake Instructions | INFO | ... |
| config.json Migration | PASS/WARN | ... |
| Notion Extension Version | PASS/WARN | ... |
```

If any checks resulted in FAIL or WARN, summarize the required actions at the end of the report.
