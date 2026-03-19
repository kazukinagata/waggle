---
name: running-standup
description: >
  Generates an automated sprint status report with stall detection and blocked
  task analysis. Replaces human standup format with quantitative metrics.
  Triggers on: "standup", "status report", "agent status",
  "burn down", "stalled tasks",
  "スタンドアップ", "ステータスレポート", "進捗報告".
---

# Waggle — Sprint Standup

Generates an automated status report for the active sprint. Focuses on stall detection and blocked task analysis rather than a human "yesterday/today/blockers" format.

## Provider Detection + Config + Identity (once per session)

1. Load `${CLAUDE_PLUGIN_ROOT}/skills/detecting-provider/SKILL.md` and follow its instructions to determine `active_provider` and retrieve `headless_config`. Skip if already set.
2. Load `${CLAUDE_PLUGIN_ROOT}/skills/resolving-identity/SKILL.md` and resolve `current_user` + `current_team`. Skip if already set.

If `headless_config.sprintsDatabaseId` is missing, tell the user to run "set up scrum" first.

## Step 1: Find Active Sprint

Fetch sprints from `headless_config.sprintsDatabaseId` where `Team = current_team.id` (if `current_team` is set). Find the one with Status = "Active".
If none, report "No active sprint found" and exit.

## Step 2: Fetch Sprint Tasks

Fetch all tasks with Sprint = <Active Sprint ID>.

## Step 3: Classify Tasks into 4 Buckets

**RUNNING** — Status = "In Progress" (and not stalled)
- Show: Task title, Session Reference, elapsed time since Dispatched At

**COMPLETED (since last report)** — Status = "Done" (completed recently)
- Show: Task title, brief Agent Output summary if available

**STALLED** — Status = "In Progress" AND Dispatched At is older than (Complexity Score × stallThresholdMultiplier) hours
- stallThresholdMultiplier and stallDefaultHours are defined in detecting-provider Constants
- Stall threshold: If Complexity Score is null, use stallDefaultHours as default
- Show: Task title, Session Reference, elapsed hours, expected duration hint

**BLOCKED** — Status = "Blocked" OR (Status = "Backlog"/"Ready" AND Blocked By contains any non-Done task)
- Show: Task title, Blocked By task names, Error Message if present

## Step 4: Display Report

```
[Sprint Status Report] <Sprint Name> (<current_team.name or "All">)
Goal: <Goal>

RUNNING (In Progress):
  - <Task Title>     [Session: <Session Reference>] [<N>h elapsed]
  - <Task Title>     [Session: <Session Reference>] [<N>h elapsed]

COMPLETED (since last report):
  - <Task Title>     [Done] [Agent Output: <brief summary>]

STALLED (needs attention):
  - <Task Title>     [In Progress] [Dispatched <N>h ago — expected ~Score:<N> = ~<N>h]
    → Check session <Session Reference>

BLOCKED:
  - <Task Title>     [Blocked by: <Dependency Title>]
    Error: <Error Message or "none (dependency pending)">

Complexity Score Progress: <Done Score> / <Total Score> (<N>%)
Stall rate this sprint: <stalled count>/<dispatched count> dispatched tasks (<N>%)
```

If a bucket is empty, omit it from the report.

## Step 5: Update Sprint Metrics

Append a daily snapshot to the sprint's `Metrics` field using `notion-update-page`:

```
<YYYY-MM-DD>: Done=<N>pts, InProgress=<N>pts, Stall=<N>task(s)
```

Append to the existing content (do not overwrite).

## Stall Detection Logic

A task is "stalled" when:
- Status = "In Progress"
- `Dispatched At` is set
- Hours since `Dispatched At` > (Complexity Score × stallThresholdMultiplier)
  - stallThresholdMultiplier and stallDefaultHours are defined in detecting-provider Constants

Recommend actions for stalled tasks:

**Terminal CLI:**
- Check tmux session: `tmux has-session -t <session-ref> 2>/dev/null`
- If the session is dead, mark as stalled

**Claude Desktop:**
- Check the task status via `mcp__scheduled-tasks__list_scheduled_tasks`
- Extract taskId from Session Reference `scheduled:<taskId>` and search

**Common:**
- Consider restarting the task
- Consider reducing scope (split into smaller tasks)

## Language

Always communicate with the user in the language they are using.
