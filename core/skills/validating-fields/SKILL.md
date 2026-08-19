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

It also hosts the protocol's **Layer 1 structural checks** applied at Ready transitions. Layer 1 is structural-only (v3.0.0+): emptiness, length, reserved placeholders, and verdict-line integrity — properties a script decides exactly and language-independently. Semantic quality (verifiability, groundedness) is owned entirely by Layer 2 (`task-quality-reviewer-agent` via `reviewing-quality`). See `references/quality-rubric.md` for the canonical rule set and the history of why semantic heuristics were removed from this layer.

**Silent operation:** This skill runs as an internal step of an invoking skill. Return
results to the invoking flow without user-facing narration — the caller owns all user
communication. Only errors, warnings, and prompts required to proceed may surface directly.

## How to Invoke This Skill

Other skills invoke this one via natural language — e.g., "Invoke the `validating-fields` skill to validate the task fields for target status Ready". When the agent receives that instruction, it loads this SKILL.md and follows the steps below.

### Steps

1. Obtain the following from the invoking context:
   - The task data (a Notion page object, a SQLite row, or an already-flat JSON)
   - The target status the task is transitioning TO: `Ready`, `In Progress`, `Blocked`, `Done`, or `Cancelled`

2. Construct a canonical flat JSON from the task data using the **Construction Guide** below. This normalizes provider differences (Notion rich_text arrays vs. SQLite strings) into a single shape the validator understands.

3. Write the canonical JSON to a writable temp file. `/tmp/validate_task.json` is the default; callers on read-only filesystems should pass a writable path instead (e.g., under `${TMPDIR}`).

4. Run the validation script. The leading eight lines resolve the skill directory for
   the runtime the shell is actually running in — `${CLAUDE_SKILL_DIR}` expands to a
   path in the agent loop's filesystem, which the shell cannot always reach (on Cowork
   the agent loop is native to the host while Bash runs in a separate VM). See the
   `provider-contract` skill for why each clause is required. Resolution and invocation
   MUST stay in the same Bash call — a resolver run in an earlier Bash call does not
   carry over.

   ```bash
   SCRIPT=scripts/validate-task-fields.sh; SKILL_DIR="${CLAUDE_SKILL_DIR}"
   if [ ! -d "$SKILL_DIR" ]; then _S="${PWD%%/mnt/*}"; _R="$_S/mnt/.remote-plugins"
     case "$SKILL_DIR" in */plugin_*) _P="plugin_${SKILL_DIR#*/plugin_}"; SKILL_DIR="$_R/$_P"
       if [ ! -f "$SKILL_DIR/$SCRIPT" ]; then _M=$(find "$_R/${_P%%/*}" -path "*/$SCRIPT" 2>/dev/null)
         [ "$(printf %s "$_M" | grep -c .)" = 1 ] && SKILL_DIR="${_M%/$SCRIPT}"; fi ;;
     esac
   fi
   [ -f "$SKILL_DIR/$SCRIPT" ] || { printf '{"valid": false, "target_status": "%s", "errors": [{"field": "_skill", "rule": "skill_dir_unresolved", "message": "Validation script not found; the skill directory could not be resolved for this shell. Validation was NOT performed."}], "warnings": []}\n' "<target_status>"; exit 0; }
   bash "$SKILL_DIR/$SCRIPT" <target_status> /tmp/validate_task.json
   ```

   The fail-closed branch honours this skill's own contract: exit 0, and the outcome
   carried in the JSON. It emits `valid: false` with a `skill_dir_unresolved` error, so
   a caller that only inspects `.valid` blocks the transition instead of proceeding on a
   check that never ran. **Never reimplement the validation rules in the model when this
   fires** — a hand-rolled validator does not error, it returns `valid: true`, which is
   the silent-wrong-answer this gate exists to prevent. Report that validation was not
   performed.

5. Parse the JSON output. It always has this shape:
   ```json
   { "valid": true|false, "target_status": "<X>", "errors": [...], "warnings": [...] }
   ```

6. Return the result to the invoking skill's context. The invoking skill decides how to proceed:
   - `valid: false` → do NOT transition status; surface the errors to the user or abort
   - `valid: true` with warnings → transition is allowed; surface the warnings as advisory

### Error handling

