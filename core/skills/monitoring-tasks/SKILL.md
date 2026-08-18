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

You are performing a health check on tasks in the configured data source. This skill analyzes 5 dimensions: task age, field quality, blocked tasks, executor ratio, and acknowledgment status.

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

## Step 1: Determine Monitoring Scope

Determine the target based on the user's request:

| User Request | Mode | Target |
|---|---|---|
| Mentions a person's name (e.g., "yagishitaryoma's tasks") | `user` | Resolve via `looking-up-members` |
| Says "all tasks", "team", "overall" | `all` | No assignee filter |
| No target specified | `user` | `current_user` |

For **mode=user** with a name, invoke the `looking-up-members` skill to resolve the name to a user ID. If ambiguous, ask the user to clarify.

Store the result as:
- `target_mode`: "user" or "all"
- `target_id`: user UUID (only for mode=user)
- `target_name`: display name (or "All" for mode=all)

## Step 2: Fetch Task Data

Two queries are needed. Use the Query Path Detection from the provider SKILL.md (loaded in Session Bootstrap) to execute each query. The provider determines the optimal query mechanism.

### Query A: Target Tasks

**mode=user** — all tasks assigned to the target user (all statuses). Filter by Assignee containing `target_id`.

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
bash "${CLAUDE_SKILL_DIR}/scripts/analyze-tasks.sh" \
  "<target_mode>" "<target_id>" "<target_name>" \
  /tmp/monitor_tasks.json /tmp/monitor_blocked.json
