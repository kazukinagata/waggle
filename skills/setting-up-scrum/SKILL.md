---
name: setting-up-scrum
description: >
  Provisions the Sprints database and extends the Tasks DB with sprint-related
  fields (Sprint relation, Complexity Score, Backlog Order). Idempotent and opt-in.
  Triggers on: "set up scrum", "enable scrum", "add scrum", "set up sprints",
  "スクラム設定", "スプリント設定".
---

# Agentic Tasks — Scrum Setup

This skill provisions the Sprints (Objectives) database and extends the Tasks DB with sprint-related fields. It is opt-in and idempotent.

## Provider Detection + Config (once per session)

Load `${CLAUDE_PLUGIN_ROOT}/skills/detecting-provider/SKILL.md` and follow its instructions to determine `active_provider` and retrieve `headless_config`. Skip if already set.

## Idempotency Check

Before doing anything, check if `headless_config.sprintsDatabaseId` already exists.
If it does, report "Scrum is already set up (sprintsDatabaseId: <ID>)" and exit.

## Step 1: Create Sprints (Objectives) DB

Use `notion-create-database` to create the Sprints DB as a sibling of the Tasks DB (same parent page).

Database name: "Sprints"

Schema:

| Property | Notion Type | DDL |
|---|---|---|
| Name | title | (auto-created) |
| Goal | rich_text | `ADD COLUMN "Goal" RICH_TEXT` |
| Status | select | `ADD COLUMN "Status" SELECT('Planning':gray, 'Active':green, 'Completed':blue, 'Closed':default)` |
| Max Concurrent Agents | number | `ADD COLUMN "Max Concurrent Agents" NUMBER` |
| Velocity | number | `ADD COLUMN "Velocity" NUMBER` |
| Metrics | rich_text | `ADD COLUMN "Metrics" RICH_TEXT` |
| Completion Notes | rich_text | `ADD COLUMN "Completion Notes" RICH_TEXT` |

After creating the DB, note its ID as `SPRINTS_DS_ID`.

Then add a Team relation to the Sprints DB (requires `teamsDatabaseId` from `headless_config`):

```
ADD COLUMN "Team" RELATION('<TEAMS_DS_ID>')
```

This allows each sprint to be scoped to a specific team.

## Step 2: Add Sprint Relation to Tasks DB

Obtain the Tasks DB data source ID via `notion-fetch` on `headless_config.tasksDatabaseId`.

Add a dual relation (one call per direction):

```
ADD COLUMN "Sprint" RELATION('<SPRINTS_DS_ID>', DUAL 'Tasks' 'tasks')
```

This creates a `Sprint` column on Tasks that points to the Sprints DB, and a back-propagated `Tasks` column on Sprints.

## Step 3: Add Complexity Score to Tasks DB

```
ADD COLUMN "Complexity Score" NUMBER
```

For the Complexity Score calculation logic, refer to the "Backlog → Ready: Complexity Score Calculation" section in managing-tasks,
or see `skills/setting-up-scrum/scripts/calc-complexity.py`.

## Step 4: Add Backlog Order to Tasks DB

```
ADD COLUMN "Backlog Order" NUMBER
```

Backlog Order convention: 1000, 2000, 3000... (gaps allow easy insertion). Agent proposes, human can override.

## Step 5: Update Config Page

Update the JSON code block in the config page to add:

```json
{
  "tasksDatabaseId": "...",
  "teamsDatabaseId": "...",
  "sprintsDatabaseId": "<NEW_SPRINTS_DB_ID>",
  "maxConcurrentAgents": 3
}
```

Use `notion-update-page` to overwrite the code block content.

## Step 6: Completion Report

Output a summary:

```
Scrum setup complete

Created database:
  Sprints DB: <SPRINTS_DB_ID>

Fields added to Tasks DB:
  - Sprint (relation → Sprints)
  - Complexity Score (number)
  - Backlog Order (number)

Config updated:
  - sprintsDatabaseId: <ID>
  - maxConcurrentAgents: 3

Next steps:
  - Run "start sprint" to begin sprint planning
  - Run "show backlog" to view the backlog
```

## Language

Always communicate with the user in the language they are using.