- **Script exit code ≠ 0**: Should not happen by design (the script always exits 0 and signals via `valid`), but if it does, treat as a fatal environment error and report it to the caller.
- **`skill_dir_unresolved` error in the output**: the validation script could not be located from the shell, so validation was **not performed**. Exit code is still 0 and `valid` is `false`, so a caller checking `.valid` blocks the transition automatically. Report to the user that the gate could not run; do not re-derive the rules in the model to unblock it.
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
  "repository": "https://github.com/org/repo",
  "qualityVerdict": "PASS hash=abc12345 @2026-04-15T10:00:00Z v2"
}
```

`createdAt` is used for legacy grandfathering of the Agent Output rule on Done transitions. `repository` is optional and enables repository-aware warnings when code tasks reach Ready without a working directory. `qualityVerdict` is the task's `Quality Verdict` cache string; when present, Ready / In Progress transitions reject a malformed verdict (a hand-authored or fabricated string whose `hash` is not a real lowercase 8-hex SHA-256 over the normalized review input) or a non-PASS verdict. A **Ready** transition additionally requires format `v2`: a `v1` verdict was produced under the five-axis rubric and so was never evaluated on Fidelity. In Progress and beyond still accept a legacy `v1` PASS during the migration window, because dispatch is cache-only and rejecting `v1` there would strand every already-Ready task. Pass it whenever it is set so a fabricated verdict cannot promote a task past the gate; an absent verdict is a warning, not a hard error (the content-hash match is verified separately by the org-layer hook).

**`qualityVerdict` means "the verdict that will travel in this write", not "the verdict currently stored on the task".** Callers validating a promotion pass the verdict they are about to write. A caller that is *producing* a verdict — running a structural pre-check before spending a Reviewer call — must **omit** the field: the new verdict does not exist yet, and validating the stale one it is about to replace rejects exactly the tasks that most need re-reviewing. A Ready task holding a legacy `v1` PASS could otherwise never be upgraded to `v2`, and a task holding a stale `NEEDS_REFINEMENT` could never be re-reviewed into a PASS.

### Construction Guide

**From Notion page object:**
```
description      <- .properties.Description.rich_text | map(.plain_text) | join("")
acceptanceCriteria <- .properties["Acceptance Criteria"].rich_text | map(.plain_text) | join("")
executionPlan    <- .properties["Execution Plan"].rich_text | map(.plain_text) | join("")
issuer           <- (.properties.Issuer.created_by.id // null) != null   # v2.8.1+: Issuer is created_by type (was .properties.Issuer.people | length > 0 under v2.7.x)
assigneeCount   <- .properties.Assignee.people | length
priority         <- .properties.Priority.select.name
executor         <- .properties.Executor.select.name
workingDirectory <- .properties["Working Directory"].rich_text | map(.plain_text) | join("")
branch           <- .properties.Branch.rich_text | map(.plain_text) | join("")
agentOutput      <- .properties["Agent Output"].rich_text | map(.plain_text) | join("")
errorMessage     <- .properties["Error Message"].rich_text | map(.plain_text) | join("")
createdAt        <- .created_time
repository       <- .properties.Repository.url // ""
qualityVerdict   <- .properties["Quality Verdict"].rich_text | map(.plain_text) | join("")
```

**From SQLite/Turso row:**
```
description      <- .description
acceptanceCriteria <- .acceptance_criteria
executionPlan    <- .execution_plan
issuer           <- (.issuer != null and .issuer != "")   # v2.8.1+: TEXT column populated by provider Create Task template
assigneeCount   <- (.assignee | fromjson | length)
priority         <- .priority
executor         <- .executor
workingDirectory <- .working_directory
branch           <- .branch
agentOutput      <- .agent_output
errorMessage     <- .error_message
createdAt        <- .created_at
repository       <- .repository
qualityVerdict   <- .quality_verdict
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
| **Ready** | Description (non-empty, >=50 chars), AC (non-empty, no reserved placeholder), Execution Plan (non-empty, no reserved placeholder), Quality Verdict (well-formed + PASS *when supplied*) | Issuer (non-empty), Assignee (non-empty), Priority (set), Quality Verdict (fresh PASS present), Working Directory & Repository (for AI code tasks — detected via keyword match) |
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

## Layer 1 Structural Checks (v3.0.0+)

Layer 1 is the deterministic half of the protocol's quality gates. Everything it enforces is listed in the Validation Rules table above; the canonical definition (including the reserved-placeholder rule and the design boundary against semantic keyword heuristics) lives in `references/quality-rubric.md`.

Semantic rules formerly defined at this layer (R-AC1–R-AC3, R-EP1–R-EP4: verifiable-indicator keywords, echo-of-title, step-count/richness, concrete-artifact detection) were removed in v3.0.0 — see the history note in `references/quality-rubric.md`. Do not reintroduce semantic keyword checks in the script.

### Worthiness tag skip

Tasks with `Tags` containing `worthiness:calendar-like` or `worthiness:info-only` skip Layer 2 entirely per the protocol Quality Spec. Layer 1 structural checks — including the reserved-placeholder rule — apply to them like any other task.

### Drift guard (tests + CI)

`tests/run.sh` pins the script's behavior with one or more fixtures per documented rule, including regression cases (a well-specified non-English AC must pass Ready; a legacy verdict line carrying the retired `suppressed-until` key must still parse). CI (`.github/workflows/validating-fields-tests.yml`) runs it on every PR touching this skill.

**Sync requirement:** any change to `scripts/validate-task-fields.sh`, to the Validation Rules table above, or to `references/quality-rubric.md` must land in the same commit as the matching test update. If the docs and the script disagree, the tests are the arbiter — fix whichever side the tests prove wrong.

## `find_quality_debt` (shared API)

When invoked with a list of Ready+ tasks, `validating-fields` can also return a categorized debt report (used by `monitoring-tasks` and `running-daily-tasks` Step 2.6). See `references/quality-rubric.md` for the output shape. Categories are structural-only (empty fields, unresolved placeholders, likely-non-task titles); semantic quality debt surfaces through Layer 2 verdicts instead.

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
