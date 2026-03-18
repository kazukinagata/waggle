---
name: analyzing-sprint-metrics
description: >
  Analyzes sprint performance metrics and generates retrospective insights
  from task data. Produces throughput, agent performance, and dependency reports.
  Triggers on: "sprint metrics", "retrospective", "retro", "agent performance",
  "スプリントメトリクス", "振り返り", "レトロ".
---

# Agentic Tasks — Sprint Metrics

Automated agent performance analysis derived from Notion task data. Replaces human retrospective with quantitative metrics.

## Provider Detection + Config + Identity (once per session)

1. Load `${CLAUDE_PLUGIN_ROOT}/skills/detecting-provider/SKILL.md` and follow its instructions to determine `active_provider` and retrieve `headless_config`. Skip if already set.
2. Load `${CLAUDE_PLUGIN_ROOT}/skills/resolving-identity/SKILL.md` and resolve `current_user` + `current_team`. Skip if already set.

If `headless_config.sprintsDatabaseId` is missing, tell the user to run "set up scrum" first.

## Step 1: Identify Target Sprint

If the user specified a sprint name, find it in `headless_config.sprintsDatabaseId` where `Team = current_team.id` (if `current_team` is set).
Otherwise, use AskUserQuestion: "Which sprint's metrics would you like to view? (Default: latest Closed sprint)"
If no Closed sprint exists, use the most recent Completed sprint.
When listing sprint candidates, filter by `Team = current_team.id` if `current_team` is set.

## Step 2: Fetch Sprint and Task Data

1. Fetch the target sprint from the Sprints DB
2. Fetch all tasks with Sprint = <target sprint ID>
3. Parse the Metrics field for existing daily snapshots

## Step 3: Calculate Metrics

### Throughput
- Tasks completed: count of Status = "Done"
- Tasks not completed: count of Status ≠ "Done"
- Completion rate: done_count / total_count × 100%
- Complexity Score completion: sum(done scores) / sum(all scores) × 100%

### Agent Performance
- **Timeout/Stall rate**: tasks where evidence of stall exists in Metrics snapshots / total dispatched tasks
  - Dispatched = tasks that had Status = "In Progress" at any point (Dispatched At is set)
  - Stall = Dispatched At set AND elapsed > Score × stallThresholdMultiplier (see detecting-provider Constants) AND required human intervention (check Agent Output / Error Message for retry indicators)
- **Error rate**: tasks with Error Message not empty / total dispatched
- **Human intervention**: tasks where Agent Output or Error Message mentions "manual", "retry", "human" or Status went Blocked→In Progress
- **Avg cycle time**: for Done tasks with Dispatched At set, estimate from daily Metrics snapshots
  - If no snapshot data, note "Cannot estimate from Dispatched At data"

### Dependency Analysis
- Blocked tasks at sprint start: tasks with Blocked By containing any non-Done task at sprint creation
- Resolved during sprint: blocked tasks that reached Done status
- Bottleneck identification: tasks whose completion unblocked the most other tasks

## Step 4: Display Report

```
[Sprint Metrics Report] <Sprint Name>
Goal: <Goal>

THROUGHPUT:
  Tasks completed:     <N> / <M> (<N>%)
  Complexity Score:    <N> / <M> (<N>%)

AGENT PERFORMANCE:
  Timeout/Stall rate:  <N> / <M> dispatched (<N>%)  [threshold: >30% = warning]
  Error rate:          <N> / <M> dispatched (<N>%)
  Human intervention:  <N> task(s) [<task names if any>]
  Avg cycle time:      <N>h (Score:1-3) / <N>h (Score:5-8)

DEPENDENCY ANALYSIS:
  Blocked tasks at sprint start: <N> / <M> (<N>%)
  Resolved during sprint:        <N> / <N>
  Bottleneck task:               <task name if applicable>

RECOMMENDATIONS:
  <generated recommendations based on data>
```

### Recommendation Rules

Generate recommendations automatically:
- If any task's actual cycle time > Score × (stallThresholdMultiplier × 1.5): "Score estimate may have been too low — <task name>"
- If stall rate > 30%: "High stall rate (>30%) — consider reducing maxConcurrentAgents or narrowing task scope"
- If stall rate < 10%: "Good stall rate (<10%) — maxConcurrentAgents could potentially be increased"
- If blocked tasks > 40% of sprint: "Dependency chains are a bottleneck — prioritize dependency-resolving tasks during sprint planning"
- If error rate > 20%: "High error rate — consider improving Execution Plan quality or splitting tasks"
- If completion rate < 60%: "Low completion rate — consider reducing batch size for the next sprint"
- If completion rate > 90%: "Excellent completion rate — batch size could potentially be increased for the next sprint"

## Step 5: Write to Sprint Metrics Field

Append (or overwrite if doing full retro) the report to the sprint's `Metrics` field via `notion-update-page`.

Format:
```
=== Sprint Metrics Report (<YYYY-MM-DD>) ===
Throughput: <N>/<M> tasks (<N>%)
Velocity: <N> pts
Stall rate: <N>%
Error rate: <N>%
...
```

## Step 6: Next Sprint Recommendations

Output actionable suggestions for the next sprint:
- Adjust `maxConcurrentAgents` (up/down based on stall rate)
- Tasks to re-evaluate Complexity Score
- Dependency ordering improvements for next sprint planning

## Language

Always communicate with the user in the language they are using.
