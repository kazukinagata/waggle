# Task Schema and State Transitions

## Schema: Property Name → Notion Type

### Core Fields (16 required — verify existence at session start)

| Property | Type | Notes |
|---|---|---|
| Title | title | Task name |
| Description | rich_text | Orchestrator-written detail |
| Acceptance Criteria | rich_text | Verifiable completion conditions |
| Status | select | Backlog / Ready / In Progress / In Review / Done / Blocked / Cancelled |
| Blocked By | relation | Self-relation (dependency). Empty or all blockers Done = actionable |
| Priority | select | Urgent / High / Medium / Low |
| Executor | select | cli / claude-desktop / cowork / human |
| Requires Review | checkbox | On → must pass In Review. Off → can go directly to Done |
| Execution Plan | rich_text | Orchestrator's plan written before dispatch. write-once |
| Working Directory | rich_text | Absolute path to the working directory |
| Session Reference | rich_text | Written after dispatch: tmux session name / Scheduled task ID |
| Dispatched At | date | Dispatch timestamp. Used for timeout detection |
| Agent Output | rich_text | Execution result |
| Error Message | rich_text | Written on failure only. Query with "Error Message is not empty" |
| Issuer | people | Who created/initiated this task. Auto-populated with current_user. Write-once. |
| Quality Verdict | rich_text | v2.8.0+. Cached Reviewer verdict. Format: `<verdict> hash=<8hex> @<iso> v1 [suppressed-until=<iso>]`. Auto-managed by `reviewing-quality` skill; users do not edit directly. |

### Extended Fields (optional — graceful degradation if absent)

| Property | Type | Notes |
|---|---|---|
| Context | rich_text | Background info, constraints |
| Artifacts | rich_text | PR URLs, file paths (newline-separated) |
| Repository | url | GitHub repository URL |
| Due Date | date | ISO format |
| Tags | multi_select | Free tags |
| Parent Task | relation | Self-relation (hierarchy) |
| Assignee | people | Human executor assignment |
| Branch | rich_text | Git branch name (e.g. feature/task-slug). Leave blank to work on the current branch |
| Acknowledged At | date | ISO timestamp — when the assignee first saw this task. Auto-set by skills, reset on re-delegation. |

## State Transition Rules

Valid transitions:
- Backlog → Ready
- Ready → In Progress (when dispatched to executor)
- In Progress → In Review (when `Requires Review` is checked and work is done)
- In Progress → Done (when `Requires Review` is unchecked and work is done)
- In Progress → Blocked (when blocked by another task or error)
- In Review → Done (when review approved)
- In Review → In Progress (when changes requested)
- Any → Backlog (deprioritize)
- Any → Cancelled (task abandoned or no longer relevant)

**When `Requires Review` is Off**, skip In Review and transition directly to Done.
**When writing errors**, set Status to Blocked and write the error message in `Error Message` (not in Agent Output).

### Auto-Cascading Transitions (Subtask Hierarchy)

These transitions are system-initiated and bypass normal validation:

| Trigger | Parent Transition | Condition |
|---|---|---|
| Subtask marked Done | Parent → **Done** (auto) | All subtasks of the parent have Status = Done |
| Subtask added to Done parent | Parent → **In Progress** (auto) | New subtask created with parentTask pointing to a Done parent |
| Subtask re-opened (Done → other) | Parent → **In Progress** (auto) | Parent's current Status is Done |

Auto-cascading appends a log entry to the parent's Context field (e.g., `[Auto] Status set to Done — all subtasks completed`).

### Deterministic Validation (hard gate)

Before executing any status transition, invoke the `validating-fields` skill. Pass the full task object and the target status (e.g., `"Ready"`, `"In Progress"`, `"Done"`). The skill handles canonical JSON construction internally and returns `{valid, errors, warnings}`.

1. Fetch the full task object from the active provider
2. Invoke the `validating-fields` skill with the task and the target status
3. Parse the result:
   - If `valid: false`: present each error to the user and **block the transition**
   - If warnings exist: present them but allow the user to proceed
4. Only execute the status update after validation passes

**Never skip validation.** This is a deterministic check, not an LLM judgment call.

### Quality Gate (Backlog → Ready, v2.8.0+)

In addition to the Rubric gate above, the Backlog → Ready transition consults the Reviewer verdict via the `reviewing-quality` skill in **cache-only** mode. (Pre-Ready is a hot path — `managing-tasks` must not block on a live LLM call.)

1. Skip-path: if the task's `Tags` contain `worthiness:calendar-like` or `worthiness:info-only`, the Reviewer is skipped entirely. Only the Rubric R-AC4 (no `[DRAFT-*]` placeholder) applies.
2. Otherwise, invoke `reviewing-quality` in `cache-only` mode. The skill reads the `Quality Verdict` cache and returns one of:
   - `PASS` → proceed with the Ready transition.
   - `NEEDS_REFINEMENT` / `REJECT` → present the cached gaps + suggested fixes; ask the user `[Refine via /planning-tasks] [Save anyway]`. On "Save anyway", the task is marked `[NEEDS-REFINE]` and the transition proceeds at the user's risk.
   - `UNREVIEWED` (cache miss) → ask the user `[Refine via /planning-tasks] [Save anyway]` with no verdict context. On "Save anyway", proceed.

The user can always override; pre-Ready is advisory, not enforcing. The protocol-level dispatch gate (in `executing-tasks`) and the daily Step 2.5 catch-net provide additional safety for tasks that slip through here.