```

The script outputs a JSON object with 6 sections: `age`, `quality`, `blocked`, `executor_ratio`, `acknowledgment`, and `quality_debt`. Parse this output and render the report as described in Step 4.

### Inline analysis (fallback)

If the analysis script is not available (no bash, no jq), compute the metrics manually from the fetched data:

1. **Age**: For each task, compute `(today - created_time)` in days. Group by status, calculate count/avg/min/max. Find the top 10 non-Done tasks by age.

2. **Quality**: For each status, check field completeness:
   - **Ready / In Progress**: Description, Acceptance Criteria, Execution Plan, Assignee, Issuer should be filled. In Progress also needs Executor.
   - **Backlog**: Description should be filled.
   - **All statuses**: Issuer should be filled (identifies task origin/owner). Flag tasks with empty Issuer.
   - Report fill rates as percentages (including `issuer_pct`). List tasks missing required fields.

3. **Blocked**: List all Blocked tasks (from Query B) with assignee names, priority, and age. Sort by age descending.

4. **Executor Ratio**: Count tasks by executor value (human, cli, claude-desktop, cowork, unset) across three slices: all tasks, Done only, non-Done only.

5. **Acknowledgment Status**: Find tasks where `Acknowledged At` is null AND `Assignee` is non-empty AND `Issuer` person IDs do not overlap with `Assignee` person IDs (i.e., assigned by someone else and not yet seen). List with title, assignee name, issuer name, and days since task creation.

6. **Quality Debt**: All categories are deterministic and structural — no LLM call and no semantic judgment in default monitoring (v3.0.0: the keyword-heuristic categories SHALLOW_AC / SHALLOW_EP_STEPS / MISSING_CONCRETE_ARTIFACT_EP were removed with Layer 1's semantic rules; semantic quality debt surfaces through the Ready Health Score and the `--deep` Reviewer batch instead). The optional `--deep` flag (see Step 5) escalates to a live Reviewer batch.

   **Always evaluated (structural / deterministic):**
   - **DRAFT placeholders**: Tasks whose AC or EP contains a reserved placeholder AND status is not Blocked / Done / Cancelled. (Recognized placeholders: `[DRAFT-AC]`, `[DRAFT-EP]`, `[NEEDS-REFINE]`.)
   - **EMPTY_AC_READY_PLUS**: Status ∈ {Ready, In Progress, In Review} AND Acceptance Criteria is empty.
   - **EMPTY_EP_READY_PLUS**: Status ∈ {Ready, In Progress, In Review} AND Execution Plan is empty.
   - **STUB_INGEST_AGED**: Tasks tagged `ingesting-messages` or `stub-import` that have been Backlog for ≥3 days.
   - **LIKELY_NON_TASK**: Title regex matches `(MTG|定例|参加|meetup|meeting)` AND Description is <100 characters AND AC is empty AND EP is empty. These look like calendar reminders that escaped Layer 0 (e.g., manually created via Notion UI before v2.8.0 or by a user who skipped the worthiness prompt). Surface for batch archival.
   - **Priority missing**: Non-Done / non-Cancelled tasks without a Priority set.
   - **Test tasks**: Titles matching placeholder patterns (`test task — delete me`, `delete me`, `wip delete`, bare `test task`). These should be cleaned up.

   **Ready Health Score**: `(Ready tasks with cached Reviewer verdict = PASS) / (total Ready tasks)`. Displayed at the top of Section 6 as a single percentage. <70% indicates broad quality debt.

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
Table: Status | Description | AC | Exec Plan | Assignee | Executor
  (show percentages, highlight values below 50% as concerning)
Subsection: Tasks Missing Required Fields (title, status, missing fields)

## 3. Blocked Tasks (All Assignees)
Table: Title | Assignee | Priority | Age (days)
  (sorted by age desc, includes tasks from other assignees)

## 4. Executor Ratio
Table: Executor | All | Done | Active (non-Done)
  (show both counts and percentages)
  Compute AI ratio = (cli + claude-code + claude-desktop + cowork) / total

## 5. Acknowledgment Status
Table: Title | Assignee | Issuer | Unacknowledged Days | Status
  (tasks where Acknowledged At is null, assigned by someone else, sorted by age desc)
  Show count: "N tasks not yet acknowledged by their assignee"

## 6. Quality Debt
**Ready Health Score**: {pct}% (Ready tasks with cached Reviewer PASS / total Ready)

### DRAFT placeholders ({count})
Table: Title | Status | Age (days) | AC/EP Preview
  (tasks where AC or EP contains [DRAFT-AC] / [DRAFT-EP] / [NEEDS-REFINE] and status is not Blocked / Done / Cancelled)

### EMPTY_AC_READY_PLUS ({count})
Table: Title | Status | Age (days)
  (Status in {Ready, In Progress, In Review} with empty Acceptance Criteria)

### EMPTY_EP_READY_PLUS ({count})
Table: Title | Status | Age (days)
  (Status in {Ready, In Progress, In Review} with empty Execution Plan)

### STUB_INGEST_AGED ({count})
Table: Title | Tags | Age in Backlog (days)
  (tagged ingesting-messages or stub-import, Backlog ≥3 days)

### LIKELY_NON_TASK ({count})
Table: Title | Status | Age (days)
  (title regex match + <100 char description + empty AC + empty EP — calendar-like leakage)

### Priority Missing ({count})
Table: Title | Status | Age (days)
  (non-Done / non-Cancelled tasks without a Priority set)

### Test Tasks ({count})
Table: Title | Status | ID
  (titles matching test-task placeholder patterns — suggest cleanup)

### 🚀 Quick Action
If any of the above counts are > 0, include copy-paste-ready commands that
batch-invoke the relevant remediation skill:

    Invoke the `planning-tasks` skill in batch mode for: <id1>, <id2>, ...
    Invoke the `managing-tasks` skill to archive: <likely_non_task_ids>

Also emit an emphasized banner when DRAFT or EMPTY_*_READY_PLUS counts have remained
stagnant for 2+ weeks:

    ⚠️ Quality debt has been stagnant for 2+ weeks. Consider running the
    batch planning command above.

(Historical comparison is a future enhancement; for now the banner is
based on the caller's judgment.)

### --deep mode (v2.8.0+, opt-in, default OFF)

If the user invokes `/monitoring-tasks --deep`, additionally batch-invoke the
`reviewing-quality` skill in live cache-aware mode for all Ready+ tasks. Most
tasks return from cache (PASS); only tasks with empty / stale cache pay the
live Reviewer cost. Display the resulting Reviewer verdicts in an additional
section "Reviewer-flagged tasks" with the same Quick Action remediation
commands. Default `monitoring-tasks` invocation does NOT invoke the Reviewer
(no LLM cost, no latency).

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
- **Unacknowledged tasks**: Tasks not seen by assignee for 2+ days — suggest sending a reminder or Slack notification
- **Quality debt (retroactive)**: If the DRAFT AC count or Priority missing count is non-zero, surface the copy-paste command shown in section 6 so the user can run `planning-tasks` in batch. Keep this a user-initiated suggestion — do not auto-dispatch, to avoid bulk side-effects.
- **Test task cleanup**: If test tasks are detected, list them and ask the user to cancel or delete them.
