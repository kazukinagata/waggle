---
name: validating-fields
description: >
  Deterministic field validation for task status transitions.
  Returns pass/fail with errors and warnings as JSON.
  Used by managing-tasks, executing-tasks, and running-daily-tasks.
user-invocable: false
---

# Validating Fields

This shared skill provides a deterministic bash+jq validation script for task status transitions.
It enforces required fields as hard-block errors and recommends optional fields as warnings.

## Usage

```bash
# Write the canonical task JSON to a temp file
echo '<canonical_json>' > /tmp/task_validate.json
bash ${CLAUDE_PLUGIN_ROOT}/skills/validating-fields/scripts/validate-task-fields.sh \
  <target_status> /tmp/task_validate.json
```

- `target_status`: The status being transitioned TO (e.g., `Ready`, `In Progress`, `Blocked`, `Done`, `Cancelled`)
- `task_json_file`: Path to a JSON file in the **canonical flat format** (see below)

## Canonical Input Format

The validation script is **provider-agnostic**. Before calling it, construct a flat JSON object from whatever provider-specific format the task data is in:

```json
{
  "description": "Full task description text",
  "acceptanceCriteria": "Verifiable completion conditions",
  "executionPlan": "Step-by-step plan",
  "issuer": true,
  "assigneeCount": 1,
  "priority": "High",
  "executor": "cli",
  "workingDirectory": "/absolute/path",
  "branch": "feature-x",
  "agentOutput": "Execution result",
  "errorMessage": "Error details",
  "createdAt": "2026-04-15T10:00:00.000Z",
  "repository": "https://github.com/org/repo"
}
```

`createdAt` is used for legacy grandfathering of the Agent Output rule on Done transitions. `repository` is optional and enables repository-aware warnings when code tasks reach Ready without a working directory.

### Construction Guide

**From Notion page object:**
```
description      <- .properties.Description.rich_text | map(.plain_text) | join("")
acceptanceCriteria <- .properties["Acceptance Criteria"].rich_text | map(.plain_text) | join("")
executionPlan    <- .properties["Execution Plan"].rich_text | map(.plain_text) | join("")
issuer           <- (.properties.Issuer.people | length) > 0
assigneeCount   <- .properties.Assignee.people | length
priority         <- .properties.Priority.select.name
executor         <- .properties.Executor.select.name
workingDirectory <- .properties["Working Directory"].rich_text | map(.plain_text) | join("")
branch           <- .properties.Branch.rich_text | map(.plain_text) | join("")
agentOutput      <- .properties["Agent Output"].rich_text | map(.plain_text) | join("")
errorMessage     <- .properties["Error Message"].rich_text | map(.plain_text) | join("")
createdAt        <- .created_time
repository       <- .properties.Repository.url // ""
```

**From SQLite/Turso row:**
```
description      <- .description
acceptanceCriteria <- .acceptance_criteria
executionPlan    <- .execution_plan
issuer           <- (.issuer | length) > 0
assigneeCount   <- (.assignee | fromjson | length)
priority         <- .priority
executor         <- .executor
workingDirectory <- .working_directory
branch           <- .branch
agentOutput      <- .agent_output
errorMessage     <- .error_message
createdAt        <- .created_at
repository       <- .repository
```

## Output

```json
{
  "valid": true,
  "target_status": "Ready",
  "errors": [],
  "warnings": [
    {"field": "Issuer", "rule": "recommended", "message": "Issuer is empty. Consider setting it manually."}
  ]
}
```

- `valid: false` -> block the transition, present errors to user
- `valid: true` with warnings -> allow proceeding, present warnings to user
- Exit code is always 0 -- check `.valid` in the JSON output

## Validation Rules

| Target Status | Required (errors) | Recommended (warnings) |
|---|---|---|
| **Ready** | Description (non-empty, >=50 chars), AC (non-empty + semantic check), Execution Plan (non-empty) | Issuer (non-empty), Assignee (non-empty), Priority (set) |
| **In Progress** | All Ready requirements + Executor (set), Working Directory (non-empty for AI executors) | Issuer, Branch (for cli executor) |
| **Blocked** | Description (non-empty), AC (non-empty) | Issuer, Error Message |
| **Done** | Description (non-empty), Agent Output (non-empty for AI executors on new tasks) | Agent Output (legacy tasks — created before the enforcement date — keep warning-only) |
| **Cancelled** | Description (non-empty) | — |

**Issuer is always a warning**, never an error -- ensures backward compatibility with pre-migration tasks.

### Agent Output on Done (Legacy Grandfathering)

Agent Output is required for AI executor tasks (cli / claude-code / claude-desktop / cowork) transitioning to Done. The requirement is enforced via a `createdAt` cutoff:

- Tasks with `createdAt` on or after the cutoff date: empty Agent Output → hard error (blocks the transition)
- Tasks with `createdAt` before the cutoff date: empty Agent Output → warning only (does not block)

This prevents retroactive invalidation of historical Done tasks while still enforcing the rule going forward. Human-executor tasks are never required to have Agent Output.

The cutoff date is hardcoded in `scripts/validate-task-fields.sh` as `$agent_output_required_from`. Update it only when introducing a similar migration — otherwise keep it stable.

## Semantic AC Check

AC text is scanned for at least one verifiable condition indicator:
- **Command**: `npm`, `curl`, `git`, `python`, `bash`, `test`, `run`, `build`, `deploy`
- **File path**: contains `/` or common extensions (`.ts`, `.js`, `.py`, `.md`, `.html`, `.css`)
- **Numeric threshold**: digits followed by `%`, `ms`, `s`, `count`, `times`, `items`
- **Explicit state**: `returns`, `displays`, `creates`, `exists`, `passes`, `fails`, `contains`, `shows`, `generates`, `sends`, `receives`, `confirms`, `records`, `updates`

If none found -> error: "AC lacks verifiable conditions. Include commands, file paths, metrics, or observable outcomes."

This is a heuristic backstop, not a perfect quality gate. It catches worst-case garbage but not subtle gaps.

## Hierarchy Validation

These checks apply when `parentTask` is being set or a subtask is being created. They are **separate from status-transition validation** and must be checked by the caller (managing-tasks) before writing to the data source.

### Rule 1: No 3+ Level Nesting

Before setting `parentTask` on task X to task Y, the caller MUST fetch task Y and verify that Y's own `parentTask` is null. If Y is already a subtask, reject with:

> "Cannot create a 3rd-level subtask. Task '{Y.title}' is already a subtask of another task."

### Rule 2: No Children on Subtasks

Before setting `parentTask` on task X to task Y, the caller MUST query whether any tasks have `parentTask = X` (i.e., X already has children). If X has children, reject with:

> "Task '{X.title}' already has subtasks. A task with subtasks cannot itself become a subtask (2-level limit)."

This check is also enforced as a defense-in-depth in the validation script via the `hasChildren` field.

### Rule 3: No Self-Reference

A task cannot reference itself as its own parent. If `parentTask = X.id` on task X, reject with:

> "A task cannot be its own parent."

### Script-Level Defense (hasChildren)

The validation script accepts an optional `hasChildren` boolean in the canonical input JSON. If `parentTaskId` is non-null and `hasChildren` is true, the script emits an error. This catches the case where a caller bypasses the managing-tasks pre-check.
