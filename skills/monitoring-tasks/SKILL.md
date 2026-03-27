---
name: monitoring-tasks
description: >
  Performs a health check on tasks. Analyzes task age (stagnation),
  field completeness by status, blocked tasks (including other assignees' blockers),
  and executor ratio (human vs AI delegation).
  Supports 3 modes: specific assignee (by name), all tasks (team-wide overview),
  or defaults to current user when no target is specified.
  Use this skill whenever the user wants to monitor task health, check stagnation,
  audit task quality, or review AI delegation metrics — even if they don't say "monitor" explicitly.
  Triggers on: "monitor tasks", "task health check", "task analysis", "stagnation report",
  "task monitoring", "task report"
user-invocable: true
---

# Waggle — Task Monitoring

You are performing a health check on tasks in the configured data source. This skill analyzes 4 dimensions: task age, field quality, blocked tasks, and executor ratio.

## Step 0: Session Bootstrap

Load `${CLAUDE_PLUGIN_ROOT}/skills/bootstrap-session/SKILL.md` and follow its instructions.
Skip if `active_provider` and `current_user` are already set in this conversation.

## Step 1: Determine Monitoring Scope

Determine the target based on the user's request:

| User Request | Mode | Target |
|---|---|---|
| Mentions a person's name (e.g., "yagishitaryoma's tasks") | `user` | Resolve via `looking-up-members` |
| Says "all tasks", "team", "overall" | `all` | No assignee filter |
| No target specified | `user` | `current_user` |

For **mode=user** with a name, load `${CLAUDE_PLUGIN_ROOT}/skills/looking-up-members/SKILL.md` to resolve the name to a user ID. If ambiguous, ask the user to clarify.

Store the result as:
- `target_mode`: "user" or "all"
- `target_id`: user UUID (only for mode=user)
- `target_name`: display name (or "All" for mode=all)

## Step 2: Fetch Task Data

Two queries are needed. Use the Query Path Detection from the provider SKILL.md (loaded in Session Bootstrap) to execute each query. The provider determines the optimal query mechanism.

### Query A: Target Tasks

**mode=user** — all tasks assigned to the target user (all statuses). Filter by Assignees containing `target_id`.

**mode=all** — all tasks (no filter).

### Query B: All Blocked Tasks

All tasks with Status = Blocked, regardless of assignee. This captures blockers assigned to other people that may affect the target user's workflow.

### Execution

Use the provider's query mechanism (determined by Query Path Detection) to execute both queries. Save results to temp files:
- `/tmp/monitor_tasks.json` — Query A results
- `/tmp/monitor_blocked.json` — Query B results

Both files should be in the provider's native format (e.g., `{"results": [...]}` for Notion).

## Step 3: Run Analysis

### Script-based analysis (preferred)

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/monitoring-tasks/scripts/analyze-tasks.sh \
  "<target_mode>" "<target_id>" "<target_name>" \
  /tmp/monitor_tasks.json /tmp/monitor_blocked.json
```

The script outputs a JSON object with 4 sections: `age`, `quality`, `blocked`, `executor_ratio`. Parse this output and render the report as described in Step 5.

### Inline analysis (fallback)

If the analysis script is not available (no bash, no jq), compute the metrics manually from the fetched data:

1. **Age**: For each task, compute `(today - created_time)` in days. Group by status, calculate count/avg/min/max. Find the top 10 non-Done tasks by age.

2. **Quality**: For each status, check field completeness:
   - **Ready / In Progress**: Description, Acceptance Criteria, Execution Plan, Assignees, Issuer should be filled. In Progress also needs Executor.
   - **Backlog**: Description should be filled.
   - **All statuses**: Issuer should be filled (identifies task origin/owner). Flag tasks with empty Issuer.
   - Report fill rates as percentages (including `issuer_pct`). List tasks missing required fields.

3. **Blocked**: List all Blocked tasks (from Query B) with assignee names, priority, and age. Sort by age descending.

4. **Executor Ratio**: Count tasks by executor value (human, cli, claude-desktop, cowork, unset) across three slices: all tasks, Done only, non-Done only.

## Step 4: Render Report

Format the analysis results as a markdown report. Respond in the user's language.

### Report Structure

```
# Task Health Report — {target_name}
_Generated: {date} | Total: {n} tasks_

## 1. Task Age
Table: Status | Count | Avg Days | Min | Max
Subsection: Top 10 Stagnating Tasks (non-Done, sorted by age desc)

## 2. Task Quality
Table: Status | Description | AC | Exec Plan | Assignees | Executor
  (show percentages, highlight values below 50% as concerning)
Subsection: Tasks Missing Required Fields (title, status, missing fields)

## 3. Blocked Tasks (All Assignees)
Table: Title | Assignee | Priority | Age (days)
  (sorted by age desc, includes tasks from other assignees)

## 4. Executor Ratio
Table: Executor | All | Done | Active (non-Done)
  (show both counts and percentages)
  Compute AI ratio = (cli + claude-desktop + cowork) / total

## Recommendations
```

### 5. Hierarchy Health

Detect parent/subtask status inconsistencies:

- **Stale parents**: Parent tasks where all subtasks are Done but the parent is not Done (cascading may have failed)
- **Orphaned Done parents**: Parent tasks marked Done that have non-Done subtasks (inconsistent state)
- **Deep nesting violations**: Any task whose parent also has a parent (3+ level — should not exist if validation is working)

Report as a table: Title | Issue | Parent/Subtask | Suggested Fix

### Recommendations Guidelines

Generate 3-5 actionable recommendations based on findings. Focus on:

- **Stagnation**: Tasks sitting in Ready/Backlog for 7+ days without progress
- **Quality gaps**: Statuses where Acceptance Criteria or Execution Plan fill rates are below 50%
- **Blocked accumulation**: Blocked tasks older than 5 days, especially those blocking the target user
- **AI delegation opportunity**: If human executor ratio is above 70%, suggest reviewing Ready tasks for AI-executable candidates
- **Unset executors**: Tasks in Ready/In Progress without an Executor assigned
