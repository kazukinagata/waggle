---
name: health-checking
description: >
  Checks waggle configuration health: Scheduled Task remnants, custom intake settings,
  config.json migration status, and which Notion query tool is usable.
  Triggers on: "health check", "check config", "check setup", "ヘルスチェック",
  "設定チェック", "設定確認"
user-invocable: true
---

# Waggle — Health Check

You are performing a configuration health check for waggle. This skill verifies that user-dependent settings are correct and up-to-date.

## Output Discipline

This skill runs as a multi-step pipeline, but the user only needs its outcomes. Do not
narrate step transitions ("Now I'll...", "X done, next Y") and do not relay protocol
internals — provider detection, config/schema checks, cache state, validation plumbing,
view-server pushes. Surfacing them buries what actually matters.

Emit user-facing text only when it changes something for the user:

- a prompt or confirmation that needs their input
- an error or a warning
- an intermediate result that changes the outcome (e.g., a non-PASS quality verdict and
  the gaps behind it — it explains why a task lands at a different status than expected)
- the final result summary

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

### Check 4: Notion Query Tool (Claude Desktop / Cowork, Notion provider only)

**Skip if** `execution_environment = "cli"` or `active_provider` is not `"notion"`.

Waggle queries Notion databases with an **uncapped query tool**: a tool whose unqualified name is exactly
`notion-query`, taking Notion API `filter` / `sorts` and paging with `page_size` / `start_cursor`. It is
provided by the Notion Desktop Extension or by a remote MCP connector the organization runs; the server part
of its full name differs per environment (it can be an opaque id such as a UUID), so look for the unqualified
name, not a prefix. Do not count the official Notion connector's `notion-query-data-sources` — it shares one
query quota across the workspace on some plans, which is why waggle uses it only as a last resort.

List every uncapped query tool in the session, then probe each one (see below):

| Condition | Result |
|---|---|
| At least one uncapped query tool passes the probe | PASS: Uncapped Notion query tool available — name each passing tool by the server part of its full name |
| A tool answers the probe but the response has no `has_more` | WARN: This query tool ignores `page_size` — a Notion Desktop Extension older than v0.4.0, or a connector without pagination (name the tool by the server part of its name). Update the Desktop Extension, or use a query connector that paginates, so `ingesting-messages` and large-database queries can paginate. Without this, the Intake Log query can overflow the MCP token cap and stall the run for many minutes. |
| A tool returns an access error — HTTP 403 or a message that the user lacks permission to use it, or HTTP 401 or a message that the login could not be verified or the user should reconnect (judge by meaning; the wording is the connector's own, often in the user's language) | WARN: The Notion query connector declined this user — quote the error verbatim. Ask whoever runs that connector for access (or reconnect it), or install the Notion Desktop Extension. Until then, queries fall back to the official Notion connector and its shared quota. |
| No uncapped query tool is available | WARN: No uncapped Notion query tool. Install the Notion Desktop Extension (v0.4.0+) or connect a remote Notion query connector for paginated, filtered queries. Until then, queries fall back to the official Notion connector and its shared quota (if it is connected). |

Report one row per tool when several are present (e.g. the Desktop Extension and a remote connector); the
check as a whole is PASS when any tool passes.

**Pagination probe**: call each uncapped query tool with `database_id: <intakeLogDatabaseId from the Waggle Config page>` and `page_size: 1`. The Intake Log is guaranteed to exist after the first `ingesting-messages` run and is always small (bounded by Step 4's TTL cleanup), so it is the safest probe target. If `intakeLogDatabaseId` is not yet set in config (first-ever waggle session, before `ingesting-messages` has created the DB), fall back to any other small config-referenced DB you already have an ID for. **Do not probe `tasksDatabaseId`** — on a v0.3.x host the probe itself will fetch the entire Tasks DB and trigger the very overflow this check is meant to detect.

Inspect the response:

- Response object contains a `has_more` key → the tool honors `page_size`. PASS.
- Response object does not contain `has_more` (only `results`) → the tool ignored `page_size` and aggregated everything → a Desktop Extension older than v0.4.0, or a connector without pagination. WARN.
- The call returns an access error → WARN as in the table above.

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
| Notion Query Tool | PASS/WARN | ... |
```

If any checks resulted in FAIL or WARN, summarize the required actions at the end of the report.
