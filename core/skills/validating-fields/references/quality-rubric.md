# Layer 1 Structural Checks (v3.0.0+)

Deterministic rules applied at every status transition into Ready or beyond. No LLM involvement; this is a fast, free pre-filter that catches structurally broken specs before any expensive Reviewer call.

This document is the canonical Layer 1 definition. The `task-quality-reviewer-agent` (Layer 2) is the canonical owner of the 5 IRC axes; both layers are referenced by `reviewing-quality`, `monitoring-tasks`, `planning-tasks`, `running-daily-tasks`, and the protocol spec.

## Design Boundary: Structural Only

Layer 1 checks only properties a script can decide **exactly and language-independently**: emptiness, length, reserved placeholder strings, and verdict-line integrity. It makes no judgment about the *meaning* of AC/EP text.

Semantic quality — verifiability, groundedness, echo-of-title, step richness, concrete artifacts — is owned entirely by Layer 2 (the `task-quality-reviewer-agent`'s 5 axes: goal clarity, boundary clarity, verifiability, reproducibility, hidden context).

> **History (v3.0.0)**: earlier versions defined semantic heuristics at Layer 1 (rules R-AC1–R-AC3, R-EP1–R-EP4: verifiable-indicator keyword lists, echo-of-title token overlap, step-count/step-length thresholds, concrete-artifact detection). They were removed because keyword heuristics cannot judge semantics: the implemented `semantic_quality` check hard-rejected well-specified Japanese ACs (its command/verb/unit vocabularies were English-only) while passing vague English prose that happened to contain a `/` or the word "test". Every semantic axis those rules approximated is evaluated better by Layer 2. Do not reintroduce semantic keyword rules at this layer.

## Checks

All rules are enforced by `scripts/validate-task-fields.sh` (see SKILL.md for the canonical flat input format). `tests/run.sh` pins each rule with fixtures — any change to the script or to this document must update both together; CI runs the tests on every PR touching this skill.

### Common (all target statuses)

| Rule | Field | Check | Severity |
|---|---|---|---|
| `required_non_empty` | Description | Non-empty | error |
| `hierarchy_2level` | Parent Task | A task with subtasks cannot itself be a subtask | error |
| `single_assignee` | Assignee | More than one assignee | warning |

### Ready / In Progress

| Rule | Field | Check | Severity |
|---|---|---|---|
| `min_length` | Description | ≥50 characters | error |
| `required_non_empty` | Acceptance Criteria | Non-empty | error |
| `placeholder_present` | Acceptance Criteria | No reserved placeholder (`[DRAFT-AC]` / `[DRAFT-EP]` / `[NEEDS-REFINE]`) remains | error |
| `required_non_empty` | Execution Plan | Non-empty | error |
| `placeholder_present` | Execution Plan | No reserved placeholder remains | error |
| `verdict_format` | Quality Verdict | When supplied, matches the cache format (lowercase 8-hex hash; fabricated/mnemonic hashes rejected) | error |
| `verdict_not_pass` | Quality Verdict | When supplied, must be `PASS` for Ready+ | error |
| `verdict_recommended` | Quality Verdict | Absent verdict — a fresh `reviewing-quality` PASS should travel in the same update as the Status change | warning |
| `required_set` | Executor | In Progress only: Executor must be set | error |
| `required_for_ai` | Working Directory | In Progress only: required for AI executors | error |
| `recommended` / `recommended_code_task` | Issuer, Assignee, Priority, Branch, Working Directory, Repository | Advisory field hygiene (code-task detection via `config/code-task-keywords.txt`) | warning |

### Blocked

| Rule | Field | Check | Severity |
|---|---|---|---|
| `required_non_empty` | Acceptance Criteria | Required even for Blocked — define what completion looks like | error |
| `recommended` | Error Message | Document why the task is blocked | warning |

### Done

| Rule | Field | Check | Severity |
|---|---|---|---|
| `required_for_ai_done` | Agent Output | Required for AI executor tasks (tasks created before the cutoff date are grandfathered to a warning) | error |

## Reserved Placeholders

The protocol reserves exactly two prefixes (three strings): `[DRAFT-AC]` / `[DRAFT-EP]` (field is an intentional stub) and `[NEEDS-REFINE]` (Reviewer flagged the field). Any of the three appearing in AC **or** EP blocks Ready+ — a `[DRAFT-EP]` string sitting in the AC field is just as much unresolved work as one in EP.

## Verdict Composition

`validate-task-fields.sh <target> <task.json>` returns:

```json
{
  "valid": true|false,
  "target_status": "Ready",
  "errors": [{ "field": "...", "rule": "placeholder_present", "message": "..." }, ...],
  "warnings": [{ "field": "...", "rule": "recommended", "message": "..." }, ...]
}
```

- Any **error** sets `valid: false` and blocks the transition.
- **Warnings** do not block but are surfaced to the user.

## `find_quality_debt(tasks)`

Given a list of Ready+ tasks, returns each task that fails a structural check, categorized. Used by `monitoring-tasks` and `running-daily-tasks` Step 2.6.

```json
{
  "EMPTY_AC_READY_PLUS": ["task_id_1", ...],
  "EMPTY_EP_READY_PLUS": [...],
  "DRAFT_AC_PRESENT": [...],      // placeholder_present on AC
  "DRAFT_EP_PRESENT": [...],      // placeholder_present on EP
  "LIKELY_NON_TASK": [...]        // title regex match + 1-line desc + empty AC/EP
}
```

Semantic quality debt (vague but non-empty ACs) is no longer enumerated here — it surfaces through Layer 2 verdicts instead: `monitoring-tasks`' Ready Health Score counts Ready tasks whose cached Reviewer verdict is PASS.

## Worthiness Tag Skip

Tasks with `Tags` containing `worthiness:calendar-like` or `worthiness:info-only` skip Layer 2 entirely per the protocol Quality Spec. Layer 1 structural checks (including `placeholder_present`) apply to them like any other task: a worthiness-tagged task with `[DRAFT-AC]` / `[DRAFT-EP]` / `[NEEDS-REFINE]` remaining cannot be promoted to Ready until the user removes the placeholder. This prevents accidentally promoting a never-refined worthiness-tagged stub.
