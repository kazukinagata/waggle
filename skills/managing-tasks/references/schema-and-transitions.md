# Task Schema and State Transitions

## Schema: Property Name → Notion Type

### Core Fields (15 required — verify existence at session start)

| Property | Type | Notes |
|---|---|---|
| Title | title | Task name |
| Description | rich_text | Orchestrator-written detail |
| Acceptance Criteria | rich_text | Verifiable completion conditions |
| Status | select | Backlog / Ready / In Progress / In Review / Done / Blocked |
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

### Extended Fields (optional — graceful degradation if absent)

| Property | Type | Notes |
|---|---|---|
| Context | rich_text | Background info, constraints |
| Artifacts | rich_text | PR URLs, file paths (newline-separated) |
| Repository | url | GitHub repository URL |
| Due Date | date | ISO format |
| Tags | multi_select | Free tags |
| Parent Task | relation | Self-relation (hierarchy) |
| Assignees | people | Human executor assignment |
| Branch | rich_text | Git branch name (e.g. feature/task-slug). Leave blank to work on the current branch |

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

Before executing any status transition, run the validation script:

```bash
# Write the canonical task JSON to a temp file (see validating-fields SKILL.md for format)
echo '<canonical_json>' > /tmp/task_validate.json
bash ${CLAUDE_PLUGIN_ROOT}/skills/validating-fields/scripts/validate-task-fields.sh \
  "<target_status>" /tmp/task_validate.json
```

1. Fetch the full task object and construct the canonical validation JSON (see `${CLAUDE_PLUGIN_ROOT}/skills/validating-fields/SKILL.md` for the Construction Guide)
2. Run the script with the target status
3. Parse the JSON output:
   - If `valid: false`: present each error to the user and **block the transition**
   - If warnings exist: present them but allow the user to proceed
4. Only execute the status update after validation passes

**Never skip validation.** This is a deterministic check, not an LLM judgment call.
