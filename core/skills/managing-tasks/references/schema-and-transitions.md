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
| Quality Verdict | rich_text | v2.8.0+. Cached Reviewer verdict. Current format: `<verdict> hash=<8hex> @<iso> v2`. `v1` is the legacy format — never written any more, still accepted for dispatch during the migration window (see the Quality Gate section below). Some lines carry a retired `suppressed-until` trailing key, ignored. Auto-managed by the `reviewing-quality` skill; users do not edit directly. |

### Extended Fields (optional — graceful degradation if absent)

| Property | Type | Notes |
|---|---|---|
| Context | rich_text | Background info, constraints |
| Artifacts | rich_text | PR URLs, file paths (newline-separated) |
| Repository | url | GitHub repository URL |
| Start Date | date | ISO format — planned work start |
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

### Verdict Carry-Forward on Ready+ transitions (v2.8.x+)

Any transition **into** a Ready+ status (`Ready` / `In Progress` / `In Review` / `Done`) must write the task's `Quality Verdict` in the **same** `update_properties` payload that sets the new Status. A write that promotes to a Ready+ status without a valid verdict is rejected before it reaches the provider.

- **Backlog → Ready** — the verdict is produced/looked up by the Quality Gate below; see that section.
- **Ready → In Progress / In Review / Done** (incl. "mark done", and the system-initiated auto-cascading transitions above) — the task already has a verdict on its page from when it became Ready. Carry it forward: read the current `Quality Verdict` field value and include that exact string in the Status-change payload. This is a one-line echo, not a re-review. (If the field is somehow empty — a legacy or UI-edited task — obtain one first via the Backlog→Ready Quality Gate procedure below, then transition.)

### Quality Gate (Backlog → Ready, v2.8.0+)

In addition to the Layer 1 structural gate above, the Backlog → Ready transition consults the Reviewer verdict via the `reviewing-quality` skill in **cache-only** mode. (Pre-Ready is a hot path — `managing-tasks` must not block on a live LLM call.)

1. Skip-path: if the task's `Tags` contain `worthiness:calendar-like` or `worthiness:info-only`, the Reviewer is skipped entirely. Only the reserved-placeholder check (no `[DRAFT-*]` / `[NEEDS-REFINE]` / `[INFERRED]` remaining) applies. `reviewing-quality` still returns a `verdict_string` (a worthiness-skip `PASS`) — carry it into the promotion write per the atomic rule below.
2. Otherwise, invoke `reviewing-quality` in `cache-only` mode. The skill reads the `Quality Verdict` cache and returns one of:
   - `PASS` → proceed with the Ready transition.
   - `NEEDS_REFINEMENT` / `REJECT` → present the cached gaps + suggested fixes (returned in the payload's `gaps` / `fixes`, sourced from the persisted findings block on the task's `Context` field; if absent or stale, fall back to showing the verdict alone and note that the detailed findings were not persisted); ask the user `[Refine via /planning-tasks] [Save anyway]`. **"Save anyway" means the task stays at Backlog** — it is marked `[NEEDS-REFINE]`, the `verdict_string` and the findings block are written, and the Status is not changed. It does **not** promote to Ready.
   - `UNREVIEWED` (cache miss) → there is no verdict to promote with. Re-invoke `reviewing-quality` in `live` mode to compute a real verdict for this task, then branch on the live result exactly as PASS / NEEDS_REFINEMENT / REJECT above. (Cache miss is rare on the pre-Ready hot path — most tasks were reviewed upstream — so the occasional live cost is acceptable, and it is required because a task cannot enter Ready with no verdict.)

**Atomic promotion (required).** The provider write that sets `Status = Ready` **must include the `Quality Verdict` property set to the `verdict_string` returned by `reviewing-quality`, in the same update_properties payload.** Do not set Status=Ready in a write that omits the verdict — such a write is rejected before it reaches the provider. **That verdict must be a current `v2` PASS**: a non-PASS verdict cannot accompany a promotion to Ready, because there is no promotion to Ready to accompany. A non-PASS outcome leaves the task at Backlog with the verdict and the findings block written there (see the branch above), so the atomic write in that case sets no new Status at all.

**Ready requires PASS (v4.0.0).** There is no override that reaches Ready with a non-PASS verdict. Earlier documentation described a "Save anyway" that promoted anyway, and that override never worked: Layer 1 rejects any supplied non-PASS verdict at Ready and above, and downstream deterministic guards deny it too. The documentation was wrong, not the enforcement. Resolved in favour of the structural rule, because it is what `Ready` means — an executor can start without asking back, and a spec the reviewer would not pass does not support that claim.

So the user's real choices at a non-PASS verdict are: refine until it passes, or leave the task at Backlog with the findings block attached. Backlog is a valid resting place, not a dead end. What the user *can* still override is whether to keep working on it now; what they cannot do is relabel an unreviewed spec as Ready.

The protocol-level dispatch gate (in `executing-tasks`) and the daily Step 2.6 catch-net provide additional safety for tasks that slip through here.
