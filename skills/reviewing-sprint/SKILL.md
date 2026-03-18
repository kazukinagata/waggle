---
name: reviewing-sprint
description: >
  Generates an automated batch completion summary and closes the active sprint.
  Reviews done/undone tasks, calculates velocity, and handles unfinished task disposition.
  Triggers on: "sprint review", "batch complete", "end sprint", "close sprint",
  "スプリントレビュー", "スプリント終了".
---

# Agentic Tasks — Sprint Review

Generates an automated batch completion summary and closes the sprint. The agent generates the summary; the human only approves the disposition of unfinished tasks.

## Provider Detection + Config + Identity (once per session)

1. Load `${CLAUDE_PLUGIN_ROOT}/skills/detecting-provider/SKILL.md` and follow its instructions to determine `active_provider` and retrieve `headless_config`. Skip if already set.
2. Load `${CLAUDE_PLUGIN_ROOT}/skills/resolving-identity/SKILL.md` and resolve `current_user` + `current_team`. Skip if already set.

If `headless_config.sprintsDatabaseId` is missing, tell the user to run "set up scrum" first.

## Step 1: Find Active Sprint

Fetch sprints from `headless_config.sprintsDatabaseId` where `Team = current_team.id` (if `current_team` is set). Find the one with Status = "Active".
If none, report "No active sprint found" and exit.

## Step 2: Fetch Sprint Tasks

Fetch all tasks with Sprint = <Active Sprint ID>.

## Step 3: Generate Batch Completion Summary

Categorize tasks:
- **DONE**: Status = "Done"
- **NOT DONE**: Status ≠ "Done"

For NOT DONE tasks, analyze dispositions:
- If Blocked By task is now Done → "Dependency resolved → can carry over to next sprint"
- If Status = "In Progress" → "In progress → extend sprint or move to next sprint"
- If Status = "Backlog"/"Ready" → "Not started → move to next sprint or return to backlog"
- If Status = "Blocked" + Error → "Blocked by error → needs investigation"

Display:
```
[Batch Completion Summary] <Sprint Name>

DONE (<N> tasks, Score:<N>):
  - <Task Title>   ✓  [Artifacts: <artifacts if any>]
  - <Task Title>   ✓

NOT DONE (<N> tasks, Score:<N>):
  - <Task Title>   [<Status>] — <disposition analysis>
  - <Task Title>   [<Status>] — <disposition analysis>

Sprint Metrics:
  Velocity: <Done Score> Complexity Score
  Stall incidents: <count from Metrics field>
  Error rate: <tasks with Error Message not empty> / <total dispatched>
  Avg cycle time: ~<hours> per task

Unfinished task disposition:
  "<Task Title>" → Carry over to next sprint? Or return to backlog?
```

## Step 4: Ask for Disposition of Unfinished Tasks

Use AskUserQuestion for each NOT DONE task (or batch them):

Options:
- Carry over to next sprint (clear Sprint relation — task returns to backlog for next sprint planning)
- Return to backlog (clear Sprint relation)
- Leave as-is (no change)

## Step 5: Apply Dispositions

For each NOT DONE task based on the user's choice:
- "Carry over to next sprint" → clear the Sprint field (will be assigned to next sprint during planning)
- "Return to backlog" → clear Sprint field, set Status = "Backlog" if it was Ready/Blocked
- "Leave as-is" → no change

## Step 6: Finalize Sprint

1. Calculate Velocity: sum of Complexity Score for all Done tasks
2. Update Sprint via `notion-update-page`:
   - Velocity: <calculated value>
   - Completion Notes: <the auto-generated summary text>
   - Status: "Completed"

3. (Optional) If user confirms, transition Status from "Completed" to "Closed"

## Step 7: Push Updates to View Server

```bash
# Silently skip if server is not running
curl -s http://localhost:3456/api/health -o /dev/null 2>/dev/null && {
  curl -s -X POST http://localhost:3456/api/data \
    -H "Content-Type: application/json" -d '<tasks_json>' -o /dev/null 2>/dev/null
  curl -s -X POST http://localhost:3456/api/sprint-data \
    -H "Content-Type: application/json" -d '<sprints_json>' -o /dev/null 2>/dev/null
} || true
```

## Step 8: Completion Report

```
Sprint completed: <Sprint Name>
Velocity: <N> Complexity Score (<Done tasks>/<Total tasks> tasks completed)

Next steps:
  - Run "retro" for detailed sprint metrics analysis
  - Run "start sprint" to begin the next sprint
```

## Language

Always communicate with the user in the language they are using.
