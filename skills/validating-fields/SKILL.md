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

In v2.8.0 it also hosts the **Quality Rubric (Layer 1)** — a deterministic AC/EP content check applied at Ready transitions. See `references/quality-rubric.md` for the full rule set. The script itself remains LLM-free; Rubric evaluation is regex/length heuristics only.

## How to Invoke This Skill

Other skills invoke this one via natural language — e.g., "Invoke the `validating-fields` skill to validate the task fields for target status Ready". When the agent receives that instruction, it loads this SKILL.md and follows the steps below.

### Steps

1. Obtain the following from the invoking context:
   - The task data (a Notion page object, a SQLite row, or an already-flat JSON)
   - The target status the task is transitioning TO: `Ready`, `In Progress`, `Blocked`, `Done`, or `Cancelled`

2. Construct a canonical flat JSON from the task data using the **Construction Guide** below. This normalizes provider differences (Notion rich_text arrays vs. SQLite strings) into a single shape the validator understands.

3. Write the canonical JSON to a writable temp file. `/tmp/validate_task.json` is the default; callers on read-only filesystems should pass a writable path instead (e.g., under `${TMPDIR}`).

4. Run the validation script:
   ```bash
   bash ${CLAUDE_SKILL_DIR}/scripts/validate-task-fields.sh <target_status> /tmp/validate_task.json
   ```

5. Parse the JSON output. It always has this shape:
   ```json
   { "valid": true|false, "target_status": "<X>", "errors": [...], "warnings": [...] }
   ```

6. Return the result to the invoking skill's context. The invoking skill decides how to proceed:
   - `valid: false` → do NOT transition status; surface the errors to the user or abort
   - `valid: true` with warnings → transition is allowed; surface the warnings as advisory

### Error handling

- **Script exit code ≠ 0**: Should not happen by design (the script always exits 0 and signals via `valid`), but if it does, treat as a fatal environment error and report it to the caller.
- **`jq` not installed**: The script prints "Error: jq is required" to stderr and exits 1. Treat as an environment setup problem and surface it to the user.
- **Malformed canonical JSON**: The script returns `valid: false` with an `input` field error. Treat as a caller bug — re-check the construction step.
- **`/tmp` not writable**: Pass a writable path instead. The caller owns the temp file location.

This skill is `user-invocable: false` — users do not trigger it directly via slash command. It is invoked by other skills (via natural language) and by developers when running the script manually during testing.

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
| **Ready** | Description (non-empty, >=50 chars), AC (non-empty + semantic check), Execution Plan (non-empty) | Issuer (non-empty), Assignee (non-empty), Priority (set), Working Directory & Repository (for AI code tasks — detected via keyword match) |
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

## Quality Rubric (Layer 1, v2.8.0+)

The Rubric formalizes the previous "semantic AC check" into 4 AC rules + 5 EP rules. See `references/quality-rubric.md` for the canonical definitions:

| Rule | Field | Summary |
|---|---|---|
| R-AC1 | AC | each criterion has ≥1 verifiable indicator (command / path / numeric+unit / observable verb / URL / code token) |
| R-AC2 | AC | criteria are not echo-of-title (token-overlap heuristic) |
| R-AC3 | AC | criteria are grounded in source material or `[INFERRED]` prefixed |
| R-AC4 | AC | no `[DRAFT-AC]` / `[NEEDS-REFINE]` placeholder at Ready+ |
| R-EP1 | EP | 3–7 numbered steps |
| R-EP2 | EP | average step length ≥30 chars, each step has action verb + target |
| R-EP3 | EP | ≥1 concrete artifact (file path / command / branch / URL / PR# / DB query) |
| R-EP4 | EP | when Executor is AI, Working Directory is set and EP paths align with it |
| R-EP5 | EP | no `[DRAFT-EP]` / `[NEEDS-REFINE]` placeholder at Ready+ |

The validation script applies these rules at every Ready (and beyond) transition.

### Worthiness tag skip

Tasks with `Tags` containing `worthiness:calendar-like` or `worthiness:info-only` are exempt from the AC/EP Rubric (R-AC1..R-AC3, R-EP1..R-EP3). R-AC4 (no `[DRAFT-*]` placeholder remaining) still applies. Worthiness-tagged tasks also skip Layer 2 entirely per the protocol Quality Spec.

## `find_quality_debt` (shared API)

When invoked with a list of Ready+ tasks, `validating-fields` can also return a categorized debt report (used by `monitoring-tasks` and `running-daily-tasks` Step 2.6). See `references/quality-rubric.md` for the output shape.

## Code Task Detection

For AI-executor tasks transitioning to Ready, the script emits two warnings if the task looks like code work but has no Working Directory / Repository set:

- The keyword list lives in `config/code-task-keywords.txt` (one keyword per line, `#` for comments)
- Keywords are joined into a single word-boundary regex at load time
- If any of description / AC / execution plan contains a keyword AND the executor is an AI agent AND Working Directory is empty → warn
- Same logic for Repository

These remain warnings (not errors) at Ready; Working Directory becomes a hard error on In Progress. The warning gives the user an earlier nudge.

To adjust what counts as "code work", edit `config/code-task-keywords.txt` without touching the script.

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
