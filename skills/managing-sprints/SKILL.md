---
name: managing-sprints
description: >
  Manages sprint (batch) lifecycle and product backlog. Handles sprint planning,
  status, backlog ordering, and task-to-sprint assignment.
  Triggers on: "start sprint", "begin sprint", "new sprint", "plan sprint",
  "sprint planning", "end sprint", "close sprint", "sprint status",
  "what's in this sprint", "show sprint", "sprint backlog", "add to sprint",
  "show backlog", "product backlog", "reorder backlog", "reprioritize",
  "backlog order",
  "スプリント開始", "スプリント計画", "スプリント状況", "バックログ".
---

# Agentic Tasks — Sprint Management

Manages the sprint (batch) lifecycle and product backlog. A "sprint" here is a scope-box (Objective), not a time-box.

## Provider Detection + Config + Identity (once per session)

1. Load `${CLAUDE_PLUGIN_ROOT}/skills/detecting-provider/SKILL.md` and follow its instructions to determine `active_provider` and retrieve `headless_config`. Skip if already set.
2. Load `${CLAUDE_PLUGIN_ROOT}/skills/resolving-identity/SKILL.md` and resolve `current_user` + `current_team`. Skip if already set.

If `headless_config.sprintsDatabaseId` is missing, tell the user to run "set up scrum" first.

All sprint operations below are **team-scoped**: filter sprints by `Team = current_team.id` and filter tasks by `Assignees ∈ current_team.members`. If `current_team` is null, skip team filtering (behave as before).

---

## Action: Start Sprint / Sprint Planning

**Triggered by**: "start sprint", "plan sprint", "new sprint", "sprint planning"

### Step 1: Guard

Fetch sprints from `headless_config.sprintsDatabaseId` where `Team = current_team.id` (if `current_team` is set). If any sprint has Status = "Active", report:
```
An active sprint already exists: <Sprint Name>
Please end the current sprint before starting a new one ("end sprint")
```

### Step 2: Gather Sprint Info

Use AskUserQuestion to ask:
- **Goal** (required): Describe the sprint goal and completion criteria
- **Max Concurrent Agents** (optional, defaults to `headless_config.maxConcurrentAgents`): Maximum parallel execution limit

### Step 3: Analyze Backlog

Fetch tasks where Status = "Backlog" or "Ready" AND Sprint = empty AND Assignees ∈ `current_team.members` (if `current_team` is set).

Build a topological sort considering `Blocked By` chains (a blocker is "resolved" if its Status = Done):
- Group A: tasks with no unresolved blockers (Blocked By is empty or all blockers are Done — immediately executable)
- Group B: tasks blocked only by Group A tasks (that are not yet Done)
- Group C+: deeper dependency chains

Within each group, sort by: Priority (Urgent > High > Medium > Low) then Complexity Score (higher first).

### Step 4: Propose Batch

Present the analysis to the user:

```
[Batch Proposal] Goal: <Goal Text>

Proposed execution batch (max parallel agents: <N>):

  Priority Group A (no dependencies, immediately executable):
    1. <Task Title>   [<Priority> / Score:<N>] [<Executor>]
    2. <Task Title>   [<Priority> / Score:<N>] [<Executor>]

  Priority Group B (executable after A completes):
    3. <Task Title>   [<Priority> / Score:<N>] [<Executor>]  <- Blocked by #1

Group A total Complexity Score: <N>
Overall total Complexity Score: <N>

"Proceed with this batch? If changes are needed, say something like 'remove #3 and add #5'."
```

### Step 5: Apply Human Approval / Modifications

Accept modifications like "remove #N" / "add #M" and update the proposed list.
When approved:

1. Create the Sprint page in the Sprints DB via `notion-create-pages`:
   - Name: "Sprint <N>" (auto-number based on existing sprints, or accept user's name)
   - Goal: <user-provided Goal>
   - Status: "Active"
   - Max Concurrent Agents: <value>
   - Team: `current_team.id` (if `current_team` is set)

2. Set the `Sprint` field on each selected task to point to the new Sprint page.

3. Push updated data to view server (see "After Operations" section).

4. Report:
```
Sprint started: <Sprint Name>
Active tasks: <N> tasks (Complexity Score: <N>)
View server: http://localhost:3456/sprint-backlog.html
```

---

## Action: Sprint Status

**Triggered by**: "sprint status", "what's in this sprint", "show sprint"

1. Find the Active sprint from `headless_config.sprintsDatabaseId` where `Team = current_team.id` (if `current_team` is set)
2. Fetch all tasks with Sprint = <Active Sprint ID>
3. Calculate stall threshold: tasks with Status = "In Progress" AND Dispatched At older than (Complexity Score × stallThresholdMultiplier (see detecting-provider Constants)) hours

Display:
```
Active Sprint: <Sprint Name>
Goal: <Goal Text>

Progress:
  Done:        <bar>  <N> tasks (Score:<N>)
  In Progress: <bar>  <N> tasks (Score:<N>)   [Session: <refs>]
  Ready:       <bar>  <N> tasks (Score:<N>)
  Backlog:     <bar>  <N> tasks (Score:<N>)
  Blocked:     <bar>  <N> tasks
  STALLED:     <bar>  <N> tasks (Dispatched Xh ago — consider timeout)

Completion: <Done Score> / <Total Score> Complexity Score (<N>%)
```

Flag STALLED tasks (In Progress with Dispatched At > Score × stallThresholdMultiplier hours ago) with yellow/red text.

---

## Action: Show Backlog / Product Backlog

**Triggered by**: "show backlog", "product backlog"

1. Fetch tasks where Sprint = empty AND Status in [Backlog, Ready] AND Assignees ∈ `current_team.members` (if `current_team` is set)
2. Build topological sort by Blocked By chains
3. Sort within groups: Backlog Order (ascending) → Priority → Complexity Score (descending)
4. Display numbered list:

```
[Product Backlog] <N> tasks

#  | Title                        | Priority | Score | Executor    | Blocked By
---|------------------------------|----------|-------|-------------|----------
1  | Implement OAuth login        | Urgent   | 8     | claude-code | —
2  | Add rate limiting            | High     | 3     | claude-code | —
3  | Write onboarding docs        | Medium   | 2     | human       | 🔒 #1
4  | Dashboard perf fix           | Medium   | 3     | claude-code | —
```

🔒 = blocked by another backlog task (shows dependency)

---

## Action: Suggest Backlog Order

**Triggered by**: "suggest backlog order", "reorder backlog", "reprioritize"

1. Fetch all backlog tasks (Sprint = empty) where Assignees ∈ `current_team.members` (if `current_team` is set)
2. Compute optimal order:
   - Topological sort (dependency-first)
   - Within same tier: Urgent > High > Medium > Low
   - Within same priority: higher Complexity Score first (more valuable)
3. Propose the new order as a numbered list
4. On approval, bulk-update Backlog Order: 1000, 2000, 3000...

---

## Action: Move Task in Backlog

**Triggered by**: "move task X before Y"

1. Identify tasks X and Y
2. Set X's Backlog Order = Y's Backlog Order - 500
3. Re-normalize all backlog tasks to 1000, 2000, 3000... (maintaining relative order)
4. Update via `notion-update-page`

---

## Action: Add Task to Sprint

**Triggered by**: "add to sprint"

1. Identify the task and Active sprint
2. Set the task's Sprint field to the Active sprint
3. Report confirmation

---

## "Next Task"

For "what should I do next?" or "next task", direct the user to `/managing-tasks`.
Sprint-aware Next Task logic is consolidated in the managing-tasks skill.

---

## After Operations

After any data modification, push fresh data to the view server:

```bash
# Silently skip if server is not running
curl -s http://localhost:3456/api/health -o /dev/null 2>/dev/null && {
  curl -s -X POST http://localhost:3456/api/data \
    -H "Content-Type: application/json" -d '<tasks_json>' -o /dev/null 2>/dev/null
  curl -s -X POST http://localhost:3456/api/sprint-data \
    -H "Content-Type: application/json" -d '<sprints_json>' -o /dev/null 2>/dev/null
} || true
```

Tasks JSON format: `{ "tasks": [...], "updatedAt": "<ISO>" }`
Sprints JSON format: `{ "sprints": [...], "currentSprintId": "<ID>|null", "updatedAt": "<ISO>" }`

Each sprint object:
```json
{
  "id": "...",
  "name": "Sprint 1",
  "goal": "Implement OAuth and API rate limiting",
  "status": "Active",
  "maxConcurrentAgents": 3,
  "velocity": null,
  "url": "https://notion.so/..."
}
```

Each task object must include sprint fields:
```json
{
  "sprintId": "<sprint_id_or_null>",
  "sprintName": "<sprint_name_or_null>",
  "complexityScore": 5,
  "backlogOrder": 1000
}
```

Silently skip if server is not running.

## Language

Always communicate with the user in the language they are using.
